"""API が契約（schema/）どおりに応答するかを確かめる。fake モードで動かす（課金なし）。"""
import copy
import json

import pytest
from fastapi.testclient import TestClient

from app import contracts
from app.main import create_app
from app.settings import EXAMPLES_DIR, Settings

TOKEN = "test-token"
H = {"X-App-Token": TOKEN}


def example(name: str) -> dict:
    with open(EXAMPLES_DIR / name, encoding="utf-8") as f:
        return json.load(f)


def make_client(**overrides) -> TestClient:
    s = Settings(gemini_mode="fake", app_token=TOKEN, **overrides)
    return TestClient(create_app(settings=s), raise_server_exceptions=False)


@pytest.fixture
def client() -> TestClient:
    return make_client()


def assert_valid(schema_rel: str, instance):
    errs = list(contracts.validator(schema_rel).iter_errors(instance))
    assert not errs, [e.message for e in errs]


# ---- /health ----

def test_health_without_token(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


# ---- 認証 ----

@pytest.mark.parametrize("headers", [{}, {"X-App-Token": "wrong"}])
def test_v1_requires_token(client, headers):
    r = client.get("/v1/tiles/16/57746/25576", headers=headers)
    assert r.status_code == 401
    assert r.json() == {"error": "unauthorized"}


def test_v1_rejects_all_when_token_not_configured():
    c = TestClient(create_app(settings=Settings(gemini_mode="fake", app_token="")))
    r = c.get("/v1/tiles/16/57746/25576", headers={"X-App-Token": ""})
    assert r.status_code == 401


# ---- /v1/tiles ----

def test_tile_sample_matches_example(client):
    r = client.get("/v1/tiles/16/57746/25576", headers=H)
    assert r.status_code == 200
    assert r.json() == example("tile_response.json")
    assert_valid(contracts.TILE_RESPONSE, r.json())


def test_tile_other_is_empty_and_valid(client):
    r = client.get("/v1/tiles/16/1/2", headers=H)
    assert r.status_code == 200
    body = r.json()
    assert body["tile"] == {"z": 16, "x": 1, "y": 2}
    assert body["landmarks"] == [] and body["stops"] == []
    assert_valid(contracts.TILE_RESPONSE, body)


@pytest.mark.parametrize("path,status,code", [
    ("/v1/tiles/15/1/2", 404, "not_found"),      # z は 16 固定
    ("/v1/tiles/16/a/2", 400, "bad_request"),
    ("/v1/tiles/16/1/65536", 400, "bad_request"),
])
def test_tile_bad_paths(client, path, status, code):
    r = client.get(path, headers=H)
    assert r.status_code == status
    assert r.json() == {"error": code}


# ---- /v1/visual-search ----

def test_visual_search_with_area_returns_named(client):
    req = example("visual_search_request.json")
    r = client.post("/v1/visual-search", headers=H, json=req)
    assert r.status_code == 200
    body = r.json()
    assert_valid(contracts.VISUAL_RESPONSE, body)
    assert body["search_id"] == req["search_id"]
    assert body["result"] == "unlisted" and body["named"] is True


def test_visual_search_with_candidates_returns_matched(client):
    req = example("visual_search_request.json") | {"area": None, "candidate_ids": ["lm_0002"]}
    body = client.post("/v1/visual-search", headers=H, json=req).json()
    assert_valid(contracts.VISUAL_RESPONSE, body)
    assert body["result"] == "matched" and body["landmark_id"] == "lm_0002"


def test_visual_search_without_candidates_returns_unlisted(client):
    req = example("visual_search_request.json") | {"area": None, "candidate_ids": []}
    body = client.post("/v1/visual-search", headers=H, json=req).json()
    assert_valid(contracts.VISUAL_RESPONSE, body)
    assert body["result"] == "unlisted"


def test_visual_search_unknown_switch(client):
    req = example("visual_search_request.json") | {"search_id": "s_000009_unknown"}
    body = client.post("/v1/visual-search", headers=H, json=req).json()
    assert_valid(contracts.VISUAL_RESPONSE, body)
    assert body["result"] == "unknown"


@pytest.mark.parametrize("mutate", [
    lambda r: r.pop("search_id"),
    lambda r: r.update(gaze_az_deg=185),             # 10°単位でない
    lambda r: r.update(candidate_ids=["x_1"]),
    lambda r: r.update(extra="not in schema"),
])
def test_visual_search_rejects_off_contract(client, mutate):
    req = example("visual_search_request.json")
    mutate(req)
    r = client.post("/v1/visual-search", headers=H, json=req)
    assert r.status_code == 400
    assert r.json() == {"error": "bad_request"}


def test_visual_search_rejects_broken_json(client):
    r = client.post("/v1/visual-search", headers=H | {"Content-Type": "application/json"}, content=b"{not json")
    assert r.status_code == 400
    assert r.json() == {"error": "bad_request"}


def test_visual_search_image_too_large():
    c = make_client(max_image_base64_chars=10)
    req = example("visual_search_request.json") | {"image_jpeg_base64": "A" * 11}
    r = c.post("/v1/visual-search", headers=H, json=req)
    assert r.status_code == 413
    assert r.json() == {"error": "image_too_large"}


def test_visual_search_daily_limit():
    c = make_client(visual_search_daily_limit=2)
    req = example("visual_search_request.json")
    assert c.post("/v1/visual-search", headers=H, json=req).status_code == 200
    assert c.post("/v1/visual-search", headers=H, json=req).status_code == 200
    r = c.post("/v1/visual-search", headers=H, json=req)
    assert r.status_code == 429
    assert r.json() == {"error": "rate_limited"}


def test_fake_does_not_mutate_examples(client):
    """fake の応答をいじっても、次の応答が変わらない（見本をコピーして返している）。"""
    req = example("visual_search_request.json")
    first = client.post("/v1/visual-search", headers=H, json=req).json()
    second = client.post("/v1/visual-search", headers=H, json=copy.deepcopy(req)).json()
    assert first == second


# ---- 設定 ----

def test_default_mode_is_fake(monkeypatch):
    monkeypatch.delenv("GEMINI_MODE", raising=False)
    assert Settings().gemini_mode == "fake"


def test_real_mode_not_implemented_yet():
    with pytest.raises(RuntimeError):
        create_app(settings=Settings(gemini_mode="real", app_token=TOKEN))

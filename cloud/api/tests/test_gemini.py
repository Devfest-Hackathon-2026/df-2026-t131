"""本物の視界の検索（GeminiVisualSearch）の後処理と呼び方を、偽の Gemini で確かめる（課金なし）。"""
import base64
import json
from types import SimpleNamespace as NS

import pytest
from fastapi.testclient import TestClient

from app import contracts
from app.errors import ApiError
from app.gemini import GeminiVisualSearch, clean_description, postprocess
from app.main import create_app
from app.settings import EXAMPLES_DIR, Settings
from app.sources import FakeTileSource

S = Settings(gemini_mode="real", app_token="t", gcp_project="test")
IMG = base64.b64encode(b"\xff\xd8\xff\xe0fake-jpeg").decode()


def example(name):
    with open(EXAMPLES_DIR / name, encoding="utf-8") as f:
        return json.load(f)


def request(**kw):
    return example("visual_search_request.json") | {"image_jpeg_base64": IMG} | kw


def valid(res):
    errs = [e.message for e in contracts.validator(contracts.VISUAL_RESPONSE).iter_errors(res)]
    assert not errs, errs
    return res


class FakeClient:
    """client.models.generate_content だけを真似る。"""

    def __init__(self, answer=None, chunks=(), raise_exc=None):
        self.answer, self.chunks, self.raise_exc, self.calls = answer, list(chunks), raise_exc, []
        self.models = self

    def generate_content(self, model, contents, config):
        self.calls.append(NS(model=model, contents=contents, config=config))
        if self.raise_exc:
            raise self.raise_exc
        meta = NS(grounding_chunks=[NS(maps=NS(**c)) for c in self.chunks])
        return NS(text=json.dumps(self.answer, ensure_ascii=False), candidates=[NS(grounding_metadata=meta)])


def ans(**kw):
    return {"result": "unknown", "landmark_id": None, "object_name": None, "named": False,
            "description": None, "confidence": 0.9} | kw


# ---- 後処理 ----

def pp(answer, cands=("lm_0001", "lm_0002"), sources=()):
    text = answer if isinstance(answer, str) else json.dumps(answer, ensure_ascii=False)
    return valid(postprocess(text, "s_000001", list(cands), list(sources), S))


def test_matched_in_candidates():
    r = pp(ans(result="matched", landmark_id="lm_0002"))
    assert r["result"] == "matched" and r["landmark_id"] == "lm_0002" and r["object_name"] is None


def test_matched_not_in_candidates_becomes_unknown():
    assert pp(ans(result="matched", landmark_id="lm_0099"))["result"] == "unknown"


def test_unlisted_drops_sentences_with_numbers():
    r = pp(ans(result="unlisted", object_name="古い木造の蔵",
               description="白い壁の蔵です。明治時代に建てられました。高さは12メートルあります。黒い瓦が目印です。"))
    assert r["description"] == "白い壁の蔵です。黒い瓦が目印です。"


def test_unlisted_only_numbers_becomes_unknown():
    assert pp(ans(result="unlisted", object_name="蔵", description="昭和三年に建ちました。"))["result"] == "unknown"


def test_unlisted_without_name_or_with_number_in_name_becomes_unknown():
    assert pp(ans(result="unlisted", object_name="", description="橋です。"))["result"] == "unknown"
    assert pp(ans(result="unlisted", object_name="第2倉庫", description="倉庫です。"))["result"] == "unknown"


def test_description_is_cut():
    long = "とても長い説明の文です。" * 20
    r = pp(ans(result="unlisted", object_name="橋", description=long))
    assert len(r["description"]) <= 100 and r["description"].endswith("。")
    assert len(clean_description("あ" * 300, 100)) == 100


@pytest.mark.parametrize("raw", ["", "ごめんなさい", "{broken json", json.dumps({"result": "maybe"})])
def test_broken_answers_become_unknown(raw):
    assert pp(raw)["result"] == "unknown"


def test_low_confidence_becomes_unknown_and_confidence_is_clamped():
    assert pp(ans(result="matched", landmark_id="lm_0001", confidence=0.1))["result"] == "unknown"
    assert pp(ans(result="matched", landmark_id="lm_0001", confidence=7))["confidence"] == 1.0


def test_named_and_sources_pass_through():
    src = [{"title": "見本橋", "uri": "https://maps.google.com/?cid=1", "place_id": "p1"}]
    r = pp(ans(result="unlisted", object_name="見本橋", named=True, description="歩行者用の橋です。"), sources=src)
    assert r["named"] is True and r["sources"] == src


# ---- 呼び方 ----

def test_search_prompt_has_candidates_and_drops_unknown_ids():
    c = FakeClient(ans(result="matched", landmark_id="lm_0099"))
    g = GeminiVisualSearch(S, FakeTileSource(), client=c)
    r = valid(g.search(request(area=None, candidate_ids=["lm_0001", "lm_0099"])))
    prompt = c.calls[0].contents[1]
    assert "lm_0001：見本の石碑" in prompt and "灰色の細長い石碑" in prompt
    assert "lm_0099" not in prompt                 # DB に無い候補は渡さない
    assert r["result"] == "unknown"                # DB に無い候補と答えても信じない
    assert c.calls[0].config.response_schema is not None   # グラウンディングなしは構造化出力


def test_search_in_area_with_maps_grounding():
    s = Settings(gemini_mode="real", app_token="t", gcp_project="test", gemini_grounding="maps")
    c = FakeClient(ans(result="unlisted", object_name="見本橋", named=True, description="公園の両岸を結ぶ橋です。"),
                   chunks=[{"title": "見本橋", "uri": "https://maps.google.com/?cid=1", "place_id": "p1"}])
    r = valid(GeminiVisualSearch(s, FakeTileSource(), client=c).search(request()))
    cfg = c.calls[0].config
    assert cfg.tools and cfg.tools[0].google_maps is not None
    assert 36.6 < cfg.tool_config.retrieval_config.lat_lng.latitude < 36.8   # タイルの中心（正確な位置は送らない）
    assert "エリア「見本の公園」の中にいる" in c.calls[0].contents[1]
    assert r["named"] is True and r["sources"][0]["place_id"] == "p1"


def test_grounding_off_even_in_area():
    c = FakeClient(ans())
    GeminiVisualSearch(S, FakeTileSource(), client=c).search(request())
    assert not c.calls[0].config.tools


ReadTimeout = type("ReadTimeout", (Exception,), {})


@pytest.mark.parametrize("exc,status,code", [
    (ReadTimeout("read timed out"), 504, "gemini_timeout"),
    (RuntimeError("500 internal"), 502, "gemini_error"),
])
def test_errors(exc, status, code):
    g = GeminiVisualSearch(S, FakeTileSource(), client=FakeClient(raise_exc=exc))
    with pytest.raises(ApiError) as e:
        g.search(request())
    assert (e.value.status, e.value.code) == (status, code)


def test_bad_base64_is_bad_request():
    g = GeminiVisualSearch(S, FakeTileSource(), client=FakeClient(ans()))
    with pytest.raises(ApiError) as e:
        g.search(request(image_jpeg_base64="@@not base64@@"))
    assert e.value.code == "bad_request"


# ---- HTTP ----

def test_http_real_mode_with_fake_client():
    tiles = FakeTileSource()
    good = GeminiVisualSearch(S, tiles, client=FakeClient(ans(result="matched", landmark_id="lm_0001")))
    c = TestClient(create_app(settings=S, tile_source=tiles, visual_search=good))
    r = c.post("/v1/visual-search", headers={"X-App-Token": "t"}, json=request(area=None))
    assert r.status_code == 200 and valid(r.json())["landmark_id"] == "lm_0001"

    slow = GeminiVisualSearch(S, tiles, client=FakeClient(raise_exc=ReadTimeout("timed out")))
    c = TestClient(create_app(settings=S, tile_source=tiles, visual_search=slow))
    r = c.post("/v1/visual-search", headers={"X-App-Token": "t"}, json=request())
    assert r.status_code == 504 and r.json() == {"error": "gemini_timeout"}


def test_real_mode_requires_project():
    with pytest.raises(RuntimeError):
        create_app(settings=Settings(gemini_mode="real", app_token="t", gcp_project=""))

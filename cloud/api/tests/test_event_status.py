"""イベントの開催状態の上書き（Firestore は偽物）。"""
from fastapi.testclient import TestClient

from app.event_status import CachedEventStatus, apply_statuses
from app.main import create_app
from app.settings import Settings
from app.sources import FakeTileSource

H = {"X-App-Token": "t"}
SAMPLE = "/v1/tiles/16/57746/25576"


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def test_status_is_overridden_in_tile():
    st = CachedEventStatus(lambda ids: {"ev_0001": "cancelled"})
    c = TestClient(create_app(settings=Settings(app_token="t"), event_status=st))
    events = c.get(SAMPLE, headers=H).json()["events"]
    assert [e["status"] for e in events] == ["cancelled"]


def test_file_mode_keeps_events_json_status():
    c = TestClient(create_app(settings=Settings(app_token="t")))
    assert c.get(SAMPLE, headers=H).json()["events"][0]["status"] == "held"


def test_cache_and_ttl():
    calls, clock = [], Clock()

    def fetch(ids):
        calls.append(list(ids))
        return {"ev_0001": "cancelled" if len(calls) == 1 else "held"}

    st = CachedEventStatus(fetch, ttl_s=30, clock=clock)
    assert st.statuses(["ev_0001"]) == {"ev_0001": "cancelled"}
    clock.t = 10
    assert st.statuses(["ev_0001"]) == {"ev_0001": "cancelled"} and len(calls) == 1   # 30秒は覚えている
    clock.t = 31
    assert st.statuses(["ev_0001"]) == {"ev_0001": "held"} and len(calls) == 2


def test_unknown_status_or_failure_keeps_file_value():
    bad = CachedEventStatus(lambda ids: {"ev_0001": "maybe"})
    assert bad.statuses(["ev_0001"]) == {}

    def boom(ids):
        raise RuntimeError("firestore down")

    tile = FakeTileSource().get_tile(57746, 25576)
    assert apply_statuses(tile, CachedEventStatus(boom))["events"][0]["status"] == "held"


def test_no_events_no_fetch():
    calls = []
    st = CachedEventStatus(lambda ids: calls.append(ids) or {})
    apply_statuses(FakeTileSource().get_tile(1, 2), st)
    assert calls == []

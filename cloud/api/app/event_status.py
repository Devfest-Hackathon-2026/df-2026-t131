"""イベントの開催状態（予定・開催中・中止）。変わるデータなので Firestore に置く（docs/design.md 8章）。

イベントそのもの（名前・場所・時間）は SQLite（manual/events.json）にあり、ここでは状態だけを上書きする。
デモでは Firestore の画面で event_status/<イベント ID> の status を "cancelled" にすると、
次にタイルを取ったときから「中止」として返る（engine は中止のイベントを話さない）。

  EVENT_STATUS=file       events.json の status をそのまま使う（既定）
  EVENT_STATUS=firestore  Firestore の event_status/<ID>.status で上書きする（30秒だけ覚えておく）
"""
import logging
import threading
import time
from typing import Protocol

log = logging.getLogger("api")
STATUSES = ("scheduled", "held", "cancelled")


class EventStatusSource(Protocol):
    def statuses(self, ids: list[str]) -> dict[str, str]:
        """ID → 状態。分からない ID は入れない（events.json の値のまま使う）。"""


class FileEventStatus:
    def statuses(self, ids: list[str]) -> dict[str, str]:
        return {}


class CachedEventStatus:
    """読み出しの結果を ttl 秒だけ覚えておく（Firestore の読み取り回数＝費用を抑える）。
    読み出しに失敗したら上書きしない（イベントの案内を止めない）。"""

    def __init__(self, fetch, ttl_s: float = 30.0, clock=time.monotonic):
        self._fetch, self._ttl, self._clock = fetch, ttl_s, clock
        self._cache: dict[str, tuple[float, str | None]] = {}
        self._lock = threading.Lock()

    def statuses(self, ids: list[str]) -> dict[str, str]:
        now = self._clock()
        with self._lock:
            missing = [i for i in ids if i not in self._cache or now - self._cache[i][0] > self._ttl]
        if missing:
            try:
                got = self._fetch(missing)
            except Exception as e:
                log.error("event status fetch failed: %s", type(e).__name__)
                got = None
            if got is not None:
                with self._lock:
                    for i in missing:
                        s = got.get(i)
                        self._cache[i] = (now, s if s in STATUSES else None)
        with self._lock:
            return {i: self._cache[i][1] for i in ids if i in self._cache and self._cache[i][1]}


def firestore_event_status(collection: str = "event_status") -> CachedEventStatus:
    from google.cloud import firestore

    client = firestore.Client()
    col = client.collection(collection)

    def fetch(ids: list[str]) -> dict[str, str]:
        snaps = client.get_all([col.document(i) for i in ids])
        return {s.id: (s.to_dict() or {}).get("status") for s in snaps if s.exists}

    return CachedEventStatus(fetch)


def apply_statuses(tile: dict, source: EventStatusSource) -> dict:
    events = tile.get("events") or []
    if not events:
        return tile
    st = source.statuses([e["id"] for e in events])
    for e in events:
        if e["id"] in st:
            e["status"] = st[e["id"]]
    return tile

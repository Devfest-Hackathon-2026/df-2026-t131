"""警報ジョブの前回の状態（インスタンスをまたいで共有するため Firestore に置く）。

  ジョブ全体（フィードの ETag・Last-Modified・処理済みの電文 ID）：alert_job/feed
  区域ごと（分野ごとのいちばん高いレベル）                   ：alert_state/<区域7桁>

区域を足しても、区域の文書が増えるだけ。
"""
from dataclasses import asdict, dataclass, field
from typing import Protocol

MAX_REMEMBERED = 300


@dataclass
class FeedState:
    etag: str | None = None
    last_modified: str | None = None
    processed: list[str] = field(default_factory=list)  # 読んだ電文の ID（新しいものを最大300件）

    def remember(self, entry_id: str) -> None:
        self.processed.append(entry_id)
        self.processed = self.processed[-MAX_REMEMBERED:]


@dataclass
class CategoryState:
    level: int = 0
    kind: str = ""       # いちばん高いものの名前（例：大雨危険警報）。レベル0なら空
    alert_id: str = ""   # そのとき送った（送るはずだった）警報の ID


@dataclass
class AreaState:
    categories: dict[str, CategoryState] = field(default_factory=dict)  # 分野（電文の題名）→ 状態
    published: bool = False  # 今出ている警報の一覧を一度でも書き出したか（無ければ最初に [] を書く）

    def to_dict(self) -> dict:
        return {"categories": {k: asdict(v) for k, v in self.categories.items()}, "published": self.published}

    @staticmethod
    def from_dict(d: dict) -> "AreaState":
        return AreaState(
            categories={k: CategoryState(**v) for k, v in (d.get("categories") or {}).items()},
            published=bool(d.get("published")),
        )


class StateStore(Protocol):
    def load_feed(self) -> FeedState: ...
    def save_feed(self, state: FeedState) -> None: ...
    def load_area(self, area_code: str) -> AreaState: ...
    def save_area(self, area_code: str, state: AreaState) -> None: ...


class MemoryStateStore:
    def __init__(self) -> None:
        self.feed = FeedState()
        self.areas: dict[str, dict] = {}

    def load_feed(self) -> FeedState:
        return FeedState(**asdict(self.feed))

    def save_feed(self, state: FeedState) -> None:
        self.feed = FeedState(**asdict(state))

    def load_area(self, area_code: str) -> AreaState:
        return AreaState.from_dict(self.areas.get(area_code, {}))

    def save_area(self, area_code: str, state: AreaState) -> None:
        self.areas[area_code] = state.to_dict()


class FirestoreStateStore:
    def __init__(self) -> None:
        from google.cloud import firestore

        self._db = firestore.Client()
        self._feed = self._db.collection("alert_job").document("feed")
        # 11/6 より前の形（alert_job/state にすべて入っていた）。フィードの続きだけ引き継ぐ
        self._legacy = self._db.collection("alert_job").document("state")

    def load_feed(self) -> FeedState:
        snap = self._feed.get()
        if snap.exists:
            return FeedState(**snap.to_dict())
        old = self._legacy.get()
        if old.exists:  # 移行：同じ電文を読み直して二重に送らないよう、処理済みの ID を引き継ぐ
            d = old.to_dict()
            return FeedState(d.get("etag"), d.get("last_modified"), list(d.get("processed") or []))
        return FeedState()

    def save_feed(self, state: FeedState) -> None:
        self._feed.set(asdict(state))

    def load_area(self, area_code: str) -> AreaState:
        snap = self._db.collection("alert_state").document(area_code).get()
        return AreaState.from_dict(snap.to_dict()) if snap.exists else AreaState()

    def save_area(self, area_code: str, state: AreaState) -> None:
        self._db.collection("alert_state").document(area_code).set(state.to_dict())

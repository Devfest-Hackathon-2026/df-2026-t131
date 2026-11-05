"""警報ジョブの前回の状態（インスタンスをまたいで共有するため Firestore に置く）。"""
from dataclasses import asdict, dataclass, field
from typing import Protocol


@dataclass
class State:
    etag: str | None = None
    last_modified: str | None = None
    levels: dict[str, int] = field(default_factory=dict)   # 分野 → いちばん高いレベル
    processed: list[str] = field(default_factory=list)     # 読んだ電文の ID（新しいものを最大300件）


class StateStore(Protocol):
    def load(self) -> State: ...
    def save(self, state: State) -> None: ...


class MemoryStateStore:
    def __init__(self) -> None:
        self.state = State()

    def load(self) -> State:
        return State(**asdict(self.state))

    def save(self, state: State) -> None:
        self.state = State(**asdict(state))


class FirestoreStateStore:
    def __init__(self, collection: str = "alert_job", doc: str = "state") -> None:
        from google.cloud import firestore

        self._ref = firestore.Client().collection(collection).document(doc)

    def load(self) -> State:
        snap = self._ref.get()
        return State(**snap.to_dict()) if snap.exists else State()

    def save(self, state: State) -> None:
        self._ref.set(asdict(state))

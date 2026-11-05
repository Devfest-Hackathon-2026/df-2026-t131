"""警報ジョブの本体：フィード → 電文 → 前回と比べる → FCM。

判断（決定論的）:
  - 分野（大雨・土砂・暴風…）ごとに、対象の市町村の「いちばん高いレベル」を覚えておく
  - 前回より上がり、かつ ALERT_MIN_LEVEL 以上になったときだけ送る（同じ警報を何度も送らない）
  - 下がったとき・解除のときは送らない（覚えている値だけ更新する）
  - 文はテンプレートで作る（AI は使わない。CLAUDE.md 3章7・8）
"""
import json
import logging
from dataclasses import dataclass, field

from jsonschema import Draft202012Validator

from .jma import FeedSource, Telegram, parse_feed, parse_telegram
from .sender import Sender
from .settings import SCHEMA_DIR, SCHEMA_VERSION, Settings
from .state import State, StateStore

log = logging.getLogger("alert-job")
MAX_REMEMBERED = 300


def build_text(area_name: str, level: int, kind_name: str, mock: bool) -> str:
    parts = []
    if mock:
        parts.append("これはデモ用の模擬の警報です。")
    parts.append(f"{area_name}に、警戒レベル{level}の{kind_name}が発表されました。")
    if level >= 4:
        parts.append("危険な場所から離れ、安全を確保してください。最新の情報を確認してください。")
    else:
        parts.append("今後の情報に注意してください。")
    return "".join(parts)


def build_data(t: Telegram, level: int, kind_name: str, settings: Settings, mock: bool) -> dict:
    return {
        "schema_version": SCHEMA_VERSION,
        "type": "alert",
        "alert_id": f"{'mock_' if mock else ''}{t.report_datetime}_{settings.municipality_code}_{kind_name}",
        "level": str(level),
        "kind": kind_name,
        "area_name": settings.area_name,
        "text": build_text(settings.area_name, level, kind_name, mock),
    }


def _validator() -> Draft202012Validator:
    from referencing import Registry, Resource

    reg = Registry()
    for p in SCHEMA_DIR.rglob("*.schema.json"):
        s = json.loads(p.read_text(encoding="utf-8"))
        reg = reg.with_resource(s["$id"], Resource.from_contents(s))
    return Draft202012Validator(json.loads((SCHEMA_DIR / "fcm" / "alert.data.schema.json").read_text(encoding="utf-8")), registry=reg)


@dataclass
class RunResult:
    feed_changed: bool = False
    telegrams: int = 0
    sent: list[dict] = field(default_factory=list)


class AlertJob:
    def __init__(self, settings: Settings, source: FeedSource, store: StateStore, sender: Sender):
        self.s, self.source, self.store, self.sender = settings, source, store, sender
        self._v = _validator()

    def _apply(self, t: Telegram, state: State, mock: bool, result: RunResult) -> None:
        if t.status != "通常" and not mock:
            return  # 訓練・試験の電文は読まない
        top = t.kinds[0] if t.kinds else (0, "")
        prev = state.levels.get(t.category, 0)
        state.levels[t.category] = top[0]
        if top[0] > prev and top[0] >= self.s.min_level:
            data = build_data(t, top[0], top[1], self.s, mock)
            errs = [e.message for e in self._v.iter_errors(data)]
            if errs:  # 形が壊れたものは送らない
                log.error("FCM の data が schema に合わない: %s", errs)
                return
            self.sender.send(self.s.topic, data)
            result.sent.append(data)

    def run(self) -> RunResult:
        state = self.store.load()
        result = RunResult()
        body, etag, lm = self.source.fetch_feed(state.etag, state.last_modified)
        if body is None:
            return result
        result.feed_changed = True
        for entry in parse_feed(body, self.s.office_code):
            if entry.id in state.processed:
                continue
            t = parse_telegram(self.source.fetch_telegram(entry.link), self.s.municipality_code)
            result.telegrams += 1
            self._apply(t, state, mock=False, result=result)
            state.processed.append(entry.id)
        state.processed = state.processed[-MAX_REMEMBERED:]
        state.etag, state.last_modified = etag, lm
        self.store.save(state)
        return result

    def run_mock(self, telegram_xml: bytes) -> RunResult:
        """デモ用：模擬電文を本物と同じ判定に通す。送る文に「デモ用の模擬の警報」と入る。
        覚えている値は本物と別に持つ（本物の判定に影響させない）。"""
        result = RunResult()
        state = State()  # 毎回まっさらから判定する（何度でも鳴らせるように）
        t = parse_telegram(telegram_xml, self.s.municipality_code)
        result.telegrams = 1
        self._apply(t, state, mock=True, result=result)
        return result

"""警報ジョブの本体。全国版と同じ3つの段に分けてある（段の間は dataclass で受け渡す）。

  ingest    ：フィードを条件付き GET → 対象の気象台の新しい電文を取る → 元の電文を記録する
  evaluate  ：区域 × 分野の「いちばん高いレベル」を前回と比べる（決定論的。AI は使わない）
  distribute：上がった警報を FCM のトピック alert_<区域7桁> へ送る／一覧 alerts/current/<区域7桁>.json を書き換える

全国版では段の間に Pub/Sub をはさむ。デモは1つの Cloud Run の中で順に呼ぶ（判定の結果は同じ）。

判断の決まり（前と同じ）:
  - 前回より上がり、かつ ALERT_MIN_LEVEL 以上になったときだけ送る（同じ警報を何度も送らない）
  - 下がったとき・解除のときは送らない（覚えている値と一覧だけ更新する）
  - 訓練・試験の電文は読まない
  - 文はテンプレートで作る（AI は使わない。CLAUDE.md 3章7・8）
"""
import json
import logging
import time
from dataclasses import dataclass, field

from jsonschema import Draft202012Validator

from .jma import FeedSource, Telegram, parse_feed, parse_telegram
from .sender import Sender
from .settings import SCHEMA_DIR, SCHEMA_VERSION, Settings
from .state import AreaState, CategoryState, FeedState, StateStore
from .storage import Archive, Publisher, current_path, raw_path

log = logging.getLogger("alert-job")

# 模擬の警報は、実際の警報と取り違えないよう、頭に断りを入れ、「気象庁が発表した」とは言わない
# （気象業務法 第23条：気象庁以外の者は警報をしてはならない。伝えるのは気象庁の発表だけ）
MOCK_PREFIX = "これは訓練用の模擬の警報で、実際の警報ではありません。"


# ======================================================================
# 文（テンプレート）と ID
# ======================================================================

def build_text(area_name: str, level: int, kind_name: str, mock: bool, current: bool = False) -> str:
    """current=False は FCM 用（発表しました）、True は一覧用（後から入った人向け：発表しています）。
    本物は「気象庁は、〜を発表しました」と、気象庁の発表を伝えていることが分かる文にする（CLAUDE.md 3章8）。
    模擬は「〜が出た、という想定です」とし、気象庁の名前は出さない。"""
    if mock:
        parts = [MOCK_PREFIX, f"{area_name}に警戒レベル{level}の{kind_name}が出た、という想定です。"]
    elif current:
        parts = [f"気象庁は、{area_name}に警戒レベル{level}の{kind_name}を発表しています。"]
    else:
        parts = [f"気象庁は、{area_name}に警戒レベル{level}の{kind_name}を発表しました。"]
    if level >= 4:
        parts.append("危険な場所から離れ、安全を確保してください。最新の情報を確認してください。")
    else:
        parts.append("今後の情報に注意してください。")
    return "".join(parts)


def build_alert_id(t: Telegram, area_code: str, kind_name: str, mock_sent_ms: int | None) -> str:
    """同じ発表なら同じ ID（端末は2回目を捨てる）。
    模擬の警報は電文の発表時刻が固定なので、送った時刻を足して毎回別の ID にする（何度でも鳴らせるように）。"""
    base = f"{t.report_datetime}_{area_code}_{kind_name}"
    return base if mock_sent_ms is None else f"mock_{base}_{mock_sent_ms}"


def build_data(area_code: str, alert_id: str, level: int, kind_name: str, settings: Settings, mock: bool) -> dict:
    """FCM の data（schema/fcm/alert.data.schema.json。値はすべて文字列）。"""
    name = settings.area_name(area_code)
    return {
        "schema_version": SCHEMA_VERSION,
        "type": "alert",
        "alert_id": alert_id,
        "level": str(level),
        "kind": kind_name,
        "area_code": area_code,
        "area_name": name,
        "text": build_text(name, level, kind_name, mock),
    }


def current_alerts(area_code: str, st: AreaState, settings: Settings, mock: bool) -> list[dict]:
    """今出ている ALERT_MIN_LEVEL 以上の警報（分野ごとに1つ）。レベルの高い順、同じなら分野の名前順。"""
    name = settings.area_name(area_code)
    rows = [(cat, c) for cat, c in st.categories.items() if c.level >= settings.min_level and c.kind]
    rows.sort(key=lambda r: (-r[1].level, r[0]))
    return [
        {"alert_id": c.alert_id, "level": str(c.level), "kind": c.kind,
         "text": build_text(name, c.level, c.kind, mock, current=True)}
        for _, c in rows
    ]


def build_current_doc(area_code: str, alerts: list[dict], settings: Settings, now_ms: int) -> dict:
    """alerts/current/<区域7桁>.json（schema/api/alerts_current.schema.json）。警報が無くても [] で置く。"""
    return {
        "schema_version": SCHEMA_VERSION,
        "area_code": area_code,
        "area_name": settings.area_name(area_code),
        "updated_at_ms": now_ms,
        "alerts": alerts,
    }


def _validator(schema_rel: str) -> Draft202012Validator:
    from referencing import Registry, Resource

    reg = Registry()
    for p in SCHEMA_DIR.rglob("*.schema.json"):
        s = json.loads(p.read_text(encoding="utf-8"))
        reg = reg.with_resource(s["$id"], Resource.from_contents(s))
    return Draft202012Validator(json.loads((SCHEMA_DIR / schema_rel).read_text(encoding="utf-8")), registry=reg)


# ======================================================================
# 段の間で受け渡すもの（全国版では Pub/Sub のメッセージになる）
# ======================================================================

@dataclass(frozen=True)
class RawTelegram:
    """ingest → evaluate：取ってきた電文1つ。"""
    entry_id: str
    office: str
    xml: bytes


@dataclass
class AreaUpdate:
    """evaluate → distribute：区域1つ分の結果。"""
    area_code: str
    state: AreaState                                   # 判定後の状態（distribute の後に保存する）
    sends: list[dict] = field(default_factory=list)    # FCM で送る data
    current: list[dict] | None = None                  # 一覧を書き換えるなら新しい中身（変わらなければ None）


@dataclass
class RunResult:
    feed_changed: bool = False
    telegrams: int = 0
    sent: list[dict] = field(default_factory=list)
    published: list[str] = field(default_factory=list)


# ======================================================================
# 段1：ingest
# ======================================================================

def ingest(source: FeedSource, feed: FeedState, settings: Settings, archive: Archive) -> tuple[bool, list[RawTelegram]]:
    """フィードが変わっていれば、対象の気象台のまだ読んでいない電文を古い順に取る。feed を書き換える。"""
    body, etag, lm = source.fetch_feed(feed.etag, feed.last_modified)
    if body is None:
        return False, []
    out = []
    for entry in parse_feed(body, settings.offices):
        if entry.id in feed.processed:
            continue
        xml = source.fetch_telegram(entry.link)
        try:
            archive.save(raw_path(entry.updated[:10] or "unknown", entry.file_id), xml)
        except Exception as e:  # 記録に失敗しても警報の判定は止めない
            log.warning("元の電文を記録できない: %s: %s", type(e).__name__, e)
        out.append(RawTelegram(entry.id, entry.office, xml))
        feed.remember(entry.id)
    feed.etag, feed.last_modified = etag, lm
    return True, out


# ======================================================================
# 段2：evaluate（決定論的）
# ======================================================================

def evaluate(telegrams: list[Telegram], states: dict[str, AreaState], settings: Settings,
             mock_sent_ms: int | None = None) -> list[AreaUpdate]:
    """電文を古い順に当てて、区域ごとに「送るもの」と「一覧の新しい中身」を決める。states は書き換えない。"""
    mock = mock_sent_ms is not None
    before = {a: current_alerts(a, st, settings, mock) for a, st in states.items()}
    work = {a: AreaState.from_dict(st.to_dict()) for a, st in states.items()}
    sends: dict[str, list[dict]] = {a: [] for a in states}

    for t in telegrams:
        if t.status != "通常" and not mock:
            continue  # 訓練・試験の電文は読まない
        for area, kinds in t.areas.items():
            if area not in work:
                continue
            top_level, top_kind = kinds[0] if kinds else (0, "")
            cats = work[area].categories
            prev = cats.get(t.category, CategoryState())
            if top_level == 0:
                cats[t.category] = CategoryState()
                continue
            if top_level == prev.level and top_kind == prev.kind:
                continue  # 継続。ID も変えない（端末が一覧から取り直しても、同じ警報として捨てられるように）
            alert_id = build_alert_id(t, area, top_kind, mock_sent_ms)
            cats[t.category] = CategoryState(top_level, top_kind, alert_id)
            if top_level > prev.level and top_level >= settings.min_level:
                sends[area].append(build_data(area, alert_id, top_level, top_kind, settings, mock))

    updates = []
    for area, st in work.items():
        after = current_alerts(area, st, settings, mock)
        changed = after != before[area] or not st.published
        if sends[area] or changed or st.to_dict() != states[area].to_dict():
            updates.append(AreaUpdate(area, st, sends[area], after if changed else None))
    return updates


# ======================================================================
# 段3：distribute
# ======================================================================

class Distributor:
    def __init__(self, settings: Settings, sender: Sender, publisher: Publisher) -> None:
        self.s, self.sender, self.publisher = settings, sender, publisher
        self._v_fcm = _validator("fcm/alert.data.schema.json")
        self._v_current = _validator("api/alerts_current.schema.json")

    def run(self, updates: list[AreaUpdate], now_ms: int, result: RunResult, mock: bool = False) -> None:
        for u in updates:
            for data in u.sends:
                errs = [e.message for e in self._v_fcm.iter_errors(data)]
                if errs:  # 形が壊れたものは送らない
                    log.error("FCM の data が schema に合わない: %s", errs)
                    continue
                for topic in self.s.topics_for(u.area_code):
                    self.sender.send(topic, data)
                result.sent.append(data)
            if u.current is not None:
                doc = build_current_doc(u.area_code, u.current, self.s, now_ms)
                errs = [e.message for e in self._v_current.iter_errors(doc)]
                if errs:
                    log.error("警報の一覧が schema に合わない: %s", errs)
                    continue
                path = current_path(u.area_code, mock)
                self.publisher.publish(path, doc)
                u.state.published = True
                result.published.append(path)


# ======================================================================
# ジョブ（3つの段を順に呼ぶ）
# ======================================================================

def _now_ms() -> int:
    return time.time_ns() // 1_000_000


class AlertJob:
    def __init__(self, settings: Settings, source: FeedSource, store: StateStore, sender: Sender,
                 publisher: Publisher, archive: Archive):
        self.s, self.source, self.store, self.archive = settings, source, store, archive
        self.distributor = Distributor(settings, sender, publisher)

    def run(self, now_ms: int | None = None) -> RunResult:
        now_ms = now_ms if now_ms is not None else _now_ms()
        result = RunResult()
        feed = self.store.load_feed()
        result.feed_changed, raws = ingest(self.source, feed, self.s, self.archive)
        result.telegrams = len(raws)
        telegrams = [parse_telegram(r.xml, self.s.areas_of(r.office)) for r in raws]

        states = {a: self.store.load_area(a) for a in self.s.areas}
        updates = evaluate(telegrams, states, self.s)
        self.distributor.run(updates, now_ms, result)
        for u in updates:
            self.store.save_area(u.area_code, u.state)
        if result.feed_changed:
            self.store.save_feed(feed)
        return result

    def clear_mock(self, now_ms: int | None = None) -> RunResult:
        """デモ用：模擬の警報の一覧（alerts/current/mock_<区域7桁>.json）を空に戻す。
        テストのあとに呼ぶ（残ったままだと、一覧を取りに来た端末が古い模擬の警報を読んでしまう）。"""
        now_ms = now_ms if now_ms is not None else _now_ms()
        result = RunResult()
        updates = [AreaUpdate(a, AreaState(), [], []) for a in self.s.areas]
        self.distributor.run(updates, now_ms, result, mock=True)
        return result

    def run_mock(self, telegram_xml: bytes, now_ms: int | None = None) -> RunResult:
        """デモ用：模擬電文を本物と同じ判定に通す。送る文に「デモ用の模擬の警報」と入る。
        状態は毎回まっさらから判定し、保存しない（本物の判定に影響させない・何度でも鳴らせる）。
        一覧は本物と分けて alerts/current/mock_<区域7桁>.json に書く。
        alert_id に送った時刻（UTC ミリ秒）を足すので、端末を起動したままでも毎回鳴る。"""
        now_ms = now_ms if now_ms is not None else _now_ms()
        result = RunResult(telegrams=1)
        t = parse_telegram(telegram_xml, self.s.areas)
        states = {a: AreaState() for a in self.s.areas}
        updates = evaluate([t], states, self.s, mock_sent_ms=now_ms)
        self.distributor.run(updates, now_ms, result, mock=True)
        return result

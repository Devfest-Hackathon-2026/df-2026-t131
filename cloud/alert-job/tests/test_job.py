"""警報ジョブの判定を、偽のフィード・電文で確かめる（通信なし・送信なし・書き出しなし）。"""
import pytest
from fastapi.testclient import TestClient

from app import settings as settings_mod
from app.jma import Telegram, parse_feed, parse_telegram
from app.job import AlertJob, build_alert_id, build_text, evaluate
from app.main import create_app
from app.sender import FakeSender
from app.settings import MOCK_DIR, Settings, office_for
from app.state import AreaState, MemoryStateStore
from app.storage import FakeArchive, FakePublisher

TOYAMA_CITY = "1620100"
TAKAOKA_CITY = "1620200"
BASE = "https://www.data.jma.go.jp/developer/xml/data/"
NOW = 1_793_581_200_000


def feed(*entries) -> bytes:
    body = "".join(
        f"""<entry><title>{title}</title><id>{BASE}{name}</id><updated>{updated}</updated>
        <author><name>x</name></author><link type="application/xml" href="{BASE}{name}"/></entry>"""
        for title, name, updated in entries
    )
    return f'<?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom">{body}</feed>'.encode()


def telegram(kinds: list[str], title="気象警報・注意報（Ｒ０６）（大雨）", status="通常",
             code=TOYAMA_CITY, report="2026-11-07T09:00:00+09:00") -> bytes:
    k = "".join(f"<Kind><Name>{n}</Name><Status>発表</Status></Kind>" for n in kinds) or \
        "<Kind><Status>発表警報・注意報はなし</Status></Kind>"
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://xml.kishou.go.jp/jmaxml1/">
 <Control><Title>{title}</Title><Status>{status}</Status></Control>
 <Head xmlns="http://xml.kishou.go.jp/jmaxml1/informationBasis1/"><ReportDateTime>{report}</ReportDateTime></Head>
 <Body xmlns="http://xml.kishou.go.jp/jmaxml1/body/meteorology1/">
  <Warning type="気象警報・注意報（一次細分区域等）"><Item><Kind><Name>レベル５大雨特別警報</Name></Kind><Area><Code>160010</Code></Area></Item></Warning>
  <Warning type="気象警報・注意報（市町村等）">
   <Item>{k}<Area><Name>富山市</Name><Code>{code}</Code></Area></Item>
   <Item><Kind><Name>レベル５大雨特別警報</Name></Kind><Area><Name>高岡市</Name><Code>{TAKAOKA_CITY}</Code></Area></Item>
  </Warning>
 </Body>
</Report>""".encode()


class FakeSource:
    def __init__(self):
        self.feed_body: bytes | None = None
        self.telegrams: dict[str, bytes] = {}
        self.fetched: list[str] = []
        self.etag_seen = None

    def fetch_feed(self, etag, last_modified):
        self.etag_seen = etag
        if self.feed_body is None:
            return None, etag, last_modified
        return self.feed_body, '"e1"', "Thu, 05 Nov 2026 02:22:00 GMT"

    def fetch_telegram(self, url):
        self.fetched.append(url)
        return self.telegrams[url]


class Parts:
    def __init__(self, min_level=3, areas=(TOYAMA_CITY,), legacy="alert_16201"):
        self.src, self.sender = FakeSource(), FakeSender()
        self.publisher, self.archive, self.store = FakePublisher(), FakeArchive(), MemoryStateStore()
        self.settings = Settings(min_level=min_level, areas=areas, legacy_topic=legacy)
        self.job = AlertJob(self.settings, self.src, self.store, self.sender, self.publisher, self.archive)

    def run(self, name, xml, updated, now_ms=NOW):
        url = BASE + name
        self.src.feed_body = feed(("気象警報・注意報（Ｒ０６）（大雨）", name, updated))
        self.src.telegrams[url] = xml
        return self.job.run(now_ms=now_ms)

    def sent_to(self, topic):
        return [d for t, d in self.sender.sent if t == topic]


# ---- 設定（全国版の形・範囲は設定で絞る） ----

def test_office_is_derived_from_area_code():
    assert office_for("1620100") == "160000"
    s = Settings(areas=(TOYAMA_CITY,))
    assert s.offices == ("160000",) and s.areas_of("160000") == (TOYAMA_CITY,)


def test_topics_are_area_7_digits_plus_legacy_during_migration():
    assert Settings(areas=(TOYAMA_CITY,)).topics_for(TOYAMA_CITY) == ["alert_1620100", "alert_16201"]
    assert Settings(areas=(TOYAMA_CITY,), legacy_topic="").topics_for(TOYAMA_CITY) == ["alert_1620100"]


def test_areas_setting_is_checked(monkeypatch):
    monkeypatch.setenv("ALERT_AREAS", "1620100, 162010")
    with pytest.raises(ValueError):
        Settings()
    monkeypatch.setenv("ALERT_AREAS", "9999999")
    with pytest.raises(ValueError):  # 名前の対応表に無い区域
        Settings()
    monkeypatch.setenv("ALERT_AREAS", "1620100")
    assert Settings().areas == (TOYAMA_CITY,)


# ---- 電文・フィードの読み取り ----

def test_parse_feed_only_toyama_new_format():
    f = feed(
        ("気象警報・注意報（Ｒ０６）（大雨）", "b_0_VPWW55_160000.xml", "2026-11-07T00:02:00Z"),
        ("気象警報・注意報（Ｒ０６）（暴風）", "a_0_VPWW58_160000.xml", "2026-11-07T00:01:00Z"),
        ("気象警報・注意報（Ｈ２７）", "c_0_VPWW54_160000.xml", "2026-11-07T00:01:00Z"),     # 古い体系
        ("気象警報・注意報（Ｒ０６）（大雨）", "d_0_VPWW55_410000.xml", "2026-11-07T00:01:00Z"),  # 佐賀
    )
    got = parse_feed(f, ["160000"])
    assert [e.link.rsplit("/", 1)[1] for e in got] == ["a_0_VPWW58_160000.xml", "b_0_VPWW55_160000.xml"]
    assert got[0].office == "160000" and got[0].file_id == "a_0_VPWW58_160000"


def test_parse_telegram_reads_only_target_areas():
    t = parse_telegram(telegram(["レベル２大雨注意報", "レベル４大雨危険警報"]), [TOYAMA_CITY])
    assert t.kinds(TOYAMA_CITY) == [(4, "大雨危険警報"), (2, "大雨注意報")]   # 高岡市・一次細分のレベル5は入らない
    assert TAKAOKA_CITY not in t.areas
    assert t.category == "気象警報・注意報（Ｒ０６）（大雨）" and t.status == "通常"
    both = parse_telegram(telegram(["レベル３大雨警報"]), [TOYAMA_CITY, TAKAOKA_CITY])
    assert both.kinds(TAKAOKA_CITY) == [(5, "大雨特別警報")]


def test_parse_telegram_none():
    assert parse_telegram(telegram([]), [TOYAMA_CITY]).kinds(TOYAMA_CITY) == []


# ---- 判定（前と同じ決まり） ----

def test_sends_when_level_rises_to_warning_and_not_again():
    p = Parts()
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル２大雨注意報"]), "2026-11-07T00:00:00Z")
    assert p.sender.sent == []                                   # 注意報（2）は送らない
    p.run("2_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"]), "2026-11-07T00:10:00Z")
    sent = p.sent_to("alert_1620100")
    assert len(sent) == 1
    data = sent[0]
    assert data["level"] == "4" and data["kind"] == "大雨危険警報"
    assert data["area_code"] == TOYAMA_CITY and data["area_name"] == "富山市"
    assert "警戒レベル4の大雨危険警報が発表されました" in data["text"]
    assert p.sent_to("alert_16201") == [data]                    # 移行の間は前のトピックにも同じもの
    p.run("3_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"], report="2026-11-07T09:30:00+09:00"),
          "2026-11-07T00:20:00Z")
    assert len(p.sent_to("alert_1620100")) == 1                  # 継続は送らない


def test_legacy_topic_can_be_turned_off():
    p = Parts(legacy="")
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:00:00Z")
    assert [t for t, _ in p.sender.sent] == ["alert_1620100"]


def test_lowered_then_raised_again_sends_again():
    p = Parts()
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:00:00Z")
    p.run("2_0_VPWW55_160000.xml", telegram(["レベル２大雨注意報"]), "2026-11-07T00:10:00Z")
    p.run("3_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:20:00Z")
    assert [d["level"] for d in p.sent_to("alert_1620100")] == ["3", "3"]


def test_same_entry_is_not_read_twice_and_etag_is_kept():
    p = Parts()
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:00:00Z")
    p.job.run()
    assert p.src.fetched.count(BASE + "1_0_VPWW55_160000.xml") == 1
    assert p.src.etag_seen == '"e1"'


def test_not_modified_does_nothing_but_first_run_places_empty_list():
    p = Parts()
    r = p.job.run(now_ms=NOW)
    assert not r.feed_changed and p.sender.sent == []
    # 一覧のファイルが無い＝データがない、と区別するため、警報が無くても最初に [] を置く
    assert p.publisher.files["alerts/current/1620100.json"]["alerts"] == []
    r2 = p.job.run(now_ms=NOW + 60_000)
    assert r2.published == []                                    # 変わらなければ書き直さない


def test_training_telegram_is_ignored():
    p = Parts()
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"], status="訓練"), "2026-11-07T00:00:00Z")
    assert p.sender.sent == []


# ---- 今出ている警報の一覧（alerts/current/<区域7桁>.json） ----

def test_current_list_follows_level_and_shares_alert_id_with_fcm():
    p = Parts()
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"]), "2026-11-07T00:00:00Z", now_ms=NOW)
    doc = p.publisher.files["alerts/current/1620100.json"]
    fcm = p.sent_to("alert_1620100")[0]
    assert doc["area_code"] == TOYAMA_CITY and doc["area_name"] == "富山市" and doc["updated_at_ms"] == NOW
    assert len(doc["alerts"]) == 1
    a = doc["alerts"][0]
    assert a["alert_id"] == fcm["alert_id"]                      # 端末は ① と ② を同じ ID で1回にまとめる
    assert a["level"] == "4" and a["kind"] == "大雨危険警報"
    assert a["text"].startswith("富山市には、警戒レベル4の大雨危険警報が発表されています。")

    # 継続（発表時刻だけ新しい電文）：ID も一覧も変えない
    p.run("2_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"], report="2026-11-07T10:00:00+09:00"),
          "2026-11-07T01:00:00Z", now_ms=NOW + 1)
    assert p.publisher.files["alerts/current/1620100.json"]["updated_at_ms"] == NOW

    # 注意報まで下がった：送らないが、一覧は空になる
    p.run("3_0_VPWW55_160000.xml", telegram(["レベル２大雨注意報"]), "2026-11-07T02:00:00Z", now_ms=NOW + 2)
    assert len(p.sent_to("alert_1620100")) == 1
    assert p.publisher.files["alerts/current/1620100.json"]["alerts"] == []


def test_current_list_keeps_one_per_category_highest_first():
    p = Parts()
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:00:00Z")
    url = BASE + "2_0_VPWW58_160000.xml"
    p.src.feed_body = feed(("気象警報・注意報（Ｒ０６）（暴風）", "2_0_VPWW58_160000.xml", "2026-11-07T00:10:00Z"))
    p.src.telegrams[url] = telegram(["レベル４暴風危険警報"], title="気象警報・注意報（Ｒ０６）（暴風）")
    p.job.run(now_ms=NOW)
    kinds = [a["kind"] for a in p.publisher.files["alerts/current/1620100.json"]["alerts"]]
    assert kinds == ["暴風危険警報", "大雨警報"]


def test_raw_telegram_is_archived_by_date():
    p = Parts()
    xml = telegram(["レベル３大雨警報"])
    p.run("1_0_VPWW55_160000.xml", xml, "2026-11-07T00:00:00Z")
    assert p.archive.files == {"raw/2026-11-07/1_0_VPWW55_160000.xml": xml}


def test_archive_failure_does_not_stop_alerts():
    p = Parts()

    class Broken:
        def save(self, path, xml):
            raise OSError("書けない")

    p.job.archive = Broken()
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"]), "2026-11-07T00:00:00Z")
    assert len(p.sent_to("alert_1620100")) == 1


def test_state_is_per_area():
    p = Parts()
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:00:00Z")
    st = p.store.load_area(TOYAMA_CITY)
    c = st.categories["気象警報・注意報（Ｒ０６）（大雨）"]
    assert (c.level, c.kind) == (3, "大雨警報") and st.published
    assert p.store.load_feed().processed == [BASE + "1_0_VPWW55_160000.xml"]


def test_two_areas_are_judged_and_sent_separately(monkeypatch):
    # 区域を足すときは設定と名前の対応表を増やすだけ（コードは変えない）
    monkeypatch.setitem(settings_mod.AREA_NAMES, TAKAOKA_CITY, "高岡市")
    p = Parts(areas=(TOYAMA_CITY, TAKAOKA_CITY))
    p.run("1_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:00:00Z")
    assert [d["level"] for d in p.sent_to("alert_1620100")] == ["3"]
    takaoka = p.sent_to("alert_1620200")
    assert [(d["level"], d["area_name"]) for d in takaoka] == [("5", "高岡市")]
    assert p.sent_to("alert_16201") == p.sent_to("alert_1620100")   # 前のトピックは富山市の分だけ
    assert p.publisher.files["alerts/current/1620200.json"]["alerts"][0]["kind"] == "大雨特別警報"


def test_evaluate_is_a_pure_step():
    # 段（evaluate）だけを呼んでも同じ判定になる。渡した状態は書き換えない（あとで Pub/Sub をはさめるように）
    s = Settings(areas=(TOYAMA_CITY,))
    t = Telegram("気象警報・注意報（Ｒ０６）（大雨）", "通常", "2026-11-07T09:00:00+09:00", {TOYAMA_CITY: [(4, "大雨危険警報")]})
    before = AreaState()
    updates = evaluate([t], {TOYAMA_CITY: before}, s)
    assert before.categories == {}
    assert len(updates) == 1 and updates[0].sends[0]["level"] == "4"
    assert updates[0].current[0]["alert_id"] == updates[0].sends[0]["alert_id"]


# ---- 模擬の警報 ----

def test_mock_alert_goes_through_same_logic_and_says_mock():
    p = Parts()
    xml = (MOCK_DIR / "level4_heavy_rain.xml").read_bytes()
    r = p.job.run_mock(xml, now_ms=NOW)
    assert len(r.sent) == 1
    d = r.sent[0]
    assert d["level"] == "4" and d["alert_id"].startswith("mock_") and d["area_code"] == TOYAMA_CITY
    assert d["text"].startswith("これはデモ用の模擬の警報です。")
    # 新しいトピックと前のトピックの両方へ
    assert [t for t, _ in p.sender.sent] == ["alert_1620100", "alert_16201"]
    # 一覧は本物と分けて mock_ に書く。本物の一覧・状態は汚さない
    mock_doc = p.publisher.files["alerts/current/mock_1620100.json"]
    assert mock_doc["alerts"][0]["alert_id"] == d["alert_id"]
    assert mock_doc["alerts"][0]["text"].startswith("これはデモ用の模擬の警報です。富山市には、")
    assert "alerts/current/1620100.json" not in p.publisher.files
    assert p.store.load_area(TOYAMA_CITY).categories == {}
    # 何度でも鳴らせる
    p.job.run_mock(xml, now_ms=NOW + 1)
    assert len(p.sent_to("alert_1620100")) == 2


def test_mock_alert_id_differs_each_time_so_device_does_not_drop_it():
    # 模擬電文の発表時刻は固定。送った時刻を足さないと、端末が「同じ警報の2回目」として捨ててしまう
    p = Parts()
    xml = (MOCK_DIR / "level4_heavy_rain.xml").read_bytes()
    a = p.job.run_mock(xml, now_ms=1_000).sent[0]["alert_id"]
    b = p.job.run_mock(xml, now_ms=2_000).sent[0]["alert_id"]
    assert a != b
    assert a.startswith("mock_") and a.endswith("_1000")
    assert p.job.run_mock(xml).sent[0]["alert_id"].startswith("mock_")   # 時刻を省略しても付く


def test_real_alert_id_is_stable_for_same_report():
    # 本物の警報は同じ発表なら同じ ID（端末が FCM の再送を捨てられるように）。時刻は足さない
    t = Telegram("気象警報・注意報（Ｒ０６）（大雨）", "通常", "2026-11-07T09:00:00+09:00", {})
    assert build_alert_id(t, TOYAMA_CITY, "大雨危険警報", None) == "2026-11-07T09:00:00+09:00_1620100_大雨危険警報"


def test_text_is_template_only():
    assert build_text("富山市", 3, "大雨警報", mock=False) == "富山市に、警戒レベル3の大雨警報が発表されました。今後の情報に注意してください。"
    assert build_text("富山市", 3, "大雨警報", mock=False, current=True) == \
        "富山市には、警戒レベル3の大雨警報が発表されています。今後の情報に注意してください。"


# ---- HTTP ----

def test_http_endpoints():
    p = Parts()
    c = TestClient(create_app(p.job))
    assert c.get("/health").json() == {"status": "ok"}
    assert c.post("/run").json() == {"feed_changed": False, "telegrams": 0, "sent": 0, "published": 1}
    r = c.post("/mock-alert").json()
    assert r["sent"][0]["level"] == "4" and r["sent"][0]["area_code"] == TOYAMA_CITY
    assert r["published"] == ["alerts/current/mock_1620100.json"]
    assert c.post("/mock-alert?name=../../etc").status_code == 404
    assert c.post("/mock-alert?name=nothing").status_code == 404

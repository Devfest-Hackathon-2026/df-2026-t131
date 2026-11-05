"""警報ジョブの判定を、偽のフィード・電文で確かめる（通信なし・送信なし）。"""
from fastapi.testclient import TestClient

from app.jma import parse_feed, parse_telegram
from app.job import AlertJob, build_text
from app.main import create_app
from app.sender import FakeSender
from app.settings import MOCK_DIR, Settings
from app.state import MemoryStateStore

TOYAMA_CITY = "1620100"
BASE = "https://www.data.jma.go.jp/developer/xml/data/"


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
   <Item><Kind><Name>レベル５大雨特別警報</Name></Kind><Area><Name>高岡市</Name><Code>1620200</Code></Area></Item>
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


def make_job(min_level=3):
    src, sender = FakeSource(), FakeSender()
    job = AlertJob(Settings(min_level=min_level), src, MemoryStateStore(), sender)
    return job, src, sender


# ---- 電文・フィードの読み取り ----

def test_parse_feed_only_toyama_new_format():
    f = feed(
        ("気象警報・注意報（Ｒ０６）（大雨）", "b_0_VPWW55_160000.xml", "2026-11-07T00:02:00Z"),
        ("気象警報・注意報（Ｒ０６）（暴風）", "a_0_VPWW58_160000.xml", "2026-11-07T00:01:00Z"),
        ("気象警報・注意報（Ｈ２７）", "c_0_VPWW54_160000.xml", "2026-11-07T00:01:00Z"),     # 古い体系
        ("気象警報・注意報（Ｒ０６）（大雨）", "d_0_VPWW55_410000.xml", "2026-11-07T00:01:00Z"),  # 佐賀
    )
    got = parse_feed(f, "160000")
    assert [e.link.rsplit("/", 1)[1] for e in got] == ["a_0_VPWW58_160000.xml", "b_0_VPWW55_160000.xml"]


def test_parse_telegram_reads_only_the_city():
    t = parse_telegram(telegram(["レベル２大雨注意報", "レベル４大雨危険警報"]), TOYAMA_CITY)
    assert t.kinds == [(4, "大雨危険警報"), (2, "大雨注意報")]   # 高岡市・一次細分のレベル5は入らない
    assert t.category == "気象警報・注意報（Ｒ０６）（大雨）" and t.status == "通常"


def test_parse_telegram_none():
    assert parse_telegram(telegram([]), TOYAMA_CITY).kinds == []


# ---- 判定 ----

def run_with(job, src, name, xml, updated):
    url = BASE + name
    src.feed_body = feed(("気象警報・注意報（Ｒ０６）（大雨）", name, updated))
    src.telegrams[url] = xml
    return job.run()


def test_sends_when_level_rises_to_warning_and_not_again():
    job, src, sender = make_job()
    run_with(job, src, "1_0_VPWW55_160000.xml", telegram(["レベル２大雨注意報"]), "2026-11-07T00:00:00Z")
    assert sender.sent == []                                   # 注意報（2）は送らない
    run_with(job, src, "2_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"]), "2026-11-07T00:10:00Z")
    assert len(sender.sent) == 1
    topic, data = sender.sent[0]
    assert topic == "alert_16201"
    assert data["level"] == "4" and data["kind"] == "大雨危険警報" and data["area_name"] == "富山市"
    assert "警戒レベル4の大雨危険警報" in data["text"]
    run_with(job, src, "3_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"]), "2026-11-07T00:20:00Z")
    assert len(sender.sent) == 1                               # 継続は送らない


def test_lowered_then_raised_again_sends_again():
    job, src, sender = make_job()
    run_with(job, src, "1_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:00:00Z")
    run_with(job, src, "2_0_VPWW55_160000.xml", telegram(["レベル２大雨注意報"]), "2026-11-07T00:10:00Z")
    run_with(job, src, "3_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:20:00Z")
    assert [d["level"] for _, d in sender.sent] == ["3", "3"]


def test_same_entry_is_not_read_twice_and_etag_is_kept():
    job, src, sender = make_job()
    run_with(job, src, "1_0_VPWW55_160000.xml", telegram(["レベル３大雨警報"]), "2026-11-07T00:00:00Z")
    job.run()
    assert src.fetched.count(BASE + "1_0_VPWW55_160000.xml") == 1
    assert src.etag_seen == '"e1"'


def test_not_modified_does_nothing():
    job, src, sender = make_job()
    r = job.run()
    assert not r.feed_changed and sender.sent == []


def test_training_telegram_is_ignored():
    job, src, sender = make_job()
    run_with(job, src, "1_0_VPWW55_160000.xml", telegram(["レベル４大雨危険警報"], status="訓練"), "2026-11-07T00:00:00Z")
    assert sender.sent == []


def test_mock_alert_goes_through_same_logic_and_says_mock():
    job, src, sender = make_job()
    r = job.run_mock((MOCK_DIR / "level4_heavy_rain.xml").read_bytes())
    assert len(r.sent) == 1
    d = r.sent[0]
    assert d["level"] == "4" and d["alert_id"].startswith("mock_")
    assert d["text"].startswith("これはデモ用の模擬の警報です。")
    # 何度でも鳴らせる、本物の状態には影響しない
    job.run_mock((MOCK_DIR / "level4_heavy_rain.xml").read_bytes())
    assert len(sender.sent) == 2
    assert job.store.load().levels == {}


def test_mock_alert_id_differs_each_time_so_device_does_not_drop_it():
    # 模擬電文の発表時刻は固定。送った時刻を足さないと、端末が「同じ警報の2回目」として捨ててしまう
    job, src, sender = make_job()
    xml = (MOCK_DIR / "level4_heavy_rain.xml").read_bytes()
    a = job.run_mock(xml, now_ms=1_000).sent[0]["alert_id"]
    b = job.run_mock(xml, now_ms=2_000).sent[0]["alert_id"]
    assert a != b
    assert a.startswith("mock_") and a.endswith("_1000")
    # 送った時刻を省略しても、毎回 ID が付く
    assert job.run_mock(xml).sent[0]["alert_id"].startswith("mock_")


def test_real_alert_id_is_stable_for_same_report():
    # 本物の警報は同じ発表なら同じ ID（端末が FCM の再送を捨てられるように）。時刻は足さない
    from app.job import build_alert_id
    from app.jma import Telegram
    from app.settings import Settings

    t = Telegram("気象警報・注意報（Ｒ０６）（大雨）", "通常", "2026-11-07T09:00:00+09:00", [(4, "大雨危険警報")])
    assert build_alert_id(t, "大雨危険警報", Settings(), None) == "2026-11-07T09:00:00+09:00_1620100_大雨危険警報"


def test_text_is_template_only():
    assert build_text("富山市", 3, "大雨警報", mock=False) == "富山市に、警戒レベル3の大雨警報が発表されました。今後の情報に注意してください。"


# ---- HTTP ----

def test_http_endpoints():
    job, src, sender = make_job()
    c = TestClient(create_app(job))
    assert c.get("/health").json() == {"status": "ok"}
    assert c.post("/run").json() == {"feed_changed": False, "telegrams": 0, "sent": 0}
    r = c.post("/mock-alert")
    assert r.status_code == 200 and r.json()["sent"][0]["level"] == "4"
    assert c.post("/mock-alert?name=../../etc").status_code == 404
    assert c.post("/mock-alert?name=nothing").status_code == 404

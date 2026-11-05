"""draft_scripts.py：manual/ を書き換えず、drafts/ にだけ下書きを出すか。課金なし（Gemini は偽物）。"""
import hashlib
import importlib.util
import json
import shutil
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("draft_scripts", ROOT / "cloud" / "data" / "scripts" / "draft_scripts.py")
ds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ds)

SAMPLE = ROOT / "schema" / "examples" / "landmarks_sample.json"
META = {"model": "test", "grounding": "off", "at": "2026-11-05T12:00:00+09:00"}


class ScriptedGenerator:
    """決まった応答を返す偽の Gemini。受け取ったプロンプトを記録する。"""

    def __init__(self, text: str, sources=None):
        self.text, self.sources, self.prompts = text, sources or [], []

    def generate(self, prompt):
        self.prompts.append(prompt)
        return self.text, self.sources


def good_response(**kw) -> str:
    body = {
        "script_short": "見本の原稿です。",
        "script_long": "見本の原稿です。もう少し長い版です。",
        "facts": [{"claim": "見本", "source_url": "https://example.com/sample"}],
        "uncertain": [],
    } | kw
    return "```json\n" + json.dumps(body, ensure_ascii=False) + "\n```"


@pytest.fixture
def files(tmp_path):
    lm = tmp_path / "landmarks.json"
    shutil.copy(SAMPLE, lm)
    return lm, tmp_path / "drafts"


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def test_drafts_only_draft_landmarks_and_never_touches_manual(files):
    lm, drafts = files
    before = sha(lm)
    gen = ScriptedGenerator(good_response(), [{"title": "t", "uri": "https://example.com/g"}])
    assert ds.run(lm, drafts, gen, META, only=[], force=False, limit=30) == 0
    assert sha(lm) == before                                       # manual は書き換えない
    assert sorted(p.name for p in drafts.iterdir()) == ["lm_0003.json"]  # draft の lm_0003 だけ
    d = json.loads((drafts / "lm_0003.json").read_text(encoding="utf-8"))
    assert d["landmark_id"] == "lm_0003" and d["script_short"] == "見本の原稿です。"
    assert d["generated_by"] == META
    # Google 検索のグラウンディングの結果は保存しない（Service Terms 20(k)）
    assert "grounding_sources" not in d


class DictReader:
    """出典のページの本文を決まった文字列で返す偽物。"""

    def __init__(self, pages: dict[str, str]):
        self.pages, self.read_urls = pages, []

    def read(self, url):
        self.read_urls.append(url)
        if url not in self.pages:
            raise OSError("読めない")
        return self.pages[url]


def test_prompt_has_sources_and_rules(files):
    lm, drafts = files
    gen = ScriptedGenerator(good_response())
    ds.run(lm, drafts, gen, META, only=[], force=False, limit=30)
    p = gen.prompts[0]
    assert "https://example.com/sample" in p
    assert "年号・数字は出典にあるものだけ" in p
    assert "方向の言葉は入れない" in p
    assert "出典の本文」に書いてある事実だけ" in p
    assert "読めた本文がありません" in p                          # 本文が無いときは事実を書かせない


def test_source_page_text_goes_into_prompt_and_osm_is_skipped(tmp_path):
    d = tmp_path / "landmarks"
    d.mkdir()
    item = json.loads((ROOT / "schema" / "templates" / "landmark_point.json").read_text(encoding="utf-8"))
    item["sources"] = [
        {"title": "公式", "url": "https://example.com/official", "license": "x"},
        {"title": "OSM", "url": "https://www.openstreetmap.org/node/1", "license": "ODbL 1.0"},
        {"title": "読めない", "url": "https://example.com/broken", "license": "x"},
    ]
    (d / f"{item['id']}.json").write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
    reader = DictReader({"https://example.com/official": "この建物は見本の年に建てられた。"})
    gen = ScriptedGenerator(good_response())
    assert ds.run(d, tmp_path / "drafts", gen, META, [], False, 30, reader) == 0
    assert "この建物は見本の年に建てられた。" in gen.prompts[0]
    assert "https://www.openstreetmap.org/node/1" not in reader.read_urls   # 位置だけの出典は読みに行かない
    out = json.loads((tmp_path / "drafts" / f"{item['id']}.json").read_text(encoding="utf-8"))
    assert out["source_pages"] == [{"url": "https://example.com/official", "chars": 16},
                                   {"url": "https://example.com/broken", "chars": 0}]


def test_html_and_youtube_text_extraction():
    raw = "<html><head><style>x{}</style><script>var a=1;</script></head><body><nav>メニュー</nav><p>本文 です</p></body></html>"
    assert ds.html_to_text(raw) == "本文 です"
    yt = 'xx "shortDescription":"2020年3月、\\n大理石の像" yy'
    assert ds.youtube_description(yt) == "2020年3月、\n大理石の像"


def test_vertex_generator_has_no_search_grounding():
    src = (ROOT / "cloud" / "data" / "scripts" / "draft_scripts.py").read_text(encoding="utf-8")
    assert "GoogleSearch(" not in src and "google_search=" not in src


def test_existing_draft_is_skipped_unless_force(files):
    lm, drafts = files
    ds.run(lm, drafts, ScriptedGenerator(good_response()), META, [], False, 30)
    gen = ScriptedGenerator(good_response(script_short="作り直し"))
    ds.run(lm, drafts, gen, META, [], False, 30)
    assert gen.prompts == []                                       # 呼んでいない（お金を使わない）
    ds.run(lm, drafts, gen, META, [], True, 30)
    assert json.loads((drafts / "lm_0003.json").read_text(encoding="utf-8"))["script_short"] == "作り直し"


def test_area_prompt_says_whole_area(files):
    lm, drafts = files
    data = json.loads(lm.read_text(encoding="utf-8"))
    for x in data["landmarks"]:
        if x["id"] == "lm_0004":
            x["status"] = "draft"
    lm.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    gen = ScriptedGenerator(good_response())
    ds.run(lm, drafts, gen, META, only=["lm_0004"], force=False, limit=30)
    assert "エリア全体の説明" in gen.prompts[0]


def test_invalid_landmarks_stops_without_calling(files):
    lm, drafts = files
    data = json.loads(lm.read_text(encoding="utf-8"))
    data["landmarks"][0]["name_kana"] = "カタカナ"
    lm.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    gen = ScriptedGenerator(good_response())
    assert ds.run(lm, drafts, gen, META, [], False, 30) == 1
    assert gen.prompts == [] and not drafts.exists()


def test_limit_stops_before_calling(files):
    lm, drafts = files
    gen = ScriptedGenerator(good_response())
    assert ds.run(lm, drafts, gen, META, [], False, 0) == 1
    assert gen.prompts == []


def test_broken_response_is_failure_not_guess(files):
    lm, drafts = files
    assert ds.run(lm, drafts, ScriptedGenerator("ごめんなさい、分かりません"), META, [], False, 30) == 1
    assert not (drafts / "lm_0003.json").exists()


def test_warnings_and_numbers():
    short = "右手に見えるのは、明治43年に建てられた" + "あ" * 50
    long = "高さは12メートル、昭和初期に移された。" + "い" * 200
    w = ds.warnings_for(short, long, facts=[])
    assert any("script_short が目安" in x for x in w)
    assert any("schema の上限も超えています" in x for x in w)
    assert any("方向の言葉" in x for x in w)
    assert any("facts" in x for x in w)
    nums = ds.numbers_to_check(short, long)
    assert any(n.startswith("明治43") for n in nums)
    assert any(n.startswith("12") for n in nums)
    assert any(n.startswith("昭和") for n in nums)


def test_fake_generator_end_to_end(files):
    lm, drafts = files
    assert ds.run(lm, drafts, ds.FakeGenerator(), META, [], False, 30) == 0
    d = json.loads((drafts / "lm_0003.json").read_text(encoding="utf-8"))
    assert "仮の原稿" in d["script_short"]


def test_reads_one_file_per_landmark(tmp_path):
    d = tmp_path / "landmarks"
    d.mkdir()
    for src in ("landmark_point.json", "landmark_area.json"):
        item = json.loads((ROOT / "schema" / "templates" / src).read_text(encoding="utf-8"))
        (d / f"{item['id']}.json").write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
    drafts = tmp_path / "drafts"
    gen = ScriptedGenerator(good_response())
    assert ds.run(d, drafts, gen, META, [], False, 30) == 0
    assert sorted(p.name for p in drafts.iterdir()) == ["lm_0001.json", "lm_0004.json"]  # どちらも draft

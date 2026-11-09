"""A の原稿の下書きを Gemini（Vertex AI）で作り、cloud/data/drafts/ に出す。

使い方（リポジトリの一番上で）:
    python cloud/data/scripts/draft_scripts.py --fake            # お試し（課金なし。決まった仮の文が出る）
    python cloud/data/scripts/draft_scripts.py                   # 本番（Vertex AI を呼ぶ。課金あり）
    python cloud/data/scripts/draft_scripts.py --only lm_0003    # 1件だけ
    python cloud/data/scripts/draft_scripts.py --force           # 下書きがあっても作り直す

本番の前に1回だけ:
    gcloud auth application-default login
    （プロジェクトは環境変数 GOOGLE_CLOUD_PROJECT か --project で指定）

決まり（docs/design.md 3章2・7）:
  - 読むのは cloud/data/manual/landmarks/<ID>.json（1件1ファイル）。書くのは cloud/data/drafts/<ID>.json だけ
    （manual/ と reviewed の原稿は絶対に書き換えない）
  - 下書きを作るのは status が draft のランドマークだけ
  - 既に下書きがあるものは作らない（お金を無駄にしない）。作り直すときは --force
  - 使ったモデル名・日時・根拠にした URL を下書きに残す
  - 下書きは人が出典で確かめてから landmarks/<ID>.json に写し、status を reviewed にする

Google 検索のグラウンディングは使わない（11/6 に変更）:
  Google Cloud の Service Terms 20(k)「Grounding with Google Search」では、グラウンディングの結果を
  保存・書き換え・データベース作りに使うことが原則として禁止されている。原稿は保存して使い続けるものなので合わない。
  代わりに、このスクリプトが出典（公式のページ）の本文を自分で取ってきてプロンプトに入れ、
  「この本文に書いてある事実だけで書く」よう頼む（ふつうの Gemini の呼び出し）。
"""
import argparse
import html
import json
import os
import re
import ssl
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from html.parser import HTMLParser
from typing import Protocol

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[3]
SCHEMA = ROOT / "schema"
LANDMARKS = ROOT / "cloud" / "data" / "manual" / "landmarks"
DRAFTS = ROOT / "cloud" / "data" / "drafts"
JST = timezone(timedelta(hours=9))

# 11/5 に実際の写真で比べて決めたモデルと地域（docs/design.md 15章）
DEFAULT_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.6-flash")
DEFAULT_LOCATION = os.environ.get("VERTEX_LOCATION", "global")

SHORT_TARGET, SHORT_MAX = 60, 80     # 目安と schema の上限
LONG_TARGET, LONG_MAX = 150, 200
DEFAULT_LIMIT = 30                   # 1回で作る上限（課金の事故を防ぐ）

KIND_JA = {
    "area": "エリア（公園・境内など範囲のある場所）", "monument": "石碑・記念碑", "building": "建物",
    "street": "通り", "place_name": "地名", "shrine_temple": "神社・寺", "nature": "自然", "other": "その他",
}

PROMPT = """あなたは、富山市を歩く人の耳元で流れる音声ガイドの原稿の下書きを書きます。
下書きは人が出典で確かめてから使います。確かでないことは書かないでください。

# 対象
- 名前：{name}（読み：{name_kana}）
- 種類：{kind}
- おおよその位置：北緯{lat:.4f}、東経{lon:.4f}（富山市）
- 出典：
{sources}

# 出典の本文（このスクリプトが公式のページから取ってきたもの）
{pages}

# 書き方
- 上の「出典の本文」に書いてある事実だけを使う。本文に無いこと・確かめられないことは書かず、uncertain に入れる
- 本文の文章をそのまま写さず、自分の言葉で書く
- 年号・数字は出典にあるものだけ。迷ったら数字を使わずに書く
- 話し言葉で、歩きながら一度聞いて分かる文にする。漢字の読みが難しい語は避ける
- 「右手に」「正面に」など方向の言葉は入れない（アプリが付ける）
- script_short：{short}字以内、1〜2文。その場所の一番の見どころか由来
- script_long：{long}字以内。short の内容に、背景や豆知識を足す
{area_rule}
# 出力
次の JSON だけを出力する（前後に説明を付けない）。
{{"script_short": "...", "script_long": "...",
  "facts": [{{"claim": "原稿に使った事実1つ", "source_url": "その根拠の URL"}}],
  "uncertain": ["確かめられなかったので書かなかったこと"]}}
"""

# 本文を取りに行かない出典（地図の位置だけの出典）
SKIP_SOURCE_HOSTS = ("openstreetmap.org",)
PAGE_MAX_CHARS = 6000      # 1ページあたり
PAGES_MAX_CHARS = 15000    # 1件あたりの合計


class _TextExtractor(HTMLParser):
    """HTML から本文の文字だけを取り出す（script・style・nav などは捨てる）。"""

    SKIP = {"script", "style", "noscript", "nav", "header", "footer", "svg"}

    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self._skip += 1

    def handle_endtag(self, tag):
        if tag in self.SKIP and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if not self._skip and data.strip():
            self.parts.append(data.strip())


def html_to_text(raw: str) -> str:
    p = _TextExtractor()
    p.feed(raw)
    return re.sub(r"\s+", " ", " ".join(p.parts)).strip()


def youtube_description(raw: str) -> str:
    """YouTube のページから動画の説明文だけを取り出す（本文はスクリプトの中の JSON にある）。"""
    m = re.search(r'"shortDescription":"((?:[^"\\]|\\.)*)"', raw)
    return json.loads('"' + m.group(1) + '"') if m else ""


class SourceReader(Protocol):
    def read(self, url: str) -> str:
        """出典のページの本文。読めなければ例外。"""


class WebSourceReader:
    """公式のページを HTTP で取ってくる。SSL_CERT_FILE があれば証明書の束に使う（cloud/data/README.md）。"""

    def __init__(self, timeout: float = 30) -> None:
        ca = os.environ.get("SSL_CERT_FILE")
        self._ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
        self._timeout = timeout

    def read(self, url: str) -> str:
        req = urllib.request.Request(url, headers={"User-Agent": "machi-talk/0.1", "Accept-Language": "ja"})
        with urllib.request.urlopen(req, context=self._ctx, timeout=self._timeout) as r:
            raw = r.read().decode(r.headers.get_content_charset() or "utf-8", "replace")
        if "youtube.com/" in url:
            return youtube_description(raw)
        return html_to_text(raw)


class NoSourceReader:
    """本文を取りに行かない（--fake・テスト用）。"""

    def read(self, url: str) -> str:
        raise RuntimeError("本文を取りに行かない設定")


def read_sources(lm: dict, reader: SourceReader) -> list[dict]:
    """出典のページの本文を集める。[{url, title, text}]。読めないページは text を空にする（止めない）。"""
    out, total = [], 0
    for s in lm.get("sources", []):
        url = s.get("url", "")
        if not url.startswith("http") or any(h in url for h in SKIP_SOURCE_HOSTS):
            continue
        try:
            text = reader.read(url)[:PAGE_MAX_CHARS]
        except Exception as e:  # 1ページ読めなくても、ほかのページで書ける
            print(f"    注意 {lm['id']}：出典を読めない {url}（{type(e).__name__}）")
            text = ""
        text = text[: max(0, PAGES_MAX_CHARS - total)]
        total += len(text)
        out.append({"url": url, "title": s.get("title", ""), "text": text})
    return out


AREA_RULE = "- これはエリア。中に入ったときに一度だけ流れる。エリア全体の説明にし、中の個々の橋や建物の説明は書かない（別の機能が案内する）\n"


class Generator(Protocol):
    def generate(self, prompt: str) -> tuple[str, list[dict]]:
        """(応答の文字列, 根拠にした出典 [{title, uri}]) を返す。"""


class FakeGenerator:
    """課金なしで流れを確かめる用。決まった仮の文を返す。"""

    def generate(self, prompt: str) -> tuple[str, list[dict]]:
        name = re.search(r"名前：(.+?)（", prompt).group(1)
        return json.dumps({
            "script_short": f"{name}の仮の原稿です。",
            "script_long": f"{name}の仮の原稿です。--fake で作ったので、本番では Gemini が書きます。",
            "facts": [], "uncertain": ["--fake のため事実は調べていない"],
        }, ensure_ascii=False), []


class VertexGenerator:
    def __init__(self, project: str, location: str, model: str):
        from google import genai  # 本番のときだけ読み込む
        from google.genai import types

        self._types = types
        # ウイルス対策ソフトが HTTPS を検査している PC では、SSL_CERT_FILE に証明書の束を指定する（cloud/data/README.md）
        ca = os.environ.get("SSL_CERT_FILE")
        opts = types.HttpOptions(timeout=120_000, client_args={"verify": ca} if ca else None)
        self._client = genai.Client(vertexai=True, project=project, location=location, http_options=opts)
        self._model = model
        # Google 検索のグラウンディングは使わない（上の説明。tools を付けない）
        self._config = types.GenerateContentConfig(temperature=0.2)

    def generate(self, prompt: str) -> tuple[str, list[dict]]:
        res = self._client.models.generate_content(model=self._model, contents=prompt, config=self._config)
        return res.text or "", []


def parse_json(text: str) -> dict:
    """応答から JSON を取り出す（```json で囲まれていても読む）。読めなければ ValueError。"""
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        raise ValueError("JSON が見つからない")
    data = json.loads(m.group(0))
    for k in ("script_short", "script_long"):
        if not isinstance(data.get(k), str) or not data[k].strip():
            raise ValueError(f"{k} が無い")
    return data


NUMBER_RE = re.compile(
    r"[0-9０-９]+(?:[.,．][0-9０-９]+)?[^\s、。「」]{0,3}"
    r"|(?:明治|大正|昭和|平成|令和|江戸|安土|室町|鎌倉|慶長|元和|寛永|元禄|享保|天保|安政|文久|慶応)[^\s、。]{0,4}"
    r"|[一二三四五六七八九十百千万]+(?:年|月|日|メートル|キロ|階|代|世紀|周年|番目)"
)


def numbers_to_check(*texts: str) -> list[str]:
    """出典と一字一句照らし合わせるべき数字・年号の一覧。"""
    seen: list[str] = []
    for t in texts:
        for m in NUMBER_RE.findall(t):
            if m not in seen:
                seen.append(m)
    return seen


def warnings_for(short: str, long: str, facts: list) -> list[str]:
    w = []
    if len(short) > SHORT_TARGET:
        w.append(f"script_short が目安の{SHORT_TARGET}字を超えています（{len(short)}字）" + ("。schema の上限も超えています" if len(short) > SHORT_MAX else ""))
    if len(long) > LONG_TARGET:
        w.append(f"script_long が目安の{LONG_TARGET}字を超えています（{len(long)}字）" + ("。schema の上限も超えています" if len(long) > LONG_MAX else ""))
    if re.search(r"右手|左手|正面|手前|向こう", short + long):
        w.append("方向の言葉が入っています（アプリが付けるので消す）")
    if not facts:
        w.append("根拠の一覧（facts）が空です。原稿の中身をすべて出典で確かめてください")
    return w


def build_prompt(lm: dict, pages: list[dict] | None = None) -> str:
    sources = "\n".join(f"  - {s['title']}：{s['url']}" for s in lm.get("sources", [])) or "  - （なし）"
    body = "\n\n".join(f"## {p['title']}（{p['url']}）\n{p['text']}" for p in (pages or []) if p["text"])
    return PROMPT.format(
        name=lm["name"], name_kana=lm["name_kana"], kind=KIND_JA.get(lm["kind"], lm["kind"]),
        lat=lm["lat"], lon=lm["lon"], sources=sources,
        pages=body or "（読めた本文がありません。事実は書かず、すべて uncertain に入れてください）",
        short=SHORT_TARGET, long=LONG_TARGET,
        area_rule=AREA_RULE if lm["kind"] == "area" else "",
    )


def make_draft(lm: dict, gen: Generator, meta: dict, schema_version: str, reader: SourceReader) -> dict:
    pages = read_sources(lm, reader)
    text, _ = gen.generate(build_prompt(lm, pages))
    data = parse_json(text)
    short, long = data["script_short"].strip(), data["script_long"].strip()
    facts = data.get("facts") if isinstance(data.get("facts"), list) else []
    return {
        "schema_version": schema_version,
        "landmark_id": lm["id"],
        "name": lm["name"],
        "kind": lm["kind"],
        "review": "下書きです。facts と numbers_to_check を出典で確かめ、直してから landmarks/<ID>.json に写し、status を reviewed にしてください",
        "script_short": short,
        "script_long": long,
        "warnings": warnings_for(short, long, facts),
        "numbers_to_check": numbers_to_check(short, long),
        "facts": facts,
        "uncertain": data.get("uncertain") if isinstance(data.get("uncertain"), list) else [],
        # 本文を読んだ出典（読めなかったものは chars が 0）。グラウンディングの結果は保存しない
        "source_pages": [{"url": p["url"], "chars": len(p["text"])} for p in pages],
        "generated_by": meta,
    }


def load_landmarks(path: Path) -> tuple[dict | None, list[str]]:
    reg = Registry()
    for p in SCHEMA.rglob("*.schema.json"):
        sch = json.loads(p.read_text(encoding="utf-8"))
        reg = reg.with_resource(sch["$id"], Resource.from_contents(sch))
    def validator(name: str) -> Draft202012Validator:
        return Draft202012Validator(json.loads((SCHEMA / name).read_text(encoding="utf-8")), registry=reg)

    if path.is_dir():  # 1件1ファイル（cloud/data/manual/landmarks/<ID>.json）
        v = validator("landmark_entry.schema.json")
        items, errs = [], []
        for p in sorted(path.glob("*.json")):
            try:
                item = json.loads(p.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                errs.append(f"{p.name}: JSON として読めない")
                continue
            errs += [f"{p.name}: {'/'.join(map(str, e.path))}: {e.message}" for e in v.iter_errors(item)]
            items.append(item)
        data = {"schema_version": items[0].get("schema_version", "0.3") if items else "0.3", "landmarks": items}
        return (None, errs) if errs else (data, [])
    v = validator("landmarks_file.schema.json")
    data = json.loads(path.read_text(encoding="utf-8"))
    errs = [f"{'/'.join(map(str, e.path))}: {e.message}" for e in v.iter_errors(data)]
    return (None, errs) if errs else (data, [])


def run(landmarks: Path, drafts: Path, gen: Generator, meta: dict, only: list[str], force: bool, limit: int,
        reader: SourceReader | None = None) -> int:
    reader = reader or NoSourceReader()
    if not landmarks.exists():
        print(f"{landmarks} がありません。先にランドマークを draft で登録してください")
        return 1
    data, errs = load_landmarks(landmarks)
    if errs:
        print(f"{landmarks.name} が schema に合いません（先に python schema/validate.py で直してください）:")
        for e in errs[:10]:
            print(f"  NG {e}")
        return 1

    targets = [lm for lm in data["landmarks"] if lm["status"] == "draft" and (not only or lm["id"] in only)]
    missing = sorted(set(only) - {lm["id"] for lm in data["landmarks"]})
    if missing:
        print(f"  注意：登録されていない ID {missing}")
    todo, skipped = [], []
    for lm in targets:
        (skipped if (drafts / f"{lm['id']}.json").exists() and not force else todo).append(lm)
    if skipped:
        print(f"  下書きが既にあるので作らない：{[lm['id'] for lm in skipped]}（作り直すなら --force）")
    if len(todo) > limit:
        print(f"{len(todo)} 件は1回の上限 {limit} 件を超えています。--only で絞るか --limit を上げてください")
        return 1
    if not todo:
        print("作る下書きはありません（draft のランドマークが無いか、すべて下書き済み）")
        return 0

    drafts.mkdir(parents=True, exist_ok=True)
    failed = 0
    for lm in todo:
        try:
            draft = make_draft(lm, gen, meta, data["schema_version"], reader)
        except Exception as e:  # 1件の失敗で全体を止めない
            print(f"  NG {lm['id']} {lm['name']}：{type(e).__name__}: {e}")
            failed += 1
            continue
        (drafts / f"{lm['id']}.json").write_text(json.dumps(draft, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        note = f"（注意 {len(draft['warnings'])} 件）" if draft["warnings"] else ""
        print(f"  OK {lm['id']} {lm['name']} → drafts/{lm['id']}.json{note}")
    print(f"できた下書き {len(todo) - failed} 件、失敗 {failed} 件")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="A の原稿の下書きを Gemini で作る")
    ap.add_argument("--fake", action="store_true", help="Gemini を呼ばずに仮の文を出す（課金なし）")
    ap.add_argument("--only", nargs="*", default=[], help="この ID だけ作る（例：--only lm_0003 lm_0004）")
    ap.add_argument("--force", action="store_true", help="下書きが既にあっても作り直す")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help=f"1回で作る上限（既定 {DEFAULT_LIMIT}）")
    ap.add_argument("--project", default=os.environ.get("GOOGLE_CLOUD_PROJECT"), help="GCP のプロジェクト ID")
    ap.add_argument("--location", default=DEFAULT_LOCATION)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--landmarks", type=Path, default=LANDMARKS, help=argparse.SUPPRESS)
    ap.add_argument("--drafts", type=Path, default=DRAFTS, help=argparse.SUPPRESS)
    a = ap.parse_args()

    if a.fake:
        gen: Generator = FakeGenerator()
        reader: SourceReader = NoSourceReader()
        meta = {"model": "fake", "grounding": "off"}
    else:
        if not a.project:
            print("プロジェクトが分かりません。GOOGLE_CLOUD_PROJECT を設定するか --project を付けてください")
            return 1
        gen = VertexGenerator(a.project, a.location, a.model)
        reader = WebSourceReader()
        meta = {"model": a.model, "location": a.location, "grounding": "off", "sources": "出典の本文を渡した"}
    meta["at"] = datetime.now(JST).isoformat(timespec="seconds")
    return run(a.landmarks, a.drafts, gen, meta, a.only, a.force, a.limit, reader)


if __name__ == "__main__":
    sys.exit(main())

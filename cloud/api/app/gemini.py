"""B：視界の検索の本物（Vertex AI の Gemini）。CLAUDE.md 6章。

1回の呼び出しで「候補のどれか（matched）／候補外の名前と説明（unlisted）／わからない（unknown）」と
自信の度合いを返させ、ここで後処理してから schema の形で返す。

部分（part）：中央に写っているのが対象の全体（whole）か、窓・入口などの特定の部分か（CLAUDE.md 6章「B の仕様」）。
  matched・whole は説明を返さない（11/6 夜：B では全体の紹介をしない＝engine が A に任せて見送る）。
  matched・whole 以外は「登録したランドマークの特徴」で、見えていることだけの説明を返す（engine は全体の紹介とは別の話として扱う）。
  ありふれたもの（電柱・自動販売機など）や、見た目をなぞるだけの説明しか言えないものは unknown にさせる（11/6 夜、メンバー2の提案）。
  11/7 夜：「ありふれているか」を聞くと、例に無いもの（クッションドラム・シェアサイクル・フットライト）をすり抜けた（実機）。
  そこで逆に「観光の案内として話す価値があるか」（worth_telling）を必ず答えさせ、false なら unknown にする。
  一般名（named=false）がありふれたものの名前でも unknown（COMMONPLACE_RE）。
  名前（11/7 夜）：固有名は看板の文字で読めるか・形で確かに見分けられるときだけ。近くの場所の名前と一般名を
  組み合わせた名前を作らない。登録した場所の名前・別名（aliases）と同じ名前で unlisted が返ったら、
  候補なら matched に直し、候補でなければ unknown にする（古い名前で話さない。全体の紹介は A が行う）。

後処理（AI の答えをそのまま信じない）:
  - JSON が壊れている・候補に無い ID を返した・名前が無い → unknown（推測で補わない）
  - 説明から、数字・年号を含む文を落とす（AI が作った数字は読み上げない。CLAUDE.md 3章7）
  - 説明は目安100字で切る
  - part が一覧に無い → other。matched で part が whole 以外なのに説明が残らない → matched・whole に戻す（安全側）
  - 自信が VISUAL_MIN_CONFIDENCE 未満 → unknown（話すかどうかの本当のしきい値は engine の定数）
  - 画像は検索が終わったら手放す（保存しない・ログに出さない）
"""
import base64
import binascii
import json
import logging
import re

from .errors import ApiError
from .settings import SCHEMA_VERSION, Settings
from .sources import TileSource
from .tiles import tile_bounds

log = logging.getLogger("api")

RESULTS = ("matched", "unlisted", "unknown")
# 部分の一覧（schema/api/visual_search.response.schema.json の part と同じ）。日本語はプロンプト用
PARTS = {
    "whole": "全体", "window": "窓", "entrance": "入口・門", "roof": "屋根", "wall": "壁・外壁", "pillar": "柱",
    "sign": "看板・文字", "statue": "像・彫刻", "railing": "欄干・手すり", "planting": "植え込み・木",
    "waterside": "水辺・川・運河", "other": "その他",
}

# 数字・年号を含む文を見つける（全角・漢数字＋単位・元号）
NUMBER_RE = re.compile(
    r"[0-9０-９]"
    r"|(?:明治|大正|昭和|平成|令和|江戸時代|慶長|元和|寛永|元禄|享保|天保|安政|文久|慶応)"
    r"|[一二三四五六七八九十百千万]+(?:年|月|日|メートル|キロ|階|代|世紀|周年|番目|基|本|人|棟)"
)
# 一般名で返ってきたら話さない、どこにでもあるもの（固有名＝named のときは止めない）
COMMONPLACE_RE = re.compile(
    r"自動販売機|自販機|電柱|電線|信号|ガードレール|駐車場|駐輪場|コンビニ|住宅|民家|マンション|アパート"
    r"|街路樹|植え込み|道路|歩道|車道|横断歩道|標識|カーブミラー|マンホール|ゴミ箱|ごみ箱|フェンス|自動車|自転車|バス停"
    # 11/7 夜に実機で話してしまったもの・その仲間
    r"|クッションドラム|ラバーポール|ポストコーン|カラーコーン|三角コーン|車止め|シェアサイクル|レンタサイクル|サイクルポート"
    r"|フットライト|足元灯|照明|街灯|ベンチ|点字ブロック|石畳|舗装|のぼり|幟|旗|広告|プランター|植木鉢|側溝|排水溝"
    r"|消火栓|室外機|自動ドア|ポスト|公衆電話|案内板"
)
SENTENCE_RE = re.compile(r"[^。！？!?]+[。！？!?]?")

PROMPT = """あなたは、富山市を歩く人のための音声ガイドです。利用者はカメラ付きのメガネをかけて歩いています。
写真は、利用者がいま見ている景色です。**写真の中央にある、歩いている人がふだん見過ごしてしまう「聞くと少し面白いもの」**
（凝った飾り・珍しい形・素材の特徴など）を1つ見つけて答えてください。建物などの全体の紹介は別の機能が行うので、全体ではなく部分を探します。

# 手がかり
- おおよその場所：{place}（地図タイル {tile}、中心は北緯{lat:.3f}・東経{lon:.3f}付近）
- 見ている方向：真北から時計回りに {gaze} 度
{context}{area}- 近くにある、登録済みの場所（中央のものがどの場所のものかを書くための手がかり。当てることが目的ではない）：
{candidates}

# 答え方
- 目的は、ふだん見過ごしてしまうものに気づくきっかけを短く伝えること
- worth_telling に、中央にあるものが観光の案内として話す価値があるかを true/false で必ず入れる。true にしてよいのは次のどれかのときだけ：
  (1) 観光案内・公式サイト・説明板で紹介されるような場所や作品（名所・文化財・パブリックアート・記念碑など）
  (2) 固有の名前・作者・由来があるもの
  (3) その場所ならではのデザイン（特徴的な建築の部分・凝った装飾・珍しい形）
  街の設備や日用品（交通安全の設備・シェアサイクル・照明・ベンチ・点字ブロック・舗装・のぼり旗や広告・店の看板・車・人など）や、
  どこにでもあるもの（電柱・信号・自動販売機・住宅・駐車場・チェーン店・コンビニ・街路樹・ガードレール・道路など）は false。
  迷ったら false。false なら result="unknown" にする
- part に、中央に写っているのがどの部分かを、次の一覧から1つ選んで入れる（unknown のときは null）
  {parts}
  対象のそのもの全体（建物の外観全体・像全体・橋全体など）なら "whole"、特定の部分が中心なら、その部分を選ぶ。
  全体が写っていても、目を引く部分（入口の飾り・窓の形・像など）があれば、その部分を選ぶ
- 中央の部分が候補の場所のものなら result="matched"、landmark_id にその ID を入れる（候補に無い ID は使わない）。
  description にその部分の特徴を書く
- 候補の場所の全体しか写っておらず、目を引く部分が言えないときは result="matched"・part="whole"・description=null にする
- 説明（description）には、聞いて「へえ」と思える点を、写真に見えていること（珍しい形・凝った飾り・素材・模様・色）から1つ入れる。
  由来・歴史・作者・年代・名前のわけは書かない。登録した場所の名前は説明の中で繰り返さない。
  見た目をなぞるだけの説明（例：「白い建物です」）しか言えないなら result="unknown" にする
- 候補ではないが何か分かるなら result="unlisted"。object_name に名前を入れる。
  固有の名前（例：〇〇橋）まで分かったときだけ named=true、一般的な名前（例：木造の蔵）なら named=false
  description に、歩きながら一度聞いて分かる話し言葉の説明を入れる（目安{max_chars}字以内、1〜2文）
- 固有の名前（named=true）は、次のどちらかのときだけ答える：看板・銘板の文字で名前が読める／形・色から、それだと確かに見分けられる
  有名な場所（例：天門橋）。どちらでもなければ named=false にして、一般的な名前で答える
  エリアの中にいるからといって、エリアで有名な場所の名前を当てはめない（写っていないものの名前を言わない）
- 近くの場所の名前と一般名をつなげて名前を作らない（例：「〇〇ビルのV字の柱」は固有名ではない）。
- 候補の場所は、別名や古い名前で呼ばれることがある（候補の「別名」）。別名に当たるものなら、その候補として result="matched" にする
- 中央に写っているのが道・地面・水面・空・人などで、名前の付いたものが写っていないときは、
  一般的な名前（例：運河沿いの散策路）で named=false にするか、result="unknown" にする
- 分からない・自信がないなら result="unknown"。推測で答えない
- 年号・数字・人数・高さなどの数は書かない。ものの数も数字で書かず、言葉で言う（「2つの塔」ではなく「両端の塔」「並んだ窓」）。
  数字を含む文は読み上げずに捨てるので、数字を使うと説明が残らない
- 「右手に」「正面に」など方向の言葉は書かない
- confidence は 0〜1 で、答えの確からしさ
{grounding_rule}
# 出力
次の JSON だけを出力する。
{{"worth_telling": true/false, "result": "matched|unlisted|unknown", "landmark_id": "lm_0001 または null", "object_name": "名前 または null",
  "named": true/false, "description": "説明 または null", "part": "whole など または null", "confidence": 0.0}}
"""

AREA_RULE = "- 利用者はエリア「{name}」の中にいる（{summary}）。エリアの中にある、名前の付いた建物・橋・道・広場などを特定して答える\n"
NEAR_RULE = (
    "- 撮影したのは登録した場所「{name}」の付近（中央のものが「{name}」の一部とは限らない。"
    "「{name}」のものなら result=\"matched\"・landmark_id に {id}）\n"
)
TIME_RULE = "- 撮影の日時：{when}（日本時間）。光の具合や季節の見え方（夜の明かり・雪・紅葉など）の手がかりにする\n"
REQUESTED_RULE = "- 利用者が自分で「これは何？」と調べるよう頼んだ。中央のものについて答える（答え方の決まりは同じ）\n"
WEEKDAYS = "月火水木金土日"

GROUNDING_RULE = "- 名前は Google マップの場所のデータで確かめる。確かめられない名前は named=false にする\n"

RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        # 観光の案内として話す価値があるか。先に答えさせ、false なら後処理で unknown にする
        # （11/6 夜は「ありふれているか」を聞いていたが、例に無いものがすり抜けた。11/7 夜に逆にした）
        "worth_telling": {"type": "BOOLEAN"},
        "result": {"type": "STRING", "enum": list(RESULTS)},
        "landmark_id": {"type": "STRING", "nullable": True},
        "object_name": {"type": "STRING", "nullable": True},
        "named": {"type": "BOOLEAN"},
        "description": {"type": "STRING", "nullable": True},
        "part": {"type": "STRING", "enum": list(PARTS), "nullable": True},
        "confidence": {"type": "NUMBER"},
    },
    "required": ["worth_telling", "result", "landmark_id", "object_name", "named", "description", "part", "confidence"],
    "propertyOrdering": ["worth_telling", "result", "landmark_id", "object_name", "named", "part", "description", "confidence"],
}


def context_place(req: dict) -> str:
    """おおまかな住所（町丁目名があれば「富山市〇〇付近」）。"""
    town = (req.get("context") or {}).get("town")
    return f"富山市{town}付近" if town else "富山市内"


def context_rules(req: dict, candidates: list[dict] | None = None) -> str:
    """撮影の手がかり（context）をプロンプトの行にする。無い項目は書かない（古いアプリは送らない）。

    範囲の中のランドマークの名前は、アプリから届いた名前ではなく、サーバーの DB（人が確認した
    ランドマーク）の名前を使う。DB に無い ID なら書かない（11/7、メンバー1）。
    """
    ctx = req.get("context") or {}
    out = ""
    near = ctx.get("near_landmark")
    known = {c["id"]: c for c in candidates or []}
    if near and near.get("id") in known:
        out += NEAR_RULE.format(name=known[near["id"]]["name"], id=near["id"])
    at = ctx.get("captured_at")
    if at:
        from datetime import date

        y, mo, d = int(at[0:4]), int(at[5:7]), int(at[8:10])
        wd = WEEKDAYS[date(y, mo, d).weekday()]
        out += TIME_RULE.format(when=f"{mo}月{d}日（{wd}）{int(at[11:13])}時{at[14:16]}分")
    if ctx.get("trigger") in ("button", "voice"):
        out += REQUESTED_RULE
    return out


def unknown(search_id: str, confidence: float = 0.0) -> dict:
    return {
        "schema_version": SCHEMA_VERSION, "search_id": search_id, "result": "unknown",
        "landmark_id": None, "object_name": None, "description": None, "part": None,
        "confidence": max(0.0, min(1.0, confidence)), "named": False, "sources": [],
    }


def clean_description(text: str, max_chars: int) -> str | None:
    """数字・年号を含む文を落とし、max_chars 以内に切る。何も残らなければ None。"""
    kept = [s.strip() for s in SENTENCE_RE.findall(text or "") if s.strip() and not NUMBER_RE.search(s)]
    out = ""
    for s in kept:
        if len(out) + len(s) > max_chars:
            break
        out += s
    if not out and kept:  # 1文目から長すぎる → 文の途中で切る
        out = kept[0][: max_chars - 1].rstrip("、") + "。"
    return out or None


def norm_name(name: str) -> str:
    """名前の照合用：全角半角・空白・中黒・括弧の違いをならす。"""
    import unicodedata

    return re.sub(r"[\s・･「」『』（）()]", "", unicodedata.normalize("NFKC", name or "")).lower()


def registered_names(landmarks: list[dict]) -> dict[str, str]:
    """登録したランドマークの名前と別名（aliases）→ ID。"""
    out: dict[str, str] = {}
    for lm in landmarks:
        for n in [lm.get("name", ""), *(lm.get("aliases") or [])]:
            if norm_name(n):
                out.setdefault(norm_name(n), lm["id"])
    return out


def postprocess(raw_text: str, search_id: str, candidate_ids: list[str], sources: list[dict], settings: Settings,
                names: dict[str, str] | None = None) -> dict:
    """Gemini の答え（文字列）→ schema の形。おかしな答えは unknown にする。

    names：登録したランドマークの名前・別名 → ID（候補とタイルの中のもの）。unlisted の名前がこれと同じなら、
    候補なら matched に直し、候補でなければ unknown にする（11/7 夜）。
    """
    m = re.search(r"\{.*\}", raw_text or "", re.S)
    try:
        data = json.loads(m.group(0)) if m else None
    except json.JSONDecodeError:
        data = None
    if not isinstance(data, dict) or data.get("result") not in RESULTS:
        return unknown(search_id)
    try:
        conf = max(0.0, min(1.0, float(data.get("confidence", 0))))
    except (TypeError, ValueError):
        conf = 0.0
    if data["result"] == "unknown" or conf < settings.visual_min_confidence:
        return unknown(search_id, conf)
    if data.get("worth_telling") is not True:  # 話す価値がない（または答えていない）→ 話さない
        # matched・whole は B では話さず A に任せるので、価値の判定に関係なくそのまま返す
        if not (data["result"] == "matched" and data.get("part") == "whole"):
            return unknown(search_id, conf)
    # 登録した場所の名前・別名で unlisted が返った → 候補なら matched、候補でなければ話さない
    if data["result"] == "unlisted" and names:
        hit = names.get(norm_name(data.get("object_name") or ""))
        if hit:
            if hit not in candidate_ids:
                return unknown(search_id, conf)
            data = data | {"result": "matched", "landmark_id": hit}

    base = unknown(search_id, conf)
    part = data.get("part")
    if part not in PARTS:  # 一覧に無い・空 → その他
        part = "other"
    if data["result"] == "matched":
        lm = data.get("landmark_id")
        if lm not in candidate_ids:  # 候補に無い ID は信じない
            return unknown(search_id, conf)
        whole = base | {"result": "matched", "landmark_id": lm, "part": "whole"}
        if part == "whole":
            return whole
        # 登録したランドマークの特徴。説明が残らなければ全体の紹介に戻す（A の確認済みの原稿で話す）
        desc = clean_description(data.get("description") or "", settings.description_max_chars)
        if desc is None:
            return whole
        return whole | {"part": part, "description": desc}

    name = (data.get("object_name") or "").strip()
    if not name or NUMBER_RE.search(name):
        return unknown(search_id, conf)
    if not data.get("named") and COMMONPLACE_RE.search(name):  # 一般名がありふれたもの → 話さない（commonplace の取りこぼし対策）
        return unknown(search_id, conf)
    desc = clean_description(data.get("description") or "", settings.description_max_chars)
    if desc is None:
        return unknown(search_id, conf)
    return base | {
        "result": "unlisted", "object_name": name, "description": desc, "part": part,
        "named": bool(data.get("named")), "sources": sources,
    }


class GeminiVisualSearch:
    def __init__(self, settings: Settings, tiles: TileSource, client=None):
        if client is None:
            if not settings.gcp_project:
                raise RuntimeError("GEMINI_MODE=real には GOOGLE_CLOUD_PROJECT が要る")
            from google import genai
            from google.genai import types

            client = genai.Client(
                vertexai=True, project=settings.gcp_project, location=settings.vertex_location,
                http_options=types.HttpOptions(timeout=int(settings.gemini_timeout_s * 1000)),
            )
        self._client = client
        self._s = settings
        self._tiles = tiles

    def _prompt(self, req: dict, candidates: list[dict]) -> str:
        s, n, w, e = tile_bounds(req["tile"]["x"], req["tile"]["y"])
        cand = "\n".join(
            f"  - {c['id']}：{c['name']}（{c['kind']}）"
            + (f"別名：{'・'.join(c['aliases'])}。" if c.get("aliases") else "")
            + f"見た目：{c.get('visual_hint') or '不明'}。{c.get('script_short', '')}"
            for c in candidates
        ) or "  - （なし）"
        area = req.get("area")
        return PROMPT.format(
            place=context_place(req), context=context_rules(req, candidates),
            tile=f"16/{req['tile']['x']}/{req['tile']['y']}", lat=(s + n) / 2, lon=(w + e) / 2,
            gaze=req["gaze_az_deg"], candidates=cand, max_chars=self._s.description_max_chars,
            parts="／".join(f"{k}（{v}）" for k, v in PARTS.items()),
            area=AREA_RULE.format(name=area["name"], summary=area["summary"]) if area else "",
            grounding_rule=GROUNDING_RULE if self._use_maps(req) else "",
        )

    def _use_maps(self, req: dict) -> bool:
        return self._s.gemini_grounding == "maps" and bool(req.get("area"))

    def _config(self, req: dict):
        from google.genai import types

        thinking = types.ThinkingConfig(thinking_level=self._s.gemini_thinking_level) if self._s.gemini_thinking_level else None
        if not self._use_maps(req):
            return types.GenerateContentConfig(
                temperature=0.1, response_mime_type="application/json", response_schema=RESPONSE_SCHEMA,
                thinking_config=thinking,
            )
        s, n, w, e = tile_bounds(req["tile"]["x"], req["tile"]["y"])
        # グラウンディングは構造化出力と一緒に使えないことがあるので、JSON はプロンプトで頼んで後処理で読む
        return types.GenerateContentConfig(
            temperature=0.1,
            thinking_config=thinking,
            tools=[types.Tool(google_maps=types.GoogleMaps())],
            tool_config=types.ToolConfig(retrieval_config=types.RetrievalConfig(
                lat_lng=types.LatLng(latitude=(s + n) / 2, longitude=(w + e) / 2), language_code="ja",
            )),
        )

    @staticmethod
    def _sources(res) -> list[dict]:
        out = []
        cand = res.candidates[0] if getattr(res, "candidates", None) else None
        meta = getattr(cand, "grounding_metadata", None)
        for ch in (getattr(meta, "grounding_chunks", None) or []):
            mp = getattr(ch, "maps", None)
            if mp and mp.uri:
                out.append({"title": mp.title or "", "uri": mp.uri, "place_id": mp.place_id})
        return out[:5]

    def search(self, request: dict) -> dict:
        from google.genai import types

        try:
            image = base64.b64decode(request["image_jpeg_base64"], validate=True)
        except (binascii.Error, ValueError):
            raise ApiError(400, "bad_request")
        # 範囲の中にいるランドマーク（context.near_landmark）も、視線の外でも候補に入れる（「〇〇付近」で撮ったため）
        near = ((request.get("context") or {}).get("near_landmark") or {}).get("id")
        ids = list(request["candidate_ids"]) + ([near] if near and near not in request["candidate_ids"] else [])
        known = self._tiles.landmarks_by_id(ids)
        candidates = [known[i] for i in ids if i in known]
        # 名前の照合用：候補と、同じタイルにある登録したランドマーク（名前と別名）
        tile_ids = [lm["id"] for lm in self._tiles.get_tile(request["tile"]["x"], request["tile"]["y"])["landmarks"]]
        names = registered_names(candidates + list(self._tiles.landmarks_by_id(tile_ids).values()))
        try:
            res = self._client.models.generate_content(
                model=self._s.gemini_model,
                contents=[types.Part.from_bytes(data=image, mime_type="image/jpeg"), self._prompt(request, candidates)],
                config=self._config(request),
            )
        except Exception as e:
            if _is_timeout(e):
                raise ApiError(504, "gemini_timeout")
            log.error("gemini error: %s", type(e).__name__)  # 本文・画像は出さない
            raise ApiError(502, "gemini_error")
        finally:
            del image
        _log_usage(res)
        return postprocess(res.text or "", request["search_id"], [c["id"] for c in candidates], self._sources(res), self._s,
                           names=names)


def _log_usage(res) -> None:
    """1回あたりの費用を実測するため、トークン数だけをログに出す（本文・画像は出さない）。"""
    u = getattr(res, "usage_metadata", None)
    if u is None:
        return
    log.info(
        "gemini usage: prompt=%s output=%s thoughts=%s total=%s",
        getattr(u, "prompt_token_count", None), getattr(u, "candidates_token_count", None),
        getattr(u, "thoughts_token_count", None), getattr(u, "total_token_count", None),
    )


def _is_timeout(e: Exception) -> bool:
    """httpx のタイムアウト、または Vertex AI が返す 504（DEADLINE_EXCEEDED）。"""
    name = type(e).__name__.lower()
    return "timeout" in name or "timed out" in str(e).lower() or getattr(e, "code", None) in (408, 504)

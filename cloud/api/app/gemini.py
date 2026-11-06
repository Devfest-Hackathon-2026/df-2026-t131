"""B：視界の検索の本物（Vertex AI の Gemini）。CLAUDE.md 6章。

1回の呼び出しで「候補のどれか（matched）／候補外の名前と説明（unlisted）／わからない（unknown）」と
自信の度合いを返させ、ここで後処理してから schema の形で返す。

部分（part）：中央に写っているのが対象の全体（whole）か、窓・入口などの特定の部分か（B の仕様書 5章）。
  matched・whole は説明を返さない（11/6 夜：B では全体の紹介をしない＝engine が A に任せて見送る）。
  matched・whole 以外は「登録したランドマークの特徴」で、見えていることだけの説明を返す（engine は全体の紹介とは別の話として扱う）。
  ありふれたもの（電柱・自動販売機など）や、見た目をなぞるだけの説明しか言えないものは unknown にさせる（11/6 夜、メンバー2の提案）。

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
SENTENCE_RE = re.compile(r"[^。！？!?]+[。！？!?]?")

PROMPT = """あなたは、富山市を歩く人のための音声ガイドです。利用者はカメラ付きのメガネをかけて歩いています。
写真は、利用者がいま見ている景色です。**写真の中央にある、歩いている人がふだん見過ごしてしまう「聞くと少し面白いもの」**
（凝った飾り・珍しい形・素材の特徴など）を1つ見つけて答えてください。建物などの全体の紹介は別の機能が行うので、全体ではなく部分を探します。

# 手がかり
- おおよその場所：富山市内（地図タイル {tile}、中心は北緯{lat:.3f}・東経{lon:.3f}付近）
- 見ている方向：真北から時計回りに {gaze} 度
{area}- 近くにある、登録済みの場所（中央のものがどの場所のものかを書くための手がかり。当てることが目的ではない）：
{candidates}

# 答え方
- 目的は、ふだん見過ごしてしまうものに気づくきっかけを短く伝えること
- 中央にあるのが、どこにでもあるもの（電柱・信号・自動販売機・ふつうの住宅・駐車場・チェーン店・コンビニ・
  ふつうの街路樹・ガードレールなど）だけなら result="unknown" にする
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
- 固有の名前は、写真に写っている形・色・看板の文字などから、それだと確かに見分けられるときだけ答える。
  エリアの中にいるからといって、エリアで有名な場所の名前を当てはめない（写っていないものの名前を言わない）
- 中央に写っているのが道・地面・水面・空・人などで、名前の付いたものが写っていないときは、
  一般的な名前（例：運河沿いの散策路）で named=false にするか、result="unknown" にする
- 分からない・自信がないなら result="unknown"。推測で答えない
- 年号・数字・人数・高さなどの数は書かない
- 「右手に」「正面に」など方向の言葉は書かない
- confidence は 0〜1 で、答えの確からしさ
{grounding_rule}
# 出力
次の JSON だけを出力する。
{{"result": "matched|unlisted|unknown", "landmark_id": "lm_0001 または null", "object_name": "名前 または null",
  "named": true/false, "description": "説明 または null", "part": "whole など または null", "confidence": 0.0}}
"""

AREA_RULE = "- 利用者はエリア「{name}」の中にいる（{summary}）。エリアの中にある、名前の付いた建物・橋・道・広場などを特定して答える\n"
GROUNDING_RULE = "- 名前は Google マップの場所のデータで確かめる。確かめられない名前は named=false にする\n"

RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "result": {"type": "STRING", "enum": list(RESULTS)},
        "landmark_id": {"type": "STRING", "nullable": True},
        "object_name": {"type": "STRING", "nullable": True},
        "named": {"type": "BOOLEAN"},
        "description": {"type": "STRING", "nullable": True},
        "part": {"type": "STRING", "enum": list(PARTS), "nullable": True},
        "confidence": {"type": "NUMBER"},
    },
    "required": ["result", "landmark_id", "object_name", "named", "description", "part", "confidence"],
}


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


def postprocess(raw_text: str, search_id: str, candidate_ids: list[str], sources: list[dict], settings: Settings) -> dict:
    """Gemini の答え（文字列）→ schema の形。おかしな答えは unknown にする。"""
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
            f"  - {c['id']}：{c['name']}（{c['kind']}）見た目：{c.get('visual_hint') or '不明'}。{c.get('script_short', '')}"
            for c in candidates
        ) or "  - （なし）"
        area = req.get("area")
        return PROMPT.format(
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
        known = self._tiles.landmarks_by_id(request["candidate_ids"])
        candidates = [known[i] for i in request["candidate_ids"] if i in known]
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
        return postprocess(res.text or "", request["search_id"], [c["id"] for c in candidates], self._sources(res), self._s)


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

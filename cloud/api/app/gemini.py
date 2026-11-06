"""B：視界の検索の本物（Vertex AI の Gemini）。CLAUDE.md 6章。

1回の呼び出しで「候補のどれか（matched）／候補外の名前と説明（unlisted）／わからない（unknown）」と
自信の度合いを返させ、ここで後処理してから schema の形で返す。

後処理（AI の答えをそのまま信じない）:
  - JSON が壊れている・候補に無い ID を返した・名前が無い → unknown（推測で補わない）
  - 説明から、数字・年号を含む文を落とす（AI が作った数字は読み上げない。CLAUDE.md 3章7）
  - 説明は目安100字で切る
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

# 数字・年号を含む文を見つける（全角・漢数字＋単位・元号）
NUMBER_RE = re.compile(
    r"[0-9０-９]"
    r"|(?:明治|大正|昭和|平成|令和|江戸時代|慶長|元和|寛永|元禄|享保|天保|安政|文久|慶応)"
    r"|[一二三四五六七八九十百千万]+(?:年|月|日|メートル|キロ|階|代|世紀|周年|番目|基|本|人|棟)"
)
SENTENCE_RE = re.compile(r"[^。！？!?]+[。！？!?]?")

PROMPT = """あなたは、富山市を歩く人のための音声ガイドです。利用者はカメラ付きのメガネをかけて歩いています。
写真は、利用者がいま見ている景色です。**写真の中央にあるもの**（建物全体ではなく、中央に写っている部分や対象）が何かを答えてください。

# 手がかり
- おおよその場所：富山市内（地図タイル {tile}、中心は北緯{lat:.3f}・東経{lon:.3f}付近）
- 見ている方向：真北から時計回りに {gaze} 度
{area}- 近くにある、登録済みの場所（候補）：
{candidates}

# 答え方
- 中央のものが候補のどれかなら result="matched"、landmark_id にその ID を入れる（候補に無い ID は使わない）
- 候補ではないが何か分かるなら result="unlisted"。object_name に名前を入れる。
  固有の名前（例：〇〇橋）まで分かったときだけ named=true、一般的な名前（例：木造の蔵）なら named=false
  description に、歩きながら一度聞いて分かる話し言葉の説明を入れる（目安{max_chars}字以内、1〜2文）
  説明には、写真から分かる具体的な特徴（形・色・素材・飾りなど）を1つ必ず入れる。言えなければ result="unknown" にする
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
  "named": true/false, "description": "説明 または null", "confidence": 0.0}}
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
        "confidence": {"type": "NUMBER"},
    },
    "required": ["result", "landmark_id", "object_name", "named", "description", "confidence"],
}


def unknown(search_id: str, confidence: float = 0.0) -> dict:
    return {
        "schema_version": SCHEMA_VERSION, "search_id": search_id, "result": "unknown",
        "landmark_id": None, "object_name": None, "description": None,
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
    if data["result"] == "matched":
        lm = data.get("landmark_id")
        if lm not in candidate_ids:  # 候補に無い ID は信じない
            return unknown(search_id, conf)
        return base | {"result": "matched", "landmark_id": lm}

    name = (data.get("object_name") or "").strip()
    if not name or NUMBER_RE.search(name):
        return unknown(search_id, conf)
    desc = clean_description(data.get("description") or "", settings.description_max_chars)
    if desc is None:
        return unknown(search_id, conf)
    return base | {
        "result": "unlisted", "object_name": name, "description": desc,
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

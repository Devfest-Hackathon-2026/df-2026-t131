"""Cloud Run の API（tasks/README.md 2.4）。

  GET  /health                 生存確認（認証なし）
  GET  /v1/tiles/16/{x}/{y}    A：タイル単位のランドマーク・電停・横断歩道・イベント
  POST /v1/visual-search       B：視界の検索

決まり：
  - /v1/ は X-App-Token ヘッダーが必要
  - エラーは HTTP 4xx/5xx と {"error": "<短いコード>"}（コード一覧は schema/README.md）
  - リクエスト本文（画像を含む）をログに出さない・ディスクに残さない
"""
import json
import logging
import secrets
import threading
from datetime import datetime, timedelta, timezone

from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import contracts
from .errors import ApiError
from .event_status import EventStatusSource, FileEventStatus, apply_statuses
from .settings import Settings
from .sources import FakeTileSource, FakeVisualSearch, SqliteTileSource, TileSource, VisualSearch

log = logging.getLogger("api")
JST = timezone(timedelta(hours=9))


class DailyLimiter:
    """1日（日本時間）あたりの呼び出し回数の上限。インスタンスごとに数える。

    Cloud Run は --max-instances を小さく（1〜2）して、全体の上限がずれすぎないようにする。
    """

    def __init__(self, limit: int):
        self._limit = limit
        self._day = None
        self._count = 0
        self._lock = threading.Lock()

    def take(self) -> bool:
        today = datetime.now(JST).date()
        with self._lock:
            if today != self._day:
                self._day, self._count = today, 0
            if self._count >= self._limit:
                return False
            self._count += 1
            return True


def create_app(
    settings: Settings | None = None,
    tile_source: TileSource | None = None,
    visual_search: VisualSearch | None = None,
    event_status: EventStatusSource | None = None,
) -> FastAPI:
    settings = settings or Settings()
    settings.check()
    if not settings.app_token:
        log.warning("APP_TOKEN が未設定のため、/v1/ はすべて 401 を返す")

    if tile_source is None:
        tile_source = SqliteTileSource(
            settings.tiles_db_path, include_zones=settings.tile_zones == "on", include_shapes=settings.tile_shapes == "on"
        ) if settings.tile_source == "sqlite" else FakeTileSource()
    tiles = tile_source
    if visual_search is None:
        if settings.gemini_mode == "real":
            from .gemini import GeminiVisualSearch  # real のときだけ読み込む

            visual_search = GeminiVisualSearch(settings, tiles)
        else:
            visual_search = FakeVisualSearch()
    visual = visual_search
    if event_status is None:
        if settings.event_status == "firestore":
            from .event_status import firestore_event_status

            event_status = firestore_event_status()
        else:
            event_status = FileEventStatus()
    limiter = DailyLimiter(settings.visual_search_daily_limit)

    app = FastAPI(title="アンビエント・ナラティブガイド API", docs_url=None, redoc_url=None, openapi_url=None)

    # ---- エラーはすべて {"error": "<コード>"} にそろえる（中身の詳細は返さない）----
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, e: ApiError):
        return JSONResponse({"error": e.code}, status_code=e.status)

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_: Request, e: StarletteHTTPException):
        code = {404: "not_found", 405: "method_not_allowed"}.get(e.status_code, "bad_request")
        return JSONResponse({"error": code}, status_code=e.status_code)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, __: RequestValidationError):
        return JSONResponse({"error": "bad_request"}, status_code=400)

    @app.exception_handler(Exception)
    async def _internal_error(_: Request, e: Exception):
        log.error("internal error: %s", type(e).__name__)  # 例外の中身（本文を含みうる）は出さない
        return JSONResponse({"error": "internal"}, status_code=500)

    def require_token(x_app_token: str | None = Header(default=None)) -> None:
        if not settings.app_token or not x_app_token or not secrets.compare_digest(
            x_app_token.encode(), settings.app_token.encode()
        ):
            raise ApiError(401, "unauthorized")

    # ---- ルート ----
    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/v1/tiles/16/{x}/{y}", dependencies=[Depends(require_token)])
    def get_tile(x: int, y: int):
        if x < 0 or y < 0 or x >= 2**16 or y >= 2**16:
            raise ApiError(400, "bad_request")
        return apply_statuses(tiles.get_tile(x, y), event_status)

    @app.post("/v1/visual-search", dependencies=[Depends(require_token)])
    async def post_visual_search(request: Request):
        try:
            body = json.loads(await request.body())
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise ApiError(400, "bad_request")
        if not isinstance(body, dict):
            raise ApiError(400, "bad_request")
        image = body.get("image_jpeg_base64")
        if isinstance(image, str) and len(image) > settings.max_image_base64_chars:
            raise ApiError(413, "image_too_large")
        if not contracts.is_valid(contracts.VISUAL_REQUEST, body):
            raise ApiError(400, "bad_request")
        if not limiter.take():
            raise ApiError(429, "rate_limited")
        try:
            return visual.search(body)
        finally:
            # 画像は検索が終わったらすぐ手放す（保存しない）
            body.pop("image_jpeg_base64", None)
            del image

    return app


app = create_app()

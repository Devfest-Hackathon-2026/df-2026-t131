"""クラウド側の定数と設定（docs/design.md 17.5）。

値は環境変数で上書きできる。Cloud Run では環境変数（秘密は Secret Manager）で渡す。
既定値は「誤って課金しない」側に倒してある（GEMINI_MODE=fake）。
"""
import os
from dataclasses import dataclass, field
from pathlib import Path

# リポジトリの一番上（コンテナの中でも同じ構成にしてある）
ROOT = Path(__file__).resolve().parents[3]
SCHEMA_DIR = ROOT / "schema"
EXAMPLES_DIR = SCHEMA_DIR / "examples"

SCHEMA_VERSION = "0.3"
TILE_ZOOM = 16


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


@dataclass(frozen=True)
class Settings:
    # fake：見本のタイルを返す／sqlite：build_sqlite.py が作った SQLite から返す
    tile_source: str = field(default_factory=lambda: _env("TILE_SOURCE", "fake"))
    # on：タイルの応答に zones（カメラで調べない区域）を付ける。engine が zones を読めるようになってから on にする（11/7）
    tile_zones: str = field(default_factory=lambda: _env("TILE_ZONES", "off"))
    # ランドマークの形（shape）をタイルに付けるか（11/7）。形を読める engine のアプリが入ってから on にする
    tile_shapes: str = field(default_factory=lambda: _env("TILE_SHAPES", "off"))
    tiles_db_path: str = field(default_factory=lambda: _env("TILES_DB_PATH", str(ROOT / "cloud" / "data" / "build" / "tiles.sqlite")))
    # file：events.json の開催状態のまま／firestore：Firestore の event_status で上書き（デモで「中止」に切り替える）
    event_status: str = field(default_factory=lambda: _env("EVENT_STATUS", "file"))
    # fake：schema/examples の見本を返す（課金なし）／real：Vertex AI の Gemini を呼ぶ
    gemini_mode: str = field(default_factory=lambda: _env("GEMINI_MODE", "fake"))
    # maps：Google マップでのグラウンディングを付ける／off：付けない（docs/design.md 6章）
    gemini_grounding: str = field(default_factory=lambda: _env("GEMINI_GROUNDING", "off"))
    # 11/5 に実際の写真で比べて決めた（docs/design.md 15章）。gemini-3.6-flash は global でだけ使える。
    # 考える量を LOW にすると 2〜3 秒で、写っていない名前を言う誤りもなかった
    vertex_location: str = field(default_factory=lambda: _env("VERTEX_LOCATION", "global"))
    gemini_model: str = field(default_factory=lambda: _env("GEMINI_MODEL", "gemini-3.6-flash"))
    # MINIMAL / LOW / MEDIUM / HIGH。空なら指定しない（モデルの既定）
    gemini_thinking_level: str = field(default_factory=lambda: _env("GEMINI_THINKING_LEVEL", "LOW"))
    gcp_project: str = field(default_factory=lambda: _env("GOOGLE_CLOUD_PROJECT", ""))
    # これ未満の自信は unknown にする（明らかに自信のない答えを外すだけ。話すかの本当のしきい値は engine の 0.6）
    visual_min_confidence: float = field(default_factory=lambda: float(_env("VISUAL_MIN_CONFIDENCE", "0.3")))
    # B の説明の長さ（目安100字＝約15秒。schema の上限は120字）
    description_max_chars: int = field(default_factory=lambda: int(_env("DESCRIPTION_MAX_CHARS", "100")))
    gemini_timeout_s: float = field(default_factory=lambda: float(_env("GEMINI_TIMEOUT_S", "6")))  # mobile の 8 秒より短く
    # 1日あたりの B の呼び出し上限（端末側の上限が壊れても予算を守る）。日付は日本時間で区切る
    visual_search_daily_limit: int = field(default_factory=lambda: int(_env("VISUAL_SEARCH_DAILY_LIMIT", "1000")))
    # 画像の上限（base64 の文字数）。長辺640px の JPEG は通常 100KB 前後なので余裕を持たせる
    max_image_base64_chars: int = field(default_factory=lambda: int(_env("MAX_IMAGE_BASE64_CHARS", str(1_000_000))))
    # X-App-Token の値。空なら /v1/ はすべて拒否する（設定漏れで開きっぱなしにしない）
    app_token: str = field(default_factory=lambda: _env("APP_TOKEN", ""))

    def check(self) -> None:
        if self.gemini_mode not in ("fake", "real"):
            raise ValueError(f"GEMINI_MODE は fake か real: {self.gemini_mode}")
        if self.tile_source not in ("fake", "sqlite"):
            raise ValueError(f"TILE_SOURCE は fake か sqlite: {self.tile_source}")
        if self.tile_zones not in ("on", "off"):
            raise ValueError(f"TILE_ZONES は on か off: {self.tile_zones}")
        if self.tile_shapes not in ("on", "off"):
            raise ValueError(f"TILE_SHAPES は on か off: {self.tile_shapes}")
        if self.event_status not in ("file", "firestore"):
            raise ValueError(f"EVENT_STATUS は file か firestore: {self.event_status}")
        if self.gemini_grounding not in ("maps", "off"):
            raise ValueError(f"GEMINI_GROUNDING は maps か off: {self.gemini_grounding}")

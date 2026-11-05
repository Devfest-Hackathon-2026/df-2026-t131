"""クラウド側の定数と設定（tasks/README.md 2.5）。

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

SCHEMA_VERSION = "0.2"
TILE_ZOOM = 16


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


@dataclass(frozen=True)
class Settings:
    # fake：schema/examples の見本を返す（課金なし）／real：Vertex AI の Gemini を呼ぶ
    gemini_mode: str = field(default_factory=lambda: _env("GEMINI_MODE", "fake"))
    # maps：Google マップでのグラウンディングを付ける／off：付けない（CLAUDE.md 6章）
    gemini_grounding: str = field(default_factory=lambda: _env("GEMINI_GROUNDING", "off"))
    # TODO(メンバー1): 本物の /v1/visual-search に取りかかる前に、地域とモデル名を確定する
    #   （Google マップでのグラウンディングが使える地域かも確かめる）
    vertex_location: str = field(default_factory=lambda: _env("VERTEX_LOCATION", "asia-northeast1"))
    gemini_model: str = field(default_factory=lambda: _env("GEMINI_MODEL", "gemini-2.5-flash"))
    gemini_timeout_s: float = field(default_factory=lambda: float(_env("GEMINI_TIMEOUT_S", "6")))  # mobile の 8 秒より短く
    # 1日あたりの B の呼び出し上限（端末側の上限が壊れても予算を守る）。日付は日本時間で区切る
    visual_search_daily_limit: int = field(default_factory=lambda: int(_env("VISUAL_SEARCH_DAILY_LIMIT", "300")))
    # 画像の上限（base64 の文字数）。長辺640px の JPEG は通常 100KB 前後なので余裕を持たせる
    max_image_base64_chars: int = field(default_factory=lambda: int(_env("MAX_IMAGE_BASE64_CHARS", str(1_000_000))))
    # X-App-Token の値。空なら /v1/ はすべて拒否する（設定漏れで開きっぱなしにしない）
    app_token: str = field(default_factory=lambda: _env("APP_TOKEN", ""))

    def check(self) -> None:
        if self.gemini_mode not in ("fake", "real"):
            raise ValueError(f"GEMINI_MODE は fake か real: {self.gemini_mode}")
        if self.gemini_grounding not in ("maps", "off"):
            raise ValueError(f"GEMINI_GROUNDING は maps か off: {self.gemini_grounding}")

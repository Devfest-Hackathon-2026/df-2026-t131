"""データの入口（Repository / Source）。fake と本物を差し替えられるようにする（CLAUDE.md 14章）。

いまは fake だけ：schema/examples の見本を返す。
  - タイル：SqliteTileSource（cloud/data/build の SQLite から返す）に差し替える予定
  - 視界の検索：GeminiVisualSearch（Vertex AI）に差し替える予定
"""
import copy
import json
from typing import Protocol

from .settings import EXAMPLES_DIR, SCHEMA_VERSION, TILE_ZOOM


def _load_example(name: str) -> dict:
    with open(EXAMPLES_DIR / name, encoding="utf-8") as f:
        return json.load(f)


class TileSource(Protocol):
    def get_tile(self, x: int, y: int) -> dict: ...


class VisualSearch(Protocol):
    def search(self, request: dict) -> dict: ...


class FakeTileSource:
    """見本のタイル（16/57746/25576）だけ中身を返し、ほかのタイルは空で返す。"""

    def __init__(self) -> None:
        self._sample = _load_example("tile_response.json")

    def get_tile(self, x: int, y: int) -> dict:
        t = self._sample["tile"]
        if (x, y) == (t["x"], t["y"]):
            return copy.deepcopy(self._sample)
        return {
            "schema_version": SCHEMA_VERSION,
            "tile": {"z": TILE_ZOOM, "x": x, "y": y},
            "landmarks": [],
            "stops": [],
            "crossings": [],
            "events": [],
        }


class FakeVisualSearch:
    """送信の中身に応じて、見本の応答を決まった規則で返す（決定論的）。

    - area がある → エリア内の名前付きの対象（named）
    - 候補がある   → 候補の先頭に一致（matched）
    - 候補がない   → 候補外の対象（unlisted）
    - search_id が "_unknown" で終わる → わからない（unknown）。mobile の「黙る」動作の確認用
    """

    def __init__(self) -> None:
        self._examples = {
            k: _load_example(f"visual_search_response_{k}.json")
            for k in ("matched", "unlisted", "unknown", "named")
        }

    def search(self, request: dict) -> dict:
        if request["search_id"].endswith("_unknown"):
            res = copy.deepcopy(self._examples["unknown"])
        elif request.get("area"):
            res = copy.deepcopy(self._examples["named"])
        elif request["candidate_ids"]:
            res = copy.deepcopy(self._examples["matched"])
            res["landmark_id"] = request["candidate_ids"][0]
        else:
            res = copy.deepcopy(self._examples["unlisted"])
        res["search_id"] = request["search_id"]
        return res

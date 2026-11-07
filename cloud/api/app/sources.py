"""データの入口（Repository / Source）。fake と本物を差し替えられるようにする（CLAUDE.md 14章）。

  - タイル：FakeTileSource（見本）／SqliteTileSource（build_sqlite.py が作った SQLite）。TILE_SOURCE で選ぶ
  - 視界の検索：FakeVisualSearch（見本）。GeminiVisualSearch（Vertex AI）に差し替える予定
"""
import copy
import json
import sqlite3
from pathlib import Path
from typing import Protocol

from .settings import EXAMPLES_DIR, SCHEMA_VERSION, TILE_ZOOM
from .tiles import tile_bounds, tile_of


def _load_example(name: str) -> dict:
    with open(EXAMPLES_DIR / name, encoding="utf-8") as f:
        return json.load(f)


class TileSource(Protocol):
    def get_tile(self, x: int, y: int) -> dict: ...

    def landmarks_by_id(self, ids: list[str]) -> dict[str, dict]:
        """B の候補の名前・見た目の説明を引く。知らない ID は入らない。"""


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
            "towns": [],
        }

    def landmarks_by_id(self, ids: list[str]) -> dict[str, dict]:
        return {lm["id"]: copy.deepcopy(lm) for lm in self._sample["landmarks"] if lm["id"] in ids}


class SqliteTileSource:
    """cloud/data/scripts/build_sqlite.py が作った SQLite からタイルを返す。

    - 点のもの（ランドマーク・電停・横断歩道・イベント・町丁目の代表点）：位置が入るタイルだけに返す
    - エリア（kind: area）：範囲が重なるタイルすべてに返す（engine は ID で重複を除く）
    - カメラで調べない区域：円＋出る判定の幅がかかるタイルすべてに返す。include_zones（TILE_ZONES=on）のときだけ、
      区域のあるタイルにだけ zones のキーを付ける（無いタイルにはキーごと付けない）。
      engine が zones を読めるようになるまでは off（engine は知らないキーがあるとタイルを読めないため）
    - ランドマークの形（shape。11/7）：形のあるランドマークは、形がかかるタイルすべてに返す。shape のキーは
      include_shapes（TILE_SHAPES=on）のときだけ残す（形を読めない古い engine のため。off なら外して前と同じ形で返す）
    R*Tree は座標を少し外側に丸めるので、点は位置から計算したタイル番号でもう一度確かめる。
    """

    _KEYS = {"landmark": "landmarks", "stop": "stops", "crossing": "crossings", "event": "events", "town": "towns"}

    def __init__(self, path, include_zones: bool = False, include_shapes: bool = False) -> None:
        self._include_zones = include_zones
        self._include_shapes = include_shapes
        self._uri = f"file:{Path(path).resolve().as_posix()}?mode=ro&immutable=1"
        with self._connect() as con:  # 起動時に開けるか・版が合うかを確かめる
            meta = dict(con.execute("SELECT key, value FROM meta"))
        if meta.get("schema_version") != SCHEMA_VERSION:
            raise RuntimeError(f"SQLite の schema_version {meta.get('schema_version')} が API の {SCHEMA_VERSION} と違う")

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._uri, uri=True)

    def get_tile(self, x: int, y: int) -> dict:
        south, north, west, east = tile_bounds(x, y)
        out = {"schema_version": SCHEMA_VERSION, "tile": {"z": TILE_ZOOM, "x": x, "y": y}}
        out |= {k: [] for k in self._KEYS.values()}
        zones = []
        con = self._connect()
        try:
            rows = con.execute(
                """SELECT f.kind, f.area, f.json FROM features f JOIN features_rtree r ON f.rowid = r.rowid
                   WHERE r.max_lat >= ? AND r.min_lat <= ? AND r.max_lon >= ? AND r.min_lon <= ?
                   ORDER BY f.kind, f.id""",
                (south, north, west, east),
            ).fetchall()
        finally:
            con.close()
        for kind, area, js in rows:
            if kind == "zone":
                zones.append(json.loads(js))
                continue
            item = json.loads(js)
            if not area and tile_of(item["lat"], item["lon"]) != (x, y):
                continue
            if kind == "landmark":
                item.pop("aliases", None)  # 別名は B の名前の照合だけに使う（サーバーの中だけ。engine は読まない）
                if not self._include_shapes:
                    item.pop("shape", None)
            out[self._KEYS[kind]].append(item)
        # 区域のあるタイルにだけ zones を付ける（11/7）。zones を読めない古い engine のアプリでも、
        # 区域の無いタイルは今までどおり読めるようにするため（壊れるのは区域のあるタイルだけに限る）
        if self._include_zones and zones:
            out["zones"] = zones
        return out

    def landmarks_by_id(self, ids: list[str]) -> dict[str, dict]:
        if not ids:
            return {}
        con = self._connect()
        try:
            q = ",".join("?" * len(ids))
            rows = con.execute(f"SELECT id, json FROM features WHERE kind = 'landmark' AND id IN ({q})", ids).fetchall()
        finally:
            con.close()
        return {i: json.loads(js) for i, js in rows}


class FakeVisualSearch:
    """送信の中身に応じて、見本の応答を決まった規則で返す（決定論的）。

    - area がある → エリア内の名前付きの対象（named）
    - 候補がある   → 候補の先頭に一致（matched）
    - 候補がない   → 候補外の対象（unlisted）
    - search_id が "_unknown" で終わる → わからない（unknown）。mobile の「黙る」動作の確認用
    - search_id が "_feature" で終わり候補がある → 候補の先頭の特徴（matched・part が whole 以外）
    """

    def __init__(self) -> None:
        self._examples = {
            k: _load_example(f"visual_search_response_{k}.json")
            for k in ("matched", "matched_feature", "unlisted", "unknown", "named")
        }

    def search(self, request: dict) -> dict:
        if request["search_id"].endswith("_unknown"):
            res = copy.deepcopy(self._examples["unknown"])
        elif request["search_id"].endswith("_feature") and request["candidate_ids"]:
            res = copy.deepcopy(self._examples["matched_feature"])
            res["landmark_id"] = request["candidate_ids"][0]
        elif request.get("area"):
            res = copy.deepcopy(self._examples["named"])
        elif request["candidate_ids"]:
            res = copy.deepcopy(self._examples["matched"])
            res["landmark_id"] = request["candidate_ids"][0]
        else:
            res = copy.deepcopy(self._examples["unlisted"])
        res["search_id"] = request["search_id"]
        return res

"""build_address.py・town_lookup.py・build_sqlite.py の町丁目（通信しない。CSV は架空のものをその場で作る）。"""
import importlib.util
import json
import sqlite3
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "cloud" / "data" / "scripts"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ba = _load("build_address")
tl = _load("town_lookup")
bs = _load("build_sqlite")

BBOX = (36.6610, 137.1685, 36.7130, 137.2195)

# 位置参照情報（大字・町丁目レベル）と同じ見出し。値は架空
TOWN_HEAD = "都道府県コード,都道府県名,市区町村コード,市区町村名,大字町丁目コード,大字町丁目名,緯度,経度,原典資料コード,大字・字・丁目区分コード"
TOWN_ROWS = [
    "16,富山県,16201,富山市,162010001001,見本町一丁目,36.701600,137.212900,1,3",
    "16,富山県,16201,富山市,162010002000,見本町,36.709700,137.212300,1,1",
    "16,富山県,16201,富山市,162010003000,範囲外町,36.600000,137.212300,1,1",   # 範囲の外（南）
    "16,富山県,16202,高岡市,162020001000,ほかの市町,36.700000,137.210000,1,1",  # 富山市ではない
    "16,富山県,16201,富山市,162010001001,見本町一丁目,36.701600,137.212900,1,3",  # 重複
]
# 街区レベルと同じ見出し。値は架空
BLOCK_HEAD = "都道府県名,市区町村名,大字・丁目名,小字・通称名,街区符号・地番,座標系番号,Ｘ座標,Ｙ座標,緯度,経度,住居表示フラグ,代表フラグ,更新前履歴フラグ,更新後履歴フラグ"
BLOCK_ROWS = [
    "富山県,富山市,見本町一丁目,,1,7,0,0,36.701700,137.213000,1,1,0,0",
    "富山県,富山市,見本町,,2,7,0,0,36.709600,137.212400,1,1,0,0",
    "富山県,富山市,見本町,,3,7,0,0,36.705000,137.212600,1,1,0,0",   # 見本町の街区だが一丁目の代表点のほうが近い → 違う になる
]


def write_csv(path: Path, head: str, rows: list[str]):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(("\r\n".join([head, *rows]) + "\r\n").encode("cp932"))


def validator():
    reg = Registry()
    for p in (ROOT / "schema").rglob("*.schema.json"):
        s = json.loads(p.read_text(encoding="utf-8"))
        reg = reg.with_resource(s["$id"], Resource.from_contents(s))
    s = json.loads((ROOT / "schema" / "towns_file.schema.json").read_text(encoding="utf-8"))
    return Draft202012Validator(s, registry=reg)


# ---- 位置 → 町丁目 ----

TOWNS = [
    {"id": "162010001001", "name": "見本町一丁目", "lat": 36.7016, "lon": 137.2129},
    {"id": "162010002000", "name": "見本町", "lat": 36.7097, "lon": 137.2123},
]


def test_nearest_town_returns_the_closest_representative_point():
    got = tl.nearest_town(36.7020, 137.2130, TOWNS)
    assert got["id"] == "162010001001" and got["name"] == "見本町一丁目"
    assert 0 < got["distance_m"] < 60
    assert tl.nearest_town(36.7090, 137.2125, TOWNS)["name"] == "見本町"


def test_far_position_is_unknown_not_a_guess():
    # 一丁目の代表点から南へ約 900m
    assert tl.nearest_town(36.6935, 137.2129, TOWNS) is None
    # 上限を広げれば答える（遠さの判定が効いていることの確認）
    assert tl.nearest_town(36.6935, 137.2129, TOWNS, max_m=1000)["name"] == "見本町一丁目"


def test_no_towns_is_unknown_and_tie_breaks_by_id():
    assert tl.nearest_town(36.70, 137.21, []) is None
    same = [{"id": "162010000002", "name": "B", "lat": 36.70, "lon": 137.21},
            {"id": "162010000001", "name": "A", "lat": 36.70, "lon": 137.21}]
    assert tl.nearest_town(36.70, 137.21, same)["name"] == "A"


def test_distance_is_about_right():
    # 緯度 0.001 度 ≒ 111m
    assert tl.distance_m(36.70, 137.21, 36.701, 137.21) == pytest.approx(111.3, abs=0.5)


# ---- CSV → towns.json ----

def test_build_keeps_only_toyama_city_inside_bbox_and_matches_schema(tmp_path):
    raw = tmp_path / "raw"
    write_csv(raw / "16201-17.0b" / "16201_2024.csv", TOWN_HEAD, TOWN_ROWS)
    write_csv(raw / "16201-22.0a" / "16201_2024.csv", BLOCK_HEAD, BLOCK_ROWS)
    out = tmp_path / "towns.json"
    assert ba.build(raw, out, BBOX) == 0
    data = json.loads(out.read_text(encoding="utf-8"))
    assert [t["id"] for t in data["towns"]] == ["162010001001", "162010002000"]   # 範囲外・他の市・重複は入らない
    assert data["towns"][0] == {"id": "162010001001", "name": "見本町一丁目", "lat": 36.7016, "lon": 137.2129}
    assert data["bbox"] == list(BBOX)
    errs = [e.message for e in validator().iter_errors(data)]
    assert not errs, errs
    # 番地・街区は出力に入らない
    assert "街区" not in out.read_text(encoding="utf-8") and "地番" not in out.read_text(encoding="utf-8")


def test_build_is_deterministic(tmp_path):
    raw = tmp_path / "raw"
    write_csv(raw / "a.csv", TOWN_HEAD, list(reversed(TOWN_ROWS)))
    a, b = tmp_path / "a.json", tmp_path / "b.json"
    assert ba.build(raw, a, BBOX) == 0
    write_csv(raw / "a.csv", TOWN_HEAD, TOWN_ROWS)
    assert ba.build(raw, b, BBOX) == 0
    assert a.read_bytes() == b.read_bytes()


def test_block_check_counts_agree_disagree(capsys):
    blocks = ba.blocks_from([dict(zip(BLOCK_HEAD.split(","), r.split(","))) for r in BLOCK_ROWS], BBOX)
    assert ba.check_with_blocks(TOWNS, blocks) == (2, 1, 0)


def test_missing_csv_or_no_town_level_fails_clearly(tmp_path, capsys):
    assert ba.build(tmp_path / "none", tmp_path / "o.json", BBOX) == 1
    assert "CSV がありません" in capsys.readouterr().out
    write_csv(tmp_path / "raw" / "b.csv", BLOCK_HEAD, BLOCK_ROWS)  # 街区だけ
    assert ba.build(tmp_path / "raw", tmp_path / "o.json", BBOX) == 1
    assert not (tmp_path / "o.json").exists()


# ---- SQLite（タイルの応答は変えない） ----

def test_sqlite_has_towns_and_landmark_towns_but_tile_json_is_unchanged(tmp_path):
    out = tmp_path / "tiles.sqlite"
    assert bs.build(out, use_examples=True) == 0
    con = sqlite3.connect(out)
    try:
        towns = con.execute("SELECT id, name FROM towns ORDER BY id").fetchall()
        assert towns == [("162019990001", "見本町一丁目"), ("162019990002", "見本町二丁目")]
        lt = dict(con.execute("SELECT landmark_id, town_id FROM landmark_towns").fetchall())
        assert lt == {"lm_0001": "162019990001", "lm_0002": "162019990001", "lm_0004": "162019990001"}
        for (js,) in con.execute("SELECT json FROM features WHERE kind = 'landmark'"):
            assert "town" not in json.loads(js)   # 応答に入る JSON には町丁目を足していない
    finally:
        con.close()

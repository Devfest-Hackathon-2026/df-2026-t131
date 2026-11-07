"""build_sqlite.py で作った SQLite から、契約どおりのタイルが返るかを確かめる。"""
import importlib.util
import json
import sqlite3

import pytest
from fastapi.testclient import TestClient

from app import contracts
from app.main import create_app
from app.settings import EXAMPLES_DIR, ROOT, Settings
from app.sources import SqliteTileSource
from app.tiles import tile_bounds, tile_of

_spec = importlib.util.spec_from_file_location("build_sqlite", ROOT / "cloud" / "data" / "scripts" / "build_sqlite.py")
build_sqlite = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build_sqlite)

SAMPLE_TILE = (57746, 25576)


def example(name: str) -> dict:
    with open(EXAMPLES_DIR / name, encoding="utf-8") as f:
        return json.load(f)


@pytest.fixture
def db(tmp_path):
    out = tmp_path / "tiles.sqlite"
    assert build_sqlite.build(out, use_examples=True) == 0
    return out


def test_tile_math_roundtrip():
    s, n, w, e = tile_bounds(*SAMPLE_TILE)
    assert s < n and w < e
    assert tile_of((s + n) / 2, (w + e) / 2) == SAMPLE_TILE
    assert tile_of(36.70025945945946, 137.2137) == SAMPLE_TILE  # 見本の石碑


KEYS = ("landmarks", "stops", "crossings", "events", "towns")


def ids(tile: dict) -> dict:
    return {k: [it["id"] for it in tile[k]] for k in KEYS}


def home_tile(item: dict) -> tuple[int, int]:
    return tile_of(item["lat"], item["lon"])


def test_sample_tile_has_only_items_inside(db):
    """見本のタイル 16/57746/25576 には、その中にある石碑・通り・信号だけが入る。
    （見本の tile_response.json は形の見本で、隣のタイルの電停・イベント・公園も一緒に載せている）"""
    got = SqliteTileSource(db).get_tile(*SAMPLE_TILE)
    assert ids(got) == {"landmarks": ["lm_0001", "lm_0002"], "stops": [], "crossings": ["cr_0001"], "events": [],
                        "towns": ["162019990001"]}   # 町丁目も代表点のあるタイルだけ（案B）


def test_tiles_together_reproduce_example(db):
    """見本の中身がそれぞれの位置のタイルに入り、まとめると見本と同じになる（draft の lm_0003 は入らない）。"""
    src = SqliteTileSource(db)
    sample = example("tile_response.json")
    tiles = {home_tile(it) for k in KEYS for it in sample[k]}
    union = {k: {} for k in KEYS}
    for t in tiles:
        got = src.get_tile(*t)
        for k in KEYS:
            for it in got[k]:
                union[k][it["id"]] = it
    for k in KEYS:
        assert sorted(union[k].values(), key=lambda it: it["id"]) == sorted(sample[k], key=lambda it: it["id"])
    assert "lm_0003" not in union["landmarks"]


def test_far_tile_is_empty(db):
    got = SqliteTileSource(db).get_tile(SAMPLE_TILE[0] + 5, SAMPLE_TILE[1] + 5)
    assert all(got[k] == [] for k in KEYS)


def test_points_only_in_own_tile_area_in_overlapping_tiles(db):
    """点のものは自分のタイルだけ。エリア（半径200m）は範囲が重なるタイルすべて。"""
    src = SqliteTileSource(db)
    sample = example("tile_response.json")
    area = next(lm for lm in sample["landmarks"] if lm["kind"] == "area")
    for k in KEYS:
        for it in sample[k]:
            hx, hy = home_tile(it)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    present = it["id"] in [x["id"] for x in src.get_tile(hx + dx, hy + dy)[k]]
                    if it is area:
                        s, n, w, e = tile_bounds(hx + dx, hy + dy)
                        a_s, a_n, a_w, a_e = build_sqlite.bbox("landmark", area)
                        assert present == (a_n >= s and a_s <= n and a_e >= w and a_w <= e)
                    else:
                        assert present == ((dx, dy) == (0, 0))


def test_build_is_deterministic(tmp_path):
    a, b = tmp_path / "a.sqlite", tmp_path / "b.sqlite"
    build_sqlite.build(a, use_examples=True)
    build_sqlite.build(b, use_examples=True)
    dump = lambda p: list(sqlite3.connect(p).iterdump())
    assert dump(a) == dump(b)


def test_build_stops_on_bad_input(tmp_path, monkeypatch, capsys):
    bad = example("landmarks_sample.json")
    bad["landmarks"][1]["name_kana"] = "カタカナ"          # ひらがなでない
    bad["landmarks"][2]["id"] = bad["landmarks"][0]["id"]  # ID の重複
    p = tmp_path / "landmarks.json"
    p.write_text(json.dumps(bad, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(build_sqlite, "INPUTS", [
        ("landmark", "landmarks_file.schema.json", "landmarks", str(p), str(p)),
    ])
    out = tmp_path / "tiles.sqlite"
    assert build_sqlite.build(out) == 1
    msg = capsys.readouterr().out
    assert "landmarks[1]（lm_0002）.name_kana" in msg
    assert "ID が重複 lm_0001" in msg
    assert not out.exists()


def test_build_warns_when_no_reviewed(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(build_sqlite, "INPUTS", [
        ("landmark", "landmarks_file.schema.json", "landmarks", str(tmp_path / "none.json"), ""),
    ])
    assert build_sqlite.build(tmp_path / "t.sqlite") == 0
    assert "reviewed のランドマークが0件" in capsys.readouterr().out


def test_api_serves_sqlite_tiles(db):
    s = Settings(gemini_mode="fake", app_token="t", tile_source="sqlite", tiles_db_path=str(db))
    c = TestClient(create_app(settings=s))
    r = c.get("/v1/tiles/16/%d/%d" % SAMPLE_TILE, headers={"X-App-Token": "t"})
    assert r.status_code == 200
    assert not list(contracts.validator(contracts.TILE_RESPONSE).iter_errors(r.json()))
    assert ids(r.json())["landmarks"] == ["lm_0001", "lm_0002"]


def test_rejects_db_with_other_schema_version(db):
    con = sqlite3.connect(db)
    con.execute("UPDATE meta SET value = '0.1' WHERE key = 'schema_version'")
    con.commit()
    con.close()
    with pytest.raises(RuntimeError):
        SqliteTileSource(db)


def test_build_from_one_file_per_landmark(tmp_path, monkeypatch):
    d = tmp_path / "landmarks"
    d.mkdir()
    for src, status in (("landmark_point.json", "reviewed"), ("landmark_area.json", "draft")):
        item = json.loads((ROOT / "schema" / "templates" / src).read_text(encoding="utf-8")) | {"status": status}
        (d / f"{item['id']}.json").write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(build_sqlite, "INPUTS", [("landmark", "landmarks_file.schema.json", "landmarks", str(d), str(d))])
    out = tmp_path / "t.sqlite"
    assert build_sqlite.build(out) == 0
    got = SqliteTileSource(out).get_tile(*SAMPLE_TILE)
    assert [lm["id"] for lm in got["landmarks"]] == ["lm_0001"]          # reviewed だけ
    assert "schema_version" not in got["landmarks"][0]                    # タイル応答の形に戻す
    assert not list(contracts.validator(contracts.TILE_RESPONSE).iter_errors(got))


def test_build_stops_when_filename_and_id_differ(tmp_path, monkeypatch, capsys):
    d = tmp_path / "landmarks"
    d.mkdir()
    item = json.loads((ROOT / "schema" / "templates" / "landmark_point.json").read_text(encoding="utf-8"))
    (d / "lm_0099.json").write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(build_sqlite, "INPUTS", [("landmark", "landmarks_file.schema.json", "landmarks", str(d), str(d))])
    assert build_sqlite.build(tmp_path / "t.sqlite") == 1
    assert "ファイル名（lm_0099）と id（lm_0001）" in capsys.readouterr().out


# ---- カメラで調べない区域（11/7）----

ZONE_KEYS = ("id", "name", "lat", "lon", "radius_m", "reason")


def zone_sample() -> dict:
    with open(EXAMPLES_DIR / "zones" / "zn_0901.json", encoding="utf-8") as f:
        return json.load(f)


def test_zones_are_off_by_default(db):
    """engine が zones を読めるようになるまで、API は zones を付けない（知らないキーで engine がタイルを読めなくなるため）。"""
    z = zone_sample()
    got = SqliteTileSource(db).get_tile(*home_tile(z))
    assert "zones" not in got


def test_zones_in_every_tile_the_circle_and_exit_margin_touch(db):
    """区域は、円＋出る判定の幅15m がかかるタイルすべてに入り、ほかのタイルには入らない。タイルの形は schema どおり。"""
    src = SqliteTileSource(db, include_zones=True)
    z = zone_sample()
    hx, hy = home_tile(z)
    z_s, z_n, z_w, z_e = build_sqlite.bbox("zone", z)
    assert z_n - z_s > 2 * (z["radius_m"] + 14) / 111_320  # 出る判定の幅を足している
    for dx in (-2, -1, 0, 1, 2):
        for dy in (-2, -1, 0, 1, 2):
            got = src.get_tile(hx + dx, hy + dy)
            s, n, w, e = tile_bounds(hx + dx, hy + dy)
            expected = z_n >= s and z_s <= n and z_e >= w and z_w <= e
            # 区域のあるタイルにだけ zones のキーが付く（古いアプリが区域の無いタイルを読めるように）
            assert ("zones" in got) == expected
            assert ([x["id"] for x in got.get("zones", [])] == [z["id"]]) == expected
            assert not list(contracts.validator(contracts.TILE_RESPONSE).iter_errors(got))
    home = src.get_tile(hx, hy)["zones"][0]
    assert tuple(sorted(home)) == tuple(sorted(ZONE_KEYS))  # note・source・schema_version はタイルに入れない
    assert home["radius_m"] == z["radius_m"]


def test_zone_does_not_change_other_keys(db):
    on = SqliteTileSource(db, include_zones=True).get_tile(*SAMPLE_TILE)
    off = SqliteTileSource(db).get_tile(*SAMPLE_TILE)
    assert {k: v for k, v in on.items() if k != "zones"} == off


def test_api_serves_zones_only_when_tile_zones_on(db):
    z = zone_sample()
    path = "/v1/tiles/16/%d/%d" % home_tile(z)
    for flag, want in (("off", False), ("on", True)):
        s = Settings(gemini_mode="fake", app_token="t", tile_source="sqlite", tiles_db_path=str(db), tile_zones=flag)
        r = TestClient(create_app(settings=s)).get(path, headers={"X-App-Token": "t"})
        assert r.status_code == 200
        assert ("zones" in r.json()) == want
        assert not list(contracts.validator(contracts.TILE_RESPONSE).iter_errors(r.json()))


def test_tile_zones_setting_is_checked():
    with pytest.raises(ValueError):
        Settings(tile_zones="yes").check()


def test_real_zone_file_builds(tmp_path):
    """本物の区域（環水公園の南側、半径20m）が入る。"""
    out = tmp_path / "real.sqlite"
    assert build_sqlite.build(out) == 0
    got = SqliteTileSource(out, include_zones=True).get_tile(*tile_of(36.707472, 137.214222))
    assert [(x["id"], x["name"], x["radius_m"], x["reason"]) for x in got["zones"]] == [
        ("zn_0001", "環水公園の南側", 20, "demo")]


def test_build_stops_when_zone_filename_and_id_differ(tmp_path, monkeypatch, capsys):
    d = tmp_path / "zones"
    d.mkdir()
    (d / "zn_0002.json").write_text(json.dumps(zone_sample(), ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(build_sqlite, "ZONES", (str(d), str(d)))
    assert build_sqlite.build(tmp_path / "t.sqlite") == 1
    assert "ファイル名（zn_0002）と id（zn_0901）" in capsys.readouterr().out


# ---- ランドマークの形（shape。11/7）----

def _real(tmp_path):
    out = tmp_path / "real.sqlite"
    assert build_sqlite.build(out) == 0
    return out


def _tiles_with(src, lm_id, x0, x1, y0, y1):
    return {(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)
            if any(lm["id"] == lm_id for lm in src.get_tile(x, y)["landmarks"])}


def test_shapes_are_off_by_default(tmp_path):
    """TILE_SHAPES=off（既定）なら shape のキーを外す（形を読めない古い engine のため）。"""
    src = SqliteTileSource(_real(tmp_path))
    tile = src.get_tile(*tile_of(36.709696, 137.212295))
    assert tile["landmarks"] and all("shape" not in lm for lm in tile["landmarks"])
    assert not list(contracts.validator(contracts.TILE_RESPONSE).iter_errors(tile))


def test_shapes_on_returns_shape_in_every_tile_it_touches(tmp_path):
    """形のある建物（富山駅の駅舎は2枚のタイルにかかる）は、かかるタイルすべてで形つきで届く。"""
    src = SqliteTileSource(_real(tmp_path), include_shapes=True)
    station = home_tile({"lat": 36.701609, "lon": 137.212874})
    got = _tiles_with(src, "lm_0002", station[0] - 1, station[0] + 1, station[1] - 1, station[1] + 1)
    assert station in got and len(got) >= 2
    lm = next(x for x in src.get_tile(*station)["landmarks"] if x["id"] == "lm_0002")
    assert lm["shape"]["type"] == "polygon" and lm["shape"]["margin_m"] == 30
    assert lm["radius_m"] == 80   # 古い engine 用の円も残す
    # 形の無いラバーズ像は、今までどおり位置のタイルだけ
    lovers = home_tile({"lat": 36.70318, "lon": 137.214206})
    assert _tiles_with(src, "lm_0006", lovers[0] - 1, lovers[0] + 1, lovers[1] - 1, lovers[1] + 1) == {lovers}


def test_api_serves_shapes_only_when_tile_shapes_on(tmp_path):
    out = _real(tmp_path)
    x, y = tile_of(36.709696, 137.212295)
    for flag, has in (("off", False), ("on", True)):
        s = Settings(gemini_mode="fake", app_token="t", tile_source="sqlite", tiles_db_path=str(out), tile_shapes=flag)
        res = TestClient(create_app(settings=s)).get(f"/v1/tiles/16/{x}/{y}", headers={"X-App-Token": "t"})
        assert res.status_code == 200
        assert not list(contracts.validator(contracts.TILE_RESPONSE).iter_errors(res.json()))
        park = next(lm for lm in res.json()["landmarks"] if lm["id"] == "lm_0001")
        assert ("shape" in park) is has


def test_tile_shapes_setting_is_checked():
    with pytest.raises(ValueError):
        Settings(tile_shapes="yes").check()

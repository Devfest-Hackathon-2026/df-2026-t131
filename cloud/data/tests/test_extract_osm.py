"""extract_osm.py：Overpass の応答 → crossings.json（通信しない）。"""
import argparse
import importlib.util
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("extract_osm", ROOT / "cloud" / "data" / "scripts" / "extract_osm.py")
eo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eo)

OVERPASS = {"elements": [
    {"type": "node", "id": 300, "lat": 36.7001, "lon": 137.2131, "tags": {"highway": "crossing", "crossing": "traffic_signals"}},
    {"type": "node", "id": 100, "lat": 36.7002, "lon": 137.2132, "tags": {"highway": "crossing", "crossing": "zebra"}},
    {"type": "node", "id": 200, "lat": 36.7003, "lon": 137.2133, "tags": {"highway": "traffic_signals"}},
    {"type": "node", "id": 100, "lat": 36.7002, "lon": 137.2132, "tags": {"highway": "crossing"}},   # 重複
    {"type": "node", "id": 400, "lat": 36.7004, "lon": 137.2134, "tags": {"highway": "bus_stop"}},  # 対象外
    {"type": "way", "id": 500, "tags": {"highway": "crossing"}},                                     # ノード以外
]}


def validator():
    reg = Registry()
    for p in (ROOT / "schema").rglob("*.schema.json"):
        s = json.loads(p.read_text(encoding="utf-8"))
        reg = reg.with_resource(s["$id"], Resource.from_contents(s))
    return Draft202012Validator(json.loads((ROOT / "schema" / "crossings_file.schema.json").read_text(encoding="utf-8")), registry=reg)


def test_convert_kinds_order_and_dedupe():
    out = eo.convert(OVERPASS)
    assert [(c["id"], c["kind"]) for c in out["crossings"]] == [
        ("cr_0001", "crossing"),          # OSM id 100
        ("cr_0002", "traffic_signals"),   # 200：信号
        ("cr_0003", "traffic_signals"),   # 300：信号つきの横断歩道
    ]
    assert out["source"]["license"] == "ODbL-1.0"
    assert not list(validator().iter_errors(out))


def test_same_input_same_ids():
    shuffled = {"elements": list(reversed(OVERPASS["elements"]))}
    assert eo.convert(OVERPASS) == eo.convert(shuffled)


def test_query_contains_bbox():
    q = eo.query((36.695, 137.205, 36.705, 137.22))
    assert "36.695000,137.205000,36.705000,137.220000" in q
    assert '"highway"="crossing"' in q and '"highway"="traffic_signals"' in q


@pytest.mark.parametrize("text", [
    "137.205,36.695,137.22,36.705",   # 緯度と経度が逆
    "36.705,137.205,36.695,137.22",   # 南北が逆
    "36.3,137.0,36.8,137.6",          # 広すぎる
    "1,2,3",                          # 数が足りない
])
def test_bad_bbox(text):
    with pytest.raises(argparse.ArgumentTypeError):
        eo.parse_bbox(text)


def test_good_bbox():
    assert eo.parse_bbox("36.695,137.205,36.705,137.220") == (36.695, 137.205, 36.705, 137.22)

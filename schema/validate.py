"""schema/examples/ と cloud/data/manual/ が JSON Schema に合っているか確かめる。

使い方（リポジトリの一番上で）:
    pip install jsonschema
    python schema/validate.py

CI でも同じコマンドを動かす。エラーがあれば終了コード1で止まる。
"""
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parent.parent
S = ROOT / "schema"


def load(p: Path):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


registry = Registry()
for p in S.rglob("*.schema.json"):
    sch = load(p)
    Draft202012Validator.check_schema(sch)
    registry = registry.with_resource(sch["$id"], Resource.from_contents(sch))

codes = set(load(S / "reason_codes.json")["codes"])
failed = 0


def check(schema_rel: str, instance, label: str):
    global failed
    v = Draft202012Validator(load(S / schema_rel), registry=registry)
    errs = sorted(v.iter_errors(instance), key=lambda e: list(e.path))
    for e in errs[:5]:
        print(f"NG {label}: {'/'.join(map(str, e.path))} {e.message}")
    failed += bool(errs)


def check_jsonl(schema_rel: str, path: Path):
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.strip():
            obj = json.loads(line)
            check(schema_rel, obj, f"{path.relative_to(ROOT)}:{i}")
            if schema_rel == "decision.schema.json" and obj.get("reason") not in codes:
                global failed
                print(f"NG {path.relative_to(ROOT)}:{i}: reason_codes.json にない理由コード {obj.get('reason')}")
                failed += 1


# デモ範囲（富山市をおおまかに囲む四角）。緯度と経度の取り違え・桁違いを見つけるため。
DEMO_BBOX = {"lat_min": 36.2, "lat_max": 36.9, "lon_min": 136.9, "lon_max": 137.7}


def check_items(items: list, label: str):
    """ID の重複と、位置がデモ範囲の中にあるかを確かめる。"""
    global failed
    ids = [it.get("id") for it in items]
    dup = {i for i in ids if ids.count(i) > 1}
    if dup:
        print(f"NG {label}: ID が重複 {sorted(dup)}")
        failed += 1
    b = DEMO_BBOX
    for it in items:
        lat, lon = it.get("lat"), it.get("lon")
        if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)):
            continue  # 形の誤りは schema の検証で出る
        if not (b["lat_min"] <= lat <= b["lat_max"] and b["lon_min"] <= lon <= b["lon_max"]):
            hint = "（緯度と経度が逆かも）" if b["lat_min"] <= lon <= b["lat_max"] and b["lon_min"] <= lat <= b["lon_max"] else ""
            print(f"NG {label}: {it.get('id')} の位置 ({lat}, {lon}) がデモ範囲の外{hint}")
            failed += 1


# (本物の置き場所, 見本, schema, 中の配列のキー)。本物も見本も同じ規則で確かめる
DATA_FILES = [
    (None, "landmarks_sample.json", "landmarks_file.schema.json", "landmarks"),  # 本物は1件1ファイル（下）
    ("cloud/data/manual/timetable.json", "timetable_sample.json", "timetable_file.schema.json", "stops"),
    ("cloud/data/manual/events.json", "events_sample.json", "events_file.schema.json", "events"),
    ("cloud/data/osm/crossings.json", "crossings_sample.json", "crossings_file.schema.json", "crossings"),
    # 町丁目の代表点（build_address.py の出力）。見本は engine の往復テストの対象外なので towns/ に分けて置く
    ("cloud/data/address/towns.json", "towns/towns_sample.json", "towns_file.schema.json", "towns"),
]

E = S / "examples"
for _, sample, schema_rel, key in DATA_FILES:
    data = load(E / sample)
    check(schema_rel, data, sample)
    check_items(data.get(key, []), sample)

tile = load(E / "tile_response.json")
check("api/tile.response.schema.json", tile, "tile_response.json")
for key in ("landmarks", "stops", "crossings", "events"):
    check_items(tile.get(key, []), f"tile_response.json の {key}")
check("api/visual_search.request.schema.json", load(E / "visual_search_request.json"), "visual_search_request.json")
for k in ("matched", "matched_feature", "unlisted", "unknown", "named"):
    check("api/visual_search.response.schema.json", load(E / f"visual_search_response_{k}.json"), f"visual_search_response_{k}.json")
check_jsonl("eventlog.schema.json", E / "walk_short.jsonl")
check_jsonl("decision.schema.json", E / "decisions_short.jsonl")

# FCM の警報：形を確かめ、さらに mobile が eventlog の alert に直した形も通ることを確かめる
fcm = load(E / "fcm_alert_data.json")
check("fcm/alert.data.schema.json", fcm, "fcm_alert_data.json")
if not any(not isinstance(v, str) for v in fcm.values()) and fcm.get("level", "").isdigit():
    as_event = {
        "schema_version": fcm["schema_version"], "t_ms": 0, "type": "alert",
        "data": {k: fcm[k] for k in ("alert_id", "kind", "area_name", "text")} | {"level": int(fcm["level"])},
    }
    check("eventlog.schema.json", as_event, "fcm_alert_data.json → eventlog の alert")
else:
    print("NG fcm_alert_data.json: FCM の data の値はすべて文字列にする")
    failed += 1

# 今出ている警報の一覧（alert-job → 公開の Cloud Storage → mobile）。
# engine の見本の往復テストの対象外なので、examples/alerts/ に分けて置く
for p in sorted((E / "alerts").glob("*.json")):
    cur = load(p)
    rel = f"alerts/{p.name}"
    check("api/alerts_current.schema.json", cur, rel)
    if p.stem != f"current_{cur.get('area_code')}":
        print(f"NG {rel}: ファイル名は current_<area_code>.json にする")
        failed += 1
    # 一覧の各要素は、FCM の data と同じ読み方（parseAlertData）で読めること
    for i, a in enumerate(cur.get("alerts", [])):
        as_fcm = {"schema_version": cur["schema_version"], "type": "alert", "area_code": cur["area_code"],
                  "area_name": cur["area_name"]} | a
        check("fcm/alert.data.schema.json", as_fcm, f"{rel} の alerts[{i}] を FCM の data の形にしたもの")

# ランドマークの本物は1件1ファイル：cloud/data/manual/landmarks/<ID>.json（ファイル名と id を同じにする）
LM_DIR = ROOT / "cloud" / "data" / "manual" / "landmarks"
if (ROOT / "cloud" / "data" / "manual" / "landmarks.json").exists():
    print("NG cloud/data/manual/landmarks.json: ランドマークは1件1ファイル（cloud/data/manual/landmarks/<ID>.json）に変わりました。分けてください")
    failed += 1
lm_items = []
for p in sorted(LM_DIR.glob("*.json")) if LM_DIR.exists() else []:
    rel = p.relative_to(ROOT).as_posix()
    try:
        data = load(p)
    except json.JSONDecodeError as e:
        print(f"NG {rel}: JSON として読めません（{e.msg}、{e.lineno}行目）")
        failed += 1
        continue
    check("landmark_entry.schema.json", data, rel)
    if isinstance(data, dict):
        if data.get("id") != p.stem:
            print(f"NG {rel}: ファイル名（{p.stem}）と id（{data.get('id')}）を同じにしてください")
            failed += 1
        lm_items.append(data)
check_items(lm_items, "cloud/data/manual/landmarks/")

# カメラで調べない区域（1件1ファイル）。見本は engine の往復テストの対象外なので examples/zones/ に分けて置く
zone_items = []
for d in (E / "zones", ROOT / "cloud" / "data" / "manual" / "zones"):
    for p in sorted(d.glob("*.json")) if d.exists() else []:
        rel = p.relative_to(ROOT).as_posix()
        data = load(p)
        check("zone_entry.schema.json", data, rel)
        if isinstance(data, dict):
            if data.get("id") != p.stem:
                print(f"NG {rel}: ファイル名（{p.stem}）と id（{data.get('id')}）を同じにしてください")
                failed += 1
            zone_items.append(data)
            # タイルに入れる形（schema_version・note・source を外したもの）も通ること
            check("zone.schema.json", {k: v for k, v in data.items() if k not in ("schema_version", "note", "source")},
                  f"{rel} をタイルの形にしたもの")
check_items(zone_items, "zones")

# 登録用のひな形（メンバー4がコピーして使う）
for p in sorted((S / "templates").glob("landmark_*.json")):
    check("landmark_entry.schema.json", load(p), p.relative_to(ROOT).as_posix())

for rel, _, schema_rel, key in DATA_FILES:
    if rel is None:
        continue
    p = ROOT / rel
    if p.exists():
        data = load(p)
        check(schema_rel, data, rel)
        check_items(data.get(key, []), rel)

FIX = ROOT / "app" / "engine" / "test" / "fixtures"
# 実機で録った歩行ログ（メンバー3 → メンバー2 経由で置く）
for p in sorted((FIX / "walks").glob("*.jsonl")):
    check_jsonl("eventlog.schema.json", p)
# engine が歩行ログを再生して書き出した判断ログ（メンバー2のテストが書き出す）
for p in sorted((FIX / "decisions").glob("*.jsonl")):
    check_jsonl("decision.schema.json", p)

if failed:
    print(f"\n{failed} 件の不一致があります")
    sys.exit(1)
print("すべて schema に合っています")

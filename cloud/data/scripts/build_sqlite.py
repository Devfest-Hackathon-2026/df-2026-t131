"""確認済みのデータから、API がタイル単位で配る SQLite（R*Tree つき）を作る。

使い方（リポジトリの一番上で）:
    python cloud/data/scripts/build_sqlite.py              # 本物：cloud/data/manual/ と cloud/data/osm/ から
    python cloud/data/scripts/build_sqlite.py --examples   # 見本：schema/examples/ から（テスト・動作確認用）
    python cloud/data/scripts/build_sqlite.py --out path/to/tiles.sqlite

入力（無いファイルは0件として扱う）:
    cloud/data/manual/landmarks/*.json ランドマーク1件1ファイル（status が reviewed のものだけ入れる。draft は入れない）
    cloud/data/manual/timetable.json   電停と時刻表
    cloud/data/manual/events.json      イベント
    cloud/data/osm/crossings.json      横断歩道・信号（extract_osm.py の出力）
出力:
    cloud/data/build/tiles.sqlite（Git 管理外）

決まり:
  - 入力は最初に schema で検証し、合わなければ「どのファイルの何件目のどこが違うか」を表示して止まる
  - 同じ入力なら同じ DB になる（並び順を ID で固定。作った日時は入れない）
  - タイルへの入れ方：点のもの（ランドマーク・電停・横断歩道・イベント）は位置のあるタイルに、
    エリア（kind: area）は範囲（radius_m）が重なるすべてのタイルに入る（API 側で判定）
"""
import argparse
import hashlib
import json
import math
import sqlite3
import sys
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[3]
SCHEMA = ROOT / "schema"
DEFAULT_OUT = ROOT / "cloud" / "data" / "build" / "tiles.sqlite"

# (種類, schema, 中の配列のキー, 本物の置き場所, 見本)
INPUTS = [
    ("landmark", "landmarks_file.schema.json", "landmarks", "cloud/data/manual/landmarks", "schema/examples/landmarks_sample.json"),
    ("stop", "timetable_file.schema.json", "stops", "cloud/data/manual/timetable.json", "schema/examples/timetable_sample.json"),
    ("event", "events_file.schema.json", "events", "cloud/data/manual/events.json", "schema/examples/events_sample.json"),
    ("crossing", "crossings_file.schema.json", "crossings", "cloud/data/osm/crossings.json", "schema/examples/crossings_sample.json"),
]

M_PER_DEG_LAT = 111_320.0


def _load(p: Path):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def _registry() -> Registry:
    reg = Registry()
    for p in SCHEMA.rglob("*.schema.json"):
        sch = _load(p)
        reg = reg.with_resource(sch["$id"], Resource.from_contents(sch))
    return reg


def validate(rel: str, data, schema_rel: str, key: str, reg: Registry) -> list[str]:
    """schema の検証と ID の重複。エラーを「ファイル: landmarks[3].name_kana …」の形で返す。"""
    v = Draft202012Validator(_load(SCHEMA / schema_rel), registry=reg)
    errors = []
    for e in sorted(v.iter_errors(data), key=lambda e: list(map(str, e.path))):
        path = list(e.path)
        where = ""
        if len(path) >= 2 and path[0] == key and isinstance(path[1], int):
            item = data[key][path[1]]
            ident = item.get("id", "?") if isinstance(item, dict) else "?"
            where = f"{key}[{path[1]}]（{ident}）" + "".join(f".{p}" for p in path[2:])
        else:
            where = ".".join(map(str, path)) or "（ファイル全体）"
        errors.append(f"{rel}: {where}: {e.message}")
    items = data.get(key, []) if isinstance(data, dict) else []
    ids = [it.get("id") for it in items if isinstance(it, dict)]
    for dup in sorted({i for i in ids if ids.count(i) > 1}):
        errors.append(f"{rel}: ID が重複 {dup}")
    return errors


def load_landmark_dir(d: Path, reg: Registry) -> tuple[dict, list[str], bytes]:
    """1件1ファイルのランドマークを集めて landmarks.json と同じ形にする。(データ, エラー, ハッシュ用の中身)"""
    v = Draft202012Validator(_load(SCHEMA / "landmark_entry.schema.json"), registry=reg)
    items, errors, raw_all = [], [], b""
    for p in sorted(d.glob("*.json")):
        rel = p.relative_to(ROOT).as_posix() if p.is_relative_to(ROOT) else str(p)
        raw = p.read_bytes()
        raw_all += rel.encode() + b"\0" + raw + b"\0"
        try:
            item = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as e:
            errors.append(f"{rel}: JSON として読めません（{e.msg}、{e.lineno}行目）")
            continue
        errs = [f"{rel}: {'.'.join(map(str, e.path)) or '（ファイル全体）'}: {e.message}" for e in v.iter_errors(item)]
        if isinstance(item, dict) and item.get("id") != p.stem:
            errs.append(f"{rel}: ファイル名（{p.stem}）と id（{item.get('id')}）を同じにしてください")
        if errs:
            errors += errs
            continue
        items.append({k: val for k, val in item.items() if k != "schema_version"})
    ids = [it["id"] for it in items]
    for dup in sorted({i for i in ids if ids.count(i) > 1}):
        errors.append(f"{d.name}/: ID が重複 {dup}")
    return {"schema_version": "0.3", "landmarks": items}, errors, raw_all


def bbox(kind: str, item: dict) -> tuple[float, float, float, float]:
    """(min_lat, max_lat, min_lon, max_lon)。エリアは半径の分だけ広げる。"""
    lat, lon = item["lat"], item["lon"]
    if kind == "landmark" and item.get("kind") == "area":
        r = float(item["radius_m"])
        dlat = r / M_PER_DEG_LAT
        dlon = r / (M_PER_DEG_LAT * math.cos(math.radians(lat)))
        return lat - dlat, lat + dlat, lon - dlon, lon + dlon
    return lat, lat, lon, lon


def build(out: Path, use_examples: bool = False) -> int:
    reg = _registry()
    errors: list[str] = []
    rows: list[tuple[str, str, str, tuple]] = []  # (種類, id, json, bbox)
    digest = hashlib.sha256()
    counts: dict[str, int] = {}

    for kind, schema_rel, key, real, sample in INPUTS:
        rel = sample if use_examples else real
        p = ROOT / rel
        if not p.exists():
            counts[kind] = 0
            continue
        if p.is_dir():  # ランドマークの1件1ファイル
            data, errs, raw = load_landmark_dir(p, reg)
            digest.update(raw)
        else:
            raw = p.read_bytes()
            digest.update(rel.encode() + b"\0" + raw + b"\0")
            data = json.loads(raw.decode("utf-8"))
            errs = validate(rel, data, schema_rel, key, reg)
        if errs:
            errors += errs
            continue
        items = data[key]
        if kind == "landmark":
            skipped = sum(1 for it in items if it["status"] != "reviewed")
            items = [{k: v for k, v in it.items() if k != "status"} for it in items if it["status"] == "reviewed"]
            if skipped:
                print(f"  {rel}: draft の {skipped} 件は入れません（reviewed だけ）")
        counts[kind] = len(items)
        for it in items:
            rows.append((kind, it["id"], json.dumps(it, ensure_ascii=False, sort_keys=True), bbox(kind, it)))

    if errors:
        print("入力が schema に合いません。SQLite は作りません:")
        for e in errors:
            print(f"  NG {e}")
        return 1
    if counts.get("landmark", 0) == 0:
        print("  注意：reviewed のランドマークが0件です（A は何も話しません）")

    rows.sort(key=lambda r: (r[0], r[1]))
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.unlink(missing_ok=True)
    con = sqlite3.connect(tmp)
    try:
        con.executescript(
            """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE features (
                rowid INTEGER PRIMARY KEY,
                kind  TEXT NOT NULL,   -- landmark / stop / event / crossing
                id    TEXT NOT NULL,
                area  INTEGER NOT NULL, -- 1 ならエリア（範囲が重なるタイルすべてに入る）
                json  TEXT NOT NULL,   -- タイル応答にそのまま入れる形
                UNIQUE (kind, id)
            );
            CREATE VIRTUAL TABLE features_rtree USING rtree(rowid, min_lat, max_lat, min_lon, max_lon);
            """
        )
        for i, (kind, ident, js, (a, b, c, d)) in enumerate(rows, 1):
            is_area = int(kind == "landmark" and json.loads(js).get("kind") == "area")
            con.execute("INSERT INTO features VALUES (?,?,?,?,?)", (i, kind, ident, is_area, js))
            con.execute("INSERT INTO features_rtree VALUES (?,?,?,?,?)", (i, a, b, c, d))
        schema_version = _load(SCHEMA / "examples" / "tile_response.json")["schema_version"]
        con.executemany(
            "INSERT INTO meta VALUES (?,?)",
            [("schema_version", schema_version), ("input_sha256", digest.hexdigest()),
             ("source", "examples" if use_examples else "manual")],
        )
        con.commit()
    finally:
        con.close()
    tmp.replace(out)
    summary = "、".join(f"{k} {v}件" for k, v in counts.items())
    print(f"作りました：{out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}（{summary}）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--examples", action="store_true", help="schema/examples/ の見本から作る")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="出力先（既定：cloud/data/build/tiles.sqlite）")
    args = ap.parse_args()
    return build(args.out.resolve(), args.examples)


if __name__ == "__main__":
    sys.exit(main())

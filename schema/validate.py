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


E = S / "examples"
check("landmarks_file.schema.json", load(E / "landmarks_sample.json"), "landmarks_sample.json")
check("api/tile.response.schema.json", load(E / "tile_response.json"), "tile_response.json")
check("api/visual_search.request.schema.json", load(E / "visual_search_request.json"), "visual_search_request.json")
for k in ("matched", "unlisted", "unknown", "named"):
    check("api/visual_search.response.schema.json", load(E / f"visual_search_response_{k}.json"), f"visual_search_response_{k}.json")
check_jsonl("eventlog.schema.json", E / "walk_short.jsonl")
check_jsonl("decision.schema.json", E / "decisions_short.jsonl")

manual = ROOT / "cloud" / "data" / "manual" / "landmarks.json"
if manual.exists():
    data = load(manual)
    check("landmarks_file.schema.json", data, "cloud/data/manual/landmarks.json")
    ids = [lm.get("id") for lm in data.get("landmarks", [])]
    dup = {i for i in ids if ids.count(i) > 1}
    if dup:
        print(f"NG cloud/data/manual/landmarks.json: ID が重複 {sorted(dup)}")
        failed += 1

walks = ROOT / "app" / "engine" / "test" / "fixtures" / "walks"
if walks.exists():
    for p in sorted(walks.glob("*.jsonl")):
        check_jsonl("eventlog.schema.json", p)

if failed:
    print(f"\n{failed} 件の不一致があります")
    sys.exit(1)
print("すべて schema に合っています")

"""デモの範囲の横断歩道・信号を OpenStreetMap（Overpass API）から取り出す（文脈ゲート用）。

使い方（リポジトリの一番上で）:
    python cloud/data/scripts/extract_osm.py --bbox 36.695,137.205,36.705,137.220
        （南の緯度,西の経度,北の緯度,東の経度）
    python cloud/data/scripts/extract_osm.py --input cloud/data/raw/osm_crossings.json   # 保存済みの応答から（通信なし）

出力:
    cloud/data/osm/crossings.json        （Git 管理。build_sqlite.py が読む）
    cloud/data/raw/osm_crossings.json    （Overpass の応答そのもの。Git 管理外。作り直し用）

決まり:
  - 同じ入力なら同じ ID（cr_0001…）になるよう、OSM のノード ID の順に並べて番号を振る
  - 種類：highway=traffic_signals、または crossing=traffic_signals の横断歩道 → traffic_signals、ほかの highway=crossing → crossing
  - データは © OpenStreetMap contributors（ODbL）。出典を crossings.json に書き、docs/attribution.md にも載せる
"""
import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "cloud" / "data" / "osm" / "crossings.json"
RAW = ROOT / "cloud" / "data" / "raw" / "osm_crossings.json"
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "ambient-narrative-guide/0.1 (DevFest GDGoC Japan Hackathon 2026)"
SCHEMA_VERSION = "0.3"
SOURCE = {
    "title": "© OpenStreetMap contributors",
    "url": "https://www.openstreetmap.org/copyright",
    "license": "ODbL-1.0",
}
# 富山市をおおまかに囲む四角（validate.py の DEMO_BBOX と同じ）。これより広い範囲は取らない
LIMIT_BBOX = (36.2, 136.9, 36.9, 137.7)
MAX_AREA_DEG2 = 0.01  # 約 10km 四方。Overpass に重い問い合わせを投げない


def parse_bbox(text: str) -> tuple[float, float, float, float]:
    try:
        s, w, n, e = (float(v) for v in text.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError("--bbox は「南,西,北,東」の4つの数（例：36.695,137.205,36.705,137.220）")
    if not (s < n and w < e):
        raise argparse.ArgumentTypeError("南 < 北、西 < 東 にしてください（緯度と経度が逆かも）")
    ls, lw, ln, le = LIMIT_BBOX
    if not (ls <= s and n <= ln and lw <= w and e <= le):
        raise argparse.ArgumentTypeError(f"富山市の範囲 {LIMIT_BBOX} の外です（緯度と経度が逆かも）")
    if (n - s) * (e - w) > MAX_AREA_DEG2:
        raise argparse.ArgumentTypeError("範囲が広すぎます（デモルートの周辺だけにしてください）")
    return s, w, n, e


def query(bbox: tuple[float, float, float, float]) -> str:
    b = ",".join(f"{v:.6f}" for v in bbox)
    return (
        "[out:json][timeout:60];\n"
        f'(node["highway"="crossing"]({b});node["highway"="traffic_signals"]({b}););\n'
        "out body;"
    )


def fetch(bbox) -> dict:
    data = urllib.parse.urlencode({"data": query(bbox)}).encode()
    req = urllib.request.Request(OVERPASS_URL, data=data, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=90) as res:
        return json.loads(res.read().decode("utf-8"))


def kind_of(tags: dict) -> str | None:
    if tags.get("highway") == "traffic_signals" or tags.get("crossing") == "traffic_signals":
        return "traffic_signals"
    if tags.get("highway") == "crossing":
        return "crossing"
    return None


def convert(overpass: dict) -> dict:
    nodes = {}
    for el in overpass.get("elements", []):
        if el.get("type") != "node":
            continue
        k = kind_of(el.get("tags", {}))
        if k is None or "lat" not in el or "lon" not in el:
            continue
        nodes[el["id"]] = (round(el["lat"], 7), round(el["lon"], 7), k)  # 同じノードの重複は1つに
    crossings = [
        {"id": f"cr_{i:04d}", "lat": lat, "lon": lon, "kind": k}
        for i, (_, (lat, lon, k)) in enumerate(sorted(nodes.items()), 1)
    ]
    return {"schema_version": SCHEMA_VERSION, "source": SOURCE, "crossings": crossings}


def main() -> int:
    ap = argparse.ArgumentParser(description="OSM から横断歩道・信号を取り出す")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--bbox", type=parse_bbox, help="南,西,北,東（度）")
    g.add_argument("--input", type=Path, help="保存済みの Overpass の応答（通信しない）")
    ap.add_argument("--out", type=Path, default=OUT)
    a = ap.parse_args()

    if a.input:
        overpass = json.loads(a.input.read_text(encoding="utf-8"))
    else:
        print(f"Overpass API に問い合わせます：{a.bbox}")
        overpass = fetch(a.bbox)
        RAW.parent.mkdir(parents=True, exist_ok=True)
        RAW.write_text(json.dumps(overpass, ensure_ascii=False), encoding="utf-8")
        print(f"  応答を保存：{RAW.relative_to(ROOT)}（Git 管理外）")

    out = convert(overpass)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    n_sig = sum(1 for c in out["crossings"] if c["kind"] == "traffic_signals")
    print(f"作りました：{a.out}（横断歩道 {len(out['crossings']) - n_sig} 件、信号 {n_sig} 件）")
    print("次に python schema/validate.py と python cloud/data/scripts/build_sqlite.py で確かめてください")
    return 0


if __name__ == "__main__":
    sys.exit(main())

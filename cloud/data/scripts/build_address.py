"""国土交通省「位置参照情報」の CSV から、町丁目の代表点を取り出して cloud/data/address/towns.json を作る。

使い方（リポジトリの一番上で）:
    python cloud/data/scripts/build_address.py
    python cloud/data/scripts/build_address.py --raw path/to/dir --bbox 36.6610,137.1685,36.7130,137.2195

入力（人がダウンロードして置く。Git 管理外。利用規約への同意も人が行う）:
    cloud/data/raw/address/ の中の CSV（文字コード Shift_JIS）。フォルダの中を下までたどって探す
      大字・町丁目レベル：見出しに「大字町丁目名」がある CSV → 町丁目の代表点（towns.json に入れる）
      街区レベル        ：見出しに「街区符号・地番」がある CSV → 数と、近い代表点で決める方法の当たり具合を表示するだけ
                           （番地・街区は towns.json に入れない）
出力:
    cloud/data/address/towns.json（Git 管理。schema/towns_file.schema.json の形）

決まり:
  - 富山市（市区町村コード 16201）だけ、範囲（--bbox。既定は横断歩道と同じ）の中の代表点だけ
  - 同じ入力なら同じ出力（id の順に並べる。作った日時は入れない）
"""
import argparse
import csv
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from town_lookup import MAX_TOWN_DISTANCE_M, nearest_town  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_RAW = ROOT / "cloud" / "data" / "raw" / "address"
DEFAULT_OUT = ROOT / "cloud" / "data" / "address" / "towns.json"
DEFAULT_BBOX = (36.6610, 137.1685, 36.7130, 137.2195)  # 南, 西, 北, 東（cloud/data/README.md の横断歩道と同じ）
CITY_CODE = "16201"
CITY_NAME = "富山市"
SOURCE = {
    "title": "「位置参照情報」（国土交通省）の大字・町丁目レベルを加工して作成",
    "url": "https://nlftp.mlit.go.jp/isj/",
    "license": "国土交通省 位置参照情報の利用規約（出典を明記）",
}


def read_csv(p: Path) -> list[dict]:
    """Shift_JIS（cp932）の CSV を見出しつきの辞書の並びで読む。"""
    text = p.read_bytes().decode("cp932")
    return list(csv.DictReader(io.StringIO(text)))


def level_of(rows: list[dict]) -> str | None:
    head = set(rows[0]) if rows else set()
    if "大字町丁目名" in head:
        return "town"
    if "街区符号・地番" in head:
        return "block"
    return None


def in_bbox(lat: float, lon: float, bbox) -> bool:
    s, w, n, e = bbox
    return s <= lat <= n and w <= lon <= e


def towns_from(rows: list[dict], bbox) -> list[dict]:
    out = {}
    for r in rows:
        if r.get("市区町村コード", "").strip() != CITY_CODE and r.get("市区町村名", "").strip() != CITY_NAME:
            continue
        try:
            lat, lon = float(r["緯度"]), float(r["経度"])
        except (KeyError, ValueError):
            continue
        if not in_bbox(lat, lon, bbox):
            continue
        code = r.get("大字町丁目コード", "").strip()
        name = r.get("大字町丁目名", "").strip()
        if len(code) != 12 or not code.isdigit() or not name:
            continue
        out[code] = {"id": code, "name": name, "lat": round(lat, 6), "lon": round(lon, 6)}
    return [out[k] for k in sorted(out)]


def blocks_from(rows: list[dict], bbox) -> list[dict]:
    """街区の代表点（町丁目の名前と位置だけ。番地は使わない）。"""
    out = []
    for r in rows:
        if r.get("市区町村名", "").strip() != CITY_NAME:
            continue
        try:
            lat, lon = float(r["緯度"]), float(r["経度"])
        except (KeyError, ValueError):
            continue
        if in_bbox(lat, lon, bbox):
            out.append({"town": r.get("大字・丁目名", "").strip(), "lat": lat, "lon": lon})
    return out


def check_with_blocks(towns: list[dict], blocks: list[dict]) -> tuple[int, int, int]:
    """街区の代表点ごとに「近い代表点で決めた町丁目」が、その街区の本当の町丁目と合うか。(合う, 違う, わからない)"""
    ok = ng = unknown = 0
    for b in blocks:
        got = nearest_town(b["lat"], b["lon"], towns)
        if got is None:
            unknown += 1
        elif got["name"] == b["town"]:
            ok += 1
        else:
            ng += 1
    return ok, ng, unknown


def build(raw: Path, out: Path, bbox) -> int:
    files = sorted(p for p in raw.rglob("*") if p.suffix.lower() == ".csv") if raw.exists() else []
    if not files:
        print(f"CSV がありません：{raw}")
        print("  国土交通省「位置参照情報ダウンロードサービス」から富山市（16201）の")
        print("  大字・町丁目レベルと街区レベルを取り、展開してここに置いてください（cloud/data/README.md）")
        return 1
    towns, blocks = [], []
    for p in files:
        rows = read_csv(p)
        lv = level_of(rows)
        if lv == "town":
            towns += towns_from(rows, bbox)
        elif lv == "block":
            blocks += blocks_from(rows, bbox)
        else:
            print(f"  読み飛ばし（見出しが位置参照情報の形ではない）：{p.name}")
    if not towns:
        print("範囲の中に町丁目の代表点がありません（大字・町丁目レベルの CSV があるか確かめてください）")
        return 1
    towns = sorted({t["id"]: t for t in towns}.values(), key=lambda t: t["id"])
    out.parent.mkdir(parents=True, exist_ok=True)
    data = {"schema_version": "0.3", "source": SOURCE, "bbox": list(bbox), "towns": towns}
    out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"作りました：{out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}（町丁目 {len(towns)} 件）")
    if blocks:
        ok, ng, unk = check_with_blocks(towns, blocks)
        n = len(blocks)
        print(f"  街区の代表点 {n} 件で確かめ：合う {ok}（{ok * 100 // n}%）・違う {ng}・わからない {unk}"
              f"（{MAX_TOWN_DISTANCE_M:.0f}m より遠い）")
    else:
        print("  街区レベルの CSV が無いので、当たり具合は確かめていません")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raw", type=Path, default=DEFAULT_RAW)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--bbox", default=",".join(map(str, DEFAULT_BBOX)), help="南,西,北,東")
    a = ap.parse_args()
    bbox = tuple(float(x) for x in a.bbox.split(","))
    return build(a.raw, a.out, bbox)


if __name__ == "__main__":
    sys.exit(main())

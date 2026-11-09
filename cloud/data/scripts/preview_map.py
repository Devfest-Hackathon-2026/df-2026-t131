"""登録したランドマーク・イベント・横断歩道を地図に並べた確認用の HTML を作る（メンバー1）。

    python cloud/data/scripts/preview_map.py
    → cloud/data/build/preview.html（Git 管理外）をブラウザで開く

読むのは manual/landmarks/*.json・manual/events.json・osm/crossings.json だけ（標準ライブラリだけで動く）。
地図の背景は地理院タイル（標準地図・航空写真。表示にネット接続が要る）。
"""
import argparse
import json
from pathlib import Path

DATA = Path(__file__).resolve().parents[1]
OUT = DATA / "build" / "preview.html"
# docs/design.md 17.5 のジオフェンス半径（既定）。radius_m が無いランドマークに使う
DEFAULT_GEOFENCE_M = 25
# 横断歩道・信号を取り出した範囲（cloud/data/README.md の --bbox）
CROSSING_BBOX = (36.6610, 137.1685, 36.7130, 137.2195)


def load() -> dict:
    landmarks = []
    for p in sorted((DATA / "manual" / "landmarks").glob("*.json")):
        d = json.loads(p.read_text(encoding="utf-8"))
        landmarks.append({
            "id": d["id"], "name": d["name"], "kind": d["kind"], "lat": d["lat"], "lon": d["lon"],
            "radius_m": d.get("radius_m") or DEFAULT_GEOFENCE_M, "radius_set": d.get("radius_m") is not None,
            "status": d.get("status"), "script_short": d.get("script_short", ""),
            "visual_hint": d.get("visual_hint") or "", "file": p.name,
        })
    ev_path = DATA / "manual" / "events.json"
    events = json.loads(ev_path.read_text(encoding="utf-8"))["events"] if ev_path.exists() else []
    cr_path = DATA / "osm" / "crossings.json"
    crossings = json.loads(cr_path.read_text(encoding="utf-8"))["crossings"] if cr_path.exists() else []
    return {
        "landmarks": landmarks,
        "events": [{k: e.get(k) for k in ("id", "name", "lat", "lon", "status")} for e in events],
        "crossings": [[c["lat"], c["lon"], c["kind"]] for c in crossings],
        "crossing_bbox": CROSSING_BBOX,
    }


HTML = """<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>登録地点の確認</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
  html, body { margin: 0; height: 100%; font-family: system-ui, sans-serif; }
  #map { position: absolute; inset: 0; }
  .panel { position: absolute; top: 10px; left: 50px; z-index: 1000; background: #fff; padding: 8px 12px;
           border-radius: 6px; box-shadow: 0 1px 4px rgba(0,0,0,.3); font-size: 13px; max-width: 320px; }
  .panel h1 { font-size: 14px; margin: 0 0 4px; }
  .panel ul { margin: 4px 0 0; padding-left: 18px; }
  .panel li { cursor: pointer; }
  .panel li:hover { text-decoration: underline; }
  .sw { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 4px; vertical-align: middle; }
  .popup b { font-size: 14px; } .popup .meta { color: #555; font-size: 12px; } .popup p { margin: 6px 0 0; }
</style></head>
<body>
<div id="map"></div>
<div class="panel">
  <h1>登録地点の確認（__COUNTS__）</h1>
  <div><span class="sw" style="background:#d62728"></span>ランドマーク（円＝範囲）
       <span class="sw" style="background:#9467bd;margin-left:8px"></span>イベント</div>
  <div><span class="sw" style="background:#1f77b4"></span>信号 <span class="sw" style="background:#2ca02c;margin-left:8px"></span>横断歩道
       <span style="margin-left:8px;border:1px dashed #555;padding:0 4px">取得範囲</span></div>
  <ul id="list"></ul>
</div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const D = __DATA__;
const map = L.map('map', { preferCanvas: true });
// 背景は地理院タイル（OSM のタイルは file:// から開くと Referer が無く「Access blocked」になるため）。
// 点のデータ（横断歩道・信号の位置）は OpenStreetMap
const gsi = L.tileLayer('https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png', {
  maxZoom: 18, attribution: '<a href="https://maps.gsi.go.jp/development/ichiran.html">地理院タイル</a>'
}).addTo(map);
const photo = L.tileLayer('https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg', {
  maxZoom: 18, attribution: '<a href="https://maps.gsi.go.jp/development/ichiran.html">地理院タイル</a>（全国最新写真）'
});
map.attributionControl.addAttribution('点のデータ &copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors');
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

const crossings = L.layerGroup(D.crossings.map(([lat, lon, kind]) => L.circleMarker([lat, lon], {
  radius: 3, weight: 0, fillOpacity: .8, fillColor: kind === 'traffic_signals' ? '#1f77b4' : '#2ca02c'
}).bindTooltip(kind === 'traffic_signals' ? '信号' : '横断歩道'))).addTo(map);
const [s, w, n, e] = D.crossing_bbox;
const bbox = L.rectangle([[s, w], [n, e]], { color: '#555', weight: 1, dashArray: '4 4', fill: false }).addTo(map);

const lmLayer = L.layerGroup().addTo(map), list = document.getElementById('list'), markers = {};
for (const l of D.landmarks) {
  const pop = `<div class="popup"><b>${esc(l.name)}</b> <span class="meta">${esc(l.id)}・${esc(l.kind)}・${esc(l.status)}</span>
    <div class="meta">範囲 ${l.radius_m} m${l.radius_set ? '' : '（既定）'}・${l.lat.toFixed(6)}, ${l.lon.toFixed(6)}・${esc(l.file)}</div>
    <p>${esc(l.script_short)}</p>${l.visual_hint ? `<p class="meta">見た目：${esc(l.visual_hint)}</p>` : ''}</div>`;
  L.circle([l.lat, l.lon], { radius: l.radius_m, color: '#d62728', weight: 1, fillOpacity: .12 }).addTo(lmLayer);
  markers[l.id] = L.circleMarker([l.lat, l.lon], { radius: 7, color: '#fff', weight: 2, fillColor: '#d62728', fillOpacity: 1 })
    .bindPopup(pop).bindTooltip(l.name, { permanent: true, direction: 'right', offset: [8, 0] }).addTo(lmLayer);
  const li = document.createElement('li');
  li.textContent = `${l.id} ${l.name}`;
  li.onclick = () => { map.setView([l.lat, l.lon], 17); markers[l.id].openPopup(); };
  list.appendChild(li);
}
const evLayer = L.layerGroup(D.events.map(ev => L.circleMarker([ev.lat, ev.lon], {
  radius: 7, color: '#fff', weight: 2, fillColor: '#9467bd', fillOpacity: 1
}).bindPopup(`<div class="popup"><b>${esc(ev.name)}</b><div class="meta">${esc(ev.id)}・${esc(ev.status)}</div></div>`))).addTo(map);

L.control.layers({ '地図': gsi, '航空写真': photo }, { 'ランドマーク': lmLayer, 'イベント': evLayer, '横断歩道・信号': crossings, '取得範囲': bbox },
  { collapsed: false, position: 'topright' }).addTo(map);
const pts = D.landmarks.map(l => [l.lat, l.lon]);
map.fitBounds(pts.length ? L.latLngBounds(pts).pad(0.15) : bbox.getBounds());
</script>
</body></html>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description="登録地点の確認用の地図（HTML）を作る")
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()
    data = load()
    counts = f"ランドマーク {len(data['landmarks'])}・イベント {len(data['events'])}・横断歩道と信号 {len(data['crossings'])}"
    # </script> を含む文字列で script が途切れないようにする
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(HTML.replace("__DATA__", payload).replace("__COUNTS__", counts), encoding="utf-8")
    print(f"作りました：{args.out}（{counts}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""位置 → 町丁目（いちばん近い代表点）。build_address.py・build_sqlite.py・テストで使う。

位置参照情報は町の「形」ではなく「代表点」なので、いちばん近い代表点の町丁目とみなす。
代表点が遠すぎる（既定 800m より遠い）ときは「わからない」（None）を返し、もっともらしい住所を作らない。
返すのは町丁目まで。番地・街区は扱わない。
"""
import math

MAX_TOWN_DISTANCE_M = 800.0
M_PER_DEG_LAT = 111_320.0


def distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """近い2点の距離（m）。町の中の距離なので平面で近似する。"""
    dy = (lat2 - lat1) * M_PER_DEG_LAT
    dx = (lon2 - lon1) * M_PER_DEG_LAT * math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot(dx, dy)


def nearest_town(lat: float, lon: float, towns: list[dict], max_m: float = MAX_TOWN_DISTANCE_M) -> dict | None:
    """いちばん近い代表点の町丁目 {"id","name","distance_m"}。max_m より遠ければ None。

    距離が同じなら id の小さい方（同じ入力なら必ず同じ答え）。
    """
    best = None
    for t in towns:
        d = distance_m(lat, lon, t["lat"], t["lon"])
        key = (d, t["id"])
        if best is None or key < best[0]:
            best = (key, t)
    if best is None or best[0][0] > max_m:
        return None
    (d, _), t = best
    return {"id": t["id"], "name": t["name"], "distance_m": round(d, 1)}

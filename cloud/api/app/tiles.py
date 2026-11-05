"""XYZ タイル（z16 固定）の計算。"""
import math

from .settings import TILE_ZOOM

N = 2**TILE_ZOOM


def tile_bounds(x: int, y: int) -> tuple[float, float, float, float]:
    """タイルの (south, north, west, east)。度。"""
    def lat(yy: int) -> float:
        return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * yy / N))))

    west = x / N * 360.0 - 180.0
    east = (x + 1) / N * 360.0 - 180.0
    return lat(y + 1), lat(y), west, east


def tile_of(lat: float, lon: float) -> tuple[int, int]:
    """位置が入るタイルの (x, y)。"""
    x = int((lon + 180.0) / 360.0 * N)
    r = math.radians(lat)
    y = int((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * N)
    return min(max(x, 0), N - 1), min(max(y, 0), N - 1)

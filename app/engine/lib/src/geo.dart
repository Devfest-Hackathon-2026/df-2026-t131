import 'dart:math' as math;

import 'models.dart';

/// 地球の平均半径（m）。デモの範囲（数km）では平面近似で十分な精度になる。
const earthRadiusM = 6371008.8;

double degToRad(double deg) => deg * math.pi / 180;
double radToDeg(double rad) => rad * 180 / math.pi;

/// 方位を 0以上360未満 に直す。
double normalizeDeg(double deg) {
  final value = deg % 360;
  return value < 0 ? value + 360 : value;
}

/// 2つの方位の差（-180より大きく180以下）。b から見た a の向き。
double angleDiffDeg(double a, double b) {
  final diff = normalizeDeg(a - b);
  return diff > 180 ? diff - 360 : diff;
}

/// 平面上の点（m）。x は東、y は北。
final class Vec2 {
  final double x, y;
  const Vec2(this.x, this.y);
  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double k) => Vec2(x * k, y * k);
  double dot(Vec2 o) => x * o.x + y * o.y;
  double get length => math.sqrt(x * x + y * y);

  /// 真北0°・時計回りの方位。
  double get bearingDeg => normalizeDeg(radToDeg(math.atan2(x, y)));
}

/// 最初の測位点を原点にした平面（正距円筒図法）。歩く範囲では誤差は無視できる。
final class LocalProjection {
  final double originLat, originLon;
  final double _cosLat;
  LocalProjection(this.originLat, this.originLon)
    : _cosLat = math.cos(degToRad(originLat));

  Vec2 toLocal(double lat, double lon) => Vec2(
    degToRad(lon - originLon) * earthRadiusM * _cosLat,
    degToRad(lat - originLat) * earthRadiusM,
  );

  (double lat, double lon) toLatLon(Vec2 p) => (
    originLat + radToDeg(p.y / earthRadiusM),
    originLon + radToDeg(p.x / (earthRadiusM * _cosLat)),
  );
}

/// 進行方向（真北0°・時計回り）と速さから速度ベクトルを作る。
Vec2 velocityFromCourse(double speedMps, double courseDeg) {
  final rad = degToRad(courseDeg);
  return Vec2(speedMps * math.sin(rad), speedMps * math.cos(rad));
}

/// 緯度経度を含む XYZ タイル（z16 固定）。
TileId tileAt(double lat, double lon, {int z = 16}) {
  final n = 1 << z;
  final latRad = degToRad(lat.clamp(-85.05112878, 85.05112878));
  final x = ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
  final y =
      ((1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
              2 *
              n)
          .floor()
          .clamp(0, n - 1);
  return TileId(z: z, x: x, y: y);
}

/// 判断ログの target_id に使うタイルの表記（例 16/57746/25576）。
String tileKey(TileId tile) => '${tile.z}/${tile.x}/${tile.y}';

import 'package:geolocator/geolocator.dart';

import '../config.dart';

/// 1回分の測位結果。
class LocationFix {
  const LocationFix({
    required this.lat,
    required this.lon,
    required this.accM,
    required this.speedMps,
    required this.courseDeg,
    required this.altM,
  });

  final double lat;
  final double lon;
  final double accM;

  /// 速度が取れないときは null。
  final double? speedMps;

  /// 進行方向（真北0°・時計回り）。遅いとき・取れないときは null。
  final double? courseDeg;
  final double? altM;
}

/// 位置の入力。差し替えられるように mobile 側でインターフェースを持つ。
abstract class LocationSource {
  Stream<LocationFix> get fixes;
}

/// 速度を整える。負（取れない）なら null。
double? normalizeSpeed(bool hasSpeed, double speed) =>
    (!hasSpeed || speed.isNaN || speed < 0) ? null : speed;

/// 進行方向を整える。速度が [AppConfig.minSpeedForCourseMps] 未満・
/// 方位が取れない・範囲外なら null（engine は null のとき自分で推定する）。
double? normalizeCourse({
  required double? speedMps,
  required bool hasHeading,
  required double heading,
}) {
  if (speedMps == null || speedMps < AppConfig.minSpeedForCourseMps) {
    return null;
  }
  if (!hasHeading || heading.isNaN || heading < 0 || heading > 360) return null;
  return heading == 360 ? 0 : heading;
}

LocationFix fixFromPosition(Position p) {
  final speed = normalizeSpeed(p.hasSpeed, p.speed);
  return LocationFix(
    lat: p.latitude,
    lon: p.longitude,
    accM: p.accuracy,
    speedMps: speed,
    courseDeg: normalizeCourse(
      speedMps: speed,
      hasHeading: p.hasHeading,
      heading: p.heading,
    ),
    altM: p.hasAltitude ? p.altitude : null,
  );
}

/// Fused Location で 1 秒ごとに測位する。
class GeolocatorLocationSource implements LocationSource {
  @override
  Stream<LocationFix> get fixes => Geolocator.getPositionStream(
    locationSettings: AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
      intervalDuration: AppConfig.sensorTick,
    ),
  ).map(fixFromPosition);
}

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../app/session_controller.dart' show haversineM;
import '../sources/location_source.dart';
import '../ui/glass_overlay.dart' show bearingBetween;

/// 緯度経度1点。
class LatLon {
  const LatLon(this.lat, this.lon);
  final double lat;
  final double lon;
}

/// フェイク GPS で流す道のり。t は「等倍で再生したときの秒」。
abstract class FakeTrack {
  String get name;

  /// 等倍で最後まで流したときの秒数。
  double get durationS;

  /// 道のり全体の長さ（メートル）。
  double get lengthM;

  /// t 秒の時点の位置。[moving] が false なら止まっている扱い（速度 0、進行方向なし）。
  /// [speedFactor] は再生の倍速（道を進む速さに掛ける）。
  LocationFix fixAt(double t, {required bool moving, double speedFactor = 1});

  /// t 秒の時点の進行方向（止まっていても向きは残す。視線を進行方向に合わせるときに使う）。
  double headingAt(double t);

  /// t 秒までに進んだ距離（メートル）。
  double distanceAt(double t);
}

/// 経由点を一定の速さで歩く道のり（デモルートなど）。
class RouteTrack implements FakeTrack {
  RouteTrack(this.name, this.points, {this.walkSpeedMps = 1.3, this.accM = 5})
    : assert(points.length >= 2) {
    var sum = 0.0;
    _cum.add(0);
    for (var i = 1; i < points.length; i++) {
      sum += haversineM(
        points[i - 1].lat,
        points[i - 1].lon,
        points[i].lat,
        points[i].lon,
      );
      _cum.add(sum);
    }
  }

  @override
  final String name;
  final List<LatLon> points;
  final double walkSpeedMps;
  final double accM;
  final _cum = <double>[];

  @override
  double get lengthM => _cum.last;

  @override
  double get durationS => lengthM / walkSpeedMps;

  @override
  double distanceAt(double t) => (t * walkSpeedMps).clamp(0, lengthM);

  int _segment(double d) {
    for (var i = 1; i < _cum.length; i++) {
      if (d <= _cum[i]) return i - 1;
    }
    return _cum.length - 2;
  }

  @override
  double headingAt(double t) {
    final i = _segment(distanceAt(t));
    return bearingBetween(
      points[i].lat,
      points[i].lon,
      points[i + 1].lat,
      points[i + 1].lon,
    );
  }

  @override
  LocationFix fixAt(double t, {required bool moving, double speedFactor = 1}) {
    final d = distanceAt(t);
    final i = _segment(d);
    final segLen = _cum[i + 1] - _cum[i];
    final f = segLen == 0 ? 0.0 : (d - _cum[i]) / segLen;
    final a = points[i];
    final b = points[i + 1];
    final atEnd = d >= lengthM;
    final speed = moving && !atEnd ? walkSpeedMps * speedFactor : 0.0;
    return LocationFix(
      lat: a.lat + (b.lat - a.lat) * f,
      lon: a.lon + (b.lon - a.lon) * f,
      accM: accM,
      speedMps: speed,
      courseDeg: speed > 0 ? headingAt(t) : null,
      altM: null,
    );
  }
}

/// 保存した歩行ログ（sensor 行）を1秒1行で流し直す。外で一度歩けば、同じ道を机で何度でも試せる。
class LogTrack implements FakeTrack {
  LogTrack(this.name, this.fixes) : assert(fixes.isNotEmpty) {
    var sum = 0.0;
    _cum.add(0);
    for (var i = 1; i < fixes.length; i++) {
      sum += haversineM(
        fixes[i - 1].lat,
        fixes[i - 1].lon,
        fixes[i].lat,
        fixes[i].lon,
      );
      _cum.add(sum);
    }
  }

  @override
  final String name;
  final List<LocationFix> fixes;
  final _cum = <double>[];

  /// 歩行ログ（JSONL）から sensor 行の位置だけを読む。読めない行は飛ばす。
  static Future<LogTrack?> load(File file) async {
    final out = <LocationFix>[];
    for (final line in await file.readAsLines()) {
      final fix = parseSensorLine(line);
      if (fix != null) out.add(fix);
    }
    if (out.isEmpty) return null;
    return LogTrack(file.uri.pathSegments.last, out);
  }

  static LocationFix? parseSensorLine(String line) {
    try {
      final row = jsonDecode(line);
      if (row is! Map || row['type'] != 'sensor') return null;
      final d = row['data'];
      if (d is! Map) return null;
      double? n(Object? v) => v is num ? v.toDouble() : null;
      final lat = n(d['lat']);
      final lon = n(d['lon']);
      if (lat == null || lon == null) return null;
      return LocationFix(
        lat: lat,
        lon: lon,
        accM: n(d['acc_m']) ?? 10,
        speedMps: n(d['speed_mps']),
        courseDeg: n(d['course_deg']),
        altM: null,
      );
    } catch (_) {
      return null;
    }
  }

  int _index(double t) => t.floor().clamp(0, fixes.length - 1);

  @override
  double get durationS => (fixes.length - 1).toDouble();

  @override
  double get lengthM => _cum.last;

  @override
  double distanceAt(double t) => _cum[_index(t)];

  @override
  double headingAt(double t) {
    final i = _index(t);
    final c = fixes[i].courseDeg;
    if (c != null) return c;
    // 進行方向が無い行は、次の点（最後なら前の点）への向きを出す
    final from = fixes[i + 1 < fixes.length ? i : math.max(i - 1, 0)];
    final to = fixes[i + 1 < fixes.length ? i + 1 : i];
    return bearingBetween(from.lat, from.lon, to.lat, to.lon);
  }

  @override
  LocationFix fixAt(double t, {required bool moving, double speedFactor = 1}) {
    final f = fixes[_index(t)];
    if (moving) return f;
    return LocationFix(
      lat: f.lat,
      lon: f.lon,
      accM: f.accM,
      speedMps: 0,
      courseDeg: null,
      altM: f.altM,
    );
  }
}

/// デモルート：富山駅（北口）→ ゴールドジムと富山市総合体育館の間の歩道 → 天門橋。
/// 経由点は map/manual/route.json と同じ。駅と天門橋はおおよその位置（開発用）。
final demoRouteToyama = RouteTrack('デモルート（富山駅 → 天門橋）', const [
  LatLon(36.70220, 137.21330), // 富山駅 北口
  LatLon(36.70420, 137.21380),
  LatLon(36.70705, 137.21512), // ゴールドジムと富山市総合体育館の間（route.json）
  LatLon(36.70950, 137.21470),
  LatLon(36.71150, 137.21410), // 天門橋
]);

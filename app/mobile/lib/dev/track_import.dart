import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import '../app/session_controller.dart' show haversineM;
import '../config.dart';
import '../sources/location_source.dart';
import '../ui/glass_overlay.dart' show bearingBetween;
import 'fake_track.dart';

/// 読めなかったときの理由（画面に出す）。
class TrackImportError implements Exception {
  const TrackImportError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 点1つ（時刻は無いこともある）。
class TrackPoint {
  const TrackPoint(this.lat, this.lon, [this.time]);
  final double lat;
  final double lon;
  final DateTime? time;
}

/// 検証用の GPS データを読む。読める形式：
/// - GPX（`<trkpt>` か `<rtept>`。時刻があれば、その速さのまま流す）
/// - GeoJSON（LineString・MultiLineString・Point の並び）
/// - JSON（`{"points":[{"lat":..,"lon":..}]}` や `[[lat, lon], ...]`、route.json の waypoints）
/// - CSV（1行に `lat,lon` か `lat,lon,ISO8601時刻`。見出し行は飛ばす）
/// - 歩行ログ（.jsonl、このアプリが記録したもの）
///
/// 時刻が無い道のりは、[walkSpeedMps] で歩く。
class TrackImporter {
  const TrackImporter({this.walkSpeedMps = 1.3});

  final double walkSpeedMps;

  static const extensions = ['.gpx', '.geojson', '.json', '.csv', '.jsonl'];

  static bool supports(String name) =>
      extensions.any((e) => name.toLowerCase().endsWith(e));

  Future<FakeTrack> loadFile(File file) async {
    final name = file.uri.pathSegments.last;
    final text = await file.readAsString();
    return parse(name, text);
  }

  FakeTrack parse(String name, String text) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jsonl')) {
      final fixes = [
        for (final line in const LineSplitter().convert(text))
          ?LogTrack.parseSensorLine(line),
      ];
      if (fixes.isEmpty) throw const TrackImportError('sensor 行がありません');
      return LogTrack(name, fixes);
    }
    final List<TrackPoint> points;
    if (lower.endsWith('.gpx')) {
      points = parseGpx(text);
    } else if (lower.endsWith('.csv')) {
      points = parseCsv(text);
    } else {
      points = parseJson(text);
    }
    return build(name, points);
  }

  /// 点の並びから道のりを作る。全部の点に時刻があれば時刻どおり、無ければ一定の速さで歩く。
  FakeTrack build(String name, List<TrackPoint> points) {
    if (points.length < 2) {
      throw const TrackImportError('点が2つ以上ありません');
    }
    final timed = points.every((p) => p.time != null);
    if (timed) {
      final fixes = resampleTimed(points);
      if (fixes.length >= 2) return LogTrack(name, fixes);
    }
    // 同じ点が続くと長さ0の区間になるので除く
    final dedup = <LatLon>[];
    for (final p in points) {
      if (dedup.isEmpty ||
          haversineM(dedup.last.lat, dedup.last.lon, p.lat, p.lon) > 0.01) {
        dedup.add(LatLon(p.lat, p.lon));
      }
    }
    if (dedup.length < 2) throw const TrackImportError('動いていない道のりです');
    return RouteTrack(name, dedup, walkSpeedMps: walkSpeedMps);
  }

  /// 時刻付きの点を1秒ごとの位置に並べ直す（間は直線で補う）。速度と進行方向は動きから出す。
  static List<LocationFix> resampleTimed(List<TrackPoint> points) {
    final pts = [...points]..sort((a, b) => a.time!.compareTo(b.time!));
    final t0 = pts.first.time!;
    double sec(TrackPoint p) => p.time!.difference(t0).inMilliseconds / 1000;
    final end = sec(pts.last);
    if (end < 1) return const [];
    // 長すぎるデータで端末を固めない（3時間まで）
    final n = math.min(end.floor(), 3 * 3600);
    final lat = <double>[];
    final lon = <double>[];
    var j = 0;
    for (var s = 0; s <= n; s++) {
      while (j < pts.length - 2 && sec(pts[j + 1]) < s) {
        j++;
      }
      final a = pts[j];
      final b = pts[j + 1];
      final span = sec(b) - sec(a);
      final f = span <= 0 ? 0.0 : ((s - sec(a)) / span).clamp(0.0, 1.0);
      lat.add(a.lat + (b.lat - a.lat) * f);
      lon.add(a.lon + (b.lon - a.lon) * f);
    }
    return [
      for (var i = 0; i < lat.length; i++)
        () {
          final k = i == 0 ? 1 : i;
          final speed = haversineM(lat[k - 1], lon[k - 1], lat[k], lon[k]);
          return LocationFix(
            lat: lat[i],
            lon: lon[i],
            accM: 5,
            speedMps: speed,
            courseDeg: speed >= AppConfig.minSpeedForCourseMps
                ? bearingBetween(lat[k - 1], lon[k - 1], lat[k], lon[k])
                : null,
            altM: null,
          );
        }(),
    ];
  }

  // ---- 形式ごとの読み取り ----

  static final _gpxPoint = RegExp(
    r'<(trkpt|rtept)\b([^>]*?)(/>|>([\s\S]*?)</\1>)',
  );
  static final _attrLat = RegExp(r'''\blat\s*=\s*["']([-+\d.eE]+)["']''');
  static final _attrLon = RegExp(r'''\blon\s*=\s*["']([-+\d.eE]+)["']''');
  static final _gpxTime = RegExp(r'<time>\s*([^<]+?)\s*</time>');

  static List<TrackPoint> parseGpx(String text) {
    final out = <TrackPoint>[];
    for (final m in _gpxPoint.allMatches(text)) {
      final attrs = m.group(2) ?? '';
      final lat = double.tryParse(_attrLat.firstMatch(attrs)?.group(1) ?? '');
      final lon = double.tryParse(_attrLon.firstMatch(attrs)?.group(1) ?? '');
      if (lat == null || lon == null || !_valid(lat, lon)) continue;
      final body = m.group(4) ?? '';
      final time = DateTime.tryParse(_gpxTime.firstMatch(body)?.group(1) ?? '');
      out.add(TrackPoint(lat, lon, time));
    }
    if (out.isEmpty) throw const TrackImportError('GPX に trkpt・rtept がありません');
    return out;
  }

  static List<TrackPoint> parseCsv(String text) {
    final out = <TrackPoint>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final cells = line.split(RegExp(r'[,\t;]')).map((c) => c.trim()).toList();
      if (cells.length < 2) continue;
      final lat = double.tryParse(cells[0]);
      final lon = double.tryParse(cells[1]);
      if (lat == null || lon == null || !_valid(lat, lon)) continue; // 見出し行など
      final time = cells.length > 2 ? DateTime.tryParse(cells[2]) : null;
      out.add(TrackPoint(lat, lon, time));
    }
    if (out.isEmpty) throw const TrackImportError('CSV に lat,lon の行がありません');
    return out;
  }

  static List<TrackPoint> parseJson(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const TrackImportError('JSON として読めません');
    }
    final out = <TrackPoint>[];
    _collect(json, out);
    if (out.isEmpty) throw const TrackImportError('JSON に位置（lat・lon）がありません');
    return out;
  }

  /// GeoJSON・点の配列・route.json などから、出てきた順に点を集める。
  static void _collect(Object? node, List<TrackPoint> out) {
    if (node is List) {
      for (final e in node) {
        _collect(e, out);
      }
      return;
    }
    if (node is! Map) return;
    final type = node['type'];
    if (type == 'FeatureCollection') return _collect(node['features'], out);
    if (type == 'Feature') return _collect(node['geometry'], out);
    if (type == 'LineString' || type == 'MultiPoint') {
      return _addLonLatList(node['coordinates'], out);
    }
    if (type == 'MultiLineString') {
      for (final line in node['coordinates'] as List? ?? const []) {
        _addLonLatList(line, out);
      }
      return;
    }
    if (type == 'Point') {
      final c = node['coordinates'];
      if (c is List && c.length >= 2) _addLonLatList([c], out);
      return;
    }
    // {"lat":..,"lon":..} の1点（lng・longitude・latitude も読む）
    final lat = _num(node['lat'] ?? node['latitude']);
    final lon = _num(node['lon'] ?? node['lng'] ?? node['longitude']);
    if (lat != null && lon != null && _valid(lat, lon)) {
      final t = node['time'] ?? node['timestamp'];
      out.add(TrackPoint(lat, lon, t is String ? DateTime.tryParse(t) : null));
      return;
    }
    // 包んでいるキー（points・waypoints・track など）を順に見る
    for (final key in const [
      'points',
      'waypoints',
      'track',
      'route',
      'coordinates',
    ]) {
      final v = node[key];
      if (v is List) {
        if (key == 'coordinates') return _addLatLonPairs(v, out);
        return _collect(v, out);
      }
    }
  }

  /// GeoJSON の [経度, 緯度] の並び。
  static void _addLonLatList(Object? list, List<TrackPoint> out) {
    if (list is! List) return;
    for (final c in list) {
      if (c is List && c.length >= 2) {
        final lon = _num(c[0]);
        final lat = _num(c[1]);
        if (lat != null && lon != null && _valid(lat, lon)) {
          out.add(TrackPoint(lat, lon));
        }
      }
    }
  }

  /// [緯度, 経度] の並び（GeoJSON でない配列）。
  static void _addLatLonPairs(List<Object?> list, List<TrackPoint> out) {
    for (final c in list) {
      if (c is List && c.length >= 2) {
        final lat = _num(c[0]);
        final lon = _num(c[1]);
        if (lat != null && lon != null && _valid(lat, lon)) {
          out.add(TrackPoint(lat, lon));
        }
      } else {
        _collect(c, out);
      }
    }
  }

  static double? _num(Object? v) =>
      v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

  static bool _valid(double lat, double lon) =>
      lat.abs() <= 90 && lon.abs() <= 180 && !(lat == 0 && lon == 0);
}

/// 端末に置いた検証用データの一覧。置き場所はアプリ専用フォルダの `test_tracks`。
/// PC から `adb push 〇〇.gpx /sdcard/Android/data/jp.dfhack26.mobile/files/test_tracks/` で置く。
class TestTrackStore {
  TestTrackStore([Future<Directory> Function()? directory])
    : _directory = directory ?? defaultDirectory;

  final Future<Directory> Function() _directory;

  static const folderName = 'test_tracks';

  static Future<Directory> defaultDirectory() async {
    final base =
        await getExternalStorageDirectory() ??
        await getApplicationSupportDirectory();
    return Directory('${base.path}/$folderName');
  }

  Future<Directory> directory() async {
    final d = await _directory();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 名前順。
  Future<List<File>> list() async {
    final d = await directory();
    final out = <File>[
      await for (final e in d.list())
        if (e is File && TrackImporter.supports(e.uri.pathSegments.last)) e,
    ];
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/dev/fake_track.dart';
import 'package:mobile/dev/track_import.dart';

const _imp = TrackImporter();

void main() {
  test('GPX：時刻付きの trkpt はその速さで1秒ごとに流す', () {
    const gpx = '''<?xml version="1.0"?>
<gpx><trk><trkseg>
 <trkpt lat="36.7000" lon="137.2000"><time>2026-11-05T01:00:00Z</time></trkpt>
 <trkpt lat="36.7010" lon="137.2000"><time>2026-11-05T01:01:40Z</time></trkpt>
</trkseg></trk></gpx>''';
    final t = _imp.parse('a.gpx', gpx);
    expect(t, isA<LogTrack>());
    expect(t.durationS, 100);
    final mid = t.fixAt(50, moving: true);
    expect(mid.lat, closeTo(36.7005, 0.00001));
    expect(mid.speedMps, closeTo(1.11, 0.02)); // 111 m ÷ 100 秒
    expect(mid.courseDeg, closeTo(0, 1));
  });

  test('GPX：時刻の無い rtept は 1.3 m/s で歩く・自己終了タグも読む', () {
    const gpx =
        '<gpx><rte><rtept lat="36.70" lon="137.20"/>'
        "<rtept lon='137.20' lat='36.701'></rtept></rte></gpx>";
    final t = _imp.parse('b.GPX', gpx);
    expect(t, isA<RouteTrack>());
    expect(t.lengthM, closeTo(111.2, 0.5));
    expect(t.fixAt(10, moving: true).speedMps, 1.3);
  });

  test('GeoJSON：LineString は [経度, 緯度] の順', () {
    const j =
        '{"type":"FeatureCollection","features":[{"type":"Feature",'
        '"geometry":{"type":"LineString","coordinates":[[137.2,36.7],[137.2,36.701]]}}]}';
    final t = _imp.parse('c.geojson', j);
    expect(t.fixAt(0, moving: false).lat, 36.7);
    expect(t.lengthM, closeTo(111.2, 0.5));
  });

  test('JSON：points・route.json の waypoints・[緯度, 経度] の配列', () {
    expect(
      _imp
          .parse(
            'd.json',
            '{"points":[{"lat":36.7,"lng":137.2},{"latitude":36.701,"longitude":137.2}]}',
          )
          .lengthM,
      closeTo(111.2, 0.5),
    );
    // 名前だけの経由点（landmark）は飛ばし、座標のある点だけ使う
    final r = _imp.parse(
      'route.json',
      '{"waypoints":[{"landmark":"富山駅"},{"lat":36.70,"lon":137.20},{"lat":36.701,"lon":137.20}]}',
    );
    expect(r.lengthM, closeTo(111.2, 0.5));
    expect(
      _imp
          .parse('e.json', '{"coordinates":[[36.7,137.2],[36.701,137.2]]}')
          .lengthM,
      closeTo(111.2, 0.5),
    );
  });

  test('CSV：見出し行とコメントを飛ばし、時刻があれば使う', () {
    const csv =
        '# 検証用\nlat,lon,time\n'
        '36.7000,137.2000,2026-11-05T01:00:00Z\n'
        '36.7010,137.2000,2026-11-05T01:01:40Z\n';
    final t = _imp.parse('f.csv', csv);
    expect(t, isA<LogTrack>());
    expect(t.durationS, 100);
  });

  test('歩行ログ（.jsonl）も読める', () {
    const l =
        '{"type":"sensor","data":{"lat":36.7,"lon":137.2,"acc_m":4,"speed_mps":1,"course_deg":0}}\n'
        '{"type":"sensor","data":{"lat":36.7001,"lon":137.2,"acc_m":4,"speed_mps":1,"course_deg":0}}';
    expect(_imp.parse('walk.jsonl', l).durationS, 1);
  });

  test('読めないものは理由を返す', () {
    expect(() => _imp.parse('x.json', '{壊れ'), throwsA(isA<TrackImportError>()));
    expect(
      () => _imp.parse('x.gpx', '<gpx/>'),
      throwsA(isA<TrackImportError>()),
    );
    expect(
      () => _imp.parse('x.csv', '36.7,137.2\n'),
      throwsA(isA<TrackImportError>()), // 1点だけ
    );
    expect(
      () => _imp.parse('x.json', '[[36.7,137.2],[36.7,137.2]]'),
      throwsA(isA<TrackImportError>()), // 動いていない
    );
  });

  test('置き場所の一覧は読める形式だけ・名前順', () async {
    final dir = await Directory.systemTemp.createTemp('tracks');
    for (final n in ['b.gpx', 'a.csv', 'memo.txt', 'c.geojson']) {
      File('${dir.path}/$n').writeAsStringSync('');
    }
    final files = await TestTrackStore(() async => dir).list();
    expect(files.map((f) => f.uri.pathSegments.last), [
      'a.csv',
      'b.gpx',
      'c.geojson',
    ]);
    await dir.delete(recursive: true);
  });

  test('同梱の見本 GPX（富山駅→天門橋）が読める', () async {
    final t = await const TrackImporter().loadFile(
      File('tool/test_tracks/toyama_demo_timed.gpx'),
    );
    expect(t, isA<LogTrack>());
    expect(t.durationS, 14 * 60);
    expect(t.fixAt(185, moving: true).speedMps, 0); // 途中で30秒止まる
  });
}

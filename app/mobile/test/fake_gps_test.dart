import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/session_controller.dart';
import 'package:mobile/dev/fake_gps.dart';
import 'package:mobile/dev/fake_track.dart';
import 'package:mobile/logging/jsonl_writer.dart';
import 'package:mobile/sources/gaze_source.dart';
import 'package:mobile/sources/location_source.dart';

class _RealLoc implements LocationSource {
  final c = StreamController<LocationFix>.broadcast(sync: true);
  int listens = 0;
  @override
  Stream<LocationFix> get fixes {
    listens++;
    return c.stream;
  }
}

class _RealGaze implements GazeSource {
  final c = StreamController<GazeReading>.broadcast(sync: true);
  @override
  Stream<GazeReading> get readings => c.stream;
  @override
  Future<void> updateLocation(double lat, double lon, double? altM) async {}
}

LocationFix _fix(double lat) => LocationFix(
  lat: lat,
  lon: 137.2,
  accM: 5,
  speedMps: 1,
  courseDeg: 0,
  altM: null,
);

void main() {
  group('道のり', () {
    final route = RouteTrack('t', const [
      LatLon(36.700, 137.2),
      LatLon(36.701, 137.2), // 北へ約111 m
      LatLon(36.701, 137.2012), // 東へ約107 m
    ]);

    test('長さ・歩く時間・途中の位置と向き', () {
      expect(route.lengthM, closeTo(218, 2));
      expect(route.durationS, closeTo(218 / 1.3, 2));
      final mid = route.fixAt(40, moving: true); // 52 m 地点（北へ向かう途中）
      expect(mid.lat, closeTo(36.70047, 0.00002));
      expect(mid.speedMps, 1.3);
      expect(mid.courseDeg, closeTo(0, 0.5));
      final east = route.fixAt(120, moving: true); // 156 m 地点（東へ向かう途中）
      expect(east.courseDeg, closeTo(90, 1));
      expect(east.lat, closeTo(36.701, 0.00001));
    });

    test('止まっているときは速度0・進行方向なし（向きは残す）', () {
      final f = route.fixAt(40, moving: false);
      expect(f.speedMps, 0);
      expect(f.courseDeg, isNull);
      expect(route.headingAt(40), closeTo(0, 0.5));
    });

    test('倍速では速度も倍になる・最後まで行くと止まる', () {
      expect(route.fixAt(10, moving: true, speedFactor: 5).speedMps, 6.5);
      final end = route.fixAt(9999, moving: true);
      expect(end.speedMps, 0);
      expect(end.lon, closeTo(137.2012, 0.000001));
    });

    test('デモルートは富山駅から天門橋までおよそ1.1 km', () {
      expect(demoRouteToyama.lengthM, inInclusiveRange(1000, 1300));
    });

    test('歩行ログの sensor 行だけを読む', () async {
      final dir = await Directory.systemTemp.createTemp('replay');
      final f = File('${dir.path}/walk_x.jsonl')
        ..writeAsStringSync(
          [
            '{"type":"sensor","data":{"lat":36.7,"lon":137.2,"acc_m":4,"speed_mps":1.2,"course_deg":null}}',
            '{"type":"tts_finished","data":{"utterance_id":"u"}}',
            '壊れた行',
            '{"type":"sensor","data":{"lat":36.7001,"lon":137.2,"acc_m":4,"speed_mps":1.2,"course_deg":3}}',
          ].join(String.fromCharCode(10)),
        );
      final track = (await LogTrack.load(f))!;
      expect(track.fixes, hasLength(2));
      expect(track.durationS, 1);
      expect(track.headingAt(0), closeTo(0, 0.5)); // 進行方向が無い行は次の点への向き
      expect(track.fixAt(1, moving: true).courseDeg, 3);
      await dir.delete(recursive: true);
    });
  });

  group('切り替え', () {
    late _RealLoc realLoc;
    late _RealGaze realGaze;
    late FakeGpsController gps;
    late List<LocationFix> fixes;
    late List<GazeReading> gazes;

    setUp(() {
      realLoc = _RealLoc();
      realGaze = _RealGaze();
      gps = FakeGpsController(
        realLocation: realLoc,
        realGaze: realGaze,
        tick: const Duration(days: 1),
      );
      fixes = [];
      gazes = [];
      gps.location.fixes.listen(fixes.add);
      gps.gaze.readings.listen(gazes.add);
    });

    tearDown(() => gps.dispose());

    test('使っていない間は本物をそのまま流す', () {
      realLoc.c.add(_fix(1));
      realGaze.c.add(const GazeReading(azDeg: 10, pitchDeg: 0));
      expect(fixes.single.lat, 1);
      expect(gazes.single.azDeg, 10);
    });

    test('使うとフェイクだけを流し、やめると本物に戻る', () async {
      gps.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      realLoc.c.add(_fix(1)); // 本物は流さない
      expect(fixes.map((f) => f.lat), [demoRouteToyama.points.first.lat]);

      gps.togglePlay();
      gps.step();
      expect(fixes.last.speedMps, 1.3);
      expect(gps.distanceM, greaterThan(0));
      expect(gazes.last.azDeg, closeTo(demoRouteToyama.headingAt(gps.t), 0.01));

      gps.setEnabled(false);
      await Future<void>.delayed(Duration.zero);
      realLoc.c.add(_fix(2));
      expect(fixes.last.lat, 2);
      expect(realLoc.listens, 2); // 戻すと本物を聞き直す
    });

    test('向きを合わせないときは本物のセンサーの向き', () async {
      gps.setGazeFollowsRoute(false);
      gps.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      final before = gazes.length;
      realGaze.c.add(const GazeReading(azDeg: 77, pitchDeg: 5));
      expect(gazes.length, before + 1);
      expect(gazes.last.azDeg, 77);
    });

    test('倍速と最後まで行ったら止まる', () {
      gps.setEnabled(true);
      gps.setSpeed(10);
      gps.togglePlay();
      for (var i = 0; i < 200; i++) {
        gps.step();
      }
      expect(gps.atEnd, isTrue);
      expect(gps.playing, isFalse);
      gps.togglePlay(); // 最後からもう一度押すと最初から
      expect(gps.t, 0);
    });
  });

  test('フェイクで記録したログは名前に _fake が付く', () {
    expect(
      walkFileName(DateTime.utc(2026, 11, 5, 1, 2, 3), fake: true),
      'walk_20261105T010203Z_fake.jsonl',
    );
    expect(haversineM(0, 0, 0, 0), 0);
  });
}

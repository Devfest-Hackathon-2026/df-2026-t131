import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/sensor_ticker.dart';
import 'package:mobile/sources/activity_source.dart';
import 'package:mobile/sources/audio_state_source.dart';
import 'package:mobile/sources/camera_source.dart';
import 'package:mobile/sources/gaze_source.dart';
import 'package:mobile/sources/image_quality.dart';
import 'package:mobile/sources/location_source.dart';

class FakeLocation implements LocationSource {
  final c = StreamController<LocationFix>.broadcast(sync: true);
  @override
  Stream<LocationFix> get fixes => c.stream;
}

class FakeGaze implements GazeSource {
  final c = StreamController<GazeReading>.broadcast(sync: true);
  final updates = <List<double>>[];
  @override
  Stream<GazeReading> get readings => c.stream;
  @override
  Future<void> updateLocation(double lat, double lon, double? altM) async {
    updates.add([lat, lon]);
  }
}

class FakeActivity implements ActivitySource {
  final c = StreamController<ActivityKind>.broadcast(sync: true);
  @override
  Stream<ActivityKind> get changes => c.stream;
}

class FakeAudio implements AudioStateSource {
  final c = StreamController<AudioState>.broadcast(sync: true);
  @override
  Stream<AudioState> get states => c.stream;
}

LocationFix fix(double lat) => LocationFix(
  lat: lat,
  lon: 137.2,
  accM: 5,
  speedMps: 1.2,
  courseDeg: 10,
  altM: null,
);

void main() {
  late FakeLocation loc;
  late FakeGaze gaze;
  late FakeActivity act;
  late FakeAudio audio;
  late int now;
  CameraFrame? frame;

  SensorTicker build() => SensorTicker(
    locationSource: loc,
    gazeSource: gaze,
    activitySource: act,
    audioStateSource: audio,
    latestFrame: () => frame,
    ttsSpeaking: () => true,
    measureQuality: (_) async => const ImageQuality(blur: 0.8, brightness: 0.4),
    clock: () => now,
    interval: const Duration(days: 1), // テストでは tick() を直接呼ぶ
  );

  setUp(() {
    loc = FakeLocation();
    gaze = FakeGaze();
    act = FakeActivity();
    audio = FakeAudio();
    now = 1000;
    frame = null;
  });

  test('裏に回ったら、視線は進行方向・水平に、画質は無し（B を撮らない）にする', () async {
    frame = CameraFrame(
      nv21: Uint8List(4 * 4 * 3 ~/ 2),
      width: 4,
      height: 4,
      yRowStride: 4,
      sensorOrientation: 90,
    );
    final t = build()..start();
    final got = <SensorSnapshot>[];
    t.snapshots.listen(got.add);
    loc.c.add(fix(36.7)); // 進行方向 10°
    gaze.c.add(const GazeReading(azDeg: 250, pitchDeg: -40)); // ポケットの中の向き
    await t.tick();
    t.background = true;
    await t.tick();
    t.background = false;
    await t.tick();
    await Future<void>.delayed(Duration.zero);
    expect(got.map((s) => s.gaze.azDeg), [250, 10, 250]);
    expect(got[1].gaze.pitchDeg, 0);
    expect(got.map((s) => s.imageQuality == null), [false, true, false]);
    await t.dispose();
  });

  test('最初の測位までは何も出さない', () async {
    final t = build()..start();
    final got = <SensorSnapshot>[];
    t.snapshots.listen(got.add);
    await t.tick();
    expect(got, isEmpty);
    await t.dispose();
  });

  test('最新の値をまとめて1つ出す', () async {
    final t = build()..start();
    final got = <SensorSnapshot>[];
    t.snapshots.listen(got.add);
    loc.c.add(fix(36.7));
    gaze.c.add(const GazeReading(azDeg: 180, pitchDeg: 5));
    act.c.add(ActivityKind.walking);
    audio.c.add(const AudioState(earphone: true, inCall: false));
    frame = CameraFrame(
      nv21: Uint8List(6),
      width: 2,
      height: 2,
      yRowStride: 2,
      sensorOrientation: 90,
    );
    now = 2000;
    await t.tick();
    await Future<void>.delayed(Duration.zero);
    expect(got, hasLength(1));
    final s = got.single;
    expect(s.tMs, 2000);
    expect(s.location.lat, 36.7);
    expect(s.gaze.azDeg, 180);
    expect(s.activity, ActivityKind.walking);
    expect(s.audio.earphone, isTrue);
    expect(s.ttsSpeaking, isTrue);
    expect(s.imageQuality!.blur, 0.8);
    await t.dispose();
  });

  test('視線が届くまでは出さない', () async {
    final t = build()..start();
    final got = <SensorSnapshot>[];
    t.snapshots.listen(got.add);
    loc.c.add(fix(36.7));
    await t.tick();
    expect(got, isEmpty);
    await t.dispose();
  });

  test('カメラが無ければ画質は null', () async {
    final t = build()..start();
    final got = <SensorSnapshot>[];
    t.snapshots.listen(got.add);
    loc.c.add(fix(36.7));
    gaze.c.add(const GazeReading(azDeg: 0, pitchDeg: 0));
    await t.tick();
    await Future<void>.delayed(Duration.zero);
    expect(got.single.imageQuality, isNull);
    expect(got.single.activity, ActivityKind.unknown);
    await t.dispose();
  });

  test('偏角の更新は最初と10分ごとだけ', () async {
    final t = build()..start();
    loc.c.add(fix(36.70));
    now += 60 * 1000;
    loc.c.add(fix(36.71));
    now += 10 * 60 * 1000;
    loc.c.add(fix(36.72));
    expect(gaze.updates.map((u) => u[0]), [36.70, 36.72]);
    await t.dispose();
  });
}

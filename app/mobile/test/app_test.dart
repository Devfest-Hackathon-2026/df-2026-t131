import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_settings.dart';
import 'package:mobile/app/session_controller.dart';
import 'package:mobile/core/sensor_ticker.dart';
import 'package:mobile/executors/voice_catalog.dart';
import 'package:mobile/logging/jsonl_writer.dart';
import 'package:mobile/sources/activity_source.dart';
import 'package:mobile/sources/audio_state_source.dart';
import 'package:mobile/sources/gaze_source.dart';
import 'package:mobile/sources/image_quality.dart';
import 'package:mobile/sources/location_source.dart';
import 'package:mobile/ui/readiness.dart';

class _Loc implements LocationSource {
  final c = StreamController<LocationFix>.broadcast(sync: true);
  @override
  Stream<LocationFix> get fixes => c.stream;
}

class _Gaze implements GazeSource {
  final c = StreamController<GazeReading>.broadcast(sync: true);
  @override
  Stream<GazeReading> get readings => c.stream;
  @override
  Future<void> updateLocation(double lat, double lon, double? altM) async {}
}

class _Act implements ActivitySource {
  @override
  Stream<ActivityKind> get changes => const Stream.empty();
}

class _Audio implements AudioStateSource {
  @override
  Stream<AudioState> get states => const Stream.empty();
}

LocationFix _fix(double lat, {double acc = 5}) => LocationFix(
  lat: lat,
  lon: 137.2135,
  accM: acc,
  speedMps: 1.3,
  courseDeg: 0,
  altM: null,
);

void main() {
  group('設定', () {
    test('JSON の往復', () {
      const s = AppSettings(
        visualSearchEnabled: false,
        voice: VoicePreset.voice2,
      );
      expect(AppSettings.fromJson(s.toJson()), s);
    });

    test('壊れた値・知らない値は既定値に戻す', () {
      final s = AppSettings.fromJson({
        'visual_search_enabled': 'yes',
        'voice': 'voice9',
      });
      expect(s, const AppSettings());
    });

    test('ファイルに保存して読み戻せる', () async {
      final dir = await Directory.systemTemp.createTemp('settings');
      final store = FileSettingsStore(directory: () async => dir);
      expect(await store.load(), const AppSettings());
      await store.save(const AppSettings(voice: VoicePreset.voice2));
      expect((await store.load()).voice, VoicePreset.voice2);
      await File('${dir.path}/settings.json').writeAsString('{壊れた');
      expect(await store.load(), const AppSettings());
      await dir.delete(recursive: true);
    });
  });

  test('日本語の声だけを、端末内の声を先に名前順で選ぶ', () {
    final v = pickJapaneseVoices([
      {'name': 'en-us-x-sfg-local', 'locale': 'en-US'},
      {'name': 'ja-jp-x-jad-network', 'locale': 'ja-JP'},
      {'name': 'ja-jp-x-jac-local', 'locale': 'ja-JP'},
      {'name': 'ja-jp-x-htm-local', 'locale': 'ja_JP'},
      'おかしな値',
    ]);
    expect(v.map((e) => e.name), [
      'ja-jp-x-htm-local',
      'ja-jp-x-jac-local',
      'ja-jp-x-jad-network',
    ]);
  });

  group('開始前の確認', () {
    test('位置と向きがそろうまで開始できない', () {
      expect(canStart(location: null, gaze: null), isFalse);
      expect(canStart(location: _fix(36.7), gaze: null), isFalse);
      expect(
        canStart(
          location: _fix(36.7),
          gaze: const GazeReading(azDeg: 0, pitchDeg: 0),
        ),
        isTrue,
      );
    });

    test('精度が悪い・スピーカーなら注意を出す', () {
      final items = buildReadiness(
        location: _fix(36.7, acc: 54),
        gaze: const GazeReading(azDeg: 0, pitchDeg: 0),
        cameraReady: true,
        audio: AudioState.initial,
        settings: const AppSettings(),
      );
      expect(
        items.where((i) => i.level == CheckLevel.warn).map((i) => i.label),
        ['位置', '音声'],
      );
    });

    test('画像検索オフならカメラは送らないと明示する', () {
      final items = buildReadiness(
        location: null,
        gaze: null,
        cameraReady: false,
        audio: AudioState.initial,
        settings: const AppSettings(visualSearchEnabled: false),
      );
      expect(
        items.firstWhere((i) => i.label == 'カメラ').detail,
        contains('送りません'),
      );
    });
  });

  test('ファイル名は開始時刻の UTC', () {
    expect(
      walkFileName(DateTime.utc(2026, 11, 5, 1, 2, 3)),
      'walk_20261105T010203Z.jsonl',
    );
  });

  group('セッション', () {
    late Directory dir;
    late _Loc loc;
    late _Gaze gaze;
    late SensorTicker ticker;
    late int nowMs;
    late SessionController session;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('walks');
      loc = _Loc();
      gaze = _Gaze();
      nowMs = DateTime.utc(2026, 11, 5, 1).millisecondsSinceEpoch;
      ticker = SensorTicker(
        locationSource: loc,
        gazeSource: gaze,
        activitySource: _Act(),
        audioStateSource: _Audio(),
        measureQuality: (_) async =>
            const ImageQuality(blur: 1, brightness: 0.5),
        clock: () => nowMs,
        interval: const Duration(days: 1),
      )..start();
      session = SessionController(
        ticker: ticker,
        settings: () => const AppSettings(visualSearchEnabled: false),
        walkDirectory: () async => dir,
        now: () => DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
      );
      gaze.c.add(const GazeReading(azDeg: 180, pitchDeg: 0));
    });

    tearDown(() async {
      await ticker.dispose();
      await dir.delete(recursive: true);
    });

    test('開始前の値は記録しない・開始から終了までを schema の形で1秒1行', () async {
      loc.c.add(_fix(36.7010));
      await ticker.tick(); // 開始前（自宅など）→ 記録されない

      await session.start();
      expect(session.phase, SessionPhase.running);
      for (var i = 0; i < 3; i++) {
        nowMs += 1000;
        loc.c.add(_fix(36.7010 - 0.00002 * (i + 1)));
        await ticker.tick();
      }
      session.recordTtsFinished('u_000001');
      nowMs += 1000;
      await session.stop();

      final s = session.summary!;
      expect(session.phase, SessionPhase.finished);
      expect(s.rows, 4); // sensor 3行 ＋ tts_finished 1行
      expect(s.maxGapMs, 1000);
      expect(s.hasGap, isFalse);
      expect(s.distanceM, closeTo(4.4, 0.3));
      expect(s.settings.visualSearchEnabled, isFalse);

      final file = File('${dir.path}/${s.fileName}');
      // schema/validate.py で確かめる用に1件残す（build/ は Git 管理外）
      await Directory('build/schema_check').create(recursive: true);
      await file.copy('build/schema_check/walk_sample.jsonl');
      final lines = await file.readAsLines();
      expect(lines, hasLength(4));
      expect(jsonDecode(lines.last)['type'], 'tts_finished');
      final row = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(row['schema_version'], '0.3');
      expect(row['type'], 'sensor');
      final data = row['data'] as Map<String, dynamic>;
      expect(data.keys.toSet(), {
        'lat',
        'lon',
        'acc_m',
        'speed_mps',
        'course_deg',
        'gaze_az_deg',
        'gaze_pitch_deg',
        'activity',
        'audio_out',
        'in_call',
        'tts_speaking',
        'image_quality',
      });
      expect(data['activity'], 'unknown');
      expect(data['audio_out'], 'speaker');

      session.reset();
      expect(session.phase, SessionPhase.idle);
    });

    test('開始を続けて2回押しても、記録は1つだけ（sensor 行も二重にならない）', () async {
      loc.c.add(_fix(36.7));
      await Future.wait([session.start(), session.start()]);
      await ticker.tick();
      await session.stop();
      expect(session.summary!.rows, 1);
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
    });

    test('3秒を超える抜けを見つける', () async {
      loc.c.add(_fix(36.7));
      await session.start();
      await ticker.tick();
      nowMs += 4500;
      await ticker.tick();
      await session.stop();
      expect(session.summary!.hasGap, isTrue);
    });
  });

  test('距離の計算（緯度 0.001° ≒ 111 m）', () {
    expect(haversineM(36.7, 137.2, 36.701, 137.2), closeTo(111.2, 0.5));
  });
}

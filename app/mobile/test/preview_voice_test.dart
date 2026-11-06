import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_mode.dart';
import 'package:mobile/app/app_services.dart';
import 'package:mobile/app/app_settings.dart';
import 'package:mobile/core/sensor_ticker.dart';
import 'package:mobile/executors/speak_executor.dart';
import 'package:mobile/executors/voice_catalog.dart';
import 'package:mobile/sources/activity_source.dart';
import 'package:mobile/sources/audio_state_source.dart';
import 'package:mobile/sources/camera_source.dart';
import 'package:mobile/sources/gaze_source.dart';
import 'package:mobile/sources/location_source.dart';

import 'speak_executor_test.dart' show FakeTts, FakeFocus, FakeChime;

class _Cam implements CameraSource {
  @override
  CameraController? get controller => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  CameraFrame? latestFrame() => null;
  @override
  Future<CameraFrame?> captureFrame() async => null;
}

class _Loc implements LocationSource {
  @override
  Stream<LocationFix> get fixes => const Stream.empty();
}

class _Gaze implements GazeSource {
  @override
  Stream<GazeReading> get readings => const Stream.empty();
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

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('試し聞きを話し終えたら、選んでいる声に戻す（試し聞きの声で案内しない）', () async {
    final tts = FakeTts();
    final s = AppServices(
      camera: _Cam(),
      ticker: SensorTicker(
        locationSource: _Loc(),
        gazeSource: _Gaze(),
        activitySource: _Act(),
        audioStateSource: _Audio(),
        interval: const Duration(days: 1),
      ),
      settingsStore: MemorySettingsStore(),
      voices: VoiceCatalog(),
      policy: const DemoSessionPolicy(),
      mode: AppMode.demo,
      speaker: SpeakExecutor(tts: tts, focus: FakeFocus(), chime: FakeChime()),
      initialSettings: const AppSettings(voice: VoicePreset.voice1),
    );
    await settle();
    tts.voices.clear();

    await s.previewVoice(VoicePreset.zunda);
    await settle();
    expect(tts.voices, [VoicePreset.zunda]); // 試し聞きはずんだもん
    for (var i = 0; i < 5 && s.speaker.speaking; i++) {
      tts.finish();
      await settle();
    }
    expect(tts.voices.last, VoicePreset.voice1); // 選んでいる声1に戻る
  });
}

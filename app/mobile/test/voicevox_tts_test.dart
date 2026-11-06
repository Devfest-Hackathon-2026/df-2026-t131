import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_settings.dart';
import 'package:mobile/executors/speak_executor.dart';
import 'package:mobile/executors/voicevox_tts.dart';

class _Fallback implements TtsEngine {
  @override
  void prepare(String text) {}

  final spoken = <String>[];
  VoicePreset? voice;
  @override
  Future<void> speak(
    String text, {
    required VoidCallback onStart,
    ValueChanged<int>? onProgress,
  }) async {
    spoken.add(text);
    onStart();
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> useVoice(VoicePreset preset) async => voice = preset;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/voicevox');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('ずんだもんが使えないビルドでは端末の声で話す', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'init' ? false : null;
    });
    final fb = _Fallback();
    final e = VoicevoxTtsEngine(fallback: fb, channel: channel);
    await e.useVoice(VoicePreset.zunda);
    var started = false;
    await e.speak('こんにちは。', onStart: () => started = true);
    expect(fb.spoken, ['こんにちは。']);
    expect(started, isTrue);
  });

  test('ずんだもんで話すときは選んだ話し方のスタイルを送り、話し始めの通知で字幕を出す', () async {
    final calls = <MethodCall>[];
    final e = VoicevoxTtsEngine(fallback: _Fallback(), channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'init') return true;
      if (call.method == 'speak') {
        // 端末側が「話し始めた」を送ってから、話し終えたことを返す
        final id = (call.arguments as Map)['id'];
        await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('started', {'id': id, 'durationMs': 1000}),
          ),
          (_) {},
        );
        return true;
      }
      return null;
    });
    await e.useVoice(VoicePreset.zundaSweet);
    var started = false;
    await e.speak('右手に富山駅があります。', onStart: () => started = true);
    final speak = calls.singleWhere((c) => c.method == 'speak');
    expect((speak.arguments as Map)['styleId'], 1); // あまあま
    expect((speak.arguments as Map)['text'], '右手に富山駅があります。');
    expect(started, isTrue);
  });

  test('声1・声2を選んでいるときは、ずんだもんを使わず端末の声で話す', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    final fb = _Fallback();
    final e = VoicevoxTtsEngine(fallback: fb, channel: channel);
    await e.useVoice(VoicePreset.voice2);
    await e.speak('こんにちは。', onStart: () {});
    expect(fb.voice, VoicePreset.voice2);
    expect(fb.spoken, ['こんにちは。']);
    expect(calls, isNot(contains('speak')));
  });
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mobile/executors/speak_executor.dart';
import 'package:mobile/executors/voice_catalog.dart';

/// 端末の TTS の通知を、テストが好きな順番で起こせる偽物。
class _NativeTts extends FlutterTts {
  VoidCallback? start, complete, cancel;
  final stopGate = Completer<void>();
  final spoken = <String>[];

  @override
  void setStartHandler(VoidCallback callback) => start = callback;
  @override
  void setCompletionHandler(VoidCallback callback) => complete = callback;
  @override
  void setCancelHandler(VoidCallback callback) => cancel = callback;
  @override
  void setProgressHandler(ProgressHandler callback) {}
  @override
  void setErrorHandler(ErrorHandler handler) {}
  @override
  Future<dynamic> setLanguage(String language) async => 1;
  @override
  Future<void> setAudioAttributesForNavigation() async {}
  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    return 1;
  }

  @override
  Future<dynamic> stop() => stopGate.future; // 止め終わるのが遅い
}

class _Focus implements AudioFocus {
  @override
  Future<void> acquire({required bool pauseMusic}) async {}
  @override
  Future<void> release() async {}
}

class _Chime implements Chime {
  @override
  Future<void> play() async {}
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('割り込んだ発話の字幕は、前の発話の遅れた通知で消えない', () async {
    final native = _NativeTts();
    final x = SpeakExecutor(
      tts: FlutterTtsEngine(VoiceCatalog(native), native),
      focus: _Focus(),
      chime: _Chime(),
    );
    final finished = <String>[];
    x.finished.listen(finished.add);

    x.execute(const SpeakRequest(utteranceId: 'g', text: '案内'));
    await settle();
    native.start!();
    expect(x.subtitle.value, '案内');

    x.execute(
      const SpeakRequest(
        utteranceId: 'p',
        text: '試し聞き',
        priority: 2,
        interrupt: true,
        group: 'preview',
      ),
    );
    await settle();
    expect(native.spoken, ['案内', '試し聞き']);

    // 前の発話の取り消し通知が、次の発話の「話し始め」より前に遅れて届く
    native.cancel!();
    native.stopGate.complete();
    await settle();
    expect(x.speaking, isTrue);

    native.start!();
    expect(x.subtitle.value, '試し聞き');
    expect(finished, ['g']);

    native.complete!();
    await settle();
    expect(x.subtitle.value, isNull);
    expect(finished, ['g', 'p']);
  });
}

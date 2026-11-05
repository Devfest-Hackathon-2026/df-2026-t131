import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_settings.dart';
import 'package:mobile/executors/speak_executor.dart';

/// 話し終わりをテストが決める偽の TTS。
class FakeTts implements TtsEngine {
  final spoken = <String>[];
  final stops = <int>[];
  Completer<void>? _now;

  ValueChanged<int>? progress;

  @override
  Future<void> speak(
    String text, {
    required VoidCallback onStart,
    ValueChanged<int>? onProgress,
  }) {
    spoken.add(text);
    progress = onProgress;
    onStart();
    _now = Completer<void>();
    return _now!.future;
  }

  /// 今の文を話し終えたことにする。
  void finish() {
    final c = _now;
    _now = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> stop() async {
    stops.add(spoken.length);
    finish(); // 止めると speak の Future も終わる（flutter_tts の onCancel と同じ）
  }

  @override
  Future<void> useVoice(VoicePreset preset) async {}
}

class FakeFocus implements AudioFocus {
  final log = <String>[];
  @override
  Future<void> acquire({required bool pauseMusic}) async =>
      log.add(pauseMusic ? 'pause' : 'duck');
  @override
  Future<void> release() async => log.add('release');
}

class FakeChime implements Chime {
  int count = 0;
  @override
  Future<void> play() async => count++;
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeTts tts;
  late FakeFocus focus;
  late FakeChime chime;
  late SpeakExecutor x;
  late List<String> finished;

  setUp(() {
    tts = FakeTts();
    focus = FakeFocus();
    chime = FakeChime();
    x = SpeakExecutor(tts: tts, focus: focus, chime: chime);
    finished = [];
    x.finished.listen(finished.add);
  });

  test('音の出口を確保 → 合図音 → 読み上げ → 終わりを返して手放す', () async {
    x.execute(const SpeakRequest(utteranceId: 'u_000001', text: '右手の石碑は…'));
    await settle();
    expect(x.speaking, isTrue);
    expect(x.subtitle.value, '右手の石碑は…');
    expect(chime.count, 1);
    expect(focus.log, ['duck']);

    tts.finish();
    await settle();
    expect(finished, ['u_000001']);
    expect(x.speaking, isFalse);
    expect(x.subtitle.value, isNull);
    expect(focus.log, ['duck', 'release']);
  });

  test('話している間に来た依頼は順番に話す（FIFO）', () async {
    x.execute(const SpeakRequest(utteranceId: 'a', text: '一つ目'));
    x.execute(const SpeakRequest(utteranceId: 'b', text: '二つ目'));
    await settle();
    expect(tts.spoken, ['一つ目']);
    tts.finish();
    await settle();
    expect(tts.spoken, ['一つ目', '二つ目']);
    tts.finish();
    await settle();
    expect(finished, ['a', 'b']);
  });

  test('割り込みは今の読み上げを止めて先に話し、止めた方の終わりも1回だけ返す', () async {
    x.execute(const SpeakRequest(utteranceId: 'a', text: '案内'));
    x.execute(const SpeakRequest(utteranceId: 'b', text: '次の案内'));
    await settle();
    x.execute(
      const SpeakRequest(
        utteranceId: 'alert',
        text: '大雨の危険警報です',
        priority: 1,
        interrupt: true,
        pauseMusic: true,
      ),
    );
    await settle();
    expect(tts.stops, isNotEmpty);
    expect(tts.spoken, ['案内', '大雨の危険警報です']);
    expect(focus.log.last, 'pause'); // 警報は音楽を一時停止
    tts.finish();
    await settle();
    tts.finish();
    await settle();
    expect(tts.spoken, ['案内', '大雨の危険警報です', '次の案内']);
    expect(finished, ['a', 'alert', 'b']);
  });

  test('同じ group（試し聞き）は連打しても最後の1回だけ話し、合図音も重ねない', () async {
    SpeakRequest p(String id) => SpeakRequest(
      utteranceId: id,
      text: '試し聞き $id',
      priority: 2,
      interrupt: true,
      group: 'preview',
    );
    x.execute(p('p1'));
    await settle();
    x.execute(p('p2'));
    x.execute(p('p3'));
    x.execute(p('p4'));
    await settle();
    expect(tts.spoken, ['試し聞き p1', '試し聞き p4']);
    expect(chime.count, 1);
    tts.finish();
    await settle();
    expect(tts.spoken, hasLength(2)); // p2・p3 は話さない
    expect(finished.toSet(), {'p1', 'p2', 'p3', 'p4'}); // どれも1回だけ終わりを返す
    expect(finished, hasLength(4));
    expect(focus.log, ['duck', 'duck', 'release']);
  });

  test('試し聞きは案内を止めて話すが、警報は止めない', () async {
    const preview = SpeakRequest(
      utteranceId: 'p',
      text: '試し聞き',
      priority: 2,
      interrupt: true,
      group: 'preview',
    );
    x.execute(const SpeakRequest(utteranceId: 'g', text: '案内'));
    await settle();
    x.execute(preview);
    await settle();
    expect(tts.spoken, ['案内', '試し聞き']);
    tts.finish();
    await settle();

    x.execute(
      const SpeakRequest(
        utteranceId: 'alert',
        text: '警報',
        priority: 1,
        interrupt: true,
      ),
    );
    await settle();
    x.execute(preview);
    await settle();
    expect(tts.spoken.last, '警報'); // 警報は最後まで話す
    tts.finish();
    await settle();
    expect(tts.spoken.last, '試し聞き');
  });

  test('字幕は話した所まで進む', () async {
    x.execute(const SpeakRequest(utteranceId: 'a', text: '右手の石碑は'));
    await settle();
    expect(x.spokenChars.value, 0);
    tts.progress!(3);
    expect(x.spokenChars.value, 3);
    tts.finish();
    await settle();
    expect(x.spokenChars.value, 0);
    expect(x.subtitle.value, isNull);
  });

  test('TTS が失敗しても列は止まらない', () async {
    final bad = SpeakExecutor(tts: _ThrowingTts(), focus: focus, chime: chime);
    final done = <String>[];
    bad.finished.listen(done.add);
    bad.execute(const SpeakRequest(utteranceId: 'a', text: 'x'));
    bad.execute(const SpeakRequest(utteranceId: 'b', text: 'y'));
    await settle();
    await settle();
    expect(done, ['a', 'b']);
    expect(bad.speaking, isFalse);
  });
}

class _ThrowingTts implements TtsEngine {
  @override
  Future<void> speak(
    String text, {
    required VoidCallback onStart,
    ValueChanged<int>? onProgress,
  }) async => throw StateError('TTS が使えない');
  @override
  Future<void> stop() async {}
  @override
  Future<void> useVoice(VoicePreset preset) async {}
}

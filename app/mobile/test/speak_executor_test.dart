import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_settings.dart';
import 'package:mobile/executors/speak_executor.dart';

/// 話し終わりをテストが決める偽の TTS。
class FakeTts implements TtsEngine {
  @override
  void prepare(String text) {}

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

  /// 当てた声の順。
  final voices = <VoicePreset>[];

  @override
  Future<void> useVoice(VoicePreset preset) async => voices.add(preset);
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
    expect(chime.count, 2); // 警報の割り込みでも合図音を鳴らす（切り替わりが分かるように）
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

  group('優先度と割り込み（docs/design.md 4章）', () {
    SpeakRequest req(
      String id, {
      int priority = 5,
      int level = 0,
      bool interrupt = false,
      int? expiresMs,
    }) => SpeakRequest(
      utteranceId: id,
      text: id,
      priority: priority,
      level: level,
      interrupt: interrupt,
      expiresMs: expiresMs,
    );

    test('待っている依頼は優先度の順、同じ優先度なら来た順', () async {
      x.execute(req('landmark1'));
      await settle();
      x.execute(req('visual', priority: 6));
      x.execute(req('landmark2'));
      x.execute(req('event', priority: 4));
      x.execute(req('alert3', priority: 1, level: 3)); // レベル3は割り込まない
      await settle();
      expect(tts.spoken, ['landmark1']); // 今の話は最後まで
      for (var i = 0; i < 5; i++) {
        tts.finish();
        await settle();
      }
      expect(tts.spoken, [
        'landmark1',
        'alert3',
        'event',
        'landmark2',
        'visual',
      ]);
    });

    test('レベル4はレベル3の警報にも割り込むが、同じレベル4どうしは割り込まない', () async {
      x.execute(req('alert3', priority: 1, level: 3));
      await settle();
      x.execute(req('alert4a', priority: 1, level: 4, interrupt: true));
      await settle();
      expect(tts.spoken, ['alert3', 'alert4a']);
      x.execute(req('alert4b', priority: 1, level: 4, interrupt: true));
      await settle();
      expect(tts.spoken.last, 'alert4a'); // 話し終えるまで待つ
      tts.finish();
      await settle();
      expect(tts.spoken.last, 'alert4b');
      tts.finish();
      await settle();
      expect(tts.spoken, ['alert3', 'alert4a', 'alert4b']); // 止めた方は話し直さない
      expect(finished, ['alert3', 'alert4a', 'alert4b']);
    });

    test('割り込みでも今の発話より大事でなければ次に回す', () async {
      x.execute(req('alert', priority: 1, level: 3));
      await settle();
      x.execute(req('landmark', interrupt: true));
      await settle();
      expect(tts.stops, isEmpty);
      tts.finish();
      await settle();
      expect(tts.spoken, ['alert', 'landmark']);
    });

    test('警報でない発話には、割り込みの依頼は優先度が低くても割り込む。今の文を話し終えてから止め、残りは話さない', () async {
      x.execute(
        const SpeakRequest(utteranceId: 'landmark', text: '一つめの文です。二つめの文です。'),
      );
      await settle();
      expect(tts.spoken, ['一つめの文です。']);
      x.execute(req('visual', priority: 6, interrupt: true));
      await settle();
      expect(tts.stops, isEmpty); // 文の途中では切らない
      expect(finished, ['landmark']);
      tts.finish(); // 一つめの文を話し終える
      await settle();
      expect(tts.spoken, ['一つめの文です。', 'visual']); // 二つめの文は話さない
      expect(chime.count, 2); // 割り込みでも合図音を鳴らす
    });

    test('合図音を鳴らさない依頼（「検索します」）は、割り込みでも合図音を鳴らさない', () async {
      x.execute(req('landmark'));
      await settle();
      x.execute(
        const SpeakRequest(
          utteranceId: 'ack',
          text: '検索します。',
          priority: 2,
          interrupt: true,
          chime: false,
        ),
      );
      await settle();
      tts.finish();
      await settle();
      expect(tts.spoken, ['landmark', '検索します。']);
      expect(chime.count, 1);
    });

    test('文の区切り', () {
      expect(splitSentences('右手に石碑があります。古い碑です。'), ['右手に石碑があります。', '古い碑です。']);
      expect(splitSentences('区切りなし'), ['区切りなし']);
      expect(splitSentences('本当？はい！'), ['本当？', 'はい！']);
      expect(splitSentences('').join(), '');
    });

    test('話す番が来たとき期限を過ぎていたら話さずに捨てる', () async {
      var nowMs = 1000;
      final timed = SpeakExecutor(
        tts: tts,
        focus: focus,
        chime: chime,
        now: () => nowMs,
      );
      final done = <String>[];
      timed.finished.listen(done.add);
      timed.execute(req('landmark'));
      await settle();
      timed.execute(req('transit', priority: 3, expiresMs: 5000));
      timed.execute(req('event', priority: 4, expiresMs: 20000));
      nowMs = 10000; // 案内が長く、電車の期限を過ぎた
      tts.finish();
      await settle();
      expect(tts.spoken, ['landmark', 'event']);
      expect(done, ['landmark', 'transit']); // 捨てた方も終わりを返す
      tts.finish();
      await settle();
      expect(done.last, 'event');
    });
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
  void prepare(String text) {}

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

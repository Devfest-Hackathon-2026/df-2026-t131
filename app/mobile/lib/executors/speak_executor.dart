import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../app/app_settings.dart';
import 'voice_catalog.dart';

/// 読み上げの依頼1件。
/// TODO(質問): engine の雛形が届いたら engine の `Speak` コマンドに置き換える（項目は README 2.3 と同じ）。
class SpeakRequest {
  const SpeakRequest({
    required this.utteranceId,
    required this.text,
    this.priority = 5,
    this.interrupt = false,
    this.pauseMusic = false,
    this.group,
    this.level = 0,
    this.expiresMs,
    this.chime = true,
  });

  final String utteranceId;
  final String text;

  /// CLAUDE.md 4章の優先度 1〜6（1 が警報）。小さいほど大事。
  final int priority;

  /// true なら今の読み上げを止めてすぐ話す。ただし今の発話の方が大事（priority が小さい）なら止めない。
  final bool interrupt;

  /// true なら音楽を一時停止、false なら音量を下げる（ダッキング）。
  final bool pauseMusic;

  /// 同じ group の古い依頼は、新しい依頼が来たら捨てる（試し聞きの連打で何度も話さないため）。
  /// engine の発話には付けない（mobile が勝手に捨てない）。
  final String? group;

  /// 同じ優先度の中での大事さ（警報の警戒レベル 1〜5）。大きいほど先に話す。
  final int level;

  /// これを過ぎたら話さずに捨てる（UTC の UNIX ミリ秒。交通・イベント・B の答え）。null なら期限なし。
  final int? expiresMs;

  /// 話し始めに合図音を鳴らすか（「検索します」の返事は声そのものが合図なので鳴らさない）。
  final bool chime;

  /// [other] より先に話すべきか（優先度が小さい、同じなら警戒レベルが大きい）。
  bool outranks(SpeakRequest other) =>
      priority < other.priority ||
      (priority == other.priority && level > other.level);
}

// ---- 差し替えられる部品（テストでは偽物を使う） ----

/// 端末の読み上げエンジン。speak の Future は「話し終えた・止められた・失敗した」のどれかで終わる。
abstract class TtsEngine {
  /// [onProgress] には、話し終えた文字数（text の先頭からの位置）を渡す。
  Future<void> speak(
    String text, {
    required VoidCallback onStart,
    ValueChanged<int>? onProgress,
  });
  Future<void> stop();
  Future<void> useVoice(VoicePreset preset);

  /// これから話す文を、先に用意しておく（声をその場で作る部品だけが使う。既定は何もしない）。
  void prepare(String text) {}
}

/// 音の出口の取り合い（オーディオフォーカス）。
abstract class AudioFocus {
  Future<void> acquire({required bool pauseMusic});
  Future<void> release();
}

/// 話し始めの合図音。
abstract class Chime {
  Future<void> play();
}

/// 読み上げを実行する（engine の `Speak` を受ける）。判断はしない。
///
/// - 1件ずつ話す。待っている依頼は優先度（CLAUDE.md 4章）の順に並べ、同じ優先度なら来た順
/// - `interrupt` で、今の発話より大事なとき（[SpeakRequest.outranks]）か、今の発話が警報でないとき
///   （「検索します」や頼まれた B の答えは A に割り込む）、今の読み上げを止めて先に話す。
///   止めた方にも `TtsFinished` を返す（TODO(質問) 1）。警報には警報より大事なときしか割り込まない
/// - 文（「。」など）ごとに区切って話す。警報の割り込みはすぐ止めるが、それ以外の割り込みは
///   今の文を話し終えてから止める（文の途中で切ると不自然なため）。止めた発話の残りは話さない
/// - 話す番が来たときに期限（`expiresMs`）を過ぎていたら話さずに捨てる
/// - `group` が同じ古い依頼は捨てる（話す前なら列から消し、話している最中なら止める）
/// - 話す前に音の出口を確保（普段はダッキング、`pauseMusic` なら一時停止）し、合図音を鳴らす。
///   割り込みでも合図音を鳴らす（話が切り替わったと分かるように）。鳴らさないのは、
///   `chime` が false の依頼（「検索します」）と、試し聞きの連打（group の差し替え）
/// - 字幕は「話し始め」の通知で出し、話した所まで `spokenChars` で知らせる
class SpeakExecutor {
  SpeakExecutor({
    required this.tts,
    required this.focus,
    required this.chime,
    int Function()? now,
  }) : _now = now ?? _systemMs;

  static int _systemMs() => DateTime.now().toUtc().millisecondsSinceEpoch;
  final int Function() _now;

  final TtsEngine tts;
  final AudioFocus focus;
  final Chime chime;

  /// 待っている依頼（先頭から話す）。
  final _queue = <SpeakRequest>[];
  final _finished = StreamController<String>.broadcast();
  SpeakRequest? _current;
  bool _interruptedCurrent = false;
  bool _skipNextChime = false;
  bool _running = false;

  /// 今話している文（字幕）。話していないときは null。
  final ValueNotifier<String?> subtitle = ValueNotifier(null);

  /// 字幕のうち、話し終えた文字数（字幕を話した所まで濃く出すため）。
  final ValueNotifier<int> spokenChars = ValueNotifier(0);

  /// 話し終えた（または止めた・捨てた）発話の ID。engine には `TtsFinished` として返す。
  Stream<String> get finished => _finished.stream;

  /// 話している最中か（`SensorFrame.ttsSpeaking`）。
  bool get speaking => _current != null;

  Future<void> useVoice(VoicePreset preset) => tts.useVoice(preset);

  /// 読み上げの依頼を受ける。終わるのを待たない。
  void execute(SpeakRequest r) {
    final group = r.group;
    if (group != null) {
      // まだ話していない同じ group の依頼は捨てる
      _queue.removeWhere((q) {
        if (q.group != group) return false;
        _emitFinished(q.utteranceId);
        return true;
      });
    }
    final cur = _current;
    final replaceCurrent =
        cur != null &&
        !_interruptedCurrent &&
        ((group != null && cur.group == group) ||
            (r.interrupt && (r.outranks(cur) || cur.priority > 1)));
    _enqueue(r);
    if (replaceCurrent) {
      // 止めた発話の終わりは、ここで1回だけ返す
      _emitFinished(cur.utteranceId);
      _interruptedCurrent = true;
      // 試し聞きの連打は合図音を重ねない。ほかの割り込みは、話が切り替わったと分かるよう鳴らす
      _skipNextChime = group != null;
      // 警報と試し聞きはすぐ止める。それ以外は今の文を話し終えてから止める（_run の文の区切り）
      final hard = group != null || r.priority <= 1;
      if (hard) unawaited(tts.stop());
    }
    if (!_running) unawaited(_run());
  }

  /// 優先度の順に入れる。同じ大事さなら後ろに（来た順）。
  void _enqueue(SpeakRequest r) {
    final i = _queue.indexWhere(r.outranks);
    if (i < 0) {
      _queue.add(r);
    } else {
      _queue.insert(i, r);
    }
  }

  /// 待っている依頼の数（画面・テスト用）。
  int get pending => _queue.length;

  Future<void> _run() async {
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final r = _queue.removeAt(0);
        final exp = r.expiresMs;
        if (exp != null && _now() > exp) {
          _emitFinished(r.utteranceId); // 期限切れ。話さずに捨てる
          continue;
        }
        _current = r;
        final sentences = splitSentences(r.text);
        // 1文目は、音の出口の確保と合図音の間に作り始める（話し出しの待ちを減らす）
        tts.prepare(sentences.first);
        await _guard(() => focus.acquire(pauseMusic: r.pauseMusic));
        if (_skipNextChime || !r.chime) {
          _skipNextChime = false;
        } else {
          await _guard(chime.play);
        }
        // 文ごとに話す。文の切れ目で割り込まれていたら（合図音の間を含む）、残りは話さない
        var offset = 0;
        for (var i = 0; i < sentences.length; i++) {
          final sentence = sentences[i];
          if (_interruptedCurrent) break;
          // 次の文は、今の文を話している間に作っておく（文と文の間を空けない）
          if (i + 1 < sentences.length) tts.prepare(sentences[i + 1]);
          final base = offset;
          await _guard(
            () => tts.speak(
              sentence,
              onStart: () {
                if (!identical(_current, r)) return;
                if (base == 0) {
                  spokenChars.value = 0;
                  subtitle.value = r.text;
                }
              },
              onProgress: (end) {
                if (identical(_current, r)) spokenChars.value = base + end;
              },
            ),
          );
          offset += sentence.length;
          if (identical(_current, r)) spokenChars.value = offset;
        }
        final wasInterrupted = _interruptedCurrent;
        _interruptedCurrent = false;
        _current = null;
        subtitle.value = null;
        spokenChars.value = 0;
        if (!wasInterrupted) _emitFinished(r.utteranceId);
      }
    } finally {
      _running = false;
      _skipNextChime = false;
      await _guard(focus.release);
    }
  }

  void _emitFinished(String id) {
    if (!_finished.isClosed) _finished.add(id);
  }

  static Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      // 音の部品が失敗しても、読み上げの列は止めない
    }
  }

  Future<void> dispose() async {
    _queue.clear();
    await _guard(tts.stop);
    await _guard(focus.release);
    await _finished.close();
    subtitle.dispose();
    spokenChars.dispose();
  }
}

/// 読み上げる文を「。」「！」「？」の後ろで区切る（区切りの記号は前の文に付ける）。
/// つなげると元の文に戻る。区切りが無ければ1つのまま。
List<String> splitSentences(String text) {
  final parts = RegExp(r'[^。！？!?]+[。！？!?]*|[。！？!?]+')
      .allMatches(text)
      .map((m) => m.group(0)!)
      .toList();
  return parts.isEmpty ? [text] : parts;
}

// ---- 実機の部品 ----

/// flutter_tts（端末内の日本語音声）。
class FlutterTtsEngine implements TtsEngine {
  @override
  void prepare(String text) {}

  FlutterTtsEngine(this._voices, [FlutterTts? tts])
    : _tts = tts ?? FlutterTts() {
    _tts.setStartHandler(_started);
    _tts.setProgressHandler((_, _, end, _) {
      if (_hasStarted) _onProgress?.call(end);
    });
    // 終わり・取り消しの通知には発話の ID が付かない。割り込みで止めた前の発話の通知が
    // 遅れて届くと次の発話を終わらせてしまうので、今の発話が話し始める前の通知は捨てる。
    _tts.setCompletionHandler(_endedIfStarted);
    _tts.setCancelHandler(_endedIfStarted);
    _tts.setErrorHandler((_) => _done());
  }

  final FlutterTts _tts;
  final VoiceCatalog _voices;
  VoidCallback? _onStart;
  ValueChanged<int>? _onProgress;
  Completer<void>? _speaking;
  bool _hasStarted = false;
  bool _configured = false;

  /// stop のたびに増やす。準備を待つ間に止められた発話を、後から話し出さないため。
  int _generation = 0;

  void _started() {
    if (_speaking == null || _hasStarted) return;
    _hasStarted = true;
    _onStart?.call();
  }

  void _endedIfStarted() {
    if (_hasStarted) _done();
  }

  void _done() {
    final c = _speaking;
    _speaking = null;
    _hasStarted = false;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> speak(
    String text, {
    required VoidCallback onStart,
    ValueChanged<int>? onProgress,
  }) async {
    final gen = _generation;
    if (!_configured) {
      _configured = true;
      // 音の用途を「ナビの案内」にする（音楽アプリと並べて扱われる）
      await _tts.setAudioAttributesForNavigation();
      // 言語の設定（setLanguage）は端末の既定の声に戻してしまうので、ここでは単独で呼ばない。
      // 選んでいる声を、言語ごと当て直す（初めての試し聞きで別の声になっていたのを直す）
      await _voices.apply(_preset);
    }
    if (gen != _generation) return; // 準備の間に止められた
    _done(); // 前の発話が残っていれば終わらせる
    final c = Completer<void>();
    _speaking = c;
    _onStart = onStart;
    _onProgress = onProgress;
    await _tts.speak(text);
    // 念のため：通知が来ないまま長く待たないよう、文の長さから上限を決める
    return c.future.timeout(
      Duration(seconds: 5 + text.length ~/ 4),
      onTimeout: () {},
    );
  }

  @override
  Future<void> stop() async {
    _generation++;
    _onStart = null;
    _onProgress = null;
    // 止めるのは「今の」発話だけ。止め終わるのを待つ間に次の発話が始まっても、それは終わらせない
    _done();
    await _tts.stop();
  }

  /// 選んでいる声（初めて話す前の準備でも、この声を当てる）。
  VoicePreset _preset = VoicePreset.voice1;

  @override
  Future<void> useVoice(VoicePreset preset) {
    _preset = preset;
    return _voices.apply(preset);
  }
}

/// audio_session で音の出口を確保する。普段は「音量を下げてもらう」、警報だけ「一時停止してもらう」。
class SessionAudioFocus implements AudioFocus {
  AudioSession? _session;

  Future<AudioSession> _get() async {
    final s = _session;
    if (s != null) return s;
    final session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        androidAudioAttributes: AndroidAudioAttributes(
          usage: AndroidAudioUsage.assistanceNavigationGuidance,
          contentType: AndroidAudioContentType.speech,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ),
    );
    return _session = session;
  }

  @override
  Future<void> acquire({required bool pauseMusic}) async {
    final s = await _get();
    await s.setActive(
      true,
      androidAudioFocusGainType: pauseMusic
          ? AndroidAudioFocusGainType.gainTransient
          : AndroidAudioFocusGainType.gainTransientMayDuck,
    );
  }

  @override
  Future<void> release() async {
    final s = _session;
    if (s != null) await s.setActive(false);
  }
}

/// Kotlin の TonePlugin で合図音を鳴らす。
class ToneChime implements Chime {
  const ToneChime({this.channel = const MethodChannel('mobile/tone')});

  final MethodChannel channel;

  @override
  Future<void> play() async {
    await channel.invokeMethod<bool>('play', {'durationMs': 150});
  }
}

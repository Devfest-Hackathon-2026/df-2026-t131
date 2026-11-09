import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 「検索して」「調べて」と言われたかを聞き取る係（docs/design.md 7章：マイクはこれだけに使う）。
///
/// - 聞き取った文字は合図の判定だけに使い、保存・記録・送信しない
/// - スマホが読み上げている間も聞く（警報以外は、頼まれた検索が割り込む）。
///   ただし読み上げ中の文に合図の言葉が入っているときは、自分の声とみなして合図にしない
/// - 一度の発話で検索を頼むのは1回だけ（合図のあと [cooldown] は聞き流す）
abstract class VoiceCommandSource {
  /// 合図を聞き取るたびに1つ流れる。
  Stream<void> get requests;

  /// 画面に出す短い状態（「聞いています」「マイク未許可」など）。
  ValueListenable<String> get status;

  /// 開発者モードで、聞き取れているかを確かめる用の「今聞き取った文字」（無ければ null）。
  /// メモリの中だけに置き、数秒で消す。保存・記録・送信はしない。
  ValueListenable<String?> get heard;

  Future<void> start();
  Future<void> stop();
}

/// 合図の言葉。認識結果の空白・句読点を除いてから、どれかを含むかで見る。
const List<String> voiceSearchWords = ['検索して', 'けんさくして', '調べて', 'しらべて'];

/// 認識された文に合図が含まれるか。
bool containsSearchWord(String text) {
  final t = text.replaceAll(RegExp(r'[\s、。,.!?！？]'), '');
  return voiceSearchWords.any(t.contains);
}

/// 端末内の認識に対応していないことを表す認識のエラーか（言語のモデルが無い・サーバーが要る）。
bool onDeviceUnsupported(String errorMsg) =>
    errorMsg.contains('language') || errorMsg.contains('server');

/// 音声認識を起動し直すたびに Android が鳴らす「ポン」を消す係（Kotlin の TonePlugin）。
class BeepMuter {
  const BeepMuter([this.channel = const MethodChannel('mobile/tone')]);
  final MethodChannel channel;

  /// 聞き取っている間ずっと、通知・システムの音を消す（止めたら戻す）。
  Future<void> muteBeeps(bool on) =>
      channel.invokeMethod<void>('muteBeeps', {'on': on}).catchError((_) {});

  /// 起動し直す瞬間だけ、メディアの音も消す（起動音がメディアで鳴る端末向け）。
  Future<void> muteMusicBriefly() => channel
      .invokeMethod<void>('muteMusicBriefly', {'ms': 700})
      .catchError((_) {});
}

/// Android の音声認識（speech_to_text）で、計測中ずっと聞き続ける。
///
/// Android の認識は数秒の無音で止まるので、止まるたびに聞き直す。
/// 聞き直すたびに鳴る起動音は [BeepMuter] で消す（音を出すのは読み上げの合図音だけにする）。
/// アプリが話しているときは、読み上げを消さないようメディアの音は消さない。
/// 認識は**端末内だけ**で行う（`onDevice`）。音声をサーバーに送らない（docs/design.md 7章）。
/// 端末が端末内の認識に対応していなければ、聞き取りをやめる（検索はボタンで頼める）。
class SpeechVoiceCommandSource implements VoiceCommandSource {
  SpeechVoiceCommandSource({
    required this.currentSpeech,
    SpeechToText? speech,
    this.cooldown = const Duration(seconds: 3),
    this.localeId = 'ja_JP',
    this.beeps,
  }) : _speech = speech ?? SpeechToText();

  /// 起動音を消す係。null なら消さない（テスト）。
  final BeepMuter? beeps;

  /// アプリがいま読み上げている文（読み上げていなければ null）。
  final String? Function() currentSpeech;
  final Duration cooldown;
  final String localeId;
  final SpeechToText _speech;

  final StreamController<void> _requests = StreamController.broadcast();
  final ValueNotifier<String> _status = ValueNotifier('停止中');
  bool _active = false;
  bool _listening = false;
  DateTime _mutedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _retry;

  @override
  Stream<void> get requests => _requests.stream;

  @override
  ValueListenable<String> get status => _status;

  final ValueNotifier<String?> _heard = ValueNotifier(null);
  Timer? _heardClear;

  @override
  ValueListenable<String?> get heard => _heard;

  void _showHeard(String text) {
    _heardClear?.cancel();
    _heard.value = text.isEmpty ? null : text;
    _heardClear = Timer(const Duration(seconds: 4), () => _heard.value = null);
  }

  @override
  Future<void> start() async {
    if (_active) return;
    _active = true;
    final ok = await _speech.initialize(onStatus: _onStatus, onError: _onError);
    if (!ok) {
      _active = false;
      _status.value = '音声認識を使えません（マイクの許可を確認）';
      return;
    }
    if (!_active) return; // 用意している間に止められた（音を消さずに終える）
    await beeps?.muteBeeps(true);
    _listen();
  }

  void _listen() {
    _retry?.cancel();
    if (!_active || _listening) return;
    if (DateTime.now().isBefore(_mutedUntil)) {
      _retry = Timer(const Duration(milliseconds: 500), _listen);
      return;
    }
    _listening = true;
    _status.value = '聞いています（端末内）';
    // 話していないときだけ、起動の瞬間のメディアの音も消す
    if (currentSpeech() == null) unawaited(beeps?.muteMusicBriefly());
    _speech
        .listen(
          onResult: _onResult,
          listenOptions: SpeechListenOptions(
            localeId: localeId,
            partialResults: true,
            onDevice: true, // 端末内だけ。サーバーの認識には切り替えない
            cancelOnError: true,
            listenMode: ListenMode.search,
            listenFor: const Duration(seconds: 30),
            pauseFor: const Duration(seconds: 4),
          ),
        )
        .catchError((Object _) {
          _listening = false;
          _scheduleRestart();
        });
  }

  void _onResult(SpeechRecognitionResult r) {
    _showHeard(r.recognizedWords); // 確かめる用に画面へ（残さない）
    if (!containsSearchWord(r.recognizedWords)) return;
    // 読み上げている文そのものに合図の言葉があれば、アプリ自身の声を拾ったとみなす
    final speech = currentSpeech();
    if (speech != null && containsSearchWord(speech)) return;
    _mutedUntil = DateTime.now().add(cooldown);
    _requests.add(null);
    _speech.cancel(); // 同じ発話をもう一度数えない
  }

  void _onStatus(String s) {
    if (s == SpeechToText.notListeningStatus || s == SpeechToText.doneStatus) {
      _listening = false;
      _scheduleRestart();
    }
  }

  void _onError(SpeechRecognitionError e) {
    _listening = false;
    if (e.errorMsg == 'error_permission') {
      _active = false;
      _status.value = 'マイク未許可';
      return;
    }
    // 端末内の認識に対応していなければ、聞き取りをやめる（サーバーの認識には切り替えない）
    if (onDeviceUnsupported(e.errorMsg)) {
      _active = false;
      _retry?.cancel();
      _status.value = '端末内の音声認識が使えません（検索はボタンで）';
      unawaited(beeps?.muteBeeps(false));
      return;
    }
    _scheduleRestart();
  }

  void _scheduleRestart() {
    if (!_active) return;
    _retry?.cancel();
    _retry = Timer(const Duration(milliseconds: 400), _listen);
  }

  @override
  Future<void> stop() async {
    _active = false;
    _retry?.cancel();
    _retry = null;
    _listening = false;
    _status.value = '停止中';
    _heardClear?.cancel();
    _heard.value = null;
    try {
      await _speech.cancel();
    } catch (_) {}
    await beeps?.muteBeeps(false);
  }
}

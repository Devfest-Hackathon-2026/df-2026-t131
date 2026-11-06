import 'dart:async';

import 'package:flutter/services.dart';

import '../app/app_settings.dart';
import 'speak_executor.dart';

/// ずんだもんの声（VOICEVOX CORE。端末の中で作る）で読み上げる。
///
/// - 警報・A・B・試し聞きのどれも、この部品を通る。ずんだもんを選んでいれば全部ずんだもんで話す
/// - 声1・声2を選んでいるとき、声のファイルが入っていないビルド、読み込めない端末では
///   [fallback]（端末の声）で話す
/// - 次の文は [prepare] で先に作り、文と文の間や話し出しの待ちを減らす
/// - 字幕の「話した所」は、音の長さから時間に比例して進める（VOICEVOX は言葉ごとの通知を出さない）
/// - 声を使うときは「VOICEVOX:ずんだもん」のクレジットを出す（[credit]）
class VoicevoxTtsEngine implements TtsEngine {
  VoicevoxTtsEngine({
    required this.fallback,
    this.channel = const MethodChannel('mobile/voicevox'),
  }) {
    channel.setMethodCallHandler(_onNative);
  }

  /// 画面に出すクレジット（VOICEVOX の音声モデルの利用規約で必要）。
  static const credit = 'VOICEVOX:ずんだもん';

  /// ずんだもんのスタイル ID（voicevox_vvm の 0.vvm）。端末の声なら null。
  static int? styleFor(VoicePreset p) => switch (p) {
    VoicePreset.zunda => 3, // ノーマル
    VoicePreset.zundaSweet => 1, // あまあま
    VoicePreset.voice1 || VoicePreset.voice2 => null,
  };

  /// 話す速さ（1.0 が標準）。歩きながら聞くので少しだけ速くする。
  static const speed = 1.1;

  final TtsEngine fallback;
  static const _tone = MethodChannel('mobile/tone');
  final MethodChannel channel;
  VoicePreset _preset = VoicePreset.voice1;
  Future<bool>? _ready;
  int _seq = 0;
  _Speaking? _now;

  /// ずんだもんが使えるか（読み込みを始め、終わるまで待つ）。初回は声のファイルを
  /// 端末の中へ写すので数秒かかる。起動時に呼んでおくと、最初の発話を待たせない。
  Future<bool> warmUp() => _ready ??= _init();

  Future<bool> _init() async {
    try {
      return _loaded = await channel.invokeMethod<bool>('init') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 読み込みが終わって使えるか（[prepare] は読み込みを待たない）。
  bool _loaded = false;

  @override
  Future<void> speak(
    String text, {
    required VoidCallback onStart,
    ValueChanged<int>? onProgress,
  }) async {
    // 音声認識の起動音を消すためにメディアの音を一瞬消していたら、話す前に戻す
    unawaited(
      _tone.invokeMethod<void>('unmuteMusic').catchError((Object _) {}),
    );
    final style = styleFor(_preset);
    if (style == null || !await warmUp()) {
      return fallback.speak(text, onStart: onStart, onProgress: onProgress);
    }
    final id = ++_seq;
    final s = _now = _Speaking(id, text.length, onStart, onProgress);
    try {
      await channel.invokeMethod<bool>('speak', {
        'id': id,
        'text': text,
        'styleId': style,
        'speed': speed,
      });
    } catch (_) {
      // 作れなかったときも、読み上げの列は止めない
    } finally {
      s.end();
      if (identical(_now, s)) _now = null;
    }
  }

  /// 次に話す文を、端末の中で先に作っておく（話す番が来たら、作ってあるものをすぐ鳴らす）。
  @override
  void prepare(String text) {
    final style = styleFor(_preset);
    if (style == null || !_loaded) return;
    channel
        .invokeMethod<void>('prepare', {
          'text': text,
          'styleId': style,
          'speed': speed,
        })
        .catchError((_) {});
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method != 'started') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final s = _now;
    if (s == null || args['id'] != s.id) return null; // 止めた前の発話の通知
    s.start((args['durationMs'] as num?)?.toInt() ?? 0);
    return null;
  }

  @override
  Future<void> stop() async {
    _now?.end();
    _now = null;
    try {
      await channel.invokeMethod<void>('stop');
    } catch (_) {}
    await fallback.stop();
  }

  @override
  Future<void> useVoice(VoicePreset preset) async {
    _preset = preset;
    // 端末の声（声1・声2）のときだけ、端末の TTS の声を切り替える
    if (styleFor(preset) == null) await fallback.useVoice(preset);
  }
}

/// 話している1文。字幕の進みを時間で動かす。
class _Speaking {
  _Speaking(this.id, this.length, this.onStart, this.onProgress);

  final int id;
  final int length;
  final VoidCallback onStart;
  final ValueChanged<int>? onProgress;
  Timer? _timer;
  bool _ended = false;

  void start(int durationMs) {
    if (_ended) return;
    onStart();
    final progress = onProgress;
    if (progress == null || durationMs <= 0) return;
    final sw = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final r = sw.elapsedMilliseconds / durationMs;
      progress((length * r).clamp(0, length).floor());
    });
  }

  void end() {
    _ended = true;
    _timer?.cancel();
    _timer = null;
  }
}

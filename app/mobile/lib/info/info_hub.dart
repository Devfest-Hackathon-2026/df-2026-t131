import 'dart:async';

import '../executors/speak_executor.dart';
import 'info_kind.dart';
import 'info_source.dart';

/// 届いた情報の行き先。
///
/// 今は engine が無いので [DirectSpeakSink] で直接読み上げる。
/// engine をつないだら、警報は `AlertReceived`、交通・イベントは engine の入力に渡す Sink に替える
/// （話すか・待つか・捨てるかは engine が決める。CLAUDE.md 5章）。
abstract class InfoSink {
  void deliver(InfoItem item);
}

/// engine が来るまでの仮のつなぎ：優先度表（CLAUDE.md 4章）のとおりに読み上げに渡す。
/// TODO(engine): engine の雛形をつないだら EngineSink に置き換える。
class DirectSpeakSink implements InfoSink {
  DirectSpeakSink(this.speaker);

  final SpeakExecutor speaker;

  @override
  void deliver(InfoItem item) => speaker.execute(
    SpeakRequest(
      utteranceId: '${item.kind.name}_${item.id}',
      text: item.text,
      priority: item.kind.priority,
      interrupt: item.interrupts,
      pauseMusic: item.kind.pauseMusic,
      level: item.level ?? 0,
      expiresMs: item.expiresMs,
    ),
  );
}

/// 情報の入口（[InfoSource]）をまとめ、重複を除き、期限切れを捨て、行き先（[InfoSink]）へ渡す。
///
/// 種類を足すときは、入口を作って [register] するだけでよい（ここは変えない）。
class InfoHub {
  InfoHub({
    required this.sink,
    required this.now,
    this.onAccepted,
    this.isEnabled,
  });

  InfoSink sink;
  final int Function() now;

  /// 受け付けた情報を記録する（歩行ログの `alert` 行など）。
  final void Function(InfoItem item)? onAccepted;

  /// 種類ごとのオン・オフ（設定）。null なら全部オン。
  final bool Function(InfoKind kind)? isEnabled;

  final Map<InfoKind, InfoSource> _sources = {};
  final List<StreamSubscription<InfoItem>> _subs = [];
  final Set<String> _seen = {};
  bool _started = false;

  /// 登録した入口（設定画面で、種類ごとの状態を出す）。
  Map<InfoKind, InfoSource> get sources => Map.unmodifiable(_sources);

  InfoReadiness readinessOf(InfoKind kind) =>
      _sources[kind]?.readiness ?? InfoReadiness.planned;

  void register(InfoSource source) {
    _sources[source.kind] = source;
    if (_started) _listen(source);
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final s in _sources.values) {
      _listen(s);
    }
  }

  void _listen(InfoSource s) {
    _subs.add(s.items.listen(accept));
    unawaited(s.start());
  }

  /// 届いた1件を受ける。受け付けたら true。
  bool accept(InfoItem item) {
    if (isEnabled != null && !isEnabled!(item.kind)) return false;
    // 同じ情報の再送は無視する（schema/README.md「FCM の警報の送り方」）
    if (!_seen.add('${item.kind.name}:${item.id}')) return false;
    final exp = item.expiresMs;
    if (exp != null && now() > exp) return false;
    onAccepted?.call(item);
    sink.deliver(item);
    return true;
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final s in _sources.values) {
      await s.stop();
    }
    _started = false;
  }
}

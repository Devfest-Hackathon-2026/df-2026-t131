import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// 呼び出しの回数を抑える（たたきすぎ防止）。
///
/// - [window] の間に [maxCalls] 回まで
/// - 前の呼び出しから [minInterval] は空ける
///
/// 端末の時計に頼らず、渡された [now]（ミリ秒）で数える（テストで時間を進められる）。
class RateLimiter {
  RateLimiter({
    required this.maxCalls,
    required this.window,
    this.minInterval = Duration.zero,
    required this.now,
  }) : assert(maxCalls > 0);

  final int maxCalls;
  final Duration window;
  final Duration minInterval;
  final int Function() now;
  final _calls = Queue<int>();

  void _forgetOld(int t) {
    while (_calls.isNotEmpty && t - _calls.first >= window.inMilliseconds) {
      _calls.removeFirst();
    }
  }

  /// 今呼んでよいなら記録して true。だめなら false（記録しない）。
  bool tryAcquire() {
    final t = now();
    if (waitMs(t) > 0) return false;
    _calls.addLast(t);
    return true;
  }

  /// あと何ミリ秒待てば呼べるか（0 なら今呼べる）。
  int waitMs([int? at]) {
    final t = at ?? now();
    _forgetOld(t);
    var wait = 0;
    if (_calls.isNotEmpty) {
      wait = minInterval.inMilliseconds - (t - _calls.last);
    }
    if (_calls.length >= maxCalls) {
      final free = window.inMilliseconds - (t - _calls.first);
      if (free > wait) wait = free;
    }
    return wait < 0 ? 0 : wait;
  }
}

/// 失敗したときの待ち時間を、回数ごとに倍にする（上限あり）。決まった回数で諦める。
class Backoff {
  Backoff({
    this.first = const Duration(seconds: 30),
    this.max = const Duration(minutes: 10),
    this.maxAttempts = 4,
  });

  final Duration first;
  final Duration max;
  final int maxAttempts;

  /// n 回目（0 始まり）の試行の前に待つ時間。諦めるなら null。
  Duration? delayBefore(int attempt) {
    if (attempt >= maxAttempts) return null;
    if (attempt == 0) return Duration.zero;
    final ms = first.inMilliseconds * (1 << (attempt - 1));
    return Duration(
      milliseconds: ms > max.inMilliseconds ? max.inMilliseconds : ms,
    );
  }
}

/// 「最後にいつ成功したか」をファイルに覚えておく（アプリを起動し直しても、同じ呼び出しを繰り返さないため）。
class CallMemo {
  CallMemo(this._file);

  final Future<File> Function() _file;

  Future<Map<String, Object?>> _read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      final j = jsonDecode(await f.readAsString());
      return j is Map<String, Object?> ? j : {};
    } catch (_) {
      return {}; // 読めなければ覚えていないことにする（呼び直すだけ）
    }
  }

  Future<int?> lastSuccessMs(String key) async {
    final v = (await _read())[key];
    return v is int ? v : null;
  }

  Future<void> recordSuccess(String key, int tMs) async {
    try {
      final m = await _read();
      m[key] = tMs;
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(m), flush: true);
    } catch (_) {
      // 書けなくても動きは変わらない（次の起動でもう一度呼ぶだけ）
    }
  }
}

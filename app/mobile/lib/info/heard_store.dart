import 'dart:convert';
import 'dart:io';

/// 一度受け付けた情報（警報など）の ID を、アプリを起動し直しても覚えておく。
///
/// アプリを起動し直すと [InfoHub] の「聞いた」記録は消えるので、続いている警報が
/// 警報の一覧（Cloud Storage）や預かりの分から届くたびに、同じ警報を何度も話してしまう。
/// それを防ぐため、受け付けた ID と時刻をファイルに残す。中身は ID と時刻だけ（位置や文は残さない）。
class HeardStore {
  HeardStore(this._file, {this.keepFor = const Duration(hours: 48)});

  final Future<File> Function() _file;

  /// これより前に聞いたものは忘れる（ファイルを大きくしない。警報はこの間に変わる）。
  final Duration keepFor;

  /// 覚えておく上限の件数。
  static const maxEntries = 200;

  final Map<String, int> _heard = {};

  /// 覚えている ID（[InfoHub] の重複判定のキー）。
  Iterable<String> get keys => _heard.keys;

  Future<void> load({required int nowMs}) async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString());
      if (m is! Map) return;
      for (final e in m.entries) {
        final t = e.value;
        if (e.key is String &&
            t is int &&
            nowMs - t <= keepFor.inMilliseconds) {
          _heard[e.key as String] = t;
        }
      }
    } catch (_) {
      // 壊れていたら覚えていないものとして続ける
    }
  }

  Future<void> add(String key, {required int nowMs}) async {
    _heard[key] = nowMs;
    _heard.removeWhere((_, t) => nowMs - t > keepFor.inMilliseconds);
    if (_heard.length > maxEntries) {
      final old = _heard.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final e in old.take(_heard.length - maxEntries)) {
        _heard.remove(e.key);
      }
    }
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_heard), flush: true);
    } catch (_) {
      // 書けなくても読み上げは止めない
    }
  }
}

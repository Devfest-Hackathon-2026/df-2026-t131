import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// JSON Lines を1行ずつ追記する。5秒ごとと閉じるときに書き出す（落ちても数秒分しか失わない）。
/// 画像は渡さないこと（呼ぶ側の約束）。
class JsonlWriter {
  JsonlWriter._(this.file, this._sink, Duration flushEvery) {
    _timer = Timer.periodic(flushEvery, (_) => flush());
  }

  final File file;
  final IOSink _sink;
  late final Timer _timer;
  bool _closed = false;
  Future<void> _pending = Future.value();
  int lines = 0;

  static Future<JsonlWriter> open(
    File file, {
    Duration flushEvery = const Duration(seconds: 5),
  }) async {
    await file.parent.create(recursive: true);
    return JsonlWriter._(
      file,
      file.openWrite(mode: FileMode.append),
      flushEvery,
    );
  }

  void write(Map<String, Object?> row) {
    if (_closed) return;
    _sink.writeln(jsonEncode(row));
    lines++;
  }

  /// 前の書き出しが終わってから次を始める（IOSink は同時に flush できない）。
  Future<void> flush() {
    if (_closed) return _pending;
    _pending = _pending.then((_) => _sink.flush()).catchError((Object _) {});
    return _pending;
  }

  Future<void> close() async {
    if (_closed) return;
    await flush();
    _closed = true;
    _timer.cancel();
    await _sink.close();
  }
}

/// `walk_20261105T013000Z.jsonl` のようなファイル名（開始時刻の UTC）。
/// フェイク GPS で記録したときは [fake] で名前に `_fake` を付け、本物の歩行と取り違えないようにする。
String walkFileName(DateTime startUtc, {bool fake = false}) {
  final t = startUtc.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'walk_${t.year}${two(t.month)}${two(t.day)}T'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}Z${fake ? '_fake' : ''}.jsonl';
}

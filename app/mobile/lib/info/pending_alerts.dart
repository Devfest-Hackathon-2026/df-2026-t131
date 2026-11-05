import 'dart:convert';
import 'dart:io';

/// アプリが閉じている間に FCM で届いた警報を、次にアプリを開いたときまで預かっておく。
///
/// 閉じている間に届くと、FCM は裏の isolate だけを起こす。そこには読み上げが無いので、
/// data を1行ずつファイルに足しておき、前面のアプリがつないだときに [drain] で受け取る。
/// 中身は気象庁の発表をテンプレートにした警報の文だけ（位置などは入らない）。
class PendingAlertStore {
  PendingAlertStore(this._file);

  final Future<File> Function() _file;

  /// 預かる上限（壊れた送り手が大量に送っても、ファイルが大きくならないように）。
  static const maxEntries = 20;

  Future<void> add(Map<String, Object?> data, {required int receivedMs}) async {
    final f = await _file();
    final lines = await _read(f);
    lines.add(jsonEncode({'received_ms': receivedMs, 'data': data}));
    final keep = lines.length > maxEntries
        ? lines.sublist(lines.length - maxEntries)
        : lines;
    await f.parent.create(recursive: true);
    await f.writeAsString('${keep.join('\n')}\n', flush: true);
  }

  /// 預かっている分を古い順に取り出し、ファイルを消す。
  /// [maxAgeMs] より前に届いたものは捨てる（古い警報を今出たように話さない）。
  Future<List<({Map<String, Object?> data, int receivedMs})>> drain({
    required int nowMs,
    required int maxAgeMs,
  }) async {
    final f = await _file();
    final lines = await _read(f);
    if (await f.exists()) await f.delete();
    final out = <({Map<String, Object?> data, int receivedMs})>[];
    for (final l in lines) {
      try {
        final m = jsonDecode(l);
        if (m is! Map) continue;
        final t = m['received_ms'];
        final d = m['data'];
        if (t is! int || d is! Map) continue;
        if (nowMs - t > maxAgeMs) continue;
        out.add((data: Map<String, Object?>.from(d), receivedMs: t));
      } on FormatException {
        // 壊れた行は飛ばす
      }
    }
    return out;
  }

  static Future<List<String>> _read(File f) async {
    if (!await f.exists()) return [];
    final text = await f.readAsString();
    return text.split('\n').where((l) => l.trim().isNotEmpty).toList();
  }
}

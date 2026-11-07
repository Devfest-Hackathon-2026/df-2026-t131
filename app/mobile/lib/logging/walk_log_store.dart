import 'dart:io';

/// 端末に保存した歩行ログ1件。
class WalkLogInfo {
  const WalkLogInfo({
    required this.file,
    required this.bytes,
    required this.modified,
  });

  final File file;
  final int bytes;
  final DateTime modified;

  String get name => file.uri.pathSegments.last;
}

/// 歩行ログ（walk_*.jsonl）の一覧と削除。位置を含むので、利用者がいつでも消せるようにする。
class WalkLogStore {
  WalkLogStore(this._directory, {String? Function()? inUse})
    : _inUse = inUse ?? _none;

  final Future<Directory> Function() _directory;

  /// 今書いている（記録中の）ファイル名。これは消さない。
  final String? Function() _inUse;
  static String? _none() => null;

  bool isInUse(WalkLogInfo log) => log.name == _inUse();

  static bool _isWalkLog(String name) =>
      name.startsWith('walk_') && name.endsWith('.jsonl');

  /// 新しい順。
  Future<List<WalkLogInfo>> list() async {
    final dir = await _directory();
    if (!await dir.exists()) return const [];
    final out = <WalkLogInfo>[];
    await for (final e in dir.list()) {
      if (e is! File || !_isWalkLog(e.uri.pathSegments.last)) continue;
      final st = await e.stat();
      out.add(WalkLogInfo(file: e, bytes: st.size, modified: st.modified));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// 消したら true。記録中のファイルは消さない。
  /// 開発者モードで保存した、送った画像のフォルダ（[sentImagesDir]）も一緒に消す。
  Future<bool> delete(WalkLogInfo log) async {
    if (isInUse(log)) return false;
    if (await log.file.exists()) await log.file.delete();
    final images = sentImagesDir(log.file);
    if (await images.exists()) await images.delete(recursive: true);
    return true;
  }

  /// 記録中以外をすべて消して、消した件数を返す。歩行ログ以外のファイルには触らない。
  Future<int> deleteAll() async {
    var n = 0;
    for (final l in await list()) {
      if (await delete(l)) n++;
    }
    return n;
  }
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 歩行ログ `walk_〇〇.jsonl` に対応する、AI に送った画像（顔ぼかし後）の置き場所
/// `walk_〇〇_images/`（開発者モードで保存をオンにしたときだけ作る）。画像の名前は `<検索 ID>.jpg`。
Directory sentImagesDir(File walkLog) {
  final path = walkLog.path;
  final base = path.endsWith('.jsonl')
      ? path.substring(0, path.length - '.jsonl'.length)
      : path;
  return Directory('${base}_images');
}

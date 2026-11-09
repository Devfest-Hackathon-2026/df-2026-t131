import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_client.dart';

/// z16 の地図タイルの番号。
class TileId {
  const TileId(this.x, this.y, {this.z = 16});

  final int z;
  final int x;
  final int y;

  /// `16/57746/25576` の形（engine の `tileKey` と同じ）。
  String get key => '$z/$x/$y';

  factory TileId.at(double lat, double lon) {
    final (x, y) = tileXY(lat, lon);
    return TileId(x, y);
  }

  @override
  bool operator ==(Object other) =>
      other is TileId && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => key;
}

/// タイルに入っているランドマーク（画面の表示に使う分だけ）。
class TileLandmark {
  const TileLandmark({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.kind,
  });

  final String id;
  final String name;
  final double lat;
  final double lon;
  final String kind;
}

/// 届いたタイル1枚（`schema/api/tile.response.schema.json`）。
/// [json] は engine の `TilesLoaded` にそのまま渡す中身。
class TileData {
  const TileData(this.id, this.json);

  final TileId id;
  final Map<String, Object?> json;

  static const _lists = ['landmarks', 'stops', 'crossings', 'events'];

  /// 語る対象も横断歩道も無い（デモの範囲の外）。
  bool get isEmpty =>
      _lists.every((k) => json[k] is! List || (json[k] as List).isEmpty);

  List<TileLandmark> get landmarks => [
    for (final m in (json['landmarks'] as List?) ?? const [])
      if (m is Map &&
          m['id'] is String &&
          m['name'] is String &&
          m['lat'] is num &&
          m['lon'] is num)
        TileLandmark(
          id: m['id'] as String,
          name: m['name'] as String,
          lat: (m['lat'] as num).toDouble(),
          lon: (m['lon'] as num).toDouble(),
          kind: m['kind'] as String? ?? 'other',
        ),
  ];
}

/// 届いたタイルを端末に残す（起動し直しても取り直さない）。
/// 中身は公開のランドマークの原稿などで、自分の位置は入らない（どのタイルを取ったかは分かる）。
class TileCache {
  TileCache(this._dir);

  final Future<Directory> Function() _dir;

  Future<File> _file(TileId t) async =>
      File('${(await _dir()).path}/${t.z}_${t.x}_${t.y}.json');

  Future<({Map<String, Object?> json, int savedMs})?> read(TileId t) async {
    try {
      final f = await _file(t);
      if (!await f.exists()) return null;
      final m = jsonDecode(await f.readAsString());
      if (m is! Map || m['saved_ms'] is! int || m['body'] is! Map) return null;
      return (
        json: Map<String, Object?>.from(m['body'] as Map),
        savedMs: m['saved_ms'] as int,
      );
    } catch (_) {
      return null; // 壊れていたら無いものとして取り直す
    }
  }

  Future<void> clear() async {
    try {
      final d = await _dir();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // 消せなくても、12時間たてば取り直す
    }
  }

  Future<void> write(TileId t, Map<String, Object?> json, int nowMs) async {
    try {
      final f = await _file(t);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({'saved_ms': nowMs, 'body': json}));
    } catch (_) {
      // 残せなくても動く（次の起動で取り直すだけ）
    }
  }
}

/// A の地図タイルを取りに行く（engine の `FetchTiles` を実行する係）。どのタイルを取るかは決めない。
///
/// - 一度届いたタイルは覚えておき、[keepFor] の間は取り直さない（中身はほとんど変わらない）
/// - **空のタイル（デモの範囲の外）も覚える。** 範囲の外を歩き回っても、同じタイルを何度も問い合わせない
/// - [inRange] が分かっていれば、範囲の外のタイルは問い合わせもしない（今はデータのある
///   タイルの一覧を渡していないので、すべて問い合わせる）
/// - 失敗したタイルは [retryAfter] の間は頼み直さない。トークンが無い・違うときは全体を止める
/// - 送るのはタイル番号だけ（正確な位置は送らない。docs/design.md 3章5）
class TileFetcher {
  TileFetcher({
    required this.api,
    this.cache,
    int Function()? now,
    this.inRange,
    this.keepFor = const Duration(hours: 12),
    // engine は届かないタイルを30秒ごとに頼み直す。それを通すため、こちらは少し短くする
    this.retryAfter = const Duration(seconds: 20),
    this.authRetryAfter = const Duration(minutes: 10),
    this.maxParallel = 2,
  }) : _now = now ?? _systemMs;

  static int _systemMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  final ApiClient api;
  final TileCache? cache;
  final int Function() _now;
  final bool Function(TileId)? inRange;
  final Duration keepFor;
  final Duration retryAfter;
  final Duration authRetryAfter;
  final int maxParallel;

  final Map<TileId, TileData> _loaded = {};
  final Set<TileId> _inFlight = {};
  final Map<TileId, int> _failedAt = {};
  final List<TileId> _waiting = [];
  int? _authBlockedUntil;
  final _out = StreamController<TileData>.broadcast();

  /// 届いたタイル（キャッシュから読んだ分も）。engine には `TilesLoaded` として渡す。
  Stream<TileData> get loaded => _out.stream;

  /// 持っているタイル。
  Iterable<TileData> get tiles => _loaded.values;

  // ---- 開発者モードに出す数 ----
  int fetched = 0;
  int fromCache = 0;
  int empty = 0;
  int skippedOutOfRange = 0;
  int failed = 0;
  String lastResult = 'まだ取りに行っていません';

  bool has(TileId t) => _loaded.containsKey(t);

  /// 取得の指示（engine の `FetchTiles`）。持っている・取っている途中・少し前に失敗したタイルは飛ばす。
  void request(Iterable<TileId> tiles) {
    final now = _now();
    for (final t in tiles) {
      final have = _loaded[t];
      if (have != null) {
        // 持っているタイルも、頼まれたら渡し直す（新しい計測の engine は何も持っていないため）。
        // engine の処理の途中で呼ばれるので、渡すのは処理が終わってから
        scheduleMicrotask(() {
          if (!_out.isClosed) _out.add(have);
        });
        continue;
      }
      if (_inFlight.contains(t) || _waiting.contains(t)) continue;
      final failedAt = _failedAt[t];
      if (failedAt != null && now - failedAt < retryAfter.inMilliseconds) {
        continue;
      }
      if (inRange != null && !inRange!(t)) {
        // 範囲の外：問い合わせず、空のタイルとして扱う
        skippedOutOfRange++;
        _accept(TileData(t, _emptyBody(t)));
        continue;
      }
      _waiting.add(t);
    }
    _pump();
  }

  void _pump() {
    while (_waiting.isNotEmpty && _inFlight.length < maxParallel) {
      final t = _waiting.removeAt(0);
      _inFlight.add(t);
      unawaited(
        _fetch(t).whenComplete(() {
          _inFlight.remove(t);
          _pump();
        }),
      );
    }
  }

  Future<void> _fetch(TileId t) async {
    final now = _now();
    final c = await cache?.read(t);
    if (c != null && now - c.savedMs < keepFor.inMilliseconds) {
      fromCache++;
      _accept(TileData(t, c.json));
      return;
    }
    final blocked = _authBlockedUntil;
    if (blocked != null && now < blocked) {
      _failedAt[t] = now;
      return;
    }
    final r = await api.getTile(t.x, t.y);
    lastResult = '${t.key}：${r.check.label}';
    final json = r.json;
    if (!r.check.ok || json is! Map) {
      failed++;
      _failedAt[t] = _now();
      if (r.check.status == 401 || r.check.label == 'トークン未設定') {
        // トークンが無い・違う間は、全部のタイルをしばらく頼まない
        _authBlockedUntil = _now() + authRetryAfter.inMilliseconds;
      }
      return;
    }
    fetched++;
    final body = Map<String, Object?>.from(json);
    await cache?.write(t, body, _now());
    _accept(TileData(t, body));
  }

  void _accept(TileData d) {
    _loaded[d.id] = d;
    _failedAt.remove(d.id);
    if (d.isEmpty) empty++;
    if (!_out.isClosed) _out.add(d);
  }

  static Map<String, Object?> _emptyBody(TileId t) => {
    'schema_version': '0.3',
    'tile': {'z': t.z, 'x': t.x, 'y': t.y},
    'landmarks': const [],
    'stops': const [],
    'crossings': const [],
    'events': const [],
  };

  /// 覚えているタイルを全部忘れ、端末のキャッシュも消す（サーバーのデータを直したあと・デモの撮影の前）。
  Future<void> clear() async {
    _loaded.clear();
    _failedAt.clear();
    _authBlockedUntil = null;
    fetched = fromCache = empty = skippedOutOfRange = failed = 0;
    lastResult = 'キャッシュを消しました';
    await cache?.clear();
  }

  Future<void> dispose() => _out.close();
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

/// A の地図タイルを取りに行く（engine の `FetchTiles` を実行する側）。
///
/// - 一度届いたタイルは覚えておき、[keepFor] の間は取り直さない（中身はほとんど変わらない）
/// - **空のタイル（デモの範囲の外）も覚える。** 範囲の外を歩き回っても、同じタイルを何度も問い合わせない
/// - [inRange] が分かっていれば、範囲の外のタイルは問い合わせもしない（TODO(サーバー)：データのある
///   タイルの一覧をメンバー1が公開したら、それを渡す）
/// - 失敗したタイルは [retryAfter] の間は頼み直さない。トークンが無い・違うときは全体を止める
/// - 送るのはタイル番号だけ（正確な位置は送らない。CLAUDE.md 3章5）
class TileFetcher {
  TileFetcher({
    required this.api,
    this.cache,
    int Function()? now,
    this.inRange,
    this.keepFor = const Duration(hours: 12),
    this.retryAfter = const Duration(seconds: 30),
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
      if (_loaded.containsKey(t) ||
          _inFlight.contains(t) ||
          _waiting.contains(t)) {
        continue;
      }
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
    'tile': {'z': t.z, 'x': t.x, 'y': t.y},
    'landmarks': const [],
    'stops': const [],
    'crossings': const [],
    'events': const [],
  };

  Future<void> dispose() => _out.close();
}

/// engine とつながるまでの仮の先読み：engine の `_prefetch`（app/engine）と同じ決め方で、
/// 要るタイルを選ぶ。
///
/// 今の位置から、今の速度のまま [stepS] 秒刻みで [horizonS] 秒先まで進んだ点を出し、
/// それぞれの前後左右 [marginM] m の角が入るタイルを集める。止まっているとき（[minMovingMps] 未満
/// か進行方向が無い）は今の位置の周りだけ。
/// TODO(engine)：engine をつないだら、これは使わず engine の `FetchTiles` を [TileFetcher.request] に渡す。
Set<TileId> tilesAhead({
  required double lat,
  required double lon,
  double? speedMps,
  double? courseDeg,
  double horizonS = 150,
  double stepS = 10,
  double marginM = 150,
  double minMovingMps = 0.3,
}) {
  final moving =
      speedMps != null && courseDeg != null && speedMps >= minMovingMps;
  final steps = moving ? (horizonS / stepS).floor() : 0;
  // 東向き・北向きの速度（m/s）
  final rad = (courseDeg ?? 0) * math.pi / 180;
  final ve = moving ? speedMps * math.sin(rad) : 0.0;
  final vn = moving ? speedMps * math.cos(rad) : 0.0;
  const mPerDegLat = 111320.0;
  final mPerDegLon = mPerDegLat * math.cos(lat * math.pi / 180);
  final out = <TileId>{};
  for (var k = 0; k <= steps; k++) {
    final e = ve * k * stepS;
    final n = vn * k * stepS;
    for (final (de, dn) in [
      (0.0, 0.0),
      (-marginM, -marginM),
      (-marginM, marginM),
      (marginM, -marginM),
      (marginM, marginM),
    ]) {
      out.add(
        TileId.at(lat + (n + dn) / mPerDegLat, lon + (e + de) / mPerDegLon),
      );
    }
  }
  return out;
}

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'rate_limiter.dart';

/// サーバー（Cloud Run の API）を呼んだ結果。
class ApiCheck {
  const ApiCheck({
    required this.ok,
    required this.label,
    this.status,
    this.elapsedMs,
  });

  final bool ok;

  /// 画面に出す短い説明（例「OK（200・312 ms）」「トークン未設定」）。
  final String label;
  final int? status;
  final int? elapsedMs;
}

/// サーバーとのつながりの確認結果（生存確認と、トークンの確認）。
class ServerStatus {
  const ServerStatus({
    required this.health,
    required this.auth,
    required this.checkedMs,
  });

  final ApiCheck health;
  final ApiCheck auth;
  final int checkedMs;

  bool get ok => health.ok && auth.ok;
}

/// Cloud Run の API（tasks/README.md 2.4）を呼ぶ。
///
/// - `/health`：生存確認（トークン不要）
/// - `/v1/…`：`X-App-Token` ヘッダーを付ける。トークンは画面・ログ・print に出さない
/// - 8秒で打ち切る。呼びすぎないよう [limiter]（既定1分に30回）を通す
///
/// TODO: A のタイル取得（`FetchTiles`）と B の画像検索も、ここに足して同じ決まりで呼ぶ。
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required String token,
    http.Client? client,
    int Function()? now,
    RateLimiter? limiter,
    this.timeout = const Duration(seconds: 8),
  // トークンは外から読めない private にしておく
  // ignore: prefer_initializing_formals
  }) : _token = token,
       _client = client ?? http.Client(),
       _now = now ?? _systemMs,
       limiter =
           limiter ??
           RateLimiter(
             maxCalls: 30,
             window: const Duration(minutes: 1),
             now: now ?? _systemMs,
           );

  static int _systemMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  final String baseUrl;
  final String _token;
  final http.Client _client;
  final int Function() _now;
  final RateLimiter limiter;
  final Duration timeout;

  bool get hasUrl => baseUrl.isNotEmpty;
  bool get hasToken => _token.isNotEmpty;

  /// 画面に出してよい接続先（ホスト名だけ）。
  String get host => hasUrl ? Uri.parse(baseUrl).host : '未設定';

  Uri _uri(String path) => Uri.parse(
    baseUrl.endsWith('/') ? '$baseUrl${path.substring(1)}' : '$baseUrl$path',
  );

  Future<ApiCheck> _get(String path, {bool auth = false}) async {
    if (!hasUrl) return const ApiCheck(ok: false, label: 'URL 未設定');
    if (!limiter.tryAcquire()) {
      return const ApiCheck(ok: false, label: '呼びすぎ防止で待っています');
    }
    final start = _now();
    try {
      final res = await _client
          .get(_uri(path), headers: {if (auth) 'X-App-Token': _token})
          .timeout(timeout);
      final ms = _now() - start;
      final ok = res.statusCode == 200;
      return ApiCheck(
        ok: ok,
        status: res.statusCode,
        elapsedMs: ms,
        label: ok
            ? 'OK（${res.statusCode}・$ms ms）'
            : switch (res.statusCode) {
                401 => 'トークンが違います（401）',
                429 => 'サーバーが混んでいます（429）',
                _ => 'エラー（${res.statusCode}）',
              },
      );
    } on TimeoutException {
      return ApiCheck(ok: false, label: '時間切れ（${timeout.inSeconds}秒）');
    } on SocketException {
      return const ApiCheck(ok: false, label: 'つながりません（通信なし）');
    } on http.ClientException {
      return const ApiCheck(ok: false, label: 'つながりません');
    }
  }

  /// 生存確認。サーバーが動いていて、ここまで通信が届くか。
  Future<ApiCheck> health() => _get('/health');

  /// トークンの確認：富山駅のタイルを1枚取ってみる（今のサーバーは見本データなので費用はかからない）。
  Future<ApiCheck> checkAuth() async {
    if (!hasToken) return const ApiCheck(ok: false, label: 'トークン未設定');
    final (x, y) = tileXY(36.7013, 137.2133);
    return _get('/v1/tiles/16/$x/$y', auth: true);
  }

  Future<ServerStatus> check() async {
    final h = await health();
    final a = h.ok
        ? await checkAuth()
        : const ApiCheck(ok: false, label: '生存確認が通るまで待ちます');
    return ServerStatus(health: h, auth: a, checkedMs: _now());
  }

  void close() => _client.close();
}

/// 緯度経度から z16 のタイル番号（Web メルカトル）。
(int, int) tileXY(double lat, double lon, {int z = 16}) {
  final n = 1 << z;
  final x = ((lon + 180) / 360 * n).floor();
  final r = lat * math.pi / 180;
  final y = ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n)
      .floor();
  return (x, y);
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../net/rate_limiter.dart';
import 'alert_message.dart';

/// 今出ている警報の一覧（`schema/api/alerts_current.schema.json`）を取りに行く。
///
/// FCM のプッシュが届かなかったとき（アプリが閉じていた・通信が切れていた）の保険。
/// 置き場所は公開の Cloud Storage（トークン不要）。取りに行くのは区域コードのファイルだけで、
/// 位置は送らない。ETag を付け、変わっていなければ 304 で中身を受け取らない。
/// 一覧の警報は FCM と同じ alert_id なので、すでに聞いた警報は InfoHub が捨てる。
class AlertListFetcher {
  AlertListFetcher({
    required this.baseUrl,
    required this.onData,
    this.area = demoAlertArea,
    http.Client? client,
    int Function()? now,
    RateLimiter? limiter,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client(),
       _now = now ?? _systemMs,
       limiter =
           limiter ??
           RateLimiter(
             maxCalls: 10,
             window: const Duration(minutes: 10),
             now: now ?? _systemMs,
           );

  static int _systemMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  final String baseUrl;
  final String area;

  /// 一覧の警報1件ずつ（FCM の data と同じ形）を渡す先。
  final void Function(Map<String, Object?> data) onData;
  final http.Client _client;
  final int Function() _now;

  /// 模擬の一覧は、書き換えからこれより経っていたら読まない。
  /// サーバーの模擬の一覧には最後に送った模擬の警報が残り続けるので、起動し直すたびに
  /// 古い模擬の警報を読まないため（撮影中に鳴らさない）。本物の一覧には使わない。
  static const mockMaxAge = Duration(minutes: 10);
  final RateLimiter limiter;
  final Duration timeout;
  final Map<String, String> _etags = {};

  /// 最後に取りに行った結果（開発者モードに出す）。
  String lastResult = 'まだ取りに行っていません';

  /// 歩いている間に取り直す間隔（schema の決まり）。
  static const refreshEvery = Duration(minutes: 15);

  Uri _uri({required bool mock}) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/alerts/current/${mock ? 'mock_' : ''}$area.json');
  }

  /// 取りに行き、届いた警報を [onData] へ渡す。渡した件数を返す（変わっていない・失敗は 0）。
  /// [mock] なら、デモ用の模擬の警報の一覧（`mock_<区域>.json`）を取る。
  Future<int> fetch({bool mock = false}) async {
    final name = mock ? '模擬の一覧' : '一覧';
    if (baseUrl.isEmpty) {
      lastResult = '$name：置き場所が未設定';
      return 0;
    }
    if (!limiter.tryAcquire()) {
      lastResult = '$name：呼びすぎ防止で待っています';
      return 0;
    }
    final uri = _uri(mock: mock);
    final key = uri.toString();
    try {
      final res = await _client
          .get(uri, headers: {'If-None-Match': ?_etags[key]})
          .timeout(timeout);
      if (res.statusCode == 304) {
        lastResult = '$name：変わりなし（304）';
        return 0;
      }
      if (res.statusCode == 404) {
        lastResult = '$name：まだありません（404）';
        return 0;
      }
      if (res.statusCode != 200) {
        lastResult = '$name：エラー（${res.statusCode}）';
        return 0;
      }
      final etag = res.headers['etag'];
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      final list = json is Map
          ? alertListToData(Map<String, Object?>.from(json))
          : null;
      if (list == null) {
        lastResult = '$name：形が違います';
        return 0;
      }
      if (etag != null) _etags[key] = etag;
      if (mock) {
        final updated = json['updated_at_ms'];
        final ageMs = updated is int ? _now() - updated : null;
        if (ageMs == null || ageMs > mockMaxAge.inMilliseconds) {
          lastResult = ageMs == null
              ? '$name：書き換えの時刻が無いので読みません'
              : '$name：${ageMs ~/ 60000}分前のものなので読みません';
          return 0;
        }
      }
      for (final d in list) {
        onData(d);
      }
      lastResult = '$name：${list.length}件（200）';
      return list.length;
    } on TimeoutException {
      lastResult = '$name：時間切れ';
    } on SocketException {
      lastResult = '$name：つながりません（通信なし）';
    } on http.ClientException {
      lastResult = '$name：つながりません';
    } on FormatException {
      lastResult = '$name：形が違います';
    }
    return 0;
  }

  void close() => _client.close();
}

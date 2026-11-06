import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/net/api_client.dart';

void main() {
  test('生存確認はトークンを付けず、タイルはトークンを付ける', () async {
    final seen = <String, String?>{};
    final api = ApiClient(
      baseUrl: 'https://example.run.app',
      token: 'secret-token',
      client: MockClient((req) async {
        seen[req.url.path] = req.headers['X-App-Token'];
        return http.Response('{"status":"ok"}', 200);
      }),
    );
    final st = await api.check();
    expect(st.ok, isTrue);
    expect(seen['/health'], isNull);
    final tilePath = seen.keys.firstWhere((p) => p.startsWith('/v1/tiles/16/'));
    expect(seen[tilePath], 'secret-token');
    expect(st.health.label, startsWith('OK（200'));
    expect(st.auth.label.contains('secret'), isFalse); // 画面にトークンを出さない
  });

  test('富山駅は z16 のタイル 57746, 25576', () {
    final (x, y) = tileXY(36.7013, 137.2133);
    expect(x, 57746);
    expect(y, 25576);
  });

  test('トークンが無い・違う', () async {
    final api = ApiClient(
      baseUrl: 'https://example.run.app',
      token: '',
      client: MockClient((_) async => http.Response('{"status":"ok"}', 200)),
    );
    expect((await api.check()).auth.label, 'トークン未設定');
    final bad = ApiClient(
      baseUrl: 'https://example.run.app',
      token: 'x',
      client: MockClient(
        (r) async => r.url.path == '/health'
            ? http.Response('{}', 200)
            : http.Response('{"error":"unauthorized"}', 401),
      ),
    );
    expect((await bad.check()).auth.label, 'トークンが違います（401）');
  });

  test('つながらない・時間切れ・URL 未設定', () async {
    final down = ApiClient(
      baseUrl: 'https://example.run.app',
      token: '',
      client: MockClient((_) async => throw const SocketException('no')),
    );
    expect((await down.health()).label, 'つながりません（通信なし）');
    final slow = ApiClient(
      baseUrl: 'https://example.run.app',
      token: '',
      timeout: const Duration(milliseconds: 10),
      client: MockClient((_) => Completer<http.Response>().future),
    );
    expect((await slow.health()).label, startsWith('時間切れ'));
    expect((await ApiClient(baseUrl: '', token: '').health()).label, 'URL 未設定');
  });

  test('呼びすぎ防止（1分に30回まで）', () async {
    final api = ApiClient(
      baseUrl: 'https://example.run.app',
      token: '',
      now: () => 0,
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    for (var i = 0; i < 30; i++) {
      expect((await api.health()).ok, isTrue);
    }
    expect((await api.health()).label, '呼びすぎ防止で待っています');
  });

  test('context を知らない古い API が 400 を返したら、context を外して一度だけ送り直す', () async {
    final bodies = <String>[];
    final api = ApiClient(
      baseUrl: 'https://example.run.app',
      token: 't',
      client: MockClient((req) async {
        bodies.add(req.body);
        return req.body.contains('"context"')
            ? http.Response('{"error":"bad_request"}', 400)
            : http.Response('{"ok":true}', 200);
      }),
    );
    final r = await api.postVisualSearch({
      'search_id': 's_000001',
      'context': {'trigger': 'auto'},
    });
    expect(r.error, isNull);
    expect(bodies, hasLength(2));
    expect(bodies.last.contains('context'), isFalse);

    // context が無い 400 は送り直さない
    bodies.clear();
    final r2 = await ApiClient(
      baseUrl: 'https://example.run.app',
      token: 't',
      client: MockClient((req) async {
        bodies.add(req.body);
        return http.Response('{"error":"bad_request"}', 400);
      }),
    ).postVisualSearch({'search_id': 's_000002'});
    expect(r2.error, 'server');
    expect(bodies, hasLength(1));
  });
}

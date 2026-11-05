import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/info/alert_list_fetcher.dart';
import 'package:mobile/info/alert_message.dart';
import 'package:mobile/info/heard_store.dart';
import 'package:mobile/info/info_hub.dart';
import 'package:mobile/info/info_source.dart';
import 'package:mobile/info/pending_alerts.dart';
import 'package:mobile/info/sources.dart';

class _Sink implements InfoSink {
  final got = <InfoItem>[];
  @override
  void deliver(InfoItem item) => got.add(item);
}

/// schema/examples/alerts/current_1620100.json と同じ形（中身は架空）。
const _list = {
  'schema_version': '0.3',
  'area_code': '1620100',
  'area_name': '富山市',
  'updated_at_ms': 1793581200000,
  'alerts': [
    {
      'alert_id': 'sample_1',
      'level': '4',
      'kind': '大雨危険警報',
      'text': '見本の警報です。富山市には、大雨危険警報が発表されています。',
    },
  ],
};

void main() {
  test('トピックは区域7桁と、移行の間の前の形の2つ', () {
    expect(alertTopics, ['alert_1620100', 'alert_16201']);
    final a = parseAlertData(mockAlertData(level: 4, nowMs: 1), receivedMs: 1)!;
    expect(a.data['area_code'], '1620100');
    // 歩行ログの alert 行には area_code を入れない（eventlog の schema に無い）
    expect(alertRowData(a).containsKey('area_code'), isFalse);
  });

  test('警報の一覧を FCM と同じ形に直し、同じ警報は2回渡さない', () async {
    var now = 1000;
    final sink = _Sink();
    final alerts = AlertSource(now: () => now);
    final hub = InfoHub(sink: sink, now: () => now)..register(alerts);
    await hub.start();

    final etags = <String?>[];
    final client = MockClient((req) async {
      etags.add(req.headers['If-None-Match']);
      expect(req.url.path, '/bucket/alerts/current/1620100.json');
      if (req.headers['If-None-Match'] == '"e1"') {
        return http.Response('', 304);
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode(_list)),
        200,
        headers: {'etag': '"e1"'},
      );
    });
    final f = AlertListFetcher(
      baseUrl: 'https://example.test/bucket/',
      onData: alerts.receive,
      client: client,
      now: () => now,
    );
    expect(await f.fetch(), 1);
    expect(sink.got.single.level, 4);
    expect(sink.got.single.interrupts, isTrue);
    // FCM で同じ警報が届いても話さない
    alerts.receive({
      'type': 'alert',
      'alert_id': 'sample_1',
      'level': '4',
      'kind': '大雨危険警報',
      'area_name': '富山市',
      'text': '…発表されました。',
    });
    expect(sink.got, hasLength(1));
    // 2回目は ETag を付け、304 なら何も渡さない
    expect(await f.fetch(), 0);
    expect(etags, [null, '"e1"']);
    expect(f.lastResult, contains('304'));
  });

  test('模擬の一覧は mock_ のファイル・つながらないときは理由を残す', () async {
    final paths = <String>[];
    final f = AlertListFetcher(
      baseUrl: 'https://example.test/b',
      onData: (_) {},
      client: MockClient((req) async {
        paths.add(req.url.path);
        throw const SocketException('offline');
      }),
    );
    expect(await f.fetch(mock: true), 0);
    expect(paths, ['/b/alerts/current/mock_1620100.json']);
    expect(f.lastResult, contains('つながりません'));
  });

  test('閉じている間に届いた警報を預かり、古すぎるものは捨てる', () async {
    final dir = await Directory.systemTemp.createTemp('pending');
    final store = PendingAlertStore(
      () async => File('${dir.path}/sub/pending.jsonl'),
    );
    await store.add(mockAlertData(level: 4, nowMs: 1), receivedMs: 1000);
    await store.add(mockAlertData(level: 3, nowMs: 2), receivedMs: 9000);
    final got = await store.drain(nowMs: 10000, maxAgeMs: 5000);
    expect(got, hasLength(1));
    expect(got.single.receivedMs, 9000);
    expect(got.single.data['level'], '3');
    // 取り出したら消える
    expect(await store.drain(nowMs: 10000, maxAgeMs: 5000), isEmpty);
    await dir.delete(recursive: true);
  });
  test('模擬の一覧は書き換えから10分より前なら読まない（本物の一覧は読む）', () async {
    const now = 100 * 60 * 1000;
    Map<String, Object?> listAt(int updated) => {
      ..._list,
      'updated_at_ms': updated,
      'alerts': [
        {
          'alert_id': 'mock_$updated',
          'level': '4',
          'kind': '大雨危険警報',
          'text': 'これはデモ用の模擬の警報です。',
        },
      ],
    };
    var updated = now - 11 * 60 * 1000;
    final got = <Object?>[];
    final f = AlertListFetcher(
      baseUrl: 'https://example.test/b',
      onData: (d) => got.add(d['alert_id']),
      now: () => now,
      client: MockClient(
        (req) async =>
            http.Response.bytes(utf8.encode(jsonEncode(listAt(updated))), 200),
      ),
    );
    expect(await f.fetch(mock: true), 0);
    expect(f.lastResult, contains('11分前'));
    expect(await f.fetch(), 1); // 本物の一覧は古くても読む（続いている警報）
    updated = now - 9 * 60 * 1000;
    expect(await f.fetch(mock: true), 1);
    expect(got, [
      'mock_${now - 11 * 60 * 1000}',
      'mock_${now - 9 * 60 * 1000}',
    ]);
  });

  test('聞いた警報は起動し直しても2回話さない（48時間で忘れる）', () async {
    final dir = await Directory.systemTemp.createTemp('heard');
    File file() => File('${dir.path}/heard.json');
    var now = 1000;
    Future<_Sink> boot() async {
      final sink = _Sink();
      final alerts = AlertSource(now: () => now);
      final hub = InfoHub(
        sink: sink,
        now: () => now,
        heard: HeardStore(() async => file()),
      )..register(alerts);
      await hub.start();
      alerts.receive(mockAlertData(level: 4, nowMs: 1)); // 同じ alert_id
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return sink;
    }

    expect((await boot()).got, hasLength(1)); // 1回目の起動：話す
    expect((await boot()).got, isEmpty); // 起動し直し：話さない
    now += const Duration(hours: 49).inMilliseconds;
    expect((await boot()).got, hasLength(1)); // 48時間を過ぎたら忘れる
    await dir.delete(recursive: true);
  });
}

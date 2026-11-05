import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/info/alert_message.dart';
import 'package:mobile/info/fcm_alerts.dart';
import 'package:mobile/info/sources.dart';
import 'package:mobile/net/rate_limiter.dart';

void main() {
  test('決まった時間に決まった回数まで・間隔も空ける', () {
    var now = 0;
    final l = RateLimiter(
      maxCalls: 3,
      window: const Duration(minutes: 1),
      minInterval: const Duration(seconds: 5),
      now: () => now,
    );
    expect(l.tryAcquire(), isTrue);
    expect(l.tryAcquire(), isFalse); // 5秒空いていない
    now = 5000;
    expect(l.tryAcquire(), isTrue);
    now = 10000;
    expect(l.tryAcquire(), isTrue);
    now = 20000;
    expect(l.tryAcquire(), isFalse); // 1分に3回まで
    expect(l.waitMs(), 40000);
    now = 60000;
    expect(l.tryAcquire(), isTrue);
  });

  test('失敗したら間を倍に空け、決まった回数で諦める', () {
    final b = Backoff(
      first: const Duration(seconds: 30),
      max: const Duration(minutes: 1),
      maxAttempts: 4,
    );
    expect(
      [for (var i = 0; i < 5; i++) b.delayBefore(i)?.inSeconds],
      [0, 30, 60, 60, null],
    );
  });

  group('トピックの購読', () {
    late Directory dir;
    late int now;
    late List<String> calls;
    late List<Duration> slept;
    late bool fail;

    TopicSubscriber make() => TopicSubscriber(
      subscribe: (t) async {
        calls.add(t);
        if (fail) throw const SocketException('つながらない');
      },
      memo: CallMemo(() async => File('${dir.path}/fcm_state.json')),
      now: () => now,
      sleep: (d) async => slept.add(d),
    );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fcm');
      now = 1000;
      calls = [];
      slept = [];
      fail = false;
    });
    tearDown(() => dir.delete(recursive: true));

    test('成功したら24時間は起動し直しても呼ばない', () async {
      expect(await make().ensure(demoAlertTopic), isTrue);
      expect(await make().ensure(demoAlertTopic), isTrue);
      expect(calls, [demoAlertTopic]);
      now += const Duration(hours: 25).inMilliseconds;
      expect(await make().ensure(demoAlertTopic), isTrue);
      expect(calls, hasLength(2));
    });

    test('つながらないときは間を空けて4回で諦める', () async {
      fail = true;
      expect(await make().ensure(demoAlertTopic), isFalse);
      expect(calls, hasLength(4));
      expect(slept.map((d) => d.inSeconds), [30, 60, 120]);
    });

    test('1時間に5回を超えて呼ばない', () async {
      fail = true;
      final s = make();
      expect(await s.ensure(demoAlertTopic), isFalse); // 4回
      expect(await s.ensure(demoAlertTopic), isFalse); // 1回だけで止まる
      expect(s.calls, 5);
    });
  });

  test('警報が異常に多く届いたら10分に6件までで捨てる（同じ警報の再送は数えない）', () {
    var now = 0;
    final a = AlertSource(now: () => now);
    final got = <String>[];
    a.items.listen((i) => got.add(i.id));
    final first = mockAlertData(level: 3, nowMs: 0);
    expect(a.receive(first), isTrue);
    expect(a.receive(first), isTrue); // 再送は数えない
    for (var i = 1; i <= 6; i++) {
      a.receive(mockAlertData(level: 3, nowMs: i));
    }
    expect(got.toSet(), hasLength(6));
    now = const Duration(minutes: 10).inMilliseconds;
    expect(a.receive(mockAlertData(level: 3, nowMs: 99)), isTrue);
  });
}

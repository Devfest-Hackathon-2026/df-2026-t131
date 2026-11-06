import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/info/alert_message.dart';
import 'package:mobile/info/info_hub.dart';
import 'package:mobile/info/info_kind.dart';
import 'package:mobile/info/info_source.dart';
import 'package:mobile/info/sources.dart';

import 'support/alert_fixture.dart';

class _Sink implements InfoSink {
  final got = <InfoItem>[];
  @override
  void deliver(InfoItem item) => got.add(item);
}

void main() {
  test('FCM の data（値はすべて文字列）を警報に直す', () {
    final a = parseAlertData({
      'schema_version': '0.3',
      'type': 'alert',
      'alert_id': 'x1',
      'level': '4',
      'kind': '大雨危険警報',
      'area_name': '富山市',
      'text': '富山市に大雨危険警報が発表されました。',
    }, receivedMs: 1000)!;
    expect(a.level, 4);
    expect(a.interrupts, isTrue);
    expect(a.kind.pauseMusic, isTrue);
    expect(alertRowData(a), {
      'alert_id': 'x1',
      'level': 4,
      'kind': '大雨危険警報',
      'area_name': '富山市',
      'text': '富山市に大雨危険警報が発表されました。',
    });
  });

  test('形の違うメッセージ・知らない type は無視する', () {
    expect(
      parseAlertData({'type': 'news', 'alert_id': 'a'}, receivedMs: 0),
      isNull,
    );
    expect(
      parseAlertData({
        'type': 'alert',
        'alert_id': 'a',
        'level': '9',
        'kind': 'k',
        'area_name': 'a',
        'text': 't',
      }, receivedMs: 0),
      isNull,
    );
  });

  test('レベル3は割り込まない（サーバーの模擬の警報の形）', () {
    final m = mockAlertData(level: 3, nowMs: 5);
    final a = parseAlertData(m, receivedMs: 5)!;
    expect(a.interrupts, isFalse);
    expect(a.id, startsWith('mock_'));
    expect(a.text, startsWith('これは訓練用の模擬の警報で、実際の警報ではありません。'));
  });

  group('まとめ役', () {
    late _Sink sink;
    late List<InfoItem> logged;
    late int now;
    late InfoHub hub;
    late AlertSource alerts;

    setUp(() async {
      sink = _Sink();
      logged = [];
      now = 1000;
      alerts = AlertSource(now: () => now);
      hub = InfoHub(sink: sink, now: () => now, onAccepted: logged.add)
        ..register(alerts);
      for (final s in plannedSources()) {
        hub.register(s);
      }
      await hub.start();
    });

    test('同じ警報の再送は1回だけ渡す', () {
      final data = mockAlertData(level: 4, nowMs: 1);
      alerts.receive(data);
      alerts.receive(data);
      expect(sink.got, hasLength(1));
      expect(logged, hasLength(1));
    });

    test('期限を過ぎた情報は捨てる', () {
      final ok = hub.accept(
        InfoItem(
          id: 'tram1',
          kind: InfoKind.transit,
          text: '次の電車は',
          receivedMs: 0,
          expiresMs: 999,
        ),
      );
      expect(ok, isFalse);
      expect(sink.got, isEmpty);
    });

    test('骨組みの種類は準備中・警報は FCM をつなぐまで準備中', () {
      expect(hub.readinessOf(InfoKind.weather), InfoReadiness.planned);
      expect(hub.readinessOf(InfoKind.transit), InfoReadiness.planned);
      expect(hub.readinessOf(InfoKind.event), InfoReadiness.planned);
      expect(hub.readinessOf(InfoKind.alert), InfoReadiness.planned);
      alerts.fcmConnected = true;
      expect(hub.readinessOf(InfoKind.alert), InfoReadiness.ready);
    });

    test('あとから足した入口もそのまま流れる', () {
      final tram = ManualSource(InfoKind.transit);
      hub.register(tram);
      tram.push(
        const InfoItem(
          id: 't',
          kind: InfoKind.transit,
          text: '次の電車',
          receivedMs: 0,
        ),
      );
      expect(sink.got.single.kind.priority, 3);
    });

    test('設定でオフの種類は渡さない', () {
      final off = InfoHub(
        sink: sink,
        now: () => now,
        isEnabled: (k) => k != InfoKind.event,
      );
      expect(
        off.accept(
          const InfoItem(
            id: 'e',
            kind: InfoKind.event,
            text: '祭り',
            receivedMs: 0,
          ),
        ),
        isFalse,
      );
    });
  });
}

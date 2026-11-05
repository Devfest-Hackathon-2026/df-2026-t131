import 'dart:async';

import '../net/rate_limiter.dart';
import 'alert_message.dart';
import 'info_kind.dart';
import 'info_source.dart';

/// 気象警報の入口。FCM のトピック [demoAlertTopic] で届く data を [parseAlertData] で直して流す。
///
/// FCM の受信は `FcmAlerts`（fcm_alerts.dart）が行い、届いた data を [receive] に渡す。
/// google-services.json が無いときは、開発者モードの「模擬の警報」だけで動く。
class AlertSource implements InfoSource {
  AlertSource({required this.now, RateLimiter? limiter})
    : limiter =
          limiter ??
          RateLimiter(
            maxCalls: maxAlertsPerWindow,
            window: alertWindow,
            now: now,
          );

  final int Function() now;
  final _c = StreamController<InfoItem>.broadcast(sync: true);

  /// 異常に多く届いたとき（送り側の不具合など）に読み上げ続けないための上限。
  /// 10分に6件まで。同じ警報の再送は数えない（2回目は InfoHub が捨てる）。
  static const maxAlertsPerWindow = 6;
  static const alertWindow = Duration(minutes: 10);
  final RateLimiter limiter;
  final Set<String> _counted = {};

  /// FCM につながっているか（つないだら true にする）。
  bool fcmConnected = false;

  @override
  InfoKind get kind => InfoKind.alert;

  @override
  InfoReadiness get readiness =>
      fcmConnected ? InfoReadiness.ready : InfoReadiness.planned;

  static const todo =
      'FCM の受信（firebase_messaging）と google-services.json を入れる。'
      '今は開発者モードの「模擬の警報」で読み上げと割り込みを確かめられます。';

  @override
  Stream<InfoItem> get items => _c.stream;

  /// FCM の data を受ける。形が違えば無視して false。
  /// [receivedMs] は、アプリが閉じていた間に届いて後から渡すときの、受け取った時刻。
  bool receive(Map<String, Object?> data, {int? receivedMs}) {
    final item = parseAlertData(data, receivedMs: receivedMs ?? now());
    if (item == null || _c.isClosed) return false;
    if (!_counted.contains(item.id)) {
      if (!limiter.tryAcquire()) return false; // 多すぎる。捨てる
      _counted.add(item.id);
    }
    _c.add(item);
    return true;
  }

  /// デモ用の模擬の警報を流す（開発者モード）。
  void sendMock({int level = 4}) =>
      receive(mockAlertData(level: level, nowMs: now()));

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  Future<void> close() => _c.close();
}

/// 骨組みだけの入口（気象・路面電車・イベント）。中身を作るときに置き換える。
///
/// それぞれ、文はテンプレートで作り（AI に書かせない）、正確な位置は外に出さない（CLAUDE.md 3章）。
List<PlannedSource> plannedSources() => [
  PlannedSource(
    InfoKind.weather,
    todo:
        '気象庁の発表（注意報・天気予報）を数分〜1時間おきに取り、変わったときだけ流す。'
        '発表値をテンプレートに入れて読む（自前で予想しない）。'
        'サーバー側の取得口（cloud）とトピックか API の形を schema に足すところから。',
  ),
  PlannedSource(
    InfoKind.transit,
    todo:
        '電停と時刻表は地図タイル（stops・departures）に入っていて engine が使う。'
        'mobile は遅れの情報を、電停に近づく直前に電停 ID だけで問い合わせて流す。'
        '期限（その便の発車まで）を付ける。',
  ),
  PlannedSource(
    InfoKind.event,
    todo:
        '当日のイベントは地図タイル（events）に入っていて engine が使う。'
        'mobile は会場に近づく直前に、イベント ID だけで開催状態を確かめて流す。'
        '確かめられたときだけ話し、期限（終了時刻）を付ける。',
  ),
];

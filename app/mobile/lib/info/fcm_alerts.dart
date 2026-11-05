import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:path_provider/path_provider.dart';

import '../net/rate_limiter.dart';
import 'alert_message.dart';
import 'sources.dart';

/// 裏で届いた警報を、前面の（読み上げを持っている）アプリへ渡すための口の名前。
const _portName = 'mobile_fcm_alerts';

/// アプリが裏に回っているときに届いた FCM（別の isolate で動く）。
/// アプリがまだ動いていれば前面の isolate へ渡して読み上げる。
/// TODO(FCM): アプリが終わっているときは受けられない（通知を出すかはチームで決める）。
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  IsolateNameServer.lookupPortByName(_portName)?.send(message.data);
}

/// トピックの購読（Firebase への通信）を、たたきすぎないように行う。
///
/// - 成功したら時刻を覚え、[resubscribeEvery]（既定24時間）の間は起動し直しても呼ばない
/// - 失敗したら 30秒・1分・2分…と間を空け、1回の起動で [backoff] の回数までで諦める
/// - それとは別に、[limiter]（既定1時間に5回）を超えて呼ばない
class TopicSubscriber {
  TopicSubscriber({
    required this.subscribe,
    required this.memo,
    required this.now,
    Future<void> Function(Duration)? sleep,
    Backoff? backoff,
    RateLimiter? limiter,
    this.resubscribeEvery = const Duration(hours: 24),
  }) : _sleep = sleep ?? Future<void>.delayed,
       backoff = backoff ?? Backoff(),
       limiter =
           limiter ??
           RateLimiter(maxCalls: 5, window: const Duration(hours: 1), now: now);

  final Future<void> Function(String topic) subscribe;
  final CallMemo memo;
  final int Function() now;
  final Future<void> Function(Duration) _sleep;
  final Backoff backoff;
  final RateLimiter limiter;
  final Duration resubscribeEvery;

  /// 実際に Firebase を呼んだ回数（確認用）。
  int calls = 0;

  /// 購読できている（または最近購読した）なら true。
  Future<bool> ensure(String topic) async {
    final key = 'subscribed:$topic';
    final last = await memo.lastSuccessMs(key);
    if (last != null && now() - last < resubscribeEvery.inMilliseconds) {
      return true; // 最近購読した。呼ばない
    }
    for (var attempt = 0; ; attempt++) {
      final wait = backoff.delayBefore(attempt);
      if (wait == null) return false; // 諦める（次の起動でもう一度）
      if (wait > Duration.zero) await _sleep(wait);
      if (!limiter.tryAcquire()) return false;
      calls++;
      try {
        await subscribe(topic);
        await memo.recordSuccess(key, now());
        return true;
      } catch (_) {
        // 通信できない。間を空けてもう一度
      }
    }
  }
}

/// FCM につなぎ、警報のトピック [demoAlertTopic] を購読して、届いた data を [AlertSource] へ渡す。
///
/// google-services.json が無い・つながらないときは false を返し、アプリは警報なしで動く。
class FcmAlerts {
  FcmAlerts(this.alerts);

  final AlertSource alerts;
  ReceivePort? _port;

  static int _nowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  Future<bool> connect() async {
    try {
      await Firebase.initializeApp();
    } catch (_) {
      return false; // 設定ファイルが無い（ほかのメンバーのビルドや CI）
    }
    // 裏で届いた分を受ける口
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(_portName);
    IsolateNameServer.registerPortWithName(port.sendPort, _portName);
    port.listen((data) {
      if (data is Map) alerts.receive(Map<String, Object?>.from(data));
    });
    _port = port;

    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
    FirebaseMessaging.onMessage.listen((m) => alerts.receive(m.data));

    final subscriber = TopicSubscriber(
      subscribe: FirebaseMessaging.instance.subscribeToTopic,
      memo: CallMemo(
        () async => File(
          '${(await getApplicationSupportDirectory()).path}/fcm_state.json',
        ),
      ),
      now: _nowMs,
    );
    final ok = await subscriber.ensure(demoAlertTopic);
    alerts.fcmConnected = ok;
    return ok;
  }

  void dispose() {
    IsolateNameServer.removePortNameMapping(_portName);
    _port?.close();
  }
}

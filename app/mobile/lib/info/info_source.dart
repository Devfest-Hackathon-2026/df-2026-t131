import 'dart:async';

import 'info_kind.dart';

/// 外から届いた情報1件（警報・気象・交通・イベント）。
///
/// どの種類も同じ形にそろえ、[InfoHub] が重複の除去・期限・優先度をまとめて扱う。
/// 文はテンプレートで作ったものだけを入れる（AI に書かせない。CLAUDE.md 3章）。
class InfoItem {
  const InfoItem({
    required this.id,
    required this.kind,
    required this.text,
    required this.receivedMs,
    this.level,
    this.expiresMs,
    this.data = const {},
  });

  /// 同じ情報の再送を見分ける ID（警報なら alert_id）。種類ごとに一意。
  final String id;
  final InfoKind kind;

  /// 読み上げる文。
  final String text;

  /// 受け取った時刻（UTC の UNIX ミリ秒）。
  final int receivedMs;

  /// 警戒レベル（警報だけ。1〜5）。
  final int? level;

  /// これを過ぎたら話さずに捨てる（交通・イベント）。null なら期限なし。
  final int? expiresMs;

  /// 種類ごとの元の値（歩行ログや engine に渡すため）。
  final Map<String, Object?> data;

  /// 今の読み上げに割り込むか（レベル4以上の警報だけ。CLAUDE.md 4章）。
  bool get interrupts => kind == InfoKind.alert && (level ?? 0) >= 4;
}

/// 情報の入口。種類ごとに1つ作り、[InfoHub] に登録する。
///
/// 例：FCM の警報（[AlertSource] の実装）、気象庁の発表の取得、路面電車の遅れの取得、
/// イベントの開催状態の確認。データの取り方は入口ごとに違ってよい（受信・定期取得・接近時の確認）。
abstract class InfoSource {
  InfoKind get kind;

  /// 今どこまで使えるか（設定画面に出す）。
  InfoReadiness get readiness;

  /// 届いた情報。
  Stream<InfoItem> get items;

  Future<void> start();
  Future<void> stop();
}

/// まだデータの入口が無い種類の骨組み。何も流さない。
///
/// 中身を作るときは、このクラスを置き換える（`readiness` を ready にし、`items` に流す）。
class PlannedSource implements InfoSource {
  PlannedSource(this.kind, {required this.todo});

  @override
  final InfoKind kind;

  /// 作るときにやること（設定画面と README に出す）。
  final String todo;

  @override
  InfoReadiness get readiness => InfoReadiness.planned;

  @override
  Stream<InfoItem> get items => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// 手で流せる入口（テストで使う）。
class ManualSource implements InfoSource {
  ManualSource(this.kind);

  @override
  final InfoKind kind;

  final _c = StreamController<InfoItem>.broadcast(sync: true);

  @override
  InfoReadiness get readiness => InfoReadiness.ready;

  @override
  Stream<InfoItem> get items => _c.stream;

  void push(InfoItem item) {
    if (!_c.isClosed) _c.add(item);
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  Future<void> close() => _c.close();
}

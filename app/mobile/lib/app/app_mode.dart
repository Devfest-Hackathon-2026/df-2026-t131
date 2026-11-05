/// デモ版と正式版の違いをここに集める。
/// `--dart-define=APP_MODE=demo|production`（既定は demo）。
///
/// - demo：歩き始める場所（デモでは富山駅）で利用者が「計測開始」を押し、終わりに「終了」を押す。
///   画面に判断の中身を重ねて見せ、「スマホで代用」を常に表示する。
/// - production（将来）：歩き出しを検知して自動で始める・画面を見ない使い方。
///   セッションの始め方は [SessionPolicy] を差し替えて変える。
/// どちらも行き先は設定しない（歩いている周りを案内するアプリのため）。
enum AppMode {
  demo,
  production;

  static AppMode get current =>
      const String.fromEnvironment('APP_MODE') == 'production'
      ? AppMode.production
      : AppMode.demo;
}

/// セッション（1回の歩行）の始め方・終わり方。
abstract class SessionPolicy {
  /// 利用者がボタンで開始・終了するか（false なら自動）。
  bool get manualStartStop;

  /// 終了するときに確認を出すか（デモ中の押し間違いを防ぐ）。
  bool get confirmBeforeStop;
}

class DemoSessionPolicy implements SessionPolicy {
  const DemoSessionPolicy();

  @override
  bool get manualStartStop => true;

  @override
  bool get confirmBeforeStop => true;
}

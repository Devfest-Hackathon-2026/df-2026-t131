/// mobile の設定値。API まわりは --dart-define で切り替える。
class AppConfig {
  AppConfig._();

  /// `fake` / `real`。URL が空なら fake を強制する。
  static const String _apiModeRaw = String.fromEnvironment(
    'API_MODE',
    defaultValue: 'fake',
  );
  static const String apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// X-App-Token の値。画面・ログ・print に出さない。
  static const String appToken = String.fromEnvironment('APP_TOKEN');

  static bool get useRealApi => _apiModeRaw == 'real' && apiBaseUrl.isNotEmpty;
  static String get apiModeLabel => useRealApi ? 'real' : 'fake';

  /// ぶれの換算の割る数（ラプラシアンの分散 ÷ K、1 で頭打ち）。屋外で調整する。
  static const double blurDivisorK = 300;

  /// 速度がこれ未満なら進行方向を null にする（静止中も 0.1〜0.45 m/s 出るため）。
  static const double minSpeedForCourseMps = 0.5;

  /// 偏角を更新する間隔。
  static const Duration declinationRefresh = Duration(minutes: 10);

  /// 今出ている警報の一覧を置く公開の Cloud Storage（`alerts/current/<区域7桁>.json`）。
  /// 誰でも読める公開の置き場所で、秘密ではない。別の置き場所を試すときは --dart-define で替える。
  static const String alertsBaseUrl = String.fromEnvironment(
    'ALERTS_BASE_URL',
    defaultValue:
        'https://storage.googleapis.com/ambient-guide-toyama-2026-alerts',
  );

  /// `--dart-define=DEV_TOOLS=true` で開発者モードを最初から出す。
  /// 出していないときも、設定画面の「このアプリについて」を7回押すと出せる。
  static const bool devTools = bool.fromEnvironment('DEV_TOOLS');

  /// SensorFrame を作る間隔。
  static const Duration sensorTick = Duration(seconds: 1);
}

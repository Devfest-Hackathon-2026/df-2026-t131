import '../net/api_client.dart';
import '../app/app_settings.dart';
import '../sources/audio_state_source.dart';
import '../sources/gaze_source.dart';
import '../sources/location_source.dart';

enum CheckLevel { ok, warn, waiting }

/// 開始前の確認の1項目。
class ReadinessItem {
  const ReadinessItem(this.label, this.detail, this.level);

  final String label;
  final String detail;
  final CheckLevel level;
}

/// 位置の精度がこれ以下なら「良い」。
const double goodAccuracyM = 20;

/// 開始前に画面に並べる確認項目を作る（画面から切り離してテストできるように）。
List<ReadinessItem> buildReadiness({
  required LocationFix? location,
  required GazeReading? gaze,
  required bool cameraReady,
  required AudioState audio,
  required AppSettings settings,
  ServerStatus? server,
  bool serverConfigured = false,
}) {
  return [
    if (location == null)
      const ReadinessItem('位置', '測位を待っています', CheckLevel.waiting)
    else if (location.accM <= goodAccuracyM)
      ReadinessItem(
        '位置',
        '±${location.accM.toStringAsFixed(0)} m',
        CheckLevel.ok,
      )
    else
      ReadinessItem(
        '位置',
        '±${location.accM.toStringAsFixed(0)} m（屋外で改善）',
        CheckLevel.warn,
      ),
    if (gaze == null)
      const ReadinessItem('向き', '方位センサーを待っています', CheckLevel.waiting)
    else
      ReadinessItem('向き', '${gaze.azDeg.toStringAsFixed(0)}°', CheckLevel.ok),
    if (!settings.visualSearchEnabled)
      const ReadinessItem('カメラ', '画像検索オフ（画像は送りません）', CheckLevel.ok)
    else if (cameraReady)
      const ReadinessItem('カメラ', '映像を受け取っています', CheckLevel.ok)
    else
      const ReadinessItem('カメラ', '準備しています', CheckLevel.waiting),
    if (audio.earphone)
      const ReadinessItem('音声', 'イヤホン', CheckLevel.ok)
    else
      const ReadinessItem('音声', 'スピーカー（イヤホン推奨）', CheckLevel.warn),
    if (serverConfigured)
      if (server == null)
        const ReadinessItem('サーバー', '確かめています', CheckLevel.waiting)
      else if (server.ok)
        ReadinessItem(
          'サーバー',
          'つながっています（${server.health.elapsedMs} ms）',
          CheckLevel.ok,
        )
      else if (server.health.ok)
        ReadinessItem('サーバー', '生存確認OK・${server.auth.label}', CheckLevel.warn)
      else
        ReadinessItem('サーバー', server.health.label, CheckLevel.warn),
  ];
}

/// 記録を始めてよいか（歩行ログの必須項目である位置と向きがそろっている）。
bool canStart({required LocationFix? location, required GazeReading? gaze}) =>
    location != null && gaze != null;

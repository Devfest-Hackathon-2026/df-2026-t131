import 'package:permission_handler/permission_handler.dart';

/// 起動時に順に求める権限と、拒否されたときに画面へ出す説明。
/// マイクは「検索して」の聞き取りだけに使う（音声も認識結果も保存・送信しない）。
class RequiredPermission {
  const RequiredPermission(this.permission, this.label, this.reason);

  final Permission permission;
  final String label;
  final String reason;
}

const List<RequiredPermission> requiredPermissions = [
  RequiredPermission(
    Permission.locationWhenInUse,
    '位置情報',
    '現在地と進行方向から、近くの場所を案内するため',
  ),
  RequiredPermission(Permission.camera, 'カメラ', '目の前の景色から建物を調べるため（画像は保存しない）'),
  RequiredPermission(
    Permission.activityRecognition,
    '身体活動',
    '歩いているか止まっているかで話す量を変えるため',
  ),
  RequiredPermission(Permission.notification, '通知', '防災の警報を受け取るため'),
  RequiredPermission(
    Permission.microphone,
    'マイク',
    '「検索して」の声で目の前の景色を調べるため（音声は保存・送信しない）',
  ),
];

/// 権限を問い合わせる部分を差し替えられるようにする（テスト用）。
typedef PermissionRequester = Future<bool> Function(Permission permission);

Future<bool> requestWithPlugin(Permission permission) async {
  final status = await permission.request();
  return status.isGranted || status.isLimited;
}

/// [requiredPermissions] を上から順に求め、許可されなかったものを返す。
/// 空なら全部そろった。
Future<List<RequiredPermission>> requestAll({
  List<RequiredPermission> permissions = requiredPermissions,
  PermissionRequester requester = requestWithPlugin,
}) async {
  final denied = <RequiredPermission>[];
  for (final p in permissions) {
    if (!await requester(p.permission)) {
      denied.add(p);
    }
  }
  return denied;
}

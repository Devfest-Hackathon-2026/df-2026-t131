import 'info_kind.dart';
import 'info_source.dart';

/// FCM の警報メッセージ（`schema/fcm/alert.data.schema.json`）を [InfoItem] に直す。
///
/// FCM の data は値がすべて文字列なので、`level` を整数に直す。
/// 形が違う・知らない type のメッセージは null（無視する）。
InfoItem? parseAlertData(Map<String, Object?> data, {required int receivedMs}) {
  String? str(String k) {
    final v = data[k];
    return v is String && v.isNotEmpty ? v : null;
  }

  if (str('type') != 'alert') return null;
  final id = str('alert_id');
  final level = int.tryParse(str('level') ?? '');
  final kind = str('kind');
  final area = str('area_name');
  final text = str('text');
  if (id == null ||
      level == null ||
      level < 1 ||
      level > 5 ||
      kind == null ||
      area == null ||
      text == null) {
    return null;
  }
  return InfoItem(
    id: id,
    kind: InfoKind.alert,
    text: text,
    receivedMs: receivedMs,
    level: level,
    data: {'kind': kind, 'area_name': area},
  );
}

/// 歩行ログの `alert` 行（`schema/eventlog.schema.json`）の data。engine の `AlertReceived` と同じ項目。
Map<String, Object?> alertRowData(InfoItem a) => {
  'alert_id': a.id,
  'level': a.level,
  'kind': a.data['kind'],
  'area_name': a.data['area_name'],
  'text': a.text,
};

/// FCM のトピック名（`alert_<市町村コード5桁>`）。デモは富山市。
const demoAlertTopic = 'alert_16201';

/// デモ用の模擬の警報（cloud/alert-job の `/mock-alert` と同じ決まり：
/// 文の頭に「これはデモ用の模擬の警報です。」、alert_id は `mock_` で始まる）。
Map<String, String> mockAlertData({required int level, required int nowMs}) => {
  'schema_version': '0.3',
  'type': 'alert',
  'alert_id': 'mock_app_$nowMs',
  'level': '$level',
  'kind': level >= 4 ? '大雨危険警報' : '大雨警報',
  'area_name': '富山市',
  'text':
      'これはデモ用の模擬の警報です。富山市に'
      '${level >= 4 ? 'レベル4の大雨危険警報' : 'レベル3の大雨警報'}が発表されました。'
      '安全な場所で、最新の情報を確認してください。',
};

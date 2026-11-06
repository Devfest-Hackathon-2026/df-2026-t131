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
  final areaCode = str('area_code'); // 11/6 から付く（前の形には無い）
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
    data: {'kind': kind, 'area_name': area, 'area_code': ?areaCode},
  );
}

/// 今出ている警報の一覧（`schema/api/alerts_current.schema.json`）を、FCM の data と同じ形の
/// Map の並びに直す（同じ [parseAlertData] で読めるように）。形が違えば null。
List<Map<String, Object?>>? alertListToData(Map<String, Object?> json) {
  final areaCode = json['area_code'];
  final areaName = json['area_name'];
  final list = json['alerts'];
  if (areaCode is! String || areaName is! String || list is! List) return null;
  return [
    for (final a in list)
      if (a is Map)
        {
          'schema_version': json['schema_version'],
          'type': 'alert',
          'alert_id': a['alert_id'],
          'level': a['level'],
          'kind': a['kind'],
          'area_code': areaCode,
          'area_name': areaName,
          'text': a['text'],
        },
  ];
}

/// 歩行ログの `alert` 行（`schema/eventlog.schema.json`）の data。engine の `AlertReceived` と同じ項目。
Map<String, Object?> alertRowData(InfoItem a) => {
  'alert_id': a.id,
  'level': a.level,
  'kind': a.data['kind'],
  'area_name': a.data['area_name'],
  'text': a.text,
};

/// デモの区域（気象庁の「気象警報・注意報」の区域コード7桁）。富山市。
const demoAlertArea = '1620100';

/// FCM のトピック名（`alert_<区域コード7桁>`）。
const demoAlertTopic = 'alert_$demoAlertArea';

/// 前の形のトピック（`alert_<市町村コード5桁>`）。サーバーが移行の間だけこちらにも送る。
/// 同じ警報が2つのトピックから届いても、同じ alert_id なので2回目は捨てる。
/// TODO(警報): メンバー1が `FCM_LEGACY_TOPIC` を止めたら外す。
const legacyAlertTopic = 'alert_16201';

/// 購読するトピック。
const alertTopics = [demoAlertTopic, legacyAlertTopic];

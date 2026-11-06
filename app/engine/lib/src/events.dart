import 'constants.dart';
import 'models.dart';
import 'wire.dart';

enum Activity { walking, still, inVehicle, unknown }

enum AudioOut { earphone, speaker, none }

sealed class EngineEvent {
  int get tMs;
  String get schemaVersion;
}

final class SensorFrame implements EngineEvent {
  @override
  final int tMs;
  @override
  final String schemaVersion;
  final double lat, lon, accM;
  final double? speedMps, courseDeg;
  final double gazeAzDeg, gazePitchDeg;
  final Activity activity;
  final AudioOut audioOut;
  final bool inCall, ttsSpeaking;
  final ImageQuality? imageQuality;
  const SensorFrame({
    required this.tMs,
    required this.lat,
    required this.lon,
    required this.accM,
    required this.speedMps,
    required this.courseDeg,
    required this.gazeAzDeg,
    required this.gazePitchDeg,
    required this.activity,
    required this.audioOut,
    required this.inCall,
    required this.ttsSpeaking,
    required this.imageQuality,
    this.schemaVersion = currentSchemaVersion,
  });
}

final class TilesLoaded implements EngineEvent {
  @override
  final int tMs;
  @override
  final String schemaVersion;
  final TileResponse tile;
  const TilesLoaded({
    required this.tMs,
    required this.tile,
    this.schemaVersion = currentSchemaVersion,
  });
}

final class TtsFinished implements EngineEvent {
  @override
  final int tMs;
  @override
  final String schemaVersion;
  final String utteranceId;
  const TtsFinished({
    required this.tMs,
    required this.utteranceId,
    this.schemaVersion = currentSchemaVersion,
  });
}

final class VisualResult implements EngineEvent {
  @override
  final int tMs;
  @override
  final String schemaVersion;
  final VisualSearchResponse response;
  const VisualResult({
    required this.tMs,
    required this.response,
    this.schemaVersion = currentSchemaVersion,
  });
}

final class VisualError implements EngineEvent {
  @override
  final int tMs;
  @override
  final String schemaVersion;
  final String searchId, error;
  const VisualError({
    required this.tMs,
    required this.searchId,
    required this.error,
    this.schemaVersion = currentSchemaVersion,
  });
}

/// 利用者が「調べて」と声で B の検索を頼んだ（音声認識はアプリが行う。音声も認識結果も渡さない）。
///
/// engine はこのときのセンサーの値で一度だけ撮影を試す。撮れなければ見送った理由を残し、あとで勝手に撮らない。
final class SearchRequested implements EngineEvent {
  @override
  final int tMs;
  @override
  final String schemaVersion;
  const SearchRequested({
    required this.tMs,
    this.schemaVersion = currentSchemaVersion,
  });
}

final class AlertReceived implements EngineEvent {
  @override
  final int tMs;
  @override
  final String schemaVersion;
  final String alertId, kind, areaName, text;
  final int level;
  const AlertReceived({
    required this.tMs,
    required this.alertId,
    required this.level,
    required this.kind,
    required this.areaName,
    required this.text,
    this.schemaVersion = currentSchemaVersion,
  });
}

EngineEvent eventFromJson(Map<String, dynamic> json) {
  const keys = ['schema_version', 't_ms', 'type', 'data'];
  wireKeys(json, keys, keys);
  final version = wireString(
    json['schema_version'],
    'schema_version',
    pattern: r'^\d+\.\d+$',
  );
  final t = wireInt(json['t_ms'], 't_ms', min: 0);
  final data = wireMap(json['data'], 'data');
  final type = wireString(json['type'], 'type');
  switch (type) {
    case 'sensor':
      const sensorKeys = [
        'lat',
        'lon',
        'acc_m',
        'speed_mps',
        'course_deg',
        'gaze_az_deg',
        'gaze_pitch_deg',
        'activity',
        'audio_out',
        'in_call',
        'tts_speaking',
        'image_quality',
      ];
      wireKeys(data, sensorKeys, sensorKeys);
      final activity = wireString(
        data['activity'],
        'activity',
        values: ['walking', 'still', 'in_vehicle', 'unknown'],
      );
      final audio = wireString(
        data['audio_out'],
        'audio_out',
        values: ['earphone', 'speaker', 'none'],
      );
      return SensorFrame(
        tMs: t,
        schemaVersion: version,
        lat: wireDouble(data['lat'], 'lat', min: -90, max: 90),
        lon: wireDouble(data['lon'], 'lon', min: -180, max: 180),
        accM: wireDouble(data['acc_m'], 'acc_m', min: 0),
        speedMps: data['speed_mps'] == null
            ? null
            : wireDouble(data['speed_mps'], 'speed_mps', min: 0),
        courseDeg: data['course_deg'] == null
            ? null
            : wireDouble(
                data['course_deg'],
                'course_deg',
                min: 0,
                exclusiveMax: 360,
              ),
        gazeAzDeg: wireDouble(
          data['gaze_az_deg'],
          'gaze_az_deg',
          min: 0,
          exclusiveMax: 360,
        ),
        gazePitchDeg: wireDouble(
          data['gaze_pitch_deg'],
          'gaze_pitch_deg',
          min: -90,
          max: 90,
        ),
        activity: activity == 'in_vehicle'
            ? Activity.inVehicle
            : Activity.values.byName(activity),
        audioOut: AudioOut.values.byName(audio),
        inCall: wireBool(data['in_call'], 'in_call'),
        ttsSpeaking: wireBool(data['tts_speaking'], 'tts_speaking'),
        imageQuality: data['image_quality'] == null
            ? null
            : ImageQuality.fromJson(
                wireMap(data['image_quality'], 'image_quality'),
              ),
      );
    case 'tiles_loaded':
      return TilesLoaded(
        tMs: t,
        schemaVersion: version,
        tile: TileResponse.fromJson(data),
      );
    case 'tts_finished':
      wireKeys(data, ['utterance_id'], ['utterance_id']);
      return TtsFinished(
        tMs: t,
        schemaVersion: version,
        utteranceId: wireString(data['utterance_id'], 'utterance_id'),
      );
    case 'visual_result':
      return VisualResult(
        tMs: t,
        schemaVersion: version,
        response: VisualSearchResponse.fromJson(data),
      );
    case 'visual_error':
      wireKeys(data, ['search_id', 'error'], ['search_id', 'error']);
      return VisualError(
        tMs: t,
        schemaVersion: version,
        searchId: wireString(data['search_id'], 'search_id'),
        error: wireString(
          data['error'],
          'error',
          values: ['timeout', 'network', 'server', 'face_blur_failed'],
        ),
      );
    case 'search_request':
      wireKeys(data, const [], const []);
      return SearchRequested(tMs: t, schemaVersion: version);
    case 'alert':
      const alertKeys = ['alert_id', 'level', 'kind', 'area_name', 'text'];
      wireKeys(data, alertKeys, alertKeys);
      return AlertReceived(
        tMs: t,
        schemaVersion: version,
        alertId: wireString(data['alert_id'], 'alert_id'),
        level: wireInt(data['level'], 'level', min: 1, max: 5),
        kind: wireString(data['kind'], 'kind'),
        areaName: wireString(data['area_name'], 'area_name'),
        text: wireString(data['text'], 'text'),
      );
    default:
      throw FormatException('未対応の入力イベント: $type');
  }
}

Map<String, dynamic> eventToJson(EngineEvent event) {
  final (type, data) = switch (event) {
    SensorFrame e => (
      'sensor',
      <String, dynamic>{
        'lat': e.lat,
        'lon': e.lon,
        'acc_m': e.accM,
        'speed_mps': e.speedMps,
        'course_deg': e.courseDeg,
        'gaze_az_deg': e.gazeAzDeg,
        'gaze_pitch_deg': e.gazePitchDeg,
        'activity': e.activity == Activity.inVehicle
            ? 'in_vehicle'
            : e.activity.name,
        'audio_out': e.audioOut.name,
        'in_call': e.inCall,
        'tts_speaking': e.ttsSpeaking,
        'image_quality': e.imageQuality?.toJson(),
      },
    ),
    TilesLoaded e => ('tiles_loaded', e.tile.toJson()),
    TtsFinished e => (
      'tts_finished',
      <String, dynamic>{'utterance_id': e.utteranceId},
    ),
    VisualResult e => ('visual_result', e.response.toJson()),
    VisualError e => (
      'visual_error',
      <String, dynamic>{'search_id': e.searchId, 'error': e.error},
    ),
    SearchRequested() => ('search_request', <String, dynamic>{}),
    AlertReceived e => (
      'alert',
      <String, dynamic>{
        'alert_id': e.alertId,
        'level': e.level,
        'kind': e.kind,
        'area_name': e.areaName,
        'text': e.text,
      },
    ),
  };
  final json = <String, dynamic>{
    'schema_version': event.schemaVersion,
    't_ms': event.tMs,
    'type': type,
    'data': data,
  };
  // 直接生成したイベントも、ログを出す境界で型・範囲を検査する。
  eventFromJson(json);
  return json;
}

import '../core/sensor_ticker.dart';
import '../sources/activity_source.dart';

/// 歩行ログの形の版（schema/README.md の現在の版）。
const String schemaVersion = '0.3';

String activityToJson(ActivityKind a) => switch (a) {
  ActivityKind.walking => 'walking',
  ActivityKind.still => 'still',
  ActivityKind.inVehicle => 'in_vehicle',
  ActivityKind.unknown => 'unknown',
};

/// [SensorSnapshot] を歩行ログの sensor 行（schema/eventlog.schema.json）にする。
/// TODO(質問): engine の雛形が届いたら SensorFrame にして engine の eventToJson に置き換える。
Map<String, Object?> sensorRowJson(SensorSnapshot s) {
  final loc = s.location;
  final q = s.imageQuality;
  return {
    'schema_version': schemaVersion,
    't_ms': s.tMs,
    'type': 'sensor',
    'data': {
      'lat': loc.lat,
      'lon': loc.lon,
      'acc_m': loc.accM,
      'speed_mps': loc.speedMps,
      'course_deg': loc.courseDeg,
      'gaze_az_deg': s.gaze.azDeg,
      'gaze_pitch_deg': s.gaze.pitchDeg.clamp(-90.0, 90.0),
      'activity': activityToJson(s.activity),
      'audio_out': s.audio.earphone ? 'earphone' : 'speaker',
      'in_call': s.audio.inCall,
      'tts_speaking': s.ttsSpeaking,
      'image_quality': q == null
          ? null
          : {'blur': q.blur, 'brightness': q.brightness},
    },
  };
}

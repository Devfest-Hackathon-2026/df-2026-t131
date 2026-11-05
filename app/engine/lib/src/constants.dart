const currentSchemaVersion = '0.2';

/// tasks/README.md 2.5の初期値。時間の単位はミリ秒。
final class EngineConfig {
  final int sensorIntervalMs,
      prefetchHorizonMs,
      proximityHorizonMs,
      topicIntervalMs;
  final int visualIntervalMs,
      candidateLimit,
      visualFreshnessMs,
      maxSearchesPerWalk;
  final double defaultRadiusM, samePlaceDistanceM, samePlaceAzimuthDeg;
  final double candidateDistanceM, candidateHalfAngleDeg, minConfidence;
  final double fastWalkingMps, crossingDistanceM, minBlur, minBrightness;

  const EngineConfig({
    this.sensorIntervalMs = 1000,
    this.defaultRadiusM = 25,
    this.prefetchHorizonMs = 150000,
    this.proximityHorizonMs = 20000,
    this.topicIntervalMs = 20000,
    this.visualIntervalMs = 60000,
    this.samePlaceDistanceM = 20,
    this.samePlaceAzimuthDeg = 30,
    this.candidateDistanceM = 150,
    this.candidateHalfAngleDeg = 30,
    this.candidateLimit = 10,
    this.visualFreshnessMs = 15000,
    this.minConfidence = 0.6,
    this.maxSearchesPerWalk = 30,
    this.fastWalkingMps = 1.8,
    this.crossingDistanceM = 15,
    this.minBlur = 0.5,
    this.minBrightness = 0.2,
  });
}

/// schema/reason_codes.jsonと照合する。追加・変更はmember1が決定する。
const reasonCodes = <String>{
  'speak:closest_approach',
  'speak:area_entered',
  'speak:long_version_still',
  'speak:alert_interrupt',
  'speak:alert',
  'speak:transit_next',
  'speak:event_nearby',
  'skip:already_told',
  'skip:crossing_ahead',
  'skip:in_vehicle',
  'skip:fast_walking',
  'skip:no_audio_output',
  'skip:in_call',
  'skip:tts_busy',
  'skip:topic_interval',
  'skip:pass_before_end',
  'skip:expired',
  'skip:event_cancelled',
  'search:interval_elapsed',
  'search:stopped_early',
  'search_skip:interval_not_elapsed',
  'search_skip:same_place',
  'search_skip:gate_blocked',
  'search_skip:low_quality',
  'search_skip:limit_reached',
  'answer:matched_landmark',
  'answer:unlisted_object',
  'answer:named_object',
  'answer:unknown',
  'answer:low_confidence',
  'answer:already_told',
  'answer:expired',
  'answer:error',
  'fetch:prefetch_tiles',
};

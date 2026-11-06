import 'dart:math' as math;

import 'package:engine/engine.dart';
import 'package:engine/src/geo.dart';

// テストで使う場面づくりの道具。A のテスト（engine_a_test.dart）と B のテスト（engine_b_test.dart）で共用する。

// ---- 見本の場所（富山駅南口付近）を原点にした平面で場面を作る ----
const lat0 = 36.7008, lon0 = 137.2135;
const t0 = 1793836800000;
final mPerDegLat = earthRadiusM * math.pi / 180;
final mPerDegLon = mPerDegLat * math.cos(lat0 * math.pi / 180);
double latAt(double northM) => lat0 + northM / mPerDegLat;
double lonAt(double eastM) => lon0 + eastM / mPerDegLon;
int ms(num sec) => t0 + (sec * 1000).round();

Landmark landmark(
  String id,
  double north,
  double east, {
  String kind = 'monument',
  double? radiusM,
  String short = '右手の石碑は、見本のための架空の石碑です。',
  String? long,
}) => Landmark(
  id: id,
  name: '見本$id',
  nameKana: 'みほん',
  lat: latAt(north),
  lon: lonAt(east),
  kind: kind,
  radiusM: radiusM,
  scriptShort: short,
  scriptLong: long ?? '$short長い版の続きです。',
  visualHint: '',
);

TilesLoaded tiles(
  num sec,
  List<Landmark> landmarks, {
  List<Crossing> crossings = const [],
  List<Town>? towns,
}) => TilesLoaded(
  tMs: ms(sec),
  tile: TileResponse(
    tile: tileAt(lat0, lon0),
    landmarks: landmarks,
    stops: const [],
    crossings: crossings,
    events: const [],
    towns: towns,
  ),
);

/// 原点から north・east（m）の位置に代表点がある町丁目。
Town town(String id, String name, double north, double east) =>
    Town(id: id, name: name, lat: latAt(north), lon: lonAt(east));

/// 1秒ごとの位置。既定は南へ 1.3 m/s。
typedef Pose = ({double north, double east, double speed, double course});
Pose southWalk(int sec) =>
    (north: -1.3 * sec, east: 0, speed: 1.3, course: 180);

/// B の応答の作り方。撮影の指示と、応答が届く時刻を受け取り、届けるイベントを返す（null なら何も返さない）。
typedef Responder = EngineEvent? Function(CaptureAndSearch c, int tMs);

/// mobile の代わり：センサーを1秒ごとに送り、Speak を受けたら読み上げ時間後に TtsFinished を返す。
/// `respond` を渡すと、CaptureAndSearch を受けてから `responseDelaySec` 秒後に B の応答を返す。
final class Sim {
  final Engine engine;
  final List<(int, Command)> commands = [];
  ({String id, int endMs})? _current;
  final Responder? respond;
  final int responseDelaySec;
  final List<(int, CaptureAndSearch)> _pendingSearches = [];
  Sim([
    EngineConfig config = const EngineConfig(),
    this.respond,
    this.responseDelaySec = 3,
  ]) : engine = Engine(config: config);

  void run(
    int seconds, {
    Pose Function(int sec) pose = southWalk,
    Activity Function(int sec)? activity,
    AudioOut audio = AudioOut.earphone,
    Map<int, List<EngineEvent>> extra = const {},
    bool reportTtsFinished = true,
    ImageQuality? Function(int sec)? quality,
    double Function(int sec)? gaze,
    bool Function(int sec)? ttsSpeaking,
    int from = 0,
  }) {
    for (var sec = from; sec <= seconds; sec++) {
      final t = ms(sec);
      final due = _pendingSearches.where((p) => p.$1 <= t).toList();
      for (final (dueMs, c) in due) {
        _pendingSearches.remove((dueMs, c));
        final e = respond!(c, dueMs);
        if (e != null) _feed(e, reportTtsFinished);
      }
      final cur = _current;
      if (cur != null && t >= cur.endMs) {
        _current = null;
        if (reportTtsFinished) {
          _feed(TtsFinished(tMs: t, utteranceId: cur.id), reportTtsFinished);
        }
      }
      final p = pose(sec);
      _feed(
        SensorFrame(
          tMs: t,
          lat: latAt(p.north),
          lon: lonAt(p.east),
          accM: 5,
          speedMps: p.speed,
          courseDeg: p.speed < 0.5 ? null : p.course,
          gazeAzDeg: gaze?.call(sec) ?? p.course,
          gazePitchDeg: 0,
          activity: activity?.call(sec) ?? Activity.walking,
          audioOut: audio,
          inCall: false,
          ttsSpeaking: ttsSpeaking?.call(sec) ?? _current != null,
          imageQuality: quality?.call(sec),
        ),
        reportTtsFinished,
      );
      for (final e in extra[sec] ?? const <EngineEvent>[]) {
        _feed(e, reportTtsFinished);
      }
    }
  }

  void _feed(EngineEvent e, bool reportTtsFinished) {
    for (final c in engine.handle(e)) {
      commands.add((e.tMs, c));
      if (c is CaptureAndSearch && respond != null) {
        _pendingSearches.add((e.tMs + responseDelaySec * 1000, c));
      }
      if (c is Speak) {
        final cur = _current;
        if (c.interrupt && cur != null && reportTtsFinished) {
          // 割り込みで止めた話にも TtsFinished を返す（mobile の想定どおり）
          _feed(TtsFinished(tMs: e.tMs, utteranceId: cur.id), true);
        }
        final dur = (c.text.runes.length / 6 * 1000).ceil();
        _current = (id: c.utteranceId, endMs: e.tMs + dur);
      }
    }
  }

  List<Decision> get decisions => [
    for (final (_, c) in commands)
      if (c is LogDecision) c.decision,
  ];
  List<(int, Speak)> get speaks => [
    for (final (t, c) in commands)
      if (c is Speak) (t, c),
  ];
  Iterable<Decision> withReason(String reason) =>
      decisions.where((d) => d.reason == reason);
  double secOf(int tMs) => (tMs - t0) / 1000;
}

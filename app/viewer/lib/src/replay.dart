import 'dart:convert';

import 'package:engine/engine.dart';

// 歩行ログ（入力イベントの JSON Lines）を engine に流し直し、各時点の状態を記録する。
// Flutter に依存しない（テストで直接確かめる）。
// 判断は engine がすべて行う。viewer は「見せる」だけで、判断を作り直さない。

/// 歩行ログの読み込みに失敗した。何行目かを持つ。
final class WalkLogFormatException implements Exception {
  final int lineNumber;
  final String message;
  const WalkLogFormatException(this.lineNumber, this.message);
  @override
  String toString() => '$lineNumber行目を読めませんでした：$message';
}

/// JSON Lines を入力イベントの列にする。空行は飛ばす。
List<EngineEvent> parseWalkLog(String text) {
  final events = <EngineEvent>[];
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    try {
      final json = jsonDecode(line);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('1行が JSON のオブジェクトではありません');
      }
      events.add(eventFromJson(json));
    } on FormatException catch (e) {
      throw WalkLogFormatException(i + 1, e.message);
    }
  }
  if (events.isEmpty) {
    throw const WalkLogFormatException(0, '入力イベントが1件もありません');
  }
  return events;
}

/// 位置（緯度・経度）。
typedef LatLon = ({double lat, double lon});

/// 入力イベント1件を engine に渡した直後の状態。
final class ReplayFrame {
  final int index;
  final EngineEvent event;

  /// このイベントで engine が出した指示。
  final List<Command> commands;

  /// 渡した直後の `engine.view`。
  final EngineView view;

  /// この時点までの最後のセンサー（まだ無ければ null）。
  final SensorFrame? sensor;

  /// この時点で読み上げ中の話（engine が出した Speak で、まだ TtsFinished が来ていないもの）。
  final Speak? speaking;

  const ReplayFrame({
    required this.index,
    required this.event,
    required this.commands,
    required this.view,
    required this.sensor,
    required this.speaking,
  });

  int get tMs => event.tMs;
}

/// 判断ログ1件と、それを出したフレームの番号。
typedef ReplayDecision = ({int frameIndex, Decision decision});

/// 読み上げ1件と、話し始めたフレームの番号。
typedef ReplaySpeak = ({int frameIndex, int tMs, Speak speak});

/// B の撮影1件。
typedef ReplaySearch = ({
  int frameIndex,
  int tMs,
  LatLon? position,
  CaptureAndSearch search,
});

/// B の撮影1件に返ってきた答え（歩行ログの visual_result / visual_error）。
typedef SearchOutcome = ({
  int frameIndex,
  int tMs,

  /// `matched`・`unlisted`・`unknown`、エラーのときは `error`。
  String result,
  double? confidence,
  String? objectName,
  String? description,

  /// エラーの種類（`server` など）。エラーでなければ null。
  String? error,
});

/// 歩行ログ1本を最後まで流した結果。シークはフレームの番号で行う。
final class Replay {
  final List<ReplayFrame> frames;
  final List<ReplayDecision> decisions;
  final List<ReplaySpeak> speaks;
  final List<ReplaySearch> searches;

  /// 撮影の番号（`s_000001` など）ごとの答え。
  final Map<String, SearchOutcome> outcomes;

  /// タイルで届いたランドマーク・エリア（同じ ID は1つにまとめる）。
  final List<Landmark> landmarks;
  final List<Crossing> crossings;

  /// センサーの位置の列（生の値。平滑化は engine の中だけで行う）。
  final List<({int tMs, LatLon position})> track;

  Replay._({
    required this.frames,
    required this.decisions,
    required this.speaks,
    required this.searches,
    required this.outcomes,
    required this.landmarks,
    required this.crossings,
    required this.track,
  });

  /// 入力イベントを順に新しい engine へ流す。同じログなら必ず同じ結果になる。
  factory Replay.run(
    List<EngineEvent> events, {
    EngineConfig config = const EngineConfig(),
  }) {
    final engine = Engine(config: config);
    final frames = <ReplayFrame>[];
    final decisions = <ReplayDecision>[];
    final speaks = <ReplaySpeak>[];
    final searches = <ReplaySearch>[];
    final outcomes = <String, SearchOutcome>{};
    final landmarks = <String, Landmark>{};
    final crossings = <String, Crossing>{};
    final track = <({int tMs, LatLon position})>[];
    SensorFrame? sensor;
    Speak? speaking;
    for (final event in events) {
      final commands = engine.handle(event);
      final index = frames.length;
      switch (event) {
        case SensorFrame():
          sensor = event;
          track.add((
            tMs: event.tMs,
            position: (lat: event.lat, lon: event.lon),
          ));
        case TilesLoaded():
          for (final lm in event.tile.landmarks) {
            landmarks[lm.id] = lm;
          }
          for (final c in event.tile.crossings) {
            crossings[c.id] = c;
          }
        case TtsFinished():
          if (speaking?.utteranceId == event.utteranceId) speaking = null;
        case VisualResult(:final response):
          outcomes[response.searchId] = (
            frameIndex: index,
            tMs: event.tMs,
            result: response.result,
            confidence: response.confidence,
            objectName: response.objectName,
            description: response.description,
            error: null,
          );
        case VisualError():
          outcomes[event.searchId] = (
            frameIndex: index,
            tMs: event.tMs,
            result: 'error',
            confidence: null,
            objectName: null,
            description: null,
            error: event.error,
          );
        default:
          break;
      }
      for (final c in commands) {
        switch (c) {
          case LogDecision():
            decisions.add((frameIndex: index, decision: c.decision));
          case Speak():
            speaking = c;
            speaks.add((frameIndex: index, tMs: event.tMs, speak: c));
          case CaptureAndSearch():
            final s = sensor;
            searches.add((
              frameIndex: index,
              tMs: event.tMs,
              position: s == null ? null : (lat: s.lat, lon: s.lon),
              search: c,
            ));
          case FetchTiles():
            break;
        }
      }
      frames.add(
        ReplayFrame(
          index: index,
          event: event,
          commands: List.unmodifiable(commands),
          view: engine.view,
          sensor: sensor,
          speaking: speaking,
        ),
      );
    }
    final sortedLandmarks = landmarks.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final sortedCrossings = crossings.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return Replay._(
      frames: List.unmodifiable(frames),
      decisions: List.unmodifiable(decisions),
      speaks: List.unmodifiable(speaks),
      searches: List.unmodifiable(searches),
      outcomes: Map.unmodifiable(outcomes),
      landmarks: List.unmodifiable(sortedLandmarks),
      crossings: List.unmodifiable(sortedCrossings),
      track: List.unmodifiable(track),
    );
  }

  int get startMs => frames.first.tMs;
  int get endMs => frames.last.tMs;
  int get durationMs => endMs - startMs;

  /// 時刻 `tMs` までに処理したうち最後のフレームの番号（`tMs` が始まりより前なら 0）。
  int frameIndexAt(int tMs) {
    var lo = 0, hi = frames.length - 1;
    if (tMs <= frames.first.tMs) return 0;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (frames[mid].tMs <= tMs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// フレーム `frameIndex` までに撮った最後の1件（まだ撮っていなければ null）。
  ReplaySearch? lastSearchAt(int frameIndex) {
    ReplaySearch? last;
    for (final s in searches) {
      if (s.frameIndex > frameIndex) break;
      last = s;
    }
    return last;
  }

  /// 撮影 `searchId` の答えのうち、フレーム `frameIndex` までに届いたもの（まだなら null）。
  SearchOutcome? outcomeAt(String searchId, int frameIndex) {
    final o = outcomes[searchId];
    return o == null || o.frameIndex > frameIndex ? null : o;
  }

  /// 判断ログのうち、フレーム `frameIndex` までに出たものの件数。
  int decisionCountAt(int frameIndex) {
    var lo = 0, hi = decisions.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (decisions[mid].frameIndex <= frameIndex) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

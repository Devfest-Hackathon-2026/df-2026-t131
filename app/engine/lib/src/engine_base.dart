import 'dart:math' as math;

import 'commands.dart';
import 'constants.dart';
import 'events.dart';
import 'geo.dart';
import 'kalman.dart';
import 'models.dart';

/// 端末内の判断エンジン。入力イベントを受けて、アプリへの指示（Command）を返す。
///
/// 時間はイベントの `tMs` だけで進み、乱数・AI・時計・通信を使わない。
/// 同じ入力イベントの列を流せば、必ず同じ指示の列が返る（歩行ログの再生で確かめられる）。
///
/// いま入っている判断：
/// - 位置の平滑化（カルマンフィルタ）
/// - 先読み（`FetchTiles`）
/// - A の発話判定（ランドマークの最接近、エリアに入ったときの定型文、立ち止まったときの長い版）
/// - 文脈ゲート（音声出力なし・通話中・乗り物・早歩き・横断歩道・読み上げ中・話題の間隔・聞いた話）
/// - 警報（重複の除去、レベル4以上の割り込み）
/// - 話した履歴（A・B 共有。B は次の段階で使う）
///
/// B の計測・結果の採否、交通・イベントの読み上げはまだ入っていない。
class Engine {
  final EngineConfig config;

  Engine({this.config = const EngineConfig()})
    : _kalman = KalmanFilter2D(
        accelNoise: config.kalmanAccelNoise,
        velocityNoise: config.kalmanVelocityNoise,
      );

  // ---- 位置 ----
  final KalmanFilter2D _kalman;
  LocalProjection? _projection;
  int? _lastSensorMs;
  SensorFrame? _sensor;

  // ---- タイルと、そこから得たデータ ----
  final Map<String, int> _tileRequestedAt = {};
  final Set<String> _tilesLoaded = {};
  final Map<String, Landmark> _landmarks = {};
  final Map<String, Crossing> _crossings = {};

  // ---- 読み上げ ----
  int _utteranceSeq = 0;
  _Utterance? _speaking;
  final Set<String> _interruptedUtterances = {};
  int? _lastSpeechEndMs;

  /// 話した対象の ID（ランドマーク・エリア）。A と B で共有する。
  final Set<String> _told = {};

  /// 対象ごとに最後に記録した「話さなかった理由」。同じ理由を毎秒記録しないため。
  final Map<String, String> _lastSkipReason = {};

  /// 文脈ゲートで待たせている対象。条件から外れたら `skip:expired` を記録する。
  final Set<String> _waiting = {};

  // ---- 警報 ----
  final Set<String> _seenAlerts = {};
  final List<AlertReceived> _pendingAlerts = [];

  // ---- エリア ----
  String? _currentAreaId;

  /// いまいるエリア（B の送信の `area` に入れる）。エリアの外なら null。
  AreaContext? get currentArea {
    final id = _currentAreaId;
    if (id == null) return null;
    final area = _landmarks[id]!;
    return AreaContext(id: area.id, name: area.name, summary: area.scriptShort);
  }

  /// 話した対象（ランドマーク・エリア）の ID の一覧。読み取り専用。
  Set<String> get toldIds => Set.unmodifiable(_told);

  List<Command> handle(EngineEvent event) {
    final out = <Command>[];
    switch (event) {
      case SensorFrame():
        _onSensor(event, out);
      case TilesLoaded():
        _onTiles(event);
      case TtsFinished():
        _onTtsFinished(event);
        _tryNext(event.tMs, out);
      case AlertReceived():
        _onAlert(event, out);
      case VisualResult():
      case VisualError():
        // B の結果の採否は次の段階で入れる。
        break;
    }
    return out;
  }

  // ======================================================================
  // 位置と先読み
  // ======================================================================

  void _onSensor(SensorFrame s, List<Command> out) {
    final last = _lastSensorMs;
    if (last != null && s.tMs < last) return; // 時刻が戻った行は使わない
    _sensor = s;
    _updatePosition(s, last);
    _lastSensorMs = s.tMs;
    _prefetch(s.tMs, out);
    _updateArea();
    _tryNext(s.tMs, out);
  }

  void _updatePosition(SensorFrame s, int? lastMs) {
    final projection = _projection ??= LocalProjection(s.lat, s.lon);
    final z = projection.toLocal(s.lat, s.lon);
    final accM = math.max(s.accM, 1.0);
    final speed = s.speedMps, course = s.courseDeg;
    // 進行方向が null（遅いとき）は速度を観測せず、フィルタの推定に任せる。
    final velocity = speed != null && course != null
        ? velocityFromCourse(speed, course)
        : null;
    if (!_kalman.initialized ||
        lastMs == null ||
        s.tMs - lastMs > config.kalmanResetGapMs) {
      _kalman.reset(z, accM, velocity);
      return;
    }
    _kalman.predict((s.tMs - lastMs) / 1000);
    _kalman.updatePosition(z, accM);
    if (velocity != null) _kalman.updateVelocity(velocity);
  }

  Vec2 get _position => _kalman.position;

  /// 平滑化した速度。止まっているとみなす速さより遅ければ 0。
  Vec2 get _velocity {
    final v = _kalman.velocity;
    return v.length < config.minMovingMps ? const Vec2(0, 0) : v;
  }

  /// 先読み：予測軌跡上の点の周りのタイルのうち、まだ持っていないものを要求する。
  void _prefetch(int t, List<Command> out) {
    final projection = _projection!;
    final v = _velocity;
    final steps = v.length == 0
        ? 0
        : config.prefetchHorizonMs ~/ config.prefetchStepMs;
    final m = config.prefetchMarginM;
    final wanted = <String, TileId>{};
    for (var k = 0; k <= steps; k++) {
      final p = _position + v * (k * config.prefetchStepMs / 1000);
      for (final corner in [
        p,
        p + Vec2(-m, -m),
        p + Vec2(-m, m),
        p + Vec2(m, -m),
        p + Vec2(m, m),
      ]) {
        final (lat, lon) = projection.toLatLon(corner);
        final tile = tileAt(lat, lon);
        wanted.putIfAbsent(tileKey(tile), () => tile);
      }
    }
    final request = <TileId>[];
    for (final MapEntry(key: key, value: tile) in wanted.entries) {
      if (_tilesLoaded.contains(key)) continue;
      final at = _tileRequestedAt[key];
      if (at != null && t - at < config.tileRetryMs) continue;
      _tileRequestedAt[key] = t;
      request.add(tile);
    }
    if (request.isEmpty) return;
    out.add(FetchTiles(tiles: request));
    for (final tile in request) {
      _log(out, t, 'fetch', 'fetch:prefetch_tiles', tileKey(tile));
    }
  }

  void _onTiles(TilesLoaded e) {
    _tilesLoaded.add(tileKey(e.tile.tile));
    for (final lm in e.tile.landmarks) {
      _landmarks[lm.id] = lm;
    }
    for (final c in e.tile.crossings) {
      _crossings[c.id] = c;
    }
  }

  Vec2 _local(double lat, double lon) => _projection!.toLocal(lat, lon);

  double _radius(Landmark lm) => lm.radiusM ?? config.defaultRadiusM;

  void _updateArea() {
    String? best;
    var bestDist = double.infinity;
    for (final lm in _landmarks.values) {
      if (lm.kind != 'area') continue;
      final d = (_local(lm.lat, lm.lon) - _position).length;
      if (d <= _radius(lm) && d < bestDist) {
        best = lm.id;
        bestDist = d;
      }
    }
    _currentAreaId = best;
  }

  // ======================================================================
  // 読み上げの状態
  // ======================================================================

  void _onTtsFinished(TtsFinished e) {
    // 割り込みで止めた話の終了の知らせは、今の話の終わりではないので無視する。
    if (_interruptedUtterances.remove(e.utteranceId)) return;
    if (_speaking?.id != e.utteranceId) return;
    _speaking = null;
    _lastSpeechEndMs = e.tMs;
  }

  /// エンジンが出した読み上げが続いているか。終了の知らせが来ないまま長く過ぎたら終わったとみなす。
  bool _engineSpeaking(int t) {
    final u = _speaking;
    if (u == null) return false;
    if (t > u.expectedEndMs + config.ttsFinishGraceMs) {
      _speaking = null;
      _lastSpeechEndMs = t;
      return false;
    }
    return true;
  }

  int _durationMs(String text) =>
      (text.runes.length / config.ttsCharsPerSecond * 1000).ceil();

  String _nextUtteranceId() {
    _utteranceSeq++;
    return 'u_${_utteranceSeq.toString().padLeft(6, '0')}';
  }

  void _speak(
    List<Command> out, {
    required int t,
    required String reason,
    required String targetId,
    required String text,
    required int priority,
    required bool interrupt,
    required bool pauseMusic,
    required bool narrative,
  }) {
    final current = _speaking;
    if (interrupt && current != null) {
      // 割り込まれた話は話していない扱いにして、条件が合えばもう一度話せるようにする。
      _interruptedUtterances.add(current.id);
      if (current.narrative) _told.remove(current.targetId);
    }
    final id = _nextUtteranceId();
    _speaking = _Utterance(
      id: id,
      targetId: targetId,
      narrative: narrative,
      expectedEndMs: t + _durationMs(text),
    );
    if (narrative) _told.add(targetId);
    _waiting.remove(targetId);
    // 自分で話した直後に「聞いた話」を記録しないよう、記録済みとしておく。
    // B が先に話した対象に A が近づいたときだけ `skip:already_told` が残る。
    _lastSkipReason[targetId] = 'skip:already_told';
    out.add(
      Speak(
        utteranceId: id,
        text: text,
        priority: priority,
        interrupt: interrupt,
        pauseMusic: pauseMusic,
      ),
    );
    _log(out, t, 'speak', reason, targetId, text: text, priority: priority);
  }

  // ======================================================================
  // 警報
  // ======================================================================

  void _onAlert(AlertReceived a, List<Command> out) {
    if (!_seenAlerts.add(a.alertId)) return; // 同じ警報の再送は無視する
    final s = _sensor;
    if (a.level >= config.alertInterruptLevel &&
        s != null &&
        _audioBlock(s) == null) {
      _speak(
        out,
        t: a.tMs,
        reason: 'speak:alert_interrupt',
        targetId: a.alertId,
        text: a.text,
        priority: 1,
        interrupt: _engineSpeaking(a.tMs) || s.ttsSpeaking,
        pauseMusic: true,
        narrative: false,
      );
      return;
    }
    _pendingAlerts.add(a);
    _tryNext(a.tMs, out);
  }

  // ======================================================================
  // 次に話すものを選ぶ（優先度：警報 1 → A 5）
  // ======================================================================

  void _tryNext(int t, List<Command> out) {
    final s = _sensor;
    if (s == null) return;
    final busy = _engineSpeaking(t) || s.ttsSpeaking;

    // 1. 警報。話題の間隔・横断歩道・乗り物では止めない。
    if (_pendingAlerts.isNotEmpty) {
      final a = _pendingAlerts.first;
      final block = _audioBlock(s) ?? (busy ? 'skip:tts_busy' : null);
      if (block != null) {
        _skipOnce(out, t, a.alertId, block, 1);
        return; // 警報が待っている間は、それより低い優先度の話を始めない
      }
      _pendingAlerts.removeAt(0);
      _speak(
        out,
        t: t,
        reason: a.level >= config.alertInterruptLevel
            ? 'speak:alert_interrupt'
            : 'speak:alert',
        targetId: a.alertId,
        text: a.text,
        priority: 1,
        interrupt: false,
        pauseMusic: true,
        narrative: false,
      );
      return;
    }

    // 5. A：ランドマークとエリア
    final candidates = _narrativeCandidates(t, out);
    final gate = _narrativeGate(s, t, busy);
    if (gate != null) {
      for (final c in candidates) {
        _skipOnce(out, t, c.landmark.id, gate, 5);
        _waiting.add(c.landmark.id);
      }
      return;
    }
    if (candidates.isEmpty) return;
    final c = candidates.first;
    _speak(
      out,
      t: t,
      reason: c.reason,
      targetId: c.landmark.id,
      text: c.text,
      priority: 5,
      interrupt: false,
      pauseMusic: false,
      narrative: true,
    );
  }

  /// 音声を出せない状態。警報もナラティブも待つ。
  String? _audioBlock(SensorFrame s) {
    if (s.audioOut == AudioOut.none) return 'skip:no_audio_output';
    if (s.inCall) return 'skip:in_call';
    return null;
  }

  /// A の文脈ゲート（CLAUDE.md 5章）。null なら話してよい。
  String? _narrativeGate(SensorFrame s, int t, bool busy) {
    final audio = _audioBlock(s);
    if (audio != null) return audio;
    if (s.activity == Activity.inVehicle) return 'skip:in_vehicle';
    if (_velocity.length > config.fastWalkingMps) return 'skip:fast_walking';
    if (_crossingAhead()) return 'skip:crossing_ahead';
    if (busy) return 'skip:tts_busy';
    final end = _lastSpeechEndMs;
    if (end != null && t - end < config.topicIntervalMs) {
      return 'skip:topic_interval';
    }
    return null;
  }

  /// 横断歩道・信号が手前（一定距離内で、まだ渡っていない側）にあるか。
  bool _crossingAhead() {
    final v = _velocity;
    for (final c in _crossings.values) {
      final rel = _local(c.lat, c.lon) - _position;
      if (rel.length > config.crossingDistanceM) continue;
      if (v.length == 0 || rel.dot(v) >= 0) return true;
    }
    return false;
  }

  /// いま話す条件に合う A の候補。早く最接近するものから並べる。
  ///
  /// あわせて、話せない候補（聞いた話・話し終える前に通り過ぎる）と、
  /// 待たせていたのに条件から外れた候補（期限切れ）を記録する。
  List<_Candidate> _narrativeCandidates(int t, List<Command> out) {
    final result = <_Candidate>[];
    final v = _velocity;
    final still = _sensor!.activity == Activity.still || v.length == 0;
    for (final lm in _landmarks.values) {
      final rel = _local(lm.lat, lm.lon) - _position;
      final r = _radius(lm);
      _Candidate? candidate;
      String? notPossible;
      if (lm.kind == 'area') {
        if (rel.length <= r) {
          candidate = _Candidate(lm, 0, 'speak:area_entered', lm.scriptShort);
        }
      } else {
        final window = _geofenceWindow(rel, v, r);
        if (window != null &&
            window.closestS <= config.proximityHorizonMs / 1000) {
          final useLong = still && rel.length <= r;
          final text =
              _directionLead(lm, rel) +
              (useLong ? lm.scriptLong : lm.scriptShort);
          if (window.exitS * 1000 >= _durationMs(text)) {
            candidate = _Candidate(
              lm,
              window.closestS,
              useLong ? 'speak:long_version_still' : 'speak:closest_approach',
              text,
            );
          } else {
            notPossible = 'skip:pass_before_end';
          }
        }
      }
      if (_told.contains(lm.id)) {
        if (candidate != null) _skipOnce(out, t, lm.id, 'skip:already_told', 5);
        continue;
      }
      if (candidate != null) {
        result.add(candidate);
        continue;
      }
      if (_waiting.remove(lm.id)) {
        _skipOnce(out, t, lm.id, 'skip:expired', 5);
      } else if (notPossible != null) {
        _skipOnce(out, t, lm.id, notPossible, 5);
      }
    }
    result.sort((a, b) {
      final byTime = a.closestS.compareTo(b.closestS);
      return byTime != 0 ? byTime : a.landmark.id.compareTo(b.landmark.id);
    });
    return result;
  }

  /// 原稿の前に付ける方向の一言（例「右手に見本の石碑があります。」）。テンプレートで作る。
  ///
  /// 原稿には方向の言葉を書かない決まり（cloud/data/scripts/draft_scripts.py）なので、ここで付ける。
  /// 基準は、歩いているときは進行方向、止まっているときは視線（スマホの向き）。
  String _directionLead(Landmark lm, Vec2 rel) {
    final v = _velocity;
    final heading = v.length > 0 ? v.bearingDeg : _sensor!.gazeAzDeg;
    return '${directionWord(angleDiffDeg(rel.bearingDeg, heading), config)}に'
        '${lm.name}があります。';
  }

  /// 等速で進んだとき、半径 r の円の中にいる時間帯。今を0秒とする。
  ///
  /// `closestS` は最も近づくまでの秒数（過ぎていれば負）、`exitS` は円から出るまでの秒数。
  /// 円に入らない、またはもう出たあとなら null。止まっているときは中にいる間ずっと話せる。
  _Window? _geofenceWindow(Vec2 rel, Vec2 v, double r) {
    final a = v.dot(v);
    if (a == 0) {
      return rel.length <= r ? const _Window(0, double.infinity) : null;
    }
    // |rel - v t|² = r² を t について解く
    final b = -2 * rel.dot(v);
    final c = rel.dot(rel) - r * r;
    final disc = b * b - 4 * a * c;
    if (disc < 0) return null;
    final exit = (-b + math.sqrt(disc)) / (2 * a);
    if (exit < 0) return null;
    return _Window(rel.dot(v) / a, exit);
  }

  // ======================================================================
  // 判断ログ
  // ======================================================================

  void _skipOnce(
    List<Command> out,
    int t,
    String targetId,
    String reason,
    int priority,
  ) {
    if (_lastSkipReason[targetId] == reason) return;
    _lastSkipReason[targetId] = reason;
    _log(out, t, 'skip', reason, targetId, priority: priority);
  }

  void _log(
    List<Command> out,
    int t,
    String kind,
    String reason,
    String? targetId, {
    String? text,
    int? priority,
  }) {
    assert(reasonCodes.contains(reason), '理由コードが一覧にない: $reason');
    out.add(
      LogDecision(
        decision: Decision(
          tMs: t,
          kind: kind,
          reason: reason,
          targetId: targetId,
          text: text,
          priority: priority,
        ),
      ),
    );
  }
}

final class _Utterance {
  final String id, targetId;
  final bool narrative;
  final int expectedEndMs;
  const _Utterance({
    required this.id,
    required this.targetId,
    required this.narrative,
    required this.expectedEndMs,
  });
}

final class _Candidate {
  final Landmark landmark;
  final double closestS;
  final String reason, text;
  const _Candidate(this.landmark, this.closestS, this.reason, this.text);
}

final class _Window {
  final double closestS, exitS;
  const _Window(this.closestS, this.exitS);
}

/// 進行方向（または視線）から見た角度を、方向の言葉にする。右が正、左が負（度）。
String directionWord(double relDeg, EngineConfig config) {
  final a = relDeg.abs();
  final right = relDeg > 0;
  if (a <= config.directionFrontDeg) return '正面';
  if (a <= config.directionDiagonalDeg) return right ? '右前方' : '左前方';
  if (a <= config.directionSideDeg) return right ? '右手' : '左手';
  if (a <= config.directionRearDeg) return right ? '右後方' : '左後方';
  return '後方';
}

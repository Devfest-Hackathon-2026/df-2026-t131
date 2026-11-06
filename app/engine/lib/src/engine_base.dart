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
/// - B の計測（`CaptureAndSearch`）と、答えの採否・読み上げ
/// - 話した履歴（A・B 共有）
///
/// 交通・イベントの読み上げはまだ入っていない。
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

  /// 立ち止まり（Activity が still）が始まった時刻。B の前倒しに使う。
  int? _stillSinceMs;

  // ---- タイルと、そこから得たデータ ----
  final Map<String, int> _tileRequestedAt = {};
  final Set<String> _tilesLoaded = {};
  final Map<String, Landmark> _landmarks = {};
  final Map<String, Crossing> _crossings = {};

  /// 最初のタイルが届いた時刻。B の最初の1枚はここから計測間隔だけ待つ。
  int? _firstFixMs;

  // ---- 読み上げ ----
  int _utteranceSeq = 0;
  _Utterance? _speaking;
  final Set<String> _interruptedUtterances = {};
  int? _lastSpeechEndMs;

  /// 話した対象の ID（ランドマーク・エリア）。A と B で共有する。
  final Set<String> _told = {};

  /// B で話した候補外の対象。固有名はエリアごと（エリアの外は全体で）名前で、
  /// 一般名は撮った場所が近いときだけ名前で、重複を判定する。
  final List<_ToldObject> _toldObjects = [];

  /// 対象ごとに最後に記録した「話さなかった理由」。同じ理由を毎秒記録しないため。
  final Map<String, String> _lastSkipReason = {};

  /// 文脈ゲートで待たせている対象。条件から外れたら `skip:expired` を記録する。
  final Set<String> _waiting = {};

  // ---- 警報 ----
  final Set<String> _seenAlerts = {};
  final List<AlertReceived> _pendingAlerts = [];

  // ---- エリア ----
  String? _currentAreaId;

  // ---- B：視界の定期検索 ----
  int _searchSeq = 0;
  int _searchCount = 0;
  int? _lastCaptureMs;
  Vec2? _lastCapturePos;
  double? _lastCaptureGaze;

  /// 結果を待っている検索。1件ずつしか出さない（tasks/README.md 2.3）。
  _Search? _inflight;

  /// 結果が来ないので諦めた検索。あとから届いた結果は期限切れとして記録する。
  final Set<String> _abandonedSearches = {};

  /// 届いたが、まだ話せていない B の答え。
  _VisualAnswer? _pendingAnswer;

  /// 最後に記録した「計測しなかった理由」。撮るたびに消す。
  String? _lastSearchSkip;

  // ---- 画面に出す値 ----
  Decision? _lastDecision;

  /// いまいるエリア（B の送信の `area` に入れる）。エリアの外なら null。
  AreaContext? get currentArea {
    final id = _currentAreaId;
    if (id == null) return null;
    final area = _landmarks[id]!;
    return AreaContext(id: area.id, name: area.name, summary: area.scriptShort);
  }

  /// 話した対象（ランドマーク・エリア）の ID の一覧。読み取り専用。
  Set<String> get toldIds => Set.unmodifiable(_told);

  /// 画面（グラス視点・判断画面）に出す、いまの状態。読み取り専用で、判断には影響しない。
  EngineView get view {
    final s = _sensor;
    if (s == null) {
      return EngineView(
        tMs: 0,
        nearby: const [],
        currentArea: null,
        nextSearchInMs: null,
        searchSkipReason: null,
        searching: false,
        searchesLeft: config.maxSearchesPerWalk,
        lastDecision: _lastDecision,
      );
    }
    final nearby = <NearbyLandmark>[];
    for (final lm in _landmarks.values) {
      final rel = _local(lm.lat, lm.lon) - _position;
      if (rel.length > config.candidateDistanceM) continue;
      nearby.add(
        NearbyLandmark(
          id: lm.id,
          name: lm.name,
          kind: lm.kind,
          distanceM: rel.length,
          relativeBearingDeg: angleDiffDeg(rel.bearingDeg, s.gazeAzDeg),
          told: _told.contains(lm.id),
        ),
      );
    }
    nearby.sort((a, b) {
      final byDist = a.distanceM.compareTo(b.distanceM);
      return byDist != 0 ? byDist : a.id.compareTo(b.id);
    });
    final ref = _lastCaptureMs ?? _firstFixMs;
    final left = config.maxSearchesPerWalk - _searchCount;
    return EngineView(
      tMs: s.tMs,
      nearby: nearby.take(config.candidateLimit).toList(),
      currentArea: currentArea,
      nextSearchInMs: ref == null || _inflight != null || left <= 0
          ? null
          : math.max(0, ref + config.visualIntervalMs - s.tMs),
      searchSkipReason: _lastSearchSkip,
      searching: _inflight != null,
      searchesLeft: left,
      lastDecision: _lastDecision,
    );
  }

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
        _onVisualResult(event, out);
        _tryNext(event.tMs, out);
      case VisualError():
        _onVisualError(event, out);
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
    _firstFixMs ??= s.tMs; // 位置と向きが初めて取れた時刻（B の最初の1枚の基準）
    _updatePosition(s, last);
    _lastSensorMs = s.tMs;
    if (s.activity == Activity.still) {
      _stillSinceMs ??= s.tMs;
    } else {
      _stillSinceMs = null;
    }
    _prefetch(s.tMs, out);
    _updateArea();
    _tryNext(s.tMs, out);
    _maybeSearch(s, out);
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

  /// 方向の言い方の基準。歩いているときは進行方向、止まっているときは視線（スマホの向き）。
  double get _heading {
    final v = _velocity;
    return v.length > 0 ? v.bearingDeg : _sensor!.gazeAzDeg;
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
    String kind = 'speak',
    _ToldObject? toldObject,
    List<VisualSearchSource>? sources,
  }) {
    final current = _speaking;
    if (interrupt && current != null) {
      // 割り込まれた話は話していない扱いにして、条件が合えばもう一度話せるようにする。
      _interruptedUtterances.add(current.id);
      if (current.narrative) _told.remove(current.targetId);
      final object = current.toldObject;
      if (object != null) _toldObjects.remove(object);
    }
    final id = _nextUtteranceId();
    _speaking = _Utterance(
      id: id,
      targetId: targetId,
      narrative: narrative,
      toldObject: toldObject,
      expectedEndMs: t + _durationMs(text),
    );
    if (narrative) _told.add(targetId);
    if (toldObject != null) _toldObjects.add(toldObject);
    _waiting.remove(targetId);
    if (kind == 'speak') {
      // 自分で話した直後に「聞いた話」を記録しないよう、記録済みとしておく。
      // B が先に話した対象に A が近づいたときだけ `skip:already_told` が残る。
      _lastSkipReason[targetId] = 'skip:already_told';
    }
    out.add(
      Speak(
        utteranceId: id,
        text: text,
        priority: priority,
        interrupt: interrupt,
        pauseMusic: pauseMusic,
      ),
    );
    _log(
      out,
      t,
      kind,
      reason,
      targetId,
      text: text,
      priority: priority,
      sources: sources,
    );
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
  // 次に話すものを選ぶ（優先度：警報 1 → A 5 → B 6）
  // ======================================================================

  void _tryNext(int t, List<Command> out) {
    final s = _sensor;
    if (s == null) return;
    _expireVisual(t, out);
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
      return; // B の答えも同じゲートで待つ（鮮度期限を過ぎたら _expireVisual で捨てる）
    }
    if (candidates.isNotEmpty) {
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
      return;
    }

    // 6. B の答え
    _speakVisualAnswer(t, out);
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
  String _directionLead(Landmark lm, Vec2 rel) =>
      '${directionWord(angleDiffDeg(rel.bearingDeg, _heading), config)}に'
      '${lm.name}があります。';

  /// 等速で進んだとき、半径 r の円の中にいる時間帯。今を0秒とする。
  ///
  /// `entryS` は円に入るまで、`closestS` は最も近づくまで（過ぎていれば負）、
  /// `exitS` は円から出るまでの秒数。円に入らない、またはもう出たあとなら null。
  /// 止まっているときは中にいる間ずっと話せる。
  _Window? _geofenceWindow(Vec2 rel, Vec2 v, double r) {
    final a = v.dot(v);
    if (a == 0) {
      return rel.length <= r ? const _Window(0, 0, double.infinity) : null;
    }
    // |rel - v t|² = r² を t について解く
    final b = -2 * rel.dot(v);
    final c = rel.dot(rel) - r * r;
    final disc = b * b - 4 * a * c;
    if (disc < 0) return null;
    final root = math.sqrt(disc);
    final exit = (-b + root) / (2 * a);
    if (exit < 0) return null;
    return _Window((-b - root) / (2 * a), rel.dot(v) / a, exit);
  }

  /// まもなく A が話し始めそうか（論点4）。まだ話していない対象が、
  /// 計測を控える時間のうちに発話判定（または範囲）に入るなら true。
  bool _narrativeSoon() {
    final v = _velocity;
    final yieldS = config.visualYieldToNarrativeMs / 1000;
    for (final lm in _landmarks.values) {
      if (_told.contains(lm.id)) continue;
      final window = _geofenceWindow(
        _local(lm.lat, lm.lon) - _position,
        v,
        _radius(lm),
      );
      if (window == null) continue;
      if (lm.kind == 'area') {
        if (window.entryS <= yieldS) return true;
        continue;
      }
      // 話し終える前に通り過ぎる対象は A が話さないので、B を止めない。
      if (window.exitS * 1000 < _durationMs(lm.scriptShort)) continue;
      if (window.closestS - config.proximityHorizonMs / 1000 <= yieldS) {
        return true;
      }
    }
    return false;
  }

  /// いまから `delayMs` 黙ったあとでは、まだ話していない A の対象を話せなくなるか。
  ///
  /// その間に A が話し始めたいはずで（ランドマークは発話判定に入る、エリアは入る）、
  /// しかも待ったあとでは出る前に話し終えられないものがあれば true。
  bool _narrativeMissedAfter(int delayMs) {
    final v = _velocity;
    final delayS = delayMs / 1000;
    for (final lm in _landmarks.values) {
      if (_told.contains(lm.id)) continue;
      final rel = _local(lm.lat, lm.lon) - _position;
      final window = _geofenceWindow(rel, v, _radius(lm));
      if (window == null) continue;
      final text = lm.kind == 'area'
          ? lm.scriptShort
          : _directionLead(lm, rel) + lm.scriptShort;
      final durS = _durationMs(text) / 1000;
      if (window.exitS < durS) continue; // 今すぐでも話し終えられない（A も話さない）
      final wantS = lm.kind == 'area'
          ? window.entryS
          : window.closestS - config.proximityHorizonMs / 1000;
      if (wantS > delayS) continue; // 待ち終わってから A の出番が来る
      if (window.exitS - delayS < durS) return true;
    }
    return false;
  }

  // ======================================================================
  // B：視界の定期検索（CLAUDE.md 6章、伝言「B_発火タイミングの論点」）
  // ======================================================================

  /// 計測するかを決め、するなら `CaptureAndSearch` を出す。
  void _maybeSearch(SensorFrame s, List<Command> out) {
    final t = s.tMs;
    if (_inflight != null) return; // 1件ずつ（結果か失敗、または諦めるまで次を出さない）

    // 60秒は最後に撮った時刻から。最初の1枚は位置と向きが初めて取れてから（論点1・2）。
    final ref = _lastCaptureMs ?? _firstFixMs;
    if (ref == null) return;
    final elapsed = t - ref;
    final String reason;
    if (elapsed >= config.visualIntervalMs) {
      reason = 'search:interval_elapsed';
    } else {
      final since = _stillSinceMs;
      if (since == null || t - since < config.stillEarlyMs) return;
      if (elapsed < config.stillEarlyMinIntervalMs) {
        _searchSkipOnce(out, t, 'search_skip:interval_not_elapsed');
        return;
      }
      reason = 'search:stopped_early'; // 論点6
    }

    final skip = _captureBlock(s, t);
    if (skip != null) {
      _searchSkipOnce(out, t, skip); // 論点7：数え直さず次の秒に
      return;
    }
    final lastPos = _lastCapturePos, lastGaze = _lastCaptureGaze;
    if (lastPos != null &&
        lastGaze != null &&
        (_position - lastPos).length <= config.samePlaceDistanceM &&
        angleDiffDeg(s.gazeAzDeg, lastGaze).abs() <=
            config.samePlaceAzimuthDeg) {
      _searchSkipOnce(out, t, 'search_skip:same_place');
      return;
    }
    _capture(s, t, reason, out);
  }

  /// 撮影の見送りの条件（上限・文脈ゲート・画質）。null なら撮ってよい。
  String? _captureBlock(SensorFrame s, int t) {
    if (_searchCount >= config.maxSearchesPerWalk) {
      return 'search_skip:limit_reached';
    }
    if (_searchBlocked(s, t)) return 'search_skip:gate_blocked';
    final q = s.imageQuality;
    if (q == null ||
        q.blur < config.minBlur ||
        q.brightness < config.minBrightness) {
      return 'search_skip:low_quality';
    }
    return null;
  }

  void _capture(SensorFrame s, int t, String reason, List<Command> out) {
    _searchSeq++;
    _searchCount++;
    final id = 's_${_searchSeq.toString().padLeft(6, '0')}';
    final (lat, lon) = _projection!.toLatLon(_position);
    final area = currentArea;
    final candidates = _visualCandidates(s.gazeAzDeg);
    _inflight = _Search(
      id: id,
      capturedMs: t,
      gazeAzDeg: s.gazeAzDeg,
      areaId: area?.id,
      position: _position,
      candidateIds: candidates.toSet(),
    );
    _lastCaptureMs = t;
    _lastCapturePos = _position;
    _lastCaptureGaze = s.gazeAzDeg;
    _lastSearchSkip = null;
    out.add(
      CaptureAndSearch(
        searchId: id,
        tile: tileAt(lat, lon),
        gazeAzDeg10: (normalizeDeg(s.gazeAzDeg) / 10).round() % 36 * 10,
        candidateIds: candidates,
        area: area,
      ),
    );
    _log(out, t, 'search', reason, id, priority: 6);
  }

  /// B の計測の文脈ゲート（CLAUDE.md 5章の B の列と、論点3・4・11）。
  bool _searchBlocked(SensorFrame s, int t) {
    if (_audioBlock(s) != null) return true;
    if (s.activity == Activity.inVehicle) return true;
    if (_velocity.length > config.fastWalkingMps) return true;
    if (_crossingAhead()) return true;
    if (_engineSpeaking(t) || s.ttsSpeaking) return true;
    if (_pendingAlerts.isNotEmpty || _pendingAnswer != null) return true;
    // 論点3：答えが届くころに話題の間隔が終わっていなければ撮らない。
    final end = _lastSpeechEndMs;
    if (end != null &&
        t < end + config.topicIntervalMs - config.visualExpectedLatencyMs) {
      return true;
    }
    // 論点4：まもなく A が話し始めるなら、A を優先して撮らない。
    return _narrativeSoon();
  }

  /// 候補：先読み済みのランドマーク（エリアを除く）のうち、一定距離内で視線の左右一定角度内のもの。
  /// 話したものも入れる（論点8：入れないと同じものを別の名前で答えて二度話す恐れがある）。
  List<String> _visualCandidates(double gazeAzDeg) {
    final found = <(double, String)>[];
    for (final lm in _landmarks.values) {
      if (lm.kind == 'area') continue;
      final rel = _local(lm.lat, lm.lon) - _position;
      if (rel.length > config.candidateDistanceM) continue;
      if (angleDiffDeg(rel.bearingDeg, gazeAzDeg).abs() >
          config.candidateHalfAngleDeg) {
        continue;
      }
      found.add((rel.length, lm.id));
    }
    found.sort((a, b) {
      final byDist = a.$1.compareTo(b.$1);
      return byDist != 0 ? byDist : a.$2.compareTo(b.$2);
    });
    return [for (final f in found.take(config.candidateLimit)) f.$2];
  }

  void _onVisualResult(VisualResult e, List<Command> out) {
    final r = e.response;
    final search = _inflight;
    if (search == null || search.id != r.searchId) {
      // 諦めたあとに届いた結果は期限切れとして記録する。知らない検索の結果は無視する。
      if (_abandonedSearches.remove(r.searchId)) {
        _logAnswer(out, e.tMs, 'answer:expired', r.searchId, r);
      }
      return;
    }
    _inflight = null;
    final t = e.tMs;
    if (t - search.capturedMs > config.visualFreshnessMs) {
      _logAnswer(out, t, 'answer:expired', search.id, r);
      return;
    }
    if (r.result == 'unknown') {
      _logAnswer(out, t, 'answer:unknown', search.id, r);
      return;
    }
    // 候補外は根拠が地図にないので、一致より高い自信を求める（CLAUDE.md 6章）。
    final minConfidence = r.result == 'matched'
        ? config.minConfidence
        : config.unlistedMinConfidence;
    if (r.confidence < minConfidence) {
      _logAnswer(out, t, 'answer:low_confidence', search.id, r);
      return;
    }
    if (r.result == 'matched') {
      final lm = search.candidateIds.contains(r.landmarkId)
          ? _landmarks[r.landmarkId]
          : null;
      if (lm == null) {
        // この検索で送った候補にない ID は、取り違えとみなして話さない。
        _logAnswer(out, t, 'answer:unknown', search.id, r);
        return;
      }
      if (_told.contains(lm.id)) {
        _logAnswer(out, t, 'answer:already_told', lm.id, r);
        return;
      }
      _pendingAnswer = _VisualAnswer(
        search: search,
        reason: 'answer:matched_landmark',
        targetId: lm.id,
        name: lm.name,
        body: lm.scriptShort,
        landmarkId: lm.id,
        toldObject: null,
        sources: r.sources,
      );
      return;
    }
    // unlisted：候補外の対象。名前で重複を判定する（論点9）。
    final object = _ToldObject(
      name: r.objectName!,
      named: r.named,
      areaId: search.areaId,
      position: search.position,
      genericRadiusM: config.genericObjectDedupM,
    );
    if (_toldObjects.any(object.sameAs)) {
      _logAnswer(out, t, 'answer:already_told', search.id, r);
      return;
    }
    _pendingAnswer = _VisualAnswer(
      search: search,
      reason: r.named ? 'answer:named_object' : 'answer:unlisted_object',
      targetId: search.id,
      name: r.objectName!,
      body: r.description!,
      landmarkId: null,
      toldObject: object,
      sources: r.sources,
    );
  }

  void _onVisualError(VisualError e, List<Command> out) {
    final search = _inflight;
    if (search == null || search.id != e.searchId) {
      _abandonedSearches.remove(e.searchId);
      return;
    }
    _inflight = null;
    _log(out, e.tMs, 'answer', 'answer:error', search.id, priority: 6);
  }

  /// B の期限：結果が来ない検索を諦め（論点5）、話せないまま鮮度期限を過ぎた答えを捨てる。
  void _expireVisual(int t, List<Command> out) {
    final search = _inflight;
    if (search != null && t - search.capturedMs > config.visualFreshnessMs) {
      _inflight = null;
      _abandonedSearches.add(search.id);
      _log(out, t, 'answer', 'answer:error', search.id, priority: 6);
    }
    final answer = _pendingAnswer;
    if (answer != null &&
        t - answer.search.capturedMs > config.visualFreshnessMs) {
      _pendingAnswer = null;
      _log(
        out,
        t,
        'answer',
        'answer:expired',
        answer.targetId,
        priority: 6,
        sources: answer.sources.isEmpty ? null : answer.sources,
      );
    }
  }

  /// 待っている B の答えを話す。A のゲートを通ったあとに呼ぶ。
  void _speakVisualAnswer(int t, List<Command> out) {
    final answer = _pendingAnswer;
    if (answer == null) return;
    _pendingAnswer = null;
    // 待っている間に A が同じ対象を話したら、話さない。
    final lmId = answer.landmarkId;
    if (lmId != null && _told.contains(lmId)) {
      _log(out, t, 'answer', 'answer:already_told', lmId, priority: 6);
      return;
    }
    // 論点10：過去形・方向つき。方向は撮ったときの視線と、いまの進行方向の差。
    final direction = directionWord(
      angleDiffDeg(answer.search.gazeAzDeg, _heading),
      config,
    );
    final text = 'さっき$directionに見えたのは${answer.name}です。${answer.body}';
    // B を話し終えて話題の間隔を空けると、直後の A が通り過ぎて話せなくなるなら B を見送る（仕様書 5章）。
    if (_narrativeMissedAfter(_durationMs(text) + config.topicIntervalMs)) {
      _log(
        out,
        t,
        'answer',
        'answer:yield_to_narrative',
        answer.targetId,
        priority: 6,
        sources: answer.sources.isEmpty ? null : answer.sources,
      );
      return;
    }
    _speak(
      out,
      t: t,
      kind: 'answer',
      reason: answer.reason,
      targetId: answer.targetId,
      text: text,
      priority: 6,
      interrupt: false,
      pauseMusic: false,
      narrative: lmId != null, // DB のランドマークなら A で話した扱いにする
      toldObject: answer.toldObject,
      sources: answer.sources.isEmpty ? null : answer.sources,
    );
  }

  void _logAnswer(
    List<Command> out,
    int t,
    String reason,
    String targetId,
    VisualSearchResponse r,
  ) => _log(
    out,
    t,
    'answer',
    reason,
    targetId,
    priority: 6,
    sources: r.sources.isEmpty ? null : r.sources,
  );

  void _searchSkipOnce(List<Command> out, int t, String reason) {
    if (_lastSearchSkip == reason) return;
    _lastSearchSkip = reason;
    _log(out, t, 'search_skip', reason, null, priority: 6);
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
    List<VisualSearchSource>? sources,
  }) {
    assert(reasonCodes.contains(reason), '理由コードが一覧にない: $reason');
    final decision = Decision(
      tMs: t,
      kind: kind,
      reason: reason,
      targetId: targetId,
      text: text,
      priority: priority,
      sources: sources,
    );
    _lastDecision = decision;
    out.add(LogDecision(decision: decision));
  }
}

/// 画面（mobile のグラス視点・viewer の再生画面）に出す、エンジンのいまの状態。
///
/// 判断ログには入れない（歩行ログを再生すれば同じ値が計算できる）。
final class EngineView {
  /// 最後に受けたセンサーの時刻。
  final int tMs;

  /// 近くのランドマーク・エリア（B の候補の距離内、近い順、最大 candidateLimit 件）。
  final List<NearbyLandmark> nearby;

  /// いまいるエリア。エリアの外なら null。
  final AreaContext? currentArea;

  /// B の次の計測までのミリ秒。0 なら計測できる状態待ち（ゲート・画質など）。
  /// 結果待ち・上限到達・センサー未着のときは null。
  final int? nextSearchInMs;

  /// B を止めている理由。判断ログの reason と同じ理由コード（例：search_skip:gate_blocked）。
  /// 撮ったら null に戻る。止められていなければ null。
  final String? searchSkipReason;

  /// B の結果を待っているか。
  final bool searching;

  /// この歩行で B をあと何回計測できるか。
  final int searchesLeft;

  /// 最後の判断（理由コードつき）。まだなければ null。
  final Decision? lastDecision;

  EngineView({
    required this.tMs,
    required List<NearbyLandmark> nearby,
    required this.currentArea,
    required this.nextSearchInMs,
    required this.searchSkipReason,
    required this.searching,
    required this.searchesLeft,
    required this.lastDecision,
  }) : nearby = List.unmodifiable(nearby);
}

/// 画面に出す近くのランドマーク。
final class NearbyLandmark {
  final String id, name, kind;

  /// 現在地（平滑化した位置）からの距離（m）。
  final double distanceM;

  /// 視線（スマホの向き）から見た方位。右が正、左が負（度、-180より大きく180以下）。
  final double relativeBearingDeg;

  /// A・B のどちらかで話したか。
  final bool told;

  const NearbyLandmark({
    required this.id,
    required this.name,
    required this.kind,
    required this.distanceM,
    required this.relativeBearingDeg,
    required this.told,
  });
}

final class _Utterance {
  final String id, targetId;
  final bool narrative;
  final _ToldObject? toldObject;
  final int expectedEndMs;
  const _Utterance({
    required this.id,
    required this.targetId,
    required this.narrative,
    required this.toldObject,
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
  final double entryS, closestS, exitS;
  const _Window(this.entryS, this.closestS, this.exitS);
}

final class _Search {
  final String id;
  final int capturedMs;
  final double gazeAzDeg;
  final String? areaId;

  /// 撮ったときの位置（平滑化した位置、端末内の平面）。一般名の重複判定に使う。
  final Vec2 position;

  /// この検索で送った候補。一致の答えはこの中の ID だけ受け付ける。
  final Set<String> candidateIds;
  const _Search({
    required this.id,
    required this.capturedMs,
    required this.gazeAzDeg,
    required this.areaId,
    required this.position,
    required this.candidateIds,
  });
}

final class _VisualAnswer {
  final _Search search;
  final String reason, targetId, name, body;
  final String? landmarkId;
  final _ToldObject? toldObject;
  final List<VisualSearchSource> sources;
  const _VisualAnswer({
    required this.search,
    required this.reason,
    required this.targetId,
    required this.name,
    required this.body,
    required this.landmarkId,
    required this.toldObject,
    required this.sources,
  });
}

/// B で話した候補外の対象（論点9、11/6 に一般名の扱いを決定）。
final class _ToldObject {
  final String name;
  final bool named;
  final String? areaId;
  final Vec2 position;
  final double genericRadiusM;
  const _ToldObject({
    required this.name,
    required this.named,
    required this.areaId,
    required this.position,
    this.genericRadiusM = 0,
  });

  /// 同じ対象の話か。固有名はエリアごとに名前で、一般名は撮った場所が近いときだけ名前で比べる。
  bool sameAs(_ToldObject other) {
    if (name != other.name || named != other.named) return false;
    if (named) return areaId == other.areaId;
    final radius = genericRadiusM > other.genericRadiusM
        ? genericRadiusM
        : other.genericRadiusM;
    return (position - other.position).length <= radius;
  }
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

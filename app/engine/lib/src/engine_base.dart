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

  /// 止まっている（Activity が still か、速さが0）が始まった時刻。A の長い版に使う。
  int? _stoppedSinceMs;

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

  /// 最後に話し終えた話が B の答えだったか。B の前後だけ話題の間隔を空ける。
  bool _lastSpeechVisual = false;

  /// 割り込まれて途中で止まった A の対象。話し直すときに前置きを付ける。
  /// 割り込まれて止めたランドマーク（警報・検索）。続きは話さず、
  /// 一度離れてからまた近づいたら最初から話す。
  final Set<String> _heldUntilLeft = {};

  /// 話した対象の ID（ランドマーク・エリア）。A と B で共有する。
  final Set<String> _told = {};

  /// B で話した候補外の対象。固有名はエリアごと（エリアの外は全体で）名前で、
  /// 一般名は撮った場所が近いときだけ名前で、重複を判定する。
  final List<_ToldObject> _toldObjects = [];

  /// 対象ごとに最後に記録した「話さなかった理由」。同じ理由を毎秒記録しないため。
  final Map<String, String> _lastSkipReason = {};

  /// 文脈ゲートで待たせている対象。条件から外れたら `skip:expired` を記録する。
  final Set<String> _waiting = {};

  // ---- デモ撮影用（11/7）----
  /// ワンタップで頼まれた、まだ話していないランドマークの案内。A の候補の先頭に置く。
  _Candidate? _demoNarration;

  // ---- 警報 ----
  final Set<String> _seenAlerts = {};
  final List<AlertReceived> _pendingAlerts = [];

  // ---- エリア ----
  String? _currentAreaId;
  final Map<String, Town> _towns = {};

  // ---- カメラで調べない区域（CLAUDE.md 6章「B の仕様」、11/7 決定）----
  final Map<String, Zone> _zones = {};

  /// いま中にいる区域。入るのは半径以内、出るのは半径＋zoneExitMarginM より外（その間は前の状態のまま）。
  final Set<String> _zonesInside = {};

  /// 今回の滞在で「入った」を話した区域。話していなければ「出た」も話さない。
  final Set<String> _zoneEntryAnnounced = {};

  /// 区域ごとに最後に出た時刻。すぐまた入ったら知らせを話さない。
  final Map<String, int> _zoneLastExitMs = {};

  /// まだ話していない区域の知らせ（入った・出た）。警報の次、A より先に話す。
  final List<_ZoneNotice> _zoneNotices = [];

  // ---- B：視界の定期検索 ----
  int _searchSeq = 0;
  int _searchCount = 0;
  int? _lastCaptureMs;

  /// 定期の検索の時刻に読み上げ中で見送った時刻。次はここから間隔を数え直す（読み上げの
  /// 直後にすぐ撮らない）。
  int? _intervalRestartMs;

  /// 定期の検索の間隔を数える起点（最後に撮った時刻、見送った時刻、最初に位置が取れた時刻）。
  int? get _searchRefMs {
    final base = _lastCaptureMs ?? _firstFixMs;
    final restart = _intervalRestartMs;
    if (base == null || restart == null) return base;
    return math.max(base, restart);
  }

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

  /// いまいる町丁目。持っているタイルの町丁目のうち、いちばん近い代表点（距離が同じなら ID の小さい方）。
  /// townMaxDistanceM より遠い・町丁目を持っていない・位置がまだ無いときは null。
  /// 決め方は cloud/data/scripts/town_lookup.py と同じ（近い2点なので平面で近似）。
  Town? get currentTown {
    if (_sensor == null || _towns.isEmpty) return null;
    final (lat, lon) = _projection!.toLatLon(_position);
    Town? best;
    var bestD = double.infinity;
    for (final t in _towns.values) {
      final d = townDistanceM(lat, lon, t.lat, t.lon);
      if (d < bestD || (d == bestD && t.id.compareTo(best!.id) < 0)) {
        best = t;
        bestD = d;
      }
    }
    return bestD > config.townMaxDistanceM ? null : best;
  }

  /// いまその範囲（ジオフェンスの半径）の中にいるランドマーク（エリアを除く）。
  /// 複数あればいちばん近いもの（同じなら ID の小さい方）。B の送信の `context.near_landmark`
  /// （「〇〇付近で撮った」）に使う。範囲の外・位置がまだ無いときは null。
  NearLandmarkRef? get nearLandmark {
    if (_sensor == null) return null;
    Landmark? best;
    var bestD = double.infinity;
    for (final lm in _landmarks.values) {
      if (lm.kind == 'area') continue;
      if (_outsideBy(lm) > 0) continue;
      final d = (_local(lm.lat, lm.lon) - _position).length;
      if (d < bestD || (d == bestD && lm.id.compareTo(best!.id) < 0)) {
        best = lm;
        bestD = d;
      }
    }
    return best == null ? null : NearLandmarkRef(id: best.id, name: best.name);
  }

  /// いま中にいるカメラで調べない区域（中心がいちばん近いもの。同じなら ID の小さい方）。外なら null。
  NoCameraZone? get noCameraZone {
    if (_zonesInside.isEmpty) return null;
    Zone? best;
    var bestD = double.infinity;
    for (final id in _zonesInside) {
      final z = _zones[id]!;
      final d = (_local(z.lat, z.lon) - _position).length;
      if (d < bestD || (d == bestD && z.id.compareTo(best!.id) < 0)) {
        best = z;
        bestD = d;
      }
    }
    return NoCameraZone(id: best!.id, name: best.name);
  }

  bool get _inNoCameraZone => _zonesInside.isNotEmpty;

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
        currentTown: null,
        noCameraZone: null,
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
    final ref = _searchRefMs;
    final max = config.maxSearchesPerWalk;
    final left = max == null ? null : max - _searchCount;
    return EngineView(
      tMs: s.tMs,
      nearby: nearby.take(config.candidateLimit).toList(),
      currentArea: currentArea,
      currentTown: currentTown,
      noCameraZone: noCameraZone,
      nextSearchInMs:
          ref == null || _inflight != null || (left != null && left <= 0)
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
      case SearchRequested():
        _onSearchRequested(event, out);
      case DemoLandmarkRequested():
        _onDemoLandmark(event, out);
        _tryNext(event.tMs, out);
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
    if (s.activity == Activity.still || _velocity.length == 0) {
      _stoppedSinceMs ??= s.tMs;
    } else {
      _stoppedSinceMs = null;
    }
    _prefetch(s.tMs, out);
    _updateArea();
    _updateZones(s.tMs);
    _updateCrosswalkSeen(s);
    _tryNext(s.tMs, out);
    _maybeSearch(s, out);
  }

  /// 画像の縞模様（横断歩道）を見た時刻と、見えない状態が続いている始まりを更新する（11/7）。
  ///
  /// 使うのは、画質が足りて（ぶれ・明るさ）、カメラで調べない区域の外で、縞模様の値がある画像だけ。
  /// 使えない画像のときは「見えない」の数え始めを消す（暗い・ぶれた画像で「無い」と決めつけない）。
  void _updateCrosswalkSeen(SensorFrame s) {
    final q = s.imageQuality;
    final score = q?.crosswalk;
    final usable =
        score != null && !_inNoCameraZone && _qualityBlock(s) == null;
    if (!usable) {
      _crosswalkClearSinceMs = null;
      return;
    }
    if (score >= config.crossingVisualMinScore) {
      _crosswalkSeenMs = s.tMs;
      _crosswalkClearSinceMs = null;
    } else {
      _crosswalkClearSinceMs ??= s.tMs;
    }
  }

  /// 最後に縞模様（横断歩道）が写った時刻。
  int? _crosswalkSeenMs;

  /// 使える画像で縞模様が写らない状態が続いている始まり。
  int? _crosswalkClearSinceMs;

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
      _shapeLocal.remove(lm.id);
    }
    for (final c in e.tile.crossings) {
      _crossings[c.id] = c;
    }
    for (final t in e.tile.towns) {
      _towns[t.id] = t;
    }
    for (final z in e.tile.zones) {
      _zones[z.id] = z; // 区域は円がかかるタイルすべてに入るので、ID で重複を除く
    }
  }

  /// カメラで調べない区域に入った・出たを決め、知らせを積む。位置は平滑化したもの。
  void _updateZones(int t) {
    final ids = _zones.keys.toList()..sort();
    for (final id in ids) {
      final z = _zones[id]!;
      final d = (_local(z.lat, z.lon) - _position).length;
      final inside = _zonesInside.contains(id);
      if (!inside && d <= z.radiusM) {
        _zonesInside.add(id);
        if (_zoneNotices.any((n) => n.zoneId == id && !n.entered)) {
          // 「出た」を話す前にまた入った：「出た」を取り消す（「入った」は話してある）
          _zoneNotices.removeWhere((n) => n.zoneId == id);
          _zoneEntryAnnounced.add(id);
          continue;
        }
        final exitAt = _zoneLastExitMs[id];
        if (exitAt != null && t - exitAt < config.zoneAnnounceCooldownMs) {
          continue; // すぐまた入った：知らせは話さない（撮らないことは同じ）
        }
        _zoneNotices.add(_ZoneNotice(zoneId: id, entered: true));
      } else if (inside && d > z.radiusM + config.zoneExitMarginM) {
        _zonesInside.remove(id);
        _zoneLastExitMs[id] = t;
        if (_zoneNotices.any((n) => n.zoneId == id && n.entered)) {
          // 「入った」を話す前に出た：入った・出たの両方を話さない
          _zoneNotices.removeWhere((n) => n.zoneId == id);
        } else if (_zoneEntryAnnounced.remove(id)) {
          _zoneNotices.add(_ZoneNotice(zoneId: id, entered: false));
        }
        if (!_inNoCameraZone &&
            _lastSearchSkip == 'search_skip:no_camera_zone') {
          _lastSearchSkip = null;
        }
      }
    }
  }

  Vec2 _local(double lat, double lon) => _projection!.toLocal(lat, lon);

  double _radius(Landmark lm) => lm.radiusM ?? config.defaultRadiusM;

  // ---- ランドマークの形（11/7）----
  // 形（shape）のあるランドマークは、円の代わりに「形から margin_m 以内（polygon は中も）」を範囲とする。
  // 形の無いもの（ラバーズ像など・古いタイル）は今までどおり中心から radius_m の円。

  /// 形を地面の座標（m）に直したもの（ランドマークの ID ごと。射影は最初の位置で決まり変わらない）。
  final Map<String, List<List<Vec2>>> _shapeLocal = {};

  List<List<Vec2>> _shapeParts(Landmark lm) => _shapeLocal.putIfAbsent(
    lm.id,
    () => [
      for (final part in lm.shape!.parts)
        [for (final p in part) _local(p.lat, p.lon)],
    ],
  );

  /// 形からの距離（m）。polygon の中なら 0。
  double _shapeDistance(Landmark lm, Vec2 p) {
    final polygon = lm.shape!.type == 'polygon';
    var best = double.infinity;
    for (final part in _shapeParts(lm)) {
      if (polygon && part.length >= 3 && insidePolygon(part, p)) return 0;
      final n = part.length;
      for (var i = 0; i < (polygon ? n : n - 1); i++) {
        best = math.min(best, segmentDistance(p, part[i], part[(i + 1) % n]));
      }
    }
    return best;
  }

  /// 範囲の外側までの距離（m）。範囲の中なら 0。[at] が無ければ今の位置。
  double _outsideBy(Landmark lm, [Vec2? at]) {
    final p = at ?? _position;
    final shape = lm.shape;
    if (shape == null) {
      return math.max(0.0, (_local(lm.lat, lm.lon) - p).length - _radius(lm));
    }
    return math.max(0.0, _shapeDistance(lm, p) - shape.marginM);
  }

  /// 等速で進んだとき、範囲の中にいる時間帯。形が無ければ円（[_geofenceWindow]）。
  ///
  /// 形のときは [EngineConfig.shapeStepS] 秒ごとに先の位置を確かめる（決定論的）。
  /// 最も近づく時刻は「範囲に入る時刻」とする（大きな建物・長い通りでは中心への最接近に意味が無いため）。
  _Window? _windowFor(Landmark lm, Vec2 rel, Vec2 v) {
    if (lm.shape == null) return _geofenceWindow(rel, v, _radius(lm));
    final p0 = _position;
    final now = _outsideBy(lm, p0);
    if (v.length == 0) {
      return now == 0 ? const _Window(0, 0, double.infinity) : null;
    }
    final maxS =
        config.proximityHorizonMs / 1000 + config.shapeLookaheadS;
    if (now > v.length * maxS) return null; // 先読みの間に届かない
    double? entry;
    for (var t = 0.0; t <= maxS; t += config.shapeStepS) {
      final inside = t == 0 ? now == 0 : _outsideBy(lm, p0 + v * t) == 0;
      if (entry == null) {
        if (inside) entry = t;
      } else if (!inside) {
        return _Window(entry, entry, t);
      }
    }
    return entry == null ? null : _Window(entry, entry, double.infinity);
  }

  void _updateArea() {
    String? best;
    var bestDist = double.infinity;
    for (final lm in _landmarks.values) {
      if (lm.kind != 'area') continue;
      final d = (_local(lm.lat, lm.lon) - _position).length;
      if (_outsideBy(lm) == 0 && d < bestDist) {
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
    final u = _speaking;
    if (u == null || u.id != e.utteranceId) return;
    _speaking = null;
    _lastSpeechEndMs = e.tMs;
    _lastSpeechVisual = u.visual;
  }

  /// エンジンが出した読み上げが続いているか。終了の知らせが来ないまま長く過ぎたら終わったとみなす。
  bool _engineSpeaking(int t) {
    final u = _speaking;
    if (u == null) return false;
    if (t > u.expectedEndMs + config.ttsFinishGraceMs) {
      _speaking = null;
      _lastSpeechEndMs = t;
      _lastSpeechVisual = u.visual;
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
    bool chime = true,
  }) {
    final current = _speaking;
    if (interrupt && current != null) {
      // 割り込まれた話は話していない扱いにして、条件が合えばもう一度話せるようにする。
      _interruptedUtterances.add(current.id);
      if (current.narrative) _told.remove(current.targetId);
      final object = current.toldObject;
      if (object != null) _toldObjects.remove(object);
      if (current.narrative && !current.visual) {
        // 割り込まれた A（警報・検索）は続きも話し直しもしない。まだ話していない扱いのまま、
        // 一度離れてからまた近づいたら最初から話す（途中で切った話の続きは不自然なため）。
        _heldUntilLeft.add(current.targetId);
      }
    }
    final id = _nextUtteranceId();
    _speaking = _Utterance(
      id: id,
      targetId: targetId,
      narrative: narrative,
      visual: kind == 'answer',
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
        chime: chime,
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
    // 横断歩道を渡っている間（手前を含む）は、警報以外の新しい話を始めない。今の話は止めない。
    // 延期した話は渡り終えてから流す（A は _crossingDeferred、B の答えは鮮度を渡り終えた時刻から数える）。
    final crossing = _crossingAhead();
    if (crossing) _lastCrossingMs = t;
    _expireVisual(t, out, crossing: crossing);
    final busy = _engineSpeaking(t) || s.ttsSpeaking;

    // 1. 警報。話題の間隔・横断歩道・乗り物では止めない。
    if (_pendingAlerts.isNotEmpty) {
      final a = _pendingAlerts.first;
      final block = _audioBlock(s) ?? (busy ? 'skip:tts_busy' : null);
      if (block != null) {
        _skipOnce(out, t, a.alertId, block, 1);
        // 警報が待っている間は、それより低い優先度の話を始めない。
        // A の候補にも同じ理由を残し、待たせる（範囲を出たら skip:expired）。
        for (final c in _narrativeCandidates(t, out)) {
          _skipOnce(out, t, c.landmark.id, block, 5);
          _waiting.add(c.landmark.id);
        }
        return;
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

    // カメラで調べない区域の知らせ：警報の次、A より先。割り込まず、話し終えるのを待つ。
    if (_zoneNotices.isNotEmpty) {
      if (_audioBlock(s) != null || busy || crossing) return;
      final n = _zoneNotices.removeAt(0);
      if (n.entered) _zoneEntryAnnounced.add(n.zoneId);
      _speak(
        out,
        t: t,
        reason: n.entered
            ? 'speak:no_camera_zone_entered'
            : 'speak:no_camera_zone_exited',
        targetId: n.zoneId,
        text: n.entered
            ? 'ここからは、カメラで調べない区域です。画像での案内を止めます。'
            : 'カメラで調べない区域を出ました。画像での案内を再開します。',
        priority: 2,
        interrupt: false,
        pauseMusic: false,
        narrative: false,
      );
      return;
    }

    // 頼まれた検索の答え：警報の次に優先し、話している途中の A・B に割り込む。
    // 話題の間隔・まもなく始まる A は見ない。横断歩道の手前・乗り物・音声を出せない・
    // 警報の読み上げ中は待つ（鮮度期限を過ぎたら _expireVisual で捨てる）。
    final pending = _pendingAnswer;
    if (pending != null && pending.search.requested) {
      if (_audioBlock(s) == null &&
          s.activity != Activity.inVehicle &&
          !_crossingAhead() &&
          !_alertSpeaking(t)) {
        _speakVisualAnswer(t, out, interrupt: busy);
      }
      return;
    }

    // 5. A：ランドマークとエリア（デモで頼まれた案内は、本物の候補より先。同じ文脈ゲートを通る）
    final demo = _demoNarration;
    final candidates = [
      if (demo != null) demo,
      for (final c in _narrativeCandidates(t, out))
        if (c.landmark.id != demo?.landmark.id) c,
    ];
    // 話題の間隔は B の前後だけ。A → A・警報 → A は短く空ける。
    final gate = _narrativeGate(
      s,
      t,
      busy,
      _lastSpeechVisual ? config.topicIntervalMs : config.narrativeChainGapMs,
    );
    if (gate != null) {
      for (final c in candidates) {
        _skipOnce(out, t, c.landmark.id, gate, 5);
        if (identical(c, demo)) continue; // デモの案内は話せるまで待つ（期限切れにしない）
        _waiting.add(c.landmark.id);
        if (gate == 'skip:crossing_ahead') _crossingDeferred.add(c.landmark.id);
      }
      return; // B の答えも同じゲートで待つ（鮮度期限を過ぎたら _expireVisual で捨てる）
    }
    if (candidates.isNotEmpty) {
      final c = candidates.first;
      if (identical(c, demo)) _demoNarration = null;
      _crossingDeferred.remove(c.landmark.id);
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
    if (_speakAfterCrossing(t, out)) return;

    // 6. B の答え。前の話の終わりから話題の間隔を空ける（B が続けて話し続けないように）。
    final end = _lastSpeechEndMs;
    if (end != null && t - end < config.topicIntervalMs) return;
    _speakVisualAnswer(t, out);
  }

  /// デモ撮影用：ワンタップで頼まれたランドマークの案内を、A の候補の先頭に置く（11/7）。
  ///
  /// 話した履歴にあっても話す（撮り直しのため）。方向は今の位置と向きから付ける（遠くても
  /// 嘘にならないよう「〜の方に」）。ランドマークを持っていない・位置が無ければ見送る。
  void _onDemoLandmark(DemoLandmarkRequested e, List<Command> out) {
    final hasPosition = _projection != null && _sensor != null;
    Landmark? lm = e.landmarkId == null ? null : _landmarks[e.landmarkId];
    if (lm == null && e.landmarkId == null && hasPosition) {
      double best = double.infinity;
      for (final c in _landmarks.values) {
        if (c.kind == 'area') continue;
        final d = (_local(c.lat, c.lon) - _position).length;
        if (d < best) {
          best = d;
          lm = c;
        }
      }
    }
    if (lm == null || !hasPosition) {
      _log(out, e.tMs, 'skip', 'skip:demo_no_landmark', e.landmarkId, priority: 5);
      return;
    }
    final rel = _local(lm.lat, lm.lon) - _position;
    final word = directionWord(angleDiffDeg(rel.bearingDeg, _heading), config);
    _lastSkipReason.remove(lm.id);
    _demoNarration = _Candidate(
      lm,
      0,
      'speak:demo_landmark',
      '$wordの方に${lm.name}があります。${lm.scriptShort}',
    );
  }

  /// 横断歩道で延期した A の話のうち、もう範囲を出たもの（渡っている間に通り過ぎた）を話す。
  /// 方向の一言は付けない（渡ったあとでは向きが変わっているため）。離れすぎたものは捨てる。
  bool _speakAfterCrossing(int t, List<Command> out) {
    while (_crossingDeferred.isNotEmpty) {
      final id = _crossingDeferred.first;
      _crossingDeferred.remove(id);
      final lm = _landmarks[id];
      if (lm == null || _told.contains(id)) continue;
      if (_outsideBy(lm) > config.crossingDeferMarginM) {
        _log(out, t, 'skip', 'skip:expired', id, priority: 5);
        continue;
      }
      _speak(
        out,
        t: t,
        reason: 'speak:after_crossing',
        targetId: id,
        text: lm.scriptShort,
        priority: 5,
        interrupt: false,
        pauseMusic: false,
        narrative: true,
      );
      return true;
    }
    return false;
  }

  /// 横断歩道で延期した A の話（ランドマークの ID。延期した順）。
  final Set<String> _crossingDeferred = <String>{};

  /// 最後に横断歩道の手前（渡っている間を含む）だった時刻。B の答えの鮮度はここから数え直す。
  int? _lastCrossingMs;

  /// 音声を出せない状態。警報もナラティブも待つ。
  String? _audioBlock(SensorFrame s) {
    if (s.audioOut == AudioOut.none) return 'skip:no_audio_output';
    if (s.inCall) return 'skip:in_call';
    return null;
  }

  /// A の文脈ゲート（CLAUDE.md 5章）。null なら話してよい。
  String? _narrativeGate(SensorFrame s, int t, bool busy, int intervalMs) {
    final audio = _audioBlock(s);
    if (audio != null) return audio;
    if (s.activity == Activity.inVehicle) return 'skip:in_vehicle';
    if (_velocity.length > config.fastWalkingMps) return 'skip:fast_walking';
    if (_crossingAhead()) return 'skip:crossing_ahead';
    // 頼まれた検索の答えを待っている間は A を始めない（答えで A を切ることになるため）。
    if (_inflight?.requested ?? false) return 'skip:awaiting_search';
    if (busy) return 'skip:tts_busy';
    final end = _lastSpeechEndMs;
    if (end != null && t - end < intervalMs) {
      return 'skip:topic_interval';
    }
    return null;
  }

  /// 横断歩道・信号が手前（一定距離内で、まだ渡っていない側）にあるか。
  /// 横断歩道・信号の手前か（地図＋画像。11/7）。
  ///
  /// 1. 地図の横断歩道が [EngineConfig.crossingNearM]（8m）以内の前にある → 手前（画像に関係なく）
  /// 2. 画像に縞模様が写ってから [EngineConfig.crossingVisualHoldMs]（3秒）以内 → 手前
  ///    （地図に無い・位置がずれた横断歩道も拾う）
  /// 3. 地図の横断歩道が [EngineConfig.crossingDistanceM]（15m）以内の前にある → 手前。
  ///    ただし画質の足りる画像で縞模様が写らない状態が [EngineConfig.crossingVisualClearMs]（2秒）
  ///    続いていれば、手前とはみなさない（GPS のずれで止まりすぎない）
  ///
  /// 縞模様の値が無い画像（古いログ・計算しない端末）だけなら、前と同じく地図の15m だけで決まる。
  bool _crossingAhead() {
    if (_mapCrossingAhead(config.crossingNearM)) return true;
    final t = _sensor?.tMs;
    final seen = _crosswalkSeenMs;
    if (t != null && seen != null && t - seen <= config.crossingVisualHoldMs) {
      return true;
    }
    if (!_mapCrossingAhead(config.crossingDistanceM)) return false;
    final clear = _crosswalkClearSinceMs;
    return !(t != null &&
        clear != null &&
        t - clear >= config.crossingVisualClearMs);
  }

  /// 地図の横断歩道が [distanceM] 以内の前にあるか（止まっているときは向きを問わない）。
  bool _mapCrossingAhead(double distanceM) {
    final v = _velocity;
    for (final c in _crossings.values) {
      final rel = _local(c.lat, c.lon) - _position;
      if (rel.length > distanceM) continue;
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
    final stoppedSince = _stoppedSinceMs;
    final still =
        stoppedSince != null && t - stoppedSince >= config.longVersionStillMs;
    for (final lm in _landmarks.values) {
      final rel = _local(lm.lat, lm.lon) - _position;
      final outside = _outsideBy(lm);
      if (_heldUntilLeft.contains(lm.id)) {
        if (outside > config.revisitMarginM) {
          _heldUntilLeft.remove(lm.id); // 離れた。次に近づいたら最初から話す
        } else {
          _skipOnce(out, t, lm.id, 'skip:interrupted', 5);
          continue;
        }
      }
      // 開発者モードの検証用：離れたら話した履歴から外す（もう一度近づいたら話す）
      if (config.retellOnRevisit &&
          outside > config.revisitMarginM &&
          _told.remove(lm.id)) {
        _crossingDeferred.remove(lm.id);
      }
      _Candidate? candidate;
      String? notPossible;
      if (lm.kind == 'area') {
        if (outside == 0) {
          candidate = _Candidate(lm, 0, 'speak:area_entered', lm.scriptShort);
        }
      } else {
        final window = _windowFor(lm, rel, v);
        if (window != null &&
            window.closestS <= config.proximityHorizonMs / 1000) {
          final useLong = still && outside == 0;
          final lead = _directionLead(lm, rel, window);
          // 長い版 → 短い版 → 方向と名前だけ、の順に、範囲を出る前に話し終えられるものを選ぶ。
          final texts = [
            if (useLong) lead + lm.scriptLong,
            lead + lm.scriptShort,
            lead,
          ];
          for (final text in texts) {
            if (window.exitS * 1000 < _durationMs(text)) continue;
            candidate = _Candidate(
              lm,
              window.closestS,
              useLong && identical(text, texts.first)
                  ? 'speak:long_version_still'
                  : 'speak:closest_approach',
              text,
            );
            break;
          }
          if (candidate == null) notPossible = 'skip:pass_before_end';
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
        // 横断歩道で延期したものは捨てない（渡り終えてから _speakAfterCrossing で話す）
        if (!_crossingDeferred.contains(lm.id)) {
          _skipOnce(out, t, lm.id, 'skip:expired', 5);
        }
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
  ///
  /// 最も近い点を過ぎていて、後ろ寄り（横より後ろ）にあるときは「いま通り過ぎたのは〜」と言う。
  /// 「後方に〜があります」では、振り返らないと見えないものを今あるように言ってしまうため。
  /// 止まっていて後ろ寄りにあるときは「振り返ると〜があります。」と言う（見る向きが分かるように）。
  String _directionLead(Landmark lm, Vec2 rel, _Window window) {
    final diff = angleDiffDeg(rel.bearingDeg, _heading);
    if (diff.abs() > config.directionSideDeg) {
      if (_velocity.length == 0) return '振り返ると${lm.name}があります。';
      if (window.closestS < 0) return 'いま通り過ぎたのは${lm.name}です。';
    }
    return '${directionWord(diff, config)}に${lm.name}があります。';
  }

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
      final window = _windowFor(lm, _local(lm.lat, lm.lon) - _position, v);
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
      final window = _windowFor(lm, rel, v);
      if (window == null) continue;
      final text = lm.kind == 'area'
          ? lm.scriptShort
          : _directionLead(lm, rel, window) + lm.scriptShort;
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
    if (_inNoCameraZone) {
      _searchSkipOnce(out, t, 'search_skip:no_camera_zone');
      return;
    }

    // 計測の間隔（既定20秒）は最後に撮った時刻から。最初の1枚は位置と向きが初めて取れてから（論点1・2）。
    final ref = _searchRefMs;
    if (ref == null) return;
    final elapsed = t - ref;
    final String reason;
    if (elapsed >= config.visualIntervalMs) {
      reason = 'search:interval_elapsed';
      // 定期の時刻に話している途中なら、この回は撮らない。話し終えるのを待たず、
      // 次の間隔まで数え直す（読み上げの直後に続けて撮って話さないため）
      if (_engineSpeaking(t) || s.ttsSpeaking) {
        _intervalRestartMs = t;
        _searchSkipOnce(out, t, 'search_skip:gate_blocked');
        return;
      }
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

  /// 「調べて」と頼まれた（検索ボタン・「検索して」）：そのときの景色で一度だけ撮影を試す（仕様書 2章）。
  ///
  /// 計測間隔と「同じ場所」は見ない。警報以外の読み上げ中でも撮る（答えはその話に割り込む）。
  /// 安全の条件（横断歩道の手前・乗り物・早歩き）と、音声を出せない・警報中・画質不足では撮らない。
  /// 撮れなければ理由を残して依頼を終える（渡ったあとなどに勝手に撮らない）。
  void _onSearchRequested(SearchRequested e, List<Command> out) {
    final s = _sensor;
    if (s != null && _inNoCameraZone) {
      _refuseInNoCameraZone(s, e.tMs, out);
      return;
    }
    final String? skip;
    if (s == null) {
      skip = 'search_skip:gate_blocked'; // 位置や向きがまだ取れていない
    } else if (_inflight != null) {
      skip = 'search_skip:gate_blocked'; // 前の検索が終わっていない
    } else {
      skip = _requestedCaptureBlock(s, e.tMs);
    }
    if (skip != null) {
      _lastSearchSkip = skip; // 画面で見送った理由を出す
      _log(out, e.tMs, 'search_skip', skip, null, priority: 6);
      return;
    }
    _capture(s!, e.tMs, 'search:user_requested', out, requested: true);
    // 頼まれたことが分かるよう「検索します」と返事する（テンプレート）。話している途中の A・B は
    // 止める（止めた A は続きを話さない）。声そのものが合図なので合図音は鳴らさない。
    _speak(
      out,
      t: e.tMs,
      reason: 'speak:search_ack',
      targetId: _inflight!.id,
      text: '検索します。',
      priority: 2,
      interrupt: _engineSpeaking(e.tMs) || s.ttsSpeaking,
      pauseMusic: false,
      narrative: false,
      chime: false,
    );
  }

  /// カメラで調べない区域の中で「調べて」と頼まれた：撮らずに決まった文で断り、依頼を終える
  /// （出たあとに勝手に撮らない）。返事は「検索します」と同じく話している途中の A・B を止める。
  /// 音声を出せない・警報を読み上げ中なら、理由だけ記録する。
  void _refuseInNoCameraZone(SensorFrame s, int t, List<Command> out) {
    const reason = 'search_skip:no_camera_zone';
    _lastSearchSkip = reason;
    if (_audioBlock(s) != null || _alertSpeaking(t)) {
      _log(out, t, 'search_skip', reason, null, priority: 6);
      return;
    }
    _speak(
      out,
      t: t,
      kind: 'search_skip',
      reason: reason,
      targetId: noCameraZone!.id,
      text: 'ここはカメラで調べない区域なので、調べられません。',
      priority: 2,
      interrupt: _engineSpeaking(t) || s.ttsSpeaking,
      pauseMusic: false,
      narrative: false,
      chime: false,
    );
  }

  /// 頼まれた検索の見送りの条件。自動（[_captureBlock]）と違い、読み上げ中・話題の間隔・
  /// 待っている B の答え・まもなく始まる A では止めない。警報だけは横取りしない。
  String? _requestedCaptureBlock(SensorFrame s, int t) {
    final max = config.maxSearchesPerWalk;
    if (max != null && _searchCount >= max) {
      return 'search_skip:limit_reached';
    }
    if (_audioBlock(s) != null ||
        s.activity == Activity.inVehicle ||
        _velocity.length > config.fastWalkingMps ||
        _crossingAhead() ||
        _pendingAlerts.isNotEmpty ||
        _alertSpeaking(t)) {
      return 'search_skip:gate_blocked';
    }
    return _qualityBlock(s);
  }

  /// エンジンが警報を読み上げている最中か。
  bool _alertSpeaking(int t) =>
      _engineSpeaking(t) && _seenAlerts.contains(_speaking!.targetId);

  String? _qualityBlock(SensorFrame s) {
    final q = s.imageQuality;
    if (q == null ||
        q.blur < config.minBlur ||
        q.brightness < config.minBrightness) {
      return 'search_skip:low_quality';
    }
    return null;
  }

  /// 自動でも「調べて」でも共通の見送りの条件。null なら撮ってよい。
  String? _captureBlock(SensorFrame s, int t) {
    final max = config.maxSearchesPerWalk;
    if (max != null && _searchCount >= max) {
      return 'search_skip:limit_reached';
    }
    if (_searchBlocked(s, t)) return 'search_skip:gate_blocked';
    return _qualityBlock(s);
  }

  void _capture(
    SensorFrame s,
    int t,
    String reason,
    List<Command> out, {
    bool requested = false,
  }) {
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
      requested: requested,
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
    if (_inNoCameraZone) {
      // 区域に入る前に撮った答えが、区域の中で届いた：話さずに捨てる
      _logAnswer(out, t, 'answer:in_no_camera_zone', search.id, r);
      return;
    }
    if (t - search.capturedMs > config.visualFreshnessMs) {
      _logAnswer(out, t, 'answer:expired', search.id, r);
      return;
    }
    if (r.result == 'unknown') {
      _logAnswer(out, t, 'answer:unknown', search.id, r);
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
      if (r.part == 'whole') {
        // ランドマーク全体は B では話さない。全体の紹介は A が近づいたときに行う（CLAUDE.md 6章、11/6 夜決定）。
        _logAnswer(out, t, 'answer:whole_left_to_narrative', lm.id, r);
        return;
      }
      // 画像から見つけた特徴は、根拠が地図にないので0.7（CLAUDE.md 6章「B の仕様」）。
      if (r.confidence < config.unlistedMinConfidence) {
        _logAnswer(out, t, 'answer:low_confidence', search.id, r);
        return;
      }
      // 全体の紹介（A）より先に部分を話さない（11/6 夜決定）。
      if (!_told.contains(lm.id)) {
        _logAnswer(out, t, 'answer:feature_before_intro', lm.id, r);
        return;
      }
      // 登録したランドマークの特徴：全体の紹介とは別の話。（ランドマーク, part）で重複を見る。
      final feature = _ToldObject(
        landmarkId: lm.id,
        name: lm.name,
        named: true,
        areaId: null,
        position: search.position,
        part: r.part!,
      );
      // other は部分を見分けられないので、全体の紹介が済んでいれば（＝ここに来れば必ず）話さない。
      // 頼まれた検索は、同じ部分でももう一度話す（11/6 メンバー3決定。黙ると壊れて見えるため）。
      if ((feature.part == 'other' || _toldObjects.any(feature.sameAs)) &&
          !search.requested) {
        _logAnswer(out, t, 'answer:already_told', lm.id, r);
        return;
      }
      _setPendingAnswer(t, out);
      _pendingAnswer = _VisualAnswer(
        search: search,
        reason: 'answer:landmark_feature',
        targetId: lm.id,
        name: lm.name,
        body: r.description!,
        partLabel: visualPartLabels[r.part],
        toldObject: feature,
        sources: r.sources,
      );
      return;
    }
    if (r.confidence < config.unlistedMinConfidence) {
      _logAnswer(out, t, 'answer:low_confidence', search.id, r);
      return;
    }
    // エリアの中のものは、エリアの紹介（A）が済んでから話す（11/6 夜決定）。
    final areaId = search.areaId;
    if (areaId != null && !_told.contains(areaId)) {
      _logAnswer(out, t, 'answer:feature_before_intro', areaId, r);
      return;
    }
    // unlisted：候補外の対象。（名前で探した場所, part）で重複を判定する（論点9）。
    final object = _ToldObject(
      name: r.objectName!,
      named: r.named,
      areaId: search.areaId,
      position: search.position,
      part: r.part!,
      genericRadiusM: config.genericObjectDedupM,
    );
    if (_toldObjects.any(object.sameAs) && !search.requested) {
      _logAnswer(out, t, 'answer:already_told', search.id, r);
      return;
    }
    _setPendingAnswer(t, out);
    _pendingAnswer = _VisualAnswer(
      search: search,
      reason: r.named ? 'answer:named_object' : 'answer:unlisted_object',
      targetId: search.id,
      name: r.objectName!,
      body: r.description!,
      toldObject: object,
      sources: r.sources,
    );
  }

  /// 新しい答えを待たせる前に、まだ話していない古い答え（自動の検索の分）を捨てた記録を残す。
  void _setPendingAnswer(int t, List<Command> out) {
    final old = _pendingAnswer;
    if (old == null) return;
    _pendingAnswer = null;
    _log(
      out,
      t,
      'answer',
      'answer:expired',
      old.targetId,
      priority: 6,
      sources: old.sources.isEmpty ? null : old.sources,
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
  void _expireVisual(int t, List<Command> out, {bool crossing = false}) {
    final search = _inflight;
    if (search != null && t - search.capturedMs > config.visualFreshnessMs) {
      _inflight = null;
      _abandonedSearches.add(search.id);
      _log(out, t, 'answer', 'answer:error', search.id, priority: 6);
    }
    // 答えを待たせている間に横断歩道を渡ったら、鮮度は渡り終えた時刻から数える（渡っている間は捨てない）
    final answer = _pendingAnswer;
    final crossed = _lastCrossingMs;
    final since = answer == null
        ? 0
        : (crossed != null && crossed > answer.search.capturedMs
              ? crossed
              : answer.search.capturedMs);
    if (answer != null && !crossing && t - since > config.visualFreshnessMs) {
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

  /// 待っている B の答えを話す。自動の分は A のゲートを通ったあとに呼ぶ。
  /// 頼まれた分は警報のすぐ後に呼び、[interrupt] で今の話（警報以外）に割り込む。
  void _speakVisualAnswer(int t, List<Command> out, {bool interrupt = false}) {
    final answer = _pendingAnswer;
    if (answer == null) return;
    _pendingAnswer = null;
    if (_inNoCameraZone) {
      // 待っている間に区域に入った：話さずに捨てる
      _log(
        out,
        t,
        'answer',
        'answer:in_no_camera_zone',
        answer.targetId,
        priority: 6,
      );
      return;
    }
    final requested = answer.search.requested;
    // 論点10：過去形・方向つき。方向は撮ったときの視線と、いまの進行方向の差。
    final direction = directionWord(
      angleDiffDeg(answer.search.gazeAzDeg, _heading),
      config,
    );
    final part = answer.partLabel;
    final text = part == null
        ? 'さっき$directionに見えたのは${answer.name}です。${answer.body}'
        : 'さっき$directionに見えたのは${answer.name}の$partです。${answer.body}';
    // B を話し終えて話題の間隔を空けると、直後の A が通り過ぎて話せなくなるなら B を見送る（仕様書 5章）。
    if (!requested &&
        _narrativeMissedAfter(_durationMs(text) + config.topicIntervalMs)) {
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
      interrupt: interrupt,
      pauseMusic: false,
      // 定期の検索の答えは合図音を鳴らさない（頼まれた検索の答えだけ鳴らす）
      chime: requested,
      narrative: false, // B は全体を話さないので、A で話した扱いにはしない
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

  /// いまいる町丁目（いちばん近い代表点）。わからなければ null。
  final Town? currentTown;

  /// いま中にいるカメラで調べない区域。外なら null。中にいる間は B を撮らない。
  final NoCameraZone? noCameraZone;

  /// B の次の計測までのミリ秒。0 なら計測できる状態待ち（ゲート・画質など）。
  /// 結果待ち・上限到達・センサー未着のときは null。
  final int? nextSearchInMs;

  /// B を止めている理由。判断ログの reason と同じ理由コード（例：search_skip:gate_blocked）。
  /// 撮ったら null に戻る。止められていなければ null。
  final String? searchSkipReason;

  /// B の結果を待っているか。
  final bool searching;

  /// この歩行で B をあと何回計測できるか。上限なし（既定）なら null。
  final int? searchesLeft;

  /// 最後の判断（理由コードつき）。まだなければ null。
  final Decision? lastDecision;

  EngineView({
    required this.tMs,
    required List<NearbyLandmark> nearby,
    required this.currentArea,
    required this.currentTown,
    required this.noCameraZone,
    required this.nextSearchInMs,
    required this.searchSkipReason,
    required this.searching,
    required this.searchesLeft,
    required this.lastDecision,
  }) : nearby = List.unmodifiable(nearby);
}

/// 近い2点の距離（m）。cloud/data/scripts/town_lookup.py の distance_m と同じ式（平面で近似）。
double townDistanceM(double lat1, double lon1, double lat2, double lon2) {
  const mPerDegLat = 111320.0;
  final dy = (lat2 - lat1) * mPerDegLat;
  final dx =
      (lon2 - lon1) * mPerDegLat * math.cos((lat1 + lat2) / 2 * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

/// 画面に出すカメラで調べない区域。
final class NoCameraZone {
  final String id, name;
  const NoCameraZone({required this.id, required this.name});
}

/// まだ話していない区域の知らせ。entered が true なら「入った」、false なら「出た」。
final class _ZoneNotice {
  final String zoneId;
  final bool entered;
  const _ZoneNotice({required this.zoneId, required this.entered});
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

  /// B の答えか。
  final bool visual;
  final _ToldObject? toldObject;
  final int expectedEndMs;
  const _Utterance({
    required this.id,
    required this.targetId,
    required this.narrative,
    required this.visual,
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

  /// 利用者が頼んだ検索（検索ボタン・「検索して」）。警報以外の話に割り込んで答え、
  /// 同じ対象でももう一度話す（頼んだのに黙ると壊れて見えるため）。
  final bool requested;
  const _Search({
    required this.id,
    required this.capturedMs,
    required this.gazeAzDeg,
    required this.areaId,
    required this.position,
    required this.candidateIds,
    this.requested = false,
  });
}

final class _VisualAnswer {
  final _Search search;
  final String reason, targetId, name, body;

  /// 登録したランドマークの特徴を話すときの部分の呼び方（例：入口）。それ以外は null。
  final String? partLabel;
  final _ToldObject? toldObject;
  final List<VisualSearchSource> sources;
  const _VisualAnswer({
    required this.search,
    required this.reason,
    required this.targetId,
    required this.name,
    required this.body,
    this.partLabel,
    required this.toldObject,
    required this.sources,
  });
}

/// B で話した話のかぎ（場所, part）。B の仕様書 5章・CLAUDE.md 6章「B の仕様」。
///
/// 場所は、登録したランドマークの特徴なら landmarkId。候補外の対象なら、固有名はエリア＋名前、
/// 一般名は名前＋撮った場所（genericRadiusM 以内）。ランドマーク全体の紹介はここに入れず、ID で A と共有する。
final class _ToldObject {
  final String? landmarkId;
  final String name;
  final bool named;
  final String? areaId;
  final Vec2 position;
  final double genericRadiusM;
  final String part;
  const _ToldObject({
    this.landmarkId,
    required this.name,
    required this.named,
    required this.areaId,
    required this.position,
    required this.part,
    this.genericRadiusM = 0,
  });

  bool samePlace(_ToldObject other) {
    if (landmarkId != null || other.landmarkId != null) {
      return landmarkId == other.landmarkId;
    }
    if (name != other.name || named != other.named) return false;
    if (named) return areaId == other.areaId;
    final radius = genericRadiusM > other.genericRadiusM
        ? genericRadiusM
        : other.genericRadiusM;
    return (position - other.position).length <= radius;
  }

  /// すでに話した [other] と同じ話か。同じ場所で同じ part なら同じ。
  /// part が other（その他）は見分けられないので、同じ場所で何か話していれば同じとみなす。
  bool sameAs(_ToldObject other) =>
      samePlace(other) && (part == other.part || part == 'other');
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

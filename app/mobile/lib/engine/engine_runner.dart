import 'dart:async';

import 'package:engine/engine.dart' as eng;
import 'package:flutter/foundation.dart';

import '../core/sensor_ticker.dart';
import '../executors/speak_executor.dart';
import '../info/info_source.dart';
import '../net/tile_fetcher.dart';
import '../sources/activity_source.dart';
import '../vision/search_progress.dart';
import '../vision/visual_searcher.dart';

/// 判断エンジン（app/engine）を動かし、返ってきた指示（Command）を実行する係。合流3。
///
/// - センサーの値を1秒ごとに `SensorFrame` で渡す
/// - `FetchTiles` → [TileFetcher] で取り、届いたタイルを `TilesLoaded` で渡す（空のタイルも渡す）
/// - `Speak` → 読み上げ（[SpeakExecutor]）。話し終えた・止めたら `TtsFinished` を返す
/// - 警報 → `AlertReceived` で渡す（話すか・割り込むかは engine が決める）
/// - `CaptureAndSearch` → [VisualSearcher] で撮影・顔ぼかし・送信し、`VisualResult` / `VisualError` を返す（合流4）
/// - 検索ボタン・「検索して」の声 → [requestSearch] で `SearchRequested` を渡す（撮るかは engine が決める）
/// - 判断（`LogDecision`）と「いまの状態」（`engine.view`）を画面に出す
///
/// engine に渡したイベントは、`sensor` 以外も歩行ログに同じ形で残す（[record]）。
/// 歩行ログを engine にもう一度流すと、同じ判断になる（決定論）。
/// 1回の計測ごとに作り直す（engine の状態は計測の間だけ持つ）。
class EngineRunner {
  EngineRunner({
    required this.speaker,
    required this.tiles,
    required this.record,
    this.searcher,
    bool Function()? searchEnabled,
    eng.EngineConfig config = const eng.EngineConfig(),
    int Function()? now,
  }) : engine = eng.Engine(config: config),
       _now = now ?? _systemMs,
       _searchEnabled = searchEnabled ?? _always {
    _tileSub = tiles.loaded.listen(_onTile);
    _finishedSub = speaker.finished.listen(_onFinished);
  }

  static int _systemMs() => DateTime.now().toUtc().millisecondsSinceEpoch;
  static bool _always() => true;

  final eng.Engine engine;
  final SpeakExecutor speaker;
  final TileFetcher tiles;

  /// B の撮影と送信の係（無ければ撮らない。engine は結果の来ない検索を15秒で諦める）。
  final VisualSearcher? searcher;

  /// 画像検索がオンか（設定画面・画面上の札で切り替える）。オフなら撮らない。
  final bool Function() _searchEnabled;

  /// 歩行ログに1行足す（`eng.eventToJson` の形）。
  final void Function(Map<String, dynamic> row) record;
  final int Function() _now;

  /// 画面に出す「いまの状態」。handle のたびに更新する。
  final ValueNotifier<eng.EngineView?> view = ValueNotifier(null);

  /// 最後の判断（画面の「今の判断」）。
  final ValueNotifier<eng.Decision?> lastDecision = ValueNotifier(null);

  /// B の検索の進み具合（画面の札）。頼んだ検索を engine が見送ったときは skipped。
  final ValueNotifier<SearchProgress?> searchProgress = ValueNotifier(null);

  final Set<String> _myUtterances = {};
  final List<eng.EngineEvent> _queue = [];
  bool _handling = false;
  bool _closed = false;
  int _lastTMs = 0;
  StreamSubscription<TileData>? _tileSub;
  StreamSubscription<String>? _finishedSub;

  /// engine の時間はイベントの tMs だけで進む。戻らないようにそろえる。
  int _t([int? t]) {
    final v = t ?? _now();
    _lastTMs = v > _lastTMs ? v : _lastTMs;
    return _lastTMs;
  }

  // ---- 入力 ----

  void onSnapshot(SensorSnapshot s) {
    final loc = s.location;
    final q = s.imageQuality;
    _push(
      eng.SensorFrame(
        tMs: _t(s.tMs),
        lat: loc.lat,
        lon: loc.lon,
        accM: loc.accM,
        speedMps: loc.speedMps,
        courseDeg: loc.courseDeg,
        gazeAzDeg: s.gaze.azDeg,
        gazePitchDeg: s.gaze.pitchDeg.clamp(-90.0, 90.0),
        activity: switch (s.activity) {
          ActivityKind.walking => eng.Activity.walking,
          ActivityKind.still => eng.Activity.still,
          ActivityKind.inVehicle => eng.Activity.inVehicle,
          ActivityKind.unknown => eng.Activity.unknown,
        },
        audioOut: s.audio.earphone
            ? eng.AudioOut.earphone
            : eng.AudioOut.speaker,
        inCall: s.audio.inCall,
        ttsSpeaking: s.ttsSpeaking,
        imageQuality: q == null
            ? null
            : eng.ImageQuality(
                blur: q.blur.clamp(0.0, 1.0),
                brightness: q.brightness.clamp(0.0, 1.0),
              ),
      ),
      log: false, // sensor 行は SessionController が書いている
    );
  }

  /// 警報（サーバーから届いたものだけ）。
  void onAlert(InfoItem a) {
    _push(
      eng.AlertReceived(
        tMs: _t(a.receivedMs),
        alertId: a.id,
        level: a.level ?? 1,
        kind: a.data['kind'] as String? ?? '気象警報',
        areaName: a.data['area_name'] as String? ?? '',
        text: a.text,
      ),
      log: false, // alert 行は AppServices が受け付けたときに書いている
    );
  }

  /// 利用者が検索を頼んだ（検索ボタン・「検索して」の声）。
  ///
  /// 撮るかどうかは engine が決める。読み上げ中・横断歩道の手前などで撮れないときは、
  /// engine が見送った理由を判断として出す（画面の「今の判断」に出る）。あとで勝手に撮らない。
  void requestSearch({bool byVoice = false}) {
    final decisions = <eng.Decision>[];
    _collect = decisions;
    _requestVia = byVoice ? 'voice' : 'button';
    try {
      _push(eng.SearchRequested(tMs: _t()));
    } finally {
      _collect = null;
      _requestVia = null;
    }
    for (final d in decisions) {
      if (d.kind == 'search_skip') {
        searchProgress.value = SearchProgress(
          SearchPhase.skipped,
          requested: true,
          detail: d.reason,
        );
      }
    }
  }

  /// [requestSearch] の間に出た判断を集める所（それ以外のときは null）。
  List<eng.Decision>? _collect;

  /// [requestSearch] の間だけ、頼んだ手段（`button`・`voice`）。
  String? _requestVia;

  /// 撮影の手がかり（B の送信の `context`）を、指示が出た瞬間の engine の状態から作る。
  /// 正確な座標は入れない（町丁目名・ランドマーク名・日本時間の分まで・きっかけだけ）。
  eng.SearchContext _searchContext(String? reason, bool requested) =>
      eng.SearchContext(
        capturedAt: jstMinute(DateTime.fromMillisecondsSinceEpoch(_now())),
        trigger: requested
            ? (_requestVia ?? 'button')
            : reason == 'search:stopped_early'
            ? 'stopped'
            : 'auto',
        town: engine.view.currentTown?.name,
        nearLandmark: engine.nearLandmark,
      );

  Future<void> _search(
    eng.CaptureAndSearch c, {
    bool requested = false,
    eng.SearchContext? context,
  }) async {
    final s = searcher;
    if (s == null || !_searchEnabled()) return;
    void show(SearchPhase phase, [String? detail]) {
      if (_closed) return;
      searchProgress.value = SearchProgress(
        phase,
        requested: requested,
        detail: detail,
      );
    }

    final VisualOutcome outcome;
    try {
      outcome = await s.run(c, onPhase: show, context: context);
    } catch (_) {
      show(SearchPhase.failed, 'server');
      // 結果待ちのまま残さない（頼んだ検索だと、その間 A も次の検索も止まるため）
      _push(eng.VisualError(tMs: _t(), searchId: c.searchId, error: 'server'));
      return;
    }
    switch (outcome) {
      case VisualAnswered(:final response):
        show(SearchPhase.answered);
        _push(eng.VisualResult(tMs: _t(), response: response));
      case VisualFailed(:final error):
        show(SearchPhase.failed, error);
        _push(eng.VisualError(tMs: _t(), searchId: c.searchId, error: error));
      case VisualNoFrame():
        show(SearchPhase.failed, 'no_frame');
        // 撮れなかったことをすぐ engine に返し、結果待ちを終わらせる（待つと、頼んだ検索では
        // 15秒の間 A も次の検索も止まる）。schema の失敗の種類にカメラが無いので、
        // 端末の中の失敗として server で返す（画面の札には「撮れませんでした」と出す）
        _push(
          eng.VisualError(tMs: _t(), searchId: c.searchId, error: 'server'),
        );
    }
  }

  void _onTile(TileData d) {
    final eng.TileResponse tile;
    try {
      tile = eng.TileResponse.fromJson(Map<String, dynamic>.from(d.json));
    } catch (_) {
      return; // 形が違うタイルは渡さない（engine がまた頼む）
    }
    _push(eng.TilesLoaded(tMs: _t(), tile: tile));
  }

  void _onFinished(String id) {
    if (!_myUtterances.remove(id)) return; // engine の発話ではない（試し聞きなど）
    _push(eng.TtsFinished(tMs: _t(), utteranceId: id));
  }

  // ---- 実行 ----

  void _push(eng.EngineEvent e, {bool log = true}) {
    if (_closed) return;
    if (log) record(eng.eventToJson(e));
    _queue.add(e);
    if (_handling) return; // 処理の途中で増えた分は、続けて処理する
    _handling = true;
    try {
      while (_queue.isNotEmpty) {
        final ev = _queue.removeAt(0);
        final List<eng.Command> cmds;
        try {
          cmds = engine.handle(ev);
        } catch (_) {
          continue; // 1つのイベントで止まらない
        }
        // 撮影の理由（search:〜）を検索 ID ごとに。頼まれた検索か・立ち止まりかを見分ける
        final reasons = <String?, String>{
          for (final c in cmds)
            if (c is eng.LogDecision && c.decision.kind == 'search')
              c.decision.targetId: c.decision.reason,
        };
        for (final c in cmds) {
          _run(c, reasons);
        }
      }
      view.value = engine.view;
    } finally {
      _handling = false;
    }
  }

  void _run(eng.Command c, Map<String?, String> searchReasons) {
    switch (c) {
      case eng.Speak():
        _myUtterances.add(c.utteranceId);
        speaker.execute(
          SpeakRequest(
            utteranceId: c.utteranceId,
            text: c.text,
            priority: c.priority,
            interrupt: c.interrupt,
            pauseMusic: c.pauseMusic,
            chime: c.chime,
          ),
        );
      case eng.FetchTiles():
        tiles.request([for (final t in c.tiles) TileId(t.x, t.y, z: t.z)]);
      case eng.CaptureAndSearch():
        final reason = searchReasons[c.searchId];
        final requested = reason == 'search:user_requested';
        unawaited(
          _search(
            c,
            requested: requested,
            context: _searchContext(reason, requested),
          ),
        );
      case eng.LogDecision():
        lastDecision.value = c.decision;
        _collect?.add(c.decision);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    await _tileSub?.cancel();
    await _finishedSub?.cancel();
    view.dispose();
    lastDecision.dispose();
    searchProgress.dispose();
  }
}

/// 日本時間の分までの日時（`2026-11-07T14:05+09:00`）。B の送信の `context.captured_at`。
String jstMinute(DateTime t) {
  final j = t.toUtc().add(const Duration(hours: 9));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${j.year.toString().padLeft(4, '0')}-${two(j.month)}-${two(j.day)}'
      'T${two(j.hour)}:${two(j.minute)}+09:00';
}

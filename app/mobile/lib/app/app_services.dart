import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:engine/engine.dart' as eng;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import '../core/sensor_ticker.dart';
import '../dev/fake_gps.dart';
import '../engine/engine_runner.dart';
import '../executors/speak_executor.dart';
import '../executors/voice_catalog.dart';
import '../executors/voicevox_tts.dart';
import '../info/alert_list_fetcher.dart';
import '../info/alert_message.dart';
import '../info/fcm_alerts.dart';
import '../info/heard_store.dart';
import '../info/info_hub.dart';
import '../info/info_kind.dart';
import '../info/info_source.dart';
import '../info/sources.dart';
import '../net/api_client.dart';
import '../net/tile_fetcher.dart';
import '../config.dart';
import '../logging/walk_log_store.dart';
import '../sources/activity_source.dart';
import '../sources/audio_state_source.dart';
import '../sources/camera_source.dart';
import '../sources/gaze_source.dart';
import '../sources/location_source.dart';
import '../sources/voice_command_source.dart';
import '../ui/glass_overlay.dart';
import '../vision/face_detector.dart';
import '../vision/search_progress.dart';
import '../vision/visual_searcher.dart';
import 'app_mode.dart';
import 'app_settings.dart';
import 'session_controller.dart';

/// アプリ全体で1つずつ持つ部品の組み立て場所。
/// 正式版やグラスに替えるときは、ここで渡す実装（Source・Policy）を差し替える。
class AppServices {
  AppServices({
    required this.camera,
    required this.ticker,
    required this.settingsStore,
    required this.voices,
    required this.policy,
    required this.mode,
    SpeakExecutor? speaker,
    this.fakeGps,
    this.useFcm = false,
    this.heardStore,
    this.tileCache,
    this.faceFinder,
    this.voiceCommands,
    ApiClient? api,
    AppSettings initialSettings = const AppSettings(),
  }) : api =
           api ??
           ApiClient(baseUrl: AppConfig.apiBaseUrl, token: AppConfig.appToken),
       settings = ValueNotifier(initialSettings),
       speaker =
           speaker ??
           SpeakExecutor(
             tts: FlutterTtsEngine(voices),
             focus: SessionAudioFocus(),
             chime: const ToneChime(),
           ) {
    session = SessionController(
      ticker: ticker,
      settings: () => settings.value,
      fakeLocation: () => fakeGps?.enabled ?? false,
    );
    // 字幕は話し始めの通知で画面に出す
    this.speaker.subtitle.addListener(
      () => overlay.value = overlay.value.withSubtitle(
        this.speaker.subtitle.value,
      ),
    );
    // 「検索します」の返事の終わりを覚える（自分の声を合図と聞き違えないため）
    this.speaker.subtitle.addListener(_trackAck);
    // 読み上げの終わりは、engine の発話の分だけ EngineRunner が歩行ログと engine に渡す
    // 声の設定を読み上げに反映する
    settings.addListener(() => this.speaker.useVoice(settings.value.voice));
    // 起動時に保存してあった声も当てておく（設定を変えるまで声1のままにならないように）
    unawaited(this.speaker.useVoice(settings.value.voice));
    // 外から届く情報（警報・気象・交通・イベント）。今は警報だけ中身があり、ほかは骨組み
    info = InfoHub(
      heard: heardStore,
      // 計測中は engine に渡し（話すか・割り込むかは engine が決める）。
      // 計測していないときは読まずに預かり、計測を始めたときに渡す
      sink: _alertSink = _AlertSink(this),
      now: () => DateTime.now().toUtc().millisecondsSinceEpoch,
      onAccepted: (item) {
        if (item.kind == InfoKind.alert) {
          _showAlert(item);
          session.recordEvent(
            'alert',
            alertRowData(item),
            tMs: item.receivedMs,
          );
        }
      },
    )..register(alerts);
    for (final s in plannedSources()) {
      info.register(s);
    }
    alertList = AlertListFetcher(
      baseUrl: AppConfig.alertsBaseUrl,
      onData: alerts.receive,
      onCurrent: _onAlertListCurrent,
    );
    tiles = TileFetcher(api: this.api, cache: tileCache);
    final faces = faceFinder;
    searcher = faces == null
        ? null
        : VisualSearcher(
            camera: camera,
            faces: faces,
            post: this.api.postVisualSearch,
            onSend: _saveSentImage,
          );
    // 画像検索をオフにしたら、声の聞き取りも止める
    settings.addListener(_syncVoice);
    // 歩き始めに警報の一覧を取りに行き、歩いている間は15分ごとに取り直す（FCM の取りこぼしの保険）
    session.addListener(_onSessionChanged);
  }

  /// 今出ている警報の一覧を取りに行く部品（FCM が届かなかったときの保険）。
  late final AlertListFetcher alertList;
  Timer? _alertListTimer;
  SessionPhase? _lastPhase;
  int _lastAlertFetchMs = 0;
  AppLifecycleListener? _lifecycle;

  void _onSessionChanged() {
    final phase = session.phase;
    if (phase == _lastPhase) return;
    _lastPhase = phase;
    _alertListTimer?.cancel();
    _alertListTimer = null;
    if (phase == SessionPhase.running) {
      _startEngine();
    } else {
      unawaited(_stopEngine());
    }
    if (phase == SessionPhase.running && useFcm) {
      unawaited(refreshAlerts());
      _alertListTimer = Timer.periodic(
        AlertListFetcher.refreshEvery,
        (_) => refreshAlerts(),
      );
    }
  }

  /// 警報の一覧を取りに行く。置き場所は1分ごとにしか変わらないので、[force] でなければ1分は空ける。
  /// 開発者モードのときは、デモ用の模擬の警報の一覧も取る。
  Future<void> refreshAlerts({bool force = false}) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (!force && now - _lastAlertFetchMs < 60 * 1000) return;
    _lastAlertFetchMs = now;
    await alertList.fetch();
    if (settings.value.developerMode || AppConfig.devTools) {
      final real = alertList.lastResult;
      await alertList.fetch(mock: true);
      alertList.lastResult = '$real ／ ${alertList.lastResult}';
    }
  }

  /// スマホ（デモ）用の組み立て。
  factory AppServices.phoneDemo({SettingsStore? store}) {
    final camera = PhoneCameraSource();
    // 声の選択と読み上げで同じ TTS を使う（flutter_tts の通知の受け口は1つのため）
    final tts = FlutterTts();
    final voices = VoiceCatalog(tts);
    // 声はすべてずんだもん（端末の中で作る）。声のファイルが無いビルドでは端末の声で話す
    final zunda = VoicevoxTtsEngine(fallback: FlutterTtsEngine(voices, tts));
    unawaited(zunda.warmUp()); // 初回は声のファイルを写すので、起動時に始めておく
    final speaker = SpeakExecutor(
      tts: zunda,
      focus: SessionAudioFocus(),
      chime: const ToneChime(),
    );
    // 開発者モードのフェイク GPS。使わない間は本物の GPS・センサーをそのまま流す
    final fakeGps = FakeGpsController(
      realLocation: GeolocatorLocationSource(),
      realGaze: const DeviceOrientationGaze(),
    );
    return AppServices(
      speaker: speaker,
      fakeGps: fakeGps,
      useFcm: true,
      tileCache: TileCache(
        () async =>
            Directory('${(await getApplicationSupportDirectory()).path}/tiles'),
      ),
      heardStore: HeardStore(
        () async => File(
          '${(await getApplicationSupportDirectory()).path}/heard_alerts.json',
        ),
      ),
      camera: camera,
      faceFinder: MlKitFaceFinder(),
      voiceCommands: SpeechVoiceCommandSource(
        currentSpeech: () => speaker.subtitle.value,
        beeps: const BeepMuter(),
      ),
      ticker: SensorTicker(
        locationSource: fakeGps.location,
        gazeSource: fakeGps.gaze,
        activitySource: RecognitionActivitySource(),
        audioStateSource: const PlatformAudioStateSource(),
        latestFrame: camera.latestFrame,
        ttsSpeaking: () => speaker.speaking,
      ),
      settingsStore: store ?? FileSettingsStore(),
      voices: voices,
      policy: const DemoSessionPolicy(),
      mode: AppMode.current,
    );
  }

  final CameraSource camera;
  final SensorTicker ticker;
  final SettingsStore settingsStore;
  final VoiceCatalog voices;
  final SessionPolicy policy;
  final AppMode mode;
  final ValueNotifier<AppSettings> settings;

  /// グラス視点の画面に重ねる判断まわりの表示（engine の Command から更新する）。
  final ValueNotifier<GlassOverlay> overlay = ValueNotifier(GlassOverlay.empty);
  late final SessionController session;

  /// 端末に保存した歩行ログの一覧と削除（設定画面から使う）。
  late final WalkLogStore walkLogs = WalkLogStore(
    defaultWalkDirectory,
    inUse: () => session.recordingFileName,
  );

  final SpeakExecutor speaker;

  /// 外から届く情報をまとめる所（[InfoHub]）と、警報の入口。
  late final InfoHub info;
  final AlertSource alerts = AlertSource(
    now: () => DateTime.now().toUtc().millisecondsSinceEpoch,
  );

  /// 画面に出している警報（無ければ null）。読み上げと同じ文を、聞き逃しても読めるよう残す。
  final ValueNotifier<InfoItem?> activeAlert = ValueNotifier(null);
  Timer? _alertTimer;

  /// 警報を画面に出しておく時間。過ぎたら自動で消す（新しい警報が来たら入れ替える）。
  static const alertShownFor = Duration(minutes: 30);

  void _showAlert(InfoItem item) {
    final cur = activeAlert.value;
    // 出している警報よりレベルが低いものでは上書きしない（読み上げはする）
    if (cur != null && (cur.level ?? 0) > (item.level ?? 0)) return;
    activeAlert.value = item;
    _alertTimer?.cancel();
    _alertTimer = Timer(alertShownFor, dismissAlert);
  }

  /// 警報の一覧を読めたとき：解除・引き下げで一覧から消えた警報を、画面の帯と預かりから外す。
  void _onAlertListCurrent(
    Set<String> currentIds,
    int updatedAtMs, {
    required bool mock,
  }) {
    bool lifted(InfoItem item) => alertLifted(
      item,
      currentIds: currentIds,
      updatedAtMs: updatedAtMs,
      mockList: mock,
    );
    final cur = activeAlert.value;
    if (cur != null && lifted(cur)) dismissAlert();
    _alertSink.dropWhere(lifted);
  }

  /// 警報の表示を閉じる。
  void dismissAlert() {
    _alertTimer?.cancel();
    _alertTimer = null;
    activeAlert.value = null;
  }

  /// Cloud Run の API。URL とトークンは --dart-define で渡す（コードに書かない）。
  final ApiClient api;

  /// サーバーとのつながりの最新の確認結果（まだ確かめていなければ null）。
  final ValueNotifier<ServerStatus?> serverStatus = ValueNotifier(null);
  bool _checkingServer = false;

  /// サーバーにつながるか確かめる（起動時と、設定画面のボタン）。重ねて呼ばない。
  Future<ServerStatus?> checkServer() async {
    if (_checkingServer) return serverStatus.value;
    _checkingServer = true;
    try {
      return serverStatus.value = await api.check();
    } finally {
      _checkingServer = false;
    }
  }

  /// A の地図タイルを取りに行く部品と、端末に残す所（テストでは残さない）。
  late final TileFetcher tiles;
  final TileCache? tileCache;

  /// 計測中だけ動く判断エンジンの係（計測していないときは null）。
  EngineRunner? get runner => _runner;
  EngineRunner? _runner;
  StreamSubscription<SensorSnapshot>? _engineSub;

  /// 判断の理由コードの説明（schema/reason_codes.json の写し）。
  Map<String, String> reasonText = const {};

  void _startEngine() {
    _demoAlertArmed = false;
    _demoAlertTimer?.cancel();
    cancelDemoTaps();
    final r = _runner = EngineRunner(
      speaker: speaker,
      tiles: tiles,
      record: session.recordRow,
      searcher: searcher,
      searchEnabled: () => settings.value.visualSearchEnabled,
      // 開発者モードの「通ったランドマークをもう一度話す」は計測開始のときの値を使う
      config: eng.EngineConfig(
        retellOnRevisit: settings.value.retellingLandmarks,
      ),
    );
    _engineSub = ticker.snapshots.listen((s) {
      _lastGazeAz = s.gaze.azDeg;
      r.onSnapshot(s);
    });
    void update() => _updateOverlayFromEngine(r);
    r.view.addListener(update);
    r.lastDecision.addListener(update);
    r.searchProgress.addListener(() => _showSearch(r.searchProgress.value));
    _syncVoice();
    // 計測前に届いていた警報は、ここで engine に渡す（話すかは engine が決める）
    _alertSink.releaseHeld(DateTime.now().toUtc().millisecondsSinceEpoch);
  }

  late final _AlertSink _alertSink;

  // ---- B：検索のきっかけ（定期は engine、ボタンと声はここから engine へ） ----

  /// 送る前に顔を見つける係（ML Kit）。テストでは null（撮らない）。
  final FaceFinder? faceFinder;

  /// 「検索して」の聞き取り。テストでは null。
  final VoiceCommandSource? voiceCommands;

  /// B の撮影と送信の係（[faceFinder] が無ければ null）。
  late final VisualSearcher? searcher;
  StreamSubscription<void>? _voiceSub;

  /// 検索ボタン・「検索して」の声。計測中で画像検索がオンのときだけ engine に頼む。
  /// 撮るかどうか（読み上げ中・横断歩道の手前などで見送るか）は engine が決める。
  bool requestSearch({bool byVoice = false}) {
    final r = _runner;
    if (r == null || !settings.value.visualSearchEnabled || _background) {
      return false;
    }
    // 短い間の重ね押し（ダブルタップ）や、ボタンと声の重なりは1回にまとめる
    final now = _nowMs();
    final last = _lastSearchRequestMs;
    if (last != null && now - last < searchRequestCooldown.inMilliseconds) {
      return true; // 受け付け済みとして扱う（画面には何も足さない）
    }
    _lastSearchRequestMs = now;
    r.requestSearch(byVoice: byVoice);
    return true;
  }

  /// 頼んだ検索を、この間は重ねて受け付けない。
  static const searchRequestCooldown = Duration(seconds: 3);
  int? _lastSearchRequestMs;

  /// 重ね押しの判定に使う時計（テストで差し替える）。
  int Function() _nowMs = () => DateTime.now().millisecondsSinceEpoch;
  @visibleForTesting
  set nowMsForTest(int Function() f) => _nowMs = f;

  /// 画面の札に出す B の検索の進み具合（出していないときは null）。
  /// 終わった札（答えが届いた・失敗・見送り）は数秒で消す。
  final ValueNotifier<SearchProgress?> searchIndicator = ValueNotifier(null);
  Timer? _searchIndicatorTimer;

  void _showSearch(SearchProgress? p) {
    _searchIndicatorTimer?.cancel();
    searchIndicator.value = p;
    // 「聞き取りました」も、続きの知らせ（撮影・見送り）が来なければ数秒で消す
    if (p == null || (p.active && p.phase != SearchPhase.heard)) return;
    _searchIndicatorTimer = Timer(const Duration(seconds: 4), () {
      if (identical(searchIndicator.value, p)) searchIndicator.value = null;
    });
  }

  /// カメラで調べない区域に入った・出たときのポップアップ（出していないときは null）。
  /// 音声の知らせは engine が Speak で出す。ポップアップは状態が変わった瞬間に出し、数秒で消す。
  final ValueNotifier<ZoneNotice?> zoneNotice = ValueNotifier(null);
  Timer? _zoneNoticeTimer;

  void _showZoneNotice(ZoneNotice n) {
    _zoneNoticeTimer?.cancel();
    zoneNotice.value = n;
    _zoneNoticeTimer = Timer(const Duration(seconds: 6), () {
      if (identical(zoneNotice.value, n)) zoneNotice.value = null;
    });
  }

  /// 札の文言。
  String searchLabel(SearchProgress p) {
    final who = p.requested ? '検索' : '自動の検索';
    return switch (p.phase) {
      SearchPhase.heard => '「検索して」を聞き取りました',
      SearchPhase.capturing => '$who：撮影中',
      SearchPhase.blurring => '$who：顔をぼかしています',
      SearchPhase.sending => '$who：送信中',
      SearchPhase.answered => '$who：答えが届きました',
      SearchPhase.failed => switch (p.detail) {
        'network' when !api.hasUrl => '$who：送信先が未設定のため、送る手前で止めました',
        'network' => '$who：送れませんでした（通信）',
        'timeout' => '$who：時間切れ',
        'face_blur_failed' => '$who：顔をぼかせなかったので送っていません',
        'no_frame' => '$who：撮れませんでした',
        _ => '$who：サーバーのエラー',
      },
      SearchPhase.skipped =>
        '検索できません：${reasonText[p.detail] ?? p.detail ?? ''}',
    };
  }

  /// アプリが裏に回っているか（画面オフ・ポケットの中）。
  bool get inBackground => _background;
  bool _background = false;

  /// 裏に回った・前に戻った（HomeShell のライフサイクルから呼ぶ）。
  ///
  /// 裏にいる間は、GPS で分かること（A のランドマーク案内・警報）だけを届ける。
  /// - 視線の代わりに進行方向を使う（ポケットの中では端末の向きが当てにならない）
  /// - カメラは止まり、画質が無いので engine は B を撮らない。「検索して」の聞き取りも止める
  /// 位置は前面サービスで取り続け、判断と読み上げはそのまま動く。
  void setBackground(bool on) {
    if (on == _background) return;
    _background = on;
    ticker.background = on;
    _syncVoice();
    if (on) _showSearch(null);
  }

  /// engine の「検索します」の返事（engine_base の speak:search_ack の文）。
  static const searchAckText = '検索します。';

  /// 返事を話し終えてから、聞き取った合図を使わない間。
  static const ackEchoGuard = Duration(milliseconds: 2500);
  int? _ackEndedMs;
  String? _lastSubtitle;

  void _trackAck() {
    final now = speaker.subtitle.value;
    if (_lastSubtitle == searchAckText && now != searchAckText) {
      _ackEndedMs = _nowMs();
    }
    _lastSubtitle = now;
  }

  bool _inAckEcho() {
    if (speaker.subtitle.value == searchAckText) return true;
    final end = _ackEndedMs;
    return end != null && _nowMs() - end < ackEchoGuard.inMilliseconds;
  }

  /// 計測中かつ画像検索オンで、前に出ているときだけマイクで聞く。
  void _syncVoice() {
    final v = voiceCommands;
    if (v == null) return;
    final want =
        _runner != null && settings.value.visualSearchEnabled && !_background;
    if (want && _voiceSub == null) {
      _voiceSub = v.requests.listen((_) {
        // アプリ自身の「検索します」を「検索して」と聞き違えると、検索がくり返し起きる。
        // 返事の最中と、話し終えてすぐの間に聞き取った合図は使わない
        if (_inAckEcho()) return;
        final last = _lastSearchRequestMs;
        final cooling =
            last != null &&
            _nowMs() - last < searchRequestCooldown.inMilliseconds;
        if (!cooling) {
          _showSearch(const SearchProgress(SearchPhase.heard, requested: true));
        }
        requestSearch(byVoice: true);
      });
      unawaited(v.start());
    } else if (!want && _voiceSub != null) {
      unawaited(_voiceSub!.cancel());
      _voiceSub = null;
      unawaited(v.stop());
    }
  }

  Future<void> _stopEngine() async {
    _demoAlertTimer?.cancel();
    cancelDemoTaps();
    await _engineSub?.cancel();
    _engineSub = null;
    final r = _runner;
    _runner = null;
    _syncVoice();
    await r?.dispose();
    // 記録を終えたら、話している途中・順番待ちの案内を残さない（終了画面で話し続けないため）。
    // 計測していない間の警報は _AlertSink が預かり、次の計測で渡す
    speaker.stopAll();
    // 途中だった検索の札は、次の計測に持ち越さない
    _searchIndicatorTimer?.cancel();
    _searchIndicatorTimer = null;
    searchIndicator.value = null;
    _zoneNoticeTimer?.cancel();
    _zoneNoticeTimer = null;
    zoneNotice.value = null;
    overlay.value = GlassOverlay(subtitle: overlay.value.subtitle);
  }

  double _lastGazeAz = 0;

  /// engine の「いまの状態」を、グラス視点の画面の表示に直す。
  // ---- 開発者モード：ラバーズ像に近づいたらデモの警報（割り込みの確認用。11/7） ----

  /// デモの警報を出すランドマーク（ラバーズ像）。
  static const demoAlertLandmarkId = 'lm_0006';

  /// 近づいてから警報を流すまでの間（A の話の途中で割り込むのを見るため）。
  static const demoAlertDelay = Duration(seconds: 3);

  /// この計測でデモの警報を出したか（出す予定を立てたか）。計測開始で戻す。
  bool _demoAlertArmed = false;
  Timer? _demoAlertTimer;

  /// ラバーズ像の話が始まった、または範囲に入ったら、[demoAlertDelay] 後にデモの警報を流す。
  /// 本物の警報と同じ入口（[AlertSource.receive]）から流すので、表示・記録・割り込みの判断も同じ。
  void _maybeDemoAlert(EngineRunner r) {
    if (_demoAlertArmed || !settings.value.demoAlertingNearLovers) return;
    final d = r.lastDecision.value;
    final speaking =
        d != null && d.kind == 'speak' && d.targetId == demoAlertLandmarkId;
    final near = r.engine.nearLandmark?.id == demoAlertLandmarkId;
    if (!speaking && !near) return;
    _demoAlertArmed = true;
    _demoAlertTimer = Timer(demoAlertDelay, () {
      if (_runner == null) return;
      _sendDemoAlert('lovers');
    });
  }

  /// デモの警報（レベル4）を、本物の警報と同じ入口（[AlertSource.receive]）から流す。
  /// ID は [eng.demoAlertIdPrefix] で始める（判断画面がデモと分かるように）。文の中でも「実際の警報ではありません」と言う。
  void _sendDemoAlert(String tag) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    alerts.receive({
      'schema_version': '0.3',
      'type': 'alert',
      'alert_id': '${eng.demoAlertIdPrefix}${tag}_$now',
      'level': '4',
      'kind': '大雨危険警報（デモ）',
      'area_code': '1620100',
      'area_name': '富山市',
      'text':
          'これは確認用のデモの警報です。実際の警報ではありません。'
          '警戒レベル4の警報は、話している途中でも割り込んでお知らせします。',
    });
  }

  // ---- 開発者モード：デモ撮影のワンタップ（11/7） ----
  // 動画では本物の警報も、横断歩道などで案内が止まる場面もまず起きないので、ワンタップで流す。
  // 押してから [demoTapDelay] 後に流す（操作している画面を動画から切れるように）。
  // 本物と同じ入口（警報は AlertSource、案内は engine の DemoLandmarkRequested）を通るので、
  // 割り込み・順番待ち・記録は本物と同じ。判断画面は「デモ」と添えて出す。

  static const demoTapDelay = Duration(seconds: 15);

  /// 「案内の途中に警報」で、案内のあと警報を流すまでの間（案内が話し始めてから割り込むように）。
  static const demoInterruptGap = Duration(seconds: 5);

  /// 予約中のデモと、流す時刻。画面の表示用。
  final ValueNotifier<Map<DemoTap, DateTime>> demoTaps = ValueNotifier(const {});
  final Map<DemoTap, Timer> _demoTapTimers = {};

  /// デモを予約する。計測中でなければ false（何もしない）。同じ種類をもう一度押したら予約し直す。
  bool scheduleDemo(DemoTap kind) {
    if (_runner == null) return false;
    switch (kind) {
      case DemoTap.alert:
        _scheduleDemo(DemoTap.alert, demoTapDelay, () => _sendDemoAlert('tap'));
      case DemoTap.landmark:
        _scheduleDemo(
          DemoTap.landmark,
          demoTapDelay,
          () => _runner?.requestDemoLandmark(),
        );
      case DemoTap.landmarkThenAlert:
        _scheduleDemo(DemoTap.landmarkThenAlert, demoTapDelay, () {
          _runner?.requestDemoLandmark();
        });
        _scheduleDemo(
          DemoTap.alert,
          demoTapDelay + demoInterruptGap,
          () => _sendDemoAlert('tap'),
        );
    }
    return true;
  }

  void _scheduleDemo(DemoTap kind, Duration delay, void Function() fire) {
    _demoTapTimers.remove(kind)?.cancel();
    _demoTapTimers[kind] = Timer(delay, () {
      _demoTapTimers.remove(kind);
      demoTaps.value = {...demoTaps.value}..remove(kind);
      if (_runner == null) return;
      fire();
    });
    demoTaps.value = {...demoTaps.value, kind: DateTime.now().add(delay)};
  }

  /// 予約したデモをすべて取り消す（計測の開始・終了でも取り消す）。
  void cancelDemoTaps() {
    for (final t in _demoTapTimers.values) {
      t.cancel();
    }
    _demoTapTimers.clear();
    if (demoTaps.value.isNotEmpty) demoTaps.value = const {};
  }

  void _updateOverlayFromEngine(EngineRunner r) {
    _maybeDemoAlert(r);
    final v = r.view.value;
    final d = r.lastDecision.value;
    final wasZone = overlay.value.noCameraZoneName;
    final nowZone = v?.noCameraZone?.name;
    if (wasZone != nowZone) {
      if (nowZone != null) {
        _showZoneNotice(ZoneNotice(zoneName: nowZone, entered: true));
      } else if (wasZone != null) {
        _showZoneNotice(ZoneNotice(zoneName: wasZone, entered: false));
      }
    }
    final skip = v?.searchSkipReason;
    overlay.value = GlassOverlay(
      candidates: [
        for (final n in v?.nearby ?? const <eng.NearbyLandmark>[])
          CandidateMark(
            name: n.told ? '${n.name}（話した）' : n.name,
            bearingDeg: (_lastGazeAz + n.relativeBearingDeg) % 360,
            distanceM: n.distanceM,
          ),
      ],
      decision: d?.reason,
      reason: d == null ? null : (reasonText[d.reason] ?? d.reason),
      subtitle: overlay.value.subtitle,
      areaName: v?.currentArea?.name,
      nextSearchIn: v?.nextSearchInMs == null
          ? null
          : Duration(milliseconds: v!.nextSearchInMs!),
      lastSearch: skip == null ? null : (reasonText[skip] ?? skip),
      noCameraZoneName: v?.noCameraZone?.name,
    );
  }

  /// 聞いた警報の ID を起動し直しても覚えておく所（テストでは null）。
  final HeardStore? heardStore;

  /// FCM で警報を受けるか（テストでは使わない）。
  final bool useFcm;
  FcmAlerts? _fcm;

  /// 開発者モードのフェイク GPS（テストなどで組み込まないときは null）。
  final FakeGpsController? fakeGps;
  StreamSubscription<String>? _finishedSub;
  int _previewCount = 0;

  /// 試し聞きの発話 ID の頭（歩行ログに残さない印）。
  static const previewPrefix = 'preview_';

  Future<void> start() async {
    settings.value = await settingsStore.load();
    reasonText = await loadReasonText();
    await speaker.useVoice(settings.value.voice);
    ticker.start();
    await info.start();
    if (useFcm) {
      // 起動を待たせないよう、裏でつなぐ。つながらなくてもアプリは動く
      final fcm = _fcm = FcmAlerts(alerts);
      unawaited(fcm.connect());
      unawaited(checkServer());
      unawaited(refreshAlerts());
      // 前面に戻ったら、閉じている間に預けた警報と一覧を確かめる
      _lifecycle = AppLifecycleListener(
        onResume: () {
          unawaited(fcm.drainPending());
          unawaited(refreshAlerts());
        },
      );
    }
  }

  /// 声の試し聞き。本番と同じ道筋（音の出口の確保・合図音・字幕）で話す。
  /// 押した人が今聞きたいので割り込んで話し、連打しても前の試し聞きは捨てて最後の1回だけ話す。
  /// 警報（優先度1）だけは止めない。
  Future<void> previewVoice(VoicePreset preset) async {
    final id = '$previewPrefix${++_previewCount}';
    await speaker.useVoice(preset);
    // 声の切り替えを待つ間にもう一度押されていたら、古い方は話さない
    if (id != '$previewPrefix$_previewCount') return;
    // 話し終えたら（止められても）、選んでいる声に戻す（試し聞きの声で案内しないように）。
    // あとの試し聞きが続いていれば、戻すのはその試し聞きに任せる
    unawaited(
      speaker.finished.firstWhere((f) => f == id).then((_) async {
        if (id == '$previewPrefix$_previewCount') {
          await speaker.useVoice(settings.value.voice);
        }
      }, onError: (Object _) {}),
    );
    speaker.execute(
      SpeakRequest(
        utteranceId: id,
        text: '${preset.label}で案内します。右手に見えるのは、富山駅です。',
        priority: 2,
        interrupt: true,
        group: previewGroup,
      ),
    );
  }

  /// 開発者モードで流す確認用の発話 ID の頭（歩行ログに残さない印）。
  static const devPrefix = 'dev_';
  int _devCount = 0;

  /// 開発者モード：優先度5のランドマーク案内のつもりの長めの文を流す（割り込みと順番の確認用）。
  void speakDevLandmark() => speaker.execute(
    SpeakRequest(
      utteranceId: '${devPrefix}landmark_${++_devCount}',
      text:
          '（確認用の案内です）右手に見えるのは富山駅です。'
          '北陸新幹線と路面電車が乗り入れ、駅の下を路面電車が南北に通り抜けます。'
          '南口を出ると、正面に路面電車の電停があります。',
      priority: InfoKind.landmark.priority,
    ),
  );

  /// 試し聞きの group（新しい試し聞きが来たら古い方を捨てる）。
  static const previewGroup = 'preview';

  /// 開発者モードで「送った画像を保存」がオンのとき、記録中の歩行ログの隣に保存する（検証用）。
  /// 記録していないとき・オフのときは何もしない。保存に失敗しても検索は続ける。
  void _saveSentImage(String searchId, Uint8List jpeg) {
    if (!settings.value.savingSentImages) return;
    final log = session.recordingFile;
    if (log == null) return;
    unawaited(() async {
      try {
        final dir = sentImagesDir(log);
        await dir.create(recursive: true);
        await File('${dir.path}/$searchId.jpg').writeAsBytes(jpeg, flush: true);
      } catch (_) {}
    }());
  }

  Future<void> updateSettings(AppSettings next) async {
    settings.value = next;
    await settingsStore.save(next);
  }

  Future<void> dispose() async {
    cancelDemoTaps();
    await _finishedSub?.cancel();
    await _stopEngine();
    settings.removeListener(_syncVoice);
    await searcher?.close();
    await tiles.dispose();
    _lifecycle?.dispose();
    _alertListTimer?.cancel();
    session.removeListener(_onSessionChanged);
    alertList.close();
    await info.stop();
    _fcm?.dispose();
    api.close();
    serverStatus.dispose();
    await alerts.close();
    _alertTimer?.cancel();
    activeAlert.dispose();
    fakeGps?.dispose();
    await speaker.dispose();
    session.dispose();
    await ticker.dispose();
    await camera.stop();
    settings.dispose();
    overlay.dispose();
    _searchIndicatorTimer?.cancel();
    searchIndicator.dispose();
    _zoneNoticeTimer?.cancel();
    zoneNotice.dispose();
  }
}

/// カメラで調べない区域に入った（entered）・出たのポップアップの中身。
class ZoneNotice {
  const ZoneNotice({required this.zoneName, required this.entered});
  final String zoneName;
  final bool entered;
}

/// 警報などの行き先：計測中は engine（`AlertReceived`）。警報以外の種類は直接読み上げる。
/// **計測していないときは読み上げない**（音を出すのは試し聞きだけ）。画面の帯には出し、
/// 受け取った分は預かって、計測を始めたときに渡す（期限の切れたものは捨てる）。
class _AlertSink implements InfoSink {
  _AlertSink(this.services);

  final AppServices services;
  late final DirectSpeakSink _direct = DirectSpeakSink(services.speaker);
  final List<InfoItem> _held = [];

  @override
  void deliver(InfoItem item) {
    final r = services.runner;
    if (r == null) {
      _held.add(item);
    } else if (item.kind == InfoKind.alert) {
      r.onAlert(item);
    } else {
      _direct.deliver(item);
    }
  }

  /// 計測を始めたとき：預かっていた分を、来た順に渡す（期限の切れたもの・古い警報は捨てる）。
  void releaseHeld(int nowMs) {
    final items = List.of(_held);
    _held.clear();
    for (final item in items) {
      if (heldItemStale(item, nowMs)) continue;
      deliver(item);
    }
  }

  /// 預かっている分から外す（解除・引き下げで警報の一覧から消えた警報）。
  void dropWhere(bool Function(InfoItem item) test) => _held.removeWhere(test);
}

/// 理由コードの説明（assets/reason_codes.json）を読む。読めなければ空（コードのまま出す）。
Future<Map<String, String>> loadReasonText() async {
  try {
    final m = jsonDecode(
      await rootBundle.loadString('assets/reason_codes.json'),
    );
    final codes = (m as Map)['codes'] as Map;
    return {
      for (final e in codes.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  } catch (_) {
    return const {};
  }
}

/// デモ撮影のワンタップの種類（11/7）。
enum DemoTap {
  /// デモの警報（レベル4。話している途中なら割り込む）
  alert,

  /// いちばん近いランドマークの案内
  landmark,

  /// ランドマークの案内を流し、その5秒後にデモの警報で割り込む
  landmarkThenAlert,
}

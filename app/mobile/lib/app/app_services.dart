import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import '../core/sensor_ticker.dart';
import '../dev/fake_gps.dart';
import '../executors/speak_executor.dart';
import '../executors/voice_catalog.dart';
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
import '../ui/glass_overlay.dart';
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
    // 読み上げの終わりを歩行ログへ（試し聞きは engine の発話ではないので残さない）
    _finishedSub = this.speaker.finished.listen((id) {
      if (!id.startsWith(previewPrefix) && !id.startsWith(devPrefix)) {
        session.recordTtsFinished(id);
      }
    });
    // 声の設定を読み上げに反映する
    settings.addListener(() => this.speaker.useVoice(settings.value.voice));
    // 外から届く情報（警報・気象・交通・イベント）。今は警報だけ中身があり、ほかは骨組み
    info = InfoHub(
      heard: heardStore,
      sink: DirectSpeakSink(this.speaker),
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
    );
    tiles = TileFetcher(api: this.api, cache: tileCache);
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
    final speaker = SpeakExecutor(
      tts: FlutterTtsEngine(voices, tts),
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
  StreamSubscription<Object?>? _tileSub;

  /// 画面に出す A の候補の範囲と件数。
  static const candidateRadiusM = 500.0;
  static const maxCandidates = 5;

  /// 位置が届くたびに、要るタイルを頼み、画面の A の候補を更新する。
  /// TODO(engine)：engine をつないだら、タイルは engine の `FetchTiles` で頼み、
  /// 届いたタイルを `TilesLoaded` で engine へ渡す。候補も engine の判断から出す。
  void _onSnapshot(SensorSnapshot s) {
    final loc = s.location;
    tiles.request(
      tilesAhead(
        lat: loc.lat,
        lon: loc.lon,
        speedMps: loc.speedMps,
        courseDeg: loc.courseDeg,
      ),
    );
    final near = <CandidateMark>[];
    for (final t in tiles.tiles) {
      for (final lm in t.landmarks) {
        final d = haversineM(loc.lat, loc.lon, lm.lat, lm.lon);
        if (d > candidateRadiusM || near.any((c) => c.name == lm.name)) {
          continue;
        }
        near.add(
          CandidateMark(
            name: lm.name,
            bearingDeg: bearingBetween(loc.lat, loc.lon, lm.lat, lm.lon),
            distanceM: d,
          ),
        );
      }
    }
    near.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    final list = near.take(maxCandidates).toList();
    final cur = overlay.value.candidates;
    final same =
        cur.length == list.length &&
        [
          for (var i = 0; i < list.length; i++)
            cur[i].name == list[i].name &&
                (cur[i].distanceM - list[i].distanceM).abs() < 10,
        ].every((b) => b);
    if (!same) overlay.value = overlay.value.withCandidates(list);
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
    await speaker.useVoice(settings.value.voice);
    ticker.start();
    _tileSub = ticker.snapshots.listen(_onSnapshot);
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

  Future<void> updateSettings(AppSettings next) async {
    settings.value = next;
    await settingsStore.save(next);
  }

  Future<void> dispose() async {
    await _finishedSub?.cancel();
    await _tileSub?.cancel();
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
  }
}

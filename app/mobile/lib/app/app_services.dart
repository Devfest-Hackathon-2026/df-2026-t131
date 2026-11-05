import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/sensor_ticker.dart';
import '../dev/fake_gps.dart';
import '../executors/speak_executor.dart';
import '../executors/voice_catalog.dart';
import '../info/alert_message.dart';
import '../info/fcm_alerts.dart';
import '../info/info_hub.dart';
import '../info/info_kind.dart';
import '../info/sources.dart';
import '../net/api_client.dart';
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
      if (!id.startsWith(previewPrefix)) session.recordTtsFinished(id);
    });
    // 声の設定を読み上げに反映する
    settings.addListener(() => this.speaker.useVoice(settings.value.voice));
    // 外から届く情報（警報・気象・交通・イベント）。今は警報だけ中身があり、ほかは骨組み
    info = InfoHub(
      sink: DirectSpeakSink(this.speaker),
      now: () => DateTime.now().toUtc().millisecondsSinceEpoch,
      onAccepted: (item) {
        if (item.kind == InfoKind.alert) {
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
    await info.start();
    if (useFcm) {
      // 起動を待たせないよう、裏でつなぐ。つながらなくてもアプリは動く
      final fcm = _fcm = FcmAlerts(alerts);
      unawaited(fcm.connect());
      unawaited(checkServer());
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

  /// 試し聞きの group（新しい試し聞きが来たら古い方を捨てる）。
  static const previewGroup = 'preview';

  Future<void> updateSettings(AppSettings next) async {
    settings.value = next;
    await settingsStore.save(next);
  }

  Future<void> dispose() async {
    await _finishedSub?.cancel();
    await info.stop();
    _fcm?.dispose();
    api.close();
    serverStatus.dispose();
    await alerts.close();
    fakeGps?.dispose();
    await speaker.dispose();
    session.dispose();
    await ticker.dispose();
    await camera.stop();
    settings.dispose();
    overlay.dispose();
  }
}

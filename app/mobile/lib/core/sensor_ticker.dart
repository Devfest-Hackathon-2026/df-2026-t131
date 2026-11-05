import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../sources/activity_source.dart';
import '../sources/audio_state_source.dart';
import '../sources/camera_source.dart';
import '../sources/gaze_source.dart';
import '../sources/image_quality.dart';
import '../sources/location_source.dart';

/// 1秒分のセンサーの値をまとめたもの。
/// TODO: engine の雛形が届いたら engine の SensorFrame（イベント）に変換して EngineRunner に渡す。
class SensorSnapshot {
  const SensorSnapshot({
    required this.tMs,
    required this.location,
    required this.gaze,
    required this.activity,
    required this.audio,
    required this.ttsSpeaking,
    required this.imageQuality,
  });

  final int tMs;
  final LocationFix location;

  /// 歩行ログの形で必須なので、視線が取れるまではまとめを出さない。
  final GazeReading gaze;
  final ActivityKind activity;
  final AudioState audio;
  final bool ttsSpeaking;

  /// カメラが動いていなければ null。
  final ImageQuality? imageQuality;
}

typedef QualityMeasurer = Future<ImageQuality> Function(CameraFrame frame);

Future<ImageQuality> _measureFrame(CameraFrame f) =>
    measureImageQualityInBackground(
      f.luma,
      f.width,
      f.height,
      rowStride: f.yRowStride,
    );

int _nowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

/// 各 Source の最新値を持ち、1秒ごとに [SensorSnapshot] を1つ作る。
/// Source 自身はイベント列に直接入れない（1秒1行にするため）。
/// 最初の測位と、最初の視線が届くまでは何も出さない。
class SensorTicker {
  SensorTicker({
    required this.locationSource,
    required this.gazeSource,
    required this.activitySource,
    required this.audioStateSource,
    this.latestFrame,
    this.ttsSpeaking,
    QualityMeasurer? measureQuality,
    int Function()? clock,
    this.interval = AppConfig.sensorTick,
  }) : _measure = measureQuality ?? _measureFrame,
       _clock = clock ?? _nowMs;

  final LocationSource locationSource;
  final GazeSource gazeSource;
  final ActivitySource activitySource;
  final AudioStateSource audioStateSource;
  final CameraFrame? Function()? latestFrame;
  final bool Function()? ttsSpeaking;
  final QualityMeasurer _measure;
  final int Function() _clock;
  final Duration interval;

  final _out = StreamController<SensorSnapshot>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _timer;
  bool _busy = false;
  int? _lastDeclinationMs;

  LocationFix? _location;
  GazeReading? _gaze;

  /// 画面用：視線を届いたとおり（約10Hz）に流す。方位テープをなめらかに動かすため。
  final ValueNotifier<GazeReading?> gazeLive = ValueNotifier(null);
  ActivityKind _activity = ActivityKind.unknown;
  AudioState _audio = AudioState.initial;

  /// 1秒ごとのまとめ。
  Stream<SensorSnapshot> get snapshots => _out.stream;

  /// 画面用：今持っている最新の値。
  LocationFix? get location => _location;
  GazeReading? get gaze => _gaze;
  ActivityKind get activity => _activity;
  AudioState get audio => _audio;

  void start() {
    _subs
      ..add(locationSource.fixes.listen(onLocation, onError: _ignore))
      ..add(
        gazeSource.readings.listen((g) {
          _gaze = g;
          gazeLive.value = g;
        }, onError: _ignore),
      )
      ..add(
        activitySource.changes.listen((a) => _activity = a, onError: _ignore),
      )
      ..add(
        audioStateSource.states.listen((s) => _audio = s, onError: _ignore),
      );
    _timer = Timer.periodic(interval, (_) => tick());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _out.close();
    gazeLive.dispose();
  }

  /// 位置を受けたとき。偏角は最初と、その後10分に1回だけ更新する。
  void onLocation(LocationFix fix) {
    _location = fix;
    final now = _clock();
    final last = _lastDeclinationMs;
    if (last == null ||
        now - last >= AppConfig.declinationRefresh.inMilliseconds) {
      _lastDeclinationMs = now;
      gazeSource.updateLocation(fix.lat, fix.lon, fix.altM).catchError((_) {});
    }
  }

  /// 1回分のまとめを作って流す。前の計算が終わっていなければ飛ばす。
  Future<void> tick() async {
    if (_busy) return;
    final loc = _location;
    final gaze = _gaze;
    if (loc == null || gaze == null) return;
    _busy = true;
    try {
      final frame = latestFrame?.call();
      ImageQuality? quality;
      if (frame != null) {
        try {
          quality = await _measure(frame);
        } catch (_) {
          quality = null;
        }
      }
      if (_out.isClosed) return;
      _out.add(
        SensorSnapshot(
          tMs: _clock(),
          location: _location ?? loc,
          gaze: _gaze ?? gaze,
          activity: _activity,
          audio: _audio,
          ttsSpeaking: ttsSpeaking?.call() ?? false,
          imageQuality: quality,
        ),
      );
    } finally {
      _busy = false;
    }
  }

  static void _ignore(Object _) {}
}

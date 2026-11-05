import 'dart:async';

import 'package:flutter/foundation.dart';

import '../sources/gaze_source.dart';
import '../sources/location_source.dart';
import 'fake_track.dart';

/// 本物とフェイクを切り替えられる位置の入力。SensorTicker からは1つの LocationSource に見える。
/// フェイクの間は本物の GPS を止める（電池のため）。
class SwitchableLocationSource implements LocationSource {
  SwitchableLocationSource(this.real);

  final LocationSource real;
  late final _out = StreamController<LocationFix>.broadcast(
    sync: true,
    onListen: _resubscribe,
    onCancel: _cancel,
  );
  StreamSubscription<LocationFix>? _sub;
  bool _fake = false;

  @override
  Stream<LocationFix> get fixes => _out.stream;

  bool get fake => _fake;
  set fake(bool v) {
    if (_fake == v) return;
    _fake = v;
    _resubscribe();
  }

  void push(LocationFix f) {
    if (_fake && !_out.isClosed) _out.add(f);
  }

  void _resubscribe() {
    _cancel();
    if (_fake || !_out.hasListener) return;
    _sub = real.fixes.listen(_out.add, onError: _out.addError);
  }

  void _cancel() {
    _sub?.cancel();
    _sub = null;
  }
}

/// 本物とフェイクを切り替えられる視線の入力。フェイクの間は道の進行方向を向いている扱いにする。
class SwitchableGazeSource implements GazeSource {
  SwitchableGazeSource(this.real);

  final GazeSource real;
  late final _out = StreamController<GazeReading>.broadcast(
    sync: true,
    onListen: _resubscribe,
    onCancel: _cancel,
  );
  StreamSubscription<GazeReading>? _sub;
  bool _fake = false;

  @override
  Stream<GazeReading> get readings => _out.stream;

  bool get fake => _fake;
  set fake(bool v) {
    if (_fake == v) return;
    _fake = v;
    _resubscribe();
  }

  void push(GazeReading g) {
    if (_fake && !_out.isClosed) _out.add(g);
  }

  @override
  Future<void> updateLocation(double lat, double lon, double? altM) =>
      real.updateLocation(lat, lon, altM);

  void _resubscribe() {
    _cancel();
    if (_fake || !_out.hasListener) return;
    _sub = real.readings.listen(_out.add, onError: _out.addError);
  }

  void _cancel() {
    _sub?.cancel();
    _sub = null;
  }
}

/// 開発者モードのフェイク GPS。道のり（デモルートか保存した歩行ログ）を1秒ごとに流す。
/// A（位置による音声ガイド）を机の上で試すためのもの。カメラは本物のままなので B の確認には向かない。
class FakeGpsController extends ChangeNotifier {
  FakeGpsController({
    required LocationSource realLocation,
    required GazeSource realGaze,
    this.tick = const Duration(seconds: 1),
  }) : location = SwitchableLocationSource(realLocation),
       gaze = SwitchableGazeSource(realGaze);

  final SwitchableLocationSource location;
  final SwitchableGazeSource gaze;
  final Duration tick;

  /// 選べる倍速。
  static const speeds = [1, 2, 5, 10];

  Timer? _timer;
  bool _enabled = false;
  FakeTrack _track = demoRouteToyama;
  double _t = 0;
  bool _playing = false;
  int _speed = 1;
  bool _gazeFollowsRoute = true;

  bool get enabled => _enabled;
  FakeTrack get track => _track;
  double get t => _t;
  bool get playing => _playing;
  int get speed => _speed;
  bool get gazeFollowsRoute => _gazeFollowsRoute;
  bool get atEnd => _t >= _track.durationS;
  double get distanceM => _track.distanceAt(_t);

  /// フェイク GPS を使う／やめる。やめると本物の GPS とセンサーに戻る。
  void setEnabled(bool on) {
    if (_enabled == on) return;
    _enabled = on;
    location.fake = on;
    gaze.fake = on && _gazeFollowsRoute;
    _timer?.cancel();
    _timer = null;
    if (on) {
      _emit();
      _timer = Timer.periodic(tick, (_) => step());
    } else {
      _playing = false;
    }
    notifyListeners();
  }

  void setTrack(FakeTrack track) {
    _track = track;
    _t = 0;
    _playing = false;
    _emitIfEnabled();
    notifyListeners();
  }

  void setGazeFollowsRoute(bool v) {
    _gazeFollowsRoute = v;
    gaze.fake = _enabled && v;
    _emitIfEnabled();
    notifyListeners();
  }

  void togglePlay() {
    if (!_playing && atEnd) _t = 0; // 最後まで行っていたら最初から
    _playing = !_playing;
    _emitIfEnabled();
    notifyListeners();
  }

  void restart() {
    _t = 0;
    _emitIfEnabled();
    notifyListeners();
  }

  void seek(double t) {
    _t = t.clamp(0, _track.durationS);
    _emitIfEnabled();
    notifyListeners();
  }

  void setSpeed(int s) {
    _speed = s;
    notifyListeners();
  }

  /// 次の倍速へ（1 → 2 → 5 → 10 → 1）。
  void cycleSpeed() =>
      setSpeed(speeds[(speeds.indexOf(_speed) + 1) % speeds.length]);

  /// 1回分進めて位置を流す（タイマーから呼ぶ。テストでは直接呼ぶ）。
  void step() {
    if (!_enabled) return;
    if (_playing) {
      _t = (_t + _speed).clamp(0, _track.durationS);
      if (atEnd) _playing = false;
    }
    _emit();
    notifyListeners();
  }

  void _emitIfEnabled() {
    if (_enabled) _emit();
  }

  void _emit() {
    location.push(
      _track.fixAt(_t, moving: _playing, speedFactor: _speed.toDouble()),
    );
    gaze.push(GazeReading(azDeg: _track.headingAt(_t), pitchDeg: 0));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

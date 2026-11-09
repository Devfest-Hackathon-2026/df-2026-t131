import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/sensor_ticker.dart';
import '../logging/jsonl_writer.dart';
import '../logging/sensor_row.dart';
import '../sources/location_source.dart';
import 'app_settings.dart';

enum SessionPhase { idle, running, finished }

/// 1回の歩行の結果（終了画面に出す）。
class SessionSummary {
  const SessionSummary({
    required this.duration,
    required this.rows,
    required this.distanceM,
    required this.maxGapMs,
    required this.fileName,
    required this.settings,
    this.fakeLocation = false,
  });

  final Duration duration;
  final int rows;
  final double distanceM;

  /// sensor 行どうしの最大の間隔。3秒を超えたら記録が途切れている（30分テストの合格条件）。
  final int maxGapMs;
  final String fileName;
  final AppSettings settings;

  /// 開発者モードのフェイク GPS で記録したか。
  final bool fakeLocation;

  bool get hasGap => maxGapMs > 3000;
}

/// 2点間の距離（メートル）。
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

typedef WalkDirectory = Future<Directory> Function();

Future<Directory> defaultWalkDirectory() async {
  // /sdcard/Android/data/<pkg>/files/walks（権限なしで書け、adb pull で取り出せる）
  final base =
      await getExternalStorageDirectory() ??
      await getApplicationSupportDirectory();
  return Directory('${base.path}/walks');
}

/// 「計測開始」〜「終了」を管理する。センサーと engine は記録していないときも動かし、
/// 記録（歩行ログ）だけをこの間に行う。自宅など個人の場所を残さないため。
class SessionController extends ChangeNotifier {
  SessionController({
    required this.ticker,
    required this.settings,
    WalkDirectory? walkDirectory,
    DateTime Function()? now,
    bool Function()? fakeLocation,
  }) : _walkDirectory = walkDirectory ?? defaultWalkDirectory,
       _now = now ?? DateTime.now,
       _fakeLocation = fakeLocation ?? _never;

  static bool _never() => false;
  final bool Function() _fakeLocation;
  bool _fakeAtStart = false;

  final SensorTicker ticker;
  final AppSettings Function() settings;
  final WalkDirectory _walkDirectory;
  final DateTime Function() _now;

  SessionPhase _phase = SessionPhase.idle;
  JsonlWriter? _writer;
  StreamSubscription<SensorSnapshot>? _sub;
  DateTime? _startedAt;
  SensorSnapshot? _last;
  LocationFix? _anchor;
  double _distanceM = 0;

  /// 距離を足す最小の移動量（メートル）。
  static const double minStepM = 3;
  int _maxGapMs = 0;
  SessionSummary? _summary;
  AppSettings? _settingsAtStart;

  SessionPhase get phase => _phase;
  SessionSummary? get summary => _summary;
  DateTime? get startedAt => _startedAt;
  int get rows => _writer?.lines ?? 0;

  /// 記録中のファイル名（設定画面で消せないようにする）。記録していなければ null。
  String? get recordingFileName => _writer?.file.uri.pathSegments.last;

  /// 記録中の歩行ログのファイル。記録していなければ null。
  File? get recordingFile => _writer?.file;
  double get distanceM => _distanceM;
  Duration get elapsed =>
      _startedAt == null ? Duration.zero : _now().difference(_startedAt!);

  /// ファイルを開いている途中か（2回押しで記録を2つ始めないため）。
  bool _starting = false;

  Future<void> start() async {
    if (_phase == SessionPhase.running || _starting) return;
    _starting = true;
    try {
      await _open();
    } finally {
      _starting = false;
    }
  }

  Future<void> _open() async {
    final start = _now();
    final dir = await _walkDirectory();
    _writer = await JsonlWriter.open(
      File('${dir.path}/${walkFileName(start, fake: _fakeLocation())}'),
    );
    _startedAt = start;
    _settingsAtStart = settings();
    _fakeAtStart = _fakeLocation();
    _last = null;
    _anchor = null;
    _distanceM = 0;
    _maxGapMs = 0;
    _summary = null;
    _sub = ticker.snapshots.listen(_onSnapshot);
    _phase = SessionPhase.running;
    notifyListeners();
  }

  void _onSnapshot(SensorSnapshot s) {
    final w = _writer;
    if (w == null) return;
    w.write(sensorRowJson(s));
    final prev = _last;
    if (prev != null) _maxGapMs = math.max(_maxGapMs, s.tMs - prev.tMs);
    // 距離：最後に数えた地点から一定以上離れたら足す（止まっているときの揺れを足さない）
    final anchor = _anchor;
    if (anchor == null) {
      _anchor = s.location;
    } else {
      final d = haversineM(
        anchor.lat,
        anchor.lon,
        s.location.lat,
        s.location.lon,
      );
      if (d >= math.max(minStepM, anchor.accM * 0.5)) {
        _distanceM += d;
        _anchor = s.location;
      }
    }
    _last = s;
    notifyListeners();
  }

  /// 読み上げが終わったことを歩行ログに残す（engine に渡す `tts_finished` と同じ形）。
  void recordTtsFinished(String utteranceId) =>
      recordEvent('tts_finished', {'utterance_id': utteranceId});

  /// sensor 以外の行（`tts_finished`・`alert` など、eventlog.schema.json の type）を残す。
  /// 記録中だけ書く。
  void recordEvent(String type, Map<String, Object?> data, {int? tMs}) {
    final w = _writer;
    if (_phase != SessionPhase.running || w == null) return;
    w.write({
      'schema_version': schemaVersion,
      't_ms': tMs ?? _now().toUtc().millisecondsSinceEpoch,
      'type': type,
      'data': data,
    });
  }

  /// engine に渡したイベント1行（`eventToJson` の形そのまま）を残す。記録中だけ書く。
  void recordRow(Map<String, Object?> row) {
    final w = _writer;
    if (_phase != SessionPhase.running || w == null) return;
    w.write(row);
  }

  /// アプリが裏に回ったときなど。すぐ書き出して失わないようにする。
  Future<void> flush() async => _writer?.flush();

  Future<void> stop() async {
    if (_phase != SessionPhase.running) return;
    await _sub?.cancel();
    _sub = null;
    final w = _writer!;
    await w.close();
    _summary = SessionSummary(
      duration: elapsed,
      rows: w.lines,
      distanceM: _distanceM,
      maxGapMs: _maxGapMs,
      fileName: w.file.uri.pathSegments.last,
      settings: _settingsAtStart ?? settings(),
      fakeLocation: _fakeAtStart || _fakeLocation(),
    );
    _writer = null;
    _phase = SessionPhase.finished;
    notifyListeners();
  }

  /// 終了画面から開始画面に戻る。
  void reset() {
    if (_phase != SessionPhase.finished) return;
    _phase = SessionPhase.idle;
    _startedAt = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _writer?.close();
    super.dispose();
  }
}

import 'dart:math' as math;

/// 画面に出す A の候補1件（方向と距離は表示のためだけに計算する。どれを話すかには使わない）。
class CandidateMark {
  const CandidateMark({
    required this.name,
    required this.bearingDeg,
    required this.distanceM,
  });

  final String name;

  /// 現在地から見た方位（真北0°・時計回り）。
  final double bearingDeg;
  final double distanceM;
}

/// グラス視点の画面に重ねる、判断まわりの表示内容。
/// engine の Command（LogDecision・Speak・CaptureAndSearch）と B の結果から作る。
/// TODO: engine が届いたら、Executor がこの値を更新する。
class GlassOverlay {
  const GlassOverlay({
    this.candidates = const [],
    this.decision,
    this.reason,
    this.subtitle,
    this.areaName,
    this.nextSearchIn,
    this.lastSearch,
  });

  final List<CandidateMark> candidates;

  /// 今の判断（例 `speak:closest_approach`）と、その説明文（reason_codes.json）。
  final String? decision;
  final String? reason;

  /// 今話している文。
  final String? subtitle;
  final String? areaName;

  /// B の次の計測まで。
  final Duration? nextSearchIn;

  /// B の前回の結果かスキップ理由。
  final String? lastSearch;

  bool get engineConnected => decision != null;

  /// 字幕だけを入れ替えたもの（null で消す）。
  GlassOverlay withSubtitle(String? text) => GlassOverlay(
    candidates: candidates,
    decision: decision,
    reason: reason,
    subtitle: text,
    areaName: areaName,
    nextSearchIn: nextSearchIn,
    lastSearch: lastSearch,
  );

  /// A の候補だけを入れ替えたもの。
  GlassOverlay withCandidates(List<CandidateMark> list) => GlassOverlay(
    candidates: list,
    decision: decision,
    reason: reason,
    subtitle: subtitle,
    areaName: areaName,
    nextSearchIn: nextSearchIn,
    lastSearch: lastSearch,
  );

  static const empty = GlassOverlay();
}

/// 視線から見た相対方位（-180〜180、右が正）。
double relativeBearing(double targetDeg, double headingDeg) {
  final d = (targetDeg - headingDeg) % 360;
  return d > 180 ? d - 360 : d;
}

/// 2点間の方位（真北0°・時計回り）。
double bearingBetween(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final y = math.sin(rad(lon2 - lon1)) * math.cos(rad(lat2));
  final x =
      math.cos(rad(lat1)) * math.sin(rad(lat2)) -
      math.sin(rad(lat1)) * math.cos(rad(lat2)) * math.cos(rad(lon2 - lon1));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

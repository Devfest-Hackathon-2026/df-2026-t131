import 'package:flutter_activity_recognition/flutter_activity_recognition.dart';

/// engine に渡す行動の種類。
/// TODO: engine の雛形が届いたら engine の Activity 型に置き換える。
enum ActivityKind { walking, still, inVehicle, unknown }

/// 対応（リーダー決定 11/5）：
/// WALKING・RUNNING → walking、STILL → still、IN_VEHICLE・ON_BICYCLE → inVehicle、UNKNOWN → unknown
ActivityKind mapActivityType(ActivityType type) => switch (type) {
  ActivityType.WALKING || ActivityType.RUNNING => ActivityKind.walking,
  ActivityType.STILL => ActivityKind.still,
  ActivityType.IN_VEHICLE || ActivityType.ON_BICYCLE => ActivityKind.inVehicle,
  ActivityType.UNKNOWN => ActivityKind.unknown,
};

/// 信頼度 LOW は捨てて直前の値を保つ（安定する）。捨てるなら null。
ActivityKind? acceptActivity(Activity a) =>
    a.confidence == ActivityConfidence.LOW ? null : mapActivityType(a.type);

abstract class ActivitySource {
  /// 行動が変わったときに流れる。LOW の信頼度は流さない。
  Stream<ActivityKind> get changes;
}

class RecognitionActivitySource implements ActivitySource {
  @override
  Stream<ActivityKind> get changes => FlutterActivityRecognition
      .instance
      .activityStream
      .map(acceptActivity)
      .where((k) => k != null)
      .cast<ActivityKind>();
}

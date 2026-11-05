import 'package:flutter/services.dart';

/// 視線（背面カメラの向き）。方位は真北0°・時計回り、傾きは水平0°・上が正。
class GazeReading {
  const GazeReading({required this.azDeg, required this.pitchDeg});

  final double azDeg;
  final double pitchDeg;
}

abstract class GazeSource {
  Stream<GazeReading> get readings;

  /// 位置が分かったら呼ぶ（真北への補正に使う偏角を更新する）。
  Future<void> updateLocation(double lat, double lon, double? altM);
}

/// 端末の回転ベクトルセンサーから求める（計算は Kotlin の GazePlugin）。
/// 将来スマートグラスに替えるときは別の GazeSource を作る。
class DeviceOrientationGaze implements GazeSource {
  const DeviceOrientationGaze({
    this.events = const EventChannel('mobile/gaze'),
    this.control = const MethodChannel('mobile/gaze_control'),
  });

  final EventChannel events;
  final MethodChannel control;

  @override
  Stream<GazeReading> get readings =>
      events.receiveBroadcastStream().map((event) {
        final m = event as Map;
        return GazeReading(
          azDeg: (m['azDeg'] as num).toDouble(),
          pitchDeg: (m['pitchDeg'] as num).toDouble(),
        );
      });

  @override
  Future<void> updateLocation(double lat, double lon, double? altM) async {
    await control.invokeMethod<double>('setLocation', {
      'lat': lat,
      'lon': lon,
      'altM': altM ?? 0.0,
    });
  }
}

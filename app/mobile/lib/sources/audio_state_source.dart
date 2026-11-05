import 'package:flutter/services.dart';

/// 音の出口と通話状態。
class AudioState {
  const AudioState({required this.earphone, required this.inCall});

  /// 有線・Bluetooth・USB のイヤホンにつながっているか（false はスピーカー）。
  final bool earphone;
  final bool inCall;

  static const initial = AudioState(earphone: false, inCall: false);
}

abstract class AudioStateSource {
  Stream<AudioState> get states;
}

/// Kotlin の AudioStatePlugin が 1 秒ごとに送る値を受ける。
class PlatformAudioStateSource implements AudioStateSource {
  const PlatformAudioStateSource({
    this.events = const EventChannel('mobile/audio_state'),
  });

  final EventChannel events;

  @override
  Stream<AudioState> get states => events.receiveBroadcastStream().map((e) {
    final m = e as Map;
    return AudioState(
      earphone: m['earphone'] == true,
      inCall: m['inCall'] == true,
    );
  });
}

/// 電池と温度（デバッグ画面用。歩行ログには入れない）。
class DeviceStatus {
  const DeviceStatus({this.batteryPct, this.tempC});

  final double? batteryPct;
  final double? tempC;

  static Future<DeviceStatus> read({
    MethodChannel channel = const MethodChannel('mobile/device'),
  }) async {
    final m = await channel.invokeMapMethod<String, dynamic>('battery');
    return DeviceStatus(
      batteryPct: (m?['levelPct'] as num?)?.toDouble(),
      tempC: (m?['tempC'] as num?)?.toDouble(),
    );
  }
}

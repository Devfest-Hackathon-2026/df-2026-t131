import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';

/// メモリ上の1枚（NV21）。ファイルには書かない。
class CameraFrame {
  const CameraFrame({
    required this.nv21,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.sensorOrientation,
  });

  /// 先頭 幅×高さ×1.5 バイトだけの正しい NV21。
  final Uint8List nv21;
  final int width;
  final int height;
  final int yRowStride;
  final int sensorOrientation;

  /// 輝度（Y 面）。NV21 の先頭 幅×高さ バイト。
  Uint8List get luma => Uint8List.sublistView(nv21, 0, yRowStride * height);
}

/// NV21 で届いたバイト列から、正しい長さ（幅×高さ×1.5）だけを切り出す。
/// camera_android_camerax は確保しただけの余りを後ろに付けて送ってくるため。
Uint8List trimNv21(Uint8List bytes, int width, int height) {
  final expected = width * height * 3 ~/ 2;
  if (bytes.length <= expected) return bytes;
  return Uint8List.sublistView(bytes, 0, expected);
}

abstract class CameraSource {
  CameraController? get controller;
  Future<void> start();
  Future<void> stop();

  /// 最新の1枚（最大でも [PhoneCameraSource.sampleEvery] 前のもの）。まだ無ければ null。
  CameraFrame? latestFrame();

  /// 今の1枚を取り出す（B の撮影用）。取れなければ null。
  Future<CameraFrame?> captureFrame();
}

/// スマホの背面カメラ。将来 GlassesCameraSource に差し替える。
///
/// 画像ストリームを流しっぱなしにすると、1枚 約540KB を毎秒30枚 Dart に写すことになり、
/// 画面がカクつく（実機で確認）。画質の計算も B の撮影も1秒に1枚で足りるので、
/// 必要なときだけストリームを開いて1枚受け取り、すぐ閉じる。プレビューには影響しない。
class PhoneCameraSource implements CameraSource {
  PhoneCameraSource({this.sampleEvery = const Duration(seconds: 1)});

  final Duration sampleEvery;
  CameraController? _controller;
  CameraFrame? _latest;
  Timer? _sampler;
  Completer<CameraFrame?>? _pending;
  int _sensorOrientation = 90;

  @override
  CameraController? get controller => _controller;

  @override
  Future<void> start() async {
    if (_controller != null) return;
    final cameras = await availableCameras();
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _sensorOrientation = back.sensorOrientation;
    final controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await controller.initialize();
    _controller = controller;
    _sampler = Timer.periodic(sampleEvery, (_) => captureFrame());
  }

  @override
  Future<CameraFrame?> captureFrame() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return Future.value(null);
    final pending = _pending;
    if (pending != null) return pending.future; // 取り出し中なら同じ1枚を待つ
    final done = Completer<CameraFrame?>();
    _pending = done;
    var got = false;
    c
        .startImageStream((image) {
          if (got) return;
          got = true;
          final plane = image.planes.first;
          final frame = CameraFrame(
            nv21: trimNv21(plane.bytes, image.width, image.height),
            width: image.width,
            height: image.height,
            yRowStride: plane.bytesPerRow,
            sensorOrientation: _sensorOrientation,
          );
          _latest = frame;
          _finish(c, done, frame);
        })
        .catchError((Object _) => _finish(c, done, null));
    // 1秒待っても届かなければあきらめる
    Future<void>.delayed(
      const Duration(seconds: 1),
      () => _finish(c, done, null),
    );
    return done.future;
  }

  void _finish(
    CameraController c,
    Completer<CameraFrame?> done,
    CameraFrame? f,
  ) {
    if (done.isCompleted) return;
    done.complete(f);
    _pending = null;
    if (c.value.isStreamingImages) {
      c.stopImageStream().catchError((Object _) {});
    }
  }

  @override
  Future<void> stop() async {
    _sampler?.cancel();
    _sampler = null;
    final c = _controller;
    _controller = null;
    _latest = null;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    _pending = null;
    if (c == null) return;
    if (c.value.isStreamingImages) await c.stopImageStream();
    await c.dispose();
  }

  @override
  CameraFrame? latestFrame() => _latest;
}

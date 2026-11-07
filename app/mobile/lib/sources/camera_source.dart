import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;

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

/// AI・画質の計算・顔の検出に渡す1枚の横幅。
///
/// プレビューを見やすくするためにカメラは 1280×720 で動かすが、プラグイン（CameraX）は
/// プレビューと画像の取り出しに同じ解像度を使うので、取り出した1枚だけ端末内で縮める。
/// 横720px は以前の設定（720×480）と同じ横幅で、ぶれの値（隣の画素との差）の大きさを変えないため。
const int analysisFrameWidth = 720;

/// NV21（Y 面のあとに VU が交互に並ぶ）を、横 [targetWidth] に縮める。
/// Y は範囲の平均（縮めたときにぶれの値が鋭く出すぎないように）、VU は近いものを拾う。
/// 返す画像は行の幅＝横幅（余りなし）。もともと [targetWidth] 以下ならそのまま返す。
CameraFrame downscaleNv21Frame(
  CameraFrame f, {
  int targetWidth = analysisFrameWidth,
}) {
  if (f.width <= targetWidth) return f;
  final w = f.width, h = f.height, stride = f.yRowStride;
  final ow = targetWidth & ~1; // VU は2画素で1組なので偶数にそろえる
  final oh = math.max(2, ((h * ow / w).round()) & ~1);
  final src = f.nv21;
  final out = Uint8List(ow * oh * 3 ~/ 2);
  final sx = w / ow, sy = h / oh;

  // 出力の各列が元のどの範囲にあたるか（先に計算しておく）
  final x0s = List<int>.generate(ow, (x) => (x * sx).floor());
  final x1s = List<int>.generate(
    ow,
    (x) => math.max((x * sx).floor() + 1, math.min(w, ((x + 1) * sx).floor())),
  );
  for (var oy = 0; oy < oh; oy++) {
    final y0 = (oy * sy).floor();
    final y1 = math.max(y0 + 1, math.min(h, ((oy + 1) * sy).floor()));
    final outRow = oy * ow;
    for (var ox = 0; ox < ow; ox++) {
      final x0 = x0s[ox], x1 = x1s[ox];
      var sum = 0;
      for (var y = y0; y < y1; y++) {
        final row = y * stride;
        for (var x = x0; x < x1; x++) {
          sum += src[row + x];
        }
      }
      out[outRow + ox] = sum ~/ ((y1 - y0) * (x1 - x0));
    }
  }

  final uvStart = stride * h;
  final outUv = ow * oh;
  final maxIndex = src.length - 2;
  for (var oy = 0; oy < oh ~/ 2; oy++) {
    final syRow = math.min((h - 1) >> 1, ((oy * 2) * sy).floor() >> 1);
    final inRow = uvStart + syRow * stride;
    final outRow = outUv + oy * ow;
    for (var ox = 0; ox < ow; ox += 2) {
      final sxCol = math.min(w - 2, (ox * sx).floor() & ~1);
      final i = inRow + sxCol;
      if (i <= maxIndex) {
        out[outRow + ox] = src[i]; // V
        out[outRow + ox + 1] = src[i + 1]; // U
      } else {
        out[outRow + ox] = 128;
        out[outRow + ox + 1] = 128;
      }
    }
  }
  return CameraFrame(
    nv21: out,
    width: ow,
    height: oh,
    yRowStride: ow,
    sensorOrientation: f.sensorOrientation,
  );
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
      // 画面で人が見るプレビューのため 1280×720。AI などに渡す1枚は [downscaleNv21Frame] で縮める
      ResolutionPreset.high,
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
          _stopStream(c); // 1枚あれば足りるので、次の1枚が届く前に閉じる
          final plane = image.planes.first;
          final full = CameraFrame(
            nv21: trimNv21(plane.bytes, image.width, image.height),
            width: image.width,
            height: image.height,
            yRowStride: plane.bytesPerRow,
            sensorOrientation: _sensorOrientation,
          );
          // 縮小は1回 10ms 前後かかり、画面の1コマ（16ms）を落とすので裏の isolate で行う
          compute(_downscale, full).then((frame) {
            if (!identical(_controller, c)) return _finish(c, done, null);
            _latest = frame;
            _finish(c, done, frame);
          }, onError: (Object _) => _finish(c, done, null));
        })
        .catchError((Object _) => _finish(c, done, null));
    // 1秒待っても届かなければあきらめる（届いたあとの縮小は待つ）
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (!got) _finish(c, done, null);
    });
    return done.future;
  }

  void _stopStream(CameraController c) {
    if (c.value.isStreamingImages) {
      c.stopImageStream().catchError((Object _) {});
    }
  }

  void _finish(
    CameraController c,
    Completer<CameraFrame?> done,
    CameraFrame? f,
  ) {
    if (done.isCompleted) return;
    done.complete(f);
    if (identical(_pending, done)) _pending = null;
    _stopStream(c);
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

/// [compute] に渡す（トップレベルの関数でないと isolate に送れない）。
CameraFrame _downscale(CameraFrame f) => downscaleNv21Frame(f);

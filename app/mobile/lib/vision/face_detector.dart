import 'dart:ui' show Size;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    as mlkit;

import '../sources/camera_source.dart';
import 'search_image.dart';

/// 送る前に顔を見つける係。端末の中だけで動く（画像を外に出さない）。
abstract class FaceFinder {
  /// [frame] の中の顔の枠（向きを直したあとの座標）。見つけられなかったら例外を投げる。
  Future<List<FaceBox>> find(CameraFrame frame, int rotationDeg);
  Future<void> close();
}

/// ML Kit Face Detection（端末内のモデル）。
///
/// 小さい顔・横顔の取りこぼしを減らすため、顔の大きさの下限を画像の幅の5%まで下げ、
/// 速さより正確さを取る（1回の検索につき1枚だけなので重くてもよい）。
class MlKitFaceFinder implements FaceFinder {
  MlKitFaceFinder()
    : _detector = mlkit.FaceDetector(
        options: mlkit.FaceDetectorOptions(
          minFaceSize: 0.05,
          performanceMode: mlkit.FaceDetectorMode.accurate,
        ),
      );

  final mlkit.FaceDetector _detector;

  @override
  Future<List<FaceBox>> find(CameraFrame frame, int rotationDeg) async {
    final input = mlkit.InputImage.fromBytes(
      bytes: frame.nv21,
      metadata: mlkit.InputImageMetadata(
        size: Size(frame.width.toDouble(), frame.height.toDouble()),
        rotation:
            mlkit.InputImageRotationValue.fromRawValue(rotationDeg) ??
            mlkit.InputImageRotation.rotation0deg,
        format: mlkit.InputImageFormat.nv21,
        bytesPerRow: frame.yRowStride,
      ),
    );
    final faces = await _detector.processImage(input);
    return [
      for (final f in faces)
        FaceBox(
          f.boundingBox.left,
          f.boundingBox.top,
          f.boundingBox.width,
          f.boundingBox.height,
        ),
    ];
  }

  @override
  Future<void> close() => _detector.close();
}

/// 画面を横向き（landscapeLeft）に固定しているときに、カメラの1枚を正しい向きにする回転。
/// 背面カメラの sensorOrientation が 90 なら 0（回さない）。
int landscapeLeftRotation(int sensorOrientation) =>
    ((sensorOrientation - 90) % 360 + 360) % 360;

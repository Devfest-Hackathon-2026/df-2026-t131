import 'dart:isolate';
import 'dart:typed_data';

import '../config.dart';

/// 画質。blur は 1 がぶれていない、brightness は 0（暗い）〜1（明るい）。
class ImageQuality {
  const ImageQuality({required this.blur, required this.brightness});

  final double blur;
  final double brightness;
}

/// Y 面（輝度）から画質を計算する。
///
/// - brightness = 間引いた画素の Y の平均 / 255
/// - blur = ラプラシアン（隣の1画素と比べる）の分散を K で割って 0〜1 に
///   （4画素先と比べると、ぼやけた画像でも 1 になって使えなかったため、隣の1画素）
/// - 計算する位置は [step] 画素おきに間引く
ImageQuality measureImageQuality(
  Uint8List y,
  int width,
  int height, {
  int rowStride = 0,
  int step = 4,
  double k = AppConfig.blurDivisorK,
}) {
  final stride = rowStride > 0 ? rowStride : width;
  var sumY = 0.0;
  var n = 0;
  var sumL = 0.0;
  var sumL2 = 0.0;
  for (var row = 1; row < height - 1; row += step) {
    final base = row * stride;
    for (var col = 1; col < width - 1; col += step) {
      final i = base + col;
      final c = y[i];
      final lap = 4 * c - y[i - 1] - y[i + 1] - y[i - stride] - y[i + stride];
      sumY += c;
      sumL += lap;
      sumL2 += lap * lap;
      n++;
    }
  }
  if (n == 0) return const ImageQuality(blur: 0, brightness: 0);
  final mean = sumL / n;
  final variance = sumL2 / n - mean * mean;
  final blur = (variance / k).clamp(0.0, 1.0);
  return ImageQuality(blur: blur, brightness: sumY / n / 255.0);
}

/// 画面の処理を止めないよう別の Isolate で計算する。
Future<ImageQuality> measureImageQualityInBackground(
  Uint8List y,
  int width,
  int height, {
  int rowStride = 0,
}) {
  return Isolate.run(
    () => measureImageQuality(y, width, height, rowStride: rowStride),
  );
}

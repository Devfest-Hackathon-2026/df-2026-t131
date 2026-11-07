import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../config.dart';

/// 画質。blur は 1 がぶれていない、brightness は 0（暗い）〜1（明るい）。
/// crosswalk は、画像の下の方（路面）に横断歩道の縞模様が写っている度合い（0〜1。11/7 追加）。
class ImageQuality {
  const ImageQuality({
    required this.blur,
    required this.brightness,
    this.crosswalk,
  });

  final double blur;
  final double brightness;
  final double? crosswalk;
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
  int rotationDeg = 0,
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
  return ImageQuality(
    blur: blur,
    brightness: sumY / n / 255.0,
    crosswalk: measureCrosswalk(
      y,
      width,
      height,
      rowStride: stride,
      rotationDeg: rotationDeg,
    ),
  );
}

/// 横断歩道の縞模様（白い帯と路面が交互に並ぶ）が、画像の下の方に写っている度合い（0〜1）。
///
/// スマホを横持ちで首の高さに構えて進む向きに向けると、前の路面は画像の下の方に写り、
/// 横断歩道の白い帯は（進む向きに沿って並ぶので）横1列の上で「明・暗・明・暗…」と並ぶ。
/// - 画像を正しい向きにした座標（[rotationDeg] は時計回りの回転）で、下 55〜95% の高さの横の列を
///   [rows] 本だけ見る（左右の端 10% は除く）
/// - 列ごとに [samples] 点を取り、明るい側と暗い側の差（上位10%−下位10%）が [minContrast] 以上で、
///   その中間で2値にしたとき明るい帯が [minStripes] 本以上、明るい部分の割合が 25〜75%、
///   帯の幅がそろっている（ばらつきが [maxWidthCv] 以下）なら「縞がある列」とする
/// - 値は「縞がある列」の割合。AI を使わない決まった計算（同じ画像なら同じ値）
double measureCrosswalk(
  Uint8List y,
  int width,
  int height, {
  int rowStride = 0,
  int rotationDeg = 0,
  int rows = 12,
  int samples = 96,
  int minContrast = 40,
  int minStripes = 3,
  double maxWidthCv = 0.6,
}) {
  final stride = rowStride > 0 ? rowStride : width;
  final r = ((rotationDeg % 360) + 360) % 360;
  final turned = r == 90 || r == 270;
  final uw = turned ? height : width; // 正しい向きにしたときの幅・高さ
  final uh = turned ? width : height;
  if (uw < samples || uh < rows * 2) return 0;
  int at(int u, int v) {
    final (x, yy) = switch (r) {
      90 => (v, height - 1 - u),
      180 => (width - 1 - u, height - 1 - v),
      270 => (width - 1 - v, u),
      _ => (u, v),
    };
    return y[yy * stride + x];
  }

  var striped = 0;
  final profile = List<int>.filled(samples, 0);
  for (var k = 0; k < rows; k++) {
    final v = (uh * (0.55 + 0.40 * k / (rows - 1))).floor().clamp(0, uh - 1);
    for (var i = 0; i < samples; i++) {
      final u = (uw * (0.10 + 0.80 * i / (samples - 1))).floor().clamp(
        1,
        uw - 2,
      );
      profile[i] = (at(u - 1, v) + 2 * at(u, v) + at(u + 1, v)) >> 2;
    }
    final sorted = List<int>.of(profile)..sort();
    final lo = sorted[samples ~/ 10], hi = sorted[samples - 1 - samples ~/ 10];
    if (hi - lo < minContrast) continue;
    final mid = (lo + hi) ~/ 2;
    final widths = <int>[];
    var bright = 0, run = 0;
    for (var i = 0; i < samples; i++) {
      if (profile[i] > mid) {
        bright++;
        run++;
      } else if (run > 0) {
        if (run >= 2) widths.add(run);
        run = 0;
      }
    }
    if (run >= 2) widths.add(run);
    final frac = bright / samples;
    if (widths.length < minStripes || frac < 0.25 || frac > 0.75) continue;
    final mean = widths.reduce((a, b) => a + b) / widths.length;
    var sq = 0.0;
    for (final w in widths) {
      sq += (w - mean) * (w - mean);
    }
    final cv = math.sqrt(sq / widths.length) / mean;
    if (cv <= maxWidthCv) striped++;
  }
  return striped / rows;
}

/// 画面の処理を止めないよう別の Isolate で計算する。
Future<ImageQuality> measureImageQualityInBackground(
  Uint8List y,
  int width,
  int height, {
  int rowStride = 0,
  int rotationDeg = 0,
}) {
  return Isolate.run(
    () => measureImageQuality(
      y,
      width,
      height,
      rowStride: rowStride,
      rotationDeg: rotationDeg,
    ),
  );
}

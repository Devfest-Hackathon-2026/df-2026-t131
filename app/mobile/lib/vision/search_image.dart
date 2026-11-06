import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// B で送る画像の長辺の上限（CLAUDE.md 6章「B の仕様」）。
const int searchImageMaxEdge = 640;

/// 顔の枠（元のカメラ画像を、向きを直したあとの座標で）。
class FaceBox {
  const FaceBox(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
}

/// [encodeSearchJpeg] に渡すもの。isolate に渡すので、中身は単純な値だけ。
class SearchImageInput {
  const SearchImageInput({
    required this.nv21,
    required this.width,
    required this.height,
    required this.rowStride,
    required this.rotationDeg,
    required this.faces,
    this.maxEdge = searchImageMaxEdge,
    this.quality = 80,
  });

  final Uint8List nv21;
  final int width, height, rowStride;

  /// 画像を正しい向きにするための時計回りの回転（0・90・180・270）。
  final int rotationDeg;

  /// 隠す顔（向きを直したあとの、元の大きさでの座標）。
  final List<FaceBox> faces;
  final int maxEdge;
  final int quality;
}

/// NV21 の1枚を、長辺 [SearchImageInput.maxEdge] 以下に縮め、向きを直し、
/// 顔をモザイクで隠して JPEG にする。ファイルには書かない（メモリの中だけ）。
///
/// 元の大きさで RGB を作らず、縮めた大きさで直接 NV21 から色を拾う（速さと電池のため）。
Uint8List encodeSearchJpeg(SearchImageInput input) {
  final w = input.width, h = input.height, stride = input.rowStride;
  if (w <= 0 || h <= 0 || stride < w) {
    throw ArgumentError('画像の大きさが不正です');
  }
  final uvStart = stride * h;
  final need = uvStart + stride * ((h + 1) ~/ 2);
  if (input.nv21.length < need - (stride - w)) {
    throw ArgumentError('NV21 の長さが足りません');
  }

  final scale = math.min(1.0, input.maxEdge / math.max(w, h));
  final ow = math.max(1, (w * scale).round());
  final oh = math.max(1, (h * scale).round());
  final src = input.nv21;
  final maxIndex = src.length - 1;
  final out = img.Image(width: ow, height: oh);
  for (var oy = 0; oy < oh; oy++) {
    final sy = math.min(h - 1, (oy / scale).floor());
    final yRow = sy * stride;
    final uvRow = uvStart + (sy >> 1) * stride;
    for (var ox = 0; ox < ow; ox++) {
      final sx = math.min(w - 1, (ox / scale).floor());
      final y = src[yRow + sx];
      final uvi = uvRow + (sx & ~1);
      // NV21 は V, U の順
      final v = (uvi <= maxIndex ? src[uvi] : 128) - 128;
      final u = (uvi + 1 <= maxIndex ? src[uvi + 1] : 128) - 128;
      final r = (y + 1.402 * v).round().clamp(0, 255);
      final g = (y - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
      final b = (y + 1.772 * u).round().clamp(0, 255);
      out.setPixelRgb(ox, oy, r, g, b);
    }
  }

  final rotated = switch (input.rotationDeg % 360) {
    0 => out,
    final deg => img.copyRotate(out, angle: deg),
  };
  for (final f in input.faces) {
    _pixelate(rotated, f, scale);
  }
  return img.encodeJpg(rotated, quality: input.quality);
}

/// 顔の枠を少し広げて、粗いモザイクにする（元に戻せない程度に粗く）。
void _pixelate(img.Image image, FaceBox f, double scale) {
  const pad = 0.25; // 髪・あごまで隠す
  final fw = f.width * scale, fh = f.height * scale;
  final x0 = ((f.left * scale) - fw * pad).floor().clamp(0, image.width);
  final y0 = ((f.top * scale) - fh * pad).floor().clamp(0, image.height);
  final x1 = ((f.left * scale) + fw * (1 + pad)).ceil().clamp(0, image.width);
  final y1 = ((f.top * scale) + fh * (1 + pad)).ceil().clamp(0, image.height);
  if (x1 <= x0 || y1 <= y0) return;
  // 顔の幅を約5マスに割る（目鼻が読めない粗さ）。小さい顔でも最低4px。
  final cell = math.max(4, ((x1 - x0) / 5).ceil());
  for (var by = y0; by < y1; by += cell) {
    for (var bx = x0; bx < x1; bx += cell) {
      final ex = math.min(bx + cell, x1), ey = math.min(by + cell, y1);
      var r = 0, g = 0, b = 0, n = 0;
      for (var y = by; y < ey; y++) {
        for (var x = bx; x < ex; x++) {
          final p = image.getPixel(x, y);
          r += p.r.toInt();
          g += p.g.toInt();
          b += p.b.toInt();
          n++;
        }
      }
      if (n == 0) continue;
      img.fillRect(
        image,
        x1: bx,
        y1: by,
        x2: ex - 1,
        y2: ey - 1,
        color: img.ColorRgb8(r ~/ n, g ~/ n, b ~/ n),
      );
    }
  }
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/sources/image_quality.dart';

/// 幅 w・高さ h の Y 面。[stripe] が true の画素を白（220）、それ以外を路面の灰色（90）にする。
Uint8List plane(int w, int h, bool Function(int x, int y) stripe) {
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      out[y * w + x] = stripe(x, y) ? 220 : 90;
    }
  }
  return out;
}

void main() {
  const w = 320, h = 240;

  test('下の方に白い帯が並んでいれば、縞模様の値が高い', () {
    final y = plane(w, h, (x, yy) => yy > h * 0.5 && (x ~/ 20).isEven);
    expect(measureCrosswalk(y, w, h), greaterThanOrEqualTo(0.9));
  });

  test('一様な路面・上の方だけの縞・帯が1本だけなら低い', () {
    expect(measureCrosswalk(plane(w, h, (_, _) => false), w, h), 0);
    final top = plane(w, h, (x, yy) => yy < h * 0.4 && (x ~/ 20).isEven);
    expect(measureCrosswalk(top, w, h), 0);
    final one = plane(w, h, (x, yy) => yy > h * 0.5 && x > 140 && x < 180);
    expect(measureCrosswalk(one, w, h), 0);
  });

  test('カメラの1枚が逆さ（180°回す）なら、生の画像の上の方を路面として見る', () {
    final y = plane(w, h, (x, yy) => yy < h * 0.5 && (x ~/ 20).isEven);
    expect(measureCrosswalk(y, w, h), 0);
    expect(
      measureCrosswalk(y, w, h, rotationDeg: 180),
      greaterThanOrEqualTo(0.9),
    );
  });

  test('measureImageQuality にも縞模様の値が入る', () {
    final y = plane(w, h, (x, yy) => yy > h * 0.5 && (x ~/ 20).isEven);
    expect(measureImageQuality(y, w, h).crosswalk, greaterThanOrEqualTo(0.9));
  });
}

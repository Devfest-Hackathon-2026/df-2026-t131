import 'dart:typed_data';

import 'package:flutter_activity_recognition/flutter_activity_recognition.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/sources/activity_source.dart';
import 'package:mobile/sources/camera_source.dart';
import 'package:mobile/sources/image_quality.dart';
import 'package:mobile/sources/location_source.dart';

void main() {
  group('位置', () {
    test('速度が負なら null', () {
      expect(normalizeSpeed(true, -1), isNull);
      expect(normalizeSpeed(false, 1.2), isNull);
      expect(normalizeSpeed(true, 1.2), 1.2);
    });

    test('0.5 m/s 未満なら進行方向は null', () {
      expect(
        normalizeCourse(speedMps: 0.45, hasHeading: true, heading: 90),
        isNull,
      );
      expect(
        normalizeCourse(speedMps: null, hasHeading: true, heading: 90),
        isNull,
      );
      expect(normalizeCourse(speedMps: 1.2, hasHeading: true, heading: 90), 90);
    });

    test('方位が取れない・範囲外なら null、360 は 0', () {
      expect(
        normalizeCourse(speedMps: 1.2, hasHeading: false, heading: 90),
        isNull,
      );
      expect(
        normalizeCourse(speedMps: 1.2, hasHeading: true, heading: -1),
        isNull,
      );
      expect(normalizeCourse(speedMps: 1.2, hasHeading: true, heading: 360), 0);
    });
  });

  group('行動', () {
    test('リーダー決定の対応', () {
      expect(mapActivityType(ActivityType.WALKING), ActivityKind.walking);
      expect(mapActivityType(ActivityType.RUNNING), ActivityKind.walking);
      expect(mapActivityType(ActivityType.STILL), ActivityKind.still);
      expect(mapActivityType(ActivityType.IN_VEHICLE), ActivityKind.inVehicle);
      expect(mapActivityType(ActivityType.ON_BICYCLE), ActivityKind.inVehicle);
      expect(mapActivityType(ActivityType.UNKNOWN), ActivityKind.unknown);
    });

    test('信頼度 LOW は捨てる', () {
      expect(
        acceptActivity(Activity(ActivityType.WALKING, ActivityConfidence.LOW)),
        isNull,
      );
      expect(
        acceptActivity(
          Activity(ActivityType.WALKING, ActivityConfidence.MEDIUM),
        ),
        ActivityKind.walking,
      );
    });
  });

  group('画質', () {
    const w = 64, h = 48;

    test('一様な画像はぶれ0・明るさは値/255', () {
      final y = Uint8List(w * h)..fillRange(0, w * h, 128);
      final q = measureImageQuality(y, w, h);
      expect(q.blur, 0);
      expect(q.brightness, closeTo(128 / 255, 1e-9));
    });

    test('細かい模様はぶれていない（1で頭打ち）', () {
      // 画素ごとにばらばらな値（ノイズ）。決まった並びにするため簡単な乱数を使う
      final y = Uint8List(w * h);
      var s = 12345;
      for (var i = 0; i < w * h; i++) {
        s = (s * 1103515245 + 12345) & 0x7fffffff;
        y[i] = s >> 16 & 0xff;
      }
      expect(measureImageQuality(y, w, h).blur, 1);
    });

    test('なめらかな傾きはぶれ扱い（隣の1画素と比べる）', () {
      final y = Uint8List(w * h);
      for (var i = 0; i < w * h; i++) {
        y[i] = (i % w) * 4;
      }
      expect(measureImageQuality(y, w, h).blur, lessThan(0.01));
    });
  });

  test('NV21 は 幅×高さ×1.5 に切り詰める', () {
    final bytes = Uint8List(541392);
    expect(trimNv21(bytes, 720, 480).length, 518400);
    expect(trimNv21(Uint8List(100), 10, 10).length, 100);
  });

  group('AI などに渡す1枚の縮小', () {
    CameraFrame frame(
      int w,
      int h, {
      int? stride,
      int y = 100,
      int v = 150,
      int u = 90,
    }) {
      final s = stride ?? w;
      final bytes = Uint8List(s * h + s * (h ~/ 2));
      bytes.fillRange(0, s * h, y);
      for (var i = s * h; i + 1 < bytes.length; i += 2) {
        bytes[i] = v;
        bytes[i + 1] = u;
      }
      return CameraFrame(
        nv21: bytes,
        width: w,
        height: h,
        yRowStride: s,
        sensorOrientation: 90,
      );
    }

    test('1280×720 は横720に縮め、色と明るさを保つ', () {
      final out = downscaleNv21Frame(frame(1280, 720));
      expect(out.width, 720);
      expect(out.height, 404); // 405 を偶数にそろえる（切り捨て）
      expect(out.yRowStride, 720);
      expect(out.nv21.length, 720 * 404 * 3 ~/ 2);
      expect(out.nv21.sublist(0, 720 * 404).every((b) => b == 100), isTrue);
      expect(out.nv21[720 * 404], 150); // V
      expect(out.nv21[720 * 404 + 1], 90); // U
      expect(out.nv21.last, 90);
    });

    test('行の余り（stride）があっても読める', () {
      final out = downscaleNv21Frame(frame(1280, 720, stride: 1344));
      expect(out.width, 720);
      expect(out.nv21.sublist(0, 720 * 404).every((b) => b == 100), isTrue);
    });

    test('もともと小さい1枚はそのまま', () {
      final f = frame(720, 480);
      expect(identical(downscaleNv21Frame(f), f), isTrue);
    });
  });
}

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:engine/engine.dart' as eng;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mobile/sources/camera_source.dart';
import 'package:mobile/sources/voice_command_source.dart';
import 'package:mobile/vision/face_detector.dart';
import 'package:mobile/vision/search_image.dart';
import 'package:mobile/vision/search_progress.dart';
import 'package:mobile/vision/visual_searcher.dart';

/// 輝度がでたらめ（ざらざら）な NV21。モザイクをかけた所だけ平らになるかで確かめる。
CameraFrame noiseFrame(int w, int h, {int seed = 1}) {
  final r = math.Random(seed);
  final bytes = Uint8List(w * h * 3 ~/ 2);
  for (var i = 0; i < w * h; i++) {
    bytes[i] = r.nextInt(256);
  }
  for (var i = w * h; i < bytes.length; i++) {
    bytes[i] = 128;
  }
  return CameraFrame(
    nv21: bytes,
    width: w,
    height: h,
    yRowStride: w,
    sensorOrientation: 90,
  );
}

double lumaStdDev(img.Image im, int x0, int y0, int x1, int y1) {
  var sum = 0.0, sq = 0.0, n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final v = im.getPixel(x, y).r.toDouble();
      sum += v;
      sq += v * v;
      n++;
    }
  }
  final mean = sum / n;
  return math.sqrt(sq / n - mean * mean);
}

class FakeCamera implements CameraSource {
  FakeCamera(this.frame);
  CameraFrame? frame;
  @override
  CameraController? get controller => null;
  @override
  Future<CameraFrame?> captureFrame() async => frame;
  @override
  CameraFrame? latestFrame() => frame;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class FakeFaces implements FaceFinder {
  FakeFaces({this.faces = const [], this.fail = false});
  final List<FaceBox> faces;
  final bool fail;
  @override
  Future<List<FaceBox>> find(CameraFrame frame, int rotationDeg) async {
    if (fail) throw StateError('ML Kit が動かない');
    return faces;
  }

  @override
  Future<void> close() async {}
}

eng.CaptureAndSearch command() => eng.CaptureAndSearch(
  searchId: 's_1',
  tile: eng.TileId(x: 58190, y: 25510),
  gazeAzDeg10: 120,
  candidateIds: const ['lm_0001'],
);

Map<String, dynamic> unknownJson(String id) => eng.VisualSearchResponse(
  searchId: id,
  result: 'unknown',
  landmarkId: null,
  objectName: null,
  description: null,
  part: null,
  confidence: 0.2,
  named: false,
  sources: const [],
).toJson();

void main() {
  group('送る画像（encodeSearchJpeg）', () {
    test('長辺640px以下の JPEG にする', () {
      final f = noiseFrame(1280, 720);
      final jpeg = encodeSearchJpeg(
        SearchImageInput(
          nv21: f.nv21,
          width: f.width,
          height: f.height,
          rowStride: f.yRowStride,
          rotationDeg: 0,
          faces: const [],
        ),
      );
      final im = img.decodeJpg(jpeg)!;
      expect(im.width, 640);
      expect(im.height, 360);
    });

    test('小さい画像は大きくしない', () {
      final f = noiseFrame(320, 240);
      final im = img.decodeJpg(
        encodeSearchJpeg(
          SearchImageInput(
            nv21: f.nv21,
            width: 320,
            height: 240,
            rowStride: 320,
            rotationDeg: 0,
            faces: const [],
          ),
        ),
      )!;
      expect((im.width, im.height), (320, 240));
    });

    test('顔の所だけモザイクで平らになる（ほかは元のまま）', () {
      final f = noiseFrame(1280, 720);
      // 元の大きさで (400,200) から 200×200 の顔 → 送る画像では (200,100) から 100×100
      final im = img.decodeJpg(
        encodeSearchJpeg(
          SearchImageInput(
            nv21: f.nv21,
            width: 1280,
            height: 720,
            rowStride: 1280,
            rotationDeg: 0,
            faces: const [FaceBox(400, 200, 200, 200)],
          ),
        ),
      )!;
      // モザイクの1マスの中（顔の中心付近）はほぼ一色
      final face = lumaStdDev(im, 245, 145, 255, 155);
      final outside = lumaStdDev(im, 500, 250, 510, 260);
      expect(face, lessThan(12));
      expect(outside, greaterThan(40));
    });

    test('90°回すと縦長になる', () {
      final f = noiseFrame(640, 480);
      final im = img.decodeJpg(
        encodeSearchJpeg(
          SearchImageInput(
            nv21: f.nv21,
            width: 640,
            height: 480,
            rowStride: 640,
            rotationDeg: 90,
            faces: const [],
          ),
        ),
      )!;
      expect((im.width, im.height), (480, 640));
    });

    test('横向き固定（landscapeLeft）での回転', () {
      expect(landscapeLeftRotation(90), 0);
      expect(landscapeLeftRotation(270), 180);
      expect(landscapeLeftRotation(0), 270);
    });
  });

  group('VisualSearcher（合流4）', () {
    test('撮って、engine の決めた値と画像だけを送り、答えを返す', () async {
      Map<String, dynamic>? sent;
      final s = VisualSearcher(
        camera: FakeCamera(noiseFrame(640, 480)),
        faces: FakeFaces(faces: const [FaceBox(10, 10, 50, 50)]),
        post: (body) async {
          sent = body;
          return (json: unknownJson('s_1'), error: null);
        },
        encode: (input) async => encodeSearchJpeg(input),
      );
      final out = await s.run(command());
      expect(out, isA<VisualAnswered>());
      expect((out as VisualAnswered).response.result, 'unknown');
      expect(sent!.keys.toSet(), {
        'schema_version',
        'search_id',
        'tile',
        'gaze_az_deg',
        'candidate_ids',
        'image_jpeg_base64',
        'area',
      });
      expect(sent!['gaze_az_deg'], 120);
      expect(sent!['candidate_ids'], ['lm_0001']);
      final jpeg = base64Decode(sent!['image_jpeg_base64'] as String);
      expect(img.decodeJpg(jpeg), isNotNull);
    });

    test('撮影 → 顔ぼかし → 送信の順に、画面の札へ段階を知らせる', () async {
      final phases = <SearchPhase>[];
      final s = VisualSearcher(
        camera: FakeCamera(noiseFrame(640, 480)),
        faces: FakeFaces(),
        post: (body) async => (json: unknownJson('s_1'), error: null),
        encode: (input) async => encodeSearchJpeg(input),
      );
      await s.run(command(), onPhase: phases.add);
      expect(phases, [
        SearchPhase.capturing,
        SearchPhase.blurring,
        SearchPhase.sending,
      ]);
    });

    test('顔ぼかしに失敗したら送信の段階に進まない', () async {
      final phases = <SearchPhase>[];
      final s = VisualSearcher(
        camera: FakeCamera(noiseFrame(640, 480)),
        faces: FakeFaces(fail: true),
        post: (body) async => (json: null, error: null),
      );
      await s.run(command(), onPhase: phases.add);
      expect(phases, [SearchPhase.capturing, SearchPhase.blurring]);
    });

    test('顔を見つけられなければ送らない（face_blur_failed）', () async {
      var posted = false;
      final s = VisualSearcher(
        camera: FakeCamera(noiseFrame(640, 480)),
        faces: FakeFaces(fail: true),
        post: (body) async {
          posted = true;
          return (json: null, error: null);
        },
        encode: (input) async => encodeSearchJpeg(input),
      );
      final out = await s.run(command());
      expect(out, isA<VisualFailed>());
      expect((out as VisualFailed).error, 'face_blur_failed');
      expect(posted, isFalse);
    });

    test('通信の失敗はそのまま engine の種類で返す', () async {
      final s = VisualSearcher(
        camera: FakeCamera(noiseFrame(640, 480)),
        faces: FakeFaces(),
        post: (body) async => (json: null, error: 'timeout'),
        encode: (input) async => encodeSearchJpeg(input),
      );
      final out = await s.run(command());
      expect((out as VisualFailed).error, 'timeout');
    });

    test('別の検索の答え・形の違う答えは server の失敗にする', () async {
      for (final json in <Object?>[
        unknownJson('s_other'),
        {'bad': true},
      ]) {
        final s = VisualSearcher(
          camera: FakeCamera(noiseFrame(640, 480)),
          faces: FakeFaces(),
          post: (body) async => (json: json, error: null),
          encode: (input) async => encodeSearchJpeg(input),
        );
        final out = await s.run(command());
        expect((out as VisualFailed).error, 'server');
      }
    });

    test('カメラが1枚も返さなければ送らない', () async {
      var posted = false;
      final s = VisualSearcher(
        camera: FakeCamera(null),
        faces: FakeFaces(),
        post: (body) async {
          posted = true;
          return (json: null, error: null);
        },
      );
      expect(await s.run(command()), isA<VisualNoFrame>());
      expect(posted, isFalse);
    });
  });

  group('「検索して」の聞き取り', () {
    test('端末内の認識に対応していないエラーなら、サーバーの認識に切り替えずにやめる', () {
      expect(onDeviceUnsupported('error_language_not_supported'), isTrue);
      expect(onDeviceUnsupported('error_language_unavailable'), isTrue);
      expect(onDeviceUnsupported('error_server_disconnected'), isTrue);
      // 無音などの一時的なエラーは聞き直す
      expect(onDeviceUnsupported('error_no_match'), isFalse);
      expect(onDeviceUnsupported('error_speech_timeout'), isFalse);
    });

    test('合図の言葉を含めば検索する', () {
      expect(containsSearchWord('検索して'), isTrue);
      expect(containsSearchWord('ちょっと 検索して。'), isTrue);
      expect(containsSearchWord('これ調べて'), isTrue);
      expect(containsSearchWord('しらべて'), isTrue);
    });

    test('関係ない言葉では検索しない', () {
      expect(containsSearchWord('こんにちは'), isFalse);
      expect(containsSearchWord('検索'), isFalse);
      expect(containsSearchWord(''), isFalse);
    });
  });
}

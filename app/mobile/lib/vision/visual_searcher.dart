import 'dart:convert';

import 'package:engine/engine.dart' as eng;
import 'package:flutter/foundation.dart';

import '../sources/camera_source.dart';
import 'face_detector.dart';
import 'search_image.dart';
import 'search_progress.dart';

/// B の検索1回の結果。engine に渡す `VisualResult` か `VisualError` のどちらか。
sealed class VisualOutcome {
  const VisualOutcome();
}

final class VisualAnswered extends VisualOutcome {
  const VisualAnswered(this.response);
  final eng.VisualSearchResponse response;
}

final class VisualFailed extends VisualOutcome {
  const VisualFailed(this.error);

  /// `timeout`・`network`・`server`・`face_blur_failed` のどれか（engine の決まり）。
  final String error;
}

/// カメラが1枚も返さなかった（engine の失敗の種類に無いので、EngineRunner が server として返す）。
final class VisualNoFrame extends VisualOutcome {
  const VisualNoFrame();
}

typedef VisualPost = Future<({Object? json, String? error})> Function(
  Map<String, dynamic> body,
);
typedef JpegEncoder = Future<Uint8List> Function(SearchImageInput input);

/// engine の `CaptureAndSearch` を実行する係（合流4）。
///
/// 撮影 → 顔を見つける（ML Kit・端末内）→ 縮小と顔のモザイク → JPEG → `POST /v1/visual-search`。
/// - 顔を見つける処理が失敗したら、**送らない**（顔が写ったまま外に出さないため）
/// - 画像はメモリの中だけで扱い、ファイル・ログに残さない。送ったら参照を捨てる
/// - 送るのは engine が決めたタイル番号・10°単位の方位・候補 ID・エリアだけ（正確な座標は送らない）
class VisualSearcher {
  VisualSearcher({
    required this.camera,
    required this.faces,
    required this.post,
    JpegEncoder? encode,
  }) : _encode = encode ?? _encodeInIsolate;

  final CameraSource camera;
  final FaceFinder faces;
  final VisualPost post;
  final JpegEncoder _encode;

  static Future<Uint8List> _encodeInIsolate(SearchImageInput input) =>
      compute(encodeSearchJpeg, input);

  /// [onPhase] には、撮影・顔ぼかし・送信の各段階に入るたびに知らせる（画面の札用）。
  Future<VisualOutcome> run(
    eng.CaptureAndSearch c, {
    void Function(SearchPhase phase)? onPhase,
  }) async {
    onPhase?.call(SearchPhase.capturing);
    final frame = await camera.captureFrame();
    if (frame == null) return const VisualNoFrame();
    final rotation = landscapeLeftRotation(frame.sensorOrientation);

    final Uint8List jpeg;
    try {
      onPhase?.call(SearchPhase.blurring);
      final found = await faces.find(frame, rotation);
      jpeg = await _encode(
        SearchImageInput(
          nv21: frame.nv21,
          width: frame.width,
          height: frame.height,
          rowStride: frame.yRowStride,
          rotationDeg: rotation,
          faces: found,
        ),
      );
    } catch (_) {
      return const VisualFailed('face_blur_failed');
    }

    final body = eng.VisualSearchRequest(
      searchId: c.searchId,
      tile: c.tile,
      gazeAzDeg: c.gazeAzDeg10,
      candidateIds: c.candidateIds,
      imageJpegBase64: base64Encode(jpeg),
      area: c.area,
    ).toJson();
    onPhase?.call(SearchPhase.sending);
    final res = await post(body);
    if (res.error != null) return VisualFailed(res.error!);
    try {
      final r = eng.VisualSearchResponse.fromJson(
        Map<String, dynamic>.from(res.json! as Map),
      );
      if (r.searchId != c.searchId) return const VisualFailed('server');
      return VisualAnswered(r);
    } catch (_) {
      return const VisualFailed('server');
    }
  }

  Future<void> close() => faces.close();
}

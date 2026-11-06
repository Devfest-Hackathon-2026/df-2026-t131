import 'models.dart';

sealed class Command {
  const Command();
}

final class Speak implements Command {
  final String utteranceId, text;
  final int priority;
  final bool interrupt, pauseMusic;

  /// 話し始めに合図音を鳴らすか。「検索します」の返事は声そのものが合図なので鳴らさない。
  final bool chime;
  const Speak({
    required this.utteranceId,
    required this.text,
    required this.priority,
    required this.interrupt,
    required this.pauseMusic,
    this.chime = true,
  });
}

final class FetchTiles implements Command {
  final List<TileId> tiles;
  FetchTiles({required List<TileId> tiles}) : tiles = List.unmodifiable(tiles);
}

final class CaptureAndSearch implements Command {
  final String searchId;
  final TileId tile;
  final int gazeAzDeg10;
  final List<String> candidateIds;
  final AreaContext? area;
  CaptureAndSearch({
    required this.searchId,
    required this.tile,
    required this.gazeAzDeg10,
    required List<String> candidateIds,
    this.area,
  }) : candidateIds = List.unmodifiable(candidateIds);
}

final class LogDecision implements Command {
  final Decision decision;
  const LogDecision({required this.decision});
}

/// Bの送信JSON（`POST /v1/visual-search`）を、engineが出した指示と画像から作る。
///
/// 画像はmobileが顔をぼかしてJPEGにしたもの。engineは画像を保持・記録せず、
/// この関数も受け取った値をJSONへ詰めるだけにする。形の検査は
/// `VisualSearchRequest` の変換と同じものを通す。
Map<String, dynamic> visualSearchRequestToJson(
  CaptureAndSearch command,
  String imageJpegBase64,
) => VisualSearchRequest(
  searchId: command.searchId,
  tile: command.tile,
  gazeAzDeg: command.gazeAzDeg10,
  candidateIds: command.candidateIds,
  imageJpegBase64: imageJpegBase64,
  area: command.area,
).toJson();

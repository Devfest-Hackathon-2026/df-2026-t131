import 'models.dart';

sealed class Command {
  const Command();
}

final class Speak implements Command {
  final String utteranceId, text;
  final int priority;
  final bool interrupt, pauseMusic;
  const Speak({
    required this.utteranceId,
    required this.text,
    required this.priority,
    required this.interrupt,
    required this.pauseMusic,
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

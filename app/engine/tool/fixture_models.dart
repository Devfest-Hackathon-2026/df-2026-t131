import 'dart:convert';
import 'dart:io';

import 'package:engine/engine.dart';

/// テストと検証ツールは、schema/examplesの原本を直接読む。
Directory findRepositoryRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File.fromUri(directory.uri.resolve('schema/eventlog.schema.json'))
        .existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path)
      throw StateError('schemaを含むリポジトリが見つかりません');
    directory = parent;
  }
}

Map<String, dynamic> readExample(String name) => jsonDecode(
  File.fromUri(findRepositoryRoot().uri.resolve('schema/examples/$name'))
      .readAsStringSync(),
) as Map<String, dynamic>;

/// engineがモデルを持たない見本。data→api、alert-job→mobileの形なので往復テストの対象外。
/// FCMの警報はmobileが `AlertReceived` に直してから渡すため、engineは `alert` イベントだけを読む。
/// ここにも `roundtripExample` にもない見本が増えたら、テストを失敗させて気づけるようにする。
const examplesOutsideEngine = <String>{
  'timetable_sample.json',
  'events_sample.json',
  'fcm_alert_data.json',
  // 横断歩道はタイル応答の crossings として読む。単独の見本（osm/crossings.json の形）は対象外
  'crossings_sample.json',
};

/// 入力イベントのログ（JSONL）を新しいEngineに流し、出た判断ログを1行ずつJSONにする。
List<String> replayDecisions(Iterable<String> lines) {
  final engine = Engine();
  final rows = <String>[];
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final event = eventFromJson(jsonDecode(line) as Map<String, dynamic>);
    for (final command in engine.handle(event)) {
      if (command is LogDecision) {
        rows.add(jsonEncode(command.decision.toJson()));
      }
    }
  }
  return rows;
}

/// 判断ログのファイル内容。判断が1件もなければ空のファイルにする。
String decisionsFileContent(List<String> rows) =>
    rows.isEmpty ? '' : '${rows.join('\n')}\n';

/// 歩行ログ（見本と実機のログ）と、その判断ログの書き出し先の組。
Map<File, File> decisionFixtureTargets() {
  final root = findRepositoryRoot().uri;
  final engineDir = root.resolve('app/engine/');
  final decisions = engineDir.resolve('test/fixtures/decisions/');
  final walksDir = Directory.fromUri(engineDir.resolve('test/fixtures/walks/'));
  final walks = <File>[
    File.fromUri(root.resolve('schema/examples/walk_short.jsonl')),
    if (walksDir.existsSync())
      ...walksDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.jsonl'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)),
  ];
  return {
    for (final walk in walks)
      walk: File.fromUri(decisions.resolve(walk.uri.pathSegments.last)),
  };
}

Map<String, dynamic> roundtripExample(String name, Map<String, dynamic> json) =>
    switch (name) {
      'landmarks_sample.json' => LandmarksFile.fromJson(json).toJson(),
      'tile_response.json' => TileResponse.fromJson(json).toJson(),
      'visual_search_request.json' => VisualSearchRequest.fromJson(
        json,
      ).toJson(),
      'visual_search_response_matched.json' ||
      'visual_search_response_unlisted.json' ||
      'visual_search_response_unknown.json' ||
      'visual_search_response_named.json' ||
      'visual_search_response_matched_feature.json' =>
        VisualSearchResponse.fromJson(json).toJson(),
      _ => throw ArgumentError('未対応の見本: $name'),
    };

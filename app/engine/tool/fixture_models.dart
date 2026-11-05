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
      'visual_search_response_named.json' => VisualSearchResponse.fromJson(
        json,
      ).toJson(),
      _ => throw ArgumentError('未対応の見本: $name'),
    };

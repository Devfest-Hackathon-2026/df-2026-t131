import 'dart:convert';
import 'dart:io';

import 'package:viewer/src/demo_map.dart';

/// cloud/data の元データから、viewer が描く地図 assets/map.json を作る。
///
/// 使い方（app/viewer で）：dart run tool/build_map.dart
/// ランドマークを足したり直したりしたら、作り直して一緒にコミットする（古いとテストが落ちる）。
void main() {
  File('assets/map.json')
      .writeAsStringSync(encodeDemoMap(loadDemoMapFromRepo()));
  stdout.writeln('assets/map.json を作りました');
}

/// リポジトリの cloud/data を読む（app/viewer から見た相対パス）。
DemoMap loadDemoMapFromRepo({String root = '../..'}) {
  Map<String, dynamic> read(String path) =>
      jsonDecode(File('$root/$path').readAsStringSync())
          as Map<String, dynamic>;
  final dir = Directory('$root/cloud/data/manual/landmarks');
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final events = File('$root/cloud/data/manual/events.json');
  return DemoMap.fromSources(
    landmarkFiles: [
      for (final f in files)
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    ],
    crossingsFile: read('cloud/data/osm/crossings.json'),
    eventsFile: events.existsSync()
        ? read('cloud/data/manual/events.json')
        : null,
  );
}

String encodeDemoMap(DemoMap map) =>
    '${const JsonEncoder.withIndent('  ').convert(map.toJson())}\n';

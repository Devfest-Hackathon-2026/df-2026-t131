import 'dart:convert';
import 'dart:io';

import 'package:engine/engine.dart';

import 'fixture_models.dart';

/// 変換後のJSONを外部のJSON Schema検証にも渡せるように書き出す。
void main() {
  final examples = Directory.fromUri(
    findRepositoryRoot().uri.resolve('schema/examples/'),
  );
  final output = Directory('.dart_tool/contract-fixtures')
    ..createSync(recursive: true);
  for (final input in examples.listSync().whereType<File>()) {
    final name = input.uri.pathSegments.last;
    final target = File.fromUri(output.absolute.uri.resolve(name));
    if (name.endsWith('.json')) {
      final json = jsonDecode(input.readAsStringSync()) as Map<String, dynamic>;
      target.writeAsStringSync(jsonEncode(roundtripExample(name, json)));
    } else if (name.endsWith('.jsonl')) {
      final rows = input
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .map((line) {
            final json = jsonDecode(line) as Map<String, dynamic>;
            return jsonEncode(
              name == 'walk_short.jsonl'
                  ? eventToJson(eventFromJson(json))
                  : Decision.fromJson(json).toJson(),
            );
          });
      target.writeAsStringSync('${rows.join('\n')}\n');
    }
  }
  stdout.writeln('変換後の見本を${output.path}へ出力しました');
}

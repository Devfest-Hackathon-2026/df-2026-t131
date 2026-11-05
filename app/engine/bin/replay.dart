import 'dart:convert';
import 'dart:io';

import 'package:engine/engine.dart';

/// 記録済みの入力イベントを順番に再生し、判断ログだけを標準出力する。
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('使い方: dart run bin/replay.dart <歩行ログ.jsonl>');
    exitCode = 64;
    return;
  }
  final engine = Engine();
  var lineNumber = 0;
  try {
    final rows = File(args.single)
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in rows) {
      lineNumber++;
      if (line.trim().isEmpty) continue;
      final event = eventFromJson(jsonDecode(line) as Map<String, dynamic>);
      for (final command in engine.handle(event)) {
        if (command is LogDecision)
          stdout.writeln(jsonEncode(command.decision.toJson()));
      }
    }
  } on Object catch (error) {
    stderr.writeln('$lineNumber行目の再生に失敗しました: ${error.runtimeType}');
    exitCode = 1;
  }
}

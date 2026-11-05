import 'dart:io';

import 'fixture_models.dart';

/// 歩行ログをEngineで再生し、判断ログを `test/fixtures/decisions/` へ書き出す。
///
/// 対象は `schema/examples/walk_short.jsonl` と `test/fixtures/walks/*.jsonl`。
/// 書き出したファイルはコミットし、CIの `python schema/validate.py` が形と理由コードを検証する。
/// Engineの判断を変えたら、このツールを実行して書き出し直す（テストが古いままのファイルを検出する）。
void main() {
  for (final MapEntry(key: walk, value: target)
      in decisionFixtureTargets().entries) {
    final rows = replayDecisions(walk.readAsLinesSync());
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(decisionsFileContent(rows));
    stdout.writeln('${target.uri.pathSegments.last}: 判断${rows.length}件');
  }
}

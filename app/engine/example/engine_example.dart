import 'package:engine/engine.dart';

void main() {
  final engine = Engine();
  const input = TtsFinished(tMs: 1000, utteranceId: 'u_000001');
  final commands = engine.handle(input);
  print('入力: ${eventToJson(input)}');
  print('指示件数: ${commands.length}（組み込み用初版は0件）');
}

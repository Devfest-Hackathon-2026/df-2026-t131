import 'commands.dart';
import 'constants.dart';
import 'events.dart';

/// 組み込み用の初版。A/Bの判断処理は次の段階で実装する。
class Engine {
  Engine({EngineConfig config = const EngineConfig()});

  /// 現段階では入力を受け取り、指示を返さない。
  List<Command> handle(EngineEvent event) => const <Command>[];
}

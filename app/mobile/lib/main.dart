import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app/app_services.dart';
import 'startup/permissions.dart';
import 'ui/home_shell.dart';
import 'ui/layout.dart';
import 'ui/licenses.dart';
import 'ui/style.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 横持ち固定（カメラのプレビューの向きを安定させる）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
  ]);
  // 没入モード（ステータスバーを隠す）
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // 歩行中は画面を消さない
  await WakelockPlus.enable();
  // pub.dev 以外のライセンスと出典を、ライセンスの一覧に足す
  registerExtraLicenses();
  runApp(const MobileApp());
}

Widget _defaultReady(BuildContext context) =>
    const HomeShell(createServices: AppServices.phoneDemo);

class MobileApp extends StatelessWidget {
  const MobileApp({
    super.key,
    this.requestPermissions = requestAll,
    this.readyBuilder = _defaultReady,
  });

  final Future<List<RequiredPermission>> Function() requestPermissions;

  /// 権限がそろったあとに出す画面。
  final WidgetBuilder readyBuilder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mobile',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      builder: clampTextScale,
      home: PermissionGate(
        requestPermissions: requestPermissions,
        readyBuilder: readyBuilder,
      ),
    );
  }
}

/// 権限がそろうまで先に進まない画面。拒否されたら理由を出して止まる。
class PermissionGate extends StatefulWidget {
  const PermissionGate({
    super.key,
    required this.requestPermissions,
    required this.readyBuilder,
  });

  final Future<List<RequiredPermission>> Function() requestPermissions;
  final WidgetBuilder readyBuilder;

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  late Future<List<RequiredPermission>> _result;

  @override
  void initState() {
    super.initState();
    _result = widget.requestPermissions();
  }

  void _retry() {
    setState(() {
      _result = widget.requestPermissions();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<List<RequiredPermission>>(
        future: _result,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: Text('権限を確認しています…'));
          }
          final denied = snapshot.data!;
          if (denied.isEmpty) {
            return widget.readyBuilder(context);
          }
          return _DeniedView(denied: denied, onRetry: _retry);
        },
      ),
    );
  }
}

class _DeniedView extends StatelessWidget {
  const _DeniedView({required this.denied, required this.onRetry});

  final List<RequiredPermission> denied;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('次の権限が必要です', style: TextStyle(fontSize: 24)),
          const SizedBox(height: 12),
          for (final p in denied) Text('・${p.label}：${p.reason}'),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('もう一度確認する')),
        ],
      ),
    );
  }
}

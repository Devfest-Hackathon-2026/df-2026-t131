import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_services.dart';
import '../app/session_controller.dart';
import '../core/sensor_ticker.dart';
import 'glass_view_screen.dart';
import 'start_screen.dart';
import 'summary_screen.dart';

/// 権限がそろった後の土台。部品を1回だけ組み立て、セッションの状態で画面を切り替える。
/// 開始前 → グラス視点（記録中）→ 終了まとめ → 開始前。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.createServices});

  final AppServices Function() createServices;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  late final AppServices _services;
  StreamSubscription<SensorSnapshot>? _sub;
  String? _cameraError;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _services = widget.createServices();
    _services.session.addListener(_rebuild);
    // 1秒ごとの値で画面を更新する（記録していないときも）
    _sub = _services.ticker.snapshots.listen((_) => _rebuild());
    _boot();
  }

  Future<void> _boot() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await _services.start();
    if (mounted) setState(() => _ready = true);
    await _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      await _services.camera.start();
      _cameraError = null;
    } catch (e) {
      _cameraError = 'カメラを開けませんでした';
    }
    _rebuild();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // 裏に回った瞬間に書き出しておく（OS に終了させられても失わない）
      _services.session.flush();
      _services.camera.stop();
      // 画面オフ・ポケットの中：GPS で分かること（A・警報）だけ声で届ける
      if (state != AppLifecycleState.inactive) _services.setBackground(true);
    } else if (state == AppLifecycleState.resumed) {
      _services.setBackground(false);
      // 戻ったときに全画面（ステータスバーを隠す）をかけ直す
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (_services.camera.controller == null) _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _services.session.removeListener(_rebuild);
    _services.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final session = _services.session;
    return switch (session.phase) {
      SessionPhase.idle => StartScreen(
        services: _services,
        cameraError: _cameraError,
      ),
      SessionPhase.running => GlassViewScreen(
        services: _services,
        cameraError: _cameraError,
      ),
      SessionPhase.finished => SummaryScreen(
        summary: session.summary!,
        onDone: session.reset,
      ),
    };
  }
}

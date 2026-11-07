import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../sources/camera_source.dart';
import 'style.dart';

/// カメラ映像を画面いっぱいに出す（はみ出た分は切る）。
class CameraView extends StatelessWidget {
  const CameraView({super.key, required this.camera, this.error});

  final CameraSource camera;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = camera.controller;
    if (c == null || !c.value.isInitialized) {
      return ColoredBox(
        color: const Color(0xFF3C4043),
        child: Center(
          child: Text(
            error ?? 'カメラを準備しています…',
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ),
      );
    }
    final size = c.value.previewSize;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          // previewSize はセンサーの向き（横長）で届く。横持ち固定なのでそのまま使う
          width: size?.width ?? 1280,
          height: size?.height ?? 720,
          child: CameraPreview(c),
        ),
      ),
    );
  }
}

/// 「スマホで代用」の常時表示（デモ動画で必ず明示する決まり）。
class SubstituteBanner extends StatelessWidget {
  const SubstituteBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return const StatusChip(
      icon: Icons.smartphone,
      label: 'スマートグラスの代わりにスマホで撮影しています',
      color: AppColors.primary,
    );
  }
}

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../dev/fake_gps_panel.dart';
import 'camera_view.dart';
import 'alert_banner.dart';
import 'caption.dart';
import 'collapsible_sheet.dart';
import 'layout.dart';
import 'readiness.dart';
import 'settings_screen.dart';
import 'style.dart';

/// 開始前の画面。カメラ映像を全面に、左に地図アプリのような白いシートを浮かべる。
/// シートには、準備の確認・よく変える設定の丸ボタン・「計測開始」を上から並べる。
/// 行き先は設定しない（歩いている周りを案内するアプリなので、目的地の概念がない）。
class StartScreen extends StatefulWidget {
  const StartScreen({super.key, required this.services, this.cameraError});

  final AppServices services;
  final String? cameraError;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  /// シートのたたみ具合（0 = 開いている、1 = たたんでいる）。
  final _progress = ValueNotifier<double>(0);
  final _sheet = GlobalKey<CollapsibleSheetState>();

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  AppServices get services => widget.services;
  String? get cameraError => widget.cameraError;

  void _openSettings(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SettingsScreen(services: services)),
  );

  @override
  Widget build(BuildContext context) {
    final t = services.ticker;
    final settings = services.settings.value;
    final items = buildReadiness(
      location: t.location,
      gaze: t.gaze,
      cameraReady: services.camera.latestFrame() != null,
      audio: t.audio,
      settings: settings,
      server: services.serverStatus.value,
      serverConfigured: services.api.hasUrl,
    );
    final ready = canStart(location: t.location, gaze: t.gaze);
    final l = Layout.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CameraView(camera: services.camera, error: cameraError),
          ),
          Positioned(
            right: l.margin,
            top: l.margin,
            // シートと重ならない幅に収め、入りきらなければ文字を縮める
            width: l.size.width - l.sheetWidth - l.margin * 3,
            child: Align(
              alignment: Alignment.topRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SubstituteBanner(),
                    const SizedBox(width: 8),
                    // 設定はシートをたたんでいても開ける
                    RoundIconButton(
                      icon: Icons.settings_outlined,
                      tooltip: '設定',
                      onPressed: () => _openSettings(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 受け取った気象警報（右上の札の下）
          Positioned(
            right: l.margin,
            top: l.margin + 56,
            width: l.size.width - l.sheetWidth - l.margin * 3,
            child: Align(
              alignment: Alignment.topRight,
              child: AlertBanner(
                alert: services.activeAlert,
                onClose: services.dismissAlert,
              ),
            ),
          ),
          // 開発者モード：フェイク GPS の操作盤（使っている間だけ、右の中ほど）
          if (services.fakeGps case final gps?)
            Positioned(
              right: l.margin,
              top: 0,
              bottom: 0,
              child: Center(child: FakeGpsPanel(controller: gps)),
            ),
          // 下：字幕（試し聞きなど、話している間だけ）
          Positioned(
            left: l.sheetWidth + l.margin * 2,
            right: l.margin,
            bottom: l.margin,
            child: Center(
              child: CaptionBar(
                subtitle: services.speaker.subtitle,
                spoken: services.speaker.spokenChars,
              ),
            ),
          ),
          // たたんだとき：左下に「計測開始」だけの小さな札（シートが引っ込むにつれて現れる）
          Positioned(
            left: l.margin + 34,
            bottom: l.margin,
            child: AppearWhenCollapsed(
              progress: _progress,
              child: MiniPill(
                onExpand: () => _sheet.currentState?.expand(),
                children: [
                  _ReadyDot(ready: ready),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 40,
                    child: FilledButton.icon(
                      onPressed: ready ? services.session.start : null,
                      icon: const Icon(Icons.navigation, size: 20),
                      label: const Text('計測開始'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 左のシート：右中央のバーを左へ引くとたたむ
          Positioned(
            left: l.margin,
            top: l.margin,
            bottom: l.margin,
            width: l.sheetWidth,
            child: CollapsibleSheet(
              key: _sheet,
              axis: Axis.horizontal,
              progress: _progress,
              padding: EdgeInsets.fromLTRB(
                l.compact ? 14 : 20,
                l.compact ? 10 : 16,
                0,
                l.compact ? 10 : 16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 中身は収まらなければスクロール、「計測開始」は常に下に見せる
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'まちトーク',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            ready ? '準備ができました（押すまで記録しません）' : '位置と向きを確かめています…',
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppColors.subtext,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final i in items) _ReadinessRow(item: i),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              QuickAction(
                                icon: settings.visualSearchEnabled
                                    ? Icons.image_search
                                    : Icons.hide_image,
                                label: settings.visualSearchEnabled
                                    ? '画像検索 オン'
                                    : '画像検索 オフ',
                                active: settings.visualSearchEnabled,
                                onTap: () => services.updateSettings(
                                  settings.copyWith(
                                    visualSearchEnabled:
                                        !settings.visualSearchEnabled,
                                  ),
                                ),
                              ),
                              QuickAction(
                                icon: Icons.record_voice_over,
                                label: settings.voice.label,
                                onTap: () {
                                  final next = settings.voice.next;
                                  services.updateSettings(
                                    settings.copyWith(voice: next),
                                  );
                                  services.previewVoice(next);
                                },
                              ),
                              QuickAction(
                                icon: Icons.tune,
                                label: '設定',
                                active: false,
                                onTap: () => _openSettings(context),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: l.buttonHeight,
                    child: FilledButton.icon(
                      onPressed: ready ? services.session.start : null,
                      icon: const Icon(Icons.navigation, size: 24),
                      label: const Text('計測開始', style: TextStyle(fontSize: 20)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 準備の確認1行：色付きの丸アイコン・項目名・状態。
class _ReadinessRow extends StatelessWidget {
  const _ReadinessRow({required this.item});

  final ReadinessItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item.level) {
      CheckLevel.ok => (Icons.check, AppColors.ok),
      CheckLevel.warn => (Icons.priority_high, AppColors.warn),
      CheckLevel.waiting => (Icons.more_horiz, AppColors.subtext),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 72,
            child: Text(
              item.label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              item.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: AppColors.subtext),
            ),
          ),
        ],
      ),
    );
  }
}

/// 準備ができているかの小さな印（たたんだときに出す）。
class _ReadyDot extends StatelessWidget {
  const _ReadyDot({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        ready ? Icons.check_circle : Icons.more_horiz,
        size: 18,
        color: ready ? AppColors.ok : AppColors.subtext,
      ),
      const SizedBox(width: 4),
      Text(
        ready ? '準備OK' : '準備中',
        style: const TextStyle(fontSize: 14, color: AppColors.text),
      ),
    ],
  );
}

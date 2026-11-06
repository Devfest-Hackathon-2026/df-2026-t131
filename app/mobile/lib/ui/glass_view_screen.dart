import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/app_settings.dart';
import '../app/session_controller.dart';
import '../core/sensor_ticker.dart';
import '../sources/location_source.dart';
import '../sources/activity_source.dart';
import '../dev/fake_gps_panel.dart';
import 'camera_view.dart';
import 'alert_banner.dart';
import 'caption.dart';
import 'settings_screen.dart';
import 'collapsible_sheet.dart';
import 'layout.dart';
import 'glass_overlay.dart';
import 'heading_tape.dart';
import 'style.dart';

/// 記録中の画面（グラス視点）。地図アプリの案内中の画面のように、
/// 上に「今話していること」のカード、下に時間・距離と「終了」の白い帯を置き、映像を広く見せる。
class GlassViewScreen extends StatefulWidget {
  const GlassViewScreen({super.key, required this.services, this.cameraError});

  final AppServices services;
  final String? cameraError;

  @override
  State<GlassViewScreen> createState() => _GlassViewScreenState();
}

class _GlassViewScreenState extends State<GlassViewScreen> {
  /// 下のシートのたたみ具合（0 = 開いている、1 = たたんでいる）。指に合わせて変わる。
  final _progress = ValueNotifier<double>(0);
  final _sheet = GlobalKey<CollapsibleSheetState>();

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  AppServices get services => widget.services;
  String? get cameraError => widget.cameraError;

  /// 設定は記録中でも開ける（記録は裏で続く）。
  void _openSettings(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SettingsScreen(services: services)),
  );

  void _toggleVisualSearch(AppSettings s) => services.updateSettings(
    s.copyWith(visualSearchEnabled: !s.visualSearchEnabled),
  );

  void _requestSearch(BuildContext context) {
    if (services.requestSearch()) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('計測中でないので検索できません')));
  }

  void _toggleVoice(AppSettings s) {
    final next = s.voice.next;
    services.updateSettings(s.copyWith(voice: next));
    services.previewVoice(next);
  }

  Future<void> _confirmStop(BuildContext context) async {
    final session = services.session;
    if (!services.policy.confirmBeforeStop) {
      await session.stop();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('計測を終了しますか？'),
        content: Text(
          '${formatDuration(session.elapsed)}・${formatDistance(session.distanceM)} を記録しました。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('続ける'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('終了する'),
          ),
        ],
      ),
    );
    if (ok == true) await session.stop();
  }

  @override
  Widget build(BuildContext context) {
    final t = services.ticker;
    final session = services.session;
    final settings = services.settings.value;
    final loc = t.location;
    final overlay = services.overlay.value;
    final l = Layout.of(context);
    final gap = l.compact ? 16.0 : 28.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CameraView(camera: services.camera, error: cameraError),
          ),
          // 左上：今話していること・今の判断（地図アプリの案内カードの位置）
          // たたむと消える（話している間の字幕だけは残す）
          Positioned(
            left: l.margin,
            top: l.margin,
            width: l.nowCardWidth,
            child: overlay.subtitle != null
                ? _NowCard(
                    overlay: overlay,
                    spoken: services.speaker.spokenChars,
                  )
                : HideWhenCollapsed(
                    progress: _progress,
                    child: _NowCard(
                      overlay: overlay,
                      spoken: services.speaker.spokenChars,
                    ),
                  ),
          ),
          // 右上：代用の明示と状態
          Positioned(
            right: l.margin,
            top: l.margin,
            // 左上のカードと重ならない幅に収め、入りきらなければ縮める
            width: l.size.width - l.nowCardWidth - l.margin * 3,
            child: Align(
              alignment: Alignment.topRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topRight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SubstituteBanner(),
                        const SizedBox(width: 8),
                        // B：今見ているものをその場で調べる（撮るかは engine が決める）
                        if (settings.visualSearchEnabled) ...[
                          RoundIconButton(
                            icon: Icons.image_search,
                            tooltip: '今見ているものを検索',
                            onPressed: () => _requestSearch(context),
                          ),
                          const SizedBox(width: 8),
                        ],
                        // 設定はたたんでいても開ける
                        RoundIconButton(
                          icon: Icons.settings_outlined,
                          tooltip: '設定',
                          onPressed: () => _openSettings(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    HideWhenCollapsed(
                      progress: _progress,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _RecDot(),
                          const SizedBox(width: 8),
                          StatusChip(
                            icon: Icons.my_location,
                            label: loc == null
                                ? '-'
                                : '±${loc.accM.toStringAsFixed(0)} m',
                            color: loc != null && loc.accM <= 20
                                ? AppColors.ok
                                : AppColors.warn,
                          ),
                          const SizedBox(width: 8),
                          // 押すとその場で切り替わる（記録は止めない）
                          StatusChip(
                            icon: settings.visualSearchEnabled
                                ? Icons.image_search
                                : Icons.hide_image,
                            label: settings.visualSearchEnabled
                                ? '画像検索 オン'
                                : '画像検索 オフ',
                            color: settings.visualSearchEnabled
                                ? AppColors.primary
                                : AppColors.subtext,
                            tooltip: '画像検索を切り替える',
                            onTap: () => _toggleVisualSearch(settings),
                          ),
                          if (settings.visualSearchEnabled &&
                              services.voiceCommands != null) ...[
                            const SizedBox(width: 8),
                            ValueListenableBuilder<String>(
                              valueListenable: services.voiceCommands!.status,
                              builder: (context, v, _) => StatusChip(
                                icon: Icons.mic_none,
                                label: '「検索して」$v',
                                color: v.startsWith('聞いています')
                                    ? AppColors.primary
                                    : AppColors.subtext,
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
                          StatusChip(
                            icon: Icons.record_voice_over,
                            label: settings.voice.label,
                            color: AppColors.primary,
                            tooltip: '声を切り替える',
                            onTap: () => _toggleVoice(settings),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 受け取った気象警報（右上の札の下。たたんでいても出す）
          Positioned(
            right: l.margin,
            top: l.margin + (l.compact ? 96 : 104),
            width: l.size.width - l.nowCardWidth - l.margin * 3,
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
          // シートの上：方位テープと A の候補（約10Hzでなめらかに動く）
          Positioned(
            left: 0,
            right: 0,
            bottom: _collapsedTapeBottom,
            // シートがたたまれるのに合わせて下へ動く
            child: ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (context, p, child) => Transform.translate(
                offset: Offset(
                  0,
                  -(1 - p) * ((l.compact ? 86 : 108) - _collapsedTapeBottom),
                ),
                child: child,
              ),
              child: Center(
                child: SizedBox(
                  width: l.tapeWidth,
                  child: LiveHeadingTape(
                    gaze: t.gazeLive,
                    candidates: overlay.candidates,
                  ),
                ),
              ),
            ),
          ),
          // 下：地図アプリの案内中のシート。上中央のバーを下へ引くとたたむ
          Positioned(
            left: l.margin,
            right: l.margin,
            bottom: 0,
            child: CollapsibleSheet(
              key: _sheet,
              progress: _progress,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              padding: EdgeInsets.fromLTRB(
                l.compact ? 16 : 24,
                0,
                12,
                l.compact ? 8 : 14,
              ),
              child: _sheetBody(
                context,
                l,
                gap,
                session,
                loc,
                settings,
                overlay,
                t,
              ),
            ),
          ),
          // たたんだとき：左下に時間と距離、右下に終了（シートが引っ込むにつれて現れる）
          Positioned(
            left: l.margin,
            bottom: _miniBottom,
            child: AppearWhenCollapsed(
              progress: _progress,
              child: MiniPill(
                onExpand: () => _sheet.currentState?.expand(),
                children: [
                  const Icon(Icons.circle, size: 10, color: AppColors.danger),
                  const SizedBox(width: 8),
                  Text(
                    '${formatDuration(session.elapsed)}・${formatDistance(session.distanceM)}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: l.margin,
            bottom: _miniBottom,
            child: AppearWhenCollapsed(
              progress: _progress,
              child: FloatingActionButton.small(
                heroTag: null,
                tooltip: '終了',
                backgroundColor: AppColors.danger,
                foregroundColor: Colors.white,
                onPressed: () => _confirmStop(context),
                child: const Icon(Icons.close),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// たたんだときの小さな札の高さ（下に残るバーの帯の上）。
  static const double _miniBottom = 34;

  /// たたんだときの方位テープの位置。
  static const double _collapsedTapeBottom = 82;

  Widget _sheetBody(
    BuildContext context,
    Layout l,
    double gap,
    SessionController session,
    LocationFix? loc,
    AppSettings settings,
    GlassOverlay overlay,
    SensorTicker t,
  ) {
    return Row(
      children: [
        StatBlock(
          value: formatDuration(session.elapsed),
          label: '経過',
          color: AppColors.ok,
        ),
        SizedBox(width: gap),
        StatBlock(value: formatDistance(session.distanceM), label: '距離'),
        // 小さい画面では速度をエリアの行に入れる
        if (!l.compact) ...[
          SizedBox(width: gap),
          StatBlock(
            value: loc?.speedMps?.toStringAsFixed(1) ?? '-',
            label: 'm/s',
          ),
        ],
        SizedBox(width: gap),
        Container(width: 1, height: 44, color: AppColors.divider),
        SizedBox(width: gap * 0.7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _InfoLine(
                icon: Icons.place_outlined,
                text:
                    '${overlay.areaName ?? 'エリアの外'}'
                    '${l.compact ? '・${loc?.speedMps?.toStringAsFixed(1) ?? '-'} m/s' : ''}',
              ),
              _InfoLine(
                icon: _activityIcon(t.activity),
                text: _bLine(settings.visualSearchEnabled, overlay),
              ),
            ],
          ),
        ),
        SizedBox(
          height: l.buttonHeight,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => _confirmStop(context),
            icon: const Icon(Icons.close),
            label: const Text('終了'),
          ),
        ),
      ],
    );
  }

  static String _bLine(bool enabled, GlassOverlay o) {
    if (!enabled) return '画像検索オフ（画像は送りません）';
    final next = o.nextSearchIn;
    final head = next == null ? '画像検索 待機中' : '次の画像検索まで ${next.inSeconds} 秒';
    return o.lastSearch == null ? head : '$head・前回 ${o.lastSearch}';
  }

  static IconData _activityIcon(ActivityKind a) => switch (a) {
    ActivityKind.walking => Icons.directions_walk,
    ActivityKind.still => Icons.accessibility_new,
    ActivityKind.inVehicle => Icons.directions_bus,
    ActivityKind.unknown => Icons.help_outline,
  };
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      children: [
        Icon(icon, size: 18, color: AppColors.subtext),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15),
          ),
        ),
      ],
    ),
  );
}

/// 上のカード。話しているときは緑のカードに字幕を大きく（地図アプリの案内カードの位置）。
/// 黙っているときは白いカードに今の判断と理由を小さく出す。
class _NowCard extends StatelessWidget {
  const _NowCard({required this.overlay, required this.spoken});

  final GlassOverlay overlay;
  final ValueListenable<int> spoken;

  @override
  Widget build(BuildContext context) {
    final subtitle = overlay.subtitle;
    if (subtitle != null) {
      return FloatingCard(
        color: const Color(0xFF0B6E3B),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            const Icon(Icons.volume_up, color: Colors.white, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: CaptionText(
                text: subtitle,
                spoken: spoken,
                fontSize: 22,
                maxLines: 2,
              ),
            ),
          ],
        ),
      );
    }
    final decision = overlay.decision;
    return FloatingCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      radius: 24,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            decision == null
                ? Icons.hourglass_empty
                : Icons.psychology_outlined,
            size: 20,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              decision == null
                  ? '判断エンジン接続待ち（記録は続いています）'
                  : '${overlay.reason ?? decision}（$decision）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

/// 記録中の赤い点（ゆっくり点滅）。
class _RecDot extends StatefulWidget {
  const _RecDot();

  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.all(Radius.circular(20)),
        boxShadow: softShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
            child: const Icon(Icons.circle, size: 12, color: AppColors.danger),
          ),
          const SizedBox(width: 6),
          const Text(
            '記録中',
            style: TextStyle(fontSize: 15, color: AppColors.text),
          ),
        ],
      ),
    );
  }
}

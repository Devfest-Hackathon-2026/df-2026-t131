import 'package:flutter/material.dart';

import '../ui/style.dart';
import 'fake_gps.dart';

/// フェイク GPS を使っている間だけ画面に出す操作盤（再生・倍速・最初から・位置の移動）。
/// 本物の歩行と見間違えないよう、オレンジの枠と「フェイクGPS」の札を付ける。
class FakeGpsPanel extends StatelessWidget {
  const FakeGpsPanel({
    super.key,
    required this.controller,
    this.width = 260,
    this.onDrag,
    this.minimized = false,
    this.onToggleMinimized,
  });

  final FakeGpsController controller;
  final double width;

  /// 札の左のつまみを引いたとき（操作盤を動かす）。null ならつまみを出さない。
  final GestureDragUpdateCallback? onDrag;

  /// たたんで札の行だけにしているか。
  final bool minimized;

  /// たたむ・広げるのボタン。null ならボタンを出さない。
  final VoidCallback? onToggleMinimized;

  static const orange = Color(0xFFE8710A);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.enabled) return const SizedBox.shrink();
        final c = controller;
        final track = c.track;
        return Container(
          width: width,
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: orange, width: 2),
            boxShadow: softShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (onDrag != null)
                    // つまみの目印（引くのは操作盤のどこでもよい）
                    const Padding(
                      key: ValueKey('fake_gps_drag'),
                      padding: EdgeInsets.fromLTRB(0, 6, 6, 6),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 22,
                        color: AppColors.subtext,
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: orange,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'フェイクGPS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.subtext,
                      ),
                    ),
                  ),
                  if (onToggleMinimized != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: minimized ? '広げる' : 'たたむ',
                      icon: Icon(
                        minimized ? Icons.unfold_more : Icons.unfold_less,
                        size: 20,
                      ),
                      onPressed: onToggleMinimized,
                    ),
                ],
              ),
              if (!minimized) ...[
                Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: c.playing ? '止める' : '歩く',
                      icon: Icon(
                        c.playing ? Icons.pause_circle : Icons.play_circle,
                        color: orange,
                        size: 34,
                      ),
                      onPressed: c.togglePlay,
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '最初から',
                      icon: const Icon(Icons.replay),
                      onPressed: c.restart,
                    ),
                    TextButton(
                      onPressed: c.cycleSpeed,
                      child: Text(
                        '×${c.speed}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // 狭い画面では縮めて、はみ出さないようにする
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          '${c.distanceM.toStringAsFixed(0)} / '
                          '${track.lengthM.toStringAsFixed(0)} m',
                          style: const TextStyle(
                            fontSize: 14,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
                SizedBox(
                  height: 28,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: orange,
                      thumbColor: orange,
                      overlayShape: SliderComponentShape.noOverlay,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                    ),
                    child: Slider(
                      value: c.t.clamp(0, track.durationS),
                      max: track.durationS <= 0 ? 1 : track.durationS,
                      onChanged: c.seek,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 画面の上で動かせるフェイク GPS の操作盤（YouTube のミニプレイヤーのような動き）。
///
/// - 操作盤のどこを引いても動く（ボタンを押す・スライダーを動かすのはそのまま使える）
/// - 指を離すと、投げた勢いの先に近い画面の四隅へ、すっと吸い付く
/// - たたむと札の行だけになる
/// 画面全体に重ねて置く（操作盤の外の場所は、下の画面の操作をそのまま通す）。
class MovableFakeGpsPanel extends StatefulWidget {
  const MovableFakeGpsPanel({
    super.key,
    required this.controller,
    required this.margin,
    this.initialTop,
  });

  final FakeGpsController controller;

  /// 画面の端から空ける幅。
  final double margin;

  /// 最初の上からの位置。null なら縦の真ん中。
  final double? initialTop;

  @override
  State<MovableFakeGpsPanel> createState() => _MovableFakeGpsPanelState();
}

class _MovableFakeGpsPanelState extends State<MovableFakeGpsPanel> {
  /// 左上の位置。null のうちは右端・[MovableFakeGpsPanel.initialTop] に置く。
  Offset? _pos;
  bool _dragging = false;
  bool _minimized = false;
  final _key = GlobalKey();

  /// 指を離したとき、勢いをどれだけ先まで見るか（秒）。
  static const double _flingLookAheadS = 0.25;

  Size get _panelSize =>
      (_key.currentContext?.findRenderObject() as RenderBox?)?.size ??
      const Size(260, 120);

  Offset _clamp(Offset p, Size area) {
    final s = _panelSize;
    final m = widget.margin;
    double fit(double v, double lo, double hi) =>
        hi < lo ? lo : v.clamp(lo, hi);
    return Offset(
      fit(p.dx, m, area.width - s.width - m),
      fit(p.dy, m, area.height - s.height - m),
    );
  }

  /// [p]（勢いの先）に一番近い四隅。
  Offset _nearestCorner(Offset p, Size area) {
    final s = _panelSize;
    final m = widget.margin;
    final corners = [
      Offset(m, m),
      Offset(area.width - s.width - m, m),
      Offset(m, area.height - s.height - m),
      Offset(area.width - s.width - m, area.height - s.height - m),
    ];
    corners.sort((a, b) => (a - p).distance.compareTo((b - p).distance));
    return _clamp(corners.first, area);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final area = box.biggest;
        // 画面が狭いときは操作盤も細くする
        final width = (area.width - widget.margin * 2).clamp(200.0, 260.0);
        final start = Offset(
          area.width - width - widget.margin,
          widget.initialTop ?? (area.height - _panelSize.height) / 2,
        );
        final pos = _clamp(_pos ?? start, area);
        return Stack(
          children: [
            AnimatedPositioned(
              // 引いている間は指に付いてくる。離したら四隅へ吸い付く
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              left: pos.dx,
              top: pos.dy,
              child: GestureDetector(
                key: const ValueKey('fake_gps_drag_area'),
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => setState(() => _dragging = true),
                onPanUpdate: (d) =>
                    setState(() => _pos = _clamp(pos + d.delta, area)),
                onPanEnd: (d) => setState(() {
                  _dragging = false;
                  final ahead =
                      pos + d.velocity.pixelsPerSecond * _flingLookAheadS;
                  _pos = _nearestCorner(ahead, area);
                }),
                onPanCancel: () => setState(() => _dragging = false),
                child: FakeGpsPanel(
                  key: _key,
                  controller: widget.controller,
                  width: width,
                  minimized: _minimized,
                  onToggleMinimized: () =>
                      setState(() => _minimized = !_minimized),
                  // つまみは目印として出す（引くのは操作盤のどこでもよい）
                  onDrag: (_) {},
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

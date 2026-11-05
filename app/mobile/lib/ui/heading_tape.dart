import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../sources/gaze_source.dart';
import 'glass_overlay.dart';
import 'style.dart';

/// 視線（約10Hz）を受けて、方位テープをなめらかに動かす。
/// 画面全体は1秒ごとにしか作り直さないので、テープだけここで細かく更新する。
class LiveHeadingTape extends StatelessWidget {
  const LiveHeadingTape({
    super.key,
    required this.gaze,
    this.candidates = const [],
  });

  final ValueListenable<GazeReading?> gaze;
  final List<CandidateMark> candidates;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<GazeReading?>(
        valueListenable: gaze,
        builder: (context, g, _) => g == null
            ? const SizedBox.shrink()
            : _SmoothHeading(
                target: g.azDeg,
                builder: (deg) =>
                    HeadingTape(headingDeg: deg, candidates: candidates),
              ),
      ),
    );
  }
}

/// 0/360 をまたいでも遠回りしないよう、前の値からの差（-180〜180）だけ動かす。
class _SmoothHeading extends StatefulWidget {
  const _SmoothHeading({required this.target, required this.builder});

  final double target;
  final Widget Function(double deg) builder;

  @override
  State<_SmoothHeading> createState() => _SmoothHeadingState();
}

class _SmoothHeadingState extends State<_SmoothHeading> {
  late double _unwrapped = widget.target;

  @override
  void didUpdateWidget(_SmoothHeading old) {
    super.didUpdateWidget(old);
    _unwrapped += relativeBearing(widget.target, _unwrapped % 360);
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _unwrapped),
      duration: const Duration(milliseconds: 120),
      builder: (context, v, _) => widget.builder(((v % 360) + 360) % 360),
    );
  }
}

/// 方位テープ。視線の方位を中央に、左右 [halfRangeDeg] 度の目盛りと方角を出す。
/// A の候補はテープの上に名前と距離のピンで、範囲の外なら端の札で示す。
class HeadingTape extends StatelessWidget {
  const HeadingTape({
    super.key,
    required this.headingDeg,
    this.candidates = const [],
    this.halfRangeDeg = 60,
  });

  final double headingDeg;
  final List<CandidateMark> candidates;
  final double halfRangeDeg;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 84,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          double xOf(double rel) => w / 2 + rel / halfRangeDeg * (w / 2);
          final inView = <Widget>[];
          final left = <CandidateMark>[];
          final right = <CandidateMark>[];
          for (final m in candidates) {
            final rel = relativeBearing(m.bearingDeg, headingDeg);
            if (rel.abs() <= halfRangeDeg) {
              inView.add(
                Positioned(
                  left: (xOf(rel) - 80).clamp(0, w - 160),
                  top: 0,
                  width: 160,
                  child: _Pin(mark: m),
                ),
              );
            } else {
              (rel < 0 ? left : right).add(m);
            }
          }
          return Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 38,
                height: 44,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: ColoredBox(
                    color: const Color(0xE6FFFFFF),
                    child: CustomPaint(
                      painter: _TapePainter(
                        headingDeg: headingDeg,
                        halfRangeDeg: halfRangeDeg,
                      ),
                    ),
                  ),
                ),
              ),
              ...inView,
              if (left.isNotEmpty)
                Positioned(
                  left: 0,
                  top: 0,
                  child: _EdgeHint(mark: left.first, leftSide: true),
                ),
              if (right.isNotEmpty)
                Positioned(
                  right: 0,
                  top: 0,
                  child: _EdgeHint(mark: right.first, leftSide: false),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TapePainter extends CustomPainter {
  _TapePainter({required this.headingDeg, required this.halfRangeDeg});

  final double headingDeg;
  final double halfRangeDeg;

  static const _names = {
    0: '北',
    45: '北東',
    90: '東',
    135: '南東',
    180: '南',
    225: '南西',
    270: '西',
    315: '北西',
  };
  static final _labelCache = <int, TextPainter>{};

  static TextPainter _label(int norm) => _labelCache.putIfAbsent(norm, () {
    return TextPainter(
      text: TextSpan(
        text: _names[norm],
        style: TextStyle(
          color: norm == 0 ? AppColors.danger : AppColors.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  });

  @override
  void paint(Canvas canvas, Size size) {
    final tick = Paint()
      ..color = AppColors.subtext
      ..strokeWidth = 1.2;
    final start = (headingDeg - halfRangeDeg).floor();
    final end = (headingDeg + halfRangeDeg).ceil();
    for (var deg = start; deg <= end; deg++) {
      if (deg % 5 != 0) continue;
      final rel = relativeBearing(deg.toDouble(), headingDeg);
      final x = size.width / 2 + rel / halfRangeDeg * (size.width / 2);
      final norm = ((deg % 360) + 360) % 360;
      final major = norm % 45 == 0;
      final len = major ? 10.0 : (norm % 15 == 0 ? 7.0 : 4.0);
      canvas.drawLine(
        Offset(x, size.height - len),
        Offset(x, size.height),
        tick,
      );
      if (major) {
        final tp = _label(norm);
        tp.paint(
          canvas,
          Offset(x - tp.width / 2, (size.height - len - tp.height) / 2),
        );
      }
    }
    // 中央の印（視線）：上から下へ青い線
    final mark = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width / 2, 4),
      Offset(size.width / 2, size.height - 4),
      mark,
    );
  }

  @override
  bool shouldRepaint(_TapePainter old) =>
      old.headingDeg != headingDeg || old.halfRangeDeg != halfRangeDeg;
}

String _dist(double m) =>
    m >= 1000 ? '${(m / 1000).toStringAsFixed(1)}km' : '${m.round()}m';

class _Pin extends StatelessWidget {
  const _Pin({required this.mark});

  final CandidateMark mark;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: const BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.all(Radius.circular(14)),
            boxShadow: softShadow,
          ),
          child: Text(
            '${mark.name} ${_dist(mark.distanceM)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
        const Icon(Icons.arrow_drop_down, color: AppColors.primary, size: 18),
      ],
    );
  }
}

class _EdgeHint extends StatelessWidget {
  const _EdgeHint({required this.mark, required this.leftSide});

  final CandidateMark mark;
  final bool leftSide;

  @override
  Widget build(BuildContext context) {
    return StatusChip(
      icon: leftSide ? Icons.chevron_left : Icons.chevron_right,
      label: '${mark.name} ${_dist(mark.distanceM)}',
      color: AppColors.primary,
    );
  }
}

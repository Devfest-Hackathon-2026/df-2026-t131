import 'package:flutter/material.dart';

import 'style.dart';

/// 指で引っ張ってたためるシート（近年の地図アプリと同じ操作）。
///
/// - [Axis.vertical]：画面の下のシート。上中央のバーを下へ引くとたたむ。
/// - [Axis.horizontal]：画面の左のシート。右中央のバーを左へ引くとたたむ。
///
/// 指に合わせて動き、離したときは「どれだけ引いたか」と「はらった速さ」で開くか閉じるかを決めて、
/// なめらかに収まる。たたんでもバーの帯（[peek]）だけは残り、そこを引けば戻せる。
/// バーを押すだけでも開閉する。
class CollapsibleSheet extends StatefulWidget {
  const CollapsibleSheet({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.peek = 26,
    this.progress,
    this.fill = false,
  });

  final Widget child;
  final Axis axis;
  final EdgeInsets padding;
  final BorderRadius borderRadius;

  /// たたんだときに残す帯の太さ（バーの部分）。
  final double peek;

  /// たたみ具合（0 = 開いている、1 = たたんでいる）を指の動きに合わせて流す。
  /// 画面側はこれで小さな札を少しずつ出す。
  final ValueNotifier<double>? progress;

  /// 親の大きさいっぱいに広げる（中身の Expanded を効かせる）。
  final bool fill;

  @override
  State<CollapsibleSheet> createState() => CollapsibleSheetState();
}

class CollapsibleSheetState extends State<CollapsibleSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..addListener(_report);
  final _key = GlobalKey();
  late final Animation<double> _contentOpacity = Tween<double>(
    begin: 1,
    end: 0,
  ).animate(CurvedAnimation(parent: _c, curve: const Interval(0.3, 0.9)));

  bool get isCollapsed => _c.value > 0.5;

  void _report() => widget.progress?.value = _c.value;

  /// 動かせる距離（シートの大きさから残す帯を引いたもの）。
  double get _travel {
    final size = (_key.currentContext?.findRenderObject() as RenderBox?)?.size;
    final full = size == null
        ? 300.0
        : (widget.axis == Axis.vertical ? size.height : size.width);
    return (full - widget.peek).clamp(1.0, double.infinity);
  }

  void expand() => _settle(0);
  void collapse() => _settle(1);
  void toggle() => _settle(isCollapsed ? 0 : 1);

  void _settle(double target) {
    _c.animateTo(target, curve: Curves.easeOutCubic);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    // 下へ（縦）・左へ（横）引くほどたたむ
    final delta = widget.axis == Axis.vertical ? d.delta.dy : -d.delta.dx;
    _c.value = (_c.value + delta / _travel).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails d) {
    final v = widget.axis == Axis.vertical
        ? d.velocity.pixelsPerSecond.dy
        : -d.velocity.pixelsPerSecond.dx;
    // 速くはらったら向きで決める。ゆっくりなら半分を超えたかで決める
    final target = v.abs() > 400
        ? (v > 0 ? 1.0 : 0.0)
        : (_c.value > 0.5 ? 1.0 : 0.0);
    _settle(target);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.axis == Axis.vertical;
    final handle = _Handle(
      vertical: vertical,
      thickness: widget.peek,
      onTap: toggle,
      onDragUpdate: _onDragUpdate,
      onDragEnd: _onDragEnd,
    );
    // 引っ込むにつれて中身を薄くする（たたんだときに端が覗かないように）
    final content = FadeTransition(
      opacity: _contentOpacity,
      child: Padding(padding: widget.padding, child: widget.child),
    );
    final body = vertical
        ? Column(
            mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              handle,
              if (widget.fill) Expanded(child: content) else content,
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: content),
              handle,
            ],
          );

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        final shift = t * _travel;
        return Transform.translate(
          offset: vertical ? Offset(0, shift) : Offset(-shift, 0),
          child: child,
        );
      },
      child: Container(
        key: _key,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: widget.borderRadius,
          boxShadow: softShadow,
        ),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: AppColors.text),
          child: body,
        ),
      ),
    );
  }
}

/// テストや自動操作でバーを見つけるための目印。
const sheetHandleKey = ValueKey('sheet-handle');

/// つまみ（バー）。縦のシートでは上中央の横長バー、横のシートでは右中央の縦長バー。
class _Handle extends StatelessWidget {
  const _Handle({
    required this.vertical,
    required this.thickness,
    required this.onTap,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final bool vertical;
  final double thickness;
  final VoidCallback onTap;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final bar = Container(
      width: vertical ? 40 : 5,
      height: vertical ? 5 : 40,
      decoration: BoxDecoration(
        color: const Color(0xFFBDC1C6),
        borderRadius: BorderRadius.circular(3),
      ),
    );
    return Semantics(
      button: true,
      label: 'シートを開く・たたむ',
      child: GestureDetector(
        key: sheetHandleKey,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onVerticalDragUpdate: vertical ? onDragUpdate : null,
        onVerticalDragEnd: vertical ? onDragEnd : null,
        onHorizontalDragUpdate: vertical ? null : onDragUpdate,
        onHorizontalDragEnd: vertical ? null : onDragEnd,
        child: SizedBox(
          width: vertical ? double.infinity : thickness,
          height: vertical ? thickness : double.infinity,
          child: Center(child: bar),
        ),
      ),
    );
  }
}

/// たたみ具合に合わせて少しずつ現れる（たたんだときの小さな札用）。
/// 半分より開いている間は押せない。
class AppearWhenCollapsed extends StatelessWidget {
  const AppearWhenCollapsed({
    super.key,
    required this.progress,
    required this.child,
  });

  final ValueNotifier<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      child: child,
      builder: (context, t, child) {
        final a = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: t < 0.5,
          child: Opacity(
            opacity: a,
            child: Transform.translate(
              offset: Offset(0, (1 - a) * 12),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// たたみ具合に合わせて少しずつ消える（たたむと隠したい表示用）。
class HideWhenCollapsed extends StatelessWidget {
  const HideWhenCollapsed({
    super.key,
    required this.progress,
    required this.child,
  });

  final ValueNotifier<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      child: child,
      builder: (context, t, child) => IgnorePointer(
        ignoring: t > 0.5,
        child: Opacity(opacity: (1 - t * 1.6).clamp(0.0, 1.0), child: child),
      ),
    );
  }
}

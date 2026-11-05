import 'package:flutter/material.dart';

/// 色。地図アプリのように、白い面に青を1色だけ使い、状態は緑・黄・赤で示す。
class AppColors {
  AppColors._();

  static const primary = Color(0xFF1A73E8); // 青：操作・情報
  static const ok = Color(0xFF188038); // 緑：正常
  static const warn = Color(0xFFF9AB00); // 黄：注意
  static const danger = Color(0xFFD93025); // 赤：記録中・終了
  static const text = Color(0xFF202124);
  static const subtext = Color(0xFF5F6368);
  static const surface = Colors.white;
  static const divider = Color(0xFFE0E0E0);

  // 互換のための別名
  static const accent = ok;
  static const info = primary;
  static const muted = subtext;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primary,
    onPrimary: Colors.white,
    surface: AppColors.surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.surface,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
      ),
    ),
  );
}

/// 浮いて見える白い面（カードの影は控えめに1段だけ）。
const List<BoxShadow> softShadow = [
  BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2)),
];

/// 映像の上に浮かべる白いカード。
class FloatingCard extends StatelessWidget {
  const FloatingCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 16,
    this.color = AppColors.surface,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: softShadow,
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: color == AppColors.surface ? AppColors.text : Colors.white,
        ),
        child: child,
      ),
    );
  }
}

/// 白い丸い札（地図アプリの検索候補チップのような見た目）。
/// 色だけに頼らず、必ずアイコンと文字を付ける。
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.icon,
    required this.label,
    this.color = AppColors.subtext,
    this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final Color color;

  /// 押せる札にするとき（押すと切り替わる設定など）。押せる札には右に小さな印を付ける。
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: EdgeInsets.fromLTRB(12, 7, onTap == null ? 12 : 8, 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: AppColors.text, fontSize: 15),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            const Icon(Icons.swap_horiz, size: 16, color: AppColors.subtext),
          ],
        ],
      ),
    );
    final chip = Material(
      color: AppColors.surface,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );
    final decorated = DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(20)),
        boxShadow: softShadow,
      ),
      child: chip,
    );
    return tooltip == null
        ? decorated
        : Tooltip(message: tooltip, child: decorated);
  }
}

/// 白い丸ボタン（地図アプリの現在地ボタンのような見た目）。
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        shape: BoxShape.circle,
        boxShadow: softShadow,
      ),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: AppColors.subtext),
        onPressed: onPressed,
      ),
    );
  }
}

/// 地図アプリの「シート」：角の大きな白い面と、上のつまみ。
class Sheet extends StatelessWidget {
  const Sheet({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 16),
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.expand = false,
    this.onMinimize,
    this.minimizeIcon = Icons.expand_more,
  });

  final Widget child;
  final EdgeInsets padding;
  final BorderRadius borderRadius;

  /// 最小化する。つまみを押す・下へはらうと呼ぶ。null なら最小化しない。
  final VoidCallback? onMinimize;
  final IconData minimizeIcon;

  /// 親の高さいっぱいに広げる（中身の Spacer を効かせる）。
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: borderRadius,
        boxShadow: softShadow,
      ),
      padding: padding,
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: AppColors.text),
        child: Column(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Grabber(onMinimize: onMinimize, icon: minimizeIcon),
            if (expand) Expanded(child: child) else child,
          ],
        ),
      ),
    );
  }
}

/// シートのつまみ。押すか下へはらうと最小化する（右端に小さな「たたむ」ボタンも出す）。
class _Grabber extends StatelessWidget {
  const _Grabber({required this.onMinimize, required this.icon});

  final VoidCallback? onMinimize;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final bar = Container(
      width: 36,
      height: 5,
      decoration: BoxDecoration(
        color: AppColors.divider,
        borderRadius: BorderRadius.circular(3),
      ),
    );
    final cb = onMinimize;
    if (cb == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Center(child: bar),
      );
    }
    return Semantics(
      button: true,
      label: 'たたむ',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: cb,
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 200) cb();
        },
        child: SizedBox(
          height: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              bar,
              Positioned(
                right: -8,
                top: -8,
                child: IconButton(
                  tooltip: 'たたむ',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(icon, color: AppColors.subtext),
                  onPressed: cb,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// たたんだときの小さな白い丸札（押すと元に戻る）。
class MiniPill extends StatelessWidget {
  const MiniPill({super.key, required this.children, required this.onExpand});

  final List<Widget> children;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 3,
      shadowColor: const Color(0x55000000),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onExpand,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...children,
              const SizedBox(width: 4),
              const Icon(Icons.expand_less, color: AppColors.subtext),
            ],
          ),
        ),
      ),
    );
  }
}

/// 丸いボタンと下の短いラベル（地図アプリの「経路・電話・共有」の並び）。
/// [active] のときは色付きの丸、そうでなければ灰色の丸。
class QuickAction extends StatelessWidget {
  const QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = true,
    this.color = AppColors.primary,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: active
                      ? color.withValues(alpha: 0.12)
                      : const Color(0xFFF1F3F4),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: active ? color : AppColors.subtext,
                  size: 26,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(fontSize: 13, color: AppColors.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 大きな数字と小さなラベル（地図アプリの「到着・時間・距離」の並び）。
class StatBlock extends StatelessWidget {
  const StatBlock({
    super.key,
    required this.value,
    required this.label,
    this.color = AppColors.text,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: MediaQuery.sizeOf(context).height < 380 ? 22 : 26,
            fontWeight: FontWeight.w600,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppColors.subtext),
        ),
      ],
    );
  }
}

/// 以前の半透明パネルの代わり（白いカード）。
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) =>
      FloatingCard(padding: padding, radius: 12, child: child);
}

String formatDuration(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String formatDistance(double m) => m >= 1000
    ? '${(m / 1000).toStringAsFixed(2)} km'
    : '${m.toStringAsFixed(0)} m';

String compassName(double az) {
  const names = ['北', '北東', '東', '南東', '南', '南西', '西', '北西'];
  return names[((az + 22.5) % 360 ~/ 45)];
}

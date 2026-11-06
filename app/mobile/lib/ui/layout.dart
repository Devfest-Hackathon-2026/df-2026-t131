import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 画面の大きさから決める寸法。どのスマホでも収まるよう、固定の数値ではなく画面の割合で決める。
/// 横持ち固定なので、高さ（短い辺）が小さい端末ほど詰める。
class Layout {
  Layout._(this.size);

  factory Layout.of(BuildContext context) =>
      Layout._(MediaQuery.sizeOf(context));

  final Size size;

  /// 高さが 380 未満（小さいスマホ）なら詰めた表示にする。
  bool get compact => size.height < 380 || size.width < 680;

  /// 画面の端からの余白。
  double get margin => compact ? 10 : 16;

  /// 開始画面の左のシートの幅。
  double get sheetWidth => (size.width * 0.44).clamp(280.0, 440.0);

  /// 記録中の画面の左上のカードの幅。
  double get nowCardWidth => math.min(520, size.width * 0.5);

  /// 方位テープの幅。
  double get tapeWidth => math.min(560, size.width * 0.6);

  /// 主ボタンの高さ。
  double get buttonHeight => compact ? 46 : 56;
}

/// システムの文字サイズ設定が大きすぎても画面が崩れないよう、倍率を抑える。
/// あわせて、高さの小さい画面では画面全体を縮めて収める（[FitToShortScreen]）。
Widget clampTextScale(BuildContext context, Widget? child) => FitToShortScreen(
  child: MediaQuery.withClampedTextScaling(
    minScaleFactor: 0.85,
    maxScaleFactor: 1.15,
    child: child ?? const SizedBox.shrink(),
  ),
);

/// 横持ちで高さ（短い辺）が [designHeight] より小さい画面では、画面全体を同じ割合で縮める。
///
/// 画面の部品は高さ約470dp を想定した大きさなので、横長で背の低いスマホ（例：高さ393dp）では
/// カメラ映像がほとんど隠れ、下のシートがはみ出す。文字・ボタン・余白を一緒に縮めて、
/// 配置はそのまま収める。押せる場所も一緒に縮む。
class FitToShortScreen extends StatelessWidget {
  const FitToShortScreen({
    super.key,
    required this.child,
    this.designHeight = 470,
    this.minScale = 0.7,
  });

  final Widget child;
  final double designHeight;
  final double minScale;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final short = math.min(mq.size.width, mq.size.height);
    if (short <= 0) return child;
    final s = (short / designHeight).clamp(minScale, 1.0);
    if (s >= 1.0) return child;
    final virtual = mq.size / s;
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: virtual,
        child: MediaQuery(
          data: mq.copyWith(
            size: virtual,
            padding: mq.padding / s,
            viewPadding: mq.viewPadding / s,
            viewInsets: mq.viewInsets / s,
            systemGestureInsets: mq.systemGestureInsets / s,
          ),
          child: child,
        ),
      ),
    );
  }
}

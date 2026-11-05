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
Widget clampTextScale(BuildContext context, Widget? child) =>
    MediaQuery.withClampedTextScaling(
      minScaleFactor: 0.85,
      maxScaleFactor: 1.15,
      child: child ?? const SizedBox.shrink(),
    );

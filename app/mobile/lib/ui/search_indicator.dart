import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../vision/search_progress.dart';
import 'style.dart';

/// B の検索の進み具合の札（「記録中」の札と同じ形）。
///
/// 進んでいる途中（聞き取り・撮影・顔ぼかし・送信）は点が点滅し、
/// 終わったら（答え・失敗・見送り）印を替えて数秒出す（消すのは AppServices）。
class SearchIndicator extends StatelessWidget {
  const SearchIndicator({
    super.key,
    required this.progress,
    required this.label,
  });

  final ValueListenable<SearchProgress?> progress;
  final String Function(SearchProgress p) label;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SearchProgress?>(
    valueListenable: progress,
    builder: (context, p, _) => AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: p == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SearchIndicatorChip(
                key: ValueKey(p),
                progress: p,
                label: label(p),
              ),
            ),
    ),
  );
}

class SearchIndicatorChip extends StatefulWidget {
  const SearchIndicatorChip({
    super.key,
    required this.progress,
    required this.label,
  });

  final SearchProgress progress;
  final String label;

  @override
  State<SearchIndicatorChip> createState() => _SearchIndicatorChipState();
}

class _SearchIndicatorChipState extends State<SearchIndicatorChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    if (widget.progress.active) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static (IconData, Color) _look(SearchPhase phase) => switch (phase) {
    SearchPhase.heard => (Icons.mic, AppColors.primary),
    SearchPhase.capturing => (Icons.photo_camera, AppColors.primary),
    SearchPhase.blurring => (Icons.face, AppColors.primary),
    SearchPhase.sending => (Icons.cloud_upload, AppColors.primary),
    SearchPhase.answered => (Icons.check_circle, AppColors.ok),
    SearchPhase.failed => (Icons.error_outline, AppColors.warn),
    SearchPhase.skipped => (Icons.block, AppColors.subtext),
  };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _look(widget.progress.phase);
    final iconWidget = Icon(icon, size: 18, color: color);
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
          widget.progress.active
              ? FadeTransition(
                  opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
                  child: iconWidget,
                )
              : iconWidget,
          const SizedBox(width: 6),
          // 長い文言は縮めずに折り返す（2行まで）
          Flexible(
            child: Text(
              widget.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, color: AppColors.text),
            ),
          ),
        ],
      ),
    );
  }
}

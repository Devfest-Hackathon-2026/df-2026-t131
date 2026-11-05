import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 字幕の文。話し終えた所までを濃く、これから話す所を薄く出す（カラオケの字幕のように）。
class CaptionText extends StatelessWidget {
  const CaptionText({
    super.key,
    required this.text,
    required this.spoken,
    this.fontSize = 20,
    this.maxLines = 3,
  });

  final String text;
  final ValueListenable<int> spoken;
  final double fontSize;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: spoken,
      builder: (context, n, _) {
        final cut = n.clamp(0, text.length);
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: text.substring(0, cut)),
              TextSpan(
                text: text.substring(cut),
                style: const TextStyle(color: Color(0xB3FFFFFF)),
              ),
            ],
          ),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.35,
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        );
      },
    );
  }
}

/// 画面の下に出す字幕の帯（動画の字幕のような濃い半透明の帯）。話していないときは消える。
class CaptionBar extends StatelessWidget {
  const CaptionBar({
    super.key,
    required this.subtitle,
    required this.spoken,
    this.maxWidth = 640,
  });

  final ValueListenable<String?> subtitle;
  final ValueListenable<int> spoken;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<String?>(
        valueListenable: subtitle,
        builder: (context, text, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.25),
                end: Offset.zero,
              ).animate(a),
              child: child,
            ),
          ),
          child: text == null
              ? const SizedBox.shrink(key: ValueKey('no-caption'))
              : ConstrainedBox(
                  key: ValueKey(text),
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Semantics(
                    liveRegion: true,
                    label: text,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.volume_up,
                            color: Colors.white,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: CaptionText(text: text, spoken: spoken),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

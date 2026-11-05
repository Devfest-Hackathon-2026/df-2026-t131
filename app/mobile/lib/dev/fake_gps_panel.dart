import 'package:flutter/material.dart';

import '../ui/style.dart';
import 'fake_gps.dart';

/// フェイク GPS を使っている間だけ画面に出す操作盤（再生・倍速・最初から・位置の移動）。
/// 本物の歩行と見間違えないよう、オレンジの枠と「フェイクGPS」の札を付ける。
class FakeGpsPanel extends StatelessWidget {
  const FakeGpsPanel({super.key, required this.controller, this.width = 260});

  final FakeGpsController controller;
  final double width;

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
                ],
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: c.playing ? '止める' : '歩く',
                    icon: Icon(
                      c.playing ? Icons.pause_circle : Icons.play_circle,
                      color: orange,
                      size: 34,
                    ),
                    onPressed: c.togglePlay,
                  ),
                  IconButton(
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
                  const Spacer(),
                  Text(
                    '${c.distanceM.toStringAsFixed(0)} / '
                    '${track.lengthM.toStringAsFixed(0)} m',
                    style: const TextStyle(
                      fontSize: 14,
                      fontFeatures: [FontFeature.tabularFigures()],
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
          ),
        );
      },
    );
  }
}

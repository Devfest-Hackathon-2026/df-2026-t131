import 'package:flutter/material.dart';

import '../app/session_controller.dart';
import 'style.dart';

/// 終了後のまとめ。30分テストの合否（途切れの有無）もここで分かる。
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key, required this.summary, required this.onDone});

  final SessionSummary summary;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('おつかれさまでした', style: TextStyle(fontSize: 26)),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _Stat(label: '時間', value: formatDuration(s.duration)),
                        _Stat(label: '距離', value: formatDistance(s.distanceM)),
                        _Stat(label: '記録', value: '${s.rows} 行'),
                        _Stat(
                          label: '最大の途切れ',
                          value: '${(s.maxGapMs / 1000).toStringAsFixed(1)} 秒',
                          color: s.hasGap ? AppColors.warn : AppColors.accent,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '画像検索 ${s.settings.visualSearchEnabled ? 'オン' : 'オフ'}・${s.settings.voice.label}'
                      '${s.fakeLocation ? '・フェイクGPS' : ''}',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                    Text(
                      '歩行ログ：${s.fileName}',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 220,
                height: 64,
                child: FilledButton.icon(
                  onPressed: onDone,
                  icon: const Icon(Icons.home),
                  label: const Text('開始画面へ', style: TextStyle(fontSize: 20)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.color = AppColors.text,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F3F4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 24, color: color)),
        ],
      ),
    );
  }
}

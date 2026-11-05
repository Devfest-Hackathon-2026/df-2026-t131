import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../info/info_source.dart';
import 'style.dart';

/// 受け取った気象警報を画面に出す帯。読み上げと同じ文を、聞き逃しても読めるよう残しておく。
///
/// レベル4以上は赤、それ以下は黄。×で消せる（消しても読み上げの履歴や歩行ログは残る）。
/// 警報が無いときは何も出さない。
class AlertBanner extends StatelessWidget {
  const AlertBanner({
    super.key,
    required this.alert,
    required this.onClose,
    this.maxWidth = 440,
  });

  final ValueListenable<InfoItem?> alert;
  final VoidCallback onClose;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<InfoItem?>(
      valueListenable: alert,
      builder: (context, a, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: a == null
            ? const SizedBox.shrink(key: ValueKey('no-alert'))
            : _Body(
                key: ValueKey(a.id),
                alert: a,
                onClose: onClose,
                maxWidth: maxWidth,
              ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    super.key,
    required this.alert,
    required this.onClose,
    required this.maxWidth,
  });

  final InfoItem alert;
  final VoidCallback onClose;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final level = alert.level ?? 0;
    final severe = level >= 4;
    final color = severe ? AppColors.danger : AppColors.warn;
    final onColor = severe ? Colors.white : AppColors.text;
    final kind = alert.data['kind'] as String? ?? '気象警報';
    final area = alert.data['area_name'] as String? ?? '';
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Semantics(
        liveRegion: true,
        label: 'レベル$level $kind $area。${alert.text}',
        child: Material(
          color: color,
          elevation: 4,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.warning_amber_rounded, color: onColor),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'レベル$level  $kind・$area',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: onColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        alert.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: onColor, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '警報の表示を閉じる',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close, color: onColor),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

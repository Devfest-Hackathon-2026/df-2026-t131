import 'package:flutter/material.dart';

/// Web 以外（テスト）では動画を出さず、場所だけ取る。
class WalkVideoPlayer extends StatelessWidget {
  final String url;
  final double positionSec;
  final bool playing;
  final int speed;
  const WalkVideoPlayer({
    super.key,
    required this.url,
    required this.positionSec,
    required this.playing,
    required this.speed,
  });

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('（動画はブラウザで表示します）', style: TextStyle(color: Colors.white)),
  );
}

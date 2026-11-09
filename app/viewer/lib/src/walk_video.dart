import 'package:flutter/material.dart';

import 'walk_video_player.dart';

// 歩いたときの動画（アプリの画面の録画）を、歩行ログの再生と同じ時刻で並べて見せる（11/8）。
// 動画はリポジトリにも viewer のイメージにも入れず、Cloud Storage から読む（docs/design.md 3章6）。
// 通行人の顔はぼかし済み、音声は消してある。

/// 歩行ログ1本ぶんの動画の置き場所と時刻のずれ（index.json の `video`）。
final class WalkVideo {
  /// 動画の URL（mp4）。
  final String url;

  /// 歩行ログの最初の記録が、動画の何ミリ秒目にあたるか。
  final int offsetMs;

  const WalkVideo(this.url, {this.offsetMs = 0});

  /// index.json の `video`（無ければ null）。
  static WalkVideo? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final url = j['url'] as String?;
    if (url == null || url.isEmpty) return null;
    return WalkVideo(url, offsetMs: (j['offset_ms'] as num?)?.toInt() ?? 0);
  }

  /// 再生の位置（歩行ログの最初からのミリ秒）を、動画の位置（秒）にする。
  double positionSec(int sinceStartMs) => (sinceStartMs + offsetMs) / 1000;
}

/// 画面に出す断り書き。
const walkVideoNotice =
    '歩いたときのアプリの画面の録画です（スマートグラスの代わりにスマホで撮影）。'
    '通行人の顔はぼかし、音声は消しています。再生の位置に合わせて動きます。';

/// 動画と断り書き。
class WalkVideoPanel extends StatelessWidget {
  final WalkVideo video;
  final int sinceStartMs;
  final bool playing;
  final int speed;
  const WalkVideoPanel({
    super.key,
    required this.video,
    required this.sinceStartMs,
    required this.playing,
    required this.speed,
  });

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    color: Colors.black,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: WalkVideoPlayer(
            url: video.url,
            positionSec: video.positionSec(sinceStartMs),
            playing: playing,
            speed: speed,
          ),
        ),
        Container(
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: const Text(
            walkVideoNotice,
            style: TextStyle(fontSize: 11, color: Colors.white),
          ),
        ),
      ],
    ),
  );
}

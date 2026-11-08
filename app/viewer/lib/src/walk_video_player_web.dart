import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ブラウザの `<video>`（使う分だけ）。
extension type _Video(JSObject _) implements JSObject {
  external set src(String v);
  external set muted(bool v);
  external set playsInline(bool v);
  external set preload(String v);
  external double get currentTime;
  external set currentTime(double v);
  external double get playbackRate;
  external set playbackRate(double v);
  external bool get paused;
  external JSPromise<JSAny?> play();
  external void pause();
  external _Style get style;
}

extension type _Style(JSObject _) implements JSObject {
  external set width(String v);
  external set height(String v);
  external set objectFit(String v);
  external set backgroundColor(String v);
  external set pointerEvents(String v);
}

/// 再生の位置に合わせて動かす動画。音声は出さない（動画自体にも音声は無い）。
///
/// 再生の時計は判断画面の側にあり、動画はそれに合わせる：
/// 止まっているときは位置だけ合わせ、再生中は同じ速さで流し、ずれが大きくなったら位置を直す。
/// ブラウザの再生速度の上限（16倍）を超えるときは、動画を止めて位置だけ追いかける。
class WalkVideoPlayer extends StatefulWidget {
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
  State<WalkVideoPlayer> createState() => _WalkVideoPlayerState();
}

class _WalkVideoPlayerState extends State<WalkVideoPlayer> {
  static const _maxRate = 16.0;
  _Video? _video;

  void _created(Object element) {
    final v = _Video(element as JSObject)
      ..muted = true
      ..playsInline = true
      ..preload = 'auto'
      ..src = widget.url;
    v.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain'
      ..backgroundColor = 'black'
      ..pointerEvents = 'none';
    _video = v;
    _sync();
  }

  @override
  void didUpdateWidget(WalkVideoPlayer old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _video?.src = widget.url;
    _sync();
  }

  void _sync() {
    final v = _video;
    if (v == null) return;
    final target = math.max(0.0, widget.positionSec);
    final drift = (v.currentTime - target).abs();
    final rate = widget.speed.toDouble();
    if (widget.playing && rate <= _maxRate) {
      if (v.playbackRate != rate) v.playbackRate = rate;
      // 判断画面の時計と少しずれるのは許す（直しすぎると映像がつかえる）
      if (drift > math.max(1.0, rate * 0.5)) v.currentTime = target;
      if (v.paused) unawaited(_play(v));
    } else {
      if (!v.paused) v.pause();
      final allowed = widget.playing ? rate * 0.5 : 0.2;
      if (drift > allowed) v.currentTime = target;
    }
  }

  Future<void> _play(_Video v) async {
    try {
      await v.play().toDart;
    } on Object {
      // 読み込み前・ブラウザが止めたときは、次の更新でまた試す
    }
  }

  @override
  void dispose() {
    _video?.pause();
    _video = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      HtmlElementView.fromTagName(tagName: 'video', onElementCreated: _created);
}

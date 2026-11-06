import 'dart:math' as math;

import 'package:engine/engine.dart';
import 'package:flutter/material.dart';

import 'demo_map.dart';
import 'replay.dart';

// 地図：独自マップ（cloud/data の元データ。demo_map.dart）の上に、
// 歩いた道・話した場所・B の撮影位置を、自前の平面（北が上）に描く。
// 背景の地図タイル（Google Maps など）を足すときは、この MapView を差し替える。

class MapView extends StatelessWidget {
  final Replay replay;
  final int frameIndex;
  final DemoMap map;
  const MapView({
    super.key,
    required this.replay,
    required this.frameIndex,
    required this.map,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: CustomPaint(
        painter: _MapPainter(
          replay,
          frameIndex,
          map,
          Theme.of(context).colorScheme,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MapPainter extends CustomPainter {
  final Replay replay;
  final int frameIndex;
  final DemoMap map;
  final ColorScheme colors;
  _MapPainter(this.replay, this.frameIndex, this.map, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final track = replay.track;
    if (track.isEmpty) return;
    final origin = track.first.position;
    final cosLat = math.cos(origin.lat * math.pi / 180);
    const mPerDeg = 6371008.8 * math.pi / 180;
    Offset local(double lat, double lon) => Offset(
      (lon - origin.lon) * mPerDeg * cosLat,
      -(lat - origin.lat) * mPerDeg, // 画面は下が正なので北を上にする
    );

    // 表示範囲：歩いた道と、その近く（300m 以内）のランドマーク。
    final points = [
      for (final p in track) local(p.position.lat, p.position.lon),
    ];
    var bounds = Rect.fromPoints(points.first, points.first);
    for (final p in points) {
      bounds = bounds.expandToInclude(Rect.fromPoints(p, p));
    }
    // 独自マップのランドマークに、歩行ログのタイルで届いたものを重ねる（同じ ID はログの方）。
    final places = <String, MapPlace>{
      for (final p in map.landmarks) p.id: p,
      for (final lm in replay.landmarks)
        lm.id: MapPlace(
          id: lm.id,
          name: lm.name,
          kind: lm.kind,
          lat: lm.lat,
          lon: lm.lon,
          radiusM: lm.radiusM,
        ),
    };
    for (final lm in places.values) {
      final p = local(lm.lat, lm.lon);
      if (_distanceToTrack(p, points) <= 300) {
        bounds = bounds.expandToInclude(Rect.fromCircle(center: p, radius: 30));
      }
    }
    bounds = bounds.inflate(40);
    final scale = math.min(
      size.width / bounds.width,
      size.height / bounds.height,
    );
    final offset = Offset(
      (size.width - bounds.width * scale) / 2 - bounds.left * scale,
      (size.height - bounds.height * scale) / 2 - bounds.top * scale,
    );
    Offset screen(Offset p) => p * scale + offset;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = colors.surfaceContainerLowest,
    );
    _drawScale(canvas, size, scale);

    // ランドマーク・エリア（話したものは色を変える）
    final view = replay.frames[frameIndex].view;
    final told = {
      for (final n in view.nearby)
        if (n.told) n.id,
    };
    final toldBySpeak = <String>{
      for (final d in replay.decisions)
        if (d.frameIndex <= frameIndex &&
            (d.decision.kind == 'speak' ||
                d.decision.reason == 'answer:matched_landmark'))
          ?d.decision.targetId,
    };
    final visible = Offset.zero & size;
    for (final lm in places.values) {
      final c = screen(local(lm.lat, lm.lon));
      if (!visible.inflate(200).contains(c)) continue;
      final isTold = told.contains(lm.id) || toldBySpeak.contains(lm.id);
      final r = (lm.radiusM ?? 25) * scale;
      final color = lm.kind == 'area' ? Colors.green : Colors.orange;
      canvas.drawCircle(
        c,
        r,
        Paint()..color = color.withValues(alpha: isTold ? 0.08 : 0.18),
      );
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke,
      );
      canvas.drawCircle(c, 4, Paint()..color = isTold ? Colors.grey : color);
      _label(
        canvas,
        c + const Offset(6, -8),
        lm.name,
        isTold ? Colors.grey : colors.onSurface,
      );
    }

    // 横断歩道・信号
    final crossings = <String, ({double lat, double lon})>{
      for (final c in map.crossings) c.id: (lat: c.lat, lon: c.lon),
      for (final c in replay.crossings) c.id: (lat: c.lat, lon: c.lon),
    };
    for (final cr in crossings.values) {
      final c = screen(local(cr.lat, cr.lon));
      if (!visible.contains(c)) continue;
      canvas.drawRect(
        Rect.fromCenter(center: c, width: 7, height: 7),
        Paint()..color = Colors.redAccent,
      );
    }

    // イベント会場
    for (final e in map.events) {
      final c = screen(local(e.lat, e.lon));
      if (!visible.contains(c)) continue;
      canvas.drawCircle(c, 5, Paint()..color = Colors.pinkAccent);
      _label(canvas, c + const Offset(6, 4), e.name, Colors.pinkAccent);
    }

    // 歩いた道（いままで＝濃く、これから＝薄く）
    final nowMs = replay.frames[frameIndex].tMs;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < points.length; i++) {
      stroke.color = track[i].tMs <= nowMs
          ? colors.primary
          : colors.outlineVariant;
      canvas.drawLine(screen(points[i - 1]), screen(points[i]), stroke);
    }

    // 話した場所・B の撮影位置
    for (final s in replay.speaks) {
      if (s.frameIndex > frameIndex) break;
      final sensor = replay.frames[s.frameIndex].sensor;
      if (sensor == null) continue;
      final c = screen(local(sensor.lat, sensor.lon));
      canvas.drawCircle(
        c,
        6,
        Paint()..color = Colors.blue.withValues(alpha: 0.8),
      );
    }
    for (final s in replay.searches) {
      if (s.frameIndex > frameIndex) break;
      final p = s.position;
      if (p == null) continue;
      final c = screen(local(p.lat, p.lon));
      canvas.drawRect(
        Rect.fromCenter(center: c, width: 10, height: 10),
        Paint()
          ..color = Colors.purpleAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // いまの位置と視線
    final sensor = replay.frames[frameIndex].sensor;
    if (sensor != null) {
      final c = screen(local(sensor.lat, sensor.lon));
      final rad = sensor.gazeAzDeg * math.pi / 180;
      final tip = c + Offset(math.sin(rad), -math.cos(rad)) * 28;
      canvas.drawLine(
        c,
        tip,
        Paint()
          ..color = colors.primary
          ..strokeWidth = 3,
      );
      canvas.drawCircle(c, 8, Paint()..color = colors.primary);
      canvas.drawCircle(c, 4, Paint()..color = colors.onPrimary);
    }
  }

  double _distanceToTrack(Offset p, List<Offset> points) {
    var best = double.infinity;
    for (final q in points) {
      best = math.min(best, (p - q).distance);
    }
    return best;
  }

  void _drawScale(Canvas canvas, Size size, double scale) {
    const meters = 50.0;
    final len = meters * scale;
    final start = Offset(16, size.height - 20);
    final paint = Paint()
      ..color = colors.onSurfaceVariant
      ..strokeWidth = 2;
    canvas.drawLine(start, start + Offset(len, 0), paint);
    _label(
      canvas,
      start + const Offset(0, -18),
      '50 m',
      colors.onSurfaceVariant,
    );
    _label(canvas, Offset(size.width - 24, 8), '北↑', colors.onSurfaceVariant);
    var y = size.height - 18.0;
    for (final a in map.attributions.reversed) {
      final tp = TextPainter(
        text: TextSpan(
          text: a,
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - tp.width - 8, y));
      y -= 14;
    }
  }

  void _label(Canvas canvas, Offset at, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 200);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.replay != replay ||
      old.frameIndex != frameIndex ||
      old.map != map ||
      old.colors != colors;
}

/// 視線から見た角度を「右前方 30°」のような言い方にする（画面の表示用）。
String relativeLabel(double deg, EngineConfig config) =>
    '${directionWord(deg, config)} ${deg.abs().round()}°';

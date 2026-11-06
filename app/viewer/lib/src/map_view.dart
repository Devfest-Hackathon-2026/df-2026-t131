import 'dart:math' as math;

import 'package:engine/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'demo_map.dart';
import 'replay.dart';

// 地図：チームの確認用の地図（cloud/data/scripts/preview_map.py が作る map.html）と同じ作り。
//   背景＝地理院タイル（標準地図・航空写真を切り替え。API キー不要）
//   点＝独自マップ（cloud/data の reviewed のランドマーク・イベント・横断歩道と信号。demo_map.dart）
// その上に、歩いた道・いまの位置と視線・話し始めた場所・B で撮った場所を重ねる。
// 色は map.html に合わせる（ランドマーク＝赤、イベント＝紫、信号＝青、横断歩道＝緑）。

const _landmarkColor = Color(0xFFD62728);
const _eventColor = Color(0xFF9467BD);
const _signalColor = Color(0xFF1F77B4);
const _crosswalkColor = Color(0xFF2CA02C);
const _speakColor = Color(0xFFFF7F0E);
const _searchColor = Color(0xFFE377C2);
const _trackColor = Color(0xFF3949AB);

const _gsiStd = 'https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png';
const _gsiPhoto =
    'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg';

class MapView extends StatefulWidget {
  final Replay replay;
  final int frameIndex;
  final DemoMap map;

  /// 地図のタイルを読むか（テストではネットワークを使わないので false）。
  final bool showTiles;

  const MapView({
    super.key,
    required this.replay,
    required this.frameIndex,
    required this.map,
    this.showTiles = true,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final _controller = MapController();
  bool _follow = true;
  bool _photo = false;
  bool _ready = false;

  @override
  void didUpdateWidget(MapView old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    if (old.replay != widget.replay) {
      _fitTrack(); // 別のログを開いたら、歩いた範囲に合わせ直す
    } else if (_follow && old.frameIndex != widget.frameIndex) {
      final p = _position;
      if (p != null) _controller.move(p, _controller.camera.zoom);
    }
  }

  LatLng? get _position {
    final s = widget.replay.frames[widget.frameIndex].sensor;
    return s == null ? null : LatLng(s.lat, s.lon);
  }

  CameraFit? get _trackFit {
    final track = widget.replay.track;
    if (track.isEmpty) return null;
    return CameraFit.bounds(
      bounds: LatLngBounds.fromPoints([
        for (final t in track) LatLng(t.position.lat, t.position.lon),
      ]),
      padding: const EdgeInsets.all(80),
      maxZoom: 17,
    );
  }

  void _fitTrack() {
    final fit = _trackFit;
    if (fit != null) _controller.fitCamera(fit);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.replay;
    final fi = widget.frameIndex;
    final nowMs = r.frames[fi].tMs;
    final told = _toldIds(r, fi);
    final places = <String, MapPlace>{
      for (final p in widget.map.landmarks) p.id: p,
      // 歩行ログのタイルで届いたものを重ねる（同じ ID はログの方）
      for (final lm in r.landmarks)
        lm.id: MapPlace(
          id: lm.id,
          name: lm.name,
          kind: lm.kind,
          lat: lm.lat,
          lon: lm.lon,
          radiusM: lm.radiusM,
        ),
    };
    final crossings = <String, MapPlace>{
      for (final c in widget.map.crossings) c.id: c,
      for (final c in r.crossings)
        c.id: MapPlace(
          id: c.id,
          name: '',
          kind: c.kind,
          lat: c.lat,
          lon: c.lon,
        ),
    };
    final past = <LatLng>[], future = <LatLng>[];
    for (final t in r.track) {
      final p = LatLng(t.position.lat, t.position.lon);
      if (t.tMs <= nowMs) {
        past.add(p);
      } else {
        if (future.isEmpty && past.isNotEmpty) future.add(past.last);
        future.add(p);
      }
    }
    final sensor = r.frames[fi].sensor;

    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCameraFit: _trackFit,
            initialCenter: const LatLng(36.7016, 137.2129), // 富山駅（ログが無いとき）
            initialZoom: 16,
            maxZoom: 18,
            onMapReady: () => _ready = true,
            onPositionChanged: (_, hasGesture) {
              if (hasGesture && _follow) setState(() => _follow = false);
            },
          ),
          children: [
            if (widget.showTiles)
              TileLayer(
                urlTemplate: _photo ? _gsiPhoto : _gsiStd,
                maxNativeZoom: 18,
                userAgentPackageName: 'jp.dfhack26.viewer',
              ),
            CircleLayer(
              circles: [
                for (final p in places.values)
                  CircleMarker(
                    point: LatLng(p.lat, p.lon),
                    radius: p.radiusM ?? 25,
                    useRadiusInMeter: true,
                    color: _landmarkColor.withValues(
                      alpha: told.contains(p.id) ? 0.05 : 0.12,
                    ),
                    borderColor: told.contains(p.id)
                        ? Colors.grey
                        : _landmarkColor,
                    borderStrokeWidth: 1,
                  ),
                for (final c in crossings.values)
                  CircleMarker(
                    point: LatLng(c.lat, c.lon),
                    radius: 3,
                    color:
                        (c.kind == 'traffic_signals'
                                ? _signalColor
                                : _crosswalkColor)
                            .withValues(alpha: 0.8),
                  ),
              ],
            ),
            PolylineLayer(
              polylines: [
                if (future.length >= 2)
                  Polyline(
                    points: future,
                    strokeWidth: 3,
                    color: Colors.black26,
                  ),
                if (past.length >= 2)
                  Polyline(points: past, strokeWidth: 4, color: _trackColor),
              ],
            ),
            CircleLayer(
              circles: [
                for (final e in widget.map.events)
                  _dot(LatLng(e.lat, e.lon), _eventColor),
                for (final p in places.values)
                  _dot(
                    LatLng(p.lat, p.lon),
                    told.contains(p.id) ? Colors.grey : _landmarkColor,
                  ),
                for (final s in r.speaks)
                  if (s.frameIndex <= fi)
                    if (r.frames[s.frameIndex].sensor case final ss?)
                      _dot(LatLng(ss.lat, ss.lon), _speakColor, radius: 6),
              ],
            ),
            PolygonLayer(
              polygons: [
                for (final s in r.searches)
                  if (s.frameIndex <= fi)
                    if (s.position case final p?)
                      Polygon(
                        points: _square(LatLng(p.lat, p.lon), 4),
                        borderColor: _searchColor,
                        borderStrokeWidth: 2,
                        color: _searchColor.withValues(alpha: 0.2),
                      ),
              ],
            ),
            MarkerLayer(
              markers: [
                for (final p in places.values)
                  Marker(
                    point: LatLng(p.lat, p.lon),
                    width: 200,
                    height: 22,
                    alignment: const Alignment(1.1, 0),
                    child: _Label(
                      p.name,
                      color: told.contains(p.id) ? Colors.grey : Colors.black87,
                    ),
                  ),
                for (final e in widget.map.events)
                  Marker(
                    point: LatLng(e.lat, e.lon),
                    width: 240,
                    height: 22,
                    alignment: const Alignment(1.08, 1.6),
                    child: _Label(e.name, color: _eventColor),
                  ),
                if (sensor != null)
                  Marker(
                    point: LatLng(sensor.lat, sensor.lon),
                    width: 64,
                    height: 64,
                    child: _PositionMark(gazeAzDeg: sensor.gazeAzDeg),
                  ),
              ],
            ),
          ],
        ),
        // 出典は畳まずに常に出す（地理院タイル・OpenStreetMap の決まり）
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            color: Colors.white.withValues(alpha: 0.8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: const Text(
              '地図：地理院タイル（国土地理院）　横断歩道・信号の位置：© OpenStreetMap contributors',
              style: TextStyle(fontSize: 11, color: Colors.black87),
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('地図')),
                      ButtonSegment(value: true, label: Text('航空写真')),
                    ],
                    selected: {_photo},
                    onSelectionChanged: (v) => setState(() => _photo = v.first),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'いまの位置を追う',
                    isSelected: _follow,
                    icon: const Icon(Icons.my_location),
                    onPressed: () {
                      setState(() => _follow = !_follow);
                      final p = _position;
                      if (_follow && p != null && _ready) {
                        _controller.move(p, _controller.camera.zoom);
                      }
                    },
                  ),
                  IconButton(
                    tooltip: '歩いた範囲を表示',
                    icon: const Icon(Icons.zoom_out_map),
                    onPressed: () {
                      setState(() => _follow = false);
                      if (_ready) _fitTrack();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static CircleMarker _dot(LatLng p, Color c, {double radius = 7}) =>
      CircleMarker(
        point: p,
        radius: radius,
        color: c,
        borderColor: Colors.white,
        borderStrokeWidth: 2,
      );

  /// 一辺 2×halfM メートルの正方形（B で撮った場所の印）。
  static List<LatLng> _square(LatLng c, double halfM) {
    final dLat = halfM / 111320;
    final dLon = halfM / (111320 * math.cos(c.latitude * math.pi / 180));
    return [
      LatLng(c.latitude - dLat, c.longitude - dLon),
      LatLng(c.latitude - dLat, c.longitude + dLon),
      LatLng(c.latitude + dLat, c.longitude + dLon),
      LatLng(c.latitude + dLat, c.longitude - dLon),
    ];
  }

  /// この時点までに A で紹介したランドマーク（B は全体を話さないので、A の紹介だけ）。
  static Set<String> _toldIds(Replay r, int fi) => {
    for (final n in r.frames[fi].view.nearby)
      if (n.told) n.id,
    for (final d in r.decisions)
      if (d.frameIndex <= fi && d.decision.kind == 'speak')
        ?d.decision.targetId,
  };
}

class _Label extends StatelessWidget {
  final String text;
  final Color color;
  const _Label(this.text, {required this.color});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: color),
      ),
    ),
  );
}

/// いまの位置（点）と視線の向き（矢印）。
class _PositionMark extends StatelessWidget {
  final double gazeAzDeg;
  const _PositionMark({required this.gazeAzDeg});
  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Transform.rotate(
        angle: gazeAzDeg * math.pi / 180,
        child: const Align(
          alignment: Alignment.topCenter,
          child: Icon(Icons.navigation, size: 28, color: _trackColor),
        ),
      ),
      Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: _trackColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
        ),
      ),
    ],
  );
}

/// 視線から見た角度を「右前方 30°」のような言い方にする（画面の表示用）。
String relativeLabel(double deg, EngineConfig config) =>
    '${directionWord(deg, config)} ${deg.abs().round()}°';

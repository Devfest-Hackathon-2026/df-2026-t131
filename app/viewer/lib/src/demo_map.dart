import 'package:engine/engine.dart';

// 独自マップ（チームで作ったデモの範囲の地図）を viewer で描くためのデータ。
//
// 元データは API の SQLite（cloud/data/scripts/build_sqlite.py が作る tiles.sqlite）と同じ
//   cloud/data/manual/landmarks/*.json（reviewed のものだけ）
//   cloud/data/osm/crossings.json
//   cloud/data/manual/events.json
// SQLite は Git 管理外で、Web では読めないので、tool/build_map.dart で assets/map.json に書き出す。
// 描くのに要る項目（ID・名前・種類・位置・範囲）だけを持つ。原稿は持たない。

final class MapPlace {
  final String id, name, kind;
  final double lat, lon;
  final double? radiusM;
  const MapPlace({
    required this.id,
    required this.name,
    required this.kind,
    required this.lat,
    required this.lon,
    this.radiusM,
  });

  factory MapPlace.fromJson(Map<String, dynamic> j) => MapPlace(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: j['kind'] as String,
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    radiusM: (j['radius_m'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'lat': lat,
    'lon': lon,
    if (radiusM != null) 'radius_m': radiusM,
  };
}

final class DemoMap {
  final List<MapPlace> landmarks;
  final List<MapPlace> crossings;
  final List<MapPlace> events;

  /// 地図に必ず出す出典の表示（OpenStreetMap など）。
  final List<String> attributions;

  const DemoMap({
    required this.landmarks,
    required this.crossings,
    required this.events,
    required this.attributions,
  });

  static const empty = DemoMap(
    landmarks: [],
    crossings: [],
    events: [],
    attributions: [],
  );

  factory DemoMap.fromJson(Map<String, dynamic> j) {
    List<MapPlace> places(String key) => [
      for (final p in j[key] as List)
        MapPlace.fromJson(p as Map<String, dynamic>),
    ];
    return DemoMap(
      landmarks: places('landmarks'),
      crossings: places('crossings'),
      events: places('events'),
      attributions: [for (final a in j['attributions'] as List) a as String],
    );
  }

  Map<String, dynamic> toJson() => {
    'note': 'tool/build_map.dart が cloud/data から作ったファイル。手で書き換えない',
    'attributions': attributions,
    'landmarks': [for (final p in landmarks) p.toJson()],
    'crossings': [for (final p in crossings) p.toJson()],
    'events': [for (final p in events) p.toJson()],
  };

  /// cloud/data の元データ（JSON を読んだもの）から作る。形は engine のモデルで確かめる。
  /// API の SQLite と同じく、ランドマークは status が reviewed のものだけを入れる。
  factory DemoMap.fromSources({
    required List<Map<String, dynamic>> landmarkFiles,
    required Map<String, dynamic> crossingsFile,
    required Map<String, dynamic>? eventsFile,
  }) {
    final landmarks = <MapPlace>[
      for (final json in landmarkFiles)
        // 1件1ファイルの形（schema の landmark_entry）は schema_version を持つので外して読む
        if (LandmarkRecord.fromJson({...json}..remove('schema_version'))
            case final r when r.status == 'reviewed')
          MapPlace(
            id: r.id,
            name: r.name,
            kind: r.kind,
            lat: r.lat,
            lon: r.lon,
            radiusM: r.radiusM,
          ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    final crossings = <MapPlace>[
      for (final c in crossingsFile['crossings'] as List)
        if (Crossing.fromJson(c as Map<String, dynamic>) case final x)
          MapPlace(id: x.id, name: '', kind: x.kind, lat: x.lat, lon: x.lon),
    ]..sort((a, b) => a.id.compareTo(b.id));
    final events = <MapPlace>[
      for (final e in (eventsFile?['events'] as List?) ?? const [])
        if (LocalEvent.fromJson(e as Map<String, dynamic>) case final x)
          MapPlace(
            id: x.id,
            name: x.name,
            kind: 'event',
            lat: x.lat,
            lon: x.lon,
          ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    final source = crossingsFile['source'] as Map<String, dynamic>?;
    return DemoMap(
      landmarks: landmarks,
      crossings: crossings,
      events: events,
      attributions: [if (source?['title'] case final String t) '横断歩道・信号：$t'],
    );
  }
}

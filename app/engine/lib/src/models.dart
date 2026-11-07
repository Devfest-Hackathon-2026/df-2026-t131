// schema 0.3の項目に対応する値オブジェクト。任意項目の省略とnullを区別する。
import 'constants.dart';
import 'wire.dart';

final class TileId {
  final int z;
  final int x;
  final int y;
  TileId._({required this.z, required this.x, required this.y});
  factory TileId({int z = 16, required int x, required int y}) =>
      TileId.fromJson({"z": z, "x": x, "y": y});
  factory TileId.fromJson(Map<String, dynamic> json) {
    wireKeys(json, ["z", "x", "y"], ["z", "x", "y"]);
    final result = TileId._(
      z: wireInt(json["z"], "z", constant: 16),
      x: wireInt(json["x"], "x", min: 0),
      y: wireInt(json["y"], "y", min: 0),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {"z": z, "x": x, "y": y};
}

final class DataSource {
  final String title;
  final String url;
  final String license;
  DataSource._({required this.title, required this.url, required this.license});
  factory DataSource({
    required String title,
    required String url,
    required String license,
  }) => DataSource.fromJson({"title": title, "url": url, "license": license});
  factory DataSource.fromJson(Map<String, dynamic> json) {
    wireKeys(json, ["title", "url", "license"], ["title", "url", "license"]);
    final result = DataSource._(
      title: wireString(json["title"], "title"),
      url: wireString(json["url"], "url"),
      license: wireString(json["license"], "license"),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "title": title,
    "url": url,
    "license": license,
  };
}

final class ImageQuality {
  final double blur;
  final double brightness;

  /// 画像の下の方（路面）に横断歩道の縞模様が写っている度合い（0〜1。任意。11/7 追加）。
  /// mobile が端末の中で計算する。古いログ・計算しない端末では null（地図だけで判定する）。
  final double? crosswalk;
  ImageQuality._({
    required this.blur,
    required this.brightness,
    required this.crosswalk,
  });
  factory ImageQuality({
    required double blur,
    required double brightness,
    double? crosswalk,
  }) => ImageQuality.fromJson({
    "blur": blur,
    "brightness": brightness,
    if (crosswalk != null) "crosswalk": crosswalk,
  });
  factory ImageQuality.fromJson(Map<String, dynamic> json) {
    wireKeys(json, ["blur", "brightness"], ["blur", "brightness", "crosswalk"]);
    final result = ImageQuality._(
      blur: wireDouble(json["blur"], "blur", min: 0, max: 1),
      brightness: wireDouble(json["brightness"], "brightness", min: 0, max: 1),
      crosswalk: json.containsKey("crosswalk")
          ? wireDouble(json["crosswalk"], "crosswalk", min: 0, max: 1)
          : null,
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "blur": blur,
    "brightness": brightness,
    if (crosswalk != null) "crosswalk": crosswalk,
  };
}

final class Departure {
  final String line;
  final String headsign;
  final String timeLocal;
  Departure._({
    required this.line,
    required this.headsign,
    required this.timeLocal,
  });
  factory Departure({
    required String line,
    required String headsign,
    required String timeLocal,
  }) => Departure.fromJson({
    "line": line,
    "headsign": headsign,
    "time_local": timeLocal,
  });
  factory Departure.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      ["line", "headsign", "time_local"],
      ["line", "headsign", "time_local"],
    );
    final result = Departure._(
      line: wireString(json["line"], "line"),
      headsign: wireString(json["headsign"], "headsign"),
      timeLocal: wireString(
        json["time_local"],
        "time_local",
        pattern: r'^([01]\d|2[0-3]):[0-5]\d$',
      ),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "line": line,
    "headsign": headsign,
    "time_local": timeLocal,
  };
}

final class TransitStop {
  final String id;
  final String name;
  final String nameKana;
  final double lat;
  final double lon;
  final List<Departure> departures;
  TransitStop._({
    required this.id,
    required this.name,
    required this.nameKana,
    required this.lat,
    required this.lon,
    required this.departures,
  });
  factory TransitStop({
    required String id,
    required String name,
    required String nameKana,
    required double lat,
    required double lon,
    required List<Departure> departures,
  }) => TransitStop.fromJson({
    "id": id,
    "name": name,
    "name_kana": nameKana,
    "lat": lat,
    "lon": lon,
    "departures": departures.map((item) => item.toJson()).toList(),
  });
  factory TransitStop.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      ["id", "name", "name_kana", "lat", "lon", "departures"],
      ["id", "name", "name_kana", "lat", "lon", "departures"],
    );
    final result = TransitStop._(
      id: wireString(json["id"], "id", pattern: r'^st_\d{4}$'),
      name: wireString(json["name"], "name"),
      nameKana: wireString(json["name_kana"], "name_kana"),
      lat: wireDouble(json["lat"], "lat", min: -90, max: 90),
      lon: wireDouble(json["lon"], "lon", min: -180, max: 180),
      departures: wireList(
        json["departures"],
        "departures",
        (value) => Departure.fromJson(wireMap(value, "departures")),
      ),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "name_kana": nameKana,
    "lat": lat,
    "lon": lon,
    "departures": departures.map((item) => item.toJson()).toList(),
  };
}

final class Crossing {
  final String id;
  final double lat;
  final double lon;
  final String kind;
  Crossing._({
    required this.id,
    required this.lat,
    required this.lon,
    required this.kind,
  });
  factory Crossing({
    required String id,
    required double lat,
    required double lon,
    required String kind,
  }) => Crossing.fromJson({"id": id, "lat": lat, "lon": lon, "kind": kind});
  factory Crossing.fromJson(Map<String, dynamic> json) {
    wireKeys(json, ["id", "lat", "lon", "kind"], ["id", "lat", "lon", "kind"]);
    final result = Crossing._(
      id: wireString(json["id"], "id", pattern: r'^cr_\d{4,6}$'),
      lat: wireDouble(json["lat"], "lat", min: -90, max: 90),
      lon: wireDouble(json["lon"], "lon", min: -180, max: 180),
      kind: wireString(
        json["kind"],
        "kind",
        values: ["crossing", "traffic_signals"],
      ),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "id": id,
    "lat": lat,
    "lon": lon,
    "kind": kind,
  };
}

final class LocalEvent {
  final String id;
  final String name;
  final double lat;
  final double lon;
  final int startTMs;
  final int endTMs;
  final String status;
  LocalEvent._({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.startTMs,
    required this.endTMs,
    required this.status,
  });
  factory LocalEvent({
    required String id,
    required String name,
    required double lat,
    required double lon,
    required int startTMs,
    required int endTMs,
    required String status,
  }) => LocalEvent.fromJson({
    "id": id,
    "name": name,
    "lat": lat,
    "lon": lon,
    "start_t_ms": startTMs,
    "end_t_ms": endTMs,
    "status": status,
  });
  factory LocalEvent.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      ["id", "name", "lat", "lon", "start_t_ms", "end_t_ms", "status"],
      ["id", "name", "lat", "lon", "start_t_ms", "end_t_ms", "status"],
    );
    final result = LocalEvent._(
      id: wireString(json["id"], "id", pattern: r'^ev_\d{4}$'),
      name: wireString(json["name"], "name"),
      lat: wireDouble(json["lat"], "lat", min: -90, max: 90),
      lon: wireDouble(json["lon"], "lon", min: -180, max: 180),
      startTMs: wireInt(json["start_t_ms"], "start_t_ms", min: 0),
      endTMs: wireInt(json["end_t_ms"], "end_t_ms", min: 0),
      status: wireString(
        json["status"],
        "status",
        values: ["scheduled", "held", "cancelled"],
      ),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "lat": lat,
    "lon": lon,
    "start_t_ms": startTMs,
    "end_t_ms": endTMs,
    "status": status,
  };
}

final class Landmark {
  final String id;
  final String name;
  final String nameKana;
  final double lat;
  final double lon;
  final String kind;
  final double? radiusM;
  final String scriptShort;
  final String scriptLong;
  final String visualHint;
  final List<DataSource>? sources;
  final String? googlePlaceId;
  final List<String>? nameHints;
  final Set<String> _presentKeys;
  Landmark._({
    required this.id,
    required this.name,
    required this.nameKana,
    required this.lat,
    required this.lon,
    required this.kind,
    required this.radiusM,
    required this.scriptShort,
    required this.scriptLong,
    required this.visualHint,
    required this.sources,
    required this.googlePlaceId,
    required this.nameHints,
    required Set<String> presentKeys,
  }) : _presentKeys = Set.unmodifiable(presentKeys);
  factory Landmark({
    required String id,
    required String name,
    required String nameKana,
    required double lat,
    required double lon,
    required String kind,
    double? radiusM,
    required String scriptShort,
    required String scriptLong,
    required String visualHint,
    List<DataSource>? sources,
    String? googlePlaceId,
    List<String>? nameHints,
  }) => Landmark.fromJson({
    "id": id,
    "name": name,
    "name_kana": nameKana,
    "lat": lat,
    "lon": lon,
    "kind": kind,
    if (radiusM != null) "radius_m": radiusM,
    "script_short": scriptShort,
    "script_long": scriptLong,
    "visual_hint": visualHint,
    if (sources != null)
      "sources": sources.map((item) => item.toJson()).toList(),
    if (googlePlaceId != null) "google_place_id": googlePlaceId,
    if (nameHints != null) "name_hints": List.of(nameHints),
  });
  factory Landmark.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      [
        "id",
        "name",
        "name_kana",
        "lat",
        "lon",
        "kind",
        "script_short",
        "script_long",
        "visual_hint",
      ],
      [
        "id",
        "name",
        "name_kana",
        "lat",
        "lon",
        "kind",
        "radius_m",
        "script_short",
        "script_long",
        "visual_hint",
        "sources",
        "google_place_id",
        "name_hints",
      ],
    );
    final result = Landmark._(
      id: wireString(json["id"], "id", pattern: r'^lm_\d{4}$'),
      name: wireString(json["name"], "name", minLength: 1),
      nameKana: wireString(
        json["name_kana"],
        "name_kana",
        pattern: r'^[ぁ-ゖー・\s]+$',
      ),
      lat: wireDouble(json["lat"], "lat", min: -90, max: 90),
      lon: wireDouble(json["lon"], "lon", min: -180, max: 180),
      kind: wireString(
        json["kind"],
        "kind",
        values: [
          "area",
          "monument",
          "building",
          "street",
          "place_name",
          "shrine_temple",
          "nature",
          "other",
        ],
      ),
      radiusM: json["radius_m"] == null
          ? null
          : wireDouble(json["radius_m"], "radius_m", exclusiveMin: 0),
      scriptShort: wireString(
        json["script_short"],
        "script_short",
        maxLength: 80,
      ),
      scriptLong: wireString(
        json["script_long"],
        "script_long",
        maxLength: 200,
      ),
      visualHint: wireString(json["visual_hint"], "visual_hint"),
      sources: json.containsKey("sources")
          ? wireList(
              json["sources"],
              "sources",
              (value) => DataSource.fromJson(wireMap(value, "sources")),
              min: 1,
            )
          : null,
      googlePlaceId: json["google_place_id"] == null
          ? null
          : wireString(json["google_place_id"], "google_place_id"),
      nameHints: json.containsKey("name_hints")
          ? wireList(
              json["name_hints"],
              "name_hints",
              (value) => wireString(value, "name_hints"),
              max: 30,
            )
          : null,
      presentKeys: json.keys.toSet(),
    );
    if (result.kind == 'area' && result.radiusM == null) {
      throw FormatException('areaにはradius_mが必要です');
    }
    return result;
  }
  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "name_kana": nameKana,
    "lat": lat,
    "lon": lon,
    "kind": kind,
    if (_presentKeys.contains("radius_m")) "radius_m": radiusM,
    "script_short": scriptShort,
    "script_long": scriptLong,
    "visual_hint": visualHint,
    if (_presentKeys.contains("sources"))
      "sources": sources?.map((item) => item.toJson()).toList(),
    if (_presentKeys.contains("google_place_id"))
      "google_place_id": googlePlaceId,
    if (_presentKeys.contains("name_hints"))
      "name_hints": nameHints == null ? null : List.of(nameHints!),
  };
}

final class LandmarkRecord {
  final String id;
  final String name;
  final String nameKana;
  final double lat;
  final double lon;
  final String kind;
  final double? radiusM;
  final String scriptShort;
  final String scriptLong;
  final String visualHint;
  final List<DataSource> sources;
  final String status;
  final String? googlePlaceId;
  final List<String>? nameHints;
  final Set<String> _presentKeys;
  LandmarkRecord._({
    required this.id,
    required this.name,
    required this.nameKana,
    required this.lat,
    required this.lon,
    required this.kind,
    required this.radiusM,
    required this.scriptShort,
    required this.scriptLong,
    required this.visualHint,
    required this.sources,
    required this.status,
    required this.googlePlaceId,
    required this.nameHints,
    required Set<String> presentKeys,
  }) : _presentKeys = Set.unmodifiable(presentKeys);
  factory LandmarkRecord({
    required String id,
    required String name,
    required String nameKana,
    required double lat,
    required double lon,
    required String kind,
    double? radiusM,
    required String scriptShort,
    required String scriptLong,
    required String visualHint,
    required List<DataSource> sources,
    required String status,
    String? googlePlaceId,
    List<String>? nameHints,
  }) => LandmarkRecord.fromJson({
    "id": id,
    "name": name,
    "name_kana": nameKana,
    "lat": lat,
    "lon": lon,
    "kind": kind,
    if (radiusM != null) "radius_m": radiusM,
    "script_short": scriptShort,
    "script_long": scriptLong,
    "visual_hint": visualHint,
    "sources": sources.map((item) => item.toJson()).toList(),
    "status": status,
    if (googlePlaceId != null) "google_place_id": googlePlaceId,
    if (nameHints != null) "name_hints": List.of(nameHints),
  });
  factory LandmarkRecord.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      [
        "id",
        "name",
        "name_kana",
        "lat",
        "lon",
        "kind",
        "script_short",
        "script_long",
        "visual_hint",
        "sources",
        "status",
      ],
      [
        "id",
        "name",
        "name_kana",
        "lat",
        "lon",
        "kind",
        "radius_m",
        "script_short",
        "script_long",
        "visual_hint",
        "sources",
        "status",
        "google_place_id",
        "name_hints",
      ],
    );
    final result = LandmarkRecord._(
      id: wireString(json["id"], "id", pattern: r'^lm_\d{4}$'),
      name: wireString(json["name"], "name", minLength: 1),
      nameKana: wireString(
        json["name_kana"],
        "name_kana",
        pattern: r'^[ぁ-ゖー・\s]+$',
      ),
      lat: wireDouble(json["lat"], "lat", min: -90, max: 90),
      lon: wireDouble(json["lon"], "lon", min: -180, max: 180),
      kind: wireString(
        json["kind"],
        "kind",
        values: [
          "area",
          "monument",
          "building",
          "street",
          "place_name",
          "shrine_temple",
          "nature",
          "other",
        ],
      ),
      radiusM: json["radius_m"] == null
          ? null
          : wireDouble(json["radius_m"], "radius_m", exclusiveMin: 0),
      scriptShort: wireString(
        json["script_short"],
        "script_short",
        maxLength: 80,
      ),
      scriptLong: wireString(
        json["script_long"],
        "script_long",
        maxLength: 200,
      ),
      visualHint: wireString(json["visual_hint"], "visual_hint"),
      sources: wireList(
        json["sources"],
        "sources",
        (value) => DataSource.fromJson(wireMap(value, "sources")),
        min: 1,
      ),
      status: wireString(
        json["status"],
        "status",
        values: ["draft", "reviewed"],
      ),
      googlePlaceId: json["google_place_id"] == null
          ? null
          : wireString(json["google_place_id"], "google_place_id"),
      nameHints: json.containsKey("name_hints")
          ? wireList(
              json["name_hints"],
              "name_hints",
              (value) => wireString(value, "name_hints"),
              max: 30,
            )
          : null,
      presentKeys: json.keys.toSet(),
    );
    if (result.kind == 'area' && result.radiusM == null) {
      throw FormatException('areaにはradius_mが必要です');
    }
    if (result.status == 'reviewed' &&
        (result.scriptShort.isEmpty || result.scriptLong.isEmpty)) {
      throw FormatException('reviewedには確認済み原稿が必要です');
    }
    if (result.kind != 'area' && json.containsKey('name_hints')) {
      throw FormatException('name_hintsはareaだけに指定できます');
    }
    return result;
  }
  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "name_kana": nameKana,
    "lat": lat,
    "lon": lon,
    "kind": kind,
    if (_presentKeys.contains("radius_m")) "radius_m": radiusM,
    "script_short": scriptShort,
    "script_long": scriptLong,
    "visual_hint": visualHint,
    "sources": sources.map((item) => item.toJson()).toList(),
    "status": status,
    if (_presentKeys.contains("google_place_id"))
      "google_place_id": googlePlaceId,
    if (_presentKeys.contains("name_hints"))
      "name_hints": nameHints == null ? null : List.of(nameHints!),
  };
}

final class LandmarksFile {
  final String schemaVersion;
  final List<LandmarkRecord> landmarks;
  LandmarksFile._({required this.schemaVersion, required this.landmarks});
  factory LandmarksFile({
    String schemaVersion = currentSchemaVersion,
    required List<LandmarkRecord> landmarks,
  }) => LandmarksFile.fromJson({
    "schema_version": schemaVersion,
    "landmarks": landmarks.map((item) => item.toJson()).toList(),
  });
  factory LandmarksFile.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      ["schema_version", "landmarks"],
      ["schema_version", "landmarks"],
    );
    final result = LandmarksFile._(
      schemaVersion: wireString(
        json["schema_version"],
        "schema_version",
        pattern: r'^\d+\.\d+$',
      ),
      landmarks: wireList(
        json["landmarks"],
        "landmarks",
        (value) => LandmarkRecord.fromJson(wireMap(value, "landmarks")),
      ),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "schema_version": schemaVersion,
    "landmarks": landmarks.map((item) => item.toJson()).toList(),
  };
}

/// 町丁目の代表点（schema/town.schema.json）。タイルの応答の towns に入る。
final class Town {
  final String id;
  final String name;
  final double lat;
  final double lon;
  Town._({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
  });
  factory Town({
    required String id,
    required String name,
    required double lat,
    required double lon,
  }) => Town.fromJson({"id": id, "name": name, "lat": lat, "lon": lon});
  factory Town.fromJson(Map<String, dynamic> json) {
    wireKeys(json, ["id", "name", "lat", "lon"], ["id", "name", "lat", "lon"]);
    final result = Town._(
      id: wireString(json["id"], "id", pattern: r'^[0-9]{12}$'),
      name: wireString(json["name"], "name", minLength: 1),
      lat: wireDouble(json["lat"], "lat", min: -90, max: 90),
      lon: wireDouble(json["lon"], "lon", min: -180, max: 180),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "lat": lat,
    "lon": lon,
  };
}

/// カメラで調べない区域（schema/zone.schema.json）。タイルの応答の zones に入る。
final class Zone {
  final String id;
  final String name;
  final double lat;
  final double lon;
  final double radiusM;
  final String reason;
  Zone._({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.radiusM,
    required this.reason,
  });
  factory Zone({
    required String id,
    required String name,
    required double lat,
    required double lon,
    required double radiusM,
    required String reason,
  }) => Zone.fromJson({
    "id": id,
    "name": name,
    "lat": lat,
    "lon": lon,
    "radius_m": radiusM,
    "reason": reason,
  });
  factory Zone.fromJson(Map<String, dynamic> json) {
    const keys = ["id", "name", "lat", "lon", "radius_m", "reason"];
    wireKeys(json, keys, keys);
    final result = Zone._(
      id: wireString(json["id"], "id", pattern: r'^zn_\d{4}$'),
      name: wireString(json["name"], "name", minLength: 1),
      lat: wireDouble(json["lat"], "lat", min: -90, max: 90),
      lon: wireDouble(json["lon"], "lon", min: -180, max: 180),
      radiusM: wireDouble(json["radius_m"], "radius_m", min: 5, max: 300),
      reason: wireString(
        json["reason"],
        "reason",
        values: ["demo", "facility_rule", "indoor"],
      ),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "lat": lat,
    "lon": lon,
    "radius_m": radiusM,
    "reason": reason,
  };
}

final class TileResponse {
  final String schemaVersion;
  final TileId tile;
  final List<Landmark> landmarks;
  final List<TransitStop> stops;
  final List<Crossing> crossings;
  final List<LocalEvent> events;

  /// このタイルの中に代表点がある町丁目。端末に残っている古いタイルには無いので、無ければ空。
  final List<Town> towns;
  final bool _hasTowns;

  /// カメラで調べない区域。古いタイルには無いので、無ければ空。
  final List<Zone> zones;
  final bool _hasZones;
  TileResponse._({
    required this.schemaVersion,
    required this.tile,
    required this.landmarks,
    required this.stops,
    required this.crossings,
    required this.events,
    required this.towns,
    required bool hasTowns,
    required this.zones,
    required bool hasZones,
  }) : _hasTowns = hasTowns,
       _hasZones = hasZones;
  factory TileResponse({
    String schemaVersion = currentSchemaVersion,
    required TileId tile,
    required List<Landmark> landmarks,
    required List<TransitStop> stops,
    required List<Crossing> crossings,
    required List<LocalEvent> events,
    List<Town>? towns,
    List<Zone>? zones,
  }) => TileResponse.fromJson({
    "schema_version": schemaVersion,
    "tile": tile.toJson(),
    "landmarks": landmarks.map((item) => item.toJson()).toList(),
    "stops": stops.map((item) => item.toJson()).toList(),
    "crossings": crossings.map((item) => item.toJson()).toList(),
    "events": events.map((item) => item.toJson()).toList(),
    if (towns != null) "towns": towns.map((item) => item.toJson()).toList(),
    if (zones != null) "zones": zones.map((item) => item.toJson()).toList(),
  });
  factory TileResponse.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      ["schema_version", "tile", "landmarks", "stops", "crossings", "events"],
      [
        "schema_version",
        "tile",
        "landmarks",
        "stops",
        "crossings",
        "events",
        "towns",
        "zones",
      ],
    );
    final result = TileResponse._(
      schemaVersion: wireString(
        json["schema_version"],
        "schema_version",
        pattern: r'^\d+\.\d+$',
      ),
      tile: TileId.fromJson(wireMap(json["tile"], "tile")),
      landmarks: wireList(
        json["landmarks"],
        "landmarks",
        (value) => Landmark.fromJson(wireMap(value, "landmarks")),
      ),
      stops: wireList(
        json["stops"],
        "stops",
        (value) => TransitStop.fromJson(wireMap(value, "stops")),
      ),
      crossings: wireList(
        json["crossings"],
        "crossings",
        (value) => Crossing.fromJson(wireMap(value, "crossings")),
      ),
      events: wireList(
        json["events"],
        "events",
        (value) => LocalEvent.fromJson(wireMap(value, "events")),
      ),
      towns: json.containsKey("towns")
          ? wireList(
              json["towns"],
              "towns",
              (value) => Town.fromJson(wireMap(value, "towns")),
            )
          : const [],
      hasTowns: json.containsKey("towns"),
      zones: json.containsKey("zones")
          ? wireList(
              json["zones"],
              "zones",
              (value) => Zone.fromJson(wireMap(value, "zones")),
            )
          : const [],
      hasZones: json.containsKey("zones"),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "schema_version": schemaVersion,
    "tile": tile.toJson(),
    "landmarks": landmarks.map((item) => item.toJson()).toList(),
    "stops": stops.map((item) => item.toJson()).toList(),
    "crossings": crossings.map((item) => item.toJson()).toList(),
    "events": events.map((item) => item.toJson()).toList(),
    if (_hasTowns) "towns": towns.map((item) => item.toJson()).toList(),
    if (_hasZones) "zones": zones.map((item) => item.toJson()).toList(),
  };
}

final class VisualSearchSource {
  final String title;
  final String uri;
  final String? placeId;
  final Set<String> _presentKeys;
  VisualSearchSource._({
    required this.title,
    required this.uri,
    required this.placeId,
    required Set<String> presentKeys,
  }) : _presentKeys = Set.unmodifiable(presentKeys);
  factory VisualSearchSource({
    required String title,
    required String uri,
    String? placeId,
  }) => VisualSearchSource.fromJson({
    "title": title,
    "uri": uri,
    if (placeId != null) "place_id": placeId,
  });
  factory VisualSearchSource.fromJson(Map<String, dynamic> json) {
    wireKeys(json, ["title", "uri"], ["title", "uri", "place_id"]);
    final result = VisualSearchSource._(
      title: wireString(json["title"], "title"),
      uri: wireString(json["uri"], "uri"),
      placeId: json["place_id"] == null
          ? null
          : wireString(json["place_id"], "place_id"),
      presentKeys: json.keys.toSet(),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "title": title,
    "uri": uri,
    if (_presentKeys.contains("place_id")) "place_id": placeId,
  };
}

final class VisualSearchResponse {
  final String schemaVersion;
  final String searchId;
  final String result;
  final String? landmarkId;
  final String? objectName;
  final String? description;

  /// 中央に写っているのがどの部分か（`visualParts` のどれか）。unknown のときだけ null。
  final String? part;
  final double confidence;
  final bool named;
  final List<VisualSearchSource> sources;
  VisualSearchResponse._({
    required this.schemaVersion,
    required this.searchId,
    required this.result,
    required this.landmarkId,
    required this.objectName,
    required this.description,
    required this.part,
    required this.confidence,
    required this.named,
    required this.sources,
  });
  factory VisualSearchResponse({
    String schemaVersion = currentSchemaVersion,
    required String searchId,
    required String result,
    required String? landmarkId,
    required String? objectName,
    required String? description,
    required String? part,
    required double confidence,
    required bool named,
    required List<VisualSearchSource> sources,
  }) => VisualSearchResponse.fromJson({
    "schema_version": schemaVersion,
    "search_id": searchId,
    "result": result,
    "landmark_id": landmarkId,
    "object_name": objectName,
    "description": description,
    "part": part,
    "confidence": confidence,
    "named": named,
    "sources": sources.map((item) => item.toJson()).toList(),
  });
  factory VisualSearchResponse.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      [
        "schema_version",
        "search_id",
        "result",
        "landmark_id",
        "object_name",
        "description",
        "part",
        "confidence",
        "sources",
        "named",
      ],
      [
        "schema_version",
        "search_id",
        "result",
        "landmark_id",
        "object_name",
        "description",
        "part",
        "confidence",
        "named",
        "sources",
      ],
    );
    final result = VisualSearchResponse._(
      schemaVersion: wireString(
        json["schema_version"],
        "schema_version",
        pattern: r'^\d+\.\d+$',
      ),
      searchId: wireString(json["search_id"], "search_id"),
      result: wireString(
        json["result"],
        "result",
        values: ["matched", "unlisted", "unknown"],
      ),
      landmarkId: json["landmark_id"] == null
          ? null
          : wireString(
              json["landmark_id"],
              "landmark_id",
              pattern: r'^lm_\d{4}$',
            ),
      objectName: json["object_name"] == null
          ? null
          : wireString(json["object_name"], "object_name"),
      description: json["description"] == null
          ? null
          : wireString(json["description"], "description", maxLength: 120),
      part: json["part"] == null
          ? null
          : wireString(json["part"], "part", values: visualParts),
      confidence: wireDouble(json["confidence"], "confidence", min: 0, max: 1),
      named: wireBool(json["named"], "named"),
      sources: wireList(
        json["sources"],
        "sources",
        (value) => VisualSearchSource.fromJson(wireMap(value, "sources")),
      ),
    );
    // matched：全体（whole）なら説明なし、部分なら特徴の説明あり。unknown だけ part が null。
    final valid = switch (result.result) {
      'matched' =>
        result.landmarkId != null &&
            result.objectName == null &&
            result.part != null &&
            (result.part == 'whole') == (result.description == null),
      'unlisted' =>
        result.landmarkId == null &&
            result.objectName != null &&
            result.description != null &&
            result.part != null,
      'unknown' =>
        result.landmarkId == null &&
            result.objectName == null &&
            result.description == null &&
            result.part == null,
      _ => false,
    };
    if (!valid) {
      throw FormatException('検索結果の項目の組み合わせが不正です');
    }
    return result;
  }
  Map<String, dynamic> toJson() => {
    "schema_version": schemaVersion,
    "search_id": searchId,
    "result": result,
    "landmark_id": landmarkId,
    "object_name": objectName,
    "description": description,
    "part": part,
    "confidence": confidence,
    "named": named,
    "sources": sources.map((item) => item.toJson()).toList(),
  };
}

final class AreaContext {
  final String id;
  final String name;
  final String summary;
  final String? googlePlaceId;
  final List<String>? nameHints;
  final Set<String> _presentKeys;
  AreaContext._({
    required this.id,
    required this.name,
    required this.summary,
    required this.googlePlaceId,
    required this.nameHints,
    required Set<String> presentKeys,
  }) : _presentKeys = Set.unmodifiable(presentKeys);
  factory AreaContext({
    required String id,
    required String name,
    required String summary,
    String? googlePlaceId,
    List<String>? nameHints,
  }) => AreaContext.fromJson({
    "id": id,
    "name": name,
    "summary": summary,
    if (googlePlaceId != null) "google_place_id": googlePlaceId,
    if (nameHints != null) "name_hints": List.of(nameHints),
  });
  factory AreaContext.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      ["id", "name", "summary"],
      ["id", "name", "summary", "google_place_id", "name_hints"],
    );
    final result = AreaContext._(
      id: wireString(json["id"], "id", pattern: r'^lm_\d{4}$'),
      name: wireString(json["name"], "name"),
      summary: wireString(json["summary"], "summary"),
      googlePlaceId: json["google_place_id"] == null
          ? null
          : wireString(json["google_place_id"], "google_place_id"),
      nameHints: json.containsKey("name_hints")
          ? wireList(
              json["name_hints"],
              "name_hints",
              (value) => wireString(value, "name_hints"),
            )
          : null,
      presentKeys: json.keys.toSet(),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "summary": summary,
    if (_presentKeys.contains("google_place_id"))
      "google_place_id": googlePlaceId,
    if (_presentKeys.contains("name_hints"))
      "name_hints": nameHints == null ? null : List.of(nameHints!),
  };
}

/// B の送信の `context`（撮影の手がかり。任意。11/7 追加）。正確な座標は入れない。
///
/// - [capturedAt]：撮影の日時（日本時間・分まで。例 `2026-11-07T14:05+09:00`）
/// - [trigger]：撮ったきっかけ（[searchTriggers]）
/// - [town]：おおまかな住所（町丁目名。市区町村名なし）
/// - [nearLandmark]：ランドマーク（エリアを除く）の範囲の中で撮ったとき、そのランドマーク
final class SearchContext {
  final String? capturedAt;
  final String? trigger;
  final String? town;
  final NearLandmarkRef? nearLandmark;
  const SearchContext({
    this.capturedAt,
    this.trigger,
    this.town,
    this.nearLandmark,
  });
  factory SearchContext.fromJson(Map<String, dynamic> json) {
    wireKeys(json, const [], const [
      "captured_at",
      "trigger",
      "town",
      "near_landmark",
    ]);
    return SearchContext(
      capturedAt: json["captured_at"] == null
          ? null
          : wireString(
              json["captured_at"],
              "captured_at",
              pattern: r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\+09:00$',
            ),
      trigger: json["trigger"] == null
          ? null
          : wireString(json["trigger"], "trigger", values: searchTriggers),
      town: json["town"] == null
          ? null
          : wireString(json["town"], "town", minLength: 1),
      nearLandmark: json["near_landmark"] == null
          ? null
          : NearLandmarkRef.fromJson(
              wireMap(json["near_landmark"], "near_landmark"),
            ),
    );
  }
  Map<String, dynamic> toJson() => {
    if (capturedAt != null) "captured_at": capturedAt,
    if (trigger != null) "trigger": trigger,
    "town": town,
    "near_landmark": nearLandmark?.toJson(),
  };
}

/// B の撮影のきっかけ（schema の `context.trigger`）。
const searchTriggers = ["auto", "stopped", "button", "voice"];

/// `context.near_landmark`（ID と名前だけ）。
final class NearLandmarkRef {
  final String id, name;
  const NearLandmarkRef({required this.id, required this.name});
  factory NearLandmarkRef.fromJson(Map<String, dynamic> json) {
    wireKeys(json, const ["id", "name"], const ["id", "name"]);
    return NearLandmarkRef(
      id: wireString(json["id"], "id", pattern: r'^lm_\d{4}$'),
      name: wireString(json["name"], "name", minLength: 1),
    );
  }
  Map<String, dynamic> toJson() => {"id": id, "name": name};
}

final class VisualSearchRequest {
  final String schemaVersion;
  final String searchId;
  final TileId tile;
  final int gazeAzDeg;
  final List<String> candidateIds;
  final String imageJpegBase64;
  final AreaContext? area;

  /// 撮影の手がかり（任意）。null なら送らない（古い API でも通る）。
  final SearchContext? context;
  VisualSearchRequest._({
    required this.schemaVersion,
    required this.searchId,
    required this.tile,
    required this.gazeAzDeg,
    required this.candidateIds,
    required this.imageJpegBase64,
    required this.area,
    required this.context,
  });
  factory VisualSearchRequest({
    String schemaVersion = currentSchemaVersion,
    required String searchId,
    required TileId tile,
    required int gazeAzDeg,
    required List<String> candidateIds,
    required String imageJpegBase64,
    required AreaContext? area,
    SearchContext? context,
  }) => VisualSearchRequest.fromJson({
    "schema_version": schemaVersion,
    "search_id": searchId,
    "tile": tile.toJson(),
    "gaze_az_deg": gazeAzDeg,
    "candidate_ids": List.of(candidateIds),
    "image_jpeg_base64": imageJpegBase64,
    "area": area?.toJson(),
    if (context != null) "context": context.toJson(),
  });
  factory VisualSearchRequest.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      [
        "schema_version",
        "search_id",
        "tile",
        "gaze_az_deg",
        "candidate_ids",
        "image_jpeg_base64",
        "area",
      ],
      [
        "schema_version",
        "search_id",
        "tile",
        "gaze_az_deg",
        "candidate_ids",
        "image_jpeg_base64",
        "area",
        "context",
      ],
    );
    final result = VisualSearchRequest._(
      schemaVersion: wireString(
        json["schema_version"],
        "schema_version",
        pattern: r'^\d+\.\d+$',
      ),
      searchId: wireString(json["search_id"], "search_id"),
      tile: TileId.fromJson(wireMap(json["tile"], "tile")),
      gazeAzDeg: wireInt(
        json["gaze_az_deg"],
        "gaze_az_deg",
        min: 0,
        max: 350,
        multipleOf: 10,
      ),
      candidateIds: wireList(
        json["candidate_ids"],
        "candidate_ids",
        (value) => wireString(value, "candidate_ids", pattern: r'^lm_\d{4}$'),
        max: 10,
      ),
      imageJpegBase64: wireString(
        json["image_jpeg_base64"],
        "image_jpeg_base64",
      ),
      area: json["area"] == null
          ? null
          : AreaContext.fromJson(wireMap(json["area"], "area")),
      context: json["context"] == null
          ? null
          : SearchContext.fromJson(wireMap(json["context"], "context")),
    );
    return result;
  }
  Map<String, dynamic> toJson() => {
    "schema_version": schemaVersion,
    "search_id": searchId,
    "tile": tile.toJson(),
    "gaze_az_deg": gazeAzDeg,
    "candidate_ids": List.of(candidateIds),
    "image_jpeg_base64": imageJpegBase64,
    "area": area?.toJson(),
    if (context != null) "context": context!.toJson(),
  };
}

final class Decision {
  final String schemaVersion;
  final int tMs;
  final String kind;
  final String reason;
  final String? targetId;
  final String? text;
  final int? priority;

  /// B の答えの裏付けに使った出典（任意。kind が answer のときだけ）。
  final List<VisualSearchSource>? sources;
  Decision._({
    required this.schemaVersion,
    required this.tMs,
    required this.kind,
    required this.reason,
    required this.targetId,
    required this.text,
    required this.priority,
    required this.sources,
  });
  factory Decision({
    String schemaVersion = currentSchemaVersion,
    required int tMs,
    required String kind,
    required String reason,
    required String? targetId,
    required String? text,
    required int? priority,
    List<VisualSearchSource>? sources,
  }) => Decision.fromJson({
    "schema_version": schemaVersion,
    "t_ms": tMs,
    "kind": kind,
    "reason": reason,
    "target_id": targetId,
    "text": text,
    "priority": priority,
    if (sources != null)
      "sources": sources.map((item) => item.toJson()).toList(),
  });
  factory Decision.fromJson(Map<String, dynamic> json) {
    wireKeys(
      json,
      [
        "schema_version",
        "t_ms",
        "kind",
        "reason",
        "target_id",
        "text",
        "priority",
      ],
      [
        "schema_version",
        "t_ms",
        "kind",
        "reason",
        "target_id",
        "text",
        "priority",
        "sources",
      ],
    );
    final result = Decision._(
      schemaVersion: wireString(
        json["schema_version"],
        "schema_version",
        pattern: r'^\d+\.\d+$',
      ),
      tMs: wireInt(json["t_ms"], "t_ms", min: 0),
      kind: wireString(
        json["kind"],
        "kind",
        values: ["speak", "skip", "search", "search_skip", "answer", "fetch"],
      ),
      reason: wireString(
        json["reason"],
        "reason",
        pattern: r'^(speak|skip|search|search_skip|answer|fetch):[a-z0-9_]+$',
      ),
      targetId: json["target_id"] == null
          ? null
          : wireString(json["target_id"], "target_id"),
      text: json["text"] == null ? null : wireString(json["text"], "text"),
      priority: json["priority"] == null
          ? null
          : wireInt(json["priority"], "priority", min: 1, max: 6),
      sources: json.containsKey("sources")
          ? wireList(
              json["sources"],
              "sources",
              (value) => VisualSearchSource.fromJson(wireMap(value, "sources")),
            )
          : null,
    );
    if (!reasonCodes.contains(result.reason) ||
        result.reason.split(':').first != result.kind) {
      throw FormatException('理由コードが一覧またはkindと一致しません');
    }
    if (result.sources != null && result.kind != 'answer') {
      throw FormatException('sourcesはkindがanswerのときだけ付けられます');
    }
    return result;
  }
  Map<String, dynamic> toJson() => {
    "schema_version": schemaVersion,
    "t_ms": tMs,
    "kind": kind,
    "reason": reason,
    "target_id": targetId,
    "text": text,
    "priority": priority,
    if (sources != null)
      "sources": sources!.map((item) => item.toJson()).toList(),
  };
}

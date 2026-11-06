import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/net/api_client.dart';
import 'package:mobile/net/tile_fetcher.dart';

/// 富山駅南口付近（schema/README.md の見本と同じタイル 16/57746/25576）。
const lat = 36.7013, lon = 137.2133;
const station = TileId(57746, 25576);

Map<String, Object?> body(TileId t, {bool withLandmark = false}) => {
  'schema_version': '0.3',
  'tile': {'z': 16, 'x': t.x, 'y': t.y},
  'landmarks': [
    if (withLandmark)
      {
        'id': 'lm_0002',
        'name': '富山駅',
        'name_kana': 'とやまえき',
        'lat': lat,
        'lon': lon,
        'kind': 'building',
        'script_short': 's',
        'script_long': 'l',
        'visual_hint': 'v',
      },
  ],
  'stops': [],
  'crossings': [],
  'events': [],
};

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('要るタイルの選び方（engine の _prefetch と同じ）', () {
    test('止まっているときは今の位置 ±150 m だけ', () {
      final s = tilesAhead(lat: lat, lon: lon, speedMps: 0, courseDeg: null);
      expect(s, contains(station));
      expect(s.length, inInclusiveRange(1, 4));
    });

    test('歩いていると、150秒先（約200 m）までの進む先のタイルも入る', () {
      final still = tilesAhead(lat: lat, lon: lon);
      final north = tilesAhead(lat: lat, lon: lon, speedMps: 1.3, courseDeg: 0);
      expect(north.containsAll(still), isTrue);
      expect(
        north,
        contains(TileId.at(lat + 195 / 111320 + 150 / 111320, lon)),
      );
      // 南（後ろ）へは ±150 m より先を取らない
      expect(north, isNot(contains(TileId.at(lat - 400 / 111320, lon))));
    });
  });

  group('取得', () {
    late List<String> asked;
    late Set<String> withData;
    late int status;
    late int now;

    TileFetcher make({
      String token = 't',
      TileCache? cache,
      bool Function(TileId)? inRange,
    }) {
      final client = MockClient((req) async {
        asked.add(req.url.path);
        expect(req.headers['X-App-Token'], token);
        if (status != 200) return http.Response('', status);
        final p = req.url.pathSegments; // v1 tiles 16 x y
        final t = TileId(int.parse(p[3]), int.parse(p[4]));
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(body(t, withLandmark: withData.contains(t.key))),
          ),
          200,
        );
      });
      return TileFetcher(
        api: ApiClient(
          baseUrl: 'https://api.test',
          token: token,
          client: client,
        ),
        cache: cache,
        now: () => now,
        inRange: inRange,
      );
    }

    setUp(() {
      asked = [];
      withData = {station.key};
      status = 200;
      now = 1000000;
    });

    test('届いたタイルを流し、同じタイルは2回問い合わせない（空のタイルも）', () async {
      final f = make();
      final got = <TileData>[];
      f.loaded.listen(got.add);
      const outside = TileId(57700, 25500);
      f.request([station, outside]);
      await settle();
      f.request([station, outside]);
      await settle();
      expect(asked, ['/v1/tiles/16/57746/25576', '/v1/tiles/16/57700/25500']);
      expect(got.map((d) => d.id), [station, outside]);
      expect(got.first.landmarks.single.name, '富山駅');
      expect(got.last.isEmpty, isTrue);
      expect(f.empty, 1);
    });

    test('範囲が分かっていれば、範囲の外は問い合わせもしない', () async {
      final f = make(inRange: (t) => t == station);
      f.request([station, const TileId(57700, 25500)]);
      await settle();
      expect(asked, ['/v1/tiles/16/57746/25576']);
      expect(f.skippedOutOfRange, 1);
      expect(f.tiles, hasLength(2));
    });

    test('失敗したタイルは30秒は頼み直さない', () async {
      status = 500;
      final f = make();
      f.request([station]);
      await settle();
      f.request([station]);
      await settle();
      expect(asked, hasLength(1));
      status = 200;
      now += 31000;
      f.request([station]);
      await settle();
      expect(asked, hasLength(2));
      expect(f.has(station), isTrue);
    });

    test('トークンが無いときは問い合わせない', () async {
      final f = make(token: '');
      f.request([station]);
      await settle();
      expect(asked, isEmpty);
      expect(f.lastResult, contains('トークン未設定'));
    });

    test('401 のあとは、しばらく全部のタイルを頼まない', () async {
      status = 401;
      final f = make();
      f.request([station]);
      await settle();
      now += 31000;
      f.request([station, const TileId(1, 1)]);
      await settle();
      expect(asked, hasLength(1));
    });

    test('端末に残したタイルは、起動し直しても12時間は取り直さない', () async {
      final dir = await Directory.systemTemp.createTemp('tiles');
      TileCache cache() => TileCache(() async => dir);
      final a = make(cache: cache());
      a.request([station]);
      await settle();
      final b = make(cache: cache());
      b.request([station]);
      await settle();
      expect(asked, hasLength(1));
      expect(b.fromCache, 1);
      expect(b.tiles.single.landmarks.single.id, 'lm_0002');
      now += const Duration(hours: 13).inMilliseconds;
      final c = make(cache: cache());
      c.request([station]);
      await settle();
      expect(asked, hasLength(2));
      await dir.delete(recursive: true);
    });
  });
}

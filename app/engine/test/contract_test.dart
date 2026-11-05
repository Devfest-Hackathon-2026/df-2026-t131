import 'dart:convert';
import 'dart:io';

import 'package:engine/engine.dart';
import 'package:test/test.dart';

import '../tool/fixture_models.dart';

Map<String, dynamic> copyJson(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

void main() {
  final examples = Directory.fromUri(
    findRepositoryRoot().uri.resolve('schema/examples/'),
  );
  for (final file in examples.listSync().whereType<File>().where(
    (file) => file.path.endsWith('.json'),
  )) {
    final name = file.uri.pathSegments.last;
    test('見本をJSONへ戻しても項目と値が変わらない: $name', () {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(roundtripExample(name, json), equals(json));
    });
  }

  test('歩行ログ全行を同じイベントとして再生でき、空のEngineは指示を出さない', () {
    final rows = File.fromUri(examples.uri.resolve('walk_short.jsonl'))
        .readAsLinesSync();
    final engine = Engine();
    final secondEngine = Engine();
    expect(rows, isNotEmpty);
    for (final line in rows.where((line) => line.trim().isNotEmpty)) {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final event = eventFromJson(json);
      expect(eventToJson(event), equals(json));
      expect(engine.handle(event), isEmpty);
      expect(secondEngine.handle(eventFromJson(copyJson(json))), isEmpty);
    }
  });

  test('判断ログの見本をLogDecisionとして受け渡せる', () {
    final rows = File.fromUri(examples.uri.resolve('decisions_short.jsonl'))
        .readAsLinesSync();
    for (final line in rows.where((line) => line.trim().isNotEmpty)) {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final command = LogDecision(decision: Decision.fromJson(json));
      expect(command.decision.toJson(), equals(json));
    }
  });

  test('公開する理由コードがschemaの一覧と一致する', () {
    final json = jsonDecode(
      File.fromUri(findRepositoryRoot().uri.resolve('schema/reason_codes.json'))
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(
      reasonCodes,
      equals((json['codes'] as Map<String, dynamic>).keys.toSet()),
    );
  });

  Map<String, dynamic> sensor() => jsonDecode(
    File.fromUri(examples.uri.resolve('walk_short.jsonl'))
        .readAsLinesSync()
        .first,
  ) as Map<String, dynamic>;

  test('乗り物・位置の欠測項目・画質の欠測をそのまま保存できる', () {
    final json = sensor();
    final data = json['data'] as Map<String, dynamic>;
    data['activity'] = 'in_vehicle';
    data['speed_mps'] = null;
    data['course_deg'] = null;
    data['image_quality'] = null;
    final event = eventFromJson(json) as SensorFrame;
    expect(event.activity, Activity.inVehicle);
    expect(event.speedMps, isNull);
    expect(eventToJson(event), equals(json));
  });

  test('失敗と警報も、センサー以外の入力イベントとして保存できる', () {
    for (final event in <EngineEvent>[
      const TtsFinished(tMs: 1000, utteranceId: 'u_000001'),
      const VisualError(
        tMs: 2000,
        searchId: 's_000001',
        error: 'face_blur_failed',
      ),
      const AlertReceived(
        tMs: 3000,
        alertId: 'alert_demo',
        level: 4,
        kind: 'rain',
        areaName: '見本市',
        text: '警報の見本文です。',
      ),
    ]) {
      expect(
        eventToJson(eventFromJson(eventToJson(event))),
        equals(eventToJson(event)),
      );
    }
  });

  test('任意項目の省略と明示的なnullを混同しない', () {
    final json = readExample('visual_search_request.json');
    final withNull = VisualSearchRequest.fromJson(json).toJson();
    expect(
      (withNull['area'] as Map<String, dynamic>).containsKey('google_place_id'),
      isTrue,
    );
    (json['area'] as Map<String, dynamic>).remove('google_place_id');
    final withoutKey = VisualSearchRequest.fromJson(json).toJson();
    expect(
      (withoutKey['area'] as Map<String, dynamic>).containsKey(
        'google_place_id',
      ),
      isFalse,
    );
  });

  test('nullを許さない任意配列にnullを入れたら拒否する', () {
    final json = readExample('visual_search_request.json');
    (json['area'] as Map<String, dynamic>)['name_hints'] = null;
    expect(() => VisualSearchRequest.fromJson(json), throwsFormatException);
  });

  test('検索結果の種類に合わない応答は拒否する', () {
    final json = readExample('visual_search_response_matched.json');
    json['landmark_id'] = null;
    expect(() => VisualSearchResponse.fromJson(json), throwsFormatException);
  });

  test('イベントに画像や未定義項目を混ぜたログを拒否する', () {
    final json = sensor();
    (json['data'] as Map<String, dynamic>)['image_jpeg_base64'] = '見本';
    expect(() => eventFromJson(json), throwsFormatException);
  });

  test('センサーの不正な型・方位・画質を拒否する', () {
    for (final change in <Map<String, dynamic>>[
      {'lat': '36.7'},
      {'gaze_az_deg': 360},
      {'audio_out': 'bluetooth'},
      {
        'image_quality': {'blur': 1.1, 'brightness': 0.5},
      },
    ]) {
      final json = sensor();
      (json['data'] as Map<String, dynamic>).addAll(change);
      expect(() => eventFromJson(json), throwsFormatException);
    }
  });

  test('未知のイベント・欠落した必須項目・不正な理由コードを拒否する', () {
    final unknown = sensor()..['type'] = 'capture';
    expect(() => eventFromJson(unknown), throwsFormatException);
    final missing = sensor();
    (missing['data'] as Map<String, dynamic>).remove('speed_mps');
    expect(() => eventFromJson(missing), throwsFormatException);
    expect(
      () => Decision(
        schemaVersion: '0.2',
        tMs: 1,
        kind: 'skip',
        reason: 'skip:undefined',
        targetId: null,
        text: null,
        priority: null,
      ),
      throwsFormatException,
    );
  });

  test('10度単位でない検索方位を拒否する', () {
    final json = readExample('visual_search_request.json')
      ..['gaze_az_deg'] = 181;
    expect(() => VisualSearchRequest.fromJson(json), throwsFormatException);
  });

  test('モデルは元のJSONや返したJSONの変更から独立している', () {
    final json = readExample('tile_response.json');
    final tile = TileResponse.fromJson(json);
    final name = tile.landmarks.first.name;
    ((json['landmarks'] as List).first as Map<String, dynamic>)['name'] = '変更';
    final encoded = tile.toJson();
    (encoded['landmarks'] as List).clear();
    expect(tile.landmarks.first.name, name);
    expect(() => tile.landmarks.clear(), throwsUnsupportedError);
  });

  test('アプリがCommandの元の配列を変更しても内容が変わらない', () {
    final ids = <String>['lm_0001'];
    final request = VisualSearchRequest.fromJson(
      readExample('visual_search_request.json'),
    );
    final command = CaptureAndSearch(
      searchId: 's_000001',
      tile: request.tile,
      gazeAzDeg10: 180,
      candidateIds: ids,
      area: request.area,
    );
    ids.clear();
    expect(command.candidateIds, ['lm_0001']);
    expect(command.area?.summary, request.area?.summary);
    final tiles = <TileId>[request.tile];
    final fetch = FetchTiles(tiles: tiles);
    tiles.clear();
    expect(fetch.tiles.single.toJson(), request.tile.toJson());
  });
}

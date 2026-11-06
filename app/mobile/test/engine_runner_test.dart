import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/sensor_ticker.dart';
import 'package:mobile/engine/engine_runner.dart';
import 'package:mobile/executors/speak_executor.dart';
import 'package:mobile/info/alert_message.dart';
import 'package:mobile/net/api_client.dart';
import 'package:mobile/net/tile_fetcher.dart';
import 'package:mobile/sources/activity_source.dart';
import 'package:mobile/sources/audio_state_source.dart';
import 'package:mobile/sources/gaze_source.dart';
import 'package:mobile/sources/location_source.dart';

import 'package:mobile/sources/image_quality.dart';
import 'package:mobile/vision/search_progress.dart';
import 'package:mobile/vision/visual_searcher.dart';

import 'speak_executor_test.dart' show FakeTts, FakeFocus, FakeChime;
import 'visual_search_test.dart' show FakeCamera, FakeFaces;
import 'support/alert_fixture.dart';

/// schema/examples の見本（架空の地名）：歩行ログと、そのタイル。
final _walk = File('../../schema/examples/walk_short.jsonl')
    .readAsLinesSync()
    .map((l) => jsonDecode(l) as Map<String, dynamic>)
    .toList();
final Map<String, dynamic> _tile = _walk.firstWhere(
  (r) => r['type'] == 'tiles_loaded',
)['data'];

SensorSnapshot _snap(
  Map<String, dynamic> row, {
  bool speaking = false,
  bool quality = false,
}) {
  final d = row['data'] as Map<String, dynamic>;
  return SensorSnapshot(
    tMs: row['t_ms'] as int,
    location: LocationFix(
      lat: (d['lat'] as num).toDouble(),
      lon: (d['lon'] as num).toDouble(),
      accM: (d['acc_m'] as num).toDouble(),
      speedMps: (d['speed_mps'] as num?)?.toDouble(),
      courseDeg: (d['course_deg'] as num?)?.toDouble(),
      altM: null,
    ),
    gaze: GazeReading(
      azDeg: (d['gaze_az_deg'] as num).toDouble(),
      pitchDeg: (d['gaze_pitch_deg'] as num).toDouble(),
    ),
    activity: ActivityKind.walking,
    audio: const AudioState(earphone: true, inCall: false),
    ttsSpeaking: speaking,
    imageQuality: quality ? const ImageQuality(blur: 1, brightness: 0.5) : null,
  );
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeTts tts;
  late FakeFocus focus;
  late SpeakExecutor speaker;
  late List<String> asked;
  late List<Map<String, dynamic>> rows;
  late int now;
  late EngineRunner r;

  setUp(() {
    tts = FakeTts();
    focus = FakeFocus();
    speaker = SpeakExecutor(tts: tts, focus: focus, chime: FakeChime());
    asked = [];
    rows = [];
    now = _walk.first['t_ms'] as int;
    final tiles = TileFetcher(
      api: ApiClient(
        baseUrl: 'https://api.test',
        token: 't',
        client: MockClient((req) async {
          asked.add(req.url.path);
          final p = req.url.pathSegments;
          final body = p[3] == '57746' && p[4] == '25576'
              ? _tile
              : {
                  ..._tile,
                  'tile': {'z': 16, 'x': int.parse(p[3]), 'y': int.parse(p[4])},
                  'landmarks': [],
                  'stops': [],
                  'crossings': [],
                  'events': [],
                };
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }),
      ),
      now: () => now,
    );
    r = EngineRunner(
      speaker: speaker,
      tiles: tiles,
      record: rows.add,
      now: () => now,
    );
  });

  tearDown(() => r.dispose());

  Future<void> walk() async {
    for (final row in _walk.where((r) => r['type'] == 'sensor')) {
      now = row['t_ms'] as int;
      r.onSnapshot(_snap(row, speaking: speaker.speaking));
      await settle();
    }
  }

  test('見本の歩行ログで、タイルを取り、石碑の手前で話す（engine の見本の判断と同じ）', () async {
    await walk();
    // engine が頼んだタイルだけを取りに行く（mobile では選ばない）
    expect(asked, contains('/v1/tiles/16/57746/25576'));
    // 取ったタイルは歩行ログに tiles_loaded として残る（空のタイルも）
    final loaded = rows.where((x) => x['type'] == 'tiles_loaded').toList();
    expect(loaded.length, asked.length);
    // decisions_short.jsonl：25秒目に lm_0001 を speak:closest_approach
    // engine が方向の言葉を前に付ける（例「左前方に見本の石碑があります。」）
    // 文ごとに区切って話す（最初の文が話されている）
    expect(tts.spoken.single, isNotEmpty);
    tts.finish();
    await settle();
    expect(tts.spoken.join(), endsWith('右手の石碑は、見本のために置いた架空の石碑です。'));
    expect(r.lastDecision.value, isNotNull);
    expect(r.view.value?.nearby, isNotEmpty);
  });

  test('engine の発話が終わったら TtsFinished を返し、歩行ログにも残す', () async {
    await walk();
    // 文ごとに区切って話すので、話し終えるまで1文ずつ終わらせる
    for (var i = 0; i < 10 && speaker.speaking; i++) {
      tts.finish();
      await settle();
    }
    final fin = rows.where((x) => x['type'] == 'tts_finished').toList();
    expect(fin, hasLength(1));
    expect((fin.single['data'] as Map)['utterance_id'], startsWith('u_'));
  });

  test('警報は engine 経由でも、レベル4以上なら今の話に割り込み、音楽を止める', () async {
    await walk();
    expect(speaker.speaking, isTrue); // 石碑の話の最中
    final a = parseAlertData(
      mockAlertData(level: 4, nowMs: now),
      receivedMs: now,
    )!;
    r.onAlert(a);
    await settle();
    expect(tts.stops, isNotEmpty);
    // 警報はすぐ割り込む（いま話しているのは警報の最初の文）
    expect(a.text, startsWith(tts.spoken.last));
    expect(focus.log.last, 'pause');
  });

  test('頼んだ検索でカメラが撮れなければ、すぐ engine に失敗を返し、結果待ちを残さない', () async {
    final rec = <Map<String, dynamic>>[];
    final r2 = EngineRunner(
      speaker: speaker,
      tiles: TileFetcher(
        api: ApiClient(baseUrl: '', token: ''),
      ),
      record: rec.add,
      searcher: VisualSearcher(
        camera: FakeCamera(null),
        faces: FakeFaces(),
        post: (_) async => (json: null, error: 'network'),
      ),
      now: () => now,
    );
    addTearDown(r2.dispose);
    for (final row in _walk.where((x) => x['type'] == 'sensor').take(5)) {
      now = row['t_ms'] as int;
      r2.onSnapshot(_snap(row, quality: true));
    }
    r2.requestSearch();
    await settle();
    expect(rec.map((x) => x['type']), contains('visual_error'));
    expect(r2.searchProgress.value?.phase, SearchPhase.failed);
    expect(r2.searchProgress.value?.detail, 'no_frame');
    // 結果待ちが残っていないので、すぐ頼み直せる（前の検索待ちで断られない）
    r2.requestSearch();
    await settle();
    expect(rec.where((x) => x['type'] == 'visual_error'), hasLength(2));
  });

  test('レベル3の警報は割り込まず、今の話の後に話す', () async {
    await walk();
    final a = parseAlertData(
      mockAlertData(level: 3, nowMs: now),
      receivedMs: now,
    )!;
    r.onAlert(a);
    await settle();
    expect(tts.stops, isEmpty);
    expect(tts.spoken.last, isNot(a.text));
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:engine/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewer/src/demo_map.dart';
import 'package:viewer/src/replay.dart';
import 'package:viewer/src/search_photo.dart';
import 'package:viewer/src/walk_video.dart';

import '../tool/build_map.dart';

// viewer の再生の仕組みのテスト（画面は使わない）。
// テストは app/viewer で `flutter test` を実行する前提で、相対パスでリポジトリのファイルを読む。

String readRepo(String path) => File('../../$path').readAsStringSync();

void main() {
  group('歩行ログの読み込み', () {
    test('見本の歩行ログを読める', () {
      final events = parseWalkLog(readRepo('schema/examples/walk_short.jsonl'));
      expect(events.first, isA<SensorFrame>());
      expect(events.whereType<TilesLoaded>(), isNotEmpty);
    });

    test('読めない行は、何行目かを付けて知らせる', () {
      final good = readRepo('schema/examples/walk_short.jsonl')
          .split('\n')
          .first;
      expect(
        () => parseWalkLog('$good\n\n{"type": "sensor"}\n'),
        throwsA(
          isA<WalkLogFormatException>().having((e) => e.lineNumber, '行', 3),
        ),
      );
    });

    test('空のログは読めない', () {
      expect(
        () => parseWalkLog('\n\n'),
        throwsA(isA<WalkLogFormatException>()),
      );
    });
  });

  group('再生', () {
    late Replay replay;
    setUpAll(() {
      replay = Replay.run(
        parseWalkLog(readRepo('schema/examples/walk_short.jsonl')),
      );
    });

    test('判断ログは、engine の再生で作った判断ログ（fixtures）と同じ', () {
      final expected = [
        for (final line in const LineSplitter().convert(
          readRepo('app/engine/test/fixtures/decisions/walk_short.jsonl'),
        ))
          if (line.trim().isNotEmpty) jsonDecode(line),
      ];
      expect([for (final d in replay.decisions) d.decision.toJson()], expected);
    });

    test('同じログを2回流すと、同じ状態になる（決定論）', () {
      final again = Replay.run(
        parseWalkLog(readRepo('schema/examples/walk_short.jsonl')),
      );
      expect(again.frames.length, replay.frames.length);
      for (var i = 0; i < replay.frames.length; i++) {
        final a = replay.frames[i].view, b = again.frames[i].view;
        expect(b.nextSearchInMs, a.nextSearchInMs);
        expect(b.lastDecision?.toJson(), a.lastDecision?.toJson());
        expect(
          [for (final n in b.nearby) (n.id, n.distanceM)],
          [for (final n in a.nearby) (n.id, n.distanceM)],
        );
      }
    });

    test('時刻からフレームを探す（その時刻までに処理した最後のもの）', () {
      expect(replay.frameIndexAt(replay.startMs - 1000), 0);
      expect(
        replay.frameIndexAt(replay.endMs + 1000),
        replay.frames.length - 1,
      );
      final mid = replay.frames[10];
      final found = replay.frameIndexAt(mid.tMs);
      expect(replay.frames[found].tMs, mid.tMs);
      expect(
        found == replay.frames.length - 1 ||
            replay.frames[found + 1].tMs > mid.tMs,
        isTrue,
      );
    });

    test('フレームまでの判断ログの件数', () {
      expect(
        replay.decisionCountAt(replay.frames.length - 1),
        replay.decisions.length,
      );
      for (final (i, d) in replay.decisions.indexed) {
        expect(replay.decisionCountAt(d.frameIndex), greaterThan(i));
      }
    });

    test('タイルのランドマークと、歩いた道を集める', () {
      expect(replay.landmarks, isNotEmpty);
      expect(
        replay.track.length,
        replay.frames
            .whereType<ReplayFrame>()
            .where((f) => f.event is SensorFrame)
            .length,
      );
    });

    test('読み上げ中の話は、TtsFinished が来るまで続く', () {
      for (final s in replay.speaks) {
        expect(
          replay.frames[s.frameIndex].speaking?.utteranceId,
          s.speak.utteranceId,
        );
      }
    });
  });

  group('同梱のファイル', () {
    test('地図（assets/map.json）は cloud/data から作り直したものと同じ（古ければ dart run tool/build_map.dart）', () {
      expect(
        File('assets/map.json').readAsStringSync(),
        encodeDemoMap(loadDemoMapFromRepo()),
      );
    });

    test('地図には reviewed のランドマークだけが入り、OpenStreetMap の出典を出す', () {
      final map = DemoMap.fromJson(
        jsonDecode(File('assets/map.json').readAsStringSync())
            as Map<String, dynamic>,
      );
      expect(map.landmarks, isNotEmpty);
      expect(map.crossings, isNotEmpty);
      expect(map.attributions.join(), contains('OpenStreetMap'));
    });

    test('理由コードの説明は schema/reason_codes.json と同じ', () {
      expect(
        jsonDecode(File('assets/reason_codes.json').readAsStringSync()),
        jsonDecode(readRepo('schema/reason_codes.json')),
      );
    });

    test('撮影ごとの答えを引ける（送った画像と並べるため）', () {
      final r = Replay.run(
        parseWalkLog(
          File('assets/walks/walk_20261108T044257Z.jsonl').readAsStringSync(),
        ),
      );
      expect(r.searches, hasLength(23));
      expect(r.outcomes, hasLength(23));
      expect(r.outcomes['s_000003']?.result, 'error');
      expect(r.outcomes['s_000021']?.objectName, '天門橋');
      final first = r.searches.first;
      expect(r.lastSearchAt(first.frameIndex)?.search.searchId, 's_000001');
      expect(r.lastSearchAt(first.frameIndex - 1), isNull);
      // 答えは撮った直後にはまだ無く、届いたフレームから見える
      expect(r.outcomeAt('s_000001', first.frameIndex), isNull);
      final o = r.outcomes['s_000001']!;
      expect(r.outcomeAt('s_000001', o.frameIndex)?.result, 'unknown');
    });

    test('画像の置き場所（images）は、書いてあればその URL を指す', () {
      final index = jsonDecode(
        File('assets/walks/index.json').readAsStringSync(),
      ) as List;
      for (final w in index.cast<Map<String, dynamic>>()) {
        final images = WalkImages.fromJson(w['images']);
        if (images == null) continue;
        expect(images.baseUrl, startsWith('https://'));
        expect(images.urlFor('s_000001'), endsWith('/s_000001.jpg'));
      }
    });

    test('動画（video）は、歩行ログの最初を動画の offset_ms に合わせる', () {
      final index = jsonDecode(
        File('assets/walks/index.json').readAsStringSync(),
      ) as List;
      final demo = index.cast<Map<String, dynamic>>().firstWhere(
        (w) => w['file'] == 'walk_20261108T044257Z.jsonl',
      );
      final video = WalkVideo.fromJson(demo['video'])!;
      expect(video.url, startsWith('https://'));
      expect(video.url, endsWith('.mp4'));
      expect(video.offsetMs, 2200);
      expect(video.positionSec(0), 2.2);
      expect(video.positionSec(60000), 62.2);
      expect(WalkVideo.fromJson(null), isNull);
      expect(WalkVideo.fromJson({'url': ''}), isNull);
      // 手でぼかしを足した画像は、画面でそう断る
      final images = WalkImages.fromJson(demo['images'])!;
      expect(images.manualBlur, {'s_000001', 's_000006'});
    });

    test('一覧に載せた歩行ログは、すべて読めて再生できる', () {
      final index = jsonDecode(
        File('assets/walks/index.json').readAsStringSync(),
      ) as List;
      expect(index, isNotEmpty);
      for (final w in index) {
        final file = (w as Map<String, dynamic>)['file'] as String;
        final text = File('assets/walks/$file').readAsStringSync();
        expect(Replay.run(parseWalkLog(text)).frames, isNotEmpty, reason: file);
      }
    });
  });
}

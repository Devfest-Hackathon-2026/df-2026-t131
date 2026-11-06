import 'package:engine/engine.dart';
import 'package:test/test.dart';

import '../tool/fixture_models.dart';
import 'support/scenario.dart';

// B（視界の定期検索）の判断のテスト。
// 発火タイミングの決めごとは伝言「B_発火タイミングの論点」（11/5 に決定）の番号で書く。

final good = ImageQuality(blur: 0.8, brightness: 0.8);
ImageQuality? goodQuality(int _) => good;

VisualSearchResponse unknownFor(String searchId) => VisualSearchResponse(
  searchId: searchId,
  result: 'unknown',
  landmarkId: null,
  objectName: null,
  description: null,
  confidence: 0.2,
  named: false,
  sources: const [],
);

VisualSearchResponse unlistedFor(
  String searchId, {
  String name = '古い木造の蔵',
  String description = '白い漆喰の壁と黒い瓦屋根の蔵が見えます。',
  double confidence = 0.8,
  bool named = false,
  List<VisualSearchSource> sources = const [],
}) => VisualSearchResponse(
  searchId: searchId,
  result: 'unlisted',
  landmarkId: null,
  objectName: name,
  description: description,
  confidence: confidence,
  named: named,
  sources: sources,
);

VisualSearchResponse matchedFor(String searchId, String landmarkId) =>
    VisualSearchResponse(
      searchId: searchId,
      result: 'matched',
      landmarkId: landmarkId,
      objectName: null,
      description: null,
      confidence: 0.86,
      named: false,
      sources: const [],
    );

Responder answer(VisualSearchResponse Function(String searchId) make) =>
    (c, t) => VisualResult(tMs: t, response: make(c.searchId));

/// 止まって立っている場所（原点）。
Pose standing(int _) => (north: 0, east: 0, speed: 0, course: 180);

/// 南へ歩いて、歩き始めから sec 秒の場所で止まる。
Pose stopAt(int sec) => (north: -1.3 * sec, east: 0, speed: 0, course: 180);

extension on Sim {
  List<(int, CaptureAndSearch)> get searches => [
    for (final (t, c) in commands)
      if (c is CaptureAndSearch) (t, c),
  ];
  List<double> get searchSecs => [for (final (t, _) in searches) secOf(t)];
}

void main() {
  group('いつ撮るか', () {
    test('論点1・2：最初の1枚はタイルが届いてから60秒後、その後は最後に撮った時刻から60秒ごと', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        200,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searchSecs, [60, 120, 180]);
      expect(
        sim.withReason('search:interval_elapsed').map((d) => sim.secOf(d.tMs)),
        [60, 120, 180],
      );
      expect(sim.withReason('answer:unknown'), hasLength(3));
      expect(sim.speaks, isEmpty);
    });

    test('タイルが届かなくても、位置と向きが初めて取れてから60秒後に撮る（候補は空）', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(100, from: 10, quality: goodQuality);
      expect(sim.searchSecs, [70]);
      final c = sim.searches.single.$2;
      expect(c.candidateIds, isEmpty);
      expect(c.area, isNull);
    });

    test('論点7：画質が足りない間は撮らず、理由を1回だけ記録し、足りたら次の秒に撮る', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        140,
        quality: (sec) =>
            sec < 70 ? ImageQuality(blur: 0.3, brightness: 0.8) : good,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.withReason('search_skip:low_quality'), hasLength(1));
      expect(
        sim.secOf(sim.withReason('search_skip:low_quality').first.tMs),
        60,
      );
      // 数え直すのは撮ったときだけ（70秒に撮ったので、次は130秒）
      expect(sim.searchSecs, [70, 130]);
    });

    test('画質の値がない（null）ときも撮らない', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        70,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searches, isEmpty);
      expect(sim.withReason('search_skip:low_quality'), hasLength(1));
    });

    test('前回と同じ場所・同じ向きなら撮らず、向きを変えたら撮る', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        140,
        pose: standing,
        // 立ち止まりの前倒しと分けるため、歩行中のまま止まっている場面にする
        activity: (_) => Activity.walking,
        quality: goodQuality,
        gaze: (sec) => sec < 130 ? 180 : 90,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searchSecs, [60, 130]);
      expect(sim.withReason('search_skip:same_place'), hasLength(1));
      expect(
        sim.secOf(sim.withReason('search_skip:same_place').first.tMs),
        120,
      );
    });

    test('1回の歩行の上限に達したら撮らない', () {
      final sim = Sim(
        const EngineConfig(visualIntervalMs: 20000, maxSearchesPerWalk: 2),
        answer(unknownFor),
      );
      sim.run(
        60,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searchSecs, [20, 40]);
      expect(sim.withReason('search_skip:limit_reached'), hasLength(1));
      expect(sim.engine.view.searchesLeft, 0);
      expect(sim.engine.view.nextSearchInMs, isNull);
    });

    test('論点6：立ち止まって5秒たち、前に撮ってから30秒以上なら前倒しで撮る', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        45,
        pose: (sec) => sec < 35 ? southWalk(sec) : stopAt(35),
        activity: (sec) => sec < 35 ? Activity.walking : Activity.still,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searchSecs, [40]);
      expect(sim.withReason('search:stopped_early'), hasLength(1));
    });

    test('論点6：前に撮ってから30秒たっていなければ、立ち止まっても待つ', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        35,
        pose: (sec) => sec < 10 ? southWalk(sec) : stopAt(10),
        activity: (sec) => sec < 10 ? Activity.walking : Activity.still,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      // 15秒：止まって5秒たったが、タイルが届いてから30秒たっていない（理由を記録して待つ）。
      // 33秒：30秒に撮った結果が届いたあと、まだ止まっている（この周期でも1回だけ記録する）
      expect(
        sim
            .withReason('search_skip:interval_not_elapsed')
            .map((d) => sim.secOf(d.tMs)),
        [15, 33],
      );
      expect(sim.searchSecs, [30]);
    });
  });

  group('文脈ゲート', () {
    test('乗り物の中・音声の出力先がないときは撮らない', () {
      for (final (activity, audio) in [
        (Activity.inVehicle, AudioOut.earphone),
        (Activity.walking, AudioOut.none),
      ]) {
        final sim = Sim(const EngineConfig(), answer(unknownFor));
        sim.run(
          100,
          activity: (_) => activity,
          audio: audio,
          quality: goodQuality,
          extra: {
            0: [tiles(0, const [])],
          },
        );
        expect(sim.searches, isEmpty);
        expect(sim.withReason('search_skip:gate_blocked'), hasLength(1));
      }
    });

    test('論点3：前の話が終わってから「話題の間隔−答えの見込み」が過ぎるまで撮らず、答えは間隔が空いてから話す', () {
      final sim = Sim(const EngineConfig(), answer((id) => unlistedFor(id)));
      sim.run(
        100,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
          50: [
            const AlertReceived(
              tMs: t0 + 50000,
              alertId: 'alert_a',
              level: 3,
              kind: 'rain',
              areaName: '見本市',
              text: '警報の見本文です。',
            ),
          ],
        },
      );
      // 警報（9文字で約1.5秒）は届いた50秒に話し始め、52秒の TtsFinished で終わる。
      // 52＋20−5＝67秒より前は撮らない
      final alert = sim.speaks.first;
      expect(sim.secOf(alert.$1), 50);
      expect(sim.withReason('search_skip:gate_blocked'), hasLength(1));
      expect(sim.searchSecs.first, 67);
      // 答えは70秒に届き、話題の間隔（52＋20＝72秒）が空いたら話す
      final b = sim.withReason('answer:unlisted_object').single;
      expect(sim.secOf(b.tMs), 72);
      expect(b.text, 'さっき正面に見えたのは古い木造の蔵です。白い漆喰の壁と黒い瓦屋根の蔵が見えます。');
      expect(b.priority, 6);
    });

    test('論点4：15秒以内に A が話し始めそうなら撮らず、A を先に話す', () {
      // 南へ1.3m/sで歩き、85秒に最接近する（A は20秒前の65秒に話し始める）
      final lm = landmark('lm_0001', -1.3 * 85, 10);
      final sim = Sim(
        const EngineConfig(),
        answer((id) => matchedFor(id, 'lm_0001')),
      );
      sim.run(
        130,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [lm]),
          ],
        },
      );
      final a = sim.withReason('speak:closest_approach').single;
      expect(sim.secOf(a.tMs), 65);
      expect(
        sim.secOf(sim.withReason('search_skip:gate_blocked').first.tMs),
        60,
      );
      expect(sim.searchSecs.first, greaterThan(65));
      // 通り過ぎたあとは後ろにあって候補に入らないので、一致が返っても話さない
      expect(sim.speaks, hasLength(1));
    });

    test('論点11：答えを待つ間は話せず、鮮度期限（撮ってから15秒）を過ぎたら捨てる', () {
      final sim = Sim(const EngineConfig(), answer((id) => unlistedFor(id)));
      sim.run(
        90,
        quality: goodQuality,
        // 63秒に答えが届くが、62〜85秒は読み上げ中（ほかの話）として話せない
        ttsSpeaking: (sec) => sec >= 62 && sec <= 85,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searchSecs.first, 60);
      final expired = sim.withReason('answer:expired').single;
      expect(sim.secOf(expired.tMs), 76);
      expect(sim.speaks, isEmpty);
    });
  });

  group('答え', () {
    test('候補のランドマークと一致したら A の原稿で話し、A で話した扱いにする', () {
      // 歩く道から40m離れた（A のジオフェンスの外の）ランドマークを、正面の視線の中に置く
      final lm = landmark('lm_0002', -200, 40, short: '見本の蔵の説明です。');
      final sim = Sim(
        const EngineConfig(),
        answer((id) => matchedFor(id, 'lm_0002')),
      );
      sim.run(
        70,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [lm]),
          ],
        },
      );
      final (_, search) = sim.searches.single;
      expect(search.candidateIds, ['lm_0002']);
      expect(search.gazeAzDeg10, 180);
      expect(search.area, isNull);
      final d = sim.withReason('answer:matched_landmark').single;
      expect(d.kind, 'answer');
      expect(d.targetId, 'lm_0002');
      expect(d.text, 'さっき正面に見えたのは見本lm_0002です。見本の蔵の説明です。');
      expect(sim.engine.toldIds, contains('lm_0002'));
    });

    test('B で一致して話したランドマークは、次の検索で一致しても二度は話さない', () {
      // 道から20m、ジオフェンスは10m（A は話さない）。60秒（124m先）と120秒（48m先）の
      // どちらでも視線の左右30°以内・150m以内に入る
      final lm = landmark('lm_0009', -200, 20, radiusM: 10);
      final sim = Sim(
        const EngineConfig(),
        answer((id) => matchedFor(id, 'lm_0009')),
      );
      sim.run(
        130,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [lm]),
          ],
        },
      );
      expect(sim.searches.map((s) => s.$2.candidateIds), [
        ['lm_0009'],
        ['lm_0009'],
      ]);
      expect(sim.withReason('answer:matched_landmark'), hasLength(1));
      expect(sim.withReason('answer:already_told').single.targetId, 'lm_0009');
      expect(sim.speaks, hasLength(1));
    });

    test('論点10：方向は、撮ったときの視線と話し始めるときの進行方向の差で言う', () {
      final sim = Sim(const EngineConfig(), answer((id) => unlistedFor(id)));
      sim.run(
        70,
        quality: goodQuality,
        // 南へ歩きながら、60秒だけ右（西）を見た
        gaze: (sec) => sec == 60 ? 270 : 180,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searches.single.$2.gazeAzDeg10, 270);
      final d = sim.withReason('answer:unlisted_object').single;
      expect(d.text, startsWith('さっき右手に見えたのは古い木造の蔵です。'));
    });

    test('論点8：候補には話したランドマークも入れる。候補は距離の近い順、視線の左右30°以内だけ', () {
      final near = landmark('lm_0003', -150, 10);
      final far = landmark('lm_0004', -200, -20);
      final side = landmark('lm_0005', -80, 100); // 視線から外れる
      final area = landmark('lm_0006', 0, 0, kind: 'area', radiusM: 10);
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        60,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [far, near, side, area]),
          ],
        },
      );
      final (_, search) = sim.searches.single;
      expect(search.candidateIds, ['lm_0003', 'lm_0004']);
      expect(sim.engine.toldIds, contains('lm_0006')); // エリアは候補に入れない
    });

    test('論点9：候補外の対象は名前が同じなら2回話さない', () {
      final sim = Sim(const EngineConfig(), answer((id) => unlistedFor(id)));
      sim.run(
        130,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.withReason('answer:unlisted_object'), hasLength(1));
      expect(sim.withReason('answer:already_told'), hasLength(1));
    });

    test('一般名は、前に話した撮影場所から100m以上離れていれば、同じ名前でもまた話す', () {
      // 1.3m/sで歩くと、60秒→120秒は78m（二度目とみなす）、60秒→180秒は156m（別の対象）
      final sim = Sim(const EngineConfig(), answer((id) => unlistedFor(id)));
      sim.run(
        190,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(
        sim.decisions
            .where((d) => d.kind == 'answer')
            .map((d) => (sim.secOf(d.tMs), d.reason)),
        [
          (60 + 3.0, 'answer:unlisted_object'),
          (120 + 3.0, 'answer:already_told'),
          (180 + 3.0, 'answer:unlisted_object'),
        ],
      );
    });

    test('固有名は、離れた場所でも同じ名前なら二度は話さない', () {
      final sim = Sim(
        const EngineConfig(),
        answer((id) => unlistedFor(id, name: '見本橋', named: true)),
      );
      sim.run(
        190,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.withReason('answer:named_object'), hasLength(1));
      expect(sim.withReason('answer:already_told'), hasLength(2));
    });

    test('候補外の答えは自信0.7未満なら話さず、候補と一致した答えは0.6以上なら話す', () {
      final lm = landmark('lm_0002', -200, 40);
      for (final (make, reason)
          in <(VisualSearchResponse Function(String), String)>[
            (
              (id) => unlistedFor(id, confidence: 0.65),
              'answer:low_confidence',
            ),
            (
              (id) => VisualSearchResponse.fromJson(
                matchedFor(id, 'lm_0002').toJson()..['confidence'] = 0.65,
              ),
              'answer:matched_landmark',
            ),
          ]) {
        final sim = Sim(const EngineConfig(), answer(make));
        sim.run(
          70,
          quality: goodQuality,
          extra: {
            0: [
              tiles(0, [lm]),
            ],
          },
        );
        expect(
          sim.decisions.where((d) => d.kind == 'answer').single.reason,
          reason,
        );
      }
    });

    test('自信が低い答えは話さない', () {
      final sim = Sim(
        const EngineConfig(),
        answer((id) => unlistedFor(id, confidence: 0.5)),
      );
      sim.run(
        70,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.withReason('answer:low_confidence'), hasLength(1));
      expect(sim.speaks, isEmpty);
    });

    test('エリアの中ではエリアを付けて送り、名前の付いた対象は named_object として出典つきで記録する', () {
      final park = landmark(
        'lm_0007',
        -50,
        0,
        kind: 'area',
        radiusM: 300,
        short: '見本の公園です。',
      );
      const source = (title: '見本橋（見本の場所データ）', uri: 'https://example.com/p');
      final sim = Sim(
        const EngineConfig(),
        answer(
          (id) => unlistedFor(
            id,
            name: '見本橋',
            description: '公園の両岸を結ぶ歩行者用の橋です。',
            named: true,
            sources: [VisualSearchSource(title: source.title, uri: source.uri)],
          ),
        ),
      );
      sim.run(
        70,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [park]),
          ],
        },
      );
      final (_, search) = sim.searches.single;
      expect(search.area?.id, 'lm_0007');
      expect(search.area?.name, '見本lm_0007');
      final d = sim.withReason('answer:named_object').single;
      expect(d.text, 'さっき正面に見えたのは見本橋です。公園の両岸を結ぶ歩行者用の橋です。');
      expect(d.toJson()['sources'], [
        {'title': source.title, 'uri': source.uri},
      ]);
      // 出典のない判断ログには sources の項目を付けない
      expect(
        sim.decisions
            .where((x) => x.reason != 'answer:named_object')
            .every((x) => !x.toJson().containsKey('sources')),
        isTrue,
      );
    });
  });

  group('A に間に合わないとき', () {
    test('B を話して話題の間隔を空けると直後の A が通り過ぎるなら、B を見送って A を話す', () {
      // 長い説明（約18秒）＋話題の間隔20秒のあいだに、正面の石碑を通り過ぎてしまう配置。
      final lm = landmark('lm_0009', -1.3 * (63 + 33), 0, radiusM: 10);
      final long = '白い漆喰の壁と黒い瓦屋根の蔵が見えます。' * 4;
      final sim = Sim(
        const EngineConfig(),
        answer((id) => unlistedFor(id, description: long)),
      );
      sim.run(
        110,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [lm]),
          ],
        },
      );
      expect(sim.searchSecs, [60]);
      final y = sim.withReason('answer:yield_to_narrative').single;
      expect(sim.secOf(y.tMs), 63);
      expect(sim.speaks.single.$2.text, contains('見本lm_0009'));
    });

    test('A に間に合うなら B を話す（短い説明）', () {
      final lm = landmark('lm_0009', -1.3 * (63 + 33), 0, radiusM: 10);
      final sim = Sim(const EngineConfig(), answer(unlistedFor));
      sim.run(
        110,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [lm]),
          ],
        },
      );
      expect(sim.withReason('answer:yield_to_narrative'), isEmpty);
      expect(sim.speaks.map((s) => s.$2.text.contains('蔵')), [true, false]);
    });
  });

  group('結果が来ないとき・失敗', () {
    test('論点5：結果待ちの間は次を撮らず、15秒たっても来なければ諦めて次の間隔を待つ', () {
      final sim = Sim(const EngineConfig(), (c, t) => null);
      sim.run(
        130,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searchSecs, [60, 120]);
      expect(
        sim.withReason('answer:error').map((d) => sim.secOf(d.tMs)).first,
        76,
      );
    });

    test('諦めたあとに届いた結果は、期限切れとして記録し、話さない', () {
      final sim = Sim(
        const EngineConfig(),
        answer((id) => unlistedFor(id)),
        20,
      );
      sim.run(
        90,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.withReason('answer:error').single.targetId, 's_000001');
      expect(sim.withReason('answer:expired').single.targetId, 's_000001');
      expect(sim.speaks, isEmpty);
    });

    test('鮮度期限を過ぎて届いた結果は話さない', () {
      final sim = Sim(
        const EngineConfig(),
        answer((id) => unlistedFor(id)),
        16,
      );
      sim.run(
        80,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.withReason('answer:expired'), hasLength(1));
      expect(sim.speaks, isEmpty);
    });

    test('失敗（visual_error）は answer:error を記録し、次の計測へ進む', () {
      final sim = Sim(
        const EngineConfig(),
        (c, t) => VisualError(tMs: t, searchId: c.searchId, error: 'timeout'),
      );
      sim.run(
        125,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.withReason('answer:error'), hasLength(2));
      expect(sim.searchSecs, [60, 120]);
    });
  });

  group('見本の答え（schema/examples/visual_search_response_*.json）', () {
    // 見本の search_id を、engine が出した検索の ID に差し替えて返す
    Responder example(String name) =>
        (c, t) => VisualResult(
          tMs: t,
          response: VisualSearchResponse.fromJson(
            readExample(name)..['search_id'] = c.searchId,
          ),
        );
    for (final (name, reason) in [
      ('visual_search_response_matched.json', 'answer:matched_landmark'),
      ('visual_search_response_unlisted.json', 'answer:unlisted_object'),
      ('visual_search_response_unknown.json', 'answer:unknown'),
      ('visual_search_response_named.json', 'answer:named_object'),
    ]) {
      test('$name → $reason', () {
        // matched の見本が返す lm_0001 を、視線の中（候補）に置く
        final lm = landmark('lm_0001', -200, 40, short: '見本の原稿です。');
        final sim = Sim(const EngineConfig(), example(name));
        sim.run(
          70,
          quality: goodQuality,
          extra: {
            0: [
              tiles(0, [lm]),
            ],
          },
        );
        final answers = sim.decisions.where((d) => d.kind == 'answer');
        expect(answers.map((d) => d.reason), [reason]);
        final spoken = reason != 'answer:unknown';
        expect(sim.speaks, hasLength(spoken ? 1 : 0));
        if (name.endsWith('named.json')) {
          expect(answers.single.toJson()['sources'], isNotEmpty);
        }
      });
    }

    test('送った候補にない ID が一致として返ったら、取り違えとみなして話さない', () {
      // lm_0001 は持っているが、視線の外なので候補に入らない
      final lm = landmark('lm_0001', 100, 0);
      final sim = Sim(
        const EngineConfig(),
        example('visual_search_response_matched.json'),
      );
      sim.run(
        70,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [lm]),
          ],
        },
      );
      expect(sim.searches.single.$2.candidateIds, isEmpty);
      expect(sim.withReason('answer:unknown'), hasLength(1));
      expect(sim.speaks, isEmpty);
      expect(sim.engine.toldIds, isNot(contains('lm_0001')));
    });
  });

  group('送るもの・画面に出す値', () {
    test('視線の方位は10°単位に丸めて送る', () {
      for (final (gaze, expected) in [(355.0, 0), (184.0, 180), (5.0, 10)]) {
        final sim = Sim(const EngineConfig(), answer(unknownFor));
        sim.run(
          60,
          pose: (sec) => (north: -1.3 * sec, east: 0, speed: 1.3, course: 180),
          gaze: (_) => gaze,
          quality: goodQuality,
          extra: {
            0: [tiles(0, const [])],
          },
        );
        expect(sim.searches.single.$2.gazeAzDeg10, expected);
      }
    });

    test('EngineView：次の計測までの時間、結果待ち、近くの候補、最後の判断を返す', () {
      final lm = landmark('lm_0008', -30, 20);
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        20,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [lm]),
          ],
        },
      );
      var view = sim.engine.view;
      expect(view.nextSearchInMs, 40000);
      expect(view.searching, isFalse);
      expect(view.nearby.single.id, 'lm_0008');
      expect(view.nearby.single.relativeBearingDeg, lessThan(0)); // 南を向いて東は左
      sim.run(61, from: 21, quality: goodQuality);
      view = sim.engine.view;
      expect(view.searching, isTrue);
      expect(view.nextSearchInMs, isNull);
      expect(view.lastDecision?.reason, 'search:interval_elapsed');
      expect(view.searchSkipReason, isNull);
      expect(view.currentArea, isNull);
    });

    test('EngineView：B を止めている理由と、いまいるエリアを返す', () {
      final park = landmark('lm_0001', -20, 0, kind: 'area', radiusM: 200);
      final sim = Sim();
      sim.run(
        65,
        quality: goodQuality,
        audio: AudioOut.none,
        extra: {
          0: [
            tiles(0, [park]),
          ],
        },
      );
      final view = sim.engine.view;
      expect(view.searchSkipReason, 'search_skip:gate_blocked');
      expect(view.currentArea?.id, 'lm_0001');
      expect(view.nextSearchInMs, 0);
    });

    test('判断ログの sources は answer のときだけ付けられる', () {
      expect(
        () => Decision(
          tMs: 1,
          kind: 'skip',
          reason: 'skip:already_told',
          targetId: null,
          text: null,
          priority: null,
          sources: [VisualSearchSource(title: 't', uri: 'u')],
        ),
        throwsFormatException,
      );
    });
  });
}

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
  part: null,
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
  String part = 'whole',
  List<VisualSearchSource> sources = const [],
}) => VisualSearchResponse(
  searchId: searchId,
  result: 'unlisted',
  landmarkId: null,
  objectName: name,
  description: description,
  part: part,
  confidence: confidence,
  named: named,
  sources: sources,
);

VisualSearchResponse matchedFor(
  String searchId,
  String landmarkId, {
  String part = 'whole',
  String? description,
  double confidence = 0.86,
}) => VisualSearchResponse(
  searchId: searchId,
  result: 'matched',
  landmarkId: landmarkId,
  objectName: null,
  description: part == 'whole' ? null : description ?? '入口の上に白い飾りが付いています。',
  part: part,
  confidence: confidence,
  named: false,
  sources: const [],
);

Responder answer(VisualSearchResponse Function(String searchId) make) =>
    (c, t) => VisualResult(tMs: t, response: make(c.searchId));

/// 検索ごとに順に違う答えを返す（足りなければ最後の答えを繰り返す）。
Responder answers(List<VisualSearchResponse Function(String searchId)> makes) {
  var i = 0;
  return (c, t) {
    final make = makes[i < makes.length ? i : makes.length - 1];
    i++;
    return VisualResult(tMs: t, response: make(c.searchId));
  };
}

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

/// 場面のテストは、作ったときの計測の間隔（60秒）と、立ち止まりの前倒しの間隔（30秒）で時刻を組んである。
/// 既定（20秒・10秒）で動くことは「既定の間隔は20秒」「既定では立ち止まって5秒・前から10秒」のテストで確かめる。
const bConfig = EngineConfig(
  visualIntervalMs: 60000,
  stillEarlyMinIntervalMs: 30000,
);

/// 道から8m・範囲30mの lm_0009 に向かって歩き、85秒で立ち止まる。A は81秒ごろに紹介する。
/// 60秒（紹介の前）・120秒・180秒（視線を右へ35°振る）に撮り、3回とも lm_0009 が候補に入る。
/// 読み上げた判断の理由コード（話した順）。
List<String> spokenReasons(Sim sim) => [
  for (final d in sim.decisions)
    if (d.text != null) d.reason,
];

Sim introduced(Responder respond) {
  final lm = landmark('lm_0009', -130, 8, radiusM: 30);
  final sim = Sim(bConfig, respond);
  sim.run(
    190,
    pose: (sec) => sec < 85
        ? southWalk(sec)
        : (north: -1.3 * 85, east: 0.0, speed: 0.0, course: 180.0),
    gaze: (sec) => sec >= 150 ? 145.0 : 180.0,
    quality: goodQuality,
    extra: {
      0: [
        tiles(0, [lm]),
      ],
    },
  );
  expect(sim.searchSecs, [60, 120, 180]);
  expect(
    sim.searches.every((x) => x.$2.candidateIds.contains('lm_0009')),
    isTrue,
  );
  return sim;
}

void main() {
  group('いつ撮るか', () {
    test('論点1・2：最初の1枚はタイルが届いてから60秒後、その後は最後に撮った時刻から60秒ごと', () {
      final sim = Sim(bConfig, answer(unknownFor));
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
      final sim = Sim(bConfig, answer(unknownFor));
      sim.run(100, from: 10, quality: goodQuality);
      expect(sim.searchSecs, [70]);
      final c = sim.searches.single.$2;
      expect(c.candidateIds, isEmpty);
      expect(c.area, isNull);
    });

    test('論点7：画質が足りない間は撮らず、理由を1回だけ記録し、足りたら次の秒に撮る', () {
      final sim = Sim(bConfig, answer(unknownFor));
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
      final sim = Sim(bConfig, answer(unknownFor));
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
      final sim = Sim(bConfig, answer(unknownFor));
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

    test('既定の間隔は20秒：最初の1枚は位置と向きが取れてから20秒後、その後20秒ごと', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        70,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searchSecs, [20, 40, 60]);
    });

    test('既定では回数の上限がなく、31回目以降も撮る', () {
      final sim = Sim(
        const EngineConfig(visualIntervalMs: 20000),
        answer(unknownFor),
      );
      sim.run(
        700,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.searchSecs.length, greaterThan(30));
      expect(sim.withReason('search_skip:limit_reached'), isEmpty);
      expect(sim.engine.view.searchesLeft, isNull);
    });

    test('論点6：立ち止まって5秒たち、前に撮ってから30秒以上なら前倒しで撮る', () {
      final sim = Sim(bConfig, answer(unknownFor));
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

    test('既定では、立ち止まって5秒たち、前に撮ってから10秒以上なら前倒しで撮る', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        18,
        pose: (sec) => sec < 10 ? southWalk(sec) : stopAt(10),
        activity: (sec) => sec < 10 ? Activity.walking : Activity.still,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      // 15秒：止まって5秒、位置と向きが取れてから15秒（10秒以上）。間隔の20秒を待たずに撮る
      expect(sim.searchSecs, [15]);
      expect(sim.withReason('search:stopped_early'), hasLength(1));
    });

    test('論点6：前に撮ってから30秒たっていなければ、立ち止まっても待つ', () {
      final sim = Sim(bConfig, answer(unknownFor));
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

  group('「調べて」と頼まれたとき', () {
    SearchRequested request(int sec) => SearchRequested(tMs: ms(sec));

    test('歩行ログには search_request（data は空）として書き、読み戻せる', () {
      final json = eventToJson(request(3));
      expect(json['type'], 'search_request');
      expect(json['data'], isEmpty);
      expect(eventFromJson(json), isA<SearchRequested>());
    });

    test('計測間隔が経っていなくても、その場で撮る。次の自動はそこから60秒後', () {
      final sim = Sim(bConfig, answer(unknownFor));
      sim.run(
        100,
        quality: goodQuality,
        extra: {
          20: [request(20)],
        },
      );
      expect(sim.searchSecs, [20, 80]);
      expect(
        sim.decisions.firstWhere((d) => d.kind == 'search').reason,
        'search:user_requested',
      );
    });

    test('前回と同じ場所・同じ向きでも撮る', () {
      final sim = Sim(bConfig, answer(unknownFor));
      sim.run(
        75,
        pose: standing,
        quality: goodQuality,
        extra: {
          70: [request(70)],
        },
      );
      expect(sim.searchSecs, [60, 70]);
      expect(sim.withReason('search:user_requested'), hasLength(1));
    });

    test('横断歩道の手前では撮らず、理由を残して依頼を終える（渡ったあとに勝手に撮らない）', () {
      final crossing = Crossing(
        id: 'cr_0001',
        lat: latAt(-20),
        lon: lonAt(0),
        kind: 'crossing',
      );
      final sim = Sim(bConfig, answer(unknownFor));
      sim.run(
        50,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, const [], crossings: [crossing]),
          ],
          5: [request(5)],
        },
      );
      expect(sim.searches, isEmpty);
      final skip = sim.withReason('search_skip:gate_blocked').single;
      expect(sim.secOf(skip.tMs), 5);
      expect(sim.engine.view.searchSkipReason, 'search_skip:gate_blocked');
    });

    Landmark longLandmark() => landmark(
      'lm_0001',
      -60,
      5,
      radiusM: 30,
      short: '見本のための架空の石碑で、とても長い説明がこのあとしばらく続きます。',
    );

    /// 頼まずに歩いて、A が話し始める秒を調べる。
    int narrativeStartSec(Pose Function(int) pose) {
      final dry = Sim(const EngineConfig(), answer(unknownFor));
      dry.run(
        60,
        pose: pose,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [longLandmark()]),
          ],
        },
      );
      return dry.secOf(dry.speaks.first.$1).ceil();
    }

    test('A を読み上げている最中でも撮り、「検索します」で A を止め、答えを話す。A の続きは話さない', () {
      final aSec = narrativeStartSec(southWalk);
      final sim = Sim(const EngineConfig(), answer((id) => unlistedFor(id)));
      sim.run(
        aSec + 20,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [longLandmark()]),
          ],
          aSec + 1: [SearchRequested(tMs: ms(aSec + 1))],
        },
      );
      final search = sim.withReason('search:user_requested').single;
      expect(sim.secOf(search.tMs), aSec + 1);
      final ack = sim.speaks.firstWhere((s) => s.$2.text == '検索します。');
      expect(sim.secOf(ack.$1), aSec + 1);
      expect(ack.$2.interrupt, isTrue);
      expect(ack.$2.chime, isFalse);
      expect(sim.withReason('speak:search_ack'), hasLength(1));
      final answerSpeak = sim.speaks.firstWhere(
        (s) => s.$2.text.contains('古い木造の蔵'),
      );
      expect(sim.secOf(answerSpeak.$1), aSec + 1 + 3);
      expect(answerSpeak.$2.chime, isTrue);
      // A の続きも話し直しもしない。範囲にいる間は止めた理由を残す
      expect(
        sim.speaks.where((s) => s.$2.text.contains('見本lm_0001')),
        hasLength(1),
      );
      expect(
        sim.speaks.where((s) => s.$2.text.contains('さきほどの話の続きです')),
        isEmpty,
      );
      expect(sim.withReason('skip:interrupted'), isNotEmpty);
    });

    test('答えを待っている間は A を始めない', () {
      final sim = Sim(const EngineConfig(), answer((id) => unlistedFor(id)), 5);
      // A の話が始まる少し前に頼む
      final aSec = narrativeStartSec(southWalk);
      sim.run(
        aSec + 20,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [longLandmark()]),
          ],
          aSec - 2: [SearchRequested(tMs: ms(aSec - 2))],
        },
      );
      expect(sim.withReason('skip:awaiting_search'), isNotEmpty);
      final answerSec = sim.secOf(
        sim.speaks.firstWhere((s) => s.$2.text.contains('古い木造の蔵')).$1,
      );
      final aSpeaks = sim.speaks.where((s) => s.$2.text.contains('見本lm_0001'));
      for (final (t, _) in aSpeaks) {
        expect(sim.secOf(t), greaterThan(answerSec));
      }
    });

    test('検索で止めたランドマークは、一度離れてからまた近づいたら最初から話す', () {
      // 南へ80秒歩いて（石碑から約44m 離れる）、北へ引き返す
      Pose outAndBack(int sec) => sec <= 80
          ? (north: -1.3 * sec, east: 0, speed: 1.3, course: 180)
          : (
              north: -1.3 * 80 + 1.3 * (sec - 80),
              east: 0,
              speed: 1.3,
              course: 0,
            );
      final aSec = narrativeStartSec(outAndBack);
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        160,
        pose: outAndBack,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [longLandmark()]),
          ],
          aSec + 1: [SearchRequested(tMs: ms(aSec + 1))],
        },
      );
      final aSpeaks = [
        for (final (t, s) in sim.speaks)
          if (s.text.contains('見本lm_0001')) sim.secOf(t),
      ];
      expect(aSpeaks, hasLength(2));
      expect(aSpeaks.last, greaterThan(80));
    });

    test('警報を読み上げている最中は撮らない（警報は横取りしない）', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        30,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
          10: [
            AlertReceived(
              tMs: ms(10),
              alertId: 'alert_x',
              level: 3,
              kind: '大雨警報',
              areaName: '富山市',
              text:
                  '富山市に大雨警報が出ています。川や用水路に近づかないでください。'
                  '最新の情報を確認してください。',
            ),
          ],
          12: [SearchRequested(tMs: ms(12))],
        },
      );
      expect(sim.withReason('search:user_requested'), isEmpty);
      expect(
        sim.withReason('search_skip:gate_blocked').map((d) => sim.secOf(d.tMs)),
        contains(12),
      );
    });

    test('頼まれた検索は、もう話した対象でももう一度話す（自動では話さない）', () {
      // 11/6 メンバー3決定：頼んだのに「もう話した」で黙ると壊れて見えるため。
      // ランドマーク全体は頼まれても B では話さない（全体の紹介は A。11/6 夜決定）。
      final sim = Sim(
        const EngineConfig(visualIntervalMs: 60000),
        answer((id) => unlistedFor(id, part: 'window')),
      );
      sim.run(
        110,
        quality: goodQuality,
        extra: {
          100: [SearchRequested(tMs: ms(100))],
        },
      );
      expect(sim.searchSecs, [60, 100]);
      expect(sim.withReason('answer:unlisted_object'), hasLength(2));
      expect(sim.withReason('answer:already_told'), isEmpty);
      // 自動の答え・「検索します」・頼まれた答え
      expect(sim.speaks.map((s) => s.$2.text.startsWith('検索します')), [
        false,
        true,
        false,
      ]);
    });

    test('前の検索の結果を待っている間は撮らない', () {
      final sim = Sim(bConfig, answer(unknownFor), 10);
      sim.run(
        65,
        quality: goodQuality,
        extra: {
          62: [request(62)],
        },
      );
      expect(sim.searchSecs, [60]);
      expect(
        sim.withReason('search_skip:gate_blocked').map((d) => sim.secOf(d.tMs)),
        [62],
      );
    });
  });

  group('文脈ゲート', () {
    test('乗り物の中・音声の出力先がないときは撮らない', () {
      for (final (activity, audio) in [
        (Activity.inVehicle, AudioOut.earphone),
        (Activity.walking, AudioOut.none),
      ]) {
        final sim = Sim(bConfig, answer(unknownFor));
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
      final sim = Sim(bConfig, answer((id) => unlistedFor(id)));
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
      final sim = Sim(bConfig, answer((id) => matchedFor(id, 'lm_0001')));
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
      final sim = Sim(bConfig, answer((id) => unlistedFor(id)));
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
    test('ランドマーク全体（whole）は B では話さない。A で話した扱いにもしない', () {
      // 歩く道から40m離れた（A のジオフェンスの外の）ランドマークを、正面の視線の中に置く
      final lm = landmark('lm_0002', -200, 40, short: '見本の蔵の説明です。');
      final sim = Sim(bConfig, answer((id) => matchedFor(id, 'lm_0002')));
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
      final d = sim.withReason('answer:whole_left_to_narrative').single;
      expect(d.kind, 'answer');
      expect(d.targetId, 'lm_0002');
      expect(sim.speaks, isEmpty);
      expect(sim.engine.toldIds, isNot(contains('lm_0002')));
    });

    test('A で紹介したあとに全体が返っても、B では話さない', () {
      final sim = introduced(answer((id) => matchedFor(id, 'lm_0009')));
      expect(sim.withReason('answer:whole_left_to_narrative'), hasLength(3));
      expect(spokenReasons(sim), ['speak:closest_approach']);
    });

    test('論点10：方向は、撮ったときの視線と話し始めるときの進行方向の差で言う', () {
      final sim = Sim(bConfig, answer((id) => unlistedFor(id)));
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
      final sim = Sim(bConfig, answer(unknownFor));
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
      final sim = Sim(bConfig, answer((id) => unlistedFor(id)));
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
      final sim = Sim(bConfig, answer((id) => unlistedFor(id)));
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
        bConfig,
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

    test('候補外の答えは自信0.7未満なら話さない', () {
      final lm = landmark('lm_0002', -200, 40);
      final sim = Sim(
        bConfig,
        answer((id) => unlistedFor(id, confidence: 0.65)),
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
      expect(
        sim.decisions.where((d) => d.kind == 'answer').single.reason,
        'answer:low_confidence',
      );
    });

    test('自信が低い答えは話さない', () {
      final sim = Sim(
        bConfig,
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
        bConfig,
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
        bConfig,
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
      final sim = Sim(bConfig, answer(unlistedFor));
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
      final sim = Sim(bConfig, (c, t) => null);
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
      final sim = Sim(bConfig, answer((id) => unlistedFor(id)), 20);
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
      final sim = Sim(bConfig, answer((id) => unlistedFor(id)), 16);
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
        bConfig,
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

  group('どの部分か（part）', () {
    // 道から20m・範囲10m（A は話さない）。60秒と120秒の2回とも候補に入る（上の lm_0009 の場面と同じ）
    Landmark near() => landmark('lm_0009', -200, 20, radiusM: 10);
    Sim twoSearches(Responder respond) {
      final sim = Sim(bConfig, respond);
      sim.run(
        130,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [near()]),
          ],
        },
      );
      expect(sim.searchSecs, [60, 120]);
      return sim;
    }

    test('登録したランドマークの特徴は、A の紹介が済むまで話さず、済んだら特徴の説明を読む', () {
      final sim = introduced(
        answer(
          (id) => matchedFor(
            id,
            'lm_0009',
            part: 'entrance',
            description: '入口の上に白い飾りが付いています。',
            confidence: 0.78,
          ),
        ),
      );
      // 60秒：A の紹介の前なので見送る
      final before = sim.withReason('answer:feature_before_intro').single;
      expect(before.targetId, 'lm_0009');
      expect(sim.secOf(before.tMs), lessThan(80));
      final d = sim.withReason('answer:landmark_feature').single;
      expect(d.targetId, 'lm_0009');
      expect(d.text, 'さっき正面に見えたのは見本lm_0009の入口です。入口の上に白い飾りが付いています。');
      expect(spokenReasons(sim), [
        'speak:closest_approach',
        'answer:landmark_feature',
      ]);
    });

    test('特徴は自信0.7未満なら話さない', () {
      final lm = landmark('lm_0002', -200, 40);
      final sim = Sim(
        bConfig,
        answer(
          (id) => matchedFor(id, 'lm_0002', part: 'roof', confidence: 0.65),
        ),
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
      expect(sim.withReason('answer:low_confidence'), hasLength(1));
      expect(sim.speaks, isEmpty);
    });

    test('同じランドマークの同じ部分は、言い方が違っても二度は話さない', () {
      final sim = introduced(
        answers([
          (id) => matchedFor(id, 'lm_0009', part: 'window'),
          (id) => matchedFor(
            id,
            'lm_0009',
            part: 'window',
            description: '窓の上に波の形の飾りがあります。',
          ),
          (id) => matchedFor(
            id,
            'lm_0009',
            part: 'window',
            description: '窓の上に波模様が見えます。',
          ),
        ]),
      );
      expect(sim.withReason('answer:landmark_feature'), hasLength(1));
      expect(sim.withReason('answer:already_told').single.targetId, 'lm_0009');
    });

    test('同じランドマークでも別の部分なら話す。その他（other）は話さない', () {
      final sim = introduced(
        answers([
          (id) => matchedFor(id, 'lm_0009', part: 'window'),
          (id) => matchedFor(id, 'lm_0009', part: 'window'),
          (id) => matchedFor(id, 'lm_0009', part: 'roof'),
        ]),
      );
      expect(sim.withReason('answer:landmark_feature'), hasLength(2));

      final other = introduced(
        answers([
          (id) => matchedFor(id, 'lm_0009', part: 'window'),
          (id) => matchedFor(id, 'lm_0009', part: 'other'),
        ]),
      );
      expect(other.withReason('answer:landmark_feature'), isEmpty);
      expect(other.withReason('answer:already_told'), hasLength(2));
    });

    test('候補外の対象も（場所, part）で見分ける：同じ蔵の窓と壁は別の話、窓をもう一度は話さない', () {
      final both = twoSearches(
        answers([
          (id) => unlistedFor(id, part: 'window'),
          (id) => unlistedFor(id, part: 'wall'),
        ]),
      );
      expect(both.withReason('answer:unlisted_object'), hasLength(2));

      final again = twoSearches(
        answers([
          (id) => unlistedFor(id, part: 'window'),
          (id) => unlistedFor(id, part: 'window'),
        ]),
      );
      expect(again.withReason('answer:unlisted_object'), hasLength(1));
      expect(again.withReason('answer:already_told'), hasLength(1));
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
      ('visual_search_response_matched.json', 'answer:whole_left_to_narrative'),
      ('visual_search_response_unlisted.json', 'answer:unlisted_object'),
      ('visual_search_response_unknown.json', 'answer:unknown'),
      ('visual_search_response_named.json', 'answer:named_object'),
      (
        'visual_search_response_matched_feature.json',
        'answer:feature_before_intro',
      ),
    ]) {
      test('$name → $reason', () {
        // matched の見本が返す lm_0001 を、視線の中（候補）に置く
        final lm = landmark('lm_0001', -200, 40, short: '見本の原稿です。');
        final sim = Sim(bConfig, example(name));
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
        final spoken = !{
          'answer:unknown',
          'answer:whole_left_to_narrative',
          'answer:feature_before_intro',
        }.contains(reason);
        expect(sim.speaks, hasLength(spoken ? 1 : 0));
        if (name.endsWith('named.json')) {
          expect(answers.single.toJson()['sources'], isNotEmpty);
        }
      });
    }

    test('送った候補にない ID が一致として返ったら、取り違えとみなして話さない', () {
      // lm_0001 は持っているが、視線の外なので候補に入らない
      final lm = landmark('lm_0001', 100, 0);
      final sim = Sim(bConfig, example('visual_search_response_matched.json'));
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

  group('カメラで調べない区域', () {
    // 南へ秒速1.3m。中心は100m南・半径20m：62秒ごろ（80m地点）に入り、104秒ごろ（135m地点）に出る
    const entered = 'speak:no_camera_zone_entered';
    const exited = 'speak:no_camera_zone_exited';
    Map<int, List<EngineEvent>> zoneTiles({
      List<Landmark> landmarks = const [],
    }) => {
      0: [
        tiles(0, landmarks, zones: [zone('zn_0001', -100, 0)]),
      ],
    };
    List<double> capturesBetween(Sim sim, double from, double to) => [
      for (final s in sim.searchSecs)
        if (s >= from && s <= to) s.toDouble(),
    ];

    test('① 外 → 中 → 外：入った・出たを1回ずつ話し、中では撮らない', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(80, quality: goodQuality, extra: zoneTiles());
      expect(sim.engine.view.noCameraZone?.id, 'zn_0001');
      expect(sim.engine.view.noCameraZone?.name, '見本の区域zn_0001');
      sim.run(160, from: 81, quality: goodQuality);
      expect(sim.engine.view.noCameraZone, isNull);

      final inAt = sim.secOf(sim.withReason(entered).single.tMs);
      final outAt = sim.secOf(sim.withReason(exited).single.tMs);
      expect(inAt, inInclusiveRange(60, 65));
      expect(outAt, inInclusiveRange(102, 108));
      expect(
        sim.withReason(entered).single.text,
        'ここからは、カメラで調べない区域です。画像での案内を止めます。',
      );
      expect(
        sim.withReason(exited).single.text,
        'カメラで調べない区域を出ました。画像での案内を再開します。',
      );
      expect(capturesBetween(sim, inAt, outAt), isEmpty);
      expect(sim.withReason('search_skip:no_camera_zone'), isNotEmpty);
      // 出たあとの B は通常どおり
      expect(sim.searchSecs.where((s) => s > outAt), isNotEmpty);
    });

    test('② 境目（半径〜半径＋15m）を行き来しても、知らせは増えない', () {
      // 85m地点（中心から15m）で入り、そのあと72m地点（28m）と85m地点を10秒ごとに行き来する
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        160,
        pose: (sec) {
          if (sec < 66) return southWalk(sec);
          final near = ((sec - 66) ~/ 10).isEven;
          return (
            north: near ? -72.0 : -85.0,
            east: 0.0,
            speed: 0.0,
            course: 180.0,
          );
        },
        quality: goodQuality,
        extra: zoneTiles(),
      );
      expect(sim.withReason(entered), hasLength(1));
      expect(sim.withReason(exited), isEmpty);
      expect(sim.engine.view.noCameraZone?.id, 'zn_0001');
    });

    test('③ 中で「調べて」：撮らずに決まった文で断り、出たあとに勝手に撮らない', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        160,
        quality: goodQuality,
        extra: {
          ...zoneTiles(),
          80: [SearchRequested(tMs: ms(80))],
        },
      );
      final d = sim
          .withReason('search_skip:no_camera_zone')
          .firstWhere((x) => x.text != null);
      expect(sim.secOf(d.tMs), 80);
      expect(d.kind, 'search_skip');
      expect(d.text, 'ここはカメラで調べない区域なので、調べられません。');
      expect(sim.withReason('search:user_requested'), isEmpty);
      expect(sim.withReason('speak:search_ack'), isEmpty);
    });

    test('④ 入る直前に撮った答えが区域の中で届いたら、話さずに捨てる', () {
      // 60秒（中心から22m、まだ外）に撮り、答えは63秒（中）に届く
      final sim = Sim(
        const EngineConfig(),
        answers([unknownFor, unknownFor, (id) => unlistedFor(id)]),
      );
      sim.run(90, quality: goodQuality, extra: zoneTiles());
      expect(sim.searchSecs.take(3), [20, 40, 60]);
      final d = sim.withReason('answer:in_no_camera_zone').single;
      expect(sim.secOf(d.tMs), 63);
      expect(sim.withReason('answer:unlisted_object'), isEmpty);
    });

    test('⑤ 「入った」を話す前に出たら、入った・出たの両方を話さない', () {
      // 半径5mの区域を通り抜ける間（約55〜80秒）、ずっと読み上げ中
      final sim = Sim(const EngineConfig());
      sim.run(
        120,
        ttsSpeaking: (sec) => sec >= 50 && sec <= 85,
        extra: {
          0: [
            tiles(0, const [], zones: [zone('zn_0001', -78, 0, radiusM: 5)]),
          ],
        },
      );
      expect(sim.withReason(entered), isEmpty);
      expect(sim.withReason(exited), isEmpty);
      expect(sim.speaks, isEmpty);
    });

    test('⑥ 区域の中に A のランドマークがあっても、A は話す（知らせのあとに）', () {
      // 半径60mの区域（31秒ごろ入る）の奥にあるランドマークを、区域の中で話す
      final lm = landmark('lm_0001', -110, 0);
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        120,
        quality: goodQuality,
        extra: {
          0: [
            tiles(0, [lm], zones: [zone('zn_0001', -100, 0, radiusM: 60)]),
          ],
        },
      );
      final reasons = [
        for (final d in sim.decisions)
          if (d.text != null) d.reason,
      ];
      expect(reasons, containsAllInOrder([entered, 'speak:closest_approach']));
      expect(sim.engine.toldIds, contains('lm_0001'));
    });

    test('⑦ zones の無い古いタイル：区域なしとして動く', () {
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        120,
        quality: goodQuality,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(sim.engine.view.noCameraZone, isNull);
      expect(sim.withReason('search_skip:no_camera_zone'), isEmpty);
      expect(sim.searchSecs, containsAll([60, 80, 100]));
    });

    test('⑧ 同じログなら同じ結果', () {
      List<Map<String, dynamic>> runOnce() {
        final sim = Sim(const EngineConfig(), answer((id) => unlistedFor(id)));
        sim.run(
          160,
          quality: goodQuality,
          extra: {
            ...zoneTiles(),
            80: [SearchRequested(tMs: ms(80))],
          },
        );
        return [for (final d in sim.decisions) d.toJson()];
      }

      expect(runOnce(), runOnce());
    });

    test('出てから60秒以内にまた入ったら、知らせは話さない（撮らないことは同じ）', () {
      // 140m地点まで南へ歩いて（104秒ごろ出る）、引き返して北へ（123秒ごろまた入る）
      final sim = Sim(const EngineConfig(), answer(unknownFor));
      sim.run(
        200,
        pose: (sec) {
          const turn = 108;
          if (sec <= turn) return southWalk(sec);
          return (
            north: -1.3 * turn + 1.3 * (sec - turn),
            east: 0.0,
            speed: 1.3,
            course: 0.0,
          );
        },
        quality: goodQuality,
        extra: zoneTiles(),
      );
      expect(sim.withReason(entered), hasLength(1));
      expect(sim.withReason(exited), hasLength(1));
      final reentry = sim.decisions.where(
        (d) =>
            d.reason == 'search_skip:no_camera_zone' && sim.secOf(d.tMs) > 115,
      );
      expect(reentry, isNotEmpty);
    });
  });

  group('送るもの・画面に出す値', () {
    test('視線の方位は10°単位に丸めて送る', () {
      for (final (gaze, expected) in [(355.0, 0), (184.0, 180), (5.0, 10)]) {
        final sim = Sim(bConfig, answer(unknownFor));
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
      final sim = Sim(bConfig, answer(unknownFor));
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

    test('EngineView：いまいる町丁目は、持っている代表点でいちばん近いもの。800m より遠ければ null', () {
      final ichome = town('162019990001', '見本町一丁目', -50, 0);
      final nichome = town('162019990002', '見本町二丁目', -400, 0);
      final sim = Sim(bConfig);
      expect(sim.engine.view.currentTown, isNull); // 位置がまだ無い
      sim.run(
        0,
        extra: {
          0: [
            tiles(0, const [], towns: [nichome, ichome]),
          ],
        },
      );
      expect(sim.engine.view.currentTown?.name, '見本町一丁目');
      // 200秒で南へ260m：一丁目まで210m、二丁目まで140m
      sim.run(200, from: 1);
      expect(sim.engine.view.currentTown?.name, '見本町二丁目');
      // 二丁目の代表点から800mより遠くへ
      sim.run(1000, from: 201);
      expect(sim.engine.view.currentTown, isNull);
    });

    test('町丁目：距離が同じなら ID の小さい方。町丁目を持たない（古い）タイルだけなら null', () {
      final sim = Sim(bConfig);
      sim.run(
        0,
        extra: {
          0: [
            tiles(
              0,
              const [],
              towns: [
                town('162019990002', '見本町東', 0, 100),
                town('162019990001', '見本町西', 0, -100),
              ],
            ),
          ],
        },
      );
      expect(sim.engine.view.currentTown?.id, '162019990001');

      final old = Sim(bConfig);
      old.run(
        0,
        extra: {
          0: [tiles(0, const [])],
        },
      );
      expect(old.engine.view.currentTown, isNull);
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

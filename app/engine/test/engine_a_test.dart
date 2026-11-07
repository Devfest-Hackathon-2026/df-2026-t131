import 'dart:math' as math;

import 'package:engine/engine.dart';
import 'package:engine/src/geo.dart';
import 'package:engine/src/kalman.dart';
import 'package:test/test.dart';

import 'support/scenario.dart';

void main() {
  group('位置の平滑化', () {
    test('ぶれた位置と進行方向の欠測でも、南へ1.3m/sの速度を推定できる', () {
      final kf = KalmanFilter2D(accelNoise: 0.5, velocityNoise: 0.5);
      kf.reset(const Vec2(0, 0), 5, null);
      for (var sec = 1; sec <= 40; sec++) {
        kf.predict(1);
        // 決まった形の揺れ（乱数を使わない）
        final noise = Vec2(4 * math.sin(sec * 1.7), 4 * math.cos(sec * 2.3));
        kf.updatePosition(Vec2(0, -1.3 * sec) + noise, 5);
      }
      expect(kf.velocity.x, closeTo(0, 0.3));
      expect(kf.velocity.y, closeTo(-1.3, 0.3));
      expect(kf.position.y, closeTo(-52, 4));
    });

    test('タイル番号は見本のタイルと一致する', () {
      expect(tileKey(tileAt(36.7008, 137.2135)), '16/57746/25576');
    });
  });

  group('先読み', () {
    test('最初のセンサーで今いるタイルを要求し、届いたタイルは二度と要求しない', () {
      final sim = Sim()
        ..run(
          40,
          extra: {
            1: [tiles(1, [])],
          },
        );
      final fetches = sim.withReason('fetch:prefetch_tiles').toList();
      expect(fetches.first.tMs, ms(0));
      expect(
        fetches.where((d) => d.targetId == '16/57746/25576'),
        hasLength(1),
      );
      final firstFetch = sim.commands.firstWhere((e) => e.$2 is FetchTiles);
      expect(
        (firstFetch.$2 as FetchTiles).tiles.map(tileKey),
        contains('16/57746/25576'),
      );
    });

    test('届かないタイルは間隔を空けてもう一度要求する', () {
      final sim = Sim()..run(65);
      final times = sim
          .withReason('fetch:prefetch_tiles')
          .where((d) => d.targetId == '16/57746/25576')
          .map((d) => sim.secOf(d.tMs))
          .toList();
      expect(times, [0, 30, 60]);
    });
  });

  group('A：ランドマークの最接近', () {
    test('最接近の手前で1回だけ話し、話した履歴に残す', () {
      // 60m 先・右手 18m の石碑。最接近は約46秒後
      final sim = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', -60, -18)]),
            ],
          },
        );
      final speaks = sim.speaks;
      expect(speaks, hasLength(1));
      final (t, speak) = speaks.single;
      expect(sim.secOf(t), inInclusiveRange(25, 46));
      expect(speak.priority, 5);
      expect(speak.interrupt, isFalse);
      expect(speak.pauseMusic, isFalse);
      expect(
        sim.withReason('speak:closest_approach').single.targetId,
        'lm_0001',
      );
      expect(sim.engine.toldIds, {'lm_0001'});
      expect(sim.withReason('skip:already_told'), isEmpty);
    });

    test('ジオフェンスに入らないランドマークは話さない', () {
      final sim = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', -60, 60)]),
            ],
          },
        );
      expect(sim.speaks, isEmpty);
    });

    test('原稿が話し終えられないなら、方向と名前だけを話す', () {
      // タイルが遅れて届き、最接近（約46秒後）の6秒前に初めて候補になる場面
      final sim = Sim()
        ..run(
          90,
          extra: {
            40: [
              tiles(40, [
                landmark('lm_0001', -60, 0, radiusM: 3, short: 'あ' * 80),
              ]),
            ],
          },
        );
      expect(sim.speaks.single.$2.text, '正面に見本lm_0001があります。');
      expect(sim.withReason('speak:closest_approach'), hasLength(1));
      expect(sim.withReason('skip:pass_before_end'), isEmpty);
    });

    test('名前だけでも話し終えられないなら話さず、理由を1回だけ記録する', () {
      // 最接近（約46秒後）を過ぎてから届き、範囲（3m）を出るまで1秒ほどしかない
      final sim = Sim()
        ..run(
          90,
          extra: {
            47: [
              tiles(47, [
                landmark('lm_0001', -60, 0, radiusM: 3, short: 'あ' * 80),
              ]),
            ],
          },
        );
      expect(sim.speaks, isEmpty);
      expect(sim.withReason('skip:pass_before_end'), hasLength(1));
    });

    test('立ち止まって5秒たち、ジオフェンスの中にいるときは長い版を話す', () {
      final sim = Sim()
        ..run(
          30,
          pose: (_) => (north: 0, east: 0, speed: 0, course: 0),
          activity: (_) => Activity.still,
          extra: {
            6: [
              tiles(6, [landmark('lm_0001', 0, 10)]),
            ],
          },
        );
      expect(sim.withReason('speak:long_version_still'), hasLength(1));
      expect(sim.speaks.single.$2.text, endsWith('長い版の続きです。'));
    });

    test('止まってすぐ（出発直後など）は長い版ではなく短い版を話す', () {
      final sim = Sim()
        ..run(
          30,
          pose: (_) => (north: 0, east: 0, speed: 0, course: 0),
          activity: (_) => Activity.still,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', 0, 10)]),
            ],
          },
        );
      expect(sim.withReason('speak:long_version_still'), isEmpty);
      expect(sim.withReason('speak:closest_approach'), hasLength(1));
      expect(sim.speaks.single.$2.text, isNot(contains('長い版')));
    });

    test('止まっていて後ろにあるものは「振り返ると」と言う', () {
      // 南を向いて止まっている。ランドマークは 10m 北（後ろ）
      final sim = Sim()
        ..run(
          30,
          pose: (_) => (north: 0, east: 0, speed: 0, course: 180),
          activity: (_) => Activity.still,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', 10, 0)]),
            ],
          },
        );
      expect(sim.speaks.single.$2.text, startsWith('振り返ると見本lm_0001があります。'));
    });

    test('最接近を過ぎて後ろにあるものは「いま通り過ぎたのは」と言う', () {
      // 出発地点の 10m 北（後ろ）にある、半径80mの駅。南へ歩いて離れていく
      final sim = Sim()
        ..run(
          30,
          extra: {
            3: [
              tiles(3, [landmark('lm_0001', 10, 0, radiusM: 80)]),
            ],
          },
        );
      final text = sim.speaks.single.$2.text;
      expect(text, startsWith('いま通り過ぎたのは見本lm_0001です。'));
      expect(text, isNot(contains('後方')));
    });
  });

  group('方向の一言', () {
    test('進行方向からの角度を方向の言葉にする（右が正）', () {
      const c = EngineConfig();
      expect(directionWord(0, c), '正面');
      expect(directionWord(-20, c), '正面');
      expect(directionWord(45, c), '右前方');
      expect(directionWord(-45, c), '左前方');
      expect(directionWord(90, c), '右手');
      expect(directionWord(-100, c), '左手');
      expect(directionWord(140, c), '右後方');
      expect(directionWord(-140, c), '左後方');
      expect(directionWord(180, c), '後方');
    });

    test('南へ歩くとき、西にあるランドマークは右、東にあるものは左と言う', () {
      final right = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', -60, -18)]),
            ],
          },
        );
      expect(right.speaks.single.$2.text, startsWith('右前方に見本lm_0001があります。'));
      final left = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', -60, 18)]),
            ],
          },
        );
      expect(left.speaks.single.$2.text, startsWith('左前方に見本lm_0001があります。'));
      // 判断ログにも、実際に読む文（方向つき）を残す
      expect(
        right.withReason('speak:closest_approach').single.text,
        right.speaks.single.$2.text,
      );
    });

    test('止まっているときは視線（スマホの向き）を基準にする', () {
      // 北を向いて立ち止まり、東 10m にランドマーク → 右手
      final sim = Sim()
        ..run(
          30,
          pose: (_) => (north: 0, east: 0, speed: 0, course: 0),
          activity: (_) => Activity.still,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', 0, 10)]),
            ],
          },
        );
      expect(sim.speaks.single.$2.text, startsWith('右手に'));
    });

    test('エリアの定型文には方向を付けない', () {
      final area = landmark(
        'lm_0004',
        0,
        0,
        kind: 'area',
        radiusM: 200,
        short: 'ここは見本の公園です。',
      );
      final sim = Sim()
        ..run(
          5,
          extra: {
            1: [
              tiles(1, [area]),
            ],
          },
        );
      expect(sim.speaks.single.$2.text, 'ここは見本の公園です。');
    });
  });

  group('文脈ゲート', () {
    final lm = landmark('lm_0001', -60, -18);

    test('乗り物の中では話さない', () {
      final sim = Sim()
        ..run(
          120,
          activity: (_) => Activity.inVehicle,
          extra: {
            1: [
              tiles(1, [lm]),
            ],
          },
        );
      expect(sim.speaks, isEmpty);
      expect(sim.withReason('skip:in_vehicle'), hasLength(1));
      expect(sim.withReason('skip:expired'), hasLength(1));
    });

    test('音声の出力先がないときは話さない', () {
      final sim = Sim()
        ..run(
          120,
          audio: AudioOut.none,
          extra: {
            1: [
              tiles(1, [lm]),
            ],
          },
        );
      expect(sim.speaks, isEmpty);
      expect(sim.withReason('skip:no_audio_output'), hasLength(1));
    });

    test('早歩きのときはナラティブを話さない', () {
      final sim = Sim()
        ..run(
          60,
          pose: (sec) => (north: -2.2 * sec, east: 0, speed: 2.2, course: 180),
          extra: {
            1: [
              tiles(1, [lm]),
            ],
          },
        );
      expect(sim.speaks, isEmpty);
      expect(sim.withReason('skip:fast_walking'), hasLength(1));
    });

    test('横断歩道の手前では待ち、渡り終えてから話す', () {
      final crossing = Crossing(
        id: 'cr_0001',
        lat: latAt(-45),
        lon: lonAt(0),
        kind: 'traffic_signals',
      );
      final sim = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [lm], crossings: [crossing]),
            ],
          },
        );
      expect(sim.withReason('skip:crossing_ahead'), hasLength(1));
      final (t, _) = sim.speaks.single;
      expect(sim.secOf(t), greaterThanOrEqualTo(34));
    });

    test('A のあとに A が続くときは、短い間隔（3秒）で次を話す', () {
      final sim = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [lm, landmark('lm_0002', -80, 18)]),
            ],
          },
        );
      final speaks = sim.speaks;
      expect(speaks, hasLength(2));
      final firstEnd =
          speaks[0].$1 + (speaks[0].$2.text.runes.length / 6 * 1000).ceil();
      final gap = speaks[1].$1 - firstEnd;
      expect(gap, greaterThanOrEqualTo(3000 - 1000));
      expect(gap, lessThan(20000 - 1000));
    });

    test('A を話している間に入った次のランドマークは、待ってから短い間隔で話す', () {
      // 1つ目を話している間に、2つ目の範囲（25m）に入る並び
      final first = landmark('lm_0001', -40, -10, short: 'あ' * 70);
      final second = landmark('lm_0002', -50, 10);
      final sim = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [first, second]),
            ],
          },
        );
      expect(sim.speaks.map((e) => e.$2.text), [
        contains('見本lm_0001'),
        contains('見本lm_0002'),
      ]);
      expect(
        sim.withReason('skip:tts_busy').where((d) => d.targetId == 'lm_0002'),
        isNotEmpty,
      );
      expect(sim.withReason('skip:expired'), isEmpty);
    });

    test('読み上げの終了が届かなくても、猶予を過ぎたら次へ進む', () {
      final sim = Sim()
        ..run(
          140,
          reportTtsFinished: false,
          extra: {
            1: [
              tiles(1, [lm, landmark('lm_0002', -150, 18)]),
            ],
          },
        );
      expect(sim.speaks, hasLength(2));
    });
  });

  group('エリア', () {
    test('エリアに入ったら定型文を1回だけ話し、出たらエリアを返さない', () {
      final area = landmark(
        'lm_0004',
        -100,
        0,
        kind: 'area',
        radiusM: 50,
        short: 'ここは見本の公園です。',
      );
      final sim = Sim()
        ..run(
          160,
          extra: {
            1: [
              tiles(1, [area]),
            ],
          },
        );
      // 160秒後（208m 南）はエリアの外
      expect(sim.engine.currentArea, isNull);
      final entered = sim.withReason('speak:area_entered').toList();
      expect(entered, hasLength(1));
      expect(entered.single.text, 'ここは見本の公園です。');
    });

    test('エリアの中にいる間は currentArea が id・名前・説明を返す', () {
      final area = landmark('lm_0004', 0, 0, kind: 'area', radiusM: 200);
      final sim = Sim()
        ..run(
          5,
          extra: {
            1: [
              tiles(1, [area]),
            ],
          },
        );
      final ctx = sim.engine.currentArea!;
      expect(ctx.id, 'lm_0004');
      expect(ctx.name, area.name);
      expect(ctx.summary, area.scriptShort);
      expect(ctx.toJson().containsKey('name_hints'), isFalse);
    });
  });

  group('警報', () {
    AlertReceived alert(num sec, int level, {String id = 'al_1'}) =>
        AlertReceived(
          tMs: ms(sec),
          alertId: id,
          level: level,
          kind: '大雨危険警報',
          areaName: '富山市',
          text: '富山市に大雨危険警報が発表されました。',
        );

    test('レベル4以上は読み上げ中でも割り込み、止めた話はもう一度話せる扱いにする', () {
      final lm = landmark('lm_0001', -60, -18, short: 'あ' * 30);
      final sim2 = Sim()
        ..run(
          28,
          extra: {
            1: [
              tiles(1, [lm]),
            ],
            28: [alert(28, 4)],
          },
        );
      final speaks = sim2.speaks;
      expect(speaks, hasLength(2));
      final interrupt = speaks.last.$2;
      expect(interrupt.interrupt, isTrue);
      expect(interrupt.pauseMusic, isTrue);
      expect(interrupt.priority, 1);
      expect(sim2.withReason('speak:alert_interrupt'), hasLength(1));
      expect(sim2.engine.toldIds, isNot(contains('lm_0001')));
    });

    test('割り込まれた A は、警報のあとも続きを話さない（範囲にいる間は skip:interrupted）', () {
      final lm = landmark('lm_0001', -60, -18, short: 'あ' * 30);
      final sim = Sim()
        ..run(
          70,
          extra: {
            1: [
              tiles(1, [lm]),
            ],
            28: [alert(28, 4)],
          },
        );
      final texts = sim.speaks.map((e) => e.$2.text).toList();
      expect(texts, hasLength(2));
      expect(texts[1], '富山市に大雨危険警報が発表されました。');
      expect(
        sim
            .withReason('skip:interrupted')
            .where((d) => d.targetId == 'lm_0001'),
        hasLength(1),
      );
      expect(sim.engine.toldIds, isNot(contains('lm_0001')));
    });

    test('割り込まれた A は、一度離れてからまた近づいたら最初から話す', () {
      final lm = landmark('lm_0001', -60, -18, short: 'あ' * 30);
      // 南へ80秒歩いて離れ、北へ引き返す
      Pose outAndBack(int sec) => sec <= 80
          ? (north: -1.3 * sec, east: 0, speed: 1.3, course: 180)
          : (
              north: -1.3 * 80 + 1.3 * (sec - 80),
              east: 0,
              speed: 1.3,
              course: 0,
            );
      final sim = Sim()
        ..run(
          150,
          pose: outAndBack,
          extra: {
            1: [
              tiles(1, [lm]),
            ],
            28: [alert(28, 4)],
          },
        );
      final aSecs = [
        for (final (t, s) in sim.speaks)
          if (s.text.endsWith('あ' * 30)) sim.secOf(t),
      ];
      expect(aSecs, hasLength(2));
      expect(aSecs.last, greaterThan(80));
      expect(
        sim.speaks.where((s) => s.$2.text.contains('さきほどの話の続きです')),
        isEmpty,
      );
    });

    test('同じ警報を2回受けても1回だけ話す', () {
      final sim = Sim()
        ..run(
          10,
          extra: {
            2: [alert(2, 4)],
            5: [alert(5, 4)],
          },
        );
      expect(sim.speaks, hasLength(1));
    });

    test('レベル3は今の話が終わるのを待ってから、割り込まずに話す', () {
      final lm = landmark('lm_0001', -60, -18, short: 'あ' * 30);
      final sim = Sim()
        ..run(
          60,
          extra: {
            1: [
              tiles(1, [lm]),
            ],
            28: [alert(28, 3)],
          },
        );
      final speaks = sim.speaks;
      expect(speaks, hasLength(2));
      expect(speaks.last.$2.interrupt, isFalse);
      expect(speaks.last.$2.pauseMusic, isTrue);
      expect(sim.withReason('speak:alert'), hasLength(1));
      final busy = sim
          .withReason('skip:tts_busy')
          .where((d) => d.targetId == 'al_1');
      expect(busy, hasLength(1));
    });
  });

  test('判断ログの理由コードはすべて一覧にある', () {
    final sim = Sim()
      ..run(
        120,
        extra: {
          1: [
            tiles(1, [
              landmark('lm_0001', -60, -18),
              landmark('lm_0004', -100, 0, kind: 'area', radiusM: 50),
            ]),
          ],
        },
      );
    for (final d in sim.decisions) {
      expect(reasonCodes, contains(d.reason));
    }
  });

  group('横断歩道：地図だけで判定・渡っている間の延期（11/7）', () {
    ImageQuality Function(int) stripes(int from, int to) =>
        (sec) => ImageQuality(
          blur: 1,
          brightness: 0.8,
          crosswalk: sec >= from && sec <= to ? 0.9 : 0,
        );
    // 南へ歩く道の上に、北 [from]〜[to] m の間 10m ごとに横断歩道を置く（その間ずっと「手前」になる）
    List<Crossing> along(int from, int to) => [
      for (var n = from, i = 1; n >= to; n -= 10, i++)
        Crossing(
          id: 'cr_${i.toString().padLeft(4, '0')}',
          lat: latAt(n.toDouble()),
          lon: lonAt(0),
          kind: 'crossing',
        ),
    ];
    final lm = landmark('lm_0001', -60, -18);

    test('画像に縞模様が写っても、地図に横断歩道が無ければ止めない（11/7 夜に画像の判定を外した）', () {
      final sim = Sim()
        ..run(
          120,
          quality: stripes(20, 45),
          extra: {
            1: [
              tiles(1, [lm]),
            ],
          },
        );
      expect(sim.withReason('skip:crossing_ahead'), isEmpty);
      expect(sim.withReason('speak:closest_approach'), hasLength(1));
    });

    test('地図の横断歩道が15m 以内の前にあれば、画像に写っていなくても止める', () {
      final crossing = Crossing(
        id: 'cr_0001',
        lat: latAt(-40),
        lon: lonAt(0),
        kind: 'traffic_signals',
      );
      final sim = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [lm], crossings: [crossing]),
            ],
          },
        );
      expect(sim.withReason('skip:crossing_ahead'), isNotEmpty);
    });

    test('渡っている間に通り過ぎたランドマークは、捨てずに渡り終えてから話す（方向の一言なし）', () {
      final sim = Sim()
        ..run(
          150,
          extra: {
            1: [
              tiles(1, [lm], crossings: along(-40, -110)),
            ],
          },
        );
      final after = sim.withReason('speak:after_crossing').toList();
      expect(after, hasLength(1));
      expect(sim.secOf(after.single.tMs), greaterThanOrEqualTo(80));
      expect(after.single.text, lm.scriptShort);
      expect(sim.withReason('skip:expired'), isEmpty);
      expect(sim.speaks, hasLength(1)); // 2回は話さない
    });

    test('渡り終えたときに遠く離れすぎていたら、延期した話は捨てる', () {
      final sim = Sim()
        ..run(
          200,
          extra: {
            1: [
              tiles(1, [lm], crossings: along(-40, -210)),
            ],
          },
        );
      expect(sim.withReason('speak:after_crossing'), isEmpty);
      expect(sim.withReason('skip:expired'), hasLength(1));
      expect(sim.speaks, isEmpty);
    });

    test('今流れている話は、横断歩道に来ても止めない', () {
      final sim = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [lm], crossings: along(-55, -80)),
            ],
          },
        );
      expect(sim.speaks.every((s) => !s.$2.interrupt), isTrue);
    });
  });

  group('開発者モード：通ったランドマークをもう一度話す（11/7）', () {
    // 南へ80m 歩いて石碑を通り過ぎ、北へ戻って、また南へ通る
    Pose there(int sec) {
      if (sec <= 80)
        return (north: -1.3 * sec, east: 0, speed: 1.3, course: 180);
      if (sec <= 160) {
        return (north: -104 + 1.3 * (sec - 80), east: 0, speed: 1.3, course: 0);
      }
      return (north: -1.3 * (sec - 160), east: 0, speed: 1.3, course: 180);
    }

    final lm = landmark('lm_0001', -60, -18);
    int told(EngineConfig config) =>
        (Sim(config)..run(
              240,
              pose: there,
              extra: {
                1: [
                  tiles(1, [lm]),
                ],
              },
            ))
            .speaks
            .where((s) => s.$2.text.contains(lm.scriptShort))
            .length;

    test('既定では2回目に近づいても話さない', () {
      expect(told(const EngineConfig()), 1);
    });

    test('retellOnRevisit なら、離れてからもう一度近づくと話す', () {
      expect(
        told(const EngineConfig(retellOnRevisit: true)),
        greaterThanOrEqualTo(2),
      );
    });
  });

  group('デモ撮影のワンタップ（11/7）', () {
    DemoLandmarkRequested demo(num sec, {String? id}) =>
        DemoLandmarkRequested(tMs: ms(sec), landmarkId: id);
    AlertReceived alert(num sec, String id) => AlertReceived(
      tMs: ms(sec),
      alertId: id,
      level: 4,
      kind: '大雨危険警報（デモ）',
      areaName: '富山市',
      text: 'これはデモの警報です。実際の警報ではありません。',
    );

    test('遠くのランドマークでも、頼まれたら A の案内として方向つきで話す', () {
      final lm = landmark('lm_0001', -400, 300);
      final sim = Sim()
        ..run(
          30,
          extra: {
            1: [
              tiles(1, [lm]),
            ],
            5: [demo(5)],
          },
        );
      final d = sim.withReason('speak:demo_landmark').single;
      expect(d.targetId, 'lm_0001');
      expect(sim.secOf(d.tMs), 5);
      final speak = sim.speaks.single.$2;
      expect(speak.priority, 5);
      expect(speak.interrupt, isFalse);
      expect(speak.text, contains('の方に見本lm_0001があります。'));
      expect(speak.text, endsWith(lm.scriptShort));
      expect(isDemoDecision(d), isTrue);
      expect(sim.engine.toldIds, contains('lm_0001'));
    });

    test('いちばん近いランドマークを選び、エリアは選ばない', () {
      final sim = Sim()
        ..run(
          20,
          extra: {
            1: [
              tiles(1, [
                landmark('lm_0001', -400, 300),
                landmark('lm_0002', 200, 100),
                landmark('lm_0003', 0, 10, kind: 'area', radiusM: 5),
              ]),
            ],
            5: [demo(5)],
          },
        );
      expect(sim.withReason('speak:demo_landmark').single.targetId, 'lm_0002');
    });

    test('話した履歴にあるランドマークも、頼まれればもう一度話す', () {
      final sim = Sim()
        ..run(
          90,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', -60, -18)]),
            ],
            70: [demo(70, id: 'lm_0001')],
          },
        );
      expect(sim.withReason('speak:closest_approach'), hasLength(1));
      expect(sim.withReason('speak:demo_landmark'), hasLength(1));
      expect(sim.speaks, hasLength(2));
    });

    test('読み上げ中なら待ち（期限切れにしない）、話し終えてから話す', () {
      final sim = Sim()
        ..run(
          40,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', -400, 300)]),
            ],
            5: [demo(5)],
          },
          ttsSpeaking: (sec) => sec < 15,
        );
      expect(sim.withReason('skip:tts_busy').first.targetId, 'lm_0001');
      final d = sim.withReason('speak:demo_landmark').single;
      expect(sim.secOf(d.tMs), greaterThanOrEqualTo(15));
      expect(sim.withReason('skip:expired'), isEmpty);
    });

    test('ランドマークを持っていなければ見送る', () {
      final sim = Sim()..run(10, extra: {5: [demo(5)]});
      expect(sim.withReason('skip:demo_no_landmark'), hasLength(1));
      expect(sim.speaks, isEmpty);
    });

    test('デモの警報は本物と同じく案内に割り込み、判断はデモと分かる', () {
      final sim = Sim()
        ..run(
          12,
          extra: {
            1: [
              tiles(1, [landmark('lm_0001', -400, 300, short: 'あ' * 60)]),
            ],
            5: [demo(5)],
            8: [alert(8, '${demoAlertIdPrefix}alert_1')],
          },
        );
      final d = sim.withReason('speak:alert_interrupt').single;
      expect(sim.speaks.last.$2.interrupt, isTrue);
      expect(isDemoDecision(d), isTrue);
      final real = Sim()
        ..run(10, extra: {5: [alert(5, 'al_1')]});
      expect(
        isDemoDecision(real.withReason('speak:alert_interrupt').single),
        isFalse,
      );
    });

    test('歩行ログの形に書いて読み直せる', () {
      for (final e in [demo(1), demo(2, id: 'lm_0001')]) {
        final json = eventToJson(e);
        expect(json['type'], 'demo_landmark');
        final back = eventFromJson(json) as DemoLandmarkRequested;
        expect(back.landmarkId, e.landmarkId);
      }
      expect(eventToJson(demo(1))['data'], isEmpty);
    });
  });

  group('ランドマークの形（11/7）', () {
    // 南へ歩く（東 0m の線上）。形は (北, 東) の m で書く
    List<({double lat, double lon})> pts(List<(double, double)> ne) => [
      for (final (n, e) in ne) (lat: latAt(n), lon: lonAt(e)),
    ];
    Landmark shaped(
      String id,
      String kind,
      double north,
      double east, {
      required double radiusM,
      required String type,
      required List<(double, double)> points,
      required double marginM,
    }) => Landmark(
      id: id,
      name: '見本$id',
      nameKana: 'みほん',
      lat: latAt(north),
      lon: lonAt(east),
      kind: kind,
      radiusM: radiusM,
      shape: LandmarkShape(type: type, parts: [pts(points)], marginM: marginM),
      scriptShort: '見本の原稿です。',
      scriptLong: '見本の原稿の長い版です。',
      visualHint: '',
    );
    Landmark park(double west) => shaped(
      'lm_0001',
      'area',
      -175,
      150,
      radiusM: 200,
      type: 'polygon',
      points: [(-50, west), (-50, 300), (-300, 300), (-300, west)],
      marginM: 0,
    );

    test('公園の輪郭の外は、前の円の中でもエリアに入らない', () {
      final sim = Sim()
        ..run(
          250,
          extra: {
            1: [
              tiles(1, [park(5)]),
            ],
          },
        );
      expect(sim.withReason('speak:area_entered'), isEmpty);
      expect(sim.engine.currentArea, isNull);
    });

    test('公園の輪郭に入ったらエリアに入る', () {
      final sim = Sim()
        ..run(
          120,
          extra: {
            1: [
              tiles(1, [park(-5)]),
            ],
          },
        );
      final d = sim.withReason('speak:area_entered').single;
      expect(sim.secOf(d.tMs), inInclusiveRange(38, 45)); // 北 -50m に着くのは約38秒後
      expect(sim.engine.currentArea?.id, 'lm_0001');
    });

    test('建物は輪郭から幅の内側を通れば話し、外なら話さない', () {
      Landmark building(double margin) => shaped(
        'lm_0002',
        'building',
        -120,
        60,
        radiusM: 100,
        type: 'polygon',
        points: [(-100, 40), (-100, 80), (-140, 80), (-140, 40)],
        marginM: margin,
      );
      final far = Sim()
        ..run(
          200,
          extra: {
            1: [
              tiles(1, [building(25)]),
            ],
          },
        );
      expect(far.speaks, isEmpty); // 前の円（100m）なら話していた
      final near = Sim()
        ..run(
          200,
          extra: {
            1: [
              tiles(1, [building(45)]),
            ],
          },
        );
      expect(near.withReason('speak:closest_approach').single.targetId, 'lm_0002');
    });

    test('通りは線から幅の内側を歩けば話す', () {
      Landmark street(double margin) => shaped(
        'lm_0003',
        'street',
        -200,
        30,
        radiusM: 60,
        type: 'line',
        points: [(-100, 30), (-300, 30)],
        marginM: margin,
      );
      final out = Sim()
        ..run(
          200,
          extra: {
            1: [
              tiles(1, [street(25)]),
            ],
          },
        );
      expect(out.speaks, isEmpty);
      final inside = Sim()
        ..run(
          200,
          extra: {
            1: [
              tiles(1, [street(35)]),
            ],
          },
        );
      expect(inside.withReason('speak:closest_approach'), hasLength(1));
    });

    test('形は JSON に書いて読み直せる（タイルの形）', () {
      final lm = park(5);
      final back = Landmark.fromJson(lm.toJson());
      expect(back.shape!.type, 'polygon');
      expect(back.shape!.parts.single, hasLength(4));
      expect(back.shape!.marginM, 0);
      expect(() => LandmarkShape.fromJson({'type': 'circle', 'parts': <Object?>[], 'margin_m': 0}), throwsFormatException);
    });

    test('線分までの距離と多角形の内外', () {
      expect(segmentDistance(const Vec2(0, 5), const Vec2(-10, 0), const Vec2(10, 0)), closeTo(5, 1e-9));
      expect(segmentDistance(const Vec2(13, 4), const Vec2(-10, 0), const Vec2(10, 0)), closeTo(5, 1e-9));
      const sq = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)];
      expect(insidePolygon(sq, const Vec2(5, 5)), isTrue);
      expect(insidePolygon(sq, const Vec2(15, 5)), isFalse);
    });
  });
}

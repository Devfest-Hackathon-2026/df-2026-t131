import 'dart:math' as math;

import 'package:engine/engine.dart';
import 'package:engine/src/geo.dart';
import 'package:engine/src/kalman.dart';
import 'package:test/test.dart';

// ---- 見本の場所（富山駅南口付近）を原点にした平面で場面を作る ----
const lat0 = 36.7008, lon0 = 137.2135;
const t0 = 1793836800000;
final mPerDegLat = earthRadiusM * math.pi / 180;
final mPerDegLon = mPerDegLat * math.cos(lat0 * math.pi / 180);
double latAt(double northM) => lat0 + northM / mPerDegLat;
double lonAt(double eastM) => lon0 + eastM / mPerDegLon;
int ms(num sec) => t0 + (sec * 1000).round();

Landmark landmark(
  String id,
  double north,
  double east, {
  String kind = 'monument',
  double? radiusM,
  String short = '右手の石碑は、見本のための架空の石碑です。',
  String? long,
}) => Landmark(
  id: id,
  name: '見本$id',
  nameKana: 'みほん',
  lat: latAt(north),
  lon: lonAt(east),
  kind: kind,
  radiusM: radiusM,
  scriptShort: short,
  scriptLong: long ?? '$short長い版の続きです。',
  visualHint: '',
);

TilesLoaded tiles(
  num sec,
  List<Landmark> landmarks, {
  List<Crossing> crossings = const [],
}) => TilesLoaded(
  tMs: ms(sec),
  tile: TileResponse(
    tile: tileAt(lat0, lon0),
    landmarks: landmarks,
    stops: const [],
    crossings: crossings,
    events: const [],
  ),
);

/// 1秒ごとの位置。既定は南へ 1.3 m/s。
typedef Pose = ({double north, double east, double speed, double course});
Pose southWalk(int sec) =>
    (north: -1.3 * sec, east: 0, speed: 1.3, course: 180);

/// mobile の代わり：センサーを1秒ごとに送り、Speak を受けたら読み上げ時間後に TtsFinished を返す。
final class Sim {
  final Engine engine;
  final List<(int, Command)> commands = [];
  ({String id, int endMs})? _current;
  Sim([EngineConfig config = const EngineConfig()])
    : engine = Engine(config: config);

  void run(
    int seconds, {
    Pose Function(int sec) pose = southWalk,
    Activity Function(int sec)? activity,
    AudioOut audio = AudioOut.earphone,
    Map<int, List<EngineEvent>> extra = const {},
    bool reportTtsFinished = true,
  }) {
    for (var sec = 0; sec <= seconds; sec++) {
      final t = ms(sec);
      final cur = _current;
      if (cur != null && t >= cur.endMs) {
        _current = null;
        if (reportTtsFinished) {
          _feed(TtsFinished(tMs: t, utteranceId: cur.id), reportTtsFinished);
        }
      }
      final p = pose(sec);
      _feed(
        SensorFrame(
          tMs: t,
          lat: latAt(p.north),
          lon: lonAt(p.east),
          accM: 5,
          speedMps: p.speed,
          courseDeg: p.speed < 0.5 ? null : p.course,
          gazeAzDeg: p.course,
          gazePitchDeg: 0,
          activity: activity?.call(sec) ?? Activity.walking,
          audioOut: audio,
          inCall: false,
          ttsSpeaking: _current != null,
          imageQuality: null,
        ),
        reportTtsFinished,
      );
      for (final e in extra[sec] ?? const <EngineEvent>[]) {
        _feed(e, reportTtsFinished);
      }
    }
  }

  void _feed(EngineEvent e, bool reportTtsFinished) {
    for (final c in engine.handle(e)) {
      commands.add((e.tMs, c));
      if (c is Speak) {
        final cur = _current;
        if (c.interrupt && cur != null && reportTtsFinished) {
          // 割り込みで止めた話にも TtsFinished を返す（mobile の想定どおり）
          _feed(TtsFinished(tMs: e.tMs, utteranceId: cur.id), true);
        }
        final dur = (c.text.runes.length / 6 * 1000).ceil();
        _current = (id: c.utteranceId, endMs: e.tMs + dur);
      }
    }
  }

  List<Decision> get decisions => [
    for (final (_, c) in commands)
      if (c is LogDecision) c.decision,
  ];
  List<(int, Speak)> get speaks => [
    for (final (t, c) in commands)
      if (c is Speak) (t, c),
  ];
  Iterable<Decision> withReason(String reason) =>
      decisions.where((d) => d.reason == reason);
  double secOf(int tMs) => (tMs - t0) / 1000;
}

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

    test('話し終える前に通り過ぎるなら話さず、理由を1回だけ記録する', () {
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
      expect(sim.speaks, isEmpty);
      expect(sim.withReason('skip:pass_before_end'), hasLength(1));
    });

    test('立ち止まってジオフェンスの中にいるときは長い版を話す', () {
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
      expect(sim.withReason('speak:long_version_still'), hasLength(1));
      expect(sim.speaks.single.$2.text, endsWith('長い版の続きです。'));
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

    test('続けて近づいても、話題の間隔を空けて次を話す', () {
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
      expect(speaks[1].$1 - firstEnd, greaterThanOrEqualTo(20000 - 1000));
      expect(sim.withReason('skip:topic_interval'), isNotEmpty);
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
}

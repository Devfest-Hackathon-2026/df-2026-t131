const currentSchemaVersion = '0.3';

/// tasks/README.md 2.5の初期値。時間の単位はミリ秒。
final class EngineConfig {
  final int sensorIntervalMs,
      prefetchHorizonMs,
      proximityHorizonMs,
      topicIntervalMs;
  final int visualIntervalMs, candidateLimit, visualFreshnessMs;
  final double defaultRadiusM, samePlaceDistanceM, samePlaceAzimuthDeg;

  /// minConfidence（0.6）は、B がランドマーク全体を A の原稿で話していたときのしきい値。
  /// 11/6 夜から B は全体を話さないので、今は使っていない（部分・候補外は unlistedMinConfidence）。
  final double candidateDistanceM, candidateHalfAngleDeg, minConfidence;
  final double fastWalkingMps, crossingDistanceM, minBlur, minBrightness;

  /// 1回の歩行で B を計測する回数の上限。null なら上限なし（既定）。
  /// 11/6：1回 約0.4円で費用は小さく、撮りすぎは計測間隔と「同じ場所」で防げ、
  /// 呼びすぎはサーバーの回数上限が止めるため、既定では外した。必要なら値を入れて使う。
  final int? maxSearchesPerWalk;

  // ---- ここから下は tasks/README.md 2.5 にない、engine の内部の仮の値（実機で調整する）----

  /// これより遅いと止まっているとみなす（m/s）。最接近の計算と先読みで使う。
  final double minMovingMps;

  /// 読み上げの速さの見積もり（1秒あたりの文字数）。話し終える前に通り過ぎないかの判定に使う。
  final double ttsCharsPerSecond;

  /// 見積もった読み上げ時間を過ぎても `TtsFinished` が来ないとき、さらに待つ時間。
  /// 過ぎたら話し終えたとみなす（読み上げ終了の取りこぼしで止まり続けないため）。
  final int ttsFinishGraceMs;

  /// 要求したタイルが届かないとき、もう一度要求するまでの時間。
  final int tileRetryMs;

  /// 先読みで予測軌跡を区切る間隔と、各点の周りで取るタイルの余白（m）。
  final int prefetchStepMs;
  final double prefetchMarginM;

  /// カルマンフィルタの加速度の標準偏差（m/s²）と、速度の観測の標準偏差（m/s）。
  final double kalmanAccelNoise, kalmanVelocityNoise;

  /// センサーがこれより長く途切れたら、位置の推定を作り直す。
  final int kalmanResetGapMs;

  /// このレベル以上の警報は今の読み上げに割り込む（CLAUDE.md 4章）。
  final int alertInterruptLevel;

  /// 方向の言い方の境目（進行方向からの角度の絶対値、度）。
  /// これ以下なら正面、前方、横（手）、後方、それより大きければ後ろ。
  final double directionFrontDeg,
      directionDiagonalDeg,
      directionSideDeg,
      directionRearDeg;

  // ---- B の発火タイミング（伝言「B_発火タイミングの論点」で11/5に決めた。実機で調整する）----

  /// B の答えが届くまでの見込み（撮影→送信→Gemini 2〜3秒→受信）。
  /// 横断歩道の判定（地図＋画像。11/7）。地図の横断歩道がこれ以内の前にあれば、画像に関係なく手前とみなす
  /// （GPS がずれていても近いので安全側）。
  final double crossingNearM;

  /// 画像の縞模様（ImageQuality.crosswalk）がこれ以上なら「横断歩道が写っている」とみなす。
  final double crossingVisualMinScore;

  /// 縞模様が写ったあと、これだけの間は手前とみなし続ける（地図に無い・位置がずれた横断歩道も拾う）。
  final int crossingVisualHoldMs;

  /// 地図の横断歩道が [crossingNearM]〜[crossingDistanceM] にあっても、画質が足りる画像で
  /// 縞模様が写らない状態がこれだけ続いたら、手前とはみなさない（GPS のずれで止まりすぎるのを防ぐ）。
  final int crossingVisualClearMs;

  /// 横断歩道で延期した A の話は、そのランドマークから（半径＋この距離）より離れたら話さずに捨てる
  /// （渡り終えたあと、もう見えないものを話さないため）。
  final double crossingDeferMarginM;

  /// 答えが届くころに話題の間隔が終わっているときだけ撮る（前の話の終わり＋話題の間隔−この値より前は撮らない）。
  final int visualExpectedLatencyMs;

  /// これ以内に A の話が始まりそうなら B を撮らない（A を優先し、B の答えが押し出されて捨てられるのを防ぐ）。
  final int visualYieldToNarrativeMs;

  /// 立ち止まってこれだけ経ったら、計測間隔を待たずに前倒しで撮る（search:stopped_early）。
  final int stillEarlyMs;

  /// 前倒しでも、前に撮ってからこれだけは空ける。
  /// 11/6 夜に30秒から10秒に下げた（計測の間隔を20秒にしたので、30秒では前倒しにならないため）。
  final int stillEarlyMinIntervalMs;

  /// 候補外の対象（地図にないもの）の答えを話す自信の下限。
  /// 根拠が地図にない分、候補と一致したとき（minConfidence）より高くする（11/6 に決定）。
  final double unlistedMinConfidence;

  /// 固有名でない対象（例：古い木造の蔵）は、前に話したときに撮った場所からこの距離以内で
  /// 同じ名前のときだけ二度目とみなす。離れた場所の別の蔵はまた話せる（11/6 に決定）。
  final double genericObjectDedupM;

  // ---- 話の続け方と中断（11/6 夕、メンバー3。実機で調整する）----

  /// A → A、警報 → A の間に空ける時間。話題の間隔（topicIntervalMs）は
  /// 「B が続けて話し続けないように」（CLAUDE.md 4章）のためなので、B の前後だけに使う。
  /// A のあとに20秒空けると、続くランドマークの範囲を歩き過ぎて話せなくなるため。
  final int narrativeChainGapMs;

  /// 止まってからこれだけ経ったら長い版を話す。出発直後の速さ0で長い版を選ばないため。
  final int longVersionStillMs;

  /// 検索で止めたランドマークは、半径＋この距離より離れてから、また近づいたときに話す。
  final double revisitMarginM;

  /// 開発者モードの検証用（11/7）：話したランドマーク・エリアから（半径＋[revisitMarginM]）より離れたら、
  /// 話した履歴から外して、もう一度近づいたら話す。既定は false（同じ話は2回しない決まり）。
  final bool retellOnRevisit;

  /// 今の町丁目：持っているタイルの町丁目のうち、いちばん近い代表点。これより遠ければ「わからない」（m）。
  /// cloud/data/scripts/town_lookup.py の MAX_TOWN_DISTANCE_M と同じ値にする。
  final double townMaxDistanceM;

  /// カメラで調べない区域を「出た」とみなすのは、半径にこれを足した距離より遠くなったとき（m）。
  /// 境目でぶれて入った・出たを繰り返さないため。cloud/data/scripts/build_sqlite.py の ZONE_EXIT_MARGIN_M と同じ値。
  final double zoneExitMarginM;

  /// 同じ区域を出てからこれより早くまた入ったら、入った・出たの知らせを話さない（撮らないことは同じ）。
  final int zoneAnnounceCooldownMs;

  const EngineConfig({
    this.sensorIntervalMs = 1000,
    this.defaultRadiusM = 25,
    this.prefetchHorizonMs = 150000,
    this.proximityHorizonMs = 20000,
    this.topicIntervalMs = 20000,
    this.visualIntervalMs = 20000,
    this.samePlaceDistanceM = 20,
    this.samePlaceAzimuthDeg = 30,
    this.candidateDistanceM = 150,
    this.candidateHalfAngleDeg = 30,
    this.candidateLimit = 10,
    this.visualFreshnessMs = 15000,
    this.minConfidence = 0.6,
    this.maxSearchesPerWalk,
    this.fastWalkingMps = 1.8,
    this.crossingDistanceM = 15,
    this.crossingNearM = 8,
    this.crossingVisualMinScore = 0.5,
    this.crossingVisualHoldMs = 3000,
    this.crossingVisualClearMs = 2000,
    this.crossingDeferMarginM = 100,
    this.minBlur = 0.5,
    this.minBrightness = 0.2,
    this.minMovingMps = 0.3,
    this.ttsCharsPerSecond = 6,
    this.ttsFinishGraceMs = 30000,
    this.tileRetryMs = 30000,
    this.prefetchStepMs = 10000,
    this.prefetchMarginM = 150,
    this.kalmanAccelNoise = 0.5,
    this.kalmanVelocityNoise = 0.5,
    this.kalmanResetGapMs = 30000,
    this.alertInterruptLevel = 4,
    this.directionFrontDeg = 20,
    this.directionDiagonalDeg = 60,
    this.directionSideDeg = 120,
    this.directionRearDeg = 160,
    this.visualExpectedLatencyMs = 5000,
    this.visualYieldToNarrativeMs = 15000,
    this.stillEarlyMs = 5000,
    this.stillEarlyMinIntervalMs = 10000,
    this.unlistedMinConfidence = 0.7,
    this.genericObjectDedupM = 100,
    this.narrativeChainGapMs = 3000,
    this.longVersionStillMs = 5000,
    this.revisitMarginM = 10,
    this.retellOnRevisit = false,
    this.townMaxDistanceM = 800,
    this.zoneExitMarginM = 15,
    this.zoneAnnounceCooldownMs = 60000,
  });
}

/// schema/reason_codes.jsonと照合する。追加・変更はmember1が決定する。
/// B の応答の part（schema/api/visual_search.response.schema.json）と、読み上げ・画面での呼び方。
/// 値（英語）は schema と同じ。変えない。
const visualPartLabels = <String, String>{
  'whole': '全体',
  'window': '窓',
  'entrance': '入口',
  'roof': '屋根',
  'wall': '壁',
  'pillar': '柱',
  'sign': '看板',
  'statue': '像',
  'railing': '欄干',
  'planting': '植え込み',
  'waterside': '水辺',
  'other': 'その他',
};
final visualParts = visualPartLabels.keys.toList(growable: false);

const reasonCodes = <String>{
  'speak:closest_approach',
  'speak:after_crossing',
  'speak:area_entered',
  'speak:no_camera_zone_entered',
  'speak:no_camera_zone_exited',
  'speak:long_version_still',
  'speak:alert_interrupt',
  'speak:alert',
  'speak:transit_next',
  'speak:event_nearby',
  'skip:already_told',
  'skip:crossing_ahead',
  'skip:in_vehicle',
  'skip:fast_walking',
  'skip:no_audio_output',
  'skip:in_call',
  'skip:tts_busy',
  'skip:topic_interval',
  'skip:pass_before_end',
  'skip:expired',
  'skip:event_cancelled',
  'search:interval_elapsed',
  'search:stopped_early',
  'search:user_requested',
  'search_skip:interval_not_elapsed',
  'search_skip:same_place',
  'search_skip:gate_blocked',
  'search_skip:low_quality',
  'search_skip:limit_reached',
  'search_skip:no_camera_zone',
  'answer:matched_landmark',
  'answer:landmark_feature',
  'answer:unlisted_object',
  'answer:named_object',
  'answer:unknown',
  'answer:low_confidence',
  'answer:already_told',
  'answer:expired',
  'answer:yield_to_narrative',
  'answer:whole_left_to_narrative',
  'answer:feature_before_intro',
  'answer:in_no_camera_zone',
  'answer:error',
  'speak:search_ack',
  'skip:awaiting_search',
  'skip:interrupted',
  'fetch:prefetch_tiles',
};

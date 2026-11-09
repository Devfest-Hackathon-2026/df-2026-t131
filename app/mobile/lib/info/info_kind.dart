/// 案内する情報の種類（docs/design.md 4章の優先度表）。
///
/// 優先度・割り込み・音楽の扱いはここに集め、種類を足すときは値を1つ足すだけにする。
enum InfoKind {
  alert(1, '気象警報', '1分おきにサーバーが確かめ、FCM で届く', pauseMusic: true),
  weather(2, '気象（注意報・天気の変化）', '気象庁の発表が変わったときだけ'),
  transit(3, '路面電車（次の便・遅れ）', '電停に近づく直前'),
  event(4, '当日のイベント', '会場に近づく直前。開催を確かめられたときだけ'),
  landmark(5, 'ランドマーク案内（A）', '最も近づく直前。エリアは入ったとき'),
  visual(6, '見ている景色（B）', '約20秒ごとに画像で調べる');

  const InfoKind(
    this.priority,
    this.label,
    this.timing, {
    this.pauseMusic = false,
  });

  /// 1 がいちばん大事。
  final int priority;
  final String label;

  /// いつ話すか（設定画面に出す説明）。
  final String timing;

  /// true なら音楽を一時停止、false なら音量を下げる。
  final bool pauseMusic;
}

/// その種類が今どこまで使えるか。
enum InfoReadiness {
  /// 使える。
  ready('使える'),

  /// 骨組みだけ。データの入口（[InfoSource]）を作れば使える。
  planned('準備中');

  const InfoReadiness(this.label);
  final String label;
}

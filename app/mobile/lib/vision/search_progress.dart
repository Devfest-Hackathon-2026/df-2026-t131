/// B の検索がいまどこまで進んだか（グラス視点の画面の札に出す）。
enum SearchPhase {
  /// 「検索して」を聞き取った（撮るかは engine がこれから決める）
  heard,

  /// カメラから1枚取り出している
  capturing,

  /// 顔を探してぼかしている（端末内）
  blurring,

  /// Cloud Run に送って答えを待っている
  sending,

  /// 答えが届いた（話すかは engine が決める）
  answered,

  /// 送れなかった・撮れなかった
  failed,

  /// engine が撮らないと決めた（読み上げ中の警報・横断歩道の手前など）
  skipped,
}

class SearchProgress {
  const SearchProgress(this.phase, {this.requested = false, this.detail});

  final SearchPhase phase;

  /// 利用者が頼んだ検索か（検索ボタン・「検索して」）。false なら20秒ごとの自動の検索。
  final bool requested;

  /// 失敗の種類（`timeout`・`network`・`server`・`face_blur_failed`・`no_frame`）か、
  /// 見送った理由コード（`search_skip:…`）。
  final String? detail;

  /// まだ進んでいる途中か（終わった札はしばらくして消す）。
  bool get active =>
      phase == SearchPhase.heard ||
      phase == SearchPhase.capturing ||
      phase == SearchPhase.blurring ||
      phase == SearchPhase.sending;
}

## 0.1.0

- schema 0.2に合わせた公開型、JSON変換、共通の設定値を追加。
- 空のEngine、歩行ログの再生CLI、見本データの契約テストを追加。
- schema 0.3へ版を更新（形の変更なし）。engineが扱わない見本（電停・イベント・FCM）は往復テストの対象外にした。
- Bの送信JSONを作る `visualSearchRequestToJson` を追加。
- 歩行ログを再生した判断ログを `test/fixtures/decisions/` に書き出すツールと、その鮮度を確かめるテストを追加。

## 0.2.0

- A の判断を追加：カルマンフィルタ、先読み（`FetchTiles`）、最接近の発話判定、立ち止まったときの長い版、エリアの定型文、文脈ゲート、話題の間隔、期限切れ、話した履歴、警報（重複の除去・レベル4以上の割り込み）。
- `Engine.currentArea`・`Engine.toldIds` を追加。
- 原稿の前に方向の一言（「右手に〇〇があります。」など）を付ける。`directionWord` を公開。
- 場面ごとのテスト（`test/engine_a_test.dart`）を追加。

## 0.3.0

- B の判断を追加：計測の間隔・最初の1枚・立ち止まりの前倒し・1件ずつ・上限・文脈ゲート（話題の間隔とのぶつかり、A が近いとき）・画質・同じ場所・候補の選択・答えの採否（鮮度・自信・重複）・過去形と方向つきの読み上げ。
- 判断ログ `Decision` に schema 0.3 の任意項目 `sources` を追加（kind が answer のときだけ）。
- 画面に出す読み取り専用の値 `Engine.view`（`EngineView`・`NearbyLandmark`）を追加。
- B の定数を `EngineConfig` に追加（`visualExpectedLatencyMs`・`visualYieldToNarrativeMs`・`stillEarlyMs`・`stillEarlyMinIntervalMs`・`unlistedMinConfidence`・`genericObjectDedupM`）。
- 一致の答えは、その検索で送った候補の ID だけを受け付ける。見本の答え4種（`visual_search_response_*.json`）で判断を確かめるテストを追加。
- 場面ごとのテスト（`test/engine_b_test.dart`）を追加。場面づくりの道具を `test/support/scenario.dart` に分けた。
- 共有の仕様書（visual-search-spec.md）に合わせて直した：
  - 「調べて」の入力イベント `SearchRequested`（歩行ログの `search_request`）と理由コード `search:user_requested` を追加（schema に追加。CLAUDE.md の B の仕様で決定）。
  - B を話すと直後の A に間に合わないときは B を捨てる（`answer:yield_to_narrative`。schema に追加）。
  - 最初の1枚の基準を「タイルが初めて届いた時刻」から「位置と向きが初めて取れた時刻」に変えた。
  - `EngineView` に `currentArea`・`searchSkipReason` を追加し、`NearbyLandmark.relativeDeg` を `relativeBearingDeg` に改名（リーダーの案に合わせた）。
- B の応答の `part`（どの部分か）に対応（メンバー1の m1/visual-part）：`VisualSearchResponse.part`、`visualPartLabels`。登録したランドマークの特徴（`answer:landmark_feature`）を話す。重複は（場所, part）で見る。
- B の1回の歩行での回数の上限を既定で外した（`EngineConfig.maxSearchesPerWalk` は `int?`、既定 null＝上限なし）。値を入れれば今までどおり `search_skip:limit_reached` で止まる。`EngineView.searchesLeft` も上限なしのとき null。
- B の計測の間隔の既定を60秒から20秒に短くした（60秒では約80mに1枚で見逃しが多いため。試し歩きで調整する）。
- B はランドマーク全体を話さない（`answer:whole_left_to_narrative`）、全体の紹介（A）より先に部分やエリアの中のものを話さない（`answer:feature_before_intro`）。11/6 夜のメンバー1の決定（CLAUDE.md 6章）。理由コードを schema に追加。`answer:matched_landmark` は出さなくなり、`minConfidence`（0.6）は使わなくなった。B で話しても A で話した扱いにはしない。
- タイルの応答の町丁目（`towns`、メンバー1の m1/tile-towns）に対応：`Town`、`TileResponse.towns`（無い古いタイルは空として読み、書き出しでも足さない）。
- 立ち止まりの前倒しの「前に撮ってから」を30秒から10秒に下げた（間隔20秒より長く、前倒しにならなかったため）。
- 今の町丁目 `Engine.currentTown`・`EngineView.currentTown` を追加：持っているタイルの町丁目のうち、いちばん近い代表点（距離が同じなら ID の小さい方）。`townMaxDistanceM`（800m）より遠ければ null。決め方は cloud/data/scripts/town_lookup.py と同じ。
- カメラで調べない区域（メンバー1の決定・11/7）：`Zone`・`TileResponse.zones`（無い古いタイルも読める）。区域の中では B を撮らず、「調べて」は決まった文で断り、入る前に撮った答えは捨てる。入った・出たを決まった文で知らせる。`EngineView.noCameraZone`、定数 `zoneExitMarginM`（15m）・`zoneAnnounceCooldownMs`（60秒）、理由コード4つを追加。

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

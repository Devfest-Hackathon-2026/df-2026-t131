## 0.1.0

- schema 0.2に合わせた公開型、JSON変換、共通の設定値を追加。
- 空のEngine、歩行ログの再生CLI、見本データの契約テストを追加。
- schema 0.3へ版を更新（形の変更なし）。engineが扱わない見本（電停・イベント・FCM）は往復テストの対象外にした。
- Bの送信JSONを作る `visualSearchRequestToJson` を追加。
- 歩行ログを再生した判断ログを `test/fixtures/decisions/` に書き出すツールと、その鮮度を確かめるテストを追加。

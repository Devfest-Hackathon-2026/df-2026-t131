# app/mobile — Android アプリ（Flutter）

持ち主：メンバー3。センサーを集めて判断エンジン（`app/engine`）に渡し、返ってきた指示（読み上げ・地図タイル・撮影と検索）を実行する。

## Firebase（FCM の警報の受信）

- **`google-services.json` はメンバー1から受け取って `android/app/` に置く。コミットしない**（`.gitignore` 済み。API キーを含むため）。
- 無くてもビルドでき、アプリは警報を受けずに動く（Gradle は、ファイルがあるときだけ Firebase の設定を読む）。
- 起動時に警報のトピック `alert_1620100`（富山市の区域コード7桁。移行の間は前の `alert_16201` も）を購読する。同じ `alert_id` は2つのトピックから届いても1回だけ話し、聞いた警報は起動し直しても覚えている（48時間）。
- FCM の取りこぼしの保険に、公開の `alerts/current/1620100.json` を起動時・計測開始時・計測中15分ごとに取りに行く。開発者モードでは模擬の一覧 `mock_1620100.json` も取るが、書き換えから10分より前のものは読まない。中身の形は `schema/README.md`「FCM の警報の送り方」と `schema/fcm/alert.data.schema.json`。

## 開発者モード

設定画面の「バージョン」を7回押すと出る。フェイク GPS（デモルート・歩行ログ・GPX などの検証用データ）を使える。
警報はサーバーから届いたものだけを読み、文もサーバー（cloud/alert-job）がテンプレートで作った全文をそのまま読む（アプリでは文を作らない）。デモの模擬の警報も、サーバーの `/mock-alert` から送る。
検証用データは `adb push 〇〇.gpx /sdcard/Android/data/jp.dfhack26.mobile/files/test_tracks/` で置く。自宅付近のデータはコミットしない。

## 歩行ログを人が読める形にする

```sh
cd app/mobile
dart run tool/walk_report.dart <歩行ログ.jsonl> <出力.md>
```

歩行ログを engine にもう一度流し、話したこと・黙った理由・判断の数を表にする（端末で動いた判断と同じになる）。緯度経度は出さない。
端末の歩行ログは `adb pull /sdcard/Android/data/jp.dfhack26.mobile/files/walks/` で取り出せる（自宅付近のログは人に渡さない）。

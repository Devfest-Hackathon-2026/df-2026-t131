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

## スマホだけで動かす（Cloud Run の API につなぐ）

PC につながなくても動くリリース版を作って入れる。API（A のタイル・B の画像検索）は Cloud Run、
警報は FCM と公開の Cloud Storage、読み上げ・顔ぼかしは端末の中で動く。

1. `env/real.example.json` を `env/real.json` に写し、`APP_TOKEN` を書く（メンバー1から受け取る。**`real.json` はコミットしない**。`.gitignore` 済み）
2. `app/mobile` で `pwsh tool/build_release.ps1 -Install`（端末をつないだ状態。APK だけなら `-Install` なし）
3. 設定画面の「API」が「本番（Cloud Run）」、サーバーの確認が通っていることを見る

APK は `build/app/outputs/flutter-apk/app-release.apk`。トークンが中に入るので、人に渡さない。

## B の画像検索で送るもの（11/7 更新）

`POST /v1/visual-search` に送るのは次だけ（正確な座標・音声は送らない）。

| 項目 | 中身 |
| :---- | :---- |
| `image_jpeg_base64` | 長辺640px以下、顔をぼかした画像1枚 |
| `tile`・`gaze_az_deg` | 地図タイル番号、10°単位の方位 |
| `candidate_ids` | 視線の先のランドマークの ID |
| `area` | エリアの中ならエリアの名前と説明 |
| `context.town` | おおまかな住所（町丁目名。端末が先読みした代表点から選ぶ） |
| `context.near_landmark` | ランドマークの範囲の中で撮ったとき、その ID と名前（「〇〇付近」） |
| `context.captured_at` | 撮影の日時（日本時間・分まで。昼夜・季節の見え方の手がかり） |
| `context.trigger` | きっかけ：`auto`（20秒ごと）・`stopped`（立ち止まり）・`button`（検索ボタン）・`voice`（「調べて」） |

`context` を知らない古い API が 400 を返したときは、`context` を外して一度だけ送り直す。

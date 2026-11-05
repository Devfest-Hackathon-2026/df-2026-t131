# app/mobile — Android アプリ（Flutter）

持ち主：メンバー3。センサーを集めて判断エンジン（`app/engine`）に渡し、返ってきた指示（読み上げ・地図タイル・撮影と検索）を実行する。

## Firebase（FCM の警報の受信）

- **`google-services.json` はメンバー1から受け取って `android/app/` に置く。コミットしない**（`.gitignore` 済み。API キーを含むため）。
- 無くてもビルドでき、アプリは警報を受けずに動く（Gradle は、ファイルがあるときだけ Firebase の設定を読む）。
- 起動時に警報のトピック `alert_16201`（富山市）を購読する。中身の形は `schema/README.md`「FCM の警報の送り方」と `schema/fcm/alert.data.schema.json`。

## 開発者モード

設定画面の「バージョン」を7回押すと出る。フェイク GPS（デモルート・歩行ログ・GPX などの検証用データ）と、模擬の警報を流せる。
検証用データは `adb push 〇〇.gpx /sdcard/Android/data/jp.dfhack26.mobile/files/test_tracks/` で置く。自宅付近のデータはコミットしない。

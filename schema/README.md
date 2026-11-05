# schema/ — 4人をつなぐ形式（契約）

持ち主：メンバー1。変更の手順は `tasks/README.md` 6章。

| ファイル | 何の形式か | 書く人 → 読む人 |
| :---- | :---- | :---- |
| `common.schema.json` | 共通の型（時刻・座標・方位・タイル・ID・出典） | — |
| `eventlog.schema.json` | 歩行ログ1行＝エンジンへの入力イベント1件 | mobile → engine・viewer |
| `decision.schema.json` | 判断ログ1行 | engine → mobile・viewer |
| `landmark.schema.json` / `landmarks_file.schema.json` | ランドマーク1件（エリア `kind: area` を含む） / `landmarks.json` 全体 | data → api |
| `stop.schema.json` / `timetable_file.schema.json` | 電停1件と当日の発車予定 / `manual/timetable.json` 全体 | data → api |
| `event.schema.json` / `events_file.schema.json` | イベント1件 / `manual/events.json` 全体 | data → api |
| `crossing.schema.json` / `crossings_file.schema.json` | 横断歩道・信号1件 / `cloud/data/osm/crossings.json` 全体（`extract_osm.py` の出力） | data scripts → api |
| `fcm/alert.data.schema.json` | FCM で送る警報の `data`（トピック・送り方も中に記載） | alert-job → mobile |
| `api/tile.response.schema.json` | `GET /v1/tiles/16/{x}/{y}` の応答 | api → mobile → engine |
| `api/visual_search.request.schema.json` | `POST /v1/visual-search` の送信 | mobile → api |
| `api/visual_search.response.schema.json` | 同じく応答 | api → mobile → engine |
| `reason_codes.json` | 理由コードの一覧 | engine → 全員 |
| `examples/` | 上のすべての見本。**各自のテストはこれを読んで通す** | 全員 |
| `validate.py` | 見本・`cloud/data/manual/`・engine の歩行ログが形式に合うか検証（CI でも実行） | 全員 |

## 見本データについて

* 現在の版は **0.3**
  * 0.2 → 0.3：電停・イベント・横断歩道の形を `stop`・`event`・`crossing` の schema に切り出し（タイル応答の形は変わらない）、`manual/timetable.json`・`manual/events.json`・`osm/crossings.json` と FCM の警報の形を追加、`validate.py` に ID の重複とデモ範囲の確認を追加
  * 0.1 → 0.2：エリア、B の送信に `area`、応答に `named`・`sources`、理由コード2つを追加
* `examples/` の地名・原稿は**実在しない仮のもの**。位置は富山駅南口付近（z16 タイル `16/57746/25576`）
* `walk_short.jsonl` は南へ 1.3 m/s で60秒歩くログ。1秒後にタイル到着、25〜33秒に読み上げ、40秒目に B の計測、42秒目に B の結果（候補外）
* `decisions_short.jsonl` は、エンジンが出す判断の**形の見本**。中身（時刻・どれを話すか）が正解という意味ではない
* `lm_0004` はエリア（`kind: area`、半径200m）の見本。`visual_search_request.json` はこのエリアの中から送った想定、`visual_search_response_named.json` はエリア内の名前付きの対象を特定した応答の見本（出典つき）
* `lm_0003` は `status: draft` なので、タイル応答には入っていない（`reviewed` だけが返る決まりの見本）
* **`tile_response.json` は形の見本で、中身は地理的に1つのタイルに収まっていない**（電停・イベントは `16/57746/25577`、公園は `16/57747/25577` にある）。本物の API は、点のもの（ランドマーク・電停・横断歩道・イベント）を位置が入るタイルだけに、エリアを範囲が重なるタイルすべてに入れて返す。engine はタイルをまたいで同じ ID が来たら1つにまとめる
* `timetable_sample.json`・`events_sample.json`・`crossings_sample.json` は `manual/timetable.json`・`manual/events.json`・`osm/crossings.json` の見本（中身はタイル応答の見本と同じ）
* `fcm_alert_data.json` は FCM の警報の見本（架空）

## validate.py が確かめること

* 見本・`cloud/data/manual/`（`landmarks.json`・`timetable.json`・`events.json`）・`cloud/data/osm/crossings.json` が schema に合うか
* engine のテストの fixtures：`app/engine/test/fixtures/walks/*.jsonl`（実機の歩行ログ）と `app/engine/test/fixtures/decisions/*.jsonl`（engine が再生して書き出した判断ログ）
* `manual/` と見本の ID の重複
* ランドマーク・電停・イベント・横断歩道の位置がデモ範囲（いまは富山市を囲む四角）の中にあるか。緯度と経度が逆なら教えてくれる
* 判断ログの理由コードが `reason_codes.json` にあるか
* FCM の警報の見本が、mobile が歩行ログの `alert` に直した形でも通るか

## FCM の警報の送り方

* トピック：`alert_<市町村コード5桁>`（富山市は `alert_16201`）。mobile は起動時にデモ地域のトピックを購読する
* data だけのメッセージ（notification は付けない。読み上げはアプリが行うため）、Android の優先度は high
* data の値はすべて文字列（FCM の決まり）。mobile は `level` を整数に直し、受信時刻を `t_ms` にして `AlertReceived` を作る
* 同じ `alert_id` を2回受けたら、mobile（または engine）は2回目を無視する

## 決まり（抜粋）

* 時刻は UTC の UNIX ミリ秒 `t_ms`。交通の発車時刻だけ現地時刻 `HH:MM`
* 方位は真北0°・時計回り。B で送る方位は10°単位の整数
* 地図タイルは z16 固定
* すべての JSON に `schema_version`。合流3（A の MVP）を通った後は項目の追加だけ

## API のエラーコード

エラーのときは HTTP の状態コードと `{"error": "<コード>"}` を返す。中身の詳細は返さない。
B が失敗したとき、mobile は `visual_error` の `error`（`eventlog.schema.json` で決まった4つの値）に置き換えてエンジンへ渡す：API がエラーを返した → `server`、mobile の8秒のタイムアウト → `timeout`、つながらない → `network`。API のコードそのものはエンジンに渡さない（判断には使わないため）。

| コード | HTTP | いつ |
| :---- | :---- | :---- |
| `unauthorized` | 401 | `X-App-Token` が無い・違う |
| `bad_request` | 400 | 送信が schema に合わない、JSON が壊れている、タイル番号が範囲外 |
| `not_found` | 404 | ルートが無い（z が16以外など） |
| `method_not_allowed` | 405 | GET と POST の取り違え |
| `image_too_large` | 413 | 画像が上限を超えた |
| `rate_limited` | 429 | B の1日の上限に達した |
| `gemini_timeout` | 504 | Gemini が時間内（6秒）に返らなかった |
| `gemini_error` | 502 | Gemini の呼び出しが失敗した |
| `internal` | 500 | それ以外のサーバーの不具合 |

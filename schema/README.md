# schema/ — 4人をつなぐ形式（契約）

持ち主：メンバー1。変更の手順は `tasks/README.md` 6章。

| ファイル | 何の形式か | 書く人 → 読む人 |
| :---- | :---- | :---- |
| `common.schema.json` | 共通の型（時刻・座標・方位・タイル・ID・出典） | — |
| `eventlog.schema.json` | 歩行ログ1行＝エンジンへの入力イベント1件 | mobile → engine・viewer |
| `decision.schema.json` | 判断ログ1行 | engine → mobile・viewer |
| `landmark.schema.json` / `landmarks_file.schema.json` | ランドマーク1件（エリア `kind: area` を含む） / `landmarks.json` 全体 | data → api |
| `api/tile.response.schema.json` | `GET /v1/tiles/16/{x}/{y}` の応答 | api → mobile → engine |
| `api/visual_search.request.schema.json` | `POST /v1/visual-search` の送信 | mobile → api |
| `api/visual_search.response.schema.json` | 同じく応答 | api → mobile → engine |
| `reason_codes.json` | 理由コードの一覧 | engine → 全員 |
| `examples/` | 上のすべての見本。**各自のテストはこれを読んで通す** | 全員 |
| `validate.py` | 見本・`cloud/data/manual/`・engine の歩行ログが形式に合うか検証（CI でも実行） | 全員 |

## 見本データについて

* 現在の版は **0.2**（0.1 から：エリア、B の送信に `area`、応答に `named`・`sources`、理由コード2つを追加）
* `examples/` の地名・原稿は**実在しない仮のもの**。位置は富山駅南口付近（z16 タイル `16/57746/25576`）
* `walk_short.jsonl` は南へ 1.3 m/s で60秒歩くログ。1秒後にタイル到着、25〜33秒に読み上げ、40秒目に B の計測、42秒目に B の結果（候補外）
* `decisions_short.jsonl` は、エンジンが出す判断の**形の見本**。中身（時刻・どれを話すか）が正解という意味ではない
* `lm_0004` はエリア（`kind: area`、半径200m）の見本。`visual_search_request.json` はこのエリアの中から送った想定、`visual_search_response_named.json` はエリア内の名前付きの対象を特定した応答の見本（出典つき）
* `lm_0003` は `status: draft` なので、タイル応答には入っていない（`reviewed` だけが返る決まりの見本）

## 決まり（抜粋）

* 時刻は UTC の UNIX ミリ秒 `t_ms`。交通の発車時刻だけ現地時刻 `HH:MM`
* 方位は真北0°・時計回り。B で送る方位は10°単位の整数
* 地図タイルは z16 固定
* すべての JSON に `schema_version`。合流3（A の MVP）を通った後は項目の追加だけ

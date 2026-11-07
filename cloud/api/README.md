# cloud/api — Cloud Run の API

持ち主：メンバー1。形式は `schema/api/`、決まりは `tasks/README.md` 2.4。

| ルート | 中身 | 認証 |
| :---- | :---- | :---- |
| `GET /health` | `{"status":"ok"}` | なし |
| `GET /v1/tiles/16/{x}/{y}` | A：タイルのランドマーク・電停・横断歩道・イベント | `X-App-Token` |
| `POST /v1/visual-search` | B：視界の検索 | `X-App-Token` |

エラーは `{"error": "<コード>"}`。コードの一覧は `schema/README.md`。

## タイル（`TILE_SOURCE`）

* `fake`（既定）：`16/57746/25576` だけ見本の中身、ほかのタイルは空の配列
* `sqlite`：`cloud/data/scripts/build_sqlite.py` が作った SQLite から返す
  * 点のもの（ランドマーク・電停・横断歩道・イベント）は位置が入るタイルだけ。エリアは範囲が重なるタイルすべて（engine は ID で重複を除く）
  * コンテナを作るときに `cloud/data/manual/` と `cloud/data/osm/` から SQLite を作る。入力が schema に合わなければビルドが止まる
  * 手元：`python cloud/data/scripts/build_sqlite.py --examples` で見本から作れる

## 視界の検索（`GEMINI_MODE`）

`fake`（既定）では `schema/examples/` の見本を返す。課金は起きない。

* 送信の中身で決まった応答を返す
  * `area` あり → エリア内の名前付きの対象（`named: true`）
  * `search_id` が `_feature` で終わり候補あり → 候補の先頭の特徴（`matched`・`part` が `whole` 以外。`visual_search_response_matched_feature.json`）
  * 候補あり → 候補の先頭に一致（`matched`）
  * 候補なし → 候補外の対象（`unlisted`）
  * `search_id` が `_unknown` で終わる → `unknown`（「黙る」動作の確認用）

### 本物（`GEMINI_MODE=real`）

Vertex AI の Gemini に、画像と「タイルの中心・見ている方向・候補（名前と見た目の説明）・エリア」を渡し、1回の呼び出しで
`matched`（候補のどれか）／`unlisted`（候補外の名前と説明）／`unknown` と自信の度合いを返させる。

撮影の手がかり `context`（任意。11/7 追加）があれば、プロンプトに足す：町丁目名（「富山市〇〇付近」）、
範囲の中にいるランドマーク（「〇〇の付近で撮った」。視線の外でも候補に入れる）、撮影の日時（日本時間）、
頼んだ検索か（`button`・`voice`）。無ければ前と同じ（古いアプリは送らない）。

話す価値と名前（11/7 夜）：Gemini に「観光の案内として話す価値があるか」（`worth_telling`）を必ず答えさせ、false なら `unknown`
（前は「ありふれているか」を聞いていたが、例に無いものがすり抜けた）。固有名は看板の文字で読めるか、確かに見分けられる有名な場所だけ。
ランドマークの別名（`aliases`。データだけに持ち、タイルには入れない）を候補の行に書き、`unlisted` の名前が登録した場所の名前・別名と
同じなら、候補なら `matched` に直し、候補でなければ `unknown` にする。

後処理（AI の答えをそのまま信じない）：

* JSON が壊れている・候補に無い ID・名前が無い → `unknown`（推測で補わない）
* 説明から、数字・年号を含む文を落とす。名前に数字があれば `unknown`
* 説明は目安100字で切る
* 自信が `VISUAL_MIN_CONFIDENCE`（0.3）未満 → `unknown`。話すかどうかの本当のしきい値は engine の 0.6
* `GEMINI_GROUNDING=maps` かつエリアの中のときだけ Google マップでのグラウンディングを付け、出典を `sources` に入れる
* 送る位置はタイルの中心だけ（正確な位置は持っていない）。画像は検索が終わったら手放す
* 6秒で返らなければ 504 `gemini_timeout`、ほかの失敗は 502 `gemini_error`

## 手元で動かす

```sh
cd cloud/api
pip install -r requirements.txt
python -m pytest -q                                   # テスト
APP_TOKEN=local-test uvicorn app.main:app --port 8080  # 起動
curl localhost:8080/health
curl -H "X-App-Token: local-test" localhost:8080/v1/tiles/16/57746/25576
```

## 設定（環境変数）

| 名前 | 既定 | 意味 |
| :---- | :---- | :---- |
| `TILE_SOURCE` | `fake` | `sqlite` で SQLite から返す（reviewed のランドマークがそろったら切り替える） |
| `TILE_ZONES` | `off` | `on` でタイルの応答に `zones`（カメラで調べない区域）を付ける。**engine が `zones` を読めるようになってから `on` にする**（engine は知らないキーがあるとタイルを読めないため）。区域のあるタイルにだけ付ける（古いアプリが壊れるのは区域のあるタイルだけ）。11/7 に追加 |
| `TILE_SHAPES` | `off` | `on` でタイルのランドマークに `shape`（実際の形。公園・建物は輪郭、通り・川は線と判定の幅）を付ける。**形を読める engine のアプリ（11/7 以降の main）が入ってから `on` にする**（古い engine は知らないキーでタイルを読めないため）。`off` でも形のあるランドマークは形がかかるタイルすべてに入る（キーは外す）。11/7 に追加 |
| `TILES_DB_PATH` | `cloud/data/build/tiles.sqlite` | SQLite の場所 |
| `EVENT_STATUS` | `file` | `firestore` でイベントの開催状態を Firestore の `event_status/<ID>.status`（`scheduled`・`held`・`cancelled`）で上書き。30秒ごとに読み直す。デモで「中止」に切り替えるとき用 |
| `APP_TOKEN` | 空 | `X-App-Token` の値。空だと `/v1/` はすべて 401。Cloud Run では Secret Manager から渡す |
| `GEMINI_MODE` | `fake` | `real` は Cloud Run の環境変数で明示したときだけ |
| `GEMINI_GROUNDING` | `off` | `maps` で Google マップでのグラウンディングを付ける。**11/5 の確認では使わない**（遅い・答えが JSON で読めないことがあった） |
| `VERTEX_LOCATION` / `GEMINI_MODEL` | `global` / `gemini-3.6-flash` | 11/5 に実際の写真で比べて決めた（3.6-flash は global だけ） |
| `GEMINI_THINKING_LEVEL` | `LOW` | 考える量。LOW で 2〜3 秒、MEDIUM 以上だと 4〜8 秒で 6 秒のタイムアウトを超えやすい |
| `GOOGLE_CLOUD_PROJECT` | 空 | `real` のときに必須 |
| `VISUAL_MIN_CONFIDENCE` | `0.3` | これ未満の自信は `unknown` |
| `DESCRIPTION_MAX_CHARS` | `100` | 説明の長さ |
| `GEMINI_TIMEOUT_S` | `6` | mobile の8秒より短く |
| `VISUAL_SEARCH_DAILY_LIMIT` | `1000` | 1日（日本時間）あたりの B の上限。インスタンスごとに数える。11/6 夜に300から上げた（計測間隔を20秒にしたため。30分の歩行で最大約90回、上限いっぱいで約400円/日）。提出後は100に下げる |
| `MAX_IMAGE_BASE64_CHARS` | `1000000` | 画像の上限（base64 の文字数） |

## デプロイ（人がやる。`gcloud` は実行前にチームで確認）

リポジトリの一番上で実行する。`PROJECT_ID` は自分のプロジェクトに置き換える。

```sh
# 1回だけ：コンテナの置き場所とトークンを作る
gcloud artifacts repositories create app --repository-format=docker --location=asia-northeast1
printf '%s' "<トークンの値>" | gcloud secrets create app-token --data-file=-
gcloud secrets add-iam-policy-binding app-token \
  --member="serviceAccount:<プロジェクト番号>-compute@developer.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor

# 毎回：ビルドしてデプロイ
gcloud builds submit --config cloud/api/cloudbuild.yaml .
gcloud run deploy api \
  --image=asia-northeast1-docker.pkg.dev/PROJECT_ID/app/api:latest \
  --region=asia-northeast1 \
  --allow-unauthenticated \
  --max-instances=2 \
  --set-env-vars=GEMINI_MODE=fake \
  --set-secrets=APP_TOKEN=app-token:latest
```

* `--allow-unauthenticated`：スマホのアプリから呼ぶため。代わりに `X-App-Token` で守る
* `--max-instances=2`：回数上限をインスタンスごとに数えるので、数を絞って全体の上限がずれすぎないようにする。費用の上限にもなる
* トークンの値はチャットで渡す。コミットしない

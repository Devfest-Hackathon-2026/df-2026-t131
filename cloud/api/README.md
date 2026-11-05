# cloud/api — Cloud Run の API

持ち主：メンバー1。形式は `schema/api/`、決まりは `tasks/README.md` 2.4。

| ルート | 中身 | 認証 |
| :---- | :---- | :---- |
| `GET /health` | `{"status":"ok"}` | なし |
| `GET /v1/tiles/16/{x}/{y}` | A：タイルのランドマーク・電停・横断歩道・イベント | `X-App-Token` |
| `POST /v1/visual-search` | B：視界の検索 | `X-App-Token` |

エラーは `{"error": "<コード>"}`。コードの一覧は `schema/README.md`。

## いまの状態（fake モード）

`GEMINI_MODE=fake`（既定）では `schema/examples/` の見本を返す。課金は起きない。

* タイル：`16/57746/25576` だけ見本の中身、ほかのタイルは空の配列
* 視界の検索：送信の中身で決まった応答を返す
  * `area` あり → エリア内の名前付きの対象（`named: true`）
  * 候補あり → 候補の先頭に一致（`matched`）
  * 候補なし → 候補外の対象（`unlisted`）
  * `search_id` が `_unknown` で終わる → `unknown`（「黙る」動作の確認用）

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
| `APP_TOKEN` | 空 | `X-App-Token` の値。空だと `/v1/` はすべて 401。Cloud Run では Secret Manager から渡す |
| `GEMINI_MODE` | `fake` | `real` は Cloud Run の環境変数で明示したときだけ |
| `GEMINI_GROUNDING` | `off` | `maps` で Google マップでのグラウンディングを付ける |
| `VERTEX_LOCATION` / `GEMINI_MODEL` | `asia-northeast1` / `gemini-2.5-flash` | 仮。本物の検索に取りかかる前に確定する |
| `GEMINI_TIMEOUT_S` | `6` | mobile の8秒より短く |
| `VISUAL_SEARCH_DAILY_LIMIT` | `300` | 1日（日本時間）あたりの B の上限。インスタンスごとに数える |
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

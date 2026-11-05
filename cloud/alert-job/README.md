# cloud/alert-job — 気象警報のジョブ

持ち主：メンバー1。気象庁の防災情報XML（随時フィード）を1分おきに見て、富山市の警報のレベルが上がったら FCM のトピック `alert_16201` に送る。送る形は `schema/fcm/alert.data.schema.json`、送り方は `schema/README.md`「FCM の警報の送り方」。

## 流れ

```
Cloud Scheduler（1分おき）→ POST /run
  → extra.xml を条件付き GET（変わっていなければ 304 で終わり）
  → 富山県（160000）の「気象警報・注意報（Ｒ０６）（分野）」の電文を読む
  → 富山市（1620100）の、分野ごとのいちばん高いレベルを前回（Firestore）と比べる
  → 上がって、かつ ALERT_MIN_LEVEL（既定3＝警報）以上なら FCM へ
```

* 形式は 2026年5月からの新しい体系（`レベル４大雨危険警報` のように名前にレベルが入る）。実際の電文で確かめてある
* 同じ警報は2回送らない（継続は送らない）。下がったとき・解除は送らない
* 文はテンプレートで作る（AI は使わない）。気象庁の発表の種類とレベルをそのまま伝え、自前の予想はしない
* 訓練・試験の電文は読まない

## デモ用の模擬の警報

本物の警報はデモのときに出ているとは限らないので、**模擬電文を本物と同じ判定に通して送る**口を用意してある。

```
POST /mock-alert                       # app/mock/level4_heavy_rain.xml（レベル4 大雨危険警報）
```

* 送る文の頭に「これはデモ用の模擬の警報です。」が入り、`alert_id` は `mock_` で始まる
* 本物の判定の状態（Firestore）には影響しない。何度でも鳴らせる
* デモ動画では「模擬の警報を、実際の判定の仕組みに流している」ことを明示する（偽装にしない）

## 手元で動かす

```sh
cd cloud/alert-job
pip install -r requirements.txt
python -m pytest -q
uvicorn app.main:app --port 8081       # 既定は送らない（ALERT_SENDER=fake）・状態はメモリ
curl -X POST localhost:8081/run
curl -X POST localhost:8081/mock-alert
```

※ このリーダーの PC は Norton が HTTPS を検査しているため、Python から気象庁に直接つなぐと証明書のエラーになる（Cloud Run では起きない）。

## 設定（環境変数）

| 名前 | 既定 | 意味 |
| :---- | :---- | :---- |
| `ALERT_SENDER` | `fake` | `fcm` で本当に送る |
| `ALERT_STATE` | `memory` | `firestore` で前回の状態を Firestore（`alert_job/state`）に置く |
| `ALERT_MIN_LEVEL` | `3` | このレベル以上に上がったら送る |
| `JMA_OFFICE_CODE` / `JMA_MUNICIPALITY_CODE` | `160000` / `1620100` | 富山県 / 富山市 |
| `ALERT_AREA_NAME` / `FCM_TOPIC` | `富山市` / `alert_16201` | |

## デプロイ（人がやる。`gcloud` は実行前にチームで確認）

```sh
gcloud builds submit --config cloud/alert-job/cloudbuild.yaml .
gcloud run deploy alert-job \
  --image=asia-northeast1-docker.pkg.dev/PROJECT_ID/app/alert-job:latest \
  --region=asia-northeast1 \
  --no-allow-unauthenticated \
  --max-instances=1 \
  --set-env-vars=ALERT_SENDER=fcm,ALERT_STATE=firestore

# Cloud Scheduler（1分おき、サービスアカウントの ID トークンで呼ぶ）
gcloud scheduler jobs create http alert-job-every-minute \
  --location=asia-northeast1 --schedule="* * * * *" \
  --uri="<alert-job の URL>/run" --http-method=POST \
  --oidc-service-account-email=<呼び出し用のサービスアカウント>
```

* Cloud Run のサービスアカウントに要る権限：Firestore の読み書き（`roles/datastore.user`）、FCM の送信（`roles/firebasecloudmessaging.admin`）
* 呼び出し用のサービスアカウントに `roles/run.invoker`
* `--max-instances=1`：同時に2つ動いて同じ警報を2回送らないように

# cloud/alert-job — 気象警報のジョブ

持ち主：メンバー1。気象庁の防災情報XML（随時フィード）を1分おきに見て、対象の区域の警報のレベルが上がったら FCM で送り、今出ている警報の一覧を公開の Cloud Storage に書き出す。

**全国版と同じ部品・同じデータの形で作り、範囲だけを設定で富山市（区域コード `1620100`）に絞っている。** 区域を足すときは、設定 `ALERT_AREAS` と `app/settings.py` の `AREA_NAMES` を増やすだけで、コードは変えない。
発表では「製品化した前提の全国版の構成を、範囲を富山市にしてデモしている」と説明する。

## 流れ（3つの段）

```
Cloud Scheduler（1分おき）→ POST /run
  ingest    ：extra.xml を条件付き GET（変わっていなければ 304 で終わり）
              対象の区域から決めた気象台（1620100 → 160000）の「気象警報・注意報（Ｒ０６）」の電文だけ取る
              元の電文を raw/<日付>/<電文ID>.xml に保存（記録用・30日で消す）
  evaluate  ：区域 × 分野（大雨・暴風…）のいちばん高いレベルを、Firestore の前回と比べる
  distribute：① 上がって ALERT_MIN_LEVEL（既定3＝警報）以上なら、FCM のトピック alert_<区域7桁> へ
              ② 一覧が変わった区域だけ、alerts/current/<区域7桁>.json を書き換える
```

* 段は関数に分けてあり、段の間は dataclass（`RawTelegram`・`AreaUpdate`）で受け渡す。全国版では段の間に Pub/Sub をはさむだけにする
* 形式は 2026年5月からの新しい体系（`レベル４大雨危険警報` のように名前にレベルが入る）。実際の電文で確かめてある
* 同じ警報は2回送らない（継続は送らない）。下がったとき・解除は送らない（一覧だけ更新する）
* 文はテンプレートで作る（AI は使わない）。気象庁の発表の種類とレベルをそのまま伝え、自前の予想はしない
* 訓練・試験の電文は読まない

## 端末に届くもの

| | どこ | 形 | いつ |
| :-- | :-- | :-- | :-- |
| ① プッシュ | FCM トピック `alert_<区域7桁>`（富山市は `alert_1620100`） | `schema/fcm/alert.data.schema.json`（`area_code` つき） | レベルが上がったとき |
| ② 一覧 | `https://storage.googleapis.com/<ALERT_BUCKET>/alerts/current/<区域7桁>.json` | `schema/api/alerts_current.schema.json`（見本 `schema/examples/alerts/current_1620100.json`） | 一覧が変わったとき。警報が無くても `"alerts": []` で置く |

* ① と ② の同じ警報は**同じ `alert_id`**。同じ警報が続いている間は ID が変わらないので、端末は ② を取り直しても同じ警報として捨てられる
* ① の文は「気象庁は、富山市に警戒レベル4の大雨危険警報を発表しました。」、② の文は後から入った人向けに「…を発表しています。」。**気象庁の発表を伝えていることが分かる文にする**（気象業務法 第23条：気象庁以外の者は警報をしてはならない。docs/design.md 3章8）
* ② は `Cache-Control: public, max-age=60`。端末は ETag をつけて取りに来る（変わっていなければ 304）
* **移行の間**は、富山市の ① を前のトピック `alert_16201` にも送る（mobile が `alert_1620100` に切り替えたら `FCM_LEGACY_TOPIC=""` で止める）

## 全国版との違い（デモで作らないもの）

| 全国版 | デモ | 理由 |
| :-- | :-- | :-- |
| 気象業務支援センターのプッシュ型の配信 | 公開フィードを1分おき | 入口は `FeedSource` で差し替えられる |
| 段の間に Pub/Sub | 1つの Cloud Run の中で順に呼ぶ | 段は関数に分けてある |
| Firestore のトランザクションで二重送信を防ぐ | `--max-instances=1` | 同時に2つ動かさない |
| ② の前に Cloud CDN | Cloud Storage から直接配る（Cache-Control つき） | ロードバランサーの固定費が予算 $20 に合わない。URL の形は同じ |

## デモ用の模擬の警報

本物の警報はデモのときに出ているとは限らないので、**模擬電文を本物と同じ判定に通して送る**口を用意してある。

```
POST /mock-alert                       # app/mock/level4_heavy_rain.xml（レベル4 大雨危険警報）
POST /mock-alert/clear                 # 模擬の一覧を空に戻す（テストのあと）
```

* 送る文は「これは訓練用の模擬の警報で、実際の警報ではありません。富山市に警戒レベル4の大雨危険警報が出た、という想定です。…」。**気象庁の名前は出さない**（模擬を気象庁の発表のように言わない）。`alert_id` は `mock_` で始まる
* `alert_id` の最後に送った時刻（UTC ミリ秒）が付くので、毎回別の ID になる（端末は同じ ID の2回目を捨てるため。アプリを起動したままでも何度でも鳴る）。本物の警報の ID は時刻を足さず、同じ発表なら同じ ID
* ① は本物と同じトピック（`alert_1620100` と移行の間の `alert_16201`）に送る。② は本物と分けて `alerts/current/mock_1620100.json` に書く
* 本物の判定の状態（Firestore）と本物の一覧には影響しない。何度でも鳴らせる
* **テストが終わったら `POST /mock-alert/clear` で模擬の一覧を空に戻す**（残ったままだと、開発者モードの端末が歩き始めるたびに古い模擬の警報を読む）
* デモ動画では「模擬の警報を、実際の判定の仕組みに流している」ことを明示する（偽装にしない）

## 手元で動かす

```sh
cd cloud/alert-job
pip install -r requirements.txt
python -m pytest -q
uvicorn app.main:app --port 8081       # 既定は送らない・書かない（fake）・状態はメモリ
curl -X POST localhost:8081/run
curl -X POST localhost:8081/mock-alert
```

※ このリーダーの PC は Norton が HTTPS を検査しているため、Python から気象庁に直接つなぐと証明書のエラーになる（Cloud Run では起きない）。

## 設定（環境変数）

| 名前 | 既定 | 意味 |
| :---- | :---- | :---- |
| `ALERT_AREAS` | `1620100` | 対象の区域（7桁のカンマ区切り）。気象台のコードは区域の頭2桁から決める（`app/settings.py` の `office_for`） |
| `ALERT_SENDER` | `fake` | `fcm` で本当に送る |
| `ALERT_STATE` | `memory` | `firestore` で前回の状態を Firestore に置く（`alert_job/feed`・`alert_state/<区域7桁>`） |
| `ALERT_PUBLISHER` | `fake` | `gcs` で ② を Cloud Storage に書く |
| `ALERT_ARCHIVE` | `fake` | `gcs` で元の電文を Cloud Storage の `raw/` に書く |
| `ALERT_BUCKET` | 空 | ② を置く公開のバケット。`ALERT_ARCHIVE_BUCKET` が空なら元の電文もここの `raw/` に置く |
| `ALERT_ARCHIVE_BUCKET` | 空 | 元の電文を別のバケットに置くとき |
| `FCM_LEGACY_TOPIC` | `alert_16201` | 移行の間だけ富山市の ① を送る前のトピック。空で止める |
| `ALERT_MIN_LEVEL` | `3` | このレベル以上に上がったら送る・一覧に載せる |

区域の名前は `app/settings.py` の `AREA_NAMES`（今は `1620100 → 富山市` だけ）。頭2桁で気象台が決まらない区域（北海道・鹿児島の奄美・沖縄など）は `OFFICE_OVERRIDES` に書く。

## いまの状態

* Cloud Run：https://alert-job-566419227445.asia-northeast1.run.app（認証あり。`ALERT_SENDER=fcm`・`ALERT_STATE=firestore`）
* Cloud Scheduler：`alert-job-every-minute`（1分おき、サービスアカウント `scheduler-invoker` の ID トークンで呼ぶ）
* Cloud Run のサービスアカウント：`566419227445-compute@developer.gserviceaccount.com`（プロジェクト既定）
* 模擬の警報を手で送る（オーナーの権限が要る。PowerShell）：
  ```
  curl.exe -X POST -H "Content-Length: 0" -H "Authorization: Bearer $(gcloud auth print-identity-token)" https://alert-job-566419227445.asia-northeast1.run.app/mock-alert
  ```
  （PowerShell では `-d ""` が消えて引数がずれるので、`-H "Content-Length: 0"` を使う）

## 公開バケットを用意する（人がやる。1回だけ）

地図などの非公開のデータとは**別の**バケットにする（中身はすべて公開になるため）。公開のバケットには ② だけを置く。
**元の電文（`raw/`）は、非公開の別のバケット `ambient-guide-toyama-2026-alerts-raw` に置く**（記録用で公開する必要がない。気象庁の電文をそのまま再配布しない。11/6 に変更）。

```sh
# 1. バケットを作る（東京、一様なアクセス制御）
gcloud storage buckets create gs://ambient-guide-toyama-2026-alerts --location=asia-northeast1 --uniform-bucket-level-access

# 2. 誰でも読めるようにする（allUsers に読み取りだけ）
gcloud storage buckets add-iam-policy-binding gs://ambient-guide-toyama-2026-alerts --member=allUsers --role=roles/storage.objectViewer

# 3. raw/ だけ30日で消す（cloud/alert-job/lifecycle.json）
gcloud storage buckets update gs://ambient-guide-toyama-2026-alerts --lifecycle-file=cloud/alert-job/lifecycle.json

# 3'. 元の電文用の非公開のバケット（外から読めない設定、raw/ を30日で消す）
gcloud storage buckets create gs://ambient-guide-toyama-2026-alerts-raw --location=asia-northeast1 --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://ambient-guide-toyama-2026-alerts-raw --lifecycle-file=cloud/alert-job/lifecycle.json
gcloud storage buckets add-iam-policy-binding gs://ambient-guide-toyama-2026-alerts-raw --member=serviceAccount:566419227445-compute@developer.gserviceaccount.com --role=roles/storage.objectCreator

# 4. 警報ジョブ（Cloud Run のサービスアカウント）に、このバケットへの書き込み（上書きを含む）を許す
gcloud storage buckets add-iam-policy-binding gs://ambient-guide-toyama-2026-alerts --member=serviceAccount:566419227445-compute@developer.gserviceaccount.com --role=roles/storage.objectAdmin
```

* 組織のポリシーで公開バケットが禁止されていると、2 が失敗する（このプロジェクトは個人のアカウントで組織が無いので、通る想定。失敗したらエラーの文を確かめる）
* ② の URL：`https://storage.googleapis.com/ambient-guide-toyama-2026-alerts/alerts/current/1620100.json`（mobile の `ALERTS_BASE_URL` は `https://storage.googleapis.com/ambient-guide-toyama-2026-alerts`）
* viewer（Web）から ② を直接読むことになったら、バケットに CORS の設定が要る（アプリからは不要）

## デプロイ（人がやる。`gcloud` は実行前にチームで確認）

```sh
gcloud builds submit --config cloud/alert-job/cloudbuild.yaml .
gcloud run deploy alert-job \
  --image=asia-northeast1-docker.pkg.dev/PROJECT_ID/app/alert-job:latest \
  --region=asia-northeast1 \
  --no-allow-unauthenticated \
  --max-instances=1 \
  --update-env-vars=ALERT_SENDER=fcm,ALERT_STATE=firestore,ALERT_AREAS=1620100,ALERT_PUBLISHER=gcs,ALERT_ARCHIVE=gcs,ALERT_BUCKET=ambient-guide-toyama-2026-alerts,ALERT_ARCHIVE_BUCKET=ambient-guide-toyama-2026-alerts-raw

# Cloud Scheduler（1分おき、サービスアカウントの ID トークンで呼ぶ）
gcloud scheduler jobs create http alert-job-every-minute \
  --location=asia-northeast1 --schedule="* * * * *" \
  --uri="<alert-job の URL>/run" --http-method=POST \
  --oidc-service-account-email=<呼び出し用のサービスアカウント>
```

* Cloud Run のサービスアカウントに要る権限：Firestore の読み書き（`roles/datastore.user`）、FCM の送信（`roles/firebasecloudmessaging.admin`）、公開バケットへの書き込み（上の 4）
* 呼び出し用のサービスアカウントに `roles/run.invoker`
* `--max-instances=1`：同時に2つ動いて同じ警報を2回送らないように
* **11/6 の形の変更（区域ごとの状態）について**：Firestore の状態は `alert_job/state` から `alert_job/feed`＋`alert_state/<区域>` に分けた。最初の実行では、処理済みの電文 ID だけを前の文書から引き継ぐ（同じ電文を読み直して二重に送らないため）。区域のレベルは0から始まるので、切り替えの時点で富山市に警報が出ていた場合、次の電文が来るまで ② に載らない（11月の富山では起こりにくい）

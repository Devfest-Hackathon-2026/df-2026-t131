# cloud/viewer-web — 判断画面の Web 版を Cloud Run で公開する（担当：メンバー1）

`app/viewer`（メンバー2）を Flutter Web でビルドし、nginx で配るコンテナにして Cloud Run に載せる。
審査用のデプロイ URL として **11/14（Regional Day）まで動かし続ける**。

* 画面の中身は `app/viewer`。このフォルダはビルドと配信の設定だけで、画面のコードは持たない
* Firebase Hosting は使わない（11/6 決定）。API・警報ジョブと同じ Cloud Run にそろえる
* 動的な処理は無い。歩行ログはブラウザの中で読むだけで、どこにも送らない（`app/viewer/README.md`）

## 中身

| ファイル | 役割 |
| :-- | :-- |
| `Dockerfile` | 1段目：Flutter 3.47.9（チームの版。公開イメージが無いので Google が配る本体を取る）で `flutter build web`。2段目：nginx で `build/web` を配る |
| `nginx.conf` | 8080 で待つ。すべてのファイルを `no-cache`（毎回確かめる。Flutter Web のファイル名は版が変わっても同じなので、古い版が残らないように）。それ以外の移動は `index.html` に返す |
| `cloudbuild.yaml` | Cloud Build でイメージを作り、Artifact Registry `app/viewer:latest` に置く（時間の上限 30分） |
| `.gcloudignore` | Cloud Build に送るのは `app/engine`・`app/viewer`・`cloud/viewer-web` だけ（一番上の `.gcloudignore` は API 用で `app/` を除くため） |

## デプロイ（人が行う。リポジトリの一番上で）

```sh
gcloud builds submit --config cloud/viewer-web/cloudbuild.yaml --ignore-file=cloud/viewer-web/.gcloudignore . --project=ambient-guide-toyama-2026
gcloud run deploy viewer --image=asia-northeast1-docker.pkg.dev/ambient-guide-toyama-2026/app/viewer:latest --region=asia-northeast1 --project=ambient-guide-toyama-2026 --allow-unauthenticated --port=8080 --memory=256Mi --max-instances=3
```

* 1行目は Flutter の取得とビルドで数分かかる
* 2回目からは `--allow-unauthenticated` 以降を省いてよい（設定は引き継がれる）
* **`app/viewer` や地図データ（`assets/map.json`）・歩行ログが変わったら、この2行で出し直す**（自動では出し直さない）
* 審査員はログインなしで開ける（`--allow-unauthenticated`）。中身は公開してよいものだけ（同梱の歩行ログはデモのルートだけ）

## 確かめる

```sh
gcloud run services describe viewer --region=asia-northeast1 --project=ambient-guide-toyama-2026 --format="value(status.url)"
```

出てきた URL をブラウザで開き、地図・再生・判断ログが出ること、`<URL>/assets/assets/map.json` が読めることを見る。

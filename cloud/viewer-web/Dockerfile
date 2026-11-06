# 判断画面の Web 版（app/viewer）を Cloud Run で配るコンテナ。
# ビルドはリポジトリの一番上を文脈にする（app/engine を path で参照しているため）:
#   gcloud builds submit --config cloud/viewer-web/cloudbuild.yaml --ignore-file=cloud/viewer-web/.gcloudignore .
# 画面の中身はメンバー2（app/viewer）、このフォルダ（ビルドと配信）はメンバー1。

# ---- 1. Flutter Web をビルドする ----
# チームの版（tasks/README.md・CI と同じ 3.47.9）。この版の公開イメージが無いので、Google が配る本体を取ってくる
FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.47.9
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
  | tar -xJ -C /opt
ENV PATH=/opt/flutter/bin:$PATH
RUN git config --global --add safe.directory /opt/flutter \
 && flutter config --no-analytics --enable-web \
 && flutter precache --web

WORKDIR /src
COPY app/engine/ app/engine/
COPY app/viewer/ app/viewer/
WORKDIR /src/app/viewer
RUN flutter pub get && flutter build web --release

# ---- 2. できたファイルを nginx で配る（動的な処理は無い） ----
FROM nginx:1.27-alpine
COPY cloud/viewer-web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/app/viewer/build/web /usr/share/nginx/html
EXPOSE 8080

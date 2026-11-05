# Cloud Run の API。ビルドはリポジトリの一番上を文脈にする（schema/ を同梱するため）:
#   docker build -f cloud/api/Dockerfile .
# コンテナの中もリポジトリと同じ構成にして、settings.py のパスがそのまま通るようにする。
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /srv
COPY cloud/api/requirements.txt cloud/api/requirements.txt
RUN pip install --no-cache-dir -r cloud/api/requirements.txt

COPY schema/ schema/
COPY cloud/api/app/ cloud/api/app/
# TODO(メンバー1): 3章で SQLite（cloud/data/build/）を同梱する

WORKDIR /srv/cloud/api
RUN useradd --create-home appuser
USER appuser

# アクセスログは Cloud Run が残すので uvicorn では出さない（本文はどちらも出ない）
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --no-access-log"]

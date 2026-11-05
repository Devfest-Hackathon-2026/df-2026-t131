# 警報ジョブ。ビルドはリポジトリの一番上を文脈にする（schema/ を同梱するため）:
#   docker build -f cloud/alert-job/Dockerfile .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /srv
COPY cloud/alert-job/requirements.txt cloud/alert-job/requirements.txt
RUN pip install --no-cache-dir -r cloud/alert-job/requirements.txt

COPY schema/ schema/
COPY cloud/alert-job/app/ cloud/alert-job/app/

WORKDIR /srv/cloud/alert-job
RUN useradd --create-home appuser
USER appuser

CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --no-access-log"]

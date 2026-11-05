"""Cloud Run の警報ジョブ。Cloud Scheduler が1分おきに POST /run を呼ぶ。

  GET  /health                 生存確認
  POST /run                    気象庁のフィードを見て、上がった警報を FCM へ。今出ている警報の一覧を書き換える
  POST /mock-alert?name=...    デモ用：模擬電文（app/mock/<name>.xml）を同じ判定に通して FCM へ。
                               一覧は alerts/current/mock_<区域>.json に書く（本物の一覧は汚さない）
  POST /mock-alert/clear       デモ用：模擬の警報の一覧を空に戻す（テストのあとに呼ぶ）

Cloud Run は認証ありでデプロイする（--no-allow-unauthenticated）。呼べるのは Cloud Scheduler と
起動者の権限を持つ人だけ。
"""
import logging
import re

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from .jma import JmaFeedSource
from .job import AlertJob
from .sender import FakeSender, FcmSender
from .settings import MOCK_DIR, Settings
from .state import FirestoreStateStore, MemoryStateStore
from .storage import FakeArchive, FakePublisher, GcsArchive, GcsPublisher

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("alert-job")


def create_app(job: AlertJob | None = None) -> FastAPI:
    if job is None:
        s = Settings()
        job = AlertJob(
            s,
            JmaFeedSource(),
            FirestoreStateStore() if s.state == "firestore" else MemoryStateStore(),
            FcmSender() if s.sender == "fcm" else FakeSender(),
            GcsPublisher(s.bucket) if s.publisher == "gcs" else FakePublisher(),
            GcsArchive(s.archive_bucket or s.bucket) if s.archive == "gcs" else FakeArchive(),
        )
    app = FastAPI(title="警報ジョブ", docs_url=None, redoc_url=None, openapi_url=None)

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.post("/run")
    def run():
        try:
            r = job.run()
        except Exception as e:
            log.error("run failed: %s: %s", type(e).__name__, e)
            return JSONResponse({"error": "internal"}, status_code=500)
        return {"feed_changed": r.feed_changed, "telegrams": r.telegrams, "sent": len(r.sent),
                "published": len(r.published)}

    @app.post("/mock-alert/clear")
    def mock_clear():
        r = job.clear_mock()
        return {"published": r.published}

    @app.post("/mock-alert")
    def mock_alert(name: str = "level4_heavy_rain"):
        if not re.fullmatch(r"[a-z0-9_]+", name) or not (MOCK_DIR / f"{name}.xml").exists():
            return JSONResponse({"error": "not_found"}, status_code=404)
        r = job.run_mock((MOCK_DIR / f"{name}.xml").read_bytes())
        return {
            "sent": [{"alert_id": d["alert_id"], "area_code": d["area_code"], "kind": d["kind"],
                      "level": d["level"], "text": d["text"]} for d in r.sent],
            "published": r.published,
        }

    return app


app = create_app()

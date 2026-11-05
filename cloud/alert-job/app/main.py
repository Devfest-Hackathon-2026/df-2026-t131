"""Cloud Run の警報ジョブ。Cloud Scheduler が1分おきに POST /run を呼ぶ。

  GET  /health                 生存確認
  POST /run                    気象庁のフィードを見て、上がった警報を FCM へ
  POST /mock-alert?name=...    デモ用：模擬電文（app/mock/<name>.xml）を同じ判定に通して FCM へ

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
        return {"feed_changed": r.feed_changed, "telegrams": r.telegrams, "sent": len(r.sent)}

    @app.post("/mock-alert")
    def mock_alert(name: str = "level4_heavy_rain"):
        if not re.fullmatch(r"[a-z0-9_]+", name) or not (MOCK_DIR / f"{name}.xml").exists():
            return JSONResponse({"error": "not_found"}, status_code=404)
        r = job.run_mock((MOCK_DIR / f"{name}.xml").read_bytes())
        return {"sent": [{"kind": d["kind"], "level": d["level"], "text": d["text"]} for d in r.sent]}

    return app


app = create_app()

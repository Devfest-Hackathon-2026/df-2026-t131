"""FCM へ送る部分。fake は送らずに記録だけする（テスト・手元用）。"""
import logging
from typing import Protocol

log = logging.getLogger("alert-job")


class Sender(Protocol):
    def send(self, topic: str, data: dict) -> None: ...


class FakeSender:
    def __init__(self) -> None:
        self.sent: list[tuple[str, dict]] = []

    def send(self, topic: str, data: dict) -> None:
        self.sent.append((topic, data))
        log.info("（fake）FCM %s に送る: %s %s", topic, data["kind"], data["level"])


class FcmSender:
    """data だけのメッセージ（notification なし）、Android の優先度 high（schema/README.md）。"""

    def __init__(self, ttl_s: int = 3600) -> None:
        import firebase_admin
        from firebase_admin import messaging

        if not firebase_admin._apps:
            firebase_admin.initialize_app()  # Cloud Run のサービスアカウントで認証する
        self._messaging = messaging
        self._ttl = ttl_s

    def send(self, topic: str, data: dict) -> None:
        m = self._messaging
        msg = m.Message(topic=topic, data=data, android=m.AndroidConfig(priority="high", ttl=self._ttl))
        message_id = m.send(msg)
        log.info("FCM %s に送った: %s %s (%s)", topic, data["kind"], data["level"], message_id)

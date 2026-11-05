"""警報ジョブの設定。既定は「何も外に出さない」側（fake）。"""
import os
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCHEMA_DIR = ROOT / "schema"
MOCK_DIR = Path(__file__).resolve().parent / "mock"
SCHEMA_VERSION = "0.3"


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


@dataclass(frozen=True)
class Settings:
    # jma：本物の気象庁のフィード／fake：テスト用（main では使わない）
    source: str = field(default_factory=lambda: _env("ALERT_SOURCE", "jma"))
    # fcm：本当に送る／fake：送らずにログだけ
    sender: str = field(default_factory=lambda: _env("ALERT_SENDER", "fake"))
    # firestore：Cloud Run 用／memory：手元用
    state: str = field(default_factory=lambda: _env("ALERT_STATE", "memory"))
    office_code: str = field(default_factory=lambda: _env("JMA_OFFICE_CODE", "160000"))          # 富山県
    municipality_code: str = field(default_factory=lambda: _env("JMA_MUNICIPALITY_CODE", "1620100"))  # 富山市
    area_name: str = field(default_factory=lambda: _env("ALERT_AREA_NAME", "富山市"))
    topic: str = field(default_factory=lambda: _env("FCM_TOPIC", "alert_16201"))
    # このレベル以上に上がったら送る（3＝警報、4＝危険警報、5＝特別警報）
    min_level: int = field(default_factory=lambda: int(_env("ALERT_MIN_LEVEL", "3")))

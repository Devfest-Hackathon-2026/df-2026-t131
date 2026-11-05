"""警報ジョブの設定。既定は「何も外に出さない」側（fake）。

全国版と同じ部品・同じデータの形で作り、対象の範囲だけを設定で絞る（デモは富山市 1620100 だけ）。
区域を足すときは、ALERT_AREAS と AREA_NAMES を増やすだけで、コードは変えない。
"""
import os
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCHEMA_DIR = ROOT / "schema"
MOCK_DIR = Path(__file__).resolve().parent / "mock"
SCHEMA_VERSION = "0.3"

# 区域コード（気象庁の「気象警報・注意報」の市町村等の区域、7桁）→ 区域名。区域を足すときはここに足す
AREA_NAMES: dict[str, str] = {
    "1620100": "富山市",
}

# 区域コードの頭2桁から気象台（府県予報区）のコードが決まらない区域だけ、ここに書く。
# 例：北海道・鹿児島（奄美）・沖縄は1つの都道府県に複数の気象台がある（足すときに気象庁の区域の一覧で確かめる）
OFFICE_OVERRIDES: dict[str, str] = {}

# 移行の間だけ、前のトピック名にも同じものを送る（mobile が alert_<7桁> に切り替えたら FCM_LEGACY_TOPIC="" で止める）
LEGACY_TOPIC_AREA = "1620100"


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def office_for(area_code: str) -> str:
    """区域コード → 気象台のコード（1620100 → 160000）。設定を2つ持たないように、区域から決める。"""
    return OFFICE_OVERRIDES.get(area_code, f"{area_code[:2]}0000")


def topic_for(area_code: str) -> str:
    return f"alert_{area_code}"


def _areas(raw: str) -> tuple[str, ...]:
    areas = tuple(a.strip() for a in raw.split(",") if a.strip())
    for a in areas:
        if not (len(a) == 7 and a.isdigit()):
            raise ValueError(f"ALERT_AREAS の区域コードは7桁の数字: {a!r}")
        if a not in AREA_NAMES:
            raise ValueError(f"区域 {a} の名前が AREA_NAMES に無い（settings.py に足す）")
    return areas


@dataclass(frozen=True)
class Settings:
    # jma：本物の気象庁のフィード／fake：テスト用（main では使わない）
    source: str = field(default_factory=lambda: _env("ALERT_SOURCE", "jma"))
    # fcm：本当に送る／fake：送らずにログだけ
    sender: str = field(default_factory=lambda: _env("ALERT_SENDER", "fake"))
    # firestore：Cloud Run 用／memory：手元用
    state: str = field(default_factory=lambda: _env("ALERT_STATE", "memory"))
    # 対象の区域（7桁のカンマ区切り）。デモは富山市だけ
    areas: tuple[str, ...] = field(default_factory=lambda: _areas(_env("ALERT_AREAS", "1620100")))
    # 前のトピック名（空なら送らない）。LEGACY_TOPIC_AREA の警報だけを送る
    legacy_topic: str = field(default_factory=lambda: _env("FCM_LEGACY_TOPIC", "alert_16201"))
    # 今出ている警報の一覧（alerts/current/<区域>.json）の書き出し先。gcs：Cloud Storage／fake：書かずに覚えるだけ
    publisher: str = field(default_factory=lambda: _env("ALERT_PUBLISHER", "fake"))
    # 元の電文の記録（raw/<日付>/<電文ID>.xml）。gcs／fake
    archive: str = field(default_factory=lambda: _env("ALERT_ARCHIVE", "fake"))
    # 公開のバケット（一覧の置き場所）。元の電文の記録も、別に指定しなければ同じバケットの raw/ に置く
    bucket: str = field(default_factory=lambda: _env("ALERT_BUCKET", ""))
    archive_bucket: str = field(default_factory=lambda: _env("ALERT_ARCHIVE_BUCKET", ""))
    # このレベル以上に上がったら送る（3＝警報、4＝危険警報、5＝特別警報）
    min_level: int = field(default_factory=lambda: int(_env("ALERT_MIN_LEVEL", "3")))

    @property
    def offices(self) -> tuple[str, ...]:
        """読む気象台（区域から決める。重複なし・並び順固定）。"""
        return tuple(sorted({office_for(a) for a in self.areas}))

    def areas_of(self, office_code: str) -> tuple[str, ...]:
        return tuple(a for a in self.areas if office_for(a) == office_code)

    @staticmethod
    def area_name(area_code: str) -> str:
        return AREA_NAMES[area_code]

    def topics_for(self, area_code: str) -> list[str]:
        topics = [topic_for(area_code)]
        if self.legacy_topic and area_code == LEGACY_TOPIC_AREA:
            topics.append(self.legacy_topic)
        return topics

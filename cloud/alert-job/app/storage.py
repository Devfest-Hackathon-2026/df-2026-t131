"""Cloud Storage への書き出し。fake は書かずに覚えるだけ（テスト・手元用）。

  Publisher：今出ている警報の一覧 alerts/current/<区域7桁>.json（公開。端末が取りに来る）
  Archive  ：元の電文 raw/<日付>/<電文ID>.xml（記録用。バケットのライフサイクルで30日で消す）

全国版では、公開の一覧の前に Cloud CDN を置く。デモではロードバランサーの固定費が予算に合わないので置かず、
Cache-Control を付けて Cloud Storage から直接配る（URL の形は同じ）。
"""
import json
import logging
from typing import Protocol

log = logging.getLogger("alert-job")

CURRENT_PREFIX = "alerts/current"
CURRENT_CACHE_CONTROL = "public, max-age=60"
RAW_PREFIX = "raw"


def current_path(area_code: str, mock: bool = False) -> str:
    return f"{CURRENT_PREFIX}/{'mock_' if mock else ''}{area_code}.json"


def raw_path(date: str, file_id: str) -> str:
    return f"{RAW_PREFIX}/{date}/{file_id}.xml"


class Publisher(Protocol):
    def publish(self, path: str, doc: dict) -> None: ...


class Archive(Protocol):
    def save(self, path: str, xml: bytes) -> None: ...


class FakePublisher:
    def __init__(self) -> None:
        self.files: dict[str, dict] = {}

    def publish(self, path: str, doc: dict) -> None:
        self.files[path] = doc
        log.info("（fake）%s を書く: 警報 %d 件", path, len(doc["alerts"]))


class FakeArchive:
    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}

    def save(self, path: str, xml: bytes) -> None:
        self.files[path] = xml


def _bucket(name: str):
    from google.cloud import storage

    if not name:
        raise ValueError("ALERT_BUCKET が空（gcs を使うときはバケット名が要る）")
    return storage.Client().bucket(name)


class GcsPublisher:
    def __init__(self, bucket: str) -> None:
        self._b = _bucket(bucket)

    def publish(self, path: str, doc: dict) -> None:
        blob = self._b.blob(path)
        blob.cache_control = CURRENT_CACHE_CONTROL
        blob.upload_from_string(json.dumps(doc, ensure_ascii=False), content_type="application/json; charset=utf-8")
        log.info("%s を書いた: 警報 %d 件", path, len(doc["alerts"]))


class GcsArchive:
    def __init__(self, bucket: str) -> None:
        self._b = _bucket(bucket)

    def save(self, path: str, xml: bytes) -> None:
        self._b.blob(path).upload_from_string(xml, content_type="application/xml")

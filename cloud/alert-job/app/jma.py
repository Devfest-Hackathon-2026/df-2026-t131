"""気象庁 防災情報XML（随時フィード）から、対象の市町村の警報を読み取る。

形式（2026年5月からの新しい体系。実際の電文で確認済み）:
  - フィードの各 entry：title が「気象警報・注意報（Ｒ０６）（大雨）」など分野ごと、link が電文の URL
  - 電文の Body/Warning[@type="気象警報・注意報（市町村等）"]/Item のうち Area/Code が市町村のもの
  - Kind/Name に「レベル２大雨注意報」「レベル４大雨危険警報」のようにレベルが入る
"""
import re
import unicodedata
import xml.etree.ElementTree as ET
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Protocol

ATOM = {"a": "http://www.w3.org/2005/Atom"}
NS_CONTROL = "http://xml.kishou.go.jp/jmaxml1/"
NS_HEAD = "http://xml.kishou.go.jp/jmaxml1/informationBasis1/"
NS_BODY = "http://xml.kishou.go.jp/jmaxml1/body/meteorology1/"
TITLE_PREFIX = "気象警報・注意報（Ｒ０６）"
MUNICIPAL_TYPE = "気象警報・注意報（市町村等）"
LEVEL_RE = re.compile(r"^レベル([1-5])(.+)$")


@dataclass(frozen=True)
class FeedEntry:
    id: str
    title: str
    updated: str
    link: str

    @property
    def office(self) -> str:
        """電文の URL の末尾（…_160000.xml）から気象台のコード。"""
        return self.link.rsplit("_", 1)[-1].removesuffix(".xml")

    @property
    def file_id(self) -> str:
        """電文のファイル名（拡張子なし）。元の電文の記録の名前に使う。"""
        return self.link.rsplit("/", 1)[-1].removesuffix(".xml")


Kinds = list[tuple[int, str]]  # (レベル, 名前) の高い順。名前は「大雨危険警報」のようにレベルを除いたもの


@dataclass(frozen=True)
class Telegram:
    """1つの電文から読み取った、対象の区域ごとの状態。"""
    category: str          # 電文の題名（例：気象警報・注意報（Ｒ０６）（大雨））＝分野
    status: str            # 通常 / 訓練 / 試験
    report_datetime: str   # 発表時刻（例：2026-11-05T11:20:00+09:00）
    areas: dict[str, Kinds]  # 区域コード → その区域の警報・注意報（電文に載っていない区域は入らない）

    def kinds(self, area_code: str) -> Kinds:
        return self.areas.get(area_code, [])


class FeedSource(Protocol):
    def fetch_feed(self, etag: str | None, last_modified: str | None) -> tuple[bytes | None, str | None, str | None]:
        """(本文, etag, last_modified)。変わっていなければ本文は None（304）。"""

    def fetch_telegram(self, url: str) -> bytes: ...


def parse_feed(xml: bytes, office_codes: Iterable[str]) -> list[FeedEntry]:
    """対象の気象台（府県予報区コード、例：富山 160000）の新しい体系の警報・注意報だけ。古い順。"""
    offices = {office_codes} if isinstance(office_codes, str) else set(office_codes)
    root = ET.fromstring(xml)
    out = []
    for e in root.findall("a:entry", ATOM):
        title = e.findtext("a:title", "", ATOM)
        link_el = e.find("a:link", ATOM)
        link = link_el.get("href", "") if link_el is not None else ""
        if title.startswith(TITLE_PREFIX) and any(link.endswith(f"_{o}.xml") for o in offices):
            out.append(FeedEntry(e.findtext("a:id", link, ATOM), title, e.findtext("a:updated", "", ATOM), link))
    return sorted(out, key=lambda x: (x.updated, x.id))


def _level_and_name(raw: str) -> tuple[int, str] | None:
    m = LEVEL_RE.match(unicodedata.normalize("NFKC", raw).strip())
    return (int(m.group(1)), m.group(2)) if m else None


def parse_telegram(xml: bytes, area_codes: Iterable[str]) -> Telegram:
    """電文から、対象の区域（市町村等、7桁）の警報・注意報を読む。対象外の区域・一次細分区域は読まない。"""
    targets = {area_codes} if isinstance(area_codes, str) else set(area_codes)
    root = ET.fromstring(xml)
    control = root.find(f"{{{NS_CONTROL}}}Control")
    head = root.find(f"{{{NS_HEAD}}}Head")
    body = root.find(f"{{{NS_BODY}}}Body")
    areas: dict[str, Kinds] = {}
    if body is not None:
        for w in body.findall(f"{{{NS_BODY}}}Warning"):
            if w.get("type") != MUNICIPAL_TYPE:
                continue
            for item in w.findall(f"{{{NS_BODY}}}Item"):
                code = item.findtext(f"{{{NS_BODY}}}Area/{{{NS_BODY}}}Code")
                if code not in targets:
                    continue
                kinds = areas.setdefault(code, [])
                for kind in item.findall(f"{{{NS_BODY}}}Kind"):
                    name = kind.findtext(f"{{{NS_BODY}}}Name")
                    st = kind.findtext(f"{{{NS_BODY}}}Status", "")
                    if not name or st == "解除":
                        continue
                    ln = _level_and_name(name)
                    if ln:
                        kinds.append(ln)
    return Telegram(
        category=control.findtext(f"{{{NS_CONTROL}}}Title", "") if control is not None else "",
        status=control.findtext(f"{{{NS_CONTROL}}}Status", "") if control is not None else "",
        report_datetime=head.findtext(f"{{{NS_HEAD}}}ReportDateTime", "") if head is not None else "",
        areas={code: sorted(k, reverse=True) for code, k in areas.items()},
    )


class JmaFeedSource:
    """本物の気象庁のフィード。条件付き GET で、変わっていなければ本文を取らない。"""

    FEED_URL = "https://www.data.jma.go.jp/developer/xml/feed/extra.xml"
    USER_AGENT = "ambient-narrative-guide/0.1 (DevFest GDGoC Japan Hackathon 2026)"

    def __init__(self, timeout_s: float = 20.0):
        import httpx

        self._client = httpx.Client(timeout=timeout_s, headers={"User-Agent": self.USER_AGENT}, follow_redirects=True)

    def fetch_feed(self, etag, last_modified):
        h = {}
        if etag:
            h["If-None-Match"] = etag
        if last_modified:
            h["If-Modified-Since"] = last_modified
        r = self._client.get(self.FEED_URL, headers=h)
        if r.status_code == 304:
            return None, etag, last_modified
        r.raise_for_status()
        return r.content, r.headers.get("ETag"), r.headers.get("Last-Modified")

    def fetch_telegram(self, url: str) -> bytes:
        if not url.startswith("https://www.data.jma.go.jp/"):
            raise ValueError("気象庁以外の URL は読まない")
        r = self._client.get(url)
        r.raise_for_status()
        return r.content

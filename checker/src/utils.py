"""Utils for the checker."""

import asyncio
import re
import string
from collections.abc import Collection
from html import unescape
from urllib.parse import parse_qs, urlencode

import httpx
from enochecker3 import MumbleException
from enochecker3.utils import assert_equals, assert_in, caller_loc

from client import Client
from noise import printable_noise


def re_escape(s: str) -> str:
    """Escape string to be literal in Regex."""
    return s.translate({ord(c): rf"\{c}" for c in r"^$.*?+{|()\["})


SHORT_URL_PREFIX = "/u/"
SHORT_URL_ALPHABET = string.digits + string.ascii_lowercase[: 16 - len(string.digits)]
SHORT_URL_LENGTH = 64 // 4
SHORT_URL_REGEX = rf"{re_escape(SHORT_URL_PREFIX)}[{re_escape(SHORT_URL_ALPHABET)}]{{{SHORT_URL_LENGTH}}}\b"

PASTE_URL_PREFIX = "/p/"
PASTE_URL_REGEX = rf"{re_escape(PASTE_URL_PREFIX)}[0-9a-f]{{56}}\b"


def assert_not_in[T](o1: T, o2: Collection[T], message: str) -> None:
    """Assert that o1 is not in collection o2."""
    if o2 and o1 in o2:
        raise MumbleException(
            message,
            log_message=f"Assertion (assert_not_in) failed! ({caller_loc()})"
            f"\n  Needle: ({type(o1)}) {o1}\n  Haystack: ({type(o2)}) {o2}",
        )


def assert_status(res: httpx.Response, status_code: int) -> None:
    """Assert that response has status code status_code."""
    assert_equals(res.status_code, status_code, "Unexpected HTTP status code")


async def _get_preferences(client: Client) -> None:
    if (
        client.last_response is None
        or client.last_response.request.method != "GET"
        or client.last_response.url.raw_path != b"/preferences"
    ):
        res = await client.get("/preferences")
        assert_status(res, 200)


async def register_user(client: Client, username: str) -> None:
    """Register a user with username."""
    await _get_preferences(client)

    res = await client.post(
        "/user_account",
        data={"username": username, "password": printable_noise(128)},
    )
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")
    assert_in("user_account", res.cookies, "No user_account cookie")
    cookie = parse_qs(res.cookies["user_account"])
    assert_in("username", cookie, "No username in cookie")
    assert_equals(len(cookie["username"]), 1, "Too many username in cookie")
    assert_equals(cookie["username"][0], username, "Unexpected username in cookie")
    assert_in("hmac", cookie, "No hmac in cookie")
    assert_equals(len(cookie["hmac"]), 1, "Too many hmac in cookie")
    if not re.fullmatch("[0-9a-f]{56}", cookie["hmac"][0]):
        raise MumbleException("Unexpected hmac in cookie")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(f'value="{username}"', unescape(res.text), "Unexpected form value")


async def set_safe_search(client: Client, enabled: bool, regex: str) -> None:
    """Set safe search preferences."""
    await _get_preferences(client)

    res = await client.post(
        "/safe_search",
        data={**({"enabled": "on"} if enabled else {}), "regex": regex},
    )
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")
    assert_in("safe_search", res.cookies, "No safe_search cookie")
    cookie = parse_qs(res.cookies["safe_search"])
    if enabled:
        assert_in("enabled", cookie, "No enabled in cookie")
        assert_equals(cookie["enabled"], ["on"], "Unexpected enabled in cookie")
    else:
        assert_not_in("enabled", cookie, "Unexpected enabled in cookie")
    assert_in("regex", cookie, "No regex in cookie")
    assert_equals(cookie["regex"], [regex], "Unexpected regex in cookie")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(f'value="{regex}"', unescape(res.text), "Unexpected form value")


async def get_search_console(client: Client) -> httpx.Response:
    """Perform a GET request to /console or return cached data."""
    if (
        client.last_response is None
        or client.last_response.request.method != "GET"
        or client.last_response.url.raw_path != b"/console"
    ):
        res = await client.get("/console")
        assert_status(res, 200)
    assert client.last_response is not None
    return client.last_response


async def submit_page(client: Client, public: bool, url: str) -> None:
    """Submit a page."""
    await get_search_console(client)

    res = await client.post(
        "/submit_page",
        data={**({"public": "on"} if public else {}), "url": url.removeprefix("http://")},
    )
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")

    while True:
        res = await client.send(res.next_request)
        if res.status_code == 200:
            assert_in(url, unescape(res.text), "Submitted URL not queue")
            await asyncio.sleep(0.1)
            res.next_request = res.request
        elif res.status_code == 302:
            if res.next_request is None:
                raise MumbleException("No redirect location")
            break
        else:
            raise MumbleException("Unexpected HTTP status code")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(url, unescape(res.text), "Submitted URL not in table")


async def shorten_url(client: Client, url: str) -> str:
    """Shorten a URL returning short URL."""
    await get_search_console(client)

    res = await client.post("/shorten_url", data={"url": url.removeprefix("http://")})
    assert_status(res, 200)
    short_url = re.search(SHORT_URL_REGEX, unescape(res.text))
    if not short_url:
        raise MumbleException("Failed to find short URL")

    return short_url[0]


async def verify_netloc(client: Client, netloc: str, api_key: str) -> str:
    """Verify a netloc."""
    await get_search_console(client)

    res = await client.post("/verify_netloc", data={"netloc": netloc, "api_key": api_key})
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(netloc, unescape(res.text), "Netloc not in table")
    assert_in(api_key, unescape(res.text), "Netlocs API key not in table")
    netloc_hash = re.search('value="([0-9a-f]{56})"', unescape(res.text))
    if not netloc_hash:
        raise MumbleException("Failed to find netloc hash")

    return netloc_hash[1]


async def token(client: Client, netloc_hash: str, token: str) -> str:
    """Provide token to complete verification of netloc."""
    await get_search_console(client)

    res = await client.post("/token", data={"hash": netloc_hash, "token": token})
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_not_in(netloc_hash, unescape(res.text), "Netloc not verified")

    return res.text


async def paste(client: Client, title: str, text: str) -> httpx.URL:
    """Submit text to pastebin returning paste url."""
    if (
        client.last_response is None
        or client.last_response.request.method != "GET"
        or client.last_response.url.raw_path != b"/pastebin"
    ):
        res = await client.get("/pastebin")
        assert_status(res, 200)

    res = await client.post("/pastebin", data={"title": title, "text": text})
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")
    if not re.fullmatch(PASTE_URL_REGEX, res.next_request.url.raw_path.decode()):
        raise MumbleException("Unexpected paste URL format")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(text, unescape(res.text), "Missing text in pastebin result")

    return res.request.url


async def search(client: Client, q: str) -> str:
    """Search for search query q returning the response text."""
    if (
        client.last_response is None
        or client.last_response.request.method != "GET"
        or client.last_response.url.raw_path != b"/"
    ):
        res = await client.get("/")
        assert_status(res, 200)
        assert_in("Greple Search", unescape(res.text), "Missing search button")
        assert_in('src="/logo.gif"', unescape(res.text), "Missing logo")

    query = urlencode({"q": q})
    res = await client.get(f"/search?{query}")
    assert_status(res, 200)
    assert_in(f'value="{q}"', unescape(res.text), "Unexpected form value")
    if not re.search(r"\b[0-9]\.[0-9]{2}\b", unescape(res.text)):
        raise MumbleException("Missing query timing information")
    if not re.search(r'title="(\d+(?:\.\d+)?) ms"', unescape(res.text)):
        raise MumbleException("Missing detailed query timing information")
    if not re.search(r"of( about)? <b>(0|[1-9][0-9]*)</b>\.", unescape(res.text)):
        raise MumbleException("Missing result count number")

    return res.text


async def get_short_url(client: Client, short_url: str) -> str:
    """Get long/redirect URL from short URL returning long URL."""
    res = await client.get(short_url)
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    assert_in("Location", res.headers, "No Location header")
    return res.headers["Location"]


async def logger(client: Client, path: str) -> str:
    """Get recent request from logger."""
    assert client.base_url.port is not None
    res = await client.get(client.base_url.copy_with(port=client.base_url.port + 1, path=f"{path}.logs"))
    assert_status(res, 200)
    return res.text


async def find_token(client: Client, username: str) -> str:
    """Find verify token in logger logs."""
    while True:
        logs = await logger(client, "/verify")
        t = re.search(
            f"x-verify-username: {re.escape(username)}\nx-verify-token: ([0-9a-f]{{56}})",
            unescape(logs),
        )
        if t:
            return t[1]
        await asyncio.sleep(0.1)

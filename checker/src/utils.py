"""Utils for the checker."""

import hashlib
import re
import string
from collections.abc import Collection
from html import escape
from typing import Any
from urllib.parse import parse_qs, quote, urlencode

import httpx
from enochecker3 import MumbleException
from enochecker3.utils import assert_equals, assert_in, caller_loc

from client import Client
from noise import printable_noise, word_noise


def re_escape(s: str) -> str:
    """Escape string to be literal in Regex."""
    return s.translate({ord(c): rf"\{c}" for c in r"^$.*?+{|()\["})


FLAG_URL_IPV4 = "1.1.1.1"
FLAG_URL_PORT = 80

SHORT_URL_PREFIX = "/u/"
SHORT_URL_ALPHABET = string.digits + string.ascii_lowercase[: 16 - len(string.digits)]
SHORT_URL_LENGTH = 64 // 4
SHORT_URL_REGEX = rf"{re_escape(SHORT_URL_PREFIX)}[{re_escape(SHORT_URL_ALPHABET)}]{{{SHORT_URL_LENGTH}}}\b"


def assert_not_in(o1: Any, o2: Collection, message: str) -> None:
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
        client.last_request is None
        or client.last_request.method != "GET"
        or client.last_request.url.raw_path != b"/preferences"
    ):
        res = await client.get("/preferences")
        assert_status(res, 200)


async def register_user(client: Client, username: str) -> None:
    """Register a user with username."""
    await _get_preferences(client)

    res = await client.post(
        "/preferences",
        data={
            "username": username,
            "password": printable_noise(2**7),
            "form_user_account": "Login",
        },
    )
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")
    assert_in("user_account", res.cookies, "No user_account cookie")
    cookie = parse_qs(res.cookies["user_account"])
    assert_in("username", cookie, "No username in cookie")
    assert_equals(cookie["username"], [username], "Unexpected username in cookie")
    assert_in("hmac", cookie, "No hmac in cookie")
    assert_equals(len(cookie["hmac"]), 1, "Unexpected hmac in cookie")
    if not re.fullmatch("[0-9a-f]{56}", cookie["hmac"][0]):
        raise MumbleException("Unexpected hmac in cookie")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(f'value="{escape(username)}"', res.text, "Unexpected form value")


async def set_safe_search(client: Client, enabled: bool, regex: str) -> None:
    """Set safe search preferences."""
    await _get_preferences(client)

    res = await client.post(
        "/preferences",
        data={
            **({"enabled": "on"} if enabled else {}),
            "regex": regex,
            "form_safe_search": "Save",
        },
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
    assert_equals(cookie["regex"], [quote(regex)], "Unexpected regex in cookie")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(f'value="{escape(regex)}"', res.text, "Unexpected form value")


async def _get_console(client: Client) -> None:
    if (
        client.last_request is None
        or client.last_request.method != "GET"
        or client.last_request.url.raw_path != b"/console"
    ):
        res = await client.get("/console")
        assert_status(res, 200)


async def register_domain(client: Client, domain: str) -> None:
    """Register a domain."""
    await _get_console(client)

    res = await client.post(
        "/console",
        data={
            "domain": domain,
            "ipv4": "127.0.0.1",
            "port": 7777,
            "form_register_domain": "Register",
        },
    )
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(escape(domain), res.text, "Missing registered domain")


async def submit_page(client: Client, public: bool, domain: str, path: str) -> None:
    """Submit a page."""
    await _get_console(client)

    res = await client.post(
        "/console",
        data={
            **({"public": "on"} if public else {}),
            "domain": hashlib.sha224(domain.encode()).hexdigest(),
            "path": path,
            "form_submit_page": "Submit",
        },
    )
    assert_status(res, 200)
    assert_in("page has been submitted", res.text, "Unexpected result text")


async def shorten_url(client: Client, domain: str, path: str) -> str:
    """Shorten a URL returning short URL."""
    await _get_console(client)

    res = await client.post(
        "/console",
        data={
            "domain": hashlib.sha224(domain.encode()).hexdigest(),
            "path": path,
            "form_shorten_url": "Shorten",
        },
    )
    assert_status(res, 200)
    short_url = re.search(SHORT_URL_REGEX, res.text)
    if not short_url:
        raise MumbleException(f"Failed to find short URL")

    return short_url[0]


async def paste(client: Client, text: str) -> httpx.URL:
    """Submit text to pastebin returning paste url."""
    if (
        client.last_request is None
        or client.last_request.method != "GET"
        or client.last_request.url.raw_path != b"/pastebin"
    ):
        res = await client.get("/pastebin")
        assert_status(res, 200)

    res = await client.post("/pastebin", data={"title": word_noise(2**7), "text": text})
    assert_status(res, 302)
    if res.next_request is None:
        raise MumbleException("No redirect location")

    res = await client.send(res.next_request)
    assert_status(res, 200)
    assert_in(escape(text), res.text, "Missing text in pastebin result")

    return res.request.url


async def search(client: Client, q: str) -> str:
    """Search for search query q returning the response text."""
    if client.last_request is None or client.last_request.method != "GET" or client.last_request.url.raw_path != b"/":
        res = await client.get("/")
        assert_status(res, 200)
        assert_in("Greple Search", res.text, "Missing search button")
        assert_in('src="/static/logo.gif"', res.text, "Missing logo")

    query = urlencode({"q": q, "btnG": "Greple Search"})
    res = await client.get(f"/search?{query}")
    assert_status(res, 200)
    assert_in(f'value="{escape(q)}"', res.text, "Unexpected form value")
    if not re.search(r"\b[0-9]\.[0-9]{3}\b", res.text):
        raise MumbleException("Missing query timing information")
    if not re.search(r"of( about)? <b>(0|[1-9][0-9]*)</b>\.", res.text):
        raise MumbleException("Missing result count number")

    return res.text


async def get_short_url(client: Client, short_url: str) -> str:
    """Get long/redirect URL from short URL returning long URL."""
    res = await client.get(short_url)
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    assert_in("Location", res.headers, "No Location header")

    return res.headers["Location"]

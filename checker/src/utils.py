"""Utils for the checker."""

import hashlib
import json
import math
import pathlib
import random
import re
import string
from collections.abc import Collection, Sequence
from html import escape
from typing import Any
from urllib.parse import parse_qs, quote, urlencode

import httpx
from enochecker3 import MumbleException
from enochecker3.utils import assert_equals, assert_in, caller_loc


def re_escape(s: str) -> str:
    """Escape string to be literal in Regex."""
    return s.translate({ord(c): rf"\{c}" for c in r"^$.*?+{|()\["})


with (pathlib.Path.cwd() / "words.json").open() as f:
    _WORDS: list[str] = [x for x in json.load(f) if x.isascii() and x.isalpha() and x.islower()]

FLAG_URL_IPV4 = "1.1.1.1"
FLAG_URL_PORT = 80

SHORT_URL_PREFIX = "/u/"
SHORT_URL_ALPHABET = string.digits + string.ascii_lowercase[: 16 - len(string.digits)]
SHORT_URL_LENGTH = 64 // 4
SHORT_URL_REGEX = rf"{re_escape(SHORT_URL_PREFIX)}[{re_escape(SHORT_URL_ALPHABET)}]{{{SHORT_URL_LENGTH}}}\b"


def assert_not_in(o1: Any, o2: Collection, message: str | None = None) -> None:
    """Assert that o1 is not in collection o2."""
    if o2 and o1 in o2:
        raise MumbleException(
            message or "Checker assertion failed",
            log_message=f"Assertion (assert_not_in) failed! ({caller_loc()})"
            + f"\n  Needle: ({type(o1)}) {o1}\n  Haystack: ({type(o2)}) {o2}",
        )


def _noise(alphabet: Sequence[str], sep: str, entropy: int) -> str:
    n = math.ceil(entropy / math.log2(len(alphabet)))
    return sep.join(random.choice(alphabet) for _ in range(n))


def printable_noise(entropy: int) -> str:
    """Generate noise consisting of printable ASCII."""
    return _noise(string.printable, "", entropy)


def lower_noise(entropy: int) -> str:
    """Generate noise consisting of lowercase ASCII letters."""
    return _noise(string.ascii_lowercase, "", entropy)


def alnum_noise(entropy: int) -> str:
    """Generate noise consisting of ASCII letter and digits."""
    return _noise(string.ascii_letters + string.digits, "", entropy)


def word_noise(entropy: int) -> str:
    """Generate noise consisting of space separated ASCII lowercase letter words."""
    return _noise(_WORDS, " ", entropy)


async def register_user(client: httpx.AsyncClient, username: str) -> None:
    """Register a user with username."""
    res = await client.get("/preferences")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/preferences",
        data={
            "username": username,
            "password": printable_noise(2**7),
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


async def set_safe_search(client: httpx.AsyncClient, enabled: bool, regex: str) -> None:
    """Set safe search preferences."""
    res = await client.get("/preferences")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/preferences",
        data={
            **({"enabled": "on"} if enabled else {}),
            "regex": regex,
            "form_safe_search": "Save",
        },
    )
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    if res.next_request is None:
        raise MumbleException("No redirect")
    assert_in("safe_search", res.cookies, "No safe_search cookie")
    cookie = parse_qs(res.cookies["safe_search"])
    if enabled:
        assert_in("enabled", cookie, "No enabled in cookie")
        assert_equals(cookie["enabled"], ["on"], "Unexpected enabled in cookie")
    assert_in("regex", cookie, "No regex in cookie")
    assert_equals(cookie["regex"], [quote(regex)], "Unexpected regex in cookie")

    res = await client.send(res.next_request)
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in(f'value="{escape(regex)}"', res.text, "Unexpected form value")


async def register_domain(client: httpx.AsyncClient, domain: str) -> None:
    """Register a domain."""
    res = await client.get("/console")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/console",
        data={
            "domain": domain,
            "ipv4": FLAG_URL_IPV4,
            "port": FLAG_URL_PORT,
            "form_register_domain": "Register",
        },
    )
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    if res.next_request is None:
        raise MumbleException("No redirect")

    res = await client.send(res.next_request)
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in(escape(domain), res.text, "Unexpected table value")


async def submit_page(client: httpx.AsyncClient, public: bool, domain: str, text: str) -> None:
    """Submit a page."""
    res = await client.get("/console")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    res = await client.post(
        "/console",
        data={
            **({"public": "on"} if public else {}),
            "domain": hashlib.sha224(domain.encode()).hexdigest(),
            "path": "/",
            "title": word_noise(2**4),
            "text": text,
            "form_submit_page": "Submit",
        },
    )
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in("page has been submitted", res.text, "Unexpected form value")


async def shorten_url(client: httpx.AsyncClient, domain: str, path: str) -> str:
    """Shorten a URL returning short URL."""
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

    short_url = re.search(SHORT_URL_REGEX, res.text)
    if not short_url:
        raise MumbleException("Failed to find short URL")

    return short_url[0]


# TODO: more checks
# TODO: add checks for result number and timing output
async def search(client: httpx.AsyncClient, q: str) -> str:
    """Search for search query q returning the response text."""
    res = await client.get("/")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")

    query = urlencode({"q": q, "btnG": "Greple Search"})
    res = await client.get(f"/search?{query}")
    assert_equals(res.status_code, 200, "Unexpected HTTP status")
    assert_in(f'value="{escape(q)}"', res.text, "Unexpected form value")

    return res.text


async def get_short_url(client: httpx.AsyncClient, short_url: str) -> str:
    """Get long/redirect URL from short URL returning long URL."""
    res = await client.get(short_url)
    assert_equals(res.status_code, 302, "Unexpected HTTP status")
    try:
        return res.headers["Location"]
    except KeyError as e:
        raise MumbleException("Failed to get Location header") from e

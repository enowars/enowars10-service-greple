"""Helpers to generate noise."""

import json
import math
import pathlib
import random
import string
from collections.abc import Sequence

with (pathlib.Path.cwd() / "words.json").open() as f:
    _WORDS: list[str] = [x for x in json.load(f) if x.isascii() and x.isalpha() and x.islower()]


def _noise(alphabet: Sequence[str], sep: str, entropy: int) -> str:
    n = math.ceil(entropy / math.log2(len(alphabet)))
    return sep.join(random.choice(alphabet) for _ in range(n))


def printable_noise(entropy: int) -> str:
    """Generate noise consisting of printable ASCII."""
    return _noise(string.printable, "", entropy)


def alnum_noise(entropy: int) -> str:
    """Generate noise consisting of ASCII letter and digits."""
    return _noise(string.ascii_letters + string.digits, "", entropy)


def word_noise(entropy: int) -> str:
    """Generate noise consisting of space separated ASCII lowercase letter words."""
    return _noise(_WORDS, " ", entropy)

"""Helpers to generate noise."""

import json
import math
import pathlib
import random
import string
from collections.abc import Sequence

with (pathlib.Path.cwd() / "words.json").open() as f:
    _WORDS: dict[str, dict[str, int]] = json.load(f)


def _noise(alphabet: Sequence[str], sep: str, entropy: int) -> str:
    n = math.ceil(entropy / math.log2(len(alphabet)))
    return sep.join(random.choice(alphabet) for _ in range(n))


def printable_noise(entropy: int) -> str:
    """Generate noise consisting of printable ASCII."""
    return _noise(string.printable, "", entropy)


def username_noise(entropy: int) -> str:
    """Generate noise that can be used as a valid username."""
    return _noise(string.ascii_letters + string.digits + "_+-=", "", entropy)


def word_noise(entropy: int) -> str:
    """Generate noise consisting of space separated ASCII lowercase letter words."""
    e = 0.0
    words: list[str] = []
    while e < entropy:
        distribution = _WORDS.get(words[-1] if words else "null", _WORDS["null"])
        population = list(distribution)
        weights = [distribution[x] for x in population]
        word = random.choices(population, weights)[0]
        words.append(word)
        e -= math.log2(distribution[word] / sum(weights))
    return " ".join(words)

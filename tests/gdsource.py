"""Reading GDScript as text, for the tests that assert on structure.

These tests exist because the mod cannot be executed outside the game: there is
no way to run a session in CI, so the checks that survive are the ones that can
be made against the source. That is a real limitation, not a preference —
anything asserted here is a shape, never a behaviour.

Every test file used to carry its own copy of `func()`, and every copy had the
same bug: slicing to the next `\\nfunc ` throws when the function is the last one
in the file.
"""

from pathlib import Path

MOD = Path(__file__).resolve().parents[1] / "mods" / "RTVCoopAlpha"


def read(rel: str) -> str:
    """Source of one mod script, by path relative to `mods/RTVCoopAlpha/`."""
    return (MOD / rel).read_text(encoding="utf-8")


def func(src: str, name: str) -> str:
    """The body of `func <name>(`, up to the next top-level `func` or EOF."""
    start = src.index(f"func {name}(")
    nxt = src.find("\nfunc ", start + 1)
    return src[start:] if nxt == -1 else src[start:nxt]


def sources():
    """(relative path, source) for every .gd in the mod."""
    for path in sorted(MOD.rglob("*.gd")):
        yield path.relative_to(MOD).as_posix(), path.read_text(encoding="utf-8")

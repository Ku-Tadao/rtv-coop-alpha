"""Parse every mod script with the real Godot, against the real game pack.

This is the only check here that knows what GDScript actually is. `build.py`
reads the sources as text and `lint_rpc.py` reads them as patterns; neither can
tell whether the engine will accept them. Godot rejects an entire script on a
parse error and says nothing at the point of use, which is how "remote players
are invisible but still collide" shipped once — one tab in a space-indented
file.

Requires Godot 4.6.x on PATH and the game installed; skipped automatically when
either is missing, because most work on this repo does not need either.

    python tools/parsecheck.py
    python tools/parsecheck.py --godot /path/to/godot --pck /path/to/RTV.pck

The game's autoloads are registered from project settings this tool project does
not have, so scripts using them report `Identifier "Loader" not declared`. Those
are filtered. Anything else is a real failure.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "tools" / "rig-inspect"
DEFAULT_PCK = Path("D:/SteamLibrary/steamapps/common/Road to Vostok/RTV.pck")

# Names the game registers as autoloads. Unresolvable here by construction, and
# an unknown name in this shape is still a real error worth seeing.
GAME_AUTOLOADS = {
    "Loader", "Database", "Simulation", "Interface", "Settings",
    "Audio", "Input_Manager", "Save", "Debug",
}

MARKER = re.compile(r"^### (.+)$")
PARSE_ERROR = re.compile(r"^SCRIPT ERROR: Parse Error: (.+)$")
UNDECLARED = re.compile(r'^Identifier "(\w+)" not declared in the current scope\.$')


def classify(output: str) -> tuple[dict, list]:
    """-> ({script: [real errors]}, [scripts that failed])"""
    current = "<preamble>"
    real: dict = {}
    failed: list = []
    for line in output.splitlines():
        m = MARKER.match(line)
        if m:
            current = m.group(1)
            continue
        if line.startswith("!!! "):
            failed.append(current)
            continue
        m = PARSE_ERROR.match(line)
        if not m:
            continue
        detail = m.group(1).strip()
        u = UNDECLARED.match(detail)
        if u and u.group(1) in GAME_AUTOLOADS:
            continue  # expected: the game registers this, we cannot
        real.setdefault(current, []).append(detail)
    return real, failed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", default=shutil.which("godot"))
    ap.add_argument("--pck", type=Path, default=DEFAULT_PCK)
    ap.add_argument("--vmz", type=Path, help="defaults to the newest in dist/")
    args = ap.parse_args()

    if not args.godot:
        print("skip: godot not on PATH")
        return 0
    if not args.pck.is_file():
        print(f"skip: game pack not found at {args.pck}")
        return 0

    vmz = args.vmz
    if vmz is None:
        built = sorted((ROOT / "dist").glob("*.vmz"), key=lambda p: p.stat().st_mtime)
        if not built:
            print("skip: no .vmz in dist/ — run tools/build.py first")
            return 0
        vmz = built[-1]

    # load_resource_pack dispatches on the extension, and .vmz is not one it knows.
    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / "mod.zip"
        staged.write_bytes(vmz.read_bytes())
        proc = subprocess.run(
            [args.godot, "--headless", "--path", str(PROJECT),
             "--script", "res://parsecheck.gd", "--", str(staged)],
            # Merged, not captured separately: markers go to stdout and parse
            # errors to stderr, and attribution depends on their real order.
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300,
        )

    output = proc.stdout
    if "### done" not in output:
        print("parse check did not complete:", file=sys.stderr)
        print(output[-2000:], file=sys.stderr)
        return 2

    real, failed = classify(output)
    checked = output.count("### ") - 1
    expected_only = [f for f in failed if f not in real]

    for script, errors in sorted(real.items()):
        for err in errors:
            print(f"ERROR: {script}: {err}")

    print(
        f"parsed {checked} script(s) against {vmz.name}: "
        f"{len(real)} with real errors, "
        f"{len(expected_only)} unresolved only by missing game autoloads"
    )
    return 1 if real else 0


if __name__ == "__main__":
    sys.exit(main())

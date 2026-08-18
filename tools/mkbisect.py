#!/usr/bin/env python3
"""Build the crash-bisect ladder described in docs/CRASH-BISECT.md.

Every arm is the current `dev` tree; arms differ only in which of the three
suspect scripts is taken from the crashing v4 build instead. Arm 0 is the
control -- our own fixes with none of the suspects -- and must be established
before any result above it means anything.

    python tools/mkbisect.py                    # -> dist/bisect/RTVCoopAlpha-arm{0,A,B,C}.vmz
    python tools/mkbisect.py --out-dir some/dir
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

import build  # same directory; reuse its validation and archive layout

ROOT = build.ROOT
V4 = Path(__file__).resolve().parent / "bisect" / "v4"
PREFIX = "mods/RTVCoopAlpha/"

LSS = "Game/Sync/LocalStateSync.gd"
PROXY = "Framework/PlayerStateProxy.gd"
MODEL = "Game/Types/PlayerModel.gd"

# Cumulative: each arm adds one suspect to the one below it.
ARMS = {"0": [], "A": [LSS], "B": [LSS, PROXY], "C": [LSS, PROXY, MODEL]}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=ROOT / "dist" / "bisect")
    args = parser.parse_args(argv)

    problems = build.validate()
    for member in {m for members in ARMS.values() for m in members}:
        path = V4 / member
        if not path.is_file():
            problems.append(f"missing suspect source: {path}")
            continue
        problems.extend(build.check_indentation(path, path.read_text(encoding="utf-8")))
    if problems:
        print(f"validation failed ({len(problems)} problem(s)):", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    args.out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        base = build.build(Path(tmp) / "base.vmz")
        for arm, members in ARMS.items():
            out = args.out_dir / f"RTVCoopAlpha-arm{arm}.vmz"
            if not members:
                shutil.copyfile(base, out)
            else:
                picks = {PREFIX + m: (V4 / m).read_bytes() for m in members}
                with zipfile.ZipFile(base) as zin, \
                     zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
                    missing = picks.keys() - set(zin.namelist())
                    assert not missing, f"not in archive: {sorted(missing)}"
                    for info in zin.infolist():
                        zout.writestr(info, picks.get(info.filename) or zin.read(info.filename))
            print(f"arm {arm}: {out.name} ({out.stat().st_size:,} bytes)"
                  f"{' + ' + ', '.join(members) if members else '  <- control'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Package the mod source tree into a drag-and-drop .vmz archive.

A .vmz is a plain zip. The game's modloader mounts it and expects `mod.txt` at
the archive root, with every script under `mods/<mod id>/`. So the repo is laid
out exactly the way the archive is, and building is mostly zipping -- the value
here is the validation that runs first.

    python tools/build.py                 # -> dist/RTVCoopAlpha-<version>.vmz
    python tools/build.py --check         # validate only, write nothing
    python tools/build.py --out some.vmz  # explicit output path
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lint_rpc  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "mod.txt"

# Zip entries carry a timestamp. Pin it so the same source always produces a
# byte-identical archive and CI artifacts can be compared across runs.
FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


class BuildError(Exception):
    pass


def parse_manifest(text: str) -> dict[str, dict[str, str]]:
    """Minimal INI-ish reader for mod.txt (keys may be quoted or bare)."""
    sections: dict[str, dict[str, str]] = {}
    current: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith((";", "#")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = sections.setdefault(line[1:-1], {})
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        current[key.strip().strip('"')] = value.strip().strip('"')
    return sections


def source_files() -> list[Path]:
    """Every file that belongs in the archive, in a stable order."""
    files = [MANIFEST]
    files += sorted((ROOT / "mods").rglob("*"))
    return [f for f in files if f.is_file()]


def check_indentation(path: Path, text: str) -> list[str]:
    """Godot refuses to load a script that mixes tab and space indentation.

    It fails the whole file, not the offending line, so a single stray tab in a
    space-indented script silently removes that script at runtime. This has
    already cost one broken release -- keep the check.
    """
    lines = [l for l in text.splitlines() if l.strip()]
    tabs = sorted(i for i, l in enumerate(lines, 1) if l.startswith("\t"))
    spaces = sorted(i for i, l in enumerate(lines, 1) if l.startswith(" "))
    if tabs and spaces:
        style, odd = ("tabs", spaces) if len(tabs) > len(spaces) else ("spaces", tabs)
        return [
            f"{path.relative_to(ROOT).as_posix()}: mixed indentation "
            f"(file is {style}-indented; see line(s) {odd[:5]})"
        ]
    return []


def validate() -> list[str]:
    problems: list[str] = []

    # A mismatched RPC is this mod's worst failure mode: Godot does not check
    # arity across peers, so the symptom looks nothing like the cause.
    rpc_report = lint_rpc.lint(lint_rpc.load_sources())
    for err in rpc_report.errors:
        problems.append(f"{err.file}:{err.line}: {err.message}")

    if not MANIFEST.is_file():
        raise BuildError("mod.txt missing from repo root")

    manifest = parse_manifest(MANIFEST.read_text(encoding="utf-8"))
    if "mod" not in manifest:
        problems.append("mod.txt: no [mod] section")
    for key in ("name", "id", "version"):
        if not manifest.get("mod", {}).get(key):
            problems.append(f"mod.txt: [mod] {key} is missing")

    files = source_files()
    present = {f.relative_to(ROOT).as_posix() for f in files}

    for path in files:
        if path.stat().st_size == 0:
            problems.append(f"{path.relative_to(ROOT).as_posix()}: zero-byte file")
            continue
        if path.suffix == ".gd":
            problems.extend(check_indentation(path, path.read_text(encoding="utf-8")))

    def resolve(res_path: str) -> str | None:
        """res://mods/... -> repo-relative path. Vanilla res:// paths live in
        the game's own pck and are not ours to ship."""
        if not res_path.startswith("res://mods/"):
            return None
        return res_path[len("res://"):]

    # Autoload, and every mod-side script the manifest points at, must exist.
    referenced: list[tuple[str, str]] = []
    for section in ("autoload", "script_extend"):
        for key, value in manifest.get(section, {}).items():
            referenced.append((f"[{section}] {key}", value))

    for label, res_path in referenced:
        rel = resolve(res_path)
        if rel and rel not in present:
            problems.append(f"mod.txt {label}: points at missing file {res_path}")

    # Main.gd spawns its modules from hardcoded lists; a rename that misses one
    # only shows up as a runtime push_error, so catch it here instead.
    main = ROOT / "mods" / "RTVCoopAlpha" / "Main.gd"
    if main.is_file():
        for res_path in re.findall(r'"(res://mods/[^"]+\.gd)"', main.read_text(encoding="utf-8")):
            rel = resolve(res_path)
            if rel and rel not in present:
                problems.append(f"Main.gd: references missing script {res_path}")

    return problems


def build(out_path: Path) -> Path:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in source_files():
            # Directory entries are omitted to match the archives the game ships.
            info = zipfile.ZipInfo(path.relative_to(ROOT).as_posix(), FIXED_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            # Otherwise this records the building OS (0 Windows, 3 Unix), so the
            # same sources give different bytes on a developer machine and in CI.
            info.create_system = 0
            archive.writestr(info, path.read_bytes())
    return out_path


def content_digest(archive: Path | None = None) -> str:
    """Identity of what the archive *contains*, independent of how it was packed.

    Byte-identical archives were the original promise and cannot be kept: zlib
    builds differ between platforms, so CI's deflate output differs from a
    Windows machine's for the same input. The bytes that matter are the members,
    and this hashes exactly those -- so "did this actually change?" and "does the
    published release match this source tree?" both stay answerable.

    With no argument, digests the working tree; the two agree by construction.
    """
    h = hashlib.sha256()
    if archive is None:
        entries = [
            (p.relative_to(ROOT).as_posix(), p.read_bytes()) for p in source_files()
        ]
    else:
        with zipfile.ZipFile(archive) as zf:
            entries = [(n, zf.read(n)) for n in zf.namelist()]
    for name, data in sorted(entries):
        h.update(name.encode("utf-8"))
        h.update(b"\0")
        h.update(hashlib.sha256(data).digest())
    return h.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, help="output .vmz path")
    parser.add_argument("--check", action="store_true", help="validate only")
    parser.add_argument(
        "--digest", metavar="VMZ", type=Path, nargs="?", const=Path("-"),
        help="print the content digest of VMZ (or of the source tree) and exit",
    )
    args = parser.parse_args(argv)

    if args.digest is not None:
        target = None if str(args.digest) == "-" else args.digest
        print(content_digest(target))
        return 0

    try:
        problems = validate()
    except BuildError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if problems:
        print(f"validation failed ({len(problems)} problem(s)):", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    files = source_files()
    for warn in lint_rpc.lint(lint_rpc.load_sources()).warnings:
        print(f"warning: {warn.file}:{warn.line}: {warn.message}")
    print(f"validated {len(files)} file(s)")
    if args.check:
        return 0

    manifest = parse_manifest(MANIFEST.read_text(encoding="utf-8"))
    version = manifest["mod"]["version"]
    out = args.out or ROOT / "dist" / f"RTVCoopAlpha-{version}.vmz"
    build(out)
    print(f"built {out.relative_to(ROOT) if out.is_relative_to(ROOT) else out} "
          f"({out.stat().st_size:,} bytes, {len(files)} entries)")
    print(f"content digest {content_digest(out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Check every `@rpc` function against every call site.

A mismatched RPC is the worst failure mode this mod has. Godot does not check
arity across peers -- it drops or mangles the call, and the symptom looks
nothing like a version mismatch. The invisible-but-solid players bug was one of
these. So was `ApplySceneChange`, an RPC that existed for a year and was never
called by anything, which is why guests learned about scene changes six seconds
late.

Five things are checked:

  arity      every `.rpc(...)` / `.rpc_id(...)` passes a legal number of
             arguments for the function it names
  unknown    every `.rpc(...)` names a function that actually carries `@rpc`
  unused     every `@rpc` function is called from somewhere
  agreement  all call sites of one RPC pass the same number of arguments
  unchecked  every `@rpc("any_peer")` handler establishes who is calling

`agreement` is the one that catches real damage. Arity alone cannot: every
trailing parameter here has a default, so dropping one is legal GDScript and the
handler silently sees a default instead of the value the sender meant. What is
never legal is two call sites of the same RPC disagreeing -- that means one was
updated and the other was missed.

An RPC whose optional arguments are a deliberate two-mode API says so with a
`# lint-rpc: optional-args` comment above it. Opting out is one line in the one
place that knows the intent; the default stays strict.

`unchecked` is the systematic version of a bug that has been fixed twice here by
hand. An `any_peer` handler is reachable by any client; if it never consults
`is_server()` or `get_remote_sender_id()` it will act on whatever it is sent, by
whoever sends it.

`unused` is a warning, not an error: a handler can legitimately be called only
by the peer that never runs this code path. It still gets printed, because a
silently-uncalled RPC is a bug that hides for a very long time.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

MOD = Path(__file__).resolve().parents[1] / "mods" / "RTVCoopAlpha"

RPC_ANNOTATION = re.compile(r"^\s*@rpc\b(?:\s*\(([^)]*)\))?")
FUNC_DEF = re.compile(r"^\s*func\s+([A-Za-z_]\w*)\s*\(")
# `foo.Bar.rpc(`, `Bar.rpc_id(`, `self.Bar.rpc(` -- the name before .rpc is what matters.
CALL_SITE = re.compile(r"([A-Za-z_]\w*)\s*\.\s*(rpc|rpc_id)\s*\(")


@dataclass
class RpcFunc:
    name: str
    file: str
    line: int
    body: str
    min_args: int
    max_args: int
    modes: tuple = ()
    called: bool = False
    optional_ok: bool = False
    arg_counts: dict = field(default_factory=dict)


@dataclass
class Problem:
    file: str
    line: int
    message: str


@dataclass
class Report:
    errors: list = field(default_factory=list)
    warnings: list = field(default_factory=list)

    def ok(self) -> bool:
        return not self.errors


def _split_top_level(text: str) -> list[str]:
    """Split on commas that are not inside brackets, braces, parens or strings."""
    parts, depth, quote, current, i = [], 0, "", [], 0
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                current.append(text[i : i + 2])
                i += 2
                continue
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
            i += 1
            continue
        current.append(ch)
        i += 1
    tail = "".join(current).strip()
    if tail:
        parts.append(tail)
    return [p.strip() for p in parts if p.strip()]


def _read_call_args(src: str, open_paren: int) -> str | None:
    """Return the text between the parens starting at `open_paren`, or None if unbalanced."""
    depth, quote, i = 0, "", open_paren
    while i < len(src):
        ch = src[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return src[open_paren + 1 : i]
        i += 1
    return None


def _param_arity(params: str) -> tuple[int, int]:
    """(required, total) for a GDScript parameter list."""
    parts = _split_top_level(params)
    required = sum(1 for p in parts if "=" not in _strip_type(p))
    return required, len(parts)


def _strip_type(param: str) -> str:
    """`x: Dictionary = {}` -> `x = {}`; keeps `=` detection honest against `:=`."""
    if ":" in param:
        name, rest = param.split(":", 1)
        return name + ("=" if "=" in rest else "")
    return param


def collect_rpcs(files: dict) -> dict:
    rpcs: dict = {}
    for rel, src in files.items():
        lines = src.splitlines()
        for n, line in enumerate(lines):
            m = RPC_ANNOTATION.match(line)
            if not m:
                continue
            modes = tuple(
                x.strip().strip("\"'") for x in _split_top_level(m.group(1) or "")
            )
            preamble = "\n".join(lines[max(0, n - 6) : n])
            optional_ok = "lint-rpc: optional-args" in preamble
            # The annotation may sit a line or two above the func.
            for look in range(n + 1, min(n + 4, len(lines))):
                fm = FUNC_DEF.match(lines[look])
                if not fm:
                    continue
                params = _read_call_args(src, src.index(lines[look]) + lines[look].index("("))
                lo, hi = _param_arity(params or "")
                start = src.index(lines[look])
                nxt = src.find("\nfunc ", start + 1)
                body = src[start:] if nxt == -1 else src[start:nxt]
                rpcs[fm.group(1)] = RpcFunc(
                    fm.group(1), rel, look + 1, body, lo, hi, modes,
                    optional_ok=optional_ok,
                )
                break
    return rpcs


def lint(files: dict) -> Report:
    report = Report()
    rpcs = collect_rpcs(files)

    for rel, src in files.items():
        for m in CALL_SITE.finditer(src):
            name, kind = m.group(1), m.group(2)
            if name in ("rpc", "rpc_id"):
                continue
            line = src.count("\n", 0, m.start()) + 1
            target = rpcs.get(name)
            if target is None:
                # Not every `x.rpc(` is ours -- only flag names that look like a
                # declared RPC handler somewhere, i.e. capitalised or underscored
                # identifiers we simply do not know.
                report.errors.append(
                    Problem(rel, line, f"`{name}.{kind}(...)` names no @rpc function")
                )
                continue
            target.called = True
            args = _read_call_args(src, m.end() - 1)
            if args is None:
                report.errors.append(Problem(rel, line, f"unbalanced call to `{name}`"))
                continue
            count = len(_split_top_level(args))
            if kind == "rpc_id":
                count -= 1  # the peer id is not a parameter of the handler
            target.arg_counts.setdefault(count, []).append((rel, line))
            if not (target.min_args <= count <= target.max_args):
                expected = (
                    str(target.min_args)
                    if target.min_args == target.max_args
                    else f"{target.min_args}-{target.max_args}"
                )
                report.errors.append(
                    Problem(
                        rel,
                        line,
                        f"`{name}.{kind}(...)` passes {count} arg(s); "
                        f"{target.file}:{target.line} takes {expected}",
                    )
                )

    for name, r in sorted(rpcs.items()):
        if "any_peer" in r.modes and not (
            "is_server()" in r.body or "get_remote_sender_id()" in r.body
        ):
            report.errors.append(
                Problem(
                    r.file,
                    r.line,
                    f'@rpc("any_peer") `{name}` never checks who is calling',
                )
            )
        # Trailing defaults make a short call legal, so arity cannot catch a call
        # site that was missed when the signature grew. Disagreement can.
        if len(r.arg_counts) > 1 and not r.optional_ok:
            spread = "; ".join(
                f"{n} arg(s) at " + ", ".join(f"{f}:{l}" for f, l in sites)
                for n, sites in sorted(r.arg_counts.items())
            )
            report.errors.append(
                Problem(r.file, r.line, f"call sites of `{name}` disagree: {spread}")
            )
        if not r.called:
            report.warnings.append(
                Problem(r.file, r.line, f"@rpc `{name}` is never called")
            )
    return report


def load_sources(root: Path = MOD) -> dict:
    return {
        p.relative_to(root).as_posix(): p.read_text(encoding="utf-8")
        for p in sorted(root.rglob("*.gd"))
    }


def main() -> int:
    files = load_sources()
    report = lint(files)
    for w in report.warnings:
        print(f"warning: {w.file}:{w.line}: {w.message}")
    for e in report.errors:
        print(f"ERROR: {e.file}:{e.line}: {e.message}")
    rpc_count = len(collect_rpcs(files))
    print(
        f"checked {rpc_count} @rpc function(s) across {len(files)} file(s): "
        f"{len(report.errors)} error(s), {len(report.warnings)} warning(s)"
    )
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())

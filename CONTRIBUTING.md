# Contributing

## Setup

Nothing to install. Python 3.11+ is all the tooling there is.

```bash
python tools/build.py --check
python -m unittest discover -s tests
python tools/build.py
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing sync code.
The host/client authority split is not optional flavour — most bugs in this
codebase are a hook doing work on the wrong peer.

## Branches

`main` is the released build; `dev` is where work happens. Branch from `dev`,
PR back into `dev`, and merge to `main` when a build has been played on two
machines without new problems.

## The indentation rule

**Godot rejects an entire script that mixes tabs and spaces.** Not the line —
the file. The script then does not exist at runtime, and there is no error at
the point of use.

Files in this repo are not uniform: `Game/Types/PlayerModel.gd` is
space-indented, most others are tab-indented. **Match the file you are editing.**
An editor that helpfully normalizes indentation will silently break a script.

This has already shipped: one tab in `PlayerModel.gd` made remote players
invisible while still solid, because the puppet's collider and its visible model
are separate nodes with separate lifetimes. `tools/build.py` now fails the build
on it, and CI runs that check on every push — but a broken file is much cheaper
to not write.

## Conventions

- Match the surrounding style; the codebase is consistent within a file even
  where it varies across files.
- Guard multiplayer work with `CoopAuthority.is_active()`. `is_host()` returns
  **true** in singleplayer by design, so it is the wrong "am I networked" test.
- New sync module: implement `_sync_key()`, add it to `SYNC_SCRIPTS` in
  `Main.gd` and to `_preloads.gd`.
- New hook: subclass `BaseHook`, implement `_setup_hooks()`, add it to
  `HOOK_SCRIPTS`, `_preloads.gd`, and `mod.txt` under `[hooks]`. See
  [docs/HOOKS.md](docs/HOOKS.md#traps) for the ways this goes wrong.
- Anything that borrows shared `GameData` state must restore it on **every**
  path out, including early returns.
- Ids are host-assigned. A client must never invent one, and must never infer
  one by proximity — treat `id <= 0` as unresolved and fail closed.

## Testing changes

Automated checks cover packaging and a handful of regressions. They cannot tell
you whether co-op works; two machines can.

Before proposing a merge to `main`:

- host and client connect with no script errors in either log
- both players are **visible** to each other and animate (walk, sprint, crouch,
  aim, stop)
- firing shows muzzle flash and audio remotely, once per shot, including with
  the weapon you spawned holding
- switching, dropping, unequipping, and attaching to weapons updates remotely
- looting, doors, and furniture placement stay consistent across peers
- disconnect/reconnect, death/respawn, and a map change do not replay stale
  state
- a third player does not disturb the other two

Collect both peers' logs for anything that fails, and record who performed the
action and who observed it. A symptom one player sees is usually caused by the
other's state.

## Reporting a bug

Include:

- which `.vmz` every peer was running (the log names the mounted archive)
- both peers' `godot.log` and `coop_debug.log`
- who did what, and who saw the problem

If a log ends mid-line, that is a hard native crash and the cause is not in the
file. Say so, and see
[docs/BUILDING.md](docs/BUILDING.md#bisecting-a-crash).

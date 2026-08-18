# Open investigation: host hard-crash

**Status: unresolved.** This file is the working record so the next session does
not repeat the dead ends. The bisect ladder it originally described was
abandoned in favour of shipping one build with every fix plus instrumentation;
what is kept here is the evidence, not a workflow to follow.

## Symptom

The host process dies. Not a Godot error, not a GDScript exception — the log
stops **mid-line** and a new process starts seconds later. Observed twice:

- while the host was sprinting and another player was firing at an AI
- immediately after interacting with a dead AI body (`target_groups=["Item"]`)

## What the logs can and cannot tell us

Checked in the host's `godot.log` and `coop_debug.log` for the crash session:

- zero `ERROR` / `WARNING` / `SCRIPT ERROR` lines in the entire session
- the mod's own debug log is **315 lines for an 8-minute session** — no runaway
  loop, no repeated failure, nothing degrading
- no `.free()` anywhere in the mod (only `queue_free`), no recursion path, no
  unbounded allocation

Godot's crash handler writes to **stderr**, which the game's log file does not
capture, and the final buffered write is lost when the process dies hard. **The
cause is not in these logs.** An earlier attempt to read one out of them
produced a confident wrong answer; do not repeat it.

To get a real stack, see
[BUILDING.md](BUILDING.md#bisecting-a-crash) for enabling Windows local crash
dumps.

## Search space

The crashing builds differ from the released `1.0.0` in exactly four files.
`1.0.0` does not crash.

| File | First changed in | Ruled out? |
|---|---|---|
| `Game/Sync/LocalStateSync.gd` | v1 | no |
| `Framework/PlayerStateProxy.gd` | v1 | no |
| `Game/Types/PlayerModel.gd` | v1 | **the node-leak theory, yes** |
| `Game/Hooks/AIHooks.gd` | v4 | **yes** |

`AIHooks.gd` is excluded by evidence: the first crash happened on the v3 build
(`[FileScope] MOUNTED ... RTVCoopAlpha-improved-v3.vmz`), and v3 does not touch
that file. A fix that landed there was aimed at the wrong target.

## Ruled out: the muzzle node leak

**This was suspect #1 for a long time and the mechanism does not exist.**

The theory: `PlayPuppetFireEffect` gained a path that never ran in `1.0.0`, and
it adds two nodes to the weapon's `Muzzle` on every remote shot —

```gdscript
muzzleNode.add_child(flash)
muzzleNode.add_child(audio)
```

— while `SwapWeapon` only frees children of `aiInstance.weapons`, a different
node. A player who never switched weapons would accumulate two nodes per shot
forever, which fits "crashed while a player was shooting" and would have been a
textbook exhaustion crash.

Tested directly against the game's own assets in headless Godot 4.6.2 — ten
shots at ten-frame intervals, 900 frames, watching the parent's child count:

```
shot 10 -> muzzle children=1
FINAL after 10 shots and 900 frames: children=0
```

Both nodes free themselves. `Resources/AudioInstance3D.tscn` does it from its
own `_process`; `Effects/Muzzle_Flash.tscn` does it from a
`get_tree().create_timer()` inside `Emit()` — which is why `Emit` has to be
called with the node already in the tree, and in `PlayPuppetFireEffect` it is.

Two consequences worth carrying forward:

- **`PlayerModel.gd` is no longer the leading suspect.** It may still be
  involved by another mechanism, but not this one.
- **A flat node count in the heartbeat is now a positive result.** It was
  previously ambiguous — "nothing is leaking" and "the leak is elsewhere" looked
  the same. If the counters are flat right up to the crash, exhaustion is out
  and the answer is in the dump.

The check is cheap to re-run and the tooling for it is
[tools/rig-inspect](../tools/rig-inspect) — mount `RTV.pck`, instantiate the
real scene, count children over time. Prefer that to reasoning about what a
vanilla script probably does.

## Remaining suspects

**1. `PlayerStateProxy.gd`.** `_apply_broadcast` changed from
`if weapon_file != "": sync_weapon_file = weapon_file` to unconditional
assignment. Empty values in an unreliable 20 Hz packet flip the puppet's weapon
off and back on, so `SwapWeapon` runs `scene.instantiate()` + `queue_free()`
repeatedly instead of once. The mod logs weapon transitions, so a session log
says whether this is actually churning — check that before theorising.

**2. `LocalStateSync.gd`.** Mostly animation blend values, plus a shot cap that
does *less* work than `1.0.0` did. Contains the sprint-animation fix, which is
confirmed working.

**3. The transport.** Every observed crash was over `SteamMultiplayerPeer`.
A hard native crash with no Godot stack is exactly what a GDExtension fault
looks like, and GodotSteam is the GDExtension in play. Local two-instance
testing runs over ENet and therefore cannot reproduce it — see
[BUILDING.md](BUILDING.md#what-local-testing-can-and-cannot-prove).

## What the next crash session needs

Instrumentation is already in the shipped build: a heartbeat every 15 s with
node / object / orphan / memory counters, muzzle child counts sampled every 25th
shot, weapon swaps, weapon-file transitions, and AI death payload sizes.

What is still missing is a stack. Before the next session, enable Windows local
crash dumps (admin shell; the executable is `RTV.exe`):

```
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\RTV.exe" /v DumpFolder /t REG_EXPAND_SZ /d "%LOCALAPPDATA%\CrashDumps" /f /reg:64
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\RTV.exe" /v DumpType /t REG_DWORD /d 2 /f /reg:64
```

Or launch once with stderr redirected:

```
RTV.exe --verbose > console.txt 2>&1
```

## Dead ends already tried

- **The muzzle node leak.** See above — disproven by measurement, not argument.
- **RPC annotation hardening on `PlayerStateProxy`.** Changing the player-state
  RPC contract made remote players invisible while still solid. Reverted. (The
  hardening that landed later in 1.1.10 is a different change: it constrains
  *who may call*, not the payload contract.)
- **A tab in space-indented `PlayerModel.gd`.** Godot rejected the whole script,
  so the puppet's collider loaded and its model did not — same
  invisible-but-solid symptom, different cause. Confirmed from the runtime log
  (`Used tab character for indentation instead of space`). Now caught by
  `tools/build.py`.
- **`AIHooks.gd` post-hook registration.** Real bug (borrowed `GameData` flags
  are not always restored, which can leave aim blocked after sprinting) but
  **not the crash** — see the table above. Fixed on its own merits.
- **The bisect ladder.** Arms 0/A/B/C across the three suspect files. Abandoned:
  every arm that stays clean over ENet clears nothing, because the crash was
  only ever seen over Steam, and the asymmetry made the ladder cost sessions
  without producing answers.

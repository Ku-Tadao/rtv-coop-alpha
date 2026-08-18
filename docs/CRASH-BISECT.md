# Open investigation: host hard-crash

> **Superseded.** The bisect ladder described below was abandoned in favour of
> shipping one build with every fix and catching the crash with logs and a crash
> dump. `v1.1.0` carries all three former suspects plus instrumentation; see
> [HANDOFF.md](HANDOFF.md#5-current-approach). Kept for the evidence it records —
> what was ruled out and why — not as a workflow to follow.

**Status: unresolved, actively bisecting.** This file is the working record so
the next session does not repeat the dead ends.

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
| `Game/Types/PlayerModel.gd` | v1 | no |
| `Game/Hooks/AIHooks.gd` | v4 | **yes** |

`AIHooks.gd` is excluded by evidence: the first crash happened on the v3 build
(`[FileScope] MOUNTED ... RTVCoopAlpha-improved-v3.vmz`), and v3 does not touch
that file. A fix that landed there was aimed at the wrong target.

## Ranked suspects

**1. `PlayerModel.gd`.** `CaptureInitialWeaponFile` gained one line:

```gdscript
currentWeaponNode = aiInstance.weapon
```

In `1.0.0`, `currentWeaponNode` was only ever set inside `SwapWeapon`, which
runs only when the weapon *file changes*. A player who never switched weapons
left it `null` forever, so `PlayPuppetFireEffect` returned immediately — that is
why the starting weapon had no muzzle flash. **That function never executed in
the released build.** It now runs per remote shot, adding two nodes:

```gdscript
muzzleNode.add_child(flash)
muzzleNode.add_child(audio)
```

and it points at `aiInstance.weapon`, the AI's *own* weapon node. `SwapWeapon`
only frees children of `aiInstance.weapons` — a different node — so nothing ever
cleans that muzzle. A brand-new path that runs on every remote shot fits
"crashed while a player was shooting."

**2. `PlayerStateProxy.gd`.** `_apply_broadcast` changed from
`if weapon_file != "": sync_weapon_file = weapon_file` to unconditional
assignment. Empty values in an unreliable 20 Hz packet now flip the puppet's
weapon off and back on, so `SwapWeapon` runs `scene.instantiate()` +
`queue_free()` repeatedly instead of once.

**3. `LocalStateSync.gd`.** Mostly animation blend values, plus a shot cap that
does *less* work than `1.0.0` did. Contains the sprint-animation fix, which is
confirmed working.

## Bisect arms

Built by `python tools/mkbisect.py` into `dist/bisect/`. Every arm is the
current `dev` tree; arms differ *only* in which suspect script is taken from the
crashing v4 build instead (`tools/bisect/v4/`, kept in-repo so the ladder is
reproducible without the original scratch builds).

| Arm | Contents | Question it answers |
|---|---|---|
| **0** | `dev`, no suspects | is our own fixed base clean? |
| **A** | 0 + `LocalStateSync.gd` | |
| **B** | A + `PlayerStateProxy.gd` | |
| **C** | B + `PlayerModel.gd` | equals the v4-era build, known to crash over Steam |

The base is `dev` rather than `1.0.0` because the earlier `1.0.0`-based arms
carried four live bugs into every test session, one of them continuously
corrupting the host's weapon state. The cost of the swap is the control:
"`1.0.0` does not crash" is backed by months of play, and `dev` has no such
record. **Arm 0 is the replacement control and must be established first** --
without it a crash on any arm above could be ours rather than the original's.

Arm C is the positive control. If the build that demonstrably crashed over Steam
survives locally over ENet, that is strong evidence the transport is the cause
and all three scripts are innocent.

Run each arm on every peer, for a session with shooting and AI.

| Result | Conclusion |
|---|---|
| 0 crashes | the crash is in our own fixes -- stop the ladder |
| 0 clean, A crashes | `LocalStateSync.gd` |
| A clean, B crashes | `PlayerStateProxy.gd` |
| B clean, C crashes | `PlayerModel.gd` |
| all four clean | nothing here reproduces over ENet; suspect `SteamMultiplayerPeer` |

Remember the asymmetry: an arm that **crashes** locally is conclusive, an arm
that stays **clean** clears nothing, because local runs use ENet and the crash
was seen over `SteamMultiplayerPeer`.

## Dead ends already tried

- **RPC annotation hardening on `PlayerStateProxy`.** Changing the player-state
  RPC contract made remote players invisible while still solid. Reverted.
- **A tab in space-indented `PlayerModel.gd`.** Godot rejected the whole script,
  so the puppet's collider loaded and its model did not — same
  invisible-but-solid symptom, different cause. Confirmed from the runtime log
  (`Used tab character for indentation instead of space`). Now caught by
  `tools/build.py`.
- **`AIHooks.gd` post-hook registration.** Real bug (borrowed `GameData` flags
  are not always restored, which can leave aim blocked after sprinting) but
  **not the crash** — see the table above. Worth fixing on its own merits, not
  as a crash fix.

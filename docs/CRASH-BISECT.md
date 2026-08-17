# Open investigation: host hard-crash

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

Both built from pristine `1.0.0`, everything else byte-identical, and both
carrying the container-id fix (constant across arms, so it cannot skew the
result):

| Arm | Contents |
|---|---|
| **A** | `1.0.0` + `LocalStateSync.gd` + container fix |
| **B** | A + `PlayerStateProxy.gd` |
| — | A + B + `PlayerModel.gd` is the v3 build, which **crashes** |

Run A first, on every peer, for a session with shooting and AI.

| Result | Conclusion |
|---|---|
| A clean, B crashes | `PlayerStateProxy.gd` |
| A and B both clean | `PlayerModel.gd` |
| A crashes | `LocalStateSync.gd`, or the container fix — rebuild A without the container fix to separate them |

Both arms deliberately give up the shooting fixes; that is the point of the
split. Neither should be merged as-is.

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

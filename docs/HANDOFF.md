# Handoff — state of play

Written at the end of a long working session, for whoever picks this up next
(including a future me with no memory of it). Everything below was verified
against source, logs, or a live session; where something is a hypothesis it says
so.

---

## 1. What exists now

**Repo:** `https://github.com/Ku-Tadao/rtv-coop-alpha` — private.

| Branch | State |
|---|---|
| `main` | Pristine RTV Coop Alpha 1.0.0 source + build tooling + docs. Tagged `v1.0.0`; the release carries a `.vmz` byte-identical in content to the shipped archive. |
| `dev` | `main` + eight commits of fixes, all documented below. |

The mod was originally distributed only as `RTVCoopAlpha.vmz` (a zip). The repo
mirrors the archive layout exactly — `mod.txt` at root, scripts under
`mods/RTVCoopAlpha/` — so `python tools/build.py` is a zip plus validation. CI
builds on every push and attaches the `.vmz` to `v*` tags.

Read [ARCHITECTURE.md](ARCHITECTURE.md) before touching sync code, and
[HOOKS.md](HOOKS.md) for the vanilla surface.

---

## 2. The open problem: a hard native crash

**This is the reason all the tooling exists, and it is still unsolved.**

The host process dies with no Godot error, no GDScript stack, and a log that
stops mid-line. Observed twice on the friend's machine: once while sprinting with
another player firing at AI, once immediately after interacting with a dead AI
body.

Godot's crash handler writes to stderr, which the game's log file does not
capture, and the final buffered write is lost. **The cause is not in the logs.**
An earlier attempt to read one out of them produced a confident wrong answer;
don't repeat it. Full record in [CRASH-BISECT.md](CRASH-BISECT.md).

### Search space

Released `1.0.0` does not crash. The crashing builds (`improved-v1` … `v4`)
differ from it in exactly four files:

| File | First changed in | Status |
|---|---|---|
| `Game/Types/PlayerModel.gd` | v1 | suspect — ranked first |
| `Framework/PlayerStateProxy.gd` | v1 | suspect — ranked second |
| `Game/Sync/LocalStateSync.gd` | v1 | suspect — ranked third |
| `Game/Hooks/AIHooks.gd` | v4 | **ruled out** |

`AIHooks` is excluded by evidence, not judgement: the first crash happened on the
v3 build (`MOUNTED ... RTVCoopAlpha-improved-v3.vmz` in the host log) and v3 does
not touch that file. A fix that landed there was aimed at the wrong target.

**Why `PlayerModel.gd` ranks first.** `CaptureInitialWeaponFile` gained one line,
`currentWeaponNode = aiInstance.weapon`. In 1.0.0 that variable was only ever set
inside `SwapWeapon`, which runs only when the weapon *file changes* — so for a
player who never switched weapons it stayed `null` and `PlayPuppetFireEffect`
returned immediately. That function **never executed in the released build**. It
now runs per remote shot, adding two nodes to a muzzle that `SwapWeapon` never
cleans (it only frees children of `aiInstance.weapons`, a different node). A
brand-new path that runs on every remote shot fits "crashed while a player was
shooting".

### Evidence status

Arm A (below) survived one firefight with a kill and the host nearby. Suggestive,
not conclusive — both original crashes were intermittent.

### The limit on every local result

Local testing runs over **ENet**, not `SteamMultiplayerPeer`. So:

- an arm that **crashes** locally is conclusive;
- an arm that stays **clean** clears nothing.

A hard native crash with no Godot stack is exactly what a GDExtension fault looks
like, and GodotSteam is the GDExtension in play. If every arm survives locally
but the Steam build still dies with a second player, **the transport becomes the
prime suspect** and the three files are exonerated. That is a real finding, not a
failed experiment.

---

## 3. Bugs found and fixed on `dev`

All six were found during this session. Each is a real defect with evidence.

### 3.1 Wrong container opened (container-id collision)

Opening a Locker in the cabin opened a Nightstand. Client logs showed the host
broadcasting one container twice under different ids:

```
cid=8  pos=(-0.4, 0.4, -3.7) storage=42   <- the Locker
cid=15 pos=(-0.4, 0.4, -3.7) storage=42   <- same Locker, second round
```

Round one was position-matched onto the Nightstand, so two client nodes held id
15, and `_find_container_by_id` returns the first match.

Three causes: `RegisterSceneContainers` stamped shelter furniture with
`nextContainerId` and the furniture pass restamped the same nodes with a
furniture id (two counters, one meta key); `BroadcastContainerFullState` fell back
to matching an unknown id to the nearest container within 1 m, permanently
recording an id the host never assigned; and `_node_id()` reports `0` for an
unregistered node, so `cid=0` matched an arbitrary container.

Fixed: the scene pass skips furniture for *id assignment only*, the position
fallback is deleted along with `_find_container_near`, `_find_container_by_id`
fails closed on `cid <= 0`, and the host no longer broadcasts containers with an
unresolved id.

**A regression was introduced and fixed here.** The first version of the
furniture skip sat above `add_to_group("CoopLootContainer")`, so furniture fell
out of container sync entirely — the host logged `broadcasting 0 containers` and
the client `container NOT FOUND for cid=0` fifteen times. Group membership answers
"does this sync at all", which is a different question from "which counter numbers
it". Only a live session surfaced it; the static tests were perfectly happy.

### 3.2 First shelter furniture never synced

`GenerateFurnitureId()` returns `nextFurnitureId` then increments, starting at 0 —
and `_broadcast_shelter_furniture` treats `fid == 0` as its "no players" sentinel
and `continue`s. The first furniture root was silently dropped on every map load.
Fixed by starting the counter at 1.

Verified live: `found 22 furniture nodes` → `fid=1` … `fid=22`. Before the fix the
same log read "found 25, spawned 1–24".

### 3.3 A guest's save overwritten by the host's world

The four save hooks guarded on `CoopAuthority.is_client()`, which short-circuits:

```gdscript
static func is_client() -> bool:
    if not is_active():
        return false
```

So the instant the transport drops, the guard stops guarding — while the guest is
still standing in the host's cabin. Nothing listened for `transport_disconnected`
to eject them, so the next `SaveShelter` / `SaveWorld` / `SaveCharacter` wrote the
host's state into their own files.

Confirmed in a real save: `Cabin.tres` held 55 items collapsed into two pieces of
furniture (Nightstand 33, Fridge 22) with every other container empty, and grid
positions running to `y=704` in a container about two cells tall — visible through
the glass, impossible to click.

Fixed: `CoopNet` tracks a sticky `_was_guest` set on both join paths and surviving
the drop; `CoopAuthority.is_guest()` sits beside the other authority questions;
all four save hooks guard on `is_client() or is_guest()`; losing the host returns
the guest to the menu; the flag clears on the menu load.

> **Diagnostic note worth remembering.** Three further "symptoms" were claimed for
> this bug and all three were wrong: an empty `catalog` (that is the *furniture*
> catalog — empty is correct when all furniture is placed), stats at exactly 100
> (normal after sleeping), and `World.shelters = 0` (an index into
> `["Cabin", "Attic", …]`, so it means "Cabin"). Only the cabin damage was real.
> Check what a field means in the game's own scripts before reading corruption
> into it — the modloader extracts them to
> `user://modloader_hooks/vanilla/Scripts/`.

### 3.4 Guests could take items the host had not numbered

The `Item` branch of `InteractorHooks` fell through when a target had no
`network_uuid`, so the **vanilla** pickup ran locally on the client — minting an
item the host never hears about.

Found in play: an AI's carried weapon could be taken off a paused pooled agent,
and then taken *again* off the corpse. Clients grow AI pools themselves
(`AISync._grow_pool` parks agents around the pool position with weapons attached),
so those weapons exist only on the guest and carry no uuid — the host only assigns
one when the AI dies. Trader display weapons were takeable the same way.

Fixed: guests refuse the interaction and drop the prompt. Host unchanged.

**Unexplained half:** why the phantom weapon is *visible* only to the guest.
`_grow_pool` is the best hypothesis and matches "the place where they spawned",
but it was not proven. The fix stops you *taking* the duplicate; if a visible gun
still lies at spawn points, that is the open part.

### 3.5 Only F11 ended a session

`Disconnect()` was reachable from exactly three places: the F11 debug key, the
lobby's Disconnect button, and a downed-state path. **Not** from the main menu.
`CoopNet` lives outside the scene tree, so the peer survived the scene change and
guests kept playing in a world the host had stopped simulating. Quitting relied on
`PEER_TIMEOUT_MS` — 90 seconds of frozen world.

Fixed: `LoadScene` hangs up when a host heads for the menu; `CoopNet` disconnects
on close-request and on tree exit.

### 3.6 The host's own weapon fired when a guest pulled the trigger

`AIHooks` borrows six fields from the shared `GameData.tres` every AI tick
(`playerPosition`, `cameraPosition`, `isRunning`, `isWalking`, `isFiring`,
`playerVector`) and restored them from a callback registered via
`register_replace_or_post` — which claims the **replace** slot and only registers
the post callback *if replace was already owned by someone else*. It wasn't, so
the restore never ran and those flags stayed set to the nearest guest's state.

Reported live as the host's gun firing whenever the guest fired. The same
mechanism, one field over, is the long-standing "aim stays blocked after
sprinting" (`isRunning`).

Fixed with two explicit registrations. A test asserts all six fields are both
borrowed and restored.

---

## 4. How to test locally (no second machine)

`CoopNet._input()` binds loopback keys that are always live, in any scene,
regardless of transport — `HostGameEnet()` and `JoinGame()` are unconditionally
ENet, so they work with GodotSteam loaded:

| Key | Action |
|---|---|
| F9 | Host over ENet on `127.0.0.1:27015` |
| F10 | Join `127.0.0.1:27015` |
| F11 | Disconnect |

The co-op menu cannot do this — `LobbyUI`'s only join path is `JoinSteam()`.

`coop-test/launch.bat <name>` (outside the repo, in the working folder) seeds a
profile from the real save, redirects `%APPDATA%` so each instance gets its own
`user://`, and starts the game. Two instances otherwise share saves and the same
`coop_debug.log`, which each opens `READ_WRITE` and seeks to its own end — they
overwrite each other and the log becomes worthless.

Verify isolation every run: the mod prints
`[CoopLogger] Appending to: <resolved path>` at startup.

Full detail in [BUILDING.md](BUILDING.md#testing-two-instances-on-one-pc).

---

## 5. Where the bisect stands, and the decision to make

Two arms are built in `editable-mods/RTVCoopAlpha/build/`, both from pristine
1.0.0 plus the shared fixes, differing **only** in the suspect file:

- **arm A** = 1.0.0 + `LocalStateSync.gd` + container fix + guest-save fix
- **arm B** = arm A + `PlayerStateProxy.gd`

Arm A is installed and survived one firefight.

### The choice

Continuing on the frozen base keeps the cleanest experiment, but means playing
with the duplicate-gun, phantom-gunshot and session-teardown bugs still present,
since those fixes are on `dev` and deliberately not in the arms.

Rolling `dev` into the arms **changes the shape of the experiment**, which is
worth being explicit about: today the control is "1.0.0 does not crash",
established by months of the friend playing it. If the base becomes `dev`, that
control no longer applies — `dev` carries eight commits nobody has stress-tested,
so a crash on any arm could be ours rather than the original.

The way to have both is to add a rung at the bottom:

| Arm | Contents | Question it answers |
|---|---|---|
| **0** | `dev`, no sync suspects | Is our own fixed base clean? |
| **A** | 0 + `LocalStateSync.gd` | |
| **B** | A + `PlayerStateProxy.gd` | |
| **C** | B + `PlayerModel.gd` | equals the v4-era build, known to crash |

Arm 0 is the new control and must be established first — without it the ladder
proves nothing. Arm C is the positive control: if it *doesn't* crash locally,
that is strong evidence the transport is the real cause, because it is the build
that demonstrably crashed over Steam.

**Recommendation: build the ladder from `dev`, run arm 0 first.** The banked arm A
result is one fight, which is weak evidence to protect, and `dev` fixes four
things that otherwise degrade every test session — including one continuously
corrupting the host's weapon state.

The arms are produced by a script in the session scratchpad (`mkbisect.py`): it
copies the pristine archive entry-for-entry, substituting named members from the
repo tree, and asserts no file mixes tab and space indentation. Rebuilding it
from that description is a ten-minute job; the important part is the rules in
§6.

---

## 6. Traps this session actually hit

Not hypothetical — each cost time or nearly shipped a wrong answer.

- **Verify a bisect arm after building it.** The build script's source path
  pointed at a stale `editable-mods` tree, so "rebuilt" arms silently carried an
  older version of the shared fixes and none of the newer ones. Caught by
  `diff -rq` against the repo, not by the build succeeding.
- **Godot rejects an entire script that mixes tabs and spaces**, with no error at
  the point of use. One tab in the space-indented `PlayerModel.gd` made remote
  players invisible but still solid, because the puppet's collider is a sibling
  node that loads independently of its model. `tools/build.py` now fails on it.
- **`godot.log` is buffered; `coop_debug.log` flushes eagerly.** While a session is
  live, read the latter. A log ending mid-line means a hard crash, not a bug in
  your reading.
- **`.bat` files need CRLF**, and `wmic` no longer exists on current Windows 11.
- **Python `write_text` on Windows emits CRLF**; pass `newline="\n"` or the repo's
  `.gitattributes` fights you.
- **`coop_puppet_mode` is set in exactly one place** (`PlayerModel.gd`, for player
  puppets) and read in eight places in `AIHooks.gd` — every one of those AI
  puppet-mode guards is dead code. Not causing any known bug, but it means AI
  hooks behave identically on host and client where the author clearly intended
  otherwise. Untouched.
- **`CoopAuthority.is_host()` returns true in singleplayer** by design. It is not
  the "am I networked" test; `is_active()` is.
- **Commits are attributed by email.** The first four commits went out under the
  wrong account because no git identity was configured and the session default was
  used. Repo identity is now pinned to `29869255+Ku-Tadao@users.noreply.github.com`.

---

## 7. Not done

- The crash. Everything above is scaffolding for finding it.
- Repo is private, and the mod's authorship and licence are unresolved — the
  README asks the original author to open an issue. Settle this before making it
  public or promoting it.
- A trailer exists at `rtv-coop-video/` (Remotion, 28 s, renders to
  `out/rtv-coop-trailer.mp4`) with a **silent** audio track — no music was added,
  to avoid a copyright claim on the upload.
- The damaged save was wiped by the player. Backups are at
  `Vastock/save-backup-20260818-114926` and `Desktop/RTV-save-backup/` if the
  corruption is ever worth studying.

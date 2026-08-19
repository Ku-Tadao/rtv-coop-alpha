# Handoff — state of play

Written at the end of a long working session, for whoever picks this up next
(including a future me with no memory of it). Everything below was verified
against source, logs, or a live session; where something is a hypothesis it says
so.

---

## 1. What exists now

**Repo:** `https://github.com/Ku-Tadao/rtv-coop-alpha` — public, and maintained
as a fork. Upstream (ModWorkshop 56011) was taken down; this is the only
surviving source. `v1.0.0` on `main` is the verbatim upstream import, kept as
the fork point.

| Branch | State |
|---|---|
| `main` | Pristine RTV Coop Alpha 1.0.0 source + build tooling + docs. Tagged `v1.0.0`; the release carries a `.vmz` byte-identical in content to the shipped archive. |
| `dev` | `main` plus every fix below. Current version `1.2.0`. |

The mod was originally distributed only as `RTVCoopAlpha.vmz` (a zip). The repo
mirrors the archive layout exactly — `mod.txt` at root, scripts under
`mods/RTVCoopAlpha/` — so `python tools/build.py` is a zip plus validation. CI
builds on every push and attaches the `.vmz` to `v*` tags.

Read [ARCHITECTURE.md](ARCHITECTURE.md) before touching sync code, and
[HOOKS.md](HOOKS.md) for the vanilla surface.

### The gates

`python tools/build.py --check` runs before every build and in CI. It fails on
mixed tab/space indentation (Godot rejects the whole script, silently), missing
manifest targets, zero-byte files, **and the RPC linter**.

The linter is the one worth knowing about. A mismatched RPC is this mod's worst
failure mode — Godot does not check arity between peers, so the symptom looks
nothing like the cause. It checks arity, unknown handlers, uncalled handlers,
unchecked `any_peer` senders, and whether two call sites of one RPC disagree.
See [BUILDING.md](BUILDING.md#the-rpc-linter). It found two real bugs the first
time it ran, and `tests/test_rpc_lint.py` mutates the real sources to prove each
check still bites.

`python -m unittest discover -s tests` runs 96 checks. They are all structural —
the mod cannot be executed outside the game, so everything asserted is a shape,
never a behaviour. That is a real limitation, not a preference, and section 6
records the time it let a bug through.

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
| `Framework/PlayerStateProxy.gd` | v1 | suspect — ranked first |
| `Game/Sync/LocalStateSync.gd` | v1 | suspect — ranked second |
| `Game/Types/PlayerModel.gd` | v1 | the node-leak theory is **disproven**; see below |
| `Game/Hooks/AIHooks.gd` | v4 | **ruled out** |

`AIHooks` is excluded by evidence, not judgement: the first crash happened on the
v3 build (`MOUNTED ... RTVCoopAlpha-improved-v3.vmz` in the host log) and v3 does
not touch that file. A fix that landed there was aimed at the wrong target.

### The leading suspect is gone

`PlayerModel.gd` ranked first for a long time. `CaptureInitialWeaponFile` gained
one line, `currentWeaponNode = aiInstance.weapon`, which switched on
`PlayPuppetFireEffect` — a function that **never executed in the released
build**. It adds two nodes to a muzzle that `SwapWeapon` never cleans (it frees
children of `aiInstance.weapons`, a different node). A brand-new path running on
every remote shot, leaking two nodes each time, fits "crashed while a player was
shooting" exactly.

**It does not leak.** Measured rather than argued: mount `RTV.pck` in headless
Godot 4.6.2, instantiate the real effect scenes, fire ten shots at ten-frame
intervals and watch the parent's child count over 900 frames. It returns to
zero. `Resources/AudioInstance3D.tscn` frees itself from its own `_process`;
`Effects/Muzzle_Flash.tscn` frees itself from a `get_tree().create_timer()`
inside `Emit()` — which is why `Emit` must be called with the node already in the
tree, and there it is.

Two consequences worth carrying:

- `PlayerModel.gd` may still be involved, but not by that mechanism.
- **A flat node count in the heartbeat is now a positive result.** It used to be
  ambiguous — "nothing leaks" and "the leak is elsewhere" looked identical. Flat
  counters now rule exhaustion out and send you to the dump.

Prefer this kind of check to reasoning about what a vanilla script probably
does. The tooling is [tools/rig-inspect](../tools/rig-inspect).

### The limit on every local result

Local testing runs over **ENet**, not `SteamMultiplayerPeer`. So:

- a build that **crashes** locally is conclusive;
- a build that stays **clean** clears nothing.

A hard native crash with no Godot stack is exactly what a GDExtension fault looks
like, and GodotSteam is the GDExtension in play. If everything survives locally
but the Steam build still dies with a second player, **the transport becomes the
prime suspect** and the three files are exonerated. That is a real finding, not a
failed experiment.

---

## 3. Bugs found and fixed on `dev`

Each is a real defect with evidence. 3.1–3.6 were found by playing; 3.7 onward
came from a full read of the sync layer and from the RPC linter.

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

### 3.7 AI drops collided with world items

Dropped weapons, backpacks and secondaries were numbered `uuid * 10 + n`. World
items are numbered `0..N` from a *different* counter that starts in the same
place, and host logs show scenes registering **85–143 items** — so the first
AI's weapon claimed uuid 1, which a scene pickup already owned.
`worldItems[1] = ai.weapon` overwrote the entry while the pickup kept its own
`network_uuid` meta, so `BroadcastPickupRemove(1)` freed whichever the dictionary
happened to hold.

The formula was not laziness: it is deterministic, so both peers could derive the
ids without putting them in the payload. The fix therefore replaces derivation
with **transmission** — one `NumberAIDrops`/`ApplyAIDropIds` pair, ids carried in
`BroadcastAIDeath` the way `corpse_cid` already was. It only works if every site
agrees, which is why there are three (two host paths, either can fire first, and
one client path). `-1` is the "no such drop" sentinel; 0 is a valid item id.

### 3.8 Doors were never synced

`RequestDoorSync` built a manifest and `ApplyDoorManifest` consumed it, and
**nothing ever called either**. Nothing pushed door state on join either. A guest
therefore saw every door in its default state — one the host had opened read as
closed, one they had unlocked read as locked.

Found by the RPC linter's "uncalled handler" check on its first run, not by
playing. Now requested alongside loot and fires when a client's map becomes
ready.

### 3.9 Two guests could take the same item

`RequestPickup` added the item to the local inventory and `queue_free()`d it,
then told the host. Two guests interacting in the same moment both succeeded.

Containers already solved this — `RequestContainerOpen` grants or denies — so
the fix mirrors that rather than inventing a second pattern. The host keeps its
immediate path, but respects a claim a guest holds, or the arbitration would only
bind the peers that do not matter. A stranded claim would lock an item for the
rest of the session, which is worse than the original bug, so every ending is
covered: taken, released on a full inventory, released on disconnect, cleared on
scene change, and timed out when a peer never answers.

### 3.10 Trusting what the sender claimed

`_apply_broadcast` was `@rpc("any_peer")` with no sender check at all, so any
client could drive any other player's puppet. `_submit_to_host` checked
`is_server()` but never that the sender owned the proxy it wrote to.
`BroadcastMicGain` took the peer id from its payload, so a peer could mute
someone else for you.

All three are the same mistake. The linter now fails any `any_peer` handler that
never consults `is_server()` or `get_remote_sender_id()`.

### 3.11 A release that was written and never called

A guest who disconnected mid-placement left that furniture locked for everyone,
for the rest of the session. `FurnitureSync.ReleaseLockForPeer` existed and
`_on_peer_left` never called it.

This is now the third time a per-peer lock has had this shape, so
`tests/test_session_teardown.py` finds every release-shaped function in the
sources and fails if one is never called.

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
| F8 | Toggle verbose logging (per-agent spawn detail; off by default) |

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

## 5. Current approach

Bisecting is set aside — see §2 for why the ENet/Steam asymmetry made each arm
cost a session and return "inconclusive". The shipped build carries every fix
**and** the remaining suspects, instrumented so the next crash explains itself.

Everything diagnostic goes through `CoopLogger.log_msg`, which flushes per line.
That is the whole point: `godot.log` loses its final buffered write when the
process dies, so `coop_debug.log` is the only sink whose last entry survives.
**Do not "optimise" that flush away** — the verbose tier (F8) exists so it does
not have to go.

- **Heartbeat every 15s** — node count, peak, object count, orphans, static
  memory, fps, peer count. Climbing counters with a last-line reading means
  exhaustion; flat counters now *rule it out* and send you to the dump.
- **Every 25th remote shot** with the muzzle child count. Kept even though the
  leak theory is disproven, because it is the direct measurement of it.
- **Weapon swaps** with the number of children freed.
- **Weapon-file transitions** only, not the 20Hz packet rate. If
  `PlayerStateProxy` is churning the puppet's weapon, this is where it shows.
- **AI death broadcast payload sizes**, since one crash followed a dead-AI
  interaction.

Host prep before a session: enable WER local dumps for `RTV.exe`
(`DumpType=2`), launch with stderr redirected to a file since Godot's crash
handler writes there and the game log never receives it, and back up the save.
Collect `coop_debug.log`, `logs/`, the `.dmp`, and the console capture **from
both machines**.

The single most valuable fact a dump gives is the faulting module. If it names
GodotSteam, the sync files are innocent and the transport is the cause — which
ENet-only local testing could never have shown.

## 6. Traps this repo has actually hit

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
- **A live session is a test the suite is not.** The container-id fix passed every
  check and still broke furniture sync, because the group-add sat below the new
  guard (§3.1). Structural tests cannot see that; budget a session for anything
  that changes what syncs.
- **Player proxies never call `set_multiplayer_authority`**, so their authority is
  the default — peer 1, the host. That is what makes `@rpc("authority")` on
  `_apply_broadcast` mean host-only. Setting authority to the owning peer would
  silently invert it. Asserted in `tests/test_rpc_authority.py`.
- **A correction to an earlier version of this document.** It claimed the eight
  `coop_puppet_mode` guards in `AIHooks.gd` were dead code, because the meta is
  set in only one place. **That is wrong.** It is set on every puppet's AI
  instance in `PlayerModel._ready`, so those guards are exactly what stops the AI
  hooks from driving a player puppet as if it were an NPC. Do not remove them —
  and note that "set in one place" says nothing about how often that place runs.
- **`CoopAuthority.is_host()` returns true in singleplayer** by design. It is not
  the "am I networked" test; `is_active()` is.
- **Commits are attributed by email.** The first four commits went out under the
  wrong account because no git identity was configured and the session default was
  used. Repo identity is now pinned to `29869255+Ku-Tadao@users.noreply.github.com`.

---

## 7. Not done

- **The crash.** Everything above is scaffolding for finding it.
- **Puppet animation.** Strafing cannot be fixed with clips: the rig has no
  sideways animations at all, confirmed by dumping the AnimationTree blend
  spaces, so it has to be body-yaw. Backwards clips (`*_Aim_Walk_B`,
  `*_Aim_Run_B`, `*_Aim_Crouch_B`) *do* exist and are simply never selected.
  Both need movement direction in the state packet; `playerVector` is already in
  `GameData` and borrowed by `AIHooks`, just not transmitted. Weapon inspection
  is not achievable — no clips exist.
- **Driving the AnimationTree instead of raw clips.** The mod disables the tree
  and calls `animPlayer.play()`, which is why nothing blends and a third of the
  rig is unreachable. The tree already blends speed continuously along the axis
  the packet's `animBlend` carries, and the `Group` blend space is what
  `weaponPosition` should drive. A bigger win than clip remapping, but it means
  re-enabling `animator.active`, which the mod deliberately turned off and which
  interacts with `AIHooks._client_animate`. Branch it.
- **Repo is public, framed as a fork.** Upstream was pulled from ModWorkshop, so
  this is the only source left; `v1.0.0` is the untouched import and everything
  after it is work done here. Original authorship is still unknown and no licence
  is asserted (none can be — the base is not ours to license), so formally it is
  all rights reserved. The README credits the unknown original author and carries
  a standing takedown offer if they surface. `[updates] modworkshop=56011` was
  removed from `mod.txt` — it pointed the loader's update tab at the dead listing,
  and at an id that could be reassigned to someone else's zip.
- A trailer exists at `rtv-coop-video/` (Remotion, 28 s, renders to
  `out/rtv-coop-trailer.mp4`) with a **silent** audio track — no music was added,
  to avoid a copyright claim on the upload.
- The damaged save was wiped by the player. Backups are at
  `Vastock/save-backup-20260818-114926` and `Desktop/RTV-save-backup/` if the
  corruption is ever worth studying.

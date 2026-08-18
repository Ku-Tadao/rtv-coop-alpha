# Audit remediation plan

Findings from a full read of the sync layer, the per-frame paths and the puppet
code, ordered into phases that can each ship and be tested on their own. Every
item records what is wrong, why it matters, and what proves it fixed — a phase
is not done because the code changed, it is done when its check passes.

Phases are sized around **in-game test sessions**, which are the expensive
resource here. Related changes are grouped so one session clears a phase, but
never so aggressively that a regression cannot be attributed.

| Phase | Theme | Version | Needs a live session? |
|---|---|---|---|
| 1 | Id correctness and cheap safety | 1.1.8 | yes — AI kill + loot |
| 2 | Load and frame cost | 1.1.9 | yes — scene load timing |
| 3 | RPC trust boundaries | 1.1.10 | light — normal session |
| 4 | Pickup arbitration | 1.2.0 | yes — two guests, one item |
| 5 | Documentation truth-up | — | no |

---

## Phase 1 — Id correctness and cheap safety (1.1.8)

### 1.1 AI drops collide with world-item uuids

**Confirmed live.** Three sites derive drop ids arithmetically:

```gdscript
var w_uuid: int = uuid * 10 + 1   # weapon
var b_uuid: int = uuid * 10 + 2   # backpack
var s_uuid: int = uuid * 10 + 3   # secondary
```

- `Game/Sync/AISync.gd:266` — host, `_watch_ai_deaths`
- `Game/Hooks/AIHooks.gd:138` — host, `_replace_ai_death`
- `Game/Sync/AISync.gd:738` — **client**, `BroadcastAIDeath` handler

`next_ai_uuid` starts at 0 and steps by 1; `nextUuid` (world items) starts at 0
and steps by 1. So the first AI's weapon claims uuid `1`, which
`RegisterSceneItems` already gave to a scene pickup. Host logs show scenes
registering **85–143 items**, so uuids 0–142 are occupied and every AI in that
range collides.

`players.worldItems[w_uuid] = ai.weapon` overwrites the dictionary entry while
the scene pickup keeps its own `network_uuid` meta. Two nodes then answer to one
id and `BroadcastPickupRemove(uuid)` frees whichever the dictionary holds. The
`if w_uuid >= players.nextUuid` guards do not help: they extend the counter, they
never detect a taken id.

**Why the formula exists:** it is deterministic, so host and client derive the
same ids without putting them in the payload. Any fix has to replace that
derivation with transmission.

**Fix.** Mint on the host with `players.GenerateUuid()` and send the ids in
`BroadcastAIDeath`. The RPC already carries `corpse_cid` explicitly for exactly
this reason — follow that precedent rather than inventing a second convention.

1. Both host sites mint the weapon/backpack/secondary uuids via
   `GenerateUuid()`, and only for parts that actually exist. Use `-1` as the
   "no such drop" sentinel, **not** `0` — uuid 0 is a valid world item.
2. Extend `BroadcastAIDeath` with the three ids. Prefer one `PackedInt32Array`
   over three trailing ints; the signature is already eight parameters wide and
   every added positional is another way to mismatch.
3. The client handler stops recomputing and reads what it was sent.
4. Both host paths must agree — `_watch_ai_deaths` is the polling fallback for
   `_replace_ai_death` and either can fire first.

**Check.** `tests/test_ai_drop_ids.py` (new): no source file computes
`uuid * 10`, both host paths call `GenerateUuid`, and the client handler reads
the transmitted ids rather than deriving them. Live: kill an AI in a scene with
loot, take the corpse weapon, confirm no unrelated world item disappears and
that the corpse gun is not duplicated.

**Risk.** RPC signature change — every peer must run 1.1.8. Already true of
every build.

### 1.2 Unclamped lerp weights

`Game/Sync/AISync.gd:113` and `Game/Types/Puppet.gd:24` pass `SPEED * delta`
straight into `lerp` / `lerp_angle` with `SPEED = 18`. Below ~18 fps the weight
exceeds 1.0, so the value overshoots the target and overshoots back the next
frame — visible jitter exactly when the game is already struggling.
`PickupSync` and `WorldSync` already clamp; these two are the outliers.

**Fix.** `clampf(SPEED * delta, 0.0, 1.0)`, matching the existing two.

**Check.** Static test asserting all four lerp sites clamp. No session needed —
the failure mode only appears under frame drops and is not reliably reproducible
on demand.

### 1.3 EventSync can spin on a full tree scan every frame

`Game/Sync/EventSync.gd:41`. If `_find_event_system()` returns null,
`_pending_events` is never cleared, so the search runs again next physics frame.
The fallback path is a recursive `find_child` plus `_scan_for_es`, which walks
every node in the tree comparing script resource paths. One event arriving
before the event system exists pins that cost for the rest of the scene.

**Fix.** Cache the resolved node and clear the cache on map change, alongside
the existing `_pending_events.clear()` in `CoopSceneFlow.ScanIfNeeded`. Throttle
the miss path to at most once per second, and after a bounded number of failures
drop the pending events with a `push_warning` rather than retrying forever.

**Check.** Static test that the search is not called unconditionally from
`_physics_process`.

### 1.4 Small cleanups

- `Game/CoopPlayers.gd:436` — `NextPlacementToken()` is dead (nothing calls it;
  `InterfaceHooks` uses `PickupSync`'s own counter) and it burns a real
  world-item uuid. Delete it.
- `Framework/PlayerStateProxy.gd:79` — `p.resize(20)` with 14 used. 24 wasted
  bytes per packet, per player, at 20 Hz. Resize to 14; `_unpack` already
  requires `>= 14`.
- `Game/Sync/LocalStateSync.gd:179` — `_bp_logged` is spent one-shot
  instrumentation. Remove it and its field.

---

## Phase 2 — Load and frame cost (1.1.9)

### 2.1 Container lookup is O(N×M) per scene load

`Game/Sync/ContainerSync.gd:29`. `_find_container_by_id` scans the
`CoopLootContainer` group, then walks every `Interactable` up its parent chain
looking for a `LootContainer`. `CoopSceneFlow._broadcast_container_storage_to`
sends **one RPC per container**, so each client runs that scan once per
container: a few hundred containers against a few thousand interactables is
hundreds of thousands of node visits per load, on top of the loading screen the
guest is already staring at.

**Fix.** A `{cid: node}` cache in `ContainerSync`, populated on the first miss by
one full scan that records every id it sees, then consulted directly. Validate
hits with `is_instance_valid` and rebuild on a stale entry. Clear it on map
change next to `_container_holders.clear()`.

Lazy population is deliberate: ids are stamped from five call sites
(`RegisterSceneContainers`, `_broadcast_shelter_furniture`, AI death, death
stash, event spawns) and threading invalidation through all of them is more code
and more ways to get it wrong than one rebuild-on-miss.

**Check.** Unit test on the rebuild-on-stale behaviour. Live: compare guest
scene-load time before and after on the same save, and confirm containers still
open with the right contents (Phase 1 must already be in).

### 2.2 GatherLocalAnimState re-resolves node paths at 20 Hz

`Game/Sync/LocalStateSync.gd:144`. Five `get_node_or_null` string-path lookups
(`Core/Camera/Manager`, `Core/UI/Interface`, `Equipment/Backpack`,
`Equipment/Rig`, `Core/Camera`) on every broadcast. Individually cheap, but they
run forever and the targets only change on scene load.

**Fix.** Resolve once per map and cache, invalidating on the existing
`scene_ready` / map-change signal. Guard every cached node with
`is_instance_valid`.

**Check.** Behaviour must be unchanged; compare the state dictionary
field-for-field against a stubbed controller.

### 2.3 Logger cost and growth

`Game/CoopLogger.gd:36` flushes on every line. That is correct and deliberate —
it is the only log that survives the hard crash — so **do not remove the flush**.
Two things around it are still worth doing:

- AI spawning logs roughly six lines per agent
  (`_full_equipment_from_variant`, `_deferred_activate`), so a wave is a burst of
  synchronous writes. Put the per-agent equipment dump behind a debug flag,
  keeping the death, swap and heartbeat lines the crash work actually reads.
- `coop_debug.log` appends across every session with no rotation. Roll it at a
  size ceiling on startup.

**Check.** A session's log still contains the heartbeat, weapon transitions, AI
deaths and container ids.

---

## Phase 3 — RPC trust boundaries (1.1.10)

`Framework/PlayerStateProxy.gd`. Proxies are created in
`Coop.ensure_player_proxy` as `State_<peer_id>` and **never** call
`set_multiplayer_authority`, so their authority is the default — peer 1, the
host. That makes the fix straightforward:

- `_apply_broadcast:124` is `@rpc("any_peer")` with no sender check at all, so
  any client can drive any other player's puppet. Change to
  `@rpc("authority", "unreliable", "call_remote")`; with default authority that
  means host-only, which is what it always intended.
- `_submit_to_host:109` checks `is_server()` but never that the sender owns the
  proxy it is writing to, so a client can submit state on another player's
  behalf. Store the owning `peer_id` on the proxy in `ensure_player_proxy` and
  reject when `multiplayer.get_remote_sender_id() != peer_id`.

**Do not** call `set_multiplayer_authority(peer_id)` on the proxies. It would
make `"authority"` mean the owning client rather than the host and invert the
first fix.

Severity is low for a friends-only session and both changes are small; this is a
separate phase only so a transport-level regression stays attributable.

**Check.** Static test on both annotations and the sender check. Live: a normal
two-instance session — puppets still move, animate and fire.

---

## Phase 4 — Pickup arbitration (1.2.0)

`Game/Sync/PickupSync.gd:88`. `RequestPickup` adds the item to the local
inventory and `queue_free()`s it, *then* notifies the host. Two guests grabbing
the same item both succeed locally and the item is duplicated. There is no
arbitration anywhere in the path.

Containers already solve exactly this: `RequestContainerOpen` → host grants or
denies → the client acts only on the grant.

**Design.** Mirror the container lock rather than inventing something new.

1. The client calls `RequestPickupClaim.rpc_id(1, uuid)` and does nothing
   locally.
2. The host checks `worldItems.has(uuid)` and a `_claimed` set, then replies
   `GrantPickup.rpc_id(sender, uuid)`, or denies with the existing `PlayError`
   feedback.
3. On grant the client runs the current `AutoStack` / `Create` path. If the
   inventory is full and the add fails it must `ReleasePickupClaim.rpc_id(1,
   uuid)` — otherwise a failed pickup locks the item permanently.
4. The host keeps its existing immediate path; it is the authority and should
   not pay a round trip to pick something up.
5. Claims must be released when a peer disconnects, the way
   `ContainerSync.release_holders_for_peer` already does.

**Cost.** Guests wait one round trip (~20–80 ms) before the item appears. That
is the price of correctness, and it matches how containers already feel.

**Check.** Live, with deliberate setup: two guests aimed at the same item, both
interacting as close to simultaneously as possible. Exactly one should get it and
the other should hear the error. Repeat with a full inventory to confirm the
claim is released rather than stranding the item.

**Risk.** Highest of the five phases — it changes the feel of the most common
interaction in the game. Ship it alone.

---

## Phase 5 — Documentation truth-up

### 5.1 The muzzle is not leaking

`docs/CRASH-BISECT.md` ranks `PlayerModel.PlayPuppetFireEffect` as suspect #1 on
the grounds that it adds two nodes per remote shot and frees neither. **That
mechanism does not exist.** Tested against the real assets in headless Godot
4.6.2 — 10 shots at 10-frame intervals, 900 frames:

```
shot 10 -> muzzle children=1
FINAL after 10 shots and 900 frames: children=0
```

`Resources/AudioInstance3D.tscn` frees itself from its own `_process`.
`Effects/Muzzle_Flash.tscn` frees itself from a `get_tree().create_timer()`
inside `Emit()` — which is why `Emit` must be called with the node already in
the tree, and in `PlayPuppetFireEffect` it is.

Rewrite the suspect ranking accordingly. If the heartbeat's node counters come
back flat, that is now **confirmation** rather than an inconclusive result, and
the remaining suspects are `PlayerStateProxy.gd` and `LocalStateSync.gd`.

### 5.2 README known issues

Add the uuid collision (closed in Phase 1) and the pickup race (Phase 4), and
drop whatever Phases 1–4 close.

---

## Order of work

Phases are independent except that **2.1 depends on Phase 1** — testing the
container cache against colliding ids would produce a confusing result. Phase 5
can land at any time and costs nothing; doing 5.1 early stops further effort
going into a suspect that has been ruled out.

Each phase: implement, `python tools/build.py --check`, run the tests, bump
`mod.txt`, build, install, commit. One phase per commit.

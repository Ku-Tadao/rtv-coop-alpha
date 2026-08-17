# Architecture

## The shape of the problem

Road to Vostok is singleplayer. Its scripts assume one player, one camera, one
`GameData` resource holding "the" player's position, aim, and movement flags.
Nothing in the vanilla codebase is written to be reconciled across a network.

This mod does not restructure that. It keeps one authoritative copy of the
singleplayer game running on the host, and drives everyone else's copy to match
by intercepting vanilla functions and replaying the results. Almost every design
decision below follows from that constraint.

Three consequences worth internalizing before changing anything:

- **The host's world is the truth.** Clients predict nothing. If a client
  appears to do something, either the host told it to, or it is a local visual
  that will be corrected.
- **Vanilla globals are shared, mutable, and singular.** `GameData.tres` is one
  resource. Any hook that writes to it must put it back, in the same frame.
- **A remote player is not a player.** It is an AI rig in a costume.

---

## Boot sequence

`mod.txt` declares `Main.gd` as an autoload. From there:

```
Main._ready()
  ├─ load GodotSteam extension (optional; ENet fallback if absent)
  ├─ RTVCoop.new()  →  added to /root, registers itself as Engine meta "Coop"
  │     └─ boot(): SyncService, CoopEvents, CoopScene, PlayerStates
  ├─ CoopLogger    →  Engine meta "CoopLogger"  (writes coop_debug.log)
  ├─ _spawn_services()   Net, Lobby, Settings, Players
  ├─ _spawn_sync()       13 modules from SYNC_SCRIPTS
  ├─ _spawn_hooks()      23 modules from HOOK_SCRIPTS
  ├─ _spawn_ui()         DebugOverlay, LobbyUI, SleepOverlay, VoiceUI
  └─ await CoopFrameworksReady.wait_async()
```

Everything is a `Node` under `/root/RTVCoop`. There is no scene file for the mod
itself; the tree is built in code.

`Main.gd` holds the module lists as hardcoded arrays. Adding a module means
adding it there *and* to `_preloads.gd` — the build validator checks the paths
resolve, because a typo otherwise surfaces only as a runtime `push_error`.

### Service locator

`RTVCoop` (`Game/Coop.gd`) is reachable from anywhere via
`RTVCoop.get_instance()`, backed by `Engine.set_meta("Coop", self)`. It exposes
`net`, `lobby`, `players`, `settings`, `events`, `scene`, and
`get_sync(key)` for the sync modules.

Sync modules self-register under a string key from their `_sync_key()`:

`ai`, `container`, `downed`, `event`, `furniture`, `interactable`,
`local_state`, `mod_bridge`, `pickup`, `quest`, `slot_serializer`, `voice`,
`world`

`BaseHook._ready()` resolves all of them into typed fields once, so hook code
reads `container.TryOpenContainer(...)` rather than looking modules up by hand.
It awaits `CoopFrameworksReady` first — hooks registered before the modloader is
ready are silently dropped.

---

## Authority

`CoopAuthority` is the single place that answers "who decides":

| Call | Meaning |
|---|---|
| `is_active()` | a session exists at all |
| `is_host()` | **true when no session is active** — singleplayer is trivially authoritative |
| `is_client()` | false when no session is active |
| `local_peer_id()` | 1 for the host |

That `is_host()` default is the important one: it lets a hook written as
`if not is_host(): return` behave correctly in singleplayer without a special
case. It also means `is_host()` is *not* the right check for "am I in
multiplayer" — use `is_active()`.

`CoopRPC` wraps the recurring shapes, chiefly `interact_pattern(submit,
execute, broadcast)`: a client submits a request to the host, the host executes
locally and broadcasts the result.

### Transport

`CoopNet` picks `SteamMultiplayerPeer` when GodotSteam is present (NAT traversal
via Steam Datagram Relay), otherwise `ENetMultiplayerPeer` on
`127.0.0.1:27015`. Max 4 peers. `CoopLobby` drives Steam lobby creation, invites,
and membership.

---

## How a remote player is drawn

There is no second player controller. `Scenes/RemotePlayer.tscn` instantiates a
`Puppet`, and `PlayerModel` builds the visible body out of **an AI instance**,
then neuters it:

- `pause = true`, collision layers zeroed, animator deactivated
- pickups stripped from the `Item` group and frozen, so you cannot loot a player
- meshes, skins, materials, and the animation tree are `duplicate(true)`'d, so
  two puppets never share animation state
- a separate `PuppetHurtbox` provides the hittable volume

The puppet's collider and its visible model are **sibling nodes with separate
lifetimes**. If `PlayerModel.gd` fails to load, the collider still exists — you
get a player you can walk into but cannot see. That exact symptom has happened,
from a single tab character in a space-indented file.

### The state pipeline

```
local player
  └─ LocalStateSync._collect_state()      reads GameData + rig slots
       └─ PlayerStateProxy._pack()        14 floats + 5 strings
            └─ RPC (unreliable, 20 Hz)
                 └─ PlayerStateProxy._unpack()
                      └─ LocalStateSync   →  Puppet.SetTarget / ApplyAnimState
                           └─ PlayerModel                animation, weapon, fire FX
```

Two details in that path have bitten before:

- **Shots are a counter, not an event.** The proxy carries a monotonically
  increasing `shot_accumulator`; the receiver plays the *difference* since last
  frame. Unreliable delivery means the counter can arrive out of order, and any
  reset (respawn, reconnect, map change) makes the delta meaningless. Both ends
  need to agree on a baseline, or a puppet replays a burst it already fired.
- **Empty strings are ambiguous.** `weapon_file = ""` means both "no weapon" and
  "this packet did not carry a weapon". Treating it as the former makes remote
  weapons flicker; treating it as the latter makes unequipping invisible.

---

## Hooking vanilla scripts

The modloader rewrites vanilla scripts to dispatch to registered callbacks.
`mod.txt` declares which script/method pairs are wrapped; `CoopHook` is the
thin wrapper the mod uses.

```gdscript
CoopHook.register(self, "interactor-interact", _my_callback)
CoopHook.register_replace_or_post(self, "ai-death", _replace_cb, _post_cb)
```

Inside a callback:

- `CoopHook.caller()` — the vanilla object whose method is running
- `CoopHook.skip_super()` — suppress the original implementation

`register_replace_or_post` takes the **replace** slot if it is free, and falls
back to registering `<name>-post` only if some other mod already owns replace.
It is not "register both" — if you need a post hook unconditionally, register
`"<name>-post"` explicitly as a second call. A restore callback that never runs
because it was passed as the fallback arm is an easy bug to write here.

Eight vanilla scripts are replaced outright via `[script_extend]` rather than
hooked (`Door`, `Switch`, `Radio`, `Television`, `Mine`, `Explosion`, `Spawner`,
`Layouts`). A script cannot be both extended and hooked — the modloader warns
that the override displaces the rewrite and the hooks silently stop firing.

Full inventory: [HOOKS.md](HOOKS.md).

---

## Identity and addressing

Synchronized objects are addressed by an integer stamped into node metadata:

| Meta key | Counter | Assigned by |
|---|---|---|
| `network_uuid` | `nextUuid` | `RegisterSceneItems` (world items), AI on death |
| `coop_container_id` | `nextContainerId` | `RegisterSceneContainers` |
| `coop_container_id` | furniture id | `_broadcast_shelter_furniture`, `FurnitureSync` |
| `coop_furniture_id` | `nextFurnitureId` | `_broadcast_shelter_furniture`, `FurnitureSync` |

Note the collision in that table: `coop_container_id` is written from **two
independent counters**. Both start low, both cover the same nodes in the cabin,
and lookup is first-match-wins — so a Locker and a Nightstand can hold the same
id and the wrong one opens. This is the root of a live bug; the fix on `dev` is
to keep shelter furniture out of the scene-container pass entirely.

Counters reset per map load. Ids are host-assigned and broadcast; a client must
never invent one. An earlier fallback that matched unknown ids to the nearest
container by position is exactly how the wrong id got baked in.

`0` is used as the "no id" sentinel in several places while also being a
reachable counter value. Treat `id <= 0` as unresolved and fail closed.

---

## Logging

Two sinks:

- the game's `godot.log` (stdout)
- `%APPDATA%/Road to Vostok/coop_debug.log`, appended across sessions, one
  `=== RTVCoop Instance Start ===` block per launch

`CoopLogger` is on `Engine` meta so any module can reach it:

```gdscript
var l = Engine.get_meta("CoopLogger", null)
if l: l.log_msg("MyModule", "something happened")
```

Lines are tagged `[HOST]` / `[CLIENT]` once authority is known, `[UNKNOWN]`
before that. When diagnosing, always collect **both** peers' logs — a symptom
one player sees is usually caused by the other's state.

A log that ends mid-line is a hard native crash: the final write buffer was
lost, and Godot's crash handler goes to stderr, which this file does not
capture. Nothing in the log will name that crash. See
[BUILDING.md](BUILDING.md#bisecting-a-crash).

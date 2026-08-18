# RTV Coop Alpha

Cooperative multiplayer for **Road to Vostok** — up to 4 players in a shared,
host-authoritative session, built as a script mod on top of the RTV modloader.

Road to Vostok is a singleplayer game. This mod does not add a multiplayer mode
to it so much as continuously reconcile two copies of a singleplayer game: one
player is the authority, everyone else runs a shadow of that world.

> **Status: alpha.** It works, and it also has known bugs. See
> [Known issues](#known-issues) before you file one.

---

## Install

1. Grab `RTVCoopAlpha-<version>.vmz` from the
   [Releases](../../releases) page (or build it — see [Building](#building)).
2. Drop it into your game's `mods/` folder:

   ```
   <Steam>/steamapps/common/Road to Vostok/mods/
   ```

3. Fully restart the game.

**Every player must run the exact same `.vmz`.** The peers exchange RPCs whose
signatures come from these scripts; mismatched builds fail in confusing ways
(most memorably: players who collide with each other but are invisible). When
you update, update everyone, and delete the old file rather than leaving both.

A **Co-op** button is injected into the main menu once the mod loads.

### Requirements

- Road to Vostok with the RTV modloader (`RTVModLib`) present
- Godot 4.6 runtime (whatever the game ships)
- Steam, for the default transport

The co-op menu only offers Steam lobbies. For solo testing, `CoopNet` also
binds hidden ENet loopback keys — see
[Testing two instances on one PC](docs/BUILDING.md#testing-two-instances-on-one-pc).

---

## What it synchronizes

| Area | Module | Notes |
|---|---|---|
| Player position, animation, weapon, firing | `LocalStateSync`, `PlayerStateProxy` | 20 Hz, unreliable |
| Remote player bodies | `Puppet`, `PlayerModel` | a repurposed AI rig, not a second player controller |
| AI spawning, targeting, damage, death, loot | `AISync`, `AIHooks`, `AISpawnerHooks` | host simulates, clients render |
| World items and pickups | `PickupSync` | uuid-addressed |
| Loot containers and stashes | `ContainerSync` | per-container open lock |
| Shelter furniture placement | `FurnitureSync`, `PlacerHooks` | id-addressed, with edit locks |
| Doors, switches, radios, TVs, mines | `InteractableSync` + `ScriptExtends/` | |
| World time, weather, save/load flow | `WorldSync`, `LoaderHooks` | |
| Dynamic events, airdrops, vehicles | `EventSync`, `VehicleHooks` | |
| Quests and traders | `QuestSync`, `TraderHooks` | |
| Downed / revive | `DownedSync`, `InteractorHooks` | 5 s revive, 4 m range |
| Proximity voice chat | `VoiceSync`, `VoiceUI` | Steam voice, 24 kHz |
| Sleep, scene transitions | `BedHooks`, `TransitionHooks` | all players must agree |

Host-tunable session settings (`CoopSettings`): loot multiplier, stat drain,
AI multiplier, day/night rate.

---

## Building

No game install or Godot needed — a `.vmz` is a zip, and the repo is laid out
exactly the way the archive is.

```bash
python tools/build.py
```

Output lands in `dist/RTVCoopAlpha-<version>.vmz`, ready to drop into `mods/`.

```bash
python tools/build.py --check          # validate without writing
python -m unittest discover -s tests   # run the checks
```

Every push builds the same file in CI and uploads it as an artifact; tagging
`v*` publishes it as a release asset. See [docs/BUILDING.md](docs/BUILDING.md)
for what the validator enforces and why.

---

## Repository layout

```
mod.txt                     manifest: hooks, script overrides, autoload
mods/RTVCoopAlpha/
  Main.gd                   entry point; spawns every module
  Framework/                transport, authority, RPC helpers, player proxies
  HookKit/                  thin wrapper over the modloader's hook API
  Game/
    Coop.gd                 service locator (Engine meta "Coop")
    Hooks/                  one file per vanilla script being intercepted
    Sync/                   one file per synchronized subsystem
    ScriptExtends/          full script replacements for vanilla classes
    Types/                  puppet + remote player model
  UI/                       lobby, debug overlay, voice UI
tools/build.py              packaging + validation
tests/                      packaging and regression checks
docs/                       architecture, hooks, building
```

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the boot sequence,
authority model, and how a remote player is actually drawn.
[docs/HOOKS.md](docs/HOOKS.md) lists every vanilla script the mod touches.
[docs/HANDOFF.md](docs/HANDOFF.md) is the current state of play — start there.

---

## Known issues

- **Host crashes.** Hard native process termination with no Godot error and no
  stack — the log just stops mid-line. Present in the `improved-v1..v4` builds,
  not in the released `1.0.0`. Still unresolved. The leading suspect for a long
  time — a node leak in the puppet muzzle effect — has been **disproven by
  measurement**; see [docs/CRASH-BISECT.md](docs/CRASH-BISECT.md) for what is
  ruled out, what remains, and what the next crash session needs.
- **A save already damaged by the guest-overwrite bug is not repaired** by the
  fix for it. Restore from a backup — see [docs/BACKUP.md](docs/BACKUP.md).
- **Strafing and backwards movement look wrong on remote players.** The AI rig
  the puppets are built from has no sideways clips at all, so a strafing player
  is drawn walking forwards. Backwards clips *do* exist and are simply never
  selected. Neither is fixed yet.
- **The co-op menu only offers Steam lobbies.** Direct IP is reachable through
  the loopback keys but has no UI.

### Fixed since 1.0.0

Kept here because each one is a shape worth recognising, not just a line item.

- **AI drops collided with world items.** Dropped weapons, backpacks and
  secondaries took ids derived as `uuid * 10 + n` while scene pickups were
  numbered `0..N` from the same counter — and scenes register 85–143 items. Two
  nodes answered to one id, so taking one could delete the other. *(1.2.0)*
- **Two guests could take the same item.** Pickups were applied locally and the
  host told afterwards, with no arbitration. Now the host grants or denies,
  the way containers always have. *(1.2.0)*
- **Doors were never synced.** The manifest and the handler both existed and
  nothing ever asked for them, so a guest saw every door in its default state.
  Found by the RPC linter, not by playing. *(1.1.8)*
- **Guests kept playing for ~6 seconds after the host left a scene**, because
  the only notification arrived after the host's own load. Anything looted in
  that window was lost. *(1.1.7)*
- **Wrong container opens.** Shelter furniture and scene loot containers drew
  ids from two independent counters into the same key, and clients guessed
  unmatched ids by proximity — so opening a Locker could open a Nightstand.
- **First shelter furniture never synced.** The id counter started at 0 while 0
  was the "no id" sentinel, so the first item was skipped on every map load.
- **The host's own weapon fired when a guest pulled the trigger**, and aim could
  stay blocked after a guest sprinted. The AI hook borrowed shared `GameData`
  flags and restored them from a callback registered via
  `register_replace_or_post`, which only registers the restore if the replace
  slot was already taken — so it never ran.
- **Only F11 ended a session.** Returning to the main menu left the peer alive,
  so guests kept playing in a world the host had stopped simulating.
- **AI weapons could be picked up twice by a guest.** Clients grow AI pools
  locally, so a paused pooled agent's weapon existed only on the guest with no
  host-assigned uuid, and the interact hook fell through to the vanilla pickup.
- **A guest's own save could be overwritten by the host's world.** The save
  hooks guarded on `is_client()`, which goes false the instant the transport
  drops — while the guest is still standing in the host's cabin.
- **Any client could drive any other player's puppet**, and submit state on
  their behalf. Both player-state RPCs were `any_peer` with no sender check.
  *(1.1.10)*
- **A guest who disconnected mid-action left things locked for everyone** —
  furniture being placed, and later pickups. The releases were written; one was
  never called. *(1.2.0)*

## Contributing

`main` is the released build. Work happens on `dev`. See
[CONTRIBUTING.md](CONTRIBUTING.md) — the section on indentation is not optional
reading; Godot rejects an entire script if it mixes tabs and spaces, and that
has already shipped as a "players are invisible" bug once.

## Credits and licensing

RTV Coop Alpha is distributed on
[ModWorkshop](https://modworkshop.net/mod/56011). Original authorship and
license are not recorded in the mod archive; this repository exists to version
and build that source. **If you are the author and want this repo changed or
taken down, open an issue.** No license is asserted here — until one is added,
treat this as all rights reserved by the original author.

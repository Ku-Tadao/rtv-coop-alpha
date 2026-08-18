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

---

## Known issues

These are reproduced and understood, and are what the `dev` branch is for.

- **Host crashes.** Hard native process termination with no Godot error and no
  stack — the log just stops mid-line. Present in the `improved-v1..v4` builds,
  not in the released `1.0.0`. Currently being bisected across three files —
  see [docs/CRASH-BISECT.md](docs/CRASH-BISECT.md) for the evidence, the
  suspects, and the arms to run.
- **Wrong container opens.** Shelter furniture and scene loot containers draw
  ids from two independent counters into the same key, and clients guess
  unmatched ids by proximity — so opening a Locker can open a Nightstand. Fixed
  on `dev`.
- **First shelter furniture never syncs.** The furniture id counter starts at 0
  while 0 is the "no id" sentinel, so the first item is skipped on every map
  load. Fixed on `dev`.
- Aiming can stay blocked after sprinting, because the AI hook borrows the
  shared `GameData` movement flags and does not always restore them.
- **A guest's own save could be overwritten by the host's world.** The save
  hooks guarded on `is_client()`, which goes false the instant the transport
  drops — while the guest is still standing in the host's cabin. Nothing sent
  them back to the menu, so the next save wrote the host's shelter, world and
  character over their own. Fixed on `dev`; a save already damaged this way is
  not repaired by the fix.

---

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

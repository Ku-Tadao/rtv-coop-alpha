# Hook inventory

Every point where this mod reaches into the base game. Two mechanisms:

- **`[hooks]`** — the modloader rewrites the vanilla script to dispatch to
  registered callbacks. The original body still exists and runs unless a
  callback calls `CoopHook.skip_super()`.
- **`[script_extend]`** — the vanilla script is replaced wholesale by a mod
  script that `extends` it.

**A script can only use one.** If a script appears in both, the override
displaces the rewrite and the hooks never fire; the modloader logs this as a
warning at startup rather than an error, so it is easy to miss.

Hook ids are `<lowercased script name>-<lowercased method>`, optionally suffixed
`-pre` or `-post`. `mod.txt` declares which methods are wrapped; the mod then
registers against those ids.

---

## Hooked scripts

| Vanilla script | Methods wrapped (`mod.txt`) | Handled in |
|---|---|---|
| `AI.gd` | `_physics_process`, `Death`, `Initialize`, `PlayFire`, `PlayTail`, `PlayIdle`, `PlayCombat`, `PlayDamage`, `PlayDeath` | `AIHooks.gd` |
| `AISpawner.gd` | `_ready`, `_physics_process`, `Initialize`, `SpawnWanderer`, `SpawnGuard`, `SpawnHider`, `SpawnMinion`, `SpawnBoss` | `AISpawnerHooks.gd` |
| `Bed.gd` | `Interact`, `UpdateTooltip` | `BedHooks.gd` |
| `BTR.gd` | `_ready`, `_physics_process`, `Muzzle` | `VehicleHooks.gd` |
| `CASA.gd` | `_ready`, `_physics_process`, `Collided` | `VehicleHooks.gd` |
| `CatFeeder.gd` | `TryFeeding` | `CatFeederHooks.gd` |
| `CatRescue.gd` | `Interact` | `WorldHooks.gd` |
| `Character.gd` | `_physics_process`, `Death` | `CharacterHooks.gd` |
| `Compiler.gd` | `Spawn` | `CompilerHooks.gd` |
| `Door.gd` | `_ready`, `Interact` | `InteractHooks.gd` |
| `EventSystem.gd` | `_ready`, `FighterJet`, `Airdrop`, `Helicopter`, `Police`, `BTR`, `CrashSite`, `Cat`, `Transmission` | `EventSystemHooks.gd` |
| `Fire.gd` | `_ready`, `Interact` | `FireHooks.gd` |
| `Helicopter.gd` | `_ready`, `_physics_process`, `FireRockets`, `Spotted`, `Sensor` | `VehicleHooks.gd` |
| `Hitbox.gd` | `ApplyDamage` | `HitboxHooks.gd` |
| `Instrument.gd` | `_physics_process`, `_exit_tree` | `InstrumentHooks.gd` |
| `Interactor.gd` | `_physics_process`, `Interact` | `InteractorHooks.gd` |
| `Interface.gd` | `Complete`, `Close`, `Drop`, `ContextPlace` | `InterfaceHooks.gd` |
| `Layouts.gd` | `_ready` | `LayoutHooks.gd` |
| `Loader.gd` | `LoadScene`, `SaveCharacter`, `SaveWorld`, `SaveShelter`, `SaveTrader` | `LoaderHooks.gd` |
| `LootContainer.gd` | `_ready`, `Interact` | `LootHooks.gd` |
| `LootSimulation.gd` | `_ready` | `LootHooks.gd` |
| `Mine.gd` | `Detonate`, `InstantDetonate` | `MineHooks.gd` |
| `MissileSpawner.gd` | `ExecuteLaunchMissiles` | `VehicleHooks.gd` |
| `Pickup.gd` | `Interact` | `LootHooks.gd` |
| `Placer.gd` | `_physics_process`, `_input`, `ContextPlace` | `PlacerHooks.gd` |
| `Police.gd` | `_ready`, `_physics_process` | `VehicleHooks.gd` |
| `Radio.gd` | `Interact` | `WorldHooks.gd` |
| `RocketGrad.gd` | `ExecuteLaunch`, `_process` | `VehicleHooks.gd` |
| `RocketHelicopter.gd` | `_ready`, `_physics_process` | `VehicleHooks.gd` |
| `Simulation.gd` | `_process` | `SimulationHooks.gd` |
| `Switch.gd` | `Interact` | `InteractHooks.gd` |
| `Television.gd` | `Interact` | `WorldHooks.gd` |
| `Trader.gd` | `_ready`, `CompleteTask` | `TraderHooks.gd` |
| `Transition.gd` | `Interact` | `TransitionHooks.gd` |
| `UIManager.gd` | `OpenContainer` | `LootHooks.gd` |

## Replaced scripts (`[script_extend]`)

| Vanilla script | Replacement |
|---|---|
| `Door.gd` | `Game/ScriptExtends/Door_Extend.gd` |
| `Switch.gd` | `Game/ScriptExtends/Switch_Extend.gd` |
| `Radio.gd` | `Game/ScriptExtends/Radio_Extend.gd` |
| `Television.gd` | `Game/ScriptExtends/Television_Extend.gd` |
| `Mine.gd` | `Game/ScriptExtends/Mine_Extend.gd` |
| `Explosion.gd` | `Game/ScriptExtends/Explosion_Extend.gd` |
| `Spawner.gd` | `Game/ScriptExtends/Spawner_Extend.gd` |
| `Layouts.gd` | `Game/ScriptExtends/Layouts_Extend.gd` |

`Door`, `Switch`, `Radio`, `Television`, `Mine` and `Layouts` appear in **both**
tables. The overrides win; the hook registrations for those paths are inert. The
startup log names each one:

```
[RTVCodegen] res://Scripts/Door.gd is rewritten and also overridden by
RTV Coop Alpha [script_overrides] -- override displaces the rewrite,
hooks won't fire for that path
```

---

## Writing a hook

Subclass `BaseHook` and implement `_setup_hooks()`. The base class resolves
`coop`, `players`, `net`, and every sync module into typed fields, and unhooks
everything in `_exit_tree()`.

```gdscript
extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"

func _setup_hooks() -> void:
    CoopHook.register(self, "door-interact", _on_door_interact)

func _on_door_interact() -> void:
    var door := CoopHook.caller()
    if door == null or not CoopAuthority.is_active():
        return
    if CoopAuthority.is_client():
        interactable.RequestDoorToggle.rpc_id(1, door.get_path())
        CoopHook.skip_super()
```

Then register the module in `Main.gd`'s `HOOK_SCRIPTS`, add a preload to
`_preloads.gd`, and declare the method in `mod.txt` under `[hooks]`.

### Traps

- **`register_replace_or_post` is not "register both."** It claims the replace
  slot, and only registers `<id>-post` if another mod already owns replace. If
  you need a post callback unconditionally — for example to restore global state
  a replace callback borrowed — register it as a separate
  `CoopHook.register(self, "<id>-post", cb)` call.
- **`CoopAuthority.is_host()` returns true in singleplayer.** Guard multiplayer
  work with `is_active()` first.
- **Restore what you borrow.** Several hooks temporarily overwrite fields on the
  shared `GameData.tres` (`playerPosition`, `isRunning`, `isFiring`, …) so
  vanilla code evaluates against a remote player. Any early return between the
  overwrite and the restore leaves the local player wearing another player's
  movement flags — which shows up as input that stops responding.
- **Do not assume `caller()` is still valid in a post hook.** The object may
  have been freed by the original implementation.

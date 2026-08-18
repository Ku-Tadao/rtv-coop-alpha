# Building

A `.vmz` is a plain zip. The repo mirrors the archive layout exactly — `mod.txt`
at the root, scripts under `mods/RTVCoopAlpha/` — so packaging is a zip plus the
validation described below. No Godot, no game install, no toolchain.

```bash
python tools/build.py            # dist/RTVCoopAlpha-<version>.vmz
python tools/build.py --check    # validate, write nothing
python tools/build.py --out /tmp/test.vmz
```

Builds are reproducible: zip entry timestamps are pinned, so identical source
produces a byte-identical archive. That makes "did this build actually change?"
answerable with a hash instead of a guess.

## What the validator enforces

Every check exists because the corresponding mistake shipped, or nearly did.

| Check | Why |
|---|---|
| **No mixed tab/space indentation in any `.gd`** | Godot rejects the *entire script*, not the line. A space-indented file with one stray tab silently vanishes at runtime. When it happened to `PlayerModel.gd`, remote players became invisible but still collided — the puppet's collider is a sibling node that loads independently of its model. |
| No zero-byte files | An empty script is not a hookable script and points at a broken copy. |
| `mod.txt` has `[mod]` with `name`, `id`, `version` | The loader keys the mod off these. |
| `[autoload]` and `[script_extend]` targets exist | A dangling `res://mods/...` path is a silent no-op at load. |
| `Main.gd` module paths exist | `HOOK_SCRIPTS` / `SYNC_SCRIPTS` are hardcoded arrays; a rename that misses one only shows up as a runtime `push_error`. |
| **RPC call sites agree with their handlers** | See below. |

Only `res://mods/...` paths are checked. `res://Scripts/...` refers to the
game's own pck, which is not in this repo.

## The RPC linter

`tools/lint_rpc.py` runs as part of `--check`, and standalone:

```bash
python tools/lint_rpc.py
```

A mismatched RPC is this mod's worst failure mode. Godot does not check arity
between peers — the call is dropped or mangled, and the symptom looks nothing
like the cause. "Players are invisible but still collide" was one of these.

| Check | Catches |
|---|---|
| **arity** | a call passing a number of arguments the handler cannot accept |
| **unknown** | a call naming a function that no longer carries `@rpc` (a rename that missed a call site) |
| **agreement** | two call sites of one RPC passing *different* counts |
| **unused** (warning) | an `@rpc` nothing ever calls |

**agreement is the one that earns its keep.** Every trailing parameter here has
a default, so dropping one is legal GDScript — the handler silently receives a
default instead of the value the sender meant, and arity cannot see it. What is
never legal is two call sites disagreeing: that means the signature grew and one
caller was missed.

**unused is not cosmetic.** It found `ApplySceneChange`, an RPC that existed
since 1.0.0 and was never called — which is why guests kept playing for six
seconds after the host left a scene. It then found `RequestDoorSync`, whose
handler and manifest both existed while nothing ever asked for them, so guests
saw every door in its default state.

An RPC whose optional arguments are a deliberate two-mode API opts out with a
comment above it:

```gdscript
## Empty means "send me everything you have"; a list means "just these".
# lint-rpc: optional-args
@rpc("any_peer", "reliable", "call_remote")
func RequestAISync(uuids: PackedInt32Array = PackedInt32Array()) -> void:
```

Opting out is one line in the place that knows the intent. The default stays
strict.

## CI

`.github/workflows/build.yml` runs on every push to `main`/`dev`, on pull
requests, and on demand.

1. `python tools/build.py --check`
2. `python -m unittest discover -s tests`
3. `python tools/build.py`
4. upload `dist/*.vmz` as a build artifact

Artifacts download as a zip wrapper (GitHub always does this), so the `.vmz`
sits one level in. For a plain drag-and-drop file, use a release.

## Releasing

Bump `version` in `mod.txt`, then tag:

```bash
git tag v1.0.1
git push origin v1.0.1
```

The tag build attaches the `.vmz` to a GitHub release with generated notes.
Release assets are not re-wrapped — that download is the file players drop into
`mods/`.

## Branches

- **`main`** — the released build. Tag from here.
- **`dev`** — in-progress fixes. Anything landing on `main` goes through here
  first.

## Testing a build in-game

1. Delete the old `.vmz` from `mods/` rather than leaving both — the loader will
   happily mount two copies and the resulting behaviour is not worth debugging.
2. Copy the new one in.
3. **Fully restart the game** on every machine. The mod does a two-pass
   modloader restart at startup; an in-place reload does not pick up changes.
4. **Every peer must run the identical file.** Mismatched RPC signatures produce
   symptoms that look nothing like a version mismatch.
5. Confirm the mounted file in the log — it names the archive it loaded:

   ```
   [FileScope]   MOUNTED (vmz->zip): .../mods/RTVCoopAlpha-<version>.vmz
   ```

## Testing two instances on one PC

You do not need a second machine or a second person. `CoopNet._input()` binds
loopback keys that are always live, in any scene, regardless of transport:

| Key | Action |
|---|---|
| **F9** | Host over ENet on `127.0.0.1:27015` |
| **F10** | Join `127.0.0.1:27015` |
| **F11** | Disconnect |
| **F8** | Toggle verbose logging |

Verbose logging adds per-agent spawn detail. It is off by default because every
log line is flushed to disk — that flush is what makes `coop_debug.log` survive
the hard crash, and it also means a spawn wave becomes a burst of synchronous
writes. The lines the crash work reads (heartbeat, weapon swaps, AI deaths,
container ids) are always on. The log rolls to `coop_debug.log.1` past 8 MB.

`HostGameEnet()` and `JoinGame()` are unconditionally ENet, so these work even
with GodotSteam loaded — nothing needs to be removed or rebuilt. Note the co-op
menu itself cannot do this: `LobbyUI`'s only join path is `JoinSteam()`, driven
by a Steam lobby callback.

### Procedure

1. Put the same `.vmz` in `mods/` — both instances read the same `res://`, so
   one file covers both.
2. Launch the first instance normally through Steam. At the main menu, press
   **F9**. The log should show `HOSTING on port 27015`.
3. Launch the second instance by running `RTV.exe` directly — Steam refuses to
   start the same app twice. Steam API init will fail without a
   `steam_appid.txt`; that is fine, ENet does not use it.
4. At the second instance's menu, press **F10** (`JOINING 127.0.0.1:27015`).
5. Start a game on the host. The client follows via `HostSceneReady`.

### Isolate the second instance's user directory

Both instances otherwise share `%APPDATA%/Road to Vostok`: the same save files
and the same `user://coop_debug.log`, which each process opens `READ_WRITE` and
seeks to its own end. They will overwrite each other's writes and you will lose
the log you are trying to read.

On Windows `user://` resolves under `%AppData%`, so give the second instance its
own:

```bat
set "APPDATA=C:\rtv-client-profile" && "D:\SteamLibrary\steamapps\common\Road to Vostok\RTV.exe"
```

Verify it took effect — the mod prints its resolved log path at startup:

```
[CoopLogger] Appending to: C:/rtv-client-profile/Road to Vostok/coop_debug.log
```

If that still points at the normal profile, the redirect did not apply and the
two logs are not trustworthy.

### What local testing can and cannot prove

Loopback runs over **ENet**, not `SteamMultiplayerPeer`. That asymmetry matters:

- An arm that **crashes** locally is conclusive — you found it.
- An arm that stays **clean** locally clears nothing. A hard native crash with
  no Godot stack is exactly what a GDExtension fault looks like, and GodotSteam
  is the GDExtension in play. If every arm is clean over ENet but the Steam
  build still dies, the transport itself becomes the prime suspect.

Two instances also share one GPU, and the observed crashes happened during
combat with AI, so the load profile is not the same.

## Bisecting a crash

The game can die as a hard native process termination: no Godot error, no
GDScript stack, the log simply stops mid-line. The crash handler writes to
stderr, which the game's log file does not capture, and the final buffered write
is lost. **Nothing in the logs will name that crash.** Do not spend time reading
them for a cause that is not there — bisect instead.

The ladder for the current investigation is already scripted --
`python tools/mkbisect.py` writes arms 0/A/B/C to `dist/bisect/`, and
`tests/test_bisect.py` checks each arm is the one below it plus exactly one
suspect. See [CRASH-BISECT.md](CRASH-BISECT.md) for what each arm answers.

For a new bisect: because the whole mod is data in a zip, an arm is cheap --
take the known good archive and swap in one changed file.

```python
import zipfile

GOOD = "RTVCoopAlpha-1.0.0.vmz"
with zipfile.ZipFile(GOOD) as zin, zipfile.ZipFile("bisect.vmz", "w") as zout:
    for info in zin.infolist():
        data = zin.read(info.filename)
        if info.filename.endswith("LocalStateSync.gd"):
            data = open("new/LocalStateSync.gd", "rb").read()
        zout.writestr(info, data)
```

Rules that make the result mean something:

- Change **one file per arm**, and keep everything else byte-identical to the
  known good archive.
- Verify the arms afterwards (`diff -rq` on the extracted trees). A build that
  differs in more than you think produces a confident wrong answer.
- Deploy each arm to **every** peer.
- Note which archive the log says it mounted, so an arm cannot be misattributed
  later.

To capture an actual stack instead of bisecting, enable Windows local crash
dumps for the game before the next session (admin shell; the executable is
`RTV.exe`):

```
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\RTV.exe" /v DumpFolder /t REG_EXPAND_SZ /d "%LOCALAPPDATA%\CrashDumps" /f /reg:64
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\RTV.exe" /v DumpType /t REG_DWORD /d 2 /f /reg:64
```

Or launch once with stderr redirected:

```
RTV.exe --verbose > console.txt 2>&1
```

## Logs to collect

Always both peers, and say who did what:

- `%APPDATA%/Road to Vostok/logs/godot.log`
- the newest timestamped log in that folder
- `%APPDATA%/Road to Vostok/coop_debug.log`

`coop_debug.log` appends across sessions; find the last
`=== RTVCoop Instance Start ===` block. Lines are tagged `[HOST]` / `[CLIENT]`,
which is how you tell whose log you are actually holding.

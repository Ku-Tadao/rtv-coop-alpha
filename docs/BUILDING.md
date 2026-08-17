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

Only `res://mods/...` paths are checked. `res://Scripts/...` refers to the
game's own pck, which is not in this repo.

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

## Bisecting a crash

The game can die as a hard native process termination: no Godot error, no
GDScript stack, the log simply stops mid-line. The crash handler writes to
stderr, which the game's log file does not capture, and the final buffered write
is lost. **Nothing in the logs will name that crash.** Do not spend time reading
them for a cause that is not there — bisect instead.

Because the whole mod is data in a zip, a bisect build is cheap: take the known
good archive and swap in one changed file.

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
dumps for the game before the next session (admin shell, and check the exe name
first):

```
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\Road to Vostok.exe" /v DumpFolder /t REG_EXPAND_SZ /d "%LOCALAPPDATA%\CrashDumps" /f /reg:64
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\Road to Vostok.exe" /v DumpType /t REG_DWORD /d 2 /f /reg:64
```

Or launch once with stderr redirected:

```
"Road to Vostok.exe" --verbose > console.txt 2>&1
```

## Logs to collect

Always both peers, and say who did what:

- `%APPDATA%/Road to Vostok/logs/godot.log`
- the newest timestamped log in that folder
- `%APPDATA%/Road to Vostok/coop_debug.log`

`coop_debug.log` appends across sessions; find the last
`=== RTVCoop Instance Start ===` block. Lines are tagged `[HOST]` / `[CLIENT]`,
which is how you tell whose log you are actually holding.

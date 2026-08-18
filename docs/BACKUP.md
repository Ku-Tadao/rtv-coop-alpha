# Backing up a save

Every player should take a copy before a co-op session, and especially while
experimental builds are being tested. A save-corrupting bug has already shipped
once: see the guest-save entry in the [README](../README.md#known-issues).

Saves live in a single folder, and only the `.tres` files there matter — the
subfolders are caches and logs that rebuild themselves:

```
%APPDATA%\Road to Vostok\
```

| File | Holds |
|---|---|
| `Cabin.tres` | The shelter: layout, furniture, and everything stored in it |
| `Character.tres` | Health, inventory, equipment, discovered-items catalog |
| `World.tres` | Day, time, season, weather |
| `Traders.tres` | Trader stock and standing |
| `Tent.tres` | Tent and contents |
| `Validator.tres` | Save integrity data |
| `Preferences.tres` | Settings and keybinds (not progress, but tedious to redo) |

## Procedure

**Close the game before copying or restoring.** Save state is held in memory and
written on exit, so copying a running game can capture a half-written file, and
restoring underneath one gets flattened seconds later.

To back up: copy the `.tres` files to a dated folder outside `AppData`.
To restore: delete the `.tres` files in the live folder, copy the backup ones in,
then check the shelter before playing.

`coop-test/backup-save.bat` in the working tree does the backup half
automatically, writing a timestamped copy to the Desktop. The restore half is
left manual on purpose — it deletes files, and that should be a deliberate act.

## Signs a save was damaged

- Items visible inside a container but positioned outside its grid, unclickable
- Storage emptied, or a container holding far more than it should
- Discovered-items catalog empty despite a long-running save
- Every stat sitting at exactly 100
- Day counter or time of day jumping
- Shelter furniture rearranged, missing, or duplicated

The first two are the signature of a container-id collision; the next two are the
signature of a guest's save being overwritten by the host's world.

## For players, not maintainers

There is a plain-language version of this written for someone who just wants to
play: hand them that rather than this file.

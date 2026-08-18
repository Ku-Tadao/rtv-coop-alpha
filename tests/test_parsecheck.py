"""Does the engine actually accept these scripts?

Everything else in this suite reads GDScript as text. Only Godot knows whether
it parses, and Godot rejects a whole script on a parse error while saying
nothing at the point of use — which is how "remote players are invisible but
still collide" shipped for a release.

Skipped unless Godot is on PATH, the game is installed, and a build exists, so
the rest of the suite still runs anywhere. That means CI does not cover this:
it is a pre-release gate on a machine that has the game, not a push gate.
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import parsecheck  # noqa: E402


def newest_build():
    built = sorted((ROOT / "dist").glob("*.vmz"), key=lambda p: p.stat().st_mtime)
    return built[-1] if built else None


def available() -> bool:
    return bool(
        shutil.which("godot")
        and parsecheck.DEFAULT_PCK.is_file()
        and newest_build()
    )


def run(vmz: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(ROOT / "tools" / "parsecheck.py"), "--vmz", str(vmz)],
        capture_output=True, text=True, timeout=300,
    )


def rebuild_with(vmz: Path, member: str, mutate, dest: Path) -> Path:
    with zipfile.ZipFile(vmz) as zin, zipfile.ZipFile(dest, "w") as zout:
        for info in zin.infolist():
            data = zin.read(info.filename)
            if info.filename == member:
                text = mutate(data.decode("utf-8"))
                data = text.encode("utf-8")
            zout.writestr(info, data)
    return dest


@unittest.skipUnless(available(), "needs godot on PATH, the game installed, and a build")
class TestTheBuildParses(unittest.TestCase):
    def test_the_shipped_build_is_clean(self):
        result = run(newest_build())
        self.assertEqual(
            result.returncode, 0,
            f"parse check failed:\n{result.stdout}\n{result.stderr}",
        )

    def test_unresolved_game_autoloads_are_not_treated_as_failures(self):
        # Roughly a quarter of the mod touches Loader/Database/Simulation, which
        # this tool project cannot register. If that ever counted as an error the
        # check would be useless noise.
        result = run(newest_build())
        self.assertIn("unresolved only by missing game autoloads", result.stdout)
        self.assertIn("0 with real errors", result.stdout)


@unittest.skipUnless(available(), "needs godot on PATH, the game installed, and a build")
class TestItCatchesWhatItIsFor(unittest.TestCase):
    """A gate nobody has seen fail is a gate nobody knows works."""

    def assert_rejected(self, member: str, mutate, needle: str):
        with tempfile.TemporaryDirectory() as tmp:
            broken = rebuild_with(
                newest_build(), member, mutate, Path(tmp) / "broken.vmz"
            )
            result = run(broken)
        self.assertEqual(result.returncode, 1, f"not rejected:\n{result.stdout}")
        self.assertIn(needle, result.stdout)

    def test_a_single_tab_in_a_space_indented_file(self):
        # The exact bug that shipped. Godot rejects the entire script, so the
        # puppet's collider loaded and its model did not.
        self.assert_rejected(
            "mods/RTVCoopAlpha/Game/Types/PlayerModel.gd",
            lambda t: t.replace(
                "    if not is_instance_valid(currentWeaponNode)",
                "\tif not is_instance_valid(currentWeaponNode)",
                1,
            ),
            "Used tab character for indentation",
        )

    def test_a_syntax_error(self):
        self.assert_rejected(
            "mods/RTVCoopAlpha/Game/Sync/PickupSync.gd",
            lambda t: t.replace(
                "func NextPlacementToken() -> int:", "func NextPlacementToken( -> int:", 1
            ),
            "PickupSync.gd",
        )

    def test_a_call_with_the_wrong_argument_count(self):
        # No text-based tool here can see this one.
        self.assert_rejected(
            "mods/RTVCoopAlpha/Game/Sync/PickupSync.gd",
            lambda t: t.replace(
                "_pickup_denied_feedback()", "_pickup_denied_feedback(1, 2)", 1
            ),
            "Too many arguments",
        )


class TestClassification(unittest.TestCase):
    """Runs anywhere: the output parsing is pure text."""

    def test_a_known_autoload_is_filtered(self):
        out = (
            '### res://mods/a.gd\n'
            'SCRIPT ERROR: Parse Error: Identifier "Loader" not declared in the current scope.\n'
            '### done\n'
        )
        real, _ = parsecheck.classify(out)
        self.assertEqual(real, {})

    def test_a_real_error_survives(self):
        out = (
            "### res://mods/a.gd\n"
            "SCRIPT ERROR: Parse Error: Unexpected \"(\" in class body.\n"
            "### done\n"
        )
        real, _ = parsecheck.classify(out)
        self.assertIn("res://mods/a.gd", real)

    def test_an_unknown_identifier_is_not_filtered(self):
        # Only the game's own autoloads get a pass; a typo must not.
        out = (
            '### res://mods/a.gd\n'
            'SCRIPT ERROR: Parse Error: Identifier "Loadr" not declared in the current scope.\n'
            '### done\n'
        )
        real, _ = parsecheck.classify(out)
        self.assertIn("res://mods/a.gd", real)

    def test_errors_are_attributed_to_the_script_being_parsed(self):
        out = (
            "### res://mods/a.gd\n"
            "### res://mods/b.gd\n"
            "SCRIPT ERROR: Parse Error: something wrong.\n"
            "### done\n"
        )
        real, _ = parsecheck.classify(out)
        self.assertEqual(list(real), ["res://mods/b.gd"])


if __name__ == "__main__":
    unittest.main()

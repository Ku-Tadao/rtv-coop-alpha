"""Checks on the packaging step itself.

The mod is shipped as a single archive that players drop into a folder, so the
failure modes that actually bite are structural: a file missing from the zip, a
script the manifest points at that no longer exists, or a script Godot refuses
to parse. `tools/build.py` validates those; this makes sure it keeps working.
"""

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build  # noqa: E402


class TestValidation(unittest.TestCase):
    def test_source_tree_is_valid(self):
        self.assertEqual(build.validate(), [])

    def test_manifest_declares_identity(self):
        manifest = build.parse_manifest((ROOT / "mod.txt").read_text(encoding="utf-8"))
        self.assertEqual(manifest["mod"]["id"], "rtv-coop-alpha")
        self.assertTrue(manifest["mod"]["version"])
        self.assertIn("autoload", manifest)

    def test_mixed_indentation_is_rejected(self):
        # Godot fails the whole script on mixed indentation, so this must be caught
        # at build time -- a broken release already shipped this way once.
        mixed = "func a():\n\tpass\nfunc b():\n    pass\n"
        self.assertTrue(build.check_indentation(ROOT / "mods" / "fake.gd", mixed))

        for consistent in ("func a():\n\tpass\n", "func a():\n    pass\n"):
            self.assertEqual(build.check_indentation(ROOT / "mods" / "fake.gd", consistent), [])


class TestArchive(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.out = Path(self._tmp.name) / "out.vmz"
        self.addCleanup(self._tmp.cleanup)

    def test_archive_contains_every_source_file(self):
        build.build(self.out)
        with zipfile.ZipFile(self.out) as archive:
            self.assertIsNone(archive.testzip())
            names = set(archive.namelist())

        expected = {p.relative_to(ROOT).as_posix() for p in build.source_files()}
        self.assertEqual(names, expected)
        self.assertIn("mod.txt", names)
        # The loader reads mod.txt from the archive root, so no wrapper directory.
        self.assertFalse([n for n in names if n.startswith("rtv-coop-alpha/")])

    def test_build_is_reproducible(self):
        other = self.out.with_name("other.vmz")
        build.build(self.out)
        build.build(other)
        self.assertEqual(self.out.read_bytes(), other.read_bytes())


if __name__ == "__main__":
    unittest.main()


class TestContentDigest(unittest.TestCase):
    """Byte-identical archives were promised and are not achievable across
    platforms -- zlib differs, so CI's deflate output differs from Windows' for
    identical input. The digest is the promise that can actually be kept."""

    def test_a_built_archive_matches_the_source_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = build.build(Path(tmp) / "t.vmz")
            self.assertEqual(build.content_digest(out), build.content_digest())

    def test_it_ignores_how_the_archive_was_packed(self):
        # Repack with different compression and timestamps: same contents, so
        # the same digest. This is exactly the CI-vs-local case.
        with tempfile.TemporaryDirectory() as tmp:
            original = build.build(Path(tmp) / "a.vmz")
            repacked = Path(tmp) / "b.vmz"
            with zipfile.ZipFile(original) as zin, \
                    zipfile.ZipFile(repacked, "w", zipfile.ZIP_STORED) as zout:
                for name in zin.namelist():
                    info = zipfile.ZipInfo(name, (2001, 2, 3, 4, 5, 6))
                    info.create_system = 3
                    zout.writestr(info, zin.read(name))
            self.assertNotEqual(original.read_bytes(), repacked.read_bytes())
            self.assertEqual(
                build.content_digest(original), build.content_digest(repacked)
            )

    def test_changing_one_byte_of_content_changes_the_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            original = build.build(Path(tmp) / "a.vmz")
            tampered = Path(tmp) / "b.vmz"
            with zipfile.ZipFile(original) as zin, \
                    zipfile.ZipFile(tampered, "w") as zout:
                for name in zin.namelist():
                    data = zin.read(name)
                    if name.endswith("Main.gd"):
                        data += b"\n# tampered\n"
                    zout.writestr(name, data)
            self.assertNotEqual(
                build.content_digest(original), build.content_digest(tampered)
            )

    def test_the_host_os_byte_is_pinned(self):
        # Unpinned this records the building OS, so the same sources give
        # different bytes on a developer machine and in CI.
        with tempfile.TemporaryDirectory() as tmp:
            out = build.build(Path(tmp) / "t.vmz")
            with zipfile.ZipFile(out) as zf:
                for info in zf.infolist():
                    self.assertEqual(info.create_system, 0, info.filename)

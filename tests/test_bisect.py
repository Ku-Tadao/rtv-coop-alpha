"""The bisect ladder is only worth running if the arms differ where we think.

A stale source path once produced arms that silently carried the wrong version
of a file, and the build succeeding said nothing about it. This asserts the one
property the experiment depends on: arm N is arm N-1 plus exactly one suspect.
"""

import hashlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import mkbisect  # noqa: E402


class TestLadder(unittest.TestCase):
    def test_arms_differ_only_in_their_suspects(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            self.assertEqual(mkbisect.main(["--out-dir", str(out)]), 0)
            digests = {}
            for arm in mkbisect.ARMS:
                with zipfile.ZipFile(out / f"RTVCoopAlpha-arm{arm}.vmz") as archive:
                    digests[arm] = {n: hashlib.sha256(archive.read(n)).hexdigest()
                                    for n in archive.namelist()}
            for arm, members in mkbisect.ARMS.items():
                self.assertEqual(digests[arm].keys(), digests["0"].keys(), arm)
                changed = {n for n in digests[arm] if digests[arm][n] != digests["0"][n]}
                self.assertEqual(changed, {mkbisect.PREFIX + m for m in members}, arm)


if __name__ == "__main__":
    unittest.main()

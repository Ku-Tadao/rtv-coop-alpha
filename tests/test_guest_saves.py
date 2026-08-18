"""Regressions for local save protection while a guest in someone else's world.

A player joined a host, the host's session ended, and the guest's own Cabin.tres
came back holding the host's cabin contents. Root cause: the four save hooks
guarded on CoopAuthority.is_client(), which returns false the moment the
transport drops -- precisely when the guest is still standing in the host's
world and a save would write the wrong data.
"""

import re
import unittest
from pathlib import Path

MOD = Path(__file__).resolve().parents[1] / "mods" / "RTVCoopAlpha"


def read(rel: str) -> str:
    return (MOD / rel).read_text(encoding="utf-8")


class TestSaveGuard(unittest.TestCase):
    def test_every_save_hook_guards_on_guest(self):
        loader = read("Game/Hooks/LoaderHooks.gd")
        saves = re.findall(r"func _replace_save(\w+)\(.*?\n(.*?)(?=\n\nfunc |\Z)", loader, re.S)
        self.assertEqual(len(saves), 4, "expected character/world/shelter/trader")
        for name, body in saves:
            self.assertIn("is_guest()", body, f"save{name} is not guarded on is_guest")
            self.assertIn("skip_super()", body, f"save{name} does not suppress the save")

    def test_is_client_alone_is_not_enough(self):
        # is_client() short-circuits to false when no session is active, so it
        # cannot protect the window after the host drops.
        auth = read("Framework/CoopAuthority.gd")
        body = auth[auth.index("static func is_client"):]
        body = body[: body.index("static func", 10)]
        self.assertIn("if not is_active():", body)
        self.assertIn("return false", body)


class TestGuestLifecycle(unittest.TestCase):
    def test_flag_is_set_on_both_join_paths(self):
        net = read("Framework/CoopNet.gd")
        for fn in ("_join_enet", "JoinSteam"):
            body = net[net.index(f"func {fn}"):]
            body = body[: body.index("\nfunc ", 1)]
            self.assertIn("_was_guest = true", body, f"{fn} does not mark the session as guest")

    def test_guest_is_ejected_when_the_host_disappears(self):
        net = read("Framework/CoopNet.gd")
        body = net[net.index("func _on_server_disconnected"):]
        body = body[: body.index("\nfunc ", 1)]
        self.assertIn('Loader.LoadScene("Menu")', body)

    def test_flag_clears_only_back_at_the_menu(self):
        loader = read("Game/Hooks/LoaderHooks.gd")
        self.assertIn('scene_name == "Menu"', loader)
        self.assertIn("ClearGuest()", loader)


if __name__ == "__main__":
    unittest.main()

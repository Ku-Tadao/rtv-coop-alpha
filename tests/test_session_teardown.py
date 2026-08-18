"""Every way a host can leave must end the session for the guests.

F11 worked because it calls CoopNet.Disconnect() directly. Returning to the main
menu did not: CoopNet lives outside the scene tree, so the peer survived the
scene change and guests kept playing in a world the host was no longer
simulating.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdsource import func, read  # noqa: E402


class TestHostLeaving(unittest.TestCase):
    def test_returning_to_menu_ends_the_session(self):
        loader = read("Game/Hooks/LoaderHooks.gd")
        body = loader[loader.index("func _on_loadscene_pre"):]
        body = body[: body.index("\nfunc ", 1)]
        self.assertIn('scene_name == "Menu"', body)
        self.assertIn("CoopAuthority.is_host()", body)
        self.assertIn("net.Disconnect()", body)

    def test_quitting_hangs_up_rather_than_timing_out(self):
        net = read("Framework/CoopNet.gd")
        self.assertIn("NOTIFICATION_WM_CLOSE_REQUEST", net)
        exit_tree = net[net.index("func _exit_tree"):]
        exit_tree = exit_tree[: exit_tree.index("\nfunc ", 1)]
        self.assertIn("Disconnect()", exit_tree)


class TestGuestEjection(unittest.TestCase):
    def test_losing_the_host_returns_the_guest_to_the_menu(self):
        net = read("Framework/CoopNet.gd")
        body = net[net.index("func _on_server_disconnected"):]
        body = body[: body.index("\nfunc ", 1)]
        self.assertIn('Loader.LoadScene("Menu")', body)


class TestSharedGameDataIsRestored(unittest.TestCase):
    def test_the_ai_post_hook_is_registered_unconditionally(self):
        ai = read("Game/Hooks/AIHooks.gd")
        setup = ai[ai.index("func _setup_hooks"):]
        setup = setup[: setup.index("\nfunc ", 1)]
        # register_replace_or_post would make the restore a fallback that never runs.
        self.assertIn('CoopHook.register(self, "ai-_physics_process-post"', setup)
        self.assertNotIn('"ai-_physics_process",\n\t\t_replace', setup)

    def test_every_borrowed_field_is_put_back(self):
        ai = read("Game/Hooks/AIHooks.gd")
        borrow = ai[ai.index('a.set_meta("_coop_saved_gd"'):]
        borrow = borrow[: borrow.index("func _post_ai_physics_process")]
        restore = ai[ai.index("func _post_ai_physics_process"):]
        restore = restore[: restore.index("\nfunc ", 1)]
        for field in ("playerPosition", "cameraPosition", "isRunning",
                      "isWalking", "isFiring", "playerVector"):
            self.assertIn(f"gd.{field} =", borrow, f"{field} not borrowed")
            self.assertIn(f"gd.{field} = saved", restore, f"{field} not restored")


if __name__ == "__main__":
    unittest.main()

"""A guest must stop playing when the host *starts* loading, not when it finishes.

HostSceneReady arrives after the host's own scene load plus a 3 s broadcast
delay, so a guest kept full control for five or six seconds in a scene the host
had already left. Loot taken in that window never reached the host, so the item
was still there when anyone walked back to it.

The failure mode this guards against is subtle: ApplySceneChange already existed
as an RPC and was never called by anything. An unused notification path looks
identical to a working one in a diff.
"""

import unittest
from pathlib import Path

MOD = Path(__file__).resolve().parents[1] / "mods" / "RTVCoopAlpha"


def read(rel: str) -> str:
    return (MOD / rel).read_text(encoding="utf-8")


def func(src: str, name: str) -> str:
    body = src[src.index(f"func {name}("):]
    return body[: body.index("\nfunc ", 1)]


class TestGuestsAreToldEarly(unittest.TestCase):
    def test_the_host_broadcasts_from_loadscene_pre(self):
        pre = func(read("Game/Hooks/LoaderHooks.gd"), "_on_loadscene_pre")
        self.assertIn("BroadcastSceneChangeStart(scene_name)", pre)
        self.assertIn("CoopAuthority.is_host()", pre)
        # Must sit above the early return that fires when there is no session seed.
        self.assertLess(pre.index("BroadcastSceneChangeStart"),
                        pre.index("coop_session_seed"))

    def test_the_broadcast_reaches_an_rpc(self):
        flow = read("Game/CoopSceneFlow.gd")
        send = func(flow, "BroadcastSceneChangeStart")
        self.assertIn("BeginSceneChange.rpc(scene_name)", send)
        self.assertIn("multiplayer.is_server()", send)
        # Menu is a session teardown, not a transition; guests get ejected instead.
        self.assertIn('"Menu"', send)

    def test_the_guest_freezes_and_fades(self):
        flow = read("Game/CoopSceneFlow.gd")
        self.assertIn('@rpc("authority", "reliable", "call_remote")\nfunc BeginSceneChange',
                      flow)
        begin = func(flow, "BeginSceneChange")
        self.assertIn("_freeze_for_transition(true)", begin)
        self.assertIn("Loader.FadeIn()", begin)
        self.assertIn("pendingSceneChange = scene_name", begin)

    def test_freeze_sets_both_flags(self):
        freeze = func(read("Game/CoopSceneFlow.gd"), "_freeze_for_transition")
        self.assertIn("isTransitioning = on", freeze)
        self.assertIn("freeze = on", freeze)


class TestTheGuestIsNeverLeftFrozen(unittest.TestCase):
    """Every path that clears pendingSceneChange without loading must unfreeze."""

    def test_host_scene_ready_already_in_target_scene(self):
        body = func(read("Game/CoopSceneFlow.gd"), "HostSceneReady")
        head = body[: body.index("_players.SaveClientCharacterBuffer()")]
        self.assertIn("_freeze_for_transition(false)", head)
        self.assertIn("Loader.FadeOut()", head)

    def test_the_90_second_timeout(self):
        body = func(read("Game/CoopSceneFlow.gd"), "_physics_process")
        window = body[body.index("SCENE_CHANGE_TIMEOUT"):]
        window = window[: window.index("ScanIfNeeded")]
        self.assertIn("_freeze_for_transition(false)", window)

    def test_the_client_spawn_clears_it_after_a_real_load(self):
        spawn = func(read("Game/Hooks/CompilerHooks.gd"), "_coop_client_spawn")
        self.assertIn("gd.isTransitioning = false", spawn)
        self.assertIn("gd.freeze = false", spawn)


if __name__ == "__main__":
    unittest.main()

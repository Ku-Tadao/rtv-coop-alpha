"""An AI's dropped gear must not claim a uuid a world item already owns.

Drop ids used to be derived as `uuid * 10 + n` so host and client could compute
them without transmitting anything. World items are numbered 0..N from a
different counter that starts at the same place, and host logs show scenes
registering 85-143 items -- so the first AI's weapon claimed uuid 1, which a
scene pickup already had. Two nodes then answer to one id and
BroadcastPickupRemove frees whichever one `worldItems` happens to hold.

The fix replaces derivation with transmission, which only works if *every* site
agrees: two host paths mint (either can fire first) and one client path adopts.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mods" / "RTVCoopAlpha"


def read(rel: str) -> str:
    return (MOD / rel).read_text(encoding="utf-8")


def func(src: str, name: str) -> str:
    body = src[src.index(f"func {name}("):]
    return body[: body.index("\nfunc ", 1)]


def gd_sources():
    for path in sorted(MOD.rglob("*.gd")):
        yield path.relative_to(MOD).as_posix(), path.read_text(encoding="utf-8")


class TestTheFormulaIsGone(unittest.TestCase):
    def test_no_source_derives_a_drop_id_arithmetically(self):
        pattern = re.compile(r"uuid\s*\*\s*10")
        for rel, src in gd_sources():
            for n, line in enumerate(src.splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue  # the comment explaining why it is gone
                self.assertIsNone(pattern.search(line), f"{rel}:{n}: {line.strip()}")


class TestHostMints(unittest.TestCase):
    """Both host paths must number drops; either can fire first."""

    def test_ai_sync_death_watcher_mints(self):
        body = func(read("Game/Sync/AISync.gd"), "_watch_ai_deaths")
        self.assertIn("NumberAIDrops(players, ai)", body)
        self.assertIn("drop_ids", body)

    def test_ai_hook_death_mints_before_broadcasting(self):
        body = func(read("Game/Hooks/AIHooks.gd"), "_replace_ai_death")
        self.assertIn("NumberAIDrops(players, a)", body)
        self.assertLess(
            body.index("NumberAIDrops"),
            body.index("BroadcastAIDeath.rpc"),
            "ids must exist before the call that carries them",
        )

    def test_ids_come_from_the_world_item_counter(self):
        body = func(read("Game/Sync/AISync.gd"), "NumberAIDrops")
        self.assertIn("players.GenerateUuid()", body)
        self.assertIn("players.worldItems[u] = part", body)

    def test_missing_gear_uses_minus_one_not_zero(self):
        # 0 is a valid world item id, so it cannot mean "no drop".
        body = func(read("Game/Sync/AISync.gd"), "NumberAIDrops")
        self.assertIn("PackedInt32Array([-1, -1, -1])", body)


class TestClientAdopts(unittest.TestCase):
    def test_the_rpc_carries_the_ids(self):
        src = read("Game/Sync/AISync.gd")
        sig = src[src.index("func BroadcastAIDeath("):]
        sig = sig[: sig.index("\n")]
        self.assertIn("drop_ids: PackedInt32Array", sig)

    def test_the_handler_applies_rather_than_derives(self):
        body = func(read("Game/Sync/AISync.gd"), "BroadcastAIDeath")
        self.assertIn("ApplyAIDropIds(players, ai, drop_ids)", body)

    def test_apply_skips_the_sentinel(self):
        body = func(read("Game/Sync/AISync.gd"), "ApplyAIDropIds")
        self.assertIn("if u < 0", body)

    def test_both_callers_pass_the_ids(self):
        for rel, name in [
            ("Game/Sync/AISync.gd", "_watch_ai_deaths"),
            ("Game/Hooks/AIHooks.gd", "_replace_ai_death"),
        ]:
            body = func(read(rel), name)
            call = body[body.index("BroadcastAIDeath.rpc(") :]
            call = call[: call.index("\n")]
            self.assertIn("drop_ids", call, rel)


class TestLerpWeightsAreClamped(unittest.TestCase):
    """Above 1.0 a lerp weight overshoots and oscillates -- worst under load."""

    def test_every_per_frame_lerp_clamps(self):
        for rel, name in [
            ("Game/Sync/AISync.gd", "_physics_process"),
            ("Game/Types/Puppet.gd", "_physics_process"),
            ("Game/Sync/PickupSync.gd", "_lerp_pickup_targets"),
            ("Game/Sync/WorldSync.gd", "_lerp_targets"),
        ]:
            body = func(read(rel), name)
            self.assertIn("clampf(", body, f"{rel}:{name} lerps unclamped")


class TestEventSystemLookupIsBounded(unittest.TestCase):
    """The fallback walks the whole tree; it must not run every frame forever."""

    def test_physics_process_throttles_and_gives_up(self):
        body = func(read("Game/Sync/EventSync.gd"), "_physics_process")
        self.assertIn("_event_system_retry", body)
        self.assertIn("EVENT_SYSTEM_MAX_RETRIES", body)
        self.assertIn("_pending_events.clear()", body)
        self.assertNotIn("_find_event_system()", body, "must go through the cache")

    def test_the_cache_is_cleared_on_map_change(self):
        flow = func(read("Game/CoopSceneFlow.gd"), "ScanIfNeeded")
        self.assertIn("reset_scene_state()", flow)
        reset = func(read("Game/Sync/EventSync.gd"), "reset_scene_state")
        self.assertIn("_event_system_cache = null", reset)
        self.assertIn("_pending_events.clear()", reset)


class TestSmallCleanups(unittest.TestCase):
    def test_dead_placement_token_helper_is_gone(self):
        # It burned a real world-item uuid and nothing called it; InterfaceHooks
        # uses PickupSync's own counter.
        self.assertNotIn("func NextPlacementToken", read("Game/CoopPlayers.gd"))

    def test_state_packet_is_sized_to_what_it_carries(self):
        body = func(read("Framework/PlayerStateProxy.gd"), "_pack")
        self.assertIn("p.resize(14)", body)
        unpack = func(read("Framework/PlayerStateProxy.gd"), "_unpack")
        self.assertIn("p.size() < 14", unpack)


if __name__ == "__main__":
    unittest.main()

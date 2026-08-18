"""Costs that only show up under load, where nobody is looking.

None of these change behaviour, so nothing in a play session will reveal a
regression. They are asserted statically or they rot.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdsource import func, read  # noqa: E402


class TestContainerLookupIsCached(unittest.TestCase):
    """The host sends one container RPC per container; each used to cost a scan
    of the CoopLootContainer group plus a parent-walk of every Interactable."""

    def test_lookup_consults_the_cache_first(self):
        body = func(read("Game/Sync/ContainerSync.gd"), "_find_container_by_id")
        self.assertIn("_cid_cache.get(cid)", body)
        self.assertNotIn('get_nodes_in_group("Interactable")', body)

    def test_rebuilds_are_capped_at_one_per_frame(self):
        # Without this an unknown id makes every RPC in the burst rebuild.
        body = func(read("Game/Sync/ContainerSync.gd"), "_find_container_by_id")
        self.assertIn("Engine.get_process_frames()", body)
        self.assertIn("if frame == _cid_cache_frame", body)

    def test_rebuild_keeps_the_group_adoption(self):
        # Group membership is what decides whether a container syncs at all.
        body = func(read("Game/Sync/ContainerSync.gd"), "_rebuild_cid_cache")
        self.assertIn('add_to_group("CoopLootContainer")', body)

    def test_cache_is_dropped_on_map_change(self):
        reset = func(read("Game/Sync/ContainerSync.gd"), "reset_scene_state")
        self.assertIn("_cid_cache.clear()", reset)
        self.assertIn("_container_holders.clear()", reset)
        self.assertIn("reset_scene_state()", func(read("Game/CoopSceneFlow.gd"), "ScanIfNeeded"))


class TestStateGatherDoesNotReResolvePaths(unittest.TestCase):
    """GatherLocalAnimState runs at 20Hz forever; the nodes change per scene."""

    def test_no_string_path_lookups_in_the_gather(self):
        body = func(read("Game/Sync/LocalStateSync.gd"), "GatherLocalAnimState")
        for path in ("Core/Camera/Manager", "Core/UI/Interface", "Core/Camera"):
            self.assertNotIn(
                f'get_node_or_null("{path}")', body, f"{path} re-resolved per broadcast"
            )

    def test_the_cache_revalidates(self):
        body = func(read("Game/Sync/LocalStateSync.gd"), "_refresh_scene_nodes")
        self.assertIn("is_instance_valid(_rig_manager)", body)
        self.assertIn("scene == _cached_scene", body)


class TestLogVolume(unittest.TestCase):
    def test_per_agent_spawn_detail_is_behind_the_verbose_flag(self):
        src = read("Game/Sync/AISync.gd")
        for name in ("_deferred_activate", "_full_equipment_from_variant"):
            body = func(src, name)
            for line in body.splitlines():
                stripped = line.strip()
                self.assertFalse(
                    stripped.startswith("_log("),
                    f"{name}: unconditional log line: {stripped}",
                )

    def test_the_expensive_diagnostic_is_not_built_when_unused(self):
        body = func(read("Game/Sync/AISync.gd"), "_full_equipment_from_variant")
        self.assertIn("if _verbose():", body)
        self.assertLess(body.index("if _verbose():"), body.index("type_string"))

    def test_lines_the_crash_work_reads_stay_unconditional(self):
        # Heartbeat, weapon swaps, AI deaths and container ids must survive
        # whatever the verbose flag is set to.
        self.assertIn('log_msg("Heartbeat"', read("Game/CoopLogger.gd"))
        self.assertIn("_log(\"BroadcastAIDeath applying", read("Game/Sync/AISync.gd"))
        self.assertIn('_coop_log("swap to=', read("Game/Types/PlayerModel.gd"))

    def test_the_flush_per_line_is_intact(self):
        # This is what makes the log survive the hard native crash. Do not
        # "optimise" it away; the verbose tier exists so it does not have to go.
        body = func(read("Game/CoopLogger.gd"), "log_msg")
        self.assertIn("_file.flush()", body)

    def test_the_log_rolls(self):
        src = read("Game/CoopLogger.gd")
        self.assertIn("LOG_ROLL_BYTES", src)
        self.assertIn("_roll_if_large()", func(src, "_ready"))


class TestDebugInstrumentationIsNotShipped(unittest.TestCase):
    """A player must not be able to change how the game looks by leaning on a
    function key, with no way to put it back."""

    def test_the_spine_slider_is_gone(self):
        src = read("Game/Types/PlayerModel.gd")
        self.assertNotIn("KEY_F6", src)
        self.assertNotIn("KEY_F7", src)
        self.assertNotIn("func _input", src)
        self.assertIn("const SPINE_SHARE", src)

    def test_tunables_are_constants_not_mutable_statics(self):
        src = read("Game/Types/PlayerModel.gd")
        self.assertNotIn("static var spine_share", src)
        self.assertNotIn("static var spine_pitch_min", src)


if __name__ == "__main__":
    unittest.main()

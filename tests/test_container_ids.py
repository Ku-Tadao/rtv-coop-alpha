"""Regressions for container / furniture id addressing.

Symptom that produced these: opening a Locker in the cabin opened a Nightstand.
Two independent counters were writing into the same `coop_container_id` meta
key, and clients were assigning unmatched ids to whichever container happened to
be nearest -- so two nodes ended up holding id 15 and lookup is first-match-wins.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdsource import func, read  # noqa: E402


class TestClientNeverInventsIds(unittest.TestCase):
    def test_no_position_based_matching(self):
        container = read("Game/Sync/ContainerSync.gd")
        # Guessing a container by proximity assigns an id the host never gave it,
        # which then shadows the node that legitimately owns that id.
        self.assertNotIn("_find_container_near", container)
        self.assertNotIn("matched by position", container)

    def test_unassigned_id_resolves_to_nothing(self):
        # _node_id() reports 0 for a node that was never assigned an id.
        self.assertIn("if cid <= 0:", read("Game/Sync/ContainerSync.gd"))


class TestSingleIdSource(unittest.TestCase):
    def test_scene_pass_skips_shelter_furniture(self):
        scene_flow = read("Game/CoopSceneFlow.gd")
        self.assertIn("if _is_shelter_furniture(root):", scene_flow)
        self.assertLess(
            scene_flow.index("if _is_shelter_furniture(root):"),
            scene_flow.index('root.set_meta("coop_container_id", _players.nextContainerId)'),
            "furniture must be skipped before the scene counter stamps it",
        )

    def test_furniture_still_joins_the_sync_group(self):
        # Regression: skipping furniture for id assignment also skipped
        # add_to_group("CoopLootContainer"), which dropped those containers out of
        # sync entirely and made the host broadcast them with cid 0.
        scene_flow = read("Game/CoopSceneFlow.gd")
        self.assertLess(
            scene_flow.index('root.add_to_group("CoopLootContainer")'),
            scene_flow.index("if _is_shelter_furniture(root):"),
            "group membership must be decided before the id-source skip",
        )

    def test_unregistered_containers_are_not_broadcast(self):
        # A container with no host-assigned id has nothing to say, and the receiver
        # rejects cid <= 0 anyway -- broadcasting it is pure log noise.
        scene_flow = read("Game/CoopSceneFlow.gd")
        body = scene_flow[scene_flow.index("func _broadcast_container_storage_to"):]
        body = body[: body.index("BroadcastContainerFullState.rpc")]
        self.assertIn("cid <= 0", body)

    def test_furniture_ids_start_past_the_sentinel(self):
        # _broadcast_shelter_furniture treats fid 0 as "no players" and skips the
        # item, so a counter starting at 0 dropped the first furniture every load.
        self.assertIn("var nextFurnitureId: int = 1", read("Game/CoopPlayers.gd"))
        self.assertNotIn("nextFurnitureId = 0", read("Game/CoopPlayers.gd"))
        self.assertNotIn("_players.nextFurnitureId = 0", read("Game/CoopSceneFlow.gd"))


class TestResolutionSemantics(unittest.TestCase):
    """Lookup is first-match-wins, so a duplicate id silently opens the wrong box."""

    @staticmethod
    def resolve(nodes: dict, cid: int):
        if cid <= 0:
            return None
        return next((name for name, i in nodes.items() if i == cid), None)

    def test_duplicate_id_returns_the_wrong_container(self):
        observed = {"Nightstand": 15, "Locker": 15}  # what position matching produced
        self.assertEqual(self.resolve(observed, 15), "Nightstand")

    def test_distinct_ids_resolve_correctly(self):
        fixed = {"Nightstand": 24, "Locker": 15, "Unregistered": 0}
        self.assertEqual(self.resolve(fixed, 15), "Locker")
        self.assertIsNone(self.resolve(fixed, 0))


if __name__ == "__main__":
    unittest.main()

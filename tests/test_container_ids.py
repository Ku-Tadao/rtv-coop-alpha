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


class TestGuestsLearnSceneContainerIds(unittest.TestCase):
    """Only the host numbers scene containers, so the guest has to be told which
    of its own nodes owns each id.

    Removing the proximity fallback fixed a Locker opening a Nightstand and, in
    the same stroke, deleted the only way a guest ever learned a scene
    container's id at all -- so guests could open corpses and death stashes
    (numbered by an RPC on every peer) and nothing that loaded with the map.
    """

    def test_the_host_sends_the_node_path(self):
        body = func(read("Game/CoopSceneFlow.gd"), "_broadcast_container_storage_to")
        self.assertIn("str(root.get_path())", body)
        self.assertIn("node_path", body)

    def test_locked_containers_are_still_numbered(self):
        # The contents broadcast skips them, so before the id manifest a locked
        # container never got an id on the guest -- and unlocking it later left
        # it permanently unopenable for them.
        body = func(read("Game/CoopSceneFlow.gd"), "_broadcast_container_storage_to")
        manifest = body[: body.index("if root.locked:")]
        self.assertIn("BroadcastContainerIds", manifest)
        self.assertNotIn("root.locked", manifest, "numbering must not skip locked")

    def test_locked_container_contents_are_not_sent(self):
        # They are generated from the per-visit seed, so both peers already
        # agree, and nothing can have changed in a container nobody can open.
        body = func(read("Game/CoopSceneFlow.gd"), "_broadcast_container_storage_to")
        state = body[body.index("if root.locked:"):]
        self.assertIn("continue", state)
        self.assertIn("BroadcastContainerFullState", state)

    def test_the_manifest_is_sent_before_the_contents(self):
        body = func(read("Game/CoopSceneFlow.gd"), "_broadcast_container_storage_to")
        self.assertLess(
            body.index("BroadcastContainerIds"),
            body.index("BroadcastContainerFullState"),
        )

    def test_the_manifest_adopts_through_the_same_exact_path(self):
        body = func(read("Game/Sync/ContainerSync.gd"), "BroadcastContainerIds")
        self.assertIn("_adopt_container_id(", body)

    def test_an_unnumbered_entry_is_refused(self):
        body = func(read("Game/Sync/ContainerSync.gd"), "_adopt_container_id")
        self.assertIn("cid <= 0", body)

    def test_the_guest_adopts_the_id_from_the_path(self):
        body = func(read("Game/Sync/ContainerSync.gd"), "BroadcastContainerFullState")
        self.assertIn("_adopt_container_id(node_path, cid)", body)

    def test_adoption_is_exact_not_a_guess(self):
        body = func(read("Game/Sync/ContainerSync.gd"), "_adopt_container_id")
        self.assertIn("get_node_or_null(node_path)", body)
        self.assertIn("node is LootContainer", body)
        # A node that already owns a different id must not be renumbered --
        # that is how two nodes came to answer to one id in the first place.
        self.assertIn("existing != cid", body)

    def test_the_position_fallback_stays_gone(self):
        src = read("Game/Sync/ContainerSync.gd")
        self.assertNotIn("_find_container_near", src)

    def test_adoption_populates_the_lookup_cache(self):
        # Otherwise the node is not findable until the cache next rebuilds.
        body = func(read("Game/Sync/ContainerSync.gd"), "_adopt_container_id")
        self.assertIn("_cid_cache[cid] = node", body)


class TestTraderDressingIsNotTakeable(unittest.TestCase):
    """A guest could take trader display items the host could not.

    RegisterSceneItems runs a second after the map loads, and dressing that is
    not parented under the trader yet gets numbered and broadcast. The host's
    interact goes through InteractorHooks, which asks about trader ownership
    before it asks about the uuid, so the host never noticed. The Pickup.Interact
    path only asked about the uuid.
    """

    def test_both_interact_paths_check_trader_ownership(self):
        for rel, name in [
            ("Game/Hooks/InteractorHooks.gd", "_replace_interactor_interact"),
            ("Game/Hooks/LootHooks.gd", "_replace_pickup_interact"),
        ]:
            body = func(read(rel), name)
            self.assertIn("_is_trader_display_item", body, rel)

    def test_ownership_is_checked_before_the_uuid(self):
        body = func(read("Game/Hooks/LootHooks.gd"), "_replace_pickup_interact")
        self.assertLess(
            body.index("_is_trader_display_item"),
            body.index('get_meta("network_uuid"'),
            "a numbered trader item would slip through",
        )

    def test_a_late_adoption_drops_the_id_again(self):
        body = func(read("Game/CoopSceneFlow.gd"), "RegisterSceneItems")
        self.assertIn("remove_meta(\"network_uuid\")", body)
        self.assertIn("worldItems.erase", body)


class TestUnarmedPoseMatches100(unittest.TestCase):
    def test_no_unarmed_special_case(self):
        # 1.0.0 fell through to the rifle carry -- an empty assault rifle. Trader
        # is the rig's only empty-handed clip and it is a standing pose, so it
        # reads worse the moment the player moves.
        body = func(read("Game/Types/PlayerModel.gd"), "_pick_animation")
        self.assertNotIn('return "Trader"', body)
        self.assertNotIn('hasWeapon', body)

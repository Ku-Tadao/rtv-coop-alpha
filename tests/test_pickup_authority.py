"""A guest must never pick up an item the host has not numbered.

Found in play: an AI's carried weapon could be taken off a paused, pooled agent
on the client, and then taken again off the corpse when that AI died -- the same
gun twice. Clients grow AI pools locally (AISync._grow_pool), so those weapons
exist only on the guest and carry no host-assigned uuid.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdsource import func, read  # noqa: E402


class TestPickupAuthority(unittest.TestCase):
    def setUp(self):
        src = read("Game/Hooks/InteractorHooks.gd")
        start = src.index('is_in_group("Item")')
        self.branch = src[start : src.index("\n\tif ", start + 10)]

    def test_unnumbered_items_are_refused_on_clients(self):
        self.assertIn("CoopAuthority.is_client()", self.branch)
        after_uuid = self.branch[self.branch.index('has_meta("network_uuid")'):]
        self.assertIn("skip_super()", after_uuid.split("CoopAuthority.is_client()")[1])

    def test_no_prompt_for_an_item_that_cannot_be_taken(self):
        # Showing "pick up" and then doing nothing reads as a broken control.
        self.assertIn("gd.interaction = false", self.branch)

    def test_numbered_items_still_route_through_the_host(self):
        self.assertIn("RequestPickup(uuid)", self.branch)

    def test_trader_dressing_stays_blocked(self):
        self.assertIn("_is_trader_display_item", self.branch)


if __name__ == "__main__":
    unittest.main()


class TestOneItemOneTaker(unittest.TestCase):
    """Two guests interacting with the same pickup at the same moment both used
    to succeed: the item went into the local inventory first and the host was
    told afterwards. Containers have always asked first; this mirrors them."""

    def test_a_guest_asks_before_taking(self):
        body = func(read("Game/Sync/PickupSync.gd"), "RequestPickup")
        self.assertIn("RequestPickupClaim.rpc_id(1, uuid)", body)
        # The taking must not happen on the guest's own say-so.
        guest_branch = body[body.index("if CoopAuthority.is_host():"):]
        guest_branch = guest_branch[guest_branch.index("RequestPickupClaim"):]
        self.assertNotIn("_take_pickup", guest_branch)

    def test_the_host_still_takes_immediately(self):
        body = func(read("Game/Sync/PickupSync.gd"), "RequestPickup")
        self.assertIn("if CoopAuthority.is_host():", body)
        self.assertIn("_take_pickup(uuid)", body)

    def test_the_host_respects_a_guest_claim(self):
        # Otherwise the arbitration only binds the peers that do not matter.
        body = func(read("Game/Sync/PickupSync.gd"), "RequestPickup")
        host_branch = body[body.index("if CoopAuthority.is_host():"):]
        self.assertIn("_pickup_claims.has(uuid)", host_branch)

    def test_a_second_claimant_is_denied(self):
        body = func(read("Game/Sync/PickupSync.gd"), "RequestPickupClaim")
        self.assertIn("get_remote_sender_id()", body)
        self.assertIn("DenyPickup.rpc_id(sender, uuid)", body)
        self.assertIn("GrantPickup.rpc_id(sender, uuid)", body)

    def test_an_item_that_is_gone_is_denied_not_granted(self):
        body = func(read("Game/Sync/PickupSync.gd"), "RequestPickupClaim")
        self.assertIn("players.worldItems.has(uuid)", body)
        self.assertIn("is_instance_valid", body)


class TestAClaimIsAlwaysGivenBack(unittest.TestCase):
    """Every way a claim can end. A stranded claim locks the item for everyone
    for the rest of the session, which is worse than the bug being fixed."""

    def test_a_full_inventory_releases_it(self):
        body = func(read("Game/Sync/PickupSync.gd"), "GrantPickup")
        self.assertIn("if not _take_pickup(uuid):", body)
        self.assertIn("ReleasePickupClaim.rpc_id(1, uuid)", body)

    def test_taking_it_clears_it(self):
        body = func(read("Game/Sync/PickupSync.gd"), "SubmitPickupRemove")
        self.assertIn("_pickup_claims.erase(uuid)", body)

    def test_only_the_holder_may_release_it(self):
        body = func(read("Game/Sync/PickupSync.gd"), "ReleasePickupClaim")
        self.assertIn('int(_pickup_claims[uuid]["peer"]) == sender', body)

    def test_a_peer_that_never_answers_times_out(self):
        body = func(read("Game/Sync/PickupSync.gd"), "_expire_pickup_claims")
        self.assertIn("_pickup_claims.erase(uuid)", body)
        self.assertIn("_awaiting_grant.erase(uuid)", body)

    def test_disconnecting_releases_it(self):
        self.assertIn(
            "release_claims_for_peer",
            func(read("Game/CoopPlayers.gd"), "_on_peer_left"),
        )

    def test_changing_scene_clears_everything(self):
        reset = func(read("Game/Sync/PickupSync.gd"), "reset_scene_state")
        self.assertIn("_pickup_claims.clear()", reset)
        self.assertIn("_awaiting_grant.clear()", reset)
        self.assertIn("reset_scene_state()", func(read("Game/CoopSceneFlow.gd"), "ScanIfNeeded"))


class TestHoldingInteractIsOneRequest(unittest.TestCase):
    def test_a_pending_request_is_not_repeated(self):
        body = func(read("Game/Sync/PickupSync.gd"), "RequestPickup")
        self.assertIn("if _awaiting_grant.has(uuid):", body)
        self.assertLess(body.index("_awaiting_grant.has(uuid)"), body.index("RequestPickupClaim"))

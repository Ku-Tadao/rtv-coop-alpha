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

"""Who is allowed to write player state.

Player proxies are `State_<peer_id>` nodes, one per player, and they never call
set_multiplayer_authority -- so their authority stays the default, peer 1, the
host. That fact is what the annotations below rely on, and it is why setting
authority to the owning peer would silently invert them.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdsource import func, read, sources  # noqa: E402

PROXY = "Framework/PlayerStateProxy.gd"


class TestHostToPeers(unittest.TestCase):
    def test_apply_broadcast_is_host_only(self):
        src = read(PROXY)
        self.assertIn(
            '@rpc("authority", "unreliable", "call_remote")\nfunc _apply_broadcast(',
            src,
            "any_peer here lets a client drive another player's puppet",
        )

    def test_only_the_host_sends_it(self):
        body = func(read(PROXY), "_push_state")
        self.assertIn("if multiplayer.is_server():", body)
        self.assertIn("_apply_broadcast.rpc(", body)
        self.assertIn("_submit_to_host.rpc_id(1,", body)


class TestPeerToHost(unittest.TestCase):
    def test_submit_checks_the_sender_owns_the_proxy(self):
        body = func(read(PROXY), "_submit_to_host")
        self.assertIn("multiplayer.get_remote_sender_id() != peer_id", body)
        self.assertIn("peer_id == 0", body, "an unowned proxy must accept nothing")

    def test_the_check_runs_before_the_payload_is_applied(self):
        body = func(read(PROXY), "_submit_to_host")
        self.assertLess(body.index("get_remote_sender_id()"), body.index("_unpack(payload)"))

    def test_every_proxy_learns_its_owner(self):
        body = func(read("Game/Coop.gd"), "ensure_player_proxy")
        # Both branches: a proxy reached through the existing-node path is the
        # one most likely to have been created before its id was known.
        self.assertEqual(body.count("peer_id = peer_id"), 2)


class TestAuthorityIsNotReassigned(unittest.TestCase):
    def test_nothing_sets_multiplayer_authority_on_a_proxy(self):
        # Comments are where this rule is *explained*, so only code counts.
        for rel, src in sources():
            for n, line in enumerate(src.splitlines(), 1):
                code = line.split("#", 1)[0]
                self.assertNotIn(
                    "set_multiplayer_authority",
                    code,
                    f'{rel}:{n}: reassigning authority inverts @rpc("authority")',
                )


if __name__ == "__main__":
    unittest.main()

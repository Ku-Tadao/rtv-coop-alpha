"""The RPC linter has to actually catch things, or it is decoration.

Each case here is a mistake that has already been made in this repo or is one
edit away from being made. The mod's own sources must lint clean; the mutations
must not.
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import lint_rpc  # noqa: E402


def sources() -> dict:
    return lint_rpc.load_sources()


def mutate(files: dict, rel: str, old: str, new: str) -> dict:
    out = dict(files)
    assert old in out[rel], f"fixture text not found in {rel}: {old!r}"
    out[rel] = out[rel].replace(old, new, 1)
    return out


class TestTheModIsClean(unittest.TestCase):
    def test_no_rpc_errors(self):
        report = lint_rpc.lint(sources())
        self.assertEqual([f"{e.file}:{e.line}: {e.message}" for e in report.errors], [])

    def test_no_uncalled_rpcs(self):
        # An @rpc nothing calls is how guests learned about scene changes six
        # seconds late, and how door state was never synced at all.
        report = lint_rpc.lint(sources())
        self.assertEqual([f"{w.file}:{w.line}: {w.message}" for w in report.warnings], [])

    def test_it_finds_the_rpcs_at_all(self):
        # Guards against a regex change that silently matches nothing, which
        # would make every other assertion here vacuously true.
        self.assertGreater(len(lint_rpc.collect_rpcs(sources())), 100)


class TestItCatchesRealMistakes(unittest.TestCase):
    def assert_errors(self, files: dict, needle: str):
        report = lint_rpc.lint(files)
        joined = " | ".join(e.message for e in report.errors)
        self.assertTrue(report.errors, "expected an error, got none")
        self.assertIn(needle, joined)

    def test_call_site_missed_when_a_signature_grew(self):
        # Arity alone cannot see this: the trailing parameter has a default, so
        # the short call is legal GDScript and the handler silently gets one.
        files = mutate(
            sources(),
            "Game/Hooks/AIHooks.gd",
            "secondary_dict, _corpse_cid, drop_ids)",
            "secondary_dict, _corpse_cid)",
        )
        self.assert_errors(files, "disagree")

    def test_too_many_arguments(self):
        files = mutate(
            sources(),
            "Game/Sync/PickupSync.gd",
            "BroadcastPickupRemove.rpc(uuid)",
            "BroadcastPickupRemove.rpc(uuid, 1, 2)",
        )
        self.assert_errors(files, "passes 3 arg(s)")

    def test_handler_renamed_leaving_a_stale_call(self):
        files = mutate(
            sources(),
            "Game/Sync/PickupSync.gd",
            "func BroadcastPickupRemove(uuid: int)",
            "func BroadcastPickupRemoved(uuid: int)",
        )
        self.assert_errors(files, "names no @rpc function")

    def test_an_rpc_that_nothing_calls(self):
        files = mutate(
            sources(),
            "Game/Sync/PickupSync.gd",
            "SubmitPickupRemove.rpc_id(1, uuid)",
            "pass",
        )
        report = lint_rpc.lint(files)
        self.assertIn(
            "@rpc `SubmitPickupRemove` is never called",
            " | ".join(w.message for w in report.warnings),
        )

    def test_rpc_id_does_not_count_the_peer_id(self):
        # `X.rpc_id(1, a)` and `X.rpc(a)` both pass one argument to the handler.
        files = mutate(
            sources(),
            "Game/Sync/PickupSync.gd",
            "SubmitPickupRemove.rpc_id(1, uuid)",
            "SubmitPickupRemove.rpc_id(1, uuid, 99)",
        )
        self.assert_errors(files, "passes 2 arg(s)")


class TestDeliberateOptionalArgsAreAllowed(unittest.TestCase):
    def test_the_opt_out_silences_the_disagreement(self):
        files = sources()
        self.assertIn("lint-rpc: optional-args", files["Game/Sync/AISync.gd"])
        report = lint_rpc.lint(files)
        self.assertNotIn("RequestAISync", " | ".join(e.message for e in report.errors))

    def test_removing_the_opt_out_brings_the_error_back(self):
        files = mutate(
            sources(), "Game/Sync/AISync.gd", "# lint-rpc: optional-args", "#"
        )
        report = lint_rpc.lint(files)
        self.assertIn("RequestAISync", " | ".join(e.message for e in report.errors))


class TestArgumentSplitting(unittest.TestCase):
    """Miscounting arguments would make the whole tool lie."""

    def test_nested_calls_and_literals_count_as_one(self):
        cases = [
            ("a, b, c", 3),
            ("a, foo(b, c), d", 3),
            ("[1, 2, 3], {'k': 'v'}", 2),
            ('"a, b", c', 2),
            ("PackedInt32Array([1, 2]), Vector3(0, 0, 0)", 2),
            ("", 0),
            ("f(g(h(1, 2), 3), 4)", 1),
        ]
        for text, expected in cases:
            self.assertEqual(
                len(lint_rpc._split_top_level(text)), expected, f"splitting {text!r}"
            )

    def test_typed_and_defaulted_params_are_told_apart(self):
        self.assertEqual(lint_rpc._param_arity("a: int, b: Dictionary = {}"), (1, 2))
        self.assertEqual(lint_rpc._param_arity("uuid: int, pos: Vector3"), (2, 2))
        self.assertEqual(lint_rpc._param_arity(""), (0, 0))
        self.assertEqual(
            lint_rpc._param_arity("p: PackedFloat32Array, s: String = \"\""), (1, 2)
        )

class TestUncheckedSenders(unittest.TestCase):
    """An `any_peer` handler is reachable by every client. If it never asks who
    is calling, it acts on whatever it is sent, by whoever sends it."""

    def test_dropping_an_is_server_guard_is_caught(self):
        files = mutate(
            sources(),
            "Game/Sync/PickupSync.gd",
            "func SubmitPickupRemove(uuid: int) -> void:\n\tif not multiplayer.is_server():\n\t\treturn\n",
            "func SubmitPickupRemove(uuid: int) -> void:\n",
        )
        report = lint_rpc.lint(files)
        self.assertIn(
            "never checks who is calling",
            " | ".join(e.message for e in report.errors),
        )

    def test_a_sender_id_check_counts_too(self):
        # Peer-to-peer handlers are legitimate; they just have to establish the
        # sender rather than believe the payload.
        rpcs = lint_rpc.collect_rpcs(sources())
        gain = rpcs["BroadcastMicGain"]
        self.assertIn("any_peer", gain.modes)
        self.assertIn("get_remote_sender_id()", gain.body)

    def test_the_sender_is_not_taken_from_the_payload(self):
        # It used to name itself, so a peer could mute someone else for you.
        rpcs = lint_rpc.collect_rpcs(sources())
        self.assertNotIn("peer_id: int", rpcs["BroadcastMicGain"].body.splitlines()[0])

if __name__ == "__main__":
    unittest.main()

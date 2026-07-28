import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "docker" / "worker"))
from workspace_reclaimer import WorkspaceReclaimer, active_issue_identifiers


def state(**overrides):
    value = {
        "running": [],
        "retrying": [],
        "blocked": [],
        "pending": {"issues": []},
    }
    value.update(overrides)
    return value


class WorkspaceReclaimerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "workspaces"
        self.root.mkdir()
        self.state_path = Path(self.temporary.name) / "state.json"
        self.reclaimer = WorkspaceReclaimer(
            self.root,
            self.state_path,
            confirmations=2,
            grace_seconds=3600,
            wall_clock=lambda: 10_000,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def workspace(self, identifier):
        path = self.root / identifier
        path.mkdir()
        (path / "evidence").write_text("kept until safe", encoding="utf-8")
        return path

    def terminal(self, state_type="completed", terminal_at="1970-01-01T01:00:00Z"):
        return {"state_type": state_type, "terminal_at": terminal_at}

    def test_requires_two_terminal_observations_before_removal(self):
        path = self.workspace("A-218")
        issues = {"A-218": self.terminal()}
        self.assertEqual(self.reclaimer.reclaim(state(), issues), [])
        self.assertTrue(path.exists())
        self.assertEqual(self.reclaimer.reclaim(state(), issues), ["A-218"])
        self.assertFalse(path.exists())

    def test_never_removes_running_retrying_blocked_or_pending_workspaces(self):
        fields = {
            "running": [{"issue_identifier": "A-1"}],
            "retrying": [{"issue_identifier": "A-2"}],
            "blocked": [{"issue_identifier": "A-3"}],
            "pending": {"issues": [{"issue_identifier": "A-4"}]},
        }
        issues = {}
        for identifier in ("A-1", "A-2", "A-3", "A-4"):
            self.workspace(identifier)
            issues[identifier] = self.terminal()
        self.state_path.write_text(
            json.dumps({identifier: 1 for identifier in issues}),
            encoding="utf-8",
        )
        self.assertEqual(self.reclaimer.reclaim(state(**fields), issues), [])
        self.assertTrue(all((self.root / identifier).exists() for identifier in issues))

    def test_preserves_nonterminal_recent_unresolved_and_system_directories(self):
        self.workspace("A-10")
        self.workspace("A-11")
        self.workspace("A-12")
        (self.root / "codex-home").mkdir()
        issues = {
            "A-10": {"state_type": "started", "terminal_at": None},
            "A-11": self.terminal(terminal_at="1970-01-01T02:30:00Z"),
        }
        self.state_path.write_text(json.dumps({"A-10": 1, "A-11": 1, "A-12": 1}), encoding="utf-8")
        self.assertEqual(self.reclaimer.reclaim(state(), issues), [])
        self.assertTrue(all(path.exists() for path in self.root.iterdir()))

    def test_fails_closed_on_invalid_symphony_state(self):
        self.workspace("A-20")
        with self.assertRaises(ValueError):
            self.reclaimer.reclaim({"running": []}, {"A-20": self.terminal()})

    def test_active_identifier_collection_deduplicates_all_runtime_queues(self):
        self.assertEqual(
            active_issue_identifiers(state(
                running=[{"issue_identifier": "A-1"}],
                retrying=[{"issue_identifier": "A-1"}],
                blocked=[{"issue_identifier": "A-2"}],
                pending={"issues": [{"issue_identifier": "A-3"}]},
            )),
            {"A-1", "A-2", "A-3"},
        )


if __name__ == "__main__":
    unittest.main()

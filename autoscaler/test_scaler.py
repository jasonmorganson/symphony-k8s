import unittest
import os
import tempfile
from unittest import mock
from scaler import Scaler, UsageLedger, desired_workers, stable_session_id


class UsageLedgerTest(unittest.TestCase):
    def test_composite_turn_ids_share_one_stable_session(self):
        thread = "019f570a-95f5-7060-b695-f1469907d96d"
        first = f"{thread}-019f5720-470c-7da2-b5b9-cdb8df0287a3"
        second = f"{thread}-019f5723-7a6d-75b1-b842-296d8407dd3c"
        self.assertEqual(stable_session_id(first), thread)
        with tempfile.TemporaryDirectory() as directory:
            ledger = UsageLedger(os.path.join(directory, "usage.json"))
            ledger.observe({"running": [{
                "issue_identifier": "A-142", "session_id": first, "turn_count": 13,
                "tokens": {"input_tokens": 100, "output_tokens": 10, "total_tokens": 110},
            }]})
            ledger.observe({"running": [{
                "issue_identifier": "A-142", "session_id": second, "turn_count": 15,
                "tokens": {"input_tokens": 120, "output_tokens": 12, "total_tokens": 132},
            }]})
            snapshot = ledger.snapshot()
            self.assertEqual(list(snapshot["sessions"]), [thread])
            self.assertEqual(snapshot["issues"]["A-142"]["input_tokens"], 120)

    def test_reload_migrates_composite_session_records_without_summing(self):
        thread = "019f570a-95f5-7060-b695-f1469907d96d"
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "usage.json")
            sessions = {}
            for suffix, tokens, ended in (("019f5720-470c-7da2-b5b9-cdb8df0287a3", 100, 3),
                                           ("019f5723-7a6d-75b1-b842-296d8407dd3c", 120, None)):
                composite = f"{thread}-{suffix}"
                sessions[composite] = {
                    "session_id": composite, "issue_identifier": "A-142", "started_at": None,
                    "first_observed_at": 1, "last_observed_at": 2, "ended_at": ended,
                    "turn_count": 2, "input_tokens": tokens, "output_tokens": 10,
                    "total_tokens": tokens + 10,
                }
            with open(path, "w", encoding="utf-8") as target:
                import json
                json.dump({"version": 1, "sessions": sessions}, target)
            ledger = UsageLedger(path)
            self.assertEqual(list(ledger.sessions), [thread])
            self.assertEqual(ledger.sessions[thread]["input_tokens"], 120)
            self.assertEqual(ledger.sessions[thread]["output_tokens"], 10)
            self.assertEqual(ledger.sessions[thread]["total_tokens"], 130)
            self.assertEqual(ledger.sessions[thread]["turn_count"], 2)
            self.assertEqual(ledger.sessions[thread]["first_observed_at"], 1)
            self.assertEqual(ledger.sessions[thread]["last_observed_at"], 2)
            self.assertIsNone(ledger.sessions[thread]["ended_at"])
    def test_persists_session_high_water_marks_and_issue_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "usage.json")
            clock = [100]
            ledger = UsageLedger(path, now=lambda: clock[0])
            ledger.observe({"running": [{
                "issue_identifier": "A-142", "session_id": "thread-1",
                "started_at": "2026-07-12T00:00:00Z", "turn_count": 2,
                "tokens": {"input_tokens": 100, "output_tokens": 10, "total_tokens": 110},
            }]})
            clock[0] = 110
            ledger.observe({"running": [{
                "issue_identifier": "A-142", "session_id": "thread-1",
                "turn_count": 3,
                "tokens": {"input_tokens": 90, "output_tokens": 12, "total_tokens": 102},
            }]})
            restored = UsageLedger(path, now=lambda: 120)
            snapshot = restored.snapshot()
            self.assertEqual(snapshot["sessions"]["thread-1"]["input_tokens"], 100)
            self.assertEqual(snapshot["sessions"]["thread-1"]["output_tokens"], 12)
            self.assertEqual(snapshot["sessions"]["thread-1"]["turn_count"], 3)
            self.assertEqual(snapshot["issues"]["A-142"]["sessions"], 1)
            self.assertEqual(snapshot["issues"]["A-142"]["total_tokens"], 112)

    def test_records_end_and_multiple_sessions_per_issue(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "usage.json")
            clock = [100]
            ledger = UsageLedger(path, now=lambda: clock[0])
            ledger.observe({"running": [{
                "issue_identifier": "A-1", "session_id": "one", "turn_count": 1,
                "tokens": {"input_tokens": 10, "output_tokens": 2, "total_tokens": 12},
            }]})
            clock[0] = 110
            ledger.observe({"running": []})
            clock[0] = 120
            ledger.observe({"running": [{
                "issue_identifier": "A-1", "session_id": "two", "turn_count": 1,
                "tokens": {"input_tokens": 20, "output_tokens": 3, "total_tokens": 23},
            }]})
            snapshot = ledger.snapshot()
            self.assertEqual(snapshot["sessions"]["one"]["ended_at"], 110)
            self.assertIsNone(snapshot["sessions"]["two"]["ended_at"])
            self.assertEqual(snapshot["issues"]["A-1"]["sessions"], 2)
            self.assertEqual(snapshot["issues"]["A-1"]["input_tokens"], 30)

    def test_corrupt_file_is_quarantined_before_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "usage.json")
            with open(path, "w", encoding="utf-8") as target:
                target.write("not-json")
            ledger = UsageLedger(path)
            self.assertEqual(ledger.sessions, {})
            self.assertEqual(ledger.load_errors, 1)
            self.assertFalse(os.path.exists(path))
            with open(f"{path}.corrupt.{int(ledger.now())}", encoding="utf-8") as source:
                self.assertEqual(source.read(), "not-json")

    def test_wrong_json_schema_is_quarantined(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "usage.json")
            with open(path, "w", encoding="utf-8") as target:
                target.write('{"sessions":[]}')
            ledger = UsageLedger(path, now=lambda: 42)
            self.assertEqual(ledger.load_errors, 1)
            self.assertTrue(os.path.exists(f"{path}.corrupt.42"))

    def test_incomplete_session_schema_is_quarantined(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "usage.json")
            with open(path, "w", encoding="utf-8") as target:
                target.write('{"sessions":{"thread-1":{}}}')
            ledger = UsageLedger(path, now=lambda: 43)
            self.assertEqual(ledger.load_errors, 1)
            self.assertTrue(os.path.exists(f"{path}.corrupt.43"))

    def test_quarantine_failure_prevents_destructive_recovery_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "usage.json")
            with open(path, "w", encoding="utf-8") as target:
                target.write("not-json")
            with mock.patch("scaler.os.replace", side_effect=OSError("readonly")):
                ledger = UsageLedger(path)
            self.assertTrue(ledger.quarantine_failed)
            with self.assertRaises(OSError):
                ledger.observe({"running": []})
            with open(path, encoding="utf-8") as source:
                self.assertEqual(source.read(), "not-json")

    def test_retention_removes_oldest_ended_sessions_only(self):
        with tempfile.TemporaryDirectory() as directory:
            ledger = UsageLedger(os.path.join(directory, "usage.json"), maximum_sessions=2)
            for session_id in ("one", "two", "three"):
                ledger.observe({"running": [{
                    "issue_identifier": "A-1", "session_id": session_id,
                    "tokens": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
                }]})
            self.assertEqual(set(ledger.sessions), {"two", "three"})
            self.assertIsNone(ledger.sessions["three"]["ended_at"])

    def test_invalid_state_items_are_ignored_and_invalid_root_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            ledger = UsageLedger(os.path.join(directory, "usage.json"))
            ledger.observe({"running": [None, {"session_id": 1, "issue_identifier": "A-1"}]})
            self.assertEqual(ledger.sessions, {})
            with self.assertRaises(ValueError):
                ledger.observe([])

    def test_atomic_replace_failure_preserves_prior_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "usage.json")
            ledger = UsageLedger(path)
            ledger.observe({"running": []})
            with open(path, encoding="utf-8") as source:
                prior = source.read()
            with mock.patch("scaler.os.replace", side_effect=OSError("disk")):
                with self.assertRaises(OSError):
                    ledger.observe({"running": []})
            with open(path, encoding="utf-8") as source:
                self.assertEqual(source.read(), prior)
            self.assertEqual(ledger.write_errors, 1)


class DesiredWorkersTest(unittest.TestCase):
    def test_capacity_bands(self):
        cases = {0: 0, 1: 2, 2: 2, 3: 3, 4: 4, 5: 5, 99: 5}
        for issues, expected in cases.items():
            with self.subTest(issues=issues):
                self.assertEqual(desired_workers(issues), expected)

    def test_custom_bounds(self):
        self.assertEqual(desired_workers(8, agents_per_worker=2, minimum=1, maximum=3), 3)


class FakeScaler(Scaler):
    def __init__(self):
        self.clock = 0
        self.now = lambda: self.clock
        self.minimum = 2
        self.maximum = 5
        self.agents_per_worker = 1
        self.cooldown_seconds = 1200
        self.low_demand_since = None
        self.issues = 0
        self.busy = 0
        self.workers = 2
        self.changes = []
        self.fail = False
        self.fail_symphony = False
        self.fail_kubernetes = False
        self.fail_write = False
        self.metrics = {"healthy": 0, "desired": 2, "queue": 0, "current": 2,
                        "cooldown": 0, "errors": 0, "last_error": "starting"}

    def linear_issue_count(self):
        if self.fail:
            raise RuntimeError("unavailable")
        return self.issues

    def symphony_busy(self):
        if self.fail_symphony:
            raise RuntimeError("symphony unavailable")
        return self.busy

    def current_workers(self):
        if self.fail_kubernetes:
            raise RuntimeError("kubernetes unavailable")
        return self.workers, "42"

    def set_workers(self, replicas, resource_version):
        self.assert_resource_version = resource_version
        if self.fail_write:
            raise RuntimeError("scale write failed")
        self.workers = replicas
        self.changes.append(replicas)


class ReconcileTest(unittest.TestCase):
    def test_scales_up_immediately(self):
        scaler = FakeScaler()
        scaler.issues = 13
        scaler.run_once()
        self.assertEqual(scaler.changes, [5])
        self.assertEqual(scaler.assert_resource_version, "42")
        self.assertEqual(scaler.metrics["healthy"], 1)

    def test_scale_down_waits_for_idle_cooldown(self):
        scaler = FakeScaler()
        scaler.workers = 5
        scaler.issues = 3
        scaler.busy = 1
        scaler.run_once()
        self.assertEqual(scaler.changes, [])
        scaler.busy = 0
        scaler.run_once()
        scaler.clock = 1199
        scaler.run_once()
        self.assertEqual(scaler.changes, [])
        scaler.clock = 1200
        scaler.run_once()
        self.assertEqual(scaler.changes, [3])

    def test_zero_demand_scales_to_zero_after_idle_cooldown(self):
        scaler = FakeScaler()
        scaler.workers = 2
        scaler.issues = 0
        scaler.run_once()
        scaler.clock = 1199
        scaler.run_once()
        self.assertEqual(scaler.changes, [])
        scaler.clock = 1200
        scaler.run_once()
        self.assertEqual(scaler.changes, [0])

    def test_new_work_wakes_two_workers_immediately(self):
        scaler = FakeScaler()
        scaler.workers = 0
        scaler.issues = 1
        scaler.run_once()
        self.assertEqual(scaler.changes, [2])

    def test_failure_retains_capacity_and_recovers(self):
        scaler = FakeScaler()
        scaler.workers = 4
        scaler.fail = True
        scaler.run_once()
        self.assertEqual(scaler.workers, 4)
        self.assertEqual(scaler.metrics["healthy"], 0)
        scaler.fail = False
        scaler.issues = 12
        scaler.run_once()
        self.assertEqual(scaler.metrics["healthy"], 1)

    def test_symphony_failure_resets_scale_down_cooldown(self):
        scaler = FakeScaler()
        scaler.workers = 5
        scaler.run_once()
        scaler.clock = 1199
        scaler.fail_symphony = True
        scaler.run_once()
        scaler.clock = 1201
        scaler.fail_symphony = False
        scaler.run_once()
        self.assertEqual(scaler.changes, [])

    def test_kubernetes_failures_retain_capacity(self):
        scaler = FakeScaler()
        scaler.workers = 4
        scaler.fail_kubernetes = True
        scaler.run_once()
        self.assertEqual(scaler.workers, 4)
        scaler.fail_kubernetes = False
        scaler.issues = 15
        scaler.fail_write = True
        scaler.run_once()
        self.assertEqual(scaler.workers, 4)


if __name__ == "__main__":
    unittest.main()

import unittest
from scaler import Scaler, desired_workers


class DesiredWorkersTest(unittest.TestCase):
    def test_capacity_bands(self):
        cases = {0: 0, 1: 2, 6: 2, 7: 3, 9: 3, 10: 4, 12: 4, 13: 5, 15: 5, 99: 5}
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
        self.agents_per_worker = 3
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
        self.assertEqual(scaler.changes, [2])

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

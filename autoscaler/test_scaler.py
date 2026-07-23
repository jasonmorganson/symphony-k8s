import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr
from datetime import datetime, timezone
from unittest import mock
from scaler import (ApprovalHandoff, Scaler, UsageLedger, desired_workers,
                    load_requester_policy, metrics_lines, requester_approval_is_current,
                    stable_session_id, tracker_demand, worker_pool_activity)


def requester_policy():
    return {
        "$schema": "./requester-policy.schema.json",
        "schema_version": 1,
        "repository": "withAutograph/arrusted-development",
        "machine_login": "autograph-symphony",
        "runtime_scope": ["local", "vm", "container", "kubernetes"],
        "requester": {
            "source": "linear_issue_creator",
            "resolution": "exactly_one_mapping_or_fail_closed",
            "creator_email_mappings": [{
                "linear_creator_email": "jason@withgraph.com",
                "github_login": "jasonmorganson",
            }],
        },
        "pull_request": {
            "attached_open_count": 1,
            "author": "machine_login",
            "reconciliation": {
                "none": "create", "one": "reuse_and_repair", "ambiguous": "fail_closed"},
            "required_body_metadata": [
                "requester", "canonical_linear_issue_link", "exactly_one_fixes_issue_id"],
            "review_request": "mapped_requester_on_create_or_reuse",
        },
        "approval_handoff": {
            "source_state": "Human Review",
            "destination_state": "Merging",
            "review_pull_request": "attached_open_pull_request",
            "actor": "mapped_requester",
            "actor_type": "human",
            "state": "APPROVED",
            "latest_by": "submitted_at",
            "ignored_review_states": ["COMMENTED"],
            "conflicting_latest_timestamp": "fail_closed",
            "concurrent_state_drift": "fail_closed",
        },
        "monitor": {
            "owner": "existing_workflow_monitor",
            "polling": "existing_monitor_loop",
            "discovery": "github_open_machine_pull_requests",
            "linear_access": "approved_candidates_only",
            "github_credential": "github-machine-arrusted-symphony",
        },
        "_requester_by_email": {"jason@withgraph.com": "jasonmorganson"},
    }


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
        cases = {0: 0, 1: 1, 5: 5, 10: 10, 99: 10}
        for issues, expected in cases.items():
            with self.subTest(issues=issues):
                self.assertEqual(desired_workers(issues), expected)

    def test_custom_bounds(self):
        self.assertEqual(desired_workers(8, agents_per_worker=2, minimum=1, maximum=3), 3)


class TrackerDemandTest(unittest.TestCase):
    def test_reads_runnable_and_blocked_counts_from_symphony_state(self):
        state = {
            "tracker": {
                "runnable_issues": 3,
                "blocked_issues": 2,
                "observed_at": "2026-07-23T17:00:00Z",
            },
        }
        self.assertEqual(tracker_demand(state), (3, 2))

    def test_missing_or_malformed_tracker_observation_fails_closed(self):
        malformed = (
            {},
            {"tracker": None},
            {"tracker": {"runnable_issues": 1, "blocked_issues": 0}},
            {"tracker": {
                "runnable_issues": True,
                "blocked_issues": 0,
                "observed_at": "2026-07-23T17:00:00Z",
            }},
            {"tracker": {
                "runnable_issues": 1,
                "blocked_issues": -1,
                "observed_at": "2026-07-23T17:00:00Z",
            }},
            {"tracker": {
                "runnable_issues": 1,
                "blocked_issues": 0,
                "observed_at": "garbage",
            }},
        )
        for state in malformed:
            with self.subTest(state=state), self.assertRaises(ValueError):
                tracker_demand(state)

    def test_rejects_stale_or_future_observations(self):
        for observed_at in ("2026-07-23T16:50:00Z", "2026-07-23T17:01:00Z"):
            state = {"tracker": {
                "runnable_issues": 1,
                "blocked_issues": 0,
                "observed_at": observed_at,
            }}
            with self.subTest(observed_at=observed_at), self.assertRaisesRegex(
                    ValueError, "stale Symphony tracker demand"):
                tracker_demand(
                    state,
                    now=datetime.fromisoformat("2026-07-23T17:00:00+00:00").timestamp(),
                    maximum_age_seconds=300)


class ScalerInitializationTest(unittest.TestCase):
    def test_capacity_initializes_when_optional_handoff_credentials_are_absent(self):
        environment = {
            "KUBERNETES_SERVICE_HOST": "kubernetes.default.svc",
            "SYMPHONY_WORKER_DRAIN_TOKEN": "d" * 32,
        }
        ledger = mock.Mock(load_errors=0)

        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch("builtins.open", mock.mock_open(read_data="service-account-token")), \
                mock.patch("scaler.ssl.create_default_context", return_value=object()), \
                mock.patch("scaler.UsageLedger", return_value=ledger):
            scaler = Scaler()

        self.assertFalse(hasattr(scaler, "linear_key"))
        self.assertFalse(hasattr(scaler, "project_slug"))
        self.assertIsNone(scaler.approval_handoff)


class WorkerPoolActivityTest(unittest.TestCase):
    def test_returns_floor_above_highest_running_or_retrying_host(self):
        state = {
            "counts": {"running": 1, "retrying": 1},
            "running": [{"worker_host": "symphony-worker-0"}],
            "retrying": [{"worker_host": "symphony-worker-2"}],
            "worker_pool": {
                "configured_hosts": ["symphony-worker-0", "symphony-worker-1", "symphony-worker-2"],
                "drained_hosts": [],
            },
        }
        self.assertEqual(worker_pool_activity(state, 3),
                         (2, 3, ["symphony-worker-0", "symphony-worker-1", "symphony-worker-2"]))

    def test_reordered_or_wrong_statefulset_hosts_fail_closed(self):
        for configured in (
                ["symphony-worker-1", "symphony-worker-0"],
                ["other-worker-0", "other-worker-1"],
                ["symphony-worker-0.symphony-worker", "symphony-worker-2.symphony-worker"]):
            state = {
                "counts": {"running": 0, "retrying": 0},
                "running": [], "retrying": [],
                "worker_pool": {"configured_hosts": configured, "drained_hosts": []},
            }
            with self.subTest(configured=configured), self.assertRaises(ValueError):
                worker_pool_activity(state, 2)

    def test_fqdn_hosts_preserve_statefulset_ordinal_mapping(self):
        hosts = [f"symphony-worker-{index}.symphony-worker.symphony.svc" for index in range(2)]
        state = {
            "counts": {"running": 1, "retrying": 0},
            "running": [{"worker_host": hosts[1]}], "retrying": [],
            "worker_pool": {"configured_hosts": hosts, "drained_hosts": []},
        }
        self.assertEqual(worker_pool_activity(state, 2), (1, 2, hosts))

    def test_unknown_placement_and_malformed_pool_fail_closed(self):
        states = [
            {
                "counts": {"running": 1, "retrying": 0},
                "running": [{"worker_host": "symphony-worker-9"}],
                "retrying": [],
                "worker_pool": {"configured_hosts": ["symphony-worker-0"], "drained_hosts": []},
            },
            {
                "counts": {"running": 0, "retrying": 0},
                "running": [],
                "retrying": [],
                "worker_pool": {"configured_hosts": [{"bad": "host"}], "drained_hosts": []},
            },
        ]
        for state in states:
            with self.subTest(state=state), self.assertRaises(ValueError):
                worker_pool_activity(state, 1)


class WorkerDrainRequestTest(unittest.TestCase):
    def test_uses_bearer_token_and_requires_exact_acknowledgement(self):
        scaler = Scaler.__new__(Scaler)
        scaler.symphony_drains_url = "http://symphony/api/v1/worker-drains"
        scaler.symphony_drain_token = "d" * 32
        scaler.request_json = mock.Mock(return_value={
            "drained_hosts": ["worker-2"],
            "active_drained_hosts": [],
        })

        self.assertEqual(scaler.set_worker_drains(["worker-2"])["drained_hosts"], ["worker-2"])
        _, kwargs = scaler.request_json.call_args
        self.assertEqual(kwargs["method"], "PUT")
        self.assertEqual(kwargs["headers"]["Authorization"], f"Bearer {'d' * 32}")

        scaler.request_json.return_value = {
            "drained_hosts": [],
            "active_drained_hosts": [],
        }
        with self.assertRaises(ValueError):
            scaler.set_worker_drains(["worker-2"])


class CurrentWorkersTest(unittest.TestCase):
    def scaler_with_response(self, response):
        scaler = Scaler.__new__(Scaler)
        scaler.token = "token"
        scaler.ssl_context = object()
        scaler.request_json = mock.Mock(return_value=response)
        scaler.scale_url = mock.Mock(return_value="https://kubernetes/scale")
        return scaler

    def test_reads_desired_replicas_from_spec(self):
        scaler = self.scaler_with_response({
            "metadata": {"resourceVersion": "42"},
            "spec": {"replicas": 2},
            "status": {"replicas": 1},
        })
        self.assertEqual(scaler.current_workers(), (2, "42"))

    def test_reads_zero_replicas_from_status_when_spec_omits_field(self):
        scaler = self.scaler_with_response({
            "metadata": {"resourceVersion": "43"},
            "spec": {},
            "status": {"replicas": 0, "selector": "app=symphony-worker"},
        })
        self.assertEqual(scaler.current_workers(), (0, "43"))

    def test_malformed_scale_responses_fail_closed(self):
        responses = [
            {"metadata": {"resourceVersion": "44"}, "spec": {}, "status": {}},
            {"metadata": {"resourceVersion": "44"}, "spec": {}, "status": {"replicas": "0"}},
            {"metadata": {"resourceVersion": "44"}, "spec": {}, "status": {"replicas": -1}},
            {"metadata": {}, "spec": {}, "status": {"replicas": 0}},
        ]
        for response in responses:
            with self.subTest(response=response), self.assertRaises(ValueError):
                self.scaler_with_response(response).current_workers()


class ApprovalHandoffTest(unittest.TestCase):
    def setUp(self):
        self.policy = requester_policy()
        self.clock = [1000]
        self.handoff = ApprovalHandoff(
            "arrusted", "linear", "github", self.policy, mock.Mock(),
            wall_clock=lambda: self.clock[0], retry_clock=lambda: self.clock[0])
        self.pull = {
            "number": 504,
            "state": "open",
            "user": {"login": "autograph-symphony"},
            "head": {"sha": "head-504"},
            "body": (
                "Requester: Jason Morganson (jason@withgraph.com) "
                "(@jasonmorganson)\n"
                "Linear issue: [A-210]"
                "(https://linear.app/withgraph/issue/A-210/approval-handoff)\n\n"
                "Fixes A-210"
            ),
        }
        self.issue = {
            "id": "issue-210",
            "identifier": "A-210",
            "url": "https://linear.app/withgraph/issue/A-210/approval-handoff",
            "creator": {"email": "jason@withgraph.com"},
            "state": {"name": "Human Review"},
            "project": {"slugId": "arrusted"},
            "attachments": {
                "nodes": [
                    {"url": "https://github.com/withAutograph/arrusted-development/pull/504"},
                    {"url": "https://github.com/withAutograph/arrusted-development/pull/494"},
                ],
                "pageInfo": {"hasNextPage": False},
            },
            "team": {"states": {"nodes": [
                {"id": "review-state", "name": "Human Review"},
                {"id": "merging-state", "name": "Merging"},
            ]}},
        }
        self.approval = {
            "user": {"login": "jasonmorganson", "type": "User"},
            "state": "APPROVED",
            "submitted_at": "2026-07-23T16:00:12Z",
        }

    def test_policy_loader_rejects_contract_drift(self):
        for mutate in (
                "state", "mapping", "extra", "nested_extra", "repository",
                "machine_login", "runtime_scope", "reconciliation",
                "schema_reference", "boolean_version", "boolean_pr_count",
                "malformed_email", "discovery", "linear_access"):
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as directory:
                policy = requester_policy()
                policy.pop("_requester_by_email")
                if mutate == "state":
                    policy["approval_handoff"]["source_state"] = "In Review"
                elif mutate == "mapping":
                    policy["requester"]["creator_email_mappings"].append(
                        dict(policy["requester"]["creator_email_mappings"][0]))
                elif mutate == "extra":
                    policy["unexpected"] = True
                elif mutate == "nested_extra":
                    policy["approval_handoff"]["unexpected"] = True
                elif mutate in ("repository", "machine_login", "runtime_scope"):
                    policy[mutate] = "wrong"
                elif mutate == "reconciliation":
                    policy["pull_request"]["reconciliation"]["one"] = "replace"
                elif mutate == "schema_reference":
                    policy["$schema"] = "./wrong.schema.json"
                elif mutate == "boolean_version":
                    policy["schema_version"] = True
                elif mutate == "boolean_pr_count":
                    policy["pull_request"]["attached_open_count"] = True
                elif mutate == "discovery":
                    policy["monitor"]["discovery"] = "linear_review_issues"
                elif mutate == "linear_access":
                    policy["monitor"]["linear_access"] = "every_poll"
                else:
                    policy["requester"]["creator_email_mappings"][0][
                        "linear_creator_email"] = "@"
                path = os.path.join(directory, "policy.json")
                with open(path, "w", encoding="utf-8") as target:
                    json.dump(policy, target)
                with self.assertRaises(ValueError):
                    load_requester_policy(path)

    def test_policy_loader_accepts_canonical_schema_bound_policy(self):
        policy = requester_policy()
        policy.pop("_requester_by_email")
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "policy.json")
            with open(path, "w", encoding="utf-8") as target:
                json.dump(policy, target)
            loaded = load_requester_policy(path)
        self.assertEqual(loaded["$schema"], "./requester-policy.schema.json")
        self.assertEqual(loaded["repository"], "withAutograph/arrusted-development")
        self.assertEqual(loaded["approval_handoff"]["source_state"], "Human Review")
        self.assertEqual(
            loaded["_requester_by_email"],
            {"jason@withgraph.com": "jasonmorganson"},
        )

    def test_open_pull_request_discovery_is_paginated_and_keeps_all_authors(self):
        first = [
            {**self.pull, "number": number, "user": {"login": "someone"}}
            for number in range(1, 101)
        ]
        self.handoff.github = mock.Mock(side_effect=[first, [self.pull]])
        pulls = list(self.handoff.open_pull_requests())
        self.assertEqual(len(pulls), 101)
        self.assertEqual(pulls[0]["user"]["login"], "someone")
        self.assertIn("page=2", self.handoff.github.call_args_list[1].args[0])

    def test_effective_requester_approval_positive_and_negative_cases(self):
        self.assertTrue(requester_approval_is_current(
            [self.approval], 504, "jasonmorganson"))
        later_comment = {
            **self.approval, "state": "COMMENTED", "submitted_at": "2026-07-23T17:00:00Z"}
        self.assertTrue(requester_approval_is_current(
            [later_comment, self.approval], 504, "jasonmorganson"))

        cases = {
            "no approval": [],
            "wrong actor": [{**self.approval, "user": {
                "login": "someone-else", "type": "User"}}],
            "bot actor": [{**self.approval, "user": {
                "login": "jasonmorganson", "type": "Bot"}}],
            "wrong pull request": [{**self.approval, "pull_request_number": 507}],
            "later change request": [self.approval, {
                **self.approval, "state": "CHANGES_REQUESTED",
                "submitted_at": "2026-07-23T17:00:00Z"}],
            "later dismissal": [self.approval, {
                **self.approval, "state": "DISMISSED",
                "submitted_at": "2026-07-23T17:00:00Z"}],
            "conflicting timestamp": [self.approval, {
                **self.approval, "state": "CHANGES_REQUESTED"}],
            "malformed timestamp": [{**self.approval, "submitted_at": "not-a-time"}],
            "impossible timestamp": [{
                **self.approval, "submitted_at": "2026-02-30T12:00:00Z"}],
        }
        for label, reviews in cases.items():
            with self.subTest(label=label):
                self.assertFalse(requester_approval_is_current(
                    reviews, 504, "jasonmorganson"))

    def test_reviews_are_paginated(self):
        first = [{**self.approval, "id": index} for index in range(100)]
        self.handoff.github = mock.Mock(side_effect=[first, [self.approval]])
        self.assertEqual(len(self.handoff.reviews(504)), 101)
        self.assertIn("page=2", self.handoff.github.call_args_list[1].args[0])

    def test_idle_and_unapproved_cycles_make_zero_linear_requests(self):
        pull_229 = {
            **self.pull,
            "number": 507,
            "head": {"sha": "head-507"},
            "body": self.pull["body"].replace("A-210", "A-229"),
        }
        self.handoff.open_pull_requests = mock.Mock(return_value=iter([pull_229]))
        self.handoff.reviews = mock.Mock(return_value=[])
        self.handoff.linear = mock.Mock()
        outcomes = self.handoff.reconcile()
        self.assertEqual(outcomes, {
            "observed": 1, "linear_candidates": 0, "linear_requests": 0,
            "deferred": 0, "transitioned": 0, "failed": 0,
        })
        self.handoff.linear.assert_not_called()

        self.handoff.open_pull_requests.return_value = iter([])
        outcomes = self.handoff.reconcile()
        self.assertEqual(outcomes["linear_requests"], 0)
        self.handoff.linear.assert_not_called()

    def test_a210_approval_reads_then_mutates_linear_and_ignores_merged_attachment(self):
        self.handoff.open_pull_requests = mock.Mock(return_value=iter([self.pull]))
        self.handoff.reviews = mock.Mock(return_value=[self.approval])
        self.handoff.fresh_issue = mock.Mock(return_value=self.issue)
        self.handoff.github_authorization_is_fresh = mock.Mock(return_value=True)
        self.handoff.transition = mock.Mock()
        with mock.patch.object(
                self.handoff, "linear", wraps=self.handoff.linear) as linear:
            outcome = self.handoff.reconcile_pull(self.pull)
        self.assertEqual(outcome, "transitioned")
        self.handoff.fresh_issue.assert_called_once_with("A-210")
        self.handoff.transition.assert_called_once_with("issue-210", "merging-state")
        linear.assert_not_called()

    def test_approved_candidate_uses_exactly_one_read_and_one_mutation(self):
        def request_json(url, **kwargs):
            if "pulls?state=open" in url:
                return [self.pull]
            if "/reviews?" in url:
                return [self.approval]
            if url.endswith("/pulls/504"):
                return self.pull
            if url.endswith("/pulls/494"):
                return {
                    "number": 494, "state": "closed",
                    "user": {"login": "autograph-symphony"},
                }
            body = json.loads(kwargs["data"])
            if "ApprovalHandoffIssue" in body["query"]:
                return {"data": {"issue": self.issue}}
            return {"data": {"issueUpdate": {
                "success": True,
                "issue": {"id": "issue-210", "state": {"name": "Merging"}},
            }}}

        self.handoff.request_json = mock.Mock(side_effect=request_json)
        outcomes = self.handoff.reconcile()
        self.assertEqual(outcomes["linear_candidates"], 1)
        self.assertEqual(outcomes["linear_requests"], 2)
        self.assertEqual(outcomes["transitioned"], 1)

    def test_wrong_metadata_and_user_authored_candidates_make_zero_linear_requests(self):
        malformed = {**self.pull, "body": "Fixes A-210"}
        user_authored = {
            **self.pull, "number": 505, "user": {"login": "jasonmorganson"}}
        self.handoff.open_pull_requests = mock.Mock(
            return_value=iter([malformed, user_authored]))
        self.handoff.linear = mock.Mock()
        outcomes = self.handoff.reconcile()
        self.assertEqual(outcomes["observed"], 1)
        self.assertEqual(outcomes["linear_requests"], 0)
        self.handoff.linear.assert_not_called()

    def test_duplicate_or_malformed_metadata_makes_zero_linear_requests(self):
        cases = (
            f"{self.pull['body']}\nRequester: stale",
            f"{self.pull['body']}\nrequester: stale",
            f"{self.pull['body']}\nLinear issue: malformed",
            f"{self.pull['body']}\nlinear issue: malformed",
            f"{self.pull['body']}\nfixes A-229",
            f"{self.pull['body']}\nFixes #999",
        )
        for body in cases:
            with self.subTest(body=body):
                self.handoff.open_pull_requests = mock.Mock(
                    return_value=iter([{**self.pull, "body": body}]))
                self.handoff.linear = mock.Mock()
                self.assertEqual(self.handoff.reconcile()["linear_requests"], 0)
                self.handoff.linear.assert_not_called()

    def test_multiple_open_attachments_including_user_pr_fail_closed(self):
        issue = {
            **self.issue,
            "attachments": {
                "nodes": [
                    *self.issue["attachments"]["nodes"],
                    {"url": "https://github.com/withAutograph/arrusted-development/pull/505"},
                ],
                "pageInfo": {"hasNextPage": False},
            },
        }
        self.handoff.open_pull_requests = mock.Mock(
            return_value=iter([self.pull]))
        self.handoff.reviews = mock.Mock(return_value=[self.approval])
        self.handoff.fresh_issue = mock.Mock(return_value=issue)
        self.handoff.github = mock.Mock(side_effect=lambda path: {
            504: self.pull,
            494: {"number": 494, "state": "closed"},
            505: {"number": 505, "state": "open",
                  "user": {"login": "jasonmorganson"}},
        }[int(path.rsplit("/", 1)[1])])
        self.handoff.transition = mock.Mock()
        outcomes = self.handoff.reconcile()
        self.assertEqual(outcomes["transitioned"], 0)
        self.handoff.transition.assert_not_called()

    def test_wrong_repository_attachment_fails_closed(self):
        issue = {
            **self.issue,
            "attachments": {
                "nodes": [{"url": "https://github.com/elsewhere/repository/pull/504"}],
                "pageInfo": {"hasNextPage": False},
            },
        }
        metadata = self.handoff.requester_metadata(self.pull)
        fingerprint = self.handoff.approval_fingerprint(
            self.pull, metadata, [self.approval])
        self.assertFalse(self.handoff.github_authorization_is_fresh(
            issue, self.pull, metadata, fingerprint))

    def test_pr_close_or_second_open_attachment_before_mutation_fails_closed(self):
        second_issue = {
            **self.issue,
            "attachments": {
                "nodes": [
                    *self.issue["attachments"]["nodes"],
                    {"url": "https://github.com/withAutograph/arrusted-development/pull/505"},
                ],
                "pageInfo": {"hasNextPage": False},
            },
        }
        scenarios = {
            "candidate closed": (
                self.issue,
                {504: {**self.pull, "state": "closed"},
                 494: {"number": 494, "state": "closed"}},
            ),
            "second attachment opened": (
                second_issue,
                {504: self.pull, 494: {"number": 494, "state": "closed"},
                 505: {"number": 505, "state": "open",
                       "user": {"login": "jasonmorganson"}}},
            ),
        }
        for label, (issue, pulls) in scenarios.items():
            with self.subTest(label=label):
                handoff = ApprovalHandoff(
                    "arrusted", "linear", "github", self.policy, mock.Mock(),
                    wall_clock=lambda: 1000, retry_clock=lambda: 1000)
                handoff.reviews = mock.Mock(return_value=[self.approval])
                handoff.fresh_issue = mock.Mock(return_value=issue)
                handoff.github = mock.Mock(
                    side_effect=lambda path: pulls[int(path.rsplit("/", 1)[1])])
                handoff.transition = mock.Mock()
                self.assertEqual(
                    handoff.reconcile_pull(self.pull), "github_state_drift")
                handoff.transition.assert_not_called()

    def test_review_dismissal_or_head_change_before_mutation_fails_closed(self):
        later_dismissal = {
            **self.approval,
            "state": "DISMISSED",
            "submitted_at": "2026-07-23T17:00:00Z",
        }
        scenarios = {
            "review dismissed": (
                self.pull, [[self.approval], [self.approval, later_dismissal]]),
            "head changed": (
                {**self.pull, "head": {"sha": "new-head"}},
                [[self.approval], [self.approval]]),
        }
        for label, (fresh_pull, review_pages) in scenarios.items():
            with self.subTest(label=label):
                handoff = ApprovalHandoff(
                    "arrusted", "linear", "github", self.policy, mock.Mock(),
                    wall_clock=lambda: 1000, retry_clock=lambda: 1000)
                handoff.reviews = mock.Mock(side_effect=review_pages)
                handoff.fresh_issue = mock.Mock(return_value=self.issue)
                handoff.github = mock.Mock(side_effect=lambda path: {
                    504: fresh_pull,
                    494: {"number": 494, "state": "closed"},
                }[int(path.rsplit("/", 1)[1])])
                handoff.transition = mock.Mock()
                self.assertEqual(
                    handoff.reconcile_pull(self.pull), "github_state_drift")
                handoff.transition.assert_not_called()

    def test_concurrent_state_drift_prevents_mutation(self):
        for state in ("Merging", "In Review"):
            with self.subTest(state=state):
                self.handoff.candidate_attempts = {}
                issue = {**self.issue, "state": {"name": state}}
                self.handoff.reviews = mock.Mock(return_value=[self.approval])
                self.handoff.fresh_issue = mock.Mock(return_value=issue)
                self.handoff.transition = mock.Mock()
                self.assertEqual(
                    self.handoff.reconcile_pull(self.pull), "linear_ineligible")
                self.handoff.transition.assert_not_called()

    def test_candidate_retry_cache_bounds_linear_requests_and_allows_recovery(self):
        issue = {**self.issue, "state": {"name": "Merging"}}
        self.handoff.reviews = mock.Mock(return_value=[self.approval])
        self.handoff.fresh_issue = mock.Mock(return_value=issue)
        self.assertEqual(
            self.handoff.reconcile_pull(self.pull), "linear_ineligible")
        self.assertEqual(
            self.handoff.reconcile_pull(self.pull), "candidate_deferred")
        self.handoff.fresh_issue.assert_called_once_with("A-210")

        self.clock[0] += 301
        self.assertEqual(
            self.handoff.reconcile_pull(self.pull), "linear_ineligible")
        self.assertEqual(self.handoff.fresh_issue.call_count, 2)

    def test_one_candidate_failure_does_not_block_later_candidate_or_recovery(self):
        pull_229 = {
            **self.pull, "number": 507, "head": {"sha": "head-507"},
            "body": self.pull["body"].replace("A-210", "A-229"),
        }
        self.handoff.open_pull_requests = mock.Mock(
            return_value=iter([self.pull, pull_229]))
        self.handoff.reconcile_pull = mock.Mock(
            side_effect=[RuntimeError("github unavailable"), "transitioned"])
        with redirect_stderr(io.StringIO()):
            outcomes = self.handoff.reconcile()
        self.assertEqual(outcomes["observed"], 2)
        self.assertEqual(outcomes["transitioned"], 1)
        self.assertEqual(outcomes["failed"], 1)

        self.handoff.open_pull_requests.return_value = iter([self.pull])
        self.handoff.reconcile_pull.side_effect = ["transitioned"]
        self.assertEqual(self.handoff.reconcile()["failed"], 0)

    def test_malformed_provider_payloads_fail_closed(self):
        self.handoff.request_json = mock.Mock(return_value={"data": None})
        with self.assertRaisesRegex(ValueError, "invalid Linear"):
            self.handoff.linear("query", {})

        self.handoff.github = mock.Mock(return_value={})
        with self.assertRaisesRegex(ValueError, "invalid GitHub"):
            list(self.handoff.open_pull_requests())

        self.handoff.linear = mock.Mock(return_value={"issue": None})
        with self.assertRaisesRegex(ValueError, "invalid fresh Linear"):
            self.handoff.fresh_issue("A-210")

        self.handoff.linear = mock.Mock(return_value={"issueUpdate": None})
        with self.assertRaisesRegex(RuntimeError, "not acknowledged"):
            self.handoff.transition("issue-210", "merging-state")


class FakeScaler(Scaler):
    def __init__(self):
        self.clock = 0
        self.now = lambda: self.clock
        self.wall_clock = lambda: self.clock + 1000
        self.minimum = 1
        self.maximum = 5
        self.agents_per_worker = 1
        self.cooldown_seconds = 1200
        self.tracker_demand_max_age_seconds = 300
        self.symphony_drain_token = "d" * 32
        self.low_demand_since = None
        self.issues = 0
        self.busy = 0
        self.active_hosts = []
        self.statefulset = "symphony-worker"
        self.configured_hosts = [f"symphony-worker-{index}" for index in range(5)]
        self.ready = 2
        self.drains = []
        self.drain_race = []
        self.workers = 2
        self.changes = []
        self.fail = False
        self.fail_symphony = False
        self.fail_kubernetes = False
        self.fail_write = False
        self.reconcile_stage = "starting"
        self.error_counts = {}
        self.usage_ledger = mock.Mock(load_errors=0)
        self.usage_ledger.snapshot.return_value = {"sessions": {}, "issues": {}}
        self.metrics = {"healthy": 0, "desired": 2, "queue": 0, "blocked": 0,
                        "current": 2, "drained": 0,
                        "cooldown": 0, "errors": 0, "ledger_errors": 0,
                        "handoff_observed": 0, "handoff_transitions": 0,
                        "handoff_linear_candidates": 0,
                        "handoff_linear_requests": 0,
                        "handoff_deferred": 0, "handoff_failures": 0,
                        "last_error": "",
                        "last_error_stage": "", "last_error_timestamp": 0,
                        "last_success_timestamp": 0}

    def symphony_state(self):
        if self.fail_symphony:
            raise RuntimeError("symphony unavailable")
        running = [{"worker_host": host} for host in self.active_hosts]
        state = {
            "counts": {"running": len(running), "retrying": 0},
            "running": running,
            "retrying": [],
            "worker_pool": {"configured_hosts": self.configured_hosts, "drained_hosts": self.drains},
            "tracker": {
                "runnable_issues": self.issues,
                "blocked_issues": 0,
                "observed_at": datetime.fromtimestamp(
                    self.wall_clock(), timezone.utc).isoformat(),
            },
        }
        if self.fail:
            state["tracker"] = None
        return state

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

    def ready_workers(self, _configured_hosts, _current_workers):
        return self.ready

    def set_worker_drains(self, hosts):
        self.drains = sorted(hosts)
        return {"drained_hosts": self.drains, "active_drained_hosts": self.drain_race}


class ReconcileTest(unittest.TestCase):
    def test_handoff_initialization_failures_leave_capacity_operational_and_retry(self):
        linear_environment = {
            "LINEAR_API_KEY": "linear",
            "LINEAR_PROJECT_SLUG": "arrusted",
        }
        for label, loader, environment in (
            ("malformed policy", mock.Mock(side_effect=ValueError("bad policy")),
             {**linear_environment, "GITHUB_TOKEN": "github"}),
            ("missing token", mock.Mock(return_value=requester_policy()), linear_environment),
        ):
            with self.subTest(label=label):
                scaler = FakeScaler()
                scaler.request_json = mock.Mock()
                with mock.patch("scaler.load_requester_policy", loader), \
                        mock.patch.dict(os.environ, environment, clear=True), \
                        redirect_stderr(io.StringIO()):
                    scaler.initialize_approval_handoff()
                    scaler.run_once()
                self.assertIsNone(scaler.approval_handoff)
                self.assertEqual(scaler.metrics["healthy"], 1)
                self.assertEqual(scaler.metrics["errors"], 0)
                self.assertEqual(scaler.metrics["handoff_failures"], 2)
                self.assertEqual(loader.call_count, 2)

    def test_handoff_failure_does_not_fail_capacity_reconciliation(self):
        for error in (
                RuntimeError("github unavailable"),
                TypeError("malformed response"),
                AttributeError("missing response field")):
            with self.subTest(error=type(error).__name__):
                scaler = FakeScaler()
                scaler.approval_handoff = mock.Mock()
                scaler.approval_handoff.reconcile.side_effect = error
                with redirect_stderr(io.StringIO()):
                    scaler.run_once()
                self.assertEqual(scaler.metrics["healthy"], 1)
                self.assertEqual(scaler.metrics["handoff_failures"], 1)
                self.assertEqual(scaler.metrics["errors"], 0)

    def test_capacity_failure_does_not_prevent_handoff_reconciliation(self):
        scaler = FakeScaler()
        scaler.fail = True
        scaler.approval_handoff = mock.Mock()
        scaler.approval_handoff.reconcile.return_value = {
            "observed": 2, "linear_candidates": 1, "linear_requests": 2,
            "deferred": 1, "transitioned": 1, "failed": 0}
        with redirect_stderr(io.StringIO()):
            scaler.run_once()
        scaler.approval_handoff.reconcile.assert_called_once_with()
        self.assertEqual(scaler.metrics["handoff_transitions"], 1)
        self.assertEqual(scaler.metrics["handoff_linear_candidates"], 1)
        self.assertEqual(scaler.metrics["handoff_linear_requests"], 2)
        self.assertEqual(scaler.metrics["handoff_deferred"], 1)
        self.assertEqual(scaler.metrics["healthy"], 0)

    def test_scales_up_immediately(self):
        scaler = FakeScaler()
        scaler.issues = 13
        scaler.run_once()
        self.assertEqual(scaler.changes, [5])
        self.assertEqual(scaler.assert_resource_version, "42")
        self.assertEqual(scaler.metrics["healthy"], 1)
        self.assertEqual(scaler.drains, ["symphony-worker-2", "symphony-worker-3", "symphony-worker-4"])

    def test_active_runtime_demand_recovers_when_tracker_observation_is_missing(self):
        scaler = FakeScaler()
        scaler.fail = True
        scaler.active_hosts = [
            "symphony-worker-0",
            "symphony-worker-1",
            "symphony-worker-2",
            "symphony-worker-3",
            "symphony-worker-4",
        ]
        scaler.run_once()
        self.assertEqual(scaler.changes, [5])
        self.assertEqual(scaler.metrics["healthy"], 1)
        self.assertEqual(scaler.metrics["queue"], 5)

    def test_active_scale_down_drains_then_removes_trailing_idle_workers(self):
        scaler = FakeScaler()
        scaler.workers = 5
        scaler.ready = 5
        scaler.issues = 2
        scaler.active_hosts = ["symphony-worker-0", "symphony-worker-1"]
        scaler.run_once()
        self.assertEqual(scaler.drains, ["symphony-worker-2", "symphony-worker-3", "symphony-worker-4"])
        self.assertEqual(scaler.changes, [2])

    def test_single_issue_retains_active_worker_zero_and_removes_worker_one(self):
        scaler = FakeScaler()
        scaler.workers = 2
        scaler.ready = 1
        scaler.issues = 1
        scaler.active_hosts = ["symphony-worker-0"]
        scaler.run_once()
        self.assertEqual(scaler.drains, [
            "symphony-worker-1", "symphony-worker-2", "symphony-worker-3", "symphony-worker-4"])
        self.assertEqual(scaler.changes, [1])

    def test_single_issue_retains_active_worker_one(self):
        scaler = FakeScaler()
        scaler.workers = 2
        scaler.ready = 2
        scaler.issues = 1
        scaler.active_hosts = ["symphony-worker-1"]
        scaler.run_once()
        self.assertEqual(scaler.drains, [
            "symphony-worker-2", "symphony-worker-3", "symphony-worker-4"])
        self.assertEqual(scaler.changes, [])

    def test_active_high_ordinal_and_drain_race_retain_capacity(self):
        scaler = FakeScaler()
        scaler.workers = 5
        scaler.ready = 5
        scaler.issues = 2
        scaler.active_hosts = ["symphony-worker-4"]
        scaler.run_once()
        self.assertEqual(scaler.changes, [])
        self.assertEqual(scaler.drains, [])

        scaler.active_hosts = ["symphony-worker-0"]
        scaler.drain_race = ["symphony-worker-3"]
        scaler.run_once()
        self.assertEqual(scaler.changes, [])

    def test_idle_scale_down_waits_for_cooldown_then_drains(self):
        scaler = FakeScaler()
        scaler.workers = 5
        scaler.ready = 5
        scaler.issues = 3
        scaler.run_once()
        scaler.clock = 1199
        scaler.run_once()
        self.assertEqual(scaler.changes, [])
        scaler.clock = 1200
        scaler.run_once()
        self.assertEqual(scaler.changes, [3])
        self.assertEqual(scaler.drains, ["symphony-worker-3", "symphony-worker-4"])

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

    def test_new_work_wakes_one_worker_immediately(self):
        scaler = FakeScaler()
        scaler.workers = 0
        scaler.ready = 0
        scaler.issues = 1
        scaler.run_once()
        self.assertEqual(scaler.changes, [1])
        self.assertEqual(scaler.drains, [
            "symphony-worker-0", "symphony-worker-1", "symphony-worker-2",
            "symphony-worker-3", "symphony-worker-4"])

        scaler.ready = 1
        scaler.run_once()
        self.assertEqual(scaler.drains, [
            "symphony-worker-1", "symphony-worker-2", "symphony-worker-3", "symphony-worker-4"])

        scaler.issues = 3
        scaler.run_once()
        self.assertEqual(scaler.changes, [1, 3])

        scaler.ready = 3
        scaler.run_once()
        self.assertEqual(scaler.drains, ["symphony-worker-3", "symphony-worker-4"])

    def test_scale_up_fences_future_hosts_before_creating_pods(self):
        scaler = FakeScaler()
        scaler.workers = 2
        scaler.ready = 2
        scaler.issues = 3
        events = []
        scaler.set_worker_drains = lambda hosts: (
            events.append(("drain", list(hosts))) or
            {"drained_hosts": sorted(hosts), "active_drained_hosts": []})
        original_set_workers = scaler.set_workers
        scaler.set_workers = lambda replicas, version: (
            events.append(("scale", replicas)), original_set_workers(replicas, version))[1]
        scaler.run_once()
        self.assertEqual(events, [
            ("drain", ["symphony-worker-2", "symphony-worker-3", "symphony-worker-4"]),
            ("scale", 3),
        ])

    def test_scale_up_creates_capacity_for_active_future_host_reservations(self):
        scaler = FakeScaler()
        scaler.workers = 2
        scaler.ready = 2
        scaler.issues = 3
        scaler.drain_race = ["symphony-worker-2"]
        scaler.run_once()
        self.assertEqual(scaler.changes, [3])
        self.assertEqual(scaler.drains, [
            "symphony-worker-2", "symphony-worker-3", "symphony-worker-4"])

    def test_failure_retains_capacity_and_recovers(self):
        scaler = FakeScaler()
        scaler.workers = 4
        scaler.fail = True
        output = io.StringIO()
        with redirect_stderr(output):
            scaler.run_once()
        self.assertEqual(scaler.workers, 4)
        self.assertEqual(scaler.metrics["healthy"], 0)
        self.assertEqual(scaler.metrics["last_error"], "ValueError")
        self.assertEqual(scaler.metrics["last_error_stage"], "tracker_demand")
        self.assertEqual(scaler.metrics["last_error_timestamp"], 1000)
        self.assertEqual(scaler.error_counts, {("tracker_demand", "ValueError"): 1})
        self.assertEqual(json.loads(output.getvalue()), {
            "error": "invalid Symphony tracker demand",
            "error_type": "ValueError",
            "event": "autoscaler_reconcile_failed",
            "stage": "tracker_demand",
            "timestamp": 1000,
        })
        scaler.fail = False
        scaler.issues = 12
        scaler.clock = 5
        scaler.run_once()
        self.assertEqual(scaler.metrics["healthy"], 1)
        self.assertEqual(scaler.metrics["last_success_timestamp"], 1005)
        self.assertEqual(scaler.metrics["last_error"], "ValueError")
        self.assertEqual(scaler.metrics["last_error_stage"], "tracker_demand")

    def test_failures_are_counted_by_reconcile_stage_and_type(self):
        scaler = FakeScaler()
        scenarios = (
            ("fail_symphony", "symphony_state"),
            ("fail_kubernetes", "kubernetes_scale_read"),
            ("fail_write", "kubernetes_scale_write"),
        )
        for attribute, stage in scenarios:
            setattr(scaler, attribute, True)
            scaler.issues = 15 if attribute == "fail_write" else 0
            with redirect_stderr(io.StringIO()):
                scaler.run_once()
            setattr(scaler, attribute, False)
            self.assertEqual(scaler.metrics["last_error_stage"], stage)
            self.assertEqual(scaler.error_counts[(stage, "RuntimeError")], 1)
        self.assertEqual(scaler.metrics["errors"], 3)

    def test_metrics_exposition_retains_typed_failure_after_recovery(self):
        scaler = FakeScaler()
        startup = "\n".join(metrics_lines(scaler))
        self.assertNotIn("symphony_autoscaler_last_error{", startup)
        self.assertIn("symphony_autoscaler_last_error_timestamp_seconds 0", startup)
        self.assertIn("symphony_approval_handoff_linear_requests_total 0", startup)

        scaler.fail = True
        with redirect_stderr(io.StringIO()):
            scaler.run_once()
        scaler.fail = False
        scaler.clock = 5
        scaler.run_once()

        recovered = "\n".join(metrics_lines(scaler))
        self.assertIn('symphony_autoscaler_last_error{type="ValueError"} 1', recovered)
        self.assertIn(
            'symphony_autoscaler_last_error_info{stage="tracker_demand",type="ValueError"} 1',
            recovered)
        self.assertIn(
            'symphony_autoscaler_reconcile_errors_total{stage="tracker_demand",type="ValueError"} 1',
            recovered)
        self.assertIn("symphony_autoscaler_last_error_timestamp_seconds 1000", recovered)
        self.assertIn("symphony_autoscaler_last_success_timestamp_seconds 1005", recovered)

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

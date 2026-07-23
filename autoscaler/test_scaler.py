import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest import mock
from scaler import (ApprovalHandoff, Scaler, UsageLedger, desired_workers, issue_is_runnable,
                    load_requester_policy, metrics_lines, requester_approval_is_current,
                    stable_session_id, worker_pool_activity)


def requester_policy():
    return {
        "$schema": "./requester-policy.schema.json",
        "schema_version": 1,
        "repository": "withAutograph/arrusted-development",
        "machine_login": "autograph-symphony",
        "runtime_scope": ["kubernetes"],
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
            "source_state": "In Review",
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
        cases = {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 99: 5}
        for issues, expected in cases.items():
            with self.subTest(issues=issues):
                self.assertEqual(desired_workers(issues), expected)

    def test_custom_bounds(self):
        self.assertEqual(desired_workers(8, agents_per_worker=2, minimum=1, maximum=3), 3)


class RunnableIssueTest(unittest.TestCase):
    def test_active_work_is_runnable_even_if_a_blocker_relation_remains(self):
        issue = {"state": {"name": "In Progress"}, "inverseRelations": {
            "nodes": [{"type": "blocks", "issue": {"state": {"type": "started"}}}],
            "pageInfo": {"hasNextPage": False},
        }}
        self.assertTrue(issue_is_runnable(issue))

    def test_todo_with_unresolved_blocker_is_not_runnable(self):
        issue = {"state": {"name": "Todo"}, "inverseRelations": {
            "nodes": [{"type": "blocks", "issue": {"state": {"type": "started"}}}],
            "pageInfo": {"hasNextPage": False},
        }}
        self.assertFalse(issue_is_runnable(issue))

    def test_todo_with_only_terminal_blockers_is_runnable(self):
        for state_type in ("completed", "canceled"):
            with self.subTest(state_type=state_type):
                issue = {"state": {"name": "Todo"}, "inverseRelations": {
                    "nodes": [{"type": "blocks", "issue": {"state": {"type": state_type}}}],
                    "pageInfo": {"hasNextPage": False},
                }}
                self.assertTrue(issue_is_runnable(issue))

    def test_non_blocking_relations_do_not_hold_todo(self):
        issue = {"state": {"name": "Todo"}, "inverseRelations": {
            "nodes": [{"type": "related", "issue": {"state": {"type": "started"}}}],
            "pageInfo": {"hasNextPage": False},
        }}
        self.assertTrue(issue_is_runnable(issue))

    def test_truncated_blocker_list_fails_closed(self):
        issue = {"state": {"name": "Todo"}, "inverseRelations": {
            "nodes": [], "pageInfo": {"hasNextPage": True},
        }}
        with self.assertRaises(RuntimeError):
            issue_is_runnable(issue)

    def test_malformed_blocker_payload_fails_closed(self):
        malformed_issues = (
            {"state": None},
            {"state": {"name": "Todo"}, "inverseRelations": None},
            {"state": {"name": "Todo"}, "inverseRelations": {
                "nodes": [None], "pageInfo": {"hasNextPage": False}}},
            {"state": {"name": "Todo"}, "inverseRelations": {
                "nodes": [{"type": "blocks", "issue": None}],
                "pageInfo": {"hasNextPage": False}}},
        )
        for issue in malformed_issues:
            with self.subTest(issue=issue), self.assertRaises(ValueError):
                issue_is_runnable(issue)

    def test_linear_count_excludes_blocked_todo_across_pages(self):
        scaler = object.__new__(Scaler)
        scaler.project_slug = "project"
        scaler.linear_key = "key"
        scaler.now = lambda: 0
        scaler.linear_rate_limit_cooldown_seconds = 60
        scaler.linear_cooldown_until = 0
        scaler.last_linear_counts = None
        pages = iter((
            {"data": {"issues": {"nodes": [
                {"state": {"name": "In Progress"}, "inverseRelations": {
                    "nodes": [], "pageInfo": {"hasNextPage": False}}},
                {"state": {"name": "Todo"}, "inverseRelations": {
                    "nodes": [{"type": "blocks", "issue": {"state": {"type": "started"}}}],
                    "pageInfo": {"hasNextPage": False}}},
            ], "pageInfo": {"hasNextPage": True, "endCursor": "next"}}}},
            {"data": {"issues": {"nodes": [
                {"state": {"name": "Todo"}, "inverseRelations": {
                    "nodes": [{"type": "blocks", "issue": {"state": {"type": "completed"}}}],
                    "pageInfo": {"hasNextPage": False}}},
            ], "pageInfo": {"hasNextPage": False, "endCursor": None}}}},
        ))
        scaler.request_json = mock.Mock(side_effect=lambda *_args, **_kwargs: next(pages))

        self.assertEqual(scaler.linear_issue_count(), (2, 1))
        self.assertEqual(scaler.request_json.call_count, 2)

    def test_linear_rate_limit_reuses_last_count_during_shared_cooldown(self):
        scaler = object.__new__(Scaler)
        scaler.project_slug = "project"
        scaler.linear_key = "key"
        scaler.clock = 10
        scaler.now = lambda: scaler.clock
        scaler.linear_rate_limit_cooldown_seconds = 60
        scaler.linear_cooldown_until = 0
        scaler.last_linear_counts = (3, 1)
        scaler.request_json = mock.Mock(return_value={
            "errors": [{
                "message": "Rate limit exceeded.",
                "extensions": {"code": "RATELIMITED", "statusCode": 429},
            }],
        })

        self.assertEqual(scaler.linear_issue_count(), (3, 1))
        self.assertEqual(scaler.linear_cooldown_until, 70)
        self.assertEqual(scaler.request_json.call_count, 1)

        scaler.clock = 20
        self.assertEqual(scaler.linear_issue_count(), (3, 1))
        self.assertEqual(scaler.request_json.call_count, 1)

    def test_linear_rate_limit_without_cached_count_fails_with_cooldown(self):
        scaler = object.__new__(Scaler)
        scaler.project_slug = "project"
        scaler.linear_key = "key"
        scaler.now = lambda: 10
        scaler.linear_rate_limit_cooldown_seconds = 60
        scaler.linear_cooldown_until = 0
        scaler.last_linear_counts = None
        scaler.request_json = mock.Mock(return_value={
            "errors": [{
                "extensions": {"code": "RATELIMITED", "statusCode": 429},
            }],
        })

        with self.assertRaisesRegex(
                RuntimeError, "Linear rate limited; shared cooldown has 60s remaining"):
            scaler.linear_issue_count()
        self.assertEqual(scaler.linear_cooldown_until, 70)
        self.assertEqual(scaler.request_json.call_count, 1)


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
        self.handoff = ApprovalHandoff(
            "arrusted", "linear", "github", self.policy, mock.Mock(), wall_clock=lambda: 1000)
        self.issue = {
            "id": "issue-210",
            "identifier": "A-210",
            "creator": {"email": "jason@withgraph.com"},
            "state": {"name": "In Review"},
            "attachments": {
                "nodes": [
                    {"url": "https://github.com/withAutograph/arrusted-development/pull/504"},
                    {"url": "https://github.com/withAutograph/arrusted-development/pull/494"},
                ],
                "pageInfo": {"hasNextPage": False},
            },
        }
        self.approval = {
            "user": {"login": "jasonmorganson", "type": "User"},
            "state": "APPROVED",
            "submitted_at": "2026-07-23T16:00:12Z",
        }

    def test_policy_loader_rejects_stale_review_state_and_duplicate_mapping(self):
        for mutate in ("state", "mapping"):
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as directory:
                policy = requester_policy()
                policy.pop("_requester_by_email")
                if mutate == "state":
                    policy["approval_handoff"]["source_state"] = "Human Review"
                else:
                    policy["requester"]["creator_email_mappings"].append(
                        dict(policy["requester"]["creator_email_mappings"][0]))
                path = os.path.join(directory, "policy.json")
                with open(path, "w", encoding="utf-8") as target:
                    json.dump(policy, target)
                with self.assertRaises(ValueError):
                    load_requester_policy(path)

    def test_a210_shape_uses_only_one_open_machine_pull_request(self):
        pulls = {
            504: {"state": "open", "user": {"login": "autograph-symphony"}},
            494: {"state": "closed", "merged": True,
                  "user": {"login": "autograph-symphony"}},
        }
        self.handoff.github = lambda path: pulls[int(path.rsplit("/", 1)[1])]
        self.assertEqual(self.handoff.open_machine_pull_request(self.issue), 504)

    def test_wrong_repository_user_authored_and_multiple_open_prs_fail_closed(self):
        wrong_repository = {
            **self.issue,
            "attachments": {"nodes": [
                {"url": "https://github.com/elsewhere/repository/pull/504"}],
                "pageInfo": {"hasNextPage": False}},
        }
        self.assertIsNone(self.handoff.open_machine_pull_request(wrong_repository))

        self.handoff.github = lambda _path: {
            "state": "open", "user": {"login": "jasonmorganson"}}
        self.assertIsNone(self.handoff.open_machine_pull_request(self.issue))

        self.handoff.github = lambda _path: {
            "state": "open", "user": {"login": "autograph-symphony"}}
        issue = {
            **self.issue,
            "attachments": {"nodes": [
                {"url": "https://github.com/withAutograph/arrusted-development/pull/504"},
                {"url": "https://github.com/withAutograph/arrusted-development/pull/505"},
            ], "pageInfo": {"hasNextPage": False}},
        }
        self.assertIsNone(self.handoff.open_machine_pull_request(issue))

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

    def test_in_review_issue_query_is_paginated(self):
        issue_229 = {**self.issue, "id": "issue-229", "identifier": "A-229"}
        self.handoff.linear = mock.Mock(side_effect=[
            {"issues": {"nodes": [self.issue],
                        "pageInfo": {"hasNextPage": True, "endCursor": "next"}}},
            {"issues": {"nodes": [issue_229],
                        "pageInfo": {"hasNextPage": False, "endCursor": None}}},
        ])
        self.assertEqual(
            [issue["identifier"] for issue in self.handoff.review_issues()],
            ["A-210", "A-229"])
        self.assertEqual(self.handoff.linear.call_args_list[1].args[1]["after"], "next")

    def test_concurrent_state_drift_prevents_mutation_and_repeat_is_idempotent(self):
        self.handoff.open_machine_pull_request = mock.Mock(return_value=504)
        self.handoff.reviews = mock.Mock(return_value=[self.approval])
        self.handoff.fresh_state_and_destination = mock.Mock(
            side_effect=["merging-state", None])
        self.handoff.transition = mock.Mock()
        self.assertEqual(self.handoff.reconcile_issue(self.issue), "transitioned")
        self.assertEqual(self.handoff.reconcile_issue(self.issue), "state_drift")
        self.handoff.transition.assert_called_once_with("issue-210", "merging-state")

    def test_unapproved_a229_remains_in_review(self):
        issue = {**self.issue, "id": "issue-229", "identifier": "A-229"}
        self.handoff.open_machine_pull_request = mock.Mock(return_value=507)
        self.handoff.reviews = mock.Mock(return_value=[])
        self.handoff.transition = mock.Mock()
        self.assertEqual(self.handoff.reconcile_issue(issue), "requester_not_approved")
        self.handoff.transition.assert_not_called()

    def test_one_issue_failure_does_not_block_later_issue_or_recovery(self):
        issue_229 = {**self.issue, "id": "issue-229", "identifier": "A-229"}
        self.handoff.review_issues = mock.Mock(return_value=iter([self.issue, issue_229]))
        self.handoff.reconcile_issue = mock.Mock(
            side_effect=[RuntimeError("github unavailable"), "transitioned"])
        with redirect_stderr(io.StringIO()):
            outcomes = self.handoff.reconcile()
        self.assertEqual(outcomes, {"observed": 2, "transitioned": 1, "failed": 1})

        self.handoff.review_issues.return_value = iter([self.issue])
        self.handoff.reconcile_issue.side_effect = ["transitioned"]
        self.assertEqual(
            self.handoff.reconcile(), {"observed": 1, "transitioned": 1, "failed": 0})


class FakeScaler(Scaler):
    def __init__(self):
        self.clock = 0
        self.now = lambda: self.clock
        self.wall_clock = lambda: self.clock + 1000
        self.minimum = 1
        self.maximum = 5
        self.agents_per_worker = 1
        self.cooldown_seconds = 1200
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
                        "last_error": "",
                        "last_error_stage": "", "last_error_timestamp": 0,
                        "last_success_timestamp": 0}

    def linear_issue_count(self):
        if self.fail:
            raise RuntimeError("unavailable")
        return self.issues, 0

    def symphony_state(self):
        if self.fail_symphony:
            raise RuntimeError("symphony unavailable")
        running = [{"worker_host": host} for host in self.active_hosts]
        return {
            "counts": {"running": len(running), "retrying": 0},
            "running": running,
            "retrying": [],
            "worker_pool": {"configured_hosts": self.configured_hosts, "drained_hosts": self.drains},
        }

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
        for label, loader, environment in (
            ("malformed policy", mock.Mock(side_effect=ValueError("bad policy")),
             {"GITHUB_TOKEN": "github"}),
            ("missing token", mock.Mock(return_value=requester_policy()), {}),
        ):
            with self.subTest(label=label):
                scaler = FakeScaler()
                scaler.project_slug = "arrusted"
                scaler.linear_key = "linear"
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
        scaler = FakeScaler()
        scaler.approval_handoff = mock.Mock()
        scaler.approval_handoff.reconcile.side_effect = RuntimeError("github unavailable")
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
            "observed": 2, "transitioned": 1, "failed": 0}
        with redirect_stderr(io.StringIO()):
            scaler.run_once()
        scaler.approval_handoff.reconcile.assert_called_once_with()
        self.assertEqual(scaler.metrics["handoff_transitions"], 1)
        self.assertEqual(scaler.metrics["healthy"], 0)

    def test_scales_up_immediately(self):
        scaler = FakeScaler()
        scaler.issues = 13
        scaler.run_once()
        self.assertEqual(scaler.changes, [5])
        self.assertEqual(scaler.assert_resource_version, "42")
        self.assertEqual(scaler.metrics["healthy"], 1)
        self.assertEqual(scaler.drains, ["symphony-worker-2", "symphony-worker-3", "symphony-worker-4"])

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

    def test_scale_up_stops_if_fence_acknowledges_an_active_future_host(self):
        scaler = FakeScaler()
        scaler.workers = 2
        scaler.ready = 2
        scaler.issues = 3
        scaler.drain_race = ["symphony-worker-2"]
        scaler.run_once()
        self.assertEqual(scaler.changes, [])

    def test_failure_retains_capacity_and_recovers(self):
        scaler = FakeScaler()
        scaler.workers = 4
        scaler.fail = True
        output = io.StringIO()
        with redirect_stderr(output):
            scaler.run_once()
        self.assertEqual(scaler.workers, 4)
        self.assertEqual(scaler.metrics["healthy"], 0)
        self.assertEqual(scaler.metrics["last_error"], "RuntimeError")
        self.assertEqual(scaler.metrics["last_error_stage"], "linear")
        self.assertEqual(scaler.metrics["last_error_timestamp"], 1000)
        self.assertEqual(scaler.error_counts, {("linear", "RuntimeError"): 1})
        self.assertEqual(json.loads(output.getvalue()), {
            "error": "unavailable",
            "error_type": "RuntimeError",
            "event": "autoscaler_reconcile_failed",
            "stage": "linear",
            "timestamp": 1000,
        })
        scaler.fail = False
        scaler.issues = 12
        scaler.clock = 5
        scaler.run_once()
        self.assertEqual(scaler.metrics["healthy"], 1)
        self.assertEqual(scaler.metrics["last_success_timestamp"], 1005)
        self.assertEqual(scaler.metrics["last_error"], "RuntimeError")
        self.assertEqual(scaler.metrics["last_error_stage"], "linear")

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

        scaler.fail = True
        with redirect_stderr(io.StringIO()):
            scaler.run_once()
        scaler.fail = False
        scaler.clock = 5
        scaler.run_once()

        recovered = "\n".join(metrics_lines(scaler))
        self.assertIn('symphony_autoscaler_last_error{type="RuntimeError"} 1', recovered)
        self.assertIn(
            'symphony_autoscaler_last_error_info{stage="linear",type="RuntimeError"} 1',
            recovered)
        self.assertIn(
            'symphony_autoscaler_reconcile_errors_total{stage="linear",type="RuntimeError"} 1',
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

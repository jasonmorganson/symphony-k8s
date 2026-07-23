#!/usr/bin/env python3
import json
import math
import os
import re
import ssl
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LINEAR_URL = "https://api.linear.app/graphql"
GITHUB_API_URL = "https://api.github.com"
TOKEN_FIELDS = ("input_tokens", "output_tokens", "total_tokens")


def stable_session_id(session_id):
    if isinstance(session_id, str) and len(session_id) == 73 and session_id[36] == "-":
        try:
            uuid.UUID(session_id[:36])
            uuid.UUID(session_id[37:])
            return session_id[:36]
        except ValueError:
            pass
    return session_id


class UsageLedger:
    def __init__(self, path, now=time.time, maximum_sessions=1000):
        self.path = path
        self.now = now
        self.sessions = {}
        self.load_errors = 0
        self.write_errors = 0
        self.quarantine_failed = False
        self.maximum_sessions = maximum_sessions
        self.lock = threading.RLock()
        self._load()

    def _load(self):
        try:
            with open(self.path, encoding="utf-8") as source:
                payload = json.load(source)
            if not isinstance(payload, dict) or not isinstance(payload.get("sessions"), dict):
                raise ValueError("invalid usage ledger schema")
            if not all(self._valid_persisted_entry(key, value)
                       for key, value in payload["sessions"].items()):
                raise ValueError("invalid usage ledger sessions")
            self.sessions = self._consolidate_sessions(payload["sessions"])
        except FileNotFoundError:
            return
        except (OSError, ValueError, TypeError, AttributeError):
            self.load_errors += 1
            try:
                os.replace(self.path, f"{self.path}.corrupt.{int(self.now())}")
            except OSError:
                self.quarantine_failed = True

    @staticmethod
    def _valid_persisted_entry(session_id, entry):
        if not isinstance(session_id, str) or not isinstance(entry, dict):
            return False
        if entry.get("session_id") != session_id or not isinstance(entry.get("issue_identifier"), str):
            return False
        if not all(type(entry.get(field)) is int and entry[field] >= 0
                   for field in (*TOKEN_FIELDS, "turn_count", "first_observed_at", "last_observed_at")):
            return False
        if entry["total_tokens"] < entry["input_tokens"] + entry["output_tokens"]:
            return False
        if entry.get("started_at") is not None and not isinstance(entry["started_at"], str):
            return False
        return entry.get("ended_at") is None or isinstance(entry["ended_at"], int)

    @staticmethod
    def _consolidate_sessions(sessions):
        consolidated = {}
        for source in sessions.values():
            session_id = stable_session_id(source["session_id"])
            entry = dict(source, session_id=session_id)
            existing = consolidated.get(session_id)
            if existing is None:
                consolidated[session_id] = entry
                continue
            if existing["issue_identifier"] != entry["issue_identifier"]:
                raise ValueError("session belongs to multiple issues")
            for field in (*TOKEN_FIELDS, "turn_count", "last_observed_at"):
                existing[field] = max(existing[field], entry[field])
            existing["first_observed_at"] = min(existing["first_observed_at"], entry["first_observed_at"])
            if existing.get("started_at") is None:
                existing["started_at"] = entry.get("started_at")
            existing["ended_at"] = (None if existing.get("ended_at") is None or entry.get("ended_at") is None
                                     else max(existing["ended_at"], entry["ended_at"]))
            existing["total_tokens"] = max(existing["total_tokens"],
                                            existing["input_tokens"] + existing["output_tokens"])
        return consolidated

    @staticmethod
    def _nonnegative_integer(value):
        try:
            return max(0, int(value))
        except (TypeError, ValueError):
            return 0

    def observe(self, state):
        with self.lock:
            if self.quarantine_failed:
                raise OSError("usage ledger quarantine failed")
            if not isinstance(state, dict) or not isinstance(state.get("running", []), list):
                raise ValueError("invalid Symphony state payload")
            observed_at = int(self.now())
            active = set()
            for running in state.get("running", []):
                if not isinstance(running, dict):
                    continue
                session_id = stable_session_id(running.get("session_id"))
                issue_identifier = running.get("issue_identifier")
                if not isinstance(session_id, str) or not session_id or \
                        not isinstance(issue_identifier, str) or not issue_identifier:
                    continue
                active.add(session_id)
                tokens = running.get("tokens") or {}
                existing = self.sessions.get(session_id, {})
                entry = {
                    "session_id": session_id,
                    "issue_identifier": issue_identifier,
                    "started_at": running.get("started_at") or existing.get("started_at"),
                    "first_observed_at": existing.get("first_observed_at", observed_at),
                    "last_observed_at": observed_at,
                    "ended_at": None,
                    "turn_count": max(self._nonnegative_integer(existing.get("turn_count")),
                                      self._nonnegative_integer(running.get("turn_count"))),
                }
                for field in TOKEN_FIELDS:
                    entry[field] = max(self._nonnegative_integer(existing.get(field)),
                                       self._nonnegative_integer(tokens.get(field)))
                entry["total_tokens"] = max(entry["total_tokens"],
                                            entry["input_tokens"] + entry["output_tokens"])
                self.sessions[session_id] = entry
            for session_id, entry in self.sessions.items():
                if session_id not in active and entry.get("ended_at") is None:
                    entry["ended_at"] = observed_at
            ended = sorted((entry for entry in self.sessions.values() if entry.get("ended_at") is not None),
                           key=lambda entry: entry.get("last_observed_at", 0))
            while len(self.sessions) > self.maximum_sessions and ended:
                self.sessions.pop(ended.pop(0)["session_id"], None)
            self._save()

    def _save(self):
        directory = os.path.dirname(self.path) or "."
        os.makedirs(directory, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=directory,
                                             prefix="usage.", suffix=".tmp", delete=False) as target:
                temporary = target.name
                json.dump({"version": 1, "sessions": self.sessions}, target,
                          sort_keys=True, separators=(",", ":"))
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary, self.path)
            directory_fd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            self.write_errors += 1
            if temporary:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass
            raise

    def snapshot(self):
        with self.lock:
            by_issue = {}
            sessions = {session_id: dict(entry) for session_id, entry in self.sessions.items()}
            for entry in sessions.values():
                issue = entry["issue_identifier"]
                aggregate = by_issue.setdefault(issue, {field: 0 for field in TOKEN_FIELDS})
                aggregate["sessions"] = aggregate.get("sessions", 0) + 1
                aggregate["turn_count"] = aggregate.get("turn_count", 0) + entry["turn_count"]
                for field in TOKEN_FIELDS:
                    aggregate[field] += entry[field]
            return {"version": 1, "sessions": sessions, "issues": by_issue}


def desired_workers(issue_count, agents_per_worker=1, minimum=1, maximum=10):
    if issue_count == 0:
        return 0
    return max(minimum, min(maximum, math.ceil(issue_count / agents_per_worker)))


def tracker_demand(state, now=None, maximum_age_seconds=None):
    tracker = state.get("tracker") if isinstance(state, dict) else None
    if not isinstance(tracker, dict):
        raise ValueError("invalid Symphony tracker demand")
    runnable = tracker.get("runnable_issues")
    blocked = tracker.get("blocked_issues")
    observed_at = tracker.get("observed_at")
    if type(runnable) is not int or runnable < 0 \
            or type(blocked) is not int or blocked < 0 \
            or not isinstance(observed_at, str) or not observed_at:
        raise ValueError("invalid Symphony tracker demand")
    try:
        observed_timestamp = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
        if observed_timestamp.tzinfo is None:
            raise ValueError
        observed_timestamp = observed_timestamp.astimezone(timezone.utc).timestamp()
    except (OverflowError, ValueError):
        raise ValueError("invalid Symphony tracker demand") from None
    if now is not None and (
            observed_timestamp > now
            or maximum_age_seconds is None
            or now - observed_timestamp > maximum_age_seconds):
        raise ValueError("stale Symphony tracker demand")
    return runnable, blocked


def worker_pool_activity(state, current_workers, statefulset="symphony-worker"):
    if not isinstance(state, dict) or not isinstance(state.get("counts"), dict) \
            or not isinstance(state.get("running"), list) or not isinstance(state.get("retrying"), list):
        raise ValueError("invalid Symphony activity state")
    pool = state.get("worker_pool")
    if not isinstance(pool, dict) or not isinstance(pool.get("configured_hosts"), list) \
            or not isinstance(pool.get("drained_hosts"), list):
        raise ValueError("invalid Symphony worker pool state")
    configured = pool["configured_hosts"]
    drained = pool["drained_hosts"]
    if len(configured) < current_workers \
            or any(not isinstance(host, str) or not host for host in configured) \
            or any(host not in configured for host in drained):
        raise ValueError("inconsistent Symphony worker pool state")
    if len(set(configured)) != len(configured):
        raise ValueError("duplicate Symphony worker hosts")
    for ordinal, host in enumerate(configured):
        if host.split(".", 1)[0] != f"{statefulset}-{ordinal}":
            raise ValueError("Symphony worker hosts do not match StatefulSet ordinals")
    running_count = state["counts"].get("running")
    retrying_count = state["counts"].get("retrying")
    if type(running_count) is not int or running_count < 0 \
            or type(retrying_count) is not int or retrying_count < 0 \
            or running_count != len(state["running"]) \
            or retrying_count != len(state["retrying"]):
        raise ValueError("inconsistent Symphony activity counts")
    active_hosts = []
    for session in state["running"] + state["retrying"]:
        host = session.get("worker_host") if isinstance(session, dict) else None
        if host not in configured:
            raise ValueError("active Symphony session has unknown worker placement")
        active_hosts.append(host)
    floor = max((configured.index(host) + 1 for host in active_hosts), default=0)
    return running_count + retrying_count, floor, configured


def load_requester_policy(path):
    with open(path, encoding="utf-8") as source:
        policy = json.load(source)
    top_level_keys = {
        "$schema", "schema_version", "repository", "machine_login", "runtime_scope",
        "requester", "pull_request", "approval_handoff", "monitor",
    }
    if not isinstance(policy, dict) or set(policy) != top_level_keys:
        raise ValueError("unsupported requester policy")
    requester = policy["requester"]
    pull_request = policy["pull_request"]
    handoff = policy["approval_handoff"]
    monitor = policy["monitor"]
    if not all(isinstance(value, dict) for value in (requester, pull_request, handoff, monitor)):
        raise ValueError("invalid requester policy sections")
    structures = (
        ("requester", requester, {
            "source", "resolution", "creator_email_mappings"}),
        ("pull_request", pull_request, {
            "attached_open_count", "author", "reconciliation",
            "required_body_metadata", "review_request"}),
        ("pull_request.reconciliation", pull_request.get("reconciliation"), {
            "none", "one", "ambiguous"}),
        ("approval_handoff", handoff, {
            "source_state", "destination_state", "review_pull_request", "actor",
            "actor_type", "state", "latest_by", "ignored_review_states",
            "conflicting_latest_timestamp", "concurrent_state_drift"}),
        ("monitor", monitor, {
            "owner", "polling", "discovery", "linear_access", "github_credential"}),
    )
    for field, value, expected_keys in structures:
        if not isinstance(value, dict) or set(value) != expected_keys:
            raise ValueError(f"invalid requester policy structure: {field}")
    reconciliation = pull_request["reconciliation"]
    expected = {
        "$schema": (policy["$schema"], "./requester-policy.schema.json"),
        "schema_version": (policy["schema_version"], 1),
        "repository": (policy["repository"], "withAutograph/arrusted-development"),
        "machine_login": (policy["machine_login"], "autograph-symphony"),
        "runtime_scope": (
            policy["runtime_scope"], ["local", "vm", "container", "kubernetes"]),
        "requester.source": (requester.get("source"), "linear_issue_creator"),
        "requester.resolution": (
            requester.get("resolution"), "exactly_one_mapping_or_fail_closed"),
        "pull_request.attached_open_count": (pull_request.get("attached_open_count"), 1),
        "pull_request.author": (pull_request.get("author"), "machine_login"),
        "pull_request.reconciliation.none": (reconciliation.get("none"), "create"),
        "pull_request.reconciliation.one": (
            reconciliation.get("one"), "reuse_and_repair"),
        "pull_request.reconciliation.ambiguous": (
            reconciliation.get("ambiguous"), "fail_closed"),
        "pull_request.required_body_metadata": (
            pull_request.get("required_body_metadata"),
            ["requester", "canonical_linear_issue_link", "exactly_one_fixes_issue_id"]),
        "pull_request.review_request": (
            pull_request.get("review_request"), "mapped_requester_on_create_or_reuse"),
        "approval_handoff.source_state": (handoff.get("source_state"), "Human Review"),
        "approval_handoff.destination_state": (handoff.get("destination_state"), "Merging"),
        "approval_handoff.review_pull_request": (
            handoff.get("review_pull_request"), "attached_open_pull_request"),
        "approval_handoff.actor": (handoff.get("actor"), "mapped_requester"),
        "approval_handoff.actor_type": (handoff.get("actor_type"), "human"),
        "approval_handoff.state": (handoff.get("state"), "APPROVED"),
        "approval_handoff.latest_by": (handoff.get("latest_by"), "submitted_at"),
        "approval_handoff.ignored_review_states": (
            handoff.get("ignored_review_states"), ["COMMENTED"]),
        "approval_handoff.conflicting_latest_timestamp": (
            handoff.get("conflicting_latest_timestamp"), "fail_closed"),
        "approval_handoff.concurrent_state_drift": (
            handoff.get("concurrent_state_drift"), "fail_closed"),
        "monitor.owner": (monitor.get("owner"), "existing_workflow_monitor"),
        "monitor.polling": (monitor.get("polling"), "existing_monitor_loop"),
        "monitor.discovery": (
            monitor.get("discovery"), "github_open_machine_pull_requests"),
        "monitor.linear_access": (
            monitor.get("linear_access"), "approved_candidates_only"),
        "monitor.github_credential": (
            monitor.get("github_credential"), "github-machine-arrusted-symphony"),
    }
    for field, (actual, wanted) in expected.items():
        if type(actual) is not type(wanted) or actual != wanted:
            raise ValueError(f"unsupported requester policy value: {field}")
    mappings = requester.get("creator_email_mappings")
    if not isinstance(mappings, list) or not mappings:
        raise ValueError("invalid requester policy identity")
    normalized = {}
    for mapping in mappings:
        if not isinstance(mapping, dict) \
                or set(mapping) != {"linear_creator_email", "github_login"}:
            raise ValueError("invalid requester mapping")
        email = mapping["linear_creator_email"]
        login = mapping["github_login"]
        if not isinstance(email, str) or re.fullmatch(r"[^@\s]+@[^@\s]+", email) is None \
                or not isinstance(login, str) or not login or email in normalized:
            raise ValueError("ambiguous requester mapping")
        normalized[email] = login
    policy["_requester_by_email"] = normalized
    return policy


def parse_review_timestamp(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        normalized = f"{value[:-1]}+00:00" if value.endswith("Z") else value
        parsed = datetime.fromisoformat(normalized)
        if parsed.tzinfo is None:
            return None
        return parsed.timestamp()
    except (OverflowError, ValueError):
        return None


def requester_approval_is_current(reviews, pull_number, requester_login):
    requester_reviews = []
    for review in reviews:
        if not isinstance(review, dict):
            return False
        user = review.get("user")
        state = review.get("state")
        if not isinstance(user, dict) or user.get("login") != requester_login:
            continue
        if user.get("type") != "User" or state == "COMMENTED":
            continue
        if state not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            return False
        submitted_at = parse_review_timestamp(review.get("submitted_at"))
        if submitted_at is None:
            return False
        requester_reviews.append(
            (submitted_at, state, review.get("pull_request_number", pull_number)))
    requester_reviews = [
        review for review in requester_reviews if review[2] == pull_number
    ]
    if not requester_reviews:
        return False
    latest = max(review[0] for review in requester_reviews)
    latest_states = {review[1] for review in requester_reviews if review[0] == latest}
    return latest_states == {"APPROVED"}


class ApprovalHandoff:
    REQUESTER_LINE = re.compile(
        r"Requester: .+ \(([^()\s]+@[^()\s]+)\) \(@([^()\s]+)\)")
    LINEAR_LINE = re.compile(
        r"Linear issue: \[([A-Z][A-Z0-9]*-\d+)\]"
        r"\((https://linear\.app/[^)\s]+/issue/\1/[^)\s]+)\)")
    FIXES_LINE = re.compile(r"Fixes ([A-Z][A-Z0-9]*-\d+)")

    def __init__(self, project_slug, linear_key, github_token, policy, request_json,
                 wall_clock=time.time, retry_clock=time.monotonic,
                 candidate_retry_seconds=300):
        self.project_slug = project_slug
        self.linear_key = linear_key
        self.github_token = github_token
        self.policy = policy
        self.request_json = request_json
        self.wall_clock = wall_clock
        self.retry_clock = retry_clock
        if type(candidate_retry_seconds) is not int or candidate_retry_seconds <= 0:
            raise ValueError("approval handoff retry seconds must be a positive integer")
        self.candidate_retry_seconds = candidate_retry_seconds
        self.candidate_attempts = {}
        self.linear_requests = 0

    def linear(self, query, variables):
        self.linear_requests += 1
        body = json.dumps({"query": query, "variables": variables}).encode()
        result = self.request_json(
            LINEAR_URL, data=body,
            headers={"Authorization": self.linear_key, "Content-Type": "application/json"})
        if not isinstance(result, dict) or result.get("errors"):
            raise RuntimeError("Linear approval handoff request failed")
        data = result.get("data")
        if not isinstance(data, dict):
            raise ValueError("invalid Linear approval handoff response")
        return data

    def github(self, path):
        return self.request_json(
            f"{GITHUB_API_URL}{path}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.github_token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "symphony-approval-handoff",
            })

    def open_pull_requests(self):
        repository = self.policy["repository"]
        page = 1
        while True:
            payload = self.github(
                f"/repos/{repository}/pulls?state=open&per_page=100&page={page}")
            if not isinstance(payload, list):
                raise ValueError("invalid GitHub pull request page")
            for pull in payload:
                if not isinstance(pull, dict):
                    raise ValueError("invalid GitHub pull request")
                yield pull
            if len(payload) < 100:
                return
            page += 1

    def requester_metadata(self, pull):
        body = pull.get("body")
        if not isinstance(body, str):
            return None
        lines = body.splitlines()
        requester_lines = [
            line for line in lines if re.match(r"^Requester:", line, re.IGNORECASE)]
        linear_lines = [
            line for line in lines if re.match(r"^Linear issue:", line, re.IGNORECASE)]
        fixes_lines = [
            line for line in lines if re.match(r"^Fixes\b", line, re.IGNORECASE)]
        if len(requester_lines) != 1 or len(linear_lines) != 1 \
                or len(fixes_lines) != 1:
            return None
        requester = self.REQUESTER_LINE.fullmatch(requester_lines[0])
        linear = self.LINEAR_LINE.fullmatch(linear_lines[0])
        fixes = self.FIXES_LINE.fullmatch(fixes_lines[0])
        if requester is None or linear is None or fixes is None:
            return None
        email, login = requester.groups()
        identifier, linear_url = linear.groups()
        if fixes.group(1) != identifier \
                or self.policy["_requester_by_email"].get(email) != login:
            return None
        return {
            "requester_email": email,
            "requester_login": login,
            "issue_identifier": identifier,
            "linear_url": linear_url,
        }

    def reviews(self, pull_number):
        repository = self.policy["repository"]
        reviews = []
        page = 1
        while True:
            payload = self.github(
                f"/repos/{repository}/pulls/{pull_number}/reviews?per_page=100&page={page}")
            if not isinstance(payload, list):
                raise ValueError("invalid GitHub reviews response")
            reviews.extend(payload)
            if len(payload) < 100:
                return reviews
            page += 1

    def approval_fingerprint(self, pull, metadata, reviews):
        if not requester_approval_is_current(
                reviews, pull["number"], metadata["requester_login"]):
            return None
        requester_reviews = [
            review for review in reviews
            if isinstance(review, dict)
            and isinstance(review.get("user"), dict)
            and review["user"].get("login") == metadata["requester_login"]
            and review.get("state") != "COMMENTED"
        ]
        latest = max(parse_review_timestamp(review.get("submitted_at"))
                     for review in requester_reviews)
        head = pull.get("head")
        head_sha = head.get("sha") if isinstance(head, dict) else None
        if not isinstance(head_sha, str) or not head_sha:
            raise ValueError("invalid GitHub pull request head")
        return (
            pull["number"], head_sha, metadata["issue_identifier"],
            metadata["requester_login"], latest,
        )

    def candidate_due(self, pull_number, fingerprint):
        previous = self.candidate_attempts.get(pull_number)
        now = self.retry_clock()
        if previous is not None and previous[0] == fingerprint \
                and now - previous[1] < self.candidate_retry_seconds:
            return False
        self.candidate_attempts[pull_number] = (fingerprint, now)
        return True

    def fresh_issue(self, identifier):
        query = """query ApprovalHandoffIssue($id: String!) {
          issue(id: $id) {
            id
            identifier
            url
            creator { email }
            state { name }
            project { slugId }
            attachments(first: 100) {
              nodes { url }
              pageInfo { hasNextPage }
            }
            team { states { nodes { id name } } }
          }
        }"""
        issue = self.linear(query, {"id": identifier}).get("issue")
        if not isinstance(issue, dict):
            raise ValueError("invalid fresh Linear issue")
        return issue

    def attached_pull_numbers(self, issue):
        attachments = issue.get("attachments")
        if not isinstance(attachments, dict) or not isinstance(attachments.get("nodes"), list):
            raise ValueError("invalid Linear issue attachments")
        page_info = attachments.get("pageInfo")
        if not isinstance(page_info, dict) or type(page_info.get("hasNextPage")) is not bool:
            raise ValueError("invalid Linear issue attachment page")
        if page_info["hasNextPage"]:
            raise RuntimeError("Linear issue has more attachments than the handoff query limit")
        prefix = f"https://github.com/{self.policy['repository']}/pull/"
        numbers = set()
        for attachment in attachments["nodes"]:
            url = attachment.get("url") if isinstance(attachment, dict) else None
            if not isinstance(url, str) or not url.startswith(prefix):
                continue
            suffix = url[len(prefix):].rstrip("/")
            if suffix.isdigit():
                numbers.add(int(suffix))
        return sorted(numbers)

    def validate_transition_candidate(self, issue, metadata):
        creator = issue.get("creator")
        state = issue.get("state")
        project = issue.get("project")
        team = issue.get("team")
        states = team.get("states") if isinstance(team, dict) else None
        nodes = states.get("nodes") if isinstance(states, dict) else None
        if not isinstance(creator, dict) or not isinstance(state, dict) \
                or not isinstance(project, dict) \
                or not isinstance(nodes, list):
            raise ValueError("invalid fresh Linear issue state")
        if issue.get("identifier") != metadata["issue_identifier"] \
                or issue.get("url") != metadata["linear_url"] \
                or project.get("slugId") != self.project_slug \
                or creator.get("email") != metadata["requester_email"] \
                or self.policy["_requester_by_email"].get(
                    creator.get("email")) != metadata["requester_login"]:
            return None
        if state.get("name") != self.policy["approval_handoff"]["source_state"]:
            return None
        destination = self.policy["approval_handoff"]["destination_state"]
        matches = [
            candidate.get("id") for candidate in nodes
            if isinstance(candidate, dict) and candidate.get("name") == destination
            and isinstance(candidate.get("id"), str) and candidate["id"]
        ]
        if len(matches) != 1 or not isinstance(issue.get("id"), str) or not issue["id"]:
            raise ValueError("Linear destination state is missing or ambiguous")
        return issue["id"], matches[0]

    def github_authorization_is_fresh(self, issue, pull, metadata, fingerprint):
        repository = self.policy["repository"]
        pull_number = pull["number"]
        open_attached = []
        fresh_pull = None
        for attached_number in self.attached_pull_numbers(issue):
            attached = self.github(f"/repos/{repository}/pulls/{attached_number}")
            if not isinstance(attached, dict) or attached.get("number") != attached_number:
                raise ValueError("invalid fresh GitHub pull request")
            if attached.get("state") == "open":
                open_attached.append(attached_number)
            if attached_number == pull_number:
                fresh_pull = attached
        if open_attached != [pull_number] or fresh_pull is None:
            return False
        user = fresh_pull.get("user")
        if not isinstance(user, dict) \
                or user.get("login") != self.policy["machine_login"] \
                or self.requester_metadata(fresh_pull) != metadata:
            return False
        fresh_fingerprint = self.approval_fingerprint(
            fresh_pull, metadata, self.reviews(pull_number))
        return fresh_fingerprint == fingerprint

    def transition(self, issue_id, destination_state_id):
        mutation = """mutation ApprovalHandoff($id: String!, $stateId: String!) {
          issueUpdate(id: $id, input: {stateId: $stateId}) {
            success
            issue { id state { name } }
          }
        }"""
        result = self.linear(
            mutation, {"id": issue_id, "stateId": destination_state_id}).get("issueUpdate")
        expected = self.policy["approval_handoff"]["destination_state"]
        updated_issue = result.get("issue") if isinstance(result, dict) else None
        state = updated_issue.get("state") if isinstance(updated_issue, dict) else None
        if not isinstance(result, dict) or result.get("success") is not True \
                or not isinstance(state, dict) or state.get("name") != expected:
            raise RuntimeError("Linear approval handoff mutation was not acknowledged")

    def reconcile_pull(self, pull):
        number = pull.get("number")
        if type(number) is not int or number <= 0 or pull.get("state") != "open":
            raise ValueError("invalid GitHub pull request identity")
        metadata = self.requester_metadata(pull)
        if metadata is None:
            return "metadata_ineligible"
        reviews = self.reviews(number)
        fingerprint = self.approval_fingerprint(pull, metadata, reviews)
        if fingerprint is None:
            return "requester_not_approved"
        if not self.candidate_due(number, fingerprint):
            return "candidate_deferred"
        issue = self.fresh_issue(metadata["issue_identifier"])
        transition = self.validate_transition_candidate(issue, metadata)
        if transition is None:
            return "linear_ineligible"
        if not self.github_authorization_is_fresh(
                issue, pull, metadata, fingerprint):
            return "github_state_drift"
        issue_id, destination_state_id = transition
        self.transition(issue_id, destination_state_id)
        print(json.dumps({
            "event": "linear_approval_handoff_transition",
            "issue_id": issue_id,
            "issue_identifier": metadata["issue_identifier"],
            "pull_request": number,
            "requester": metadata["requester_login"],
            "source_state": self.policy["approval_handoff"]["source_state"],
            "destination_state": self.policy["approval_handoff"]["destination_state"],
            "timestamp": int(self.wall_clock()),
        }, sort_keys=True), flush=True)
        return "transitioned"

    def reconcile(self):
        outcomes = {
            "observed": 0, "linear_candidates": 0, "linear_requests": 0,
            "deferred": 0, "transitioned": 0, "failed": 0,
        }
        self.linear_requests = 0
        pulls = list(self.open_pull_requests())
        machine_pulls = [
            pull for pull in pulls
            if isinstance(pull.get("user"), dict)
            and pull["user"].get("login") == self.policy["machine_login"]
        ]
        machine_pull_numbers = {
            pull.get("number") for pull in machine_pulls
            if type(pull.get("number")) is int
        }
        self.candidate_attempts = {
            number: attempt for number, attempt in self.candidate_attempts.items()
            if number in machine_pull_numbers
        }
        for pull in machine_pulls:
            outcomes["observed"] += 1
            try:
                before = self.linear_requests
                outcome = self.reconcile_pull(pull)
                if outcome == "candidate_deferred":
                    outcomes["deferred"] += 1
                elif outcome == "transitioned":
                    outcomes["transitioned"] += 1
            except (
                    AttributeError, KeyError, OSError, RuntimeError, TypeError,
                    ValueError, urllib.error.URLError) as error:
                outcomes["failed"] += 1
                print(json.dumps({
                    "event": "linear_approval_handoff_failed",
                    "pull_request": pull.get("number") if isinstance(pull, dict) else None,
                    "error_type": type(error).__name__,
                    "error": str(error),
                    "timestamp": int(self.wall_clock()),
                }, sort_keys=True), file=sys.stderr, flush=True)
            finally:
                if self.linear_requests > before:
                    outcomes["linear_candidates"] += 1
        outcomes["linear_requests"] = self.linear_requests
        return outcomes


class Scaler:
    def __init__(self, now=time.monotonic, wall_clock=time.time):
        self.now = now
        self.wall_clock = wall_clock
        self.namespace = os.getenv("POD_NAMESPACE", "symphony")
        self.statefulset = os.getenv("WORKER_STATEFULSET", "symphony-worker")
        self.symphony_url = os.getenv("SYMPHONY_STATE_URL", "http://symphony-orchestrator:4000/api/v1/state")
        self.symphony_drains_url = os.getenv(
            "SYMPHONY_DRAINS_URL", "http://symphony-orchestrator:4000/api/v1/worker-drains")
        self.symphony_drain_token = os.environ["SYMPHONY_WORKER_DRAIN_TOKEN"]
        if len(self.symphony_drain_token) < 32:
            raise ValueError("SYMPHONY_WORKER_DRAIN_TOKEN must contain at least 32 characters")
        self.minimum = int(os.getenv("MIN_WORKERS", "1"))
        self.maximum = int(os.getenv("MAX_WORKERS", "10"))
        self.agents_per_worker = int(os.getenv("AGENTS_PER_WORKER", "1"))
        self.cooldown_seconds = int(os.getenv("SCALE_DOWN_COOLDOWN_SECONDS", "1200"))
        self.tracker_demand_max_age_seconds = int(
            os.getenv("TRACKER_DEMAND_MAX_AGE_SECONDS", "300"))
        self.kube_host = os.environ["KUBERNETES_SERVICE_HOST"]
        self.kube_port = os.getenv("KUBERNETES_SERVICE_PORT_HTTPS", "443")
        self.token = open("/var/run/secrets/kubernetes.io/serviceaccount/token", encoding="utf-8").read().strip()
        self.ssl_context = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
        self.low_demand_since = None
        self.usage_ledger = UsageLedger(os.getenv("USAGE_LEDGER_PATH", "/var/lib/symphony-metrics/usage.json"))
        self.reconcile_stage = "starting"
        self.error_counts = {}
        self.metrics = {"healthy": 0, "desired": self.minimum, "queue": 0, "blocked": 0,
                        "current": self.minimum, "drained": 0,
                        "cooldown": 0, "errors": 0, "ledger_errors": 0,
                        "handoff_observed": 0, "handoff_transitions": 0,
                        "handoff_linear_candidates": 0,
                        "handoff_linear_requests": 0,
                        "handoff_deferred": 0, "handoff_failures": 0,
                        "last_error": "", "last_error_stage": "",
                        "last_error_timestamp": 0, "last_success_timestamp": 0}
        self.initialize_approval_handoff()

    def initialize_approval_handoff(self):
        self.approval_handoff = None
        try:
            policy = load_requester_policy(
                os.getenv(
                    "REQUESTER_POLICY_PATH",
                    "/etc/symphony-workflow/requester-policy.json"))
            self.approval_handoff = ApprovalHandoff(
                os.environ["LINEAR_PROJECT_SLUG"], os.environ["LINEAR_API_KEY"],
                os.environ["GITHUB_TOKEN"],
                policy, self.request_json, wall_clock=self.wall_clock,
                retry_clock=self.now,
                candidate_retry_seconds=int(os.getenv(
                    "APPROVAL_HANDOFF_RETRY_SECONDS", "300")))
        except (KeyError, OSError, ValueError) as error:
            self.metrics["handoff_failures"] = self.metrics.get("handoff_failures", 0) + 1
            print(json.dumps({
                "event": "linear_approval_handoff_initialization_failed",
                "error_type": type(error).__name__,
                "error": str(error),
                "timestamp": int(self.wall_clock()),
            }, sort_keys=True), file=sys.stderr, flush=True)

    def at_stage(self, stage, function, *args, **kwargs):
        self.reconcile_stage = stage
        return function(*args, **kwargs)

    def record_error(self, stage, error_type):
        counter = (stage, error_type)
        updated = dict(self.error_counts)
        updated[counter] = updated.get(counter, 0) + 1
        self.error_counts = updated

    def request_json(self, url, *, data=None, headers=None, method=None, context=None):
        request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
        with urllib.request.urlopen(request, timeout=10, context=context) as response:
            return json.load(response)

    def symphony_state(self):
        state = self.request_json(self.symphony_url)
        try:
            self.usage_ledger.observe(state)
        except (OSError, TypeError, ValueError, AttributeError):
            self.metrics["ledger_errors"] += 1
        return state

    def set_worker_drains(self, hosts):
        body = json.dumps({"drained_worker_hosts": hosts}).encode()
        result = self.request_json(
            self.symphony_drains_url, data=body,
            headers={"Authorization": f"Bearer {self.symphony_drain_token}",
                     "Content-Type": "application/json"}, method="PUT")
        if result.get("drained_hosts") != sorted(hosts) \
                or not isinstance(result.get("active_drained_hosts"), list):
            raise ValueError("invalid Symphony worker drain acknowledgement")
        return result

    def scale_url(self):
        return (f"https://{self.kube_host}:{self.kube_port}/apis/apps/v1/namespaces/"
                f"{self.namespace}/statefulsets/{self.statefulset}/scale")

    def current_workers(self):
        scale = self.request_json(self.scale_url(), headers={"Authorization": f"Bearer {self.token}"},
                                  context=self.ssl_context)
        spec = scale.get("spec") if isinstance(scale, dict) else None
        status = scale.get("status") if isinstance(scale, dict) else None
        metadata = scale.get("metadata") if isinstance(scale, dict) else None
        if not isinstance(spec, dict) or not isinstance(status, dict) or not isinstance(metadata, dict):
            raise ValueError("invalid Kubernetes Scale response")
        replicas = spec.get("replicas") if "replicas" in spec else status.get("replicas")
        resource_version = metadata.get("resourceVersion")
        if type(replicas) is not int or replicas < 0 \
                or not isinstance(resource_version, str) or not resource_version:
            raise ValueError("invalid Kubernetes Scale response")
        return replicas, resource_version

    def set_workers(self, replicas, resource_version):
        body = json.dumps({"apiVersion": "autoscaling/v1", "kind": "Scale",
                           "metadata": {"name": self.statefulset, "namespace": self.namespace,
                                        "resourceVersion": resource_version},
                           "spec": {"replicas": replicas}}).encode()
        self.request_json(self.scale_url(), data=body,
                          headers={"Authorization": f"Bearer {self.token}",
                                   "Content-Type": "application/json"}, method="PUT", context=self.ssl_context)

    def pods_url(self):
        return (f"https://{self.kube_host}:{self.kube_port}/api/v1/namespaces/"
                f"{self.namespace}/pods?labelSelector=app%3Dsymphony-worker")

    def ready_workers(self, configured_hosts, current_workers):
        pods = self.request_json(self.pods_url(), headers={"Authorization": f"Bearer {self.token}"},
                                 context=self.ssl_context)
        ready_names = set()
        for pod in pods.get("items", []):
            name = pod.get("metadata", {}).get("name")
            conditions = pod.get("status", {}).get("conditions", [])
            if any(condition.get("type") == "Ready" and condition.get("status") == "True"
                   for condition in conditions):
                ready_names.add(name)
        ready = 0
        for host in configured_hosts[:current_workers]:
            if host.split(".", 1)[0] not in ready_names:
                break
            ready += 1
        return ready

    def reconcile(self):
        state = self.at_stage("symphony_state", self.symphony_state)
        current, resource_version = self.at_stage("kubernetes_scale_read", self.current_workers)
        busy, active_floor, configured_hosts = self.at_stage(
            "state_validation", worker_pool_activity, state, current, self.statefulset)
        try:
            issue_count, blocked_count = self.at_stage(
                "tracker_demand", tracker_demand, state,
                self.wall_clock(), self.tracker_demand_max_age_seconds)
        except ValueError:
            if busy == 0:
                raise
            issue_count, blocked_count = busy, 0
        ready = self.at_stage("kubernetes_pods", self.ready_workers, configured_hosts, current)
        target = self.at_stage(
            "demand_calculation", desired_workers,
            issue_count, self.agents_per_worker, self.minimum, self.maximum)
        self.reconcile_stage = "capacity_validation"
        if target > len(configured_hosts):
            raise ValueError("autoscaler target exceeds configured Symphony worker hosts")
        now = self.now()
        drained_count = 0
        if target > current:
            acknowledgement = self.at_stage(
                "symphony_drains", self.set_worker_drains, configured_hosts[ready:])
            drained_count = len(acknowledgement["drained_hosts"])
            if not acknowledgement["active_drained_hosts"]:
                self.at_stage("kubernetes_scale_write", self.set_workers, target, resource_version)
                current = target
                self.low_demand_since = None
        elif target < current:
            if busy:
                self.low_demand_since = None
                safe_target = max(target, active_floor)
                if safe_target < current:
                    acknowledgement = self.at_stage(
                        "symphony_drains", self.set_worker_drains,
                        configured_hosts[safe_target:])
                    drained_count = len(acknowledgement["drained_hosts"])
                    if not acknowledgement["active_drained_hosts"]:
                        self.at_stage(
                            "kubernetes_scale_write", self.set_workers,
                            safe_target, resource_version)
                        current = safe_target
                else:
                    drained_count = len(self.at_stage(
                        "symphony_drains", self.set_worker_drains,
                        configured_hosts[current:])["drained_hosts"])
            elif self.low_demand_since is None:
                self.low_demand_since = now
                drained_count = len(self.at_stage(
                    "symphony_drains", self.set_worker_drains,
                    configured_hosts[current:])["drained_hosts"])
            elif now - self.low_demand_since >= self.cooldown_seconds:
                acknowledgement = self.at_stage(
                    "symphony_drains", self.set_worker_drains, configured_hosts[target:])
                drained_count = len(acknowledgement["drained_hosts"])
                if not acknowledgement["active_drained_hosts"]:
                    self.at_stage(
                        "kubernetes_scale_write", self.set_workers, target, resource_version)
                    current = target
                    self.low_demand_since = None
            else:
                drained_count = len(self.at_stage(
                    "symphony_drains", self.set_worker_drains,
                    configured_hosts[current:])["drained_hosts"])
        else:
            self.low_demand_since = None
            drained_count = len(self.at_stage(
                "symphony_drains", self.set_worker_drains,
                configured_hosts[min(ready, current):])["drained_hosts"])
        cooldown = 0 if self.low_demand_since is None else max(0, self.cooldown_seconds - int(now - self.low_demand_since))
        self.metrics.update(healthy=1, desired=target, queue=issue_count, blocked=blocked_count,
                            current=current, drained=drained_count,
                            cooldown=cooldown)

    def run_once(self):
        try:
            self.reconcile()
            self.metrics["last_success_timestamp"] = int(self.wall_clock())
        except (
                AttributeError, KeyError, OSError, RuntimeError, TypeError,
                ValueError, urllib.error.URLError) as error:
            self.low_demand_since = None
            error_type = type(error).__name__
            timestamp = int(self.wall_clock())
            self.record_error(self.reconcile_stage, error_type)
            self.metrics.update(healthy=0, errors=self.metrics["errors"] + 1,
                                last_error=error_type,
                                last_error_stage=self.reconcile_stage,
                                last_error_timestamp=timestamp)
            print(json.dumps({
                "event": "autoscaler_reconcile_failed",
                "stage": self.reconcile_stage,
                "error_type": error_type,
                "error": str(error),
                "timestamp": timestamp,
            }, sort_keys=True), file=sys.stderr, flush=True)
        if not hasattr(self, "approval_handoff"):
            return
        handoff = self.approval_handoff
        if handoff is None:
            self.initialize_approval_handoff()
            handoff = self.approval_handoff
            if handoff is None:
                return
        try:
            outcomes = handoff.reconcile()
            self.metrics["handoff_observed"] = outcomes["observed"]
            self.metrics["handoff_linear_candidates"] = (
                self.metrics.get("handoff_linear_candidates", 0)
                + outcomes["linear_candidates"])
            self.metrics["handoff_linear_requests"] = (
                self.metrics.get("handoff_linear_requests", 0)
                + outcomes["linear_requests"])
            self.metrics["handoff_deferred"] = (
                self.metrics.get("handoff_deferred", 0) + outcomes["deferred"])
            self.metrics["handoff_transitions"] = (
                self.metrics.get("handoff_transitions", 0) + outcomes["transitioned"])
            self.metrics["handoff_failures"] = (
                self.metrics.get("handoff_failures", 0) + outcomes["failed"])
        except (
                AttributeError, KeyError, OSError, RuntimeError, TypeError,
                ValueError, urllib.error.URLError) as error:
            self.metrics["handoff_failures"] = self.metrics.get("handoff_failures", 0) + 1
            print(json.dumps({
                "event": "linear_approval_handoff_failed",
                "error_type": type(error).__name__,
                "error": str(error),
                "timestamp": int(self.wall_clock()),
            }, sort_keys=True), file=sys.stderr, flush=True)


def metrics_lines(scaler):
    metrics = dict(scaler.metrics)
    lines = [
        f'symphony_autoscaler_healthy {metrics["healthy"]}',
        f'symphony_autoscaler_desired_workers {metrics["desired"]}',
        f'symphony_autoscaler_current_workers {metrics["current"]}',
        f'symphony_autoscaler_drained_workers {metrics["drained"]}',
        f'symphony_autoscaler_runnable_issues {metrics["queue"]}',
        f'symphony_autoscaler_blocked_issues {metrics["blocked"]}',
        f'symphony_autoscaler_idle {int(metrics["queue"] == 0)}',
        f'symphony_autoscaler_active_minimum_workers {scaler.minimum}',
        f'symphony_autoscaler_scale_down_cooldown_seconds {metrics["cooldown"]}',
        f'symphony_autoscaler_errors_total {metrics["errors"]}',
        f'symphony_usage_ledger_errors_total {metrics["ledger_errors"] + scaler.usage_ledger.load_errors}',
        f'symphony_approval_handoff_observed_pull_requests {metrics.get("handoff_observed", 0)}',
        f'symphony_approval_handoff_linear_candidates_total {metrics.get("handoff_linear_candidates", 0)}',
        f'symphony_approval_handoff_linear_requests_total {metrics.get("handoff_linear_requests", 0)}',
        f'symphony_approval_handoff_deferred_candidates_total {metrics.get("handoff_deferred", 0)}',
        f'symphony_approval_handoff_transitions_total {metrics.get("handoff_transitions", 0)}',
        f'symphony_approval_handoff_failures_total {metrics.get("handoff_failures", 0)}',
        f'symphony_autoscaler_last_error_timestamp_seconds {metrics["last_error_timestamp"]}',
        f'symphony_autoscaler_last_success_timestamp_seconds {metrics["last_success_timestamp"]}',
    ]
    if metrics["last_error"]:
        lines.extend([
            f'symphony_autoscaler_last_error{{type="{metrics["last_error"]}"}} 1',
            f'symphony_autoscaler_last_error_info{{stage="{metrics["last_error_stage"]}",type="{metrics["last_error"]}"}} 1',
        ])
    error_counts = scaler.error_counts
    for (stage, error_type), count in sorted(error_counts.items()):
        lines.append(
            f'symphony_autoscaler_reconcile_errors_total{{stage="{stage}",type="{error_type}"}} {count}')
    ledger = scaler.usage_ledger.snapshot()
    lines.append(f'symphony_usage_ledger_sessions {len(ledger["sessions"])}')
    lines.append(f'symphony_usage_ledger_issues {len(ledger["issues"])}')
    for field in TOKEN_FIELDS:
        lines.append(f'symphony_usage_ledger_{field} {sum(issue[field] for issue in ledger["issues"].values())}')
    return lines


class MetricsHandler(BaseHTTPRequestHandler):
    scaler = None

    def do_GET(self):
        if self.path == "/healthz":
            status = 200 if self.scaler.metrics["healthy"] else 503
            self.send_response(status)
            self.end_headers()
            return
        if self.path == "/usage":
            body = (json.dumps(self.scaler.usage_ledger.snapshot(), sort_keys=True) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = ("\n".join(metrics_lines(self.scaler)) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


def main():
    scaler = Scaler()
    MetricsHandler.scaler = scaler
    server = ThreadingHTTPServer(("0.0.0.0", 8080), MetricsHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    interval = int(os.getenv("POLL_INTERVAL_SECONDS", "15"))
    while True:
        scaler.run_once()
        time.sleep(interval)


if __name__ == "__main__":
    main()

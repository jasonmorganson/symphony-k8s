#!/usr/bin/env python3
import json
import math
import os
import ssl
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LINEAR_URL = "https://api.linear.app/graphql"
RUNNABLE_STATES = ("Todo", "In Progress", "Rework", "Merging")
TERMINAL_STATE_TYPES = ("completed", "canceled")
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


def desired_workers(issue_count, agents_per_worker=1, minimum=1, maximum=5):
    if issue_count == 0:
        return 0
    return max(minimum, min(maximum, math.ceil(issue_count / agents_per_worker)))


def issue_is_runnable(issue):
    state = issue.get("state")
    if not isinstance(state, dict) or not isinstance(state.get("name"), str):
        raise ValueError("invalid Linear issue state")
    if state["name"] != "Todo":
        return True
    blockers = issue.get("inverseRelations")
    if not isinstance(blockers, dict) or not isinstance(blockers.get("nodes"), list) \
            or not isinstance(blockers.get("pageInfo"), dict):
        raise ValueError("invalid Linear blocker relations")
    if blockers["pageInfo"].get("hasNextPage"):
        raise RuntimeError("Linear issue has more blockers than the autoscaler query limit")
    for relation in blockers["nodes"]:
        if not isinstance(relation, dict) or not isinstance(relation.get("type"), str):
            raise ValueError("invalid Linear blocker relation")
        if relation["type"] != "blocks":
            continue
        blocker = relation.get("issue")
        blocker_state = blocker.get("state") if isinstance(blocker, dict) else None
        if not isinstance(blocker_state, dict) or not isinstance(blocker_state.get("type"), str):
            raise ValueError("invalid Linear blocker state")
        if blocker_state["type"] not in TERMINAL_STATE_TYPES:
            return False
    return True


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


class Scaler:
    def __init__(self, now=time.monotonic, wall_clock=time.time):
        self.now = now
        self.wall_clock = wall_clock
        self.namespace = os.getenv("POD_NAMESPACE", "symphony")
        self.statefulset = os.getenv("WORKER_STATEFULSET", "symphony-worker")
        self.project_slug = os.environ["LINEAR_PROJECT_SLUG"]
        self.linear_key = os.environ["LINEAR_API_KEY"]
        self.symphony_url = os.getenv("SYMPHONY_STATE_URL", "http://symphony-orchestrator:4000/api/v1/state")
        self.symphony_drains_url = os.getenv(
            "SYMPHONY_DRAINS_URL", "http://symphony-orchestrator:4000/api/v1/worker-drains")
        self.symphony_drain_token = os.environ["SYMPHONY_WORKER_DRAIN_TOKEN"]
        if len(self.symphony_drain_token) < 32:
            raise ValueError("SYMPHONY_WORKER_DRAIN_TOKEN must contain at least 32 characters")
        self.minimum = int(os.getenv("MIN_WORKERS", "1"))
        self.maximum = int(os.getenv("MAX_WORKERS", "5"))
        self.agents_per_worker = int(os.getenv("AGENTS_PER_WORKER", "1"))
        self.cooldown_seconds = int(os.getenv("SCALE_DOWN_COOLDOWN_SECONDS", "1200"))
        self.linear_rate_limit_cooldown_seconds = int(
            os.getenv("LINEAR_RATE_LIMIT_COOLDOWN_SECONDS", "60"))
        self.linear_cooldown_until = 0
        self.last_linear_counts = None
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
                        "last_error": "", "last_error_stage": "",
                        "last_error_timestamp": 0, "last_success_timestamp": 0}

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

    def linear_issue_count(self):
        if self.now() < self.linear_cooldown_until:
            return self._linear_counts_during_cooldown()

        query = """query AutoscalerIssues($slug: String!, $states: [String!]!, $after: String) {
          issues(first: 100, after: $after, filter: {project: {slugId: {eq: $slug}}, state: {name: {in: $states}}}) {
            nodes {
              id
              state { name }
              inverseRelations(first: 50) {
                nodes { type issue { state { type } } }
                pageInfo { hasNextPage }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }"""
        count = 0
        blocked = 0
        after = None
        while True:
            body = json.dumps({"query": query, "variables": {"slug": self.project_slug,
                              "states": list(RUNNABLE_STATES), "after": after}}).encode()
            try:
                result = self.request_json(
                    LINEAR_URL, data=body,
                    headers={"Authorization": self.linear_key, "Content-Type": "application/json"})
            except urllib.error.HTTPError as error:
                if self._linear_http_error_is_rate_limited(error):
                    self._activate_linear_cooldown(self._retry_after_seconds(error))
                    return self._linear_counts_during_cooldown()
                raise
            if result.get("errors"):
                if self._linear_result_is_rate_limited(result):
                    self._activate_linear_cooldown()
                    return self._linear_counts_during_cooldown()
                raise RuntimeError("Linear GraphQL request failed")
            page = result["data"]["issues"]
            for issue in page["nodes"]:
                if issue_is_runnable(issue):
                    count += 1
                else:
                    blocked += 1
            if not page["pageInfo"]["hasNextPage"]:
                self.last_linear_counts = (count, blocked)
                return self.last_linear_counts
            after = page["pageInfo"]["endCursor"]

    def _activate_linear_cooldown(self, retry_after_seconds=None):
        seconds = retry_after_seconds
        if not isinstance(seconds, int) or seconds < 0:
            seconds = self.linear_rate_limit_cooldown_seconds
        self.linear_cooldown_until = max(self.linear_cooldown_until, self.now() + seconds)

    def _linear_counts_during_cooldown(self):
        if self.last_linear_counts is not None:
            return self.last_linear_counts
        remaining = max(0, math.ceil(self.linear_cooldown_until - self.now()))
        raise RuntimeError(f"Linear rate limited; shared cooldown has {remaining}s remaining")

    @staticmethod
    def _linear_result_is_rate_limited(result):
        errors = result.get("errors") if isinstance(result, dict) else None
        if not isinstance(errors, list):
            return False
        for error in errors:
            extensions = error.get("extensions") if isinstance(error, dict) else None
            if isinstance(extensions, dict) and (
                    extensions.get("code") == "RATELIMITED"
                    or extensions.get("statusCode") == 429):
                return True
        return False

    @classmethod
    def _linear_http_error_is_rate_limited(cls, error):
        if error.code == 429:
            return True
        try:
            return cls._linear_result_is_rate_limited(json.load(error))
        except (OSError, ValueError, TypeError, AttributeError):
            return False

    @staticmethod
    def _retry_after_seconds(response):
        value = response.headers.get("Retry-After") if response.headers is not None else None
        try:
            return max(0, int(value))
        except (TypeError, ValueError):
            return None

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
        issue_count, blocked_count = self.at_stage("linear", self.linear_issue_count)
        state = self.at_stage("symphony_state", self.symphony_state)
        current, resource_version = self.at_stage("kubernetes_scale_read", self.current_workers)
        busy, active_floor, configured_hosts = self.at_stage(
            "state_validation", worker_pool_activity, state, current, self.statefulset)
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
        except (KeyError, OSError, RuntimeError, ValueError, urllib.error.URLError) as error:
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

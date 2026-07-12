#!/usr/bin/env python3
import json
import math
import os
import ssl
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LINEAR_URL = "https://api.linear.app/graphql"
RUNNABLE_STATES = ("Todo", "In Progress", "Rework", "Merging")
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


def desired_workers(issue_count, agents_per_worker=1, minimum=2, maximum=5):
    if issue_count == 0:
        return 0
    return max(minimum, min(maximum, math.ceil(issue_count / agents_per_worker)))


class Scaler:
    def __init__(self, now=time.monotonic):
        self.now = now
        self.namespace = os.getenv("POD_NAMESPACE", "symphony")
        self.statefulset = os.getenv("WORKER_STATEFULSET", "symphony-worker")
        self.project_slug = os.environ["LINEAR_PROJECT_SLUG"]
        self.linear_key = os.environ["LINEAR_API_KEY"]
        self.symphony_url = os.getenv("SYMPHONY_STATE_URL", "http://symphony-orchestrator:4000/api/v1/state")
        self.minimum = int(os.getenv("MIN_WORKERS", "2"))
        self.maximum = int(os.getenv("MAX_WORKERS", "5"))
        self.agents_per_worker = int(os.getenv("AGENTS_PER_WORKER", "1"))
        self.cooldown_seconds = int(os.getenv("SCALE_DOWN_COOLDOWN_SECONDS", "1200"))
        self.kube_host = os.environ["KUBERNETES_SERVICE_HOST"]
        self.kube_port = os.getenv("KUBERNETES_SERVICE_PORT_HTTPS", "443")
        self.token = open("/var/run/secrets/kubernetes.io/serviceaccount/token", encoding="utf-8").read().strip()
        self.ssl_context = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
        self.low_demand_since = None
        self.usage_ledger = UsageLedger(os.getenv("USAGE_LEDGER_PATH", "/var/lib/symphony-metrics/usage.json"))
        self.metrics = {"healthy": 0, "desired": self.minimum, "queue": 0, "current": self.minimum,
                        "cooldown": 0, "errors": 0, "ledger_errors": 0,
                        "last_error": "starting"}

    def request_json(self, url, *, data=None, headers=None, method=None, context=None):
        request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
        with urllib.request.urlopen(request, timeout=10, context=context) as response:
            return json.load(response)

    def linear_issue_count(self):
        query = """query AutoscalerIssues($slug: String!, $states: [String!]!, $after: String) {
          issues(first: 100, after: $after, filter: {project: {slugId: {eq: $slug}}, state: {name: {in: $states}}}) {
            nodes { id }
            pageInfo { hasNextPage endCursor }
          }
        }"""
        count = 0
        after = None
        while True:
            body = json.dumps({"query": query, "variables": {"slug": self.project_slug,
                              "states": list(RUNNABLE_STATES), "after": after}}).encode()
            result = self.request_json(LINEAR_URL, data=body,
                                       headers={"Authorization": self.linear_key, "Content-Type": "application/json"})
            if result.get("errors"):
                raise RuntimeError("Linear GraphQL request failed")
            page = result["data"]["issues"]
            count += len(page["nodes"])
            if not page["pageInfo"]["hasNextPage"]:
                return count
            after = page["pageInfo"]["endCursor"]

    def symphony_state(self):
        state = self.request_json(self.symphony_url)
        try:
            self.usage_ledger.observe(state)
        except (OSError, TypeError, ValueError, AttributeError):
            self.metrics["ledger_errors"] += 1
        return state

    def symphony_busy(self):
        state = self.symphony_state()
        counts = state.get("counts", {})
        return int(counts.get("running", len(state.get("running", [])))) + \
            int(counts.get("retrying", len(state.get("retrying", []))))

    def scale_url(self):
        return (f"https://{self.kube_host}:{self.kube_port}/apis/apps/v1/namespaces/"
                f"{self.namespace}/statefulsets/{self.statefulset}/scale")

    def current_workers(self):
        scale = self.request_json(self.scale_url(), headers={"Authorization": f"Bearer {self.token}"},
                                  context=self.ssl_context)
        return int(scale["spec"]["replicas"]), scale["metadata"]["resourceVersion"]

    def set_workers(self, replicas, resource_version):
        body = json.dumps({"apiVersion": "autoscaling/v1", "kind": "Scale",
                           "metadata": {"name": self.statefulset, "namespace": self.namespace,
                                        "resourceVersion": resource_version},
                           "spec": {"replicas": replicas}}).encode()
        self.request_json(self.scale_url(), data=body,
                          headers={"Authorization": f"Bearer {self.token}",
                                   "Content-Type": "application/json"}, method="PUT", context=self.ssl_context)

    def reconcile(self):
        issue_count = self.linear_issue_count()
        busy = self.symphony_busy()
        current, resource_version = self.current_workers()
        target = desired_workers(issue_count, self.agents_per_worker, self.minimum, self.maximum)
        now = self.now()
        if target > current:
            self.set_workers(target, resource_version)
            current = target
            self.low_demand_since = None
        elif target < current:
            if busy:
                self.low_demand_since = None
            elif self.low_demand_since is None:
                self.low_demand_since = now
            elif now - self.low_demand_since >= self.cooldown_seconds:
                self.set_workers(target, resource_version)
                current = target
                self.low_demand_since = None
        else:
            self.low_demand_since = None
        cooldown = 0 if self.low_demand_since is None else max(0, self.cooldown_seconds - int(now - self.low_demand_since))
        self.metrics.update(healthy=1, desired=target, queue=issue_count, current=current,
                            cooldown=cooldown, last_error="")

    def run_once(self):
        try:
            self.reconcile()
        except (KeyError, OSError, RuntimeError, ValueError, urllib.error.URLError) as error:
            self.low_demand_since = None
            self.metrics.update(healthy=0, errors=self.metrics["errors"] + 1,
                                last_error=type(error).__name__)


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
        metrics = self.scaler.metrics
        lines = [
            f'symphony_autoscaler_healthy {metrics["healthy"]}',
            f'symphony_autoscaler_desired_workers {metrics["desired"]}',
            f'symphony_autoscaler_current_workers {metrics["current"]}',
            f'symphony_autoscaler_runnable_issues {metrics["queue"]}',
            f'symphony_autoscaler_idle {int(metrics["queue"] == 0)}',
            f'symphony_autoscaler_active_minimum_workers {self.scaler.minimum}',
            f'symphony_autoscaler_scale_down_cooldown_seconds {metrics["cooldown"]}',
            f'symphony_autoscaler_errors_total {metrics["errors"]}',
            f'symphony_usage_ledger_errors_total {metrics["ledger_errors"] + self.scaler.usage_ledger.load_errors}',
            f'symphony_autoscaler_last_error{{type="{metrics["last_error"]}"}} 1',
        ]
        ledger = self.scaler.usage_ledger.snapshot()
        lines.append(f'symphony_usage_ledger_sessions {len(ledger["sessions"])}')
        lines.append(f'symphony_usage_ledger_issues {len(ledger["issues"])}')
        for field in TOKEN_FIELDS:
            lines.append(f'symphony_usage_ledger_{field} {sum(issue[field] for issue in ledger["issues"].values())}')
        body = ("\n".join(lines) + "\n").encode()
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

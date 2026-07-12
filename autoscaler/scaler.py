#!/usr/bin/env python3
import json
import math
import os
import ssl
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LINEAR_URL = "https://api.linear.app/graphql"
RUNNABLE_STATES = ("Todo", "In Progress", "Rework", "Merging")


def desired_workers(issue_count, agents_per_worker=3, minimum=2, maximum=5):
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
        self.agents_per_worker = int(os.getenv("AGENTS_PER_WORKER", "3"))
        self.cooldown_seconds = int(os.getenv("SCALE_DOWN_COOLDOWN_SECONDS", "1200"))
        self.kube_host = os.environ["KUBERNETES_SERVICE_HOST"]
        self.kube_port = os.getenv("KUBERNETES_SERVICE_PORT_HTTPS", "443")
        self.token = open("/var/run/secrets/kubernetes.io/serviceaccount/token", encoding="utf-8").read().strip()
        self.ssl_context = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
        self.low_demand_since = None
        self.metrics = {"healthy": 0, "desired": self.minimum, "queue": 0, "current": self.minimum,
                        "cooldown": 0, "errors": 0, "last_error": "starting"}

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

    def symphony_busy(self):
        state = self.request_json(self.symphony_url)
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
            f'symphony_autoscaler_last_error{{type="{metrics["last_error"]}"}} 1',
        ]
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

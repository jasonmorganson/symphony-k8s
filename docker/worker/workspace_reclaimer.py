#!/usr/bin/env python3
"""Reclaim terminal Symphony issue workspaces without racing active agents."""

import datetime
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


ISSUE_DIRECTORY = re.compile(r"^A-[1-9][0-9]*$")
TERMINAL_STATE_TYPES = {"completed", "canceled"}


def request_json(url, *, data=None, headers=None, timeout=15):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def active_issue_identifiers(state):
    if not isinstance(state, dict):
        raise ValueError("Symphony state must be an object")
    active = set()
    for field in ("running", "retrying", "blocked"):
        entries = state.get(field)
        if not isinstance(entries, list):
            raise ValueError(f"Symphony state {field} must be a list")
        for entry in entries:
            identifier = entry.get("issue_identifier") if isinstance(entry, dict) else None
            if isinstance(identifier, str):
                active.add(identifier)
    pending = state.get("pending")
    if pending is not None:
        if not isinstance(pending, dict) or not isinstance(pending.get("issues"), list):
            raise ValueError("Symphony pending state must contain an issues list")
        for entry in pending["issues"]:
            identifier = entry.get("issue_identifier") if isinstance(entry, dict) else None
            if isinstance(identifier, str):
                active.add(identifier)
    return active


def issue_directories(root):
    return {
        child.name: child
        for child in root.iterdir()
        if ISSUE_DIRECTORY.fullmatch(child.name) and child.is_dir() and not child.is_symlink()
    }


def linear_issue_states(api_key, identifiers):
    if not identifiers:
        return {}
    fields = []
    for index, identifier in enumerate(sorted(identifiers)):
        fields.append(
            f'i{index}: issue(id: "{identifier}") '
            "{ identifier completedAt canceledAt state { type } }"
        )
    payload = json.dumps({"query": "query WorkspaceReclaimer { " + " ".join(fields) + " }"}).encode()
    result = request_json(
        "https://api.linear.app/graphql",
        data=payload,
        headers={
            "Authorization": api_key,
            "Content-Type": "application/json",
            "User-Agent": "symphony-workspace-reclaimer",
        },
    )
    if not isinstance(result, dict) or result.get("errors") or not isinstance(result.get("data"), dict):
        raise ValueError("Linear workspace reclaimer query failed")
    issues = {}
    for issue in result["data"].values():
        if not isinstance(issue, dict):
            continue
        identifier = issue.get("identifier")
        state = issue.get("state")
        state_type = state.get("type") if isinstance(state, dict) else None
        terminal_at = issue.get("completedAt") or issue.get("canceledAt")
        if isinstance(identifier, str):
            issues[identifier] = {"state_type": state_type, "terminal_at": terminal_at}
    return issues


def parse_timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


class WorkspaceReclaimer:
    def __init__(self, root, state_path, confirmations=2, grace_seconds=3600, wall_clock=time.time):
        self.root = Path(root).resolve()
        self.state_path = Path(state_path)
        self.confirmations = confirmations
        self.grace_seconds = grace_seconds
        self.wall_clock = wall_clock
        if confirmations < 2:
            raise ValueError("reclaimer confirmations must be at least two")
        if grace_seconds < 0:
            raise ValueError("reclaimer grace must be nonnegative")

    def load_observations(self):
        try:
            data = json.loads(self.state_path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def save_observations(self, observations):
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(observations, sort_keys=True), encoding="utf-8")
        os.replace(temporary, self.state_path)

    def reclaim(self, symphony_state, linear_states):
        active = active_issue_identifiers(symphony_state)
        directories = issue_directories(self.root)
        previous = self.load_observations()
        next_observations = {}
        removed = []
        now = self.wall_clock()
        for identifier, path in directories.items():
            issue = linear_states.get(identifier)
            if identifier in active or not isinstance(issue, dict):
                continue
            terminal_at = parse_timestamp(issue.get("terminal_at"))
            if issue.get("state_type") not in TERMINAL_STATE_TYPES or terminal_at is None:
                continue
            if now - terminal_at < self.grace_seconds:
                continue
            count = int(previous.get(identifier, 0)) + 1
            next_observations[identifier] = count
            if count < self.confirmations:
                continue
            resolved = path.resolve()
            if resolved.parent != self.root or resolved.name != identifier:
                raise ValueError("workspace reclamation target escaped the configured root")
            shutil.rmtree(resolved)
            removed.append(identifier)
            next_observations.pop(identifier, None)
        self.save_observations(next_observations)
        return removed


def run():
    root = Path(os.getenv("WORKSPACE_ROOT", "/srv/symphony/workspaces"))
    state_path = os.getenv(
        "WORKSPACE_RECLAIMER_STATE_PATH",
        "/srv/worker-data/.workspace-reclaimer-state.json",
    )
    interval = int(os.getenv("WORKSPACE_RECLAIMER_INTERVAL_SECONDS", "600"))
    if interval < 60:
        raise ValueError("workspace reclaimer interval must be at least 60 seconds")
    reclaimer = WorkspaceReclaimer(
        root,
        state_path,
        confirmations=int(os.getenv("WORKSPACE_RECLAIMER_CONFIRMATIONS", "2")),
        grace_seconds=int(os.getenv("WORKSPACE_RECLAIMER_GRACE_SECONDS", "3600")),
    )
    api_key = os.environ["LINEAR_API_KEY"]
    state_url = os.getenv(
        "SYMPHONY_STATE_URL",
        "http://symphony-orchestrator:4000/api/v1/state",
    )
    while True:
        try:
            state = request_json(state_url)
            directories = issue_directories(reclaimer.root)
            issues = linear_issue_states(api_key, directories)
            removed = reclaimer.reclaim(state, issues)
            print(json.dumps({
                "event": "workspace_reclaimer_completed",
                "observed": len(directories),
                "removed": removed,
                "timestamp": int(time.time()),
            }, sort_keys=True), flush=True)
        except (OSError, RuntimeError, TypeError, ValueError, urllib.error.URLError) as error:
            print(json.dumps({
                "event": "workspace_reclaimer_failed",
                "error_type": type(error).__name__,
                "error": str(error),
                "timestamp": int(time.time()),
            }, sort_keys=True), file=sys.stderr, flush=True)
        time.sleep(interval)


if __name__ == "__main__":
    run()

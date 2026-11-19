"""Qodo calls: local review of uncommitted changes, and the PR review session."""

from __future__ import annotations

import json
import time

from common import sh
from verdict import classify, classify_level


def _parse(out: str) -> dict | None:
    try:
        return json.loads(out)
    except (json.JSONDecodeError, TypeError):
        start = (out or "").find("{")
        if start < 0:
            return None
        try:
            return json.loads(out[start:])
        except json.JSONDecodeError:
            return None


def local_review(qodo: str, workdir: str, repo: str, base: str, context_file: str, timeout_min: int) -> dict:
    """Review staged, unstaged and untracked changes against `base`. Returns a summary dict.

    `repo` is passed explicitly: the work tree's origin is the upstream, which is not connected to Qodo.
    """
    r = sh([qodo, "review", "--repo", repo, "--base", base,
            "--context-file", context_file, "--json"],
           cwd=workdir, timeout=timeout_min * 60)
    data = _parse(r.out)
    if data is None:
        return {"ok": False, "error": (r.err or r.out).strip()[-600:] or f"exit {r.code}"}
    findings = {f.get("id"): f for f in data.get("findings") or []}
    state = data.get("finding_state") or {}
    open_ids = [*(state.get("introduced") or []), *(state.get("still_open") or [])]
    open_ids = [i if isinstance(i, str) else (i or {}).get("id") for i in open_ids]
    open_f = [findings.get(i) or {"id": i} for i in open_ids]
    coverage = ((data.get("meta") or {}).get("coverage") or {}).get("complete")
    by_level = {"blocking": [], "informational": [], "unknown": []}
    for finding in open_f:
        by_level[classify_level(finding.get("action_level"))].append(finding)
    return {
        "ok": True,
        "complete": bool(state.get("complete")) and coverage is not False,
        **by_level,
        "comment": data.get("review_agent_comment"),
        "run": (data.get("meta") or {}).get("run"),
    }


def pr_review(qodo: str, pr_url: str) -> dict | None:
    r = sh([qodo, "read", "pr-review-session", "findings", "--pr-url", pr_url, "--json"], timeout=120)
    return _parse(r.out) if r.ok else None


def wait_pr_review(qodo: str, pr_url: str, head: str, timeout_min: int, poll: int = 60) -> dict:
    """Poll until Qodo finishes a review of `head`. Returns the last read, with `timed_out` set."""
    deadline = time.time() + timeout_min * 60
    last: dict | None = None
    while time.time() < deadline:
        last = pr_review(qodo, pr_url)
        session = (last or {}).get("review_session") or {}
        if session.get("commit_sha") == head and session.get("status") not in (None, "started"):
            return {**last, "timed_out": False}
        time.sleep(poll)
    return {**(last or {}), "timed_out": True}


def blocking(findings: list[dict]) -> list[dict]:
    return [f for f in findings if classify(f) == "blocking"]


def describe(findings: list[dict]) -> str:
    parts = []
    for f in findings:
        loc = f.get("location") or {}
        where = f"{loc.get('file_path')}:{loc.get('start_line')}" if loc.get("file_path") else "?"
        parts.append(f"- id `{f.get('id')}` [{f.get('action_level')}] {f.get('title')} at {where}\n"
                     f"  {(f.get('description') or '').strip()[:1500]}")
    return "\n".join(parts)

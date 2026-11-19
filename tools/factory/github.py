"""GitHub calls through the `gh` CLI. CI query and write failures are recorded."""

from __future__ import annotations

import json

from common import must, sh
from verdict import CIFacts, CIRun


class GitHub:
    def __init__(self, repo: str, *, pull_requests: bool = False) -> None:
        self.repo = repo
        self.resource = "pr" if pull_requests else "issue"
        self.errors: list[str] = []

    def _json(self, args: list[str]):
        return json.loads(must(["gh", *args, "-R", self.repo]) or "null")

    def tickets(self, label: str) -> list[dict]:
        items = self._json(["issue", "list", "--state", "open", "--label", label, "--limit", "50",
                            "--json", "number,title,body,labels,createdAt,url"])
        for it in items:
            it["labels"] = [l["name"] for l in it["labels"]]
        return sorted(items, key=lambda it: it["createdAt"])

    def issue(self, number: int) -> dict:
        it = self._json(["issue", "view", str(number), "--json", "number,title,body,labels,url,state"])
        it["labels"] = [l["name"] for l in it["labels"]]
        return it

    def relabel(self, number: int, add: list[str], remove: list[str]) -> str | None:
        args = [self.resource, "edit", str(number), "-R", self.repo]
        for l in add:
            args += ["--add-label", l]
        for l in remove:
            args += ["--remove-label", l]
        r = sh(["gh", *args])
        if r.ok:
            return None
        msg = f"relabel #{number}: {(r.err or r.out).strip()[-300:]}"
        self.errors.append(msg)
        return msg

    def comment(self, number: int, body: str, *, pull_request: bool = False) -> None:
        resource = "pr" if pull_request else self.resource
        r = sh(["gh", resource, "comment", str(number), "-R", self.repo, "--body-file", "-"], stdin=body)
        if not r.ok:
            self.errors.append(f"comment #{number}: {(r.err or r.out).strip()[-300:]}")

    def open_pr(self, branch: str) -> dict | None:
        items = self._json(["pr", "list", "--state", "open", "--head", branch,
                            "--json", "number,url,headRefOid"])
        return items[0] if items else None

    def create_pr(self, branch: str, base: str, title: str, body: str) -> dict:
        must(["gh", "pr", "create", "-R", self.repo, "--head", branch, "--base", base,
              "--title", title, "--body-file", "-"], stdin=body)
        pr = self.open_pr(branch)
        if not pr:
            raise RuntimeError("the PR was created but cannot be found")
        return pr

    def edit_pr_body(self, number: int, body: str) -> None:
        r = sh(["gh", "pr", "edit", str(number), "-R", self.repo, "--body-file", "-"], stdin=body)
        if not r.ok:
            self.errors.append(f"edit PR #{number}: {(r.err or r.out).strip()[-300:]}")

    def merge_pr(self, number: int, sha: str) -> str:
        must(["gh", "pr", "merge", str(number), "--repo", self.repo, "--merge", "--match-head-commit", sha])
        pr = self._json(["pr", "view", str(number), "--json", "state,headRefOid,mergeCommit"])
        if not isinstance(pr, dict):
            raise RuntimeError(f"GitHub did not return the PR after the merge of {sha}")
        commit = (pr.get("mergeCommit") or {}).get("oid")
        if pr.get("state") != "MERGED" or pr.get("headRefOid") != sha or not commit:
            raise RuntimeError(f"GitHub did not confirm a merge of {sha}")
        return commit

    def _ci_runs(self, endpoint: str, collection: str) -> list[CIRun] | None:
        query = f'.{collection}[] | {{id, name, status, conclusion, url: .html_url}} | @json'
        r = sh(["gh", "api", endpoint, "--paginate", "--jq", query])
        if not r.ok:
            self.errors.append(f"read CI at {endpoint}: {(r.err or r.out).strip()[-300:]}")
            return None
        try:
            return [CIRun(**json.loads(line)) for line in r.out.splitlines()]
        except (ValueError, TypeError) as e:
            self.errors.append(f"read CI at {endpoint}: {e}")
            return None

    def ci_facts(self, sha: str, *, all_check_runs: bool = False) -> CIFacts:
        workflows = self._ci_runs(f"repos/{self.repo}/actions/runs?head_sha={sha}", "workflow_runs")
        if not workflows or any(run.status != "completed" for run in workflows):
            return CIFacts(sha, workflows, [])
        suffix = "?filter=all" if all_check_runs else ""
        checks = self._ci_runs(f"repos/{self.repo}/commits/{sha}/check-runs{suffix}", "check_runs")
        return CIFacts(sha, workflows, checks)

    def ci_state(self, sha: str) -> str:
        return self.ci_facts(sha).state()

"""GitHub calls through the `gh` CLI. CI query and write failures are recorded."""

from __future__ import annotations

import json

from common import must, sh


def combine_ci(workflows: list[str] | None, checks: list[str] | None) -> str:
    if workflows is None or checks is None:
        return "error"
    if not workflows or any(s != "completed" for s in workflows) or not checks:
        return "pending"
    rows = [line.partition("\t") for line in checks]
    if any(status != "completed" for status, _, _ in rows):
        return "pending"
    good = {"success", "neutral", "skipped"}
    return "success" if all(c in good for _, _, c in rows) else "failure"


class GitHub:
    def __init__(self, repo: str) -> None:
        self.repo = repo
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
        args = ["issue", "edit", str(number), "-R", self.repo]
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

    def comment(self, number: int, body: str) -> None:
        r = sh(["gh", "issue", "comment", str(number), "-R", self.repo, "--body-file", "-"], stdin=body)
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

    def _ci_rows(self, endpoint: str, query: str) -> list[str] | None:
        r = sh(["gh", "api", endpoint, "--paginate", "--jq", query])
        if r.ok:
            return r.out.splitlines()
        self.errors.append(f"read CI at {endpoint}: {(r.err or r.out).strip()[-300:]}")
        return None

    def ci_state(self, sha: str) -> str:
        statuses = self._ci_rows(f"repos/{self.repo}/actions/runs?head_sha={sha}", ".workflow_runs[].status")
        if not statuses or any(s != "completed" for s in statuses):
            return combine_ci(statuses, [])
        checks = self._ci_rows(f"repos/{self.repo}/commits/{sha}/check-runs",
                               '.check_runs[] | [.status, (.conclusion // "")] | @tsv')
        return combine_ci(statuses, checks)

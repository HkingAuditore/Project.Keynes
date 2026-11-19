"""GitHub calls through the `gh` CLI. Failures to write are collected, not swallowed."""

from __future__ import annotations

import json

from common import must, sh


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

    def ci_state(self, sha: str) -> str | None:
        """Combined state of check runs on a commit: success, failure, pending, or None (no checks)."""
        r = sh(["gh", "api", f"repos/{self.repo}/commits/{sha}/check-runs", "--paginate",
                "--jq", ".check_runs[] | [.status, (.conclusion // \"\")] | @tsv"])
        if not r.ok:
            return None
        rows = [line.split("\t") for line in r.out.splitlines() if line.strip()]
        if not rows:
            return None
        if any(status != "completed" for status, _ in rows):
            return "pending"
        good = {"success", "neutral", "skipped"}
        return "success" if all(c in good for _, c in rows) else "failure"

"""GitHub calls through the `gh` CLI. CI query and write failures are recorded."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Literal
from urllib.parse import quote

from common import must, sh
from verdict import CIFacts, CIRun

PR_MERGE_FIELDS = "headRefOid,baseRefName,baseRefOid,changedFiles,state,isDraft,isCrossRepository,labels,mergeable"


@dataclass(frozen=True)
class ChangedFile:
    filename: str
    status: str
    previous_filename: str | None = None


@dataclass(frozen=True)
class MergeResult:
    outcome: Literal["merged", "not_merged"]
    commit: str | None = None
    reason: str = ""


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
        endpoint = f"repos/{self.repo}/issues/{number}/labels"
        if add:
            r = sh(["gh", "api", endpoint, "--method", "POST", "--input", "-"],
                   stdin=json.dumps({"labels": add}))
            if not r.ok:
                return self._label_error(number, r.err or r.out)
        error = None
        for label in remove:
            r = sh(["gh", "api", f"{endpoint}/{quote(label, safe='')}", "--method", "DELETE", "--include", "--silent"])
            status = r.out.split(maxsplit=2)[:2]
            not_found = len(status) == 2 and status[0].startswith("HTTP/") and status[1] == "404"
            if not r.ok and not not_found:
                error = self._label_error(number, r.err or r.out)
        return error

    def _label_error(self, number: int, details: str) -> str:
        msg = f"relabel #{number}: {details.strip()[-300:]}"
        self.errors.append(msg)
        return msg

    def comment(self, number: int, body: str, *, pull_request: bool = False) -> None:
        resource = "pr" if pull_request else "issue"
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

    def pr_merge_state(self, number: int) -> dict:
        pr = self._json(["pr", "view", str(number), "--json", PR_MERGE_FIELDS])
        if not isinstance(pr, dict) or any(field not in pr for field in PR_MERGE_FIELDS.split(",")):
            raise ValueError("GitHub returned incomplete PR metadata")
        try:
            pr["labels"] = [label["name"] for label in pr["labels"]]
        except (KeyError, TypeError) as e:
            raise ValueError("GitHub returned invalid PR labels") from e
        if any(not isinstance(name, str) for name in pr["labels"]):
            raise ValueError("GitHub returned invalid PR labels")
        return pr

    def pr_files(self, number: int, changed_count: int) -> list[ChangedFile]:
        endpoint = f"repos/{self.repo}/pulls/{number}/files?per_page=100"
        rows = must(["gh", "api", endpoint, "--paginate", "--jq", ".[] | {filename, status, previous_filename} | @json"])
        try:
            files = [ChangedFile(**json.loads(line)) for line in rows.splitlines()]
        except (ValueError, TypeError) as e:
            raise ValueError(f"GitHub returned invalid changed files: {e}") from e
        if any(not isinstance(f.filename, str) or not f.filename or not isinstance(f.status, str) or not f.status
               or (f.previous_filename is not None and not isinstance(f.previous_filename, str))
               or (f.status == "renamed" and not f.previous_filename) for f in files):
            raise ValueError("GitHub returned invalid changed file paths or statuses")
        if len(files) != changed_count or len({f.filename for f in files}) != changed_count:
            raise ValueError(f"GitHub returned an incomplete changed-files list (expected {changed_count})")
        return files

    def merge_pr(self, number: int, sha: str) -> MergeResult:
        must(["gh", "pr", "merge", str(number), "--repo", self.repo, "--merge", "--match-head-commit", sha])
        try:
            pr = self._json(["pr", "view", str(number), "--json", "state,headRefOid,mergeCommit"])
            state = pr.get("state") if isinstance(pr, dict) else None
            if not isinstance(state, str) or not state:
                raise ValueError("GitHub did not return the PR state")
            head = pr.get("headRefOid")
            if state != "MERGED" or head != sha:
                return MergeResult("not_merged", reason=(
                    f"GitHub reported PR state `{state}` at head `{head or 'unknown'}` after the merge command. "
                    f"The factory expected `MERGED` at `{sha}`."))
            merge_commit = pr.get("mergeCommit")
            oid = merge_commit.get("oid") if isinstance(merge_commit, dict) else None
            if not isinstance(oid, str) or not oid:
                raise ValueError("GitHub did not return the merge commit")
            return MergeResult("merged", oid)
        except (RuntimeError, ValueError) as e:
            self.errors.append(f"read PR #{number} after merge: {e}")
            return MergeResult("merged")

    def _ci_runs(self, endpoint: str, collection: str, *, latest_workflows: bool = False) -> list[CIRun] | None:
        fields = "id, name, status, conclusion, url: .html_url"
        if latest_workflows:
            fields += ", workflow_id, run_number, run_attempt"
        query = f".{collection}[] | {{{fields}}} | @json"
        r = sh(["gh", "api", endpoint, "--paginate", "--jq", query])
        if not r.ok:
            self.errors.append(f"read CI at {endpoint}: {(r.err or r.out).strip()[-300:]}")
            return None
        try:
            rows = [json.loads(line) for line in r.out.splitlines()]
            if latest_workflows:
                latest: dict[int, tuple[tuple[int, int], dict]] = {}
                for row in rows:
                    workflow_id = row.pop("workflow_id")
                    version = (row.pop("run_number"), row.pop("run_attempt") or 1)
                    if not all(isinstance(value, int) for value in (workflow_id, *version)):
                        raise ValueError("GitHub returned invalid workflow run metadata")
                    if workflow_id not in latest or version > latest[workflow_id][0]:
                        latest[workflow_id] = (version, row)
                rows = [row for _, row in latest.values()]
            return [CIRun(**row) for row in rows]
        except (AttributeError, KeyError, ValueError, TypeError) as e:
            self.errors.append(f"read CI at {endpoint}: {e}")
            return None

    def ci_facts(self, sha: str, *, latest_workflows: bool = False) -> CIFacts:
        workflows = self._ci_runs(f"repos/{self.repo}/actions/runs?head_sha={sha}", "workflow_runs",
                                  latest_workflows=latest_workflows)
        if not workflows or any(run.status != "completed" for run in workflows):
            return CIFacts(sha, workflows, [])
        suffix = "?filter=latest" if latest_workflows else ""
        checks = self._ci_runs(f"repos/{self.repo}/commits/{sha}/check-runs{suffix}", "check_runs")
        return CIFacts(sha, workflows, checks)

    def ci_state(self, sha: str) -> str:
        return self.ci_facts(sha).state()

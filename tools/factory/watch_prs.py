"""Keynes factory, PR mode: update conflicting branches, fix findings, or merge reviewed PRs.

One tick: list open PRs into the base branch and decide whether they need a conflict update,
review fix, or GitHub merge. An update or fix checks out the PR head, records existing failures,
applies the change, and checks it before pushing. Qodo then reviews the new commit.

Usage: python3 tools/factory/watch_prs.py [--pr N] [--dry]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from dataclasses import asdict, dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent  # noqa: E402
import checks  # noqa: E402
import qodo  # noqa: E402
import work  # noqa: E402
from common import Events, lane_lock, legacy_lane_gate, load_config, must  # noqa: E402
from github import PR_MERGE_FIELDS, ChangedFile, GitHub  # noqa: E402
from verdict import CIFacts, NativeFacts, unknown_findings  # noqa: E402

TRAILER = "Fixed-By: keynes-factory"


@dataclass
class PrState:
    """What the factory remembers about one PR, in ~/.keynes-factory/prs/<n>.json."""
    pushed: list[str] = field(default_factory=list)     # commits the factory pushed
    rounds: int = 0                                     # fix and update rounds since a person last pushed
    seen: list[list[str]] = field(default_factory=list)  # finding-id sets already sent to Codex
    disputed: list[str] = field(default_factory=list)   # finding ids Codex disputed (a person decides)
    gave_up_at: str | None = None                       # head commit where the factory stopped
    reason: str | None = None
    attempted: list[str] = field(default_factory=list)  # heads sent to Codex that a person pushed
    update_attempted: list[str] = field(default_factory=list)
    last_update: str | None = None
    last_conflicts: list[str] = field(default_factory=list)


@dataclass
class Decision:
    action: str            # "skip", "fix", "update", "merge" or "stop"
    reason: str
    findings: list[dict] = field(default_factory=list)
    needs_files: bool = False
    needs_ci: bool = False


# update_preflight refusals that say nothing about the merge itself, so the same head is tried again.
RETRY_UPDATE = {"the PR base changed before push", "the PR base could not be read before push"}


def automation_skip_labels(cfg: dict) -> set[str]:
    labels = cfg["labels"]
    return {*cfg["skipLabels"], labels["help"], labels["working"]}


def merge_blocker(pr: dict, cfg: dict) -> str | None:
    blocked = automation_skip_labels(cfg) | {"no-auto-merge"}
    if blocked.intersection(pr.get("labels") or []):
        return "has a label that blocks auto-merge"
    if pr.get("mergeable") in (None, "UNKNOWN"):
        return "waiting for GitHub to determine mergeability"
    if pr["mergeable"] != "MERGEABLE":
        return "GitHub reports merge conflicts"
    return None


def merge_path_blocker(files: list[ChangedFile], cfg: dict) -> str | None:
    paths = [path for f in files for path in (f.filename, f.previous_filename) if path is not None]
    forbidden, human, _ = work.scope(cfg, paths)
    protected = sorted(set(forbidden + human))
    if protected:
        return f"a person merges this PR because it touches protected paths ({', '.join(protected)})"
    return None


def skip_before_review(pr: dict, state: PrState, cfg: dict) -> Decision | None:
    """Skips that need no Qodo read, so tick() does not spend a review lookup on them."""
    head = pr["headRefOid"]
    if pr.get("isDraft"):
        return Decision("skip", "draft")
    if pr.get("isCrossRepository"):
        return Decision("skip", "the branch is in another repository; the factory cannot push to it")
    labels = set(pr.get("labels") or [])
    if labels.intersection(cfg["skipLabels"]):
        return Decision("skip", "has a skip label")
    if (pr.get("headRefName") or "").startswith(cfg["issueBranchPrefix"]) and cfg["labels"]["handoff"] not in labels:
        return Decision("skip", "the issue runner has not handed this PR over")
    if state.gave_up_at == head:
        return Decision("skip", f"stopped at this head ({state.reason}); waiting for a person")
    return None


def decide(pr: dict, review: dict | None, state: PrState, cfg: dict, *,
           changed_files: list[ChangedFile] | None = None, ci: CIFacts | None = None) -> Decision:
    """Pure decision for one PR from GitHub metadata, the Qodo review read and the saved state."""
    head = pr["headRefOid"]
    early = skip_before_review(pr, state, cfg)
    if early is not None:
        return early
    labels = set(pr.get("labels") or [])
    if pr.get("mergeable") == "UNKNOWN":
        return Decision("skip", "waiting for GitHub to determine mergeability")
    if pr.get("mergeable") == "CONFLICTING":
        if not cfg.get("autoUpdateConflicts", True):
            return Decision("skip", "GitHub reports merge conflicts")
        if labels.intersection(automation_skip_labels(cfg)):
            return Decision("skip", "has a label that blocks conflict updates")
        if head in state.update_attempted:
            return Decision("skip", "the factory already tried to update this head")
        limit = cfg["limits"]["prReviewRounds"]
        if head in state.pushed and state.rounds >= limit:
            return Decision("stop", f"{limit} factory rounds used and the branch still conflicts")
        return Decision("update", "GitHub reports merge conflicts")
    if review is None:
        return Decision("skip", "Qodo review could not be read")
    session = review.get("review_session") or {}
    if not session:
        return Decision("skip", "no Qodo review yet")
    if session.get("commit_sha") != head:
        return Decision("skip", "waiting for Qodo to review the head commit")
    status = session.get("status")
    if status == "started":
        return Decision("skip", "Qodo review in progress")
    if status != "completed":
        return Decision("stop", f"Qodo review ended with status {status!r}")
    findings = review.get("findings")
    auto_merge = cfg["autoMerge"]
    if auto_merge and (not isinstance(findings, list) or any(not isinstance(f, dict) for f in findings)):
        return Decision("stop", "Qodo findings could not be read")
    findings = findings or []
    unknown = unknown_findings(findings)
    if unknown:
        return Decision("stop", "findings with an unknown status or action_level: " + ", ".join(unknown))
    open_blocking = qodo.blocking(findings)
    if not open_blocking:
        if auto_merge:
            blocker = merge_blocker(pr, cfg)
            if blocker:
                return Decision("skip", blocker)
            unknown = unknown_findings(findings, require_level=True)
            if unknown:
                return Decision("stop", "findings with an unknown status or action_level: " + ", ".join(unknown))
            if changed_files is None:
                return Decision("skip", "waiting for the PR's changed files", needs_files=True)
            blocker = merge_path_blocker(changed_files, cfg)
            if blocker:
                return Decision("skip", blocker)
            if ci is None or ci.sha != head:
                return Decision("skip", "waiting for CI facts on the head", needs_ci=True)
            ci_state = ci.state(strict=True)
            if ci_state == "error":
                return Decision("stop", "the CI state could not be read")
            if ci_state != "success":
                return Decision("skip", f"CI on the head is {ci_state}")
            info = [f for f in findings if f.get("action_level") == "informational"]
            return Decision("merge", "clean Qodo review and successful CI on the head", info)
        if state.disputed:
            return Decision("skip", "only findings the agent disputed are open; a person decides")
        return Decision("skip", "no open blocking findings at the head")
    block = [f for f in open_blocking if str(f.get("id")) not in state.disputed]
    if not block:
        return Decision("skip", "only findings the agent disputed are open; a person decides")
    # Only gates another fix: a head whose findings the agent settled (dismissed disputes) may still merge.
    if head not in state.pushed and head in state.attempted:
        return Decision("skip", "Codex already ran at this head; waiting for a person")
    ids = sorted(str(f.get("id")) for f in block)
    round_limit = cfg["limits"]["prReviewRounds"]
    rounds = state.rounds if head in state.pushed else 0
    seen = state.seen if head in state.pushed else []
    if ids in seen:
        return Decision("stop", "the same findings are open again after a fix")
    if rounds >= round_limit:
        return Decision("stop", f"{round_limit} fix rounds used without a clean review")
    return Decision("fix", f"{len(block)} blocking finding(s) at {head[:10]}", block)


class Watcher:
    def __init__(self, cfg: dict, dry: bool) -> None:
        self.cfg, self.dry = cfg, dry
        self.gh = GitHub(cfg["repo"])
        self.home = Path(cfg["home"])
        self.workdir = str(self.home / "pr-work")
        self.base_cache = str(self.home / "pr-base-checks")
        self.stamp = time.strftime("%Y%m%d-%H%M%S")

    # ---- state -----------------------------------------------------------------------
    def state_path(self, n: int) -> Path:
        return self.home / "prs" / f"{n}.json"

    def load(self, n: int) -> PrState:
        p = self.state_path(n)
        if not p.exists():
            return PrState()
        data = json.loads(p.read_text(encoding="utf-8"))
        data.pop("merge_requested_at", None)  # Ignore the retired field in older state files.
        return PrState(**data)

    def save(self, n: int, st: PrState) -> None:
        p = self.state_path(n)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(st.__dict__, indent=2), encoding="utf-8")

    # ---- one tick --------------------------------------------------------------------
    def prs(self, only: int | None) -> list[dict]:
        items = json.loads(must(["gh", "pr", "list", "-R", self.cfg["repo"], "--state", "open",
                                 "--base", self.cfg["base"], "--limit", "50", "--json",
                                 f"number,title,url,headRefName,createdAt,{PR_MERGE_FIELDS}"]))
        for it in items:
            it["labels"] = [l["name"] for l in it["labels"]]
        items.sort(key=lambda it: it["createdAt"])
        return [it for it in items if only is None or it["number"] == only]

    def tick(self, only: int | None) -> int:
        for pr in self.prs(only):
            st = self.load(pr["number"])
            review = None
            early = skip_before_review(pr, st, self.cfg)
            if early is not None:
                print(json.dumps({"pr": pr["number"], "action": "skip", "reason": early.reason}), flush=True)
                continue
            if pr.get("mergeable") not in ("CONFLICTING", "UNKNOWN"):
                review = qodo.pr_review(self.cfg["tools"]["qodo"], pr["url"])
            args = (pr, review, st, self.cfg)
            d = decide(*args)
            changed_files = None
            if d.needs_files:
                try:
                    changed_files = self.gh.pr_files(pr["number"], pr["changedFiles"])
                except (KeyError, RuntimeError, ValueError) as e:
                    d = Decision("skip", f"the PR's changed files could not be read: {e}")
                else:
                    d = decide(*args, changed_files=changed_files)
            ci = None
            if d.needs_ci:
                ci = self.gh.ci_facts(pr["headRefOid"], latest_workflows=True)
                d = decide(*args, changed_files=changed_files, ci=ci)
            print(json.dumps({"pr": pr["number"], "action": d.action, "reason": d.reason}), flush=True)
            if self.dry or d.action == "skip":
                continue
            if ci is not None and d.action in ("merge", "stop"):
                paths = [path for f in changed_files or [] for path in (f.filename, f.previous_filename)
                         if path is not None]
                native = work.scope(self.cfg, paths)[2]
                result = self.apply_merge_decision(pr, st, d, review["review_session"], ci, native=bool(native))
                if result is not None:
                    return result
                continue
            if d.action == "stop":
                self.stop(pr, st, d.reason)
                continue
            if d.action == "update":
                return self.update(pr, st)
            return self.fix(pr, st, d.findings)  # one fix per tick: it takes minutes
        return 0

    def stop(self, pr: dict, st: PrState, reason: str, details: str = "", *, resume_on_label_removal: bool = False) -> None:
        n, head = pr["number"], pr["headRefOid"]
        L = self.cfg["labels"]
        # Only adding the help label determines whether removing it can resume the merge.
        label_error = self.gh.relabel(n, [L["help"]], []) if resume_on_label_removal else None
        if resume_on_label_removal and label_error is None:
            next_step = (f"The factory will not retry the merge while `{L['help']}` is set. "
                         f"Remove `{L['help']}` to let it try again.")
        else:
            st.gave_up_at, st.reason = head, reason
            self.save(n, st)
            next_step = "The factory will look again after the next push to this branch."
            if label_error is not None:
                next_step = f"The factory could not add `{L['help']}` ({label_error}).\n\n{next_step}"
        self.gh.comment(n, f"### Factory stopped on {head[:10]}\n\n{reason}\n\n{details}".strip()
                        + f"\n\n{next_step}", pull_request=True)
        if not resume_on_label_removal:
            self.gh.relabel(n, [L["help"]], [L["working"]])
        elif label_error is None:
            self.gh.relabel(n, [], [L["working"]])

    def merge_preflight(self, pr: dict) -> str | None:
        try:
            fresh = self.gh.pr_merge_state(pr["number"])
        except (RuntimeError, ValueError) as e:
            self.gh.errors.append(f"read PR #{pr['number']} before merge: {e}")
            return "the PR could not be re-read before merge"
        if fresh["headRefOid"] != pr["headRefOid"]:
            return "the PR head changed before merge"
        if fresh["baseRefName"] != pr["baseRefName"] or fresh["baseRefOid"] != pr["baseRefOid"]:
            return "the PR base changed before merge"
        if fresh["state"] != "OPEN" or fresh["isDraft"] or fresh["isCrossRepository"]:
            return "the PR is no longer open and eligible for auto-merge"
        blocker = merge_blocker(fresh, self.cfg)
        if blocker:
            return blocker
        if set(fresh["labels"]) != set(pr["labels"]):
            return "the PR labels changed before merge"
        if fresh["changedFiles"] != pr["changedFiles"]:
            return "the PR changed-file count changed before merge"
        return None

    def apply_merge_decision(self, pr: dict, st: PrState, decision: Decision, session: dict, ci: CIFacts,
                             *, native: bool) -> int | None:
        """Record this merge decision. A preflight skip lets the tick continue to the next PR."""
        n, sha = pr["number"], pr["headRefOid"]
        record = {"pr": n, "url": pr["url"], "head": sha, "started": self.stamp,
                  "reviewedSha": session["commit_sha"], "reviewStatus": session["status"],
                  "mergeable": pr["mergeable"], "ci": asdict(ci), "informationalFindings": decision.findings}
        error = skipped = None
        if decision.action == "stop":
            error = decision.reason
            self.stop(pr, st, error, "\n".join(self.gh.errors))
        else:
            skipped = self.merge_preflight(pr)
            if skipped is None and native:
                try:
                    if not self.prepare_head(pr, Events()):
                        skipped = "the PR head changed before the native checks"
                    else:
                        logdir = self.home / "logs" / f"merge-pr-{n}-{self.stamp}"
                        results = record["nativeChecks"] = []
                        checks.Runner(self.cfg, self.workdir, str(logdir)).run_native(results)
                        failures = checks.failed(results)
                        if failures:
                            error = "the PR has failing native checks: " + ", ".join(failures)
                            self.stop(pr, st, error, checks.feedback(results, failures))
                        else:
                            skipped = self.merge_preflight(pr)
                except (RuntimeError, OSError) as e:
                    error = f"the native checks could not run: {e}"
                    self.stop(pr, st, error)
            if skipped is None and error is None:
                try:
                    result = self.gh.merge_pr(n, sha)
                    record.update(outcome=result.outcome, mergeCommit=result.commit)
                except RuntimeError as e:
                    error = f"the merge failed: {e}"
                    self.stop(pr, st, error)
        if error:
            record.update(outcome="stopped", error=error)
        elif skipped:
            record.update(outcome="skipped", reason=skipped)
            print(json.dumps({"pr": n, "action": "skip", "reason": skipped}), flush=True)
        elif record["outcome"] == "not_merged":
            record["error"] = result.reason
            self.stop(pr, st, result.reason, resume_on_label_removal=True)
        else:
            lines = [f"### Factory merged PR #{n}", "",
                     f"Qodo completed its review of `{sha}` with no open blocking findings.", ""]
            for title, runs in (("GitHub Actions workflows", ci.workflows), ("Check runs", ci.checks)):
                lines += [title, ""]
                if not runs:
                    lines.append("GitHub reported zero runs.")
                for run in runs or []:
                    name = run.name or str(run.id)
                    source = f" ([run #{run.id}]({run.url}))" if run.url else f" (run #{run.id})"
                    lines.append(f"- {name} — {run.conclusion}{source}")
                lines.append("")
            if decision.findings:
                lines += ["Informational findings", ""] + [
                    f"- `{f.get('id')}` {f.get('title') or '(untitled)'}" for f in decision.findings]
            self.gh.comment(n, "\n".join(lines).rstrip(), pull_request=True)
        record.update(finished=time.strftime("%Y%m%d-%H%M%S"), githubErrors=self.gh.errors)
        runs = self.home / "runs"
        runs.mkdir(parents=True, exist_ok=True)
        (runs / f"merge-pr-{n}-{self.stamp}.json").write_text(json.dumps(record, indent=2, ensure_ascii=False),
                                                            encoding="utf-8")
        if skipped:
            return None
        return 1 if error or record["outcome"] == "not_merged" else 0

    # ---- the fix ---------------------------------------------------------------------
    def stop_with_patch(self, pr: dict, st: PrState, logs: Path, reason: str, details: str = "") -> None:
        patches = work.save_patch(self.workdir, pr["headRefOid"], logs / "fix.patch")
        self.stop(pr, st, reason, "\n\n".join(filter(None, [work.patch_notice(patches), details])))

    def scope_blocked(self, pr: dict, st: PrState, logs: Path, files: list[str],
                      candidate: checks.Candidate, *, before_commit: bool = False) -> bool:
        reason = self.scope_problem(files, candidate, before_commit=before_commit)
        if not reason:
            return False
        self.stop_with_patch(pr, st, logs, f"{reason}. Nothing was pushed.", candidate.facts.report())
        return True

    def scope_problem(self, files: list[str], candidate: checks.Candidate, *, before_commit: bool) -> str | None:
        bad, human, native = candidate.scope(files)
        protected = sorted(set(bad + human))
        if protected:
            return f"the change touches files a person must handle ({', '.join(protected)})"
        return candidate.commit_problem(native) if before_commit else None

    def fix(self, pr: dict, st: PrState, findings: list[dict]) -> int:
        return self.run_change(pr, st, "fix", findings)

    def update(self, pr: dict, st: PrState) -> int:
        return self.run_change(pr, st, "update", [])

    def run_change(self, pr: dict, st: PrState, action: str, findings: list[dict]) -> int:
        cfg, n, head = self.cfg, pr["number"], pr["headRefOid"]
        L = cfg["labels"]
        logs = self.home / "logs" / f"pr-{n}-{self.stamp}"
        logs.mkdir(parents=True, exist_ok=True)
        ev = Events()
        record: dict = {"pr": n, "url": pr["url"], "head": head, "started": self.stamp, "action": action,
                        "findings": [f.get("id") for f in findings]}
        facts = NativeFacts()
        outcome = "error"
        try:
            self.gh.relabel(n, [L["working"]], [] if action == "update" else [L["help"]])
            if action == "update":
                outcome = self._update(pr, st, logs, ev, record, facts)
            else:
                outcome = self._fix(pr, st, findings, logs, ev, record, facts)
        except Exception as e:
            record["error"] = str(e)
            ev.add("error", trace=traceback.format_exc()[-3000:])
            self.stop(pr, st, f"the {action} run failed: {e}", facts.report())
        finally:
            self.gh.relabel(n, [], [L["working"]])
            record.update({"outcome": outcome, "events": ev.items, "githubErrors": self.gh.errors, "facts": asdict(facts),
                           "finished": time.strftime("%Y%m%d-%H%M%S")})
            runs = self.home / "runs"
            runs.mkdir(parents=True, exist_ok=True)
            (runs / f"pr-{n}-{self.stamp}.json").write_text(json.dumps(record, indent=2, ensure_ascii=False),
                                                           encoding="utf-8")
        return 1 if self.gh.errors else 0

    def prepare_head(self, pr: dict, ev: Events) -> bool:
        cfg, n = self.cfg, pr["number"]
        runner_dir = str(Path(__file__).resolve().parents[2])
        work.ensure(runner_dir, self.workdir, f"{cfg['remote']}/{cfg['base']}")
        got = work.prepare(self.workdir, cfg["remote"], pr["headRefName"], f"factory-pr-{n}")
        if got != pr["headRefOid"]:
            ev.add("moved", expected=pr["headRefOid"], got=got)
            return False
        return True

    def update_head_moved(self, pr: dict, ev: Events) -> bool:
        got = work.remote_head(self.workdir, self.cfg["remote"], pr["headRefName"])
        expected = pr["headRefOid"]
        if got == expected:
            return False
        ev.add("moved", expected=expected, got=got)
        return True

    def base_moved(self, base: str, checked: str, now: str, ev: Events) -> bool:
        """The base moved since the checks ran. Moves that touch only the factory's own files cannot
        change what the checks saw, so they do not count."""
        try:
            work.git(self.workdir, "fetch", "-q", self.cfg["remote"], base)
            files = work.git(self.workdir, "diff", "--name-only", checked, now).split("\n")
        except RuntimeError as e:
            ev.add("base-diff-failed", error=str(e))
            return True
        files = [f for f in files if f]
        ours = tuple(self.cfg["paths"].get("factoryOnly", ["tools/factory/", "docs/factory/"]))
        moved = [f for f in files if not f.startswith(ours)]
        ev.add("base-moved", checked=checked, now=now, files=len(files), other=moved[:20])
        return bool(moved)

    def update_preflight(self, pr: dict, base: str, parent: str, ev: Events) -> str | None:
        try:
            fresh = self.gh.pr_merge_state(pr["number"])
        except (RuntimeError, ValueError) as e:
            self.gh.errors.append(f"read PR #{pr['number']} before update push: {e}")
            return "the PR could not be re-read before push"
        if fresh["headRefOid"] != pr["headRefOid"]:
            ev.add("moved", expected=pr["headRefOid"], got=fresh["headRefOid"])
            return "head moved"
        if fresh["baseRefName"] != base:
            return "the PR base changed before push"
        # GitHub's baseRefOid is refreshed only when the PR head is pushed, so it can name a commit far
        # behind the branch. A stale value would refuse every push, and with no push it never refreshes.
        # Read the branch itself.
        try:
            now = work.remote_head(self.workdir, self.cfg["remote"], base)
        except RuntimeError as e:
            ev.add("base-read-failed", error=str(e))
            now = None
        if now is None:
            return "the PR base could not be read before push"
        if now != parent and self.base_moved(base, parent, now, ev):
            return "the PR base changed before push"
        if fresh["state"] != "OPEN" or fresh["isDraft"] or fresh["isCrossRepository"]:
            return "the PR is no longer open and eligible for conflict updates"
        expected = set(pr.get("labels") or []) | {self.cfg["labels"]["working"]}
        if set(fresh["labels"]) != expected:
            return "the PR labels changed before push"
        return None

    def _update(self, pr: dict, st: PrState, logs: Path, ev: Events, record: dict, facts: NativeFacts) -> str:
        cfg, n, head = self.cfg, pr["number"], pr["headRefOid"]
        if not self.prepare_head(pr, ev):
            return "head moved"
        if head not in st.pushed:
            st.rounds, st.seen = 0, []
        st.update_attempted.append(head)
        self.save(n, st)
        base = pr.get("baseRefName", cfg["base"])
        parent = work.git(self.workdir, "rev-parse", f"{cfg['remote']}/{base}")
        record.update(base=base, baseSha=parent)
        head_res = checks.base_results(cfg, self.workdir, head, self.base_cache, str(logs / "checks-head"))
        try:
            work.checkout(self.workdir, parent)
            base_res = checks.base_results(cfg, self.workdir, parent, self.base_cache, str(logs / "checks-base"))
        finally:
            work.checkout(self.workdir, head, branch=f"factory-pr-{n}")
        parent_failures = {"head": checks.failed(head_res), "base": checks.failed(base_res)}
        before = sorted(set(parent_failures["head"]) | set(parent_failures["base"]))
        passed_on_both = {row["name"] for row in head_res if row["ok"]} & {
            row["name"] for row in base_res if row["ok"]
        }
        ev.add("checks-before", failed=before, failedByParent=parent_failures)
        record["checks"] = {"before": before, "beforeByParent": parent_failures}
        if self.update_head_moved(pr, ev):
            return "head moved"

        synced_submodule = False

        def abort() -> None:
            pending = work.merge_head(self.workdir)
            if pending is None:
                return
            try:
                work.git(self.workdir, "merge", "--abort")
            except RuntimeError as e:
                # The factory started with a clean checkout. Abort can refuse unstaged agent edits.
                if pending != parent or work.head(self.workdir) != head:
                    raise
                ev.add("merge-abort-reset", error=str(e))
                work.git(self.workdir, "reset", "--hard", "-q", head)
            if synced_submodule:
                work.update_godot_cpp(self.workdir)

        def stop(reason: str, details: str = "") -> str:
            record["reason"] = reason
            abort()
            self.stop(pr, st, f"{reason}. Nothing was pushed.",
                      "\n\n".join(filter(None, [details, facts.report()])))
            return "stopped"

        try:
            if work.merge_from(self.workdir, parent) is None:
                ev.add("up-to-date", base=base)
                return "already up to date"

            conflicts = work.unmerged(self.workdir)
            paths = sorted(conflicts)
            record["conflicts"] = paths
            if paths and st.last_update == head and paths == st.last_conflicts:
                return stop("the same conflicts reappeared after the factory update: " + ", ".join(paths))
            bad, human, _ = work.scope(cfg, paths)
            gitlinks = [path for path, stages in conflicts.items() if "160000" in stages.values()]
            protected = sorted(set(bad + human + gitlinks))
            if protected:
                return stop("conflicts in paths a person must handle: " + ", ".join(protected))

            binary = work.binary_conflicts(self.workdir, head, parent, paths)
            if binary:
                return stop("binary conflicts a person must handle: " + ", ".join(binary))
            resolutions = []

            if work.git(self.workdir, "diff", "--cached", "--name-only", head, "--", work.GODOT_CPP):
                synced_submodule = True
                work.update_godot_cpp(self.workdir)
            candidate = checks.Candidate(cfg, self.workdir, facts, merge_parent=parent)
            if paths:
                clean_entries = work.stage_zero_entries(self.workdir)
                prompt = agent.render("resolve-conflicts", files="\n".join(f"- `{path}`" for path in paths))
                out = agent.codex(cfg, self.workdir, prompt, str(logs / "resolve-conflicts.md"), writable=True)
                record["report"] = out["report"]
                ev.add("agent", ok=out["ok"], code=out.get("code"))
                if self.update_head_moved(pr, ev):
                    return "head moved"
                if not out["ok"]:
                    record["agentFailure"] = agent.failure_reason(out)
                unrelated = work.changes_outside_conflicts(self.workdir, clean_entries, paths)
                if unrelated:
                    record["unrelatedFiles"] = unrelated
                    return stop("Codex changed paths outside the conflicts: " + ", ".join(unrelated),
                                record.get("agentFailure", ""))
                if not out["ok"]:
                    return stop(record["agentFailure"], record["report"])
                if work.head(self.workdir) != head or work.merge_head(self.workdir) != parent:
                    return stop("the working checkout no longer has the expected pending merge")
                if work.unmerged(self.workdir) != conflicts:
                    return stop("Codex changed the conflict entries in the index")
                try:
                    choices = agent.parse_conflict_resolutions(out["report"], paths)
                    work.validate_conflict_files(self.workdir, choices)
                except ValueError as e:
                    return stop(str(e), out["report"])
                work.git(self.workdir, "add", "-A", "--", *[f":(top,literal){path}" for path in paths])
                resolutions.extend(f"- `{path}` · {choices[path][0]}: {choices[path][1]}" for path in paths)

            repaired = False

            def merge_problem(files: list[str]) -> str | None:
                if work.head(self.workdir) != head or work.merge_head(self.workdir) != parent:
                    return "the working checkout no longer has the expected pending merge"
                unresolved = sorted(work.unmerged(self.workdir))
                if unresolved:
                    return "unmerged paths remain: " + ", ".join(unresolved)
                marked = work.conflict_markers(self.workdir, sorted(set(paths + files)))
                if marked:
                    return "conflict markers remain: " + ", ".join(marked)
                return None

            files = candidate.changed(head)
            record["files"] = files
            reason = merge_problem(files) or self.scope_problem(files, candidate, before_commit=False)
            if reason:
                return stop(reason)
            rounds, session = cfg["limits"].get("checkFixRounds", 0), None
            for attempt in range(rounds + 1):
                res, files = candidate.run(head, files, str(logs / ("checks-update" if attempt == 0 else f"checks-update-{attempt}")), [])
                after = checks.failed(res)
                new = [name for name in after if name in passed_on_both]
                native_failed = [name for name in after if name.startswith("native-")]
                ev.add("checks-after", failed=after, new=new, nativeFailed=native_failed, attempt=attempt)
                record["checks"].update(after=after, new=new, nativeFailed=native_failed, results=res)
                record["files"] = files
                if self.update_head_moved(pr, ev):
                    return "head moved"
                if not new or native_failed or attempt == rounds:
                    break
                # Two changes that each fit can fail together. Give Codex the failing checks on the pending merge.
                prompt = agent.render("fix-update", number=str(n), title=pr["title"], base=base,
                                      feedback=checks.feedback(res, new))
                out = agent.codex(cfg, self.workdir, prompt, str(logs / f"fix-update-{attempt + 1}.md"), writable=True,
                                  session=session)
                session = out.get("session") or session
                record.setdefault("checkFixReports", []).append(out["report"][-4000:])
                ev.add("check-fix", attempt=attempt + 1, ok=out["ok"], code=out.get("code"))
                if self.update_head_moved(pr, ev):
                    return "head moved"
                if not out["ok"]:
                    return stop(agent.failure_reason(out) + " while fixing the checks that fail after the merge",
                                out["report"])
                repaired = True
                files = candidate.changed(head)
                reason = merge_problem(files) or self.scope_problem(files, candidate, before_commit=False)
                if reason:
                    return stop(reason)
            # The required native gates block even without a baseline result.
            blocking = sorted(set(new) | set(native_failed))
            if blocking:
                return stop("the update has failing checks: " + ", ".join(blocking),
                            checks.feedback(res, blocking)[:6000])

            reason = merge_problem(files)
            if reason:
                return stop(reason)
            # Inspect worktree changes against the index as well as the merge parents.
            # A rebuilt legacy binary might match a parent and vanish from the merge scope.
            unstaged = work.git(self.workdir, "diff", "--name-only", "--no-renames", "-z").split("\0")
            binaries = work.binary_changes(cfg, unstaged)
            if binaries:
                return stop("binary files changed in the working tree: " + ", ".join(binaries))
            reason = self.scope_problem(files, candidate, before_commit=True)
            if reason:
                return stop(reason)
            work.stage(self.workdir)
            record["files"] = candidate.changed(head)
            reason = self.scope_problem(record["files"], candidate, before_commit=True)
            if reason:
                return stop(reason)
            message = f"Merge {base} into {pr['headRefName']}\n\n{TRAILER}\n"
            if paths or repaired:
                message += f"Implemented-By: Codex ({cfg['agent']['model']})\n"
            sha = work.commit(self.workdir, message, staged=True)
            if work.git(self.workdir, "show", "-s", "--format=%P", sha).split() != [head, parent]:
                raise RuntimeError("the update commit must have the PR head and fetched base as parents")
            candidate.committed()
            branch = pr["headRefName"]
            blocker = self.update_preflight(pr, base, parent, ev)
            if blocker:
                record["reason"] = blocker
                ev.add("push-skipped", reason=blocker)
                if blocker in RETRY_UPDATE:
                    # The base moved, or could not be read this time; retry this head on the next poll.
                    st.update_attempted.remove(head)
                    self.save(n, st)
                return "head moved" if blocker == "head moved" else "skipped"
            try:
                work.push(self.workdir, cfg["remote"], branch, expected_head=head)
            except RuntimeError:
                if self.update_head_moved(pr, ev):
                    return "head moved"
                raise
            st.pushed.append(sha)
            st.rounds += 1
            st.gave_up_at = st.reason = None
            st.last_update, st.last_conflicts = sha, paths
            self.save(n, st)
            ev.add("pushed", sha=sha, round=st.rounds)
            lines = [f"### Factory updated this branch from `{base}`", "",
                     f"Pushed merge commit `{sha}`.", "", "Conflict resolutions", "",
                     *(resolutions or ["Git merged cleanly with the fetched base."])]
            if repaired:
                lines += ["", "Codex repaired checks that failed after the merge", "", *record["checkFixReports"]]
            lines += ["", facts.report(), "", "Checks", ""]
            lines += [f"- `{row['name']}` · {'passed' if row['ok'] else 'failed'}" for row in res]
            for label, failures in (("PR head", parent_failures["head"]), (base, parent_failures["base"])):
                if failures:
                    lines += ["", f"Failures recorded on {label}: " + ", ".join(failures)]
            self.gh.comment(n, "\n".join(lines), pull_request=True)
            return "pushed"
        finally:
            abort()

    def _fix(self, pr: dict, st: PrState, findings: list[dict], logs: Path, ev: Events, record: dict,
             facts: NativeFacts | None = None) -> str:
        cfg, n, head, branch = self.cfg, pr["number"], pr["headRefOid"], pr["headRefName"]
        facts = facts if facts is not None else NativeFacts()
        candidate = checks.Candidate(cfg, self.workdir, facts)
        if head not in st.pushed:  # a person pushed: start counting again
            st.rounds, st.seen = 0, []
        if not self.prepare_head(pr, ev):
            return "head moved"
        base_res = checks.base_results(cfg, self.workdir, head, self.base_cache, str(logs / "checks-head"))
        before = checks.failed(base_res)
        ev.add("checks-before", failed=before)

        prompt = agent.render("fix-pr", number=str(n), title=pr["title"], findings=qodo.describe(findings))
        if head not in st.pushed:
            st.attempted.append(head)
            self.save(n, st)
        out = agent.codex(cfg, self.workdir, prompt, str(logs / "fix.md"), writable=True)
        session = out.get("session")
        record["report"] = out["report"][-6000:]
        record["codexSession"] = session
        ev.add("agent", ok=out["ok"], code=out.get("code"))
        if not out["ok"]:
            reason = agent.failure_reason(out)
            record["agentFailure"] = reason
            self.stop_with_patch(pr, st, logs, reason)
            return "stopped"
        try:
            parsed = agent.parse_disputes(work.scratch(self.workdir, "disagree.md"), findings)
        except ValueError as e:
            record["disputeError"] = str(e)
            self.stop_with_patch(pr, st, logs, str(e))
            return "stopped"
        disputes = [f"{finding_id}: {evidence}" for finding_id, evidence in parsed]
        disputed_ids = {finding_id for finding_id, _ in parsed}
        record["disputes"] = disputes
        ids = sorted(str(f["id"]) for f in findings)
        undisputed = sorted(set(ids) - disputed_ids)
        st.seen.append(ids)
        # The agent's judgement wins over Qodo's: close each disputed finding in Qodo with its evidence.
        # Only a dismissal that fails is left for a person.
        unsettled = set(disputed_ids)
        if cfg.get("acceptAgentDisputes", True):
            for finding_id, evidence in parsed:
                error = qodo.dismiss(cfg["tools"]["qodo"], finding_id, qodo.accepted_explanation(evidence))
                if error:
                    record.setdefault("dismissErrors", {})[finding_id] = error
                else:
                    unsettled.discard(finding_id)
                    record.setdefault("dismissed", []).append(finding_id)
            ev.add("disputes-dismissed", dismissed=record.get("dismissed", []), failed=sorted(unsettled))
        st.disputed = sorted(set(st.disputed) | unsettled)

        if work.head(self.workdir) != head:
            self.stop(pr, st, "the agent made its own commits; nothing was pushed")
            return "stopped"
        files = work.changed(self.workdir, head)
        record["files"] = files
        if not files:
            record["undisputed"] = undisputed
            if undisputed:
                self.stop(pr, st, "the agent made no changes and left these findings undisputed: "
                          + ", ".join(undisputed), "\n".join(f"- {d}" for d in disputes))
                return "stopped"
            text = self.comment_text(head, None, findings, disputes, [], out["report"],
                                     settled=not unsettled) + f"\n\n{facts.report()}"
            if not unsettled:
                # Every finding is closed in Qodo; the next poll merges this head if CI is green.
                self.save(n, st)
                self.gh.comment(n, text, pull_request=True)
                return "disputed"
            st.gave_up_at, st.reason = head, "the agent disputed every finding and made no changes"
            self.save(n, st)
            self.gh.comment(n, text, pull_request=True)
            self.gh.relabel(n, [cfg["labels"]["help"]], [])
            return "disputed"
        if self.scope_blocked(pr, st, logs, files, candidate):
            return "stopped"

        rounds = cfg["limits"].get("checkFixRounds", 0)
        for attempt in range(rounds + 1):
            label = "checks-fix" if attempt == 0 else f"checks-fix-{attempt}"
            res, files = candidate.run(head, files, str(logs / label), [])
            after = checks.failed(res)
            new = checks.new_failures(res, before)
            ev.add("checks-after", failed=after, new=new, attempt=attempt)
            record["checks"] = {"before": before, "after": after, "new": new, "results": res, "checkFixRounds": attempt}
            record["files"] = files
            if self.scope_blocked(pr, st, logs, files, candidate, before_commit=not new):
                return "stopped"
            if not new or attempt == rounds:
                break
            # Give Codex the failing checks and let it repair its own change before giving up.
            prompt = agent.render("fix-checks", number=str(n), title=pr["title"], feedback=checks.feedback(res, new))
            # Continue the fixing conversation so Codex keeps its reasons; start fresh only without an id.
            out = agent.codex(cfg, self.workdir, prompt, str(logs / f"fix-checks-{attempt + 1}.md"), writable=True,
                              session=session)
            session = out.get("session") or session
            record.setdefault("checkFixReports", []).append(out["report"][-4000:])
            ev.add("check-fix", attempt=attempt + 1, ok=out["ok"], code=out.get("code"))
            if not out["ok"]:
                self.stop_with_patch(pr, st, logs, f"{agent.failure_reason(out)} while fixing failing checks")
                return "stopped"
            if work.head(self.workdir) != head:
                self.stop(pr, st, "the agent made its own commits; nothing was pushed")
                return "stopped"
            files = work.changed(self.workdir, head)
            if self.scope_blocked(pr, st, logs, files, candidate):
                return "stopped"
        if new:
            tried = f" after {rounds} check-fix round{'s' if rounds != 1 else ''}" if rounds else ""
            self.stop(pr, st, f"the fix has failing checks{tried}: {', '.join(new)}; nothing was pushed",
                      checks.feedback(res, new)[:6000] + f"\n\n{facts.report()}")
            return "stopped"

        if not record["files"]:
            record["undisputed"] = undisputed
            reason = "no changes remain after the checks"
            if undisputed:
                reason += ". Findings left undisputed: " + ", ".join(undisputed)
            self.stop(pr, st, reason)
            return "stopped"
        sha = work.commit(self.workdir, f"Address Qodo findings on #{n}\n\nFindings: {', '.join(ids)}\n\n"
                                        f"Implemented-By: Codex ({cfg['agent']['model']})\n{TRAILER}\n")
        candidate.committed()
        work.push(self.workdir, cfg["remote"], branch, expected_head=head)
        st.pushed.append(sha)
        st.rounds += 1
        st.gave_up_at = st.reason = None
        self.save(n, st)
        ev.add("pushed", sha=sha, round=st.rounds)
        self.gh.comment(n, self.comment_text(head, sha, findings, disputes, before, out["report"],
                                               settled=not unsettled) + f"\n\n{facts.report()}",
                        pull_request=True)
        return "pushed"

    def comment_text(self, head: str, sha: str | None, findings: list[dict], disputes: list[str],
                     before: list[str], report: str, settled: bool = False) -> str:
        lines = [f"### Factory fix for Qodo findings on {head[:10]}", ""]
        if sha:
            lines.append(f"Pushed {sha[:10]} to this branch. Checks: nothing that passed on {head[:10]} fails now.")
            if before:
                lines.append(f"Already failing before the fix (left alone): {', '.join(before)}.")
        else:
            lines.append("Nothing was pushed: the agent disputes every finding below.")
        lines += ["", "Findings sent to Codex:"] + [f"- `{f.get('id')}` {f.get('title')}" for f in findings]
        if disputes and settled:
            lines += ["", "Disputed by the agent and dismissed in Qodo (the agent's judgement takes precedence):"]
            lines += [f"- {d[:800]}" for d in disputes]
        elif disputes:
            lines += ["", "Disputed by the agent (a person decides; the factory will not retry these):"]
            lines += [f"- {d[:800]}" for d in disputes]
        lines += ["", "<details><summary>Agent report</summary>", "", report[-6000:], "", "</details>"]
        if sha:
            lines += ["", "Qodo reviews the new commit next."]
        return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pr", type=int)
    ap.add_argument("--dry", action="store_true", help="print decisions only")
    a = ap.parse_args()
    cfg = load_config()
    if a.dry:
        return Watcher(cfg, True).tick(a.pr)
    home = Path(cfg["home"])
    with lane_lock(home, "pr") as acquired:
        if not acquired or legacy_lane_gate(home, "pr"):
            print("the PR lane is already running", flush=True)
            return 0
        return Watcher(cfg, False).tick(a.pr)


if __name__ == "__main__":
    sys.exit(main())

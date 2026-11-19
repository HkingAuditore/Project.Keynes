"""Keynes factory, PR mode: fix Qodo findings or merge a reviewed PR with passing CI.

One tick: list open PRs into the base branch -> for each, read Qodo's review session -> decide()
-> for the first PR that needs a fix: check out its head, run the checks on that head, let Codex
fix the blocking findings, run the checks again, push to the PR branch only if nothing new fails,
comment on the PR. Qodo then reviews the new commit and the next tick looks again.

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
from common import Events, load_config, must  # noqa: E402
from github import PR_MERGE_FIELDS, ChangedFile, GitHub  # noqa: E402
from run import take_lock  # noqa: E402
from verdict import CIFacts, NativeFacts, unknown_findings  # noqa: E402

TRAILER = "Fixed-By: keynes-factory"


@dataclass
class PrState:
    """What the factory remembers about one PR, in ~/.keynes-factory/prs/<n>.json."""
    pushed: list[str] = field(default_factory=list)     # commits the factory pushed
    rounds: int = 0                                     # fix rounds since a person last pushed
    seen: list[list[str]] = field(default_factory=list)  # finding-id sets already sent to Codex
    disputed: list[str] = field(default_factory=list)   # finding ids Codex disputed (a person decides)
    gave_up_at: str | None = None                       # head commit where the factory stopped
    reason: str | None = None
    attempted: list[str] = field(default_factory=list)  # heads sent to Codex that a person pushed


@dataclass
class Decision:
    action: str            # "skip", "fix", "merge" or "stop"
    reason: str
    findings: list[dict] = field(default_factory=list)
    needs_files: bool = False
    needs_ci: bool = False


def merge_blocker(pr: dict, cfg: dict) -> str | None:
    labels = cfg["labels"]
    blocked = {*cfg["skipLabels"], labels["help"], labels["working"], "no-auto-merge"}
    if blocked.intersection(pr.get("labels") or []):
        return "has a label that blocks auto-merge"
    if pr.get("mergeable") in (None, "UNKNOWN"):
        return "waiting for GitHub to determine mergeability"
    if pr["mergeable"] != "MERGEABLE":
        return "GitHub reports merge conflicts"
    return None


def merge_path_blocker(files: list[ChangedFile], cfg: dict) -> str | None:
    paths = [path for f in files for path in (f.filename, f.previous_filename) if path is not None]
    forbidden, human, native = work.scope(cfg, paths)
    protected = sorted(set(forbidden + human))
    if protected:
        return f"a person merges this PR because it touches protected paths ({', '.join(protected)})"
    updated = {f.filename for f in files if f.status not in ("removed", "unchanged")}
    if native and not set(cfg["paths"]["nativeLibraries"]).issubset(updated):
        return "C++ changed but the macOS libraries were not rebuilt"
    return None


def decide(pr: dict, review: dict | None, state: PrState, cfg: dict, *,
           changed_files: list[ChangedFile] | None = None, ci: CIFacts | None = None) -> Decision:
    """Pure decision for one PR from GitHub metadata, the Qodo review read and the saved state."""
    head = pr["headRefOid"]
    if pr.get("isDraft"):
        return Decision("skip", "draft")
    if pr.get("isCrossRepository"):
        return Decision("skip", "the branch is in another repository; the factory cannot push to it")
    labels = set(pr.get("labels") or [])
    if labels.intersection(cfg["skipLabels"]):
        return Decision("skip", "has a skip label")
    if state.gave_up_at == head:
        return Decision("skip", f"stopped at this head ({state.reason}); waiting for a person")
    if head not in state.pushed and head in state.attempted:
        return Decision("skip", "Codex already ran at this head; waiting for a person")
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
        self.workdir = str(self.home / "work")
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
                result = self.apply_merge_decision(pr, st, d, review["review_session"], ci)
                if result is not None:
                    return result
                continue
            if d.action == "stop":
                self.stop(pr, st, d.reason)
                continue
            return self.fix(pr, st, d.findings)  # one fix per tick: it takes minutes
        return 0

    def stop(self, pr: dict, st: PrState, reason: str, details: str = "", *, resume_on_label_removal: bool = False) -> None:
        L = self.cfg["labels"]
        if resume_on_label_removal:
            next_step = (f"The factory will not retry the merge while `{L['help']}` is set. "
                         f"Remove `{L['help']}` to let it try again.")
        else:
            st.gave_up_at, st.reason = pr["headRefOid"], reason
            self.save(pr["number"], st)
            next_step = "The factory will look again after the next push to this branch."
        self.gh.comment(pr["number"], f"### Factory stopped on {pr['headRefOid'][:10]}\n\n{reason}\n\n{details}".strip()
                        + f"\n\n{next_step}", pull_request=True)
        self.gh.relabel(pr["number"], [L["help"]], [L["working"]])

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

    def apply_merge_decision(self, pr: dict, st: PrState, decision: Decision, session: dict, ci: CIFacts) -> int | None:
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
            if skipped is None:
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
        bad, human, native = candidate.scope(files)
        protected = sorted(set(bad + human))
        if protected:
            reason = f"the fix touches files a person must handle ({', '.join(protected)})"
        else:
            reason = candidate.commit_problem(files, native) if before_commit else None
        if not reason:
            return False
        self.stop_with_patch(pr, st, logs, f"{reason}. Nothing was pushed.", candidate.facts.report())
        return True

    def fix(self, pr: dict, st: PrState, findings: list[dict]) -> int:
        cfg, n, head = self.cfg, pr["number"], pr["headRefOid"]
        L = cfg["labels"]
        logs = self.home / "logs" / f"pr-{n}-{self.stamp}"
        logs.mkdir(parents=True, exist_ok=True)
        ev = Events()
        record: dict = {"pr": n, "url": pr["url"], "head": head, "started": self.stamp,
                        "findings": [f.get("id") for f in findings]}
        facts = NativeFacts()
        outcome = "error"
        try:
            self.gh.relabel(n, [L["working"]], [L["help"]])
            outcome = self._fix(pr, st, findings, logs, ev, record, facts)
        except Exception as e:
            record["error"] = str(e)
            ev.add("error", trace=traceback.format_exc()[-3000:])
            self.stop(pr, st, f"the fix run failed: {e}", facts.report())
        finally:
            self.gh.relabel(n, [], [L["working"]])
            record.update({"outcome": outcome, "events": ev.items, "githubErrors": self.gh.errors, "facts": asdict(facts),
                           "finished": time.strftime("%Y%m%d-%H%M%S")})
            runs = self.home / "runs"
            runs.mkdir(parents=True, exist_ok=True)
            (runs / f"pr-{n}-{self.stamp}.json").write_text(json.dumps(record, indent=2, ensure_ascii=False),
                                                           encoding="utf-8")
        return 1 if self.gh.errors else 0

    def _fix(self, pr: dict, st: PrState, findings: list[dict], logs: Path, ev: Events, record: dict,
             facts: NativeFacts | None = None) -> str:
        cfg, n, head, branch = self.cfg, pr["number"], pr["headRefOid"], pr["headRefName"]
        facts = facts if facts is not None else NativeFacts()
        candidate = checks.Candidate(cfg, self.workdir, facts)
        if head not in st.pushed:  # a person pushed: start counting again
            st.rounds, st.seen = 0, []
        runner_dir = str(Path(__file__).resolve().parents[2])
        work.ensure(runner_dir, self.workdir, f"{cfg['remote']}/{cfg['base']}")
        got = work.prepare(self.workdir, cfg["remote"], branch, f"factory-pr-{n}")
        if got != head:
            ev.add("moved", expected=head, got=got)
            return "head moved"
        base_res = checks.base_results(cfg, self.workdir, head, str(self.home / "base-checks"), str(logs / "checks-head"))
        before = checks.failed(base_res)
        ev.add("checks-before", failed=before)

        prompt = agent.render("fix-pr", number=str(n), title=pr["title"], findings=qodo.describe(findings))
        if head not in st.pushed:
            st.attempted.append(head)
            self.save(n, st)
        out = agent.codex(cfg, self.workdir, prompt, str(logs / "fix.md"), writable=True)
        record["report"] = out["report"][-6000:]
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
        st.disputed = sorted(set(st.disputed) | disputed_ids)

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
            st.gave_up_at, st.reason = head, "the agent disputed every finding and made no changes"
            self.save(n, st)
            self.gh.comment(n, self.comment_text(head, None, findings, disputes, [], out["report"]) + f"\n\n{facts.report()}",
                            pull_request=True)
            self.gh.relabel(n, [cfg["labels"]["help"]], [])
            return "disputed"
        if self.scope_blocked(pr, st, logs, files, candidate):
            return "stopped"

        res, files = candidate.run(head, files, str(logs / "checks-fix"), [])
        after = checks.failed(res)
        new = checks.new_failures(res, before)
        ev.add("checks-after", failed=after, new=new)
        record["checks"] = {"before": before, "after": after, "new": new, "results": res}
        record["files"] = files
        if self.scope_blocked(pr, st, logs, files, candidate, before_commit=not new):
            return "stopped"
        if new:
            self.stop(pr, st, f"the fix has failing checks: {', '.join(new)}; nothing was pushed",
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
        must(["git", "-C", self.workdir, "push", "-q", f"--force-with-lease=refs/heads/{branch}:{head}",
              cfg["remote"], f"HEAD:refs/heads/{branch}"])
        st.pushed.append(sha)
        st.rounds += 1
        st.gave_up_at = st.reason = None
        self.save(n, st)
        ev.add("pushed", sha=sha, round=st.rounds)
        self.gh.comment(n, self.comment_text(head, sha, findings, disputes, before, out["report"]) + f"\n\n{facts.report()}",
                        pull_request=True)
        return "pushed"

    def comment_text(self, head: str, sha: str | None, findings: list[dict], disputes: list[str],
                     before: list[str], report: str) -> str:
        lines = [f"### Factory fix for Qodo findings on {head[:10]}", ""]
        if sha:
            lines.append(f"Pushed {sha[:10]} to this branch. Checks: nothing that passed on {head[:10]} fails now.")
            if before:
                lines.append(f"Already failing before the fix (left alone): {', '.join(before)}.")
        else:
            lines.append("Nothing was pushed: the agent disputes every finding below.")
        lines += ["", "Findings sent to Codex:"] + [f"- `{f.get('id')}` {f.get('title')}" for f in findings]
        if disputes:
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
    lock = Path(cfg["home"]) / "lock"
    if not a.dry and not take_lock(lock):
        print("another factory run holds the lock")
        return 0
    try:
        return Watcher(cfg, a.dry).tick(a.pr)
    finally:
        if not a.dry:
            lock.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())

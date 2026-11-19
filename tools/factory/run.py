"""Keynes factory: take one `ready-for-agent` ticket to a reviewed PR on the fork. Never merges.

Stages: G0 ticket gate -> plan (Codex, read-only) -> implement + checks (Codex, retry limit)
-> Qodo local review of uncommitted changes -> commit, push, PR -> Qodo PR review + CI
-> fix loop -> verdict from facts -> run record, issue comment, label.

Usage: python3 tools/factory/run.py [--issue N] [--dry]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent  # noqa: E402
import checks  # noqa: E402
import qodo  # noqa: E402
import work  # noqa: E402
from common import Events, load_config, sh  # noqa: E402
from github import GitHub  # noqa: E402
from ticket import criteria, gate, touching  # noqa: E402
from verdict import Facts, classify, judge  # noqa: E402


def take_lock(path: Path) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return True
        except FileExistsError:
            try:
                pid = int(path.read_text().strip() or 0)
            except (OSError, ValueError):
                pid = 0
            owner = sh(["ps", "-o", "command=", "-p", str(pid)]).out if pid else ""
            if "tools/factory/run.py" in owner:
                return False
            path.unlink(missing_ok=True)
    return False


class Run:
    def __init__(self, cfg: dict, number: int, dry: bool) -> None:
        self.cfg, self.number, self.dry = cfg, number, dry
        self.gh = GitHub(cfg["repo"])
        self.ev = Events()
        self.facts = Facts(review_round_limit=cfg["limits"]["prReviewRounds"])
        self.stamp = time.strftime("%Y%m%d-%H%M%S")
        home = Path(cfg["home"])
        self.home = home
        self.workdir = str(home / "work")
        self.logs = home / "logs" / f"{number}-{self.stamp}"
        self.logs.mkdir(parents=True, exist_ok=True)
        self.branch = f"agent/issue-{number}"
        self.pr: dict | None = None
        self.record: dict = {"issue": number, "started": self.stamp, "branch": self.branch}

    # ---- helpers -------------------------------------------------------------------------
    def path(self, name: str) -> str:
        return str(self.logs / name)

    def run_checks(self, label: str, extra: list[str], base_failed: list[str]) -> tuple[list[dict], list[str]]:
        files = work.changed(self.workdir, self.base)
        native = bool(touching(files, self.cfg["checks"]["nativePaths"]))
        self.facts.native_changed = self.facts.native_changed or native
        res = checks.Runner(self.cfg, self.workdir, self.path(f"checks-{label}")).run(native, extra)
        if native:
            work.restore(self.workdir, self.cfg["paths"]["trackedBinaries"])
        new = [n for n in checks.failed(res) if n not in base_failed]
        self.ev.add("checks", label=label, failed=checks.failed(res), new=new)
        return res, new

    def scope_problems(self) -> list[str]:
        files = work.changed(self.workdir, self.base)
        self.facts.human_paths = touching(files, self.cfg["paths"]["needsHuman"])
        bad = touching(files, self.cfg["paths"]["forbidden"])
        return [f"files outside the agent's area changed: {', '.join(bad)}; revert them"] if bad else []

    # ---- stages --------------------------------------------------------------------------
    def plan(self, issue: dict) -> str | None:
        prompt = agent.render("plan", number=str(self.number), title=issue["title"], body=issue["body"] or "")
        out = agent.codex(self.cfg, self.workdir, prompt, self.path("plan.md"), writable=False)
        plan = out["report"]
        missing = agent.plan_complete(plan)
        self.ev.add("plan", ok=out["ok"], missing=missing)
        if not out["ok"] or missing:
            self.facts.stopped_by = f"the plan step failed (exit {out['code']}, missing {missing})"
            return None
        self.facts.plan_questions = agent.plan_questions(plan)
        self.gh.comment(self.number, f"### Factory plan (Codex, read-only)\n\n{plan}")
        return plan

    def implement(self, issue: dict, plan: str, extra: list[str], base_failed: list[str]) -> bool:
        feedback, new = "", []
        crit = "\n".join(f"- {c}" for c in criteria(issue["body"]))
        for attempt in range(1, self.cfg["limits"]["implementAttempts"] + 1):
            prompt = agent.render("implement", number=str(self.number), title=issue["title"],
                                  body=issue["body"] or "", criteria=crit, plan=plan,
                                  feedback=f"Problems from the previous attempt:\n\n{feedback}" if feedback else "")
            out = agent.codex(self.cfg, self.workdir, prompt, self.path(f"implement-{attempt}.md"), writable=True)
            self.record.setdefault("reports", []).append(out["report"][-4000:])
            question = work.scratch(self.workdir, "question.md")
            if question:
                self.facts.stopped_by = f"the agent asks: {question[:1500]}"
                return False
            if work.head(self.workdir) != self.base:
                self.facts.stopped_by = "the agent made its own commits"
                return False
            if not work.changed(self.workdir, self.base):
                feedback = "You changed no files."
                self.ev.add("implement", attempt=attempt, result="no changes")
                continue
            problems = self.scope_problems()
            if problems:
                feedback = "\n".join(problems)
                self.ev.add("implement", attempt=attempt, result="scope", problems=problems)
                continue
            res, new = self.run_checks(f"implement-{attempt}", extra, base_failed)
            if not new:
                self.ev.add("implement", attempt=attempt, result="checks pass")
                return True
            feedback = checks.feedback(res, new)
        self.facts.stopped_by = f"checks still fail after {self.cfg['limits']['implementAttempts']} attempts"
        self.facts.new_failures = new
        return False

    def local_review(self, issue: dict, plan: str, extra: list[str], base_failed: list[str]) -> bool:
        seen: set[tuple] = set()
        recent = ["Initial implementation of the ticket by Codex."]
        for rnd in range(1, self.cfg["limits"]["localReviewRounds"] + 1):
            ctx = {
                "decisions": [f"Ticket #{self.number} scope as written by its author; plan from a Codex read-only pass."],
                "notes": f"Ticket: {issue['title']}\n\n{issue['body']}\n\nPlan:\n{plan[:12000]}",
                "recent_work": recent,
            }
            ctx_file = self.path(f"review-context-{rnd}.json")
            Path(ctx_file).write_text(json.dumps(ctx, ensure_ascii=False), encoding="utf-8")
            rev = qodo.local_review(self.cfg["tools"]["qodo"], self.workdir, self.base, ctx_file,
                                    self.cfg["limits"]["localReviewTimeoutMinutes"])
            self.record.setdefault("localReviews", []).append(
                {k: rev.get(k) for k in ("ok", "complete", "error", "comment")}
                | {"blocking": [b.get("id") for b in rev.get("blocking", [])],
                   "informational": [b.get("id") for b in rev.get("informational", [])]})
            self.ev.add("local-review", round=rnd, ok=rev["ok"], blocking=len(rev.get("blocking", [])))
            if not rev["ok"]:
                self.facts.stopped_by = f"Qodo local review failed: {rev['error']}"
                return False
            ids = tuple(sorted(str(b.get("id")) for b in rev["blocking"]))
            if not ids:
                return True
            if ids in seen:
                break
            seen.add(ids)
            if rnd == self.cfg["limits"]["localReviewRounds"]:
                break
            if not self.fix(issue, rev["blocking"], "local review of uncommitted changes", False, extra, base_failed):
                return False
            recent = [f"Addressed local-review findings {', '.join(ids)}; fixes only."]
        self.facts.local_blocking = list(ids)
        return True

    def fix(self, issue: dict, findings: list[dict], source: str, committed: bool,
            extra: list[str], base_failed: list[str]) -> bool:
        prompt = agent.render("fix-review", number=str(self.number), title=issue["title"],
                              committed=" and committed" if committed else "",
                              source=source, findings=qodo.describe(findings))
        out = agent.codex(self.cfg, self.workdir, prompt, self.path(f"fix-{int(time.time())}.md"), writable=True)
        self.record.setdefault("reports", []).append(out["report"][-4000:])
        disagree = work.scratch(self.workdir, "disagree.md")
        if disagree:
            self.facts.disagreements += [l.strip("- ").strip() for l in disagree.splitlines() if l.strip()]
        if work.head(self.workdir) != (self.facts.head or self.base):
            self.facts.stopped_by = "the agent made its own commits"
            return False
        problems = self.scope_problems()
        if problems:
            self.facts.stopped_by = problems[0]
            return False
        res, new = self.run_checks(f"fix-{int(time.time())}", extra, base_failed)
        self.facts.new_failures = new
        if new:
            self.facts.stopped_by = "checks fail after the review fix: " + ", ".join(new)
            return False
        return True

    def pr_body(self, issue: dict, plan: str) -> str:
        crit = "\n".join(f"- [ ] {c}" for c in criteria(issue["body"]))
        reports = self.record.get("reports") or [""]
        return (f"Closes #{self.number}\n\n## Acceptance criteria\n{crit}\n\n"
                f"## Factory\nPlan, checks and reviews are in the run record `{self.stamp}` "
                f"and the issue comments. The verdict is computed from facts, not from this report.\n\n"
                f"<details><summary>Plan</summary>\n\n{plan[:20000]}\n\n</details>\n\n"
                f"<details><summary>Agent report</summary>\n\n{reports[-1][:12000]}\n\n</details>\n\n"
                f"Implemented-By: Codex ({self.cfg['agent']['model']})\n")

    def pr_loop(self, issue: dict, extra: list[str], base_failed: list[str]) -> None:
        seen: set[tuple] = set()
        lim = self.cfg["limits"]
        while True:
            head = self.facts.head
            rev = qodo.wait_pr_review(self.cfg["tools"]["qodo"], self.pr["url"], head, lim["prReviewTimeoutMinutes"])
            session = rev.get("review_session") or {}
            self.facts.review_status = session.get("status") if session.get("commit_sha") == head else (
                "not started on the head" if not rev.get("timed_out") else "timed out")
            self.facts.review_sha = session.get("commit_sha")
            self.facts.findings = rev.get("findings") or []
            self.facts.ci_state = self.wait_ci(head, lim["ciTimeoutMinutes"])
            block = qodo.blocking(self.facts.findings)
            self.ev.add("pr-review", round=self.facts.review_rounds, status=self.facts.review_status,
                        blocking=len(block), ci=self.facts.ci_state)
            if self.facts.review_status != "completed" or not block:
                return
            if self.facts.review_rounds >= lim["prReviewRounds"]:
                return
            ids = tuple(sorted(str(f.get("id")) for f in block))
            if ids in seen:
                self.facts.review_stalled = True
                return
            seen.add(ids)
            self.facts.review_rounds += 1
            if not self.fix(issue, block, f"PR review of {head[:10]}", True, extra, base_failed):
                return
            if not work.dirty(self.workdir):
                self.facts.review_stalled = True
                return
            self.facts.head = work.commit(self.workdir, f"Issue #{self.number}: address Qodo findings "
                                          f"{', '.join(ids)}\n\nImplemented-By: Codex ({self.cfg['agent']['model']})\n")
            self.facts.checks_sha = self.facts.head
            work.push(self.workdir, self.cfg["remote"], self.branch)

    def wait_ci(self, sha: str, timeout_min: int) -> str | None:
        deadline = time.time() + timeout_min * 60
        state = None
        while time.time() < deadline:
            state = self.gh.ci_state(sha)
            if state in ("success", "failure"):
                return state
            time.sleep(60)
        return state

    # ---- main ----------------------------------------------------------------------------
    def go(self, issue: dict) -> None:
        cfg = self.cfg
        L = cfg["labels"]
        errors = gate(issue["title"], issue["body"] or "", issue["labels"], cfg["skipLabels"])
        self.ev.add("G0", errors=errors)
        if errors:
            self.facts.stopped_by = "the ticket is not ready: " + "; ".join(errors)
            return
        if self.dry:
            self.ev.add("dry", note="G0 passed; stopping before any write")
            return
        err = self.gh.relabel(self.number, [L["working"]], [L["trigger"]])
        if err:
            raise RuntimeError(err)
        existing = self.gh.open_pr(self.branch)
        if existing:
            self.facts.stopped_by = f"an open PR already exists for {self.branch}: {existing['url']}"
            return
        runner_dir = str(Path(__file__).resolve().parents[2])
        work.ensure(runner_dir, self.workdir, f"{cfg['remote']}/{cfg['base']}")
        self.base = work.prepare(self.workdir, cfg["remote"], cfg["base"], self.branch)
        self.record["base"] = self.base
        self.ev.add("worktree", base=self.base)

        base_res = checks.base_results(cfg, self.workdir, self.base, str(self.home / "base-checks"),
                                       self.path("checks-base"))
        base_failed = checks.failed(base_res)
        self.facts.base_failures = base_failed
        self.ev.add("base-checks", failed=base_failed)

        plan = self.plan(issue)
        if plan is None or self.facts.plan_questions:
            return
        extra, rejected = checks.extra_checks(agent.plan_checks(plan), cfg["checks"]["extraCheckPattern"])
        self.record["extraChecks"] = {"run": extra, "rejected": rejected}

        if not self.implement(issue, plan, extra, base_failed):
            return
        if not self.local_review(issue, plan, extra, base_failed):
            return

        title = f"Issue #{self.number}: {issue['title']}"
        self.facts.head = work.commit(self.workdir, f"{title}\n\nImplemented-By: Codex ({cfg['agent']['model']})\n")
        self.facts.checks_sha = self.facts.head
        work.push(self.workdir, cfg["remote"], self.branch)
        self.pr = self.gh.create_pr(self.branch, cfg["base"], title, self.pr_body(issue, plan))
        self.record["pr"] = self.pr["url"]
        self.ev.add("pr", url=self.pr["url"], head=self.facts.head)
        self.pr_loop(issue, extra, base_failed)

    def finish(self) -> int:
        if self.pr:
            remote_head = (self.gh.open_pr(self.branch) or {}).get("headRefOid")
            if remote_head and remote_head != self.facts.head:
                self.facts.stopped_by = self.facts.stopped_by or "the PR head moved outside the factory"
        v = judge(self.facts)
        self.record.update({"finished": time.strftime("%Y%m%d-%H%M%S"), "verdict": v.verdict,
                            "reasons": v.reasons, "forHuman": v.for_human, "facts": asdict(self.facts),
                            "events": self.ev.items})
        runs = self.home / "runs"
        runs.mkdir(parents=True, exist_ok=True)
        out = runs / f"{self.number}-{self.stamp}.json"
        L = self.cfg["labels"]
        if not self.dry:
            lines = [f"### Factory verdict: **{v.verdict}**", ""] + [f"- {r}" for r in v.reasons]
            if v.for_human:
                lines += ["", "For a person to decide (informational findings):"] + [f"- {x}" for x in v.for_human]
            if self.pr:
                lines += ["", f"PR: {self.pr['url']} (the factory never merges)"]
            lines += ["", f"Run record: `{out.name}`"]
            self.gh.comment(self.number, "\n".join(lines))
            done = v.verdict == "READY"
            self.gh.relabel(self.number, [L["done"] if done else L["help"]], [L["working"]])
        self.record["githubErrors"] = self.gh.errors
        out.write_text(json.dumps(self.record, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"verdict {v.verdict}: {out}")
        return 1 if self.gh.errors else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--issue", type=int)
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    cfg = load_config()
    gh = GitHub(cfg["repo"])
    if a.issue:
        issue = gh.issue(a.issue)
    else:
        tickets = [t for t in gh.tickets(cfg["labels"]["trigger"]) if not set(t["labels"]) & set(cfg["skipLabels"])]
        if not tickets:
            print("no ticket labelled", cfg["labels"]["trigger"])
            return 0
        issue = tickets[0]
    lock = Path(cfg["home"]) / "lock"
    if not a.dry and not take_lock(lock):
        print("another factory run holds the lock")
        return 0
    run = Run(cfg, issue["number"], a.dry)
    try:
        run.go(issue)
    except Exception as e:  # the ticket must never stay stuck in agent-working
        run.facts.stopped_by = f"the run failed: {e}"
        run.ev.add("error", trace=traceback.format_exc()[-3000:])
    finally:
        code = run.finish()
        if not a.dry:
            lock.unlink(missing_ok=True)
    return code


if __name__ == "__main__":
    sys.exit(main())

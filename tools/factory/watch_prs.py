"""Keynes factory, PR mode: watch open PRs on the fork and fix what Qodo's review finds. Never merges.

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
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent  # noqa: E402
import checks  # noqa: E402
import qodo  # noqa: E402
import work  # noqa: E402
from common import Events, load_config, must, sh  # noqa: E402
from github import GitHub  # noqa: E402
from run import take_lock  # noqa: E402
from verdict import unknown_findings  # noqa: E402

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


@dataclass
class Decision:
    action: str            # "skip", "fix" or "stop"
    reason: str
    findings: list[dict] = field(default_factory=list)


def decide(pr: dict, review: dict | None, state: PrState, skip_labels: list[str], round_limit: int) -> Decision:
    """Pure decision for one PR from GitHub metadata, the Qodo review read and the saved state."""
    head = pr["headRefOid"]
    if pr.get("isDraft"):
        return Decision("skip", "draft")
    if pr.get("isCrossRepository"):
        return Decision("skip", "the branch is in another repository; the factory cannot push to it")
    if set(pr.get("labels") or []) & set(skip_labels):
        return Decision("skip", "has a skip label")
    if state.gave_up_at == head:
        return Decision("skip", f"stopped at this head ({state.reason}); waiting for a person")
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
    findings = review.get("findings") or []
    unknown = unknown_findings(findings)
    if unknown:
        return Decision("stop", "findings with an unknown status or action_level: " + ", ".join(unknown))
    block = [f for f in qodo.blocking(findings) if str(f.get("id")) not in state.disputed]
    if not block:
        if state.disputed:
            return Decision("skip", "only findings the agent disputed are open; a person decides")
        return Decision("skip", "no open blocking findings at the head")
    ids = sorted(str(f.get("id")) for f in block)
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
        return PrState(**json.loads(p.read_text(encoding="utf-8"))) if p.exists() else PrState()

    def save(self, n: int, st: PrState) -> None:
        p = self.state_path(n)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(st.__dict__, indent=2), encoding="utf-8")

    # ---- one tick --------------------------------------------------------------------
    def prs(self, only: int | None) -> list[dict]:
        items = json.loads(must(["gh", "pr", "list", "-R", self.cfg["repo"], "--state", "open",
                                 "--base", self.cfg["base"], "--limit", "50", "--json",
                                 "number,title,url,headRefName,headRefOid,isDraft,isCrossRepository,labels,createdAt"]))
        for it in items:
            it["labels"] = [l["name"] for l in it["labels"]]
        items.sort(key=lambda it: it["createdAt"])
        return [it for it in items if only is None or it["number"] == only]

    def tick(self, only: int | None) -> int:
        lim = self.cfg["limits"]
        for pr in self.prs(only):
            st = self.load(pr["number"])
            review = qodo.pr_review(self.cfg["tools"]["qodo"], pr["url"])
            d = decide(pr, review, st, self.cfg["skipLabels"], lim["prReviewRounds"])
            print(json.dumps({"pr": pr["number"], "action": d.action, "reason": d.reason}), flush=True)
            if self.dry or d.action == "skip":
                continue
            if d.action == "stop":
                self.stop(pr, st, d.reason)
                continue
            return self.fix(pr, st, d.findings)  # one fix per tick: it takes minutes
        return 0

    def stop(self, pr: dict, st: PrState, reason: str, details: str = "") -> None:
        st.gave_up_at, st.reason = pr["headRefOid"], reason
        self.save(pr["number"], st)
        L = self.cfg["labels"]
        self.gh.comment(pr["number"], f"### Factory stopped on {pr['headRefOid'][:10]}\n\n{reason}\n\n{details}".strip()
                        + "\n\nThe factory will look again after the next push to this branch.")
        self.gh.relabel(pr["number"], [L["help"]], [L["working"]])

    # ---- the fix ---------------------------------------------------------------------
    def scope_blocked(self, pr: dict, st: PrState, logs: Path, files: list[str]) -> bool:
        bad, human, native = work.scope(self.cfg, files)
        protected = sorted(set(bad + human + native))
        if not protected:
            return False
        patch = logs / "fix.patch"
        sh(["git", "-C", self.workdir, "add", "-A", "-N", "."])
        patch.write_text(sh(["git", "-C", self.workdir, "diff", pr["headRefOid"]]).out, encoding="utf-8")
        self.stop(pr, st, f"the fix touches files a person must handle ({', '.join(protected)}). Nothing was pushed.",
                  f"The patch is saved locally at `{patch}`.")
        return True

    def fix(self, pr: dict, st: PrState, findings: list[dict]) -> int:
        cfg, n, head, branch = self.cfg, pr["number"], pr["headRefOid"], pr["headRefName"]
        L = cfg["labels"]
        logs = self.home / "logs" / f"pr-{n}-{self.stamp}"
        logs.mkdir(parents=True, exist_ok=True)
        ev = Events()
        record: dict = {"pr": n, "url": pr["url"], "head": head, "started": self.stamp,
                        "findings": [f.get("id") for f in findings]}
        outcome = "error"
        self.gh.relabel(n, [L["working"]], [L["help"]])
        try:
            outcome = self._fix(pr, st, findings, logs, ev, record)
        except Exception as e:
            record["error"] = str(e)
            ev.add("error", trace=traceback.format_exc()[-3000:])
            self.stop(pr, st, f"the fix run failed: {e}")
        finally:
            if outcome == "pushed":
                self.gh.relabel(n, [], [L["working"]])
            record.update({"outcome": outcome, "events": ev.items, "githubErrors": self.gh.errors,
                           "finished": time.strftime("%Y%m%d-%H%M%S")})
            runs = self.home / "runs"
            runs.mkdir(parents=True, exist_ok=True)
            (runs / f"pr-{n}-{self.stamp}.json").write_text(json.dumps(record, indent=2, ensure_ascii=False),
                                                           encoding="utf-8")
        return 1 if self.gh.errors else 0

    def _fix(self, pr: dict, st: PrState, findings: list[dict], logs: Path, ev: Events, record: dict) -> str:
        cfg, n, head, branch = self.cfg, pr["number"], pr["headRefOid"], pr["headRefName"]
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
        out = agent.codex(cfg, self.workdir, prompt, str(logs / "fix.md"), writable=True)
        record["report"] = out["report"][-6000:]
        disputes = [l.strip("- ").strip() for l in (work.scratch(self.workdir, "disagree.md") or "").splitlines() if l.strip()]
        disputed_ids = [str(f.get("id")) for f in findings if any(str(f.get("id")) in d for d in disputes)]
        record["disputes"] = disputes
        st.seen.append(sorted(str(f.get("id")) for f in findings))
        st.disputed = sorted(set(st.disputed) | set(disputed_ids))
        ev.add("agent", ok=out["ok"], disputes=len(disputes))

        if work.head(self.workdir) != head:
            self.stop(pr, st, "the agent made its own commits; nothing was pushed")
            return "stopped"
        files = work.changed(self.workdir, head)
        record["files"] = files
        if not files:
            if disputes:
                self.save(n, st)
                self.gh.comment(n, self.comment_text(head, None, findings, disputes, [], out["report"]))
                self.gh.relabel(n, [cfg["labels"]["help"]], [cfg["labels"]["working"]])
                return "disputed"
            self.stop(pr, st, "the agent changed nothing and disputed nothing")
            return "stopped"
        if self.scope_blocked(pr, st, logs, files):
            return "stopped"

        res = checks.Runner(cfg, self.workdir, str(logs / "checks-fix")).run(native=False, extra=[])
        after = checks.failed(res)
        new = [x for x in after if x not in before]
        ev.add("checks-after", failed=after, new=new)
        record["checks"] = {"before": before, "after": after, "new": new}
        if new:
            self.stop(pr, st, f"checks that passed before the fix fail after it: {', '.join(new)}; nothing was pushed",
                      checks.feedback(res, new)[:6000])
            return "stopped"

        ids = ", ".join(str(f.get("id")) for f in findings)
        record["files"] = work.changed(self.workdir, head)
        if self.scope_blocked(pr, st, logs, record["files"]):
            return "stopped"
        if not record["files"]:
            self.stop(pr, st, "no changes remain after the checks")
            return "stopped"
        sha = work.commit(self.workdir, f"Address Qodo findings on #{n}\n\nFindings: {ids}\n\n"
                                        f"Implemented-By: Codex ({cfg['agent']['model']})\n{TRAILER}\n")
        must(["git", "-C", self.workdir, "push", "-q", f"--force-with-lease=refs/heads/{branch}:{head}",
              cfg["remote"], f"HEAD:refs/heads/{branch}"])
        st.pushed.append(sha)
        st.rounds += 1
        st.gave_up_at = st.reason = None
        self.save(n, st)
        ev.add("pushed", sha=sha, round=st.rounds)
        self.gh.comment(n, self.comment_text(head, sha, findings, disputes, before, out["report"]))
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
        lines += ["", "<details><summary>Agent report</summary>", "", report[-6000:], "", "</details>",
                  "", "Qodo reviews the new commit next; the factory never merges."]
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

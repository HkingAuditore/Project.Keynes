"""The factory's verdict. It is computed only from recorded facts, never from the agent's own report.

Order: NEEDS_HUMAN, then NOT_DONE (evidence missing), then NEEDS_FIX, then READY.
"""

from __future__ import annotations

from dataclasses import dataclass, field

OPEN = {"pending", "partial_implementation", "not_implemented", "focus_areas_edited"}
CLOSED = {"implemented", "full_implementation", "dismissed", "detected_after_merge", "outdated"}
BLOCKING = ("action_required", "remediation_recommended")


@dataclass
class Facts:
    head: str | None = None
    stopped_by: str | None = None
    plan_questions: list[str] = field(default_factory=list)
    rejected_checks: list[str] = field(default_factory=list)
    disagreements: list[str] = field(default_factory=list)
    base_failures: list[str] = field(default_factory=list)
    checks_sha: str | None = None
    new_failures: list[str] = field(default_factory=list)
    human_paths: list[str] = field(default_factory=list)
    native_changed: bool = False
    local_blocking: list[str] = field(default_factory=list)
    local_review_incomplete: bool = False
    review_status: str | None = None
    review_sha: str | None = None
    findings: list[dict] = field(default_factory=list)
    review_rounds: int = 0
    review_round_limit: int = 3
    review_stalled: bool = False
    ci_state: str | None = None


def classify_level(level: str | None) -> str:
    if level in BLOCKING:
        return "blocking"
    return "informational" if level == "informational" else "unknown"


def classify(finding: dict) -> str:
    status = finding.get("attribution_status")
    if status in OPEN:
        return classify_level(finding.get("action_level"))
    if status in CLOSED:
        return "closed"
    return "unknown"


def unknown_findings(findings: list[dict]) -> list[str]:
    return [f"{f.get('id', '?')} (status={f.get('attribution_status')!r}, action_level={f.get('action_level')!r})"
            for f in findings if classify(f) == "unknown"]


@dataclass
class Verdict:
    verdict: str
    reasons: list[str]
    for_human: list[str]


def judge(f: Facts) -> Verdict:
    human: list[str] = []
    if f.stopped_by:
        human.append(f.stopped_by)
    human += [f"the plan asks: {q}" for q in f.plan_questions]
    human += [f"the plan check was rejected by the allowlist: {c}" for c in f.rejected_checks]
    human += [f"the agent disagrees with a finding: {d}" for d in f.disagreements]
    if f.base_failures:
        human.append("master already fails " + ", ".join(f.base_failures)
                     + "; AGENTS.md requires fixing found failures before a push")
    if f.human_paths:
        human.append("baseline or contract files changed and need a human check: " + ", ".join(f.human_paths))
    if f.local_blocking:
        human.append("local Qodo review findings left open after the round limit: " + ", ".join(f.local_blocking))
    if f.native_changed:
        human.append("C++ changed: rebuild and commit both macOS libraries, then run check_macos_runtime_extension.py")
    unknown = unknown_findings(f.findings)
    if unknown:
        human.append("findings with an unknown status or action_level: " + ", ".join(unknown))
    blocking = [x for x in f.findings if classify(x) == "blocking"]
    if f.review_stalled:
        human.append("the fix-and-review loop stalled on the same findings")
    elif blocking and f.review_rounds >= f.review_round_limit:
        human.append(f"findings still open after {f.review_rounds} review rounds")

    info = [f"[{x.get('action_level')}] {x.get('title')}" for x in f.findings if classify(x) == "informational"]
    if human:
        return Verdict("NEEDS_HUMAN", human, info)

    missing: list[str] = []
    if not f.head:
        missing.append("no PR head commit")
    elif f.checks_sha != f.head:
        missing.append("local checks did not run on the PR head")
    if f.review_status is None:
        missing.append("Qodo has not reviewed the PR")
    elif f.review_status != "completed":
        missing.append(f"the Qodo review is {f.review_status}")
    elif f.review_sha != f.head:
        missing.append("the Qodo review is of an older commit")
    if f.ci_state in (None, "pending"):
        missing.append("CI has not finished on the PR head")
    if missing:
        return Verdict("NOT_DONE", missing, info)

    fix: list[str] = []
    if f.new_failures:
        fix.append("checks fail that pass on master: " + ", ".join(f.new_failures))
    if blocking:
        fix.append("open Qodo findings: " + ", ".join(str(x.get("id")) for x in blocking))
    if f.ci_state != "success":
        fix.append(f"CI is {f.ci_state}")
    if fix:
        return Verdict("NEEDS_FIX", fix, info)
    return Verdict("READY", ["checks, CI and the Qodo review of the head all pass"], info)

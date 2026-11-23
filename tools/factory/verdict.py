"""The factory's verdict. It is computed only from recorded facts, never from the agent's own report.

Order: NEEDS_HUMAN, then NOT_DONE (evidence missing), then NEEDS_FIX, then READY.
"""

from __future__ import annotations

from dataclasses import dataclass, field, fields

OPEN = {"pending", "partial_implementation", "not_implemented", "focus_areas_edited"}
CLOSED = {"implemented", "full_implementation", "dismissed", "detected_after_merge", "outdated"}
BLOCKING = ("action_required", "remediation_recommended")


@dataclass(frozen=True)
class CIRun:
    status: str
    conclusion: str | None
    id: int = 0
    name: str = ""
    url: str = ""


@dataclass(frozen=True)
class CIFacts:
    sha: str
    workflows: list[CIRun] | None
    checks: list[CIRun] | None

    def state(self, *, strict: bool = False) -> str:
        if self.workflows is None or self.checks is None:
            return "error"
        if not self.workflows or (not strict and not self.checks):
            return "pending"
        if any(run.status != "completed" for run in self.workflows + self.checks):
            return "pending"
        if strict:
            return "success" if all(run.conclusion == "success" for run in self.workflows + self.checks) else "failure"
        # Keep the issue verdict's existing allowance for neutral and skipped checks.
        return "success" if all(run.conclusion in {"success", "neutral", "skipped"} for run in self.checks) else "failure"


@dataclass
class NativeFacts:
    native_changed: bool = False
    native_rebuilt: bool = False
    native_runtime_ok: bool = False

    def report(self) -> str:
        return " · ".join(f"`{item.name}={str(getattr(self, item.name)).lower()}`" for item in fields(NativeFacts))


@dataclass
class Facts(NativeFacts):
    head: str | None = None
    stopped_by: str | None = None
    plan_questions: list[str] = field(default_factory=list)
    rejected_checks: list[str] = field(default_factory=list)
    native_requested: bool = False
    disagreements: list[str] = field(default_factory=list)
    accepted_disputes: list[str] = field(default_factory=list)  # disputed by the agent and settled its way
    base_failures: list[str] = field(default_factory=list)
    base_extra_failures: list[str] = field(default_factory=list)  # plan-requested checks that already fail on the base
    checks_sha: str | None = None
    new_failures: list[str] = field(default_factory=list)
    human_paths: list[str] = field(default_factory=list)
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
    if not isinstance(status, str):
        return "unknown"
    if status in OPEN:
        return classify_level(finding.get("action_level"))
    if status in CLOSED:
        return "closed"
    return "unknown"


def unknown_findings(findings: list[dict], *, require_level: bool = False) -> list[str]:
    return [f"{f.get('id', '?')} (status={f.get('attribution_status')!r}, action_level={f.get('action_level')!r})"
            for f in findings if classify(f) == "unknown" or
            (require_level and classify_level(f.get("action_level")) == "unknown")]


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
    if f.human_paths:
        human.append("protected files changed and need a human check: " + ", ".join(f.human_paths))
    if f.local_blocking:
        human.append("local Qodo review findings left open after the round limit: " + ", ".join(f.local_blocking))
    if f.native_changed:
        if not f.native_rebuilt:
            human.append("C++ changed and the macOS rebuild did not pass")
        if not f.native_runtime_ok:
            human.append("C++ changed and both macOS runtime checks have not passed")
    if f.native_requested and not f.native_changed:
        human.append("the plan asked for the macOS runtime check, but no native sources changed, so it did not run")
    if f.ci_state == "error":
        human.append("the CI state could not be read")
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

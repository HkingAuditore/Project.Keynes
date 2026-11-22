# Quality gate: when an agent may call a task done

This is the gate every coding agent working on Project.Keynes follows, whether it is the factory (`tools/factory/`), Codex, or an interactive session using Qodo's Reviewer or Review Resolver skill. The factory enforces it in code (`tools/factory/verdict.py`); `tools/factory/tests/test_quality_gate.py` fails if this page and that code disagree.

## The rule

> Fix every valid High or Medium finding, whatever its type (Bug, Rule violation, Requirement gap) or category. Report every Low finding to a person and leave it for them to decide. A task is done only when the latest completed Qodo review covers the current head commit, the relevant checks passed, and no valid High or Medium finding is open.

Not done, with the blocker stated, when any of these holds: a High or Medium finding is still open; a check failed or did not run on the head; the Qodo review is missing, still running, failed, skipped, or covers an older commit; the fix-and-review loop made no progress (same findings again, or three rounds used). The agent does not weaken a check or dismiss a finding to get past the gate. If it thinks a finding is wrong it changes no code for it and records file and line evidence; the factory then dismisses that finding in Qodo with the evidence, where it stays visible. This means an agent's reasoned dispute can close a High finding without a person, which is a deliberate factory choice (`run.py`, `watch_prs.py`) and the main limit of this gate.

## Severity as the tools expose it

Qodo's findings API (`qodo read pr-review-session findings`) returns `action_level`, not a High/Medium/Low label. The PR comment shows the label as a badge. What we observed on our own PRs, and what we assume:

| Severity | `action_level` | Gate | How we know |
|---|---|---|---|
| High | action_required | blocks | Badge `High` with alt text "Action required" on 11 inline comments across our PRs |
| Medium | remediation_recommended | blocks | Not seen on any of our PRs yet; assumed from the name. The factory blocks on it either way |
| Low | informational | reported | Badge `Low` with alt text "Informational" on PR 7 and PR 38 |

An open finding with any other or a missing `action_level` is unknown and goes to a person. `judge()` does not look at the level of a finding that is already closed; the merge path in `watch_prs.py` does, and stops on it.

## Where it is enforced

- `verdict.py` `judge()`: open High/Medium gives NEEDS_FIX; review of an older commit, a running review, or no review gives NOT_DONE; unknown status or level gives NEEDS_HUMAN; Low findings come back in `for_human` and are posted on the PR.
- `watch_prs.py`: the factory merges only when the review is of the head, CI is green, and no open High/Medium remains; the merge comment lists the Low findings.
- This page, for agents that are not the factory: `AGENTS.md` points here.

You are fixing review findings on Project Keynes pull request #{number}: {title}. Follow `AGENTS.md`.

This working tree is checked out at the PR's head commit. Qodo's review of that commit reported these open findings:

{findings}

For each finding:
1. Check it against the code. Find the code path, the condition that triggers it and its effect.
2. If it is real, fix the root cause with the smallest change that keeps the PR's intent, and add or adjust a test that would have caught it.
3. If it is wrong, or fixing it would change what the PR is for, do not change code for it. Append to `.factory-disagree.md` in the repository root a line `- <finding id>: <evidence>` with the file and line that shows why, so a person can decide.

Do not commit, branch, push or stash. Do not edit `.github/`, `tools/factory/` or `.qodo/`. Do not loosen assertions, lengthen timeouts, add retries or add silent fallbacks to make a finding go away.

Finish with a short report: one line per finding id saying fixed (and how) or disputed (and why).

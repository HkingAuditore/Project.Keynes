You are fixing review findings on Project Keynes pull request #{number}: {title}. Follow `AGENTS.md`.

This working tree is checked out at the PR's head commit. Qodo's review of that commit reported these open findings:

{findings}

For each finding:
1. Check it against the code. Find the code path, the condition that triggers it and its effect.
2. If it is real, fix the root cause with the smallest change that keeps the PR's intent, and add or adjust a test that would have caught it.
3. If it is wrong, or fixing it would change what the PR is for, do not change code for it. Append to `.factory-disagree.md` in the repository root using exactly `- <finding id>: <evidence>`, one finding per line, the id exactly as given. Use the bare id as shown below. Include the file and line in the evidence: the factory dismisses the finding in Qodo with it, so dispute only what you are sure is wrong.

   ```text
   - abc123: example.gd:42 validates the value before use.
   ```

Do not commit, branch, push or stash. Do not loosen assertions, lengthen timeouts, add retries or add silent fallbacks to make a finding go away.

Leave `.github/`, `tools/factory/`, `tools/ci/`, `.qodo/`, `gdext/godot-cpp/` and `gdext/rebuild.sh` to a person. Leave changes under `Project/project-keynes/addons/dots_ext/bin/` to a person. The factory builds and checks the macOS libraries locally when native source changes.
A finding that asks for the Linux, Windows, Android or Web libraries to be rebuilt, or for export or `.gdextension` library selection to change, is outside what one ticket does: dispute it with that reason and change nothing for it.

Finish with a short report: one line per finding id saying fixed (and how) or disputed (and why).

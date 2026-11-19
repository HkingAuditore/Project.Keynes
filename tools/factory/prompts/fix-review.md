You are addressing review findings on a change for Project Keynes ticket #{number}: {title}. Follow `AGENTS.md`.

The change is already in this working tree{committed}. Qodo reported these open findings ({source}):

{findings}

For each finding:
1. Check it against the code. Find the code path, the condition that triggers it and its effect.
2. If it is real, fix the root cause and add or adjust a test that would have caught it.
3. If it is wrong, do not change code for it. Append to `.factory-disagree.md` in the repository root using exactly `- <finding id>: <evidence>`, one finding per line, the id exactly as given. Use the bare id as shown below. Include the file and line in the evidence so a person can decide.

   ```text
   - abc123: example.gd:42 validates the value before use.
   ```

Do not commit, branch, push or stash. Do not loosen assertions, lengthen timeouts or add retries to make a finding go away.

Leave `.github/`, `tools/factory/`, `tools/ci/`, `.qodo/`, `gdext/godot-cpp/` and `gdext/rebuild.sh` to a person. Leave the tracked native libraries to the factory. It rebuilds and checks both macOS libraries when native source changes.

Finish with a short report: one line per finding id saying fixed (and how) or disputed (and why).

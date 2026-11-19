You are repairing your own uncommitted fix on Project Keynes pull request #{number}: {title}. Follow `AGENTS.md`.

The working tree still holds the changes from the previous step. The factory ran the project's checks on them, and these checks failed although they pass on the PR head:

{feedback}

Make the smallest change that makes these checks pass while keeping the fixes already in the tree. Read the error lines first; a compile error or a count over a recorded limit usually points at one line.

Do not commit, branch, push or stash. Do not edit `.factory-disagree.md`. Do not loosen assertions, raise baselines or limits, lengthen timeouts, add retries or add silent fallbacks to make a check pass. If a check can only pass by reverting one of the fixes, revert that fix and say which finding it was.

Leave `.github/`, `tools/factory/`, `tools/ci/`, `.qodo/`, `gdext/godot-cpp/` and `gdext/rebuild.sh` to a person. Leave the tracked native libraries to the factory. It rebuilds and checks both macOS libraries when native source changes, so you do not need to build them.

Finish with a short report: one line per failed check saying what caused it and what you changed.

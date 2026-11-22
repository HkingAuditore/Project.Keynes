You are finishing a pending merge on Project Keynes pull request #{number}: {title}. Follow `AGENTS.md`.

The factory is merging `{base}` into the pull request branch. The merge is pending in the working tree and the factory commits it after the checks pass. After the merge these checks fail, although they passed on the PR head and on `{base}`:

{feedback}

Each side fits on its own, so the failure comes from the two changes together. Make the smallest change that makes these checks pass while keeping the intent of both sides. Read the error lines first; a count over a recorded limit usually points at one place, and moving a whole responsibility into a new file, as `docs/architecture/development-guide.md` describes, is the way to get under a size limit.

Do not commit, abort or reset the merge, branch, push or stash. Do not loosen assertions, raise baselines or limits, lengthen timeouts, add retries or add silent fallbacks to make a check pass.

Leave `.github/`, `tools/factory/`, `tools/ci/`, `.qodo/`, `gdext/godot-cpp/` and `gdext/rebuild.sh` to a person. Leave the tracked native libraries to the factory. It rebuilds and checks both macOS libraries when native source changes, so you do not need to build them.

Finish with a short report: one line per failed check saying what caused it and what you changed.

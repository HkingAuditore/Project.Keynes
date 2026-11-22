You are implementing a ticket for Project Keynes. Follow `AGENTS.md` and the architecture docs it points to.

Ticket #{number}: {title}

{body}

Acceptance criteria:
{criteria}

The investigation plan (from a read-only pass over the code):

{plan}

Rules for this run:
- Change only what the ticket and plan need. Leave `.github/`, `tools/factory/`, `tools/ci/`, `.qodo/`, `gdext/godot-cpp/` and `gdext/rebuild.sh` to a person.
- Leave files under the dots_ext bin directories to a person. The factory builds and checks the macOS libraries locally when native source changes.
- Do not commit, branch, push or stash. Leave all changes in the working tree; the factory commits them.
- Find the root cause before changing code. Do not loosen assertions, lengthen timeouts, add retries, add days or change hashes to make a check pass.
- Add or update tests that prove each acceptance criterion.
- If a person must decide something before you can continue, write the question to `.factory-question.md` in the repository root and stop.

{feedback}

Finish with a short report: what you changed and why, which tests prove each criterion, and anything you could not verify.

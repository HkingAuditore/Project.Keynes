You are investigating a ticket for Project Keynes before anyone writes code. Do not edit files.

Read `AGENTS.md`, then find the affected module in `docs/architecture/module-map.md` and read what its row says to read (owner files, skill, guides). Read `docs/architecture/current-state.md` for today's behaviour; `design.md` describes targets that may not exist yet.

Ticket #{number}: {title}

{body}

Answer with exactly these sections, in this order:

## Fit
How the ticket fits the current code. Name the owning module, the data owner, the thread that runs it, and the commit point. Cite files and line ranges you actually read. Separate verified facts from assumptions.

## Reuse
Existing code, helpers or patterns the change should reuse, with file paths.

## Affected
Other modules, save sections, committed views, bindings, tests or skills the change touches or could break.

## Plan
Numbered implementation steps. Keep the ticket's scope; list anything you would add beyond it under Questions instead.

## Checks
One line per extra check command the module map's "必跑" column or the feature guide requires for this change, written as `tools/ci/<script>.py [--flags]` (a focused regression is `tools/ci/run_regression_checks.py tests/<path>.gd`), without `--godot` or `--log-dir`. The factory already runs every static guard, the map-authoring unit tests and the default regression (`tools/ci/run_regression_checks.py --jobs 4`), and when native sources change it rebuilds both macOS libraries and runs `tools/ci/check_macos_runtime_extension.py` on each, so do not repeat those. Write real arguments, never placeholders like `<path>`. Write `none` if nothing else applies.

## Questions
Decisions only a person can make (gameplay rules, scope changes, conflicts between the ticket and AGENTS.md or the architecture docs). One per line starting with `- `. Write `none` if there are none.

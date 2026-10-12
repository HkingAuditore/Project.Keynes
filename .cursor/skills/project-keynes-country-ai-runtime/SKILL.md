---
name: project-keynes-country-ai-runtime
description: Develop, tune, review, or diagnose the Project.Keynes native foreign-country AI (layered utility AI) covering agendas/personalities/difficulty, research and era planning, default-tax controller, founding-card preferences, AI colonization intents, CountryAiEconomyDigest, worker/sync scheduling, PKSV pkai, decision log and country_ai_record CSV, headless soak acceptance, and offline sep-CMA-ES tuning. Use when changing country_ai_core.*, country_ai_runtime.*, economy_runtime_country_ai.cpp, world_ext_country_ai.cpp, country_ai_*.gd, default_country_ai.tres, tools/country_ai_tune, or when foreign countries behave wrongly (no research, bad taxes, failed expansion).
---

# Project.Keynes Country AI Runtime

The authoritative contract is `docs/cpp-dots-runtime/country-ai-runtime.md`. Read it before editing.
Also load `project-keynes-country-runtime` (Country authority, commands, PKCN),
`project-keynes-tax-runtime` (tax commands and fiscal settlement),
`project-keynes-family-runtime` (founding cards, expeditions) and
`project-keynes-headless-perf` (soak runs) as the task requires.

## Non-negotiable boundaries

- The AI is a **player-equivalent producer**. It only emits commands the player can submit
  (`ENQUEUE_RESEARCH`, `SET_RESEARCH_WEIGHTS`, `SET_RESEARCH_BUDGET`, `SET_TAX_DEFAULT`) with
  `COUNTRY_AI_PRODUCER_ID`, or ordinary `COMMAND_START_FAMILY_EXPEDITION` with
  `COUNTRY_AI_COLONIZATION_SEQUENCE_TAG`. Never add an AI-only state write, never mint resources,
  never let difficulty grant resources.
- Scope is `foreign_only`. The player handle is excluded and restored with `pkai`; an unarmed
  runtime never plans. Do not hand the player country to the AI.
- No fog cheating: colonization quotes are prechecked with the intent's visibility list.
- The core (`country_ai_core.*`) is pure integer: Q16, SplitMix64 `country_ai_mix(seed, handle,
  day, salt)`, no floats, clocks, Godot types or unordered iteration. PC/Android/WASM must agree
  bit-for-bit.
- Plan day D only from Country state committed through D-1 plus the last published digest.
  Commit AI memory only after the Country `commit_day` succeeds; on failure abort and keep memory.
- Worker and sync paths never plan the same day. The worker skips leftover sync AI packets
  (no replay) in all three enqueue loops. On a failed `plan_day`, remove the AI producer's pending
  commands and retry once so player commands are never dragged down.
- The digest is published at Economy publish, swapped via `shared_ptr`, and stays outside PKEC and
  the economy state hash. Do not read cold Dictionary overview APIs from the AI.
- `pkai` (PKAW wrapper with inner PKAI) is a required PKSV section after `pkfg` and before
  `journal`. A catalog hash mismatch is rejected (`catalog_hash_mismatch`). Changing
  `CountryAiMemory` layout requires a `PKAI_VERSION` bump.
- Append new inputs to the end of `CountryAiInput` / `INPUT_IDS`; include every new catalog field
  in `country_ai_catalog_hash` and validation.

## Workflow

1. Identify the module (strategy, research/era, tax, family preference, colonization, digest,
   scheduling, persistence, tuning) and read the matching section of the contract doc.
2. Edit native catalog IR and `country_ai_catalog.gd` together; keep `.tres` and hash in sync.
3. Run the native self-test `runtime_country_ai_self_test()` and
   `tests/runtime_country_ai_test.gd` (determinism, PROBE/ACTIVE equivalence, save/restore),
   plus `tests/game_save_roundtrip_test.gd`.
4. Build `cd gdext; scons platform=windows target=template_debug dev_build=no -j16`.
5. Soak with the headless perf runner:
   `run_headless_perf.ps1 -Days 3650 -ForeignCount 5 -CountryAi ACTIVE -Speed 200 -Label <label>`.
   Accept only when there is no economy fatal, no money/goods conservation failure, no country
   with long negative cash, milestones and territory grow, rejection rate is low and
   `plan_ms_max` stays well under 1 ms. Read `[headless-perf/country-ai]` and the per-country
   `[headless-perf/country-ai/country]` lines.
6. Update the contract doc (and `runtime-authority-matrix.md` / `references/system-map.md` when
   ownership or file layout changes) in the same change.

## Diagnosis hints

- Use `CountryAiFacade.decision_log` / `poll_new_decisions` and the `country_ai_record` CSV to see
  why a module skipped (`agenda_locked`, cooldown, reserve floor, no frontier, no families).
- `commands_rejected > 0` usually means a stale generation or an invalid research target; check
  the receipt reason before changing planner logic.
- Colonization failures (kind-7 receipts) trigger `colonize_failure_cooldown_days`; persistent
  failures point to quote/population thresholds, not to the core.
- The AI is the first thing that makes foreign countries tax and colonize. A conservation fault in
  an AI soak is usually a latent Economy bug on a rarely used path (see section 10 of the doc):
  fix the Economy path, never paper over it in the AI.
- A conservation error that first shows up at the research stage but has the shape "Country +q goods
  / −c cash, market unchanged", or "Country −q goods only", is a half-settled cross-domain leg
  (for example a cancelled expedition procurement), not a research bug. Temporarily log each
  `flush_country_economy_asset_commits` commit with its `settle_request_id`. A self-settled
  op 8/9 committed under a different settle id is the leak.

## Offline tuning

`tools/country_ai_tune/cmaes_tune.py` (stdlib-only sep-CMA-ES) over
`tools/country_ai_tune/param_space.json`. Candidates are written by
`Project/project-keynes/tools/country_ai_tune/apply_params.gd` and injected with
`PK_COUNTRY_AI_CATALOG`. Use `--baseline-only` to score the current catalog, `--resume` to
continue, `--write-back` to update `data/country/default_country_ai.tres`. Writing back changes the
catalog hash, so older saves are rejected on restore.

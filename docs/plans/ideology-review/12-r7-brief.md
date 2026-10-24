# 12 - R-7 brief (reviewer, 2026-10-23)

Goal (11-infra-first-roadmap §2): close the R-6 P1 leftovers, commit WIP, then R-5.
Worker path only. Parity frozen. No balance work.

All root causes below were reproduced by the reviewer against DLL 17:23:54.
Evidence lives in `tmp/reviewer/`.

## A. metric 68/69 read the wrong cohorts (C++, P1)

Both sites assume the cohorts of cell `c` are slots `c*COHORT_PAGE_SIZE..+63`.
The store is a paged list (`runtime_economy_population_store.h:15-16`,
`cell_first_page` / `page_next`). A full-repo grep finds exactly these two sites:

- `gdext/src/economy_runtime.cpp:5504` - metric 69 reserve denominator
  (`annual_income[country]`) - income attributed to the wrong country.
- `gdext/src/economy_runtime.cpp:17052` - metric 68 `cell.net_tax_burden_q16`.
  A cohort-free cell reads 6760 instead of `Q16_ONE` (X16 failure #3).

Fix: replace both loops with

```cpp
population_store().for_each_in_cell(cell, [&](int32_t slot) {
    // same body; for_each_in_cell already skips inactive slots
});
```

(`for_each_in_cell` at `runtime_economy_population_store.h:83`; already used at
`economy_runtime.cpp:159/615/6051/8304`.)

Regression test: a cell whose first page id != its cell id (settle cell 5 first,
then cell 0), assert metric 68 for both cells, `Q16_ONE` on a cohort-free cell, and
metric 69 income lands on the owning country.

## B. ideology_x16_worker_test failures 1-2 are a test bug

`land_value` (era 5) and `tax_holiday` (era 8) are rejected by the pod at EQUIP
because the test never satisfies draw requirements. After "equip": `slots_used=0`,
`list_modifiers` empty (`tmp/reviewer/x16_probe.txt`). Modifier -> X16 itself works
(`land_tax_reform` reads 1.30 on the worker).

Fix in `tests/ideology/ideology_x16_worker_test.gd`:

- move `_grant_draw_gates` (`ideology_card_content_worker_test.gd:777`) into a
  shared helper script and call it in `_equip` (`:295`) before DISCOVER;
- after EQUIP assert `slots_used >= 1` and that the modifier row appears; fail fast;
- `_wait_epoch_freeze` (`:335`, 60 days) -> at most 5 days with `epoch_days=1`.

Accept: 26/0 twice in a row, 0 SCRIPT ERROR, no Application event Id 1000;
`ideology_effect_metric_publish_test` and `ideology_mechanism_matrix_test` stay green.

## C. runtime_country_identity_mismatch_test fixture

Measured (`tmp/reviewer/identity_probe*.txt`):

1. `_capture_save` configures `cell_count=1` but `create_entities(6)` -> opinion
   never publishes (revision 0), pod never ready. With `create_entities(1)` the test
   reaches 15 checks.
2. `_restore_and_start` configures country/economy with 6 cells against a 1-cell
   save -> `ecp2_resource_wire_invalid` (`economy_runtime_persistence.cpp:1876`).
   Restore must use the capture's cell and entity counts.
3. `_foreign_country_section` flips the last 16 bytes -> rejected earlier by
   `runtime_bundle_checksum_failed`, never reaching
   `verify_deferred_country_identity` (`economy_runtime_persistence.cpp:1812`).
   Produce a valid-but-different country section (other generation / business
   hash, checksums recomputed; a test hook is fine).

Assert: mismatch -> fault `economy_country_identity_mismatch*`; the normal restore
starts and commits days.

## D. P1-b "restarted worker does not commit" is a fixture bug

`tmp/reviewer/p1b_rootcause.md`. Three runs, `C0_ONLY_CARD=pit_dwelling
C0_SAVE_ROUNDTRIP=1`:

| run | change | result |
|---|---|---|
| 1 | none | 29/1, restart fails `economy_country_identity_mismatch` (expected gen 19, live gen 1) |
| 2 | + `restore_country_runtime_checkpoint(saved.country_pkcn)` | restart ok, 33/3: 16->16, row gone |
| 3 | + restart mask `0x10` -> `0xFFF` | **33/0**, stat 0.95 -> 0.95, no crash |

Fix in `ideology_card_content_worker_test.gd::_test_save_roundtrip`:

- after `restore_runtime_bundle` succeeds call
  `ext.restore_country_runtime_checkpoint(saved.country_pkcn)` and assert ok -
  production does this through the pkcn provider (`game_save_coordinator.gd:1104`);
- restart with `authoritative_domain_mask: 0xFFF` (`:572`), as production does;
- delete the "layer 3/4 still open, stays red on purpose" comment block.

Do NOT touch `verify_deferred_country_identity`; its rejection was correct.
Accept: 33/0 twice; then the roundtrip on all 10 published worker cards.

## E. Commit

After A-D: branch `codex/ideology-wip-1023`, `git add` only ideology / effect /
economy / runtime sources, their tests and `docs/plans/ideology-review/`. Not
`tools/audio`, `scripts/audio`, `tests/audio`, `docs/audio`.

## F. R-5 prerequisite: a worker acceptance for cell-scope cards

Dry run (`tmp/reviewer/x1plain_dryrun.md`, outputs redirected, real files
untouched). Adding `X1_PLAIN_SWITCH`:

- `cards_published` 93 -> 100 of 105, programs 114 -> 191;
- 7 new cards: arcology, basic_income, circular_economy, department_store,
  gig_economy, offshore_drilling, welfare_state;
- 16 already-published cards switch from country rows to cell rows (selector 12 +
  tags): agrarian_reform, assembly_line, automation_line, carbon_market,
  colonial_plantation, financialization, fire_keeping, free_trade, gene_editing,
  heaven_human, manufactory_regulation, maritime_insurance, nuclear_power,
  ocean_company, open_ports, scholar_office.

Every cell stat used has a C++ reader. But no worker test reads a cell-scope
result: `ideology_card_content_worker_test._read` only evaluates domain COUNTRY
(`:1017`), and its `CARDS` table is hand-written country rows.

Build a table-driven worker test over `card_expectations.json` rows with
`scope == "cell"`: 0xFFF worker, one tagged and one untagged owned cell, assert the
tagged cell moves in the right direction, the untagged cell stays at base, and
unequip restores. One card per process. When all 23 pass, add `X1_PLAIN_SWITCH` to
`AVAILABLE_CAPABILITIES`, regenerate, record the behaviour change and the catalog
hash change (old saves fail closed) in 05. Then X1-b (09 §7.11).

F implementation notes (reviewer, checked against the tree):

- Read a cell result with
  `ext.evaluate_modifier_stat(2 /*ECONOMY*/, 0, cell, stat, base)` - cell rows bind
  GROUP scope on the ECONOMY domain, exactly what Economy reads at
  `economy_runtime.cpp:6772` (`effective_value(ECONOMY, stat_id, 0, scope_id)`).
  Domain COUNTRY (what `_read` uses) always returns base for these rows.
- Choose the tagged cell from `get_ideology_effect_instance_report(handle)`
  `target_handles` (cells the selector actually resolved), and the untagged cell as
  any owned cell not in that list. Do not hand-build tags; a card whose list is empty
  after 5 days must FAIL with "fixture never produced <tags>", not be skipped.
- Tags the 23 cards need (dry-run count): coast 16, metropolis 15, unemployed 10,
  sector.manufacturing 9, grain/specialized/abundant/chained/sector.agriculture/
  market 6 each, diversified 4, tundra 4, specialized_high 3, sector.energy 3,
  sector.knowledge 3, settlement 3. If the real 16x12 MapGenerator map lacks some
  (tundra, unemployed), use a second fixed seed or a bigger map - not a fake tag.
- All 23 cards' cell rows are selector 12 constant rows. Cell definitions are ADD
  terms with `add = 1.0` and the command magnitude as the effect (generator
  `:264-268`; `.cut` twins subtract), and `effective_value` is
  `(base + add) * factor` (`modifier_runtime.cpp:1415`). So with base 1.0 the
  tagged cell must read `1.0 + value` (value is negative for cuts), the untagged
  cell 1.0. Cell rows in the json carry no `operation` field - do not default to
  multiply.
- Test the dry-run catalog (`tmp/reviewer/x1dry/run.py on` writes it to
  `tmp/reviewer/x1dry/`) or a local switch env var; do not flip the real switch first.

## G. Country-scope ramp carrier (11 §4.5) - do after F, before X5

Unblocks the 2 `reserve_ratio` staged cards (`excise`, `progressive_tax`) and any
future "每有 N 个 X，全国 +y%" clause. Reviewer traced it against the current tree;
the runtime already supports most of it.

Already there (do not rebuild):

- target resolve: `ideology_runtime.cpp:1502` maps `target_domain == 3` to the
  country handle;
- Effect -> Modifier: `effect_runtime.cpp:1134` maps domain 3 to Modifier COUNTRY;
- adapter scope ENTITY for domain 3 on both paths
  (`native_simulation_host.cpp:10069`, EffectRuntime native ideology branch);
- metric 69 is a country value sampled per cell via `cell_country_slot(cell)`
  (`economy_runtime.cpp:17088`); same for 47-49 / 55-67;
- Ramp emits READ_METRIC / MIN / MUL_Q16 and the metric mask already unions
  READ_METRIC ids; a diagnostic program `v1_granary_belt` (generator `:1339`)
  already runs domain 3 + selector 0.

Missing (the whole job):

1. **Metric sampling skips domain 3.** `ideology_runtime.cpp:1875` drops every
   activation with `target_domain != 2 && != 5`, so a country-domain ramp reads 0.
   Fix: for domain 3, sample `_economy_runtime->country_anchor_cell(country_slot)`
   (country metrics are identical on every owned cell) and key the cache by that
   cell. Worker mode reaches the same reconcile through
   `step_ideology_instance_refresh`, so one fix covers both paths - prove it with
   the worker test below.
2. **Generator rejects the program.** `generate_ideology_catalog.py:4757-4761`
   requires `ideology.city.*` keys. Allow `target_domain == DOMAIN_COUNTRY` programs
   to name a new `ideology.country.*` definition set, and hard-fail:
   - a domain-3 program that names an `ideology.city.*` key (and vice versa);
   - a domain-3 Ramp reading a `cell.*` metric (meaningless at the anchor);
   - `per * cap >= 1.0` on a `.cut` MULTIPLY definition (see 3).
3. **Definition family.** One definition per country stat that ramps, e.g.
   `ideology.country.population.death_factor.cut` and
   `ideology.country.construction.cost_factor.cut`: a single MULTIPLY term with
   `factor = 0.0`, so `scaled_factor` gives `1 - magnitude`
   (`modifier_runtime.cpp:765`); gain twins use `factor = 2.0` (`1 + magnitude`).
   Magnitude 1.0 would make the bucket exactly zero - hence the lint in 2.
   Sync `stat_key_families.gd`; catalog hash changes, old saves fail closed.
4. **Move the clauses.** In `excise` L3 and `progressive_tax` L1-L3, replace the
   `RampTerm` rows in `LEVEL_TERMS` with a domain-3 `prog(...)` in `LEVEL_ROWS`
   (selector `SEL_OWNER`, `Ramp(metric="country.treasury_reserve_ratio_pct", ...)`,
   one command naming the `.cut` definition). Keep the existing
   "RampTerm on a published card is a hard error" lint.
5. **Capability.** Add `reserve_ratio` to `AVAILABLE_CAPABILITIES` only after the
   worker test passes.

Worker test (`tests/ideology/ideology_country_ramp_worker_test.gd`, 0xFFF):
equip `progressive_tax`; set reserve so metric 69 = 0, 3, 20; assert
`country.population.death_factor` = 1.00 / 0.97 / 0.94 (L1 cap 6); unequip -> 1.00;
save roundtrip keeps the value. One card per process.

Accept: generator tail `cards_published` +2 and staged list without
`reserve_ratio`; test N/0 twice; `ideology_effect_metric_publish_test` and
`ideology_card_content_worker_test` unchanged.

## Report format

Per item: files:lines changed, raw last test line, DLL timestamp, generator tail,
event-log check. Unfinished items: "not done + blocker".

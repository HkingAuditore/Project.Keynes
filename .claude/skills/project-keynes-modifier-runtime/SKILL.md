---
name: project-keynes-modifier-runtime
description: Implement, review, extend, or diagnose Project.Keynes native Modifier Runtime work, including ModifierStore/catalog/facade, handles, scope and lifecycle, climate/country/economy/gameplay integrations, explain and journal APIs, PKCM/PKCN/PKEC/PKGP persistence, tests, performance, and documentation sync. Use for any modifier stat, definition, command, scheduler, domain consumer, save schema, or modifier-removal bug.
---

# Project.Keynes Modifier Runtime

Use this skill for every Modifier Runtime change. Also load:

- `cpp-dots-runtime-development` for C++/SoA/build/performance work.
- `project-keynes-runtime-architecture` for scheduler, authority, bridge, or docs changes.
- `project-keynes-country-runtime` for Country handles, PKCN, or country snapshots.
- `project-keynes-economy-runtime` for building output, conservation, or PKEC.
- `project-keynes-tax-runtime` for tax stat generation, frozen effective rates, fiscal behavior,
  or tax catalog migration.
- `project-keynes-game-flow-runtime` for PKSV providers and restore order.

## Grounding

Read `docs/cpp-dots-runtime/native-modifier-runtime.md` first. Then read only the
reference relevant to the task:

- Data structures, catalog, handles, formula: `references/architecture-and-data.md`.
- Climate/country/economy/gameplay consumers: `references/domain-integration.md`.
- Scheduler, save, tests, performance: `references/scheduling-save-and-verification.md`.

Inspect current code before editing:

- `gdext/src/modifier_runtime.*`
- `gdext/src/world_ext_modifier.cpp`
- `gdext/src/world_ext.h`
- `gdext/src/world_ext_bind_methods.cpp`
- `Project/project-keynes/scripts/modifier/`
- `Project/project-keynes/scripts/simulation/systems/modifier_daily_system.gd`
- the affected domain consumer and save provider
- for economy changes, `Project/project-keynes/scripts/economy/MODULE.md`

## Non-Negotiable Invariants

- Never overwrite authoritative base values.
- Always compute `clamp((base + sum(add)) * product(factor), min, max)`.
- Normalize subtract to negative add and divide to reciprocal factor; reject zero divide.
- Preserve generation-safe handles and exact single-instance removal.
- Query only global, one group, and entity buckets; never fan out parent modifiers.
- Keep all four domain stores isolated. Cross-domain effects use frozen published values.
- Never register cash, goods, population, or another conserved ledger as a modifier stat.
- Workers and hot loops use dense IDs/POD/Q16 caches only: no strings, Variant,
  Godot Object calls, or per-entity allocation.
- Consumers never mutate stores. Commands produced during consumption wait for the next
  safe boundary.
- Country building-family and exact-building-type factors are configuration-resolved and epoch-frozen;
  actual production and target forecasts must multiply the same dense Q16 factors.
- Removal changes future calculations only; never rewind simulation history.
- Persist stable keys and normalized terms, never process-local dense IDs.
- Persist Q16 instance magnitude. Add terms scale linearly; factor terms interpolate from one before
  stack power: `1 + (factor - 1) * magnitude`.

## Change Workflow

1. Classify the change: catalog/core, command/facade, scheduler, domain consumer, save,
   explain/journal, or performance.
2. Trace authority and base/effective separation in code and the primary document.
3. Update catalog and native compile validation before adding a consumer.
4. Route every production and prediction calculation through one domain helper.
5. Freeze parent/domain factors at the existing daily or epoch boundary.
6. Update persistence and strict schema rejection if identity or instance state changes.
7. Add focused math/lifecycle/handle/scope/domain/save tests.
8. Update the primary document, affected architecture docs, this skill, and relevant reference.
9. Run `scripts/verify_modifier_runtime.ps1`; use `-Build` and `-Godot` for final validation.

## Diagnosis Workflow

For "value does not recover after removal":

1. Confirm the remove command result and handle generation.
2. Inspect journal for remove/reject/expire/cleanup.
3. Use `explain_stat` to separate base, add, factor, clamp, and remaining instances.
4. Verify `modifier_daily` ran at the same-day deadline boundary; inspect budget skip reports.
5. Verify the consumer reads the current frozen snapshot and does not cache effective as base.
6. Verify scope ID and parent group generation did not change.
7. For economy, check cached BuildingGroup factor refresh at epoch/restore/topology change.
8. For climate, distinguish restored radiative target from non-rewound temperature history.

## Current Compatibility Limits

- Treat `value_conversion` as documentation only until it is added to the native packed catalog;
  economy consumers must explicitly convert to Q16.
- Do not rely on `persistable=false`; the current serializer persists every active instance.
- Restore requires an exact catalog hash and exact definition version/normalized terms. Append-only
  catalog compatibility and definition aliases require an explicit migration implementation.
- Gameplay archetype labels do not yet enforce per-archetype stat allow-lists.

## Delivery Gate

Do not claim completion unless code, focused tests, docs, and this skill agree. Do not claim
the 3 percent median / 5 percent p95 target without same-machine baseline and after data.
Run `quick_validate.py` after editing this skill. Forward-test in isolated context when agent
delegation is available; otherwise report that gate as not executed.

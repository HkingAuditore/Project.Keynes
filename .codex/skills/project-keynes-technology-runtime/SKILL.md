---
name: project-keynes-technology-runtime
description: Guide Project.Keynes technology-tree development and review across the authoritative TechnologyCatalog, country-owned research state and queues, technology-points economy and government procurement, technology Modifier effects, research buildings and professions, GraphEdit workspace, NewGameConfig, PKCN/PKEC saves, performance, and validation. Use when changing technology definitions or prerequisites, tech.* unlock tags, research allocation or milestones, technology_points production/consumption/trade, research institutions or technology professions, research procurement, technology Modifier stats, technology UI, technology save/restore, GM reveal/grant behavior, or related tests and documentation.
---

# Project.Keynes Technology Runtime

Treat the technology system as a coordinated catalog/country/economy/modifier/UI feature, not as an
independent runtime. Preserve one authority for each kind of state.

## Ground first

Before editing, inspect the affected source and read the relevant references:

- Read [architecture-and-contracts.md](references/architecture-and-contracts.md) for authority,
  catalog compilation, research state, daily ordering, procurement, Modifier activation, UI, or saves.
- Read [extension-and-validation.md](references/extension-and-validation.md) for adding technologies,
  professions, research buildings, technology-points inputs, public APIs, tests, builds, or benchmarks.
- Read the repository's `docs/cpp-dots-runtime/technology-tree-runtime.md` when present; it is the
  project-facing current-state document and must remain synchronized with runtime contract changes.

Also use `civ-grounded-development` for repository changes. Add
`project-keynes-country-runtime`, `project-keynes-economy-runtime`,
`project-keynes-modifier-runtime`, `project-keynes-runtime-architecture`,
`cpp-dots-runtime-development`, `project-keynes-ui-art-direction`, or
`project-keynes-game-flow-runtime` when the change crosses those domains.

## Required workflow

1. Identify which authority owns every changed field or behavior.
2. Inspect catalog data, C++ storage/consumer, bindings/facade, save schema, UI snapshot, focused tests,
   and current documentation before editing.
3. Reuse the existing country, economy, Modifier, and GraphEdit paths. Notify the user before creating
   any new runtime subsystem.
4. Resolve stable string IDs during compilation or command packing; keep simulation hot loops dense,
   numeric, allocation-free in steady state, and deterministically ordered.
5. Preserve atomic command validation, the economy-cycle boundary, exact cash/goods conservation,
   pending-to-completed activation ordering, and fog-of-war non-disclosure.
6. Update focused tests, save compatibility behavior, repository documentation, and this skill whenever
   a contract changes.
7. Run the bundled verifier, relevant broader runtime tests, required builds, and `git diff --check`.
   Report any gate that was not run.

## Non-negotiable boundaries

- Do not introduce an independent `TechnologyRuntime`.
- Do not let `EconomyCatalog` synthesize technology IDs; `TechnologyCatalog` is authoritative.
- Do not store technology strings in runtime hot paths or dense progress for every
  `country × technology`.
- Do not move research queues, progress, discovery, completion, policy, or technology treasury
  authority out of `NativeCountryRuntime`.
- Do not bypass market settlement by sending research-building output directly to the country treasury.
- Do not let procurement precede private consumption or violate merchant payment, price signals, or
  cash/goods conservation.
- Do not spill an empty or blocked domain's allocation into another domain; preserve it as deferred
  stock until policy or queue state releases it.
- Do not expose completion tags before permanent `UNIQUE_SOURCE` technology Modifiers apply
  successfully, and do not let `GRANT_TECHNOLOGY` bypass this path.
- Do not use Modifiers to directly create/delete cash, inventory, or technology points.
- Do not reveal unknown technology names, effects, prerequisites, connection labels, tooltips, search
  text, or accessibility text.
- Restore PKCN before PKEC. Reject unsupported legacy technology-tree saves explicitly rather than
  silently defaulting state.
- Do not add taxes, cross-country technology trade, research diplomacy, or AI research policy as
  incidental scope.

## Research-signal prerequisite contract

Technology prerequisites are no longer limited to `prerequisite_ids`. `TechnologyCatalog` compiles
authoring-side `ResearchCondition` / `ResearchPredicate` data into postfix dense IR; legacy
`prerequisite_ids` remain the structural compatibility gate. `NativeCountryRuntime` evaluates the
IR from its frozen numeric state, never from Resources, strings, or Dictionaries.

The currently active v1 operators are `TECH_COMPLETED`, `SIGNAL_PRESENT`, `SIGNAL_COUNT`,
`ALL_OF`, `ANY_OF`, `AT_LEAST`, and `NOT`. Treat `COUNTRY_FLAG`, `COUNTRY_STAT`,
`BUILDING_COUNT`, `CURRENT_STATE`, `EVENT_OCCURRED`, `SEQUENCE`, and `WITHIN_DAYS` as declared
authoring surface only until a packed native source and focused tests are added; do not silently
compile them as an always-true condition.

`ResearchSignalCatalog` owns stable IDs and catalog metadata for Bio, resource, landform, weather,
and breakthrough signals. A technology may only use a dense signal ID resolved at catalog compile
time. Permanent map discoveries are country-local: they block/unblock queue heads while preserving
their existing progress, and must not be treated as goods inventory or as cross-country technology
transfer. `pending` technology activation remains unchanged and must not re-check a gate.

## Verify

From the repository root run:

```powershell
& "C:\Users\hkinghuang\.codex\skills\project-keynes-technology-runtime\scripts\verify_technology_runtime.ps1" -GodotExe "<godot_console.exe>"
```

Add `-Build` to compile the debug GDExtension first. Run the 50-day headless performance workflow for
changes to research or procurement hot loops and compare country/economy/modifier timing plus
population, money, goods, and technology conservation.

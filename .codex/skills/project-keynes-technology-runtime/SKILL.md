---
name: project-keynes-technology-runtime
description: Guide Project.Keynes technology-tree development and review across the authoritative TechnologyCatalog, country-owned research state and queues, research signals, technology-points economy and government procurement, technology Effect/Modifier activation, research buildings, static DAG UI, NewGameConfig, PKCN/PKEF/PKTR/PKEC saves, performance, and validation. Use when changing technology definitions or prerequisites, tech.* unlock tags, research allocation or milestones, technology_points production/consumption/trade, research institutions, research procurement, technology Modifier stats, technology UI, technology save/restore, GM reveal/grant behavior, or related tests and documentation.
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
3. Reuse the existing country, economy, Modifier, and self-drawn technology-tree paths. Notify the user before creating
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
- Keep `Project/project-keynes/data/technology/technology_network.json` as the sole authoring source.
  `TechnologyCatalog` remains the sole compiled/runtime authority; do not restore parallel row constants
  or route-based Modifier inference.
- Do not store technology strings in runtime hot paths or dense progress for every
  `country × technology`.
- Do not move research queues, progress, discovery, completion, policy, or technology treasury
  authority out of `NativeCountryRuntime`.
- Do not bypass market settlement by sending research-building output directly to the country treasury.
- Do not let procurement precede private consumption or violate merchant payment, price signals, or
  cash/goods conservation.
- Do not spill a blocked domain's allocation into another domain; preserve it as deferred stock
  until policy or queue state releases it. Empty-domain shares remain in the treasury and are
  reallocated by current weights on later research days.
- Do not expose completion tags before permanent `UNIQUE_SOURCE` technology Modifiers apply
  successfully, and do not let `GRANT_TECHNOLOGY` bypass this path.
- Do not use Modifiers to directly create/delete cash, inventory, or technology points.
- Resolve exact-building technology stats at catalog/configuration time and freeze their country×type
  Q16 factors at the economy epoch boundary; never look up `building_id` strings in production loops.
- Do not reveal unknown technology names, effects, prerequisites, connection labels, tooltips, search
  text, or accessibility text.
- Keep player-facing Chinese names, effect summaries, and route labels in the
  `public_definitions()` presentation layer. Translation-only edits must not change stable `tech.*`
  IDs, compiled native catalog rows, or exact catalog identity.
- Restore PKCN before PKEC. PKCN v11, PKEF v9 and PKTR v5 use exact schema/catalog identity and
  return `catalog_hash_mismatch` for older trees rather than silently defaulting state.
- Do not add taxes, cross-country technology trade, research diplomacy, or AI research policy as
  incidental scope.

## Research-signal discovery contract

`hard_prerequisite_ids` contains only irreplaceable core knowledge. Authoring-side
`research_condition` is forbidden: the compiler must reject it when non-empty. Optional
`research_routes[]` packages contain stable route IDs, Chinese names, route types, explanations and
conditions. Formal eligibility is every hard prerequisite completed AND (no route
package OR one complete route). Era-milestone nodes additionally require the
previous-era milestone. A route may substitute for professional knowledge, but
never for core principles or for an era-milestone node's previous-era gate. Geography, resources, contact and
practice signals can reveal a problem; development, institutional and practice signals can also be
part of a route when they express the capability used to solve it. Reveal and route conditions must
not reuse the same signal atom.

The currently active v1 operators are `TECH_COMPLETED`, `SIGNAL_PRESENT`, `SIGNAL_COUNT`,
`ALL_OF`, `ANY_OF`, `AT_LEAST`, and `NOT`. Treat `COUNTRY_FLAG`, `COUNTRY_STAT`,
`BUILDING_COUNT`, `CURRENT_STATE`, `EVENT_OCCURRED`, `SEQUENCE`, and `WITHIN_DAYS` as declared
authoring surface only until a packed native source and focused tests are added; do not silently
compile them as an always-true condition.

`ResearchSignalCatalog` owns stable IDs and catalog metadata for Bio, resource, landform, weather,
and breakthrough signals. Map occupancy (`cell.bio_occupancy_bits`) is the current presence of a
species and can change; country research signals are permanent knowledge that a country has seen
that species. A technology may only use a dense signal ID resolved at catalog compile time.
Vision submits landform/resource CSR plus current occupancy on first exploration, and occupancy
0→1 on already-explored cells. Local extinction does not delete evidence. Trade still yields
`contact.*` only. Permanent discoveries do not block an already revealed queue head and must not
be treated as goods inventory or cross-country technology transfer. `pending` technology
activation remains unchanged and must not re-check a gate.

## Verify

From the repository root run:

```powershell
& "C:\Users\hkinghuang\.codex\skills\project-keynes-technology-runtime\scripts\verify_technology_runtime.ps1" -GodotExe "<godot_console.exe>"
```

Add `-Build` to compile the debug GDExtension first. Run the 50-day headless performance workflow for
changes to research or procurement hot loops and compare country/economy/modifier timing plus
population, money, goods, and technology conservation.

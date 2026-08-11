---
name: project-keynes-country-runtime
description: Guide Project.Keynes native country runtime work covering country identity and handles, territory CSR, country-level technology, cash and goods treasury, tax policy/defaults/overrides, CountryDailySystem commands, the native economy bridge, PKCN/PKEC save ordering, Inspector summaries, performance, and validation. Use when changing country_runtime.*, world_ext_country.cpp, CountryFacade, country scheduling, country tax policy or treasury, country/economy ownership or conservation, country save/restore, or country-facing UI and tests.
---

# Project.Keynes Country Runtime

Treat `NativeCountryRuntime` as the only authority for country identity, territory, country technology,
and treasury. Keep GDScript as orchestration, command packing, stable-ID resolution, and read-only UI.

## Ground first

Before editing, inspect the affected code and read only the relevant references:

- Read [architecture-and-data.md](references/architecture-and-data.md) for storage, handles,
  invariants, commands, queries, or DataCore work.
- Read [economy-bridge-and-conservation.md](references/economy-bridge-and-conservation.md) for
  technology gates, treasury transfer, frozen economy cycles, audits, or state hashes.
- Read [scheduling-save-and-verification.md](references/scheduling-save-and-verification.md) for
  `country_daily`, barriers, PKCN/PKEC, tests, builds, or performance work.

Also use `project-keynes-runtime-architecture`, `project-keynes-economy-runtime`, and
`cpp-dots-runtime-development` when available. Preserve the dirty worktree and reuse existing
country/economy paths before introducing another subsystem.

Load `project-keynes-tax-runtime` for tax commands, profession/good/building overrides, fiscal cash
reservation, tax policy snapshots, Modifier-effective rates, subsidy history, or tariff placeholders.

## Required workflow

1. Identify the authority and invariant being changed.
2. Inspect C++ storage, bindings, GDScript facade/system, save schema, tests, and current docs.
3. Keep hot paths dense/SoA and numeric; resolve strings and Dictionaries before loops.
4. Stage commands, validate the whole atomic batch, then publish once.
5. Preserve the economy frozen-country epoch and exact money/goods conservation.
6. Update code, tests, docs, and this skill together when a contract changes.
7. Run the bundled verifier, focused tests, debug/release builds, and `git diff --check`.

## Non-negotiable boundaries

- Do not restore per-cell technology or an economy-owned global treasury.
- Mirror only `cell.country_slot` into DataCore/MapData; do not put country strings, treasury,
  technology bitsets, or CSR into `HexCell` or per-cell components.
- Do not allow water ownership, duplicate territory, active zero-territory countries, or stale handles.
- Do not let mid-cycle country changes enter an already frozen economy cycle.
- Do not let economy start a new frozen cycle while due country commands remain uncommitted.
- Restore PKCN before PKEC and reject legacy countryless PKEC schemas precisely.
- Restore PKFG after PKCN, and never store exploration progress inside PKCN.
  Vision and country borders only consume `cell.country_slot`; they are not
  country authority. See `docs/cpp-dots-runtime/vision-fog-and-borders.md`.
- Keep `country_committed` as the single broadcast for territory change. Visual
  consumers subscribe to it; do not add a second notification path.
- Add taxation only through the dedicated tax/fiscal contract: country owns policy and treasury;
  economy owns taxable events and fiscal escrow. Do not add research growth, diplomacy, war,
  country AI, deletion, or technology revocation as incidental behavior.

## Research-signal evidence

Country discovery evidence is native authority. `DISCOVER_COUNTRY_SIGNAL` accepts an already-dense
signal ID plus source cell/kind, stages it with ordinary country commands, and deduplicates by
`(country, signal, cell)`. Store permanent membership in a compact country×signal bitset and only
store count/first-day/last-day/first-cell in sorted sparse evidence; never create a full
country×signal-value matrix or write these fields into `HexCell`/DataCore.

Vision is not country authority. Its player-fog transition only submits the command at the next
country boundary. `CountryFacade.research_signal_snapshot()` and country events are cold-path/UI
facades. PKCN v11 persists the signal/catalog/content/Trigger identity, bitset, observed-cell dedupe
keys, and sparse evidence; restore rejects older schemas and catalog mismatch as
`catalog_hash_mismatch`.

## Verify

From the repository root run:

```powershell
& .\.codex\skills\project-keynes-country-runtime\scripts\verify_country_runtime.ps1
```

Use `-Build` for debug/release GDExtension builds and `-Godot` when a Godot executable is available.
Report unrun gates explicitly, including performance gates that need the release benchmark scene.

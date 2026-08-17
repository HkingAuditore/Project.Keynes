# Technology Extension and Validation

## Add or change a technology

1. Edit the sole authoring source at
   `Project/project-keynes/data/technology/technology_network.json`, normally through the deterministic
   `tools/build_technology_network_authoring.gd` workflow. `TechnologyCatalog` is the compiler, not a
   second hand-maintained catalog.
2. Preserve every existing stable ID unless the user explicitly authorizes a compatibility break; the
   360-node rebuild is an intentional exact-hash break with no migration.
3. Define era, domain, cost, core prerequisites, research routes, milestone flags/candidates, public summary, route tags,
   unique Effect recipe and explicit Modifier terms together.
4. Keep prerequisite and route technology references acyclic and era-monotonic. Verify each milestone has eight
   candidates, requires four, and remains reachable across the resource-poor, inland, low-trade,
   low-urbanization and specialist-industry scenarios.
5. Add or update the generated permanent Modifier definition and a real domain consumer when adding a
   numerical effect. A definition with no consumer is incomplete.
6. Update Good/Building/Resource bindings and compile `EconomyCatalog`; professions must not carry a
   direct `tech.*` unlock.
7. Consider catalog-hash and old-save behavior deliberately.
8. Update focused catalog, reachability, activation, UI, and save tests plus the repository technology
   document.

Do not add a second catalog, fallback taxonomy, or string-based runtime lookup.

## Add research professions or institutions

- Add profession resources under `data/economy/professions/`.
- Set `profession_class_id = "technology"` for technology workers.
- Use `scholarly_household` for early knowledge workers and `technical_household` only where modern
  technology-points consumption is intended.
- Add research institutions under `data/economy/buildings/` as normal `industrial` buildings.
- Keep them in `upgrade_family_id = "research_institution"` with monotonic tiers.
- Express workers, inputs, output, unlock tags, sector, construction cost, and soft-input penalties in
  content resources.
- Verify actual employment and required inputs drive output; do not special-case production in C++.

## Add technology-points consumption

For households, use the existing need/bundle price-elastic purchase path with no forced minimum. For
buildings, add an explicit ordinary input recipe and encode the intended soft shortage penalty through
the existing required-fraction/input semantics. Check:

- normal cost share remains in the intended range;
- complete absence lowers output by the requested percentage but does not stop production;
- candidate/category arrays stay aligned;
- goods production/market/in-transit/treasury/private/research conservation remains exact.

## Change research commands or snapshots

Update all layers together:

1. C++ command enum, validation, staged state, commit, and report/event behavior.
2. WorldExt binding.
3. `CountryFacade` stable-ID packing.
4. `CountryViewModel` and `TechnologyWorkspace` read-only model/command submission.
5. PKCN serialization if authoritative state changes.
6. Deterministic command, queue, state-hash, round-trip, and UI tests.

Validate the whole command batch before commit. Publish once. Never let UI dictionaries become
simulation authority.

## Focused test matrix

Run from `Project/project-keynes` with a Godot console executable:

```powershell
& "<godot_console.exe>" --headless --path . --script res://tests/technology_catalog_test.gd
& "<godot_console.exe>" --headless --path . --script res://tests/technology_network_design_test.gd
& "<godot_console.exe>" --headless --path . --script res://tests/technology_content_binding_audit_test.gd
& "<godot_console.exe>" --headless --path . --script res://tests/technology_research_runtime_test.gd
& "<godot_console.exe>" --headless --path . --script res://tests/technology_breakthrough_trigger_test.gd
& "<godot_console.exe>" --headless --path . --script res://tests/technology_procurement_runtime_test.gd
& "<godot_console.exe>" --headless --path . --script res://tests/technology_modifier_activation_test.gd
& "<godot_console.exe>" --headless --path . --script res://tests/technology_pending_activation_scheduler_test.gd
& "<godot_console.exe>" --headless --path . --script res://tests/technology_workspace_smoke_test.gd
```

Broader gates for cross-domain changes:

- `country_runtime_test.gd`
- `economy_rolling_runtime_test.gd`
- `economy_trade_runtime_test.gd`
- `modifier_runtime_test.gd`
- `new_game_config_test.gd`
- `gm_panel_view_model_test.gd`

Run GDExtension builds from `gdext`:

```powershell
scons platform=windows target=template_debug -j4
scons platform=windows target=template_release -j4
```

Run `git diff --check` from the repository root. Treat focused test assertions as authoritative when
Godot emits shutdown-only Dummy renderer RID/resource warnings; still report those warnings and do not
ignore crashes or failed assertions.

## Performance and conservation gates

For storage or command changes, run `country_runtime_bench.gd` with 512 countries and a 4096-tech
capacity. Keep additional country memory below 8 MB, avoid daily stable-state heap allocations, and
avoid string parsing in hot loops.

For research/procurement/economy-loop changes, run the project's 50-day headless performance workflow.
Require:

- exactly the requested number of CSV data rows;
- no fatal simulation error;
- population, money, goods, and technology ledger failures equal zero;
- median combined Modifier/country/economy cost no more than 3% above a comparable baseline;
- p95 no more than 5% above baseline.

Do not compare timings across materially different hardware, build targets, map sizes, seeds, or content
catalogs without labeling the comparison invalid.

## Common failure modes

- Recursive reveal exposes an entire future tree.
- Revealed or GM-granted nodes are accidentally marked complete.
- `GRANT_TECHNOLOGY` writes completion bits without applying Modifier sources.
- A blocked queue silently skips to a later node.
- Empty-domain shares leak into another domain instead of deferred stock.
- Rounding destroys minimum technology-point units.
- Procurement buys before households/firms or pays no merchant.
- Research output teleports directly from a building to country treasury.
- Modifier definitions exist but the economy/research consumer never queries them.
- Node refresh rebuilds `GraphEdit`, losing pan/zoom/selection or growing node count.
- Search, tooltip, connection label, or accessibility text leaks unknown technology details.
- PKCN/PKEC restore order or catalog hashes are ignored.

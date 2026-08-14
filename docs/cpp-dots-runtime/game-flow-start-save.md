# Formal Game Flow, Player Start, and PKSV

This document is the current contract for the player-facing startup path, the
multi-country opening bootstrap, and complete-game persistence. The legacy
`world_setup.tscn` remains a development tool and is not a product entry point.

## Session Authority

`GameFlowService` is the process-local session authority. It owns exactly one
pending `new_game` or `load_game` request and changes between
`main_menu.tscn` and `player_game.tscn`. Product code must not use `Engine`
metadata to move configuration between scenes.

`NewGameConfig v3` is the shared UI/generator/save schema. Its top-level groups
are `country`, `base`, `world_controls`, `climate`, and `research`. The
`country.foreign_count` field is persisted with range `0..12` and default `5`;
v2 loads migrate to `0` so existing saves retain their single-country opening.
`base.land_layout` is a player-facing preset id (`single` / `two` / `multiple` /
`archipelago` / `custom`). Named presets write `num_continents`, `continent_size`,
`sea_level`, plus `world_controls.continent_spacing` and `island_amount`; the
default is `two`, sized so the two cores stay separated instead of merging into
one Pangaea. Missing or unknown ids validate as `custom` and keep the stored
numeric knobs. Always validate through
`validate()` or `from_dictionary()` before generation. The resolved nonzero
seed, including a UI-generated random seed, is the value stored in PKSV.

## Generation and Bootstrap Order

The formal path has one fixed order:

1. Generate physical geography and bake the static world.
2. Generate natural-resource deposits and publish them to `MapData`, `DCWorld`,
   and `DCWorldExt`.
3. Select the player start, then deterministically select the configured foreign
   starts from cells whose natural deposits and visible geography already close the starter route.
4. Bootstrap PKCN once with `country.player` in slot 0 followed by
   `country.foreign.001` etc.; every country owns exactly its start cell and all
   remaining land stays unowned.
5. Build one aggregated production settlement packet with
   `StarterSettlementBootstrap`, including each capital's founder family and
   notable founder declarations.
6. Bootstrap PKEC and run its initial conservation checks.
7. Register `country_daily` before `economy_daily`, then register the remaining
   daily systems and build scheduler topology.
8. Publish UI state, select the start cell, and center it in the map safe area.

Do not call `EconomyTestBootstrap` from this path. It remains test/demo data.

## Start Policy

`StartLocationProfile` is gameplay configuration, independent of inspector
habitability presentation. A candidate must be passable land, satisfy the
temperature/moisture/elevation/vitality ranges, and have river/lake hydrology
on itself or a neighbor. Candidates are sorted by survival score. Naturally
gold/silver-bearing candidates are preferred, and a stable hash of
`seed + player_start` selects within the top quartile.

No resource deposit is added or topped up by start selection. A candidate must already have natural
gold or silver and enough local resources and visible signals to close food, clothing, construction,
knowledge and trade production. Generation fails with a player-facing error when no valid closed
candidate exists.

Foreign starts use the same survival predicate. Their minimum pairwise land
distance is `clamp(round(min(width, height) * 0.15), 4, 12)` over the map's
six-neighbor topology; disconnected landmasses count as infinitely distant.
Selection is deterministic and greedily orders candidates by distance from the
nearest selected start, natural precious metal, survival score, then cell index.
Generation fails rather than reducing the requested count or relaxing distance.
Display names are selected without replacement from the resource-backed Chinese
country-name pack, excluding the player's display name.

## Twenty-Person Settlements

Every opening country receives exactly 20 people. Occupations are derived from the selected regional
producer bundle, including the matching gold/silver work site and the merchant owner of an
`early_merchant_post`; the remaining people start unemployed. The weak regional bundle is prebuilt,
and only 15 days of its locally produced food is bridged into market stock. All settlements are compiled
into one PKEC bootstrap packet. PKCN/PKEC and the economy
ledger remain the authorities; UI code does not own this state.
Each capital also starts with exactly one founder family: the two foragers who
operate its gathering ground become conserved family members, that building unit
becomes the family's first industry, and one of those occupied owner jobs becomes
the family's named notable founder. This explicit opening exception is created
inside native bootstrap, preserves total population, money, goods, and building
count, and is immediately queryable before the first daily settlement.
The v3 `founder_family_*` columns remain the preferred explicit contract. Native
bootstrap also derives the same declaration from `forced_named_cells` plus an
actual `gathering_ground` when those columns are absent, so a long-lived editor
emitting the older v2 packet cannot silently create a capital without founders.
For already-running early sessions, `FAMILY_COMMIT` repairs a still-empty forced
capital during days 0..30 once its occupied gathering-ground owner posts exist;
the normal `PERSON_COMMIT` then promotes and binds the representative.
The packet marks every opening-country start cell as `forced_named_cells`.
Native `SettlementStore` therefore assigns each capital a deterministic name
even though 20 people remain below the ordinary rural naming threshold. This is
a naming exception only: prosperity remains population-derived and the exact
20-person economy contract is unchanged.

## PKSV v1

`SaveRepository` writes one PKSV file for each fixed slot:
`manual_1.pksv`, `manual_2.pksv`, `manual_3.pksv`, and `autosave.pksv`.
The container has a JSON header, a section table, compressed payload blocks,
uncompressed lengths, and per-section SHA-256. Replacement is:

```text
write .tmp -> read/decompress/hash verify -> move final to .bak -> rename .tmp
```

Load ignores `.tmp`, prefers a valid final file, and falls back to a valid
backup. Incompatible generator/catalog/schema hashes are rejected rather than
guessed or migrated.

Required sections are `new_game_config`, `world_clock`, `dynamic_world`,
`environment`, `pkcm`, `pkcn`, `pkec`, `pkgp`, `pkef`, `pkid`, `pkfg`, `journal`, `pktr`, `player_context`,
`player_view`, and `preview`. Missing authority fails closed. `environment` uses
`PKEnvironmentRuntime v1` and includes native core SoA, weather ping-pong,
topology, dirty/active sets, round flags, stage cursors, and publish versions;
diagnostic counts alone are not a save provider.

Every authority is registered through `RuntimeStateProvider`, whose contract is
`provider_id()`, `schema_version()`, `can_save()`, `write_sections()`,
`restore_sections()`, and `state_hash()`. The PKSV header stores the ordered
provider manifest (id, schema, owned sections, and capture hash). Slot listing
and load preparation reject a missing or mismatched provider before rebuilding
the world. The current restore registry order is dynamic world, environment,
PKCM, clock, PKCN, PKEF, PKEC, PKGP, PKFG, journal, PKTR, PKID, then player
session/view/preview. PKEF precedes PKEC so Economy can cross-check every settling
cross-domain transaction against authoritative Effect state. `PKID v2` follows
`PKEF v9`: every active ideology must match its
durable external binding by identity, generation, level, location, template
signature, and Effect program hash. Missing/mismatched bindings or unknown
pending transitions fail restore; PKID and PKEF must also agree on the exact
country/ideology source of every pending transaction, with no extra PKEF
ideology transaction omitted by PKID. They are never repaired by replaying effects.
PKID v1 is accepted only when every ideology is inactive. Save capture waits for
`ideology_should_run(day)`, `effect_should_run(day)`, and every native
Country/Economy/Gameplay Effect ingress to be idle, so no cross-section snapshot
can span a preflight/commit/ACK boundary.
PKCM v1 saves Climate modifiers. PKCN v11 embeds Country modifiers, research,
tax policy, territory claim and native Effect ingress idempotency; PKEC v34 embeds Economy
modifiers, BuildingIdentityStore, family traits/cell influence,
production-climate state, and Economy Effect ingress idempotency. PKGP v1 saves
Gameplay identity/base SoA and modifiers; journal v4 saves native
`PUBLISH_EVENT` Effect idempotency evidence; PKTR v5 saves static/dynamic branch
and technology-practice Trigger accumulation. PKEF v9 saves Effect recipe/program
identity and pending ACK state. Old PKCN/PKEF/PKTR schemas or related catalog
identity changes are rejected with `catalog_hash_mismatch`.

`pkfg` is `PKFogOfWar v1` and persists exactly one array: the monotonic
`cell_explored` progress, plus the cell count it was captured at. Current
visibility and the blurred fog knowledge `fog_k` are pure functions of territory
and terrain, so they are never written; restore recomputes them. A cell-count
mismatch or a truncated array is rejected rather than padded. When fog has never
been solved (sandbox or fog disabled) the provider still writes a zero-filled
array so the section stays mandatory.

The load screen validates every section without retaining full payloads, and
loads the screenshot through a separately verified `preview` section. This
keeps corrupt or truncated slots visible with a reason while disabling load;
valid backups remain recoverable.

## Safe Boundary and Restore

A save request freezes the clock while rendering continues. If Trigger,
Ideology, Effect, Modifier, Gameplay Effect, Country, or Economy has pending
safe-boundary work, `GameSaveCoordinator` advances the native order
`Trigger -> Ideology -> Effect -> Modifier -> Gameplay -> Country -> Economy`
once per render frame until every owner is idle and Economy is committed. It
then captures all providers and restores the original pause and speed state.
Annual autosave runs once after the new year's first joint safe boundary.
Return-to-menu and exit await autosave success; failure offers retry, discard,
or cancel.

Restore order is strict:

1. Validate PKSV header, compatibility hash, section hashes, and required set.
2. Regenerate static terrain from the complete saved `NewGameConfig`.
3. Restore dynamic `DCWorld` and the full native environment provider.
4. Restore PKCM, then `WorldClock`.
5. Restore PKCN v11, including Country modifiers, research state, national/cell tax policy,
   and native Country Effect ingress idempotency.
6. Restore PKEF v9, then PKEC v34 after trade topology has been configured, including Economy
   modifiers, building identities, notable families, active family expeditions, and production-climate state.
7. Restore PKGP, then PKFG; re-solve vision and republish `enum_lut.a` and the border
   mesh through `WorldRuntimeHost.refresh_country_visuals()`.
8. Restore journal v4 and PKTR v5, then PKID v2
   ideology state. PKID verifies its active PKEF bindings before the session is
   allowed to resume.
9. Rebuild derived views/render resources and scheduler topology.
10. Restore selected cell, camera position/zoom, pause, and speed.

PKCM must follow environment; PKCN and PKEF must precede PKEC; PKGP follows Economy
base/identity restore. PKFG must follow PKCN, because re-solving
visibility reads the restored territory. Native restore rejects crossed
generations or catalog hashes.

While regenerating a load target, `MapGenerator` enters restore-preparation
mode: it configures the native country catalog but does not bootstrap a
temporary player country or settlement. After PKCN restore makes the country
authority available, the coordinator configures the economy catalog and trade
topology, then restores PKEC. Because native PKEC restore clears transient
topology state, finalization recaptures the same normalized topology before it
registers `country_daily`/`economy_daily` and rebuilds the existing scheduler
topology. This preserves the required
`PKCN -> economy configure -> PKEC -> topology recapture -> scheduler`
sequence.

PKEC restore must also reconstruct every building-group transient span before
daily scheduling resumes. In particular, the inspector-only selected-input lane
is allocated from each restored building type's input count and initialized to
`-1`; it is neither serialized nor included in the state hash. Restore
finalization validates the span shape so a missing cache fails during load
instead of surfacing later in `BUILDING_PRODUCTION`.

The PKSV `pkec` section is a byte-for-byte concatenation of native framed PKEC
chunks. `EconomyFacade.restore_bytes()` must recover each frame from its
16-byte header and feed exact frame boundaries to native restore; a fixed-size
slice is not a valid framing rule. Native journal restore returns the same
structured success contract as the other providers (`ok=true`,
`fallback=false`) so the coordinator can distinguish a restored journal from
an unavailable fallback.

## Validation

Minimum gates are configuration and repository tests; deterministic multi-start
tests across representative seeds/sizes; one-cell ownership, pairwise land
distance, unique names, resource, population,
and building assertions; `EnvironmentRuntime` byte-exact round-trip; PKCN/PKEC
focused tests; four Modifier domain round-trips; a PKFG round-trip that hashes `explored_arr` across save/load
and then advances the restored runtime through at least one complete five-phase
economy settlement cycle (`game_save_roundtrip_test.gd`); debug/release GDExtension builds; and
desktop/narrow UI checks.
For economy changes, retain 60-day, two-year, and ten-year conservation soaks.

## Regional technology/economy bootstrap v5

Formal new games no longer grant four universal technologies or a universal settlement bundle.
`StartLocationPolicy` classifies each capital from the capital ring's Bio/resource/landform/climate
evidence and returns one food, clothing, construction, precious-metal and knowledge route.
`MapGenerator` grants only the selected zero-cost handling technologies plus recursive structural
prerequisites, plus the zero-cost `tech.early_trade`; `StarterSettlementBootstrap` prebuilds the
matching weak producers and `early_merchant_post`. The supported
families are coastal, floodplain, cold highland, tropical forest, arid highland and temperate.

The bootstrap validates the complete direct/required-technology, construction-good, input, output,
local-resource and resource-generation closure. It never adds gold, silver or any non-precious route
resource, and it never tops up the former universal fertile-soil/timber/game/stone/flint set. Starting
buildings cannot require steel, coal, industrial chemicals, industrialists, managers,
landlords, serfs or indentured labor. The only food bridge is 15 days of the route's locally produced
food good; `processed_food` receives no fixed grant. Every generated country starts with exactly one
territory cell, one regional weak bundle, 20 population, one founder family and one notable founder.

Save flow requires `PKTR v5` after journal/domain state. Missing/older PKTR, older PKCN/PKEF,
PKEC v32 or older, and incompatible catalog hashes reject restore; no empty-trigger or technology
ID migration is provided.

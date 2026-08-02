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
Always validate through
`validate()` or `from_dictionary()` before generation. The resolved nonzero
seed, including a UI-generated random seed, is the value stored in PKSV.

## Generation and Bootstrap Order

The formal path has one fixed order:

1. Generate physical geography and bake the static world.
2. Generate natural-resource deposits and publish them to `MapData`, `DCWorld`,
   and `DCWorldExt`.
3. Select the player start, then deterministically select the configured foreign
   starts and publish all resource top-ups through the same three mirrors.
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
temperature/moisture/elevation/vitality ranges, and have river/lake freshwater
on itself or a neighbor. Candidates are sorted by survival score. Naturally
gold/silver-bearing candidates are preferred, and a stable hash of
`seed + player_start` selects within the top quartile.

The chosen cell is topped up to the profile minimum for fertile soil, timber,
wild game, stone, flint, and one precious resource. If neither precious metal
exists locally, the globally rarer metal is chosen; a stable hash breaks ties.
Generation fails with a player-facing error when no valid survival candidate
exists.

Foreign starts use the same survival predicate. Their minimum pairwise land
distance is `clamp(round(min(width, height) * 0.25), 6, 16)` over the map's
six-neighbor topology; disconnected landmasses count as infinitely distant.
Selection is deterministic and greedily orders candidates by distance from the
nearest selected start, natural precious metal, survival score, then cell index.
Generation fails rather than reducing the requested count or relaxing distance.
Display names are selected without replacement from the resource-backed Chinese
country-name pack, excluding the player's display name.

## Twenty-Person Settlements

Every opening country receives exactly 20 people. Each settlement contains three foragers, two merchants,
one gold miner or two silver miners, and unemployed household members for the
remainder. It starts with one gathering ground, one timber collector, one
merchant post, and one matching gold/silver work site. Market stocks and cohort
funds cover the configured 60-day survival bridge. All settlements are compiled
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
`environment`, `pkcm`, `pkcn`, `pkec`, `pkgp`, `pkfg`, `journal`, `player_context`,
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
PKCM, clock, PKCN, PKEC, PKGP, PKFG, journal, then player session/view/preview.
PKCM v1 saves Climate modifiers. PKCN v4 embeds Country modifiers, research and tax policy; PKEC v28
embeds Economy modifiers, BuildingIdentityStore, notable-family authority, and production-climate state; PKGP v1 saves Gameplay
identity/base SoA and modifiers. Legacy PKCN/PKEC technology-tree saves are
rejected with `legacy_technology_tree_save_unsupported`.

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

A save request freezes the clock while rendering continues. If country or
economy has an open continuation, `GameSaveCoordinator` advances it once per
render frame until country is idle and economy is committed. It then captures
all providers and restores the original pause and speed state. Annual autosave
runs once after the new year's first joint safe boundary. Return-to-menu and
exit await autosave success; failure offers retry, discard, or cancel.

Restore order is strict:

1. Validate PKSV header, compatibility hash, section hashes, and required set.
2. Regenerate static terrain from the complete saved `NewGameConfig`.
3. Restore dynamic `DCWorld` and the full native environment provider.
4. Restore PKCM, then `WorldClock`.
5. Restore PKCN v4, including Country modifiers, research state and tax policy.
6. Restore PKEC v28 after trade topology has been configured, including Economy
   modifiers, building identities, notable families, and production-climate state.
7. Restore PKGP, then PKFG; re-solve vision and republish `enum_lut.a` and the border
   mesh through `WorldRuntimeHost.refresh_country_visuals()`.
8. Restore journal and player/session context.
9. Rebuild derived views/render resources and scheduler topology.
10. Restore selected cell, camera position/zoom, pause, and speed.

PKCM must follow environment; PKCN must precede PKEC; PKGP follows Economy
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

Save flow includes optional `PKTR` after journal/domain state. Missing PKTR in older
saves migrates to an empty trigger state; incompatible catalog hashes reject restore.

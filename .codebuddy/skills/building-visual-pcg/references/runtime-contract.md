# Building Visual Runtime Contract

## Authority

`NativeEconomyRuntime` owns building groups, counts, construction, employment, production,
and committed timing. It publishes a read-only sparse visual mirror only after the complete
`building_commit`. The mirror aggregates the same cell/type across owner groups and stores
stable `(cell_idx, type_idx)` order. Ordinary production, wages, or inventory changes do not
change the visual generation.

The same view carries four per-cell byte columns: `settlement_tiers` (0–7, the authoritative
`_settlements.tier`), and three presentation-only bands computed in
`publish_social_pressure_facts` from the cohort composite satisfaction:
`living_levels` (0–6, thresholds shared with `living_standard_level_for` via
`LIVING_STANDARD_THRESHOLDS_Q16`), `rich_buckets` and `poor_buckets` (0–3; population
share at living level ≥5 or ≤1, bucketed at 5/20/40%). 255 means no population. Bands are
hysteretic (±1.5% living, ±2% share, one band per step), so cohorts hovering on a threshold
do not repaint daily. A tier or band change calls `mark_building_visual_cell(cell)`, which
bumps the visual generation and queues only that cell in the sorted, deduplicated outbox.
`read_view_reset` rebuilds the bands. They are never persisted or hashed.

`NativeCountryRuntime` owns technology completion. `current_visual_era[slot]` is derived from
the maximum sort order of completed era milestone technologies. Ordinary technology, pending
technology, or an unapplied modifier cannot advance the era. GM grants must use the same
completion path.

The renderer consumes these snapshots through `DCWorldExt`; it never reads a mutating native
slice and never creates a second economy or technology state.

## Native bridge shape

The relevant cold/batch APIs are:

```text
get_building_visual_snapshot(requested_cells)
consume_building_visual_dirty_cells()
consume_country_visual_era_dirty_slots()
bake_building_visual_chunk(knobs)        # synchronous wrapper, tests/tools only
NativeBuildingVisualCache.configure/submit_cells/take_ready_chunks/build_chunk/...
```

Snapshot requests are sorted, deduplicated, range-checked, and aligned to CSR rows. Empty
cells remain zero-width rows so old geometry/intelligence can be cleared without special
cases. Snapshot failure must leave the existing intelligence untouched.

The runtime path is the per-cell cache: `configure` takes the static tables (cell positions,
map width, chunk size, `type_to_archetype` plus optional `type_to_family/type_to_scale/
type_to_grade`, quality, flow field), and `submit_cells` takes changed rows (cell, era, water
flag, type/count CSR, optional `settlement_tiers/living_levels/rich_buckets/poor_buckets`).
The input hash includes the social bands. A row with no types but tier 1–7 stays cached and
draws houses; a row with no types and tier 0/unknown is removed after its empty plan. The
worker plans off-thread and the layer assembles chunks with `build_chunk`. The synchronous
chunk baker accepts the same tables and columns (optional ones empty or exactly aligned).
Both return two packed 16-float-per-instance buffers (`buffer` for building volumes,
`decal_buffer` for ground features); the baker also reports `instance_count/
decal_instance_count/lot_count/house_count/villa_count/shanty_count/field_count/
family_lots(22)/candidate_count/river_rejected/elapsed_ms`. Input shape, monotonic offsets,
type ranges, positive counts, and numeric knobs are validated before generation.

Family, scale, and grade are derived by `BuildingVisualLayer.configure_catalog` through
`BuildingVisualFamilyTable` (order: `visual.family.<id>` tag, sector/kind, production climate
profile, production resource, keywords over type id, chain id and output goods). Scale is
`clamp(round(8·sqrt(owner + employee slots)), 8, 255)`; grade is the highest construction
good grade (0 primitive … 3 steel frame) and caps the era band of that family's lots.

## Player intelligence and fog

`BuildingVisualIntelCache` is owned by `WorldRuntimeHost`; rendering reads it. A row stores:

- cell and observed country slot;
- observed era index, including `-1` unknown era;
- exact type indices and exact counts for inspector use;
- observed `settlement_tier/living_level/rich_bucket/poor_bucket` (255 unknown);
- a visual signature based on logarithmic count buckets plus the four social bands;
- settlement core bucket and dominant category metadata.

Only currently visible cells accept a live snapshot. Newly hidden cells keep the last row.
Construction or foreign era changes in hidden cells are ignored until the cell is visible
again. Fog disabled means every cell is treated as visible. An empty visible snapshot removes
the cached row and its macro entry. Unknown era does not erase known buildings; it uses a
neutral style. Live weather and snow are disabled for hidden memory geometry.

## PKFG v3

Building intelligence is stored as sparse CSR fields plus cell-aligned social columns:

```text
building_intel_cells
building_intel_country_slots
building_intel_era_indices
building_intel_type_offsets
building_intel_type_indices
building_intel_counts
building_intel_settlement_tiers
building_intel_living_levels
building_intel_rich_buckets
building_intel_poor_buckets
```

Save only known building rows, sorted by cell. Do not save transforms, random seeds, GPU
buffers, LOD, or weather. Restore into a staged cache, validate all offsets/ranges/counts and
that each social column matches the cell count (`pkfg_building_social_truncated` otherwise),
then replace the live cache atomically. PKFG v2 still restores with social bands unknown
(255); the tier is then estimated from the building count until the cell is seen again. A
missing `version` is PKFG v1: preserve explored cells but restore no building intelligence.
Never fill missing rows from current foreign runtime state. The save coordinator's pkfg
provider schema is 3 and accepts 1–3.

## Update ordering

1. Consume committed building, settlement-tier/social-band, and country-era dirty signals.
2. Solve/compare visibility and update fog LUT state.
3. Batch refresh newly visible and visible dirty cells into the intelligence cache.
4. Recompute macro LUT entries (density is the larger of the building-count density and
   `tier/8`) and visual signatures.
5. Submit only signature-changed cells to `NativeBuildingVisualCache`; the worker replans
   them and marks their 16x16 chunk ready once every pending cell is done.
6. Upload ready chunks that are resident or in prefetch range; stale worker results are
   discarded by cell generation, never uploaded.
7. Send settlement core buckets to vegetation as a read-only exclusion input.

Do not put visual rows in `MapData`, `HexCell`, DataCore economy fields, PKEC, or the economy
state hash. Do not let hidden building changes alter vegetation appearance.

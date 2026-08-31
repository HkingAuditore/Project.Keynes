# Building Visual Runtime Contract

## Authority

`NativeEconomyRuntime` owns building groups, counts, construction, employment, production,
and committed timing. It publishes a read-only sparse visual mirror only after the complete
`building_commit`. The mirror aggregates the same cell/type across owner groups and stores
stable `(cell_idx, type_idx)` order. Ordinary production, wages, or inventory changes do not
change the visual generation.

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
bake_building_visual_chunk(knobs)
```

Snapshot requests are sorted, deduplicated, range-checked, and aligned to CSR rows. Empty
cells remain zero-width rows so old geometry/intelligence can be cleared without special
cases. Snapshot failure must leave the existing intelligence untouched.

The numeric chunk baker accepts packed cell positions, CSR offsets/types/counts, era indices,
archetype mapping, water flags, and optional flow data. It returns a packed 16-float-per-
instance buffer plus counts and diagnostics. Input shape, monotonic offsets, type ranges,
positive counts, and numeric knobs are validated before generation.

## Player intelligence and fog

`BuildingVisualIntelCache` is owned by `WorldRuntimeHost`; rendering reads it. A row stores:

- cell and observed country slot;
- observed era index, including `-1` unknown era;
- exact type indices and exact counts for inspector use;
- a visual signature based on logarithmic count buckets;
- settlement core bucket and dominant category metadata.

Only currently visible cells accept a live snapshot. Newly hidden cells keep the last row.
Construction or foreign era changes in hidden cells are ignored until the cell is visible
again. Fog disabled means every cell is treated as visible. An empty visible snapshot removes
the cached row and its macro entry. Unknown era does not erase known buildings; it uses a
neutral style. Live weather and snow are disabled for hidden memory geometry.

## PKFG v2

Building intelligence is stored as sparse CSR fields:

```text
building_intel_cells
building_intel_country_slots
building_intel_era_indices
building_intel_type_offsets
building_intel_type_indices
building_intel_counts
```

Save only known building rows, sorted by cell. Do not save transforms, random seeds, GPU
buffers, LOD, or weather. Restore into a staged cache, validate all offsets/ranges/counts,
then replace the live cache atomically. A missing `version` is PKFG v1: preserve explored
cells but restore no building intelligence. Never fill missing rows from current foreign
runtime state.

## Update ordering

1. Consume committed building and country-era dirty signals.
2. Solve/compare visibility and update fog LUT state.
3. Batch refresh newly visible and visible dirty cells into the intelligence cache.
4. Recompute macro LUT entries and visual signatures.
5. Map signature changes to 16x16 render chunks.
6. Bake only resident/prefetch chunks and upload after generation validation.
7. Send settlement core buckets to vegetation as a read-only exclusion input.

Do not put visual rows in `MapData`, `HexCell`, DataCore economy fields, PKEC, or the economy
state hash. Do not let hidden building changes alter vegetation appearance.

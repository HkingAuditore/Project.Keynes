# Architecture And Data

## Formula And Catalog

The effective-stat formula is:

```text
clamp((base + sum(add)) * product(factor), stat_min, stat_max)
```

Catalog resources compile stable stat/definition keys to dense IDs. Validate duplicate keys,
domain alignment, allowed operations, finite values, ranges, duration, stack limits, and zero
divide. One definition cannot span domains.

Each instance has `magnitude_q16`. Scale add terms linearly. Scale factor terms from the neutral
value before applying stacks: `scaled_factor = 1 + (factor - 1) * magnitude`; a magnitude of one
preserves legacy behavior and zero is neutral.

## Store

Each domain owns an independent SoA Store. Instance columns include active, generation,
definition, entity/group, source, scope, stacks, magnitude, applied/expiry day, and expiry revision.
`generation << 32 | index` is the public handle.

Bucket key is `(stat_id, scope, scope_id)`. Cache sum add, nonzero factor product, zero factor
count, and member references. Rebuild after the mutation threshold or numeric failure.

Expiry uses a min-heap with day, index, generation, and revision. Refresh invalidates old heap
nodes lazily.

## Stack Policies

- `INDEPENDENT`: allocate one handle per application.
- `UNIQUE_SOURCE`: replace matching definition/target/scope/source in place.
- `STACK_REFRESH`: add stacks to max and refresh expiry; add is linear, factor is power.

N-day effects expire before consumers on `applied_day + N`. Permanent expiry is `-1`.

## Identity

Climate entity is the cell index. Country uses NativeCountryRuntime handles. Economy uses
BuildingIdentityStore key `(cell, type_id, owner_signature_id)`. Gameplay uses its own identity
store and explicit base SoA. Target retirement removes entity-scope instances only.

## Persistence

Save stable definition/stat keys, definition version, target/source/scope, stacks, dates, and
Q16 magnitude plus normalized term payload. Modifier save schema v2 is strict. On restore validate
the entire payload before swapping the store,
rebuild buckets/unique maps/heap, and increment snapshot version. Never replay apply events.

## Derived Cell Layer

Permanent cell-card contributions live in a dedicated derived layer **inside
`ModifierRuntime`**, not in `Store`. `apply_pod_snapshot` rebuilds `_stores`, so anything
placed there is wiped on a snapshot swap.

### Shape

```cpp
struct DerivedCellFront {
    uint64_t generation, world_identity, map_generation;
    int64_t sample_day; uint64_t epoch_id, execution_contract_hash;
    std::vector<uint64_t> stat_versions;      // indexed by stat id
    std::vector<DerivedCellStatRow> rows;     // one row per stat
};
struct DerivedCellContribution {              // one per (stat, cell)
    uint64_t source_country;
    uint32_t contributor_count;
    double sum_add, product_nonzero;
    uint32_t zero_factor_count;
};
```

`row_for_stat(stat_id)` + `find(cell)` are binary searches: `effective_value` is a hot path
and cannot scan linearly.

### Merge rule

The derived contribution joins the SAME add/factor sum, **before the single final clamp**:

```cpp
add += slot->sum_add;
factor = slot->zero_factor_count > 0 ? 0.0 : factor * slot->product_nonzero;
double value = (base_value + add) * factor;
return std::clamp(value, min_value, max_value);   // the only clamp
```

`clamp((legacy_effective + derived_add) * derived_factor)` is wrong: the legacy value has
already multiplied its own factors and may already be clamped, so no arithmetic recovers the
correct combination.

A zero factor must annihilate the whole product; multiplying by `product_nonzero` alone
ignores a "-100%" card.

### Which handle carries the cell

**`group_handle` is the cell and `entity_handle` is 0.** Every ECONOMY-domain reader does
this (`economy_runtime.cpp:4391,4394`, `economy_runtime_family_buff.cpp:7127`). The branch
gate is `domain == ECONOMY && !rows.empty()`.

> `group_handle != 0` used to be part of that gate and **was a real defect**: cell 0 is a
> legitimate cell, so every card silently did nothing on its country's first cell (measured
> cell 0 value 1.0 vs cell 1 value 1.05). Removing it is safe because COUNTRY-domain callers
> pass `group 0` meaning "no group" but are blocked by `domain == ECONOMY`, and all three
> callers of `effective_values` are COUNTRY-domain too.

### Install

`install_derived_cell_layer(front, expected_generation, skipped, error)` is the only writer.
A new generation replaces the old one atomically after the build completes, so readers see
either the old front or the new one, never a half-built one. Identical content is an
idempotent no-op and does **not** bump the version (I13) — otherwise an idle day would
invalidate every cache keyed on the layer generation.

An explicitly empty candidate CLEARS the layer: a card whose conditions are all false must
retire its previous contribution, not silently keep it.

### Materialiser

`DerivedCellMaterializeJob` is resumable: `fold_step(budget_ms)` + `finish()`, fold state
living in the object. The split is required by the 1 ms slice budget, not a style choice.
Ramp magnitudes come from the card's own program via
`DerivedProgramMagnitudeSampler` (`evaluate_program_magnitude_for_metrics`), not from
`metric * scale`.

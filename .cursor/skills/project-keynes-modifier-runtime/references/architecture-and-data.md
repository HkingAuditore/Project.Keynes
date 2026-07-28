# Architecture And Data

## Formula And Catalog

The only formula is:

```text
clamp((base + sum(add)) * product(factor), stat_min, stat_max)
```

Catalog resources compile stable stat/definition keys to dense IDs. Validate duplicate keys,
domain alignment, allowed operations, finite values, ranges, duration, stack limits, and zero
divide. One definition cannot span domains.

## Store

Each domain owns an independent SoA Store. Instance columns include active, generation,
definition, entity/group, source, scope, stacks, applied/expiry day, and expiry revision.
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
normalized term payload. On restore validate the entire payload before swapping the store,
rebuild buckets/unique maps/heap, and increment snapshot version. Never replay apply events.

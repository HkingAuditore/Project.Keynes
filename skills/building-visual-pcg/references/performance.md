# Building Visual Performance

## Budget principle

Visual computation must cost far less than the simulation, and nothing heavy may run on the
main thread. Layout is planned per cell on a background worker, only for cells whose input
changed; the main thread submits changed rows and uploads assembled chunks.

## Background per-cell cache

`NativeBuildingVisualCache` (`gdext/src/building_visual_cache.h`, implementation at the end of
`world_ext_building_visual.cpp`) owns one dedicated `std::thread` worker in the
`EconomyCsvRecorder` style: mutex + condition variables, POD inputs copied at `configure`,
no Godot API on the worker. Per cell it keeps the input (era, water, four social bands,
type/count CSR), an input hash, `input_gen/output_gen`, and the encoded body/decal floats.

- `submit_cells(rows)`: unchanged hash is skipped; a change bumps the generation and queues
  the cell once.
- Worker: copies the input under the lock, runs `plan_cells` with K = 1 unlocked, commits
  only if the generation still matches (otherwise the cell is already requeued).
- A chunk enters `take_ready_chunks()` only when its pending count reaches zero.
- `build_chunk(chunk, cap)`: memcpy of the cached cells in cell order; over-cap chunks keep
  each cell's lowest ranks (`select_by_rank`).
- `chunks_in_rect(rect, center, limit)`: residency from per-chunk bounds of non-empty chunks.
- `set_quality(q)`: requeues every cached cell; old geometry stays until replaced.

C++ performs CSR reads, family weight aggregation, the log lot ladder and `weight^0.75`
quotas, tier housing, villas/shanties, ring ordering, settlement planning (plaza, streets,
frontage cursors, OBB collision with bounding-circle reject, hex and river checks, outer
farmland), in-cell rank, and buffer encoding. The social bands come precomputed from the
economy's existing social-pressure scan (no extra cohort pass). GDScript
builds the changed-row CSR, chooses resident chunks through the cache, and uploads
`MultiMesh` buffers into reused nodes. There is no GDScript baker.

Recorded local samples (debug DLL, stress fixture of 16×16 cells at 100k buildings each):

| Item | Thread | Cost |
|---|---|---|
| plan one cell | worker | ~60 µs avg, ~180 µs max |
| `submit_cells` 256 cells / 1 changed | main | ~0.08 ms / ~0.02 ms |
| `build_chunk` 6144 instances, rank-capped | main | ~0.07 ms median, ~0.28 ms max |

The art harness (66 cells of mixed real families) averages ~43 µs per cell on the worker.
A 60×40 fresh-start headless 50-day run marks 0–1 building-visual dirty cells per day and
keeps ~69 days/s, inside the pre-change 62–74 range. The old synchronous chunk bake cost
~9.4 ms of main thread for the stress fixture. Planning cost is dominated by failed
placement probes, which is why a cell stops after 4 consecutive failed slots.

## Representation

Use 16x16 cell render chunks. A chunk has at most three nodes — GroundDecal (z 1), Shadow
(z 2), Body (z 3). Body and GroundDecal use one unit quad, Shadow the hull fan mesh; Body and
Shadow share one buffer. The
16-float instance layout is defined in `shaders/include/building_form.gdshaderinc`:

```text
0..7   2D transform; basis column lengths are the half extents
8..11  body: eave/16, ridge/16, (material+0.5)/16, rank   decal: param, flag, 0, 1
12..15 style=(era*6+archetype)/65, seed, cell/(cell_count-1),
       body: (form+0.5)/32 (decode with BF_FORM_SCALE)   decal: (kind+0.5)/16
```

LOD is one `lod_fraction` uniform on the Body and Shadow materials (0.28 below zoom 0.82,
0.62 below 1.30, 1.0 otherwise; chunks clear below 0.46 where Macro takes over). The vertex
stage collapses instances whose in-cell rank `(n+0.5)/N` exceeds it, so every settlement
thins from its edge. Do not copy or mutate instances on camera movement or weather change.

## Budgets

Resident limits are 128 chunks on desktop and 48 on Web. Body caps q0/q1/q2 are
6,000/18,000/36,000. Per cell and quality q0/q1/q2: industry lots `[6, 12, 20]`, houses
`[6, 16, 30]` (tier table `[0, 3, 6, 10, 15, 20, 26, 32]`), at most 4 villas and 5 shanties,
outer fields `[0, 8, 16]`. q0 has no ground decals; Web has no cast shadows.

## Shader cost

No ray marching. Body: one parallax correction onto the roof height field, analytic wall
intersection (box slabs, disc quadratic, cross union, courtyard inner wall), numerical roof
normals (4 roof taps). Shadow follows the vegetation blob approach: the shape is built in
the vertex stage on a 9-vertex hull fan (edges facing away from the sun pushed along the
shadow), and the fragment evaluates one footprint distance for the soft edge plus one for
contact AO. Daylight is evaluated once per vertex and passed as flat varyings.
Patterns fade through `bf_detail` at far zoom so high-frequency noise does not alias.

## Scheduling and resident lifecycle

Ready chunks that are resident or inside the prefetch range join the upload queue; the
layer uploads the nearest first, at most 4 per frame within 1.5 ms. Evict chunks outside
the prefetch range; eviction releases nodes but keeps the cached layout, so returning to an
area is a memcpy, not a replan. Diagnostics report `last/max_submit_ms`,
`last/max_upload_frame_ms`, and worker statistics under `cache`.

## Validation

Run the focused catalog, native bridge, intelligence, and layer tests under
`Project/project-keynes/tests/building_visual_*_test.gd`, debug and release GDExtension
builds, the art harness, and:

```powershell
git diff --check -- .agents/skills/building-visual-pcg Project/project-keynes/scripts/rendering Project/project-keynes/shaders gdext/src/world_ext_building_visual.cpp gdext/src/building_visual_cache.h docs/cpp-dots-runtime/building-visual-runtime.md
```

When economy-side social bands change, also run the headless perf skill for 50 days and
confirm dirty cells per day stay near the count of cells whose tier or band really moved.

Record the worker per-cell time and the main-thread submit/assemble times printed by the
native bridge test. Native numbers are local samples, not a device guarantee; real rendered
screenshots are required for art sign-off.

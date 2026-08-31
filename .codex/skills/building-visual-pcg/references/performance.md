# Building Visual Performance

## C++ first

The production path is `DCWorldExt::bake_building_visual_chunk`. C++ performs CSR reads,
six-category aggregation, logarithmic quota calculation, stable best-candidate placement,
water/river rejection, importance trimming, and packed buffer encoding. GDScript handles
resource loading, coarse scheduling, node/material creation, upload, diagnostics, and an
explicit test-only fallback. The fallback is not an acceptable desktop/Web default: a
historical 16x16 stress fixture took about 53 ms in GDScript, while the native fixture is
about 0.91 ms average, 1.02 ms p95, and 1.05 ms max on the recorded machine.

If native baking exceeds the 1.5 ms chunk gate, set `bulk_encoder_required` and investigate
profile or a GDExtension bulk encoder. Do not silently switch production back to GDScript.

## Representation

Use 16x16 cell render chunks. A chunk has at most one shared node for each of Body, Ground
Decal, Landmark, and Shadow. All procedural era/category styles share a superset mesh and
material. The instance format is 16 floats:

```text
0..7   2D transform
8..11  instance color/transition metadata
12..13 world UV
14     packed style index (era * 6 + archetype)
15     stable seed/variant
```

Use `visible_instance_count` for Far/Mid/Near prefixes. Do not copy or mutate every instance
on camera movement or weather change. Macro is one world quad reading a building LUT and glyph
atlas; a large map must not create one node per cell.

## Budgets

Default resident limits are 128 chunks on desktop and 48 on Web. Body caps for desktop q0/q1/q2
are 6,000/18,000/36,000; Web low/mid/high are 1,200/3,000/6,000. Per-cell Near caps are
4/8/12 for desktop q0/q1/q2. Web uses 2/4/6. Desktop q1/q2 may use bounded analytic shadows;
Web normally keeps contact AO and disables long shadows. Ground decals are off in q0/Web low,
one per cell in q1, and one per major category in q2.

The visual compound count is `1` for total `1`; otherwise use
`ceil(1.05 * log2(1 + total))`, clamped to the active quality cap. Category quotas use
`log2(1 + count)` weights, stable descending order, and a largest-remainder allocation.

Target draw calls are one Macro call at full-map zoom and no more than about 96/72 per visible
desktop q2/q1 chunks or 36 on Web. When over budget, retain center/high-screen-coverage
chunks, reduce secondary categories, and return edge chunks to Macro. Do not truncate by cell
index and do not delete primary category or era cues randomly.

## Shader cost

Use static q0/q1/q2 shader variants. Keep approximate texture samples to 2-3 for q0, 4 for q1,
and 6 for q2. Avoid raymarching, per-pixel module loops, large transparent billboards, and
high-frequency noise at far zoom. Snow, wetness, fog, sunlight, terrain normal, and horizon
are sampled in the shader. They must not trigger MultiMesh rebuilds. Shadow meshes use one
analytic soft edge, no material atlas, and a bounded sun-height projection.

## Scheduling and resident lifecycle

Merge dirty cells before mapping to chunks. Prioritize new visible cells and camera-center
chunks. Desktop normally uploads one chunk per frame; Web low uploads one every two frames.
Allow at most two in-flight desktop bake tasks and use a synchronous credit-limited fallback
on Web without worker support. Store only the newest pending generation per chunk. Discard
stale worker results after the generation check.

Evict chunks outside the prefetch range, then by least recent visibility, low density, and
opposition to camera motion. Eviction releases nodes/buffers but never deletes intelligence.
Era changes are spread by camera distance; do not rebuild a whole country in one frame.

## Validation

Run the focused catalog, native bridge, intelligence, and layer tests under
`Project/project-keynes/tests/building_visual_*_test.gd`. Also run Godot parser/shader checks,
debug and release GDExtension builds, save/restore checks for PKFG/PKCN/PKEC, and:

```powershell
git diff --check -- .agents/skills/building-visual-pcg Project/project-keynes/scripts/rendering Project/project-keynes/shaders gdext/src/world_ext_building_visual.cpp docs/cpp-dots-runtime/building-visual-runtime.md
```

Record average/p95/max native bake time, chunk upload time, resident chunks, draw calls, body/
shadow/decal instances, GPU frame delta, VRAM, queue depth, and whether `bulk_encoder_required`
was set. Test zoom 0.25/0.45/0.65/1.0/1.5/3.0, 5%/25%/100% occupancy, water/river edges, fog
memory state, all six archetypes, all eleven eras, snow/rain, and east-west wrapping.

The current native numbers are local samples, not a device guarantee. A real rendered-device
screenshot is still required for house recognition, spacing, snow silhouette, shadow direction,
and the absence of large transparent gaps.

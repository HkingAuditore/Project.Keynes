---
name: vegetation-visual-pcg
description: Use when implementing, tuning, debugging, or reviewing Project.Keynes vegetation visual layers such as shrubs, trees, grass, rocks, or other climate-reactive map detail instances. Covers PCG distribution, MultiMesh/GPU-instance rendering, device/quality budgets, MapData/WorldData sampling, and visual response to temperature, moisture, weather, snow, rivers, landform, vegetation type, cover, and vegetation_vitality.
---

# Vegetation Visual PCG

Use this project-local skill for vegetation/detail visual work in Project.Keynes. Pair it with `civ-grounded-development`; use `cpp-dots-runtime-development` only if the task touches DataCore/DOTS/native simulation, not for ordinary visual instance layers.

## Grounding Pass

Read current code before changing behavior:

- `Project/project-keynes/scripts/rendering/hex_renderer.gd`
- The target visual layer, e.g. `Project/project-keynes/scripts/rendering/shrub_layer.gd`
- Its profile resource, e.g. `Project/project-keynes/scripts/data/shrub_visual_profile.gd`
- Default `.tres` profile under `Project/project-keynes/data/visual/`
- `Project/project-keynes/scripts/geography/map_data.gd`
- `Project/project-keynes/scripts/geography/world_data.gd`
- For ecology semantics: `Project/project-keynes/scripts/data_core/component_schema.gd`, `Project/project-keynes/scripts/geography/map_generator.gd`, and UI display code such as `Project/project-keynes/scripts/ui/info_panel_controller.gd`

Useful searches:

```powershell
rg -n "vegetation_vitality|vegetation_heat_stress|vegetation_drought_stress|vegetation_cold_stress|has_river|sample_flow" Project\project-keynes\scripts
rg -n "visual_quality|mobile_quality_tier|set_mobile_quality_tier|MultiMeshInstance2D|MultiMesh" Project\project-keynes\scripts
rg -n "road|road_arr|has_road|route|pathway|trail" Project\project-keynes\scripts
```

If a requested signal such as roads does not exist, state that explicitly and use the closest existing mask only if the user accepts or the request can reasonably fall back.

## Data Sources

Prefer existing authoritative fields:

- Position: `MapData.cell_pos_x_arr/y_arr`; remember these are cube-to-world positions at hex size `1.0`, so multiply by renderer `hex_size` before placing instances.
- Terrain exclusion: `landform_arr`, `is_water_arr`, `LandformType.is_water()`.
- Rivers: `has_river_arr` for cell-level edge density; `WorldData.sample_flow(world_pos)` for river-body rejection.
- Climate: `temp_arr`, `moisture_arr`, `snow_cover_arr`, `weather_type_arr`, `weather_intensity_arr`.
- Ecology: `vegetation_arr`, `cover_arr`, `vegetation_vitality_arr`, `vegetation_heat_stress_arr`, `vegetation_drought_stress_arr`, `vegetation_cold_stress_arr`.

Treat `vegetation_vitality` as the visual health source of truth. It should affect density, alpha, size, color, dieback, and cluster richness, not just act as a minor tint.

## Distribution Rules

Avoid uniform per-cell scatter. Use layered deterministic PCG:

- Cell suitability = vegetation type weight * landform weight * cover weight * climate compatibility * vitality factor * stress reduction * PCG patch weight.
- Use stable hash/value noise keyed by cell index and cell world position so distribution is deterministic and does not shimmer.
- Combine coarse patches, mid-frequency variation, and per-cell micro gaps.
- Evaluate the final PCG acceptance at each candidate world position, not only at the cell center. Cell suitability should express ecological permission; visible patchiness should come from continuous world-space noise sampled at the candidate point.
- Generate clustered positions: choose a per-cell cluster center, then place most attempts around that center with a configurable spread; keep some outliers for organic variation.
- Keep river and water checks after candidate-position generation, because a land cell can still contain river body pixels.
- When enforcing a global instance cap, keep high-scoring candidates from strong world-noise patches instead of thinning uniformly by cell order.
- Avoid solving bad distribution by setting very high global density; it saturates every cell and makes the map look uniform. Prefer lower base density plus patch/cluster multipliers and per-biome weights.

## Climate And Health Response

For generation, compute a presence factor from current cell state:

- High vitality: more density, larger size, stronger cluster coherence, healthier green.
- Low vitality: sparse density, smaller size, lower alpha, brown/gray dead tones.
- At or below dead threshold: skip most generation; optionally keep a few dead remnants using deterministic dieback noise.
- Wet/moist conditions: push toward lush green only when vitality is adequate.
- Heat/drought: push yellow, then brown; reduce alpha and size.
- Cold/snow: desaturate and whiten, reduce alpha and size; allow disappearance under heavy snow.
- Weather intensity should temporarily amplify relevant stress: drought/heatwave, rain/monsoon, blizzard.

Runtime climate response must be material-driven, not per-instance CPU-driven. Bind the same global visual state used by the terrain shader:

- `dyn_atlas_smooth_atlas` or, when cell indirection is active, `cell_index_tex + dyn_lut`.
- `ecology_visual_atlas` or `cell_index_tex + eco_lut`.
- `world_origin/world_size` only if the shader derives UV from world position; otherwise pass a stable per-instance UV once in `INSTANCE_CUSTOM`.

The shader should sample `R=temp, G=moisture, B=snow, A=vegetation_vitality` and compute color, alpha, wind response, shrink, yellowing, greening, snow cover, dieback, and disappearance on the GPU. Do not loop over every shrub/tree/grass instance to push temperature, moisture, snow, vitality, or transforms after generation.

## Rendering Pattern

Prefer `MultiMeshInstance2D` for large visual detail layers.

- Keep one mesh/material per layer; use per-instance transform, color, and custom data.
- Treat per-instance custom data as static generation data: sample UV, seed, variant, coarse biome/style id, or other values that do not change every climate tick.
- Use shader `INSTANCE_CUSTOM` for stable seed/variant and global-state sampling coordinates. Do not use it as a per-frame/per-day climate upload channel.
- Keep rendering side effects in the visual layer and renderer wiring. Do not add C++/DOTS work for purely visual scatter unless profiling proves GDScript rebuilds are the bottleneck.

## Top-Down Procedural Impostors (current, 2026-10)

The map is viewed straight down. Every vegetation instance is one camera-facing quad (`IMPOSTOR_QUAD_HALF = 0.62`) whose fragment shader draws a top-down form procedurally. Do not go back to lobe meshes, side-view sprites, or marching/raymarched volumes; reuse the existing projected-shadow approach for depth.

- Shader split: `shaders/vegetation_family.gdshader` (+ `shrub_layer.gdshader`) include `shaders/include/vegetation_forms.gdshaderinc` (forms: broadleaf, conifer, palm, shrub, grass/tussock, rock, snow mound, kelp, reed, cactus, lichen, peat, coral, flower) and `vegetation_shadow.gdshaderinc` (shadow pass, absolute strength from style LUT px2.a, alpha ×0.80 cluster / ×0.55 grove).
- Form resolution: `ShrubVisualProfile.resolved_visual_form()` / `detail_visual_form()` maps archetype to form; `ShrubLayer._archetype_casts_shadow()` disables shadows for kelp, coral, lichen, peat.
- Multi-element instances: one instance draws 1..32 elements in a 3×3 cell field. `sub_form` 0 single, 1 cluster (2–4), 2 grove (5–32 crowns). `crown_local_radius(count) = count<=1 ? 0.80 : min(0.58, 0.88/sqrt(count))` must stay identical in C++ (`world_ext_detail.cpp`), GDScript (`shrub_layer.gd`) and the shader.
- `custom.a` contract: scatter writes `sub_form + (count-0.5)/32`; `VegetationFamilyLayer` re-packs as `style_id*4 + form`; shader decodes `style = floor(a*0.25)`. Colour variant no longer lives in `custom.a`.
- Profile knobs (`data/visual/*.tres`): `sub_form_enabled`, `crown_diameter_hex` (canopy ≈ 0.24–0.32 hex, about 2–3× a house), `cluster_density_threshold`, `grove_density_threshold`, `grove_crown_min/max`, `edge_single_bias`, `element_count_min/max` (non-canopy). Canopy instance size is derived so the crown diameter stays constant while count grows with density.
- Scatter: R2 low-discrepancy candidates; world noise evaluated before form choice; same-cell exclusion rejects instances with `dist < (ra+rb)*0.72`. C++ and GDScript fallback must stay per-instance identical.
- Style LUT (16×32 RGBAF): px0 wind/shape/family, px1 base colour, px2 casts/foot/length/strength, px3 form/phen_resp/phen_dom/veg_resp, px4 bloom/snow_ret/alb_floor/burial, px5 aquatic/size_floor/sat_gain/val_gain.
- Soft shadows are deliberately approximate (one ellipse per element, never the exact silhouette). In-quad: `vf_soft_shadow` (desktop q2, `hs>0.1`) reuses `vf_ring_slot`/`vf_grid_slot` and stretches each ellipse along `-L.xy/max(L.z,0.28)*hs*top` (cap `r0*1.1`); penumbra width and lightening grow with `len/(2.5r)` so noon is short/crisp and dusk long/soft. Out-of-quad: the cast pass uses one ellipse per instance, length `clamp(cot(elev),0,shadow_max_len=3.6)` (caps near 15.5° elevation, below that `local_day` fades it), and `shadow_soft` drives inner-penumbra, far-end spread and lightening. Family shadow materials are duplicated at configure time, so `VegetationFamilyLayer.sync_dynamic_materials()` must also copy the sun/day/season/tod_debug params to them.
- Performance: climate/GI/horizon sampling only in `vertex()`; fragment does the 3×3 field plus the analytic ellipse soft-shadow loop on desktop q2 (no second `vf_eval`). Far fallback `vf_far` when element radius < 3px (6px mobile). Budget reference: ~34k instances, vegetation GPU ≈ 0.11–0.14 ms, rebuild ≈ 9–12 ms.
- Tests: `tests/vegetation_form_scatter_test.gd` (pack round-trip, determinism, crown diameter, grove growth, exclusion, GD/native parity), `tests/vegetation_family_layer_test.gd` (LUT/pack), plus manifest perf / settlement avoidance / LOD tests. Contract doc: `docs/cpp-dots-runtime/computation-pipelines.md` → 俯视程序化冒名体.

## Performance Rules

For GPU-instanced visual layers, RTX-class hardware failing at 10k-20k instances usually indicates CPU/driver submission or shader/fill-rate mistakes, not raw instance count. Check these first:

- No `_process()` or timer should iterate all instances to call `set_instance_transform_2d`, `set_instance_color`, or `set_instance_custom_data` for climate changes.
- Build/rebuild may write all instance transforms once; runtime climate ticks should update only global textures/uniforms through existing atlas systems.
- Avoid Dictionary allocation in instance hot loops except rebuild/generation paths.
- Keep mesh complexity quality-tiered. Desktop high can use more lobes; mobile and low quality should reduce lobe count before reducing biological correctness.
- If a material needs per-cell dynamic values, sample the project global atlas/LUT rather than adding new per-object parameters.

## Profiles And Budgets

Move tunables into a `Resource` profile and default `.tres` under `data/visual/`.

Expose at least:

- Enabled flag.
- Density scale.
- Desktop and mobile quality tiers.
- Per-tier instance cap.
- Per-tier max-per-cell.
- Per-tier mesh complexity/lobe count.
- Per-tier size scale.
- River avoidance thresholds.
- PCG patch/cluster parameters.
- Climate response strengths.
- Vegetation vitality thresholds and response powers.

On mobile, do not assume `visual_quality` reflects the desired vegetation tier. Project.Keynes can force `visual_quality = 0` while using `mobile_quality_tier` for shader/device budget. Forward `set_mobile_quality_tier()` to the visual layer.

## Validation Checklist

Run available Godot checks after edits:

```powershell
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' --headless --path Project\project-keynes --check-only --script res://scripts/rendering/<layer>.gd
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' --headless --path Project\project-keynes --check-only --script res://scripts/data/<profile>.gd
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' --headless --path Project\project-keynes --quit
git diff --check -- <changed-files>
```

For logic-heavy visual rules, add temporary smoke scripts and delete them afterward. Useful assertions:

- Wet/healthy state has higher presence than dry/stressed/snow states.
- Dead vitality has near-zero density.
- Sparse vitality < healthy vitality for density, alpha, and size.
- PCG noise has nontrivial variation; it is not effectively constant.
- Candidate positions are scaled by `hex_size` and rejected from river body SDF.

## Reporting

When finishing, report:

- Which existing data sources were reused.
- Which profile fields control the visible effect.
- Which device/quality budgets apply.
- What validations ran.
- Any missing source masks, such as an absent road layer, and the fallback used.

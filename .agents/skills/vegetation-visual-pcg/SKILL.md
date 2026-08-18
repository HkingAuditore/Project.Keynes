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
- Build richer meshes from several simple lobes or sub-shapes instead of relying only on count; this makes each GPU instance read as a shrub/tree cluster rather than a dot.
- Use shader `INSTANCE_CUSTOM` for stable seed/variant and global-state sampling coordinates. Do not use it as a per-frame/per-day climate upload channel.
- Keep rendering side effects in the visual layer and renderer wiring. Do not add C++/DOTS work for purely visual scatter unless profiling proves GDScript rebuilds are the bottleneck.

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

# Perf Report — 20260707_v2

- ticks = 491
- columns = 462 (fixed-width payload CSV)

## FPS
- mean = 59.49 | median = 60.00 | p5 = 55.00 | min = 55.00 | max = 60.00

## Simulation cost (rolling 300-tick, ms)
- avg  = 3.099
- p95  = 4.797
- max  = 10.003
- sim_slice_budget_ms mean = 3.000 | min = 3.000
- ticks with largest_slice_ms > 1.0ms: **451 / 491** (91.9%)

## Job-level (ms / slices / fallback ticks)
- **j_ocean_currents**: ms mean=1.058 p95=2.346 max=2.613 | slices mean=0.7 max=1
- **j_native_daily_sim**: ms mean=1.652 p95=3.127 max=7.792 | slices mean=0.9 max=1
- **j_season_refresh**: ms mean=0.035 p95=0.040 max=0.084 | slices mean=1.0 max=1
- **j_natural_resource_daily**: ms mean=0.225 p95=0.277 max=0.371 | slices mean=1.0 max=1
- **j_enum_atlas_upload**: ms mean=0.107 p95=0.937 max=7.507 | slices mean=0.1 max=1
- **j_dynamic_visual_atlas_upload**: ms mean=0.161 p95=0.371 max=0.450 | slices mean=0.5 max=1

## Largest-slice spikes by stage / path
| rank | stage | path | count | max(ms) | mean(ms) | p95(ms) |
|---|---|---|---|---|---|---|
| 1 | weather | gdext_native_daily_slice | 41 | 7.77 | 2.90 | 3.05 |
| 2 | climate_pass_a | gdext_native_daily_slice | 41 | 3.89 | 3.00 | 3.64 |
| 3 | native_daily_complete | gdext_native_daily_slice | 41 | 3.88 | 3.11 | 3.63 |
| 4 | phys_wind | gdext | 78 | 2.60 | 1.89 | 2.55 |
| 5 | phys_psi_init | gdext | 39 | 2.09 | 1.74 | 1.92 |
| 6 | ocean_water | gdext_native_daily_slice | 41 | 2.08 | 1.80 | 2.02 |
| 7 | phys_slp | gdext | 80 | 2.04 | 1.70 | 1.92 |
| 8 | climate_pass_b | gdext_native_daily_slice | 2 | 1.80 | 1.68 | 1.80 |
| 9 | daily_wind_prepass | gdext_daily_wind_slp | 41 | 1.73 | 1.56 | 1.67 |
| 10 | runtime_hydrology | gdext_native_daily_slice | 2 | 1.70 | 1.62 | 1.70 |
| 11 | wind_air | gdext_native_daily_slice | 40 | 1.65 | 1.33 | 1.45 |
| 12 | ocean_land | gdext_native_daily_slice | 1 | 1.57 | 1.57 | 1.57 |
| 13 | transpiration | gdext_native_daily_slice | 4 | 1.56 | 1.36 | 1.56 |
| 14 | phys_upwelling | physical_circulation | 40 | 0.83 | 0.61 | 0.75 |

## Top-25 largest_slice_path by max(ms)
| rank | path | stage | count | max(ms) | mean(ms) |
|---|---|---|---|---|---|
| 1 | gdext_native_daily_slice | ocean_land | 213 | 7.77 | 2.40 |
| 2 | gdext | phys_wind | 197 | 2.60 | 1.79 |
| 3 | gdext_daily_wind_slp | daily_wind_prepass | 41 | 1.73 | 1.56 |
| 4 | physical_circulation | phys_upwelling | 40 | 0.83 | 0.61 |

## Fallback reasons (bd climate/weather/atlas)
- false: 245

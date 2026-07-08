# Perf Report — 20260708

- ticks = 778
- columns = 462 (fixed-width payload CSV)

## FPS
- mean = 59.76 | median = 60.00 | p5 = 56.00 | min = 56.00 | max = 60.00

## Simulation cost (rolling 300-tick, ms)
- avg  = 3.724
- p95  = 6.518
- max  = 8.396
- sim_slice_budget_ms mean = 3.000 | min = 3.000
- ticks with largest_slice_ms > 1.0ms: **716 / 778** (92.0%)

## Job-level (ms / slices / fallback ticks)
- **j_ocean_currents**: ms mean=1.131 p95=2.416 max=2.996 | slices mean=0.7 max=1
- **j_native_daily_sim**: ms mean=1.873 p95=3.572 max=7.460 | slices mean=0.9 max=1
- **j_season_refresh**: ms mean=0.037 p95=0.048 max=0.123 | slices mean=1.0 max=1
- **j_natural_resource_daily**: ms mean=0.244 p95=0.325 max=1.216 | slices mean=1.0 max=1
- **j_enum_atlas_upload**: ms mean=0.113 p95=0.922 max=6.223 | slices mean=0.1 max=1
- **j_dynamic_visual_atlas_upload**: ms mean=0.406 p95=0.906 max=1.881 | slices mean=0.5 max=1

## Largest-slice spikes by stage / path
| rank | stage | path | count | max(ms) | mean(ms) | p95(ms) |
|---|---|---|---|---|---|---|
| 1 | native_daily_complete | gdext_native_daily_slice | 65 | 7.44 | 3.65 | 4.82 |
| 2 | weather | gdext_native_daily_slice | 65 | 6.88 | 3.26 | 3.97 |
| 3 | climate_pass_a | gdext_native_daily_slice | 65 | 6.26 | 3.28 | 4.83 |
| 4 | ocean_water | gdext_native_daily_slice | 64 | 4.51 | 2.26 | 2.95 |
| 5 | sea_ice | gdext_native_daily_slice | 13 | 4.17 | 2.22 | 3.55 |
| 6 | runtime_hydrology | gdext_native_daily_slice | 4 | 3.87 | 2.84 | 3.87 |
| 7 | wind_air | gdext_native_daily_slice | 64 | 3.36 | 1.66 | 2.38 |
| 8 | phys_wind | gdext | 123 | 2.98 | 1.93 | 2.51 |
| 9 | climate_pass_b | gdext_native_daily_slice | 2 | 2.94 | 2.93 | 2.94 |
| 10 | phys_psi_init | gdext | 61 | 2.84 | 2.36 | 2.60 |
| 11 | phys_slp | gdext | 124 | 2.56 | 1.75 | 1.95 |
| 12 | wind_surface | gdext_native_daily_slice | 4 | 2.17 | 1.87 | 2.17 |
| 13 | ocean_land | gdext_native_daily_slice | 1 | 2.13 | 2.13 | 2.13 |
| 14 | transpiration | gdext_native_daily_slice | 6 | 2.07 | 1.63 | 2.07 |
| 15 | daily_wind_prepass | gdext_daily_wind_slp | 53 | 1.92 | 1.57 | 1.81 |
| 16 |  | cell_indirection_lut | 64 | 1.07 | 0.82 | 0.97 |

## Top-25 largest_slice_path by max(ms)
| rank | path | stage | count | max(ms) | mean(ms) |
|---|---|---|---|---|---|
| 1 | gdext_native_daily_slice | ocean_land | 353 | 7.44 | 2.77 |
| 2 | gdext | phys_psi_init | 308 | 2.98 | 1.94 |
| 3 | gdext_daily_wind_slp | daily_wind_prepass | 53 | 1.92 | 1.57 |
| 4 | cell_indirection_lut |  | 64 | 1.07 | 0.82 |

## Fallback reasons (bd climate/weather/atlas)
- false: 389

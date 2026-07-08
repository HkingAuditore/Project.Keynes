# Perf baseline — pre-Item-2 cell-range slicing

Source: `perf_record_20260707_202818.csv`
Rows (ticks): 491

## Frame-level
- fps: mean=59.49 p50=60.00 p5=55.00 min=55.00
- sus_sim_p95_300 (ms): mean=4.732 p95=4.797 max=4.797
- sus_sim_max_300 (ms): mean=5.990 p95=10.003 max=10.003
- sim_slice_budget_ms: mean=3.000
- largest-slice over budget: 43/491 = 8.8%

## Jobs observed as largest-slice source
- `ocean_currents`: 278
- `native_daily_sim`: 213

### By largest_slice_stage

| path/stage | count | mean(ms) | p50 | p95 | p99 | max | avg_cells | avg_cursor_span |
|---|---|---|---|---|---|---|---|---|
| `weather` | 41 | 2.896 | 2.730 | 3.046 | 7.767 | 7.767 | - | - |
| `climate_pass_a` | 41 | 3.005 | 2.956 | 3.644 | 3.894 | 3.894 | - | - |
| `native_daily_complete` | 41 | 3.109 | 3.037 | 3.627 | 3.879 | 3.879 | - | - |
| `phys_wind` | 78 | 1.892 | 2.153 | 2.563 | 2.602 | 2.602 | - | - |
| `phys_psi_init` | 39 | 1.744 | 1.724 | 1.936 | 2.091 | 2.091 | - | - |
| `ocean_water` | 41 | 1.804 | 1.792 | 2.023 | 2.076 | 2.076 | 1 | - |
| `phys_slp` | 80 | 1.701 | 1.688 | 1.980 | 2.042 | 2.042 | - | - |
| `climate_pass_b` | 2 | 1.680 | 1.805 | 1.805 | 1.805 | 1.805 | - | - |
| `daily_wind_prepass` | 41 | 1.558 | 1.545 | 1.670 | 1.728 | 1.728 | 6400 | - |
| `runtime_hydrology` | 2 | 1.623 | 1.700 | 1.700 | 1.700 | 1.700 | - | - |
| `wind_air` | 40 | 1.328 | 1.323 | 1.637 | 1.653 | 1.653 | - | - |
| `ocean_land` | 1 | 1.575 | 1.575 | 1.575 | 1.575 | 1.575 | 1 | - |
| `transpiration` | 4 | 1.359 | 1.364 | 1.563 | 1.563 | 1.563 | - | - |
| `phys_upwelling` | 40 | 0.613 | 0.594 | 0.780 | 0.829 | 0.829 | - | - |
### By largest_slice_path (all)

| path/stage | count | mean(ms) | p50 | p95 | p99 | max | avg_cells | avg_cursor_span |
|---|---|---|---|---|---|---|---|---|
| `gdext_native_daily_slice` | 213 | 2.395 | 2.636 | 3.488 | 3.894 | 7.767 | 0 | - |
| `gdext` | 197 | 1.785 | 1.704 | 2.447 | 2.574 | 2.602 | - | - |
| `gdext_daily_wind_slp` | 41 | 1.558 | 1.545 | 1.670 | 1.728 | 1.728 | 6400 | - |
| `physical_circulation` | 40 | 0.613 | 0.594 | 0.780 | 0.829 | 0.829 | - | - |
### Top 25 slice paths by MAX ms
| # | path | count | mean | p95 | max | avg_cells | avg_cursor_span |
|---|---|---|---|---|---|---|---|
| 1 | `gdext_native_daily_slice` | 213 | 2.395 | 3.488 | 7.767 | 0 | - |
| 2 | `gdext` | 197 | 1.785 | 2.447 | 2.602 | - | - |
| 3 | `gdext_daily_wind_slp` | 41 | 1.558 | 1.670 | 1.728 | 6400 | - |
| 4 | `physical_circulation` | 40 | 0.613 | 0.780 | 0.829 | - | - |

### Ocean job by j_ocean_currents_path

| path/stage | count | mean(ms) | p50 | p95 | p99 | max | avg_cells | avg_cursor_span |
|---|---|---|---|---|---|---|---|---|
| `gdext` | 204 | 1.789 | 1.712 | 2.455 | 2.585 | 2.613 | - | - |
| `gdext_daily_wind_slp` | 82 | 1.571 | 1.536 | 1.739 | 2.421 | 2.421 | 6400 | - |
| `physical_circulation` | 41 | 0.624 | 0.605 | 0.761 | 0.846 | 0.846 | - | - |
| `(none)` | 164 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | - | - |
### Native daily sim by j_native_daily_sim_path

| path/stage | count | mean(ms) | p50 | p95 | p99 | max | avg_cells | avg_cursor_span |
|---|---|---|---|---|---|---|---|---|
| `gdext_native_daily_slice` | 450 | 1.802 | 1.404 | 3.141 | 3.827 | 7.792 | - | - |
| `(none)` | 41 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | - | - |
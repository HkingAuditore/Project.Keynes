# 2026-06-10 climate slice review

Source: `tmp/tile_data_record_20260610_010152.csv`

Scale:
- 1,300,800 rows
- 2,400 cells per tick
- 542 ticks, tick 1251..1792

## Main Findings

1. Temperature is not physically plausible in the current dump.
   - Neighbor temperature delta p95 = 0.244, p99 = 0.373, max = 0.645.
   - Coast neighbor temperature delta p95 = 0.333, p99 = 0.419, max = 0.645.
   - A persistent whole-row jump appears between lat_norm 0.487179 and 0.512821. Example tick 1257: row mean 0.840 -> 0.572, delta 0.268.
   - The largest neighbor edge repeats around cells 1185/1246: water mountain-like cell temp ~0.30 beside land cell temp ~0.95.
   - Latitudinal pattern is inverted/implausible in this sample: land tropics mean temp 0.214, water tropics 0.257, while S_polar land/water means are 0.461/0.501.

2. Weather generation has plausible local ordering but too-sharp spatial boundaries.
   - CLEAR/RAIN/STORM/BLIZZARD/FOG numeric behavior is broadly ordered as expected:
     CLEAR precip 0.032, RAIN 0.101, STORM 0.255, BLIZZARD temp 0.244.
   - Neighbor weather type differs on 25.2% of neighbor edges, which can be acceptable for fronts but combines with large temp/moisture jumps.
   - Heavy precipitation with low vapor occurs 428 times, small but worth checking.

3. Wind and ocean current are not acting like dynamic physical drivers in this dump.
   - wind_mag is effectively constant at 1.0 everywhere and tick-to-tick wind delta p99 = 0.
   - air_mass_temp_anomaly_arr is zero across the analyzed groups, so wind heat transport has no visible effect in the CSV.
   - ocean_vector tick delta p99 = 0 and SLP/wind/ocean fields are mostly static over the dump.
   - water_ocean_current_zero appears 253,645 times and land_ocean_current_nonzero 71,002 times, suggesting a terrain/is_water or recording mask mismatch.
   - Upwelling has a strong cooling relation with water temp (r = -0.452), but ocean current magnitude only weakly correlates with transport anomaly (r = 0.133).

4. Moisture and precipitation are partly plausible but too discontinuous.
   - Precip correlates with vapor r = 0.419, cloud r = 0.372, instability r = 0.421.
   - Moisture tracks base moisture very strongly r = 0.945, meaning much of the moisture map is static baseline rather than weather-driven evolution.
   - Neighbor moisture delta p95 = 0.367, p99 = 0.488, max = 0.689: spatial moisture discontinuity is severe.
   - Tick-to-tick precip/vapor/cloud medians are 0, so fields often remain frozen, with occasional sharp local jumps.

## Likely Code-Level Causes

- Temperature pass A uses per-cell latitude baseline plus elevation penalty and thermal inertia, but there is no final spatial smoothing/diffusion pass to constrain neighbor gradients.
- Ocean and wind heat transport mix directly with upstream cells (`lerpf(temp_self, temp_up, heat_mix)`) and can bypass the apparent daily delta cap.
- In this dump, wind heat transport is probably not actually contributing: `air_mass_temp_anomaly_arr` is zero, and wind vectors are static unit vectors.
- Ocean current/is_water inconsistencies suggest some systems key off `terrain_arr` while the recorder/check uses `is_water_arr`.
- Weather field solver uses wind advection and diffusion, but with static wind and strong baseline moisture, it can preserve bands rather than evolve them naturally.


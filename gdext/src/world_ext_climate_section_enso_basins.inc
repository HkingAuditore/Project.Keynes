// ─── F.2a: ocean water pass ─────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// _ocean_water_pass_soa (map_generator.gd:4679+) hot loop:
//   for each WATER cell i with non-zero current:
//     advect upstream `advect_steps` times (pick best dot vs -current dir)
//     temp_mixed = lerp(temp_before[i], temp_before[upstream], heat_mix)
//     temp_a[i] = clamp(temp_mixed, 0, 1)
//     anomaly_out[i] = lerp(prev_tta, clamp(temp_mixed - baseline[i], source_cap), blend)
//   for each WATER cell i with zero current OR advect_steps==0:
//     anomaly_out[i] = prev_tta * (1 - zero_current_decay)
//
// Caller-side responsibility (与 GDScript path 一致)：
//   * pre-compute baseline[]  (ema_init=true → temp_baseline_a, else compute_temperature)
//   * pre-compute temp_before[] (temp_a > 0 → temp_a, else baseline)
//   * pass anomaly_out as scratch buffer (water cells written; land cells preserved
//     for subsequent run_ocean_land_pass call)
//   * after both passes return, copy anomaly_out → cells[i].temperature_transport_anomaly
// pk_limit_cold_water_positive_transport_source 已在 S3 搬到 runtime_climate_pass_math.h。

void DCWorldExt::_ensure_enso_basin_cache(
        int n_cells, const uint8_t *is_water, const uint8_t *terrain,
        const float *lat_norm, const float *pos_x, const int32_t *neighbors,
        const PackedByteArray &ocean_terrain_ids, float tropical_lat_limit,
        int max_basins, float wrap_period_x, int world_seed) {
    const auto t0 = std::chrono::high_resolution_clock::now();
    uint64_t fp = 1469598103934665603ull;
    auto mix = [&fp](uint64_t v) { fp ^= v; fp *= 1099511628211ull; };
    mix(uint64_t(n_cells));
    mix(uint64_t(std::lround(tropical_lat_limit * 10000.0f)));
    mix(uint64_t(max_basins));
    mix(uint64_t(std::lround(wrap_period_x * 1000.0f)));
    for (int i = 0; i < n_cells; ++i) {
        mix(uint64_t(is_water[i]));
        mix(uint64_t(std::lround(lat_norm[i] * 10000.0f)));
    }
    for (int i = 0; i < n_cells * 6; ++i) mix(uint64_t(uint32_t(neighbors[i])));
    if (_enso_cache_valid && _enso_cache_fp == fp) {
        _enso_cache_last_hit = true;
        return;
    }
    _enso_cache_last_hit = false;

    bool terrain_lut[256] = {};
    for (int i = 0; i < ocean_terrain_ids.size(); ++i) {
        terrain_lut[uint8_t(ocean_terrain_ids[i])] = true;
    }
    const bool filter_terrain = terrain != nullptr && !ocean_terrain_ids.is_empty();
    auto eligible = [&](int i) {
        const float signed_lat = std::abs((lat_norm[i] - 0.5f) * 2.0f);
        return is_water[i] != 0 && signed_lat <= tropical_lat_limit &&
               (!filter_terrain || terrain_lut[terrain[i]]);
    };

    struct Candidate { std::vector<int32_t> cells; uint64_t signature = 0; };
    std::vector<Candidate> candidates;
    std::vector<uint8_t> seen(static_cast<size_t>(n_cells), 0);
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(n_cells));
    const int min_cells = std::max(24, int(std::sqrt(double(n_cells)) * 0.45));
    for (int seed = 0; seed < n_cells; ++seed) {
        if (seen[seed] || !eligible(seed)) continue;
        queue.clear();
        queue.push_back(seed);
        seen[seed] = 1;
        for (size_t head = 0; head < queue.size(); ++head) {
            const int cur = queue[head];
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[cur * 6 + d];
                if (ni < 0 || ni >= n_cells || seen[ni] || !eligible(ni)) continue;
                seen[ni] = 1;
                queue.push_back(ni);
            }
        }
        if (int(queue.size()) < min_cells) continue;
        Candidate c;
        c.cells = queue;
        std::sort(c.cells.begin(), c.cells.end());
        uint64_t sig = 1469598103934665603ull;
        for (int32_t idx : c.cells) { sig ^= uint64_t(uint32_t(idx)); sig *= 1099511628211ull; }
        c.signature = sig;
        candidates.push_back(std::move(c));
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) {
        if (a.cells.size() != b.cells.size()) return a.cells.size() > b.cells.size();
        return a.signature < b.signature;
    });
    if (int(candidates.size()) > max_basins) candidates.resize(static_cast<size_t>(max_basins));

    const std::vector<EnsoBasinState> old_states = _enso_states;
    _enso_basin_id.assign(static_cast<size_t>(n_cells), int8_t(-1));
    _enso_eastness.assign(static_cast<size_t>(n_cells), 0.0f);
    _enso_prev_forcing.assign(static_cast<size_t>(n_cells), 0.0f);
    _enso_members.clear();
    _enso_basins.clear();
    _enso_states.clear();
    for (int bi = 0; bi < int(candidates.size()); ++bi) {
        const Candidate &c = candidates[bi];
        EnsoBasinMeta meta;
        meta.signature = c.signature;
        meta.member_begin = int(_enso_members.size());
        meta.member_count = int(c.cells.size());
        double cx = 0.0;
        if (wrap_period_x > 0.0f) {
            double sx = 0.0, sy = 0.0;
            for (int idx : c.cells) {
                const double a = 2.0 * M_PI * double(pos_x[idx]) / double(wrap_period_x);
                sx += simulation_math::cos(a); sy += simulation_math::sin(a);
            }
            cx = simulation_math::atan2(sy, sx) * double(wrap_period_x) / (2.0 * M_PI);
        } else {
            for (int idx : c.cells) cx += pos_x[idx];
            cx /= std::max<size_t>(1, c.cells.size());
        }
        double max_abs_dx = 1e-6;
        for (int idx : c.cells) {
            const double dx = pk_wrap_min_image_dx(float(double(pos_x[idx]) - cx), wrap_period_x);
            max_abs_dx = std::max(max_abs_dx, std::abs(dx));
        }
        meta.span_x = float(max_abs_dx * 2.0);
        for (int idx : c.cells) {
            _enso_members.push_back(idx);
            _enso_basin_id[static_cast<size_t>(idx)] = int8_t(bi);
            const float dx = pk_wrap_min_image_dx(float(double(pos_x[idx]) - cx), wrap_period_x);
            _enso_eastness[static_cast<size_t>(idx)] = dc_clampf(dx / float(max_abs_dx), -1.0f, 1.0f);
        }
        _enso_basins.push_back(meta);
        EnsoBasinState state;
        state.signature = c.signature;
        bool restored = false;
        for (const EnsoBasinState &old : old_states) {
            if (old.signature == c.signature) { state = old; restored = true; break; }
        }
        if (!restored) {
            uint64_t h = c.signature ^ (uint64_t(uint32_t(world_seed)) * 0x9e3779b97f4a7c15ull);
            state.temp_index = ((h >> 11) & 1ull) ? 0.018f : -0.018f;
            state.recharge_index = ((h >> 17) & 1ull) ? -0.010f : 0.010f;
        }
        _enso_states.push_back(state);
    }
    _enso_wind_sum.assign(_enso_states.size(), 0.0);
    _enso_wind_count.assign(_enso_states.size(), 0);

    if (!_climate_modes_pending_restore.is_empty()) {
        Array saved = _climate_modes_pending_restore.get("enso_basins", Array());
        for (int si = 0; si < saved.size(); ++si) {
            Dictionary d = saved[si];
            const uint64_t sig = uint64_t(int64_t(d.get("signature", int64_t(0))));
            for (EnsoBasinState &state : _enso_states) {
                if (state.signature != sig) continue;
                state.temp_index = dc_clampf(float(d.get("temp_index", state.temp_index)), -1.0f, 1.0f);
                state.recharge_index = dc_clampf(float(d.get("recharge_index", state.recharge_index)), -1.0f, 1.0f);
                state.wind_ema = float(d.get("wind_ema", 0.0));
                state.wind_anomaly = float(d.get("wind_anomaly", 0.0));
                state.last_update_tick = int64_t(d.get("last_update_tick", -1));
            }
        }
        _climate_modes_pending_restore.erase("enso_basins");
        const float restored_cap = dc_clampf(float(_native_runtime_config.get(
            "enso_temp_anomaly_cap", 0.06)), 0.0f, 0.12f);
        for (int i = 0; i < n_cells; ++i) {
            const int bi = int(_enso_basin_id[static_cast<size_t>(i)]);
            if (bi < 0 || bi >= int(_enso_states.size())) continue;
            const float east = _enso_eastness[static_cast<size_t>(i)];
            const float shape = east >= 0.0f ? east : 0.35f * east;
            _enso_prev_forcing[static_cast<size_t>(i)] =
                restored_cap * _enso_states[static_cast<size_t>(bi)].temp_index * shape;
        }
    }
    _enso_cache_fp = fp;
    _enso_cache_valid = true;
    const auto t1 = std::chrono::high_resolution_clock::now();
    _enso_cache_build_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
}

void DCWorldExt::_apply_enso_ocean_slice(
        Dictionary &knobs, int n_cells, int start_idx, int end_idx,
        const uint8_t *is_water, const uint8_t *terrain, const float *lat_norm,
        const float *pos_x, const int32_t *neighbors, const float *wind_x,
        const float *wind_speed, float *ocean_anomaly, float *transport_anomaly) {
    const bool enabled = bool(knobs.get("enso_basin_modes_enabled",
        _native_runtime_config.get("enso_basin_modes_enabled", false)));
    if (!enabled || lat_norm == nullptr || wind_x == nullptr || wind_speed == nullptr) return;
    const int max_basins = std::clamp(int(knobs.get("enso_max_basins",
        _native_runtime_config.get("enso_max_basins", 3))), 1, 3);
    const float lat_limit = dc_clampf(float(knobs.get("enso_tropical_lat_limit",
        _native_runtime_config.get("enso_tropical_lat_limit", 0.33))), 0.10f, 0.50f);
    const float wrap_x = float(knobs.get("wrap_period_x", _native_wrap_period_x));
    PackedByteArray ocean_ids = knobs.get("enso_ocean_terrain_ids", PackedByteArray());
    const int world_seed = int(knobs.get("world_seed", _native_runtime_config.get("world_seed", 0)));
    _ensure_enso_basin_cache(n_cells, is_water, terrain, lat_norm, pos_x, neighbors,
                             ocean_ids, lat_limit, max_basins, wrap_x, world_seed);
    if (_enso_states.empty()) return;

    if (start_idx == 0) {
        const float period = std::max(730.0f, float(knobs.get("enso_period_days",
            _native_runtime_config.get("enso_period_days", 1460.0))));
        const float dt_total = std::max(0.0f, float(knobs.get("dt_days", 1.0)));
        const float substep = std::max(1.0f, float(knobs.get("enso_integration_substep_days",
            _native_runtime_config.get("enso_integration_substep_days", 10.0))));
        const float coupling = std::max(0.0f, float(knobs.get("enso_wind_coupling",
            _native_runtime_config.get("enso_wind_coupling", 0.0008))));
        const int steps = std::max(1, int(std::ceil(dt_total / substep)));
        const float dt = dt_total / float(steps);
        const float omega = float(2.0 * M_PI) / period;
        for (EnsoBasinState &s : _enso_states) {
            for (int k = 0; k < steps; ++k) {
                const float t0 = s.temp_index, h0 = s.recharge_index;
                const float d_t0 = omega * h0 + 0.0012f * (1.0f - t0 * t0) * t0
                    + coupling * s.wind_anomaly;
                const float d_h0 = -omega * t0 - 0.00025f * h0;
                const float tp = t0 + dt * d_t0, hp = h0 + dt * d_h0;
                const float d_t1 = omega * hp + 0.0012f * (1.0f - tp * tp) * tp
                    + coupling * s.wind_anomaly;
                const float d_h1 = -omega * tp - 0.00025f * hp;
                s.temp_index = dc_clampf(t0 + 0.5f * dt * (d_t0 + d_t1), -1.0f, 1.0f);
                s.recharge_index = dc_clampf(h0 + 0.5f * dt * (d_h0 + d_h1), -1.0f, 1.0f);
            }
            s.last_update_tick = int64_t(knobs.get("day_index", _native_daily_tick_count));
        }
        std::fill(_enso_wind_sum.begin(), _enso_wind_sum.end(), 0.0);
        std::fill(_enso_wind_count.begin(), _enso_wind_count.end(), 0);
    }
    const float cap = dc_clampf(float(knobs.get("enso_temp_anomaly_cap",
        _native_runtime_config.get("enso_temp_anomaly_cap", 0.06))), 0.0f, 0.12f);
    for (int i = start_idx; i < end_idx; ++i) {
        const int bi = (i < int(_enso_basin_id.size())) ? int(_enso_basin_id[static_cast<size_t>(i)]) : -1;
        if (bi < 0 || bi >= int(_enso_states.size()) || is_water[i] == 0) continue;
        const float previous = _enso_prev_forcing[static_cast<size_t>(i)];
        const float east = _enso_eastness[static_cast<size_t>(i)];
        const float shape = east >= 0.0f ? east : 0.35f * east;
        const float forcing = cap * _enso_states[static_cast<size_t>(bi)].temp_index * shape;
        ocean_anomaly[i] = dc_clampf(ocean_anomaly[i] - previous + forcing, -0.12f, 0.12f);
        transport_anomaly[i] = dc_clampf(transport_anomaly[i] - previous + forcing, -0.5f, 0.5f);
        _enso_prev_forcing[static_cast<size_t>(i)] = forcing;
        _enso_wind_sum[static_cast<size_t>(bi)] += double(wind_x[i] * wind_speed[i]);
        ++_enso_wind_count[static_cast<size_t>(bi)];
    }
    if (end_idx == n_cells) {
        for (size_t bi = 0; bi < _enso_states.size(); ++bi) {
            if (_enso_wind_count[bi] <= 0) continue;
            const float mean = float(_enso_wind_sum[bi] / double(_enso_wind_count[bi]));
            EnsoBasinState &s = _enso_states[bi];
            const float old = s.wind_ema;
            s.wind_ema += 0.05f * (mean - s.wind_ema);
            s.wind_anomaly = s.wind_ema - old;
        }
    }
    knobs["enso_basin_count"] = int(_enso_states.size());
    knobs["enso_cache_hit"] = _enso_cache_last_hit;
    knobs["enso_cache_build_ms"] = _enso_cache_build_ms;
}

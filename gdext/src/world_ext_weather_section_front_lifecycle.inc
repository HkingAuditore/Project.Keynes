// ─── F.6 main pass ──────────────────────────────────────────────────────────
//
// 1:1 mirror of scripts/weather/weather_front.gd::advance_one_day +
// refresh_visual_lifecycle (line 74-127).
//
// fronts ≤ 16 → 不分 phase / 不需要 stage buffer，直接 in-place 改 batch
// 内的 PackedArray ptrw。emergent_coupling（decay_mul / precip_bonus）由
// caller 在 GDScript 端预算（需要 map 查询），通过：
//   1. caller 改 fronts[i].decay_per_day *= decay_mul（pack 之前）
//   2. caller 在 apply_dict_to_fronts 之后再加 precip_bonus 到 precip_amount
// C++ 端只做"机械"循环（无 map 访问 / 无 Variant）。
double DCWorldExt::run_weather_front_advect_pass(Dictionary knobs) {
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;
    using godot::PackedVector2Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_front_advect_pass: ", why,
            " — fallback to GDScript");
    };

    if (!knobs.has("n_fronts")) { diag("missing n_fronts"); return -1.0; }
    const int n = int(knobs["n_fronts"]);
    if (n <= 0) {
        // 空 front 列表是合法情况（某些季节没有活跃 front）；
        // 不打 warning，只 return 0.0（视为成功完成 0 行工作）。
        return 0.0;
    }
    const float max_turn = float(knobs.get("max_axis_turn_rad", 0.383972f));

    // 必填 keys。缺任一即 fallback。
    static const char *required_keys[] = {
        "front_center_x", "front_center_y",
        "front_velocity_x", "front_velocity_y",
        "front_axis_x", "front_axis_y",
        "front_stable_axis_x", "front_stable_axis_y",
        "front_radius", "front_intensity", "front_decay_per_day",
        "front_age_days", "front_type", "front_ttl_days",
        "front_life_progress", "front_cloud_amount",
        "front_precip_amount", "front_dissolve_amount", "front_alive",
        "wind_per_front",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_weather_front_advect_pass: missing key '", k, "'");
            return -1.0;
        }
    }

    // 取 PackedArray（CoW shared via Dictionary refcount）。
    PackedFloat32Array center_x = knobs["front_center_x"];
    PackedFloat32Array center_y = knobs["front_center_y"];
    PackedFloat32Array velocity_x = knobs["front_velocity_x"];
    PackedFloat32Array velocity_y = knobs["front_velocity_y"];
    PackedFloat32Array axis_x = knobs["front_axis_x"];
    PackedFloat32Array axis_y = knobs["front_axis_y"];
    PackedFloat32Array stable_axis_x = knobs["front_stable_axis_x"];
    PackedFloat32Array stable_axis_y = knobs["front_stable_axis_y"];
    PackedFloat32Array radius_arr = knobs["front_radius"];
    PackedFloat32Array intensity_arr = knobs["front_intensity"];
    PackedFloat32Array decay_arr = knobs["front_decay_per_day"];
    PackedInt32Array   age_days_arr = knobs["front_age_days"];
    PackedInt32Array   type_arr = knobs["front_type"];
    PackedInt32Array   ttl_arr = knobs["front_ttl_days"];
    PackedFloat32Array life_progress_arr = knobs["front_life_progress"];
    PackedFloat32Array cloud_amount_arr = knobs["front_cloud_amount"];
    PackedFloat32Array precip_amount_arr = knobs["front_precip_amount"];
    PackedFloat32Array dissolve_amount_arr = knobs["front_dissolve_amount"];
    PackedByteArray    alive_arr = knobs["front_alive"];
    PackedVector2Array wind_arr = knobs["wind_per_front"];

    // size 校验
    if (center_x.size() != n || center_y.size() != n ||
        velocity_x.size() != n || velocity_y.size() != n ||
        axis_x.size() != n || axis_y.size() != n ||
        stable_axis_x.size() != n || stable_axis_y.size() != n ||
        radius_arr.size() != n || intensity_arr.size() != n ||
        decay_arr.size() != n || age_days_arr.size() != n ||
        type_arr.size() != n || ttl_arr.size() != n ||
        life_progress_arr.size() != n || cloud_amount_arr.size() != n ||
        precip_amount_arr.size() != n || dissolve_amount_arr.size() != n ||
        alive_arr.size() != n || wind_arr.size() != n) {
        diag("PackedArray size != n_fronts");
        return -1.0;
    }

    // ptrw / ptr
    float * const __restrict CX = center_x.ptrw();
    float * const __restrict CY = center_y.ptrw();
    float * const __restrict VX = velocity_x.ptrw();
    float * const __restrict VY = velocity_y.ptrw();
    float * const __restrict AX = axis_x.ptrw();
    float * const __restrict AY = axis_y.ptrw();
    float * const __restrict SAX = stable_axis_x.ptrw();
    float * const __restrict SAY = stable_axis_y.ptrw();
    const float * const __restrict R   = radius_arr.ptr();
    float * const __restrict I_  = intensity_arr.ptrw();
    const float * const __restrict D   = decay_arr.ptr();
    int32_t * const __restrict AGE = age_days_arr.ptrw();
    const int32_t * const __restrict TY = type_arr.ptr();
    const int32_t * const __restrict TTL = ttl_arr.ptr();
    float * const __restrict LP  = life_progress_arr.ptrw();
    float * const __restrict CA  = cloud_amount_arr.ptrw();
    float * const __restrict PA  = precip_amount_arr.ptrw();
    float * const __restrict DA  = dissolve_amount_arr.ptrw();
    uint8_t * const __restrict AL = alive_arr.ptrw();
    const godot::Vector2 * const __restrict WIND = wind_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // helpers
    auto length2 = [](float x, float y) -> float { return x*x + y*y; };
    auto smoothstep_fn = [](float a, float b, float x) -> float {
        if (b <= a) return x >= b ? 1.0f : 0.0f;
        float t = (x - a) / (b - a);
        if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
        return t * t * (3.0f - 2.0f * t);
    };
    auto clampf = [](float v, float lo, float hi) -> float {
        return v < lo ? lo : (v > hi ? hi : v);
    };
    auto maxf2 = [](float a, float b) -> float { return a > b ? a : b; };

    // WeatherType.WT enum (weather_type.gd:23-32):
    //   CLEAR=0, RAIN=1, STORM=2, BLIZZARD=3, DROUGHT=4, FOG=5, HEATWAVE=6, MONSOON=7
    constexpr int WT_CLEAR    = 0;
    constexpr int WT_STORM    = 2;
    constexpr int WT_BLIZZARD = 3;
    constexpr int WT_DROUGHT  = 4;
    constexpr int WT_FOG      = 5;
    constexpr int WT_HEATWAVE = 6;
    constexpr int WT_MONSOON  = 7;

    for (int i = 0; i < n; ++i) {
        // ─── advance_one_day part ─────────────────────────────────────
        const godot::Vector2 wind = WIND[i];
        const float wind_len2 = length2(wind.x, wind.y);
        if (wind_len2 > 0.0025f /* 0.05^2 */) {
            // wind 有效 → 旋转 stable_axis 朝向 wind_axis（最多 max_turn 弧度）
            const float wind_len = std::sqrt(wind_len2);
            const float wax = wind.x / wind_len;
            const float way = wind.y / wind_len;

            // from_axis = stable_axis (or fallback Vector2.RIGHT if degenerate)
            float fx = SAX[i];
            float fy = SAY[i];
            float fl2 = length2(fx, fy);
            if (fl2 < 0.0001f) { fx = 1.0f; fy = 0.0f; fl2 = 1.0f; }
            const float fl = std::sqrt(fl2);
            fx /= fl; fy /= fl;

            // delta_angle = angle_to(from, to) = atan2(cross, dot)（与 GDScript Vector2.angle_to 等价）
            const float dot_   = fx * wax + fy * way;
            const float cross_ = fx * way - fy * wax;
            float delta = simulation_math::atan2(cross_, dot_);
            if (delta > max_turn) delta = max_turn;
            else if (delta < -max_turn) delta = -max_turn;

            // out = from.rotated(delta)
            const float cs = simulation_math::cos(delta);
            const float sn = simulation_math::sin(delta);
            float out_x = fx * cs - fy * sn;
            float out_y = fx * sn + fy * cs;
            const float ol2 = length2(out_x, out_y);
            if (ol2 > 0.0001f) {
                const float ol = std::sqrt(ol2);
                out_x /= ol; out_y /= ol;
            } else {
                // degenerate → keep from_axis
                out_x = fx; out_y = fy;
            }

            SAX[i] = out_x; SAY[i] = out_y;
            AX[i]  = out_x; AY[i]  = out_y;
            VX[i] = out_x * (R[i] * 0.4f);
            VY[i] = out_y * (R[i] * 0.4f);
        }
        // center += velocity
        CX[i] += VX[i];
        CY[i] += VY[i];
        // intensity = max(intensity - decay_per_day, 0)
        float new_i = I_[i] - D[i];
        if (new_i < 0.0f) new_i = 0.0f;
        I_[i] = new_i;
        // age_days++
        AGE[i] += 1;

        // ─── refresh_visual_lifecycle part ────────────────────────────
        const float ttl_f = (TTL[i] >= 1) ? float(TTL[i]) : 1.0f;
        float life_p = float(AGE[i]) / ttl_f;
        if (life_p < 0.0f) life_p = 0.0f; else if (life_p > 1.0f) life_p = 1.0f;
        LP[i] = life_p;

        const float dissolve = smoothstep_fn(0.58f, 1.0f, life_p);
        DA[i] = dissolve;

        // _visual_intensity(intensity)
        const float raw_i = clampf(new_i, 0.0f, 1.0f);
        float visual_i = 0.0f;
        if (raw_i > 0.0f) {
            // pow(raw_i, 0.55) * smoothstep(0, 0.08, raw_i)
            const float pw = simulation_math::pow(raw_i, 0.55f);
            const float ss = smoothstep_fn(0.0f, 0.08f, raw_i);
            visual_i = clampf(pw * ss, 0.0f, 1.0f);
        }

        const float birth = smoothstep_fn(0.0f, 0.32f, life_p);
        float cloud_retire  = 1.0f - smoothstep_fn(0.78f, 1.0f, life_p);
        float precip_retire = 1.0f - smoothstep_fn(0.56f, 0.88f, life_p);

        float cloud_mul = 1.0f;
        float precip_mul = 1.0f;
        const int t_kind = TY[i];
        switch (t_kind) {
            case WT_STORM:
                cloud_mul = 1.22f;
                precip_mul = 1.32f;
                precip_retire = 1.0f - smoothstep_fn(0.46f, 0.80f, life_p);
                break;
            case WT_MONSOON:
                cloud_mul = 1.18f;
                precip_mul = 1.22f;
                precip_retire = 1.0f - smoothstep_fn(0.70f, 0.96f, life_p);
                break;
            case WT_BLIZZARD:
                cloud_mul = 1.10f;
                precip_mul = 1.18f;
                break;
            case WT_FOG:
                cloud_mul = 1.28f;
                precip_mul = 0.0f;
                cloud_retire = 1.0f - smoothstep_fn(0.62f, 1.0f, life_p);
                break;
            case WT_DROUGHT:
            case WT_HEATWAVE:
                cloud_mul = 0.24f;
                precip_mul = 0.0f;
                break;
            case WT_CLEAR:
                cloud_mul = 0.0f;
                precip_mul = 0.0f;
                break;
            default:
                // RAIN 等：保持 1.0 / 1.0
                break;
        }
        (void) maxf2; // 未使用（保留 helper 给未来扩展）
        CA[i] = clampf(visual_i * birth * cloud_retire * cloud_mul, 0.0f, 1.0f);
        PA[i] = clampf(visual_i * birth * precip_retire * precip_mul, 0.0f, 1.0f);

        // is_alive: intensity > 0.01 && age_days < ttl_days
        AL[i] = (new_i > 0.01f && AGE[i] < TTL[i]) ? 1 : 0;
    }

    // 写回 knobs（PackedArray 是 CoW：ptrw 后已经 detach；这里赋值确保
    // GDScript 端 Dictionary 拿到的是新 buffer 而不是 stale alias）。
    knobs["front_center_x"] = center_x;
    knobs["front_center_y"] = center_y;
    knobs["front_velocity_x"] = velocity_x;
    knobs["front_velocity_y"] = velocity_y;
    knobs["front_axis_x"] = axis_x;
    knobs["front_axis_y"] = axis_y;
    knobs["front_stable_axis_x"] = stable_axis_x;
    knobs["front_stable_axis_y"] = stable_axis_y;
    knobs["front_intensity"] = intensity_arr;
    knobs["front_age_days"] = age_days_arr;
    knobs["front_life_progress"] = life_progress_arr;
    knobs["front_cloud_amount"] = cloud_amount_arr;
    knobs["front_precip_amount"] = precip_amount_arr;
    knobs["front_dissolve_amount"] = dissolve_amount_arr;
    knobs["front_alive"] = alive_arr;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

Dictionary DCWorldExt::get_cyclone_perturbations_dict() const {
    Dictionary out;
    out.clear();
    for (const auto &e : _cyclone_perturbations) {
        Dictionary d;
        d["vec"]        = e.vec;
        d["vec_init"]   = e.vec_init;
        d["days_left"]  = e.days_left;
        d["init_days"]  = e.init_days;
        // key 用 int64 —— GDScript Dictionary 接受 int key（自动 Variant::INT）
        out[godot::Variant(int64_t(e.key))] = d;
    }
    return out;
}

Dictionary DCWorldExt::get_active_cyclone_snapshot() const {
    Dictionary out;
    Array entries;
    entries.resize(int(_cyclone_perturbations.size()));
    for (int i = 0; i < int(_cyclone_perturbations.size()); ++i) {
        const CycloneWakeEntry &e = _cyclone_perturbations[static_cast<size_t>(i)];
        Dictionary d;
        d["stable_id"] = int64_t(e.stable_id);
        d["cell_idx"] = e.cell_idx;
        d["steering"] = e.steering;
        d["intensity"] = e.intensity;
        d["radius_cells"] = e.radius_cells;
        d["age_days"] = e.age_days;
        d["days_left"] = e.days_left;
        entries[i] = d;
    }
    out["count"] = entries.size();
    out["capacity"] = int(_native_runtime_config.get("tropical_cyclone_capacity", 24));
    out["cyclones"] = entries;
    return out;
}

Dictionary DCWorldExt::get_climate_modes_report() const {
    Dictionary out;
    out["thermal_monsoon_enabled"] = bool(_native_runtime_config.get("thermal_monsoon_enabled", false));
    out["monsoon_eligible_cells"] = _monsoon_eligible_cells;
    out["monsoon_onshore_cells"] = _monsoon_onshore_cells;
    out["monsoon_offshore_cells"] = _monsoon_offshore_cells;
    out["monsoon_contrast_abs_max"] = _monsoon_contrast_abs_max;
    out["monsoon_coast_cache_hit"] = _phys_wind_coast_last_hit;
    out["monsoon_coast_cache_build_ms"] = _phys_wind_coast_build_ms;
    out["enso_enabled"] = bool(_native_runtime_config.get("enso_basin_modes_enabled", false));
    out["enso_basin_count"] = int(_enso_states.size());
    out["enso_cache_hit"] = _enso_cache_last_hit;
    out["enso_cache_build_ms"] = _enso_cache_build_ms;
    Array basins;
    basins.resize(int(_enso_states.size()));
    for (int i = 0; i < int(_enso_states.size()); ++i) {
        const EnsoBasinState &s = _enso_states[static_cast<size_t>(i)];
        Dictionary d;
        d["signature"] = int64_t(s.signature);
        d["temp_index"] = s.temp_index;
        d["recharge_index"] = s.recharge_index;
        d["wind_anomaly"] = s.wind_anomaly;
        d["member_count"] = i < int(_enso_basins.size()) ? _enso_basins[static_cast<size_t>(i)].member_count : 0;
        basins[i] = d;
    }
    out["enso_basins"] = basins;
    out["cyclone_enabled"] = bool(_native_runtime_config.get("native_tropical_cyclone_enabled", false));
    out["cyclone_active_count"] = int(_cyclone_perturbations.size());
    out["cyclone_touched_cells"] = _cyclone_last_touched_cells;
    out["cyclone_total_genesis"] = _cyclone_total_genesis;
    out["cyclone_total_decay"] = _cyclone_total_decay;
    return out;
}

Dictionary DCWorldExt::capture_climate_modes_state() const {
    Dictionary out;
    out["schema"] = String("PKClimateModes");
    out["version"] = 1;
    out["next_cyclone_id"] = int64_t(_cyclone_next_stable_id);
    // ENSO basin state restores lazily, on the next basin-cache rebuild. Until
    // then the pending copy is the authoritative state; exporting the live
    // (still empty) basins would let a save made right after a load overwrite
    // the restored ENSO phase with a fresh one.
    if (_climate_modes_pending_restore.has("enso_basins")) {
        out["enso_basins"] = Array(
            _climate_modes_pending_restore["enso_basins"]).duplicate(true);
    } else {
        Array basins;
        for (const EnsoBasinState &s : _enso_states) {
            Dictionary d;
            d["signature"] = int64_t(s.signature);
            d["temp_index"] = s.temp_index;
            d["recharge_index"] = s.recharge_index;
            d["wind_ema"] = s.wind_ema;
            d["wind_anomaly"] = s.wind_anomaly;
            d["last_update_tick"] = s.last_update_tick;
            basins.append(d);
        }
        out["enso_basins"] = basins;
    }
    Array cyclones;
    for (const CycloneWakeEntry &e : _cyclone_perturbations) {
        Dictionary d;
        d["stable_id"] = int64_t(e.stable_id);
        d["key"] = e.key;
        d["cell_idx"] = e.cell_idx;
        d["steering"] = e.steering;
        d["intensity"] = e.intensity;
        d["radius_cells"] = e.radius_cells;
        d["age_days"] = e.age_days;
        d["move_progress"] = e.move_progress;
        cyclones.append(d);
    }
    out["cyclones"] = cyclones;
    out["total_genesis"] = _cyclone_total_genesis;
    out["total_decay"] = _cyclone_total_decay;
    return out;
}

Dictionary DCWorldExt::restore_climate_modes_state(const Dictionary &state) {
    Dictionary out;
    if (String(state.get("schema", String())) != String("PKClimateModes") || int(state.get("version", 0)) != 1) {
        out["ok"] = false;
        out["code"] = String("climate_modes_schema_mismatch");
        return out;
    }
    _climate_modes_pending_restore = state.duplicate(true);
    _cyclone_perturbations.clear();
    Array cyclones = state.get("cyclones", Array());
    const int capacity = std::clamp(int(_native_runtime_config.get("tropical_cyclone_capacity", 24)), 1, 64);
    for (int i = 0; i < cyclones.size() && int(_cyclone_perturbations.size()) < capacity; ++i) {
        Dictionary d = cyclones[i];
        CycloneWakeEntry e;
        e.stable_id = uint64_t(int64_t(d.get("stable_id", 0)));
        e.key = int64_t(d.get("key", 0));
        e.cell_idx = int(d.get("cell_idx", -1));
        e.steering = d.get("steering", Vector2(-1.0f, 0.0f));
        e.intensity = dc_clampf(float(d.get("intensity", 0.0)), 0.0f, 1.0f);
        e.radius_cells = dc_clampf(float(d.get("radius_cells", 2.0)), 2.0f, 6.0f);
        e.age_days = dc_clampf(float(d.get("age_days", 0.0)), 0.0f, 32.0f);
        e.move_progress = dc_clampf(float(d.get("move_progress", 0.0)), 0.0f, 1.0f);
        e.vec = e.steering * e.intensity;
        e.vec_init = e.vec;
        e.days_left = std::max(0, int(std::ceil(32.0f - e.age_days)));
        e.init_days = 32;
        if (e.cell_idx >= 0 && e.intensity >= 0.075f) _cyclone_perturbations.push_back(e);
    }
    _cyclone_next_stable_id = std::max<uint64_t>(1, uint64_t(int64_t(state.get("next_cyclone_id", 1))));
    _cyclone_total_genesis = std::max(0, int(state.get("total_genesis", 0)));
    _cyclone_total_decay = std::max(0, int(state.get("total_decay", 0)));
    out["ok"] = true;
    out["code"] = String("ok");
    out["cyclone_count"] = int(_cyclone_perturbations.size());
    out["enso_state_pending"] = Array(state.get("enso_basins", Array())).size();
    return out;
}

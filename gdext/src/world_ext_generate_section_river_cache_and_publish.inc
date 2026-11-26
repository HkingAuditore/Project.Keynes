godot::Dictionary DCWorldExt::restuff_generation_river_cache(const godot::Dictionary &input) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["rc"] = -1;
    out["ok"] = false;
    out["fallback"] = true;
    out["reason"] = String();
    out["n_cells"] = 0;

    const int width = int(input.get("width", 0));
    const int height = int(input.get("height", 0));
    const int n = int(input.get("n_cells", int64_t(width) * int64_t(height)));
    if (width <= 0 || height <= 0 || n <= 0 || n != width * height) {
        out["reason"] = String("invalid_dimensions");
        return out;
    }

    PackedInt32Array q_arr = input.get("q_arr", PackedInt32Array());
    PackedInt32Array r_arr = input.get("r_arr", PackedInt32Array());
    PackedFloat32Array elevation_arr = input.get("elevation_arr", PackedFloat32Array());
    PackedByteArray terrain_arr = input.get("terrain_arr", PackedByteArray());
    PackedByteArray has_river_arr = input.get("has_river_arr", PackedByteArray());
    PackedFloat32Array river_flow_arr = input.get("river_flow_arr", PackedFloat32Array());
    PackedInt32Array river_downstream_arr = input.get("river_downstream_arr", PackedInt32Array());
    if (q_arr.size() != n || r_arr.size() != n || elevation_arr.size() != n || terrain_arr.size() != n) {
        out["reason"] = String("required_input_size_mismatch");
        return out;
    }
    if (has_river_arr.size() != n) {
        has_river_arr.resize(n);
        uint8_t *H = has_river_arr.ptrw();
        for (int i = 0; i < n; ++i) H[i] = 0;
    }
    if (river_flow_arr.size() != n) {
        river_flow_arr.resize(n);
        float *F = river_flow_arr.ptrw();
        for (int i = 0; i < n; ++i) F[i] = 0.0f;
    }
    if (river_downstream_arr.size() != n) {
        river_downstream_arr.resize(n);
        int32_t *D = river_downstream_arr.ptrw();
        for (int i = 0; i < n; ++i) D[i] = -1;
    }

    const int32_t *Q = q_arr.ptr();
    const int32_t *R = r_arr.ptr();
    const float *E = elevation_arr.ptr();
    const uint8_t *TERR = terrain_arr.ptr();
    const uint8_t *RIV = has_river_arr.ptr();
    const float *RFLOW = river_flow_arr.ptr();
    const int32_t *RDOWN = river_downstream_arr.ptr();

    constexpr int DQ[6] = { 1, 1, 0, -1, -1, 0 };
    constexpr int DR[6] = { 0, -1, -1, 0, 1, 1 };
    auto index_for_qr = [&](int q, int r) -> int {
        if (r < 0 || r >= height) return -1;
        int col = q + ((r - (r & 1)) / 2);
        col = ((col % width) + width) % width;
        return r * width + col;
    };

    _gen_river_n = n;
    _gen_river_q.assign(size_t(n), 0);
    _gen_river_r.assign(size_t(n), 0);
    _gen_river_terrain.assign(size_t(n), 0);
    _gen_river_elev.assign(size_t(n), 0.0f);
    _gen_river_has.assign(size_t(n), 0);
    _gen_river_flow.assign(size_t(n), 0.0f);
    _gen_river_downstream.assign(size_t(n), -1);
    _gen_river_neighbors.assign(size_t(n) * 6, -1);
    for (int i = 0; i < n; ++i) {
        _gen_river_q[size_t(i)] = Q[i];
        _gen_river_r[size_t(i)] = R[i];
        _gen_river_terrain[size_t(i)] = TERR[i];
        _gen_river_elev[size_t(i)] = E[i];
        _gen_river_has[size_t(i)] = RIV[i];
        _gen_river_flow[size_t(i)] = RFLOW[i];
        _gen_river_downstream[size_t(i)] = RDOWN[i];
        for (int d = 0; d < 6; ++d) {
            _gen_river_neighbors[size_t(i) * 6 + size_t(d)] = index_for_qr(Q[i] + DQ[d], R[i] + DR[d]);
        }
    }

    out["rc"] = 0;
    out["ok"] = true;
    out["fallback"] = false;
    out["n_cells"] = n;
    return out;
}

Dictionary DCWorldExt::_run_native_generation_publish_pass(
    int seed,
    const Dictionary &cfg,
    const Dictionary &profile,
    const Dictionary &budget) {
    Dictionary out;
    out["rc"] = -1;
    out["status"] = String("failed");
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["seed"] = seed;
    out["has_config"] = !cfg.is_empty();
    out["has_profile"] = !profile.is_empty();
    out["implemented"] = true;
    out["published_to_slot"] = false;
    out["published_slots"] = Array();
    out["n_cells"] = 0;
    out["elapsed_ms"] = -1.0;
    out["native_ms"] = -1.0;
    out["compute_ms"] = 0.0;
    out["flush_ms"] = 0.0;
    out["generation_progress"] = 0.0;
    if (!budget.is_empty()) {
        out["budget"] = budget.duplicate(true);
    }

    auto fail = [&](const String &why, const String &stage = String("native_generation_publish")) -> Dictionary {
        out["fallback_reason"] = why;
        out["reason"] = why;
        out["fail_stage"] = stage;
        _native_generation_report = out.duplicate(true);
        return out;
    };

    if (!_bound || _map_data == nullptr) {
        return fail("not_bound", "bind_map_data");
    }

    const double sea_level = double(cfg.get("sea_level", 0.5));
    int n_cells = int(cfg.get("cell_count", 0));
    if (n_cells <= 0) {
        n_cells = _native_world_cell_count;
    }
    if (n_cells <= 0) {
        n_cells = _entity_count;
    }

    struct RequiredSlot {
        const char *name;
        SlotDType dtype;
        int sid = -1;
    };
    RequiredSlot req[] = {
        {"cell_lat_norm", SlotDType::F32, -1},
        {"cell_elevation", SlotDType::F32, -1},
        {"cell_temp_baseline_year", SlotDType::F32, -1},
        {"cell_temp", SlotDType::F32, -1},
        {"cell_temp_baseline", SlotDType::F32, -1},
        {"cell_temp_30d", SlotDType::F32, -1},
        {"cell_temp_365d", SlotDType::F32, -1},
        {"cell_base_moisture", SlotDType::F32, -1},
        {"cell_water_balance_30d", SlotDType::F32, -1},
        {"cell_temp_anomaly", SlotDType::F32, -1},
        {"cell_thermal_energy", SlotDType::F32, -1},
        {"cell_terrain", SlotDType::U8, -1},
        {"cell_is_water", SlotDType::U8, -1},
        {"cell_ema_initialized", SlotDType::U8, -1},
    };

    for (RequiredSlot &r : req) {
        r.sid = component_id(StringName(r.name));
        if (r.sid < 0 || r.sid >= _slots.size()) {
            String msg = String("missing_slot: ") + String(r.name);
            return fail(msg, "slot_lookup");
        }
        const Slot &s = _slots.write[r.sid];
        if (s.dtype != r.dtype) {
            String msg = String("slot_dtype_mismatch: ") + String(r.name);
            return fail(msg, "slot_dtype");
        }
        const int sz = (r.dtype == SlotDType::F32) ? s.arr_f32.size() : s.arr_u8.size();
        if (n_cells <= 0) {
            n_cells = sz;
        }
        if (sz != n_cells) {
            String msg = String("slot_size_mismatch: ") + String(r.name)
                + String(" size=") + String::num_int64(sz)
                + String(" expected=") + String::num_int64(n_cells);
            return fail(msg, "slot_size");
        }
    }
    if (n_cells <= 0) {
        return fail("empty_world", "slot_size");
    }

    auto sid_of = [&](const char *name) -> int {
        for (const RequiredSlot &r : req) {
            if (std::strcmp(r.name, name) == 0) {
                return r.sid;
            }
        }
        return -1;
    };

    const int sid_lat = sid_of("cell_lat_norm");
    const int sid_elev = sid_of("cell_elevation");
    const int sid_temp_year = sid_of("cell_temp_baseline_year");
    const int sid_temp = sid_of("cell_temp");
    const int sid_temp_baseline = sid_of("cell_temp_baseline");
    const int sid_temp_30d = sid_of("cell_temp_30d");
    const int sid_temp_365d = sid_of("cell_temp_365d");
    const int sid_temp_anom = sid_of("cell_temp_anomaly");
    const int sid_thermal = sid_of("cell_thermal_energy");
    const int sid_terrain = sid_of("cell_terrain");
    const int sid_is_water = sid_of("cell_is_water");
    const int sid_ema = sid_of("cell_ema_initialized");

    const float * const __restrict LAT = _slots.write[sid_lat].arr_f32.ptr();
    const float * const __restrict ELEV = _slots.write[sid_elev].arr_f32.ptr();
    const uint8_t * const __restrict TERR = _slots.write[sid_terrain].arr_u8.ptr();
    float * const __restrict TEMP_YEAR = _slots.write[sid_temp_year].arr_f32.ptrw();
    float * const __restrict TEMP = _slots.write[sid_temp].arr_f32.ptrw();
    float * const __restrict TEMP_BASE = _slots.write[sid_temp_baseline].arr_f32.ptrw();
    float * const __restrict TEMP_30D = _slots.write[sid_temp_30d].arr_f32.ptrw();
    float * const __restrict TEMP_365D = _slots.write[sid_temp_365d].arr_f32.ptrw();
    float * const __restrict TEMP_ANOM = _slots.write[sid_temp_anom].arr_f32.ptrw();
    float * const __restrict THERMAL = _slots.write[sid_thermal].arr_f32.ptrw();
    uint8_t * const __restrict IS_WATER = _slots.write[sid_is_water].arr_u8.ptrw();
    uint8_t * const __restrict EMA = _slots.write[sid_ema].arr_u8.ptrw();

    const auto t0 = std::chrono::high_resolution_clock::now();
    const auto tc0 = std::chrono::high_resolution_clock::now();
    int water_count = 0;
    for (int i = 0; i < n_cells; ++i) {
        const float ny = LAT[i];
        const float elev = ELEV[i];
        const float year = float(pk_clamp01(pk_lat_temp_bell((double(ny) - 0.5) * 2.0)));
        const float boot_temp = pk_compute_temperature(double(ny), double(elev), sea_level);
        const uint8_t water = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);

        TEMP_YEAR[i] = year;
        TEMP[i] = boot_temp;
        TEMP_BASE[i] = boot_temp;
        TEMP_30D[i] = boot_temp;
        TEMP_365D[i] = boot_temp;
        TEMP_ANOM[i] = 0.0f;
        THERMAL[i] = boot_temp;
        EMA[i] = 1;
        IS_WATER[i] = water;
        water_count += int(water);
    }
    const auto tc1 = std::chrono::high_resolution_clock::now();

    Array published_slots;
    auto flush_publish = [&](int sid, const char *name) {
        if (sid >= 0) {
            _flush_slot_to_map(sid);
            published_slots.append(String(name));
        }
    };
    const auto tf0 = std::chrono::high_resolution_clock::now();
    flush_publish(sid_temp_year, "cell_temp_baseline_year");
    flush_publish(sid_temp, "cell_temp");
    flush_publish(sid_temp_baseline, "cell_temp_baseline");
    flush_publish(sid_temp_30d, "cell_temp_30d");
    flush_publish(sid_temp_365d, "cell_temp_365d");
    flush_publish(sid_temp_anom, "cell_temp_anomaly");
    flush_publish(sid_thermal, "cell_thermal_energy");
    flush_publish(sid_ema, "cell_ema_initialized");
    flush_publish(sid_is_water, "cell_is_water");
    const auto tf1 = std::chrono::high_resolution_clock::now();
    const auto t1 = std::chrono::high_resolution_clock::now();

    const double compute_ms = std::chrono::duration<double, std::milli>(tc1 - tc0).count();
    const double flush_ms = std::chrono::duration<double, std::milli>(tf1 - tf0).count();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["rc"] = 0;
    out["status"] = String("completed");
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["published_to_slot"] = true;
    out["published_slots"] = published_slots;
    out["published_temp_baseline_year"] = true;
    out["n_cells"] = n_cells;
    out["water_count"] = water_count;
    out["land_count"] = n_cells - water_count;
    out["elapsed_ms"] = elapsed_ms;
    out["native_ms"] = elapsed_ms;
    out["compute_ms"] = compute_ms;
    out["flush_ms"] = flush_ms;
    out["generation_progress"] = 1.0;
    out["cfg_width"] = int(cfg.get("width", 0));
    out["cfg_height"] = int(cfg.get("height", 0));
    out["profile_keys"] = profile.keys();
    _native_generation_report = out.duplicate(true);
    return out;
}



// ─── F.2c: wind heat transport, air mass pass ───────────────────────────────
double DCWorldExt::run_wind_air_mass_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_wind_air_mass_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_y   = component_id(StringName("cell_wind_y"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_air_anom = component_id(StringName("cell_air_mass_temp_anomaly"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    if (sid_temp < 0 || sid_wind_x < 0 || sid_wind_y < 0 || sid_wind_spd < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_air_anom < 0) {
        diag("missing slot id (temp/wind/wind_speed/pos/air_anom)");
        return -1.0;
    }

    const bool read_temp_from_slot = knobs.has("read_temp_from_slot") && bool(knobs["read_temp_from_slot"]);
    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || (!read_temp_from_slot && !knobs.has("temp_before_arr"))) {
        diag("knobs missing required keys");
        return -1.0;
    }

    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    const float heat_mix     = float(knobs["heat_mix"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    const int end_idx_raw = knobs.has("end_idx") ? int(knobs["end_idx"]) : n_cells;
    if (start_idx < 0 || start_idx > n_cells) { diag("invalid start_idx"); return -1.0; }
    const int end_idx = std::min(std::max(end_idx_raw, start_idx), n_cells);

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr;
    if (!read_temp_from_slot) {
        temp_before_arr = knobs["temp_before_arr"];
    }
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (baseline_arr.size() != n_cells) { diag("baseline_arr size mismatch"); return -1.0; }
    if (!read_temp_from_slot && temp_before_arr.size() != n_cells) {
        diag("temp_before_arr size mismatch");
        return -1.0;
    }

    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_wind_x   = _slots.write[sid_wind_x];
    Slot &s_wind_y   = _slots.write[sid_wind_y];
    Slot &s_wind_spd = _slots.write[sid_wind_spd];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_air_anom = _slots.write[sid_air_anom];
    if (s_temp.arr_f32.size() != n_cells || s_wind_x.arr_f32.size() != n_cells ||
        s_wind_y.arr_f32.size() != n_cells || s_wind_spd.arr_f32.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells ||
        s_pos_y.arr_f32.size() != n_cells || s_air_anom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    const float * const __restrict WX = s_wind_x.arr_f32.ptr();
    const float * const __restrict WY = s_wind_y.arr_f32.ptr();
    const float * const __restrict WSP = s_wind_spd.arr_f32.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    float * const __restrict A = s_air_anom.arr_f32.ptrw();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict BL = baseline_arr.ptr();
    const float * const __restrict TB = read_temp_from_slot
        ? s_temp.arr_f32.ptr()
        : temp_before_arr.ptr();

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x10, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // NS 化 Phase 2:风场回溯轨迹表消费资格(与 weather field solve 同一契约:
    // 指纹失配 → 旧 hopping 并计数;knob wind_traj_weather_share=false → 仅构建不消费)。
    const int32_t *TRAJ_IDX = nullptr;
    const float   *TRAJ_W   = nullptr;
    if (_phys_wind_traj_valid && _phys_wind_traj_consume_enabled
            && int(_phys_wind_traj_idx.size()) == n_cells * 3) {
        if (pk_wind_state_fp(n_cells, WX, WY, WSP) == _phys_wind_traj_fp) {
            TRAJ_IDX = _phys_wind_traj_idx.data();
            TRAJ_W   = _phys_wind_traj_w.data();
        } else {
            ++_phys_wind_traj_stale_count;
        }
    }

    // S3：baseline 与轨迹表都不是 slot，capture 侧取不到，worker 只能靠这里照抄。
    // 分片调用时每一片都记同一份（内容与 start_idx 无关），最后一片覆盖前面的，
    // 结果一致。
    {
        auto wa_in = std::make_shared<pk_async_climate::WindAirInput>();
        wa_in->n_cells = n_cells;
        wa_in->baseline.assign(BL, BL + n_cells);
        wa_in->wind_x.assign(WX, WX + n_cells);
        wa_in->wind_y.assign(WY, WY + n_cells);
        wa_in->wind_speed.assign(WSP, WSP + n_cells);
        if (TRAJ_IDX != nullptr && TRAJ_W != nullptr) {
            wa_in->traj_idx.assign(TRAJ_IDX, TRAJ_IDX + size_t(n_cells) * 3u);
            wa_in->traj_w.assign(TRAJ_W, TRAJ_W + size_t(n_cells) * 3u);
        }
        _production_wind_air = std::move(wa_in);
    }

    // S3：这一段曾与 worker 的 _async_wind_air_kernel_pure 是两份实现，差三处
    // （轨迹表分支、isfinite 兜底、baseline 来源），温度链条因此在 round 里偏。
    // 现在两边都调这一个内核。
    {
        pk_async_climate::WindAirKnobs wa_knobs;
        wa_knobs.n_cells = n_cells;
        wa_knobs.advect_steps = advect_steps;
        wa_knobs.heat_mix = heat_mix;
        wa_knobs.wrap_period_x = wrap_period_x;

        pk_async_climate::WindAirLanes wa_lanes;
        wa_lanes.wind_x = WX;
        wa_lanes.wind_y = WY;
        wa_lanes.wind_speed = WSP;
        wa_lanes.pos_x = POSX;
        wa_lanes.pos_y = POSY;
        wa_lanes.temp_before = TB;
        wa_lanes.baseline = BL;
        wa_lanes.neighbor_indices = NB;
        wa_lanes.traj_idx = TRAJ_IDX;
        wa_lanes.traj_w = TRAJ_W;
        wa_lanes.air_anomaly = A;

        pk_async_climate::wind_air_pure(wa_knobs, wa_lanes, start_idx, end_idx);
    }

    knobs["cursor_start"] = start_idx;
    knobs["cursor_end"] = end_idx;
    knobs["processed_cells"] = end_idx - start_idx;
    knobs["wind_traj_used"] = (TRAJ_IDX != nullptr);
    knobs["wind_traj_stale_count"] = _phys_wind_traj_stale_count;

    if (!bool(knobs.get("defer_flush", false))) {
        _flush_slot_to_map(sid_air_anom);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.2d: wind heat transport, surface injection pass ──────────────────────
double DCWorldExt::run_wind_surface_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_wind_surface_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_y   = component_id(StringName("cell_wind_y"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_air_anom = component_id(StringName("cell_air_mass_temp_anomaly"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    // A 修复（2026-06）：wind_surface 是 climate-daily 链中唯一写 cell_temp 的 pass。
    // 末端把 baseline + transport(ocean+air) + local_anom 合成为 cell_temp。
    const int sid_baseline = component_id(StringName("cell_temp_baseline"));
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    const int sid_lanom    = component_id(StringName("cell_local_thermal_anomaly"));
    if (sid_temp < 0 || sid_wind_x < 0 || sid_wind_y < 0 || sid_wind_spd < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_air_anom < 0 || sid_iswater < 0 ||
        sid_baseline < 0 || sid_oanom < 0 || sid_lanom < 0) {
        diag("missing slot id (temp/wind/wind_speed/pos/air_anom/is_water/baseline/ocean_anom/local_anom)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("air_leak") ||
        !knobs.has("neighbor_indices") || !knobs.has("fallback_baseline_arr")) {
        diag("knobs missing required keys");
        return -1.0;
    }

    const int n_cells = int(knobs["n_cells"]);
    const float air_leak = float(knobs["air_leak"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    const float cold_transport_form = knobs.has("cold_transport_form_threshold")
        ? float(knobs["cold_transport_form_threshold"]) : 0.06f;
    const float cold_transport_melt = knobs.has("cold_transport_melt_threshold")
        ? float(knobs["cold_transport_melt_threshold"]) : 0.11f;
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    const int end_idx_raw = knobs.has("end_idx") ? int(knobs["end_idx"]) : n_cells;
    if (start_idx < 0 || start_idx > n_cells) { diag("invalid start_idx"); return -1.0; }
    const int end_idx = std::min(std::max(end_idx_raw, start_idx), n_cells);

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array fallback_baseline = knobs["fallback_baseline_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (fallback_baseline.size() != n_cells) { diag("fallback_baseline_arr size mismatch"); return -1.0; }

    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_wind_x   = _slots.write[sid_wind_x];
    Slot &s_wind_y   = _slots.write[sid_wind_y];
    Slot &s_wind_spd = _slots.write[sid_wind_spd];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_air_anom = _slots.write[sid_air_anom];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_baseline = _slots.write[sid_baseline];
    Slot &s_oanom    = _slots.write[sid_oanom];
    Slot &s_lanom    = _slots.write[sid_lanom];
    if (s_temp.arr_f32.size() != n_cells || s_wind_x.arr_f32.size() != n_cells ||
        s_wind_y.arr_f32.size() != n_cells || s_wind_spd.arr_f32.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells ||
        s_pos_y.arr_f32.size() != n_cells || s_air_anom.arr_f32.size() != n_cells ||
        s_iswater.arr_u8.size() != n_cells ||
        s_baseline.arr_f32.size() != n_cells || s_oanom.arr_f32.size() != n_cells ||
        s_lanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    PackedFloat32Array anomaly_src = s_air_anom.arr_f32;
    if (anomaly_src.size() != n_cells) { diag("air anomaly size mismatch"); return -1.0; }
    PackedFloat32Array anomaly_out = anomaly_src.duplicate();

    float * const __restrict T = s_temp.arr_f32.ptrw();
    const float * const __restrict WX = s_wind_x.arr_f32.ptr();
    const float * const __restrict WY = s_wind_y.arr_f32.ptr();
    const float * const __restrict WSP = s_wind_spd.arr_f32.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const float * const __restrict AIN = anomaly_src.ptr();
    float * const __restrict AOUT = anomaly_out.ptrw();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict FBL = fallback_baseline.ptr();
    // A 修复（2026-06）：合成需要 baseline / ocean anomaly / local anomaly。
    const float * const __restrict BL_RUNTIME = s_baseline.arr_f32.ptr();
    const float * const __restrict OANOM      = s_oanom.arr_f32.ptr();
    const float * const __restrict LANOM      = s_lanom.arr_f32.ptr();

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x20, knobs);
    // oanom 是分叉链头，且它的权威在生产的分片 ocean stage 手里（见
    // WindSurfaceInput 注释）。在消费点记录，抽到的就是生产真正用的那份。
    record_production_wind_surface_input(n_cells, OANOM);

    auto t0 = std::chrono::high_resolution_clock::now();

    // S3：与 worker 的 _async_wind_surface_kernel_pure 合成一个内核。两份主循环
    // 此前恰好逐位相同，但那是运气——它们连 smoothstep 都调的是不同函数，只是
    // 在当前 knobs 下数学等价。合了之后 cell_temp 只有一个写法。
    {
        pk_async_climate::WindSurfaceKnobs ws_knobs;
        ws_knobs.n_cells = n_cells;
        ws_knobs.air_leak = air_leak;
        ws_knobs.wrap_period_x = wrap_period_x;
        ws_knobs.cold_transport_form = cold_transport_form;
        ws_knobs.cold_transport_melt = cold_transport_melt;

        pk_async_climate::WindSurfaceLanes ws_lanes;
        ws_lanes.wind_x = WX;
        ws_lanes.wind_y = WY;
        ws_lanes.wind_speed = WSP;
        ws_lanes.pos_x = POSX;
        ws_lanes.pos_y = POSY;
        ws_lanes.is_water = IW;
        ws_lanes.baseline = BL_RUNTIME;
        ws_lanes.fallback_baseline = FBL;
        ws_lanes.ocean_anomaly = OANOM;
        ws_lanes.local_anomaly = LANOM;
        ws_lanes.neighbor_indices = NB;
        ws_lanes.air_anomaly_in = AIN;
        ws_lanes.air_anomaly_out = AOUT;
        ws_lanes.temp_out = T;

        pk_async_climate::wind_surface_pure(ws_knobs, ws_lanes, start_idx, end_idx);
    }

    s_air_anom.arr_f32 = anomaly_out;
    knobs["cursor_start"] = start_idx;
    knobs["cursor_end"] = end_idx;
    knobs["processed_cells"] = end_idx - start_idx;

    if (!bool(knobs.get("defer_flush", false))) {
        _flush_slot_to_map(sid_temp);
        _flush_slot_to_map(sid_air_anom);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

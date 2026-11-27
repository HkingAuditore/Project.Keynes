// ─── F.4 main pass ──────────────────────────────────────────────────────────
//
// 1:1 mirror of map_generator.gd::_apply_sea_ice_daily_pass (line 3856-3980).
// 2-phase: (A) has_cold_neighbor snapshot using prev-day sea_ice_fraction;
//          (B) fraction increment + flip-list collection.
//
// terrain 翻转**不**在 C++ 端写——只输出 flip lists，由 GDScript apply_terrain
// 维护 multi-axis 同步（passable_land / passable_sea / landform 等派生字段）。
// 这是 charter §2.5 STRUCT-001 反模式规避：C++ 不应直接改 multi-axis enum。
// sea_ice_smoothstep / sea_ice_freeze_gate / sea_ice_solar_melt /
// sea_ice_solar_exposure / sea_ice_positive_tta_residual 已在 S3 搬到
// runtime_climate_pass_math.h。

double DCWorldExt::run_sea_ice_daily_pass(Dictionary knobs, float season_phase) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_sea_ice_daily_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }
    (void) season_phase; // 当前算法未直接使用，仅 GDScript 端 throttled print 用

    // 注意：cell_temp slot **不**能直接读——pass_b/ocean_water/ocean_land 是
    // C++ 跑、写 SoA 不回写 cell.temperature；GDScript 1:1 mirror 读 cell.temperature
    // 拿到的是 pass_a 之后的"基线温度"（更暖），SoA cell_temp 是 ocean_land 之后
    // 的"修正温度"（更冷）。读错温度 → sea_ice 算冰过多 → 全图下雪。
    // 修复：GDScript fast-path 必须从 cell.temperature 打包成 cell_temperature_arr
    // 传入 knobs，C++ 读这个 PackedArray 而非 SoA。
    const int sid_sea_ice  = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    if (sid_sea_ice < 0 || sid_terrain < 0 || sid_oanom < 0) {
        diag("missing slot id (cell_sea_ice_frac / cell_terrain / cell_ocean_thermal_anomaly)");
        return -1.0;
    }

    static const char *required_keys[] = {
        "n_cells", "k_freeze", "k_melt", "t_form", "t_melt", "contagion",
        "threshold", "hysteresis", "ice_delay", "enable_ocean_heat_transport",
        "terrain_lake_id", "terrain_sea_ice_id", "terrain_ocean_id",
        "water_terrain_ids", // PackedByteArray，与 GDScript _is_water 1:1 对齐
        "neighbor_indices", "base_terrain_arr",
        "temp_transport_anomaly", "upwelling_strength",
        "insolation_now_arr", "solar_gate_enabled",
        "freeze_insol_low", "freeze_insol_high",
        "solar_melt_start", "solar_melt_gain",
        "cell_temperature_arr", // climate/ocean-adjusted temperature; no direct season signal here
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_sea_ice_daily_pass: knobs missing key '", k,
                "' — fallback to GDScript");
            return -1.0;
        }
    }

    const int   n_cells     = int(knobs["n_cells"]);
    const float k_freeze    = float(knobs["k_freeze"]);
    const float k_melt      = float(knobs["k_melt"]);
    const float t_form      = float(knobs["t_form"]);
    const float t_melt      = float(knobs["t_melt"]);
    const float contagion   = float(knobs["contagion"]);
    const float threshold   = float(knobs["threshold"]);
    const float hysteresis  = float(knobs["hysteresis"]);
    const float ice_delay   = float(knobs["ice_delay"]);
    const bool  enable_oht  = bool(knobs["enable_ocean_heat_transport"]);
    const bool  apply_terrain_flips = bool(knobs.get("apply_terrain_flips", false));
    const bool  solar_gate_enabled = bool(knobs["solar_gate_enabled"]);
    const float freeze_insol_low = float(knobs["freeze_insol_low"]);
    const float freeze_insol_high = float(knobs["freeze_insol_high"]);
    const float solar_melt_start = float(knobs["solar_melt_start"]);
    const float solar_melt_gain = float(knobs["solar_melt_gain"]);
    const float min_thick_ice_solar_exposure = knobs.has("min_thick_ice_solar_exposure") ? float(knobs["min_thick_ice_solar_exposure"]) : 0.32f;
    const float daily_delta_cap = knobs.has("daily_delta_cap") ? float(knobs["daily_delta_cap"]) : 0.070f;
    float edge_mix_rate = knobs.has("edge_mix_rate") ? float(knobs["edge_mix_rate"]) : 0.035f;
    if (edge_mix_rate < 0.0f) edge_mix_rate = 0.0f;
    else if (edge_mix_rate > 0.20f) edge_mix_rate = 0.20f;
    const int   id_lake     = int(knobs["terrain_lake_id"]);
    const int   id_sea_ice  = int(knobs["terrain_sea_ice_id"]);
    const int   id_ocean    = int(knobs["terrain_ocean_id"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    // [S2 fix 2026-05-23] dt_days：optional knob。缺省 1.0 → 与历史 1:1 兼容；
    // GDScript 端用 WorldClock.current_day 算"上次到本次的真实游戏天数差"。
    // clamp [0, 30] 与 GDScript 端一致，防意外越界。详见 GDScript 入口注释。
    float dt_days = 1.0f;
    if (knobs.has("dt_days")) {
        dt_days = float(knobs["dt_days"]);
        if (dt_days < 0.0f) dt_days = 0.0f;
        else if (dt_days > 30.0f) dt_days = 30.0f;
    }

    PackedInt32Array  nb_arr   = knobs["neighbor_indices"];
    PackedByteArray   base_terr_arr = knobs["base_terrain_arr"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array upw_arr = knobs["upwelling_strength"];
    PackedFloat32Array insol_arr = knobs["insolation_now_arr"];
    PackedByteArray   water_ids_arr = knobs["water_terrain_ids"];
    PackedFloat32Array cell_temp_arr = knobs["cell_temperature_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (base_terr_arr.size() < n_cells) { diag("base_terrain_arr size < n_cells"); return -1.0; }
    if (tta_arr.size() < n_cells)       { diag("temp_transport_anomaly size < n_cells"); return -1.0; }
    if (upw_arr.size() < n_cells)       { diag("upwelling_strength size < n_cells"); return -1.0; }
    if (insol_arr.size() < n_cells)     { diag("insolation_now_arr size < n_cells"); return -1.0; }
    if (water_ids_arr.size() <= 0)      { diag("water_terrain_ids empty"); return -1.0; }
    if (cell_temp_arr.size() < n_cells) { diag("cell_temperature_arr size < n_cells"); return -1.0; }

    // Build a 256-entry lookup table for is_water(terrain). Faster than
    // linear scan inside hot loop, and trivially extensible if GDScript
    // _is_water adds more terrain ids.
    bool is_water_lut[256];
    for (int i = 0; i < 256; ++i) is_water_lut[i] = false;
    for (int k = 0; k < water_ids_arr.size(); ++k) {
        const int wid = int(water_ids_arr[k]);
        if (wid >= 0 && wid < 256) is_water_lut[wid] = true;
    }

    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_oanom   = _slots.write[sid_oanom];
    if (s_sea_ice.arr_f32.size() != n_cells ||
        s_terrain.arr_u8.size()  != n_cells ||
        s_oanom.arr_f32.size()   != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    // T 从 knobs["cell_temperature_arr"] 拿（与 GDScript fallback 1:1 mirror）；
    // **不**读 SoA cell_temp slot（ocean_land 之后的修正温度，与 GDScript 看到的不同）。
    const float   * const __restrict T    = cell_temp_arr.ptr();
    float         * const __restrict SIF  = s_sea_ice.arr_f32.ptrw();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const uint8_t * const __restrict BT   = base_terr_arr.ptr();
    const float   * const __restrict TTA  = tta_arr.ptr();
    const float   * const __restrict OANOM = s_oanom.arr_f32.ptr();
    const float   * const __restrict UPW  = upw_arr.ptr();
    const float   * const __restrict INS  = insol_arr.ptr();

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x40, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // Phase A/B 都在共享内核里。worker 的 _async_sea_ice_kernel_pure 走同一份实现，
    // flip 列表与统计从 emit 取回后按老契约回填 knobs。
    pk_async_climate::SeaIceKnobs sk;
    sk.n_cells = n_cells;
    sk.k_freeze = k_freeze;
    sk.k_melt = k_melt;
    sk.t_form = t_form;
    sk.t_melt = t_melt;
    sk.contagion = contagion;
    sk.threshold = threshold;
    sk.hysteresis = hysteresis;
    sk.ice_delay = ice_delay;
    sk.enable_ocean_heat_transport = enable_oht;
    sk.solar_gate_enabled = solar_gate_enabled;
    sk.freeze_insol_low = freeze_insol_low;
    sk.freeze_insol_high = freeze_insol_high;
    sk.solar_melt_start = solar_melt_start;
    sk.solar_melt_gain = solar_melt_gain;
    sk.min_thick_ice_solar_exposure = min_thick_ice_solar_exposure;
    sk.daily_delta_cap = daily_delta_cap;
    sk.edge_mix_rate = edge_mix_rate;
    sk.dt_days = dt_days;
    sk.terrain_lake_id = id_lake;
    sk.terrain_sea_ice_id = id_sea_ice;
    sk.terrain_ocean_id = id_ocean;

    pk_async_climate::SeaIceLanes sl;
    sl.terrain = TR;
    sl.base_terrain = BT;
    sl.cell_temperature = T;
    sl.temp_transport_anomaly = TTA;
    sl.ocean_thermal_anomaly = OANOM;
    sl.upwelling_strength = UPW;
    sl.insolation_now = INS;
    sl.water_terrain_ids = water_ids_arr.ptr();
    sl.water_terrain_ids_size = int(water_ids_arr.size());
    sl.neighbor_indices = NB;
    sl.sea_ice_frac = SIF;
    record_production_sea_ice_input(sl, n_cells);

    pk_async_climate::SeaIceScratch scratch;
    pk_async_climate::SeaIceEmit emit;
    pk_async_climate::sea_ice_pure(sk, sl, scratch, emit);

    PackedInt32Array  flip_to_ice;
    PackedInt32Array  flip_to_base;
    PackedByteArray   flip_to_base_terrain;
    flip_to_ice.resize(int(emit.flip_to_ice.size()));
    if (!emit.flip_to_ice.empty()) {
        std::memcpy(flip_to_ice.ptrw(), emit.flip_to_ice.data(),
                    emit.flip_to_ice.size() * sizeof(int32_t));
    }
    flip_to_base.resize(int(emit.flip_to_base.size()));
    flip_to_base_terrain.resize(int(emit.flip_to_base_terrain.size()));
    if (!emit.flip_to_base.empty()) {
        std::memcpy(flip_to_base.ptrw(), emit.flip_to_base.data(),
                    emit.flip_to_base.size() * sizeof(int32_t));
        std::memcpy(flip_to_base_terrain.ptrw(), emit.flip_to_base_terrain.data(),
                    emit.flip_to_base_terrain.size());
    }
    const int water_count   = emit.water_count;
    const int flipped_count = emit.flipped_count;

    // 写 SIF slot（cell_sea_ice_frac CoW-detached buffer 同步回 MapData）
    _flush_slot_to_map(sid_sea_ice);
    if (apply_terrain_flips && flipped_count > 0) {
        uint8_t * const __restrict TRW = s_terrain.arr_u8.ptrw();
        for (int i = 0; i < flip_to_ice.size(); ++i) {
            const int idx = int(flip_to_ice[i]);
            if (idx >= 0 && idx < n_cells) {
                TRW[idx] = uint8_t(id_sea_ice & 0xFF);
            }
        }
        for (int i = 0; i < flip_to_base.size(); ++i) {
            const int idx = int(flip_to_base[i]);
            if (idx >= 0 && idx < n_cells && i < flip_to_base_terrain.size()) {
                TRW[idx] = uint8_t(int(flip_to_base_terrain[i]) & 0xFF);
            }
        }
        _flush_slot_to_map(sid_terrain);
        _native_dirty_report["atlas_dirty"] = true;
        _native_dirty_report["sea_ice_atlas_dirty"] = true;
        _native_dirty_report["sea_ice_terrain_flip_count"] = flipped_count;
    }

    // 输出回填到 knobs（让 GDScript caller 拿到 flip 列表 + 统计）
    knobs["flip_to_ice_list"]     = flip_to_ice;
    knobs["flip_to_base_list"]    = flip_to_base;
    knobs["flip_to_base_terrain"] = flip_to_base_terrain;
    knobs["stat_water_count"]     = water_count;
    knobs["stat_flipped_count"]   = flipped_count;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── [Phase C.3d] sea_ice 并行变体 ─────────────────────────────────────────
//
// 完整复制 run_sea_ice_daily_pass 的 prelude，主体两阶段：
//   Phase A: cold_neighbor 快照（cell-local 读写 has_cold_neighbor[i]） →
//            走 pk::parallel_for_range，无 emit。
//   Phase B: 主循环（cell-local 读写 SIF + emit 3 个 flip lists + 2 counter） →
//            走 pk::parallel_for_range_with_emit，thread-local Emit reduce。
//
// emit reduce 顺序：每 task 内部按 cell idx 升序 push → 按 task_idx 升序 merge_into
// global → 全局顺序 == scalar bit-equal。counters 直接累加。
double DCWorldExt::run_sea_ice_daily_pass_thread(Dictionary knobs, float season_phase, int n_tasks) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_sea_ice_daily_pass_thread: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }
    (void) season_phase;

    const int sid_sea_ice = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_oanom   = component_id(StringName("cell_ocean_thermal_anomaly"));
    if (sid_sea_ice < 0 || sid_terrain < 0 || sid_oanom < 0) {
        diag("missing slot id (cell_sea_ice_frac / cell_terrain / cell_ocean_thermal_anomaly)");
        return -1.0;
    }

    static const char *required_keys[] = {
        "n_cells", "k_freeze", "k_melt", "t_form", "t_melt", "contagion",
        "threshold", "hysteresis", "ice_delay", "enable_ocean_heat_transport",
        "terrain_lake_id", "terrain_sea_ice_id", "terrain_ocean_id",
        "water_terrain_ids",
        "neighbor_indices", "base_terrain_arr",
        "temp_transport_anomaly", "upwelling_strength",
        "insolation_now_arr", "solar_gate_enabled",
        "freeze_insol_low", "freeze_insol_high",
        "solar_melt_start", "solar_melt_gain",
        "cell_temperature_arr",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_sea_ice_daily_pass_thread: knobs missing key '", k,
                "' — fallback to GDScript");
            return -1.0;
        }
    }

    const int   n_cells     = int(knobs["n_cells"]);
    const float k_freeze    = float(knobs["k_freeze"]);
    const float k_melt      = float(knobs["k_melt"]);
    const float t_form      = float(knobs["t_form"]);
    const float t_melt      = float(knobs["t_melt"]);
    const float contagion   = float(knobs["contagion"]);
    const float threshold   = float(knobs["threshold"]);
    const float hysteresis  = float(knobs["hysteresis"]);
    const float ice_delay   = float(knobs["ice_delay"]);
    const bool  enable_oht  = bool(knobs["enable_ocean_heat_transport"]);
    const bool  solar_gate_enabled = bool(knobs["solar_gate_enabled"]);
    const float freeze_insol_low = float(knobs["freeze_insol_low"]);
    const float freeze_insol_high = float(knobs["freeze_insol_high"]);
    const float solar_melt_start = float(knobs["solar_melt_start"]);
    const float solar_melt_gain = float(knobs["solar_melt_gain"]);
    const float min_thick_ice_solar_exposure = knobs.has("min_thick_ice_solar_exposure") ? float(knobs["min_thick_ice_solar_exposure"]) : 0.32f;
    const float daily_delta_cap = knobs.has("daily_delta_cap") ? float(knobs["daily_delta_cap"]) : 0.070f;
    float edge_mix_rate = knobs.has("edge_mix_rate") ? float(knobs["edge_mix_rate"]) : 0.035f;
    if (edge_mix_rate < 0.0f) edge_mix_rate = 0.0f;
    else if (edge_mix_rate > 0.20f) edge_mix_rate = 0.20f;
    const int   id_lake     = int(knobs["terrain_lake_id"]);
    const int   id_sea_ice  = int(knobs["terrain_sea_ice_id"]);
    const int   id_ocean    = int(knobs["terrain_ocean_id"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    // [S2 fix 2026-05-23] dt_days：与 scalar 路径同步（optional, default 1.0）。
    float dt_days = 1.0f;
    if (knobs.has("dt_days")) {
        dt_days = float(knobs["dt_days"]);
        if (dt_days < 0.0f) dt_days = 0.0f;
        else if (dt_days > 30.0f) dt_days = 30.0f;
    }

    PackedInt32Array  nb_arr   = knobs["neighbor_indices"];
    PackedByteArray   base_terr_arr = knobs["base_terrain_arr"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array upw_arr = knobs["upwelling_strength"];
    PackedFloat32Array insol_arr = knobs["insolation_now_arr"];
    PackedByteArray   water_ids_arr = knobs["water_terrain_ids"];
    PackedFloat32Array cell_temp_arr = knobs["cell_temperature_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (base_terr_arr.size() < n_cells) { diag("base_terrain_arr size < n_cells"); return -1.0; }
    if (tta_arr.size() < n_cells)       { diag("temp_transport_anomaly size < n_cells"); return -1.0; }
    if (upw_arr.size() < n_cells)       { diag("upwelling_strength size < n_cells"); return -1.0; }
    if (insol_arr.size() < n_cells)     { diag("insolation_now_arr size < n_cells"); return -1.0; }
    if (water_ids_arr.size() <= 0)      { diag("water_terrain_ids empty"); return -1.0; }
    if (cell_temp_arr.size() < n_cells) { diag("cell_temperature_arr size < n_cells"); return -1.0; }

    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_oanom   = _slots.write[sid_oanom];
    if (s_sea_ice.arr_f32.size() != n_cells ||
        s_terrain.arr_u8.size()  != n_cells ||
        s_oanom.arr_f32.size()   != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    const float   * const __restrict T    = cell_temp_arr.ptr();
    float         * const __restrict SIF  = s_sea_ice.arr_f32.ptrw();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const uint8_t * const __restrict BT   = base_terr_arr.ptr();
    const float   * const __restrict TTA  = tta_arr.ptr();
    const float   * const __restrict OANOM = s_oanom.arr_f32.ptr();
    const float   * const __restrict UPW  = upw_arr.ptr();
    const float   * const __restrict INS  = insol_arr.ptr();

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x40, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // native daily 默认走这个 thread 变体。它此前是 2026-06-16 的单步
    // `d_frac = rate * dt_days` 抄本，而 scalar / worker 已经换成 sea_ice_pure
    // 的按日子步积分。dt_days≈8..10 时两边差一个数量级，sea_ice 因此在每一个
    // 真实对拍日都分叉。接到同一份内核之后，并行只是调度，不再是第二套物理。
    pk_async_climate::SeaIceKnobs sk;
    sk.n_cells = n_cells;
    sk.k_freeze = k_freeze;
    sk.k_melt = k_melt;
    sk.t_form = t_form;
    sk.t_melt = t_melt;
    sk.contagion = contagion;
    sk.threshold = threshold;
    sk.hysteresis = hysteresis;
    sk.ice_delay = ice_delay;
    sk.enable_ocean_heat_transport = enable_oht;
    sk.solar_gate_enabled = solar_gate_enabled;
    sk.freeze_insol_low = freeze_insol_low;
    sk.freeze_insol_high = freeze_insol_high;
    sk.solar_melt_start = solar_melt_start;
    sk.solar_melt_gain = solar_melt_gain;
    sk.min_thick_ice_solar_exposure = min_thick_ice_solar_exposure;
    sk.daily_delta_cap = daily_delta_cap;
    sk.edge_mix_rate = edge_mix_rate;
    sk.dt_days = dt_days;
    sk.terrain_lake_id = id_lake;
    sk.terrain_sea_ice_id = id_sea_ice;
    sk.terrain_ocean_id = id_ocean;

    pk_async_climate::SeaIceLanes sl;
    sl.terrain = TR;
    sl.base_terrain = BT;
    sl.cell_temperature = T;
    sl.temp_transport_anomaly = TTA;
    sl.ocean_thermal_anomaly = OANOM;
    sl.upwelling_strength = UPW;
    sl.insolation_now = INS;
    sl.water_terrain_ids = water_ids_arr.ptr();
    sl.water_terrain_ids_size = int(water_ids_arr.size());
    sl.neighbor_indices = NB;
    sl.sea_ice_frac = SIF;
    record_production_sea_ice_input(sl, n_cells);

    pk_async_climate::SeaIceScratch scratch;
    pk_async_climate::SeaIceEmit emit;
    pk_async_climate::sea_ice_pure(sk, sl, scratch, emit);
    (void)n_tasks;

    _flush_slot_to_map(sid_sea_ice);

    PackedInt32Array flip_to_ice;
    PackedInt32Array flip_to_base;
    PackedByteArray  flip_to_base_terrain;
    flip_to_ice.resize(int(emit.flip_to_ice.size()));
    if (!emit.flip_to_ice.empty()) {
        std::memcpy(flip_to_ice.ptrw(), emit.flip_to_ice.data(),
                    emit.flip_to_ice.size() * sizeof(int32_t));
    }
    flip_to_base.resize(int(emit.flip_to_base.size()));
    flip_to_base_terrain.resize(int(emit.flip_to_base_terrain.size()));
    if (!emit.flip_to_base.empty()) {
        std::memcpy(flip_to_base.ptrw(), emit.flip_to_base.data(),
                    emit.flip_to_base.size() * sizeof(int32_t));
        std::memcpy(flip_to_base_terrain.ptrw(), emit.flip_to_base_terrain.data(),
                    emit.flip_to_base_terrain.size());
    }

    knobs["flip_to_ice_list"]     = flip_to_ice;
    knobs["flip_to_base_list"]    = flip_to_base;
    knobs["flip_to_base_terrain"] = flip_to_base_terrain;
    knobs["stat_water_count"]     = emit.water_count;
    knobs["stat_flipped_count"]   = emit.flipped_count;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

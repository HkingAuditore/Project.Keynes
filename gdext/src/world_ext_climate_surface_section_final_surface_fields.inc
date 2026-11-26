

// ─── 方案 B：stage_b 三段合并 run_stage_b_pass ────────────────────────────
//
// 生产热路径只跑这一份 fused loop。独立的 run_albedo_pass /
// run_vegetation_dynamics_pass / run_climate_feedback_pass 仍保留 1:1 拷贝，
// 仅供 SHADOW / 缺 stage_b_knobs 的 helper；slice graph 在已有 stage_b_knobs
// 时跳过拆开节点，避免双跑。
//
// 这是 run_albedo_pass + run_vegetation_dynamics_pass +
// run_climate_feedback_pass 的顺序内联合并版本。三段主循环算法**完全 1:1
// 拷贝**自原三个独立函数，仅做以下结构合并：
//
//   1. 单一 prelude：_bound 检查 + slot id resolve + size validate（合并需要
//      的 9 个 SoA slot：cell_is_water / cell_vegetation / cell_cover /
//      cell_temp / cell_moisture / cell_weather_type / cell_weather_intensity /
//      cell_weather_field_init / cell_base_moisture）。
//   2. 三个 run_* bool 控制是否跑（保留 GDScript 端 stride 语义；
//      false 时整段连入参验证都跳过，避免把 false 段的 knobs 设为必填）。
//   3. cross-pass 依赖：albedo 写 cell_temp、veg_dyn 读 cell_temp。合并版本里
//      两段共享同一份 s_temp.arr_f32 ptrw，**无需中间 _flush_slot_to_map** ——
//      这是合并相对于"GDScript 跑三次 cpp call 各自 flush + GDScript 端
//      refresh_slots_from_map 各自一次"的核心收益之一。
//   4. 末尾批量 flush（仅 cell_temp + cell_base_moisture 两个 SoA 写出 slot）；
//      _flush_slot_to_map 是 O(1) Variant 引用交换，开销可忽略（参见 §11.2 注释）。
//   5. 计时：每段独立 chrono → ms 写回 knobs（albedo_ms / veg_dyn_ms /
//      feedback_ms），caller 端用作 _last_weather_breakdown 沿用打点。
//
// **不修改任何算法逻辑**。如果发现 SAME_SOURCE A/B 漂移，回头去改这里就是
// 合并破坏了语义；目标是字节级一致。
double DCWorldExt::run_stage_b_pass(Dictionary knobs) {
    SimTraceWriteGuard sim_trace_guard{this, "run_stage_b_pass"};
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_stage_b_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── 总开关 + n_cells ───────────────────────────────────────────────
    if (!knobs.has("n_cells")) { diag("knobs missing n_cells"); return -1.0; }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const bool run_albedo   = bool(knobs.get("run_albedo",   false));
    const bool run_veg_dyn  = bool(knobs.get("run_veg_dyn",  false));
    const bool run_feedback = bool(knobs.get("run_feedback", false));
    if (!run_albedo && !run_veg_dyn && !run_feedback) {
        // 三个 stride 同 tick 都跳过 —— 也算合法，返回 0ms 让 caller 走快路径
        knobs["albedo_ms"]   = 0.0;
        knobs["veg_dyn_ms"]  = 0.0;
        knobs["feedback_ms"] = 0.0;
        return 0.0;
    }

    // ─── Resolve 所有 slot id（即使某段不跑也 resolve，便于一次性失败诊断） ──
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_cover    = component_id(StringName("cell_cover"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_water_bal = component_id(StringName("cell_water_balance_30d"));
    const int sid_plant_water = component_id(StringName("cell_plant_available_water"));
    const int sid_wt_type  = component_id(StringName("cell_weather_type"));
    const int sid_wt_int   = component_id(StringName("cell_weather_intensity"));
    const int sid_wt_init  = component_id(StringName("cell_weather_field_init"));
    const int sid_base_m   = component_id(StringName("cell_base_moisture"));
    if (sid_iswater < 0 || sid_veg < 0 || sid_cover < 0 || sid_terrain < 0 || sid_landform < 0 || sid_temp < 0 ||
        sid_temp_30d < 0 || sid_moist < 0 || sid_water_bal < 0 || sid_plant_water < 0 ||
        sid_wt_type < 0 || sid_wt_int < 0 ||
        sid_wt_init < 0 || sid_base_m < 0) {
        diag("missing slot id (one of cell_is_water/vegetation/cover/temp/moisture/"
             "weather_type/weather_intensity/weather_field_init/base_moisture)");
        return -1.0;
    }

    // ─── B3b：6 个植被动力学新 slot（vit/low/high/soil/vg/tta） ────────────
    // use_soa = true 时，veg_dyn / feedback 段直接读写这 6 个 slot 的 _slots 后端，
    // 不再从 knobs 取 PackedArray（消除 GDScript 端 pack/unpack ~7ms wall）。
    // use_soa = false 时（向后兼容），仍走 knobs PackedArray 路径，slot id 仅做
    // 一次性 resolve 不消费——保证老 caller 的 SAME_SOURCE A/B 不破坏。
    const bool use_soa = bool(knobs.get("use_soa", false));
    const bool vegetation_stress_enabled_stage_b = bool(knobs.get("vegetation_stress_enabled", false));
    const int sid_vit       = component_id(StringName("cell_vegetation_vitality"));
    const int sid_low_streak  = component_id(StringName("cell_vitality_low_streak"));
    const int sid_high_streak = component_id(StringName("cell_vitality_high_streak"));
    const int sid_soil      = component_id(StringName("cell_soil_moisture"));
    const int sid_vgp       = component_id(StringName("cell_vegetation_growth_pressure"));
    const int sid_tta       = component_id(StringName("cell_temperature_transport_anomaly"));
    const int sid_v_heat    = component_id(StringName("cell_vegetation_heat_stress"));
    const int sid_v_drought = component_id(StringName("cell_vegetation_drought_stress"));
    const int sid_v_cold    = component_id(StringName("cell_vegetation_cold_stress"));
    const int sid_v_regen   = component_id(StringName("cell_vegetation_regen_score"));
    if (use_soa) {
        if (sid_vit < 0 || sid_low_streak < 0 || sid_high_streak < 0 ||
            sid_soil < 0 || sid_vgp < 0 || sid_tta < 0) {
            diag("[use_soa] missing one of cell_vegetation_vitality / "
                 "cell_vitality_low_streak / cell_vitality_high_streak / "
                 "cell_soil_moisture / cell_vegetation_growth_pressure / "
                 "cell_temperature_transport_anomaly — did bind_map_data run after schema update?");
            return -1.0;
        }
        if (vegetation_stress_enabled_stage_b &&
            (sid_v_heat < 0 || sid_v_drought < 0 || sid_v_cold < 0 || sid_v_regen < 0)) {
            diag("[use_soa] missing vegetation stress slots "
                 "(cell_vegetation_heat_stress / drought / cold / regen_score)");
            return -1.0;
        }
    }

    // ─── Acquire all slot arrays + validate sizes ───────────────────────
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_veg     = _slots.write[sid_veg];
    Slot &s_cover   = _slots.write[sid_cover];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_temp30  = _slots.write[sid_temp_30d];
    Slot &s_moist   = _slots.write[sid_moist];
    Slot &s_wb      = _slots.write[sid_water_bal];
    Slot &s_plant_water = _slots.write[sid_plant_water];
    Slot &s_wt_type = _slots.write[sid_wt_type];
    Slot &s_wt_int  = _slots.write[sid_wt_int];
    Slot &s_wt_init = _slots.write[sid_wt_init];
    Slot &s_base_m  = _slots.write[sid_base_m];
    if (s_iswater.arr_u8.size() != n_cells || s_veg.arr_u8.size()    != n_cells ||
        s_cover.arr_u8.size()   != n_cells || s_terrain.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_temp.arr_f32.size()  != n_cells ||
        s_temp30.arr_f32.size() != n_cells || s_moist.arr_f32.size() != n_cells ||
        s_wb.arr_f32.size()     != n_cells || s_plant_water.arr_f32.size() != n_cells ||
        s_wt_type.arr_u8.size()!= n_cells ||
        s_wt_int.arr_f32.size() != n_cells || s_wt_init.arr_u8.size()!= n_cells ||
        s_base_m.arr_f32.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // 通用 SoA pointer
    const uint8_t * const __restrict IW    = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict VG    = s_veg.arr_u8.ptr();
    const uint8_t * const __restrict CV    = s_cover.arr_u8.ptr();
    const uint8_t * const __restrict TERR  = s_terrain.arr_u8.ptr();
    const uint8_t * const __restrict LF    = s_landform.arr_u8.ptr();
    float         * const __restrict T     = s_temp.arr_f32.ptrw();   // albedo 写、veg_dyn 读
    const float   * const __restrict T30   = s_temp30.arr_f32.ptr();
    const float   * const __restrict M     = s_moist.arr_f32.ptr();
    const float   * const __restrict WBAL  = s_wb.arr_f32.ptr();
    float         * const __restrict PLANT_WATER = s_plant_water.arr_f32.ptrw();
    const uint8_t * const __restrict WTT   = s_wt_type.arr_u8.ptr();
    const float   * const __restrict WTI   = s_wt_int.arr_f32.ptr();
    const uint8_t * const __restrict WTIN  = s_wt_init.arr_u8.ptr();
    float         * const __restrict BM    = s_base_m.arr_f32.ptrw();
    const float   *SOIL_COMP = nullptr;
    float         *VGP_COMP = nullptr;
    if (use_soa) {
        const Slot &s_soil_comp = _slots[sid_soil];
        Slot &s_vgp_comp = _slots.write[sid_vgp];
        if (s_soil_comp.arr_f32.size() != n_cells || s_vgp_comp.arr_f32.size() != n_cells) {
            diag("[use_soa] soil_moisture/vegetation_growth_pressure slot size != n_cells");
            return -1.0;
        }
        SOIL_COMP = s_soil_comp.arr_f32.ptr();
        VGP_COMP = s_vgp_comp.arr_f32.ptrw();
    }

    auto t_total_0 = std::chrono::high_resolution_clock::now();
    bool flush_temp = false;     // albedo 跑了才需要 flush
    bool flush_base_m = false;   // feedback 跑了才需要 flush
    double albedo_ms = 0.0;
    double veg_dyn_ms = 0.0;
    double feedback_ms = 0.0;

    // ════════════════════════════════════════════════════════════════════
    // ① ALBEDO 段（1:1 复制 run_albedo_pass 主循环）
    // ════════════════════════════════════════════════════════════════════
    if (run_albedo) {
        if (!knobs.has("reference_albedo") || !knobs.has("albedo_temp_gain") ||
            !knobs.has("albedo_table")) {
            diag("[albedo] knobs missing required keys (reference_albedo / albedo_temp_gain / albedo_table)");
            return -1.0;
        }
        const float reference_albedo  = float(knobs["reference_albedo"]);
        const float albedo_temp_gain  = float(knobs["albedo_temp_gain"]);
        const float snow_cover_albedo = float(knobs.get("snow_cover_albedo", 0.75f));
        const uint8_t cover_snow_id    = uint8_t(int(knobs.get("cover_snow_id", 1)));
        const uint8_t cover_glacier_id = uint8_t(int(knobs.get("cover_glacier_id", 2)));

        PackedFloat32Array albedo_arr = knobs["albedo_table"];
        const int albedo_size = albedo_arr.size();
        if (albedo_size <= 0) { diag("[albedo] albedo_table empty"); return -1.0; }
        const float * const __restrict ALB = albedo_arr.ptr();

        auto t0 = std::chrono::high_resolution_clock::now();

        // ─── Main loop ──────────────────────────────────────────────────
        // S3：与 run_albedo_pass 一同下沉到共享纯 kernel。这里原先是第三份逐字副本
        // （run_albedo_pass / run_albedo_pass_thread / 本段），任何一份改动漏同步都
        // 会表现成"温度场在某些天分叉"。
        pk_async_climate::ClimateAlbedoKnobs alb_knobs;
        alb_knobs.ran = true;
        alb_knobs.reference_albedo = reference_albedo;
        alb_knobs.temp_gain = albedo_temp_gain;
        alb_knobs.snow_cover_albedo = snow_cover_albedo;
        alb_knobs.cover_snow_id = cover_snow_id;
        alb_knobs.cover_glacier_id = cover_glacier_id;
        pk_async_climate::albedo_apply_pure(alb_knobs, IW, VG, CV, ALB,
                                            albedo_size, T, n_cells);
        _production_albedo = alb_knobs;
        _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_ALBEDO;

        auto t1 = std::chrono::high_resolution_clock::now();
        albedo_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        flush_temp = true;
    }

    // ════════════════════════════════════════════════════════════════════
    // ② VEGETATION_DYNAMICS 段（1:1 复制 run_vegetation_dynamics_pass 主循环）
    //    注意：读最新 T[]（如果 albedo 段刚写过，这里直接读到——共享 SoA）
    // ════════════════════════════════════════════════════════════════════
    PackedInt32Array out_indices_vd;     // 留到末尾写回 knobs
    PackedByteArray  out_to_veg_vd;
    int n_succ_vd = 0;
    if (run_veg_dyn) {
        // 标量
        static const char *required_scalars[] = {
            "day_scale", "streak_days",
            "vitality_change_rate", "compat_harshness",
            "plant_water_balance_weight", "plant_soil_buffer_weight",
            "plant_drought_penalty", "succession_min_compat_gain",
            "low_threshold", "high_threshold",
            "succession_degrade_days", "succession_upgrade_days",
            "n_wt", "wt_clear_id", "veg_none_id",
        };
        for (const char *k : required_scalars) {
            if (!knobs.has(k)) { diag("[veg_dyn] knobs missing required scalar key"); return -1.0; }
        }
        const float day_scale_raw = float(knobs["day_scale"]);
        const float scale         = day_scale_raw < 1.0f ? 1.0f : day_scale_raw;
        const int   streak_days   = int(knobs["streak_days"]);
        const float rate          = float(knobs["vitality_change_rate"]);
        const float harshness     = float(knobs["compat_harshness"]);
        const float low_thresh    = float(knobs["low_threshold"]);
        const float high_thresh   = float(knobs["high_threshold"]);
        const int   degrade_days  = int(knobs["succession_degrade_days"]);
        const int   upgrade_days  = int(knobs["succession_upgrade_days"]);
        const int   n_wt          = int(knobs["n_wt"]);
        const int   wt_clear_id   = int(knobs["wt_clear_id"]);
        const uint8_t veg_none_id = uint8_t(int(knobs["veg_none_id"]));
        const float weather_penalty_scale = knobs.has("weather_penalty_scale") ? float(knobs["weather_penalty_scale"]) : 1.0f;
        const float plant_water_balance_weight = float(knobs["plant_water_balance_weight"]);
        const float plant_soil_buffer_weight = float(knobs["plant_soil_buffer_weight"]);
        const float plant_drought_penalty = float(knobs["plant_drought_penalty"]);
        const float succession_min_compat_gain = float(knobs["succession_min_compat_gain"]);
        const float low_vitality_damping_threshold = knobs.has("vegetation_low_vitality_damping_threshold")
                                                   ? float(knobs["vegetation_low_vitality_damping_threshold"]) : 0.40f;
        const int   succession_cooldown_days = knobs.has("vegetation_succession_cooldown_days")
                                             ? int(knobs["vegetation_succession_cooldown_days"]) : 30;
        const bool  vegetation_stress_enabled = vegetation_stress_enabled_stage_b;
        const float vegetation_stress_memory_days = std::max(1.0f, float(knobs.get("vegetation_stress_memory_days", 30.0f)));
        const float vegetation_stress_blend = std::clamp(scale / vegetation_stress_memory_days, 0.0f, 1.0f);
        const int   wt_blizzard_id = int(knobs.get("wt_blizzard_id", 3));
        const int   wt_drought_id  = int(knobs.get("wt_drought_id", 4));
        const int   wt_heatwave_id = int(knobs.get("wt_heatwave_id", 6));
        if (n_wt <= 0) { diag("[veg_dyn] n_wt <= 0"); return -1.0; }

        // 表
        static const char *required_tables[] = {
            "ideal_temp_table", "ideal_moist_table",
            "temp_tol_table", "moist_tol_table",
            "weather_penalty_table", "resistance_table",
            "next_up_table", "next_down_table",
        };
        for (const char *k : required_tables) {
            if (!knobs.has(k)) { diag("[veg_dyn] knobs missing required table key"); return -1.0; }
        }
        // 老路径（use_soa=false）：vit/streak 通过 knobs 传入 PackedArray
        // 新路径（use_soa=true）： vit/streak 直接走 _slots[sid_*].arr_*
        if (!use_soa) {
            if (!knobs.has("vitality_arr") || !knobs.has("low_streak_arr") || !knobs.has("high_streak_arr")) {
                diag("[veg_dyn] knobs missing vitality_arr/low_streak_arr/high_streak_arr (use_soa=false path)");
                return -1.0;
            }
        }
        PackedFloat32Array ideal_t_arr   = knobs["ideal_temp_table"];
        PackedFloat32Array ideal_m_arr   = knobs["ideal_moist_table"];
        PackedFloat32Array tol_t_arr     = knobs["temp_tol_table"];
        PackedFloat32Array tol_m_arr     = knobs["moist_tol_table"];
        PackedFloat32Array wt_pen_arr    = knobs["weather_penalty_table"];
        PackedFloat32Array resist_arr    = knobs["resistance_table"];
        PackedByteArray    next_up_arr   = knobs["next_up_table"];
        PackedByteArray    next_down_arr = knobs["next_down_table"];

        // VIT / LSK / HSK ptrw —— 二选一来源
        float   *VIT = nullptr;
        int32_t *LSK = nullptr;
        int32_t *HSK = nullptr;
        float   *VHEAT = nullptr;
        float   *VDROUGHT = nullptr;
        float   *VCOLD = nullptr;
        float   *VREGEN = nullptr;
        // 持有引用确保 ptrw 生命周期跨越整个 loop（老路径用 knobs 入口的 PackedArray，
        // 新路径用 _slots 内部的 PackedArray —— 后者由 _slots 持有）
        PackedFloat32Array vitality_arr;  // 老路径用
        PackedInt32Array   low_streak;    // 老路径用
        PackedInt32Array   high_streak;   // 老路径用
        if (use_soa) {
            Slot &s_vit  = _slots.write[sid_vit];
            Slot &s_lsk  = _slots.write[sid_low_streak];
            Slot &s_hsk  = _slots.write[sid_high_streak];
            if (s_vit.arr_f32.size() != n_cells ||
                s_lsk.arr_i32.size() != n_cells ||
                s_hsk.arr_i32.size() != n_cells) {
                diag("[veg_dyn] use_soa: vit/streak slot size != n_cells (bind_map_data missing?)");
                return -1.0;
            }
            VIT = s_vit.arr_f32.ptrw();
            LSK = s_lsk.arr_i32.ptrw();
            HSK = s_hsk.arr_i32.ptrw();
            if (vegetation_stress_enabled) {
                Slot &s_v_heat    = _slots.write[sid_v_heat];
                Slot &s_v_drought = _slots.write[sid_v_drought];
                Slot &s_v_cold    = _slots.write[sid_v_cold];
                Slot &s_v_regen   = _slots.write[sid_v_regen];
                if (s_v_heat.arr_f32.size() != n_cells ||
                    s_v_drought.arr_f32.size() != n_cells ||
                    s_v_cold.arr_f32.size() != n_cells ||
                    s_v_regen.arr_f32.size() != n_cells) {
                    diag("[veg_dyn] use_soa: vegetation stress slot size != n_cells");
                    return -1.0;
                }
                VHEAT = s_v_heat.arr_f32.ptrw();
                VDROUGHT = s_v_drought.arr_f32.ptrw();
                VCOLD = s_v_cold.arr_f32.ptrw();
                VREGEN = s_v_regen.arr_f32.ptrw();
            }
        } else {
            if (vegetation_stress_enabled) {
                diag("[veg_dyn] vegetation_stress_enabled requires use_soa=true");
                return -1.0;
            }
            vitality_arr = knobs["vitality_arr"];
            low_streak   = knobs["low_streak_arr"];
            high_streak  = knobs["high_streak_arr"];
            if (vitality_arr.size() != n_cells || low_streak.size() != n_cells ||
                high_streak.size() != n_cells) {
                diag("[veg_dyn] vitality/streak in/out array size mismatch");
                return -1.0;
            }
            VIT = vitality_arr.ptrw();
            LSK = low_streak.ptrw();
            HSK = high_streak.ptrw();
        }

        const int n_veg = ideal_t_arr.size();
        if (n_veg <= 0) { diag("[veg_dyn] ideal_temp_table empty"); return -1.0; }
        if (ideal_m_arr.size() != n_veg || tol_t_arr.size() != n_veg ||
            tol_m_arr.size() != n_veg || next_up_arr.size() != n_veg ||
            next_down_arr.size() != n_veg) {
            diag("[veg_dyn] VEG-indexed table size mismatch");
            return -1.0;
        }
        if (wt_pen_arr.size() < n_wt) { diag("[veg_dyn] weather_penalty_table size < n_wt"); return -1.0; }
        if (resist_arr.size() != n_veg * n_wt) {
            diag("[veg_dyn] resistance_table size != n_veg * n_wt");
            return -1.0;
        }

        const float   * const __restrict IDT  = ideal_t_arr.ptr();
        const float   * const __restrict IDM  = ideal_m_arr.ptr();
        const float   * const __restrict TLT  = tol_t_arr.ptr();
        const float   * const __restrict TLM  = tol_m_arr.ptr();
        const float   * const __restrict WPN  = wt_pen_arr.ptr();
        const float   * const __restrict RES  = resist_arr.ptr();
        const uint8_t * const __restrict NXU  = next_up_arr.ptr();
        const uint8_t * const __restrict NXD  = next_down_arr.ptr();

        auto t0 = std::chrono::high_resolution_clock::now();

        // S3：如实上报"生产这一天跑了 stage 9 VEGETATION_DYNAMICS"。native_daily
        // 路径真正跑的是这一份（stage_b ② 段），不是 run_vegetation_dynamics_pass。
        _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS;

        pk_async_climate::VegetationDynamicsEmit vd_emit;
        vd_emit.indices.reserve(64);
        vd_emit.to_veg.reserve(64);
        std::vector<int32_t> &succ_indices = vd_emit.indices;
        std::vector<uint8_t> &succ_to_veg  = vd_emit.to_veg;

        // ─── Main loop ─────────────────────────────────────
        // S3：下沉到共享纯内核。native_daily 生产热路径跑的就是这一处，
        // 所以 record_production_vegetation_input 也必须在这里取读当日真实输入：
        // weather_type / weather_intensity 已经被本 tick 的 weather pass 整场重写过，
        // environment 快照那份是 tick 起始拍的，用它等于拿昨天的天气算今天的植被。
        pk_async_climate::VegetationDynamicsKnobs vd_knobs;
        vd_knobs.ran = true;
        vd_knobs.scale = scale;
        vd_knobs.streak_days = streak_days;
        vd_knobs.vitality_change_rate = rate;
        vd_knobs.compat_harshness = harshness;
        vd_knobs.low_threshold = low_thresh;
        vd_knobs.high_threshold = high_thresh;
        vd_knobs.succession_degrade_days = degrade_days;
        vd_knobs.succession_upgrade_days = upgrade_days;
        vd_knobs.n_wt = n_wt;
        vd_knobs.wt_clear_id = wt_clear_id;
        vd_knobs.veg_none_id = veg_none_id;
        vd_knobs.weather_penalty_scale = weather_penalty_scale;
        vd_knobs.plant_water_balance_weight = plant_water_balance_weight;
        vd_knobs.plant_soil_buffer_weight = plant_soil_buffer_weight;
        vd_knobs.plant_drought_penalty = plant_drought_penalty;
        vd_knobs.succession_min_compat_gain = succession_min_compat_gain;
        vd_knobs.low_vitality_damping_threshold = low_vitality_damping_threshold;
        vd_knobs.succession_cooldown_days = succession_cooldown_days;
        vd_knobs.stress_enabled = vegetation_stress_enabled;
        vd_knobs.stress_blend = vegetation_stress_blend;
        vd_knobs.wt_blizzard_id = wt_blizzard_id;
        vd_knobs.wt_drought_id = wt_drought_id;
        vd_knobs.wt_heatwave_id = wt_heatwave_id;
        vd_knobs.n_veg = n_veg;
        vd_knobs.wt_pen_size = wt_pen_arr.size();

        pk_async_climate::VegetationDynamicsTables vd_tables;
        vd_tables.ideal_temp      = IDT;
        vd_tables.ideal_moist     = IDM;
        vd_tables.temp_tol        = TLT;
        vd_tables.moist_tol       = TLM;
        vd_tables.weather_penalty = WPN;
        vd_tables.resistance      = RES;
        vd_tables.next_up         = NXU;
        vd_tables.next_down       = NXD;

        pk_async_climate::VegetationDynamicsLanes vd_lanes;
        vd_lanes.is_water              = IW;
        vd_lanes.terrain               = TERR;
        vd_lanes.landform              = LF;
        vd_lanes.vegetation            = VG;
        vd_lanes.temp_30d              = T30;
        vd_lanes.moisture              = M;
        vd_lanes.water_balance_30d     = WBAL;
        vd_lanes.soil_moisture         = SOIL_COMP;
        vd_lanes.weather_type          = WTT;
        vd_lanes.weather_intensity     = WTI;
        vd_lanes.weather_field_init    = WTIN;
        vd_lanes.plant_available_water = PLANT_WATER;
        vd_lanes.vegetation_growth_pressure = VGP_COMP;
        vd_lanes.vitality              = VIT;
        vd_lanes.low_streak            = LSK;
        vd_lanes.high_streak           = HSK;
        vd_lanes.heat_stress           = VHEAT;
        vd_lanes.drought_stress        = VDROUGHT;
        vd_lanes.cold_stress           = VCOLD;
        vd_lanes.regen_score           = VREGEN;

        record_production_vegetation_input(vd_knobs, vd_tables, vd_lanes, n_cells);
        pk_async_climate::vegetation_dynamics_apply_pure(
            vd_knobs, vd_tables, vd_lanes, 0, n_cells, vd_emit);

        // 演替输出 → out_*_vd（最后统一写回 knobs）
        n_succ_vd = int(succ_indices.size());
        out_indices_vd.resize(n_succ_vd);
        out_to_veg_vd.resize(n_succ_vd);
        if (n_succ_vd > 0) {
            std::memcpy(out_indices_vd.ptrw(), succ_indices.data(), n_succ_vd * sizeof(int32_t));
            std::memcpy(out_to_veg_vd.ptrw(),  succ_to_veg.data(),  n_succ_vd * sizeof(uint8_t));
        }

        // 写回 in/out arrays —— 仅老路径（use_soa=false）需要把 vit/streak
        // PackedArray 重新塞回 knobs 让 GDScript caller unpack。新路径下
        // _slots 已经被 ptrw 直接修改，末尾 _flush_slot_to_map 会 ref-swap
        // 推回 MapData，GDScript 不需要 unpack。
        if (!use_soa) {
            knobs["vitality_arr"]    = vitality_arr;
            knobs["low_streak_arr"]  = low_streak;
            knobs["high_streak_arr"] = high_streak;
        }

        auto t1 = std::chrono::high_resolution_clock::now();
        veg_dyn_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
    // 即使 run_veg_dyn=false，也写空的演替结果保证 caller 端 unpack 安全
    knobs["succession_indices"]    = out_indices_vd;
    knobs["succession_to_veg"]     = out_to_veg_vd;
    knobs["stat_succession_count"] = n_succ_vd;
    if (n_succ_vd > 0) {
        const int64_t tick = int64_t(knobs.get("tick", int64_t(knobs.get("day_idx", 0))));
        const int32_t phase = int32_t(knobs.get("event_phase", 0));
        _emit_succession_events(out_indices_vd, out_to_veg_vd, VG, s_veg.arr_u8.size(), tick, phase, 1);
    }

    // ════════════════════════════════════════════════════════════════════
    // ③ FEEDBACK 段（1:1 复制 run_climate_feedback_pass 主循环）
    // ════════════════════════════════════════════════════════════════════
    if (run_feedback) {
        static const char *required_scalars[] = {
            "soil_gain", "veg_gain", "scale", "per_day_clamp",
            "ocean_drift_gain",
            "wt_rain_id", "wt_storm_id", "wt_monsoon_id",
            "wt_blizzard_id", "wt_drought_id", "wt_heatwave_id",
        };
        for (const char *k : required_scalars) {
            if (!knobs.has(k)) { diag("[feedback] knobs missing required scalar key"); return -1.0; }
        }
        const float soil_gain        = float(knobs["soil_gain"]);
        const float veg_gain         = float(knobs["veg_gain"]);
        const float scale            = float(knobs["scale"]);
        const float per_day_clamp    = float(knobs["per_day_clamp"]);
        const float ocean_drift_gain = float(knobs["ocean_drift_gain"]);
        // 让天气流动(2026-06-21)：weather → base_moisture 反馈增益(optional; 缺省 0 = 关闭)。
        const float base_m_gain = float(knobs.has("weather_to_base_moisture_gain") ? double(knobs["weather_to_base_moisture_gain"]) : 0.0);
        const int   wt_rain_id       = int(knobs["wt_rain_id"]);
        const int   wt_storm_id      = int(knobs["wt_storm_id"]);
        const int   wt_monsoon_id    = int(knobs["wt_monsoon_id"]);
        const int   wt_blizzard_id   = int(knobs["wt_blizzard_id"]);
        const int   wt_drought_id    = int(knobs["wt_drought_id"]);
        const int   wt_heatwave_id   = int(knobs["wt_heatwave_id"]);
        const bool  write_weather_veg_pressure = bool(knobs.get("write_weather_veg_pressure", true));

        if (!knobs.has("neighbor_indices")) {
            diag("[feedback] knobs missing neighbor_indices");
            return -1.0;
        }
        // 老路径（use_soa=false）：tta/soil/vg 通过 knobs 传入 PackedArray
        // 新路径（use_soa=true）： 直接走 _slots[sid_*].arr_f32
        if (!use_soa) {
            if (!knobs.has("temp_transport_anomaly") ||
                !knobs.has("soil_moisture_arr") || !knobs.has("veg_growth_pressure_arr")) {
                diag("[feedback] knobs missing required PackedArray key (use_soa=false path)");
                return -1.0;
            }
        }
        PackedInt32Array   nb_arr   = knobs["neighbor_indices"];
        if (nb_arr.size() < n_cells * 6) { diag("[feedback] neighbor_indices size < n_cells * 6"); return -1.0; }
        const int32_t * const __restrict NB    = nb_arr.ptr();

        // tta（read）/ soil（read+write）/ vg（read+write）—— 二选一来源
        const float *TTA  = nullptr;
        float       *SOIL = nullptr;
        float       *VGP  = nullptr;
        // 老路径下持有 PackedArray 引用确保 ptrw 生命周期
        PackedFloat32Array tta_arr;
        PackedFloat32Array soil_arr;
        PackedFloat32Array vg_arr;
        if (use_soa) {
            Slot &s_tta  = _slots.write[sid_tta];
            Slot &s_soil = _slots.write[sid_soil];
            Slot &s_vgp  = _slots.write[sid_vgp];
            if (s_tta.arr_f32.size()  != n_cells ||
                s_soil.arr_f32.size() != n_cells ||
                s_vgp.arr_f32.size()  != n_cells) {
                diag("[feedback] use_soa: tta/soil/vg slot size != n_cells (bind_map_data missing?)");
                return -1.0;
            }
            TTA  = s_tta.arr_f32.ptr();
            SOIL = s_soil.arr_f32.ptrw();
            VGP  = s_vgp.arr_f32.ptrw();
        } else {
            tta_arr  = knobs["temp_transport_anomaly"];
            soil_arr = knobs["soil_moisture_arr"];
            vg_arr   = knobs["veg_growth_pressure_arr"];
            if (tta_arr.size() != n_cells)   { diag("[feedback] temp_transport_anomaly size mismatch"); return -1.0; }
            if (soil_arr.size() != n_cells)  { diag("[feedback] soil_moisture_arr size mismatch"); return -1.0; }
            if (vg_arr.size() != n_cells)    { diag("[feedback] veg_growth_pressure_arr size mismatch"); return -1.0; }
            TTA  = tta_arr.ptr();
            SOIL = soil_arr.ptrw();
            VGP  = vg_arr.ptrw();
        }

        auto t0 = std::chrono::high_resolution_clock::now();

        // ─── Main loop ────────────────────────────────
        // S3：与 run_climate_feedback_pass 一同下沉到共享纯 kernel。这里原先是第三份
        // 逐字副本，而它才是生产 native_daily 路径上真正跑的那一份。
        pk_async_climate::ClimateFeedbackKnobs fb_knobs;
        fb_knobs.ran = true;
        fb_knobs.soil_gain = soil_gain;
        fb_knobs.veg_gain = veg_gain;
        fb_knobs.scale = scale;
        fb_knobs.per_day_clamp = per_day_clamp;
        fb_knobs.ocean_drift_gain = ocean_drift_gain;
        fb_knobs.base_moisture_gain = base_m_gain;
        fb_knobs.write_weather_veg_pressure = write_weather_veg_pressure;
        fb_knobs.wt_rain_id = wt_rain_id;
        fb_knobs.wt_storm_id = wt_storm_id;
        fb_knobs.wt_monsoon_id = wt_monsoon_id;
        fb_knobs.wt_blizzard_id = wt_blizzard_id;
        fb_knobs.wt_drought_id = wt_drought_id;
        fb_knobs.wt_heatwave_id = wt_heatwave_id;
        record_production_feedback_input(fb_knobs, n_cells, IW, WTT, WTI, WTIN,
                                        TTA, BM, SOIL);
        pk_async_climate::climate_feedback_apply_pure(
            fb_knobs, IW, WTT, WTI, WTIN, NB, TTA, BM, SOIL, VGP, 0, n_cells);

        // 写回 in/out arrays —— 仅老路径需要把 soil/vg 重新塞回 knobs；
        // 新路径下 _slots 已被 ptrw 直接修改，末尾 _flush_slot_to_map 推回。
        if (!use_soa) {
            knobs["soil_moisture_arr"]       = soil_arr;
            knobs["veg_growth_pressure_arr"] = vg_arr;
        }

        auto t1 = std::chrono::high_resolution_clock::now();
        feedback_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        flush_base_m = true;
    }

    // ════════════════════════════════════════════════════════════════════
    // 末尾批量 flush（仅推 SoA 写出过的 slot；Variant 引用交换 O(1)）
    // ════════════════════════════════════════════════════════════════════
    if (flush_temp)   _flush_slot_to_map(sid_temp);
    if (flush_base_m) _flush_slot_to_map(sid_base_m);
    // B3b：use_soa 路径下，veg_dyn 段写过 vit/low/high，feedback 段写过 soil/vg。
    // 这些 slot 的 arr_f32 / arr_i32 已经被 ptrw 直接修改，需要 _flush_slot_to_map
    // 把 _slots[].arr_* 推回 MapData.<map_field>（CoW 引用交换 O(1)）。
    // 老路径下这些 slot 没人写，flush 无害，但为了代码简洁仅在 use_soa=true 时 flush。
    if (use_soa) {
        if (run_veg_dyn) {
            _flush_slot_to_map(sid_vit);
            _flush_slot_to_map(sid_low_streak);
            _flush_slot_to_map(sid_high_streak);
            _flush_slot_to_map(sid_vgp);
            _flush_slot_to_map(sid_plant_water);
            if (vegetation_stress_enabled_stage_b) {
                _flush_slot_to_map(sid_v_heat);
                _flush_slot_to_map(sid_v_drought);
                _flush_slot_to_map(sid_v_cold);
                _flush_slot_to_map(sid_v_regen);
            }
        }
        if (run_feedback) {
            _flush_slot_to_map(sid_soil);
            _flush_slot_to_map(sid_vgp);
        }
    }

    // 计时回填
    knobs["albedo_ms"]   = albedo_ms;
    knobs["veg_dyn_ms"]  = veg_dyn_ms;
    knobs["feedback_ms"] = feedback_ms;

    auto t_total_1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t_total_1 - t_total_0).count();
}

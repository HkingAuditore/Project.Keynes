// plan/dots-slp-psi-cpp — SLP field solver (stage 1)
// ═══════════════════════════════════════════════════════════════════════════
//
// PhysicalCirculationSolver.solve_slp_field native authority:
//   Pass A writes the per-cell SLP target from:
//     - three-cell latitude pressure belts,
//     - current solar-insolation anomaly from orbital phase + axial tilt,
//     - land/sea thermal inertia and continentality,
//     - optional temp anomaly, ice/snow highs, moist/cloud lows, synoptic waves.
//   `season_phase` is only the year/orbital phase used to compute solar
//   declination/insolation; it is not used as an independent season sign.
//   Pass B applies smooth_passes rounds of 6-neighbor Jacobi smoothing.

godot::Dictionary DCWorldExt::run_slp_field_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["published_to_slot"] = false;
    out["slice_start"] = -1;
    out["slice_end"] = -1;
    out["slice_final"] = false;
    out["slot_id"] = -1;
    out["slot_size"] = 0;
    out["slot_publish_reason"] = String("not_evaluated");

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        out["slot_publish_reason"] = String("pass_fallback");
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_slp_field_pass: ", why,
            " — fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not _bound");

    static const char *required_keys[] = {
        "n_cells", "hex_size", "season_phase", "smooth_passes",
        "world_bounds_pos_y", "world_bounds_size_y",
        "neighbor_indices", "water_terrain_ids",
        nullptr,
    };
    for (int k = 0; required_keys[k] != nullptr; ++k) {
        if (!knobs.has(required_keys[k])) {
            String s = String("missing knob '") + String(required_keys[k]) + String("'");
            return fail(s.utf8().get_data());
        }
    }

    const int    n_cells       = int(knobs["n_cells"]);
    const double season_phase  = double(knobs["season_phase"]);
    const int    smooth_passes = int(knobs["smooth_passes"]);
    const double bounds_pos_y  = double(knobs["world_bounds_pos_y"]);
    const double bounds_size_y = double(knobs["world_bounds_size_y"]);
    if (n_cells <= 0)            return fail("n_cells <= 0");
    if (bounds_size_y <= 0.001)  return fail("world_bounds_size_y <= 0.001");

    // Tunables (defaults match GDScript constants; allow override via knobs).
    const float A_LAT          = float(knobs.has("slp_lat_amp")        ? double(knobs["slp_lat_amp"])        : 0.16);
    const float A_LAND         = float(knobs.has("slp_land_amp")       ? double(knobs["slp_land_amp"])       : 0.55);
    const float WATER_DAMP     = float(knobs.has("slp_water_damp")     ? double(knobs["slp_water_damp"])     : 0.20);
    const float INTERIOR_BOOST = float(knobs.has("slp_interior_boost") ? double(knobs["slp_interior_boost"]) : 1.30);
    const float COAST_DAMP     = float(knobs.has("slp_coast_damp")     ? double(knobs["slp_coast_damp"])     : 0.60);
    const float THERMAL_WEIGHT = float(knobs.has("wind_thermal_slp_weight") ? double(knobs["wind_thermal_slp_weight"]) : 0.0);
    const float ICE_HIGH_WEIGHT = float(knobs.has("slp_ice_high_weight") ? double(knobs["slp_ice_high_weight"]) : 0.0);
    const float SNOW_HIGH_WEIGHT = float(knobs.has("slp_snow_high_weight") ? double(knobs["slp_snow_high_weight"]) : 0.0);
    float slp_response_rate = float(knobs.has("slp_response_rate") ? double(knobs["slp_response_rate"]) : 0.55);
    if (slp_response_rate < 0.0f) slp_response_rate = 0.0f;
    else if (slp_response_rate > 1.0f) slp_response_rate = 1.0f;
    const float SLP_SYNOPTIC_AMP = float(knobs.has("slp_synoptic_amp") ? double(knobs["slp_synoptic_amp"]) : 0.075);
    // 让天气流动(2026-06-21 阶段1)：移动低压系统 knobs（hot loop 外解析）。count=0 或 amp=0 关闭。
    int mobile_low_count = knobs.has("slp_mobile_low_count") ? int(knobs["slp_mobile_low_count"]) : 0;
    if (mobile_low_count < 0) mobile_low_count = 0;
    else if (mobile_low_count > 8) mobile_low_count = 8;
    float mobile_low_amp = float(knobs.has("slp_mobile_low_amp") ? double(knobs["slp_mobile_low_amp"]) : 0.0);
    if (mobile_low_amp < 0.0f) mobile_low_amp = 0.0f;
    float mobile_low_sigma = float(knobs.has("slp_mobile_low_sigma") ? double(knobs["slp_mobile_low_sigma"]) : 0.16);
    if (mobile_low_sigma < 0.02f) mobile_low_sigma = 0.02f;
    double mobile_low_period = knobs.has("slp_mobile_low_period_days") ? double(knobs["slp_mobile_low_period_days"]) : 38.0;
    if (mobile_low_period < 1.0) mobile_low_period = 1.0;
    const float MOIST_LOW_WEIGHT = float(knobs.has("slp_moist_low_weight") ? double(knobs["slp_moist_low_weight"]) : 0.12);
    const bool SLP_RECENTER = bool(knobs.has("slp_recenter") ? bool(knobs["slp_recenter"]) : true);
    const float SLP_TARGET_P95 = float(knobs.has("slp_target_p95") ? double(knobs["slp_target_p95"]) : 0.18);
    int days_per_year = int(knobs.has("days_per_year") ? int(knobs["days_per_year"]) : 365);
    if (days_per_year < 1) days_per_year = 1;
    else if (days_per_year > 3660) days_per_year = 3660;
    double year_phase = std::fmod(season_phase, 4.0);
    if (year_phase < 0.0) year_phase += 4.0;
    const int sim_day = int(knobs.has("sim_day") ? int(knobs["sim_day"]) : int(std::floor((year_phase / 4.0) * double(days_per_year))));
    const int world_seed = int(knobs.has("world_seed") ? int(knobs["world_seed"]) : 0);
    const double wrap_origin_x = double(knobs.has("wrap_origin_x") ? double(knobs["wrap_origin_x"]) : 0.0);
    const double wrap_period_x = double(knobs.has("wrap_period_x") ? double(knobs["wrap_period_x"]) : 0.0);
    // 天气尺度修复(2026-06-19)：SLP synoptic 时间项原先 sim_day*0.071(≈88 天/周期)，在日/月尺度上
    // 准静止。改用 synoptic 角速率 2π/period(~6 天/周期)，让压力距平逐日漂移，与风场 synoptic 协同
    // 推动天气系统移动。共用 wind_synoptic_period_days knob。在循环外提升为常量。镜像见 run_wind_field_pass。
    double slp_synoptic_period_days = double(knobs.has("wind_synoptic_period_days") ? double(knobs["wind_synoptic_period_days"]) : 6.0);
    if (slp_synoptic_period_days < 0.5) slp_synoptic_period_days = 0.5;

    PackedInt32Array nb_arr   = knobs["neighbor_indices"];
    PackedByteArray  water_ids = knobs["water_terrain_ids"];
    PackedFloat32Array prev_slp_arr;
    if (knobs.has("prev_slp_arr")) {
        prev_slp_arr = knobs["prev_slp_arr"];
    }
    if (nb_arr.size()  < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");
    if (water_ids.size() <= 0)         return fail("water_terrain_ids empty");
    if (prev_slp_arr.size() != 0 && prev_slp_arr.size() != n_cells) {
        return fail("prev_slp_arr size mismatch");
    }

    // Slot resolution (cached via _phys_resolve_static; FNV 指纹失效，地图 regen 自动重建)。
    _phys_resolve_static(n_cells, water_ids);
    const int sid_pos_y   = _phys_sid_pos_y;
    const int sid_pos_x   = _phys_sid_pos_x;  // 让天气流动: SLP synoptic 二维空间波(optional)
    const int sid_terrain = _phys_sid_terrain;
    const int sid_temp_an = _phys_sid_temp_an;
    const int sid_snow    = _phys_sid_snow;
    const int sid_ice     = _phys_sid_ice;
    const int sid_w_vapor = _phys_sid_wvap;
    const int sid_w_cloud = _phys_sid_wcld;
    if (sid_pos_y < 0 || sid_terrain < 0) {
        return fail("missing slot id (cell_pos_y/cell_terrain)");
    }
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_terrain = _slots.write[sid_terrain];
    if (s_pos_y.arr_f32.size()  != n_cells ||
        s_terrain.arr_u8.size() != n_cells) {
        return fail("slot array size mismatch (re-bind needed?)");
    }

    // is_water LUT (cached via _phys_resolve_static, 同指纹随 slot 一起重建)。
    const bool *is_water_lut = _phys_is_water_lut;

    // perf (Item 2a, 2026-07-07): cell-range 切片旋钮。默认 start_idx=0 / end_idx=n_cells
    // → 单次全量 pass（与历史逐位等价，向后兼容）。GDScript 游标可传子区间把 Pass A 拆成
    // 多次调用；Pass B/norm/融合/发布只在末切片 end_idx==n_cells 跑，跨切片靠 _phys_slp_buf
    // 累积 Pass A 结果。切片外不触碰 slot，避免部分数据污染 cell_slp。
    int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    int end_idx   = knobs.has("end_idx")   ? int(knobs["end_idx"])   : n_cells;
    if (start_idx < 0)            start_idx = 0;
    if (end_idx > n_cells)        end_idx   = n_cells;
    if (start_idx > end_idx)      start_idx = end_idx;
    const int slice_n = end_idx - start_idx;
    const bool slice_final = end_idx == n_cells;
    const int sid_slp = component_id(StringName("cell_slp"));
    const int slp_slot_size = sid_slp >= 0 ? _slots.write[sid_slp].arr_f32.size() : 0;
    out["slice_start"] = start_idx;
    out["slice_end"] = end_idx;
    out["slice_final"] = slice_final;
    out["slot_id"] = sid_slp;
    out["slot_size"] = slp_slot_size;
    out["slot_publish_reason"] = slice_final
        ? (sid_slp < 0 ? String("slot_missing")
                       : (slp_slot_size != n_cells ? String("slot_size_mismatch")
                                                   : String("slot_ready")))
        : String("intermediate_slice");

    const float   * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float *POSX = nullptr;  // 让天气流动: SLP synoptic 改地理坐标二维波(无则退回 i 索引)
    if (sid_pos_x >= 0 && _slots.write[sid_pos_x].arr_f32.size() == n_cells) {
        POSX = _slots.write[sid_pos_x].arr_f32.ptr();
    }
    const float *TEMP_AN = nullptr;
    const float *SNOW = nullptr;
    const float *ICE = nullptr;
    const float *WVAP = nullptr;
    const float *WCLD = nullptr;
    const float *PREV_SLP = (prev_slp_arr.size() == n_cells) ? prev_slp_arr.ptr() : nullptr;
    if (sid_temp_an >= 0 && _slots.write[sid_temp_an].arr_f32.size() == n_cells) {
        TEMP_AN = _slots.write[sid_temp_an].arr_f32.ptr();
    }
    if (sid_snow >= 0 && _slots.write[sid_snow].arr_f32.size() == n_cells) {
        SNOW = _slots.write[sid_snow].arr_f32.ptr();
    }
    if (sid_ice >= 0 && _slots.write[sid_ice].arr_f32.size() == n_cells) {
        ICE = _slots.write[sid_ice].arr_f32.ptr();
    }
    if (sid_w_vapor >= 0 && _slots.write[sid_w_vapor].arr_f32.size() == n_cells) {
        WVAP = _slots.write[sid_w_vapor].arr_f32.ptr();
    }
    if (sid_w_cloud >= 0 && _slots.write[sid_w_cloud].arr_f32.size() == n_cells) {
        WCLD = _slots.write[sid_w_cloud].arr_f32.ptr();
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    const float axial_tilt_deg = float(knobs.has("axial_tilt_deg") ? double(knobs["axial_tilt_deg"]) : 23.5);
    const float daylen_amp = float(knobs.has("insolation_daylen_amp") ? double(knobs["insolation_daylen_amp"]) : 0.35);

    // Output buffer (n_cells floats); will become slp_out PackedFloat32Array.
    // perf (Item 2a, 2026-07-07): slp_buf 改为 _phys_slp_buf 引用——持久、跨切片累积 Pass A。
    // Pass A 对每 cell 用 '=' 全量覆写，切片区间外无依赖，故无需清零；仅 size 失配时 resize。
    if (_phys_slp_buf.size() != static_cast<size_t>(n_cells)) {
        _phys_slp_buf.assign(static_cast<size_t>(n_cells), 0.0f);
    }
    std::vector<float> &slp_buf = _phys_slp_buf;
    std::vector<float> slp_delta(static_cast<size_t>(n_cells), 0.0f);
    // perf (Item 2a): thermal_abs 同样持久化（仅在权重非 0 时保留 size，否则 clear），
    // 使末切片 slp_thermal_p95 基于完整场（各切片 Pass A 均已写入其区间）。
    std::vector<float> &thermal_abs = _phys_slp_thermal_abs;
    if (A_LAND != 0.0f || THERMAL_WEIGHT != 0.0f || ICE_HIGH_WEIGHT != 0.0f || SNOW_HIGH_WEIGHT != 0.0f) {
        if (thermal_abs.size() != static_cast<size_t>(n_cells)) {
            thermal_abs.assign(static_cast<size_t>(n_cells), 0.0f);
        }
    } else {
        thermal_abs.clear();
    }

    // ─── Latitude LUT (plan/slp-lat-lut, 2026-06-17) ──────────────────────
    // base_lat 与 solar_heat 只依赖纬度 ny（固定 season/axial_tilt 的一次 pass 内）。
    // 旧实现每 cell 重算 base_lat(cos) + s_lat(sin) + dc_insolation_now(~9 trig) +
    // dc_insolation_annual_mean(16×9=144 trig) ≈ 155 次超越函数；6400 cell ≈ 100 万次。
    // 这里改成：pass 内按 ny 预建 B 档 LUT（B×155 次），cell 循环只做一次线性插值。
    // dc_insolation_annual_mean 是年均、与 season 无关，本就对所有同纬度 cell 恒等，
    // 预建后冗余完全消除。B 默认 1024（≈0.18° 纬度分辨率，足以分辨极昼/极夜 acos 拐点）。
    int slp_lat_lut_bins = int(knobs.has("slp_lat_lut_bins") ? int(knobs["slp_lat_lut_bins"]) : 1024);
    if (slp_lat_lut_bins < 16) slp_lat_lut_bins = 16;
    else if (slp_lat_lut_bins > 8192) slp_lat_lut_bins = 8192;
    const int LUT_BINS = slp_lat_lut_bins;
    std::vector<float> lut_base_lat(static_cast<size_t>(LUT_BINS), 0.0f);
    std::vector<float> lut_solar_heat(static_cast<size_t>(LUT_BINS), 0.0f);
    // perf (Item 5b, 2026-07-05): dc_insolation_annual_mean(ny_b, axial_tilt, daylen)
    // 是本 LUT 里唯一 season-无关的项（16×9 trig/bin），每 pass 重算纯冗余。缓存该年均
    // 子 LUT，指纹 = FNV-1a(LUT_BINS, axial_tilt bits, daylen bits)。命中即逐位复用
    // → bit-equal（insol_now/solar_dev/base_lat 仍每 pass 重建，因 season_phase 变化）。
    {
        uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
        auto mix = [&fp](uint32_t bits) {
            fp ^= uint64_t(bits);
            fp *= 1099511628211ull; // FNV-1a prime
        };
        mix(uint32_t(LUT_BINS));
        {
            uint32_t b;
            std::memcpy(&b, &axial_tilt_deg, sizeof(b));
            mix(b);
            std::memcpy(&b, &daylen_amp, sizeof(b));
            mix(b);
        }
        if (!(_slp_insol_mean_lut_valid && _slp_insol_mean_lut_fp == fp &&
              int(_slp_insol_mean_lut.size()) == LUT_BINS)) {
            _slp_insol_mean_lut.resize(static_cast<size_t>(LUT_BINS));
            for (int b = 0; b < LUT_BINS; ++b) {
                const float ny_b = float(b) / float(LUT_BINS - 1);
                _slp_insol_mean_lut[static_cast<size_t>(b)] =
                    dc_insolation_annual_mean(ny_b, axial_tilt_deg, daylen_amp);
            }
            _slp_insol_mean_lut_fp = fp;
            _slp_insol_mean_lut_valid = true;
        }
    }
    // 年均缓存仍由主线程持有；逐轮 LUT 与空间强迫统一由 prepare_slp_forcing 生成。

    // 让天气流动(2026-06-21)：SLP synoptic 由 cell 索引 i 改地理坐标 (px,py) 二维低频空间波。
    // 原 sin(i*4.886) 在索引空间周期≈1.3 格 → 高频碎压差 → 6 邻域 ∇ 放大成碎风向 → 平流相互
    // 抵消而非整团输送(用户反馈"风场太细")。改大尺度 (px,py) 波 → 平滑压差 → 风带成片、整团
    // 输送云系。bounds_x 自 POSX 求取(沿用 wind synoptic 同款归一化)。
    double slp_bounds_pos_x = 0.0, slp_inv_bounds_w = 1.0;
    if (POSX != nullptr && n_cells > 0) {
        double bx_min = double(POSX[0]); double bx_max = bx_min;
        for (int i = 1; i < n_cells; ++i) {
            const double v = double(POSX[i]);
            if (v < bx_min) bx_min = v;
            if (v > bx_max) bx_max = v;
        }
        slp_bounds_pos_x = bx_min;
        slp_inv_bounds_w = 1.0 / std::max(0.001, bx_max - bx_min);
        static bool s_warned_slp_wrap = false;
        physical_warn_wrap_units("slp_field", wrap_period_x, bx_max - bx_min, s_warned_slp_wrap);
    }
    const bool slp_has_wrap_domain = wrap_period_x > 0.001;
    // 纬度权威：cell_lat_norm slot（见 phys_make_lat_norm）。world_bounds_* 不再参与纬度归一化。
    const PhysLatNorm LATN = phys_make_lat_norm(_phys_lat_norm_ptr(n_cells), POSY, n_cells);
    (void)bounds_pos_y;
    (void)bounds_size_y;

    // 让天气流动(2026-06-21 阶段1)：移动低压中心（循环外预计算；hot loop 仅做 exp 距离衰减）。
    // 每个低压由 (world_seed, j) 哈希出确定性初始相位/纬度，随 sim_day 自西向东平移（中纬西风带
    // 主导）并在归一化 x∈[0,1) 环绕（到东缘从西缘重入 → 源源不断的过境系统），纬度叠加慢摆动。
    // 无 cell_pos_x slot（POSX==nullptr）或 amp<=0 时无法/无需定位中心 → 退化关闭，向后兼容。
    const int n_mlow = (POSX != nullptr && mobile_low_amp > 0.0f) ? mobile_low_count : 0;

    // ─── Pass A: per-cell baseline ────────────────────────────────────────
    // perf (2A): 逐 cell 独立（读 POSY/TR/NB/LUT/可选场 slot，写 slp_buf[i]/thermal_abs[i]，
    // 无标量累加器；mobile_low/synoptic 均 cell-local）→ 按 cell 区间并行、bit-equal。
    // perf (Item 5a, 2026-07-05): synoptic 波数 sa/sb/k1x..k2y 只依赖 world_seed，
    // 原在 cell 循环内每 cell 重算 4 次 sin/cos。外提到循环外一次算好 → bit-equal
    // (逐 cell 值不变，只是不再重复 6400 次三角)。
    // 经向必须采用整数谐波，才能同时保证场值与经向导数在圆柱接缝连续。
    // 波数标定(wind-variability 2026-08-03)：k1x∈{1,2} 时本项经向梯度只有
    // AMP·0.65·2π·k1x/100 ≈ 0.011/格，而静态纬向基线约 0.030/格 → 天气扭不动风向。
    // 改 {3..6}（均值 4.5）后约 0.033/格，与静态基线同量级：竞争得起但不压倒。
    // k1y 只温和提高（[0.9,1.7]，约 0.015/行 = 静态基线一半）—— 纬向 SLP 梯度正是
    // 三圈环流风带的定义者，经向涟漪过强会把风带打碎成涡群而非「会蜿蜒的带」。
    // B8 P2：Pass A 已抽成 Godot 无依赖的共享内核（worker 走同一份）。
    // 生产保留 parallel_for_range 分段：逐 cell 独立 → 分段 bit-equal。
    pk_async_physics::SlpPassAKnobs slp_a;
    slp_a.lat_amp = A_LAT;
    slp_a.land_amp = A_LAND;
    slp_a.water_damp = WATER_DAMP;
    slp_a.interior_boost = INTERIOR_BOOST;
    slp_a.coast_damp = COAST_DAMP;
    slp_a.thermal_weight = THERMAL_WEIGHT;
    slp_a.ice_high_weight = ICE_HIGH_WEIGHT;
    slp_a.snow_high_weight = SNOW_HIGH_WEIGHT;
    slp_a.moist_low_weight = MOIST_LOW_WEIGHT;
    slp_a.synoptic_amp = SLP_SYNOPTIC_AMP;
    slp_a.bounds_pos_x = float(slp_bounds_pos_x);
    slp_a.inv_bounds_w = float(slp_inv_bounds_w);
    slp_a.has_wrap_domain = slp_has_wrap_domain;
    slp_a.wrap_origin_x = wrap_origin_x;
    slp_a.wrap_period_x = wrap_period_x;
    slp_a.world_seed = world_seed;
    pk_async_physics::prepare_slp_forcing(slp_a, LUT_BINS, float(season_phase),
        axial_tilt_deg, daylen_amp, sim_day, slp_synoptic_period_days,
        n_mlow, mobile_low_amp, mobile_low_sigma, mobile_low_period,
        lut_base_lat, lut_solar_heat, _slp_insol_mean_lut.data());
    pk_async_physics::SlpPassALanes slp_lanes;
    slp_lanes.lat_norm = LATN.lat;
    slp_lanes.pos_y = LATN.posy;
    slp_lanes.lat_origin = LATN.origin;
    slp_lanes.lat_inv_span = LATN.inv_span;
    slp_lanes.terrain = TR;
    slp_lanes.neighbors = NB;
    slp_lanes.pos_x = POSX;
    slp_lanes.temp_anomaly = TEMP_AN;
    slp_lanes.ice = ICE;
    slp_lanes.snow = SNOW;
    slp_lanes.vapor = WVAP;
    slp_lanes.cloud = WCLD;
    slp_lanes.is_water_lut = is_water_lut;
    auto slp_passA_range = [&](int rb, int re) {
        pk_async_physics::slp_pass_a_range(
            n_cells, start_idx + rb, start_idx + re, slp_a, slp_lanes,
            slp_buf.data(),
            thermal_abs.empty() ? nullptr : thermal_abs.data());
    };
    pk::parallel_for_range("pk_slp_passA", slice_n, slp_passA_range);

    // 埋点（plan/daily-wind-stage-split）：Pass A（逐 cell 三角/insolation/synoptic）
    // 通常是 SLP 的大头；t_slp_pa 标记 Pass A 结束。
    auto t_slp_pa = std::chrono::high_resolution_clock::now();

    // ─── 全图归约段：仅最终切片(end_idx==n_cells)执行 ───────────────────────
    // Pass B 平滑 / recenter+p95 / 融合 / slot 发布 均依赖完整 slp_buf 才能逐位等价；
    // 中间切片只把 Pass A 结果累积进 _phys_slp_buf，构造 full-size slp_out 供 GDScript
    // size-gate 通过（但不会被用作地图值），且不触碰 cell_slp slot。GDScript 游标须保证
    // 末切片 end_idx==n_cells 覆盖全图，使 _phys_slp_buf 在末切片时已是完整 Pass A 场。
    bool published_to_slot = false;
    PackedFloat32Array slp_out;
    slp_out.resize(n_cells);
    auto t_slp_pb   = t_slp_pa;
    auto t_slp_norm = t_slp_pa;
    if (end_idx == n_cells) {
    // ─── Pass B: 6-neighbor Jacobi smoothing ──────────────────────────────
    // B8 P2：平滑 + recenter/p95 + 响应混合 + delta 全部走共享内核
    // （pk_async_physics::slp_pass_b_pure）。生产侧只负责准备 scratch 与参数。
    std::vector<float> tmp(static_cast<size_t>(n_cells), 0.0f);
    {
        // 段 1：只做 Jacobi 平滑（保持 slp_passB_ms 的原有口径）。
        pk_async_physics::SlpPassBKnobs slp_b;
        slp_b.smooth_passes = smooth_passes;
        slp_b.recenter = false;
        slp_b.response_rate = -1.0f;
        pk_async_physics::slp_pass_b_pure(
            n_cells, slp_b, NB, nullptr, slp_buf.data(),
            (smooth_passes > 0) ? tmp.data() : nullptr,
            nullptr);
    }

    // 埋点：t_slp_pb 标记 Pass B（邻域平滑）结束。
    t_slp_pb = std::chrono::high_resolution_clock::now();

    {
        // 段 2：recenter + p95 缩放（slp_norm_ms 的原有口径）。
        pk_async_physics::SlpPassBKnobs slp_b;
        slp_b.smooth_passes = 0;
        slp_b.recenter = SLP_RECENTER;
        slp_b.target_p95 = SLP_TARGET_P95;
        slp_b.response_rate = -1.0f;
        pk_async_physics::slp_pass_b_pure(
            n_cells, slp_b, nullptr, nullptr, slp_buf.data(),
            (n_cells > 0) ? tmp.data() : nullptr, nullptr);
    }

    // 埋点：t_slp_norm 标记 recenter + p95 排序 + 缩放（norm 段）结束。
    t_slp_norm = std::chrono::high_resolution_clock::now();

    // ─── Marshall slp_out ─────────────────────────────────────────────────
    {
        // 段 3：响应混合（prev → cur）+ 再 recenter + delta。这三步原先就落在
        // marshall 段（t_slp_norm 之后），所以计时口径不变。
        pk_async_physics::SlpPassBKnobs slp_b;
        slp_b.smooth_passes = 0;
        slp_b.recenter = SLP_RECENTER;
        slp_b.target_p95 = 0.0f;   // 段 3 不再做 p95 缩放
        slp_b.response_rate = (PREV_SLP != nullptr) ? slp_response_rate : -1.0f;
        pk_async_physics::slp_pass_b_pure(
            n_cells, slp_b, nullptr, PREV_SLP, slp_buf.data(), nullptr,
            slp_delta.empty() ? nullptr : slp_delta.data());
    }
    {
        float *dst = slp_out.ptrw();
        std::memcpy(dst, slp_buf.data(), sizeof(float) * static_cast<size_t>(n_cells));
    }

    if (sid_slp >= 0 && slp_slot_size == n_cells) {
        float *dst = _slots.write[sid_slp].arr_f32.ptrw();
        std::memcpy(dst, slp_buf.data(), sizeof(float) * static_cast<size_t>(n_cells));
        _flush_slot_to_map(sid_slp);
        published_to_slot = true;
        out["slot_publish_reason"] = String("slot_published");
    }
    } else {
        // 中间切片：仅构造 full-size slp_out（GDScript size-gate 通过；不会被用作地图值），
        // 不发布到 cell_slp slot、不计算 stats。Pass A 结果已写入 _phys_slp_buf 对应区间。
        float *dst = slp_out.ptrw();
        std::memcpy(dst, slp_buf.data(), sizeof(float) * static_cast<size_t>(n_cells));
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"]   = false;
    out["reason"]     = String();
    out["slp_out"]    = slp_out;
    out["published_to_slot"] = published_to_slot;
    knobs["slp_out"]  = slp_out;
    // 埋点 surface（plan/daily-wind-stage-split）：把 SLP 内部 4 段耗时返回给
    // GDScript，定位每日 ~3ms 花在 Pass A(三角)/Pass B(平滑)/norm(排序)/marshall(发布)。
    // 注意 elapsed_ms = t1-t0 不含末尾 stats 排序段（与历史一致）。
    out["slp_passA_ms"]    = std::chrono::duration<double, std::milli>(t_slp_pa - t0).count();
    out["slp_passB_ms"]    = std::chrono::duration<double, std::milli>(t_slp_pb - t_slp_pa).count();
    out["slp_norm_ms"]     = std::chrono::duration<double, std::milli>(t_slp_norm - t_slp_pb).count();
    out["slp_marshall_ms"] = std::chrono::duration<double, std::milli>(t1 - t_slp_norm).count();
    // stats 仅在末切片（完整场）计算；中间切片跳过，避免发出误导性的 partial 统计量。
    if (end_idx == n_cells) {
    if (!thermal_abs.empty()) {
        std::sort(thermal_abs.begin(), thermal_abs.end());
        const size_t p95_i = thermal_abs.empty() ? 0 : std::min(thermal_abs.size() - 1, size_t(std::floor(double(thermal_abs.size() - 1) * 0.95)));
        out["slp_thermal_p95"] = double(thermal_abs[p95_i]);
    }
    if (n_cells > 0) {
        double mean = 0.0;
        for (int i = 0; i < n_cells; ++i) {
            mean += double(slp_buf[i]);
        }
        mean /= double(n_cells);
        double var = 0.0;
        std::vector<float> slp_abs(static_cast<size_t>(n_cells), 0.0f);
        for (int i = 0; i < n_cells; ++i) {
            const double d = double(slp_buf[i]) - mean;
            var += d * d;
            slp_abs[static_cast<size_t>(i)] = std::fabs(slp_buf[i]);
        }
        std::sort(slp_abs.begin(), slp_abs.end());
        const size_t p95_i = std::min(slp_abs.size() - 1, size_t(std::floor(double(slp_abs.size() - 1) * 0.95)));
        out["slp_mean"] = mean;
        out["slp_std"] = std::sqrt(var / double(n_cells));
        out["slp_abs_p95"] = double(slp_abs[p95_i]);
    }
    if (!slp_delta.empty()) {
        std::sort(slp_delta.begin(), slp_delta.end());
        const size_t p95_i = std::min(slp_delta.size() - 1, size_t(std::floor(double(slp_delta.size() - 1) * 0.95)));
        out["slp_delta_p95"] = double(slp_delta[p95_i]);
    }
    }
    return out;
}

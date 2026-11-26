//     coastal sea/land pressure contrast comes from SLP; no direct season sign
//     v_sum    = W_LAT*v_base + W_GRAD*v_grad
//     dir      = normalize(v_sum)
//     spd      = wind_belt_speed_at(ny, orbital_phase, axial_tilt) * land_friction
//                * (mountain_damp / hill_damp 按 landform)
//     terrain_aware：山脉绕流 + 山脉迎风减速
//     write wind_x_arr[i], wind_y_arr[i], wind_speed_out[i]
double DCWorldExt::run_wind_field_pass(godot::Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_wind_field_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── slot id resolution moved below (after water_ids, via _phys_resolve_static cache) ──

    // ─── knobs validation ──────────────────────────────────────────────
    static const char *required_keys[] = {
        "n_cells", "hex_size", "season_phase", "terrain_aware",
        "world_bounds_pos_y", "world_bounds_size_y",
        "neighbor_indices", "slp_arr", "water_terrain_ids",
        "land_lf_mountain", "land_lf_peak", "land_lf_hill",
        nullptr,
    };
    for (int k = 0; required_keys[k] != nullptr; ++k) {
        if (!knobs.has(required_keys[k])) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_wind_field_pass: missing knob '",
                required_keys[k], "' — fallback to GDScript");
            return -1.0;
        }
    }

    const int    n_cells       = int(knobs["n_cells"]);
    const double season_phase  = double(knobs["season_phase"]);
    const bool   terrain_aware = (int(knobs["terrain_aware"]) != 0);
    const double bounds_pos_y  = double(knobs["world_bounds_pos_y"]);
    const double bounds_size_y = double(knobs["world_bounds_size_y"]);
    const int    lf_mountain   = int(knobs["land_lf_mountain"]);
    const int    lf_peak       = int(knobs["land_lf_peak"]);
    const int    lf_hill       = int(knobs["land_lf_hill"]);
    const bool   wind_belt_only = bool(knobs.has("wind_belt_only_debug") ? bool(knobs["wind_belt_only_debug"]) : false);
    float response_rate = float(knobs.has("wind_response_rate") ? double(knobs["wind_response_rate"]) : 0.25);
    if (response_rate < 0.0f) response_rate = 0.0f;
    else if (response_rate > 1.0f) response_rate = 1.0f;
    const double synoptic_amp = double(knobs.has("wind_synoptic_amp") ? double(knobs["wind_synoptic_amp"]) : 0.055);
    double synoptic_period_days = double(knobs.has("wind_synoptic_period_days") ? double(knobs["wind_synoptic_period_days"]) : 6.0);
    if (synoptic_period_days < 0.5) synoptic_period_days = 0.5;
    const double axial_tilt_deg = double(knobs.has("axial_tilt_deg") ? double(knobs["axial_tilt_deg"]) : 23.5);
    // 转向速率限幅。knob 语义是「每游戏日」，但本 pass 不是每日调用：
    // earth_like.tres 的 ocean_daily_wind_period_ticks=6 配合 daily_wind_split_passes 交替
    // slp/wind → wind 段每 24 tick 才跑一次。若不按经过天数缩放，名义 32°/日会退化成
    // 32°/24日 ≈ 1.33°/日，风向被硬性钉死（实测方向恒定度中位 0.958、中纬度反而最稳）。
    // caller 传 wind_elapsed_days（缺省 1.0 = 旧行为）。
    double wind_elapsed_days = double(knobs.has("wind_elapsed_days") ? double(knobs["wind_elapsed_days"]) : 1.0);
    if (wind_elapsed_days < 0.0) wind_elapsed_days = 0.0;
    else if (wind_elapsed_days > 60.0) wind_elapsed_days = 60.0;
    double max_turn_rad = double(knobs.has("wind_max_turn_deg_per_day") ? double(knobs["wind_max_turn_deg_per_day"]) : 32.0)
        * (3.14159265358979323846 / 180.0) * wind_elapsed_days;
    if (max_turn_rad < 0.0) max_turn_rad = 0.0;
    else if (max_turn_rad > 3.14159265358979323846) max_turn_rad = 3.14159265358979323846;
    double min_flux_for_dir_update = double(knobs.has("wind_min_flux_for_dir_update") ? double(knobs["wind_min_flux_for_dir_update"]) : 0.035);
    if (min_flux_for_dir_update < 0.0) min_flux_for_dir_update = 0.0;
    const double min_flux_len2 = min_flux_for_dir_update * min_flux_for_dir_update;
    int days_per_year = int(knobs.has("days_per_year") ? int(knobs["days_per_year"]) : 365);
    if (days_per_year < 1) days_per_year = 1;
    else if (days_per_year > 3660) days_per_year = 3660;
    double year_phase = std::fmod(season_phase, 4.0);
    if (year_phase < 0.0) year_phase += 4.0;
    const int sim_day = int(knobs.has("sim_day") ? int(knobs["sim_day"]) : int(std::floor((year_phase / 4.0) * double(days_per_year))));
    const int world_seed = int(knobs.has("world_seed") ? int(knobs["world_seed"]) : 0);
    const double wrap_origin_x = double(knobs.has("wrap_origin_x") ? double(knobs["wrap_origin_x"]) : 0.0);
    const double wrap_period_x = double(knobs.has("wrap_period_x") ? double(knobs["wrap_period_x"]) : 0.0);
    // ─── NS 化旋钮(plan/NS化气候动力学四方向深化,2026-08-04)──────────────
    // 全部默认 0/关 → 缺省时与旧诊断风逐位一致。分 Phase 独立 gate,便于 A/B。
    // 方向 A:动量自平流权重(≤0.5,读上一轮轨迹表;首跑无表退化为 own-cell)
    double momentum_advect_w = double(knobs.has("wind_momentum_advect_w") ? double(knobs["wind_momentum_advect_w"]) : 0.0);
    momentum_advect_w = wind_clamp(momentum_advect_w, 0.0, 0.5);
    // 方向 A:动量扩散日权重(6 邻居 Laplacian 松弛;dt 与格距归一在主循环前换算)
    double momentum_diffuse_w_daily = double(knobs.has("wind_momentum_diffuse_w_daily") ? double(knobs["wind_momentum_diffuse_w_daily"]) : 0.0);
    momentum_diffuse_w_daily = wind_clamp(momentum_diffuse_w_daily, 0.0, 0.5);
    // Phase 0:轨迹表构建 gate(动量自平流开启时强制构建,供下一轮消费)
    const bool traj_table_enabled = bool(knobs.has("wind_traj_table_enabled") ? bool(knobs["wind_traj_table_enabled"]) : false);
    // 回溯长度 = |flux|·traj_pos_scale·s·traj_dt_days(pos 单位;s=√(N/15000) 格距归一)
    double traj_pos_scale = double(knobs.has("wind_traj_pos_scale") ? double(knobs["wind_traj_pos_scale"]) : 0.65);
    traj_pos_scale = wind_clamp(traj_pos_scale, 0.0, 4.0);
    double traj_dt_days = double(knobs.has("wind_traj_dt_days") ? double(knobs["wind_traj_dt_days"]) : 10.0);
    traj_dt_days = wind_clamp(traj_dt_days, 0.25, 60.0);
    // 消费端总闸(weather field solve / wind_air):false 时仅构建不共享(A/B 隔离)
    _phys_wind_traj_consume_enabled = bool(knobs.has("wind_traj_weather_share") ? bool(knobs["wind_traj_weather_share"]) : true);
    // 方向 B:散度阻尼 L1 强度(格单位,硬上限 0.3;超出 push_warning 并 clamp)
    double div_damp_alpha = double(knobs.has("wind_div_damp_alpha") ? double(knobs["wind_div_damp_alpha"]) : 0.0);
    if (div_damp_alpha > 0.3) {
        static bool s_warned_div_alpha = false;
        if (!s_warned_div_alpha) {
            s_warned_div_alpha = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_wind_field_pass: wind_div_damp_alpha > 0.3 clamped "
                "(散度阻尼硬上限,防误杀天气尺度辐合)");
        }
        div_damp_alpha = 0.3;
    }
    if (div_damp_alpha < 0.0) div_damp_alpha = 0.0;
    const bool thermal_monsoon_enabled = bool(knobs.has("thermal_monsoon_enabled")
        ? bool(knobs["thermal_monsoon_enabled"]) : false);
    const double monsoon_lat_limit = wind_clamp(double(knobs.get(
        "thermal_monsoon_lat_limit", 0.45)), 0.0, 1.0);
    const double monsoon_deadband = wind_clamp(double(knobs.get(
        "thermal_monsoon_deadband", 0.015)), 0.0, 0.10);
    const double monsoon_full_contrast = std::max(
        monsoon_deadband + 0.001,
        wind_clamp(double(knobs.get("thermal_monsoon_full_contrast", 0.08)),
                   0.01, 0.25));
    const double monsoon_gain = wind_clamp(double(knobs.get(
        "thermal_monsoon_gain", 0.85)), 0.0, 1.5);
    const double monsoon_breeze_floor = wind_clamp(double(knobs.get(
        "thermal_monsoon_breeze_floor", 0.20)), 0.0, 0.5);
    if (n_cells <= 0)         { diag("n_cells <= 0"); return -1.0; }
    if (bounds_size_y <= 0.001) { diag("world_bounds_size_y <= 0.001"); return -1.0; }

    PackedInt32Array  nb_arr     = knobs["neighbor_indices"];
    PackedFloat32Array slp_arr   = knobs["slp_arr"];
    PackedByteArray   water_ids  = knobs["water_terrain_ids"];
    if (nb_arr.size()  < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (slp_arr.size() < n_cells)     { diag("slp_arr size < n_cells");              return -1.0; }
    if (water_ids.size() <= 0)        { diag("water_terrain_ids empty");             return -1.0; }

    // Slot id resolution (cached via _phys_resolve_static; FNV 指纹失效，地图 regen 自动重建)。
    _phys_resolve_static(n_cells, water_ids);
    const int sid_pos_x    = _phys_sid_pos_x;
    const int sid_pos_y    = _phys_sid_pos_y;
    const int sid_terrain  = _phys_sid_terrain;
    const int sid_landform = _phys_sid_landform;
    const int sid_wind_x   = _phys_sid_wind_x;
    const int sid_wind_y   = _phys_sid_wind_y;
    const int sid_wind_spd = _phys_sid_wind_spd;
    const int sid_temp      = _phys_sid_temp;
    if (sid_pos_x < 0 || sid_pos_y < 0 || sid_terrain < 0 || sid_landform < 0 ||
        sid_wind_x < 0 || sid_wind_y < 0 || sid_wind_spd < 0 ||
        (thermal_monsoon_enabled && sid_temp < 0)) {
        diag("missing slot id (cell_pos_x/cell_pos_y/terrain/landform/wind_x/wind_y/wind_speed/temp)");
        return -1.0;
    }

    // 256-entry is_water LUT（cached via _phys_resolve_static, 同指纹随 slot 一起重建）。
    const bool *is_water_lut = _phys_is_water_lut;

    // Item 2: cell-range 切片（默认全量，逐位等价；GDScript 游标驱动时传 start_idx/end_idx）。
    int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    int end_idx   = knobs.has("end_idx")   ? int(knobs["end_idx"])   : n_cells;
    if (start_idx < 0)       start_idx = 0;
    if (end_idx > n_cells)   end_idx = n_cells;
    if (start_idx > end_idx) start_idx = end_idx;
    const int slice_n = end_idx - start_idx;

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_terrain  = _slots.write[sid_terrain];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_wind_x   = _slots.write[sid_wind_x];
    Slot &s_wind_y   = _slots.write[sid_wind_y];
    Slot &s_wind_spd = _slots.write[sid_wind_spd];
    Slot *s_temp      = sid_temp >= 0 ? &_slots.write[sid_temp] : nullptr;
    if (s_pos_x.arr_f32.size()    != n_cells ||
        s_pos_y.arr_f32.size()    != n_cells ||
        s_terrain.arr_u8.size()   != n_cells ||
        s_landform.arr_u8.size()  != n_cells ||
        s_wind_x.arr_f32.size()   != n_cells ||
        s_wind_y.arr_f32.size()   != n_cells ||
        s_wind_spd.arr_f32.size() != n_cells ||
        (thermal_monsoon_enabled &&
         (s_temp == nullptr || s_temp->arr_f32.size() != n_cells))) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // ─── Hot pointers ──────────────────────────────────────────────────
    const float   * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float   * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    const uint8_t * const __restrict LF   = s_landform.arr_u8.ptr();
    float         * const __restrict WX   = s_wind_x.arr_f32.ptrw();
    float         * const __restrict WY   = s_wind_y.arr_f32.ptrw();
    float         * const __restrict WSP_SLOT = s_wind_spd.arr_f32.ptrw();
    const float   * const __restrict TEMP = (s_temp != nullptr &&
        s_temp->arr_f32.size() == n_cells) ? s_temp->arr_f32.ptr() : nullptr;
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict SLP  = slp_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Pass 0 / 0b: coast/sea BFS（缓存到成员，指纹失配才重建；见 _phys_ensure_wind_coast）──
    // 主循环读 coast_dist/sea_dist 等指针（指向成员缓存），不再每调用重建全图 vector。
    _phys_ensure_wind_coast(n_cells, TR, NB, is_water_lut, water_ids);
    const int8_t  *coast_dist  = _phys_wind_coast_dist.data();
    const float   *coast_sea_x = _phys_wind_coast_sea_x.data();
    const float   *coast_sea_y = _phys_wind_coast_sea_y.data();
    const int8_t  *sea_dist    = _phys_wind_sea_dist.data();
    const float   *sea_land_x  = _phys_wind_sea_land_x.data();
    const float   *sea_land_y  = _phys_wind_sea_land_y.data();
    const int32_t *coast_sea_anchor = _phys_wind_coast_sea_anchor.data();
    const int32_t *sea_land_anchor = _phys_wind_sea_land_anchor.data();
    if (_phys_monsoon_thermal.size() != static_cast<size_t>(n_cells)) {
        _phys_monsoon_thermal.assign(static_cast<size_t>(n_cells), 0.0f);
    }

    // ─── 主循环 ────────────────────────────────────────────────────────
    // wind_speed_out 写入 knobs；caller 拿来同步到 cell.wind_speed
    PackedFloat32Array wind_speed_out;
    wind_speed_out.resize(n_cells);
    float * const __restrict WSPD = wind_speed_out.ptrw();
    std::vector<float> wind_delta(static_cast<size_t>(n_cells), 0.0f);
    std::vector<float> wind_dir_delta(static_cast<size_t>(n_cells), 0.0f);
    int wind_flip_count = 0;
    // perf (2A): wind 逐 cell 独立（邻居只读 SLP/LF/TR，自身读写 WX/WY/WSP_SLOT/WSPD/
    // wind_delta/wind_dir_delta[i]，唯一 cross-cell 共享是 flip 计数标量）→ thread-local
    // emit + 串行 reduce 并行；flip 为整数加法、task 顺序无关 → bit-equal。
    struct WindFlipEmit {
        int flip = 0;
        int monsoon_eligible = 0;
        int monsoon_onshore = 0;
        int monsoon_offshore = 0;
        float monsoon_abs_max = 0.0f;
        void merge_into(WindFlipEmit &dst) const {
            dst.flip += flip;
            dst.monsoon_eligible += monsoon_eligible;
            dst.monsoon_onshore += monsoon_onshore;
            dst.monsoon_offshore += monsoon_offshore;
            if (monsoon_abs_max > dst.monsoon_abs_max) {
                dst.monsoon_abs_max = monsoon_abs_max;
            }
        }
    };
    WindFlipEmit wind_flip_emit;

    // 纬度权威：cell_lat_norm slot（见 phys_make_lat_norm 注释）。world_bounds_* 不再参与
    // 纬度归一化，仅保留 knob 契约校验。
    const PhysLatNorm LATN = phys_make_lat_norm(_phys_lat_norm_ptr(n_cells), POSY, n_cells);
    (void)bounds_pos_y;
    (void)bounds_size_y;
    const bool   ta = terrain_aware;
    double bounds_pos_x = double(POSX[0]);
    double bounds_max_x = bounds_pos_x;
    for (int i = 1; i < n_cells; ++i) {
        const double px_i = double(POSX[i]);
        if (px_i < bounds_pos_x) bounds_pos_x = px_i;
        else if (px_i > bounds_max_x) bounds_max_x = px_i;
    }
    const double inv_bounds_w = 1.0 / std::max(0.001, bounds_max_x - bounds_pos_x);
    const bool has_wrap_domain = wrap_period_x > 0.001;
    {
        static bool s_warned_wind_wrap = false;
        physical_warn_wrap_units("wind_field", wrap_period_x, bounds_max_x - bounds_pos_x,
                                 s_warned_wind_wrap);
    }
    const uint32_t seed_bits = static_cast<uint32_t>(world_seed);

    // ─── NS 化 Phase 1:旧通量快照 + 有效权重换算(动量关闭时零成本零数值差)──
    // 快照是并行安全的唯一前提:主循环内邻居的旧通量必须读快照而非 slot(slot 在
    // 并行写回中)。内存 ≈0.9MB@110k,内存换耗时(与 coast BFS 缓存同策)。
    // 切片兼容:快照驻留成员,只在首切片(start_idx==0)或换图(size 失配)重建;
    // 后续切片复用 → 切片执行与全量执行逐位一致(每切片各拍会读到前序切片已写回
    // 的新风,污染"旧值"语义)。
    const bool momentum_active = (momentum_advect_w > 0.0 || momentum_diffuse_w_daily > 0.0);
    if (momentum_active
            && (start_idx == 0 || int(_phys_wind_snap_fx.size()) != n_cells)) {
        _phys_wind_snap_fx.resize(static_cast<size_t>(n_cells));
        _phys_wind_snap_fy.resize(static_cast<size_t>(n_cells));
        for (int i = 0; i < n_cells; ++i) {
            _phys_wind_snap_fx[static_cast<size_t>(i)] = WX[i] * WSP_SLOT[i];
            _phys_wind_snap_fy[static_cast<size_t>(i)] = WY[i] * WSP_SLOT[i];
        }
    }
    const float * const __restrict SNAP_FX = momentum_active ? _phys_wind_snap_fx.data() : nullptr;
    const float * const __restrict SNAP_FY = momentum_active ? _phys_wind_snap_fy.data() : nullptr;
    // 扩散权重:日权重按 wind_elapsed_days 换算(沿用 max_turn_rad 的 rate 语义),
    // 再乘 s² 格距归一(w=ν·dt/h²,h∝1/√N);上限 0.5 = 6 邻居显式扩散无条件稳定域。
    const double grid_s = std::sqrt(double(n_cells) / 15000.0);
    double diffuse_w = 0.0;
    if (momentum_diffuse_w_daily > 0.0) {
        diffuse_w = 1.0 - simulation_math::pow(1.0 - momentum_diffuse_w_daily, wind_elapsed_days);
        diffuse_w *= grid_s * grid_s;
        if (diffuse_w > 0.5) diffuse_w = 0.5;
    }
    // 自平流读上一轮轨迹表(几何冻结系数,滞后一次 wind 更新);首跑无表 → 跳过。
    const int32_t * const __restrict TRAJ_IDX =
        (momentum_advect_w > 0.0 && _phys_wind_traj_valid
         && int(_phys_wind_traj_idx.size()) == n_cells * 3
         && pk_wind_state_fp(n_cells, WX, WY, WSP_SLOT) == _phys_wind_traj_fp)
            ? _phys_wind_traj_idx.data() : nullptr;
    const float * const __restrict TRAJ_W = (TRAJ_IDX != nullptr) ? _phys_wind_traj_w.data() : nullptr;
    std::vector<float> momentum_delta;
    if (momentum_active) momentum_delta.assign(static_cast<size_t>(n_cells), 0.0f);

    // B8 P2：主循环体已搬到 pk_async_physics::wind_field_range（worker 与生产
    // 共用同一份）。这里只负责组装 POD 与把分段统计合并回 WindFlipEmit。
    pk_async_physics::WindFieldKnobs wind_k;
    wind_k.season_phase = season_phase;
    wind_k.axial_tilt_deg = axial_tilt_deg;
    wind_k.terrain_aware = terrain_aware;
    wind_k.wind_belt_only = wind_belt_only;
    wind_k.response_rate = double(response_rate);
    wind_k.synoptic_amp = synoptic_amp;
    wind_k.synoptic_period_days = synoptic_period_days;
    wind_k.max_turn_rad = max_turn_rad;
    wind_k.min_flux_len2 = min_flux_len2;
    wind_k.sim_day = sim_day;
    wind_k.world_seed = world_seed;
    wind_k.bounds_pos_x = bounds_pos_x;
    wind_k.inv_bounds_w = inv_bounds_w;
    wind_k.has_wrap_domain = has_wrap_domain;
    wind_k.wrap_origin_x = wrap_origin_x;
    wind_k.wrap_period_x = wrap_period_x;
    wind_k.lf_mountain = lf_mountain;
    wind_k.lf_peak = lf_peak;
    wind_k.lf_hill = lf_hill;
    wind_k.thermal_monsoon_enabled = thermal_monsoon_enabled;
    wind_k.monsoon_lat_limit = monsoon_lat_limit;
    wind_k.monsoon_deadband = monsoon_deadband;
    wind_k.monsoon_full_contrast = monsoon_full_contrast;
    wind_k.monsoon_gain = monsoon_gain;
    wind_k.monsoon_breeze_floor = monsoon_breeze_floor;
    wind_k.momentum_active = momentum_active;
    wind_k.momentum_advect_w = momentum_advect_w;
    wind_k.diffuse_w = diffuse_w;
    wind_k.traj_idx = TRAJ_IDX;
    wind_k.traj_w = TRAJ_W;
    wind_k.snap_fx = SNAP_FX;
    wind_k.snap_fy = SNAP_FY;
    pk_async_physics::WindFieldLanes wind_l;
    wind_l.lat_norm = LATN.lat;
    wind_l.pos_y = LATN.posy;
    wind_l.lat_origin = LATN.origin;
    wind_l.lat_inv_span = LATN.inv_span;
    wind_l.pos_x = POSX;
    wind_l.slp = SLP;
    wind_l.neighbors = NB;
    wind_l.terrain = TR;
    wind_l.landform = LF;
    wind_l.is_water_lut = is_water_lut;
    wind_l.coast_dist = _phys_wind_coast_dist.data();
    wind_l.coast_sea_x = _phys_wind_coast_sea_x.data();
    wind_l.coast_sea_y = _phys_wind_coast_sea_y.data();
    wind_l.coast_sea_anchor = _phys_wind_coast_sea_anchor.data();
    wind_l.sea_dist = _phys_wind_sea_dist.data();
    wind_l.sea_land_x = _phys_wind_sea_land_x.data();
    wind_l.sea_land_y = _phys_wind_sea_land_y.data();
    wind_l.sea_land_anchor = _phys_wind_sea_land_anchor.data();
    wind_l.temp = TEMP;
    wind_l.wind_x = WX;
    wind_l.wind_y = WY;
    wind_l.wind_speed = WSP_SLOT;
    wind_l.wind_speed_out = WSPD;
    wind_l.wind_delta = wind_delta.data();
    wind_l.wind_dir_delta = wind_dir_delta.data();
    wind_l.momentum_delta = momentum_delta.empty() ? nullptr : momentum_delta.data();
    wind_l.monsoon_thermal = _phys_monsoon_thermal.data();
    pk::parallel_for_range_with_emit<WindFlipEmit>(
        "pk_wind_field", slice_n, wind_flip_emit,
        [&](int __wrb, int __wre, WindFlipEmit &__we) {
            pk_async_physics::WindFieldStats wind_stats;
            pk_async_physics::wind_field_range(
                n_cells, start_idx + __wrb, start_idx + __wre,
                wind_k, wind_l, wind_stats);
            // 逐字段合并（emit 类型归生产所有，内核只给统计 POD）。
            __we.flip += wind_stats.flip;
            __we.monsoon_eligible += wind_stats.monsoon_eligible;
            __we.monsoon_onshore += wind_stats.monsoon_onshore;
            __we.monsoon_offshore += wind_stats.monsoon_offshore;
            if (wind_stats.monsoon_abs_max > __we.monsoon_abs_max) {
                __we.monsoon_abs_max = wind_stats.monsoon_abs_max;
            }
        }); // pk_wind_field parallel_for_range_with_emit
    wind_flip_count = wind_flip_emit.flip;
    if (start_idx == 0) {
        _monsoon_eligible_cells = 0;
        _monsoon_onshore_cells = 0;
        _monsoon_offshore_cells = 0;
        _monsoon_contrast_abs_max = 0.0f;
    }
    _monsoon_eligible_cells += wind_flip_emit.monsoon_eligible;
    _monsoon_onshore_cells += wind_flip_emit.monsoon_onshore;
    _monsoon_offshore_cells += wind_flip_emit.monsoon_offshore;
    if (wind_flip_emit.monsoon_abs_max > _monsoon_contrast_abs_max) {
        _monsoon_contrast_abs_max = wind_flip_emit.monsoon_abs_max;
    }

    // ─── NS 化 Phase 3:散度阻尼 L1(仅末切片/全量,对完整新风场执行)─────────
    // div = ∇·V 与 grad(div) 用与 (b) 段相同的 (1/3)Σ_d Δ·NB_DIR 离散(内洽):
    // V += α_eff·∇div —— 符号取 +:∂E/∂t = -α∫|∇div|² ≤ 0(E=½∫div²),
    // 即 div 的扩散(阻尼);取 - 则是反扩散,放大散度模态(2026-08-04 DIV-only
    // A/B 实测证实:div p95 +10%、风速 +3.8%,已据此翻转符号)。
    // α 按 s² 格距归一、硬上限 0.3 → 谱选择性压制网格级散度噪声,
    // 几乎不触行星尺度辐合(NWP 标准散度阻尼)。两趟只读/写分离 sweep,bit-equal 并行。
    // 不复用 turn-limit(α 小,增量远低于 32°/日帽);div_damp_alpha==0 时零成本。
    double div_damp_applied = 0.0;
    if (div_damp_alpha > 0.0 && end_idx == n_cells && n_cells > 0) {
        double a_eff = div_damp_alpha * grid_s * grid_s;
        if (a_eff > 0.3) a_eff = 0.3;
        std::vector<float> div_f(static_cast<size_t>(n_cells), 0.0f);
        float * const __restrict DIV = div_f.data();
        pk::parallel_for_range("pk_wind_div1", n_cells, [&](int rb, int re) {
            pk_async_physics::wind_divergence_range(n_cells, rb, re, NB, WX, WY, WSP_SLOT, DIV);
        });
        pk::parallel_for_range("pk_wind_div2", n_cells, [&](int rb, int re) {
            pk_async_physics::wind_divergence_apply_range(n_cells, rb, re, NB, DIV, a_eff, WX, WY, WSP_SLOT);
        });
        div_damp_applied = a_eff;
    }

    // ─── NS 化 Phase 0/2:回溯轨迹表(消费端 weather/wind_air 指纹校验共享)────
    // 动量自平流开启时强制构建(下一轮 wind pass 读本表);只在末切片对完整新风场
    // 构建,保证表与发布风严格一致。构建于 div 阻尼之后 → 表反映最终风。
    if ((traj_table_enabled || momentum_active) && end_idx == n_cells && n_cells > 0) {
        _phys_build_wind_traj(n_cells, POSX, POSY, NB, WX, WY, WSP_SLOT,
                              wrap_period_x, traj_pos_scale, traj_dt_days);
        knobs["wind_traj_gen"] = int(_phys_wind_traj_gen);
    }

    // Item 2: 重建完整 wind_speed_out（GDScript 整图写回 cell.wind_speed；切片外 cell
    // 取 slot 上一 tick 值，切片内 cell 取本 tick 新值 → 整图一致、无 0 污染）。
    {
        const float *src = s_wind_spd.arr_f32.ptr();
        float *dst = wind_speed_out.ptrw();
        for (int i = 0; i < n_cells; ++i) dst[i] = src[i];
    }

    // §11.2 flush: push CoW-detached cell_wind_x/y back to MapData
    _flush_slot_to_map(sid_wind_x);
    _flush_slot_to_map(sid_wind_y);
    _flush_slot_to_map(sid_wind_spd);

    // 输出回填到 knobs（让 GDScript caller 拿到 wind_speed_out 写每 cell.wind_speed）
    knobs["wind_speed_out"] = wind_speed_out;
    if (!wind_delta.empty()) {
        std::sort(wind_delta.begin(), wind_delta.end());
        const size_t p95_i = std::min(wind_delta.size() - 1, size_t(std::floor(double(wind_delta.size() - 1) * 0.95)));
        knobs["wind_delta_p95"] = double(wind_delta[p95_i]);
    }
    if (!wind_dir_delta.empty()) {
        std::sort(wind_dir_delta.begin(), wind_dir_delta.end());
        const size_t p95_i = std::min(wind_dir_delta.size() - 1, size_t(std::floor(double(wind_dir_delta.size() - 1) * 0.95)));
        knobs["wind_dir_delta_p95"] = double(wind_dir_delta[p95_i]);
        knobs["wind_dir_flip_count"] = wind_flip_count;
    }
    // NS 化诊断键(进现有 slow-dump 链;momentum/div_damp 关闭时恒 0,键始终存在)。
    if (!momentum_delta.empty()) {
        std::sort(momentum_delta.begin(), momentum_delta.end());
        const size_t p95_i = std::min(momentum_delta.size() - 1, size_t(std::floor(double(momentum_delta.size() - 1) * 0.95)));
        knobs["momentum_advect_diffuse_delta_p95"] = double(momentum_delta[p95_i]);
    }
    knobs["momentum_advect_w_eff"] = momentum_advect_w;
    knobs["momentum_diffuse_w_eff"] = diffuse_w;
    knobs["div_damp_alpha_eff"] = div_damp_applied;
    knobs["wind_traj_stale_count"] = _phys_wind_traj_stale_count;
    knobs["monsoon_eligible_cells"] = _monsoon_eligible_cells;
    knobs["monsoon_onshore_cells"] = _monsoon_onshore_cells;
    knobs["monsoon_offshore_cells"] = _monsoon_offshore_cells;
    knobs["monsoon_contrast_abs_max"] = _monsoon_contrast_abs_max;
    knobs["monsoon_coast_cache_hit"] = _phys_wind_coast_last_hit;
    knobs["monsoon_coast_cache_build_ms"] = _phys_wind_coast_build_ms;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

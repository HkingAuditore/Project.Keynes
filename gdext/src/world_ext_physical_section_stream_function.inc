// plan/dots-slp-psi-cpp — PSI ocean stream-function solver (stage 3+4+5)
// ═══════════════════════════════════════════════════════════════════════════
//
// Fused init + SOR iters + finalize, 1:1 mirror of GDScript:
//   PhysicalCirculationSolver.init_psi_solver  (stage 3 PSI_INIT)
//   PhysicalCirculationSolver.step_psi_solver  (stage 4 PSI_ITERS, n_iters)
//   PhysicalCirculationSolver.psi_to_ocean_current + commit_psi_to_cells
//                                              (stage 5 PSI_FINALIZE)
//
// Water-cell ordering MUST match GDScript: enumerate all cells in cell-index
// ascending order, push back to water_to_cell[] when terrain is water. This
// matches the GDScript loop "for cell in cells" since cells are indexed
// linearly. Mismatch here would cause SOR to converge to a different shape.
//
// Algorithmic choices kept identical to GDScript:
//   - 6-neighbor curl tau (z component): a.x * b.y - a.y * b.x
//   - PSI source = source_scale * curl_tau / max(beta_abs, beta_floor)
//   - r_factor   = r_base / max(beta_abs, beta_floor)
//   - SOR sweep: in-place Gauss-Seidel; psi_e = nb[d=0], psi_w = nb[d=3];
//                advection term r_factor * (psi_e - psi_w) * 0.5
//                target  = sum_nb / 6 - adv + source
//                psi[k]  = (1 - omega) * old + omega * target
//   - Finalize : grad_psi = (1/3) * sum_d (psi[nb] - psi[self]) * NB_DIR_d
//                cur = (-grad.y, grad.x) * ocean_current_scale
//                if |ls| > UPWELLING_HIGHLAT_ABS && temp_rel < cold_sink_temp:
//                    cur.y += sign(ls) * sin(|ls| * pi) * thermohaline_weight
//                cur.x = clamp(cur.x, -1, 1); cur.y = clamp(cur.y, -1, 1);
//
// NEIGHBOR_DIRS (match physical_circulation_solver.gd::NEIGHBOR_DIRS exactly,
// which is the order the GDScript map_data stores _neighbor_indices in,
// i.e. HexUtils.CUBE_DIRECTIONS: E, NE, NW, W, SW, SE; screen +y = south):
//   d=0 ( sqrt3,    0  )  east
//   d=1 ( sqrt3/2, -1.5)  north-east
//   d=2 (-sqrt3/2, -1.5)  north-west
//   d=3 (-sqrt3,    0  )  west
//   d=4 (-sqrt3/2, +1.5)  south-west
//   d=5 ( sqrt3/2, +1.5)  south-east
godot::Dictionary DCWorldExt::run_psi_solver_pass(godot::Dictionary knobs) {
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

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_psi_solver_pass: ", why,
            " — fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not _bound");

    static const char *required_keys[] = {
        "n_cells", "hex_size",
        "world_bounds_pos_y", "world_bounds_size_y",
        "neighbor_indices", "water_terrain_ids",
        "wind_x_arr", "wind_y_arr", "wind_speed_arr",
        nullptr,
    };
    for (int k = 0; required_keys[k] != nullptr; ++k) {
        if (!knobs.has(required_keys[k])) {
            String s = String("missing knob '") + String(required_keys[k]) + String("'");
            return fail(s.utf8().get_data());
        }
    }

    const int    n_cells       = int(knobs["n_cells"]);
    const double bounds_pos_y  = double(knobs["world_bounds_pos_y"]);
    const double bounds_size_y = double(knobs["world_bounds_size_y"]);
    if (n_cells <= 0)            return fail("n_cells <= 0");
    if (bounds_size_y <= 0.001)  return fail("world_bounds_size_y <= 0.001");

    // Numeric constants (defaults must mirror physical_circulation_solver.gd).
    const int   PSI_TOTAL_ITERS = int(knobs.has("psi_total_iters")     ? int(knobs["psi_total_iters"])     : 40);
    const float PSI_OMEGA       = float(knobs.has("psi_sor_omega")     ? double(knobs["psi_sor_omega"])    : 1.40);
    const float PSI_R_BASE      = float(knobs.has("psi_r_base")        ? double(knobs["psi_r_base"])       : 0.18);
    const float PSI_BETA_FLOOR  = float(knobs.has("psi_beta_floor")    ? double(knobs["psi_beta_floor"])   : 0.05);
    const float PSI_SRC_SCALE   = float(knobs.has("psi_source_scale")  ? double(knobs["psi_source_scale"]) : 0.06);
    const float OC_SCALE        = float(knobs.has("ocean_current_scale")    ? double(knobs["ocean_current_scale"])    : 0.13);
    float OC_MAX_MAG            = float(knobs.has("ocean_current_max_magnitude") ? double(knobs["ocean_current_max_magnitude"]) : 0.65);
    if (OC_MAX_MAG < 0.01f) OC_MAX_MAG = 0.01f;
    else if (OC_MAX_MAG > 1.4142136f) OC_MAX_MAG = 1.4142136f;
    const float TH_WEIGHT       = float(knobs.has("thermohaline_weight")    ? double(knobs["thermohaline_weight"])    : 0.12);
    const float UPW_HIGHLAT_ABS = float(knobs.has("upwelling_highlat_abs")  ? double(knobs["upwelling_highlat_abs"])  : 0.75);
    const float COLD_SINK_TEMP  = float(knobs.has("cold_sink_temp")         ? double(knobs["cold_sink_temp"])         : -0.05);
    float response_rate = float(knobs.has("ocean_current_response_rate") ? double(knobs["ocean_current_response_rate"]) : 1.0);
    if (response_rate < 0.0f) response_rate = 0.0f;
    else if (response_rate > 1.0f) response_rate = 1.0f;
    const float THERMAL_CURRENT_WEIGHT = float(knobs.has("ocean_thermal_current_weight") ? double(knobs["ocean_thermal_current_weight"]) : TH_WEIGHT);
    const float DENSITY_COLD_WEIGHT = float(knobs.has("ocean_density_cold_weight") ? double(knobs["ocean_density_cold_weight"]) : 0.22);
    const float DENSITY_ICE_WEIGHT = float(knobs.has("ocean_density_ice_weight") ? double(knobs["ocean_density_ice_weight"]) : 0.12);
    // ─── NS 化 Phase 4:洋流深度耦合 + 地形转向(默认 0 → 旧行为逐位不变)─────
    // 风应力旋度源项按深度衰减:陆架上旋度效率降低(浅水底摩擦耗散)。
    // depth = sea_level - elev(归一化单位),depth_ref 参考水深,damp=0 关闭。
    float DEPTH_CURL_DAMP = float(knobs.has("ocean_depth_curl_damp") ? double(knobs["ocean_depth_curl_damp"]) : 0.0);
    if (DEPTH_CURL_DAMP < 0.0f) DEPTH_CURL_DAMP = 0.0f;
    else if (DEPTH_CURL_DAMP > 1.0f) DEPTH_CURL_DAMP = 1.0f;
    float SEA_LEVEL = float(knobs.has("sea_level") ? double(knobs["sea_level"]) : 0.42);
    if (SEA_LEVEL < 0.05f) SEA_LEVEL = 0.05f;
    else if (SEA_LEVEL > 0.95f) SEA_LEVEL = 0.95f;
    float DEPTH_REF = float(knobs.has("ocean_depth_ref") ? double(knobs["ocean_depth_ref"]) : 0.12);
    if (DEPTH_REF < 0.01f) DEPTH_REF = 0.01f;
    // current-from-PSI 步加地形等深线偏转分量 k_topo·(∇h × k)(洋流被等深线引导,
    // 陆架/海山绕流);k_topo 默认 0 关闭。
    float TOPO_STEER_W = float(knobs.has("ocean_topo_steer_w") ? double(knobs["ocean_topo_steer_w"]) : 0.0);
    if (TOPO_STEER_W < 0.0f) TOPO_STEER_W = 0.0f;
    else if (TOPO_STEER_W > 0.5f) TOPO_STEER_W = 0.5f;
    // warm-start（plan/psi-warm-start 2026-06-17）：SOR 用上一轮发布在 cell_ocean_psi
    // slot 的 ψ 作初值，而非每轮从 0 冷启动。洋流流函数日间变化极小，warm-start 后
    // 残差很小，少量迭代即可收敛（配合 psi_total_iters 下调）。默认 true；A/B 对照
    // 时传 psi_warm_start=false 退回冷启动。
    const bool PSI_WARM_START = bool(knobs.has("psi_warm_start") ? bool(knobs["psi_warm_start"]) : true);
    const String PSI_EARLY_EXIT_MODE = String(knobs.has("psi_early_exit_mode")
        ? String(knobs["psi_early_exit_mode"])
        : String("perf"));
    bool psi_early_exit_enabled = false;
    int psi_min_iters = PSI_TOTAL_ITERS;
    int psi_check_every = 2;
    float psi_residual_epsilon = 0.0f;
    if (PSI_EARLY_EXIT_MODE == String("balanced")) {
        psi_early_exit_enabled = true;
        psi_min_iters = 8;
        psi_residual_epsilon = 0.00035f;
    } else if (PSI_EARLY_EXIT_MODE == String("perf")) {
        psi_early_exit_enabled = true;
        psi_min_iters = 6;
        psi_residual_epsilon = 0.00075f;
    }
    if (!PSI_WARM_START && psi_early_exit_enabled) {
        psi_min_iters += 4;
    }
    if (psi_min_iters < 1) psi_min_iters = 1;
    if (psi_min_iters > PSI_TOTAL_ITERS) psi_min_iters = PSI_TOTAL_ITERS;
    if (psi_check_every < 1) psi_check_every = 1;

    PackedInt32Array nb_arr     = knobs["neighbor_indices"];
    PackedByteArray  water_ids  = knobs["water_terrain_ids"];
    PackedFloat32Array wind_x   = knobs["wind_x_arr"];
    PackedFloat32Array wind_y   = knobs["wind_y_arr"];
    PackedFloat32Array wind_spd = knobs["wind_speed_arr"];
    if (nb_arr.size()   < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");
    if (water_ids.size() <= 0)          return fail("water_terrain_ids empty");
    if (wind_x.size()   < n_cells)      return fail("wind_x_arr size < n_cells");
    if (wind_y.size()   < n_cells)      return fail("wind_y_arr size < n_cells");
    if (wind_spd.size() < n_cells)      return fail("wind_speed_arr size < n_cells");

    _phys_resolve_static(n_cells, water_ids);
    const int sid_pos_y   = _phys_sid_pos_y;
    const int sid_terrain = _phys_sid_terrain;
    const int sid_temp    = _phys_sid_temp;
    const int sid_temp_an = _phys_sid_temp_an;
    const int sid_ice     = _phys_sid_ice;
    const int sid_ocx     = _phys_sid_ocx;
    const int sid_ocy     = _phys_sid_ocy;
    if (sid_pos_y < 0 || sid_terrain < 0) {
        return fail("missing slot id (cell_pos_y/cell_terrain)");
    }
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_terrain = _slots.write[sid_terrain];
    if (s_pos_y.arr_f32.size()  != n_cells ||
        s_terrain.arr_u8.size() != n_cells) {
        return fail("slot array size mismatch (re-bind needed?)");
    }

    const bool *is_water_lut = _phys_is_water_lut;

    const float   * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict WX   = wind_x.ptr();
    const float   * const __restrict WY   = wind_y.ptr();
    const float   * const __restrict WSP  = wind_spd.ptr();
    const float *TEMP = nullptr;
    const float *TEMP_AN = nullptr;
    const float *ICE = nullptr;
    const float *OLD_OCX = nullptr;
    const float *OLD_OCY = nullptr;
    if (sid_temp >= 0 && _slots.write[sid_temp].arr_f32.size() == n_cells) {
        TEMP = _slots.write[sid_temp].arr_f32.ptr();
    }
    if (sid_temp_an >= 0 && _slots.write[sid_temp_an].arr_f32.size() == n_cells) {
        TEMP_AN = _slots.write[sid_temp_an].arr_f32.ptr();
    }
    if (sid_ice >= 0 && _slots.write[sid_ice].arr_f32.size() == n_cells) {
        ICE = _slots.write[sid_ice].arr_f32.ptr();
    }
    if (sid_ocx >= 0 && _slots.write[sid_ocx].arr_f32.size() == n_cells) {
        OLD_OCX = _slots.write[sid_ocx].arr_f32.ptr();
    }
    if (sid_ocy >= 0 && _slots.write[sid_ocy].arr_f32.size() == n_cells) {
        OLD_OCY = _slots.write[sid_ocy].arr_f32.ptr();
    }
    // NS 化 Phase 4:elevation slot(深度耦合/地形转向的数据源);缺失时两项自动失效,
    // 与 knob=0 等价(旧行为),由 out["ocean_topo_active"] 上报实际状态。
    const int sid_elev = _phys_sid_elev;
    const float *ELEV = nullptr;
    if (sid_elev >= 0 && _slots.write[sid_elev].arr_f32.size() == n_cells) {
        ELEV = _slots.write[sid_elev].arr_f32.ptr();
    }
    // warm-start：上一轮 ψ 已发布到 cell_ocean_psi slot；读它作 SOR 初值。
    // 冷启动 / slot 不可用 / 显式关闭时为 null → 退回 0 初值。
    const int sid_psi_prev = _phys_sid_psi_prev;
    const float *PSI_PREV = nullptr;
    if (PSI_WARM_START && sid_psi_prev >= 0 && _slots.write[sid_psi_prev].arr_f32.size() == n_cells) {
        PSI_PREV = _slots.write[sid_psi_prev].arr_f32.ptr();
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── PSI init ─────────────────────────────────────────────────────────
    // Build water_to_cell[] in cell-index ascending order; cell_to_water[] is
    // the inverse map (-1 for land cells); nb_w[] maps each water cell's 6
    // neighbors to water-domain indices (-1 = land/out-of-domain).
    // perf (Item 6, 2026-07-05): 这三者纯由水掩膜(TR+water_ids)与邻接(NB)决定，与风/温
    // 无关，对静态地图逐 tick 恒等。海冰是独立 slot，不改 terrain id → 掩膜生成后静态。
    // 缓存进成员，自校验指纹 = FNV-1a(n_cells, water_ids, 全 TR, 全 NB)；命中即逐位复用
    // (nb_w/water_to_cell/cell_to_water bit-identical)，跳过重建与三次堆分配。地形/邻接
    // 任何变化指纹即失配、自动重建 → 无需外部失效钩子（消除最易漏的失效点）。
    {
        uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
        auto mix = [&fp](uint32_t bits) {
            fp ^= uint64_t(bits);
            fp *= 1099511628211ull; // FNV-1a prime
        };
        mix(uint32_t(n_cells));
        for (int k = 0; k < water_ids.size(); ++k) {
            mix(uint32_t(int(water_ids[k])));
        }
        for (int i = 0; i < n_cells; ++i) {
            mix(uint32_t(TR[i]));
        }
        for (int i = 0; i < n_cells * 6; ++i) {
            mix(uint32_t(NB[i]));
        }
        if (!(_psi_topo_valid && _psi_topo_fp == fp &&
              int(_psi_cell_to_water.size()) == n_cells)) {
            _psi_cell_to_water.assign(static_cast<size_t>(n_cells), -1);
            _psi_water_to_cell.assign(static_cast<size_t>(n_cells), 0);
            _psi_nb_w.assign(static_cast<size_t>(n_cells) * 6, -1);
            // B8 P2：CSR 拓扑构建已抽成共享纯内核（worker 走同一份）。
            _psi_topo_n_water = pk_async_physics::psi_topology_build_pure(
                n_cells, TR, NB, is_water_lut,
                _psi_cell_to_water.data(), _psi_water_to_cell.data(),
                _psi_nb_w.data());
            _psi_water_to_cell.resize(static_cast<size_t>(_psi_topo_n_water));
            _psi_topo_fp = fp;
            _psi_topo_valid = true;
        }
    }
    const std::vector<int> &cell_to_water = _psi_cell_to_water;
    const std::vector<int> &water_to_cell = _psi_water_to_cell;
    const std::vector<int> &nb_w = _psi_nb_w;
    const int n_water = _psi_topo_n_water;

    // Per-water-cell: nb_idx (to water-domain index, -1 = land/out-of-domain),
    // wind stress (= wind_vector * wind_speed), curl_tau, beta_abs, r_factor,
    // source, psi.
    // 注：nb_w 已在上方拓扑缓存块构建（member 别名），此处不再声明。
    std::vector<float> tau_x(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> tau_y(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> ny_w(static_cast<size_t>(n_water), 0.5f);
    std::vector<float> ls_w(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> curl(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> beta_abs(static_cast<size_t>(n_water), PSI_BETA_FLOOR);
    std::vector<float> r_factor(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> source(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> psi(static_cast<size_t>(n_water), 0.0f);
    // warm-start 与 NEIGHBOR_DIRS 都已在共享内核里（psi_solve_pure 自带清零 +
    // prev_psi 播种与同源的邻居方向表），生产侧不再重复。

    // B8 P2：tau/curl/源项 → SOR → finalize 三段已抽到 pk_async_physics::psi_solve_pure
    // （worker 走同一份）。生产侧只保留拓扑缓存、scratch 与诊断输出。
    // 纬度权威：cell_lat_norm slot（见 phys_make_lat_norm）。
    const PhysLatNorm LATN = phys_make_lat_norm(_phys_lat_norm_ptr(n_cells), POSY, n_cells);
    (void)bounds_pos_y;
    (void)bounds_size_y;

    // ─── PSI finalize + SOR（共享内核）────────────────────────────────────
    PackedFloat32Array curl_out, psi_out, ocx_out, ocy_out;
    curl_out.resize(n_cells);
    psi_out.resize(n_cells);
    ocx_out.resize(n_cells);
    ocy_out.resize(n_cells);
    std::vector<float> ocean_delta(static_cast<size_t>(n_cells), 0.0f);
    std::vector<float> ocean_preclamp_mag(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> thermal_current_mag(static_cast<size_t>(n_water), 0.0f);

    pk_async_physics::PsiSolveKnobs psi_k;
    psi_k.total_iters = PSI_TOTAL_ITERS;
    psi_k.omega = PSI_OMEGA;
    psi_k.r_base = PSI_R_BASE;
    psi_k.beta_floor = PSI_BETA_FLOOR;
    psi_k.source_scale = PSI_SRC_SCALE;
    psi_k.oc_scale = OC_SCALE;
    psi_k.oc_max_mag = OC_MAX_MAG;
    psi_k.thermohaline_weight = TH_WEIGHT;
    psi_k.upwelling_highlat_abs = UPW_HIGHLAT_ABS;
    psi_k.cold_sink_temp = COLD_SINK_TEMP;
    psi_k.response_rate = response_rate;
    psi_k.thermal_current_weight = THERMAL_CURRENT_WEIGHT;
    psi_k.density_cold_weight = DENSITY_COLD_WEIGHT;
    psi_k.density_ice_weight = DENSITY_ICE_WEIGHT;
    psi_k.depth_curl_damp = DEPTH_CURL_DAMP;
    psi_k.sea_level = SEA_LEVEL;
    psi_k.depth_ref = DEPTH_REF;
    psi_k.topo_steer_w = TOPO_STEER_W;
    psi_k.early_exit = psi_early_exit_enabled;
    psi_k.min_iters = psi_min_iters;
    psi_k.check_every = psi_check_every;
    psi_k.residual_epsilon = psi_residual_epsilon;

    pk_async_physics::PsiSolveLanes psi_l;
    psi_l.n_cells = n_cells;
    psi_l.n_water = n_water;
    psi_l.neighbors = NB;
    psi_l.terrain = TR;
    psi_l.is_water_lut = is_water_lut;
    psi_l.cell_to_water = cell_to_water.data();
    psi_l.water_to_cell = water_to_cell.data();
    psi_l.nb_w = nb_w.data();
    psi_l.wind_x = WX;
    psi_l.wind_y = WY;
    psi_l.wind_speed = WSP;
    psi_l.lat_norm = LATN.lat;
    psi_l.pos_y = LATN.posy;
    psi_l.lat_origin = LATN.origin;
    psi_l.lat_inv_span = LATN.inv_span;
    psi_l.temp = TEMP;
    psi_l.temp_anomaly = TEMP_AN;
    psi_l.ice = ICE;
    psi_l.elevation = ELEV;
    psi_l.prev_psi = PSI_PREV;
    psi_l.old_ocean_x = OLD_OCX;
    psi_l.old_ocean_y = OLD_OCY;
    psi_l.out_curl = curl_out.ptrw();
    psi_l.out_psi = psi_out.ptrw();
    psi_l.out_ocean_x = ocx_out.ptrw();
    psi_l.out_ocean_y = ocy_out.ptrw();
    psi_l.ocean_delta = ocean_delta.data();
    psi_l.out_preclamp_mag = ocean_preclamp_mag.data();
    psi_l.out_thermal_mag = thermal_current_mag.data();

    pk_async_physics::PsiSolveScratch psi_s;
    psi_s.tau_x = tau_x.data();
    psi_s.tau_y = tau_y.data();
    psi_s.ny_w = ny_w.data();
    psi_s.ls_w = ls_w.data();
    psi_s.curl = curl.data();
    psi_s.beta_abs = beta_abs.data();
    psi_s.r_factor = r_factor.data();
    psi_s.source = source.data();
    psi_s.psi = psi.data();

    pk_async_physics::PsiSolveStats psi_stats;
    if (!pk_async_physics::psi_solve_pure(psi_k, psi_l, psi_s, psi_stats)) {
        return fail("psi_solve_pure rejected inputs");
    }
    const int   psi_iters_run = psi_stats.iters_run;
    const float psi_residual_final = psi_stats.residual_final;
    const bool  psi_early_exit = psi_stats.early_exit;
    const int   ocean_current_clamp_count = psi_stats.clamp_count;
    const float ocean_preclamp_max = psi_stats.preclamp_max;

    knobs["wind_stress_curl_out"] = curl_out;
    knobs["ocean_psi_out"]        = psi_out;
    knobs["ocean_current_x_out"]  = ocx_out;
    knobs["ocean_current_y_out"]  = ocy_out;

    bool published_to_slot = false;
    if (sid_ocx >= 0 && sid_ocy >= 0 &&
        _slots.write[sid_ocx].arr_f32.size() == n_cells &&
        _slots.write[sid_ocy].arr_f32.size() == n_cells) {
        std::memcpy(
            _slots.write[sid_ocx].arr_f32.ptrw(),
            ocx_out.ptr(),
            sizeof(float) * static_cast<size_t>(n_cells));
        std::memcpy(
            _slots.write[sid_ocy].arr_f32.ptrw(),
            ocy_out.ptr(),
            sizeof(float) * static_cast<size_t>(n_cells));
        _flush_slot_to_map(sid_ocx);
        _flush_slot_to_map(sid_ocy);
        // Fix #11 (2026-06-15): wind_stress_curl + ocean_psi 加入 schema 后也 publish。
        // 之前 GDScript caller 必须 2400-loop 写 map.wind_stress_curl_arr / ocean_psi_arr，
        // 这两个 slot 化后 caller 完全跳过 unpack（节省 2400 × 2 = 4800 GDScript array writes）。
        // 仅 tile_data_recorder 读 PackedArray，flush_slot 后 map.* 仍是同步的。
        const int sid_curl = component_id(StringName("cell_wind_stress_curl"));
        const int sid_psi  = component_id(StringName("cell_ocean_psi"));
        if (sid_curl >= 0 && _slots.write[sid_curl].arr_f32.size() == n_cells) {
            std::memcpy(
                _slots.write[sid_curl].arr_f32.ptrw(),
                curl_out.ptr(),
                sizeof(float) * static_cast<size_t>(n_cells));
            _flush_slot_to_map(sid_curl);
        }
        if (sid_psi >= 0 && _slots.write[sid_psi].arr_f32.size() == n_cells) {
            std::memcpy(
                _slots.write[sid_psi].arr_f32.ptrw(),
                psi_out.ptr(),
                sizeof(float) * static_cast<size_t>(n_cells));
            _flush_slot_to_map(sid_psi);
        }
        published_to_slot = true;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"]   = false;
    out["reason"]     = String();
    out["n_water"]    = n_water;
    out["wind_stress_curl_out"] = curl_out;
    out["ocean_psi_out"]        = psi_out;
    out["ocean_current_x_out"]  = ocx_out;
    out["ocean_current_y_out"]  = ocy_out;
    out["published_to_slot"]    = published_to_slot;
    out["psi_iters_run"] = psi_iters_run;
    out["psi_residual_final"] = double(psi_residual_final);
    out["psi_early_exit"] = psi_early_exit;
    out["psi_mode"] = PSI_EARLY_EXIT_MODE;
    // NS 化 Phase 4 诊断键:knob 回显 + elevation slot 实际可用状态。
    out["ocean_topo_steer_w"] = double(TOPO_STEER_W);
    out["ocean_depth_curl_damp"] = double(DEPTH_CURL_DAMP);
    out["ocean_topo_active"] = (ELEV != nullptr);
    if (!ocean_delta.empty()) {
        std::sort(ocean_delta.begin(), ocean_delta.end());
        const size_t p95_i = std::min(ocean_delta.size() - 1, size_t(std::floor(double(ocean_delta.size() - 1) * 0.95)));
        out["ocean_delta_p95"] = double(ocean_delta[p95_i]);
    }
    if (!thermal_current_mag.empty()) {
        std::sort(thermal_current_mag.begin(), thermal_current_mag.end());
        const size_t p95_t = std::min(thermal_current_mag.size() - 1, size_t(std::floor(double(thermal_current_mag.size() - 1) * 0.95)));
        out["thermal_current_p95"] = double(thermal_current_mag[p95_t]);
    }
    if (!ocean_preclamp_mag.empty()) {
        std::sort(ocean_preclamp_mag.begin(), ocean_preclamp_mag.end());
        const size_t p95_pre = std::min(ocean_preclamp_mag.size() - 1, size_t(std::floor(double(ocean_preclamp_mag.size() - 1) * 0.95)));
        out["ocean_current_preclamp_p95"] = double(ocean_preclamp_mag[p95_pre]);
        out["ocean_current_preclamp_max"] = double(ocean_preclamp_max);
        out["ocean_current_clamp_count"] = ocean_current_clamp_count;
        out["ocean_current_clamp_ratio"] = double(ocean_current_clamp_count) / double(ocean_preclamp_mag.size());
        out["ocean_current_max_magnitude"] = double(OC_MAX_MAG);
    }
    return out;
}

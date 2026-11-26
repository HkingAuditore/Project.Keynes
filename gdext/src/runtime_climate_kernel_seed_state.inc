    report = RuntimeClimateKernelReport{};
    struct DiagStageTrace {
        std::string line; int64_t day;
        DiagStageTrace(int64_t d, const RuntimeClimateStore &s) : day(d) {
            if (pk_sim_trace_file() != nullptr) {
                g_diag_stage_line = &line; g_diag_stage_store = &s;
            }
        }
        ~DiagStageTrace() {
            if (g_diag_stage_line == &line) {
                diag_note_stage("end");
                if (std::FILE *trace = pk_sim_trace_file()) {
                    const std::string out = "[climate-out] day=" + std::to_string(day) + line + "\n";
                    std::fputs(out.c_str(), trace);
                    std::fflush(trace);
                }
            }
            g_diag_stage_line = nullptr; g_diag_stage_store = nullptr;
        }
    } diag_stage_trace{day, next};
    // B8 P2：物理环流 prepass 的就绪状态。worker 用自己的 lane，只缺 profile 标量；
    // 未就绪时物理继续读生产 transport（不静默算错），这一行给出第一手证据。
    {
        // 前 6 天都打：bake 的 knob base 可能在首日 capture 之后才建好，只打前两天
        // 会看不到 ready 从 0→1 的切换（实测踩过）。
        static std::atomic<int> s_physics_ready_reports_left{6};
        if (s_physics_ready_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
            std::fprintf(stderr,
                "[climate/worker][b8] physics_knobs day=%lld ready=%d missing=%s\n",
                static_cast<long long>(day),
                input.climate_physics_knobs.ready ? 1 : 0,
                input.climate_physics_knobs.missing_key);
            std::fflush(stderr);
        }
    }
    std::string error;
    std::string current_error;
    std::string next_error;
    // publish 边界已对同一份 snapshot 做过完整 validate；热路径再跑一遍会把
    // hydro cycle（O(cells·depth)）和有限性扫描算进 plan_ms。
    if (validate_input && !validate_runtime_environment_snapshot(input, error)) {
        copy_error(report, error.c_str());
        return false;
    }
    // 提交态 store：形状契约即可。finite / physics decode 留给 save 与自测。
    if (!current.validate_shape(current_error) || &current == &next ||
        catalog.abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION ||
        catalog.cell_count != current.cell_count || next.cell_count != current.cell_count ||
        (input.climate_catalog_hash != 0 && input.climate_catalog_hash != catalog.hash) ||
        day < 0 || day > INT32_MAX || current.committed_day >= day) {
        const char *reason = !current_error.empty() ? current_error.c_str()
                                                    : "climate_kernel_preflight_failed";
        copy_error(report, reason);
        return false;
    }
    // next 是可丢弃工作区。上次失败留下的无效值不能阻止从有效 current 重试。
    if (!next.validate_shape(next_error)) next.reset(current.cell_count);
    copy_store_lanes(next, current, reuse_committed_history);
    {
        const bool own_extras = input.climate_worker_authoritative &&
            current.committed_day >= 0;
        auto stash = [&](std::vector<float> &dst, const std::vector<float> &src) {
            if (own_extras && src.size() == current.cell_count) dst = src;
            else dst.clear();
        };
        stash(_committed_soil, _distribute_soil_scratch);
        stash(_committed_insolation_now, _round_out.insolation_now);
        stash(_committed_insolation_dev, _round_out.insolation_dev);
        stash(_committed_heat_input, _round_out.heat_input);
    }
    const std::vector<float> &soil_in =
        !_committed_soil.empty() ? _committed_soil : input.cell_soil_moisture;
    static const bool full_physics = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_PHYSICS_RESTORE_FULL);
        return value && std::strcmp(value, "1") == 0;
    }();
    const bool reuse_physics = reuse_committed_history && !full_physics &&
        _committed_physics_owner == &current &&
        _committed_physics_generation == current.generation &&
        _physics.cell_count == static_cast<int>(current.cell_count) &&
        !current.physics_state.empty();
    const auto &physics_knobs = input.climate_physics_knobs;
    const auto &physics_terrain = input.climate_worker_authoritative &&
        current.committed_day >= 0 && current.terrain.size() == current.cell_count
        ? current.terrain : input.terrain;
    const std::array<double, 3> traj_knobs{physics_knobs.wrap_period_x,
        double(physics_knobs.wind_traj_pos_scale), double(physics_knobs.wind_traj_dt_days)};
    const bool same_neighbors = _physics_cache_keys_valid &&
        _physics_cache_neighbors == input.neighbor_indices;
    const bool same_terrain = _physics_cache_terrain == physics_terrain;
    const bool same_water_ids = _physics_cache_water_ids == physics_knobs.water_terrain_ids;
    const bool same_geometry = same_neighbors && same_water_ids && (same_terrain || [&] {
        // Both builders depend on the land/water classification, not the raw terrain ID.
        bool water[256]{};
        for (uint8_t id : physics_knobs.water_terrain_ids) water[id] = true;
        return std::equal(_physics_cache_terrain.begin(), _physics_cache_terrain.end(),
            physics_terrain.begin(), physics_terrain.end(),
            [&water](uint8_t previous, uint8_t next) { return water[previous] == water[next]; });
    }());
    const bool same_trajectory_inputs = same_neighbors &&
        same_float_bits(_physics_cache_pos_x, input.cell_pos_x) &&
        same_float_bits(_physics_cache_pos_y, input.cell_pos_y) &&
        std::memcmp(_physics_cache_traj_knobs.data(), traj_knobs.data(), sizeof(traj_knobs)) == 0;
    _committed_physics_owner = nullptr;
    _planned_physics_generation = 0;
    {
        EconomyCostProbe probe("climate.physics_restore", day, reuse_physics ? 0 : 1);
        // 与提交胶囊完全相同的 canonical lanes 可驻留；禁止复用 speculative 计划。
        if (!reuse_physics && !pk_async_physics::restore_physics_state(current.physics_state.data(),
                current.physics_state.size(), _physics, error)) {
            copy_error(report, error.c_str()); return false;
        }
        if (reuse_physics) {
            _physics.wind_speed_out = _physics.wind_speed;
            // 邻接或海陆分类变化时才需要重算海岸与海域编号。
            _physics.topo_valid &= same_geometry;
            _physics.coast_valid &= same_geometry;
            // wind_prepass 每次改风都会更新或废弃轨迹。这里另核对地图坐标和配置。
            _physics.wind_traj_valid &= same_trajectory_inputs;
        }
    }
    if (current.physics_state.empty()) _physics.resize(static_cast<int>(current.cell_count));
    if (_physics.cell_count != static_cast<int>(current.cell_count)) {
        copy_error(report, "physics_store_shape_mismatch"); return false;
    }
    const bool physics_owned = physics_inputs_ready(input, current.cell_count);
    {
        EconomyCostProbe probe("climate.physics_prepass", day, current.cell_count);
        EconomyCostProbe cache_probe("climate.physics_geometry_reused", day,
            physics_owned && _physics.topo_valid && _physics.coast_valid ? 1 : 0);
        if (physics_owned && !physics_prepass(day, input, current, _physics, error)) {
            copy_error(report, error.c_str()); return false;
        }
    }
    if (physics_owned) {
        if (!same_terrain) _physics_cache_terrain = physics_terrain;
        if (!same_water_ids) _physics_cache_water_ids = physics_knobs.water_terrain_ids;
        if (!same_neighbors) _physics_cache_neighbors = input.neighbor_indices;
        if (!same_trajectory_inputs) {
            _physics_cache_pos_x = input.cell_pos_x;
            _physics_cache_pos_y = input.cell_pos_y;
            _physics_cache_traj_knobs = traj_knobs;
        }
        _physics_cache_keys_valid = true;
    } else _physics_cache_keys_valid = false;
    if (physics_owned) report.work_units += uint64_t(current.cell_count) *
        (uint64_t(_physics.last_slp_day == day) + uint64_t(_physics.last_wind_day == day) +
         2u * uint64_t(_physics.last_ocean_day == day));
    // 缺配置时不能沿用上次 ready 来授权主线程停算。
    if (!physics_owned) _physics.initialized = false;
    _physics.committed_day = day;
    _physics.input_generation = input.generation;
    _cyclone_seeded = false;
    _cyclone_entries.clear();
    _cyclone_next_stable_id = 1;
    // B8-2：store 里的 synoptic ψ 是跨天 + 跨存档的权威副本。先把它装进 kernel
    // scratch；只有"store 里确实有非零状态"才算已播种，否则留着让生产 capture
    // 的冷启动种子生效（ABI 3 旧档读进来就是全零）。
    if (current.physics_state.empty() && current.synoptic_psi.size() == current.cell_count &&
        current.synoptic_psi_prev.size() == current.cell_count) {
        for (size_t i = 0; i < current.synoptic_psi.size(); ++i) {
            if (current.synoptic_psi[i] != 0.0f ||
                current.synoptic_psi_prev[i] != 0.0f) {
                _physics.synoptic_psi = current.synoptic_psi;
                _physics.synoptic_psi_prev = current.synoptic_psi_prev;
                _physics.synoptic_seeded = true;
                break;
            }
        }
    }
    // B8-P1：演替状态的冷启动。store 里全零（新图 / ABI 4 旧档）时用生产 capture
    // 的 vegetation lane 播种；之后由 worker 的演替 emit 自己推进。
    if (current.vegetation.size() == current.cell_count &&
        !current.vegetation.empty() &&
        input.vegetation.size() == current.cell_count) {
        bool vegetation_seeded = false;
        for (uint8_t value : current.vegetation) {
            if (value != 0u) {
                vegetation_seeded = true;
                break;
            }
        }
        if (!vegetation_seeded) {
            next.vegetation = input.vegetation;
            next.base_vegetation = input.vegetation;
        }
    }
    // B8-P1 / ABI 8：terrain / cover 冷启动。store 全零（新图 / ABI<=7 旧档）时
    // 用环境快照播种；之后由 sea_ice 翻转与 weather distribute 在 worker 侧推进。
    if (current.terrain.size() == current.cell_count &&
        !current.terrain.empty() &&
        input.terrain.size() == current.cell_count) {
        bool terrain_seeded = false;
        for (uint8_t value : current.terrain) {
            if (value != 0u) {
                terrain_seeded = true;
                break;
            }
        }
        if (!terrain_seeded) {
            next.terrain = input.terrain;
            // sea_ice 与翻转后的 terrain 是同一份状态，一起冷启动。全零本身是合法的
            // 海冰状态，不能像 terrain 那样用"有无非零"判断是否已播种。
            const auto &seed_ice = input.climate_round_input.sea_ice_frac_inout;
            if (seed_ice.size() == current.cell_count &&
                next.sea_ice.size() == current.cell_count) {
                next.sea_ice = seed_ice;
            }
        }
    }
    if (current.cover.size() == current.cell_count &&
        !current.cover.empty() &&
        input.cover.size() == current.cell_count) {
        bool cover_seeded = false;
        for (uint8_t value : current.cover) {
            if (value != 0u) {
                cover_seeded = true;
                break;
            }
        }
        if (!cover_seeded) next.cover = input.cover;
    }
    // B8-2：cyclone 状态同样先看 store（存档恢复），再退回 capture 的生产种子。
    // blob 的语义由 cyclone_state_encode/decode 拥有；只要 header 合法就算播种成功，
    // 哪怕是"0 个条目"—— 否则 worker 会每天重新播种、永远不开始自己的推进。
    if (!_cyclone_seeded && !current.cyclone_state.empty()) {
        cyclone_state_decode(current.cyclone_state, _cyclone_entries,
                             _cyclone_next_stable_id);
        if (current.cyclone_state.size() >= 16u) {
            _cyclone_seeded = true;
        }
    }
    if (!_cyclone_seeded && !input.cyclone_seed_blob.empty()) {
        cyclone_state_decode(input.cyclone_seed_blob, _cyclone_entries,
                             _cyclone_next_stable_id);
        if (input.cyclone_seed_blob.size() >= 16u) {
            _cyclone_seeded = true;
        }
    }

    // P2 日序：physics → synoptic → cyclone stamp → round → weather。
    bool physics_cyclone_stamp_ready = false;
    if (physics_owned && input.climate_weather && input.climate_weather->ran) {
        const auto &wx = *input.climate_weather;
        const size_t n = current.cell_count;
        if (wx.n_cells != static_cast<int>(n)) { copy_error(report, "physics_weather_shape"); return false; }
        const auto &nb = input.neighbor_indices;
        const char *syn_off = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_SYNOPTIC_OFF);
        if (wx.synoptic_enabled && !(syn_off && syn_off[0] == '1')) {
            if (!_physics.synoptic_seeded) {
                if (wx.psi.size() == n) _physics.synoptic_psi = wx.psi;
                if (wx.psi_prev.size() == n) _physics.synoptic_psi_prev = wx.psi_prev;
                _physics.synoptic_seeded = true;
            }
            if (_physics.synoptic_tick == INT32_MAX) { copy_error(report, "physics_synoptic_tick_overflow"); return false; }
            auto syn = wx.synoptic;
            syn.tick = ++_physics.synoptic_tick;
            pk_async_climate::synoptic_advance_pure(static_cast<int>(n), nb.data(),
                input.cell_pos_x.data(), input.cell_pos_y.data(), _physics.wind_x.data(),
                _physics.wind_y.data(), current.temperature.data(), syn,
                _physics.synoptic_psi, _physics.synoptic_psi_prev);
        }
        const char *cyc_force = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_CYCLONE_FORCE);
        if (input.cyclone_enabled || (cyc_force && cyc_force[0] == '1')) {
            // stamp/tag 是当日派生场，每次从空工作区重建，使重试不依赖上次计划。
            _cyclone_force_tag.assign(n, 0); _cyclone_visit_tag.assign(n, 0);
            _cyclone_force_x.assign(n, 0); _cyclone_force_y.assign(n, 0); _cyclone_lift.assign(n, 0);
            _cyclone_force_generation = 1;
            pk_async_climate::CycloneAdvanceKnobs ck;
            ck.enabled = true; ck.dt_days = input.cyclone_dt_days;
            ck.world_bounds_pos_y = input.cyclone_world_bounds_pos_y;
            ck.world_bounds_size_y = input.cyclone_world_bounds_size_y;
            ck.wrap_width_x = input.cyclone_wrap_width_x; ck.max_radius_cells = input.cyclone_max_radius_cells;
            pk_async_climate::CycloneLanes cl;
            cl.neighbors = nb.data(); cl.pos_x = input.cell_pos_x.data(); cl.pos_y = input.cell_pos_y.data();
            cl.lat_norm = input.cell_lat_norm.data();
            cl.terrain = (input.climate_worker_authoritative && current.committed_day >= 0 &&
                          current.terrain.size() == n) ? current.terrain.data() : input.terrain.data();
            cl.temp = current.temperature.data();
            cl.wind_x = _physics.wind_x.data(); cl.wind_y = _physics.wind_y.data(); cl.wind_speed = _physics.wind_speed.data();
            cl.vapor = current.vapor.data(); cl.instability = current.instability.data();
            pk_async_climate::CycloneStamp stamp;
            stamp.force_tag = _cyclone_force_tag.data(); stamp.visit_tag = _cyclone_visit_tag.data();
            stamp.force_x = _cyclone_force_x.data(); stamp.force_y = _cyclone_force_y.data(); stamp.lift = _cyclone_lift.data();
            stamp.force_generation = stamp.visit_generation = 1;
            pk_async_climate::CycloneStats stats;
            pk_async_climate::cyclone_advance_and_stamp_pure(static_cast<int>(n), ck, cl, _cyclone_entries, stamp, stats);
            _physics.cyclone_total_decayed += static_cast<uint64_t>(std::max(0, stats.decayed));
            report.cyclone_touched = stats.touched_cells;
            physics_cyclone_stamp_ready = true;
            _cyclone_seeded = true;
        }
    }
    // climate_anomaly 是季节系统给出的全局量，不是 Climate 域自己的状态：生产每 tick
    // 从 environment 提供它，而 worker 的 store 只在 day % 365 == 0 改写。两者因此长期
    // 不等，且这个差异不在 parity 字段表里（只进 parity_hash），会一直隐身。它进
    // weather knobs 与温度合成，采纳生产的值是长期正确的语义 —— 年度漂移仍由下面的
    // annual_temperature_drift 维护，供 ACTIVE 模式下 environment 缺值时兜底。
    if (std::isfinite(input.climate_anomaly)) {
        next.climate_anomaly = static_cast<float>(input.climate_anomaly);
    }
    // 季末地理级重算在当天 climate round 之前跑（SUS priority 50 vs 210）。
    // capture 里的 cell_moisture 是 tick 开头、refresh 之前的快照，不能当权威。
    // 生产 pass_a 的输入才是 stage 0/1/3/4 全部写完之后的值。没有 production
    // overlay 时退回 stage 0：陆地 moisture = clamp(base, 0, 1)，水体 = base。
    // ACTIVE 之后这条语义依然成立：season refresh 保持在主线程，它是地理权威。
    if (input.climate_season_refresh_ran &&
        next.moisture.size() == current.cell_count) {
        const auto &round_moist = input.climate_round_input.moisture;
        const auto &round_base = input.climate_round_input.base_moisture;
        if (input.climate_round_ran &&
            round_moist.size() == current.cell_count) {
            for (size_t i = 0; i < current.cell_count; ++i) {
                const float m = round_moist[i];
                if (std::isfinite(m)) next.moisture[i] = m;
            }
        } else {
            const auto &bases = !round_base.empty() ? round_base
                                                    : input.cell_base_moisture;
            const auto &water = input.climate_round_input.is_water.empty()
                ? input.is_water : input.climate_round_input.is_water;
            if (bases.size() == current.cell_count) {
                for (size_t i = 0; i < current.cell_count; ++i) {
                    const float base = bases[i];
                    if (!std::isfinite(base)) continue;
                    const bool is_water = i < water.size() && water[i] != 0u;
                    const float m = is_water ? base
                        : climate_formula::clamp01(base);
                    next.moisture[i] = m;
                }
            }
        }
    }
    // PAW 每天在这里重算，而不是从 input 收回。它是 f(moisture, WB30, soil) 的纯派生
    // 量，没有跨天累积，所以「收回」这个动作本身就是错的抽象。
    //
    // 不收回的理由是收了没用。ACTIVE 下 PAW 有两份，通过 MapData 首尾相接：
    //
    //   next.plant_available_water（store，进回灌表）
    //       ↑ 每 48 天被 vegetation_dynamics 写一次，别处不写
    //   input.climate_round_input.plant_*（capture 从 slot 填，喂共享 round）
    //       ↑ 就是上面那份昨天回灌的结果
    //
    // 于是 PAW 只在 vegetation_dynamics 那几天动一下 —— 实测 150 天两个值
    // （0.296 / 0.302），而主线程那侧单调降 12%（0.294 → 0.258）。transpiration 每天拿
    // PAW 乘 heat 算 vegetation_growth_pressure，所以整条植被链的活跃 cell 集合跟着锁死。
    //
    // season refresh 那侧的写入也进不来：capture 早于 _sus.tick()（见
    // world_ext_simulation_host.cpp 里 fill_climate_round_input 那处说明），而 season
    // refresh 跑在 _sus.tick() 里，它写完 MapData 之后，第二天开头的回灌就把它覆盖了。
    // moisture 没有这个问题，因为它的收回走 base_moisture，那条场没有 store 成员、不在
    // 回灌表里，主线程仍是它唯一的写者。
    //
    // SHADOW 必须保持原样（PAW 跟着生产的 48/49 天节拍走），每天自算会立刻分叉，所以
    // 这一段由 climate_own_paw 门控。
    //
    // 用 next 而不是 current 读 moisture：上面那段收回可能刚把 season refresh 的
    // base_moisture 写进 next.moisture，PAW 应当看到它。soil 没有 store 成员，读的是
    // worker 昨天 distribute scratch 的副本（soil_in，见 _committed_soil）。
    if (input.climate_worker_authoritative &&
        next.plant_available_water.size() == current.cell_count &&
        next.moisture.size() == current.cell_count &&
        next.water_balance_30d.size() == current.cell_count) {
        const auto &soil = soil_in;
        const auto &water = input.is_water;
        // B8-3 归因诊断：PAW 链 collapse 的逐日输入。只打前 12 天、每图选第一个
        // 陆地格（水域 PAW 恒 0，看它没有意义）。定位"是 WB30 变负、soil 缺席、
        // 还是权重口径不同"三选一，而不是继续猜。
        static std::atomic<int> s_paw_reports_left{12};
        size_t paw_probe_cell = current.cell_count;
        for (size_t i = 0; i < current.cell_count; ++i) {
            if (i >= water.size() || water[i] == 0u) {
                paw_probe_cell = i;
                break;
            }
        }
        const bool paw_probe = paw_probe_cell < current.cell_count &&
            s_paw_reports_left.load(std::memory_order_relaxed) > 0;
        for (size_t i = 0; i < current.cell_count; ++i) {
            // 水域格 PAW 恒 0，与生产两处调用点的 is_water 分支一致
            // （runtime_climate_passes.cpp:2602 与 :5043）。
            if (i < water.size() && water[i] != 0u) {
                next.plant_available_water[i] = 0.0f;
                continue;
            }
            next.plant_available_water[i] = climate_formula::plant_available_water(
                next.moisture[i], next.water_balance_30d[i],
                i < soil.size() ? soil[i] : 0.0f,
                input.climate_paw_water_balance_weight,
                input.climate_paw_soil_buffer_weight,
                input.climate_paw_drought_penalty);
        }
        if (paw_probe) {
            s_paw_reports_left.fetch_sub(1, std::memory_order_relaxed);
            const size_t c = paw_probe_cell;
            // 零值按水/陆分类：PAW 的"collapse"要么是水域规则（生产共享内核同样
            // 把 water/veg_none 清零），要么是陆地真的算错。分类计数一次就能分开。
            size_t zero_water = 0, zero_land = 0, nonzero = 0;
            for (size_t i = 0; i < current.cell_count; ++i) {
                const bool is_water = i < water.size() && water[i] != 0u;
                if (next.plant_available_water[i] == 0.0f) {
                    if (is_water) ++zero_water; else ++zero_land;
                } else {
                    ++nonzero;
                }
            }
            std::fprintf(stderr,
                "[climate/worker][b8] paw day=%lld cell=%zu moisture=%.6g "
                "wb30=%.6g soil=%s%.6g paw=%.6g "
                "zeros(water=%zu land=%zu) nonzero=%zu weights(wb=%.4g soil=%.4g dry=%.4g) "
                "round=%d distribute=%d hydrology=%d\n",
                static_cast<long long>(day), c, next.moisture[c],
                next.water_balance_30d[c],
                c < soil.size() ? "" : "missing/",
                c < soil.size() ? soil[c] : 0.0f,
                next.plant_available_water[c],
                zero_water, zero_land, nonzero,
                input.climate_paw_water_balance_weight,
                input.climate_paw_soil_buffer_weight,
                input.climate_paw_drought_penalty,
                input.climate_round_ran ? 1 : 0,
                (input.climate_weather_distribute != nullptr &&
                 input.climate_weather_distribute->ran) ? 1 : 0,
                (input.climate_hydrology != nullptr &&
                 input.climate_hydrology->ran) ? 1 : 0);
            std::fflush(stderr);
        }
    }
    // 生产 stage 11（consume_feedback_buffers）在 climate round / hydrology 之前
    // 把 VGP *= decay。放在全部 stage 之后会让当天 hydrology 仍按未衰减的 VGP
    // 抽水，比完之后 VGP 本身却是绿的——day 28 的 moisture/PAW/河网链就是这样。
    if (input.season_growth_pressure.size() == current.cell_count) {
        next.vegetation_growth_pressure = input.season_growth_pressure;
        next.vegetation = input.vegetation;
    } else if (input.climate_seasonal_feedback_ran &&
        next.vegetation_growth_pressure.size() == current.cell_count) {
        const float decay = input.climate_seasonal_feedback_decay;
        if (std::isfinite(decay)) {
            for (size_t i = 0; i < current.cell_count; ++i) {
                next.vegetation_growth_pressure[i] *= decay;
            }
        }
    }
    {
        EconomyCostProbe probe("climate.input_hash", day, current.cell_count);
        static const bool full_input_hash = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_INPUT_HASH_FULL);
            return value && std::strcmp(value, "1") == 0;
        }();
        // 仅消费 Host 已校验并冻结的副本；公开 kernel/独立对拍仍完整重算。
        const bool sealed = reuse_committed_history && !validate_input && !full_input_hash &&
            input.sealed_climate_input_hash != 0;
        report.input_hash = sealed ? input.sealed_climate_input_hash : input_hash(input);
        EconomyCostProbe::record("climate.input_hash_precomputed", day, 0.0, sealed ? 1 : 0);
    }
    // 生产这一天跑了哪些 stage。与下面累积的 report.stage_ran_mask 的差集就是
    // "生产算了、worker 没算"——分叉矩阵里 stage 9..13 的字段全靠它归因。
    report.production_stage_mask = input.climate_production_stage_mask;

    // 生产 Climate round 按 stride 跑，不是每日一轮。这一天生产没跑 round 时，
    // reference 里 Climate 拥有的场与前一天完全相同，所以 worker 也必须一个 stage
    // 都不跑：copy_store_lanes 已经把状态原样搬过来了，直接收工即为等价。
    // 反之若 worker 每天都跑，它会在生产没动的日子里单方面推进温度场，而分叉矩阵
    // 会把这种节拍错位报成算法分叉。
    // albedo 不在 climate round 里：它跑在 native daily graph 的 stage_b 段、用
    // cp.weather_albedo_stride 自己的节拍。所以"这一天 worker 要不要干活"是两个
    // 独立条件的并集 —— 只看 round 会漏掉那些生产只跑了 albedo 的日子，而 albedo 是
    // temp 的日内最后写者，漏一天温度场就整场落后一个 delta。
    // feedback（stage 10）同在 stage_b 段、同样有自己的 stride，所以是第三个独立条件。
    // vegetation_dynamics（stage 9）与 feedback（stage 10）同在 stage_b 段、各有自己的
    // stride，所以是第三、第四个独立条件。
    const bool vegetation_requested = input.climate_vegetation != nullptr &&
        input.climate_vegetation->knobs.ran &&
        input.climate_vegetation->n_cells == static_cast<int>(current.cell_count);
    const bool feedback_requested = input.climate_feedback != nullptr &&
        input.climate_feedback->knobs.ran &&
        input.climate_feedback->n_cells == static_cast<int>(current.cell_count);
    // weather（stage 11）跑在 round 末尾，但有自己的 weather bucket cadence，所以同样
    // 是一个独立条件：只看 round 会在"生产这天只跑了 weather"的日子上什么都不做。
    const bool weather_requested = input.climate_weather != nullptr &&
        input.climate_weather->ran &&
        input.climate_weather->n_cells == static_cast<int>(current.cell_count);
    // hydrology（stage 12）有 runtime_hydrology_stride 自己的节拍，同样是一个独立条件。
    const bool hydrology_requested = input.climate_hydrology != nullptr &&
        input.climate_hydrology->ran &&
        input.climate_hydrology->n_cells == static_cast<int>(current.cell_count);
    // weather distribute 跟 weather bucket 同节拍，但它自己的记录可能缺席（字段不全）。
    const bool distribute_requested =
        input.climate_weather_distribute != nullptr &&
        input.climate_weather_distribute->ran &&
        input.climate_weather_distribute->n_cells == static_cast<int>(current.cell_count);
    if (!input.climate_round_ran && !input.climate_albedo.ran &&
        !vegetation_requested && !feedback_requested && !weather_requested &&
        !hydrology_requested && !distribute_requested) {
        if (!pk_async_physics::serialize_physics_state(_physics, next.physics_state, error)) {
            copy_error(report, error.c_str()); return false;
        }
        next.committed_day = day;
        ++next.generation;
        ++next.climate_generation;
        _planned_physics_generation = next.generation;
        report.completed = 1;
        if (compute_state_hash) report.state_hash = next.state_hash();
        return true;
    }

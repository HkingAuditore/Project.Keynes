    // ─── stage 11 WEATHER（共享纯内核，weather bucket 自己的 cadence）────────
    //
    // 状态所有权在这一段分得最细，因为 weather 是 climate 里跨 tick 状态最多的一段：
    //
    //   worker 自己那一份（store 成员，真正被对拍的量）：
    //       vapor / cloud_water / cloud_cover / weather_precipitation /
    //       weather_intensity / convergence / instability / weather_type 与过渡三条。
    //       prev_* 输入也取自 worker 的 store —— 也就是它自己昨天算出来的场。天气
    //       是强惯性系统（vapor/cloud 都带 inertia 项），所以逐日累积的偏差会被
    //       如实放大出来，这正是这一段该验的东西。
    //   生产记录那一份（worker 无从重建）：
    //       风场、温度、湿度等读 lane —— 它们的生产者（wind / pass_b）还没提取；
    //       ψ、对流抑制、气旋强迫、季风热力、回溯轨迹表 —— 都不是 store 成员，且
    //       ψ 与轨迹表都由 wind pass 派生并带指纹校验。这几组照抄生产当天用过的
    //       那一份，输出丢弃。stage 12/13 与 wind 提取完之后才有资格换成 worker 的。
    //
    // use_next_outputs 在 worker 侧一律取 false：生产 native daily 走 staged，把原始
    // 类型写进 int32 next buffer、由 commit pass 落成显示类型；worker 没有 commit
    // pass，用 direct 语义可以在同一次调用里直接得到显示类型。这个 flag 在内核里只
    // 切换"写 int32 原始类型"与"写 u8 显示类型 + field_init"，不影响任何数值。
    const bool shared_weather_ran = weather_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_weather_ran) {
        run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
            // SHADOW 保持捕获的参考输入；ACTIVE 的物理消费者只读本次 worker 计划。
            pk_async_climate::WeatherFieldInput owned_weather;
            if (physics_owned) {
                owned_weather = *input.climate_weather;
                owned_weather.wind_x = _physics.wind_x;
                owned_weather.wind_y = _physics.wind_y;
                owned_weather.wind_speed = _physics.wind_speed;
                owned_weather.monsoon_thermal = _physics.monsoon_thermal;
                owned_weather.temp_read = next.temperature;
                owned_weather.moisture_read = next.moisture;
                owned_weather.sea_ice = next.sea_ice;
                owned_weather.snow_cover = next.snow_cover;
                if (current.committed_day >= 0) {
                    if (next.terrain.size() == cells) owned_weather.terrain = next.terrain;
                    if (next.vegetation.size() == cells) owned_weather.vegetation = next.vegetation;
                    if (!owned_weather.vitality.empty() &&
                        next.vegetation_vitality.size() == cells) {
                        owned_weather.vitality = next.vegetation_vitality;
                    }
                }
                owned_weather.traj_idx.clear();
                owned_weather.traj_w.clear();
                if (input.climate_physics_knobs.wind_traj_weather_share && _physics.wind_traj_valid) {
                    owned_weather.traj_idx = _physics.wind_traj_idx;
                    owned_weather.traj_w = _physics.wind_traj_w;
                }
            }
            const pk_async_climate::WeatherFieldInput &wx = physics_owned
                ? owned_weather : *input.climate_weather;
            const auto &neighbors = physics_owned ? input.neighbor_indices
                : input.climate_round_static_knobs.neighbor_indices;
            const auto lane_ok = [cells](const std::vector<float> &v) {
                return v.size() == cells;
            };
            if (!lane_ok(wx.temp_read) || !lane_ok(wx.moisture_read) ||
                !lane_ok(wx.air_anomaly) || !lane_ok(wx.wind_x) ||
                !lane_ok(wx.wind_y) || !lane_ok(wx.wind_speed) ||
                !lane_ok(wx.elevation) || !lane_ok(wx.pos_x) ||
                !lane_ok(wx.pos_y) || !lane_ok(wx.temp_transport_anomaly) ||
                wx.terrain.size() != cells || wx.has_river.size() != cells ||
                wx.vegetation.size() != cells ||
                neighbors.size() < cells * 6u ||
                next.vapor.size() != cells || next.cloud_water.size() != cells ||
                next.cloud_cover.size() != cells ||
                next.weather_precipitation.size() != cells ||
                next.weather_intensity.size() != cells ||
                next.convergence.size() != cells ||
                next.instability.size() != cells ||
                next.weather_type.size() != cells ||
                next.weather_prev_type.size() != cells ||
                next.weather_target_type.size() != cells ||
                next.weather_transition_alpha.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                // 这一段的 bit 与 distribute 共用（同属 stage 11），所以静默返回
                // 会被 distribute 的成功掩盖 —— 说一次哪条短了。
                static std::atomic<bool> wx_starved_reported{false};
                bool expected = false;
                if (wx_starved_reported.compare_exchange_strong(expected, true)) {
                    std::fprintf(stderr,
                        "[climate/worker] weather starved: temp=%zu moist=%zu air=%zu "
                        "wx=%zu wy=%zu wspd=%zu elev=%zu posx=%zu posy=%zu tta=%zu "
                        "terrain=%zu river=%zu veg=%zu nb=%zu | store vapor=%zu "
                        "cloudw=%zu cloud=%zu precip=%zu intens=%zu conv=%zu "
                        "instab=%zu type=%zu prev=%zu target=%zu alpha=%zu | cells=%zu\n",
                        wx.temp_read.size(), wx.moisture_read.size(),
                        wx.air_anomaly.size(), wx.wind_x.size(), wx.wind_y.size(),
                        wx.wind_speed.size(), wx.elevation.size(), wx.pos_x.size(),
                        wx.pos_y.size(), wx.temp_transport_anomaly.size(),
                        wx.terrain.size(), wx.has_river.size(),
                        wx.vegetation.size(), neighbors.size(),
                        next.vapor.size(), next.cloud_water.size(),
                        next.cloud_cover.size(), next.weather_precipitation.size(),
                        next.weather_intensity.size(), next.convergence.size(),
                        next.instability.size(), next.weather_type.size(),
                        next.weather_prev_type.size(),
                        next.weather_target_type.size(),
                        next.weather_transition_alpha.size(), cells);
                }
                return static_cast<uint64_t>(0);
            }
            // prev_* 必须是独立缓冲：内核会读 PREV_CNV[upstream_idx]，upstream 可能
            // 小于 i，与 OUT_CNV 共用同一块内存就会读到本轮已经改写过的值。生产
            // staged 路径用的是两块 buffer，这里跟着分开。
            _weather_prev_vapor = next.vapor;
            _weather_prev_precip = next.weather_precipitation;
            _weather_prev_cloud_water = next.cloud_water;
            _weather_prev_cloud = next.cloud_cover;
            _weather_prev_convergence = next.convergence;
            // own_field_state 决定 conv_inhib 跨天归属（见 WeatherFieldInput）。
            if (!wx.own_field_state || _weather_conv_inhib.size() != cells) {
                _weather_conv_inhib = wx.conv_inhib;
            }
            // field_init 是"这张图的天气场是否已经解算过一次"，一置 1 就长期为真。
            // 从前这里每轮 assign(cells, 0)，于是 distribute 侧读到的永远是"未初始化"
            // （它按 field_init 决定 weather_type/intensity/precip 取真值还是取 0），
            // worker 的天气输出因此成片写零。只在首次分配，之后由 commit 置位。
            const bool field_init_fresh =
                _weather_field_init_scratch.size() != cells;
            if (field_init_fresh) {
                _weather_field_init_scratch.assign(cells, 0u);
                // 换图/换尺寸后旧图的有效性不能继承；stage_b 在 weather 之后读
                // 这张 scratch，继承一个 true 会把新图当成已初始化。
                _weather_field_init_seeded = false;
            }
            // 生产生成阶段通常已经把 field_init 置 1。worker 若从全零起步会按
            // moisture*0.15 重做 spinup，vapor 因此整场偏 0.15。
            // own_field_state 下只首次播种。commit 会把解算过的格子置 1，每天拿
            // input 覆盖会把这份记忆抹掉 —— 若覆盖成全 1，下面的 spinup 就被整场
            // 跳过，prev_vapor 停在 store 的 0，水汽循环永远起不来（vapor / precip
            // 全场恒 0）；若覆盖成全 0 则每天重做 spinup，同样不是演化。
            if (wx.field_init.size() == cells &&
                (!wx.own_field_state || field_init_fresh)) {
                _weather_field_init_scratch = wx.field_init;
                _weather_field_init_seeded = true;
            }
            // commit 会写这张 scratch；即使 seed 分支没走（own_field_state 且非
            // fresh），只要它带着上一日的值就是有效状态。全零只可能是"首日还没解
            // 算过"，那不算有效状态 —— 否则 starved 的首日会让 stage_b 把已初始化
            // 的地图当成 spin-up。
            if (_weather_field_init_scratch.size() == cells &&
                !_weather_field_init_seeded) {
                for (size_t i = 0; i < cells; ++i) {
                    if (_weather_field_init_scratch[i] != 0u) {
                        _weather_field_init_seeded = true;
                        break;
                    }
                }
            }
            // 未初始化的格子不读 SoA vapor/precip —— 那份此刻还是零，而生产按稳态
            // 量级 moisture * WEATHER_SPINUP_VAPOR_FRACTION 起步（field_solver.gd 的
            // 首帧暴雨修复：prev_vapor=moisture 会让首 tick 处处过饱和）。少了这一步，
            // worker 首轮的 prev_vapor 就整场低 0.15，而天气是强惯性系统，这个偏差
            // 会一路带到 cloud / instability / precipitation。
            if (wx.moisture_read.size() == cells) {
                constexpr float WEATHER_SPINUP_VAPOR_FRACTION = 0.15f;
                for (size_t i = 0; i < cells; ++i) {
                    if (_weather_field_init_scratch[i] > 0) continue;
                    _weather_prev_vapor[i] =
                        wx.moisture_read[i] * WEATHER_SPINUP_VAPOR_FRACTION;
                    _weather_prev_precip[i] = 0.0f;
                }
            }
            // staged next buffer：生产 native daily 的 weather_advance 把结果写进
            // 调用方给的 next buffer（weather_type 走 int32），再由 weather_commit
            // 落到 slot 并解析 display/transition/field_init。worker 必须走同一分支，
            // 否则两边在同一 stage 上跑同一内核的不同分支。
            auto ensure_f32 = [cells](std::vector<float> &v) {
                if (v.size() != cells) v.assign(cells, 0.0f);
            };
            ensure_f32(_wx_next_vapor);
            ensure_f32(_wx_next_cloud);
            ensure_f32(_wx_next_cloud_water);
            ensure_f32(_wx_next_precip);
            ensure_f32(_wx_next_instability);
            ensure_f32(_wx_next_intensity);
            ensure_f32(_wx_next_convergence);
            if (_wx_next_type.size() != cells) _wx_next_type.assign(cells, 0);
            if (_weather_dirty_scratch.size() != cells) {
                _weather_dirty_scratch.assign(cells, 0u);
            }

            pk_async_climate::WeatherFieldKnobs knobs = wx.knobs;
            knobs.use_next_outputs = true;
            // The worker's own fields take precedence, as before. When they
            // are unavailable, sample from the same arrays the script read.
            if (physics_owned && knobs.world_bounds_size_y > 0.001f) {
                knobs.weather_lat_te_norm = thermal_equator_lat_norm(
                    wx.temp_read, wx.pos_y, knobs.world_bounds_pos_y,
                    knobs.world_bounds_size_y, knobs.weather_lat_te_norm);
            } else if (const auto &sample = wx.captured_thermal_equator) {
                knobs.weather_lat_te_norm = static_cast<float>(thermal_equator_lat_norm(
                    sample->temperature, sample->pos_y, sample->bounds_y,
                    sample->bounds_height, static_cast<double>(knobs.weather_lat_te_norm)));
            }

            pk_async_climate::WeatherFieldLanes lanes;
            lanes.temp_read = wx.temp_read.data();
            lanes.moisture_read = wx.moisture_read.data();
            lanes.air_anomaly = wx.air_anomaly.data();
            lanes.wind_x = wx.wind_x.data();
            lanes.wind_y = wx.wind_y.data();
            lanes.wind_speed = wx.wind_speed.data();
            lanes.terrain = wx.terrain.data();
            lanes.has_river = wx.has_river.data();
            lanes.river_q30 = lane_ok(wx.river_q30) ? wx.river_q30.data() : nullptr;
            lanes.elevation = wx.elevation.data();
            lanes.vegetation = wx.vegetation.data();
            lanes.soil_moisture = !lane_ok(wx.soil_moisture) ? nullptr
                : (soil_in.size() == cells ? soil_in.data() : wx.soil_moisture.data());
            lanes.vitality = lane_ok(wx.vitality) ? wx.vitality.data() : nullptr;
            lanes.sea_ice = lane_ok(wx.sea_ice) ? wx.sea_ice.data() : nullptr;
            lanes.pos_x = wx.pos_x.data();
            lanes.pos_y = wx.pos_y.data();
            lanes.temp_anomaly =
                lane_ok(wx.temp_anomaly) ? wx.temp_anomaly.data() : nullptr;
            lanes.snow_cover =
                lane_ok(wx.snow_cover) ? wx.snow_cover.data() : nullptr;
            lanes.neighbor_indices = neighbors.data();
            lanes.temp_transport_anomaly = wx.temp_transport_anomaly.data();
            lanes.prev_vapor = _weather_prev_vapor.data();
            lanes.prev_precip = _weather_prev_precip.data();
            lanes.prev_cloud_water = _weather_prev_cloud_water.data();
            lanes.prev_cloud = _weather_prev_cloud.data();
            lanes.prev_convergence = _weather_prev_convergence.data();
            // staged 分支：写 next buffer，类型走 int32；transition 三条与
            // field_init 在这一步是 nullptr（与生产 world_ext_weather.cpp:698-705
            // 的 use_next_outputs=true 分支一致），由随后的 commit 解析。
            lanes.out_vapor = _wx_next_vapor.data();
            lanes.out_cloud = _wx_next_cloud.data();
            lanes.out_cloud_water = _wx_next_cloud_water.data();
            lanes.out_precip = _wx_next_precip.data();
            lanes.out_instability = _wx_next_instability.data();
            lanes.out_intensity = _wx_next_intensity.data();
            lanes.out_convergence = _wx_next_convergence.data();
            lanes.out_type_i32 = _wx_next_type.data();
            lanes.out_type_u8 = nullptr;
            lanes.out_prev_type = nullptr;
            lanes.out_target_type = nullptr;
            lanes.out_alpha = nullptr;
            lanes.out_field_init = nullptr;

            pk_async_climate::WeatherFieldState state;
            state.conv_inhib =
                _weather_conv_inhib.size() == cells ? _weather_conv_inhib.data() : nullptr;
            // B8-2：worker 自持 cyclone —— 在生产同一位置、同一顺序（field solve 之前）
            // 推进已有条目并 stamp 当天的强迫 lane。PK_CLIMATE_CYCLONE_FORCE=1 用于
            // 特性默认关闭时的验证；生产配置走 capture 的 native_tropical_cyclone_enabled。
            static const bool cyclone_force_enabled = [] {
                const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_CYCLONE_FORCE);
                return value != nullptr && value[0] == '1';
            }();
            const bool cyclone_enabled_for_day =
                input.cyclone_enabled || cyclone_force_enabled;
            static std::atomic<int> s_cyc_gate_debug{2};
            if (s_cyc_gate_debug.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                    "[climate/worker][b8] cyclone_gate day=%lld input_enabled=%d "
                    "force_env=%d effective=%d\n",
                    static_cast<long long>(day),
                    input.cyclone_enabled ? 1 : 0, cyclone_force_enabled ? 1 : 0,
                    cyclone_enabled_for_day ? 1 : 0);
                std::fflush(stderr);
            }
            bool cyclone_lanes_ready = physics_cyclone_stamp_ready;
            if (cyclone_enabled_for_day && input.climate_worker_authoritative && !physics_owned) {
                if (_cyclone_force_tag.size() != cells) {
                    _cyclone_force_tag.assign(cells, 0u);
                    _cyclone_visit_tag.assign(cells, 0u);
                    _cyclone_force_x.assign(cells, 0.0f);
                    _cyclone_force_y.assign(cells, 0.0f);
                    _cyclone_lift.assign(cells, 0.0f);
                    _cyclone_force_generation = 1u;
                }
                if (++_cyclone_force_generation == 0u) {
                    std::fill(_cyclone_force_tag.begin(),
                              _cyclone_force_tag.end(), 0u);
                    std::fill(_cyclone_visit_tag.begin(),
                              _cyclone_visit_tag.end(), 0u);
                    _cyclone_force_generation = 1u;
                }
                if (wx.pos_x.size() == cells && wx.pos_y.size() == cells &&
                    wx.wind_x.size() == cells && wx.wind_y.size() == cells &&
                    wx.wind_speed.size() == cells && wx.temp_read.size() == cells &&
                    wx.terrain.size() == cells && neighbors.size() >= cells * 6u &&
                    next.vapor.size() == cells && next.instability.size() == cells) {
                    pk_async_climate::CycloneAdvanceKnobs cyc;
                    cyc.enabled = true;
                    cyc.dt_days = input.cyclone_dt_days;
                    cyc.world_bounds_pos_y = input.cyclone_world_bounds_pos_y;
                    cyc.world_bounds_size_y = input.cyclone_world_bounds_size_y;
                    cyc.wrap_width_x = input.cyclone_wrap_width_x;
                    cyc.max_radius_cells = input.cyclone_max_radius_cells;
                    pk_async_climate::CycloneLanes cyc_lanes;
                    cyc_lanes.neighbors = neighbors.data();
                    cyc_lanes.pos_x = wx.pos_x.data();
                    cyc_lanes.pos_y = wx.pos_y.data();
                    cyc_lanes.terrain = wx.terrain.data();
                    cyc_lanes.temp = wx.temp_read.data();
                    cyc_lanes.wind_x = wx.wind_x.data();
                    cyc_lanes.wind_y = wx.wind_y.data();
                    cyc_lanes.wind_speed = wx.wind_speed.data();
                    // 水汽和不稳定度仍取本次天气计算开始前的已提交值。
                    cyc_lanes.vapor = next.vapor.data();
                    cyc_lanes.instability = next.instability.data();
                    cyc_lanes.lat_norm = input.cell_lat_norm.size() == cells
                        ? input.cell_lat_norm.data() : nullptr;
                    pk_async_climate::CycloneStamp cyc_stamp;
                    cyc_stamp.force_tag = _cyclone_force_tag.data();
                    cyc_stamp.visit_tag = _cyclone_visit_tag.data();
                    cyc_stamp.force_x = _cyclone_force_x.data();
                    cyc_stamp.force_y = _cyclone_force_y.data();
                    cyc_stamp.lift = _cyclone_lift.data();
                    cyc_stamp.force_generation = _cyclone_force_generation;
                    cyc_stamp.visit_generation = _cyclone_force_generation;
                    pk_async_climate::CycloneStats cyc_stats;
                    pk_async_climate::cyclone_advance_and_stamp_pure(
                        static_cast<int>(cells), cyc, cyc_lanes,
                        _cyclone_entries, cyc_stamp, cyc_stats);
                    cyclone_lanes_ready = true;
                    report.cyclone_alive = cyc_stats.alive;
                    _physics.cyclone_total_decayed +=
                        static_cast<uint64_t>(std::max(0, cyc_stats.decayed));
                    report.cyclone_decayed =
                        static_cast<int32_t>(_physics.cyclone_total_decayed);
                    report.cyclone_touched = cyc_stats.touched_cells;
                    static std::atomic<int> s_cyclone_reports_left{24};
                    if (s_cyclone_reports_left.fetch_sub(
                            1, std::memory_order_relaxed) > 0) {
                        std::fprintf(stderr,
                            "[climate/worker][b8] cyclone day=%lld cells=%zu "
                            "entries=%zu alive=%d decayed=%d touched=%d gen=%u "
                            "int(before/after)=%.3f/%.3f\n",
                            static_cast<long long>(day), cells,
                            _cyclone_entries.size(), cyc_stats.alive,
                            cyc_stats.decayed, cyc_stats.touched_cells,
                            _cyclone_force_generation,
                            static_cast<double>(cyc_stats.entry_intensity_max_before),
                            static_cast<double>(cyc_stats.entry_intensity_max_after));
                        std::fflush(stderr);
                    }
                }
            }
            // B8-2：worker 自持 ψ。生产这次只提供冷启动种子；推进会覆盖它，所以
            // 一旦播种成功就只喂 worker 自己那份。SHADOW 保持与参考同源（用捕获的
            // 生产 tick），ACTIVE 用自己的单调 tick。
            // PK_CLIMATE_SYNOPTIC_OFF=1 复现 B8 之前的"无 ψ"路径，只用于 E6 归因
            // A/B（ψ 对降水/云量/水汽的贡献），不参与生产配置。
            static const bool synoptic_disabled = [] {
                const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_SYNOPTIC_OFF);
                return value != nullptr && value[0] == '1';
            }();
            bool worker_psi_ready = physics_owned && _physics.synoptic_seeded && wx.synoptic_enabled && !synoptic_disabled;
            if (!physics_owned && wx.synoptic_enabled && !synoptic_disabled) {
                if (_physics.synoptic_psi.size() != cells) {
                    _physics.synoptic_psi.assign(cells, 0.0f);
                    _physics.synoptic_psi_prev.assign(cells, 0.0f);
                    _physics.synoptic_seeded = false;
                }
                if (!_physics.synoptic_seeded && wx.psi.size() == cells) {
                    _physics.synoptic_psi = wx.psi;
                    if (wx.psi_prev.size() == cells) {
                        _physics.synoptic_psi_prev = wx.psi_prev;
                    }
                    _physics.synoptic_seeded = true;
                }
                if (!_physics.synoptic_seeded && input.climate_worker_authoritative) {
                    // ACTIVE 下主线程 weather 被抑制门关掉，`_wx_synoptic` 可能永远
                    // 不被构建（cap 里就是空 lane）。这时 worker 必须从零场冷启动
                    // 自持推进；否则 `_physics.synoptic_seeded` 永远为假，ψ 一天都不参与，
                    // 降水就少掉 syn_base_lift 这条最强驱动。
                    _physics.synoptic_seeded = true;
                }
                // SHADOW 只做忠实复刻：直接用生产当天 solve 读到的 ψ，不自己推进。
                // 自己的推进节拍与生产的内联推进不会逐位相同（tick 不同），在
                // SHADOW 里推一份只会把"节拍差"记成算法分叉。自持从 ACTIVE 开始。
                if (input.climate_worker_authoritative && _physics.synoptic_seeded &&
                    wx.wind_x.size() == cells &&
                    wx.wind_y.size() == cells &&
                    wx.temp_read.size() == cells &&
                    wx.pos_x.size() == cells && wx.pos_y.size() == cells &&
                    neighbors.size() >= cells * 6u) {
                    pk_async_climate::SynopticAdvanceKnobs syn = wx.synoptic;
                    syn.tick = static_cast<int>(++_physics.synoptic_tick);
                    pk_async_climate::synoptic_advance_pure(
                        static_cast<int>(cells), neighbors.data(),
                        wx.pos_x.data(), wx.pos_y.data(), wx.wind_x.data(),
                        wx.wind_y.data(), wx.temp_read.data(), syn,
                        _physics.synoptic_psi, _physics.synoptic_psi_prev);
                    worker_psi_ready = true;
                } else if (input.climate_worker_authoritative && _physics.synoptic_seeded) {
                    // 风/温度 lane 缺失时不能推进，但已播种的 ψ 仍比 nullptr 好：
                    // 内核走无 ψ 分支会直接丢掉 syn_base_lift 这条最强降水驱动。
                    worker_psi_ready = true;
                }
            }
            if (worker_psi_ready) {
                state.psi = _physics.synoptic_psi.data();
            } else {
                state.psi = (wx.synoptic_enabled && !synoptic_disabled &&
                             wx.psi.size() == cells)
                    ? wx.psi.data() : nullptr;
            }
            if (cyclone_lanes_ready) {
                // B8-2：worker 自持 cyclone 的 stamp 结果优先。生产条目表只在冷启动
                // 播种时读过一次；之后这几条 lane 完全由 worker 推进。
                state.cyclone_tag = _cyclone_force_tag.data();
                state.cyclone_tag_count = static_cast<int>(cells);
                state.cyclone_generation = _cyclone_force_generation;
                state.cyclone_lift = _cyclone_lift.data();
                state.cyclone_x = _cyclone_force_x.data();
                state.cyclone_y = _cyclone_force_y.data();
            } else if (wx.cyclone_tag.size() == cells) {
                state.cyclone_tag = wx.cyclone_tag.data();
                state.cyclone_tag_count = static_cast<int>(cells);
                state.cyclone_generation = wx.cyclone_generation;
                state.cyclone_lift =
                    lane_ok(wx.cyclone_lift) ? wx.cyclone_lift.data() : nullptr;
                state.cyclone_x = lane_ok(wx.cyclone_x) ? wx.cyclone_x.data() : nullptr;
                state.cyclone_y = lane_ok(wx.cyclone_y) ? wx.cyclone_y.data() : nullptr;
            }
            if (lane_ok(wx.monsoon_thermal)) {
                state.monsoon_thermal = wx.monsoon_thermal.data();
                state.monsoon_thermal_count = static_cast<int>(cells);
            }
            if (wx.traj_idx.size() == cells * 3u && wx.traj_w.size() == cells * 3u) {
                state.traj_idx = wx.traj_idx.data();
                state.traj_w = wx.traj_w.data();
            }
            // Derived only from these four inputs, including on a replay or
            // when the worker briefly switches back to captured weather data.
            if (_weather_geom_neighbors != neighbors ||
                    !same_float_bits(_weather_geom_pos_x, wx.pos_x) ||
                    !same_float_bits(_weather_geom_pos_y, wx.pos_y) ||
                    std::memcmp(&_weather_geom_wrap, &knobs.weather_wrap_width_x,
                        sizeof(_weather_geom_wrap)) != 0) {
                const size_t geom_n = cells * 6u;
                _weather_geom_dx.resize(geom_n);
                _weather_geom_dy.resize(geom_n);
                _weather_geom_invd.resize(geom_n);
                pk_async_climate::weather_field_geometry_cache_pure(
                    static_cast<int>(cells), neighbors.data(), wx.pos_x.data(),
                    wx.pos_y.data(), knobs.weather_wrap_width_x,
                    _weather_geom_dx.data(), _weather_geom_dy.data(),
                    _weather_geom_invd.data());
                _weather_geom_neighbors = neighbors;
                _weather_geom_pos_x = wx.pos_x;
                _weather_geom_pos_y = wx.pos_y;
                _weather_geom_wrap = knobs.weather_wrap_width_x;
            }
            state.geom_dx = _weather_geom_dx.data();
            state.geom_dy = _weather_geom_dy.data();
            state.geom_invd = _weather_geom_invd.data();

            // The staged solve reads frozen neighbors and writes only the
            // current cell, including its convection inhibition value.
            pk::parallel_for_range("pk_weather_field", static_cast<int>(cells),
                0, 2048, [&](int begin, int end) {
                    pk_async_climate::weather_field_solve_pure(knobs, lanes, state, begin, end);
                });

            // weather_commit：把 next buffer 落到 store，并解析 display_type /
            // transition 三条 / field_init。生产 native daily 的 weather_commit 节点
            // 做的就是这件事，走的是同一份 weather_commit_pure。
            pk_async_climate::WeatherCommitKnobs ck;
            ck.n_cells                    = static_cast<int>(cells);
            ck.refresh_convergence        = false;   // 不需要 delta 报告
            ck.weather_transition_enabled = wx.knobs.weather_transition_enabled;
            ck.transition_rate            = wx.knobs.weather_transition_alpha_rate;
            ck.transition_dt_days         = wx.knobs.weather_transition_dt_days;
            ck.lut_slots                  = 0;

            pk_async_climate::WeatherCommitLanes cl;
            cl.next_vapor        = _wx_next_vapor.data();
            cl.next_cloud        = _wx_next_cloud.data();
            cl.next_cloud_water  = _wx_next_cloud_water.data();
            cl.next_precip       = _wx_next_precip.data();
            cl.next_instability  = _wx_next_instability.data();
            cl.next_intensity    = _wx_next_intensity.data();
            cl.next_convergence  = _wx_next_convergence.data();
            cl.next_type         = _wx_next_type.data();
            cl.prev_vapor        = _weather_prev_vapor.data();
            cl.neighbor_indices  = neighbors.data();
            cl.intensity         = next.weather_intensity.data();
            cl.cloud             = next.cloud_cover.data();
            cl.cloud_water       = next.cloud_water.data();
            cl.precip            = next.weather_precipitation.data();
            cl.vapor             = next.vapor.data();
            cl.convergence       = next.convergence.data();
            cl.instability       = next.instability.data();
            cl.type              = next.weather_type.data();
            cl.prev_type         = next.weather_prev_type.data();
            cl.target_type       = next.weather_target_type.data();
            cl.transition_alpha  = next.weather_transition_alpha.data();
            cl.field_init        = _weather_field_init_scratch.data();
            cl.dirty             = _weather_dirty_scratch.data();
            cl.lut               = nullptr;
            cl.convergence_deltas = nullptr;

            pk_async_climate::WeatherCommitStats cs;
            pk_async_climate::weather_commit_pure(ck, cl, cs);

            // B8-2 genesis（出生）：与生产 native-entity 路径同一位置（field solve /
            // commit / distribute 之后的当天后段），但判据改用 worker 自己的状态：
            // 前沿等价物 = 当天 weather_type == STORM 且 intensity 过门的格子。
            // 只在 ACTIVE 下注入：SHADOW 必须保持"复刻生产前沿路径"，否则对拍会
            // 把两套 genesis 规则的差记录成算法分叉。
            if (input.climate_worker_authoritative && cyclone_enabled_for_day &&
                input.cyclone_storm_type_id >= 0 &&
                next.weather_type.size() == cells &&
                next.weather_intensity.size() == cells &&
                next.weather_precipitation.size() == cells &&
                next.cloud_cover.size() == cells &&
                next.instability.size() == cells &&
                next.temperature.size() == cells) {
                const auto &water_ids =
                    input.climate_round_static_knobs.water_terrain_ids;
                if (water_ids.size() > 0u && wx.terrain.size() == cells &&
                    wx.pos_x.size() == cells && wx.pos_y.size() == cells &&
                    wx.wind_x.size() == cells && wx.wind_y.size() == cells &&
                    neighbors.size() >= cells * 6u) {
                    uint8_t water_lut[256] = {};
                    for (size_t k = 0; k < water_ids.size(); ++k) {
                        const uint8_t wid = water_ids[k];
                        water_lut[wid] = 1u;
                    }
                    pk_async_climate::CycloneGenesisKnobs gen;
                    gen.enabled = true;
                    gen.storm_type_id = input.cyclone_storm_type_id;
                    gen.capacity = input.cyclone_capacity;
                    gen.births_per_commit = input.cyclone_births_per_commit;
                    gen.min_temp = input.cyclone_min_temp;
                    gen.min_instability = input.cyclone_min_instability;
                    gen.max_shear = input.cyclone_max_shear;
                    gen.min_lat = input.cyclone_min_lat;
                    gen.max_lat = input.cyclone_max_lat;
                    gen.world_bounds_pos_y = input.cyclone_world_bounds_pos_y;
                    gen.world_bounds_size_y = input.cyclone_world_bounds_size_y;
                    gen.wake_days = input.cyclone_wake_days;
                    // 出生强度门 = 生产 native-entity 路径的硬编码 0.8（front
                    // intensity 就是 cluster 内最大 cell intensity，与之同源）。
                    // PK_CLIMATE_CYCLONE_GENESIS_GATE 只用于验证/归因 A/B：默认
                    // 世界里热带水格年峰值 ≈0.76，正好压在 0.8 之下，gate 不降就
                    // 拿不到"出生→推进→stamp→回灌→持久化"这条链路的实证。
                    static const float genesis_gate_override = [] {
                        const char *value =
                            pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_CYCLONE_GENESIS_GATE);
                        return value != nullptr ? std::strtof(value, nullptr) : 0.0f;
                    }();
                    if (genesis_gate_override > 0.0f && genesis_gate_override < 1.0f) {
                        gen.intensity_gate = genesis_gate_override;
                    }
                    pk_async_climate::CycloneGenesisLanes gen_lanes;
                    gen_lanes.terrain = wx.terrain.data();
                    gen_lanes.water_lut = water_lut;
                    gen_lanes.weather_type = next.weather_type.data();
                    gen_lanes.weather_intensity = next.weather_intensity.data();
                    gen_lanes.temp = next.temperature.data();
                    gen_lanes.precip = next.weather_precipitation.data();
                    gen_lanes.cloud = next.cloud_cover.data();
                    gen_lanes.instability = next.instability.data();
                    gen_lanes.wind_x = wx.wind_x.data();
                    gen_lanes.wind_y = wx.wind_y.data();
                    gen_lanes.wind_speed = wx.wind_speed.data();
                    gen_lanes.pos_x = wx.pos_x.data();
                    gen_lanes.pos_y = wx.pos_y.data();
                    gen_lanes.wrap_width_x = input.cyclone_wrap_width_x;
                    gen_lanes.lat_norm = input.cell_lat_norm.size() == cells
                        ? input.cell_lat_norm.data() : nullptr;
                    gen_lanes.neighbors = neighbors.data();
                    gen_lanes.is_water = input.is_water.size() == cells
                        ? input.is_water.data() : nullptr;
                    pk_async_climate::CycloneGenesisStats gen_stats;
                    pk_async_climate::cyclone_genesis_pure(
                        static_cast<int>(cells), gen, gen_lanes,
                        _cyclone_entries, _cyclone_next_stable_id, gen_stats);
                    // 纬度漏斗诊断：genesis 全部堵在 lat 闸时，必须能区分「世界
                    // 边界没送到」与「候选确实都在带外」。lat_norm 存在时应走
                    // 规范纬度（赤道=0.5），打印两次即封顶。
                    static std::atomic<int> s_cyclone_lat_reports_left{2};
                    if (s_cyclone_lat_reports_left.fetch_sub(
                            1, std::memory_order_relaxed) > 0) {
                        float ny_min = 1e30f, ny_max = -1e30f;
                        float lat_min = 1e30f, lat_max = -1e30f;
                        const float wb_h = std::max(0.001f, gen.world_bounds_size_y);
                        for (size_t i = 0; i < cells; ++i) {
                            if (water_lut[wx.terrain[i]] == 0u) continue;
                            const float ny = dc_clampf(
                                (wx.pos_y[i] - gen.world_bounds_pos_y) / wb_h,
                                0.0f, 1.0f);
                            ny_min = std::min(ny_min, ny);
                            ny_max = std::max(ny_max, ny);
                            const float abs_lat = gen_lanes.lat_norm != nullptr
                                ? std::abs((dc_clampf(gen_lanes.lat_norm[i], 0.0f, 1.0f) -
                                            0.5f) * 2.0f)
                                : std::abs((ny - 0.5f) * 2.0f);
                            lat_min = std::min(lat_min, abs_lat);
                            lat_max = std::max(lat_max, abs_lat);
                        }
                        std::fprintf(stderr,
                            "[climate/worker][b8] cyclone_lat day=%lld wb_y=%.3f "
                            "wb_h=%.3f water_ny=[%.3f,%.3f] abs_lat=[%.3f,%.3f] "
                            "lat_norm=%d band=[%.3f,%.3f]\n",
                            static_cast<long long>(day),
                            static_cast<double>(gen.world_bounds_pos_y),
                            static_cast<double>(gen.world_bounds_size_y),
                            static_cast<double>(ny_min), static_cast<double>(ny_max),
                            static_cast<double>(lat_min), static_cast<double>(lat_max),
                            gen_lanes.lat_norm != nullptr ? 1 : 0,
                            static_cast<double>(gen.min_lat),
                            static_cast<double>(gen.max_lat));
                        std::fflush(stderr);
                    }
                    if (gen_stats.injected > 0 || gen_stats.replaced > 0) {
                        _cyclone_seeded = true;
                    }
                    _physics.cyclone_total_injected +=
                        static_cast<uint64_t>(std::max(0, gen_stats.injected));
                    _physics.cyclone_total_replaced +=
                        static_cast<uint64_t>(std::max(0, gen_stats.replaced));
                    report.cyclone_injected =
                        static_cast<int32_t>(_physics.cyclone_total_injected);
                    report.cyclone_replaced =
                        static_cast<int32_t>(_physics.cyclone_total_replaced);
                    report.cyclone_alive = gen_stats.alive;
                    static std::atomic<int> s_cyclone_genesis_reports_left{24};
                    if (s_cyclone_genesis_reports_left.fetch_sub(
                            1, std::memory_order_relaxed) > 0) {
                        std::fprintf(stderr,
                            "[climate/worker][b8] cyclone_genesis day=%lld "
                            "injected=%d replaced=%d alive=%d "
                            "water=%d lat=%d phys=%d inten=%d shear=%d "
                            "storm_type=%d fail(t/p/c/i)=%d/%d/%d/%d "
                            "max(p/c/i/conv)=%.3f/%.3f/%.3f/%.3f "
                            "max_int=%.3f\n",
                            static_cast<long long>(day), gen_stats.injected,
                            gen_stats.replaced, gen_stats.alive,
                            gen_stats.cand_water, gen_stats.cand_lat,
                            gen_stats.cand_physical, gen_stats.cand_intensity,
                            gen_stats.cand_shear,
                            gen_stats.type_storm,
                            gen_stats.fail_temp, gen_stats.fail_precip,
                            gen_stats.fail_cloud, gen_stats.fail_instability,
                            static_cast<double>(gen_stats.max_precip),
                            static_cast<double>(gen_stats.max_cloud),
                            static_cast<double>(gen_stats.max_instability),
                            static_cast<double>(gen_stats.max_convergence),
                            static_cast<double>(gen_stats.max_intensity));
                        std::fflush(stderr);
                    }
                }
            }
            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
            // B8 诊断：确认 weather field solve 真的产出非零场。headless soak 里
            // 如果这一行全零，问题在输入 lane 或 solve 资格，而不是 writeback。
            static std::atomic<int> s_weather_solve_reports_left{4};
            if (s_weather_solve_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                    "[climate/worker][b8] weather_solve day=%lld cells=%zu psi=%d "
                    "vapor0=%.6g precip0=%.6g cloud0=%.6g type0=%u field_init0=%u\n",
                    static_cast<long long>(day), cells,
                    state.psi != nullptr ? 1 : 0,
                    next.vapor.empty() ? 0.0f : next.vapor[0],
                    next.weather_precipitation.empty() ? 0.0f : next.weather_precipitation[0],
                    next.cloud_cover.empty() ? 0.0f : next.cloud_cover[0],
                    next.weather_type.empty() ? 0u : next.weather_type[0],
                    _weather_field_init_scratch.empty() ? 0u : _weather_field_init_scratch[0]);
                std::fflush(stderr);
            }
            return static_cast<uint64_t>(cells) * 6u;
        });
    }

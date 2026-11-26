bool RuntimeClimateKernel::self_test(std::string &error) {
    {
        // A coordinate just below a bin edge rounds onto that edge at single
        // precision. The captured script path must retain the double result.
        const std::vector<float> temperature{0.25f, 0.875f, 0.5f};
        const std::vector<double> pos{0.5, 8.0 - 1.0e-8, 23.5};
        const std::vector<float> rounded_pos(pos.begin(), pos.end());
        if (thermal_equator_lat_norm(temperature, pos, 0.0, 24.0, 0.5) != 7.5 / 24.0 ||
            thermal_equator_lat_norm(temperature, rounded_pos, 0.0f, 24.0f, 0.5f) != 8.5f / 24.0f ||
            thermal_equator_lat_norm(temperature, pos, 0.0, 0.0, 0.25) != 0.25) {
            error = "climate_weather_thermal_equator_precision";
            return false;
        }
    }
    {
        RuntimeEnvironmentSnapshot input;
        input.cell_temp = {0.0f, 0.0f, 0.0f};
        const uint64_t original = input_hash(input);
        input.cell_temp.front() = -0.0f;
        const bool first_word_changed = input_hash(input) != original;
        input.cell_temp.front() = 0.0f;
        input.cell_temp.back() = 0.5f;
        const bool tail_changed = input_hash(input) != original;
        input.cell_temp.back() = 0.0f;
        input.cell_temp.pop_back();
        if (!first_word_changed || !tail_changed || input_hash(input) == original) {
            error = "climate_input_hash_missing_word_tail_or_length";
            return false;
        }
    }
    // 驻留缓存与完整解码逐日对拍，覆盖空闲日、海陆翻转、邻接、坐标与轨迹参数变化。
    {
        constexpr int n = 4;
        RuntimeEnvironmentSnapshot in;
        in.generation = 1; in.cell_count = n; in.day = 0;
        in.climate_catalog_hash = 7;
        in.climate_worker_authoritative = true;
        in.terrain = {1, 0, 0, 1}; in.is_water = {0, 1, 1, 0};
        in.landform.assign(n, 0);
        in.cell_temp.assign(n, 0.5f); in.cell_moisture.assign(n, 0.5f);
        in.cell_plant_available_water.assign(n, 0.5f);
        in.cell_pos_x = {0, 1, 2, 3}; in.cell_pos_y.assign(n, 0.5f);
        in.cell_lat_norm.assign(n, 0.5f); in.cell_elevation.assign(n, 0.1f);
        in.cell_temperature_transport_anomaly.assign(n, 0.0f);
        in.cell_wind_x.assign(n, 1.0f); in.cell_wind_y.assign(n, 0.0f);
        in.cell_wind_speed.assign(n, 0.5f);
        in.cell_ocean_current_x.assign(n, 0.0f); in.cell_ocean_current_y.assign(n, 0.0f);
        in.neighbor_indices.assign(n * 6, -1);
        for (int i = 0; i < n; ++i) {
            if (i > 0) in.neighbor_indices[i * 6] = i - 1;
            if (i + 1 < n) in.neighbor_indices[i * 6 + 1] = i + 1;
        }
        auto &k = in.climate_physics_knobs;
        k.enabled = true; k.ready = 1; k.water_id_count = 4;
        k.water_terrain_ids = {0, 3, 4, 5};
        k.land_lf_mountain = 1; k.land_lf_peak = 2; k.land_lf_hill = 3;
        k.wind_traj_table_enabled = 1; k.wind_momentum_advect_w = 0.1f;
        k.daily_period_days = 2;
        RuntimeClimateKernel cached;
        RuntimeClimateStore current, next;
        current.reset(n); next.reset(n); current.terrain = in.terrain;
        RuntimeClimateCatalog catalog;
        if (!cached.compile_catalog(in, catalog, error)) return false;
        for (int day = 0; day < 20; ++day) {
            in.day = day; ++in.generation;
            if (day == 2) { current.terrain[1] = 3; in.terrain[1] = 3; }
            if (day == 3) { current.terrain[3] = 2; in.terrain[3] = 2; }
            if (day == 4) { current.terrain[0] = 0; in.terrain[0] = 0; }
            if (day == 6) in.neighbor_indices[1] = 2;
            if (day == 8) in.cell_pos_x[1] = 1.25f;
            if (day == 10) k.wind_traj_dt_days = 12.0f;
            if (day == 12) k.wrap_period_x = 4.0;
            if (day == 14) k.water_terrain_ids[1] = 1;
            RuntimeClimateKernel reference = cached;
            RuntimeClimateStore expected = next;
            RuntimeClimateKernelReport got_report, expected_report;
            if (!cached.plan_day(day, in, catalog, current, next, got_report, false, false, true) ||
                !reference.plan_day(day, in, catalog, current, expected, expected_report, false, false, false) ||
                next.state_hash() != expected.state_hash() ||
                cached._physics.wind_traj_idx != reference._physics.wind_traj_idx ||
                cached._physics.wind_traj_w != reference._physics.wind_traj_w ||
                cached._physics.coast_dist != reference._physics.coast_dist ||
                cached._physics.cell_to_water != reference._physics.cell_to_water) {
                error = "climate_resident_cache_invalidation_mismatch:" + std::to_string(day) +
                    ":" + got_report.error + ":" + expected_report.error;
                return false;
            }
            commit(current, next);
            cached.accept_committed_physics(current);
            auto physics = cached.copy_physics_writeback(current);
            pk_async_physics::RuntimeClimatePhysicsState decoded;
            if (!physics || !pk_async_physics::restore_physics_state(
                    current.physics_state.data(), current.physics_state.size(), decoded, error) ||
                !decoded.initialized || physics->state_hash() != decoded.state_hash() ||
                !physics->wind_display_signature || !reference._physics.wind_display_signature ||
                physics->wind_display_signature->words != reference._physics.wind_display_signature->words ||
                !physics->wind_traj_valid ||
                physics->wind_traj_generation != decoded.wind_traj_generation) {
                error = "climate_physics_writeback_mismatch:" + std::to_string(day);
                return false;
            }
            auto old_idx = physics->wind_traj_idx;
            auto old_weights = physics->wind_traj_w;
            const pk_async_physics::WindTrajKnobs knobs{
                k.wrap_period_x, k.wind_traj_pos_scale, k.wind_traj_dt_days};
            const pk_async_physics::WindTrajLanes lanes{
                in.cell_pos_x.data(), in.cell_pos_y.data(), in.neighbor_indices.data(),
                decoded.wind_x.data(), decoded.wind_y.data(), decoded.wind_speed.data(),
                old_idx.data(), old_weights.data()};
            pk_async_physics::wind_traj_build_range(n, 0, n, knobs, lanes);
            if (old_idx != physics->wind_traj_idx ||
                !same_float_bits(old_weights, physics->wind_traj_w)) {
                error = "climate_wind_writeback_mismatch:" + std::to_string(day);
                return false;
            }
            if (day == 16) {
                cached.invalidate_committed_physics();
                if (cached.copy_physics_writeback(current)) {
                    error = "climate_invalidated_physics_writeback_available";
                    return false;
                }
            }
        }
    }
    {
        RuntimeClimateStore source;
        source.reset(3);
        source.generation = 1;
        source.history_cursor = 350; // 很快跨过第 365 行。
        RuntimeClimateStore copied = source;
        for (uint64_t step = 1; step <= 400; ++step) {
            if (step == 300) {
                source.reset(3); // 跨恢复/新世界，禁止用旧缓冲的历史。
                std::fill(source.temperature_history.begin(), source.temperature_history.end(), 0.25f);
            }
            source.generation += step == 200 ? 400 : 1;
            source.committed_day = static_cast<int64_t>(step);
            if (step % 3 != 0) {
                const size_t offset = static_cast<size_t>(source.history_cursor) * source.cell_count;
                std::fill_n(source.temperature_history.begin() + offset, source.cell_count,
                    static_cast<float>(step) / 500.0f);
                source.history_cursor = (source.history_cursor + 1u) % 365u;
            }
            if (step % 4 == 0) continue; // 模拟发布槽落后多轮。
            if (step == 89) {
                copied.generation = source.generation + 1; // speculative retry。
                copied.temperature_history[0] = -1.0f;
            }
            copy_store_lanes(copied, source, true);
            if (copied.state_hash() != source.state_hash()) {
                error = "climate_incremental_history_copy_mismatch";
                return false;
            }
        }
        source.physics_state = {1, 2, 3};
        source.cyclone_state = {4, 5};
        RuntimeClimateStore visible;
        copy_visible_store(visible, source);
        if (!visible.temperature_history.empty()) {
            error = "climate_visible_snapshot_copied_private_history";
            return false;
        }
        visible.temperature_history = source.temperature_history;
        if (visible.state_hash() != source.state_hash()) {
            error = "climate_visible_snapshot_lost_public_fields";
            return false;
        }
    }
    if (!climate_formula::self_test()) {
        error = "climate_formula_self_test_failed";
        return false;
    }
    // B8-2：cyclone 纯内核自检。7 个连成一行的水格，1 个气旋条目；验证
    //   1. 推进改变 intensity / age；
    //   2. stamp 写出 tag/x/y/lift，且 force_generation 逐位落到 tag；
    //   3. encode→decode 往返保持条目字段与 next_stable_id。
    {
        constexpr int kCells = 7;
        std::vector<int32_t> neighbors(static_cast<size_t>(kCells) * 6u, -1);
        for (int i = 0; i < kCells; ++i) {
            neighbors[static_cast<size_t>(i) * 6u + 0u] = (i > 0) ? i - 1 : -1;
            neighbors[static_cast<size_t>(i) * 6u + 1u] = (i + 1 < kCells) ? i + 1 : -1;
        }
        std::vector<float> pos_x(kCells), pos_y(kCells, 0.0f);
        std::vector<uint8_t> terrain(kCells, 0u);
        std::vector<float> temp(kCells, 0.90f), wind_x(kCells, 1.0f);
        std::vector<float> wind_y(kCells, 0.0f), wind_speed(kCells, 0.80f);
        std::vector<float> vapor(kCells, 0.85f), instability(kCells, 0.80f);
        for (int i = 0; i < kCells; ++i) pos_x[static_cast<size_t>(i)] = float(i);
        pk_async_climate::CycloneAdvanceKnobs knobs;
        knobs.enabled = true;
        knobs.dt_days = 1.0f;
        knobs.world_bounds_pos_y = 0.0f;
        knobs.world_bounds_size_y = 1.0f;
        knobs.wrap_width_x = 0.0f;
        knobs.max_radius_cells = 4;
        pk_async_climate::CycloneLanes lanes;
        lanes.neighbors = neighbors.data();
        lanes.pos_x = pos_x.data();
        lanes.pos_y = pos_y.data();
        lanes.terrain = terrain.data();
        lanes.temp = temp.data();
        lanes.wind_x = wind_x.data();
        lanes.wind_y = wind_y.data();
        lanes.wind_speed = wind_speed.data();
        lanes.vapor = vapor.data();
        lanes.instability = instability.data();
        std::vector<uint32_t> tag(kCells, 0u), visit(kCells, 0u);
        std::vector<float> fx(kCells, 0.0f), fy(kCells, 0.0f), lift(kCells, 0.0f);
        pk_async_climate::CycloneStamp stamp;
        stamp.force_tag = tag.data();
        stamp.visit_tag = visit.data();
        stamp.force_x = fx.data();
        stamp.force_y = fy.data();
        stamp.lift = lift.data();
        stamp.force_generation = 1u;
        stamp.visit_generation = 1u;
        std::vector<pk_async_climate::CycloneEntry> entries(1);
        entries[0].stable_id = 7u;
        entries[0].key = 12;
        entries[0].cell_idx = 3;
        entries[0].intensity = 0.35f;
        entries[0].steering_x = 1.0f;
        entries[0].steering_y = 0.0f;
        pk_async_climate::CycloneStats stats;
        pk_async_climate::cyclone_advance_and_stamp_pure(
            kCells, knobs, lanes, entries, stamp, stats);
        if (entries.empty() || entries[0].age_days <= 0.0f) {
            error = "cyclone_kernel_advance_failed";
            return false;
        }
        bool stamped = false;
        for (int i = 0; i < kCells; ++i) {
            if (tag[static_cast<size_t>(i)] == 1u) {
                stamped = true;
                break;
            }
        }
        if (!stamped || stats.touched_cells <= 0) {
            error = "cyclone_kernel_stamp_failed";
            return false;
        }
        const std::vector<uint8_t> blob =
            pk_async_climate::cyclone_state_encode(entries, 9u);
        std::vector<pk_async_climate::CycloneEntry> decoded;
        uint64_t decoded_next = 0;
        pk_async_climate::cyclone_state_decode(blob, decoded, decoded_next);
        if (decoded.size() != entries.size() || decoded_next != 9u ||
            decoded[0].stable_id != entries[0].stable_id ||
            decoded[0].cell_idx != entries[0].cell_idx ||
            decoded[0].intensity != entries[0].intensity ||
            decoded[0].age_days != entries[0].age_days) {
            error = "cyclone_state_codec_failed";
            return false;
        }
        // 气旋生成自检：第一次最多注入两个，第二次只刷新同键气旋。
        {
            constexpr int kGenCells = 3;
            uint8_t water_lut[256] = {};
            water_lut[0] = 1u;
            std::vector<uint8_t> gen_terrain(kGenCells, 0u);
            std::vector<uint8_t> gen_is_water(kGenCells, 1u);
            std::vector<uint8_t> gen_type(kGenCells, 2u);
            std::vector<float> gen_intensity(kGenCells, 0.90f);
            std::vector<float> gen_temp(kGenCells, 0.90f);
            std::vector<float> gen_precip(kGenCells, 0.20f);
            std::vector<float> gen_cloud(kGenCells, 0.50f);
            std::vector<float> gen_inst = {0.60f, 0.10f, 0.10f};
            std::vector<float> gen_posx = {0.0f, 1.0f, 2.0f};
            std::vector<float> gen_wx(kGenCells, 1.0f);
            std::vector<float> gen_wy(kGenCells, 0.0f);
            std::vector<float> gen_posy = {0.35f, 0.35f, 0.35f};
            std::vector<int32_t> gen_nb(static_cast<size_t>(kGenCells) * 6u, -1);
            gen_nb[0] = 1; gen_nb[6] = 0; gen_nb[7] = 2; gen_nb[12] = 1;
            pk_async_climate::CycloneGenesisKnobs gen;
            gen.enabled = true;
            gen.storm_type_id = 2;
            gen.capacity = 4;
            gen.births_per_commit = 2;
            gen.world_bounds_pos_y = 0.0f;
            gen.world_bounds_size_y = 1.0f;
            pk_async_climate::CycloneGenesisLanes gen_lanes;
            gen_lanes.terrain = gen_terrain.data();
            gen_lanes.water_lut = water_lut;
            gen_lanes.weather_type = gen_type.data();
            gen_lanes.weather_intensity = gen_intensity.data();
            gen_lanes.temp = gen_temp.data();
            gen_lanes.precip = gen_precip.data();
            gen_lanes.cloud = gen_cloud.data();
            gen_lanes.instability = gen_inst.data();
            gen_lanes.pos_x = gen_posx.data();
            gen_lanes.wind_x = gen_wx.data();
            gen_lanes.wind_y = gen_wy.data();
            gen_lanes.pos_y = gen_posy.data();
            gen_lanes.neighbors = gen_nb.data();
            gen_lanes.is_water = gen_is_water.data();
            std::vector<pk_async_climate::CycloneEntry> gen_entries;
            uint64_t gen_next_id = 1;
            pk_async_climate::CycloneGenesisStats gen_stats;
            pk_async_climate::cyclone_genesis_pure(kGenCells, gen, gen_lanes,
                                                  gen_entries, gen_next_id,
                                                  gen_stats);
            // 水格 1 和 2 靠原向内风评分达标，尽管不稳定度不足。
            if (gen_stats.injected != 2 || gen_entries.size() != 2u ||
                gen_next_id != 3u || gen_stats.cand_water != 3 ||
                gen_stats.cand_shear != 3 || gen_entries[0].cell_idx != 0 ||
                gen_entries[1].cell_idx != 1) {
                error = "cyclone_genesis_inject_failed";
                return false;
             }
            // 第二次调用把容量压到已满：同键（0/1）刷新，第 3 格因容量被挡住。
            gen.capacity = 2;
            pk_async_climate::cyclone_genesis_pure(kGenCells, gen, gen_lanes,
                                                  gen_entries, gen_next_id,
                                                  gen_stats);
            if (gen_stats.injected != 0 || gen_stats.replaced != 2 ||
                gen_entries.size() != 2u) {
                error = "cyclone_genesis_replace_failed";
                return false;
            }
        }
    }
    // B8 P0：顺序契约是 kernel 的一部分，随 self_test 一起跑。表本身错了
    // （漏 stage / 重复 / fallback tail 不在尾部）时不必等到 plan_day。
    std::string order_error;
    if (!runtime_climate_stage_order_self_test(order_error)) {
        error = "climate_kernel_stage_order_contract_failed:" + order_error;
        return false;
    }
    RuntimeEnvironmentSnapshot input;
    input.generation = 1;
    input.day = 0;
    input.cell_count = 2;
    input.climate_catalog_hash = 7;
    input.cell_temp = {15.0f, -8.0f};
    input.cell_moisture = {0.5f, 0.25f};
    input.cell_plant_available_water = {0.7f, 0.2f};
    input.terrain = {1, 0};
    input.is_water = {0, 1};
    input.neighbor_offsets = {0, 1, 2};
    input.neighbor_indices = {1, 0};
    RuntimeClimateStore current;
    RuntimeClimateStore next;
    current.reset(2);
    next.reset(2);
    RuntimeClimateCatalog catalog;
    RuntimeClimateKernel kernel;
    if (!kernel.compile_catalog(input, catalog, error)) return false;
    RuntimeClimateKernelReport report;
    if (!kernel.plan_day(0, input, catalog, current, next, report) || !report.completed) {
        error = report.error;
        return false;
    }
    // 执行序必须与声明序一致。位掩码只能证明 stage 跑过，证明不了顺序。
    if (!runtime_climate_stage_sequence_is_canonical(
            report.stage_sequence.data(), report.stage_sequence_count,
            order_error)) {
        error = "climate_kernel_stage_sequence_contract_failed:" + order_error;
        return false;
    }
    commit(current, next);
    if (current.committed_day != 0 || current.state_hash() != report.state_hash || report.work_units == 0) {
        error = "climate_kernel_self_test_state_invalid";
        return false;
    }
    return true;
}

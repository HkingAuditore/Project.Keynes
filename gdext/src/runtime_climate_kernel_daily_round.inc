    const size_t cells = current.cell_count;
    const float season = static_cast<float>(input.season_phase);
    // The capture boundary carries the actual logical-day delta. Clamping to
    // one day here silently slowed stride/fast-forward runs and made EMA,
    // transition, hydrology and sea-ice state depend on call frequency.
    const float dt = std::clamp(input.dt_days, 1.0f,
                                std::max(1.0f, catalog.dt_days_cap));

    // S3（断点 2）：优先走生产共享纯内核。round_in 由主线程 capture 时用
    // DCWorldExt::fill_climate_round_input 填好，与 async_climate_round_kick 走同
    // 一段提取代码，所以 worker 与生产 round 吃的是逐位相同的输入。
    //
    // n_cells 不匹配（旧 harness / 稀疏 fixture / 未接线的地图）时退回下面的诊断
    // 近似实现。这条回退路径不具备 parity 语义，只用于让 SHADOW 诊断不中断。
    const pk_async_climate::ClimateInputBuf &round_in = input.climate_round_input;
    const bool shared_passes_available =
        input.climate_round_ran &&
        round_in.n_cells > 0 && static_cast<size_t>(round_in.n_cells) == cells;

    // ─── 共享 round：9 个 pass 一次跑完（生产用的同一份编排 + 同一份内核）────
    //
    // 覆盖 stage PASS_A..TRANSPIRATION。这里刻意不逐 stage 分别调用内核：pass 之间
    // 的 in←out 接力字段是编排的一部分，拆开调用就等于在 worker 里重写一遍顺序。
    //
    // shared_passes_available 为假时（旧 harness / 未接线的地图）落到下面的诊断近似，
    // 那条路径没有 parity 语义，只保证 SHADOW 诊断不中断。
    bool shared_round_ran = false;
    if (shared_passes_available) {
        _round_in = round_in;   // 编排在 in 上做接力，必须给它可变副本
        if (physics_owned) {
            _round_in.wind_x = _physics.wind_x; _round_in.wind_y = _physics.wind_y;
            _round_in.wind_speed = _physics.wind_speed;
            _round_in.ocean_current_x = _physics.ocean_current_x;
            _round_in.ocean_current_y = _physics.ocean_current_y;
            _round_in.upwelling_strength = _physics.upwelling;
            _round_in.wind_traj_idx.clear(); _round_in.wind_traj_w.clear();
            if (input.climate_physics_knobs.wind_traj_weather_share && _physics.wind_traj_valid) {
                _round_in.wind_traj_idx = _physics.wind_traj_idx;
                _round_in.wind_traj_w = _physics.wind_traj_w;
            }
        }
        // water terrain LUT 走 static knobs（它不是 per-cell lane，capture 的 slot 兜底
        // 覆盖不到）。round input 里没带时从 static knobs 补，否则 sea_ice 会饿死。
        if (_round_in.water_terrain_ids.empty()) {
            _round_in.water_terrain_ids =
                input.climate_round_static_knobs.water_terrain_ids;
        }
        // ABI 8：ACTIVE 下 MapData terrain 被冻结，round 必须吃 worker 自持副本，
        // 否则海冰翻转无法跨天累积。
        if (next.terrain.size() == cells) {
            _round_in.terrain = next.terrain;
        }
        // 海冰同理：capture 抓的是主线程 slot，而回灌落后于流水线中的 worker 若干天，
        // 用它当起点会让多天从同一个旧值起算，冰的累积按流水线深度被摊薄。
        if (input.climate_worker_authoritative && next.sea_ice.size() == cells) {
            _round_in.sea_ice_frac = next.sea_ice;
            _round_in.sea_ice_frac_inout = next.sea_ice;
        }
        // 其余有 store 成员的跨天 lane 同一条理由。锁步下 slot 恰好等于昨天回灌的
        // store，这里是 no-op；流水线下 slot 落后若干天。首日 store 还没提交过
        // （temp_baseline / vapor 等未播种），只能用 capture。
        // season refresh 写的 moisture 已在上面并入 next.moisture，所以用它不会丢。
        if (input.climate_worker_authoritative && current.committed_day >= 0) {
            auto own = [cells](auto &dst, const auto &src) {
                if (src.size() == cells) dst = src;
            };
            own(_round_in.temp, next.temperature);
            own(_round_in.temp_30d, next.temperature_30d_ema);
            own(_round_in.temp_365d, next.temperature_365d_ema);
            own(_round_in.thermal_energy, next.thermal_energy);
            own(_round_in.temp_baseline, next.temperature_baseline);
            own(_round_in.moisture, next.moisture);
            own(_round_in.snowpack, next.snowpack);
            own(_round_in.water_balance_30d, next.water_balance_30d);
            own(_round_in.weather_precip, next.weather_precipitation);
            own(_round_in.weather_vapor, next.vapor);
            own(_round_in.vegetation, next.vegetation);
            own(_round_in.cover, next.cover);
            own(_round_in.soil_moisture, _committed_soil);
            own(_round_in.insolation_now, _committed_insolation_now);
            own(_round_in.insolation_dev, _committed_insolation_dev);
            if (physics_owned) {
                own(_round_in.ocean_thermal_anomaly, _physics.ocean_thermal_anomaly);
            }
        }
        // scalars 由 capture 侧整套填好（world_ext_simulation_host.cpp 里
        // climate_round_scalars 那段），这里不再逐字段补。
        //
        // 留一道 season_phase 的兜底：它是 scalars 里唯一的时变量，0.0 不是"合理
        // 默认"而是"永远的春分"，日照整年不动。旧 harness / 未接线的地图不传
        // climate_round_scalars 时，至少不能让整个季节链停摆。
        if (input.climate_worker_authoritative &&
            _round_in.scalars.season_phase == 0.0 && input.season_phase != 0.0) {
            _round_in.scalars.season_phase = input.season_phase;
        }
        // TTA 不在 climate store / parity 回写里，ACTIVE 下 capture 给的 slot 永远是
        // 生成时的值；ocean_water 以它为 blend 基值，等于每天从头收敛一步。
        if (input.climate_worker_authoritative && _physics.tta_seeded &&
            pk::runtime_switch_value(pk::RuntimeSwitch::PK_TTA_CARRY_OFF) == nullptr &&
            _physics.temp_transport_anomaly.size() == cells) {
            _round_in.temp_transport_anomaly = _physics.temp_transport_anomaly;
        }
        if (std::FILE *trace = pk_sim_trace_file()) {
            std::string line = "[climate-round-in] day=" + std::to_string(day);
            auto lane = [&line](const char *name, const auto &values) {
                uint64_t h = FNV_OFFSET;
                for (const auto &value : values) {
                    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
                    for (size_t b = 0; b < sizeof(value); ++b) h = (h ^ bytes[b]) * FNV_PRIME;
                }
                line += ' '; line += name; line += '='; line += std::to_string(h ^ values.size());
            };
#define PK_ROUND_LANE(name) lane(#name, _round_in.name)
            PK_ROUND_LANE(landform); PK_ROUND_LANE(vegetation); PK_ROUND_LANE(is_water);
            PK_ROUND_LANE(terrain); PK_ROUND_LANE(cover); PK_ROUND_LANE(ema_initialized);
            PK_ROUND_LANE(moisture); PK_ROUND_LANE(elevation); PK_ROUND_LANE(base_moisture);
            PK_ROUND_LANE(weather_vapor); PK_ROUND_LANE(soil_moisture); PK_ROUND_LANE(water_balance_30d);
            PK_ROUND_LANE(lat_norm); PK_ROUND_LANE(maritime); PK_ROUND_LANE(temp_baseline_year);
            PK_ROUND_LANE(insol_annual_mean); PK_ROUND_LANE(temp); PK_ROUND_LANE(temp_30d);
            PK_ROUND_LANE(temp_365d); PK_ROUND_LANE(thermal_energy); PK_ROUND_LANE(snowpack);
            PK_ROUND_LANE(radiative_modifier_add); PK_ROUND_LANE(radiative_modifier_factor);
            PK_ROUND_LANE(pos_x); PK_ROUND_LANE(pos_y); PK_ROUND_LANE(insolation_dev);
            PK_ROUND_LANE(temp_transport_anomaly); PK_ROUND_LANE(sea_ice_frac);
            PK_ROUND_LANE(local_thermal_anomaly); PK_ROUND_LANE(ocean_current_x);
            PK_ROUND_LANE(ocean_current_y); PK_ROUND_LANE(ocean_thermal_anomaly);
            PK_ROUND_LANE(production_ocean_anomaly); PK_ROUND_LANE(production_ocean_baseline);
            PK_ROUND_LANE(production_ocean_temp_before); PK_ROUND_LANE(wind_x); PK_ROUND_LANE(wind_y);
            PK_ROUND_LANE(wind_speed); PK_ROUND_LANE(temp_baseline); PK_ROUND_LANE(air_mass_temp_anomaly);
            PK_ROUND_LANE(wind_baseline); PK_ROUND_LANE(wind_traj_idx); PK_ROUND_LANE(wind_traj_w);
            PK_ROUND_LANE(base_terrain); PK_ROUND_LANE(upwelling_strength); PK_ROUND_LANE(insolation_now);
            PK_ROUND_LANE(cell_temperature_arr); PK_ROUND_LANE(production_sea_ice_oanom);
            PK_ROUND_LANE(production_sea_ice_tta); PK_ROUND_LANE(water_terrain_ids);
            PK_ROUND_LANE(sea_ice_frac_inout); PK_ROUND_LANE(temp_start_of_day);
            PK_ROUND_LANE(tta_start_of_day); PK_ROUND_LANE(sea_ice_frac_prev); PK_ROUND_LANE(weather_precip);
#undef PK_ROUND_LANE
            lane("paw_soil", soil_in);
            lane("season_moist", input.climate_round_input.moisture);
            lane("season_base", input.climate_round_input.base_moisture);
            line += " season=" + std::to_string(_round_in.scalars.season_phase);
            line += " season_ran=" + std::to_string(input.climate_season_refresh_ran ? 1 : 0);
            line += '\n';
            std::fputs(line.c_str(), trace);
            std::fflush(trace);
        }
        _round_out.n_cells = static_cast<int>(cells);
        pk_async_climate::ClimateRoundPassTiming timing;
        const bool round_ok = pk_async_climate::run_climate_round_passes(
            _round_in, input.climate_round_static_knobs, _round_work, _round_out,
            &timing);

        // 一次性诊断（worker 线程，不能用 Godot 的 print）：说明这一天走的是共享编排
        // 还是下面的近似回退。回退是静默的，而两者的数值差一个数量级，缺了这行日志
        // 就只能从分叉矩阵反推。
        static std::atomic<bool> shared_path_logged{false};
        bool expected = false;
        if (shared_path_logged.compare_exchange_strong(expected, true)) {
            std::fprintf(stderr,
                "[climate-kernel][round] shared=%d ok=%d n_cells=%d mask=0x%X "
                "ran=0x%X starved=0x%X knobs_cells=%d\n",
                1, round_ok ? 1 : 0, round_in.n_cells,
                round_in.scalars.passes_mask, timing.passes_ran,
                timing.passes_starved,
                input.climate_round_static_knobs.n_cells);
            std::fflush(stderr);
        }
        // starved = 这个 pass 被 mask 启用了，但输入 lane 不完整所以没跑。它的 out
        // 字段留空，下面的 scatter 会静默 no-op —— 于是 worker 少跑了半个 round，而
        // 分叉矩阵只会看到"某些字段停在昨天的值"，和算法分叉长得一模一样。所以这里
        // 必须当作输入边界故障报出来，而不是当成一次成功的 round。
        if (timing.passes_starved != 0) {
            report.round_passes_starved = timing.passes_starved;
            static std::atomic<bool> starved_logged{false};
            bool starved_expected = false;
            if (starved_logged.compare_exchange_strong(starved_expected, true)) {
                std::fprintf(stderr,
                    "[climate-kernel][round] input starved passes=0x%X — "
                    "round input lanes incomplete (n=%d)\n",
                    timing.passes_starved, _round_in.n_cells);
                // 只报"哪个 pass 饿死"还得回头对着守卫条件人工比对；直接把这个 pass
                // 需要的 lane 长度打出来，缺哪条一眼可见。
                if ((timing.passes_starved & 0x40) != 0) {
                    std::fprintf(stderr,
                        "[climate-kernel][round]   sea_ice lanes: terrain=%zu "
                        "base_terrain=%zu sea_ice_frac_inout=%zu tta=%zu "
                        "upwelling=%zu insol_now=%zu cell_temp_arr=%zu "
                        "water_terrain_ids=%zu\n",
                        _round_in.terrain.size(), _round_in.base_terrain.size(),
                        _round_in.sea_ice_frac_inout.size(),
                        _round_in.temp_transport_anomaly.size(),
                        _round_in.upwelling_strength.size(),
                        _round_in.insolation_now.size(),
                        _round_in.cell_temperature_arr.size(),
                        _round_in.water_terrain_ids.size());
                }
                std::fflush(stderr);
            }
        }
        report.round_passes_ran = timing.passes_ran;
        // passes_mask 的 bit 0..7 与 RuntimeClimateStage 的 PASS_A..TRANSPIRATION
        // 一一对应；bit 8 是 finalizer，它不是一个 stage（没有自己的 stage 槽位）。
        report.stage_ran_mask |= timing.passes_ran & 0xFF;
        if (!round_ok) {
            runtime_copy_text(report.error, "climate_shared_round_failed");
            return false;
        }

        // 把编排输出散射回 store。只写生产侧确实由这些 pass 授权的 lane——
        // 多写一条就会掩盖后面尚未接入共享实现的 stage 的真实分叉。
        auto scatter = [cells](std::vector<float> &dst,
                               const std::vector<float> &src) {
            if (src.size() == cells) std::memcpy(dst.data(), src.data(),
                                                 cells * sizeof(float));
        };
        scatter(next.temperature_baseline, _round_out.temp_baseline);
        scatter(next.thermal_energy,       _round_out.thermal_energy);
        scatter(next.moisture,             _round_out.moisture);
        scatter(next.temperature_30d_ema,  _round_out.temp_30d);
        scatter(next.temperature_365d_ema, _round_out.temp_365d);
        scatter(next.snowpack,             _round_out.snowpack);
        // cell_temp 由 wind_surface 末端合成、finalizer 收尾 clamp；这是 round 内
        // 温度场的唯一授权写者。
        scatter(next.temperature,          _round_out.temp);
        scatter(next.sea_ice,              _round_out.sea_ice_frac);
        if (input.climate_worker_authoritative) {
            // finalizer 没跑时，round 内 ocean 累加完的值已回写到 _round_in。
            const std::vector<float> &tta_end =
                (_round_out.fin_applied && _round_out.tta_final.size() == cells)
                    ? _round_out.tta_final : _round_in.temp_transport_anomaly;
            if (tta_end.size() == cells) {
                _physics.temp_transport_anomaly = tta_end;
                _physics.tta_seeded = true;
            }
            if (pk::runtime_switch_value(pk::RuntimeSwitch::PK_TTA_DIAG) != nullptr) {
                double a = 0, mx = 0, t = 0, ice = 0;
                for (size_t i = 0; i < cells; ++i) {
                    const double v = std::fabs(tta_end[i]); a += v; if (v > mx) mx = v;
                    t += next.temperature[i]; ice += next.sea_ice[i];
                }
                std::printf("[tta] day=%lld mean_abs=%.6f max=%.6f T=%.6f ice=%.4f\n",
                    static_cast<long long>(day), a / cells, mx, t / cells, ice);
                std::fflush(stdout);
            }
        }
        // ABI 8：sea_ice 翻转后的 terrain 写回 worker store，供次日 round 与 writeback。
        if (_round_out.terrain.size() == cells && next.terrain.size() == cells) {
            std::memcpy(next.terrain.data(), _round_out.terrain.data(), cells);
        }

        // 逐 pass 耗时记进对应 stage 槽位（索引与 passes_mask 的 bit 位一致）。
        // finalizer 没有独立 stage 槽，它的耗时并入 round 尾巴不单列。
        static constexpr RuntimeClimateStage PASS_STAGES[8] = {
            RuntimeClimateStage::PASS_A,       RuntimeClimateStage::PASS_B,
            RuntimeClimateStage::OCEAN_WATER,  RuntimeClimateStage::OCEAN_LAND,
            RuntimeClimateStage::WIND_AIR,     RuntimeClimateStage::WIND_SURFACE,
            RuntimeClimateStage::SEA_ICE,      RuntimeClimateStage::TRANSPIRATION,
        };
        for (size_t k = 0; k < 8; ++k) {
            // 只记真的跑过的 pass。以前这里无条件按 cells 记账，于是被 mask 关掉或
            // 被 starve 掉的 pass 也会报出一份满额工作量而耗时为 0——导出到
            // performance.csv 之后，那一行看起来像"这个 stage 免费算完了 2400 个
            // cell"，恰好是最容易被当成优化成果的假象。
            if ((timing.passes_ran & (1 << k)) == 0) continue;
            const size_t slot = static_cast<size_t>(PASS_STAGES[k]);
            report.stage_ms[slot] = static_cast<double>(timing.pass_us[k]) / 1000.0;
            report.stage_work[slot] = static_cast<uint64_t>(cells);
            report.work_units += static_cast<uint64_t>(cells);
        }
        diag_note_stage("round");
        shared_round_ran = true;
    }

    // ─── 以下是 shared_passes_available == false 时的诊断近似 ─────────────
    // 它们不具备 parity 语义。共享 round 跑过时必须整段跳过，否则会把刚算出来的
    // 场重新覆盖成近似值。
    if (input.climate_round_ran && !shared_round_ran) {
    run_stage(report, RuntimeClimateStage::PASS_A, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float ny = climate_formula::clamp01(
                read_or(input.cell_lat_norm, i, 0.5f));
            const float elevation = read_or(input.cell_elevation, i, 0.0f);
            const bool is_water = read_or(input.is_water, i, 0u) != 0u;
            const float annual_mean = climate_formula::annual_insolation_mean(
                ny, catalog.axial_tilt_deg, catalog.day_length_gain);
            const float current_insolation = climate_formula::daily_insolation(
                ny, season, catalog.axial_tilt_deg, catalog.day_length_gain);
            float deviation = climate_formula::insolation_season_dev(
                ny, current_insolation,
                annual_mean);
            deviation = climate_formula::clamp(
                deviation, catalog.insol_dev_min, catalog.insol_dev_max);

            float base_moisture = read_or(input.cell_base_moisture, i,
                                          read_or(input.cell_moisture, i, 0.0f));
            base_moisture = climate_formula::clamp01(base_moisture);
            const float abs_lat = std::fabs(ny * 2.0f - 1.0f);
            float lat_t = (abs_lat - 0.18f) / 0.64f;
            if (lat_t < 0.0f) lat_t = 0.0f;
            else if (lat_t > 1.0f) lat_t = 1.0f;
            const float lat_w = lat_t * lat_t * (3.0f - 2.0f * lat_t);
            const float season_amp = is_water ? (0.08f + 0.50f * lat_w)
                                              : (0.12f + 0.36f * lat_w);
            const float season_term = (is_water ? season_amp : -season_amp) * deviation;
            float synoptic = 0.0f;
            if (input.cell_weather_vapor.size() == cells &&
                catalog.runtime_moisture_weather_vapor_weight > 0.0f) {
                const float vapor = climate_formula::clamp(
                    input.cell_weather_vapor[i], 0.0f, 1.0f);
                synoptic += (vapor - base_moisture * 0.15f) *
                    catalog.runtime_moisture_weather_vapor_weight;
            }
            if (input.cell_weather_precip.size() == cells &&
                catalog.runtime_moisture_precip_weight > 0.0f) {
                const float precip = climate_formula::clamp(
                    input.cell_weather_precip[i], 0.0f, 1.0f);
                synoptic += (precip - 0.04f) *
                    catalog.runtime_moisture_precip_weight * 3.5f;
            }
            const float synoptic_cap = is_water ? 0.12f : 0.28f;
            synoptic = climate_formula::clamp(synoptic, -synoptic_cap, synoptic_cap);
            float moisture_target = base_moisture + season_term + synoptic;
            if (!is_water) {
                if (input.cell_soil_moisture.size() == cells) {
                    moisture_target += climate_formula::signed_hydrology_contribution(
                        climate_formula::clamp(input.cell_soil_moisture[i], -0.5f, 0.5f),
                        catalog.runtime_moisture_soil_weight,
                        catalog.runtime_moisture_soil_dry_weight);
                }
                if (input.cell_water_balance_30d.size() == cells) {
                    moisture_target += climate_formula::signed_hydrology_contribution(
                        climate_formula::clamp(input.cell_water_balance_30d[i], -1.0f, 1.0f),
                        catalog.runtime_moisture_water_balance_weight,
                        catalog.runtime_moisture_water_balance_dry_weight);
                }
            }
            moisture_target = climate_formula::clamp01(moisture_target);
            float previous_moisture = read_or(input.cell_moisture, i,
                                              current.moisture[i]);
            if (!std::isfinite(previous_moisture) || previous_moisture < 0.0f ||
                previous_moisture > 1.0f) {
                previous_moisture = moisture_target;
            }
            const float moisture_alpha = climate_formula::thermal_alpha_eff(
                catalog.runtime_moisture_base_relax_rate, dt);
            const float moisture_now = climate_formula::clamp01(previous_moisture +
                (moisture_target - previous_moisture) * moisture_alpha);

            float temp_year = read_or(input.cell_temp_baseline_year, i,
                                      0.0f) - static_cast<float>(
                                          climate_formula::altitude_penalty(
                                              elevation, catalog.sea_level));
            temp_year = climate_formula::clamp01(temp_year);
            const float insolation_gain = catalog.insol_amp * catalog.insol_gain;
            float season_offset = climate_formula::season_offset_continental(
                insolation_gain, is_water,
                current.temperature_365d_ema[i], deviation,
                catalog.land_continentality);
            float radiative_target = climate_formula::clamp01(temp_year + season_offset);
            const float current_temp = read_or(input.cell_temp, i,
                                               current.temperature[i]);
            float previous_energy = current.thermal_energy[i];
            if (current.committed_day < 0) previous_energy = current_temp;
            float alpha = catalog.thermal_inertia_land;
            const uint8_t cover = read_or(input.cover, i, 0u);
            const float snowpack = current.snowpack[i];
            if (is_water) alpha = catalog.thermal_inertia_water;
            else if (cover == 2u || snowpack > catalog.snowpack_cover_low)
                alpha = catalog.thermal_inertia_snow;
            else if (elevation > 0.70f)
                alpha = catalog.thermal_inertia_high_mountain;
            alpha = climate_formula::thermal_alpha_eff(alpha, dt);
            const float heat_next = previous_energy +
                (radiative_target - previous_energy) * alpha;
            const float delta_cap = std::max(0.0f,
                catalog.thermal_daily_delta_cap) * dt;
            const float temp_now = climate_formula::clamp01(
                previous_energy + climate_formula::clamp(
                    heat_next - previous_energy, -delta_cap, delta_cap));
            next.temperature_baseline[i] = temp_now;
            next.thermal_energy[i] = heat_next;
            next.moisture[i] = moisture_now;
            next.temperature_30d_ema[i] = current.temperature_30d_ema[i] +
                (temp_now - current.temperature_30d_ema[i]) *
                climate_formula::thermal_alpha_eff(1.0f / 30.0f, dt);
            next.temperature_365d_ema[i] = current.temperature_365d_ema[i] +
                (temp_now - current.temperature_365d_ema[i]) *
                climate_formula::thermal_alpha_eff(
                    1.0f / static_cast<float>(std::max(1u, catalog.days_per_year)), dt);
            next.snowpack[i] = is_water ? 0.0f : snowpack;
            next.snow_cover[i] = climate_formula::clamp01(next.snowpack[i]);
            next.temperature[i] = temp_now;
            next.convergence[i] = 0.0f;
            next.vapor[i] = read_or(input.cell_weather_vapor, i, current.vapor[i]);
            next.weather_precipitation[i] = read_or(input.cell_weather_precip, i,
                                                     current.weather_precipitation[i]);
            next.weather_intensity[i] = read_or(input.cell_weather_intensity, i,
                                                current.weather_intensity[i]);
            next.plant_available_water[i] = read_or(input.cell_plant_available_water,
                                                    i, current.plant_available_water[i]);
        }
        return static_cast<uint64_t>(cells) * 6u;
    });
    run_stage(report, RuntimeClimateStage::PASS_B, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float moisture = read_or(input.cell_moisture, i, current.moisture[i]);
            const float terrain = static_cast<float>(read_or(input.terrain, i, 0u));
            next.moisture[i] = std::clamp(moisture + (terrain > 0.0f ? -0.002f : 0.002f), 0.0f, 1.0f);
            next.temperature[i] = next.thermal_energy[i] + next.temperature_baseline[i] * 0.05f;
        }
        return static_cast<uint64_t>(cells) * 3u;
    });
    run_stage(report, RuntimeClimateStage::OCEAN_WATER, [&]() {
        for (size_t i = 0; i < cells; ++i) if (read_or(input.is_water, i, 0u) != 0) {
            next.temperature[i] = next.temperature[i] * 0.96f + current.temperature_365d_ema[i] * 0.04f;
        }
        return static_cast<uint64_t>(cells);
    });
    run_stage(report, RuntimeClimateStage::OCEAN_LAND, [&]() {
        for (size_t i = 0; i < cells; ++i) if (read_or(input.is_water, i, 0u) == 0) {
            next.temperature[i] += (next.moisture[i] - 0.5f) * 0.15f;
        }
        return static_cast<uint64_t>(cells);
    });
    run_stage(report, RuntimeClimateStage::WIND_AIR, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            float sum = 0.0f;
            uint32_t count = 0;
            const size_t begin = input.neighbor_offsets.empty() ? i * 6u :
                static_cast<size_t>(input.neighbor_offsets[i]);
            const size_t end = input.neighbor_offsets.empty() ? begin + 6u :
                static_cast<size_t>(input.neighbor_offsets[i + 1u]);
            for (size_t p = begin; p < end && p < input.neighbor_indices.size(); ++p) {
                const int32_t n = input.neighbor_indices[p];
                if (n >= 0) { sum += next.temperature[static_cast<size_t>(n)]; ++count; }
            }
            next.convergence[i] = count == 0 ? 0.0f : (sum / static_cast<float>(count) - next.temperature[i]);
        }
        return static_cast<uint64_t>(cells) * 7u;
    });
    run_stage(report, RuntimeClimateStage::WIND_SURFACE, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] += next.convergence[i] * 0.18f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::SEA_ICE, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            float ice = current.sea_ice[i];
            if (read_or(input.is_water, i, 0u) != 0) {
                if (next.temperature[i] < catalog.sea_ice_freeze) ice += 0.04f * dt;
                else if (next.temperature[i] > catalog.sea_ice_melt) ice -= 0.03f * dt;
            } else ice = 0.0f;
            next.sea_ice[i] = std::clamp(ice, 0.0f, 1.0f);
            next.snowpack[i] = std::max(0.0f, current.snowpack[i] +
                (next.temperature[i] < 0.0f ? 0.01f : -0.02f * dt));
            next.snow_cover[i] = std::clamp(next.snowpack[i], 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 5u;
    });
    run_stage(report, RuntimeClimateStage::TRANSPIRATION, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float heat = std::max(0.0f, next.temperature[i] - 3.0f) / 35.0f;
            next.vegetation_growth_pressure[i] = std::clamp(next.plant_available_water[i] * heat, 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.vapor[i] = std::clamp(next.moisture[i] + std::max(0.0f, next.temperature[i]) * 0.004f, 0.0f, 1.0f);
            next.cloud_water[i] = std::max(0.0f, next.vapor[i] + next.convergence[i] * 0.02f - 0.35f);
            next.cloud_cover[i] = std::clamp(next.cloud_water[i] * 2.0f, 0.0f, 1.0f);
            next.instability[i] = std::clamp(std::abs(next.temperature[i] - next.temperature_30d_ema[i]) / 12.0f, 0.0f, 1.0f);
            const float precipitation = std::max(0.0f, next.cloud_water[i] * (0.25f + next.instability[i]));
            next.weather_precipitation[i] = precipitation;
            next.weather_intensity[i] = std::clamp(precipitation * 4.0f, 0.0f, 1.0f);
            const uint8_t type = precipitation > 0.20f ? 3u : precipitation > 0.04f ? 2u : next.cloud_cover[i] > 0.35f ? 1u : 0u;
            // 过渡三条 lane：这条诊断近似路径没有生产的 rate/dt knob，只记"从哪个
            // 类型过渡到哪个类型"，alpha 立即完成。它不具备 parity 语义（整条
            // fallback 都不具备），真正的过渡状态机在 stage 11 的共享内核里。
            if (next.weather_target_type[i] != type) {
                next.weather_prev_type[i] = current.weather_type[i];
                next.weather_target_type[i] = type;
            }
            next.weather_transition_alpha[i] = 0.0f;
            next.weather_type[i] = type;
        }
        return static_cast<uint64_t>(cells) * 10u;
    });
    run_stage(report, RuntimeClimateStage::RUNTIME_HYDROLOGY, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float melt = next.temperature[i] > 0.0f ? std::min(next.snowpack[i], next.temperature[i] * 0.01f) : 0.0f;
            next.snowpack[i] -= melt;
            const float inflow = next.weather_precipitation[i] + melt + read_or(input.canal_water, i, 0.0f);
            const float water = std::clamp(current.plant_available_water[i] + inflow - next.vegetation_growth_pressure[i] * 0.015f, 0.0f, catalog.soil_capacity);
            next.plant_available_water[i] = water;
            next.water_balance_30d[i] = current.water_balance_30d[i] * (29.0f / 30.0f) + (inflow - next.vegetation_growth_pressure[i] * 0.015f) / 30.0f;
            next.runoff[i] = std::max(0.0f, water - 0.85f);
            next.groundwater[i] = std::max(0.0f, current.groundwater[i] * 0.995f + next.runoff[i] * 0.15f);
            next.river_storage[i] = std::max(0.0f, current.river_storage[i] + next.runoff[i] - current.river_discharge[i]);
            next.river_discharge[i] = next.river_storage[i] * (read_or(input.has_river, i, 0u) != 0 ? 0.25f : 0.02f);
            next.riparian_moisture[i] = std::clamp(water + next.river_discharge[i] * 0.25f, 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 11u;
    });
    // 近似回退路径同样遵守 canonical 顺序：albedo → vegetation → feedback 在生产
    // 语义里是 weather 之后的 stage_b 三段，排在 weather/hydrology 之前会改变
    // 温度与植被链的读写接力。这条路径没有 parity 语义，但顺序不能与生产相反，
    // 否则 stage_sequence 契约会（正确地）拒绝它。
    run_stage(report, RuntimeClimateStage::ALBEDO, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] -= next.snow_cover[i] * 0.4f + next.sea_ice[i] * 0.25f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::VEGETATION_DYNAMICS, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.vegetation_heat_stress[i] = std::clamp((next.temperature[i] - 30.0f) / 20.0f, 0.0f, 1.0f);
            next.vegetation_drought_stress[i] = 1.0f - std::clamp(next.plant_available_water[i], 0.0f, 1.0f);
            next.vegetation_cold_stress[i] = std::clamp((-next.temperature[i]) / 20.0f, 0.0f, 1.0f);
            const float pressure = next.vegetation_growth_pressure[i] -
                (next.vegetation_heat_stress[i] + next.vegetation_drought_stress[i] + next.vegetation_cold_stress[i]) / 3.0f;
            next.vegetation_vitality[i] = std::clamp(current.vegetation_vitality[i] + pressure * 0.02f, 0.0f, 1.0f);
            next.vegetation_growth_streak[i] = pressure > 0.0f ? current.vegetation_growth_streak[i] + 1 : 0;
            next.vegetation_drought_streak[i] = next.vegetation_drought_stress[i] > 0.7f ? current.vegetation_drought_streak[i] + 1 : 0;
            next.vegetation_succession_candidate[i] = next.vegetation_growth_streak[i] >= 30 ? 1u : 0u;
        }
        return static_cast<uint64_t>(cells) * 9u;
    });
    run_stage(report, RuntimeClimateStage::CLIMATE_FEEDBACK, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] += (next.vegetation_vitality[i] - 0.5f) * 0.05f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::STAGE_B_AFTER_HYDROLOGY, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.moisture[i] = std::clamp(next.moisture[i] * 0.9f + next.plant_available_water[i] * 0.1f, 0.0f, 1.0f);
            if (next.temperature[i] != current.temperature[i] ||
                next.plant_available_water[i] != current.plant_available_water[i] ||
                next.weather_precipitation[i] != current.weather_precipitation[i]) ++report.changed_cells;
        }
        return static_cast<uint64_t>(cells) * 3u;
    });
    }

    // ─── stage 8 ALBEDO（共享纯内核，节拍独立于 round）────────────────────
    //
    // 生产侧 albedo 是一个仿真日内 temp 的最后一个写者：round 末尾 wind_surface /
    // finalizer 定下温度后，stage_b 再叠一层 (reference_albedo - alb) * gain。所以这里
    // 必须排在 round 之后，且只在生产当天真的跑过 albedo 时跑。
    //
    // 输入全部取自 environment 快照（is_water / vegetation / cover）与 static knobs 的
    // albedo_table —— 与生产 stage_b 从 SoA slot 读的是同一批 lane。
    // 走了上面那条近似回退时不叠 albedo：那条路径自带一份 ALBEDO 近似，再叠一次共享
    // 内核等于对同一天算两遍。回退路径本来就没有 parity 语义，保持它自洽即可。
    const bool shared_albedo_ran = input.climate_albedo.ran &&
        (shared_round_ran || !input.climate_round_ran);
    // B8-1：这里只登记执行体，不在当前位置执行。stage_b 的三段（albedo →
    // vegetation → feedback）在生产里跑在 weather / distribute / hydrology
    // 之后；真正调用点固定在下面气象段之后，顺序与 canonical 表一致。
    auto run_shared_albedo = [&]() {
        if (!shared_albedo_ran) return;
        run_stage(report, RuntimeClimateStage::ALBEDO, [&]() {
            const auto &knobs = input.climate_round_static_knobs;
            // ACTIVE 下 vegetation / cover 由 worker 推进，capture 那份落后流水线深度。
            const bool own_lanes = input.climate_worker_authoritative &&
                current.committed_day >= 0;
            const std::vector<uint8_t> &alb_veg =
                (own_lanes && next.vegetation.size() == cells)
                    ? next.vegetation : input.vegetation;
            const std::vector<uint8_t> &alb_cover =
                (own_lanes && next.cover.size() == cells)
                    ? next.cover : input.cover;
            if (input.is_water.size() != cells ||
                alb_veg.size() != cells ||
                alb_cover.size() != cells ||
                knobs.albedo_table.empty()) {
                return static_cast<uint64_t>(0);
            }
            pk_async_climate::albedo_apply_pure(
                input.climate_albedo, input.is_water.data(),
                alb_veg.data(), alb_cover.data(),
                knobs.albedo_table.data(),
                static_cast<int>(knobs.albedo_table.size()),
                next.temperature.data(), static_cast<int>(cells));
            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_ALBEDO;
            return static_cast<uint64_t>(cells);
        });
    };

    // ─── stage 9 VEGETATION_DYNAMICS（共享纯内核，节拍独立于 round）────────
    //
    // 顺序必须夹在 albedo 与 feedback 之间：生产 stage_b 就是 ① albedo → ②
    // vegetation → ③ feedback 这个顺序，而三段之间通过 SoA 直接接力
    //（albedo 写 temp、vegetation 写 plant_available_water、feedback 读改后的场）。
    //
    // 输入 lane 的取值来源分两类，这个划分是当前 S3 进度的直接反映：
    //   - is_water / terrain / landform / vegetation / temp_30d / moisture /
    //     water_balance_30d / weather_* 取生产的记录。其中 water_balance_30d 与
    //     weather_* 的生产者（hydrology / weather）还没有共享实现，用 worker 自己
    //     那份必然分叉；而 vegetation 会被 GDScript 侧的演替后处理改写，那次写入
    //     不属于任何 climate stage，快照里也拿不到。stage 11/12 提取完成后，这几条
    //     才有资格换成 worker 自己的场。
    //   - vitality / streak / heat / drought / cold 与 plant_available_water /
    //     vegetation_growth_pressure 是 store 成员，必须读写 worker 自己那一份，
    //     否则 parity 就退化成"把生产的结果抄一遍"。
    //   - regen_score 没有 float store 成员，用 scratch 承接生产读到的初值后丢弃。
    const bool shared_vegetation_ran = vegetation_requested &&
        (shared_round_ran || !input.climate_round_ran);
    auto run_shared_vegetation = [&]() {
        if (!shared_vegetation_ran) return;
        run_stage(report, RuntimeClimateStage::VEGETATION_DYNAMICS, [&]() {
            const pk_async_climate::VegetationDynamicsInput &vd = *input.climate_vegetation;
            // B8-1：weather 段现在排在本段之前，worker 自己当天的场才是生产语义里
            // 的输入。生产记录只在 worker 当天没算出该场时兜底（跳过节拍 / 缺 lane）。
            const uint8_t *wx_type = (next.weather_type.size() == cells)
                ? next.weather_type.data() : vd.weather_type.data();
            const float *wx_intensity = (next.weather_intensity.size() == cells)
                ? next.weather_intensity.data() : vd.weather_intensity.data();
            const uint8_t *wx_field_init =
                (_weather_field_init_seeded &&
                 _weather_field_init_scratch.size() == cells)
                    ? _weather_field_init_scratch.data()
                    : vd.weather_field_init.data();
            // B8-3 E2：植被阶段读 worker 自己当天算出来的慢层，而不是 tick 起始的
            // 生产记录。本段已经排在 weather/distribute 之后（P1 重排），所以
            // next.moisture 是 distribute/hydrology 之后的当天值、
            // next.water_balance_30d 是 distribute 之后的当天值、
            // next.temperature_30d_ema 是 round pass_a 之后的当天值。
            //
            // 之前三条读 vd（生产记录）时，PAW/VGP/moisture/WB30 的量级偏差正好
            // 集中在它们身上：worker 用"别人的昨天"算自己的今天，再回灌覆盖，
            // 差值每天被重新引入。
            const float *veg_temp_30d = (next.temperature_30d_ema.size() == cells)
                ? next.temperature_30d_ema.data() : vd.temp_30d.data();
            const float *veg_moisture = (next.moisture.size() == cells)
                ? next.moisture.data() : vd.moisture.data();
            const float *veg_water_balance =
                (next.water_balance_30d.size() == cells)
                    ? next.water_balance_30d.data()
                    : vd.water_balance_30d.data();
            if (vd.is_water.size() != cells || vd.terrain.size() != cells ||
                vd.landform.size() != cells || vd.vegetation.size() != cells ||
                veg_temp_30d == nullptr || veg_moisture == nullptr ||
                veg_water_balance == nullptr ||
                wx_type == nullptr || wx_intensity == nullptr ||
                wx_field_init == nullptr ||
                next.plant_available_water.size() != cells ||
                next.vegetation_vitality.size() != cells ||
                next.vegetation_drought_streak.size() != cells ||
                next.vegetation_growth_streak.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                return static_cast<uint64_t>(0);
            }
            pk_async_climate::VegetationDynamicsKnobs knobs = vd.knobs;
            pk_async_climate::VegetationDynamicsTables tables;
            tables.ideal_temp = vd.ideal_temp.data();
            tables.ideal_moist = vd.ideal_moist.data();
            tables.temp_tol = vd.temp_tol.data();
            tables.moist_tol = vd.moist_tol.data();
            tables.weather_penalty = vd.weather_penalty.data();
            tables.resistance = vd.resistance.data();
            tables.next_up = vd.next_up.data();
            tables.next_down = vd.next_down.data();

            // terrain / vegetation 由 worker 推进（海冰翻转、演替），capture 那份落后。
            const bool own_lanes = input.climate_worker_authoritative &&
                current.committed_day >= 0;
            pk_async_climate::VegetationDynamicsLanes lanes;
            lanes.is_water = vd.is_water.data();
            lanes.terrain = (own_lanes && next.terrain.size() == cells)
                ? next.terrain.data() : vd.terrain.data();
            lanes.landform = vd.landform.data();
            lanes.vegetation = (own_lanes && next.vegetation.size() == cells)
                ? next.vegetation.data() : vd.vegetation.data();
            lanes.temp_30d = veg_temp_30d;
            lanes.moisture = veg_moisture;
            lanes.water_balance_30d = veg_water_balance;
            lanes.soil_moisture = !vd.has_soil_moisture ? nullptr
                : (soil_in.size() == cells ? soil_in.data() : vd.soil_moisture.data());
            lanes.weather_type = wx_type;
            lanes.weather_intensity = wx_intensity;
            lanes.weather_field_init = wx_field_init;
            lanes.plant_available_water = next.plant_available_water.data();
            lanes.vegetation_growth_pressure =
                (vd.has_growth_pressure &&
                 next.vegetation_growth_pressure.size() == cells)
                    ? next.vegetation_growth_pressure.data() : nullptr;
            lanes.vitality = next.vegetation_vitality.data();
            lanes.low_streak = next.vegetation_drought_streak.data();
            lanes.high_streak = next.vegetation_growth_streak.data();
            if (knobs.stress_enabled) {
                if (next.vegetation_heat_stress.size() != cells ||
                    next.vegetation_drought_stress.size() != cells ||
                    next.vegetation_cold_stress.size() != cells ||
                    vd.regen_score.size() != cells) {
                    return static_cast<uint64_t>(0);
                }
                lanes.heat_stress = next.vegetation_heat_stress.data();
                lanes.drought_stress = next.vegetation_drought_stress.data();
                lanes.cold_stress = next.vegetation_cold_stress.data();
                _vegetation_regen_scratch = vd.regen_score;
                lanes.regen_score = _vegetation_regen_scratch.data();
            }
            pk_async_climate::VegetationDynamicsEmit emit;
            pk_async_climate::vegetation_dynamics_apply_pure(
                knobs, tables, lanes, 0, static_cast<int>(cells), emit);
            // B8-P1：演替后处理从主线程搬进 worker。规则与
            // map_generator._apply_vegetation_succession_candidates 逐条对齐：
            //   * vegetation / base_vegetation 一起改成下一档；
            //   * 降级（next_down[prev] == next）用 degrade_reset_target，升级用 0.7；
            //   * vitality 取"当前与目标的中点"；
            //   * streak 冷却（-succession_cooldown_days）已由纯内核写入。
            // 生产侧对应的 GDScript 写入在 ACTIVE 下被抑制门关掉，worker 是唯一写者。
            if (next.vegetation.size() == cells &&
                next.base_vegetation.size() == cells) {
                for (size_t k = 0; k < emit.indices.size(); ++k) {
                    const int32_t idx = emit.indices[k];
                    if (idx < 0 || static_cast<size_t>(idx) >= cells) continue;
                    const uint8_t next_veg = emit.to_veg[k];
                    const uint8_t prev_veg = next.vegetation[static_cast<size_t>(idx)];
                    if (next_veg == prev_veg) continue;
                    const bool is_degrade =
                        static_cast<size_t>(prev_veg) < vd.next_down.size() &&
                        vd.next_down[prev_veg] == next_veg;
                    next.vegetation[static_cast<size_t>(idx)] = next_veg;
                    next.base_vegetation[static_cast<size_t>(idx)] = next_veg;
                    const float target =
                        is_degrade ? knobs.degrade_reset_target : 0.7f;
                    next.vegetation_vitality[static_cast<size_t>(idx)] =
                        (next.vegetation_vitality[static_cast<size_t>(idx)] +
                         target) * 0.5f;
                }
            }
            // B8-P1：演替本身已经在上面的 apply 里落到 worker 自己的
            // vegetation / base_vegetation lane；生产侧同一步 GDScript 后处理在
            // ACTIVE 下被抑制门关掉，worker 是唯一写者。
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS;
            return static_cast<uint64_t>(cells);
        });
    };

    // ─── stage 10 CLIMATE_FEEDBACK（共享纯内核，节拍独立于 round）──────────
    //
    // 输入整份取自生产的记录，而不是 environment 快照的同名 lane：feedback 跑在
    // stage_b 段（weather 之后），快照是 tick 起始拍的，weather_type /
    // weather_intensity 在这两个时刻之间正好被 weather pass 整场重写过。
    //
    // 状态所有权分两类，不能混：
    //   base_moisture / soil_moisture — 不在 canonical parity 字段表里，worker store
    //       也没有对应成员。用 scratch 承接生产读到的初值，输出丢弃。
    //   vegetation_growth_pressure — 是 store 成员。必须读写 worker 自己那一份，
    //       否则 parity 就退化成"把生产的结果抄一遍"，什么都验不出来。
    const bool shared_feedback_ran = feedback_requested &&
        (shared_round_ran || !input.climate_round_ran);
    auto run_shared_feedback = [&]() {
        if (!shared_feedback_ran) return;
        run_stage(report, RuntimeClimateStage::CLIMATE_FEEDBACK, [&]() {
            const pk_async_climate::ClimateFeedbackInput &fb = *input.climate_feedback;
            const auto &neighbors = input.climate_round_static_knobs.neighbor_indices;
            // B8-1：与 vegetation 同一口径 —— feedback 读当天 weather 段的产物，
            // 而不是 tick 开始时的生产记录。weather_type/intensity 的 store 成员
            // 一定齐长；field_init 走 weather 段写过的 scratch。
            const uint8_t *wx_type = (next.weather_type.size() == cells)
                ? next.weather_type.data() : fb.weather_type.data();
            const float *wx_intensity = (next.weather_intensity.size() == cells)
                ? next.weather_intensity.data() : fb.weather_intensity.data();
            const uint8_t *wx_field_init =
                (_weather_field_init_seeded &&
                 _weather_field_init_scratch.size() == cells)
                    ? _weather_field_init_scratch.data()
                    : fb.weather_field_init.data();
            if (fb.is_water.size() != cells ||
                wx_type == nullptr || wx_intensity == nullptr ||
                wx_field_init == nullptr ||
                fb.temp_transport_anomaly.size() != cells ||
                fb.base_moisture.size() != cells ||
                fb.soil_moisture.size() != cells ||
                neighbors.size() < cells * 6u ||
                next.vegetation_growth_pressure.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                // production_stage_mask 里有 feedback 而 stage_ran_mask 里没有，
                // 差集就会把它报出来，不会变成一次静默 no-op。
                return static_cast<uint64_t>(0);
            }
            _feedback_base_moisture = fb.base_moisture;
            _feedback_soil_moisture = soil_in.size() == cells ? soil_in : fb.soil_moisture;
            pk_async_climate::climate_feedback_apply_pure(
                fb.knobs, fb.is_water.data(), wx_type,
                wx_intensity, wx_field_init,
                neighbors.data(), fb.temp_transport_anomaly.data(),
                _feedback_base_moisture.data(), _feedback_soil_moisture.data(),
                next.vegetation_growth_pressure.data(),
                0, static_cast<int>(cells));
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_CLIMATE_FEEDBACK;
            return static_cast<uint64_t>(cells);
        });
    };

    // B8-3 单因子实验开关：把 stage_b 三段放回 weather 之前（旧顺序）。只用于
    // soak A/B 归因，默认关闭；进程级读取一次，不参与任何仿真状态，也不进存档。
    // 归因方法：同一 seed/尺寸跑 canonical vs legacy，只翻这一个变量，差值就是
    // "顺序"这一项的贡献，与"输入所有权""节拍""ψ"等其它因子分开。
    static const bool legacy_stage_order = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_STAGE_ORDER_LEGACY);
        return value != nullptr && value[0] == '1';
    }();
    if (legacy_stage_order) {
        run_shared_albedo();
        run_shared_vegetation();
        run_shared_feedback();
    }

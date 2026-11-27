    // ─── stage 11 后段 weather distribute（共享纯内核）────────────────────────
    //
    // 必须排在 field solve 之后、hydrology 之前：生产 native daily 的节点序是
    // weather_field → weather_commit → weather_distribute → … → runtime_hydrology，
    // 而 distribute 读 field solve 写出的 weather_type / intensity / precip，又写
    // hydrology 要读的 snowpack。
    //
    //   worker 自己那一份：temperature / moisture / snow_cover / snowpack /
    //       water_balance_30d。前两条是 distribute 之后仍会被 stage_b 改的量，后三条
    //       就是这一段的产物 —— snow_cover 尤其关键，sea_ice 与 albedo 都读它。
    //   生产记录那一份：weather_* 四条读 lane 取 worker 自己 store（field solve 刚
    //       写的），heat / elevation / landform / terrain 取记录；cover 与两条积雪
    //       计数、soil_moisture 没有 store 成员，用 scratch 承接初值后丢弃。
    const bool shared_distribute_ran = distribute_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_distribute_ran) {
        run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
            const pk_async_climate::WeatherDistributeInput &wd =
                *input.climate_weather_distribute;
            if (wd.heat.size() != cells || wd.elevation.size() != cells ||
                wd.landform.size() != cells || wd.terrain.size() != cells ||
                wd.weather_intensity.size() != cells ||
                wd.weather_precip.size() != cells ||
                wd.weather_type.size() != cells ||
                wd.weather_field_init.size() != cells ||
                wd.cover.size() != cells || wd.soil_moisture.size() != cells ||
                wd.accumulated_snow_days.size() != cells ||
                wd.pre_snow_cover.size() != cells ||
                next.temperature.size() != cells || next.moisture.size() != cells ||
                next.snow_cover.size() != cells || next.snowpack.size() != cells ||
                next.water_balance_30d.size() != cells) {
                return static_cast<uint64_t>(0);
            }
            // ABI 8：cover 由 worker 自持；已播种时用 store，否则跟生产冷启动。
            if (next.cover.size() == cells) {
                _distribute_cover_scratch = next.cover;
            } else {
                _distribute_cover_scratch = wd.cover;
            }
            _distribute_soil_scratch = soil_in.size() == cells ? soil_in : wd.soil_moisture;
            // 两条积雪计数：own_snow_state 决定跨天由谁持有（见
            // WeatherDistributeInput 那里的说明）。SHADOW 每天跟生产播种以便对拍
            // 同一条状态链；ACTIVE 只在首次（或换图）建立初值，之后 worker 自持
            // —— 否则会一直拿生产那份不再推进的缓存重置，snow_accum_days_req
            // 永远攒不满，snow_cover 于是恒为 0。
            const bool seed_snow_state = !wd.own_snow_state ||
                _distribute_acc_snow_scratch.size() != cells ||
                _distribute_pre_cover_scratch.size() != cells;
            if (seed_snow_state) {
                _distribute_acc_snow_scratch = wd.accumulated_snow_days;
                _distribute_pre_cover_scratch = wd.pre_snow_cover;
            }

            pk_async_climate::WeatherDistributeLanes lanes;
            lanes.temp = next.temperature.data();
            lanes.moisture = next.moisture.data();
            lanes.snow_cover = next.snow_cover.data();
            lanes.snowpack = next.snowpack.data();
            lanes.water_balance_30d = next.water_balance_30d.data();
            lanes.soil_moisture = _distribute_soil_scratch.data();
            lanes.cover = _distribute_cover_scratch.data();
            lanes.heat = _committed_heat_input.size() == cells
                ? _committed_heat_input.data() : wd.heat.data();
            lanes.elevation = wd.elevation.data();
            lanes.landform = wd.landform.data();
            lanes.terrain = next.terrain.size() == cells
                ? next.terrain.data() : wd.terrain.data();
            // 这四条走 worker 自己的 store：field solve 刚刚写过它们，拿生产的记录
            // 等于把 field solve 的对拍结果绕过去，那一段就白验了。
            // weather_field_init 没有 store 成员，而 field solve 在 worker 侧总是走
            // direct 语义（一定写 field_init=1），所以直接给全 1。
            lanes.weather_intensity = next.weather_intensity.data();
            lanes.weather_precip = next.weather_precipitation.data();
            lanes.weather_type = next.weather_type.data();
            if (_distribute_field_init_scratch.size() != cells) {
                _distribute_field_init_scratch.assign(cells, 1u);
            }
            lanes.weather_field_init = _distribute_field_init_scratch.data();

            pk_async_climate::WeatherDistributeState state;
            state.accumulated_snow_days = _distribute_acc_snow_scratch.data();
            state.pre_snow_cover = _distribute_pre_cover_scratch.data();

            pk_async_climate::WeatherDistributeEmit emit;
            pk_async_climate::weather_distribute_pure(wd.knobs, lanes, state, emit);
            // ABI 8：distribute 就地改 cover scratch，写回 worker store 供 writeback。
            if (_distribute_cover_scratch.size() == cells &&
                next.cover.size() == cells) {
                std::memcpy(next.cover.data(), _distribute_cover_scratch.data(),
                            cells);
            }
            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
            return static_cast<uint64_t>(cells) * 8u;
        });
    }

    // ─── stage 12 RUNTIME_HYDROLOGY（共享纯内核，runtime_hydrology_stride）──────
    //
    // 这一段的状态几乎全是 store 成员，所以它是目前 parity 信号最强的一段：
    //
    //   worker 自己那一份（被对拍的量）：moisture / plant_available_water /
    //       water_balance_30d / runoff / groundwater / river_storage /
    //       river_discharge / riparian_moisture，以及 soil_moisture 与
    //       river_discharge_30d、canal_water 这三条 scratch。前八条都是逐日累积的
    //       水量账，一天算错就再也回不来，所以这里不能拿生产的初值播种。
    //   生产记录那一份：降水 / 天气类型 / 温度 / 热输入 / 积雪 / 植被活力 / 运河
    //       掩码等读 lane —— 它们的生产者（weather distribute / pass_b / 演替）还没
    //       提取，或者根本不是 climate stage。
    //
    // hydro_parent 直接取 environment 快照那份：它只在地图生成/regen 时重建，快照
    // 本来就带着它，再往 HydrologyInput 里抄一遍纯属每天多拷一张全图 int32。
    const bool shared_hydrology_ran = hydrology_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_hydrology_ran) {
        run_stage(report, RuntimeClimateStage::RUNTIME_HYDROLOGY, [&]() {
            const pk_async_climate::HydrologyInput &hy = *input.climate_hydrology;
            const auto &neighbors = input.climate_round_static_knobs.neighbor_indices;
            if (hy.has_river.size() != cells || hy.terrain.size() != cells ||
                hy.landform.size() != cells || hy.vegetation.size() != cells ||
                hy.cover.size() != cells || hy.elevation.size() != cells ||
                hy.precip.size() != cells || hy.intensity.size() != cells ||
                hy.weather_type.size() != cells || hy.temp.size() != cells ||
                hy.heat.size() != cells || hy.snowpack.size() != cells ||
                hy.base_moisture.size() != cells || hy.is_water.size() != cells ||
                hy.vitality.size() != cells || hy.canal_mask.size() != cells ||
                hy.soil_moisture.size() != cells ||
                hy.discharge_30d.size() != cells ||
                input.hydro_parent.size() != cells ||
                next.moisture.size() != cells ||
                next.plant_available_water.size() != cells ||
                next.water_balance_30d.size() != cells ||
                next.runoff.size() != cells || next.groundwater.size() != cells ||
                next.river_storage.size() != cells ||
                next.river_discharge.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                return static_cast<uint64_t>(0);
            }
            // soil_moisture / river_discharge_30d / canal_water 没有 store 成员。前两
            // 条都是 in/out 的累积量，用 scratch 承接生产读到的初值再丢弃 —— 与
            // feedback 的 soil_moisture 同处理。canal_water 是每轮重算的派生量。
            _hydrology_soil_scratch = hy.soil_moisture;
            _hydrology_q30_scratch = hy.discharge_30d;
            if (hy.canal_water.size() == cells) {
                // 与 soil / q30 同理：canal_water 跨日存活，必须每天回到生产读到的
                // 初值。只在首次分配就等于让 worker 带着自己那份独立累积往邻格灌水。
                _hydrology_canal_water_scratch = hy.canal_water;
            } else if (_hydrology_canal_water_scratch.size() != cells) {
                _hydrology_canal_water_scratch.assign(cells, 0.0f);
            }

            pk_async_climate::HydrologyLanes lanes;
            lanes.hydro_parent = input.hydro_parent.data();
            lanes.has_river = hy.has_river.data();
            lanes.terrain = hy.terrain.data();
            lanes.landform = hy.landform.data();
            lanes.vegetation = hy.vegetation.data();
            lanes.cover = hy.cover.data();
            lanes.elevation = hy.elevation.data();
            lanes.precip = hy.precip.data();
            lanes.intensity = hy.intensity.data();
            lanes.weather_type = hy.weather_type.data();
            lanes.temp = hy.temp.data();
            lanes.heat = hy.heat.data();
            lanes.snowpack = hy.snowpack.data();
            lanes.base_moisture = hy.base_moisture.data();
            lanes.is_water = hy.is_water.data();
            lanes.vitality = hy.vitality.data();
            lanes.canal_mask = hy.canal_mask.data();
            lanes.neighbor_indices = (hy.has_neighbors && neighbors.size() >= cells * 6u)
                ? neighbors.data() : nullptr;
            lanes.moisture = next.moisture.data();
            lanes.soil_moisture = _hydrology_soil_scratch.data();
            lanes.water_balance_30d = next.water_balance_30d.data();
            lanes.plant_water = next.plant_available_water.data();
            lanes.discharge = next.river_discharge.data();
            lanes.discharge_30d = _hydrology_q30_scratch.data();
            lanes.river_storage = next.river_storage.data();
            lanes.groundwater = next.groundwater.data();
            lanes.runoff = next.runoff.data();
            lanes.canal_water = _hydrology_canal_water_scratch.data();

            _hydrology_canal.topology_generation = hy.canal_topology_generation;
            pk_async_climate::HydrologyStats stats;
            pk_async_climate::hydrology_pass_pure(hy.knobs, lanes, _hydrology_canal,
                                                _hydrology_scratch, stats);
            // riparian_moisture 是 store 成员但生产侧没有对应 slot（分叉表里标
            // map_data.gd declares no riparian_moisture_arr）。它的物理定义就是河道
            // 影响后的可用水，这里跟着 plant_available_water 走，免得停在昨天的值。
            if (next.riparian_moisture.size() == cells) {
                for (size_t i = 0; i < cells; ++i) {
                    next.riparian_moisture[i] = next.plant_available_water[i];
                }
            }
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_RUNTIME_HYDROLOGY;
            return static_cast<uint64_t>(cells) * 11u;
        });
    }

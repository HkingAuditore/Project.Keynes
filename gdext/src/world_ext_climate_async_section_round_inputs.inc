bool DCWorldExt::override_climate_round_input_from_slots(int n_cells,
        pk_async_climate::ClimateInputBuf &buf) {
    if (!_bound || n_cells <= 0) return false;

    // 只覆盖 pass_a 真正读的 slot-backed lane。maritime_factor 不是 slot（由
    // cp_struct 侧携带），radiative modifier 与 insol LUT 由调用方烘焙。
    struct F32Lane { const char *component; std::vector<float> *dst; bool required; };
    struct U8Lane  { const char *component; std::vector<uint8_t> *dst; bool required; };
    const F32Lane f32_lanes[] = {
        {"cell_elevation",          &buf.elevation,         true},
        {"cell_base_moisture",      &buf.base_moisture,     true},
        {"cell_lat_norm",           &buf.lat_norm,          true},
        {"cell_temp_baseline_year", &buf.temp_baseline_year, true},
        {"cell_temp",               &buf.temp,              true},
        {"cell_temp_30d",           &buf.temp_30d,          true},
        {"cell_temp_365d",          &buf.temp_365d,         true},
        {"cell_thermal_energy",     &buf.thermal_energy,    true},
        {"cell_snowpack",           &buf.snowpack,          true},
        {"cell_moisture",           &buf.moisture,          true},
        // 可选水文列：slot 缺失时清空，让内核走"这条 lane 不参与"的分支——与
        // run_climate_pass_a 里 nullptr 指针的语义一致。
        {"cell_weather_vapor",      &buf.weather_vapor,     false},
        {"cell_weather_precip",     &buf.weather_precip,    false},
        {"cell_soil_moisture",      &buf.soil_moisture,     false},
        {"cell_water_balance_30d",  &buf.water_balance_30d, false},
    };
    const U8Lane u8_lanes[] = {
        {"cell_is_water",        &buf.is_water,        true},
        {"cell_terrain",         &buf.terrain,         true},
        {"cell_cover",           &buf.cover,           true},
        {"cell_ema_initialized", &buf.ema_initialized, true},
    };

    // 先整体校验，避免只覆盖一半 lane 留下混合来源的 buffer。
    for (const F32Lane &lane : f32_lanes) {
        const int sid = component_id(StringName(lane.component));
        const bool ok = sid >= 0 && _slots.write[sid].arr_f32.size() == n_cells;
        if (!ok && lane.required) return false;
    }
    for (const U8Lane &lane : u8_lanes) {
        const int sid = component_id(StringName(lane.component));
        const bool ok = sid >= 0 && _slots.write[sid].arr_u8.size() == n_cells;
        if (!ok && lane.required) return false;
    }

    for (const F32Lane &lane : f32_lanes) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_f32.size() != n_cells) {
            lane.dst->clear();
            continue;
        }
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_f32.ptr(),
                    size_t(n_cells) * sizeof(float));
    }
    for (const U8Lane &lane : u8_lanes) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_u8.size() != n_cells) {
            lane.dst->clear();
            continue;
        }
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_u8.ptr(), size_t(n_cells));
    }

    // ─── pass_b..sea_ice 读的 slot-backed lane ────────────────────────────
    //
    // 这些 lane 此前只从 GDScript 的 round-input Dictionary 取，而那份 Dictionary
    // 走的是 MapData 镜像。风场是纯 slot 产物（physics 只写 DCWorldExt slot，从不
    // 回灌 MapData），于是 worker 拿到的 wind_x/wind_y/wind_speed 是长度对、内容
    // 全零的数组 —— 长度对所以 pass 守卫全过、不报 starve，但 wind_air 每个 cell
    // 都在 wind_len2 < 1e-6 处 continue，wind_surface 的平流权重全被跳过，weather
    // solve 也拿不到风。分叉矩阵里 temperature 的 2266 格、vapor 的全图偏移、
    // precipitation 归零，都是这一条。
    //
    // 与上面两组的区别：slot 不可用时**保留** Dictionary 给的内容而不是清空。
    // 清空会把当前唯一的来源也一并抹掉，比拿到零值更糟。
    struct OverlayF32 { const char *component; std::vector<float> *dst; };
    struct OverlayU8  { const char *component; std::vector<uint8_t> *dst; };
    const OverlayF32 overlay_f32[] = {
        // wind_air / wind_surface / weather solve
        {"cell_wind_x",                        &buf.wind_x},
        {"cell_wind_y",                        &buf.wind_y},
        {"cell_wind_speed",                    &buf.wind_speed},
        // 邻居方向几何（pass_b / ocean_* / wind_* 都用）
        {"cell_pos_x",                         &buf.pos_x},
        {"cell_pos_y",                         &buf.pos_y},
        // pass_b
        {"cell_insolation_dev",                &buf.insolation_dev},
        {"cell_temperature_transport_anomaly", &buf.temp_transport_anomaly},
        // wind_surface 的合成 baseline 与 air anomaly 快照
        {"cell_temp_baseline",                 &buf.temp_baseline},
        {"cell_air_mass_temp_anomaly",         &buf.air_mass_temp_anomaly},
        // ocean_water / ocean_land
        {"cell_ocean_current_x",               &buf.ocean_current_x},
        {"cell_ocean_current_y",               &buf.ocean_current_y},
        {"cell_ocean_thermal_anomaly",         &buf.ocean_thermal_anomaly},
        // sea_ice
        {"cell_upwelling_strength",            &buf.upwelling_strength},
        {"cell_insolation_now",                &buf.insolation_now},
        {"cell_sea_ice_frac",                  &buf.sea_ice_frac_inout},
    };
    const OverlayU8 overlay_u8[] = {
        {"cell_landform",     &buf.landform},
        {"cell_vegetation",   &buf.vegetation},
        {"cell_base_terrain", &buf.base_terrain},
    };
    for (const OverlayF32 &lane : overlay_f32) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_f32.size() != n_cells) continue;
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_f32.ptr(),
                    size_t(n_cells) * sizeof(float));
    }
    for (const OverlayU8 &lane : overlay_u8) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_u8.size() != n_cells) continue;
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_u8.ptr(), size_t(n_cells));
    }
    return true;
}


void DCWorldExt::fill_climate_round_input(const Dictionary &input, int n_cells,
                                          pk_async_climate::ClimateInputBuf &buf,
                                          bool prefer_slot_lanes) {
    using namespace pk_async_climate;
    if (n_cells <= 0) {
        buf = ClimateInputBuf{};
        return;
    }
    buf.n_cells = n_cells;

    // Stage 1 字段（transp 读）
    _read_pu8_to_vec(input,  "landform",   buf.landform,   n_cells);
    _read_pu8_to_vec(input,  "vegetation", buf.vegetation, n_cells);
    _read_pf32_to_vec(input, "moisture",   buf.moisture,   n_cells);

    // Stage 2 字段（pass_a 读）。如不提供则填空（0）；worker 内的 pass_a
    // 维度校验会拒绝跑（passes_mask & 0x01 但 is_water.size() != n_cells）。
    _read_pu8_to_vec(input,  "is_water",            buf.is_water,            n_cells);
    _read_pu8_to_vec(input,  "terrain",             buf.terrain,             n_cells);
    _read_pu8_to_vec(input,  "cover",               buf.cover,               n_cells);
    _read_pu8_to_vec(input,  "ema_initialized",     buf.ema_initialized,     n_cells);
    _read_pf32_to_vec(input, "elevation",           buf.elevation,           n_cells);
    _read_pf32_to_vec(input, "base_moisture",       buf.base_moisture,       n_cells);
    _read_pf32_to_vec(input, "weather_vapor",       buf.weather_vapor,       n_cells);
    _read_pf32_to_vec(input, "weather_precip",      buf.weather_precip,      n_cells);
    _read_pf32_to_vec(input, "soil_moisture",       buf.soil_moisture,       n_cells);
    _read_pf32_to_vec(input, "water_balance_30d",   buf.water_balance_30d,   n_cells);
    _read_pf32_to_vec(input, "lat_norm",            buf.lat_norm,            n_cells);
    // [climate-zone-fix P2] 海洋性调温因子（静态 per-cell；缺省空→不调温）
    _read_pf32_to_vec(input, "maritime_factor",     buf.maritime,            n_cells);
    _read_pf32_to_vec(input, "temp_baseline_year",  buf.temp_baseline_year,  n_cells);
    _read_pf32_to_vec(input, "temp",                buf.temp,                n_cells);
    _read_pf32_to_vec(input, "temp_30d",            buf.temp_30d,            n_cells);
    _read_pf32_to_vec(input, "temp_365d",           buf.temp_365d,           n_cells);
    _read_pf32_to_vec(input, "thermal_energy",      buf.thermal_energy,      n_cells);
    _read_pf32_to_vec(input, "snowpack",            buf.snowpack,            n_cells);
    buf.radiative_modifier_add.assign(
        static_cast<size_t>(n_cells), 0.0f);
    buf.radiative_modifier_factor.assign(
        static_cast<size_t>(n_cells), 1.0f);
    if (_modifier_runtime != nullptr) {
        const ModifierRuntime *modifier =
            static_cast<const ModifierRuntime *>(_modifier_runtime);
        for (int cell = 0; cell < n_cells; ++cell) {
            double add = 0.0;
            double factor = 1.0;
            modifier->climate_radiative_terms(cell, add, factor);
            buf.radiative_modifier_add[static_cast<size_t>(cell)] =
                static_cast<float>(add);
            buf.radiative_modifier_factor[static_cast<size_t>(cell)] =
                static_cast<float>(factor);
        }
    }

    // Stage 2 字段（pass_b 读）。snow_cover/moisture 与 pass_a 共享。
    _read_pf32_to_vec(input, "pos_x",                     buf.pos_x,                     n_cells);
    _read_pf32_to_vec(input, "pos_y",                     buf.pos_y,                     n_cells);
    _read_pf32_to_vec(input, "insolation_dev",            buf.insolation_dev,            n_cells);
    _read_pf32_to_vec(input, "temp_transport_anomaly",    buf.temp_transport_anomaly,    n_cells);
    _read_pf32_to_vec(input, "local_thermal_anomaly",     buf.local_thermal_anomaly,     n_cells);
    _read_pf32_to_vec(input, "sea_ice_frac",              buf.sea_ice_frac,              n_cells);

    // Stage 2 字段（ocean_water/ocean_land 读）
    _read_pf32_to_vec(input, "ocean_current_x",           buf.ocean_current_x,           n_cells);
    _read_pf32_to_vec(input, "ocean_current_y",           buf.ocean_current_y,           n_cells);
    _read_pf32_to_vec(input, "ocean_thermal_anomaly",     buf.ocean_thermal_anomaly,     n_cells);

    // Stage 2 字段（wind_air/wind_surface 读）
    _read_pf32_to_vec(input, "wind_x",                    buf.wind_x,                    n_cells);
    _read_pf32_to_vec(input, "wind_y",                    buf.wind_y,                    n_cells);
    _read_pf32_to_vec(input, "wind_speed",                buf.wind_speed,                n_cells);
    _read_pf32_to_vec(input, "temp_baseline",             buf.temp_baseline,             n_cells);
    _read_pf32_to_vec(input, "air_mass_temp_anomaly",     buf.air_mass_temp_anomaly,     n_cells);

    // Stage 2 字段（sea_ice 读）
    _read_pu8_to_vec(input,  "base_terrain",              buf.base_terrain,              n_cells);
    _read_pf32_to_vec(input, "upwelling_strength",        buf.upwelling_strength,        n_cells);
    _read_pf32_to_vec(input, "insolation_now",            buf.insolation_now,            n_cells);
    _read_pf32_to_vec(input, "cell_temperature_arr",      buf.cell_temperature_arr,      n_cells);
    _read_pf32_to_vec(input, "sea_ice_frac_inout",        buf.sea_ice_frac_inout,        n_cells);
    _read_pu8_to_vec(input,  "water_terrain_ids",         buf.water_terrain_ids,         0);

    // Round-level scalars
    buf.scalars.season_phase     = double(input.get("season_phase", 0.0));
    buf.scalars.axial_tilt_deg   = double(input.get("axial_tilt_deg", 23.5));
    buf.scalars.day_length_gain  = double(input.get("day_length_gain", 0.35));
    buf.scalars.solar_gain       = double(input.get("solar_gain", 1.0));
    buf.scalars.insol_amp        = double(input.get("insol_amp", 0.20));
    buf.scalars.insol_gain       = double(input.get("insol_gain", 1.0));
    buf.scalars.moist_scale_now  = double(input.get("moist_scale_now", 1.0));
    buf.scalars.runtime_moisture_base_relax_rate = float(input.get("runtime_moisture_base_relax_rate", 0.24));
    buf.scalars.runtime_moisture_weather_vapor_weight = float(input.get("runtime_moisture_weather_vapor_weight", 0.12));
    buf.scalars.runtime_moisture_precip_weight = float(input.get("runtime_moisture_precip_weight", 0.78));
    buf.scalars.runtime_moisture_soil_weight = float(input.get("runtime_moisture_soil_weight", 1.82));
    buf.scalars.runtime_moisture_soil_dry_weight = float(input.get("runtime_moisture_soil_dry_weight", 2.21));
    buf.scalars.runtime_moisture_water_balance_weight = float(input.get("runtime_moisture_water_balance_weight", 1.04));
    buf.scalars.runtime_moisture_water_balance_dry_weight = float(input.get("runtime_moisture_water_balance_dry_weight", 1.30));
    buf.scalars.days_per_year    = int(input.get("days_per_year", 365));
    buf.scalars.sea_level        = double(input.get("sea_level", 0.5));
    // pass_a 扩展 scalars
    buf.scalars.insol_dev_min               = double(input.get("insol_dev_min", -1.0));
    buf.scalars.insol_dev_max               = double(input.get("insol_dev_max", 1.0));
    buf.scalars.thermal_inertia_land        = double(input.get("thermal_inertia_land", 0.35));
    buf.scalars.thermal_inertia_water       = double(input.get("thermal_inertia_water", 0.045));
    buf.scalars.thermal_inertia_snow        = double(input.get("thermal_inertia_snow", 0.09));
    buf.scalars.thermal_inertia_high_mountain = double(input.get("thermal_inertia_high_mountain", 0.16));
    buf.scalars.thermal_daily_delta_cap     = double(input.get("thermal_daily_delta_cap", 0.15));
    buf.scalars.thermal_dt_days             = double(input.get("thermal_dt_days", 1.0));
    buf.scalars.snowpack_cover_low          = double(input.get("snowpack_cover_low", 0.05));
    buf.scalars.snowpack_cover_full         = double(input.get("snowpack_cover_full", 0.32));
    buf.scalars.maritime_season_damp        = double(input.get("maritime_season_damp", 0.0));
    // transp scalars
    buf.scalars.transp_outflow_rate = float(input.get("transp_outflow_rate", 0.025));
    buf.scalars.transp_self_rate    = float(input.get("transp_self_rate", 0.015));

    // pass_b scalars（Stage 2）
    buf.scalars.pb_winter_boost  = float(input.get("pb_winter_boost", 1.0));
    buf.scalars.pb_snow_cool     = float(input.get("pb_snow_cool", 0.0));
    buf.scalars.pb_veg_cool      = float(input.get("pb_veg_cool", 0.0));
    buf.scalars.pb_diurnal_amp   = float(input.get("pb_diurnal_amp", 0.0));
    buf.scalars.pb_evap_gain     = float(input.get("pb_evap_gain", 0.0));
    buf.scalars.pb_rs_threshold  = float(input.get("pb_rs_threshold", 0.0));
    buf.scalars.pb_rs_factor     = float(input.get("pb_rs_factor", 1.0));
    buf.scalars.pb_rs_lookback   = int(input.get("pb_rs_lookback", 0));
    buf.scalars.pb_t_freeze      = float(input.get("pb_t_freeze", 0.0));
    buf.scalars.pb_coupling_gain = float(input.get("pb_coupling_gain", 0.0));
    buf.scalars.pb_coast_leak    = float(input.get("pb_coast_leak", 0.0));
    buf.scalars.pb_sea_ice_albedo_cooling = float(input.get("pb_sea_ice_albedo_cooling", 0.01));

    // seam-advection-fix：环绕周期。常驻值优先，input 显式给了才覆盖（单测用）。
    buf.scalars.wrap_period_x = float(input.get("wrap_period_x", _native_wrap_period_x));

    // ocean_water / ocean_land scalars（Stage 2）
    buf.scalars.ow_advect_steps  = int(input.get("ow_advect_steps", 3));
    buf.scalars.ow_heat_mix      = float(input.get("ow_heat_mix", 0.55));
    buf.scalars.ow_tta_source_cap = float(input.get("ow_tta_source_cap", 0.22));
    buf.scalars.ow_cold_transport_form =
        float(input.get("ow_cold_transport_form", 0.06));
    buf.scalars.ow_cold_transport_melt =
        float(input.get("ow_cold_transport_melt", 0.11));
    buf.scalars.ow_tta_blend_rate = float(input.get("ow_tta_blend_rate", 0.70));
    buf.scalars.ow_tta_zero_current_decay = float(input.get("ow_tta_zero_current_decay", 0.06));
    buf.scalars.ol_effective_leak = float(input.get("ol_effective_leak", 0.55));
    buf.scalars.ol_tta_source_cap = float(input.get("ol_tta_source_cap", 0.22));
    buf.scalars.ol_tta_blend_rate = float(input.get("ol_tta_blend_rate", 0.70));
    buf.scalars.ol_tta_decay_rate = float(input.get("ol_tta_decay_rate", 0.04));

    // wind_air / wind_surface scalars（Stage 2）
    buf.scalars.wa_advect_steps = int(input.get("wa_advect_steps", 3));
    buf.scalars.wa_heat_mix     = float(input.get("wa_heat_mix", 0.25));
    buf.scalars.ws_air_leak     = float(input.get("ws_air_leak", 0.35));
    buf.scalars.ws_cold_transport_form = float(input.get("ws_cold_transport_form", 0.06));
    buf.scalars.ws_cold_transport_melt = float(input.get("ws_cold_transport_melt", 0.11));

    // sea_ice scalars（Stage 2）
    buf.scalars.si_k_freeze     = float(input.get("si_k_freeze", 0.40));
    buf.scalars.si_k_melt       = float(input.get("si_k_melt", 1.45));
    buf.scalars.si_t_form       = float(input.get("si_t_form", 0.06));
    buf.scalars.si_t_melt       = float(input.get("si_t_melt", 0.11));
    buf.scalars.si_contagion    = float(input.get("si_contagion", 0.035));
    buf.scalars.si_threshold    = float(input.get("si_threshold", 0.68));
    buf.scalars.si_hysteresis   = float(input.get("si_hysteresis", 0.12));
    buf.scalars.si_ice_delay    = float(input.get("si_ice_delay", 1.0));
    buf.scalars.si_enable_oht   = bool(input.get("si_enable_oht", true));
    buf.scalars.si_apply_terrain_flips = bool(input.get("si_apply_terrain_flips", false));
    buf.scalars.si_solar_gate_enabled = bool(input.get("si_solar_gate_enabled", true));
    buf.scalars.si_freeze_insol_low  = float(input.get("si_freeze_insol_low", 0.22));
    buf.scalars.si_freeze_insol_high = float(input.get("si_freeze_insol_high", 0.45));
    buf.scalars.si_solar_melt_start  = float(input.get("si_solar_melt_start", 0.28));
    buf.scalars.si_solar_melt_gain   = float(input.get("si_solar_melt_gain", 1.35));
    buf.scalars.si_min_thick_ice_solar_exposure = float(input.get("si_min_thick_ice_solar_exposure", 0.32));
    buf.scalars.si_daily_delta_cap   = float(input.get("si_daily_delta_cap", 0.070));
    buf.scalars.si_edge_mix_rate     = float(input.get("si_edge_mix_rate", 0.035));
    buf.scalars.si_dt_days           = float(input.get("si_dt_days", 1.0));
    buf.scalars.si_terrain_lake_id    = int(input.get("si_terrain_lake_id", -1));
    buf.scalars.si_terrain_sea_ice_id = int(input.get("si_terrain_sea_ice_id", -1));
    buf.scalars.si_terrain_ocean_id   = int(input.get("si_terrain_ocean_id", -1));

    // ─── finalizer pass fields（Stage 9，2026-06-16） ─────────────────
    // _temp_start_of_day_arr / _tta_start_of_day_arr / sea_ice_frac_prev /
    // weather_precip 由 GDScript 主线程在 begin_round 时打快照传入。
    _read_pf32_to_vec(input, "fin_temp_start_of_day",   buf.temp_start_of_day,   n_cells);
    _read_pf32_to_vec(input, "fin_tta_start_of_day",    buf.tta_start_of_day,    n_cells);
    _read_pf32_to_vec(input, "fin_sea_ice_frac_prev",   buf.sea_ice_frac_prev,   n_cells);
    _read_pf32_to_vec(input, "fin_weather_precip",      buf.weather_precip,      n_cells);
    buf.scalars.fin_temp_cap_enabled = bool(input.get("fin_temp_cap_enabled", true));
    buf.scalars.fin_temp_cap         = float(input.get("fin_temp_cap", 0.15));
    buf.scalars.fin_tta_cap          = float(input.get("fin_tta_cap", 0.12));
    buf.scalars.fin_has_temp_start   = bool(input.get("fin_has_temp_start", false));
    buf.scalars.fin_has_tta_start    = bool(input.get("fin_has_tta_start", false));

    // passes_mask（默认 0x1FF 含 finalizer bit）
    buf.scalars.passes_mask = int(input.get("passes_mask", 0x1FF));

    // ─── S3：把 pass_a 的 per-cell lane 换成 _slots 的内容 ─────────────────
    // 必须在下面烘焙 insol LUT 之前做，因为 LUT 由 buf.lat_norm 导出。
    if (prefer_slot_lanes) {
        override_climate_round_input_from_slots(n_cells, buf);
    }

    // ─── Item 4 (perf 2026-07-05)：主线程预烘焙年均日照 LUT ────────────────
    // pass_a worker 每 cell 需 dc_insolation_annual_mean(clamp01(ny), axial_tilt, daylen)，
    // 该值 season-无关（16×9 trig/cell）。async kernel 跑在 worker thread、无法安全用 member
    // 缓存，故在此（持锁、主线程）按 lat_norm 逐 cell 预算好，worker 直接读 → bit-equal。
    // 仅 pass_a 参与时（passes_mask & 0x01）才烘焙，省无谓开销；否则清空退回 inline。
    if ((buf.scalars.passes_mask & 0x01) != 0 &&
        (int)buf.lat_norm.size() == n_cells) {
        const float ax_tilt = float(buf.scalars.axial_tilt_deg);
        const float dl_amp  = float(buf.scalars.day_length_gain);
        const float *mean = ensure_insol_annual_mean_cache(
            buf.lat_norm.data(), n_cells, ax_tilt, dl_amp);
        buf.insol_annual_mean.assign(mean, mean + n_cells);
    } else {
        buf.insol_annual_mean.clear();
    }

}

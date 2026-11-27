double DCWorldExt::run_transpiration_pass(Dictionary knobs) {
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_TRANSPIRATION;
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_transpiration_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_landform   = component_id(StringName("cell_landform"));
    const int sid_vegetation = component_id(StringName("cell_vegetation"));
    const int sid_moisture   = component_id(StringName("cell_moisture"));
    if (sid_landform < 0 || sid_vegetation < 0 || sid_moisture < 0) {
        diag("missing slot id (cell_landform / cell_vegetation / cell_moisture)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("outflow_rate") ||
        !knobs.has("self_rate") || !knobs.has("neighbor_indices") ||
        !knobs.has("donor_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int   n_cells     = int(knobs["n_cells"]);
    const float outflow_rate = float(knobs["outflow_rate"]);
    const float self_rate    = float(knobs["self_rate"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array   nb_arr     = knobs["neighbor_indices"];
    PackedFloat32Array donor_arr  = knobs["donor_table"];
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells * 6");
        return -1.0;
    }
    const int donor_size = donor_arr.size();
    if (donor_size <= 0) { diag("donor_table empty"); return -1.0; }

    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_vegetation];
    Slot &s_moist    = _slots.write[sid_moisture];
    if (s_landform.arr_u8.size() != n_cells ||
        s_veg.arr_u8.size()      != n_cells ||
        s_moist.arr_f32.size()   != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    // S3：算法体是共享纯内核，与 async round 和 SHADOW worker 完全同一份代码。
    // 这里只负责 slot → buffer → slot 的搬运；transpiration 不再有第二份实现。
    using namespace pk_async_climate;
    ClimateInputBuf &tin = _transp_sync_input_buf;
    ClimateOutputBuf &tout = _transp_sync_output_buf;
    ClimateRoundStaticKnobs tknobs;
    tin.n_cells = n_cells;
    tin.landform.assign(s_landform.arr_u8.ptr(), s_landform.arr_u8.ptr() + n_cells);
    tin.vegetation.assign(s_veg.arr_u8.ptr(), s_veg.arr_u8.ptr() + n_cells);
    tin.moisture.assign(s_moist.arr_f32.ptr(), s_moist.arr_f32.ptr() + n_cells);
    tin.scalars.transp_outflow_rate = outflow_rate;
    tin.scalars.transp_self_rate = self_rate;
    tknobs.n_cells = n_cells;
    tknobs.neighbor_indices.assign(nb_arr.ptr(), nb_arr.ptr() + n_cells * 6);
    tknobs.donor_table.assign(donor_arr.ptr(), donor_arr.ptr() + donor_size);

    if (!_async_transp_kernel_pure(tin, tknobs, _transp_sync_work_buf, tout)) {
        diag("shared transp kernel rejected input dimensions");
        return -1.0;
    }
    auto t_compute = std::chrono::high_resolution_clock::now();

    // 内核的 dirty 列表就是"哪些 cell 真的变了"，直接转成 Godot 侧的两条数组，
    // 不再重新扫一遍。
    float * const __restrict M = s_moist.arr_f32.ptrw();
    const int dirty_count = (int)tout.moisture_dirty_indices.size();
    PackedInt32Array dirty_indices;
    PackedFloat32Array dirty_values;
    dirty_indices.resize(dirty_count);
    dirty_values.resize(dirty_count);
    for (int k = 0; k < dirty_count; ++k) {
        const int32_t idx = tout.moisture_dirty_indices[k];
        const float value = tout.moisture_dirty_values[k];
        M[idx] = value;
        dirty_indices.set(k, idx);
        dirty_values.set(k, value);
    }
    knobs["dirty_indices"] = dirty_indices;
    knobs["dirty_values"] = dirty_values;
    knobs["dirty_count"] = dirty_count;
    auto t_apply = std::chrono::high_resolution_clock::now();

    // §11.2 flush: push CoW-detached cell_moisture back to MapData
    if (!bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moisture);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    knobs["compute_ms"] = std::chrono::duration<double, std::milli>(t_compute - t0).count();
    knobs["apply_ms"] = std::chrono::duration<double, std::milli>(t_apply - t_compute).count();
    knobs["flush_ms"] = std::chrono::duration<double, std::milli>(t1 - t_apply).count();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

Dictionary DCWorldExt::run_runtime_hydrology_pass(const Dictionary &knobs) {
    SimTraceWriteGuard sim_trace_guard{this, "run_runtime_hydrology_pass"};
    using godot::PackedFloat32Array;
    using godot::StringName;

    Dictionary out;
    const auto t0 = std::chrono::high_resolution_clock::now();
    auto fail = [&](const char *why) -> Dictionary {
        const auto t1 = std::chrono::high_resolution_clock::now();
        out["done"] = true;
        out["path"] = "gdext";
        out["fallback_reason"] = why;
        out["published_to_slot"] = false;
        out["native_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["compute_ms"] = 0.0;
        out["flush_ms"] = 0.0;
        out["n_cells"] = 0;
        out["water_budget_error"] = 0.0;
        out["river_discharge_p95"] = 0.0;
        out["river_discharge_max"] = 0.0;
        out["moisture_response_alpha"] = 0.0;
        out["river_moisture_max_delta"] = 0.0;
        out["riparian_moisture_max_delta"] = 0.0;
        out["flood_candidate_count"] = 0;
        return out;
    };

    if (!_bound) return fail("world_ext_not_bound");

    const int sid_hparent = component_id(StringName("cell_hydro_parent"));
    const int sid_has_riv = component_id(StringName("cell_has_river"));
    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_veg = component_id(StringName("cell_vegetation"));
    const int sid_cover = component_id(StringName("cell_cover"));
    const int sid_precip = component_id(StringName("cell_weather_precip"));
    const int sid_intensity = component_id(StringName("cell_weather_intensity"));
    const int sid_wtype = component_id(StringName("cell_weather_type"));
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_heat = component_id(StringName("cell_heat_input"));
    const int sid_snowpack = component_id(StringName("cell_snowpack"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_base_m = component_id(StringName("cell_base_moisture"));
    const int sid_soil = component_id(StringName("cell_soil_moisture"));
    const int sid_wb30 = component_id(StringName("cell_water_balance_30d"));
    const int sid_plant_water = component_id(StringName("cell_plant_available_water"));
    const int sid_is_water = component_id(StringName("cell_is_water"));
    const int sid_vital = component_id(StringName("cell_vegetation_vitality"));
    const int sid_q = component_id(StringName("cell_river_discharge"));
    const int sid_q30 = component_id(StringName("cell_river_discharge_30d"));
    const int sid_storage = component_id(StringName("cell_river_storage"));
    const int sid_gw = component_id(StringName("cell_groundwater_storage"));
    const int sid_runoff = component_id(StringName("cell_surface_runoff"));
    const int sid_canal_mask = component_id(StringName("cell_canal_edge_mask"));
    const int sid_canal_water = component_id(StringName("cell_canal_water"));

    const int required[] = {
        sid_hparent, sid_has_riv, sid_terrain, sid_landform, sid_elev, sid_veg, sid_cover,
        sid_precip, sid_intensity, sid_wtype, sid_temp, sid_heat, sid_snowpack, sid_moist,
        sid_base_m, sid_soil, sid_wb30, sid_plant_water, sid_is_water, sid_vital,
        sid_q, sid_q30, sid_storage, sid_gw, sid_runoff,
        sid_canal_mask, sid_canal_water
    };
    for (int sid : required) {
        if (sid < 0 || sid >= int(_slots.size())) return fail("missing_required_slot");
    }

    const int n_cells = knobs.has("n_cells") ? int(knobs["n_cells"]) : int(_entity_archetype.size());
    if (n_cells <= 0) return fail("empty_world");

    auto slot_ok_f32 = [&](int sid) -> bool { return int(_slots.write[sid].arr_f32.size()) >= n_cells; };
    auto slot_ok_i32 = [&](int sid) -> bool { return int(_slots.write[sid].arr_i32.size()) >= n_cells; };
    auto slot_ok_u8 = [&](int sid) -> bool { return int(_slots.write[sid].arr_u8.size()) >= n_cells; };
    if (!slot_ok_i32(sid_hparent) || !slot_ok_u8(sid_has_riv) || !slot_ok_u8(sid_terrain) ||
        !slot_ok_u8(sid_landform) || !slot_ok_f32(sid_elev) || !slot_ok_u8(sid_veg) ||
        !slot_ok_u8(sid_cover) || !slot_ok_f32(sid_precip) || !slot_ok_f32(sid_intensity) ||
        !slot_ok_u8(sid_wtype) || !slot_ok_f32(sid_temp) || !slot_ok_f32(sid_heat) ||
        !slot_ok_f32(sid_snowpack) || !slot_ok_f32(sid_moist) || !slot_ok_f32(sid_base_m) ||
        !slot_ok_f32(sid_soil) || !slot_ok_f32(sid_wb30) ||
        !slot_ok_f32(sid_plant_water) || !slot_ok_u8(sid_is_water) ||
        !slot_ok_f32(sid_vital) ||
        !slot_ok_f32(sid_q) || !slot_ok_f32(sid_q30) || !slot_ok_f32(sid_storage) ||
        !slot_ok_f32(sid_gw) || !slot_ok_f32(sid_runoff) ||
        !slot_ok_u8(sid_canal_mask) || !slot_ok_f32(sid_canal_water)) {
        return fail("slot_size_mismatch");
    }

    // 标量收进 POD 结构体。派生系数（*_eff / *_alpha）不在这里算 —— 它们由
    // hydrology_pass_pure 按 dt_days 自己推，避免生产与 worker 各写一份公式。
    pk_async_climate::HydrologyKnobs hk;
    hk.n_cells = n_cells;
    const auto knob_f = [&knobs](const char *key, float fallback) {
        return knobs.has(key) ? float(knobs[key]) : fallback;
    };
    hk.precip_scale = knob_f("hydro_precip_scale", 1.0f);
    hk.snowmelt_scale = knob_f("hydro_snowmelt_scale", 0.55f);
    hk.soil_capacity = knobs.has("hydro_soil_capacity")
        ? std::max(0.05f, float(knobs["hydro_soil_capacity"])) : 0.75f;
    hk.infiltration_rate = knobs.has("hydro_infiltration_rate")
        ? dc_clampf(float(knobs["hydro_infiltration_rate"]), 0.0f, 1.0f) : 0.52f;
    hk.quickflow_fraction = knobs.has("hydro_quickflow_fraction")
        ? dc_clampf(float(knobs["hydro_quickflow_fraction"]), 0.0f, 1.0f) : 0.36f;
    hk.baseflow_recession = knobs.has("hydro_baseflow_recession")
        ? dc_clampf(float(knobs["hydro_baseflow_recession"]), 0.0f, 1.0f) : 0.035f;
    hk.channel_release = knobs.has("hydro_channel_release_rate")
        ? dc_clampf(float(knobs["hydro_channel_release_rate"]), 0.01f, 1.0f) : 0.62f;
    hk.lake_release = knobs.has("hydro_lake_release_rate")
        ? dc_clampf(float(knobs["hydro_lake_release_rate"]), 0.005f, 1.0f) : 0.18f;
    hk.discharge_ema = knobs.has("hydro_discharge_ema")
        ? dc_clampf(float(knobs["hydro_discharge_ema"]), 0.01f, 1.0f) : 0.08f;
    hk.bank_moisture_gain = knobs.has("hydro_bank_moisture_gain")
        ? dc_clampf(float(knobs["hydro_bank_moisture_gain"]), 0.0f, 0.25f) : 0.035f;
    hk.river_moisture_floor = knobs.has("hydro_river_moisture_floor")
        ? dc_clampf(float(knobs["hydro_river_moisture_floor"]), 0.0f, 1.0f) : 0.66f;
    hk.riparian_moisture_floor = knobs.has("hydro_riparian_moisture_floor")
        ? dc_clampf(float(knobs["hydro_riparian_moisture_floor"]), 0.0f, 1.0f) : 0.38f;
    hk.river_evap_gain = knobs.has("hydro_river_evap_gain")
        ? dc_clampf(float(knobs["hydro_river_evap_gain"]), 0.0f, 1.0f) : 0.12f;
    hk.moisture_response_rate = knobs.has("hydro_moisture_response_rate")
        ? dc_clampf(float(knobs["hydro_moisture_response_rate"]), 0.0f, 1.0f) : 0.08f;
    hk.flood_threshold = knobs.has("hydro_flood_threshold")
        ? std::max(0.01f, float(knobs["hydro_flood_threshold"])) : 2.2f;
    hk.snowpack_melt_temp_gain = knob_f("snowpack_melt_temp_gain", 0.22f);
    hk.snowpack_melt_sun_gain = knob_f("snowpack_melt_sun_gain", 0.12f);
    hk.plant_water_balance_weight = knob_f("plant_water_balance_weight", 0.35f);
    hk.plant_soil_buffer_weight = knob_f("plant_soil_buffer_weight", 0.25f);
    hk.plant_drought_penalty = knob_f("plant_drought_penalty", 0.65f);
    hk.dt_days = knobs.has("dt_days")
        ? dc_clampf(float(knobs["dt_days"]), 1.0f, 30.0f) : 1.0f;
    const float moisture_response_alpha =
        1.0f - simulation_math::pow(1.0f - hk.moisture_response_rate, hk.dt_days);
    PackedInt32Array neighbor_indices;
    if (knobs.has("neighbor_indices")) {
        neighbor_indices = knobs["neighbor_indices"];
    }
    const bool has_neighbor_indices = neighbor_indices.size() >= n_cells * 6;

    pk_async_climate::HydrologyLanes hl;
    hl.hydro_parent = _slots.write[sid_hparent].arr_i32.ptr();
    hl.has_river = _slots.write[sid_has_riv].arr_u8.ptr();
    hl.terrain = _slots.write[sid_terrain].arr_u8.ptr();
    hl.landform = _slots.write[sid_landform].arr_u8.ptr();
    hl.vegetation = _slots.write[sid_veg].arr_u8.ptr();
    hl.cover = _slots.write[sid_cover].arr_u8.ptr();
    hl.elevation = _slots.write[sid_elev].arr_f32.ptr();
    hl.precip = _slots.write[sid_precip].arr_f32.ptr();
    hl.intensity = _slots.write[sid_intensity].arr_f32.ptr();
    hl.weather_type = _slots.write[sid_wtype].arr_u8.ptr();
    hl.temp = _slots.write[sid_temp].arr_f32.ptr();
    hl.heat = _slots.write[sid_heat].arr_f32.ptr();
    hl.snowpack = _slots.write[sid_snowpack].arr_f32.ptr();
    hl.base_moisture = _slots.write[sid_base_m].arr_f32.ptr();
    hl.is_water = _slots.write[sid_is_water].arr_u8.ptr();
    hl.vitality = _slots.write[sid_vital].arr_f32.ptr();
    hl.canal_mask = _slots.write[sid_canal_mask].arr_u8.ptr();
    hl.neighbor_indices = has_neighbor_indices ? neighbor_indices.ptr() : nullptr;
    hl.moisture = _slots.write[sid_moist].arr_f32.ptrw();
    hl.soil_moisture = _slots.write[sid_soil].arr_f32.ptrw();
    hl.water_balance_30d = _slots.write[sid_wb30].arr_f32.ptrw();
    hl.plant_water = _slots.write[sid_plant_water].arr_f32.ptrw();
    hl.discharge = _slots.write[sid_q].arr_f32.ptrw();
    hl.discharge_30d = _slots.write[sid_q30].arr_f32.ptrw();
    hl.river_storage = _slots.write[sid_storage].arr_f32.ptrw();
    hl.groundwater = _slots.write[sid_gw].arr_f32.ptrw();
    hl.runoff = _slots.write[sid_runoff].arr_f32.ptrw();
    hl.canal_water = _slots.write[sid_canal_water].arr_f32.ptrw();

    const auto tc0 = std::chrono::high_resolution_clock::now();

    // S3：如实上报"生产这一天跑了 stage 12 RUNTIME_HYDROLOGY"。放在所有守卫之后，
    // 因为上面的 fail() 分支属于"这一天没算"。
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_RUNTIME_HYDROLOGY;

    // stage 12 的数值核心已抽成共享纯内核 pk_async_climate::hydrology_pass_pure。
    // 运河编译态整组抬进 HydrologyCanalState：以前它是五个 DCWorldExt 成员，worker
    // 拿不到，于是水文根本没法在 worker 侧跑。现在主线程与 worker 各持一份、各自按
    // topology_generation 失效。
    _hydrology_canal.topology_generation = _canal_topology_generation;
    pk_async_climate::HydrologyStats hs;
    // 记录给 worker 对拍用的输入。必须在内核之前：MOIST / SOIL / WB30 / Q / Q30 /
    // STORAGE / GW / CANAL_WATER 都是 in/out，跑完再记就变成记结果。
    record_production_hydrology_input(hk, hl, has_neighbor_indices,
                                     _canal_topology_generation, n_cells);
    pk_async_climate::hydrology_pass_pure(hk, hl, _hydrology_canal,
                                        _hydrology_scratch, hs);

    const double water_in_total = hs.water_in_total;
    const double outlet_total = hs.outlet_total;
    const int runoff_source_cells = hs.runoff_source_cells;
    const int river_cells_processed = hs.river_cells_processed;
    const int riparian_neighbor_touches = hs.riparian_neighbor_touches;
    const int river_moisture_floor_touches = hs.river_moisture_floor_touches;
    const int riparian_moisture_floor_touches = hs.riparian_moisture_floor_touches;
    const float river_moisture_max_delta = hs.river_moisture_max_delta;
    const float riparian_moisture_max_delta = hs.riparian_moisture_max_delta;
    const int flood_candidate_count = hs.flood_candidate_count;
    const int canal_cells_processed = hs.canal_cells_processed;
    const int canal_edges_processed = hs.canal_edges_processed;
    const int canal_freshwater_cells = hs.canal_freshwater_cells;
    const int canal_saline_cells = hs.canal_saline_cells;
    const float q_max = hs.q_max;
    const float q_p95 = hs.q_p95;

    const auto tc1 = std::chrono::high_resolution_clock::now();
    const auto tf0 = std::chrono::high_resolution_clock::now();
    _flush_slot_to_map(sid_q);
    _flush_slot_to_map(sid_q30);
    _flush_slot_to_map(sid_storage);
    _flush_slot_to_map(sid_gw);
    _flush_slot_to_map(sid_runoff);
    const bool defer_visual_publish =
        _native_daily_visual_commit_pending || bool(knobs.get("defer_visible_publish", false));
    if (!defer_visual_publish) {
        _flush_slot_to_map(sid_moist);
    }
    _flush_slot_to_map(sid_soil);
    _flush_slot_to_map(sid_wb30);
    _flush_slot_to_map(sid_plant_water);
    _flush_slot_to_map(sid_canal_water);
    const auto tf1 = std::chrono::high_resolution_clock::now();
    const auto t1 = std::chrono::high_resolution_clock::now();

    const double compute_ms = std::chrono::duration<double, std::milli>(tc1 - tc0).count();
    const double flush_ms = std::chrono::duration<double, std::milli>(tf1 - tf0).count();
    const double native_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["done"] = true;
    out["path"] = "gdext";
    out["fallback_reason"] = "";
    out["published_to_slot"] = true;
    out["visible_publish_deferred"] = defer_visual_publish;
    out["native_ms"] = native_ms;
    out["compute_ms"] = compute_ms;
    out["kernel_ms"] = compute_ms;
    out["flush_ms"] = flush_ms;
    out["n_cells"] = n_cells;
    out["processed_cells"] = n_cells;
    out["dt_days"] = hk.dt_days;
    out["runoff_source_cells"] = runoff_source_cells;
    out["river_cells_processed"] = river_cells_processed;
    out["riparian_neighbor_touches"] = riparian_neighbor_touches;
    out["river_moisture_floor_touches"] = river_moisture_floor_touches;
    out["riparian_moisture_floor_touches"] = riparian_moisture_floor_touches;
    out["moisture_response_rate"] = hk.moisture_response_rate;
    out["moisture_response_alpha"] = moisture_response_alpha;
    out["river_moisture_max_delta"] = river_moisture_max_delta;
    out["riparian_moisture_max_delta"] = riparian_moisture_max_delta;
    out["water_budget_error"] = water_in_total > 0.000001 ? std::abs(water_in_total - outlet_total) / water_in_total : 0.0;
    out["river_discharge_p95"] = q_p95;
    out["river_discharge_max"] = q_max;
    out["flood_candidate_count"] = flood_candidate_count;
    out["flood_count"] = flood_candidate_count;
    out["canal_cells_processed"] = canal_cells_processed;
    out["canal_edges_processed"] = canal_edges_processed;
    out["canal_freshwater_cells"] = canal_freshwater_cells;
    out["canal_saline_cells"] = canal_saline_cells;
    return out;
}

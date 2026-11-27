
// ─── F.3 main pass ──────────────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// _climate_pass_b_soa (map_generator.gd:4311+) with these scope cuts:
//   * sparse path (go_sparse=true) → return -1.0 fallback
//   * cell.temperature_breakdown UI dict writes → SKIP
//   * [DIAG pass_b_end] end-of-pass stat print → SKIP (caller can dump SoA)
//
// Algorithm (mirror lines 4396-4523):
//   temp_snapshot = temp_a.duplicate()
//   for each cell i:
//     temp_now = temp_snapshot[i]; moisture_now = moist_a[i]
//     d_albedo = (-snow_cool * SNOW + -veg_cool * foliage)  if !is_water
//     d_coastal = coast_leak * avg(water-nb anomaly) * winter_boost  if !is_water
//     d_landform = +/- diurnal by landform * cell_insolation_dev       if !is_water
//     temp_a[i] = clamp(temp_now + d_albedo + d_coastal + d_landform, 0, 1)
//     d_evap = evap_gain * (t_eff - t_freeze) * nb_water_norm * (1 + coupling*avg_anom)  if !is_water
//     d_rain_shadow = rs_factor if max-upwind-elev - elev[i] >= rs_threshold  if !is_water
//     moist_a[i] = clamp((moisture_now + d_evap) * d_rain_shadow, 0, 1)
namespace {

struct OceanWaterCtx {
    int             n_cells;
    int             advect_steps;
    float           heat_mix;
    // seam-advection-fix：经度环绕周期，0 = 无环绕域（退化为裸差分）。
    float           wrap_period_x;
    float           tta_source_cap;
    float           tta_blend_rate;
    float           tta_zero_current_decay;
    float           cold_transport_form;
    float           cold_transport_melt;
    const int32_t  *NB;        // n_cells * 6
    const uint8_t  *IW;        // n_cells
    const float    *POSX;      // n_cells
    const float    *POSY;      // n_cells
    const float    *OCX;       // n_cells
    const float    *OCY;       // n_cells
    const float    *BL;        // baseline, n_cells
    const float    *TB;        // temp_before, n_cells
    const float    *SIF;       // sea_ice_frac, n_cells
    // A 修复（2026-06）：T 已不再被写；保留只读指针仅作未来诊断。
    const float    *T_RO;
    float          *OANOM_SLOT;// cell_ocean_thermal_anomaly out
    float          *AOUT;      // anomaly_out, n_cells (water cells written)
};

// 单 cell hot kernel：完整复刻 run_ocean_water_pass 主循环 body（line 3160-3206）。
// IW[i]==1 已由 idx 预筛保证，外层无分支。
inline void ocean_water_compute_one(const OceanWaterCtx &c, int i) {
    const float cur_x = c.OCX[i];
    const float cur_y = c.OCY[i];
    const float cur_len2 = cur_x * cur_x + cur_y * cur_y;
    if (cur_len2 < 1e-6f || c.advect_steps == 0) {
        c.AOUT[i] = dc_decay_tta(c.AOUT[i], c.tta_zero_current_decay);
        // A 修复：current 不足时 ocean anomaly 也朝 0 衰减。
        c.OANOM_SLOT[i] = c.OANOM_SLOT[i] * (1.0f - c.tta_zero_current_decay);
        return;
    }
    const float inv_cur = 1.0f / std::sqrt(cur_len2);
    const float up_dx = -cur_x * inv_cur;
    const float up_dy = -cur_y * inv_cur;

    int upstream_idx = i;
    for (int step = 0; step < c.advect_steps; ++step) {
        int   best_idx = -1;
        float best_dot = 0.1f;
        const float swx = c.POSX[upstream_idx];
        const float swy = c.POSY[upstream_idx];
        const int ub = upstream_idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = c.NB[ub + d];
            if (ni < 0) continue;
            if (c.IW[ni] == 0) continue;
            const float dx = pk_wrap_min_image_dx(c.POSX[ni] - swx, c.wrap_period_x);
            const float dy = c.POSY[ni] - swy;
            const float len2 = dx * dx + dy * dy;
            if (len2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(len2);
            const float dot_v = (dx * up_dx + dy * up_dy) * inv_len;
            if (dot_v > best_dot) {
                best_dot = dot_v;
                best_idx = ni;
            }
        }
        if (best_idx < 0) break;
        upstream_idx = best_idx;
    }

    const float temp_self = c.TB[i];
    const float temp_up   = c.TB[upstream_idx];
    float temp_mixed = temp_self + (temp_up - temp_self) * c.heat_mix; // = lerpf
    if (temp_mixed < 0.0f) temp_mixed = 0.0f;
    else if (temp_mixed > 1.0f) temp_mixed = 1.0f;
    float source = temp_mixed - c.BL[i];
    source = pk_limit_cold_water_positive_transport_source(
        source, c.BL[i], c.SIF[i], c.cold_transport_form, c.cold_transport_melt);
    // A 修复（2026-06）：不再写 T；写入 ocean thermal anomaly slot。
    float oanom = source;
    if (oanom < -0.08f) oanom = -0.08f;
    else if (oanom > 0.08f) oanom = 0.08f;
    c.OANOM_SLOT[i] = oanom;
    c.AOUT[i] = dc_stabilize_tta(c.AOUT[i], source, c.tta_source_cap, c.tta_blend_rate);
}

inline void ocean_water_run_water_range(const OceanWaterCtx &c,
                                        const int *water_idx,
                                        int begin, int end) {
    for (int k = begin; k < end; ++k) {
        ocean_water_compute_one(c, water_idx[k]);
    }
}

// [Phase C.3b] 原 OceanWaterTask + ocean_water_worker 已由 parallel_dispatcher.h
// 内的 parallel_for_range 取代。

} // anonymous namespace (ocean water helpers)

static void pk_run_ocean_water_pure(
        int n_cells,
        int advect_steps,
        float heat_mix,
        float wrap_period_x,
        float tta_source_cap,
        float tta_blend_rate,
        float tta_zero_current_decay,
        float cold_transport_form,
        float cold_transport_melt,
        const uint8_t *is_water,
        const float *pos_x,
        const float *pos_y,
        const float *ocean_current_x,
        const float *ocean_current_y,
        const float *baseline,
        const float *temp_before,
        const float *sea_ice_frac,
        const int32_t *neighbors,
        float *ocean_anomaly,
        float *tta_inout) {
    pk_async_climate::OceanWaterKnobs ok;
    ok.n_cells = n_cells;
    ok.start_idx = 0;
    ok.end_idx = n_cells;
    ok.advect_steps = advect_steps;
    ok.heat_mix = heat_mix;
    ok.wrap_period_x = wrap_period_x;
    ok.tta_source_cap = tta_source_cap;
    ok.tta_blend_rate = tta_blend_rate;
    ok.tta_zero_current_decay = tta_zero_current_decay;
    ok.cold_transport_form = cold_transport_form;
    ok.cold_transport_melt = cold_transport_melt;

    pk_async_climate::OceanWaterLanes ol;
    ol.is_water = is_water;
    ol.pos_x = pos_x;
    ol.pos_y = pos_y;
    ol.ocean_current_x = ocean_current_x;
    ol.ocean_current_y = ocean_current_y;
    ol.baseline = baseline;
    ol.temp_before = temp_before;
    ol.sea_ice_frac = sea_ice_frac;
    ol.neighbors = neighbors;
    ol.ocean_anomaly = ocean_anomaly;
    ol.tta_inout = tta_inout;
    pk_async_climate::ocean_water_pure(ok, ol);
}

static void pk_run_ocean_land_pure(
        int n_cells,
        float effective_leak,
        float wrap_period_x,
        float tta_source_cap,
        float tta_blend_rate,
        float tta_decay_rate,
        const uint8_t *is_water,
        const float *pos_x,
        const float *pos_y,
        const float *ocean_current_x,
        const float *ocean_current_y,
        const int32_t *neighbors,
        float *tta_inout,
        float *ocean_anomaly) {
    pk_async_climate::OceanLandKnobs ok;
    ok.n_cells = n_cells;
    ok.start_idx = 0;
    ok.end_idx = n_cells;
    ok.effective_leak = effective_leak;
    ok.wrap_period_x = wrap_period_x;
    ok.tta_source_cap = tta_source_cap;
    ok.tta_blend_rate = tta_blend_rate;
    ok.tta_decay_rate = tta_decay_rate;

    pk_async_climate::OceanLandLanes ol;
    ol.is_water = is_water;
    ol.pos_x = pos_x;
    ol.pos_y = pos_y;
    ol.ocean_current_x = ocean_current_x;
    ol.ocean_current_y = ocean_current_y;
    ol.neighbors = neighbors;
    ol.tta_inout = tta_inout;
    ol.ocean_anomaly = ocean_anomaly;
    pk_async_climate::ocean_land_pure(ok, ol);
}

// fallback：任何 sanity check 失败返回 -1.0，调用方走原 run_ocean_water_pass。
double DCWorldExt::run_ocean_water_pass_simd(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_water_pass_simd: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    // A 修复（2026-06）：ocean_water SIMD 改写 ocean thermal anomaly slot。
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    const int sid_sea_ice  = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0 ||
        sid_oanom < 0 || sid_sea_ice < 0) {
        diag("missing slot id");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || !knobs.has("temp_before_arr") ||
        !knobs.has("anomaly_out") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    const float heat_mix     = float(knobs["heat_mix"]);
    float tta_source_cap = knobs.has("tta_source_cap") ? float(knobs["tta_source_cap"]) : 0.22f;
    float tta_blend_rate = knobs.has("tta_blend_rate") ? float(knobs["tta_blend_rate"]) : 0.70f;
    float tta_zero_current_decay = knobs.has("tta_zero_current_decay") ? float(knobs["tta_zero_current_decay"]) : 0.06f;
    const float cold_transport_form = knobs.has("cold_transport_form_threshold")
        ? float(knobs["cold_transport_form_threshold"]) : 0.06f;
    const float cold_transport_melt = knobs.has("cold_transport_melt_threshold")
        ? float(knobs["cold_transport_melt_threshold"]) : 0.11f;
    tta_source_cap = dc_clampf(tta_source_cap, 0.0f, 0.5f);
    tta_blend_rate = dc_clampf(tta_blend_rate, 0.0f, 1.0f);
    tta_zero_current_decay = dc_clampf(tta_zero_current_decay, 0.0f, 1.0f);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array   nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr = knobs["temp_before_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6)         { diag("neighbor_indices size"); return -1.0; }
    if (baseline_arr.size()    != n_cells)   { diag("baseline_arr size"); return -1.0; }
    if (temp_before_arr.size() != n_cells)   { diag("temp_before_arr size"); return -1.0; }
    if (ocx_arr.size()         != n_cells)   { diag("ocx_arr size"); return -1.0; }
    if (ocy_arr.size()         != n_cells)   { diag("ocy_arr size"); return -1.0; }

    // CoW fix: duplicate caller state so unchanged cells keep previous TTA.
    PackedFloat32Array anomaly_src = knobs["anomaly_out"];
    PackedFloat32Array anomaly_out = anomaly_src.size() == n_cells
        ? anomaly_src.duplicate()
        : PackedFloat32Array();
    if (anomaly_out.size() != n_cells) {
        anomaly_out.resize(n_cells);
    }

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_oanom   = _slots.write[sid_oanom];
    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells ||
        s_oanom.arr_f32.size() != n_cells || s_sea_ice.arr_f32.size() != n_cells) {
        diag("slot array size");
        return -1.0;
    }

    OceanWaterCtx ctx{};
    ctx.n_cells      = n_cells;
    ctx.advect_steps = advect_steps;
    ctx.heat_mix     = heat_mix;
    ctx.wrap_period_x = wrap_period_x;
    ctx.tta_source_cap = tta_source_cap;
    ctx.tta_blend_rate = tta_blend_rate;
    ctx.tta_zero_current_decay = tta_zero_current_decay;
    ctx.cold_transport_form = cold_transport_form;
    ctx.cold_transport_melt = cold_transport_melt;
    ctx.NB           = nb_arr.ptr();
    ctx.IW           = s_iswater.arr_u8.ptr();
    ctx.POSX         = s_pos_x.arr_f32.ptr();
    ctx.POSY         = s_pos_y.arr_f32.ptr();
    ctx.OCX          = ocx_arr.ptr();
    ctx.OCY          = ocy_arr.ptr();
    ctx.BL           = baseline_arr.ptr();
    ctx.TB           = temp_before_arr.ptr();
    ctx.SIF          = s_sea_ice.arr_f32.ptr();
    ctx.T_RO         = s_temp.arr_f32.ptr();
    ctx.OANOM_SLOT   = s_oanom.arr_f32.ptrw();
    ctx.AOUT         = anomaly_out.ptrw();

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x04, knobs);
    record_production_ocean_water_input(n_cells, baseline_arr.ptr(), temp_before_arr.ptr());

    auto t0 = std::chrono::high_resolution_clock::now();

    // native daily 默认走 thread 变体；simd 也必须吃同一份内核，否则
    // SHADOW 对拍的是两套 ocean 物理。并行只是调度，不再是第二套公式。
    pk_run_ocean_water_pure(
        n_cells, advect_steps, heat_mix, wrap_period_x,
        tta_source_cap, tta_blend_rate, tta_zero_current_decay,
        cold_transport_form, cold_transport_melt,
        ctx.IW, ctx.POSX, ctx.POSY, ctx.OCX, ctx.OCY,
        ctx.BL, ctx.TB, ctx.SIF, ctx.NB, ctx.OANOM_SLOT, ctx.AOUT);

    const uint8_t *enso_terrain = sid_terrain >= 0 && _slots.write[sid_terrain].arr_u8.size() == n_cells
        ? _slots.write[sid_terrain].arr_u8.ptr() : nullptr;
    const float *enso_lat = sid_lat >= 0 && _slots.write[sid_lat].arr_f32.size() == n_cells
        ? _slots.write[sid_lat].arr_f32.ptr() : nullptr;
    const float *enso_wx = sid_wind_x >= 0 && _slots.write[sid_wind_x].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_x].arr_f32.ptr() : nullptr;
    const float *enso_wspd = sid_wind_spd >= 0 && _slots.write[sid_wind_spd].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_spd].arr_f32.ptr() : nullptr;
    _apply_enso_ocean_slice(knobs, n_cells, 0, n_cells, ctx.IW, enso_terrain,
                            enso_lat, ctx.POSX, ctx.NB, enso_wx, enso_wspd,
                            ctx.OANOM_SLOT, ctx.AOUT);

    knobs["anomaly_out"] = anomaly_out;
    // A 修复（2026-06）：不再 flush cell_temp，改 flush ocean anomaly slot。
    _flush_slot_to_map(sid_oanom);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double DCWorldExt::run_ocean_water_pass_thread(Dictionary knobs, int n_tasks) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_water_pass_thread: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    // A 修复（2026-06）：ocean_water thread 改写 ocean thermal anomaly slot。
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    const int sid_sea_ice  = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0 ||
        sid_oanom < 0 || sid_sea_ice < 0) {
        diag("missing slot id"); return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || !knobs.has("temp_before_arr") ||
        !knobs.has("anomaly_out") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing"); return -1.0;
    }
    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    const float heat_mix     = float(knobs["heat_mix"]);
    float tta_source_cap = knobs.has("tta_source_cap") ? float(knobs["tta_source_cap"]) : 0.22f;
    float tta_blend_rate = knobs.has("tta_blend_rate") ? float(knobs["tta_blend_rate"]) : 0.70f;
    float tta_zero_current_decay = knobs.has("tta_zero_current_decay") ? float(knobs["tta_zero_current_decay"]) : 0.06f;
    const float cold_transport_form = knobs.has("cold_transport_form_threshold")
        ? float(knobs["cold_transport_form_threshold"]) : 0.06f;
    const float cold_transport_melt = knobs.has("cold_transport_melt_threshold")
        ? float(knobs["cold_transport_melt_threshold"]) : 0.11f;
    tta_source_cap = dc_clampf(tta_source_cap, 0.0f, 0.5f);
    tta_blend_rate = dc_clampf(tta_blend_rate, 0.0f, 1.0f);
    tta_zero_current_decay = dc_clampf(tta_zero_current_decay, 0.0f, 1.0f);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array   nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr = knobs["temp_before_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6)         { diag("nb size"); return -1.0; }
    if (baseline_arr.size()    != n_cells)   { diag("baseline size"); return -1.0; }
    if (temp_before_arr.size() != n_cells)   { diag("temp_before size"); return -1.0; }
    if (ocx_arr.size()         != n_cells)   { diag("ocx size"); return -1.0; }
    if (ocy_arr.size()         != n_cells)   { diag("ocy size"); return -1.0; }

    PackedFloat32Array anomaly_src = knobs["anomaly_out"];
    PackedFloat32Array anomaly_out = anomaly_src.size() == n_cells
        ? anomaly_src.duplicate()
        : PackedFloat32Array();
    if (anomaly_out.size() != n_cells) {
        anomaly_out.resize(n_cells);
    }

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_oanom   = _slots.write[sid_oanom];
    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells ||
        s_oanom.arr_f32.size() != n_cells || s_sea_ice.arr_f32.size() != n_cells) {
        diag("slot size"); return -1.0;
    }

    OceanWaterCtx ctx{};
    ctx.n_cells      = n_cells;
    ctx.advect_steps = advect_steps;
    ctx.heat_mix     = heat_mix;
    ctx.wrap_period_x = wrap_period_x;
    ctx.tta_source_cap = tta_source_cap;
    ctx.tta_blend_rate = tta_blend_rate;
    ctx.tta_zero_current_decay = tta_zero_current_decay;
    ctx.cold_transport_form = cold_transport_form;
    ctx.cold_transport_melt = cold_transport_melt;
    ctx.NB           = nb_arr.ptr();
    ctx.IW           = s_iswater.arr_u8.ptr();
    ctx.POSX         = s_pos_x.arr_f32.ptr();
    ctx.POSY         = s_pos_y.arr_f32.ptr();
    ctx.OCX          = ocx_arr.ptr();
    ctx.OCY          = ocy_arr.ptr();
    ctx.BL           = baseline_arr.ptr();
    ctx.TB           = temp_before_arr.ptr();
    ctx.SIF          = s_sea_ice.arr_f32.ptr();
    ctx.T_RO         = s_temp.arr_f32.ptr();
    ctx.OANOM_SLOT   = s_oanom.arr_f32.ptrw();
    ctx.AOUT         = anomaly_out.ptrw();

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x04, knobs);
    record_production_ocean_water_input(n_cells, baseline_arr.ptr(), temp_before_arr.ptr());

    auto t0 = std::chrono::high_resolution_clock::now();
    (void)n_tasks;

    // 与 scalar / worker 同一份内核。thread 变体此前走 ocean_water_compute_one
    // 平行实现；公式已经对齐，但任何后续改动都会再次分叉。并行只留在 ENSO 之外。
    pk_run_ocean_water_pure(
        n_cells, advect_steps, heat_mix, wrap_period_x,
        tta_source_cap, tta_blend_rate, tta_zero_current_decay,
        cold_transport_form, cold_transport_melt,
        ctx.IW, ctx.POSX, ctx.POSY, ctx.OCX, ctx.OCY,
        ctx.BL, ctx.TB, ctx.SIF, ctx.NB, ctx.OANOM_SLOT, ctx.AOUT);

    const uint8_t *enso_terrain = sid_terrain >= 0 && _slots.write[sid_terrain].arr_u8.size() == n_cells
        ? _slots.write[sid_terrain].arr_u8.ptr() : nullptr;
    const float *enso_lat = sid_lat >= 0 && _slots.write[sid_lat].arr_f32.size() == n_cells
        ? _slots.write[sid_lat].arr_f32.ptr() : nullptr;
    const float *enso_wx = sid_wind_x >= 0 && _slots.write[sid_wind_x].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_x].arr_f32.ptr() : nullptr;
    const float *enso_wspd = sid_wind_spd >= 0 && _slots.write[sid_wind_spd].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_spd].arr_f32.ptr() : nullptr;
    _apply_enso_ocean_slice(knobs, n_cells, 0, n_cells, ctx.IW, enso_terrain,
                            enso_lat, ctx.POSX, ctx.NB, enso_wx, enso_wspd,
                            ctx.OANOM_SLOT, ctx.AOUT);

    knobs["anomaly_out"] = anomaly_out;
    _flush_slot_to_map(sid_oanom);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

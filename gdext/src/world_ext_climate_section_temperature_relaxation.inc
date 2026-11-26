double DCWorldExt::run_climate_pass_b(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_pass_b: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve all 10 slot ids ONCE ───────────────────────────────────
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_snowpack = component_id(StringName("cell_snowpack"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_elev     = component_id(StringName("cell_elevation"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_insol_dev= component_id(StringName("cell_insolation_dev"));
    // A 修复（2026-06）：pass_b 不再写 cell_temp，改累加到 cell_local_thermal_anomaly。
    const int sid_lanom    = component_id(StringName("cell_local_thermal_anomaly"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snowpack < 0 || sid_iswater < 0 ||
        sid_landform < 0 || sid_veg < 0 || sid_elev < 0 || sid_lat < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_insol_dev < 0 || sid_lanom < 0) {
        diag("missing slot id (cell_temp/moisture/snowpack/is_water/landform/vegetation/elevation/lat_norm/pos_x/pos_y/insolation_dev/local_thermal_anomaly)");
        return -1.0;
    }

    // ─── Pull scalars from knobs ────────────────────────────────────────
    if (!knobs.has("n_cells") || !knobs.has("winter_boost") ||
        !knobs.has("snow_cool") || !knobs.has("veg_cool") ||
        !knobs.has("diurnal_amp") || !knobs.has("evap_gain") ||
        !knobs.has("rs_threshold") || !knobs.has("rs_factor") ||
        !knobs.has("rs_lookback") || !knobs.has("t_freeze") ||
        !knobs.has("coupling_gain") || !knobs.has("coast_leak") ||
        !knobs.has("season_phase") ||
        !knobs.has("neighbor_indices") || !knobs.has("temp_transport_anomaly") ||
        !knobs.has("foliage_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (knobs.has("go_sparse") && bool(knobs["go_sparse"])) {
        diag("go_sparse=true — sparse path not yet supported in C++");
        return -1.0;
    }
    const float winter_boost          = float(knobs["winter_boost"]);
    const float snow_cool             = float(knobs["snow_cool"]);
    const float veg_cool              = float(knobs["veg_cool"]);
    const float diurnal_amp           = float(knobs["diurnal_amp"]);
    const float evap_gain             = float(knobs["evap_gain"]);
    const float rs_threshold          = float(knobs["rs_threshold"]);
    const float rs_factor             = float(knobs["rs_factor"]);
    const int   rs_lookback           = int(knobs["rs_lookback"]);
    // seam-advection-fix：雨影上风探测的经度环绕周期，缺省取常驻值。
    const double wrap_period_x        = knobs.has("wrap_period_x")
        ? double(knobs["wrap_period_x"]) : _native_wrap_period_x;
    const float t_freeze              = float(knobs["t_freeze"]);
    const float coupling_gain         = float(knobs["coupling_gain"]);
    const float coast_leak            = float(knobs["coast_leak"]);
    const double season_phase         = double(knobs["season_phase"]);
    const float snowpack_cover_low    = knobs.has("snowpack_cover_low") ? float(knobs["snowpack_cover_low"]) : 0.05f;
    const float snowpack_cover_full   = knobs.has("snowpack_cover_full") ? float(knobs["snowpack_cover_full"]) : 0.32f;

    // S3: 留存生产这一轮真实用过的标量，reference publish 时发布给 worker。
    // 不写的后果是 worker 跑同一份内核但吃结构默认 knobs。
    record_production_round_scalars(0x02, knobs);
    // ─── Pull PackedArrays ──────────────────────────────────────────────
    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array foliage_arr = knobs["foliage_table"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (tta_arr.size() != n_cells)   { diag("temp_transport_anomaly size mismatch"); return -1.0; }
    const int foliage_size = foliage_arr.size();
    if (foliage_size <= 0) { diag("foliage_table empty"); return -1.0; }

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈（可选 knobs；缺省 0 = 关闭）。
    const float sea_ice_albedo_cooling = knobs.has("sea_ice_albedo_cooling") ? float(knobs["sea_ice_albedo_cooling"]) : 0.0f;
    PackedFloat32Array sif_arr_pb;
    if (knobs.has("sea_ice_frac")) sif_arr_pb = knobs["sea_ice_frac"];
    const float * const __restrict SIF_PB = (sif_arr_pb.size() == n_cells) ? sif_arr_pb.ptr() : nullptr;
    record_production_pass_b_input(n_cells, SIF_PB, tta_arr.ptr());

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moist];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_veg];
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_lat      = _slots.write[sid_lat];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_insol_dev= _slots.write[sid_insol_dev];
    Slot &s_lanom    = _slots.write[sid_lanom];
    if (s_temp.arr_f32.size()  != n_cells || s_moist.arr_f32.size()    != n_cells ||
        s_snowpack.arr_f32.size() != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_elev.arr_f32.size()  != n_cells || s_lat.arr_f32.size()      != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()    != n_cells ||
        s_insol_dev.arr_f32.size() != n_cells ||
        s_lanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // ─── Hot pointers ───────────────────────────────────────────────────
    // A 修复（2026-06）：T 只读快照（用于 evap 的 t_eff）。pass_b 写 local anomaly，
    // 由 wind_surface 末端合成回 cell_temp。
    const float * const __restrict T_RO = s_temp.arr_f32.ptr();
    float       * const __restrict LANOM = s_lanom.arr_f32.ptrw();
    float       * const __restrict M    = s_moist.arr_f32.ptrw();
    const float * const __restrict SNOWPACK = s_snowpack.arr_f32.ptr();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict LF = s_landform.arr_u8.ptr();
    const uint8_t * const __restrict VG = s_veg.arr_u8.ptr();
    const float * const __restrict ELEV = s_elev.arr_f32.ptr();
    const float * const __restrict LAT  = s_lat.arr_f32.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const float * const __restrict INSOL_DEV = s_insol_dev.arr_f32.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict TTA  = tta_arr.ptr();
    const float * const __restrict FOL  = foliage_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Snapshot temp BEFORE any writes ────────────────────────────────
    // A 修复（2026-06）：TS 是 yesterday's composed cell_temp（pass_b 不再就地写 T）。
    // d_albedo / d_coastal / d_landform 仍然以 TS 为基准计算（与 GDScript bit-equal）。
    std::vector<float> temp_snapshot(n_cells);
    std::memcpy(temp_snapshot.data(), T_RO, n_cells * sizeof(float));
    const float * const __restrict TS = temp_snapshot.data();

    // S3 P3：主循环已提取为 pk_async_climate::climate_pass_b_pure，worker 侧吃同一份。
    pk_async_climate::ClimatePassBKnobs pbk;
    pbk.n_cells                = n_cells;
    pbk.winter_boost           = winter_boost;
    pbk.snow_cool              = snow_cool;
    pbk.veg_cool               = veg_cool;
    pbk.diurnal_amp            = diurnal_amp;
    pbk.evap_gain              = evap_gain;
    pbk.rs_threshold           = rs_threshold;
    pbk.rs_factor              = rs_factor;
    pbk.rs_lookback            = rs_lookback;
    pbk.wrap_period_x          = wrap_period_x;
    pbk.t_freeze               = t_freeze;
    pbk.coupling_gain          = coupling_gain;
    pbk.coast_leak             = coast_leak;
    pbk.sea_ice_albedo_cooling = sea_ice_albedo_cooling;
    pbk.season_phase           = season_phase;
    pbk.snowpack_cover_low     = snowpack_cover_low;
    pbk.snowpack_cover_full    = snowpack_cover_full;
    pbk.foliage_size           = foliage_size;

    pk_async_climate::ClimatePassBLanes pbl;
    pbl.temp_snapshot           = TS;
    pbl.snowpack                = SNOWPACK;
    pbl.elevation               = ELEV;
    pbl.lat_norm                = LAT;
    pbl.pos_x                   = POSX;
    pbl.pos_y                   = POSY;
    pbl.insolation_dev          = INSOL_DEV;
    pbl.temp_transport_anomaly  = TTA;
    pbl.is_water                = IW;
    pbl.landform                = LF;
    pbl.vegetation              = VG;
    pbl.sea_ice_frac            = SIF_PB;
    pbl.neighbor_indices        = NB;
    pbl.foliage_table           = FOL;
    pbl.local_thermal_anomaly   = LANOM;
    pbl.moisture                = M;

    pk_async_climate::climate_pass_b_pure(pbk, pbl);

    // §11.2 flush: A 修复（2026-06）— pass_b 不再 flush cell_temp，改 flush local anomaly。
    _flush_slot_to_map(sid_lanom);
    if (!bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moist);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ════════════════════════════════════════════════════════════════════════════
// plan/sim-2ms-simd-dirty-budget — climate Pass-B SIMD / Thread variants
// ════════════════════════════════════════════════════════════════════════════
//
// 策略：pass_b 的 5 段计算（albedo / coastal / landform / write / evap +
// rain-shadow）全部是 `if (!is_water) { ... }` 嵌套。原 scalar 实现按 cell
// 顺序串行迭代，每个 cell 命中 5 个分支预测槽位。改造路径：
//   1. 一次性 scan IW[]，构建 PackedInt32-equivalent `land_idx` 列表；
//   2. land-cell 主段按 land_idx 直线迭代——5 段去 if 后 MSVC /O2 /arch:AVX2
//      能自动向量化最简单的 albedo + write 段；
//   3. rain-shadow 串行 probe 段对每个 land cell 单独走，因为算法需要沿
//      wind direction 沿 6-邻居最佳方向多步追踪，无 SIMD-able 模式；
//   4. water cell 不需要任何 hot 计算（pass_b 对 water cell 完全 no-op）。
//
// 与原 scalar 的语义差异（plan §risk = B 已接受 ulp ≤ 4）：
//   - 内存访问顺序变为 land-first（按 land_idx 顺序），cache 命中模式不同；
//   - 浮点重排：FMA / 编译器 vectorize 引入 ulp 差异（≤ 4）；
//   - water cell 的 T/M 完全未写——与原 scalar 完全一致（原 scalar 也只
//     在 land 分支写 T，水 cell 走 `T[i] = clamp(temp_now)`，但 temp_now =
//     TS[i] = T[i]，等价于不写）；为安全起见 land-mask 路径下仍保持 water
//     cell T/M 不变。
//   - moisture 同理：water cell 在原 scalar 中也走 `(M[i] + 0) * 1 = M[i]`，
//     等价不写。
//
// 显式 AVX2 fast block 仅用于 albedo 段（最简单 = 单 ld + 1 fmul + 1 fsub）；
// 其余段直线代码交给编译器 auto-vectorize 即可（pass_b 复杂度远高于 pass_a
// 的纯 stencil，手写 6-邻居 mask gather 收益 < 30%、维护成本高）。
//
// run_climate_pass_b_simd / _thread 的 ulp 差异不会比原 scalar 在不同编译
// 器版本间的差异更大；A/B 验收（sim_2ms_ulp_tolerant_test）应通过。

namespace {

// Inline LandformType ordinals — 与 run_climate_pass_b 内 constexpr 同源。
constexpr uint8_t kLF_LOWLAND   = 5;
constexpr uint8_t kLF_MOUNTAIN  = 7;
constexpr uint8_t kLF_PEAK      = 8;
constexpr uint8_t kLF_DELTA     = 9;
constexpr uint8_t kLF_SALT_FLAT = 11;

// pass_b 共享输入指针 + 标量 knobs 的不变 view，避免重复传 20+ 参数。
struct PassBCtx {
    // 输出
    // A 修复（2026-06）：pass_b 不再写 cell_temp；T 字段保留为只读快照入口，
    // 改写 LANOM（cell_local_thermal_anomaly）。M（cell_moisture）写权不变。
    const float * __restrict T;
    float       * __restrict LANOM;
    float       * __restrict M;
    // 只读
    const float * __restrict TS;       // temp snapshot (pre-write)
    const float * __restrict SNOWPACK;
    const uint8_t * __restrict IW;
    const uint8_t * __restrict LF;
    const uint8_t * __restrict VG;
    const float * __restrict ELEV;
    const float * __restrict LAT;
    const float * __restrict POSX;
    const float * __restrict POSY;
    const float * __restrict INSOL_DEV;
    const int32_t * __restrict NB;
    const float * __restrict TTA;
    const float * __restrict FOL;
    int foliage_size;
    // 标量
    float winter_boost, snow_cool, veg_cool, diurnal_amp, evap_gain;
    float rs_threshold, rs_factor, t_freeze, coupling_gain, coast_leak;
    float snowpack_cover_low, snowpack_cover_full;
    double season_phase;
    int rs_lookback;
    // seam-advection-fix：雨影上风探测的经度环绕周期，0 = 无环绕域。
    double wrap_period_x;
    // 海冰反照率尾循环所需（0 / nullptr = 关闭）。原先三个变体各写一份尾循环，
    // 收进 ctx 后统一交给 climate_pass_b_sea_ice_tail_pure。
    int n_cells = 0;
    float sea_ice_albedo_cooling = 0.0f;
    const float * __restrict SIF = nullptr;
};

// PassBCtx → 共享内核的 knobs/lanes。生产 _simd / _thread 与 worker 现在跑同一份
// per-cell body，pass_b 不再有第二份实现可以偏移。
inline void pass_b_ctx_to_kernel(const PassBCtx &c,
                                 pk_async_climate::ClimatePassBKnobs &k,
                                 pk_async_climate::ClimatePassBLanes &l) {
    k.n_cells                = c.n_cells;
    k.winter_boost           = c.winter_boost;
    k.snow_cool              = c.snow_cool;
    k.veg_cool               = c.veg_cool;
    k.diurnal_amp            = c.diurnal_amp;
    k.evap_gain              = c.evap_gain;
    k.rs_threshold           = c.rs_threshold;
    k.rs_factor              = c.rs_factor;
    k.rs_lookback            = c.rs_lookback;
    k.wrap_period_x          = c.wrap_period_x;
    k.t_freeze               = c.t_freeze;
    k.coupling_gain          = c.coupling_gain;
    k.coast_leak             = c.coast_leak;
    k.sea_ice_albedo_cooling = c.sea_ice_albedo_cooling;
    k.season_phase           = c.season_phase;
    k.snowpack_cover_low     = c.snowpack_cover_low;
    k.snowpack_cover_full    = c.snowpack_cover_full;
    k.foliage_size           = c.foliage_size;

    l.temp_snapshot          = c.TS;
    l.snowpack               = c.SNOWPACK;
    l.elevation              = c.ELEV;
    l.lat_norm               = c.LAT;
    l.pos_x                  = c.POSX;
    l.pos_y                  = c.POSY;
    l.insolation_dev         = c.INSOL_DEV;
    l.temp_transport_anomaly = c.TTA;
    l.is_water               = c.IW;
    l.landform               = c.LF;
    l.vegetation             = c.VG;
    l.sea_ice_frac           = c.SIF;
    l.neighbor_indices       = c.NB;
    l.foliage_table          = c.FOL;
    l.local_thermal_anomaly  = c.LANOM;
    l.moisture               = c.M;
}

// land-only main pass：把 land_idx[begin..end) 交给共享内核。
// 原先这里还有 pass_b_land_compute_temp / _evap / _rain_shadow 三个 helper，
// 与 worker 侧那份平行实现逐行重复；已并入 pk_async_climate::climate_pass_b_pure。
inline void pass_b_run_land_range(const PassBCtx &c,
                                  const int *land_idx,
                                  int begin, int end) {
    pk_async_climate::ClimatePassBKnobs k;
    pk_async_climate::ClimatePassBLanes l;
    pass_b_ctx_to_kernel(c, k, l);
    pk_async_climate::climate_pass_b_land_range_pure(k, l, land_idx, begin, end);
}

// [Phase C.3b] 原 PassBLandTask + pass_b_land_worker 已由 parallel_dispatcher.h
// 内的 parallel_for_range 取代（统一所有 _thread 并行模板）。
} // namespace

// ─── pass-B SIMD（land-mask 预筛 + 直线 hot kernel） ────────────────────
//
// 与 run_climate_pass_b 同输入 / 同输出语义；改造点：
//   1. 主循环前一次性 scan IW[] 提取 land_idx；
//   2. land-only loop 走 helper（直线代码无 if (!is_water) 分支）；
//   3. 编译器在 albedo / write 段自动向量化（MSVC /O2 /arch:AVX2 等价）；
//   4. evap / rain-shadow 段保持 scalar 串行（算法本身不 SIMD-able）。
//
// fallback：任何 sanity check 失败返回 -1.0，调用方走原 run_climate_pass_b。
double DCWorldExt::run_climate_pass_b_simd(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_pass_b_simd: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_snowpack = component_id(StringName("cell_snowpack"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_elev     = component_id(StringName("cell_elevation"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_insol_dev= component_id(StringName("cell_insolation_dev"));
    // A 修复（2026-06）：pass_b SIMD 同样不再写 cell_temp。
    const int sid_lanom    = component_id(StringName("cell_local_thermal_anomaly"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snowpack < 0 || sid_iswater < 0 ||
        sid_landform < 0 || sid_veg < 0 || sid_elev < 0 || sid_lat < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_insol_dev < 0 || sid_lanom < 0) {
        diag("missing slot id");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("winter_boost") ||
        !knobs.has("snow_cool") || !knobs.has("veg_cool") ||
        !knobs.has("diurnal_amp") || !knobs.has("evap_gain") ||
        !knobs.has("rs_threshold") || !knobs.has("rs_factor") ||
        !knobs.has("rs_lookback") || !knobs.has("t_freeze") ||
        !knobs.has("coupling_gain") || !knobs.has("coast_leak") ||
        !knobs.has("season_phase") ||
        !knobs.has("neighbor_indices") || !knobs.has("temp_transport_anomaly") ||
        !knobs.has("foliage_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (knobs.has("go_sparse") && bool(knobs["go_sparse"])) {
        diag("go_sparse=true — sparse path not supported in SIMD variant");
        return -1.0;
    }

    PassBCtx ctx;
    ctx.winter_boost          = float(knobs["winter_boost"]);
    ctx.snow_cool             = float(knobs["snow_cool"]);
    ctx.veg_cool              = float(knobs["veg_cool"]);
    ctx.diurnal_amp           = float(knobs["diurnal_amp"]);
    ctx.evap_gain             = float(knobs["evap_gain"]);
    ctx.rs_threshold          = float(knobs["rs_threshold"]);
    ctx.rs_factor             = float(knobs["rs_factor"]);
    ctx.rs_lookback           = int(knobs["rs_lookback"]);
    ctx.wrap_period_x         = knobs.has("wrap_period_x")
        ? double(knobs["wrap_period_x"]) : _native_wrap_period_x;  // seam-advection-fix
    ctx.t_freeze              = float(knobs["t_freeze"]);
    ctx.coupling_gain         = float(knobs["coupling_gain"]);
    ctx.coast_leak            = float(knobs["coast_leak"]);
    ctx.season_phase          = double(knobs["season_phase"]);
    ctx.snowpack_cover_low    = knobs.has("snowpack_cover_low") ? float(knobs["snowpack_cover_low"]) : 0.05f;
    ctx.snowpack_cover_full   = knobs.has("snowpack_cover_full") ? float(knobs["snowpack_cover_full"]) : 0.32f;

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array foliage_arr = knobs["foliage_table"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (tta_arr.size() != n_cells)   { diag("temp_transport_anomaly size mismatch"); return -1.0; }
    ctx.foliage_size = foliage_arr.size();
    if (ctx.foliage_size <= 0) { diag("foliage_table empty"); return -1.0; }

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈（可选 knobs；缺省 0 = 关闭）。
    const float sea_ice_albedo_cooling = knobs.has("sea_ice_albedo_cooling") ? float(knobs["sea_ice_albedo_cooling"]) : 0.0f;
    PackedFloat32Array sif_arr_pb;
    if (knobs.has("sea_ice_frac")) sif_arr_pb = knobs["sea_ice_frac"];
    const float * const __restrict SIF_PB = (sif_arr_pb.size() == n_cells) ? sif_arr_pb.ptr() : nullptr;
    record_production_pass_b_input(n_cells, SIF_PB, tta_arr.ptr());

    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moist];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_veg];
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_lat      = _slots.write[sid_lat];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_insol_dev= _slots.write[sid_insol_dev];
    Slot &s_lanom    = _slots.write[sid_lanom];
    if (s_temp.arr_f32.size()  != n_cells || s_moist.arr_f32.size()    != n_cells ||
        s_snowpack.arr_f32.size() != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_elev.arr_f32.size()  != n_cells || s_lat.arr_f32.size()      != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()    != n_cells ||
        s_insol_dev.arr_f32.size() != n_cells ||
        s_lanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x02, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // A 修复（2026-06）：pass_b SIMD 不再写 T；改写 LANOM。T 只读供 TS snapshot。
    ctx.T     = s_temp.arr_f32.ptr();
    ctx.LANOM = s_lanom.arr_f32.ptrw();
    ctx.M    = s_moist.arr_f32.ptrw();
    ctx.SNOWPACK = s_snowpack.arr_f32.ptr();
    ctx.IW   = s_iswater.arr_u8.ptr();
    ctx.LF   = s_landform.arr_u8.ptr();
    ctx.VG   = s_veg.arr_u8.ptr();
    ctx.ELEV = s_elev.arr_f32.ptr();
    ctx.LAT  = s_lat.arr_f32.ptr();
    ctx.POSX = s_pos_x.arr_f32.ptr();
    ctx.POSY = s_pos_y.arr_f32.ptr();
    ctx.INSOL_DEV = s_insol_dev.arr_f32.ptr();
    ctx.NB   = nb_arr.ptr();
    ctx.TTA  = tta_arr.ptr();
    ctx.FOL  = foliage_arr.ptr();
    ctx.n_cells = n_cells;
    ctx.sea_ice_albedo_cooling = sea_ice_albedo_cooling;
    ctx.SIF  = SIF_PB;

    // Snapshot temp BEFORE writes（与原 scalar 等价；coastal/evap 段读 TS/TTA）
    std::vector<float> temp_snapshot(n_cells);
    std::memcpy(temp_snapshot.data(), ctx.T, n_cells * sizeof(float));
    ctx.TS = temp_snapshot.data();

    // Land-cell index 预筛：reserve 上界 n_cells，append-only。
    // 后续 land hot path 直接迭代该向量，省去 if (!is_water) 分支。
    std::vector<int> land_idx;
    land_idx.reserve(n_cells);
    for (int i = 0; i < n_cells; ++i) {
        if (ctx.IW[i] == 0) land_idx.push_back(i);
    }
    const int n_land = static_cast<int>(land_idx.size());

    // Hot loop：仅遍历 land cells，直线代码无 if-water 分支。
    pass_b_run_land_range(ctx, land_idx.data(), 0, n_land);

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈尾循环（仅水域；与 scalar 同形态）。
    // A 修复（2026-06）：写入 LANOM 而非 T。
    {
        // 海冰反照率→水域 LANOM：与 scalar / worker 同一份 climate_pass_b_sea_ice_tail_pure。
        pk_async_climate::ClimatePassBKnobs tk;
        pk_async_climate::ClimatePassBLanes tl;
        pass_b_ctx_to_kernel(ctx, tk, tl);
        pk_async_climate::climate_pass_b_sea_ice_tail_pure(tk, tl);
    }

    _flush_slot_to_map(sid_lanom);
    if (!bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moist);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── pass-B Thread（land 段分块 WorkerThreadPool） ──────────────────────
double DCWorldExt::run_climate_pass_b_thread(const Dictionary &knobs, int n_tasks) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_pass_b_thread: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }
    // n_tasks <= 0 → 自适应分块（交给 parallel_for_range / parallel_default_n_tasks，
    //   公式 ceil(n_land/1024) clamp[1,16]）；与 pass_a_thread 约定一致，便于 daily
    //   graph 直接传 0 取自适应多核。显式 >0 仍按 caller 指定（bench 用）。
    if (n_tasks < 0) n_tasks = 0;

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_snowpack = component_id(StringName("cell_snowpack"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_elev     = component_id(StringName("cell_elevation"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_insol_dev= component_id(StringName("cell_insolation_dev"));
    // A 修复（2026-06）：pass_b thread 同样不再写 cell_temp。
    const int sid_lanom    = component_id(StringName("cell_local_thermal_anomaly"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snowpack < 0 || sid_iswater < 0 ||
        sid_landform < 0 || sid_veg < 0 || sid_elev < 0 || sid_lat < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_insol_dev < 0 || sid_lanom < 0) {
        diag("missing slot id");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("neighbor_indices") ||
        !knobs.has("temp_transport_anomaly") || !knobs.has("foliage_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (knobs.has("go_sparse") && bool(knobs["go_sparse"])) {
        diag("go_sparse=true — sparse path not supported in thread variant");
        return -1.0;
    }

    PassBCtx ctx;
    ctx.winter_boost          = float(knobs["winter_boost"]);
    ctx.snow_cool             = float(knobs["snow_cool"]);
    ctx.veg_cool              = float(knobs["veg_cool"]);
    ctx.diurnal_amp           = float(knobs["diurnal_amp"]);
    ctx.evap_gain             = float(knobs["evap_gain"]);
    ctx.rs_threshold          = float(knobs["rs_threshold"]);
    ctx.rs_factor             = float(knobs["rs_factor"]);
    ctx.rs_lookback           = int(knobs["rs_lookback"]);
    ctx.wrap_period_x         = knobs.has("wrap_period_x")
        ? double(knobs["wrap_period_x"]) : _native_wrap_period_x;  // seam-advection-fix
    ctx.t_freeze              = float(knobs["t_freeze"]);
    ctx.coupling_gain         = float(knobs["coupling_gain"]);
    ctx.coast_leak            = float(knobs["coast_leak"]);
    ctx.season_phase          = double(knobs["season_phase"]);
    ctx.snowpack_cover_low    = knobs.has("snowpack_cover_low") ? float(knobs["snowpack_cover_low"]) : 0.05f;
    ctx.snowpack_cover_full   = knobs.has("snowpack_cover_full") ? float(knobs["snowpack_cover_full"]) : 0.32f;

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array foliage_arr = knobs["foliage_table"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (tta_arr.size() != n_cells)   { diag("temp_transport_anomaly size mismatch"); return -1.0; }
    ctx.foliage_size = foliage_arr.size();
    if (ctx.foliage_size <= 0) { diag("foliage_table empty"); return -1.0; }

    // [climate-mt 2026-07 bug-parity] 海冰反照率→温度水域尾循环：scalar / _simd 都有，
    //   thread 变体此前漏写（sea_ice_albedo_cooling>0 时 water LANOM 与 scalar 分叉，
    //   被 sim_2ms_ulp_tolerant_test A/B 捕获）。补齐以保证 thread 逐位等价。
    const float sea_ice_albedo_cooling = knobs.has("sea_ice_albedo_cooling") ? float(knobs["sea_ice_albedo_cooling"]) : 0.0f;
    PackedFloat32Array sif_arr_pb;
    if (knobs.has("sea_ice_frac")) sif_arr_pb = knobs["sea_ice_frac"];
    const float * const __restrict SIF_PB = (sif_arr_pb.size() == n_cells) ? sif_arr_pb.ptr() : nullptr;
    record_production_pass_b_input(n_cells, SIF_PB, tta_arr.ptr());

    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moist];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_veg];
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_lat      = _slots.write[sid_lat];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_insol_dev= _slots.write[sid_insol_dev];
    Slot &s_lanom    = _slots.write[sid_lanom];
    if (s_temp.arr_f32.size()  != n_cells || s_moist.arr_f32.size()    != n_cells ||
        s_snowpack.arr_f32.size() != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_elev.arr_f32.size()  != n_cells || s_lat.arr_f32.size()      != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()    != n_cells ||
        s_insol_dev.arr_f32.size() != n_cells ||
        s_lanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x02, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // A 修复（2026-06）：thread 变体不再写 T；ctx.T 只读供 TS snapshot。
    ctx.T     = s_temp.arr_f32.ptr();
    ctx.LANOM = s_lanom.arr_f32.ptrw();
    ctx.M    = s_moist.arr_f32.ptrw();
    ctx.SNOWPACK = s_snowpack.arr_f32.ptr();
    ctx.IW   = s_iswater.arr_u8.ptr();
    ctx.LF   = s_landform.arr_u8.ptr();
    ctx.VG   = s_veg.arr_u8.ptr();
    ctx.ELEV = s_elev.arr_f32.ptr();
    ctx.LAT  = s_lat.arr_f32.ptr();
    ctx.POSX = s_pos_x.arr_f32.ptr();
    ctx.POSY = s_pos_y.arr_f32.ptr();
    ctx.INSOL_DEV = s_insol_dev.arr_f32.ptr();
    ctx.NB   = nb_arr.ptr();
    ctx.TTA  = tta_arr.ptr();
    ctx.FOL  = foliage_arr.ptr();
    ctx.n_cells = n_cells;
    ctx.sea_ice_albedo_cooling = sea_ice_albedo_cooling;
    ctx.SIF  = SIF_PB;

    std::vector<float> temp_snapshot(n_cells);
    std::memcpy(temp_snapshot.data(), ctx.T, n_cells * sizeof(float));
    ctx.TS = temp_snapshot.data();

    std::vector<int> land_idx;
    land_idx.reserve(n_cells);
    for (int i = 0; i < n_cells; ++i) {
        if (ctx.IW[i] == 0) land_idx.push_back(i);
    }
    const int n_land = static_cast<int>(land_idx.size());

    if (n_land == 0) {
        // 全水图：跳过 land hot loop，但海冰反照率水域尾循环仍需执行（与 scalar / _simd 等价）。
    {
        // 海冰反照率→水域 LANOM：与 scalar / worker 同一份 climate_pass_b_sea_ice_tail_pure。
        pk_async_climate::ClimatePassBKnobs tk;
        pk_async_climate::ClimatePassBLanes tl;
        pass_b_ctx_to_kernel(ctx, tk, tl);
        pk_async_climate::climate_pass_b_sea_ice_tail_pure(tk, tl);
    }
        // A 修复（2026-06）：不再 flush cell_temp，改 flush local_anom。
        _flush_slot_to_map(sid_lanom);
        if (!bool(knobs.get("defer_visible_publish", false))) {
            _flush_slot_to_map(sid_moist);
        }
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }

    // 任务粒度兜底：n_land 很小时（< 256），分块开销 > 收益，直接单线程跑。
    // [Phase C.3b] 整段 chunk + WTP gate + wait 由 parallel_for_range 统一封装；
    // 行为与原手写 PassBLandTask + native executor 模板严格一致：
    //   - n < 256 || n_tasks == 1 直接 run_range(0, n_land)
    //   - WTP 缺失 in-thread 顺序按 task_idx 跑（保持调度等价）
    //   - 否则 NativeParallelExecutor group + wait
    pk::parallel_for_range(
        "pk_pass_b_land", n_land, n_tasks, /*seq_threshold=*/256,
        [&](int begin, int end) {
            pass_b_run_land_range(ctx, land_idx.data(), begin, end);
        });

    // [climate-mt 2026-07 bug-parity] 海冰反照率→温度水域尾循环（仅水域，无跨 cell 依赖，
    //   串行即可；与 scalar / _simd lines 2065-2073 逐位等价）。
    {
        // 海冰反照率→水域 LANOM：与 scalar / worker 同一份 climate_pass_b_sea_ice_tail_pure。
        pk_async_climate::ClimatePassBKnobs tk;
        pk_async_climate::ClimatePassBLanes tl;
        pass_b_ctx_to_kernel(ctx, tk, tl);
        pk_async_climate::climate_pass_b_sea_ice_tail_pure(tk, tl);
    }

    _flush_slot_to_map(sid_lanom);
    if (!bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moist);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

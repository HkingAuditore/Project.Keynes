#include "world_ext.h"
#include "runtime_climate_physics.h"
#include "parallel_dispatcher.h"
#include "world_ext_internal.h"
#include <array>
#include <chrono>
#include <cmath>
#include <vector>

namespace pk {

using namespace godot;

using pk_async_physics::COAST_INF;
using pk_async_physics::SEA_BREEZE_SEA_MAX_DIST;
using pk_async_physics::WIND_COAST_THERMAL_MAX_DIST;

// ─── perf 2026-07-08, Item 1：phys pass 每调用固定开销缓存 ───────────
// 解析四个 phys pass 共用的 cell_* slot id + 重建 is_water_lut，按
// FNV-1a(n_cells, water_terrain_ids) 指纹失效（地图 regen / 水掩膜变化即重建，
// 不挂 _bound 钩子，仿 PSI 拓扑缓存 line 2228）。命中后各 pass 直接读成员，
// 省掉重复 component_id(StringName) 与 256 字节 LUT 重建。邻居索引仍由 knob
// 传入（保留 fallback）。slot 缺失时 _phys_sid_* 为 -1，pass 内 sid<0 守卫仍触发。
const float *DCWorldExt::_phys_lat_norm_ptr(int n_cells) {
    if (_phys_sid_lat_norm < 0 || _phys_sid_lat_norm >= _slots.size()) return nullptr;
    Slot &s = _slots.write[_phys_sid_lat_norm];
    if (s.arr_f32.size() != n_cells) return nullptr;
    return s.arr_f32.ptr();
}

void DCWorldExt::_phys_resolve_static(int n_cells, const godot::PackedByteArray &water_ids) {
    uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
    auto mix = [&fp](uint32_t bits) {
        fp ^= uint64_t(bits);
        fp *= 1099511628211ull; // FNV-1a prime
    };
    mix(uint32_t(n_cells));
    for (int k = 0; k < water_ids.size(); ++k) {
        mix(uint32_t(int(water_ids[k])));
    }
    if (_phys_static_valid && _phys_static_fp == fp) return;

    _phys_sid_pos_x     = component_id(StringName("cell_pos_x"));
    _phys_sid_pos_y     = component_id(StringName("cell_pos_y"));
    _phys_sid_lat_norm  = component_id(StringName("cell_lat_norm"));
    _phys_sid_terrain   = component_id(StringName("cell_terrain"));
    _phys_sid_landform  = component_id(StringName("cell_landform"));
    _phys_sid_wind_x    = component_id(StringName("cell_wind_x"));
    _phys_sid_wind_y    = component_id(StringName("cell_wind_y"));
    _phys_sid_wind_spd  = component_id(StringName("cell_wind_speed"));
    _phys_sid_slp       = component_id(StringName("cell_slp"));
    _phys_sid_temp      = component_id(StringName("cell_temp"));
    _phys_sid_temp_an   = component_id(StringName("cell_temp_anomaly"));
    _phys_sid_snow      = component_id(StringName("cell_snow_cover"));
    _phys_sid_ice       = component_id(StringName("cell_sea_ice_frac"));
    _phys_sid_wvap      = component_id(StringName("cell_weather_vapor"));
    _phys_sid_wcld      = component_id(StringName("cell_weather_cloud"));
    _phys_sid_ocx       = component_id(StringName("cell_ocean_current_x"));
    _phys_sid_ocy       = component_id(StringName("cell_ocean_current_y"));
    _phys_sid_psi_prev  = component_id(StringName("cell_ocean_psi"));
    _phys_sid_upwelling = component_id(StringName("cell_upwelling_strength"));
    _phys_sid_elev      = component_id(StringName("cell_elevation"));

    for (int i = 0; i < 256; ++i) _phys_is_water_lut[i] = false;
    for (int k = 0; k < water_ids.size(); ++k) {
        const int wid = int(water_ids[k]);
        if (wid >= 0 && wid < 256) _phys_is_water_lut[wid] = true;
    }

    _phys_static_fp = fp;
    _phys_static_valid = true;
}

// ─── perf 2026-07-08, Item 2：WIND coast/sea BFS 缓存 ──────────────────
// run_wind_field_pass 每调用重建 coast_dist/sea_dist 全图 vector（Pass 0 + 0b），是全局
// 状态、与 cell 内容无关、对静态地图逐调用恒等。缓存进成员，指纹 = FNV(TR 字节 +
// water_ids + NB 整型) —— 地图 regen / 地形 flip 即失配自动重建（≈地图期一次）。
// 命中即 coast_dist/sea_dist 等逐位复用 → bit-equal；主线程同步调用，成员存储线程安全。
// 注：NB_DIR_X/Y、WIND_COAST_THERMAL_MAX_DIST、SEA_BREEZE_SEA_MAX_DIST 为本 TU 常量。
void DCWorldExt::_phys_ensure_wind_coast(int n_cells, const uint8_t *TR, const int32_t *NB,
                                         const bool *is_water_lut, const godot::PackedByteArray &water_ids) {
    const auto build_t0 = std::chrono::high_resolution_clock::now();
    uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
    auto mix = [&fp](uint32_t bits) {
        fp ^= uint64_t(bits);
        fp *= 1099511628211ull; // FNV-1a prime
    };
    mix(uint32_t(n_cells));
    for (int i = 0; i < n_cells; ++i) mix(uint32_t(TR[i]));
    mix(uint32_t(water_ids.size()));
    for (int k = 0; k < water_ids.size(); ++k) mix(uint32_t(int(water_ids[k])));
    for (int i = 0; i < n_cells * 6; ++i) mix(uint32_t(NB[i]));
    if (_phys_wind_coast_valid && _phys_wind_coast_fp == fp) {
        _phys_wind_coast_last_hit = true;
        return;
    }
    _phys_wind_coast_last_hit = false;

    // B8 P2：两次 BFS 已抽到 pk_async_physics::wind_coast_build_pure（worker 走同一份）。
    // 生产仍持有缓存与指纹外壳 —— 命中即整段跳过。
    _phys_wind_coast_dist.assign(static_cast<size_t>(n_cells), COAST_INF);
    _phys_wind_coast_sea_x.assign(static_cast<size_t>(n_cells), 0.0f);
    _phys_wind_coast_sea_y.assign(static_cast<size_t>(n_cells), 0.0f);
    _phys_wind_coast_sea_anchor.assign(static_cast<size_t>(n_cells), -1);
    _phys_wind_sea_dist.assign(static_cast<size_t>(n_cells), COAST_INF);
    _phys_wind_sea_land_x.assign(static_cast<size_t>(n_cells), 0.0f);
    _phys_wind_sea_land_y.assign(static_cast<size_t>(n_cells), 0.0f);
    _phys_wind_sea_land_anchor.assign(static_cast<size_t>(n_cells), -1);
    std::vector<int32_t> bfs_scratch(static_cast<size_t>(n_cells) * 2u, 0);
    pk_async_physics::WindCoastKnobs coast_k;
    coast_k.coast_max_dist = WIND_COAST_THERMAL_MAX_DIST;
    coast_k.sea_max_dist = SEA_BREEZE_SEA_MAX_DIST;
    pk_async_physics::WindCoastLanes coast_l;
    coast_l.terrain = TR;
    coast_l.neighbors = NB;
    coast_l.is_water_lut = is_water_lut;
    coast_l.coast_dist = _phys_wind_coast_dist.data();
    coast_l.coast_sea_x = _phys_wind_coast_sea_x.data();
    coast_l.coast_sea_y = _phys_wind_coast_sea_y.data();
    coast_l.coast_sea_anchor = _phys_wind_coast_sea_anchor.data();
    coast_l.sea_dist = _phys_wind_sea_dist.data();
    coast_l.sea_land_x = _phys_wind_sea_land_x.data();
    coast_l.sea_land_y = _phys_wind_sea_land_y.data();
    coast_l.sea_land_anchor = _phys_wind_sea_land_anchor.data();
    coast_l.scratch_queue = bfs_scratch.data();
    pk_async_physics::wind_coast_build_pure(n_cells, coast_k, coast_l);

    _phys_wind_coast_fp = fp;
    _phys_wind_coast_valid = true;
    const auto build_t1 = std::chrono::high_resolution_clock::now();
    _phys_wind_coast_build_ms =
        std::chrono::duration<double, std::milli>(build_t1 - build_t0).count();
}

// ─── NS 化 Phase 0：风场回溯轨迹表构建 ─────────────────────────────────
// 每 cell 沿 -通量 回溯 dist = |flux|·traj_pos_scale·s·traj_dt_days（s=√(N/15000)
// 格距归一：世界是固定大小行星，格距∝1/√N，同一物理距离在高分辨率图上跨更多格），
// 上限 12 pos 单位（≈7 格）防御异常风速。回溯终点用直线近似（低速大 dt 下与
// RK2 差异 < 亚格级），随后按最对齐邻居逐格 walk（≤12 跳）推进宿主 cell，
// 保证宿主与终点一致，再交 pk_hex_sextant_barycentric 求三点权重。
// 只读 wind slots（已写完，稳定）、写 own-row → parallel_for_range bit-equal。
void DCWorldExt::_phys_build_wind_traj(int n_cells, const float *POSX, const float *POSY,
                                       const int32_t *NB, const float *WX, const float *WY,
                                       const float *WSP, double wrap_period_x,
                                       double traj_pos_scale, double traj_dt_days) {
    if (int(_phys_wind_traj_idx.size()) != n_cells * 3) {
        _phys_wind_traj_idx.assign(static_cast<size_t>(n_cells) * 3, 0);
        _phys_wind_traj_w.assign(static_cast<size_t>(n_cells) * 3, 0.0f);
    }
    const double grid_s = std::sqrt(double(n_cells) / 15000.0);
    // B8 P2：回溯轨迹构建已抽到 pk_async_physics::wind_traj_build_range。
    pk_async_physics::WindTrajKnobs traj_k;
    traj_k.wrap_period_x = wrap_period_x;
    traj_k.traj_pos_scale = traj_pos_scale;
    traj_k.traj_dt_days = traj_dt_days;
    pk_async_physics::WindTrajLanes traj_l;
    traj_l.pos_x = POSX;
    traj_l.pos_y = POSY;
    traj_l.neighbors = NB;
    traj_l.wind_x = WX;
    traj_l.wind_y = WY;
    traj_l.wind_speed = WSP;
    traj_l.traj_idx = _phys_wind_traj_idx.data();
    traj_l.traj_w = _phys_wind_traj_w.data();
    pk::parallel_for_range("pk_wind_traj", n_cells, [&](int rb, int re) {
        pk_async_physics::wind_traj_build_range(n_cells, rb, re, traj_k, traj_l);
    });
    _phys_wind_traj_fp = pk_wind_state_fp(n_cells, WX, WY, WSP);
    ++_phys_wind_traj_gen;
    _phys_wind_traj_valid = true;
}

bool DCWorldExt::runtime_weather_traj_snapshot(
        int n_cells, std::vector<int32_t> &out_idx,
        std::vector<float> &out_w) const {
    out_idx.clear();
    out_w.clear();
    if (n_cells <= 0 || !_bound) return false;
    const int sid_wx = component_id(StringName("cell_wind_x"));
    const int sid_wy = component_id(StringName("cell_wind_y"));
    const int sid_ws = component_id(StringName("cell_wind_speed"));
    if (sid_wx < 0 || sid_wy < 0 || sid_ws < 0) return false;
    // const 方法：用只读下标（_slots.write[] 在 const 语义下返回写代理，不能取引用）。
    const Slot &s_wx = _slots[sid_wx];
    const Slot &s_wy = _slots[sid_wy];
    const Slot &s_ws = _slots[sid_ws];
    if (int(s_wx.arr_f32.size()) != n_cells ||
        int(s_wy.arr_f32.size()) != n_cells ||
        int(s_ws.arr_f32.size()) != n_cells) {
        return false;
    }
    // 与 run_weather_field_solve_pass / run_wind_air_pass 的消费契约逐条一致：
    // 表已建、knob 允许消费、长度正确、指纹仍匹配当前风场。任何一条不满足都让
    // worker 走和生产相同的 hopping 回退，而不是拿一张过期表插值。
    if (!_phys_wind_traj_valid || !_phys_wind_traj_consume_enabled ||
        int(_phys_wind_traj_idx.size()) != n_cells * 3 ||
        int(_phys_wind_traj_w.size()) != n_cells * 3) {
        return false;
    }
    if (pk_wind_state_fp(n_cells, s_wx.arr_f32.ptr(), s_wy.arr_f32.ptr(),
                         s_ws.arr_f32.ptr()) != _phys_wind_traj_fp) {
        return false;
    }
    out_idx = _phys_wind_traj_idx;
    out_w = _phys_wind_traj_w;
    return true;
}


} // namespace pk

// ─── Climate pass 纯内核实现（Godot 无依赖）──────────────────────
//
// S3 搬迁体：下面 9 个 kernel 原位于 world_ext_climate.cpp（static 文件作用域），
// 现在是生产与 SHADOW worker 共用的唯一实现。搬迁是逐字的，不含任何算法改动；
// 任何数值行为变更必须单独提案，否则无法与 S2 分叉矩阵对齐。
//
// 不得 include godot_cpp。这一条约束就是“worker 可用”的全部含义。

#include "runtime_climate_passes.h"
#include "simulation_math.h"
#include "parallel_dispatcher.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <queue>
#include <utility>
#include <vector>

namespace pk {
namespace pk_async_climate {

// pass_b pure kernel — 移植自 DCWorldExt::run_climate_pass_b（world_ext.cpp:5256）。
// 算法逐行 1:1 镜像 sync 路径主循环（line 5399-5546）+ 海冰反照率尾循环（line 5552-5560）：
//   - 5 段决定：albedo / coastal heat leak / landform diurnal / evap / rain_shadow
//   - 写出 cell_local_thermal_anomaly（累加，clamp ±0.08）和 cell_moisture
//   - 海冰反照率尾循环只对水域 cell 写 LANOM
//
// 输入：in.{is_water, landform, vegetation, snow_cover, elevation, lat_norm,
//           pos_x, pos_y, insolation_dev, temp（snapshot 入参）, moisture（in/out）,
//           local_thermal_anomaly（in/out）, temp_transport_anomaly, sea_ice_frac} +
//      static knobs.{neighbor_indices, foliage_table} + scalars
// 输出：out.{moisture, local_thermal_anomaly}
//
// 注意：算法本体严格 1:1，与 sync 路径在同一 input 下输出 bit-equal。
// 海冰反照率尾循环（sync line 5548-5560）也实装。
// pass_b 的单 land cell 体。生产的 scalar / _simd / _thread 与 worker 四条路径
// 现在都落到这里。is_water 分支保留原样：land cell 走的就是每个 guard 都命中的
// 那条路，所以这份 body 与被替换掉的三份逐字一致。
static inline void pass_b_land_cell(const ClimatePassBKnobs &knobs,
                                   const ClimatePassBLanes &lanes,
                                   int i) {
    // ── 前言：把 knobs/lanes 摊回生产里的局部名，主循环得以原样保留 ──
    const auto winter_boost = knobs.winter_boost;
    const auto snow_cool = knobs.snow_cool;
    const auto veg_cool = knobs.veg_cool;
    const auto diurnal_amp = knobs.diurnal_amp;
    const auto evap_gain = knobs.evap_gain;
    const auto rs_threshold = knobs.rs_threshold;
    const auto rs_factor = knobs.rs_factor;
    const auto rs_lookback = knobs.rs_lookback;
    const auto wrap_period_x = knobs.wrap_period_x;
    const auto t_freeze = knobs.t_freeze;
    const auto coupling_gain = knobs.coupling_gain;
    const auto coast_leak = knobs.coast_leak;
    const auto sea_ice_albedo_cooling = knobs.sea_ice_albedo_cooling;
    const auto season_phase = knobs.season_phase;
    const auto snowpack_cover_low = knobs.snowpack_cover_low;
    const auto snowpack_cover_full = knobs.snowpack_cover_full;
    const auto foliage_size = knobs.foliage_size;
    const auto n_cells = knobs.n_cells;
    const auto TS = lanes.temp_snapshot;
    const auto SNOWPACK = lanes.snowpack;
    const auto ELEV = lanes.elevation;
    const auto LAT = lanes.lat_norm;
    const auto POSX = lanes.pos_x;
    const auto POSY = lanes.pos_y;
    const auto INSOL_DEV = lanes.insolation_dev;
    const auto TTA = lanes.temp_transport_anomaly;
    const auto IW = lanes.is_water;
    const auto LF = lanes.landform;
    const auto VG = lanes.vegetation;
    const auto SIF_PB = lanes.sea_ice_frac;
    const auto NB = lanes.neighbor_indices;
    const auto FOL = lanes.foliage_table;
    const auto LANOM = lanes.local_thermal_anomaly;
    const auto M = lanes.moisture;

    // LandformType.LF: LOWLAND=5, HILL=6, MOUNTAIN=7, PEAK=8, DELTA=9,
    //                  SALT_FLAT=11 (per landform_type.gd:9-23)
    constexpr uint8_t LF_LOWLAND   = 5;
    constexpr uint8_t LF_MOUNTAIN  = 7;
    constexpr uint8_t LF_PEAK      = 8;
    constexpr uint8_t LF_DELTA     = 9;
    constexpr uint8_t LF_SALT_FLAT = 11;

        const bool is_water = IW[i] != 0;
        const float temp_now     = TS[i];
        const float moisture_now = M[i];
        const float snow_cover   = pk_snowpack_cover_for_albedo(SNOWPACK[i], snowpack_cover_low, snowpack_cover_full);

        float d_albedo      = 0.0f;
        float d_coastal     = 0.0f;
        float d_landform    = 0.0f;
        float d_evap        = 0.0f;
        float d_rain_shadow = 1.0f;

        // (line 4413-4416) ① albedo (land only)
        if (!is_water) {
            d_albedo = -snow_cool * snow_cover;
            const uint8_t veg_id = VG[i];
            const float foliage = (veg_id < foliage_size) ? FOL[veg_id] : 0.0f;
            d_albedo -= veg_cool * foliage;
        }

        // (line 4419-4431) ② coastal heat leak (land only, using snapshot
        //                   of cells[ni].temperature_transport_anomaly)
        if (!is_water) {
            float sum_anomaly = 0.0f;
            int   n_water     = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    sum_anomaly += TTA[ni];
                    n_water += 1;
                }
            }
            if (n_water > 0) {
                d_coastal = coast_leak * (sum_anomaly / float(n_water)) * winter_boost;
            }
        }

        // (line 4434-4440) ③ landform diurnal (land only)
        if (!is_water) {
            const uint8_t lf = LF[i];
            const float solar_factor = std::clamp(INSOL_DEV[i], -1.0f, 1.0f);
            if (lf == LF_LOWLAND || lf == LF_SALT_FLAT || lf == LF_DELTA) {
                d_landform = diurnal_amp * solar_factor;
            } else if (lf == LF_PEAK || lf == LF_MOUNTAIN) {
                d_landform = -diurnal_amp * 0.5f * std::max(0.0f, -solar_factor);
            }
        }

        // (line 4442-4445) A 修复（2026-06）：原 `T[i] = clamp(temp_now + d_*)`
        // 改为累加到 cell_local_thermal_anomaly。temp_final 仍计算用于下面 evap
        // 阶段的 t_eff（保持 GDScript bit-equal 的语义：evap 用 "本日 d_* 注入后" 的 t）。
        float local_anom_contrib = d_albedo + d_coastal + d_landform;
        if (local_anom_contrib < -0.08f) local_anom_contrib = -0.08f;
        else if (local_anom_contrib > 0.08f) local_anom_contrib = 0.08f;
        LANOM[i] = LANOM[i] + local_anom_contrib;
        if (LANOM[i] < -0.08f) LANOM[i] = -0.08f;
        else if (LANOM[i] > 0.08f) LANOM[i] = 0.08f;
        float temp_final = temp_now + local_anom_contrib;
        if (temp_final < 0.0f) temp_final = 0.0f;
        else if (temp_final > 1.0f) temp_final = 1.0f;

        // (line 4456-4481) ④ evap (land only)
        if (!is_water) {
            const float t_eff = temp_final + TTA[i];
            float water_neighbor_w = 0.0f;
            float sum_water_anomaly = 0.0f;
            const int bo = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[bo + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    water_neighbor_w += 1.0f;
                    sum_water_anomaly += TTA[ni];
                }
            }
            float avg_water_anomaly = 0.0f;
            if (water_neighbor_w > 0.0f) {
                avg_water_anomaly = sum_water_anomaly / water_neighbor_w;
            }
            float nb_w_norm = water_neighbor_w / 6.0f;
            if (nb_w_norm > 1.0f) nb_w_norm = 1.0f;
            if (t_eff > t_freeze && nb_w_norm > 0.0f) {
                d_evap = evap_gain * (t_eff - t_freeze) * nb_w_norm;
                if (coupling_gain > 0.0f && std::fabs(avg_water_anomaly) > 0.001f) {
                    float evap_mul = 1.0f + coupling_gain * avg_water_anomaly;
                    if (evap_mul < 0.0f) evap_mul = 0.0f;
                    else if (evap_mul > 2.0f) evap_mul = 2.0f;
                    d_evap *= evap_mul;
                }
            }
            if (avg_water_anomaly < -0.01f && nb_w_norm > 0.0f && coupling_gain > 0.0f) {
                d_evap += -evap_gain * (-avg_water_anomaly) * nb_w_norm * coupling_gain * 0.5f;
            }
        }

        // (line 4484-4518) ⑤ rain shadow (land only, gated by rs_lookback>0)
        if (!is_water && rs_lookback > 0) {
            const double ny = double(LAT[i]);
            // jitter = sin(q*0.31 + r*0.47) * 0.05；schema 没存 q/r。本实现把
            // jitter 取 0（jitter 仅 ±0.05 ny，对 wind_at 输出方向影响极小，
            // bit-equal 容差 1e-4 内可容忍。后续 PR 加 cell_q/cell_r schema 后
            // 可补 jitter）。
            double w_dx = 0.0, w_dy = 0.0;
            wind_belt_at(ny, season_phase, &w_dx, &w_dy);
            const double wlen2 = w_dx * w_dx + w_dy * w_dy;
            if (wlen2 > 1e-6) {
                float max_upwind_h = ELEV[i];
                int probe_idx = i;
                for (int step = 0; step < rs_lookback; ++step) {
                    int   best_idx = -1;
                    double best_dot = 0.1;
                    const float pwx = POSX[probe_idx];
                    const float pwy = POSY[probe_idx];
                    const int pbase = probe_idx * 6;
                    for (int d3 = 0; d3 < 6; ++d3) {
                        const int32_t ni3 = NB[pbase + d3];
                        if (ni3 < 0) continue;
                        const double dx = pk_wrap_min_image_dx(
                            double(pwx) - double(POSX[ni3]), wrap_period_x);
                        const double dy = double(pwy) - double(POSY[ni3]);
                        const double len2 = dx * dx + dy * dy;
                        if (len2 < 1e-6) continue;
                        const double inv_len = 1.0 / std::sqrt(len2);
                        const double dotv = (dx * w_dx + dy * w_dy) * inv_len;
                        if (dotv > best_dot) {
                            best_dot = dotv;
                            best_idx = ni3;
                        }
                    }
                    if (best_idx < 0) break;
                    probe_idx = best_idx;
                    if (ELEV[probe_idx] > max_upwind_h) {
                        max_upwind_h = ELEV[probe_idx];
                    }
                }
                if (max_upwind_h - ELEV[i] >= rs_threshold) {
                    d_rain_shadow = rs_factor;
                }
            }
        }

        // (line 4520-4523) write moisture
        float moisture_final = (moisture_now + d_evap) * d_rain_shadow;
        if (moisture_final < 0.0f) moisture_final = 0.0f;
        else if (moisture_final > 1.0f) moisture_final = 1.0f;
        M[i] = moisture_final;
}

void climate_pass_b_land_range_pure(const ClimatePassBKnobs &knobs,
                                    const ClimatePassBLanes &lanes,
                                    const int *land_idx,
                                    int begin, int end) {
    if (land_idx == nullptr) return;
    for (int k = begin; k < end; ++k) {
        pass_b_land_cell(knobs, lanes, land_idx[k]);
    }
}

void climate_pass_b_sea_ice_tail_pure(const ClimatePassBKnobs &knobs,
                                      const ClimatePassBLanes &lanes) {
    const auto n_cells = knobs.n_cells;
    const auto sea_ice_albedo_cooling = knobs.sea_ice_albedo_cooling;
    const auto IW = lanes.is_water;
    const auto SIF_PB = lanes.sea_ice_frac;
    const auto LANOM = lanes.local_thermal_anomaly;

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈尾循环（仅水域）。
    // A 修复（2026-06）：水域 cell sea-ice 反照率冷却也作为 local anomaly 贡献，
    // 不再直接改写 cell_temp。LANOM 已被 pass_a 末尾清零，pass_b 主循环对 water cell
    // 也不写（与原 scalar 一致），所以此处直接累加为水域唯一的 LANOM 贡献。
    if (sea_ice_albedo_cooling > 0.0f && SIF_PB != nullptr) {
        for (int i = 0; i < n_cells; ++i) {
            if (IW[i] == 0) continue;
            float water_local = LANOM[i] - sea_ice_albedo_cooling * SIF_PB[i];
            if (water_local < -0.08f) water_local = -0.08f;
            else if (water_local > 0.08f) water_local = 0.08f;
            LANOM[i] = water_local;
        }
    }
}

void climate_pass_b_pure(const ClimatePassBKnobs &knobs,
                         const ClimatePassBLanes &lanes) {
    if (knobs.n_cells <= 0) return;
    // 生产热路径（_thread）预筛 land_idx 后只迭代陆地；这里等价地跳过水域，
    // 保证 dense 驱动与分块驱动逐位一致。
    for (int i = 0; i < knobs.n_cells; ++i) {
        if (lanes.is_water[i] != 0) continue;
        pass_b_land_cell(knobs, lanes, i);
    }
    climate_pass_b_sea_ice_tail_pure(knobs, lanes);
}


bool _async_pass_b_kernel_pure(const ClimateInputBuf &in,
                                      const ClimateRoundStaticKnobs &knobs,
                                      ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()       != n) return false;
    if ((int)in.landform.size()       != n) return false;
    if ((int)in.vegetation.size()     != n) return false;
    if ((int)in.snowpack.size()       != n) return false;
    if ((int)in.elevation.size()      != n) return false;
    if ((int)in.lat_norm.size()       != n) return false;
    if ((int)in.pos_x.size()          != n) return false;
    if ((int)in.pos_y.size()          != n) return false;
    if ((int)in.insolation_dev.size() != n) return false;
    if ((int)in.temp.size()           != n) return false;
    if ((int)in.moisture.size()       != n) return false;
    if ((int)in.local_thermal_anomaly.size() != n) return false;
    if ((int)in.temp_transport_anomaly.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    const int foliage_size = (int)knobs.foliage_table.size();
    if (foliage_size <= 0) return false;
    // sea_ice_frac 可选；尾循环要求 size == n_cells，否则跳过
    const bool sif_valid = ((int)in.sea_ice_frac.size() == n);

    // S3 P3：worker 与生产吃同一份 climate_pass_b_pure。
    // 这里原本是一份逐行抄来的平行实现，唯一的差异是多了一个 cover == GLACIER
    // 时把 snow_cover 抬到 0.80 的钳位——生产 pass_b 并没有这一步，那条钳位让
    // moisture 在分叉矩阵里一直挂着 0.78 的最大差。合成一份内核后差异不复存在。
    ClimatePassBKnobs pbk;
    pbk.n_cells                = n;
    pbk.winter_boost           = in.scalars.pb_winter_boost;
    pbk.snow_cool              = in.scalars.pb_snow_cool;
    pbk.veg_cool               = in.scalars.pb_veg_cool;
    pbk.diurnal_amp            = in.scalars.pb_diurnal_amp;
    pbk.evap_gain              = in.scalars.pb_evap_gain;
    pbk.rs_threshold           = in.scalars.pb_rs_threshold;
    pbk.rs_factor              = in.scalars.pb_rs_factor;
    pbk.rs_lookback            = in.scalars.pb_rs_lookback;
    pbk.wrap_period_x          = double(in.scalars.wrap_period_x);
    pbk.t_freeze               = in.scalars.pb_t_freeze;
    pbk.coupling_gain          = in.scalars.pb_coupling_gain;
    pbk.coast_leak             = in.scalars.pb_coast_leak;
    pbk.sea_ice_albedo_cooling = in.scalars.pb_sea_ice_albedo_cooling;
    pbk.season_phase           = in.scalars.season_phase;
    pbk.snowpack_cover_low     = float(in.scalars.snowpack_cover_low);
    pbk.snowpack_cover_full    = float(in.scalars.snowpack_cover_full);
    pbk.foliage_size           = foliage_size;

    // LANOM 与 moisture 都是 in/out：生产路径直接在 slot 上原位累加，等价于
    // in == out 别名。先 copy 进 out，再让内核在 out 上原位改。
    auto ensure_f32 = [n](std::vector<float> &v) {
        if ((int)v.size() != n) v.resize(n);
    };
    ensure_f32(out.moisture);
    ensure_f32(out.local_thermal_anomaly);
    std::memcpy(out.local_thermal_anomaly.data(),
                in.local_thermal_anomaly.data(), n * sizeof(float));
    std::memcpy(out.moisture.data(), in.moisture.data(), n * sizeof(float));

    ClimatePassBLanes pbl;
    pbl.temp_snapshot          = in.temp.data();   // pass_b 不写 temp
    pbl.snowpack               = in.snowpack.data();
    pbl.elevation              = in.elevation.data();
    pbl.lat_norm               = in.lat_norm.data();
    pbl.pos_x                  = in.pos_x.data();
    pbl.pos_y                  = in.pos_y.data();
    pbl.insolation_dev         = in.insolation_dev.data();
    pbl.temp_transport_anomaly = in.temp_transport_anomaly.data();
    pbl.is_water               = in.is_water.data();
    pbl.landform               = in.landform.data();
    pbl.vegetation             = in.vegetation.data();
    pbl.sea_ice_frac           = sif_valid ? in.sea_ice_frac.data() : nullptr;
    pbl.neighbor_indices       = knobs.neighbor_indices.data();
    pbl.foliage_table          = knobs.foliage_table.data();
    pbl.local_thermal_anomaly  = out.local_thermal_anomaly.data();
    pbl.moisture               = out.moisture.data();

    climate_pass_b_pure(pbk, pbl);
    return true;
}

} // namespace pk_async_climate
} // namespace pk

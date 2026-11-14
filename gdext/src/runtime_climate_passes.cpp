// ─── Climate pass 纯内核实现（Godot 无依赖）──────────────────────
//
// S3 搬迁体：下面 9 个 kernel 原位于 world_ext_climate.cpp（static 文件作用域），
// 现在是生产与 SHADOW worker 共用的唯一实现。搬迁是逐字的，不含任何算法改动；
// 任何数值行为变更必须单独提案，否则无法与 S2 分叉矩阵对齐。
//
// 不得 include godot_cpp。这一条约束就是“worker 可用”的全部含义。

#include "runtime_climate_passes.h"
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

// Remaining pure kernels, diagnostics, and round orchestration.

void finalizer_pure(const FinalizerKnobs &knobs,
                    const FinalizerLanes &lanes,
                    FinalizerStats &stats) {
    const int n = knobs.n_cells;
    if (n <= 0) return;

    // 全程 double，只在写回时收窄 —— 见头文件注释。
    float * const tp = lanes.temp;
    const float * const ts = knobs.has_temp_start ? lanes.temp_start : nullptr;
    const bool cap_temp = knobs.temp_cap_enabled && knobs.has_temp_start && ts != nullptr;

    for (int i = 0; i < n; ++i) {
        const double start_t = (ts != nullptr) ? double(ts[i]) : double(tp[i]);
        const double raw = double(tp[i]);
        double final_t = raw;
        const double pre = std::fabs(raw - start_t);
        if (lanes.preclamp_temp_deltas != nullptr) {
            lanes.preclamp_temp_deltas[i] = float(pre);
        }
        if (pre > stats.preclamp_max_temp_delta) stats.preclamp_max_temp_delta = pre;
        if (cap_temp) {
            const double lo = start_t - knobs.temp_cap;
            const double hi = start_t + knobs.temp_cap;
            final_t = final_t < lo ? lo : (final_t > hi ? hi : final_t);
            final_t = final_t < 0.0 ? 0.0 : (final_t > 1.0 ? 1.0 : final_t);
            if (std::fabs(final_t - raw) > 0.000001) ++stats.temp_clamped;
            tp[i] = float(final_t);
        }
        const double dt = std::fabs(final_t - start_t);
        if (lanes.temp_deltas != nullptr) lanes.temp_deltas[i] = float(dt);
        if (dt > 0.005) ++stats.temp_delta_gt_005;
        if (dt > 0.010) ++stats.temp_delta_gt_010;
        if (dt > 0.020) ++stats.temp_delta_gt_020;
        if (dt > stats.max_temp_delta) stats.max_temp_delta = dt;
    }

    // TTA：只在真的被 clamp 时才写。生产侧靠这个决定 CoW 要不要 fork —— 无条件
    // 写会让 buffer 与 map.* 解除别名，反而偏 ~1e-5（见生产注释）。
    float * const qp = lanes.tta;
    const float * const qs = knobs.has_tta_start ? lanes.tta_start : nullptr;
    const bool cap_tta = knobs.tta_cap > 0.0 && knobs.has_tta_start && qs != nullptr;
    for (int i = 0; i < n; ++i) {
        const double start_q = (qs != nullptr) ? double(qs[i]) : 0.0;
        const double raw = double(qp[i]);
        double final_q = raw;
        if (cap_tta) {
            const double lo = start_q - knobs.tta_cap;
            const double hi = start_q + knobs.tta_cap;
            final_q = final_q < lo ? lo : (final_q > hi ? hi : final_q);
            if (std::fabs(final_q - raw) > 0.000001) {
                qp[i] = float(final_q);
                ++stats.tta_clamped;
            }
        }
        const double aq = std::fabs(final_q);
        if (aq > stats.max_transport_anomaly) stats.max_transport_anomaly = aq;
    }

    // thermal 初始化用的是**已 clamp 的** temp。
    if (lanes.thermal != nullptr) {
        float * const hp = lanes.thermal;
        for (int i = 0; i < n; ++i) {
            bool needs = !std::isfinite(hp[i]);
            if (!needs && lanes.ema != nullptr && i < lanes.ema_size && lanes.ema[i] == 0) {
                needs = true;
            }
            if (needs) { hp[i] = tp[i]; ++stats.thermal_init; }
        }
    }
}

void overlay_production_wind_surface(ClimateInputBuf &base, const WindSurfaceInput &prod) {
    if (prod.n_cells != base.n_cells) return;
    if ((int) prod.ocean_anomaly.size() == base.n_cells) {
        base.production_ocean_anomaly = prod.ocean_anomaly;
    }
}

void overlay_production_sea_ice(ClimateInputBuf &base, const SeaIceInput &prod) {
    if (prod.n_cells != base.n_cells) return;
    const int n = prod.n_cells;
    // 只叠 sea_ice 自己消费、且不会被更早 pass 当输入的字段。
    // terrain / sif / insolation / upwelling 写进共享 lane 会让 ocean / pass_b
    // 吃到 sea_ice 时刻的快照；cell_temperature_arr 仅供 sea_ice 读，且
    // wind_surface 之后会用 worker 自己的合成温度覆盖。
    if ((int) prod.cell_temperature.size() == n) {
        base.cell_temperature_arr = prod.cell_temperature;
    }
    if ((int) prod.ocean_thermal_anomaly.size() == n) {
        base.production_sea_ice_oanom = prod.ocean_thermal_anomaly;
    }
    if ((int) prod.temp_transport_anomaly.size() == n) {
        base.production_sea_ice_tta = prod.temp_transport_anomaly;
    }
    if (base.water_terrain_ids.empty() && !prod.water_terrain_ids.empty()) {
        base.water_terrain_ids = prod.water_terrain_ids;
    }
}

// sea_ice pure kernel — 移植自 DCWorldExt::run_sea_ice_daily_pass（world_ext.cpp:6784）。
// 算法逐行 1:1 镜像 sync 路径主循环：
//   Phase A：build has_cold_neighbor[]（前一日 SIF 邻居快照）
//   Phase B：fraction 增量更新 + flip 候选收集
//
// 关键依赖：
//   - is_water_lut（256-entry 表，由 water_terrain_ids 构建）
//   - cell_temperature_arr（climate/ocean 之后调整的 T——主线程算）
//   - sea_ice_freeze_gate / sea_ice_solar_melt（已有 inline helper，worker 安全）
//
// 输入：in.{terrain, base_terrain, sea_ice_frac_inout, temp_transport_anomaly,
//           ocean_thermal_anomaly, upwelling_strength, insolation_now, cell_temperature_arr,
//           water_terrain_ids} + scalars + static knobs.neighbor_indices
// 输出：out.{sea_ice_frac, terrain, flipped_cell_indices, flipped_new_terrain}
//
// 注意：flipped lists 主线程在 poll 时消费（atlas dirty / map.terrain mirror sync）。
// out.terrain 已包含翻转结果（与 in.terrain 不同），主线程 poll 写 _slots[cell_terrain]
// 时若 apply_terrain_flips 为 true 则会同步生效。
bool _async_sea_ice_kernel_pure(const ClimateInputBuf &in,
                                       const ClimateRoundStaticKnobs &knobs,
                                       ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int) in.terrain.size()                != n) return false;
    if ((int) in.base_terrain.size()           != n) return false;
    if ((int) in.sea_ice_frac_inout.size()     != n) return false;
    if ((int) in.temp_transport_anomaly.size() != n) return false;
    if ((int) in.ocean_thermal_anomaly.size()  != n) return false;
    if ((int) in.upwelling_strength.size()     != n) return false;
    if ((int) in.insolation_now.size()         != n) return false;
    if ((int) in.cell_temperature_arr.size()   != n) return false;
    if ((int) in.water_terrain_ids.size()      <= 0) return false;
    if ((int) knobs.neighbor_indices.size() < n * 6) return false;

    if ((int) out.sea_ice_frac.size() != n) out.sea_ice_frac.resize(n);
    // 起始冰量优先取生产 pass_b 消费点记录的那份（ClimatePassBInput.sea_ice_frac）。
    // pass_b 与 sea_ice 在同一天内读的是同一个值 —— 当天还没有人改写过它 —— 而
    // capture 侧的 sea_ice_frac_inout 是 tick 某一刻的 slot 快照，两者并不同时。
    // 没有生产记录时（例如生产这天没跑 pass_b）才退回快照。
    const float *frac_in = ((int) in.sea_ice_frac.size() == n)
        ? in.sea_ice_frac.data() : in.sea_ice_frac_inout.data();
    std::memcpy(out.sea_ice_frac.data(), frac_in, n * sizeof(float));
    if ((int) out.terrain.size() != n) out.terrain.resize(n);
    std::memcpy(out.terrain.data(), in.terrain.data(), n);
    out.flipped_cell_indices.clear();
    out.flipped_new_terrain.clear();

    SeaIceKnobs sk;
    sk.n_cells = n;
    sk.k_freeze = in.scalars.si_k_freeze;
    sk.k_melt = in.scalars.si_k_melt;
    sk.t_form = in.scalars.si_t_form;
    sk.t_melt = in.scalars.si_t_melt;
    sk.contagion = in.scalars.si_contagion;
    sk.threshold = in.scalars.si_threshold;
    sk.hysteresis = in.scalars.si_hysteresis;
    sk.ice_delay = in.scalars.si_ice_delay;
    sk.enable_ocean_heat_transport = in.scalars.si_enable_oht;
    sk.solar_gate_enabled = in.scalars.si_solar_gate_enabled;
    sk.freeze_insol_low = in.scalars.si_freeze_insol_low;
    sk.freeze_insol_high = in.scalars.si_freeze_insol_high;
    sk.solar_melt_start = in.scalars.si_solar_melt_start;
    sk.solar_melt_gain = in.scalars.si_solar_melt_gain;
    sk.min_thick_ice_solar_exposure = in.scalars.si_min_thick_ice_solar_exposure;
    sk.daily_delta_cap = in.scalars.si_daily_delta_cap;
    sk.edge_mix_rate = in.scalars.si_edge_mix_rate;
    sk.dt_days = in.scalars.si_dt_days;
    sk.terrain_lake_id = in.scalars.si_terrain_lake_id;
    sk.terrain_sea_ice_id = in.scalars.si_terrain_sea_ice_id;
    sk.terrain_ocean_id = in.scalars.si_terrain_ocean_id;

    SeaIceLanes sl;
    sl.terrain = in.terrain.data();
    sl.base_terrain = in.base_terrain.data();
    sl.cell_temperature = in.cell_temperature_arr.data();
    sl.temp_transport_anomaly =
        ((int) in.production_sea_ice_tta.size() == n)
            ? in.production_sea_ice_tta.data()
            : in.temp_transport_anomaly.data();
    sl.ocean_thermal_anomaly =
        ((int) in.production_sea_ice_oanom.size() == n)
            ? in.production_sea_ice_oanom.data()
            : in.ocean_thermal_anomaly.data();
    sl.upwelling_strength = in.upwelling_strength.data();
    sl.insolation_now = in.insolation_now.data();
    sl.water_terrain_ids = in.water_terrain_ids.data();
    sl.water_terrain_ids_size = (int) in.water_terrain_ids.size();
    sl.neighbor_indices = knobs.neighbor_indices.data();
    sl.sea_ice_frac = out.sea_ice_frac.data();

    SeaIceScratch scratch;
    SeaIceEmit emit;
    sea_ice_pure(sk, sl, scratch, emit);

    // 生产把两份 flip 列表分开回填给 GDScript，worker 侧的 out 只有一对
    // (indices, new_terrain)，所以在这里合成。顺序按生产的收集顺序：同一个主循环
    // 里按 cell idx 升序，to_ice 与 to_base 交错 —— 但两份列表各自升序且互斥，
    // 合并成一条时按 idx 归并即可复现同一序列。
    size_t a = 0, b = 0;
    const uint8_t ice_terr = uint8_t(sk.terrain_sea_ice_id & 0xFF);
    while (a < emit.flip_to_ice.size() || b < emit.flip_to_base.size()) {
        const bool take_ice = (b >= emit.flip_to_base.size()) ||
            (a < emit.flip_to_ice.size() && emit.flip_to_ice[a] <= emit.flip_to_base[b]);
        if (take_ice) {
            out.flipped_cell_indices.push_back(emit.flip_to_ice[a]);
            out.flipped_new_terrain.push_back(ice_terr);
            ++a;
        } else {
            out.flipped_cell_indices.push_back(emit.flip_to_base[b]);
            out.flipped_new_terrain.push_back(emit.flip_to_base_terrain[b]);
            ++b;
        }
    }
    if (in.scalars.si_apply_terrain_flips) {
        uint8_t *TR_OUT = out.terrain.data();
        for (size_t k = 0; k < out.flipped_cell_indices.size(); ++k) {
            const int idx = out.flipped_cell_indices[k];
            if (idx >= 0 && idx < n) TR_OUT[idx] = out.flipped_new_terrain[k];
        }
    }
    return true;
}

// transp pure kernel — 移植自 run_transpiration_pass（world_ext.cpp:7341）。
// 算法逐行 1:1，输入输出全 std::vector，不写 _slots，不调 _flush_slot_to_map。
// 输出在 out.moisture / out.moisture_dirty_indices / out.moisture_dirty_values。
//
// ✅ Stage 3 数据流闭环：worker loop 在每个 pass 跑完后把 out.field 同步回
// in.field，让后续 pass 读 in 就拿到 fresh 值。transp 是 round 最后 pass，
// 读 in.moisture 时 pass_b 已把它的输出同步回去（pass_b → in.moisture），
// 等价于 sync 路径里 transp 读 _slots[cell_moisture]（已被 pass_b 写过）。
//
// 返回 true 成功，false 表示 input 验证失败（输入维度不匹配）。
bool _async_transp_kernel_pure(const ClimateInputBuf &in,
                                      const ClimateRoundStaticKnobs &knobs,
                                      ClimateWorkBuf &work,
                                      ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.landform.size()   != n) return false;
    if ((int)in.vegetation.size() != n) return false;
    if ((int)in.moisture.size()   != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    const int donor_size = (int)knobs.donor_table.size();
    if (donor_size <= 0) return false;

    const float outflow_rate = in.scalars.transp_outflow_rate;
    const float self_rate    = in.scalars.transp_self_rate;

    // 准备工作 buffer
    if ((int)work.deltas.size() != n) work.deltas.assign(n, 0.0f);
    else std::fill(work.deltas.begin(), work.deltas.end(), 0.0f);
    float *D = work.deltas.data();

    const uint8_t *LF  = in.landform.data();
    const uint8_t *VEG = in.vegetation.data();
    const float   *M_in = in.moisture.data();
    const int32_t *NB   = knobs.neighbor_indices.data();
    const float   *DON  = knobs.donor_table.data();

    // ─── Phase 1: compute deltas（与 sync 路径 1:1） ───
    for (int i = 0; i < n; ++i) {
        if (LF[i] <= 3) continue;             // skip water cells (LandformType.is_water)
        const uint8_t veg_id = VEG[i];
        if (veg_id >= donor_size) continue;    // safety
        const float trans = DON[veg_id];
        if (trans < 0.01f) continue;
        const float moist = M_in[i];
        const float output      = trans * moist;
        const float self_share = output * self_rate;

        const int base = i * 6;
        int valid_land_neighbors = 0;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            if (LF[nb_idx] <= 3) continue;     // 水面邻居不接受陆地蒸腾外溢
            ++valid_land_neighbors;
        }
        const float transported = valid_land_neighbors > 0 ? output * outflow_rate : 0.0f;
        D[i] += self_share - transported;
        const float nb_share = valid_land_neighbors > 0
            ? transported / float(valid_land_neighbors) : 0.0f;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0 || LF[nb_idx] <= 3) continue;
            D[nb_idx] += nb_share;
        }
    }

    // ─── Phase 2: apply deltas to output（先 copy input → output，再 +deltas） ───
    if ((int)out.moisture.size() != n) out.moisture.assign(n, 0.0f);
    std::memcpy(out.moisture.data(), M_in, n * sizeof(float));
    if ((int)out.moisture_dirty_indices.size() < n) {
        out.moisture_dirty_indices.assign(n, 0);
    }
    if ((int)out.moisture_dirty_values.size() < n) {
        out.moisture_dirty_values.assign(n, 0.0f);
    }
    int32_t *dirty_idx = out.moisture_dirty_indices.data();
    float   *dirty_val = out.moisture_dirty_values.data();
    int dirty_count = 0;

    float *M_out = out.moisture.data();
    for (int i = 0; i < n; ++i) {
        const float d = D[i];
        if (d == 0.0f) continue;
        float v = M_out[i] + d;
        if (v < 0.0f) v = 0.0f;
        else if (v > 1.0f) v = 1.0f;
        if (M_out[i] != v) {
            M_out[i] = v;
            dirty_idx[dirty_count] = i;
            dirty_val[dirty_count] = v;
            ++dirty_count;
        }
    }
    out.moisture_dirty_indices.resize(dirty_count);
    out.moisture_dirty_values.resize(dirty_count);
    return true;
}

// ─── finalizer kernel（Stage 9，2026-06-16） ──────────────────────────────
// 移植自 GDScript ClimateDailySystem::_apply_daily_climate_finalizer
// (climate_daily_system.gd:586)。
//
// 行为完全 1:1（含 mirror_temperature_cells / TTA clamp / thermal init / sort /
// percentile / sea_ice_delta_max / precip_p95）。但有几点关键区别：
//   1. 不写 HexCell facade（worker thread 不能碰 Godot Object）。GDScript 端
//      在 facade 启用时 mirror=false，cell.temperature getter 直接走 SoA，所以
//      worker 写 out.temp + 主线程 publish_to_slot 完全等价。facade 关闭时
//      （兼容 fallback 路径）GDScript 自己跑 finalizer。
//   2. 读 in.temp / in.tta / in.thermal_energy / in.ema_initialized / in.sea_ice_frac /
//      in.sea_ice_frac_prev / in.weather_precip。
//   3. 输入 baseline：in.temp_start_of_day / in.tta_start_of_day。size==n 时
//      启用 clamp，否则跳过（diag 仍累计 max_delta）。
//   4. 写 out.temp（覆盖 wind_surface 的输出）/ out.tta（in/out aliasing —
//      需要先 copy in→out 再 clamp）/ out.thermal_energy（覆盖 pass_a 的输出）。
//
// 返回 true 成功 / false 输入维度问题。
bool _async_finalizer_kernel_pure(const ClimateInputBuf &in,
                                         ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int) in.temp.size() != n) return false;
    if ((int) in.temp_transport_anomaly.size() != n) return false;
    if ((int) in.thermal_energy.size() != n) return false;

    // wind_surface 是 out.temp 的唯一写者（round 最终 temp），finalizer 在它之上 cap。
    // mask 关掉 wind_surface 时用 in.temp 兜底。
    if ((int) out.temp.size() != n) {
        out.temp.assign(size_t(n), 0.0f);
        std::memcpy(out.temp.data(), in.temp.data(), size_t(n) * sizeof(float));
    }
    if ((int) out.tta_final.size() != n) out.tta_final.assign(size_t(n), 0.0f);
    std::memcpy(out.tta_final.data(), in.temp_transport_anomaly.data(),
                size_t(n) * sizeof(float));
    if ((int) out.thermal_energy.size() != n) out.thermal_energy.assign(size_t(n), 0.0f);
    std::memcpy(out.thermal_energy.data(), in.thermal_energy.data(),
                size_t(n) * sizeof(float));

    const bool has_temp_start = in.scalars.fin_has_temp_start
                                && (int) in.temp_start_of_day.size() == n;
    const bool has_tta_start = in.scalars.fin_has_tta_start
                               && (int) in.tta_start_of_day.size() == n;

    FinalizerKnobs fk;
    fk.n_cells = n;
    fk.temp_cap_enabled = in.scalars.fin_temp_cap_enabled;
    fk.temp_cap = double(in.scalars.fin_temp_cap);
    fk.tta_cap = double(in.scalars.fin_tta_cap);
    fk.has_temp_start = has_temp_start;
    fk.has_tta_start = has_tta_start;

    std::vector<float> temp_deltas(size_t(n), 0.0f);
    std::vector<float> preclamp_temp_deltas(size_t(n), 0.0f);

    FinalizerLanes fl;
    fl.temp_start = has_temp_start ? in.temp_start_of_day.data() : nullptr;
    fl.tta_start = has_tta_start ? in.tta_start_of_day.data() : nullptr;
    fl.ema = in.ema_initialized.empty() ? nullptr : in.ema_initialized.data();
    fl.ema_size = (int) in.ema_initialized.size();
    fl.temp = out.temp.data();
    fl.tta = out.tta_final.data();
    fl.thermal = out.thermal_energy.data();
    fl.temp_deltas = temp_deltas.data();
    fl.preclamp_temp_deltas = preclamp_temp_deltas.data();

    FinalizerStats fs;
    finalizer_pure(fk, fl, fs);

    out.fin_max_temp_delta = float(fs.max_temp_delta);
    out.fin_preclamp_max_temp_delta = float(fs.preclamp_max_temp_delta);
    out.fin_temp_delta_gt_005_count = fs.temp_delta_gt_005;
    out.fin_temp_delta_gt_010_count = fs.temp_delta_gt_010;
    out.fin_temp_delta_gt_020_count = fs.temp_delta_gt_020;
    out.fin_temp_delta_clamped_count = fs.temp_clamped;
    out.fin_max_transport_anomaly = float(fs.max_transport_anomaly);
    out.fin_tta_clamped_count = fs.tta_clamped;
    out.fin_thermal_init_count = fs.thermal_init;

    // p95 / p99 是 worker 独有的观测量，生产不算，所以留在适配器里。
    std::sort(temp_deltas.begin(), temp_deltas.end());
    std::sort(preclamp_temp_deltas.begin(), preclamp_temp_deltas.end());
    auto percentile = [](const std::vector<float> &sorted, double pct) -> float {
        if (sorted.empty()) return 0.0f;
        const int idx = std::min((int) sorted.size() - 1,
                                 (int) std::floor(double(sorted.size() - 1) * pct));
        return sorted[size_t(idx)];
    };
    out.fin_p95_temp_delta = percentile(temp_deltas, 0.95);
    out.fin_p99_temp_delta = percentile(temp_deltas, 0.99);
    out.fin_preclamp_p99_temp_delta = percentile(preclamp_temp_deltas, 0.99);

    // ── sea_ice_delta_max（仅当 in.sea_ice_frac / in.sea_ice_frac_prev 都齐） ──
    out.fin_sea_ice_delta_max = 0.0f;
    if ((int)in.sea_ice_frac.size() == n && (int)in.sea_ice_frac_prev.size() == n) {
        const float *SIF = in.sea_ice_frac.data();
        const float *SIFp = in.sea_ice_frac_prev.data();
        float max_ds = 0.0f;
        for (int i = 0; i < n; ++i) {
            const float ds = std::fabs(SIF[i] - SIFp[i]);
            if (ds > max_ds) max_ds = ds;
        }
        out.fin_sea_ice_delta_max = max_ds;
    }

    // ── precip_p95（sort weather_precip duplicate） ──
    out.fin_precip_p95 = 0.0f;
    if ((int)in.weather_precip.size() == n) {
        std::vector<float> precip_vals(in.weather_precip);
        std::sort(precip_vals.begin(), precip_vals.end());
        out.fin_precip_p95 = percentile(precip_vals, 0.95f);
    }

    out.fin_cells_seen = n;
    out.fin_applied = true;
    return true;
}


// ─── 生产 pass_a 输入叠加（见头文件注释）─────────────────────────────
namespace {

// Names every per-cell lane that still differs after the pass_a overlay. Some
// differences are expected — a lane the worker owns (vapor, cloud, sea ice) is
// the thing being compared, not an input — so this prints everything and leaves
// the judgement to the reader. On the first round of a run nothing has diverged
// yet, so on that day every entry here is an input bug.
bool pk_lane_diag_enabled() {
    static const bool on = [] {
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_LANE_DIAG);
        return v != nullptr && v[0] == '1';
    }();
    return on;
}

template <typename T>
void pk_report_lane(const char *name, const std::vector<T> &before,
                    const std::vector<T> &after) {
    // nonzero counts matter as much as the delta: a lane the capture path never
    // populated reads as all-zero, and without a recording point the overlay
    // cannot fix it. "capture_nz=0" on a lane that should carry a field is the
    // signature of a missing capture, not of a stale one.
    size_t before_nz = 0;
    for (const T &v : before) {
        if (v != T{}) ++before_nz;
    }
    size_t after_nz = 0;
    for (const T &v : after) {
        if (v != T{}) ++after_nz;
    }
    if (before.size() != after.size()) {
        std::fprintf(stderr,
                     "[lane-diag] %-28s size capture=%zu(nz=%zu) overlaid=%zu(nz=%zu)\n",
                     name, before.size(), before_nz, after.size(), after_nz);
        return;
    }
    size_t changed = 0;
    size_t first = 0;
    for (size_t i = 0; i < after.size(); ++i) {
        if (before[i] == after[i]) continue;
        if (changed == 0) first = i;
        ++changed;
    }
    std::fprintf(stderr,
                 "[lane-diag] %-28s n=%zu capture_nz=%zu overlaid_nz=%zu changed=%zu",
                 name, after.size(), before_nz, after_nz, changed);
    if (changed != 0) {
        std::fprintf(stderr, " first=%zu capture=%.9g prod=%.9g", first,
                     static_cast<double>(before[first]),
                     static_cast<double>(after[first]));
    }
    std::fprintf(stderr, "\n");
}

} // namespace

bool round_input_lane_diag_enabled() { return pk_lane_diag_enabled(); }

void report_round_input_lane_delta(const ClimateInputBuf &before,
                                   const ClimateInputBuf &after,
                                   int64_t day) {
    std::fprintf(stderr, "[lane-diag] ==== day %lld ====\n",
                 static_cast<long long>(day));
#define PK_INPUT_LANE(field, type) pk_report_lane(#field, before.field, after.field);
#include "runtime_climate_input_lane_fields.inc"
#undef PK_INPUT_LANE
    std::fprintf(stderr, "[lane-diag] ---- end of overlay delta ----\n");
    std::fflush(stderr);
}

void overlay_production_pass_a(ClimateInputBuf &base, const ClimateInputBuf &prod) {
    if (prod.n_cells <= 0 || prod.n_cells != base.n_cells) return;

    // prod 里为空 = 生产那一轮也没启用这条可选列（sync 路径以 slot 缺失为不启用），
    // 此时保留 base 会让 worker 多启用一条列 —— 所以可选列必须连"空"一起照抄。
    // 下面按 pass_a 是否真的读它来分两类。
    auto take_f32 = [](std::vector<float> &dst, const std::vector<float> &src) {
        if (!src.empty()) dst = src;
    };
    auto take_u8 = [](std::vector<uint8_t> &dst, const std::vector<uint8_t> &src) {
        if (!src.empty()) dst = src;
    };
    // 必填列：pass_a 一定读，prod 一定非空。
    take_u8(base.is_water, prod.is_water);
    take_u8(base.cover, prod.cover);
    take_u8(base.ema_initialized, prod.ema_initialized);
    take_f32(base.elevation, prod.elevation);
    take_f32(base.base_moisture, prod.base_moisture);
    take_f32(base.lat_norm, prod.lat_norm);
    take_f32(base.temp_baseline_year, prod.temp_baseline_year);
    take_f32(base.temp, prod.temp);
    take_f32(base.temp_30d, prod.temp_30d);
    take_f32(base.temp_365d, prod.temp_365d);
    take_f32(base.thermal_energy, prod.thermal_energy);
    take_f32(base.snowpack, prod.snowpack);
    take_f32(base.moisture, prod.moisture);
    take_f32(base.insol_annual_mean, prod.insol_annual_mean);
    take_f32(base.radiative_modifier_add, prod.radiative_modifier_add);
    take_f32(base.radiative_modifier_factor, prod.radiative_modifier_factor);
    // 可选列：内核以"长度 == n"为启用条件，生产以"slot 存在"为启用条件。这里连空一起
    // 抄，才能让两边的启用集合一致；保留 base 的非空值会让 worker 多算一项 anomaly。
    base.weather_vapor = prod.weather_vapor;
    base.weather_precip = prod.weather_precip;
    base.soil_moisture = prod.soil_moisture;
    base.water_balance_30d = prod.water_balance_30d;
    base.maritime = prod.maritime;

    // pass_a 标量子集。逐字段列 —— 见头文件注释里为什么不能整体覆盖 scalars。
    ClimateRoundScalars &s = base.scalars;
    const ClimateRoundScalars &p = prod.scalars;
    s.season_phase = p.season_phase;
    s.axial_tilt_deg = p.axial_tilt_deg;
    s.day_length_gain = p.day_length_gain;
    s.solar_gain = p.solar_gain;
    s.insol_amp = p.insol_amp;
    s.insol_gain = p.insol_gain;
    s.insol_dev_min = p.insol_dev_min;
    s.insol_dev_max = p.insol_dev_max;
    s.thermal_inertia_land = p.thermal_inertia_land;
    s.thermal_inertia_water = p.thermal_inertia_water;
    s.thermal_inertia_snow = p.thermal_inertia_snow;
    s.thermal_inertia_high_mountain = p.thermal_inertia_high_mountain;
    s.thermal_daily_delta_cap = p.thermal_daily_delta_cap;
    s.thermal_dt_days = p.thermal_dt_days;
    s.runtime_moisture_base_relax_rate = p.runtime_moisture_base_relax_rate;
    s.runtime_moisture_weather_vapor_weight = p.runtime_moisture_weather_vapor_weight;
    s.runtime_moisture_precip_weight = p.runtime_moisture_precip_weight;
    s.runtime_moisture_soil_weight = p.runtime_moisture_soil_weight;
    s.runtime_moisture_soil_dry_weight = p.runtime_moisture_soil_dry_weight;
    s.runtime_moisture_water_balance_weight = p.runtime_moisture_water_balance_weight;
    s.runtime_moisture_water_balance_dry_weight = p.runtime_moisture_water_balance_dry_weight;
    // 生产 sync 路径没有给 snowpack_cover_full 赋值，它用的就是结构默认值。要逐位相同
    // 就得连这个"默认"一起抄，而不是保留 base 从 GDScript 传来的那个。
    s.snowpack_cover_low = p.snowpack_cover_low;
    s.snowpack_cover_full = p.snowpack_cover_full;
    s.maritime_season_damp = p.maritime_season_damp;
    s.sea_level = p.sea_level;
    s.days_per_year = p.days_per_year;
}


// ─── 生产其余 pass 标量叠加（见头文件注释）───────────────────────────
void overlay_production_pass_b(ClimateInputBuf &base, const ClimatePassBInput &prod) {
    if (base.n_cells <= 0 || prod.n_cells != base.n_cells) return;
    const size_t n = static_cast<size_t>(base.n_cells);
    if (prod.sea_ice_frac.size() == n) base.sea_ice_frac = prod.sea_ice_frac;
    if (prod.temp_transport_anomaly.size() == n) {
        base.temp_transport_anomaly = prod.temp_transport_anomaly;
    }
}

void overlay_production_wind_air(ClimateInputBuf &base, const WindAirInput &prod) {
    if (base.n_cells <= 0 || prod.n_cells != base.n_cells) return;
    const size_t n = static_cast<size_t>(base.n_cells);
    if (prod.baseline.size() == n) base.wind_baseline = prod.baseline;
    if (prod.wind_x.size() == n) base.wind_x = prod.wind_x;
    if (prod.wind_y.size() == n) base.wind_y = prod.wind_y;
    if (prod.wind_speed.size() == n) base.wind_speed = prod.wind_speed;
    // 轨迹表只有整对齐全才叠。生产未命中时这里清空，而不是留上一天那张 ——
    // 留着会让 worker 在生产走离散分支的那一天仍然做重心插值。
    if (prod.traj_idx.size() == n * 3u && prod.traj_w.size() == n * 3u) {
        base.wind_traj_idx = prod.traj_idx;
        base.wind_traj_w = prod.traj_w;
    } else {
        base.wind_traj_idx.clear();
        base.wind_traj_w.clear();
    }
}

namespace {

// Names every knob that production and the worker disagree on *and* that the
// overlay above does not carry across. Those are the real holes: a knob the
// worker guessed from the kick-time dictionary while production used something
// else. Enabled with PK_CLIMATE_SCALAR_DIAG=1 because it prints per round.
bool pk_scalar_diag_enabled() {
    static const bool on = [] {
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_SCALAR_DIAG);
        return v != nullptr && v[0] == '1';
    }();
    return on;
}

void pk_report_uncovered_scalars(const ClimateRoundScalars &before,
                                 const ClimateRoundScalars &after,
                                 const ClimateRoundScalars &prod,
                                 int scalar_mask) {
    int holes = 0;
#define PK_ROUND_SCALAR(field)                                                 \
    if (static_cast<double>(before.field) != static_cast<double>(prod.field) && \
        static_cast<double>(after.field) != static_cast<double>(prod.field)) {  \
        std::fprintf(stderr,                                                    \
                     "[scalar-diag] mask=0x%02X uncovered %s worker=%.9g prod=%.9g\n", \
                     scalar_mask, #field, static_cast<double>(after.field),      \
                     static_cast<double>(prod.field));                          \
        ++holes;                                                                \
    }
#include "runtime_climate_round_scalar_fields.inc"
#undef PK_ROUND_SCALAR
    if (holes != 0) std::fflush(stderr);
}

} // namespace

void overlay_production_round_scalars(ClimateInputBuf &base,
                                     const ClimateRoundScalars &p,
                                     int scalar_mask) {
    ClimateRoundScalars &s = base.scalars;
    const ClimateRoundScalars before = pk_scalar_diag_enabled()
        ? base.scalars : ClimateRoundScalars{};
    // wrap_period_x 是五个 advect 类 pass 共用的域宽，任一 pass 记录过就采用。
    if (scalar_mask != 0) s.wrap_period_x = p.wrap_period_x;
    if ((scalar_mask & 0x01) != 0) {
        // pass_a 段。thermal_dt_days 在这里：生产每约十天跑一次气候并用 dt 补偿，
        // 所以它绝不是 1，而 worker 若退回默认值，所有带 dt 的量（热惯性 EMA、
        // 海冰日上限、天气过渡速率）都会整场偏掉。
        s.season_phase = p.season_phase;
        s.axial_tilt_deg = p.axial_tilt_deg;
        s.day_length_gain = p.day_length_gain;
        s.solar_gain = p.solar_gain;
        s.insol_amp = p.insol_amp;
        s.insol_gain = p.insol_gain;
        s.insol_dev_min = p.insol_dev_min;
        s.insol_dev_max = p.insol_dev_max;
        s.thermal_inertia_land = p.thermal_inertia_land;
        s.thermal_inertia_water = p.thermal_inertia_water;
        s.thermal_inertia_snow = p.thermal_inertia_snow;
        s.thermal_inertia_high_mountain = p.thermal_inertia_high_mountain;
        s.thermal_daily_delta_cap = p.thermal_daily_delta_cap;
        s.thermal_dt_days = p.thermal_dt_days;
        s.runtime_moisture_base_relax_rate = p.runtime_moisture_base_relax_rate;
        s.runtime_moisture_weather_vapor_weight = p.runtime_moisture_weather_vapor_weight;
        s.runtime_moisture_precip_weight = p.runtime_moisture_precip_weight;
        s.runtime_moisture_soil_weight = p.runtime_moisture_soil_weight;
        s.runtime_moisture_soil_dry_weight = p.runtime_moisture_soil_dry_weight;
        s.runtime_moisture_water_balance_weight = p.runtime_moisture_water_balance_weight;
        s.runtime_moisture_water_balance_dry_weight = p.runtime_moisture_water_balance_dry_weight;
        s.snowpack_cover_low = p.snowpack_cover_low;
        s.maritime_season_damp = p.maritime_season_damp;
        s.sea_level = p.sea_level;
        s.days_per_year = p.days_per_year;
    }
    if ((scalar_mask & 0x02) != 0) {
        s.pb_winter_boost = p.pb_winter_boost;
        s.pb_snow_cool = p.pb_snow_cool;
        s.pb_veg_cool = p.pb_veg_cool;
        s.pb_diurnal_amp = p.pb_diurnal_amp;
        s.pb_evap_gain = p.pb_evap_gain;
        s.pb_rs_threshold = p.pb_rs_threshold;
        s.pb_rs_factor = p.pb_rs_factor;
        s.pb_rs_lookback = p.pb_rs_lookback;
        s.pb_t_freeze = p.pb_t_freeze;
        s.pb_coupling_gain = p.pb_coupling_gain;
        s.pb_coast_leak = p.pb_coast_leak;
        s.pb_sea_ice_albedo_cooling = p.pb_sea_ice_albedo_cooling;
    }
    if ((scalar_mask & 0x04) != 0) {
        s.ow_advect_steps = p.ow_advect_steps;
        s.ow_heat_mix = p.ow_heat_mix;
        s.ow_tta_source_cap = p.ow_tta_source_cap;
        s.ow_cold_transport_form = p.ow_cold_transport_form;
        s.ow_cold_transport_melt = p.ow_cold_transport_melt;
        s.ow_tta_blend_rate = p.ow_tta_blend_rate;
        s.ow_tta_zero_current_decay = p.ow_tta_zero_current_decay;
    }
    if ((scalar_mask & 0x08) != 0) {
        s.ol_effective_leak = p.ol_effective_leak;
        s.ol_tta_source_cap = p.ol_tta_source_cap;
        s.ol_tta_blend_rate = p.ol_tta_blend_rate;
        s.ol_tta_decay_rate = p.ol_tta_decay_rate;
    }
    if ((scalar_mask & 0x10) != 0) {
        s.wa_advect_steps = p.wa_advect_steps;
        s.wa_heat_mix = p.wa_heat_mix;
    }
    if ((scalar_mask & 0x20) != 0) {
        s.ws_air_leak = p.ws_air_leak;
        s.ws_cold_transport_form = p.ws_cold_transport_form;
        s.ws_cold_transport_melt = p.ws_cold_transport_melt;
    }
    if ((scalar_mask & 0x40) != 0) {
        s.si_k_freeze = p.si_k_freeze;
        s.si_k_melt = p.si_k_melt;
        s.si_t_form = p.si_t_form;
        s.si_t_melt = p.si_t_melt;
        s.si_contagion = p.si_contagion;
        s.si_threshold = p.si_threshold;
        s.si_hysteresis = p.si_hysteresis;
        s.si_ice_delay = p.si_ice_delay;
        s.si_enable_oht = p.si_enable_oht;
        s.si_solar_gate_enabled = p.si_solar_gate_enabled;
        s.si_freeze_insol_low = p.si_freeze_insol_low;
        s.si_freeze_insol_high = p.si_freeze_insol_high;
        s.si_solar_melt_start = p.si_solar_melt_start;
        s.si_solar_melt_gain = p.si_solar_melt_gain;
        s.si_min_thick_ice_solar_exposure = p.si_min_thick_ice_solar_exposure;
        s.si_daily_delta_cap = p.si_daily_delta_cap;
        s.si_edge_mix_rate = p.si_edge_mix_rate;
        s.si_dt_days = p.si_dt_days;
        s.si_terrain_lake_id = p.si_terrain_lake_id;
        s.si_terrain_sea_ice_id = p.si_terrain_sea_ice_id;
        s.si_terrain_ocean_id = p.si_terrain_ocean_id;
    }
    // 生产这一天没跑过的 pass 不该由 worker 单方面跑：把它从 passes_mask 里摘掉，
    // 让 run_climate_round_passes 直接跳过（而不是用 base 的默认 knobs 硬跑一遍）。
    // pass_a / transp / finalizer 的启用仍由 base 决定 —— 前者由 overlay_production_pass_a
    // 保证权威，后两者没有独立的生产 knobs 记录点。
    constexpr int RECORDED_PASSES = 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40;
    s.passes_mask &= ~RECORDED_PASSES;
    s.passes_mask |= (scalar_mask & RECORDED_PASSES);

    if (pk_scalar_diag_enabled()) {
        pk_report_uncovered_scalars(before, s, p, scalar_mask);
    }
}




// ─── Round 编排（9 pass 串联，生产 worker main 与 runtime worker 共用）──────
//
// S3：这段编排本身也必须共享。它决定 pass 顺序、mask 门控、尺寸守卫，以及每个
// pass 写完后哪些字段要刷回 in 供后续 pass 读（sync 路径靠 _flush_slot_to_map +
// refresh_slots_from_map 达到同样效果）。复制一份到 runtime worker 就等于重新引入
// “两套实现”——顺序或接力字段差一条，分叉矩阵就会把它报成算法分叉。
//
// in 是 in/out：逐 pass 的接力就写在它上面，所以调用方必须传自己的可变副本
// （生产是 worker 私有的 w_in_buf，runtime worker 是 kernel 的 scratch buf）。

// Stage breadcrumb。worker 线程上的访存违例会绕过 Godot 的 crash handler，日志里
// 看不到栈。开 PK_CLIMATE_STAGE_TRACE=1 后每个 stage 前写一行并 flush，崩溃后日志
// 最后一行就是出事的 stage。默认关，开关只读一次。
static bool pk_stage_trace_enabled() {
    static const bool on = [] {
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_STAGE_TRACE);
        return v != nullptr && v[0] == '1';
    }();
    return on;
}

static void pk_stage_trace(const char *stage, int day, int n_cells, uint32_t mask) {
    if (!pk_stage_trace_enabled()) return;
    std::fprintf(stderr, "[climate][stage-trace] day=%d mask=0x%X n=%d -> %s\n",
                 day, mask, n_cells, stage);
    std::fflush(stderr);
}

bool run_climate_round_passes(ClimateInputBuf &in,
                              const ClimateRoundStaticKnobs &knobs,
                              ClimateWorkBuf &work,
                              ClimateOutputBuf &out,
                              ClimateRoundPassTiming *timing) {
    using clock = std::chrono::steady_clock;
    bool ok = true;
    const int mask = in.scalars.passes_mask;

    // ─── pass_a（bit 0） ──────────────────────────────────────────
    pk_stage_trace("pass_a", -1, in.n_cells, mask);
    const auto pa0 = clock::now();
    if ((mask & 0x01) != 0 && (int)in.is_water.size() == in.n_cells) {
        // 输入完整时跑 pass_a pure kernel
        if (timing) timing->passes_ran |= 0x1;
        if (!_async_pass_a_kernel_pure(in, out)) {
            ok = false;
        }
        // Round 数据流：pass_a 写的字段刷新到 in，让后续 pass 读到 fresh 值。
        // sync 路径里 pass_a 通过 _flush_slot_to_map 把 16 个 slot 推回 MapData，
        // 然后下一 pass 入口的 refresh_slots_from_map 把 _slots 又拉到最新。
        // async 路径不走 MapData，但同 round 内的"上一 pass 写 → 下一 pass 读"
        // 必须用 in/out 同步实现。
        // 注：pass_a 是 round 第一个 pass，没有前序 pass 写过 in 字段；只刷新
        // pass_a 的输出回 in，让 pass_b / ocean_water / wind_air / transp 等读到。
        const int n_pa = in.n_cells;
        if (n_pa > 0) {
            auto cp_if_size = [n_pa](std::vector<float> &dst, const std::vector<float> &src) {
                if ((int)src.size() == n_pa) {
                    if ((int)dst.size() != n_pa) dst.resize(n_pa);
                    std::memcpy(dst.data(), src.data(), n_pa * sizeof(float));
                }
            };
            auto cp_if_size_u8 = [n_pa](std::vector<uint8_t> &dst, const std::vector<uint8_t> &src) {
                if ((int)src.size() == n_pa) {
                    if ((int)dst.size() != n_pa) dst.resize(n_pa);
                    std::memcpy(dst.data(), src.data(), n_pa);
                }
            };
            // pass_b 读这些字段：temp_baseline / moisture / snow_cover / insolation_dev
            // ocean_water 读 temp_baseline (作 baseline_arr)；其他 pass 间接读
            cp_if_size(in.moisture,         out.moisture);
            cp_if_size(in.temp_baseline,    out.temp_baseline);
            cp_if_size(in.insolation_dev,   out.insolation_dev);
            // sea_ice 的 solar gate 与融冰量读 in.insolation_now。漏掉这一行，它读到的
            // 是 capture 快照里的全零（该 slot 在 capture 时刻还没被这一天的 pass_a
            // 写过），于是 freeze_gate / solar_melt 整场按"永夜"走 —— 生产读的是
            // pass_a 刚算出的真值。
            cp_if_size(in.insolation_now,   out.insolation_now);
            cp_if_size(in.thermal_energy,   out.thermal_energy);
            cp_if_size(in.snowpack,         out.snowpack);
            cp_if_size(in.temp_30d,         out.temp_30d);
            cp_if_size(in.temp_365d,        out.temp_365d);
            cp_if_size_u8(in.ema_initialized, out.ema_initialized);
            // ocean / local anomaly 被 pass_a 清 0；同步给 pass_b/ocean_*
            cp_if_size(in.ocean_thermal_anomaly, out.ocean_thermal_anomaly);
            cp_if_size(in.local_thermal_anomaly, out.local_thermal_anomaly);
        }
    }
    const auto pa1 = clock::now();
    if (timing) timing->pass_us[0] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            pa1 - pa0).count();
    if (timing && (mask & 0x1) != 0 &&
        (timing->passes_ran & 0x1) == 0) {
        timing->passes_starved |= 0x1;
    }

    // ─── pass_b（bit 1） ──────────────────────────────────────────
    pk_stage_trace("pass_b", -1, in.n_cells, mask);
    const auto pb0 = clock::now();
    if ((mask & 0x02) != 0
            && (int)in.is_water.size()       == in.n_cells
            && (int)in.landform.size()       == in.n_cells
            && (int)in.vegetation.size()     == in.n_cells
            && (int)in.snowpack.size()       == in.n_cells
            && (int)in.elevation.size()      == in.n_cells
            && (int)in.lat_norm.size()       == in.n_cells
            && (int)in.pos_x.size()          == in.n_cells
            && (int)in.pos_y.size()          == in.n_cells
            && (int)in.insolation_dev.size() == in.n_cells
            && (int)in.temp.size()           == in.n_cells
            && (int)in.moisture.size()       == in.n_cells
            && (int)in.local_thermal_anomaly.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)knobs.foliage_table.size() > 0) {
        if (timing) timing->passes_ran |= 0x2;
        if (!_async_pass_b_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：pass_b 写 moisture（覆盖 pass_a）+ local_thermal_anomaly。
        // 同步给 ocean_water/land 和 wind_air/surface 等后续 pass。
        const int n_pb = in.n_cells;
        if (n_pb > 0) {
            if (((int)out.moisture.size() == n_pb)
                    && (int) in.moisture.size() == n_pb) {
                std::memcpy(in.moisture.data(),
                            out.moisture.data(), n_pb * sizeof(float));
            }
            if (((int)out.local_thermal_anomaly.size() == n_pb)
                    && (int) in.local_thermal_anomaly.size() == n_pb) {
                std::memcpy(in.local_thermal_anomaly.data(),
                            out.local_thermal_anomaly.data(), n_pb * sizeof(float));
            }
        }
    }
    const auto pb1 = clock::now();
    if (timing) timing->pass_us[1] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            pb1 - pb0).count();
    if (timing && (mask & 0x2) != 0 &&
        (timing->passes_ran & 0x2) == 0) {
        timing->passes_starved |= 0x2;
    }

    // ─── ocean_water（bit 2） ─────────────────────────────────────
    pk_stage_trace("ocean_water", -1, in.n_cells, mask);
    const auto ow0 = clock::now();
    if ((mask & 0x04) != 0
            && (int)in.is_water.size()        == in.n_cells
            && (int)in.pos_x.size()           == in.n_cells
            && (int)in.pos_y.size()           == in.n_cells
            && (int)in.ocean_current_x.size() == in.n_cells
            && (int)in.ocean_current_y.size() == in.n_cells
            && (int)in.temp.size()            == in.n_cells
            && (int)in.temp_baseline_year.size() == in.n_cells
            && (int)in.ocean_thermal_anomaly.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells) {
        if (timing) timing->passes_ran |= 0x4;
        if (!_async_ocean_water_kernel_pure(in, knobs,
                                            work, out)) {
            ok = false;
        }
        // Round 数据流：ocean_water 写 ocean_thermal_anomaly (water cells)。
        // ocean_land 通过 work.ocean_tta_inout 读 water cells fresh anomaly，
        // ocean_thermal_anomaly slot 也要同步给 wind_surface 做合成。
        const int n_ow = in.n_cells;
        if ((n_ow > 0 && (int)out.ocean_thermal_anomaly.size() == n_ow)
                && (int) in.ocean_thermal_anomaly.size() == n_ow) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        out.ocean_thermal_anomaly.data(), n_ow * sizeof(float));
        }
    }
    const auto ow1 = clock::now();
    if (timing) timing->pass_us[2] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ow1 - ow0).count();
    if (timing && (mask & 0x4) != 0 &&
        (timing->passes_ran & 0x4) == 0) {
        timing->passes_starved |= 0x4;
    }

    // ─── ocean_land（bit 3） — 依赖 ocean_water 写完 work.ocean_tta_inout
    pk_stage_trace("ocean_land", -1, in.n_cells, mask);
    const auto ol0 = clock::now();
    if ((mask & 0x08) != 0
            && (int)in.is_water.size()        == in.n_cells
            && (int)in.pos_x.size()           == in.n_cells
            && (int)in.pos_y.size()           == in.n_cells
            && (int)in.ocean_current_x.size() == in.n_cells
            && (int)in.ocean_current_y.size() == in.n_cells) {
        // 若 ocean_water 没跑，ocean_tta_inout 还是空——单跑 ocean_land 时
        // 用 in.temp_transport_anomaly 初始化它。
        if ((int)work.ocean_tta_inout.size() != in.n_cells
                && (int)in.temp_transport_anomaly.size() == in.n_cells) {
            work.ocean_tta_inout.resize(in.n_cells);
            std::memcpy(work.ocean_tta_inout.data(),
                        in.temp_transport_anomaly.data(),
                        in.n_cells * sizeof(float));
        }
        if (timing) timing->passes_ran |= 0x8;
        if (!_async_ocean_land_kernel_pure(in, knobs,
                                           work, out)) {
            ok = false;
        }
        // Round 数据流：ocean_land 累加 ocean_thermal_anomaly (land cells)。
        // wind_surface 读它做合成。
        const int n_ol = in.n_cells;
        if ((n_ol > 0 && (int)out.ocean_thermal_anomaly.size() == n_ol)
                && (int) in.ocean_thermal_anomaly.size() == n_ol) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        out.ocean_thermal_anomaly.data(), n_ol * sizeof(float));
        }
    }
    const auto ol1 = clock::now();
    if (timing) timing->pass_us[3] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ol1 - ol0).count();
    if (timing && (mask & 0x8) != 0 &&
        (timing->passes_ran & 0x8) == 0) {
        timing->passes_starved |= 0x8;
    }

    // ─── wind_air / wind_surface / sea_ice 仍是 stub
    // TTA 在 round 内只活在 work.ocean_tta_inout 里（ocean_water 写水格、ocean_land
    // 写陆格），而 wind_surface 与 sea_ice 读的是 in.temp_transport_anomaly。少了这次
    // 回写，它们读到的是 kick 时刻的初值 —— 生产那两个 pass 跑在 ocean 之后，读的是
    // 刚累加完的值。与 insolation_now 是同一类漏接。
    if ((int) work.ocean_tta_inout.size() == in.n_cells &&
        (int) in.temp_transport_anomaly.size() == in.n_cells && in.n_cells > 0) {
        std::memcpy(in.temp_transport_anomaly.data(),
                    work.ocean_tta_inout.data(),
                    size_t(in.n_cells) * sizeof(float));
    }

    // 把生产 wind_surface 真正读到的 oanom 注回来（见 WindSurfaceInput 注释）。
    //
    // 位置必须在 ocean_land 之后、wind_air 之前，不能提到 pass_a 后面：
    //   • ocean_water / ocean_land 是**累加** oanom 的。提前注入等于让它们在生产的
    //     成品值上再累一遍 —— 实测 wind_surface 读到的 oanom 正好是生产的两倍。
    //   • 生产的 pass_b 跑在 ocean 之前，读到的是 pass_a 刚清零的 oanom。提前注入
    //     会让 worker 的 pass_b 读到非零值。
    // in 与 out 都要写：wind_surface 取的是 choose_field(out, in)，只写一边会被另一
    // 边的值盖掉。
    if ((int) in.production_ocean_anomaly.size() == in.n_cells && in.n_cells > 0) {
        const size_t bytes = size_t(in.n_cells) * sizeof(float);
        if ((int) in.ocean_thermal_anomaly.size() == in.n_cells) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        in.production_ocean_anomaly.data(), bytes);
        }
        if ((int) out.ocean_thermal_anomaly.size() == in.n_cells) {
            std::memcpy(out.ocean_thermal_anomaly.data(),
                        in.production_ocean_anomaly.data(), bytes);
        }
    }

    pk_stage_trace("wind_air", -1, in.n_cells, mask);
    // ─── wind_air（bit 4） ────────────────────────────────────────
    const auto wa0 = clock::now();
    if ((mask & 0x10) != 0
            && (int)in.wind_x.size()  == in.n_cells
            && (int)in.wind_y.size()  == in.n_cells
            && (int)in.wind_speed.size() == in.n_cells
            && (int)in.pos_x.size()   == in.n_cells
            && (int)in.pos_y.size()   == in.n_cells
            && (int)in.temp.size()    == in.n_cells
            && (int)in.temp_baseline_year.size() == in.n_cells) {
        if (timing) timing->passes_ran |= 0x10;
        if (!_async_wind_air_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：wind_air 写 air_mass_temp_anomaly。
        // wind_surface 读它（作为 AIN snapshot）做加权平均。
        const int n_wa = in.n_cells;
        if ((n_wa > 0 && (int)out.air_mass_temp_anomaly.size() == n_wa)
                && (int) in.air_mass_temp_anomaly.size() == n_wa) {
            std::memcpy(in.air_mass_temp_anomaly.data(),
                        out.air_mass_temp_anomaly.data(), n_wa * sizeof(float));
        }
    }
    const auto wa1 = clock::now();
    if (timing) timing->pass_us[4] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            wa1 - wa0).count();
    if (timing && (mask & 0x10) != 0 &&
        (timing->passes_ran & 0x10) == 0) {
        timing->passes_starved |= 0x10;
    }

    // ─── wind_surface（bit 5） — 依赖 wind_air / pass_a / pass_b / ocean_*
    pk_stage_trace("wind_surface", -1, in.n_cells, mask);
    const auto ws0 = clock::now();
    if ((mask & 0x20) != 0
            && (int)in.wind_x.size()  == in.n_cells
            && (int)in.wind_y.size()  == in.n_cells
            && (int)in.wind_speed.size() == in.n_cells
            && (int)in.pos_x.size()   == in.n_cells
            && (int)in.pos_y.size()   == in.n_cells) {
        if (timing) timing->passes_ran |= 0x20;
        if (!_async_wind_surface_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：wind_surface 写 cell_temp（合成）+ overwrite air_anom。
        // sea_ice 期望读 climate/ocean-adjusted T —— round 模式下这就是 wind_surface
        // 输出的 cell_temp，同步给 in.cell_temperature_arr（覆盖 kick 传入的旧值）。
        const int n_ws = in.n_cells;
        if (n_ws > 0) {
            if ((int)out.temp.size() == n_ws) {
                if ((int)in.cell_temperature_arr.size() != n_ws) {
                    in.cell_temperature_arr.resize(n_ws);
                }
                std::memcpy(in.cell_temperature_arr.data(),
                            out.temp.data(), n_ws * sizeof(float));
            }
            if (((int)out.air_mass_temp_anomaly.size() == n_ws)
                    && (int) in.air_mass_temp_anomaly.size() == n_ws) {
                std::memcpy(in.air_mass_temp_anomaly.data(),
                            out.air_mass_temp_anomaly.data(), n_ws * sizeof(float));
            }
        }
    }
    const auto ws1 = clock::now();
    if (timing) timing->pass_us[5] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ws1 - ws0).count();
    if (timing && (mask & 0x20) != 0 &&
        (timing->passes_ran & 0x20) == 0) {
        timing->passes_starved |= 0x20;
    }

    // sea_ice 仍是 stub（Stage 2 余下工作）
    // ─── sea_ice（bit 6） ─────────────────────────────────────────
    pk_stage_trace("sea_ice", -1, in.n_cells, mask);
    const auto si0 = clock::now();
    if ((mask & 0x40) != 0
            && (int)in.terrain.size()              == in.n_cells
            && (int)in.base_terrain.size()         == in.n_cells
            && (int)in.sea_ice_frac_inout.size()   == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)in.upwelling_strength.size()   == in.n_cells
            && (int)in.insolation_now.size()       == in.n_cells
            && (int)in.cell_temperature_arr.size() == in.n_cells
            && (int)in.water_terrain_ids.size()    > 0) {
        if (timing) timing->passes_ran |= 0x40;
        if (!_async_sea_ice_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：sea_ice 写 sea_ice_frac + 翻转 terrain。transp 不依赖
        // 它们；但 in.sea_ice_frac_inout / in.terrain 同步以便后续诊断 / round
        // 重复 kick 时拿到最新值（虽然单 round 不会重复跑同一 pass）。
        const int n_si = in.n_cells;
        if (n_si > 0) {
            if (((int)out.sea_ice_frac.size() == n_si)
                    && (int) in.sea_ice_frac_inout.size() == n_si) {
                std::memcpy(in.sea_ice_frac_inout.data(),
                            out.sea_ice_frac.data(), n_si * sizeof(float));
            }
            if (((int)out.terrain.size() == n_si)
                    && (int) in.terrain.size() == n_si) {
                std::memcpy(in.terrain.data(),
                            out.terrain.data(), n_si);
            }
        }
    }
    const auto si1 = clock::now();
    if (timing) timing->pass_us[6] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            si1 - si0).count();
    if (timing && (mask & 0x40) != 0 &&
        (timing->passes_ran & 0x40) == 0) {
        timing->passes_starved |= 0x40;
    }

    // ─── transp（bit 7） ──────────────────────────────────────────
    pk_stage_trace("transp", -1, in.n_cells, mask);
    const auto tr0 = clock::now();
    if ((mask & 0x80) != 0
            && (int)in.landform.size()   == in.n_cells
            && (int)in.vegetation.size() == in.n_cells
            && (int)in.moisture.size()   == in.n_cells) {
        if (timing) timing->passes_ran |= 0x80;
        if (!_async_transp_kernel_pure(in, knobs,
                                       work, out)) {
            ok = false;
        }
    }
    const auto tr1 = clock::now();
    if (timing) timing->pass_us[7] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            tr1 - tr0).count();
    if (timing && (mask & 0x80) != 0 &&
        (timing->passes_ran & 0x80) == 0) {
        timing->passes_starved |= 0x80;
    }

    // ─── finalizer（bit 8，Stage 9 2026-06-16） ──────────────────────
    pk_stage_trace("finalizer", -1, in.n_cells, mask);
    // 在 round 末尾跑一次：clamp temp/TTA、统计 Δ percentile、thermal init、
    // sea_ice_delta_max、precip_p95。等价 GDScript _apply_daily_climate_finalizer。
    const auto fi0 = clock::now();
    if ((mask & 0x100) != 0
            && (int)in.temp.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)in.thermal_energy.size() == in.n_cells) {
        // out.temp 已被 wind_surface 写入（mask bit 5 启用时）；finalizer
        // 在它之上 clamp。若 wind_surface 没写过（mask bit 5 关闭），kernel
        // 内部用 in.temp 兜底初始化 out.temp。
        if (timing) timing->passes_ran |= 0x100;
        if (!_async_finalizer_kernel_pure(in, out)) {
            ok = false;
        }
    }
    const auto fi1 = clock::now();
    if (timing) timing->pass_us[8] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            fi1 - fi0).count();
    if (timing && (mask & 0x100) != 0 &&
        (timing->passes_ran & 0x100) == 0) {
        timing->passes_starved |= 0x100;
    }
    out.n_cells = in.n_cells;
    return ok;
}



} // namespace pk_async_climate
} // namespace pk

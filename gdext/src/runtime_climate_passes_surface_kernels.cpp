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

} // namespace pk_async_climate
} // namespace pk

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

// ocean_water pure kernel — 移植自 DCWorldExt::run_ocean_water_pass（world_ext.cpp:4558）。
// 算法逐行 1:1 镜像 sync 路径（line 4655-4708）：
//   - 仅 water cell：沿 -current 方向回溯 advect_steps 步，找最对齐邻居
//   - temp_mixed = lerp(temp_self, temp_up, heat_mix)，clamp [0,1]
//   - 写 ocean_thermal_anomaly slot = clamp(temp_mixed - baseline, ±0.08)
//   - 用 dc_stabilize_tta / dc_decay_tta 更新 work.ocean_tta_inout（per-cell TTA）
//
// 输入：in.{is_water, pos_x, pos_y, ocean_current_x, ocean_current_y} + scalars
// work：work.ocean_tta_inout（in/out 累加器，pass_b 也会读它作为 TTA snapshot）
// 输出：out.ocean_thermal_anomaly（写 water cells）
//
// 注意：sync 路径接 `baseline_arr` / `temp_before_arr` knobs，但本 kernel 把
// baseline 等同于 cell_temp_baseline (in.temp_baseline)，temp_before 等同于
// in.temp（pre-pass_a 快照）。这与 sync 路径同语义（caller 都用 baseline=
// temp_baseline_a 或 EMA-init 时算的派生值；temp_before=temp_a or baseline）。
// Stage 2 期间 sync 端 caller 仍传 baseline_arr/temp_before_arr knobs，所以
// async 这里直接复用 in.temp_baseline_year / in.temp 做参考——bench 时主线程
// 把 sync 端用到的 baseline/temp_before 一并传过来。
bool _async_ocean_water_kernel_pure(const ClimateInputBuf &in,
                                           const ClimateRoundStaticKnobs &knobs,
                                           ClimateWorkBuf &work,
                                           ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()        != n) return false;
    if ((int)in.pos_x.size()           != n) return false;
    if ((int)in.pos_y.size()           != n) return false;
    if ((int)in.ocean_current_x.size() != n) return false;
    if ((int)in.ocean_current_y.size() != n) return false;
    if ((int)in.temp.size()            != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)in.sea_ice_frac.size()    != n) return false;
    if ((int)in.ocean_thermal_anomaly.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    const int advect_steps = in.scalars.ow_advect_steps;
    const float heat_mix   = in.scalars.ow_heat_mix;
    const float wrap_period_x = in.scalars.wrap_period_x;  // seam-advection-fix
    const float tta_source_cap = dc_clampf(in.scalars.ow_tta_source_cap, 0.0f, 0.5f);
    const float tta_blend_rate = dc_clampf(in.scalars.ow_tta_blend_rate, 0.0f, 1.0f);
    const float tta_zero_current_decay = dc_clampf(in.scalars.ow_tta_zero_current_decay, 0.0f, 1.0f);

    // 输出
    if ((int)out.ocean_thermal_anomaly.size() != n) out.ocean_thermal_anomaly.resize(n);
    // ocean_water 累加到 ocean_thermal_anomaly slot；首先 copy in → out 作为基础。
    std::memcpy(out.ocean_thermal_anomaly.data(),
                in.ocean_thermal_anomaly.data(),
                n * sizeof(float));

    // work.ocean_tta_inout：sync 路径的 anomaly_out。round 入口处由主线程从
    // map.temperature_transport_anomaly_arr 初始化（kick 写 in.temp_transport_anomaly），
    // worker 入口再 copy 到 work scratch。
    if ((int)work.ocean_tta_inout.size() != n) work.ocean_tta_inout.resize(n);
    std::memcpy(work.ocean_tta_inout.data(),
                in.temp_transport_anomaly.data(),
                n * sizeof(float));

    const uint8_t *IW = in.is_water.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const float *OCX  = in.ocean_current_x.data();
    const float *OCY  = in.ocean_current_y.data();
    // 生产在消费点抽的真值优先；没有时才退回旧拄本的等同假设。
    const float *TB   = ((int) in.production_ocean_temp_before.size() == n)
                        ? in.production_ocean_temp_before.data()
                        : in.temp.data();
    const float *BL   = ((int) in.production_ocean_baseline.size() == n)
                        ? in.production_ocean_baseline.data()
                        : in.temp_baseline_year.data();
    const float *SIF  = in.sea_ice_frac.data();
    const int32_t *NB = knobs.neighbor_indices.data();

    float *AOUT = work.ocean_tta_inout.data();
    float *OANOM = out.ocean_thermal_anomaly.data();

    // 与生产同一份内核。worker 整图跑，所以 [0, n)。
    {
        OceanWaterKnobs ok;
        ok.n_cells = n;
        // worker 整图跑。试过跟随生产的分片区间，结果反而退化 —— 两边对 TTA
        // 的持久方式不同：生产的分片是就地增量更新一个跳 tick 存活的数组，数组本身
        // 始终完整；worker 每天从 in.temp_transport_anomaly 重新初始化。只跑一片的话其余
        // 格子停在 kick 初值，而生产那些格子带着历史累积。
        ok.start_idx = 0;
        ok.end_idx = n;
        ok.advect_steps = advect_steps;
        ok.heat_mix = heat_mix;
        ok.wrap_period_x = wrap_period_x;
        ok.tta_source_cap = tta_source_cap;
        ok.tta_blend_rate = tta_blend_rate;
        ok.tta_zero_current_decay = tta_zero_current_decay;
        // 旧拄本这里用的是 sea_ice 的 si_t_form / si_t_melt，而生产用的是
        // cold_transport_{form,melt}_threshold —— 两组不同的 knob。现在跟生产走。
        ok.cold_transport_form = in.scalars.ow_cold_transport_form;
        ok.cold_transport_melt = in.scalars.ow_cold_transport_melt;

        OceanWaterLanes ol;
        ol.is_water = IW;
        ol.pos_x = POSX;
        ol.pos_y = POSY;
        ol.ocean_current_x = OCX;
        ol.ocean_current_y = OCY;
        ol.baseline = BL;
        ol.temp_before = TB;
        ol.sea_ice_frac = SIF;
        ol.neighbors = NB;
        ol.ocean_anomaly = OANOM;
        ol.tta_inout = AOUT;

        // Upstream temperatures are immutable; only the two outputs at i change.
        parallel_for_range("pk_climate_ocean_water", n, 0, 2048, [&](int begin, int end) {
            auto range = ok;
            range.start_idx = begin;
            range.end_idx = end;
            ocean_water_pure(range, ol);
        });
    }
    return true;
}

// ocean_land 复用同步和切片入口的纯内核。朝岸投影用于加权海邻居的温差，投影总和
// 决定衰减与全量带入之间的比例，结果写入 TTA 和 ocean_thermal_anomaly。
//
// 注意：必须在 ocean_water 之后跑，依赖 work.ocean_tta_inout 里 water cells 的
// fresh anomaly（ocean_water 已写）。
bool _async_ocean_land_kernel_pure(const ClimateInputBuf &in,
                                          const ClimateRoundStaticKnobs &knobs,
                                          ClimateWorkBuf &work,
                                          ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()        != n) return false;
    if ((int)in.pos_x.size()           != n) return false;
    if ((int)in.pos_y.size()           != n) return false;
    if ((int)in.ocean_current_x.size() != n) return false;
    if ((int)in.ocean_current_y.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    if ((int)work.ocean_tta_inout.size() != n) return false;

    const float effective_leak = in.scalars.ol_effective_leak;
    const float wrap_period_x = in.scalars.wrap_period_x;  // seam-advection-fix
    const float tta_source_cap = dc_clampf(in.scalars.ol_tta_source_cap, 0.0f, 0.5f);
    const float tta_blend_rate = dc_clampf(in.scalars.ol_tta_blend_rate, 0.0f, 1.0f);
    const float tta_decay_rate = dc_clampf(in.scalars.ol_tta_decay_rate, 0.0f, 1.0f);

    if ((int)out.ocean_thermal_anomaly.size() != n) {
        // 防御：若 ocean_water 没跑，则用 in.ocean_thermal_anomaly 作为基础
        out.ocean_thermal_anomaly.resize(n);
        std::memcpy(out.ocean_thermal_anomaly.data(),
                    in.ocean_thermal_anomaly.data(),
                    n * sizeof(float));
    }

    const uint8_t *IW = in.is_water.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const float *OCX  = in.ocean_current_x.data();
    const float *OCY  = in.ocean_current_y.data();
    const int32_t *NB = knobs.neighbor_indices.data();
    float *A = work.ocean_tta_inout.data();
    float *OANOM = out.ocean_thermal_anomaly.data();

    {
        OceanLandKnobs ok;
        ok.n_cells = n;
        // worker 整图跑。试过跟随生产的分片区间，结果反而退化 —— 两边对 TTA
        // 的持久方式不同：生产的分片是就地增量更新一个跳 tick 存活的数组，数组本身
        // 始终完整；worker 每天从 in.temp_transport_anomaly 重新初始化。只跑一片的话其余
        // 格子停在 kick 初值，而生产那些格子带着历史累积。
        ok.start_idx = 0;
        ok.end_idx = n;
        ok.effective_leak = effective_leak;
        ok.wrap_period_x = wrap_period_x;
        ok.tta_source_cap = tta_source_cap;
        ok.tta_blend_rate = tta_blend_rate;
        ok.tta_decay_rate = tta_decay_rate;

        OceanLandLanes ol;
        ol.is_water = IW;
        ol.pos_x = POSX;
        ol.pos_y = POSY;
        ol.ocean_current_x = OCX;
        ol.ocean_current_y = OCY;
        ol.neighbors = NB;
        ol.tta_inout = A;
        ol.ocean_anomaly = OANOM;

        ocean_land_pure(ok, ol);
    }
    return true;
}


void overlay_production_ocean_water(ClimateInputBuf &base, const OceanWaterInput &prod) {
    if (base.n_cells <= 0 || prod.n_cells != base.n_cells) return;
    const size_t n = static_cast<size_t>(base.n_cells);
    if (prod.baseline.size() == n) base.production_ocean_baseline = prod.baseline;
    if (prod.temp_before.size() == n) base.production_ocean_temp_before = prod.temp_before;
}

void ocean_water_pure(const OceanWaterKnobs &knobs, const OceanWaterLanes &lanes) {
    const int start = knobs.start_idx;
    const int end = knobs.end_idx;
    if (end <= start) return;

    const uint8_t * const __restrict IW = lanes.is_water;
    const float * const __restrict POSX = lanes.pos_x;
    const float * const __restrict POSY = lanes.pos_y;
    const float * const __restrict OCX = lanes.ocean_current_x;
    const float * const __restrict OCY = lanes.ocean_current_y;
    const float * const __restrict BL = lanes.baseline;
    const float * const __restrict TB = lanes.temp_before;
    const float * const __restrict SIF = lanes.sea_ice_frac;
    const int32_t * const __restrict NB = lanes.neighbors;
    float * const __restrict OANOM = lanes.ocean_anomaly;
    float * const __restrict AOUT = lanes.tta_inout;

    const int   advect_steps = knobs.advect_steps;
    const float heat_mix = knobs.heat_mix;
    const float wrap_period_x = knobs.wrap_period_x;

    for (int i = start; i < end; ++i) {
        if (IW[i] == 0) continue;  // skip land
        const float cur_x = OCX[i];
        const float cur_y = OCY[i];
        const float cur_len2 = cur_x * cur_x + cur_y * cur_y;
        if (cur_len2 < 1e-6f || advect_steps == 0) {
            AOUT[i] = dc_decay_tta(AOUT[i], knobs.tta_zero_current_decay);
            // current 不足时 ocean anomaly 也朝 0 衰减，避免上轮残值滞留。
            OANOM[i] = OANOM[i] * (1.0f - knobs.tta_zero_current_decay);
            continue;
        }
        const float inv_cur = 1.0f / std::sqrt(cur_len2);
        const float up_dx = -cur_x * inv_cur;
        const float up_dy = -cur_y * inv_cur;

        int upstream_idx = i;
        for (int step = 0; step < advect_steps; ++step) {
            int   best_idx = -1;
            float best_dot = 0.1f;
            const float swx = POSX[upstream_idx];
            const float swy = POSY[upstream_idx];
            const int ub = upstream_idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[ub + d];
                if (ni < 0) continue;
                if (IW[ni] == 0) continue;
                const float dx = pk_wrap_min_image_dx(POSX[ni] - swx, wrap_period_x);
                const float dy = POSY[ni] - swy;
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

        const float temp_self = TB[i];
        const float temp_up = TB[upstream_idx];
        float temp_mixed = temp_self + (temp_up - temp_self) * heat_mix;  // = lerpf
        if (temp_mixed < 0.0f) temp_mixed = 0.0f;
        else if (temp_mixed > 1.0f) temp_mixed = 1.0f;
        // 海冰把表层与正的洋流热异常隔开：冷异常保留，暖流注入按冰盖折减。
        float source = temp_mixed - BL[i];
        source = pk_limit_cold_water_positive_transport_source(
            source, BL[i], SIF[i], knobs.cold_transport_form, knobs.cold_transport_melt);
        float oanom = source;
        if (oanom < -0.08f) oanom = -0.08f;
        else if (oanom > 0.08f) oanom = 0.08f;
        OANOM[i] = oanom;
        AOUT[i] = dc_stabilize_tta(AOUT[i], source,
                                   knobs.tta_source_cap, knobs.tta_blend_rate);
    }
}

void ocean_land_pure(const OceanLandKnobs &knobs, const OceanLandLanes &lanes) {
    const int start = knobs.start_idx;
    const int end = knobs.end_idx;
    if (end <= start) return;

    const uint8_t * const __restrict IW = lanes.is_water;
    const float * const __restrict POSX = lanes.pos_x;
    const float * const __restrict POSY = lanes.pos_y;
    const float * const __restrict OCX = lanes.ocean_current_x;
    const float * const __restrict OCY = lanes.ocean_current_y;
    const int32_t * const __restrict NB = lanes.neighbors;
    float * const __restrict A = lanes.tta_inout;
    float * const __restrict OANOM = lanes.ocean_anomaly;

    const float wrap_period_x = knobs.wrap_period_x;
    // 96×64 地图（种子 20260718）首日岸格的正朝岸投影总和 P25 为 0.00561676。
    constexpr float full_inflow_weight = 0.0056f;
    const auto add_ocean_anomaly = [](float &ocean_anomaly, float transport) {
        if (transport < -1e-5f || transport > 1e-5f) {
            ocean_anomaly = dc_clampf(ocean_anomaly + transport, -0.08f, 0.08f);
        }
    };

    for (int i = start; i < end; ++i) {
        if (IW[i] != 0) continue;  // skip water
        const float swx = POSX[i];
        const float swy = POSY[i];
        float weighted_sum = 0.0f;
        float weight_total = 0.0f;
        const int b = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[b + d];
            if (ni < 0) continue;
            if (IW[ni] == 0) continue;  // 只有 water 邻居贡献
            const float cx = OCX[ni];
            const float cy = OCY[ni];
            if (cx * cx + cy * cy < 1e-6f) continue;
            const float dx = pk_wrap_min_image_dx(swx - POSX[ni], wrap_period_x);
            const float dy = swy - POSY[ni];
            const float dlen2 = dx * dx + dy * dy;
            if (dlen2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(dlen2);
            const float dot_v = (dx * cx + dy * cy) * inv_len;
            if (dot_v <= 0.0f) continue;
            weighted_sum += A[ni] * dot_v;
            weight_total += dot_v;
        }
        const float prev_anomaly = A[i];
        float anomaly_in = dc_decay_tta(prev_anomaly, knobs.tta_decay_rate);
        if (weight_total > 0.0f) {
            const float full_anomaly = dc_stabilize_tta(
                prev_anomaly, (weighted_sum / weight_total) * knobs.effective_leak,
                knobs.tta_source_cap, knobs.tta_blend_rate);
            if (weight_total < full_inflow_weight) {
                const float fraction = weight_total / full_inflow_weight;
                float decayed_ocean = OANOM[i];
                float full_ocean = decayed_ocean;
                // 先求两端的海洋项，避免弱来流跨过 1e-5 的写入门槛时跳变。
                add_ocean_anomaly(decayed_ocean, anomaly_in);
                add_ocean_anomaly(full_ocean, full_anomaly);
                A[i] = anomaly_in + (full_anomaly - anomaly_in) * fraction;
                OANOM[i] = decayed_ocean + (full_ocean - decayed_ocean) * fraction;
                continue;
            }
            anomaly_in = full_anomaly;
        }
        A[i] = anomaly_in;
        add_ocean_anomaly(OANOM[i], anomaly_in);
    }
}

} // namespace pk_async_climate
} // namespace pk

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

// wf_wind_speed_norm 的原地展开。world_ext_internal.h 拖进整个 Godot 头链，纯内核
// 这一侧不能包含它，所以这里复制一份——三行且无分支歧义，比让两边各写一遍安全。
static inline float wind_speed_norm(float dir_x, float dir_y, float speed) {
    if (speed > 0.0001f) return speed;
    const float len2 = dir_x * dir_x + dir_y * dir_y;
    return (len2 > 0.0001f) ? std::sqrt(len2) : 0.0f;
}

void wind_air_pure(const WindAirKnobs &knobs, const WindAirLanes &lanes,
                   int start_idx, int end_idx) {
    const int   advect_steps  = knobs.advect_steps;
    const float heat_mix      = knobs.heat_mix;
    const float wrap_period_x = knobs.wrap_period_x;

    const float   *WX   = lanes.wind_x;
    const float   *WY   = lanes.wind_y;
    const float   *WSP  = lanes.wind_speed;
    const float   *POSX = lanes.pos_x;
    const float   *POSY = lanes.pos_y;
    const float   *TB   = lanes.temp_before;
    const float   *BL   = lanes.baseline;
    const int32_t *NB   = lanes.neighbor_indices;
    float         *A    = lanes.air_anomaly;

    // 轨迹表要么整对可用，要么整对不用。只给一半时按未命中处理，而不是解引用
    // 空指针——生产的资格判定也是两个字段一起过的。
    const int32_t *TRAJ_IDX =
        (lanes.traj_idx != nullptr && lanes.traj_w != nullptr) ? lanes.traj_idx : nullptr;
    const float *TRAJ_W = TRAJ_IDX != nullptr ? lanes.traj_w : nullptr;

    for (int i = start_idx; i < end_idx; ++i) {
        A[i] = 0.0f;

        const float wind_x = WX[i];
        const float wind_y = WY[i];
        const float wind_len2 = wind_x * wind_x + wind_y * wind_y;
        if (wind_len2 < 1e-6f || advect_steps == 0) {
            continue;
        }

        const float inv_wind_len = 1.0f / std::sqrt(wind_len2);
        const float up_dx = -wind_x * inv_wind_len;
        const float up_dy = -wind_y * inv_wind_len;

        int upstream_idx = i;
        for (int step = 0; step < advect_steps; ++step) {
            int best_idx = -1;
            float best_dot = 0.1f;
            const float swx = POSX[upstream_idx];
            const float swy = POSY[upstream_idx];
            const int ub = upstream_idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[ub + d];
                if (ni < 0) continue;
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

        const float temp_self_raw = TB[i];
        const float temp_self = std::isfinite(temp_self_raw) ? temp_self_raw : BL[i];
        // 轨迹表命中 → 回溯三角形三点插值上游温度（每顶点独立 finite 守门，与
        // 离散分支的单点守门同语义）；未命中 → 离散上游。
        float temp_up;
        if (TRAJ_IDX != nullptr) {
            const int t3 = i * 3;
            const int j0 = TRAJ_IDX[t3], j1 = TRAJ_IDX[t3 + 1], j2 = TRAJ_IDX[t3 + 2];
            const float t0r = TB[j0], t1r = TB[j1], t2r = TB[j2];
            const float t0v = std::isfinite(t0r) ? t0r : BL[j0];
            const float t1v = std::isfinite(t1r) ? t1r : BL[j1];
            const float t2v = std::isfinite(t2r) ? t2r : BL[j2];
            temp_up = TRAJ_W[t3] * t0v + TRAJ_W[t3 + 1] * t1v + TRAJ_W[t3 + 2] * t2v;
        } else {
            const float temp_up_raw = TB[upstream_idx];
            temp_up = std::isfinite(temp_up_raw) ? temp_up_raw : BL[upstream_idx];
        }
        float speed_mix = wind_speed_norm(wind_x, wind_y, WSP[i]) / 1.2f;
        if (speed_mix < 0.25f) speed_mix = 0.25f;
        else if (speed_mix > 1.35f) speed_mix = 1.35f;
        const float temp_mixed_raw = temp_self + (temp_up - temp_self) * heat_mix * speed_mix;
        A[i] = temp_mixed_raw - BL[i];
    }
}

// PK_WS_PROBE_CELL 一次性解析；未设或非法时返回 -1（探针整条不触发）。
static int pk_ws_probe_cell() {
    static const int cached = []() {
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_WS_PROBE_CELL);
        if (v == nullptr || *v == 0) return -1;
        return std::atoi(v);
    }();
    return cached;
}

void wind_surface_pure(const WindSurfaceKnobs &knobs,
                       const WindSurfaceLanes &lanes,
                       int start_idx, int end_idx) {
    const float air_leak            = knobs.air_leak;
    const float wrap_period_x       = knobs.wrap_period_x;
    const float cold_transport_form = knobs.cold_transport_form;
    const float cold_transport_melt = knobs.cold_transport_melt;

    const float   *WX    = lanes.wind_x;
    const float   *WY    = lanes.wind_y;
    const float   *WSP   = lanes.wind_speed;
    const float   *POSX  = lanes.pos_x;
    const float   *POSY  = lanes.pos_y;
    const float   *AIN   = lanes.air_anomaly_in;
    const uint8_t *IW    = lanes.is_water;
    const int32_t *NB    = lanes.neighbor_indices;
    const float   *FBL   = lanes.fallback_baseline;
    const float   *BL_RUNTIME = lanes.baseline;
    const float   *OANOM = lanes.ocean_anomaly;
    const float   *LANOM = lanes.local_anomaly;
    float         *AOUT  = lanes.air_anomaly_out;
    float         *T     = lanes.temp_out;

    for (int i = start_idx; i < end_idx; ++i) {
        const float swx = POSX[i];
        const float swy = POSY[i];
        float weighted_sum = 0.0f;
        float weight_total = 0.0f;
        const int b = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[b + d];
            if (ni < 0) continue;
            const float wind_x = WX[ni];
            const float wind_y = WY[ni];
            if (wind_x * wind_x + wind_y * wind_y < 1e-6f) continue;
            const float dx = pk_wrap_min_image_dx(swx - POSX[ni], wrap_period_x);
            const float dy = swy - POSY[ni];
            const float len2 = dx * dx + dy * dy;
            if (len2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(len2);
            const float weight = (dx * wind_x + dy * wind_y) * inv_len;
            if (weight <= 0.0f) continue;
            float speed_w = wind_speed_norm(wind_x, wind_y, WSP[ni]) / 1.2f;
            if (speed_w < 0.20f) speed_w = 0.20f;
            else if (speed_w > 1.35f) speed_w = 1.35f;
            const float adv_weight = weight * speed_w;
            weighted_sum += AIN[ni] * adv_weight;
            weight_total += adv_weight;
        }

        // 风致 air-mass 平流：把邻接 air-mass anomaly 加权平均到本 cell。
        float anomaly_in = 0.0f;
        if (weight_total > 0.0f) {
            anomaly_in = (weighted_sum / weight_total) * air_leak;
        }
        // air anomaly 是单 round 的瞬时 deviation（不持久），OVERWRITE 而非累加。
        float air_final = anomaly_in;
        if (air_final < -0.08f) air_final = -0.08f;
        else if (air_final > 0.08f) air_final = 0.08f;
        AOUT[i] = air_final;

        // 合成 cell_temp：ocean 与 air 都是横向热输运，共享同一 ±0.08 预算；
        // 对接近结冰线的水格，正向输运先被潜热/成冰门控吸收，避免无冰边缘水面
        // 被固定抬高到 melt 阈值以上而无法重新结冰。
        float base = BL_RUNTIME[i];
        // 极夜/结冰 baseline 恰好等于 0.0 是合法值，只有非有限值才回退静态基线。
        if (!std::isfinite(base)) base = FBL[i];
        float transport_anom = (OANOM != nullptr ? OANOM[i] : 0.0f) + air_final;
        if (IW[i] != 0 && transport_anom > 0.0f) {
            // wf_smoothstep 的原地展开（span 由调用方保证非零）。
            float t = (base - cold_transport_form) /
                      (cold_transport_melt - cold_transport_form);
            if (t < 0.0f) t = 0.0f;
            else if (t > 1.0f) t = 1.0f;
            transport_anom *= t * t * (3.0f - 2.0f * t);
        }
        if (transport_anom < -0.08f) transport_anom = -0.08f;
        else if (transport_anom > 0.08f) transport_anom = 0.08f;
        float total_anom = transport_anom + (LANOM != nullptr ? LANOM[i] : 0.0f);
        if (total_anom < -0.15f) total_anom = -0.15f;
        else if (total_anom > 0.15f) total_anom = 0.15f;
        float total = base + total_anom;
        if (total < 0.0f) total = 0.0f;
        else if (total > 1.0f) total = 1.0f;
        T[i] = total;

        // 对拍定位用：PK_WS_PROBE_CELL=<idx> 时打印这一格的温度分量。生产与 worker
        // 走同一份内核，两边输出并列即可指出是哪条 lane 先偏。默认不设 → 零开销。
        if (i == pk_ws_probe_cell()) {
            std::fprintf(stderr,
                "[ws-probe] cell=%d base=%.9g oanom=%.9g ain=%.9g lanom=%.9g "
                "transport=%.9g total_anom=%.9g T=%.9g wind=(%.6g,%.6g,%.6g)\n",
                i, double(base), double(OANOM != nullptr ? OANOM[i] : 0.0f),
                double(air_final), double(LANOM != nullptr ? LANOM[i] : 0.0f),
                double(transport_anom), double(total_anom), double(total),
                double(WX[i]), double(WY[i]), double(WSP[i]));
        }
    }
}



// wind_air pure kernel — 移植自 DCWorldExt::run_wind_air_mass_pass（world_ext.cpp:4887）。
// 算法逐行 1:1 镜像 sync 主循环（line 4963-5009）：
//   - 每 cell：A[i] = 0
//   - 若 wind_speed^2 < 1e-6 或 advect_steps==0：跳过（A=0）
//   - 否则沿 -wind 方向回溯 advect_steps 步找最对齐邻居（**不限 water**——
//     与 sync 路径一致；与 ocean_water 限 water 不同）
//   - temp_mixed = lerp(temp_self, temp_up, heat_mix * speed_mix)
//     speed_mix = clamp(wf_wind_speed_norm(...) / 1.2, 0.25, 1.35)
//   - A[i] = temp_mixed - baseline
//
// 输入：in.{wind_x, wind_y, wind_speed, pos_x, pos_y, temp（snapshot）,
//           temp_baseline_year（作 baseline_arr）} + scalars
// 输出：out.air_mass_temp_anomaly
bool _async_wind_air_kernel_pure(const ClimateInputBuf &in,
                                        const ClimateRoundStaticKnobs &knobs,
                                        ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.wind_x.size()             != n) return false;
    if ((int)in.wind_y.size()             != n) return false;
    if ((int)in.wind_speed.size()         != n) return false;
    if ((int)in.pos_x.size()              != n) return false;
    if ((int)in.pos_y.size()              != n) return false;
    if ((int)in.temp.size()               != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    if ((int)out.air_mass_temp_anomaly.size() != n) out.air_mass_temp_anomaly.resize(n);

    WindAirKnobs wa_knobs;
    wa_knobs.n_cells = n;
    wa_knobs.advect_steps = in.scalars.wa_advect_steps;
    wa_knobs.heat_mix = in.scalars.wa_heat_mix;
    wa_knobs.wrap_period_x = in.scalars.wrap_period_x;  // seam-advection-fix

    WindAirLanes wa_lanes;
    wa_lanes.wind_x = in.wind_x.data();
    wa_lanes.wind_y = in.wind_y.data();
    wa_lanes.wind_speed = in.wind_speed.data();
    wa_lanes.pos_x = in.pos_x.data();
    wa_lanes.pos_y = in.pos_y.data();
    wa_lanes.temp_before = in.temp.data();
    // 生产的 baseline_arr 优先；没记到时退回年级 LUT（旧行为），但那会偏。
    wa_lanes.baseline = (int)in.wind_baseline.size() == n
        ? in.wind_baseline.data() : in.temp_baseline_year.data();
    wa_lanes.neighbor_indices = knobs.neighbor_indices.data();
    if ((int)in.wind_traj_idx.size() == n * 3 &&
        (int)in.wind_traj_w.size() == n * 3) {
        wa_lanes.traj_idx = in.wind_traj_idx.data();
        wa_lanes.traj_w = in.wind_traj_w.data();
    }
    wa_lanes.air_anomaly = out.air_mass_temp_anomaly.data();

    pk::parallel_for_range("pk_climate_wind_air", n, 0, 2048, [&](int begin, int end) {
        wind_air_pure(wa_knobs, wa_lanes, begin, end);
    });
    return true;
}

// wind_surface pure kernel — 移植自 DCWorldExt::run_wind_surface_pass（world_ext.cpp:5022）。
// 算法逐行 1:1 镜像 sync 主循环（line 5114-5166）：
//   - 每 cell：对 6 邻居计算 weight = dot(self→nb_pos, nb_wind) * speed_mix(nb)
//     speed_mix = clamp(wf_wind_speed_norm(nb_wind, nb_wind_speed) / 1.2, 0.20, 1.35)
//   - anomaly_in = (weighted_sum / weight_total) * air_leak，clamp ±0.08
//   - 写 out.air_mass_temp_anomaly[i] = anomaly_in（OVERWRITE 不累加）
//   - 合成 cell_temp = clamp(baseline + clamp(ocean_anom + air_anom, ±0.08)
//                     + local_anom, 0, 1)，总 anomaly 再 clamp ±0.15
//
// 依赖：必须在 pass_a / pass_b / ocean_water / ocean_land / wind_air 之后跑（依赖
// 它们写的 temp_baseline / ocean_thermal_anomaly / local_thermal_anomaly /
// air_mass_temp_anomaly 当前值）。
//
// 输入：in.{wind_x, wind_y, wind_speed, pos_x, pos_y, temp_baseline_year（备份 baseline）}
// in/out：out.{air_mass_temp_anomaly, temp_baseline, ocean_thermal_anomaly,
//              local_thermal_anomaly}（前序 pass 输出，wind_surface 读取做合成）
// 输出：out.{air_mass_temp_anomaly（覆写）, temp（最终温度）}
bool _async_wind_surface_kernel_pure(const ClimateInputBuf &in,
                                            const ClimateRoundStaticKnobs &knobs,
                                            ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.wind_x.size()             != n) return false;
    if ((int)in.wind_y.size()             != n) return false;
    if ((int)in.wind_speed.size()         != n) return false;
    if ((int)in.pos_x.size()              != n) return false;
    if ((int)in.pos_y.size()              != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    const float air_leak = in.scalars.ws_air_leak;
    const float cold_transport_form = in.scalars.ws_cold_transport_form;
    const float cold_transport_melt = in.scalars.ws_cold_transport_melt;
    const float wrap_period_x = in.scalars.wrap_period_x;  // seam-advection-fix

    // 准备 input snapshot：sync 路径用 anomaly_src.duplicate()（air_anom 旧值）
    // 作为读取来源，AOUT 作为新输出。但 wind_air 已写 out.air_mass_temp_anomaly。
    // 我们这里 AIN 用 in.air_mass_temp_anomaly（或 out.air_mass_temp_anomaly 如果非空），
    // AOUT 直接写 out.air_mass_temp_anomaly。复刻 sync 的 AIN/AOUT 分离。
    // Stage 2 bench 时主线程会传 in.air_mass_temp_anomaly = MapData.air_mass_temp_anomaly_arr。
    // Round 模式下（mask=0x30 + 上一 pass wind_air 跑过），out.air_mass_temp_anomaly 已是
    // wind_air 输出——但 sync 路径的 AIN 也是 wind_air 写完的值（slot 写后再读），所以
    // **正确做法是用 out.air_mass_temp_anomaly 作为 AIN**（如果它是 wind_air 输出的话）。
    // 决策：bench 时 mask=0x20（仅 wind_surface），主线程要把 sync 路径"wind_air 跑完之后"
    // 的 air_anom 传成 in.air_mass_temp_anomaly。该字段同时也是 out 的初值。
    if ((int)out.air_mass_temp_anomaly.size() != n) {
        out.air_mass_temp_anomaly.resize(n);
        if ((int)in.air_mass_temp_anomaly.size() == n) {
            std::memcpy(out.air_mass_temp_anomaly.data(),
                        in.air_mass_temp_anomaly.data(),
                        n * sizeof(float));
        }
    }
    if ((int)out.temp.size() != n) out.temp.resize(n);

    // 准备合成 baseline / oanom / lanom 输入。这些字段如果 out 已写则用 out 值；
    // 否则用 in 值（bench 模式：主线程把 sync 路径"pass_a/b/ocean_* 之后"的快照传过来）。
    auto choose_field = [n](const std::vector<float> &out_v,
                            const std::vector<float> &in_v) -> const float* {
        if ((int)out_v.size() == n) return out_v.data();
        if ((int)in_v.size()  == n) return in_v.data();
        return nullptr;
    };
    const float *BL_RUNTIME = choose_field(out.temp_baseline, in.temp_baseline);
    if (BL_RUNTIME == nullptr) {
        // 兜底：用 in.temp_baseline_year（年级 LUT）作为 fallback baseline
        BL_RUNTIME = in.temp_baseline_year.data();
    }
    const float *OANOM = choose_field(out.ocean_thermal_anomaly, in.ocean_thermal_anomaly);
    const float *LANOM = choose_field(out.local_thermal_anomaly, in.local_thermal_anomaly);
    const float *FBL = in.temp_baseline_year.data();  // fallback_baseline_arr

    // AIN：上一 pass wind_air 输出的 air anomaly。bench mask=0x20 时主线程把它
    // 装到 in.air_mass_temp_anomaly。
    // 注意：sync 路径 AIN 与 AOUT 是同 slot 的 in-place 别名读/写，因为
    // wind_surface 读 ni（邻居）的旧 air_anom 计算 weighted_sum，写 i 自己的
    // 新 air_anom。**邻居 ni 的写时序在 i 之前**（loop 顺序），所以 sync 实际是
    // 类似 Gauss-Seidel：当 i 处理时，nb_idx < i 的邻居用的是它们刚刚的新值，
    // nb_idx > i 用的是旧值。
    // 但 sync 用 anomaly_src.duplicate() → AIN 永远指向"调用前"的旧 air anomaly，
    // 即 wind_air 写完后的整套值，loop 内 ni 邻居读的是 AIN[ni] 旧值；
    // AOUT 写的是新值。这是 Jacobi 风格——pure kernel 必须严格遵守。
    std::vector<float> ain_snapshot;
    ain_snapshot.assign(out.air_mass_temp_anomaly.begin(), out.air_mass_temp_anomaly.end());
    const float *AIN = ain_snapshot.data();
    float *AOUT = out.air_mass_temp_anomaly.data();
    float *T_OUT = out.temp.data();

    const float *WX  = in.wind_x.data();
    const float *WY  = in.wind_y.data();
    const float *WSP = in.wind_speed.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const int32_t *NB = knobs.neighbor_indices.data();

    // is_water 缺失时按"全非水"处理，等价于旧实现里那个 size 守卫：结冰线门控
    // 只对水格生效，没有 is_water 就没有水格。
    static const std::vector<uint8_t> s_no_water;
    const std::vector<uint8_t> &iw_src =
        (int)in.is_water.size() == n ? in.is_water : s_no_water;
    std::vector<uint8_t> iw_zero;
    if ((int)iw_src.size() != n) iw_zero.assign(n, 0u);
    const uint8_t *IW = (int)iw_src.size() == n ? iw_src.data() : iw_zero.data();

    WindSurfaceKnobs ws_knobs;
    ws_knobs.n_cells = n;
    ws_knobs.air_leak = air_leak;
    ws_knobs.wrap_period_x = wrap_period_x;
    ws_knobs.cold_transport_form = cold_transport_form;
    ws_knobs.cold_transport_melt = cold_transport_melt;

    WindSurfaceLanes ws_lanes;
    ws_lanes.wind_x = WX;
    ws_lanes.wind_y = WY;
    ws_lanes.wind_speed = WSP;
    ws_lanes.pos_x = POSX;
    ws_lanes.pos_y = POSY;
    ws_lanes.is_water = IW;
    ws_lanes.baseline = BL_RUNTIME;
    ws_lanes.fallback_baseline = FBL;
    ws_lanes.ocean_anomaly = OANOM;
    ws_lanes.local_anomaly = LANOM;
    ws_lanes.neighbor_indices = NB;
    ws_lanes.air_anomaly_in = AIN;
    ws_lanes.air_anomaly_out = AOUT;
    ws_lanes.temp_out = T_OUT;

    parallel_for_range("pk_climate_wind_surface", n, 0, 2048, [&](int begin, int end) {
        wind_surface_pure(ws_knobs, ws_lanes, begin, end);
    });
    return true;
}

} // namespace pk_async_climate
} // namespace pk

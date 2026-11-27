#pragma once
// ─── pk_async_physics：物理环流求解器的共享纯内核（B8 P2）────────────────────
//
// 目的与 runtime_climate_passes.h 完全同构：把 `world_ext_physical.cpp` /
// `world_ext_weather.cpp` 里"生产在用、worker 也要用"的数值内核抽成不依赖 Godot
// 类型的纯函数（raw pointer + POD knobs），让主线程 MapBaker 路径与 climate worker
// 跑**同一份代码**。任何"顺手优化"（重调迭代数、换收敛判据、改遍历顺序）都会让
// 两侧不再可对拍，所以这里只做等价搬移。
//
// 约定：
//   * 所有 hot loop 只做标量读写，不查 Dictionary、不分配、不调用 Godot；
//   * 标量 knob 由调用方在循环外解析成 POD；
//   * 并行由调用方决定：生产按 `pk::parallel_for_range` 分段调用 range 版本，
//     worker 单线程一次调用（worker 自己就是执行线程，不能再吃线程池）。
//
// 当前覆盖：SLP 场（Pass A 逐 cell 基线 + Pass B/norm 平滑与响应）。
// 第二批：wind field 主循环（含热力季风与 NS Phase 1 动量项）。
// 后续：psi SOR / upwelling / wind traj。

#include "map_overlay_input_signature.h"
#include "runtime_climate_physics_solver.h"

namespace pk {
namespace pk_async_physics {

// ═══════════════════════════════════════════════════════════════════════════
// RuntimeClimatePhysicsState（B8 P2 §4.2）：worker 侧物理环流的常驻状态
// ═══════════════════════════════════════════════════════════════════════════
//
// 设计约束（与计划一致）：
//   * SoA + shape/generation 校验：cell_count 变化即整份失效重建，绝不复用旧图缓冲；
//   * 每日零分配：所有 scratch（SLP Pass B、psi 的 9 条、coast BFS 队列、traj 表）
//     都常驻在这里，kernel 每天只做数值读写；
//   * 派生量（coast 缓存 / 水域 CSR / traj 表）各带指纹 + valid 标记，生产侧同一套
//     指纹语义（map_baker 的 `_phys_ensure_knob_cache` / `_psi_topo_fp` /
//     `_phys_wind_coast_fp` / `_phys_wind_traj_fp`）—— 换图或掩膜变化必然重建。
//
// 归属边界（不在这份 state 里的两样，且**已经**是 worker 自持状态）：
//   * synoptic ψ：本结构的 `synoptic_psi/psi_prev`（原 kernel 成员搬进来）；
//   * cyclone 条目表与 stamp lane：`pk_async_climate::CycloneEntry` 属 climate 库类型，
//     留在 kernel（`_cyclone_entries` 等），避免 physics 库反向依赖 climate 头。
struct RuntimeClimatePhysicsState {
    // ── shape / 世代 ────────────────────────────────────────────────────
    int      cell_count = 0;
    uint64_t generation = 0;   // 每次成功 resize/reset 自增（读视图/存档用）
    bool     ready = false;
    bool     initialized = false;
    int64_t  committed_day = -1;
    uint64_t input_generation = 0;
    int64_t  last_daily_day = -1, last_slp_day = -1, last_wind_day = -1, last_ocean_day = -1;
    std::optional<MapOverlayInputSignature> wind_display_signature;
    void note_wind_solve(int64_t day);
    uint64_t daily_due_seq = 0;
    uint64_t cyclone_total_injected = 0, cyclone_total_replaced = 0, cyclone_total_decayed = 0;

    // ── SLP（cell 索引）─────────────────────────────────────────────────
    std::vector<float> slp;            // 当轮 SLP 场
    std::vector<float> slp_prev;       // 上一轮（响应用；= 对外可见场）
    std::vector<float> slp_thermal;    // Pass A 的 thermal_abs（p95 诊断）
    std::vector<float> slp_scratch;    // Pass B Jacobi / p95 排序缓冲

    // ── 风场（cell 索引）────────────────────────────────────────────────
    std::vector<float> wind_x;         // 方向单位向量（in/out）
    std::vector<float> wind_y;
    std::vector<float> wind_speed;     // 标量风速（in/out）
    std::vector<float> wind_speed_out; // 当日整图输出（= wind_speed，供 raster/weather）
    std::vector<float> wind_delta;     // |Δ(dir,spd)| 诊断
    std::vector<float> wind_dir_delta; // |Δdir| 诊断

    // ── 海岸/海风几何（cell 索引，派生缓存）─────────────────────────────
    std::vector<int8_t>  coast_dist;
    std::vector<float>   coast_sea_x;
    std::vector<float>   coast_sea_y;
    std::vector<int32_t> coast_sea_anchor;
    std::vector<int8_t>  sea_dist;
    std::vector<float>   sea_land_x;
    std::vector<float>   sea_land_y;
    std::vector<int32_t> sea_land_anchor;
    std::vector<int32_t> coast_scratch;      // BFS 队列，2 * cell_count
    std::vector<float>   monsoon_thermal;    // 热力季风派生量（cell 索引）
    uint64_t coast_fingerprint = 0;
    bool     coast_valid = false;

    // ── 洋流 ψ 为 cell 索引；CSR / SOR 工作区为 water 索引 ──────────────
    std::vector<int>     cell_to_water;      // [cell_count]，陆地 = -1
    std::vector<int>     water_to_cell;      // [n_water]
    std::vector<int32_t> nb_w;               // [n_water * 6]
    int      n_water = 0;
    uint64_t topo_fingerprint = 0;
    bool     topo_valid = false;
    std::vector<float> ocean_psi;            // 当轮 ψ（warm start 种子 / 读视图）
    std::vector<float> ocean_psi_prev;       // 上一轮 ψ（存档/对比）
    std::vector<float> ocean_current_x;      // 洋流（cell 索引）
    std::vector<float> ocean_current_y;
    std::vector<float> upwelling;            // 上涌强度（cell 索引）
    std::vector<float> wind_stress_curl;     // 风应力旋度（cell 索引）
    std::vector<float> ocean_thermal_anomaly;// 洋流热输运距平（cell 索引）
    // psi_solve_pure 的 9 条 scratch（water 索引，每日零分配）
    std::vector<float> psi_tau_x, psi_tau_y, psi_ny, psi_ls, psi_curl;
    std::vector<float> psi_beta, psi_r, psi_source, psi_work;
    std::vector<float> psi_preclamp_mag, psi_thermal_mag;  // 诊断用

    // ── 回溯轨迹表（cell*3）─────────────────────────────────────────────
    std::vector<int32_t> wind_traj_idx;
    std::vector<float>   wind_traj_w;
    uint64_t wind_traj_fingerprint = 0;
    uint32_t wind_traj_generation = 0;
    bool     wind_traj_valid = false;

    // ── synoptic ψ（worker 自持；原 kernel 成员）────────────────────────
    std::vector<float> synoptic_psi;
    std::vector<float> synoptic_psi_prev;
    bool     synoptic_seeded = false;
    int32_t  synoptic_tick = 0;

    // ── 温度输运距平 TTA（finalizer 收尾后的值，次日 round 的起点）──────────
    // ocean_water 以前一日 TTA 为基值做 blend/decay，它是真正的跨天状态；climate
    // store 没有这条 lane，parity 回写也不带它，ACTIVE 下只能由 worker 在这里接力。
    // tta_seeded=false（新图 / CHP1 v1 旧档）时 round 退回 capture 值。
    std::vector<float> temp_transport_anomaly;
    bool     tta_seeded = false;

    // 按 cell_count 重建全部 cell 索引缓冲（派生缓存一并失效）。
    void resize(int cells) {
        if (cells < 0) cells = 0;
        cell_count = cells;
        const size_t n = static_cast<size_t>(cells);
        slp.assign(n, 0.0f);
        slp_prev.assign(n, 0.0f);
        slp_thermal.assign(n, 0.0f);
        slp_scratch.assign(n, 0.0f);
        wind_x.assign(n, 1.0f);
        wind_y.assign(n, 0.0f);
        wind_speed.assign(n, 0.0f);
        wind_speed_out.assign(n, 0.0f);
        wind_delta.assign(n, 0.0f);
        wind_dir_delta.assign(n, 0.0f);
        coast_dist.assign(n, COAST_INF);
        coast_sea_x.assign(n, 0.0f);
        coast_sea_y.assign(n, 0.0f);
        coast_sea_anchor.assign(n, -1);
        sea_dist.assign(n, COAST_INF);
        sea_land_x.assign(n, 0.0f);
        sea_land_y.assign(n, 0.0f);
        sea_land_anchor.assign(n, -1);
        coast_scratch.assign(n * 2u, 0);
        monsoon_thermal.assign(n, 0.0f);
        cell_to_water.assign(n, -1);
        ocean_current_x.assign(n, 0.0f);
        ocean_current_y.assign(n, 0.0f);
        upwelling.assign(n, 0.0f);
        wind_stress_curl.assign(n, 0.0f);
        ocean_thermal_anomaly.assign(n, 0.0f);
        wind_traj_idx.assign(n * 3u, 0);
        wind_traj_w.assign(n * 3u, 0.0f);
        synoptic_psi.assign(n, 0.0f);
        synoptic_psi_prev.assign(n, 0.0f);
        synoptic_seeded = false;
        synoptic_tick = 0;
        temp_transport_anomaly.assign(n, 0.0f);
        tta_seeded = false;
        // water 索引缓冲等拓扑重建时再定形（这里只清空）。
        n_water = 0;
        water_to_cell.clear();
        nb_w.clear();
        ocean_psi.assign(n, 0.0f);
        ocean_psi_prev.assign(n, 0.0f);
        initialized = false;
        committed_day = last_daily_day = last_slp_day = last_wind_day = last_ocean_day = -1;
        wind_display_signature.reset();
        input_generation = daily_due_seq = 0;
        cyclone_total_injected = cyclone_total_replaced = cyclone_total_decayed = 0;
        psi_tau_x.clear(); psi_tau_y.clear(); psi_ny.clear(); psi_ls.clear();
        psi_curl.clear(); psi_beta.clear(); psi_r.clear(); psi_source.clear();
        psi_work.clear(); psi_preclamp_mag.clear(); psi_thermal_mag.clear();
        coast_fingerprint = 0;
        coast_valid = false;
        topo_fingerprint = 0;
        topo_valid = false;
        wind_traj_fingerprint = 0;
        wind_traj_generation = 0;
        wind_traj_valid = false;
        ++generation;
        ready = cells > 0;
    }

    // 只按水域格数定形 CSR/工作区，不改变 cell-index ψ 或其 warm-start。
    void resize_water(int n) {
        if (n < 0) n = 0;
        n_water = n;
        const size_t nw = static_cast<size_t>(n);
        water_to_cell.assign(nw, 0);
        nb_w.assign(nw * 6u, -1);
        // ψ 的输入/输出始终按 cell 索引；只有 SOR 工作区按水格索引。
        psi_tau_x.assign(nw, 0.0f);
        psi_tau_y.assign(nw, 0.0f);
        psi_ny.assign(nw, 0.5f);
        psi_ls.assign(nw, 0.0f);
        psi_curl.assign(nw, 0.0f);
        psi_beta.assign(nw, 0.0f);
        psi_r.assign(nw, 0.0f);
        psi_source.assign(nw, 0.0f);
        psi_work.assign(nw, 0.0f);
        psi_preclamp_mag.assign(nw, 0.0f);
        psi_thermal_mag.assign(nw, 0.0f);
    }

    // 形状/有限性校验。失败写 error 并返回 false（caller 不跑物理）。
    bool validate(std::string &error, MapOverlayInputSignature *wind_signature = nullptr) const {
        if (cell_count <= 0 || cell_count > 10000000) { error = "physics_cell_count_invalid"; return false; }
        const size_t n = static_cast<size_t>(cell_count);
        auto ok_n = [n](const std::vector<float> &v) { return v.size() == n; };
        if (!ok_n(slp) || !ok_n(slp_prev) || !ok_n(slp_thermal) ||
            !ok_n(slp_scratch) || !ok_n(wind_x) || !ok_n(wind_y) ||
            !ok_n(wind_speed) || !ok_n(wind_speed_out) || !ok_n(wind_delta) ||
            !ok_n(wind_dir_delta) || !ok_n(monsoon_thermal) ||
            !ok_n(ocean_current_x) || !ok_n(ocean_current_y) ||
            !ok_n(upwelling) || !ok_n(wind_stress_curl) ||
            !ok_n(ocean_thermal_anomaly) || !ok_n(synoptic_psi) ||
            !ok_n(synoptic_psi_prev) || !ok_n(ocean_psi) || !ok_n(ocean_psi_prev) ||
            !ok_n(temp_transport_anomaly)) {
            error = "cell_lane_shape_mismatch";
            return false;
        }
        if (coast_dist.size() != n || coast_sea_x.size() != n ||
            coast_sea_y.size() != n || coast_sea_anchor.size() != n ||
            sea_dist.size() != n || sea_land_x.size() != n ||
            sea_land_y.size() != n || sea_land_anchor.size() != n ||
            coast_scratch.size() != n * 2u || cell_to_water.size() != n ||
            wind_traj_idx.size() != n * 3u || wind_traj_w.size() != n * 3u) {
            error = "cell_cache_shape_mismatch";
            return false;
        }
        const size_t nw = static_cast<size_t>(n_water);
        if (n_water < 0 || n_water > cell_count || water_to_cell.size() != nw ||
            nb_w.size() != nw * 6u || psi_preclamp_mag.size() != nw ||
            psi_thermal_mag.size() != nw || psi_tau_x.size() != nw ||
            psi_tau_y.size() != nw || psi_ny.size() != nw ||
            psi_ls.size() != nw || psi_curl.size() != nw ||
            psi_beta.size() != nw || psi_r.size() != nw ||
            psi_source.size() != nw || psi_work.size() != nw) {
            error = "water_lane_shape_mismatch";
            return false;
        }
        return validate_values(error, wind_signature);
    }
    bool validate_values(std::string &error, MapOverlayInputSignature *wind_signature) const;

    // 轻量状态哈希（FNV-1a，按位：float 用 bit pattern）。用于读视图游标
    // （get_climate_physics_read_view 的 generation 比对）与存档段校验；
    // 不做数值容差 —— 它只回答"是不是同一份状态"。
    uint64_t state_hash() const {
        uint64_t h = 1469598103934665603ull;
        auto mix = [&h](uint64_t v) {
            h ^= v;
            h *= 1099511628211ull;
        };
        mix(static_cast<uint64_t>(cell_count));
        mix(generation); mix(input_generation); mix(static_cast<uint64_t>(committed_day));
        mix(initialized); mix(ready); mix(daily_due_seq);
        mix(static_cast<uint64_t>(last_daily_day)); mix(static_cast<uint64_t>(last_slp_day));
        mix(static_cast<uint64_t>(last_wind_day)); mix(static_cast<uint64_t>(last_ocean_day));
        mix(synoptic_seeded); mix(static_cast<uint32_t>(synoptic_tick));
        mix(wind_traj_generation);
        mix(cyclone_total_injected); mix(cyclone_total_replaced); mix(cyclone_total_decayed);
        auto mix_vec = [&mix](const std::vector<float> &v) {
            for (float f : v) {
                uint32_t bits = 0;
                std::memcpy(&bits, &f, sizeof(bits));
                mix(static_cast<uint64_t>(bits));
            }
        };
        mix_vec(slp); mix_vec(wind_x); mix_vec(wind_y); mix_vec(wind_speed);
        mix_vec(ocean_current_x); mix_vec(ocean_current_y);
        mix_vec(upwelling); mix_vec(ocean_psi);
        mix_vec(synoptic_psi); mix_vec(synoptic_psi_prev); mix_vec(slp_prev);
        mix_vec(ocean_psi_prev); mix_vec(wind_stress_curl);
        mix_vec(ocean_thermal_anomaly); mix_vec(monsoon_thermal);
        // 未播种时不参与，保持与 CHP1 v1 存档里记录的哈希一致。
        if (tta_seeded) { mix(1u); mix_vec(temp_transport_anomaly); }
        return h;
    }
};

// 自检：resize 后形状校验通过、清空后失败、water 缓冲按 n_water 定形、
// generation 递增、hash 随数据变化且对同一份数据稳定。
bool physics_state_self_test(std::string &error);

// 空 blob 是 legacy 冷启动；非空错误返回 false，且不修改目标状态。
bool serialize_physics_state(RuntimeClimatePhysicsState &state,
                             std::vector<uint8_t> &blob, std::string &error);
// Copy the saved fields of an already validated commit for native readers.
// Solver scratch and derived caches remain private to the solver.
void copy_committed_physics_fields(const RuntimeClimatePhysicsState &source,
                                  RuntimeClimatePhysicsState &out);
bool restore_physics_state(const uint8_t *data, size_t size,
                           RuntimeClimatePhysicsState &state, std::string &error);

// 两趟 sweep 必须隔开，生产可分段并行、worker 整段串行。
void wind_divergence_range(int n, int begin, int end, const int32_t *nb,
                          const float *wx, const float *wy, const float *speed, float *div);
void wind_divergence_apply_range(int n, int begin, int end, const int32_t *nb,
                                const float *div, double alpha,
                                float *wx, float *wy, float *speed);

// 纬度 LUT、synoptic 波与移动低压的同源预处理。
void prepare_slp_forcing(SlpPassAKnobs &k, int bins, float season,
                        float tilt, float daylen, int day, double period,
                        int mobile_count, float mobile_amp, float mobile_sigma,
                        double mobile_period, std::vector<float> &base,
                        std::vector<float> &heat, const float *annual_mean = nullptr);

// 自检：合成小网格上验证 Pass A 的有限性/水陆差异、Pass B 的 Jacobi 平均、
// recenter（均值≈0）与 response_rate=0 的"保持 prev"语义。失败写 error。
bool self_test(std::string &error);

} // namespace pk_async_physics
} // namespace pk

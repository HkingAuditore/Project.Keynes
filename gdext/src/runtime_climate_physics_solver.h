#pragma once

// Inputs and pure kernel boundaries for circulation and wind solvers.

#include "simulation_math.h"
#include <cstdint>
#include <cmath>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

namespace pk {
namespace pk_async_physics {

// ─── 共享常量（唯一来源）────────────────────────────────────────────────────
//
// 这些常量原先散在 world_ext_physical.cpp 的匿名 namespace 里。内核与生产必须
// 用同一份，故集中在这里；world_ext_physical.cpp 通过 using 声明继续用原名。
// 取值来自 physical_circulation_solver.gd（line 233-244）与 wind_belt.gd。

// 海岸/海洋 BFS 距离上界（coast_dist/sea_dist == COAST_INF 表示超出搜索半径）。
inline constexpr int8_t COAST_INF = 127;

// 6 邻居方向在屏幕坐标系下的世界向量（pointy-top），顺序 E/NE/NW/W/SW/SE。
inline constexpr double ND_SQRT3_HALF = 0.8660254037844387; // √3 / 2
inline constexpr double NB_DIR_X[6] = {
    ND_SQRT3_HALF * 2.0, ND_SQRT3_HALF, -ND_SQRT3_HALF,
    -ND_SQRT3_HALF * 2.0, -ND_SQRT3_HALF, ND_SQRT3_HALF,
};
inline constexpr double NB_DIR_Y[6] = {
    0.0, -1.5, -1.5, 0.0, 1.5, 1.5,
};

inline constexpr double WIND_W_LAT = 0.45;
inline constexpr double WIND_W_GRAD = 1.05;
inline constexpr double WIND_W_COAST_THERMAL = 0.58;
inline constexpr int    WIND_COAST_THERMAL_MAX_DIST = 5;
inline constexpr double WIND_CORIOLIS_MAX_RAD = 1.20;
inline constexpr double WIND_PRESSURE_GRAD_WEAK = 0.006;
inline constexpr double WIND_PRESSURE_GRAD_STRONG = 0.055;
inline constexpr double WIND_PRESSURE_BASE_W = 0.55;
inline constexpr double WIND_PRESSURE_GRAD_W = 2.55;
inline constexpr double WIND_LAT_GRAD_SUPPRESS = 0.75;
inline constexpr double WIND_TERRAIN_MOUNTAIN_DAMP = 0.55;
inline constexpr double WIND_TERRAIN_HILL_DAMP = 0.85;
inline constexpr double WIND_LAND_FRICTION = 0.85;
inline constexpr double WIND_MOUNTAIN_DEFLECT_W = 0.85;
inline constexpr double WIND_MOUNTAIN_UPSTREAM_DAMP = 0.55;
inline constexpr double WIND_SEA_BREEZE_W = 1.0;
inline constexpr int    SEA_BREEZE_SEA_MAX_DIST = 5;

inline double pk_wind_clamp(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

inline double pk_wind_smoothstep(double a, double b, double x) {
    const double span = b - a;
    if (std::abs(span) < 1e-12) return (x >= a) ? 1.0 : 0.0;
    double t = (x - a) / span;
    if (t < 0.0) t = 0.0;
    else if (t > 1.0) t = 1.0;
    return t * t * (3.0 - 2.0 * t);
}

inline double pk_wind_orbital_progress(double orbital_phase) {
    double p = std::fmod(orbital_phase, 4.0);
    if (p < 0.0) p += 4.0;
    return p * 0.25;
}

inline double pk_wind_subsolar_signed(double orbital_phase, double axial_tilt_deg) {
    constexpr double PI_HALF = 1.57079632679489661923;
    constexpr double TAU = 6.28318530717958647692;
    const double decl_rad = axial_tilt_deg * (3.14159265358979323846 / 180.0) *
        simulation_math::cos(TAU * pk_wind_orbital_progress(orbital_phase));
    return pk_wind_clamp(decl_rad / PI_HALF, -1.0, 1.0);
}

inline double pk_wind_shifted_lat_signed(double ny, double orbital_phase,
                                         double axial_tilt_deg) {
    const double lat_signed = (ny - 0.5) * 2.0;
    const double itcz_shift = pk_wind_clamp(
        pk_wind_subsolar_signed(orbital_phase, axial_tilt_deg) * 0.45, -0.18, 0.18);
    return pk_wind_clamp(lat_signed - itcz_shift, -1.0, 1.0);
}

// 三圈环流速度包络（ITCZ/信风/西风/极地四带的 smoothstep 加权）。
inline double pk_wind_belt_speed_at(double ny, double orbital_phase,
                                    double axial_tilt_deg) {
    constexpr double ITCZ_HALF_WIDTH = 0.05;
    constexpr double TRADE_TOP = 0.40;
    constexpr double WEST_TOP = 0.70;
    constexpr double SPEED_ITCZ = 0.15;
    constexpr double SPEED_TRADE = 0.85;
    constexpr double SPEED_WEST = 1.10;
    constexpr double SPEED_POLAR = 0.65;
    const double lat_signed =
        pk_wind_shifted_lat_signed(ny, orbital_phase, axial_tilt_deg);
    const double abs_lat = (lat_signed < 0.0) ? -lat_signed : lat_signed;
    const double w_itcz = 1.0 - pk_wind_smoothstep(
        ITCZ_HALF_WIDTH - 0.03, ITCZ_HALF_WIDTH + 0.03, abs_lat);
    const double w_trade = pk_wind_smoothstep(
        ITCZ_HALF_WIDTH - 0.03, ITCZ_HALF_WIDTH + 0.03, abs_lat) *
        (1.0 - pk_wind_smoothstep(TRADE_TOP - 0.04, TRADE_TOP + 0.04, abs_lat));
    const double w_west = pk_wind_smoothstep(
        TRADE_TOP - 0.04, TRADE_TOP + 0.04, abs_lat) *
        (1.0 - pk_wind_smoothstep(WEST_TOP - 0.04, WEST_TOP + 0.04, abs_lat));
    const double w_polar =
        pk_wind_smoothstep(WEST_TOP - 0.04, WEST_TOP + 0.04, abs_lat);
    return w_itcz * SPEED_ITCZ + w_trade * SPEED_TRADE +
        w_west * SPEED_WEST + w_polar * SPEED_POLAR;
}

inline double pk_wind_belt_speed_at(double ny, double orbital_phase) {
    return pk_wind_belt_speed_at(ny, orbital_phase, 23.5);
}

// ─── SLP Pass A：逐 cell 基线场 ──────────────────────────────────────────────
//
// 逐 cell 独立（读邻居/纬度/可选场，写本 cell），所以按 cell 区间并行是 bit-equal。
// 对应 world_ext_physical.cpp::run_slp_field_pass 的 Pass A 段。
struct SlpPassAKnobs {
    // 基线振幅（ClimateProfile / 默认值与 GDScript 常量一致）
    float lat_amp = 0.16f;
    float land_amp = 0.55f;
    float water_damp = 0.20f;
    float interior_boost = 1.30f;
    float coast_damp = 0.60f;
    // 热力/冰雪/水汽项权重（0 = 关闭，缺 lane 时自动等价关闭）
    float thermal_weight = 0.0f;
    float ice_high_weight = 0.0f;
    float snow_high_weight = 0.0f;
    float moist_low_weight = 0.12f;
    // synoptic 空间波
    float synoptic_amp = 0.075f;
    float syn_sa = 0.0f;
    float syn_sb = 0.0f;
    float syn_phase = 0.0f;
    float syn_phase2 = 0.0f;
    float syn_k1x = 3.0f;
    float syn_k1y = 1.3f;
    float syn_k2x = 3.0f;
    float syn_k2y = 1.45f;
    // 经向归一化（POSX 缺失时的退路；wrap 域优先）
    float bounds_pos_x = 0.0f;
    float inv_bounds_w = 1.0f;
    bool  has_wrap_domain = false;
    double wrap_origin_x = 0.0;
    double wrap_period_x = 0.0;
    int   world_seed = 0;
    // 移动低压（0 = 关闭）：cx/cy 已由调用方按 sim_day 演进完毕
    int   n_mobile_low = 0;
    float mobile_low_amp = 0.0f;
    float mobile_low_inv2s2 = 0.0f;
    float mobile_low_cx[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    float mobile_low_cy[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    // 纬度 LUT（[lut_bins] 线性插值；调用方预建）
    int   lut_bins = 1024;
    const float *lut_base = nullptr;
    const float *lut_heat = nullptr;
};

struct SlpPassALanes {
    // 纬度权威：lat_norm（0..1，赤道 0.5）优先；缺失时用 pos_y 自归一化
    const float   *lat_norm = nullptr;
    const float   *pos_y = nullptr;
    double         lat_origin = 0.0;
    double         lat_inv_span = 1.0;
    const uint8_t *terrain = nullptr;
    const int32_t *neighbors = nullptr;   // [n_cells * 6]
    const float   *pos_x = nullptr;       // 可空
    const float   *temp_anomaly = nullptr;
    const float   *ice = nullptr;
    const float   *snow = nullptr;
    const float   *vapor = nullptr;
    const float   *cloud = nullptr;
    const bool    *is_water_lut = nullptr; // [256]
};

// 只处理 [begin, end)。写 slp_buf[i]；thermal_abs 可空。
// 返回处理的 cell 数（= end - begin，供 work_units 记账）。
int slp_pass_a_range(int n_cells, int begin, int end,
                     const SlpPassAKnobs &knobs, const SlpPassALanes &lanes,
                     float *slp_buf, float *thermal_abs);

// ─── SLP Pass B + norm：平滑 / recenter+p95 / 响应混合 ───────────────────────
//
// 需要完整场（整轮求解的末切片才执行）。`scratch` 只在 smooth_passes > 0 时使用，
// 长度必须 >= n_cells（worker 侧用常驻缓冲，避免每天分配）。
struct SlpPassBKnobs {
    int   smooth_passes = 3;
    bool  recenter = true;
    float target_p95 = 0.18f;
    // <0 = 不做 prev 混合（等价"无 prev_slp_arr"）；否则
    // next = prev + (cur - prev) * response_rate
    float response_rate = -1.0f;
};

// 原地改 slp_buf；delta 可空（|slp - prev|，无 prev 时 = |slp|）。
void slp_pass_b_pure(int n_cells, const SlpPassBKnobs &knobs,
                     const int32_t *neighbors, const float *prev_slp,
                     float *slp_buf, float *scratch, float *delta);

// ─── Wind field 主循环 ───────────────────────────────────────────────────────
//
// 对应 world_ext_physical.cpp::run_wind_field_pass 的 pk_wind_field 主循环：
//   纬度基线 → SLP 梯度/科氏偏转 → 沿海权重 → 海风/热力季风 → synoptic 波 →
//   地形绕流/减速 → 响应混合（+ NS Phase 1 动量自平流/扩散）→ 转向限幅 → 写回。
// 逐 cell 独立（邻居只读 SLP/LF/TR 与动量快照），所以按区间分段 bit-equal。
// 统计量（flip / 季风计数）按区间返回，由调用方合并 —— 整数加法的合并顺序无关。
struct WindFieldKnobs {
    double season_phase = 0.0;
    double axial_tilt_deg = 23.5;
    bool   terrain_aware = true;
    bool   wind_belt_only = false;
    double response_rate = 0.25;
    double synoptic_amp = 0.055;
    double synoptic_period_days = 6.0;
    double max_turn_rad = 0.0;
    double min_flux_len2 = 0.0;
    int    sim_day = 0;
    int    world_seed = 0;
    double bounds_pos_x = 0.0;
    double inv_bounds_w = 1.0;
    bool   has_wrap_domain = false;
    double wrap_origin_x = 0.0;
    double wrap_period_x = 0.0;
    int    lf_mountain = -1;
    int    lf_peak = -1;
    int    lf_hill = -1;
    // 热力季风（thermal_monsoon_enabled=false 时全部走零成本分支）
    bool   thermal_monsoon_enabled = false;
    double monsoon_lat_limit = 0.45;
    double monsoon_deadband = 0.015;
    double monsoon_full_contrast = 0.08;
    double monsoon_gain = 0.85;
    double monsoon_breeze_floor = 0.20;
    // NS Phase 1：动量自平流/扩散（关闭时逐位等于旧行为）
    bool   momentum_active = false;
    double momentum_advect_w = 0.0;
    double diffuse_w = 0.0;
    const int32_t *traj_idx = nullptr;   // [n_cells*3]，可空
    const float   *traj_w = nullptr;     // [n_cells*3]，可空
    const float   *snap_fx = nullptr;    // 旧通量快照，momentum_active 时必填
    const float   *snap_fy = nullptr;
};

struct WindFieldLanes {
    const float   *lat_norm = nullptr;
    const float   *pos_y = nullptr;
    double         lat_origin = 0.0;
    double         lat_inv_span = 1.0;
    const float   *pos_x = nullptr;
    const float   *slp = nullptr;
    const int32_t *neighbors = nullptr;      // [n_cells * 6]
    const uint8_t *terrain = nullptr;
    const uint8_t *landform = nullptr;
    const bool    *is_water_lut = nullptr;   // [256]
    const int8_t  *coast_dist = nullptr;
    const float   *coast_sea_x = nullptr;
    const float   *coast_sea_y = nullptr;
    const int32_t *coast_sea_anchor = nullptr;
    const int8_t  *sea_dist = nullptr;
    const float   *sea_land_x = nullptr;
    const float   *sea_land_y = nullptr;
    const int32_t *sea_land_anchor = nullptr;
    const float   *temp = nullptr;           // 热力季风需要
    // 读写：风向量/风速 slot（in = 上一轮，out = 本轮）
    float *wind_x = nullptr;
    float *wind_y = nullptr;
    float *wind_speed = nullptr;
    // 只写：整图风速输出 + 两个 delta 诊断 + 季风/动量诊断（后三个可空）
    float *wind_speed_out = nullptr;
    float *wind_delta = nullptr;
    float *wind_dir_delta = nullptr;
    float *momentum_delta = nullptr;
    float *monsoon_thermal = nullptr;
};

struct WindFieldStats {
    int   flip = 0;
    int   monsoon_eligible = 0;
    int   monsoon_onshore = 0;
    int   monsoon_offshore = 0;
    float monsoon_abs_max = 0.0f;
};

// 只处理 [begin, end)。返回处理的 cell 数。
int wind_field_range(int n_cells, int begin, int end,
                     const WindFieldKnobs &knobs, const WindFieldLanes &lanes,
                     WindFieldStats &stats);

// 自检：合成网格上验证方向单位化/速度范围、风带-only 退化、季风关闭时
// monsoon_thermal 归零、以及 response_rate=1 时"直接采用目标风"的语义。
bool wind_self_test(std::string &error);

// ─── PSI 拓扑（水域 CSR）────────────────────────────────────────────────────
//
// 纯由水掩膜（terrain + water LUT）与邻接决定，与风/温无关。生产用 FNV 指纹
// 缓存它；worker 侧在 shape/generation 变化时重建。返回水域格数。
int psi_topology_build_pure(int n_cells, const uint8_t *terrain,
                            const int32_t *neighbors,
                            const bool *is_water_lut,
                            int *cell_to_water,   // [n_cells]，陆地 = -1
                            int *water_to_cell,   // [n_cells]，前 n_water 有效
                            int32_t *nb_w);       // [n_cells * 6]，-1 = 陆地/越界

// ─── PSI 求解（SOR + 洋流 finalize）─────────────────────────────────────────
//
// 对应 world_ext_physical.cpp::run_psi_solver_pass 的三段：tau/curl/源项 →
// SOR Gauss-Seidel（含 warm-start 与提前退出）→ grad ψ → 洋流 + 密度/地形/高纬
// 项 + 响应混合 + 限幅。1:1 搬移，参数默认值与原实现一致。
struct PsiSolveKnobs {
    int   total_iters = 40;
    float omega = 1.40f;              // PSI_OMEGA
    float r_base = 0.18f;             // PSI_R_BASE
    float beta_floor = 0.05f;         // PSI_BETA_FLOOR
    float source_scale = 0.06f;       // PSI_SOURCE_SCALE
    float oc_scale = 0.13f;           // OCEAN_CURRENT_SCALE
    float oc_max_mag = 0.65f;         // OCEAN_CURRENT_MAX_MAGNITUDE（已 clamp）
    float thermohaline_weight = 0.12f;
    float upwelling_highlat_abs = 0.75f;
    float cold_sink_temp = -0.05f;
    float response_rate = 1.0f;       // OCEAN_CURRENT_RESPONSE_RATE（0..1）
    float thermal_current_weight = 0.12f;
    float density_cold_weight = 0.22f;
    float density_ice_weight = 0.12f;
    // NS Phase 4（默认 0 = 旧行为逐位不变）
    float depth_curl_damp = 0.0f;
    float sea_level = 0.42f;
    float depth_ref = 0.12f;
    float topo_steer_w = 0.0f;
    // 提前退出（mode=balanced/perf 由调用方换算成这三个数）
    bool  early_exit = false;
    int   min_iters = 40;
    int   check_every = 2;
    float residual_epsilon = 0.0f;
};

struct PsiSolveLanes {
    int n_cells = 0;
    int n_water = 0;
    const int32_t *neighbors = nullptr;
    const uint8_t *terrain = nullptr;
    const bool    *is_water_lut = nullptr;
    const int     *cell_to_water = nullptr;   // [n_cells]
    const int     *water_to_cell = nullptr;   // [n_water]
    const int32_t *nb_w = nullptr;            // [n_water * 6]
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const float   *lat_norm = nullptr;
    const float   *pos_y = nullptr;
    double         lat_origin = 0.0;
    double         lat_inv_span = 1.0;
    const float   *temp = nullptr;            // 可空（缺省 0.5）
    const float   *temp_anomaly = nullptr;
    const float   *ice = nullptr;
    const float   *elevation = nullptr;
    const float   *prev_psi = nullptr;        // warm-start 种子（cell 索引）
    const float   *old_ocean_x = nullptr;     // 响应混合基准
    const float   *old_ocean_y = nullptr;
    // 输出（cell 索引；curl/psi/ocean 必填，delta 可空）
    float *out_curl = nullptr;
    float *out_psi = nullptr;
    float *out_ocean_x = nullptr;
    float *out_ocean_y = nullptr;
    float *ocean_delta = nullptr;
    // 诊断用逐水格量（可空；生产用它们算 p95）：
    float *out_preclamp_mag = nullptr;   // [n_water] 限幅前洋流模长
    float *out_thermal_mag = nullptr;    // [n_water] 热力分量模长
};

// 调用方持有的 n_water 长 scratch（生产用局部 vector，worker 用常驻缓冲）。
struct PsiSolveScratch {
    float *tau_x = nullptr;
    float *tau_y = nullptr;
    float *ny_w = nullptr;
    float *ls_w = nullptr;
    float *curl = nullptr;
    float *beta_abs = nullptr;
    float *r_factor = nullptr;
    float *source = nullptr;
    float *psi = nullptr;
};

struct PsiSolveStats {
    int   iters_run = 0;
    float residual_final = 0.0f;
    bool  early_exit = false;
    int   clamp_count = 0;
    float preclamp_max = 0.0f;
    float thermal_current_max = 0.0f;
};

bool psi_solve_pure(const PsiSolveKnobs &knobs, const PsiSolveLanes &lanes,
                    const PsiSolveScratch &scratch, PsiSolveStats &stats);

// 自检：面积水域上的 CSR 拓扑正确性（cell↔water 互逆、nb_w 只连水格）+
// 纯风应力旋度驱动的 SOR 收敛（残差随迭代下降）+ finalize 限幅生效。
bool psi_self_test(std::string &error);

// ─── Upwelling（离岸 Ekman + 高纬冷沉）──────────────────────────────────────
//
// 对应 world_ext_physical.cpp::run_physical_circulation_pass(stage=upwelling) 的
// 主循环。逐 cell 独立（只读纬度/风/地形/邻接，写 upwelling[i]）→ 分段 bit-equal。
struct UpwellingKnobs {
    float ekman_gain = 0.6f;
    float cold_sink_gain = 0.15f;
    float highlat_abs = 0.75f;
    float cold_sink_temp = -0.05f;
};

struct UpwellingLanes {
    const float   *lat_norm = nullptr;
    const float   *pos_y = nullptr;
    double         lat_origin = 0.0;
    double         lat_inv_span = 1.0;
    const uint8_t *terrain = nullptr;
    const int32_t *neighbors = nullptr;
    const bool    *is_water_lut = nullptr;
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    float         *upwelling = nullptr;   // [n_cells] 输出
};

int upwelling_range(int n_cells, int begin, int end,
                    const UpwellingKnobs &knobs, const UpwellingLanes &lanes);

// ─── Wind 回溯轨迹表（半拉格朗日，动量自平流的读表）────────────────────────
//
// 对应 world_ext_physical.cpp::_phys_build_wind_traj：对每格沿 -风通量方向回溯
// step_len（受 max_dist 上限与 12 跳限制），用六分扇形 barycentric 求终点权重。
// 写 traj_idx/traj_w（各 n_cells*3）。逐 cell 独立 → 分段 bit-equal。
struct WindTrajKnobs {
    double wrap_period_x = 0.0;
    double traj_pos_scale = 0.65;
    double traj_dt_days = 10.0;
};

struct WindTrajLanes {
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const int32_t *neighbors = nullptr;
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    int32_t       *traj_idx = nullptr;   // [n_cells * 3]
    float         *traj_w = nullptr;     // [n_cells * 3]
};

int wind_traj_build_range(int n_cells, int begin, int end,
                          const WindTrajKnobs &knobs, const WindTrajLanes &lanes);

// 自检：upwelling 的"无邻陆 → 0"与高纬冷沉符号；wind traj 的权重和为 1、
// 静止风退化为 own-cell、wrap 域不产生越界索引。
bool ocean_self_test(std::string &error);

// ─── Coast/Sea BFS 缓存（风场海风项与季风的几何前置）────────────────────────
//
// 对应 world_ext_physical.cpp::_phys_ensure_wind_coast 的两次 BFS：
//   Pass 0 ：陆地 → 到最近海岸的格数（≤ coast_max_dist）+ 朝海单位向量 + 锚格；
//   Pass 0b：水面 → 到最近岸线的格数（≤ sea_max_dist）+ 朝陆单位向量 + 锚格。
// 纯由水掩膜 + 邻接决定（静态地图恒等）。生产保留 FNV 指纹缓存与计时外壳；
// worker 在 shape/generation 变化时重建。scratch_queue 长度须 ≥ n_cells*2。
struct WindCoastKnobs {
    int coast_max_dist = 5;   // WIND_COAST_THERMAL_MAX_DIST
    int sea_max_dist = 5;     // SEA_BREEZE_SEA_MAX_DIST
};

struct WindCoastLanes {
    const uint8_t *terrain = nullptr;
    const int32_t *neighbors = nullptr;
    const bool    *is_water_lut = nullptr;
    int8_t  *coast_dist = nullptr;          // [n_cells]
    float   *coast_sea_x = nullptr;         // [n_cells]
    float   *coast_sea_y = nullptr;
    int32_t *coast_sea_anchor = nullptr;
    int8_t  *sea_dist = nullptr;
    float   *sea_land_x = nullptr;
    float   *sea_land_y = nullptr;
    int32_t *sea_land_anchor = nullptr;
    int32_t *scratch_queue = nullptr;       // [n_cells * 2]
};

void wind_coast_build_pure(int n_cells, const WindCoastKnobs &knobs,
                           const WindCoastLanes &lanes);

// 自检：海岸 BFS 的格数/方向/锚格一致性与越界防护（land→水 距离 0，
// 传播出的方向单位化，远处 land 保持 COAST_INF）。
bool coast_self_test(std::string &error);

} // namespace pk_async_physics
} // namespace pk

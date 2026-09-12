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

#include <cstdint>
#include <cmath>
#include <cstring>
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
        std::cos(TAU * pk_wind_orbital_progress(orbital_phase));
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

    // ── 洋流 ψ / CSR / 工作区（water 索引）──────────────────────────────
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
        // water 索引缓冲等拓扑重建时再定形（这里只清空）。
        n_water = 0;
        water_to_cell.clear();
        nb_w.clear();
        ocean_psi.clear();
        ocean_psi_prev.clear();
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

    // 按水域格数定形 ψ/CSR/工作区缓冲。
    void resize_water(int n) {
        if (n < 0) n = 0;
        n_water = n;
        const size_t nw = static_cast<size_t>(n);
        water_to_cell.assign(nw, 0);
        nb_w.assign(nw * 6u, -1);
        ocean_psi.assign(nw, 0.0f);
        ocean_psi_prev.assign(nw, 0.0f);
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
    bool validate(std::string &error) const {
        if (cell_count <= 0) { error = "cell_count<=0"; return false; }
        const size_t n = static_cast<size_t>(cell_count);
        auto ok_n = [n](const std::vector<float> &v) { return v.size() == n; };
        if (!ok_n(slp) || !ok_n(slp_prev) || !ok_n(slp_thermal) ||
            !ok_n(slp_scratch) || !ok_n(wind_x) || !ok_n(wind_y) ||
            !ok_n(wind_speed) || !ok_n(wind_speed_out) || !ok_n(wind_delta) ||
            !ok_n(wind_dir_delta) || !ok_n(monsoon_thermal) ||
            !ok_n(ocean_current_x) || !ok_n(ocean_current_y) ||
            !ok_n(upwelling) || !ok_n(wind_stress_curl) ||
            !ok_n(ocean_thermal_anomaly) || !ok_n(synoptic_psi) ||
            !ok_n(synoptic_psi_prev)) {
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
        if (n_water < 0 || water_to_cell.size() != nw ||
            nb_w.size() != nw * 6u || ocean_psi.size() != nw ||
            ocean_psi_prev.size() != nw || psi_tau_x.size() != nw ||
            psi_tau_y.size() != nw || psi_ny.size() != nw ||
            psi_ls.size() != nw || psi_curl.size() != nw ||
            psi_beta.size() != nw || psi_r.size() != nw ||
            psi_source.size() != nw || psi_work.size() != nw) {
            error = "water_lane_shape_mismatch";
            return false;
        }
        return true;
    }

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
        mix(static_cast<uint64_t>(n_water));
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
        mix_vec(synoptic_psi);
        return h;
    }
};

// 自检：resize 后形状校验通过、清空后失败、water 缓冲按 n_water 定形、
// generation 递增、hash 随数据变化且对同一份数据稳定。
bool physics_state_self_test(std::string &error);

// 自检：合成小网格上验证 Pass A 的有限性/水陆差异、Pass B 的 Jacobi 平均、
// recenter（均值≈0）与 response_rate=0 的"保持 prev"语义。失败写 error。
bool self_test(std::string &error);

} // namespace pk_async_physics
} // namespace pk

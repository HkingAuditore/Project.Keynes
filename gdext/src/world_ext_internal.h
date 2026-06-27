#pragma once

// ─────────────────────────────────────────────────────────────────────────
// world_ext_internal.h — DCWorldExt 拆分后的共享内部头。
// 内容：① 持久状态结构体（WeatherSummaryState/AtlasPipelineState/...）；
//       ② BIND_TABLE 别名；③ 跨翻译单元复用的 file-local 无状态 helper
//       （dc_/pk_ 气候、wf_ 天气场、wind_belt_at、worldgen 几何）。
// 这些 helper 原为 world_ext.cpp 内的 static/匿名命名空间符号；移到本头后
// 仍保持 internal linkage（每个 TU 各一份），零行为变化。仅供 world_ext*.cpp
// 包含，不对外暴露。
// ─────────────────────────────────────────────────────────────────────────

#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include "world_ext.h"
#include "component_bind_table.gen.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace pk {

using namespace godot;


// ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）持久化状态 ────────
// 提到 pk 命名空间顶部（而非匿名 namespace）的原因：DCWorldExt 析构函数会
// `delete static_cast<WeatherSummaryState*>(_summary_state)`，要求该类型在析构
// 函数定义点已可见。helpers (get_or_create_summary_state) 仍放在 anonymous
// namespace 中（仅本翻译单元用），定义点位于 advect pass 实装末尾。
struct PrevSummarySeed {
    int     type   = 0;
    float   center_x = 0.0f;
    float   center_y = 0.0f;
    int     age    = 0;
    int     area   = 1;
    float   velocity_x = 0.0f;
    float   velocity_y = 0.0f;
};

struct WeatherSummaryState {
    std::vector<PrevSummarySeed> prev_seeds;
    // 长度 = n_cells（首次 reset / pass 入口 resize）；[i] = cluster idx 或 -1。
    std::vector<int32_t>         prev_membership;
};

// ─── plan/atlas-pipeline-cpp（2026-05-20）：4 张运行期视觉 atlas 全管线下沉 ──
// dynamic_visual_atlas_upload_system 每帧热路径整套搬到 C++：dirty 消费 →
// value-diff（4 个 prev_sigs snapshot）→ 1-跳膨胀 → CSR 打包 → 4 张 atlas
// encode → 4-phase 调度节流，统一收敛到 DCWorldExt::run_atlas_pipeline_step。
//
// 与 WeatherSummaryState 同模式：定义在 pk 命名空间顶部，析构函数走
// `delete static_cast<AtlasPipelineState*>(_atlas_state)`；helpers 仍放在
// 匿名 namespace 中（get_or_create_atlas_state / destroy_atlas_state）。
//
// 字段语义：
//   - phase / cursor: 4-phase 调度状态机游标（IDLE→DYNAMIC→ECOLOGY→SMOOTH→ICE→DONE）
//   - prev_sigs_*: 4 张 atlas 上一帧 per-cell 签名 snapshot（长度 = n_cells），
//     value-diff 用；对 dirty_indices 兜底过滤真·变化的 cell。
//   - eco_foliage / eco_stress / eco_transition_age / eco_growth_damage：
//     ecology 持久状态（从 map_baker.gd 迁移）。decay set 用 indices 数组而
//     非 Dictionary，避免 hash 开销；衰减扫描时只遍历 active 子集。
//   - csr_first_px / csr_px_count / csr_flat_px: world.cells_to_pixel_lists
//     的 CSR 形态缓存，地图稳定时跨 stride 复用；invalidate_atlas_csr_cache
//     使其失效。
//   - stride_*_real: 本 stride value-diff + 膨胀后的真·工作集（4 个 atlas 各一份）。
//   - ms_*_prep / step / fin: 12 个 phase 细分时间切片（μs/ms），返回给 GD 端
//     诊断窗口；保留 dynamic_visual_atlas_upload_system 现有 dashboard 兼容格式。
//   - buf_*: 4 张 atlas 输出 PackedByteArray，每 phase finalize 时填充并随
//     run_atlas_pipeline_step 返回 Dict 暴露给 GD，由 GD 调 ImageTexture.update。
struct AtlasPipelineState {
    enum Phase : int {
        IDLE    = 0,
        DYNAMIC = 1,
        ECOLOGY = 2,
        SMOOTH  = 3,
        ICE     = 4,
        DONE    = 5,
    };

    Phase phase  = IDLE;
    int   cursor = 0;

    // 4 atlas value-diff snapshot（按 cell.index 顺序，长度 = n_cells；初次为空）。
    PackedInt32Array prev_sigs_dyn;
    PackedInt32Array prev_sigs_eco;
    PackedInt32Array prev_sigs_smo;
    PackedInt32Array prev_sigs_ice;

    // ecology 持久状态（从 map_baker.gd _eco_* 字段迁过来）。
    PackedFloat32Array eco_foliage;
    PackedFloat32Array eco_stress;
    PackedFloat32Array eco_transition_age;
    PackedFloat32Array eco_growth_damage;
    PackedInt32Array   eco_active_decay_indices;  // 替代 GDScript Dictionary set

    // ── Cell-index 间接寻址 LUT 路径专用持久 prev 状态（encode_cell_luts 自维护）──
    // 与上面 4-phase fan-out pipeline 的 eco 状态相互独立：两条路径读同一 SoA，
    // 各自维护 transition_age，结果 bit-equivalent。lut_initialized=false 时首帧
    // （冷启 / invalidate_atlas_csr_cache 之后）强制 transition_age=0、prev_vit=cur。
    bool             lut_initialized = false;
    PackedByteArray  lut_prev_veg;          // per-cell 上一帧 vegetation enum byte
    PackedByteArray  lut_prev_vit;          // per-cell 上一帧 q01(vitality) byte
    PackedByteArray  lut_transition_age;    // per-cell transition_age（0..255）

    // CSR 缓存：地图稳定时常驻，invalidate_atlas_csr_cache 失效。
    PackedInt32Array csr_first_px;
    PackedInt32Array csr_px_count;
    PackedInt32Array csr_flat_px;
    bool             csr_valid = false;

    // 本 stride 工作集（每 tick 入口在 consume_dirty_with_diff_cpp 中重建）。
    PackedInt32Array stride_dirty_indices;  // 原始 dirty（read_and_clear_dirty_mask 拉取）
    PackedInt32Array stride_dyn_real;       // 真·变化（per-atlas value-diff 过滤后）
    PackedInt32Array stride_eco_real;
    PackedInt32Array stride_smo_real;       // ∪ 1 跳邻居
    PackedInt32Array stride_ice_real;       // ∩ water_cells

    // 12 个 phase 细分时间切片（毫秒）。
    double ms_dyn_prep = 0.0, ms_dyn_step = 0.0, ms_dyn_fin = 0.0;
    double ms_eco_prep = 0.0, ms_eco_step = 0.0, ms_eco_fin = 0.0;
    double ms_smo_prep = 0.0, ms_smo_step = 0.0, ms_smo_fin = 0.0;
    double ms_ice_prep = 0.0, ms_ice_step = 0.0, ms_ice_fin = 0.0;

    // 4 张 atlas 输出 buffer（每 phase finalize 时填充）。
    PackedByteArray buf_dyn;
    PackedByteArray buf_eco;
    PackedByteArray buf_smo;
    PackedByteArray buf_ice;

    // 累计 stride 计数（采样诊断节流用：每 30 stride 打一次）。
    int stride_counter = 0;

    // ── plan/atlas-phase-slicing（2026-05-21）：phase-by-phase 时间切片 ──
    // 当 opts["phase_budget"] < 4 时，run_atlas_pipeline_step 会在跑完
    // budget 个 phase 后提前 return，把 phase 状态留在 IDLE..ICE 之间，下一
    // 次 call 接着跑。整段 stride 期间持有的"入口快照"（dirty_indices /
    // cache_valid_* / 4 个 prep 产物）必须跨 call 持久化，避免每 phase 重做。
    //
    // 入口判断：phase==IDLE 或 phase==DONE 时执行 stride 入口 setup（
    // 消费 dirty_indices、SoA 拉取、buf 校验、cache_valid 计算、prep_*）；
    // 中间态（DYNAMIC..ICE）直接复用本结构里的 cached 值。
    //
    // 注意：所有 PackedXxxArray CoW 引用计数共享，跨 call 不产生拷贝；
    // 真正的 SoA 指针（TEMP/MOIST/...）每 call 通过 fetch_world_soa 重拿
    // ——这本身只是几次 Object::get（< 5μs），不计入"传输开销"。
    bool             stride_active = false;     // true: 入口快照有效（IDLE→DONE 期间）
    bool             stride_dirty_path_used = false;
    bool             stride_dirty_noop = false;
    bool             stride_have_nb = false;
    bool             stride_cache_valid_dyn = false;
    bool             stride_cache_valid_eco = false;
    bool             stride_cache_valid_smo = false;
    bool             stride_cache_valid_ice = false;
    int              stride_n_pix = 0;
    int              stride_n_cells = 0;
    int              stride_terrain_lake = -1;
    int              stride_terrain_sea_ice = -1;
    int              stride_veg_none = -1;
    PackedInt32Array stride_nb_arr;             // neighbor_indices_packed snapshot

    // 4 个 phase 的 prep 产物（每 phase 入口写一次，phase 内 step 消费）。
    PackedInt32Array prep_dyn_real_indices;
    PackedInt32Array prep_dyn_real_sigs;
    PackedInt32Array prep_eco_real_indices;
    PackedInt32Array prep_smo_real_indices;
    PackedInt32Array prep_ice_real_indices;
    bool             prep_eco_skip = false;
    bool             prep_smo_skip = false;
    bool             prep_ice_skip = false;
    bool             prep_smo_ready = false;
    int              prep_smo_cursor = 0;

    // 整段 stride 起始时间戳（用于 total_ms 跨 call 累加）。
    std::chrono::high_resolution_clock::time_point stride_t_start;
    double stride_total_ms_accum = 0.0;
};

// ─── Phase B+ (2026-05-21)：season refresh round 切片调度 opaque state ────
// SAME_SOURCE: map_generator.gd::run_season_refresh_stage 12-stage round。
// B+ 调度要点：
//   1. start_season_round 一次性接收完整 round_knobs（12 stage 所需字段超集），
//      存到 input_knobs；同时把所有 PackedArray 引用持有，避免 GDScript 释放。
//   2. run_season_round_slice 内部按 "round_stage 0..11" 推进，每 stage 把
//      input_knobs 浅拷贝出来 + 改写 stage 字段后 →
//      DCWorldExt::run_season_refresh_stage(stage_knobs)。零算法复制。
//   3. b1 粒度（用户 2026-05-21 决策）：每 stage 是最小切片单位；stage 边界
//      永远查 deadline，不在 stage 内 cursor 切片。
//   4. round_stage → C++ stage_id 映射（与 GDScript 12-stage 顺序一致）：
//        0 moisture     → cpp_stage 0   (run_season_refresh_stage)
//        1 rain_shadow  → cpp_stage 1
//        2 redecide     → cpp_stage 2
//        3 river        → cpp_stage 3
//        4 veg_fb       → cpp_stage 4
//        5 shrubland    → cpp_stage 5
//        6 mangrove     → cpp_stage 6
//        7 glacier      → cpp_stage 7
//        8 swamp        → cpp_stage 9   (历史命名冲突，避开 stage 8=sync)
//        9 sync_state   → cpp_stage 8
//       10 atlas_queue  → SKIP（render concern；GDScript 端在 finish 阶段
//                         调 _mark_enum_atlas_dirty）
//       11 feedback_decay→ cpp_stage 10
//   5. generation 计数器：每次 start/abort 自增；run_slice/finish 校验入参
//      handle == generation，不匹配返回 fallback。reload world / 异常退出
//      场景下，旧 handle 自然失效，避免 stale state。
//   6. soil_moisture_arr / veg_growth_pressure_arr 是 in/out PackedFloat32Array
//      （由 stage 11=feedback_decay 写回 decayed 值），finish_season_round
//      把它们放进返回 dict 让 GDScript 灌回 map.xxx_arr。
struct SeasonRoundState {
    int      generation       = 0;       // 起始时 +=1；caller 持的 handle 必须等于本值
    bool     active           = false;
    int      round_stage      = 0;       // 0..11，当前要跑的 round_stage
    int      stages_done      = 0;       // 已完成的 stage 数（含 SKIP）
    int      slices_used      = 0;       // 跑过的 slice 数
    double   total_native_ms  = 0.0;     // 累计 C++ 算法纯耗时（不含 dispatch）
    Dictionary input_knobs;              // round 起始一次性塞齐的所有字段（Variant 持引用）
    // stage 11 (feedback_decay) 的 in/out PackedArray 引用——单独缓存指针的快照，
    // C++ stage 10 内会 ptrw 写回；finish 时把这两个 array 放回 ret dict。
    PackedFloat32Array soil_moisture_arr;
    PackedFloat32Array veg_growth_pressure_arr;
};
// ─── BIND_TABLE — autogenerated single source（原 world_ext.cpp 匿名 ns）─────
// 提到共享头：bind_map_data / _flush_slot_to_map（CORE）与 _debug_poke_f32_with_flush
// （DEMO）分处不同 TU，需都能见到该别名。匿名 ns -> 每 TU 各一份 internal linkage。
namespace {
[[maybe_unused]] constexpr auto &BIND_TABLE      = BIND_TABLE_AUTOGEN;
[[maybe_unused]] constexpr int   BIND_TABLE_SIZE = BIND_TABLE_AUTOGEN_SIZE;
} // namespace


static inline float dc_clamp01f(float v) {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

static inline float dc_clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline float dc_stabilize_tta(float prev, float source,
                                     float source_cap, float blend_rate) {
    const float cap = std::fabs(source_cap);
    const float capped_source = dc_clampf(source, -cap, cap);
    const float blend = dc_clampf(blend_rate, 0.0f, 1.0f);
    return prev + (capped_source - prev) * blend;
}

static inline float dc_decay_tta(float prev, float decay_rate) {
    return prev * (1.0f - dc_clampf(decay_rate, 0.0f, 1.0f));
}

static inline float dc_phase_progress(float season_phase) {
    float p = std::fmod(season_phase, 4.0f);
    if (p < 0.0f) p += 4.0f;
    return p * 0.25f;
}

static inline float dc_subsolar_lat_rad(float season_phase, float axial_tilt_deg) {
    constexpr float TAU_F = 6.2831853071795864769f;
    return axial_tilt_deg * float(M_PI / 180.0) *
           std::cos(TAU_F * dc_phase_progress(season_phase));
}

static inline float dc_sunset_hour_angle(float lat_rad, float decl_rad) {
    if (std::fabs(decl_rad) <= 1e-6f) return float(M_PI) * 0.5f;
    const float polar_test = -std::tan(lat_rad) * std::tan(decl_rad);
    if (polar_test <= -1.0f) return float(M_PI);
    if (polar_test >= 1.0f) return 0.0f;
    return std::acos(polar_test);
}

static inline float dc_day_length_norm(float ny, float season_phase, float axial_tilt_deg) {
    const float lat_rad = (ny - 0.5f) * float(M_PI);
    const float decl_rad = dc_subsolar_lat_rad(season_phase, axial_tilt_deg);
    return dc_clamp01f(dc_sunset_hour_angle(lat_rad, decl_rad) / float(M_PI));
}

static inline float dc_insolation_now(float ny, float season_phase, float axial_tilt_deg, float daylen_amp) {
    (void)daylen_amp;
    const float lat_rad = (ny - 0.5f) * float(M_PI);
    const float subsolar = dc_subsolar_lat_rad(season_phase, axial_tilt_deg);
    const float h0 = dc_sunset_hour_angle(lat_rad, subsolar);
    if (h0 <= 1e-6f) return 0.0f;
    const float daily =
        h0 * std::sin(lat_rad) * std::sin(subsolar) +
        std::cos(lat_rad) * std::cos(subsolar) * std::sin(h0);
    return dc_clamp01f(daily);
}

static inline float dc_insolation_annual_mean(float ny, float axial_tilt_deg, float daylen_amp) {
    constexpr int SAMPLES = 16;
    float acc = 0.0f;
    for (int s = 0; s < SAMPLES; ++s) {
        acc += dc_insolation_now(ny, (float(s) + 0.5f) * (4.0f / float(SAMPLES)), axial_tilt_deg, daylen_amp);
    }
    return acc / float(SAMPLES);
}

// SAME_SOURCE（C++ 镜像）: DCClimateMath.compute_insolation_dev_from_values。
// 2026-06-16 物理化：删除"极地放大/衰减"band-aid，dev 还原为纯物理偏差
//   dev = insol_now - insol_mean。极地夏季过热改由 pk_surface_absorbed_factor
//   （吸收短波 / 冰反照率反馈）在 season_offset 处处理，更物理。
// ny 保留入参以稳定签名与调用点，但不再参与计算。
static inline float dc_insolation_season_dev(float ny, float insol_now, float insol_mean) {
    (void)ny;
    return insol_now - insol_mean;
}

// ─── 表面吸收短波因子（海陆/极地物理化 2026-06-16，年均代理版）──────────────
// SAME_SOURCE（C++ 镜像）: DCClimateMath.surface_absorbed_factor / ALBEDO_*。
// absorb = 1 - 反照率；冰雪高反照率反射极昼强日射 → 极地夏季自然变冷，并形成
// "冷→结冰→反照率升高→更冷"的自洽冰反照率正反馈。海洋反照率低于陆地→吸收更多
// （季节强迫更大），但其高热容（低 thermal_inertia_water）阻尼实际摆幅→大陆性对比。
// 归一化基准 = 无冰陆地 (1-PK_ALBEDO_LAND)，使无冰陆地 factor=1.0（中纬零重调）。
// 仅缩放 season_offset，不动 cos^1.6 年均基线 → 反馈有下界、不失控。
static constexpr float PK_ALBEDO_OCEAN = 0.08f;   // 开阔水面
static constexpr float PK_ALBEDO_LAND  = 0.20f;   // 一般陆地（归一化基准面）
static constexpr float PK_ALBEDO_ICE   = 0.62f;   // 冰雪覆盖
static constexpr float PK_T_ICE_LO     = 0.12f;   // ≤ 此温度视为完全冰封
static constexpr float PK_T_ICE_HI     = 0.30f;   // ≥ 此温度视为无冰
// temp_annual 必须传【年均温度 temp_365d】（慢 EMA），不能传瞬时温度——否则
// "暖→脱冰→吸收增→更暖"会形成夏季融化正反馈使极地夏季失控变热（实测 0.43）。
// 用年均温度作"持久冰封气候"代理：深极地年均≈0.05 常年冰封 → 因子≈0.475 →
// 极地夏季自然压低且稳定（夏峰 0.30→0.22）；中纬年均高 → 因子=1.0 → 季节性不变。
static inline float pk_surface_absorbed_factor(bool is_water, float temp_annual) {
    const float a_base = is_water ? PK_ALBEDO_OCEAN : PK_ALBEDO_LAND;
    // ice_w：年均温度落入冻结带时升到 1（端点反序 smoothstep(HI,LO,t) → 冷=1, 暖=0）。
    float t = (temp_annual - PK_T_ICE_HI) / (PK_T_ICE_LO - PK_T_ICE_HI);
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    const float ice_w = t * t * (3.0f - 2.0f * t);
    const float a_eff = a_base + (PK_ALBEDO_ICE - a_base) * ice_w;
    return (1.0f - a_eff) / (1.0f - PK_ALBEDO_LAND);
}

// ─── 季节项冷侧软压缩（冬季过冷托底 物理化 v2 2026-06-16）──────────────────
// SAME_SOURCE（C++ 镜像）: DCClimateMath.compress_season_cooling / WINTER_COOL_KNEE。
// 物理依据：极向热量输送 + 海洋/地表热库在冬季半球托底，使中/高纬冬季远比纯局地
// 辐射平衡暖。暖侧(s≥0)原样返回（保留夏季/极昼季节性与吸收因子效果）；冷侧(s<0)
// 按 tanh 软饱和到约 −KNEE：小幅降温几乎不变，深冬大幅降温不再无限过冷。
// KNEE=0.13：温带平原冬季 min 0.087→0.21（叠加 pass_b≈0.13 严寒、脱离极寒），
// 夏峰不变，深极地仍冻结（海冰核/冰带不塌）。
static constexpr float PK_WINTER_COOL_KNEE = 0.13f;

static inline float pk_compress_season_cooling(float season_offset) {
    if (season_offset >= 0.0f) return season_offset;
    return -PK_WINTER_COOL_KNEE * std::tanh(-season_offset / PK_WINTER_COOL_KNEE);
}

// 热惯性松弛系数的多日积分：单日 α 表示"每日向 radiative target 逼近 α 比例"。
// 经过 dt 天（加速/跳日）后等效一次性系数 α_eff = 1 - (1-α)^dt（target 视作窗口内
// 近似恒定）。dt<=1 时退化为原 α，保持非加速档 bit-equal。SAME_SOURCE：
// map_generator.gd 同名内联与 climate_daily_system 共享同一公式。
static inline float pk_thermal_alpha_eff(float alpha, float dt_days) {
    if (alpha < 0.0f) alpha = 0.0f;
    else if (alpha > 1.0f) alpha = 1.0f;
    if (dt_days <= 1.0f) return alpha;
    return 1.0f - std::pow(1.0f - alpha, dt_days);
}

// ─── 季节项组合（legacy parity）──────────────────────────────────────────
// 2026-06-27 regression: native/SoA once multiplied land season forcing by
// land_continentality, while the original AoS fallback did not. At subpolar
// summer/daylight extremes that extra factor pushed season_offset to ~0.45 and
// made runtime baselines far warmer than pre-migration behavior. Keep the
// parameter in the signature for cp_struct/resource compatibility, but do not
// let pass-A amplify land temperatures outside the legacy formula.
static inline float pk_season_offset_continental(float insol_amp_gain, bool is_water,
                                                 float temp_annual, float dev_today,
                                                 float land_continentality) {
    (void)land_continentality;
    return pk_compress_season_cooling(insol_amp_gain * pk_surface_absorbed_factor(is_water, temp_annual) * dev_today);
}

// ════════════════════════════════════════════════════════════════════════════
// Phase F / dots-full-migration §F.1-F.6 hot pass C++ implementations
// ════════════════════════════════════════════════════════════════════════════
//
// F.1 已落地 (this PR)。F.2-F.6 仍为 stub（返回 -1.0 → GDScript fallback）。
// 后续 PR 按 charter §12.4 七步 SOP 逐个填充实际算法。

// ─── F.1 helpers ─────────────────────────────────────────────────────────────
namespace {

// Mirror weather_system.gd::_is_water_terrain — bit-equal terrain enum check.
// Source: weather_system.gd:2125-2131 (TerrainType.TERRAIN values are stable
// 0-based ordinals from terrain_type.gd; see component_schema.gd terrain SoA).
inline bool wf_is_water_terrain(uint8_t t) {
    // OCEAN=0, COAST=1, REEF=19, KELP=21, SEA_ICE=20, LAKE=18 (from
    // scripts/geography/terrain_type.gd::TERRAIN enum order).
    return t == 0  || t == 1  || t == 18 || t == 19 || t == 20 || t == 21;
}

// Mirror weather_system.gd::_vegetation_transpiration_factor — bit-equal.
// Source: weather_system.gd:1384-1394. Veg ordinals from vegetation_type.gd
// VEG enum (line 33+).
inline float wf_vegetation_transp_factor(uint8_t veg) {
    // NONE=0
    if (veg == 0) return 0.0f;
    // TROPICAL_RAINFOREST=14, SWAMP=20, MANGROVE=19
    if (veg == 14 || veg == 19 || veg == 20) return 1.0f;
    // TEMPERATE_DECIDUOUS=7, TAIGA=5, SUBTROPICAL_FOREST=12
    if (veg == 5 || veg == 7 || veg == 12) return 0.65f;
    // TEMPERATE_GRASSLAND=9, SAVANNA=13, MARSH=21
    if (veg == 9 || veg == 13 || veg == 21) return 0.35f;
    return 0.18f;
}

inline void wf_wrapped_delta(float ax, float ay, float bx, float by,
                             float wrap_width_x, float &dx, float &dy) {
    dx = bx - ax;
    dy = by - ay;
    if (wrap_width_x > 0.001f) {
        const float half = wrap_width_x * 0.5f;
        if (dx > half) {
            dx -= wrap_width_x;
        } else if (dx < -half) {
            dx += wrap_width_x;
        }
    }
}

// Mirror weather_system.gd::_neighbor_aligned_idx (line 1261).
// Returns -1 if no neighbour clears the cone threshold.
//   - cone_thresh = cell_pos_scale * 0.31176915 (sqrt(3)*0.18)
//   - Note: GDScript reads `dir.length_squared() <= 0.0001` then normalises;
//     here we trust caller has non-degenerate `dir` (handled at call site).
inline int wf_neighbor_aligned_idx(int idx, float dir_x, float dir_y,
                                   const godot::Vector2 *POS,
                                   const int32_t *NB,
                                   int n_cells, float cell_pos_scale,
                                   float wrap_width_x) {
    if (idx < 0 || idx >= n_cells) return -1;
    const float dl2 = dir_x * dir_x + dir_y * dir_y;
    if (dl2 <= 0.0001f) return -1;
    const float inv_dl = 1.0f / Math::sqrt(dl2);
    const float ndx = dir_x * inv_dl;
    const float ndy = dir_y * inv_dl;
    const float self_x = POS[idx].x;
    const float self_y = POS[idx].y;
    int   best_idx = -1;
    const float pos_scale = (cell_pos_scale > 0.001f) ? cell_pos_scale : 1.0f;
    float best_dot = pos_scale * 0.31176915f;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float to_nb_x = 0.0f;
        float to_nb_y = 0.0f;
        wf_wrapped_delta(self_x, self_y, POS[nb_idx].x, POS[nb_idx].y,
                         wrap_width_x, to_nb_x, to_nb_y);
        const float dot = to_nb_x * ndx + to_nb_y * ndy;
        if (dot > best_dot) {
            best_dot = dot;
            best_idx = nb_idx;
        }
    }
    return best_idx;
}

// Mirror weather_system.gd::_upstream_vapor_idx_from_first (line 1297).
// Walks the upstream chain (`field_advect_steps` total) and returns the
// decay-weighted average vapor.
inline float wf_upstream_vapor_idx_from_first(int idx, int first_upstream_idx,
                                              const godot::Vector2 *POS,
                                              const int32_t *NB,
                                              const float *PV,
                                              float wind_dx, float wind_dy,
                                              int n_cells, float cell_pos_scale,
                                              float wrap_width_x,
                                              int field_advect_steps) {
    if (first_upstream_idx < 0 || field_advect_steps <= 0) {
        return PV[idx];
    }
    int   current_idx = first_upstream_idx;
    float sum_v   = PV[current_idx];
    float weight  = 1.0f;
    float w_decay = 0.75f;
    for (int step = 1; step < field_advect_steps; ++step) {
        const int upstream_idx = wf_neighbor_aligned_idx(
            current_idx, -wind_dx, -wind_dy, POS, NB, n_cells,
            cell_pos_scale, wrap_width_x);
        if (upstream_idx < 0) break;
        sum_v   += PV[upstream_idx] * w_decay;
        weight  += w_decay;
        w_decay *= 0.75f;
        current_idx = upstream_idx;
    }
    return sum_v / weight;
}

// Mirror weather_system.gd::_neighbor_average_vapor_idx (line 1314).
inline float wf_neighbor_average_vapor_idx(int idx, const int32_t *NB,
                                           const float *PV) {
    float sum_v = PV[idx];
    int   n     = 1;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        sum_v += PV[nb_idx];
        n += 1;
    }
    return sum_v / float(n);
}

// Mirror weather_system.gd::_avg_ocean_anomaly_at_idx (line 1326).
// `TA` is per-cell `cell.temperature_transport_anomaly` extracted by GDScript.
inline float wf_avg_ocean_anomaly_at_idx(int idx, const uint8_t *TERR,
                                         const int32_t *NB, const float *TA) {
    if (wf_is_water_terrain(TERR[idx])) return TA[idx];
    float sum_an  = 0.0f;
    int   n_water = 0;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        if (wf_is_water_terrain(TERR[nb_idx])) {
            sum_an += TA[nb_idx];
            n_water += 1;
        }
    }
    if (n_water == 0) return 0.0f;
    return sum_an / float(n_water);
}

// Mirror weather_system.gd::_evaporation_for_cell_idx (line 1345).
inline float wf_evaporation_for_cell_idx(int idx, const uint8_t *TERR,
                                         const uint8_t *VEG,
                                         const uint8_t *HAS_RIV,
                                         const int32_t *NB,
                                         float temp, float moisture,
                                         float ocean_an, bool on_water,
                                         float field_ocean_evap_gain,
                                         float field_lake_evap_scale) {
    float evap = on_water ? 0.028f : 0.006f;
    if (TERR[idx] == 18) {
        evap *= field_lake_evap_scale;
    }
    const float excess_moist = moisture - 0.45f;
    if (excess_moist > 0.0f) evap += excess_moist * 0.018f;
    evap += wf_vegetation_transp_factor(VEG[idx]) * 0.012f;
    if (!on_water) {
        if (HAS_RIV[idx] != 0) evap += 0.012f;
        const int base = idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            if (wf_is_water_terrain(TERR[nb_idx])) {
                evap += 0.018f;
                break;
            }
        }
    }
    float ocean_mul = 1.0f + field_ocean_evap_gain * ocean_an;
    if (ocean_mul < 0.20f) ocean_mul = 0.20f;
    else if (ocean_mul > 1.80f) ocean_mul = 1.80f;
    float temp_mul = 0.35f + temp * 1.05f;
    if (temp_mul < 0.12f) temp_mul = 0.12f;
    else if (temp_mul > 1.35f) temp_mul = 1.35f;
    return evap * ocean_mul * temp_mul;
}

// Mirror weather_system.gd::_orographic_lift_from_upstream_idx (line 1420).
inline float wf_orographic_lift_from_upstream_idx(int idx, int upstream_idx,
                                                  const float *ELEV) {
    if (upstream_idx < 0) return 0.0f;
    const float diff = ELEV[idx] - ELEV[upstream_idx];
    if (diff > 0.02f) {
        float v = diff * 2.2f;
        if (v > 1.0f) v = 1.0f;
        return v;
    }
    if (diff < -0.02f) {
        float v = diff * 1.6f;
        if (v < -1.0f) v = -1.0f;
        return v;
    }
    return 0.0f;
}

inline float wf_wind_speed_norm(float dir_x, float dir_y, float speed) {
    if (speed > 0.0001f) return speed;
    const float len2 = dir_x * dir_x + dir_y * dir_y;
    return (len2 > 0.0001f) ? Math::sqrt(len2) : 0.0f;
}

// Mirror weather_system.gd::_wind_convergence_idx (line 1452).
inline float wf_wind_convergence_idx(int idx, const godot::Vector2 *POS,
                                     const int32_t *NB,
                                     const float *WX, const float *WY,
                                     const float *WSPD = nullptr,
                                     float wrap_width_x = 0.0f) {
    const float self_x = POS[idx].x;
    const float self_y = POS[idx].y;
    float incoming = 0.0f;
    int   checked  = 0;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float dx = 0.0f;
        float dy = 0.0f;
        wf_wrapped_delta(POS[nb_idx].x, POS[nb_idx].y, self_x, self_y,
                         wrap_width_x, dx, dy);
        const float dl2 = dx * dx + dy * dy;
        if (dl2 <= 0.0001f) continue;
        const float wx = WX[nb_idx];
        const float wy = WY[nb_idx];
        const float wl2 = wx * wx + wy * wy;
        if (wl2 <= 0.0001f) continue;
        const float inv_d = 1.0f / Math::sqrt(dl2);
        const float inv_w = 1.0f / Math::sqrt(wl2);
        float cos_in = (dx * wx + dy * wy) * (inv_d * inv_w);
        if (cos_in < 0.0f) cos_in = 0.0f;
        const float wsp = (WSPD != nullptr) ? wf_wind_speed_norm(wx, wy, WSPD[nb_idx]) : Math::sqrt(wl2);
        float speed_w = wsp / 1.2f;
        if (speed_w < 0.20f) speed_w = 0.20f;
        else if (speed_w > 1.25f) speed_w = 1.25f;
        incoming += cos_in * speed_w;
        checked  += 1;
    }
    if (checked == 0) return 0.0f;
    float v = incoming / float(checked);
    if (v < 0.0f) v = 0.0f;
    else if (v > 1.0f) v = 1.0f;
    return v;
}

// Mirror weather_system.gd::_classify_field_weather_at (line 1497).
// WeatherType.WT enum values: CLEAR=0 RAIN=1 STORM=2 BLIZZARD=3 DROUGHT=4
//                              FOG=5 HEATWAVE=6 MONSOON=7
inline float wf_smoothstep(float edge0, float edge1, float x) {
    float t = (x - edge0) / (edge1 - edge0);
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return t * t * (3.0f - 2.0f * t);
}

// Deterministic per-(cell,tick) hash → [0,1). Integer ops chosen to mirror GDScript exactly
// (32-bit wrap). Used to seed the synoptic eddy field ψ (Stage7). Same formula in field_solver.gd.
inline float wf_hash01(int cell, int tick) {
    uint32_t h = (uint32_t)cell * 374761393u + (uint32_t)tick * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    h ^= (h >> 16);
    return (float)(h & 0x00FFFFFFu) / (float)0x01000000u;
}

inline float wf_precip_terrain_damping_factor(uint8_t terrain) {
    // TerrainType.TERRAIN enum: HILL=5, SWAMP=10, JUNGLE=11, LAKE=18, DELTA=22.
    // Stage8: 原设定压低雨林/地形坡/湿地降水(方向反了，致"雨团绕湖/山/盆地走")。JUNGLE/HILL→0(应多雨)，湿地轻阻尼。镜像 weather_system.gd。
    switch (terrain) {
        case 18: return 0.50f; // LAKE
        case 22: return 0.40f; // DELTA
        case 10: return 0.30f; // SWAMP
        case 11: return 0.0f;  // JUNGLE
        case 5:  return 0.0f;  // HILL
        default: return 0.0f;
    }
}

inline float wf_apply_precip_stability(uint8_t terrain, float precip,
                                       float wet_damp, float lake_damp,
                                       float soft_cap, float softness) {
    float out = precip;
    if (out < 0.0f) out = 0.0f;
    else if (out > 1.0f) out = 1.0f;
    const float factor = wf_precip_terrain_damping_factor(terrain);
    if (factor > 0.0f && out > 0.08f) {
        float damp = (terrain == 18) ? lake_damp : wet_damp;
        if (damp < 0.0f) damp = 0.0f;
        else if (damp > 1.0f) damp = 1.0f;
        out -= (out - 0.08f) * damp * factor;
    }
    if (soft_cap < 0.0f) soft_cap = 0.0f;
    else if (soft_cap > 1.0f) soft_cap = 1.0f;
    if (softness < 0.0f) softness = 0.0f;
    else if (softness > 1.0f) softness = 1.0f;
    if (soft_cap > 0.0f && out > soft_cap) {
        out = soft_cap + (out - soft_cap) * softness;
    }
    if (out < 0.0f) out = 0.0f;
    else if (out > 1.0f) out = 1.0f;
    return out;
}

inline uint8_t wf_classify_field_weather_at(float temp, float vapor, float cloud,
                                            float cloud_water, float precip,
                                            float instability, float ocean_an,
                                            float wind_speed, float temp_anom,
                                            float monsoon_flux,
                                            bool cold_precip_as_blizzard,
                                            float snow_classification_margin,
                                            bool is_water,
                                            float snow_cover) {
    // 涌现式半真实大气分类（2026-06-20 去季节化重写，镜像 weather_system.gd::_classify_field_weather_core）。
    // 天气类型完全由瞬时物理场涌现(温度/湿度/云/降水/不稳定度/风/洋流异常)，不再读 season_idx 或纬度
    // ——"季节"作为温度场随轴倾/公转的结果自然进入。阈值由 tile_data_record_20260620_004323 实测标定，与 GDScript 严格一致。

    const bool warm  = temp > 0.55f;
    // Stage3(2026-06-23): 删除 hot(temp>0.64)——热浪重定义为温度距平事件，不再用绝对高温门。
    // advective 模型下陆地 vapor/cloud 量级仅海洋的 1/5~1/30(海洋是水汽源,陆地远离源天然干)。湿润类
    // 阈值海陆独立标定:海洋保原值(海洋天气分布已合理);陆地按实测分位下调(陆 vapor p50=.034/p90=.086,
    // cloud p50=.021/p90=.078),否则陆地 STORM/MONSOON/FOG 被"打死"全归 CLEAR/DROUGHT(用户:内陆永旱)。
    const float humid_gate     = is_water ? 0.28f  : 0.09f;
    const float mp_cloud_gate  = is_water ? 0.22f  : 0.12f;
    const float mp_vapor_gate  = is_water ? 0.28f  : 0.09f;
    const float monsoon_vapor  = is_water ? 0.40f  : 0.14f;
    const float monsoon_precip = is_water ? 0.055f : 0.065f;
    const float monsoon_cloud  = is_water ? 0.45f  : 0.24f;
    const float fog_vapor      = is_water ? 0.34f  : 0.16f;
    const float fog_cloud      = is_water ? 0.14f  : 0.18f;
    const bool humid = vapor > humid_gate;
    const float effective_cloud = (cloud > cloud_water * 1.25f) ? cloud : (cloud_water * 1.25f);
    const float precip_cloud_mass = (cloud_water > precip * 0.70f) ? cloud_water : (precip * 0.70f);
    // 降水判据回归单阈值(2026-06-20 根因重构)：precip 已是带时间惯性的 EMA 状态量(见主求解循环)，逐tick
    // 平滑由场层惯性提供，分类不再需要滞回/拖尾补丁。镜像 weather_system.gd::_classify_field_weather_core。
    const float precip_gate = is_water ? 0.032f : 0.040f;
    const float weak_precip_gate = is_water ? 0.022f : 0.030f;
    const bool meaningful_precip = precip > precip_gate ||
        (precip > weak_precip_gate && effective_cloud > mp_cloud_gate &&
         precip_cloud_mass > mp_cloud_gate * 0.35f && vapor > mp_vapor_gate);

    // 1) 冰雪 / 暴风雪：极冷(temp≤FREEZE)+可观降水 → 直接暴雪（极地降水本就是冰雪）；
    //    过渡带(FREEZE~MELT)+降水 → 仅当大风(wind_speed>门)才算"暴风雪"，风弱则视为冷雨落到 RAIN。
    if (cold_precip_as_blizzard && meaningful_precip) {
        if (temp <= 0.24f)
            return 3; // BLIZZARD
        if (!is_water && snow_cover >= 0.25f &&
            temp < 0.31f + snow_classification_margin)
            return 3; // BLIZZARD
        if (temp < 0.31f + snow_classification_margin &&
            effective_cloud > 0.18f && vapor > 0.20f && precip > 0.04f &&
            wind_speed > 1.0f)   // Stage2: 1.15→1.0 (镜像 weather_system.gd BLIZZARD_WIND_GATE)
            return 3; // BLIZZARD
    }
    // 2) 强对流风暴：暖湿 + 高不稳定 + 强降水；暖洋异常核心强制成 STORM。去硬纬度门(原 lat_abs<0.70)
    //    ——warm 已把 STORM 限制在暖区，类型边界改由弯曲等温线决定，消除"沿纬线的数学直线天气带"。
    // Stage6h: STORM 阈大幅提高(0.50→0.70, precip 0.05→0.065)——雷暴=少数强对流，去 STORM≈RAIN 与横跳。镜像 weather_system.gd。
    const bool warm_ocean_core = is_water && ocean_an > 0.05f &&
        instability > 0.64f && precip > 0.060f && effective_cloud > 0.24f && precip_cloud_mass > 0.045f;
    if (warm && humid &&
        ((instability > 0.70f && precip > 0.065f && precip_cloud_mass > 0.050f) || warm_ocean_core))
        return 2; // STORM
    // 3) 季风：暖 + 季风湿通量/大尺度高湿 + 持续降水 + 厚云；暖海强对流核心先归 STORM，
    //    季风保留给沿岸/上岸的持续雨带，避免台风种子被 MONSOON 抢占。
    float monsoon_driver = wf_smoothstep(monsoon_vapor * 0.78f, monsoon_vapor + 0.06f, vapor) * 0.24f;
    if (monsoon_flux > monsoon_driver) monsoon_driver = monsoon_flux;
    const bool sustained_precip = precip > monsoon_precip * 0.82f && precip_cloud_mass > monsoon_cloud * 0.38f;
    const float monsoon_flux_gate = is_water ? 0.08f : 0.13f;
    const bool inland_monsoon_plume = !is_water && vapor > 0.24f && wind_speed > 0.75f &&
        precip > monsoon_precip && precip_cloud_mass > monsoon_cloud * 0.45f;
    const bool monsoon_flow_gate = monsoon_driver > monsoon_flux_gate || inland_monsoon_plume;
    if (warm && sustained_precip && effective_cloud > monsoon_cloud * 0.82f && monsoon_flow_gate)
        return 7; // MONSOON
    // 4) 普通降水（含被降级的过渡带冷雨）。
    if (meaningful_precip)
        return 1; // RAIN
    // 5) 雾：高湿低降水、偏凉。单阈 cloud>0.14（FOG 闪烁由 EMA 平滑后的 cloud/precip 场自然消除）。
    if (vapor > fog_vapor && effective_cloud > fog_cloud && precip < 0.030f && temp < 0.55f)
        return 5; // FOG
    // 6) 旱灾(2026-06-22 定义，Stage3 提到热浪之前)：暖 + 异常偏暖(temp_anom>0.10) + 几乎无降水 + 少云。
    //    bone-dry 强暖距平先归旱灾；剩余暖距平少雨格落到下面的热浪。镜像 weather_system.gd。
    if (!is_water && temp > 0.55f && temp_anom > 0.10f && precip < 0.006f && effective_cloud < 0.18f)
        return 4; // DROUGHT
    // 7) 热浪(Stage3→Stage5 重定义 2026-06-23)：实测 target_type=6 运行期恒为 0(分类器收到的 temp_anom
    //    与录制不一致)。改用 STORM/MONSOON 同款已验证可达的 warm(temp>0.55)+晴(effective_cloud<0.24)
    //    +干(vapor<0.12)+少雨。语义=暖季晴干热天。可达但速率需用新录制标定。镜像 weather_system.gd。
    if (!is_water && warm && precip < 0.012f && effective_cloud < 0.24f && vapor < 0.12f)
        return 6; // HEATWAVE
    return 0; // CLEAR
}

inline bool wf_is_precip_weather_type(uint8_t wt) {
    return wt == 1 || wt == 2 || wt == 3 || wt == 7;
}

// Mirror weather_system.gd::_field_intensity_for_type (line 1551).
inline float wf_field_intensity_for_type(uint8_t wt, float temp, float vapor,
                                         float cloud, float precip,
                                         float instability, float ocean_an) {
    float v = 0.0f;
    switch (wt) {
        case 2: { // STORM
            const float m = (precip > instability) ? precip : instability;
            v = m * 0.82f + cloud * 0.18f;
            break;
        }
        case 7: // MONSOON
            v = precip * 0.72f + vapor * 0.18f + cloud * 0.18f;
            break;
        case 1: // RAIN
        case 3: // BLIZZARD
            v = precip * 1.15f + cloud * 0.20f;
            break;
        case 5: // FOG
            v = cloud * 0.75f + vapor * 0.20f;
            break;
        case 6: { // HEATWAVE
            float dry = 0.32f - vapor;
            if (dry < 0.0f) dry = 0.0f;
            v = (temp - 0.65f) * 2.2f + dry;
            break;
        }
        case 4: { // DROUGHT
            float oa = -ocean_an;
            if (oa < 0.0f) oa = 0.0f;
            v = (0.35f - vapor) * 2.0f + (0.16f - cloud) + oa * 0.6f;
            break;
        }
        default:
            return 0.0f;
    }
    if (v < 0.0f) v = 0.0f;
    else if (v > 1.0f) v = 1.0f;
    return v;
}

// Mirror weather_system.gd::_apply_frontal_convergence_boost fast-indexed path.
// Folded into F.1 so commit() no longer pays a separate GDScript full sweep on
// convergence-refresh ticks.
inline void wf_apply_frontal_convergence_boost_idx(
        int idx, const float *T, const float *AA, const int32_t *NB,
        float climate_anomaly, float convergence,
        float temp_self, float vapor, float ocean_an,
        float &cloud, float &precip, float &instability, uint8_t &wt,
        float &intensity) {
    constexpr float STORM_TEMP_DIFF = 0.28f;
    constexpr float WEAK_TEMP_DIFF = 0.06f;
    constexpr float CONVERGENCE_THRESHOLD = 0.45f;
    if (convergence < CONVERGENCE_THRESHOLD) return;

    float t_min = temp_self;
    float t_max = temp_self;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float t_nb = T[nb_idx] + climate_anomaly + AA[nb_idx];
        if (t_nb < 0.0f) t_nb = 0.0f;
        else if (t_nb > 1.0f) t_nb = 1.0f;
        if (t_nb < t_min) t_min = t_nb;
        if (t_nb > t_max) t_max = t_nb;
    }

    const float temp_diff = t_max - t_min;
    float diff_score = temp_diff / STORM_TEMP_DIFF;
    if (diff_score < 0.0f) diff_score = 0.0f;
    else if (diff_score > 1.0f) diff_score = 1.0f;
    float frontal_score = ((convergence - CONVERGENCE_THRESHOLD)
            / (1.0f - CONVERGENCE_THRESHOLD)) * diff_score;
    if (frontal_score < 0.0f) frontal_score = 0.0f;
    else if (frontal_score > 1.0f) frontal_score = 1.0f;
    if (frontal_score < 0.45f) return;

    const float cloud_min = 0.25f + frontal_score * 0.20f;
    const bool frontal_precip_allowed = vapor > 0.09f;
    const float precip_min = frontal_precip_allowed ? (0.05f + frontal_score * 0.12f) : 0.0f;
    const float inst_min = 0.25f + frontal_score * 0.15f;
    if (cloud < cloud_min) cloud = cloud_min;
    if (frontal_precip_allowed && precip < precip_min) precip = precip_min;
    if (instability < inst_min) instability = inst_min;
    if (cloud > 1.0f) cloud = 1.0f;
    if (precip > 1.0f) precip = 1.0f;
    if (instability > 1.0f) instability = 1.0f;

    if (temp_diff < WEAK_TEMP_DIFF && (wt == 2 || wt == 7)) {
        wt = 1; // RAIN
    }
    if (!wf_is_precip_weather_type(wt) && precip >= 0.040f) {
        wt = 1; // RAIN
    }
    intensity = wf_field_intensity_for_type(
        wt, temp_self, vapor, cloud, precip, instability, ocean_an);
}

} // anonymous namespace (F.1 helpers)

// ─── F.3 helpers ─────────────────────────────────────────────────────────────
namespace {

// Mirror weather/wind_belt.gd::wind_at — bit-equal scalar translation.
// Constants from wind_belt.gd:38-51. All scalar; promote to double for
// bit-equal stability across libm differences (charter §12.6.2).
inline void wind_belt_at(double ny, double season_phase,
                         double *out_wx, double *out_wy) {
    (void)season_phase;
    constexpr double ITCZ_HALF_WIDTH = 0.05;
    constexpr double TRADE_TOP       = 0.40;
    constexpr double WEST_TOP        = 0.70;
    constexpr double TRADE_X         = -1.0;
    constexpr double TRADE_Y_AMP     = 0.20;
    constexpr double WEST_X          = 1.0;
    constexpr double WEST_Y_AMP      = 0.10;
    constexpr double POLAR_X         = -1.0;
    constexpr double POLAR_Y_AMP     = 0.20;
    constexpr double ITCZ_X          = -0.20;
    constexpr double BBH             = 0.06;
    const double lat_signed = (ny - 0.5) * 2.0; // F.3 不传 lat_jitter
    const double abs_lat    = (lat_signed < 0.0) ? -lat_signed : lat_signed;
    const double sl         = (lat_signed < -0.001) ? -1.0 : (lat_signed > 0.001 ? 1.0 : 1.0);

    // smoothstep(a, b, x) = (clamp((x-a)/(b-a), 0, 1))^2 * (3 - 2*t)
    auto smoothstep = [](double a, double b, double x) -> double {
        const double span = b - a;
        if (std::abs(span) < 1e-12) return (x >= a) ? 1.0 : 0.0;
        double t = (x - a) / span;
        if (t < 0.0) t = 0.0; else if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    };

    const double w_itcz_b = 1.0 - smoothstep(ITCZ_HALF_WIDTH - BBH, ITCZ_HALF_WIDTH + BBH, abs_lat);
    const double w_trade_b = smoothstep(ITCZ_HALF_WIDTH - BBH, ITCZ_HALF_WIDTH + BBH, abs_lat)
                           * (1.0 - smoothstep(TRADE_TOP - BBH, TRADE_TOP + BBH, abs_lat));
    const double w_west_b = smoothstep(TRADE_TOP - BBH, TRADE_TOP + BBH, abs_lat)
                          * (1.0 - smoothstep(WEST_TOP - BBH, WEST_TOP + BBH, abs_lat));
    const double w_polar_b = smoothstep(WEST_TOP - BBH, WEST_TOP + BBH, abs_lat);
    const double base_x = w_itcz_b * ITCZ_X + w_trade_b * TRADE_X + w_west_b * WEST_X + w_polar_b * POLAR_X;
    const double base_y = w_trade_b * (-TRADE_Y_AMP * sl) + w_west_b * (WEST_Y_AMP * sl) + w_polar_b * (-POLAR_Y_AMP * sl);

    double wx = base_x;
    double wy = base_y;
    const double wlen2 = wx * wx + wy * wy;
    if (wlen2 < 0.0001) {
        *out_wx = 1.0;
        *out_wy = 0.0;
        return;
    }
    const double inv = 1.0 / std::sqrt(wlen2);
    *out_wx = wx * inv;
    *out_wy = wy * inv;
}

} // anonymous namespace (F.3 helpers)

namespace {

static inline double pk_clamp01(double v) {
    return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
}

static inline bool pk_is_water_terrain(uint8_t t) {
    return t == 0 || t == 1 || t == 18 || t == 19 || t == 20 || t == 21;
}

static inline bool pk_is_ocean_connected_seed_terrain(uint8_t t) {
    return t == 0 || t == 1;
}

static inline int pk_upwind_dir_index_from_wind(float wx, float wy) {
    const double len2 = double(wx) * double(wx) + double(wy) * double(wy);
    if (len2 <= 0.0001) {
        return -1;
    }
    const double inv_len = 1.0 / std::sqrt(len2);
    const double nx = double(wx) * inv_len;
    const double ny = double(wy) * inv_len;
    const double wind_q = std::sqrt(3.0) / 3.0 * nx - ny / 3.0;
    const double wind_r = 2.0 / 3.0 * ny;
    const double wind_s = -wind_q - wind_r;
    const double cube_len = std::sqrt(wind_q * wind_q + wind_r * wind_r + wind_s * wind_s);
    if (cube_len <= 0.0001) {
        return -1;
    }
    const double uq = -wind_q / cube_len;
    const double ur = -wind_r / cube_len;
    const double us = -wind_s / cube_len;
    constexpr int DIRS[6][3] = {
        { 1,  0, -1},
        { 1, -1,  0},
        { 0, -1,  1},
        {-1,  0,  1},
        {-1,  1,  0},
        { 0,  1, -1},
    };
    const double inv_dir_len = 1.0 / std::sqrt(2.0);
    int best = 0;
    double best_dot = -std::numeric_limits<double>::infinity();
    for (int d = 0; d < 6; ++d) {
        const double dot = uq * double(DIRS[d][0]) * inv_dir_len
                         + ur * double(DIRS[d][1]) * inv_dir_len
                         + us * double(DIRS[d][2]) * inv_dir_len;
        if (dot > best_dot) {
            best_dot = dot;
            best = d;
        }
    }
    return best;
}

static inline uint8_t pk_derive_landform(uint8_t terrain, float elev, float sea_level) {
    // Terrain enum order mirrors scripts/geography/terrain_type.gd.
    // Landform enum order mirrors scripts/geography/landform_type.gd.
    if (terrain == 18) return 3; // LAKE
    if (terrain == 0 || terrain == 1 || terrain == 19 || terrain == 20 || terrain == 21) {
        if (elev < sea_level * 0.55f) return 0; // DEEP_OCEAN
        if (elev < sea_level * 0.92f) return 1; // OCEAN
        return 2; // COAST
    }
    if (terrain == 22) return 9;  // DELTA
    if (terrain == 25) return 10; // BADLANDS
    if (terrain == 24) return 11; // SALT_FLAT
    if (terrain == 29) return 4;  // FLOODPLAIN -> PLAIN geom, wet alluvial ecology
    if (terrain == 30) return 13; // MESA → PLATEAU（方山＝小型平顶台地）

    const float denom = std::max(1.0f - sea_level, 0.001f);
    const float land_h = (elev - sea_level) / denom;
    if (land_h > 0.92f) return 8; // PEAK（仅极端高程；普通峰顶由 post-base 局部峰顶 pass 稀疏写入）
    if (land_h > 0.70f) return 7; // MOUNTAIN（较高且陡峭的山地；山原由 PLATEAU override 接管）
    if (land_h > 0.22f) return 6; // HILL
    if (land_h > 0.05f) return 5; // LOWLAND
    return 4; // PLAIN
}

static inline uint8_t pk_derive_landform_with_volcano(uint8_t terrain, float elev,
                                                      float sea_level, bool has_volcano) {
    if (has_volcano) return 12; // VOLCANO
    return pk_derive_landform(terrain, elev, sea_level);
}

// 季节/生态 biome 转换时复用：单格派生 landform，但保留生成期通过多格邻域起伏分析写入的
// 结构性地貌 PEAK(8)/VOLCANO(12)/PLATEAU(13)/RIFT_VALLEY(14)/CANYON(15)。这些地貌无法由
// 单格 pk_derive_landform 复现，若每个 refresh round 的 biome 转换 pass(shrubland/mangrove/
// glacier/redecide 等)都裸调 pk_derive_landform，会把高原/高峰/裂谷/峡谷逐轮侵蚀掉(实测高寒
// 高原转冰川即丢失 PLATEAU)。地质上冰盖覆于高原、冰川覆于高峰，landform 仍应是高原/高峰。
static inline uint8_t pk_derive_landform_preserve(uint8_t terrain, float elev,
                                                  float sea_level, uint8_t prev_lf) {
    if (!pk_is_water_terrain(terrain) &&
        (prev_lf == 8 || prev_lf == 12 || prev_lf == 13 || prev_lf == 14 || prev_lf == 15)) {
        return prev_lf;
    }
    return pk_derive_landform(terrain, elev, sea_level);
}

static inline uint8_t pk_whittaker_vegetation(float temperature, float moisture, uint8_t landform) {
    const bool is_alpine = (landform == 7 || landform == 8);
    const bool is_hilly = (landform == 6);
    if (temperature < 0.06f) return 1; // POLAR_DESERT
    if (temperature < 0.20f) return is_alpine ? 3 : 2; // ALPINE_TUNDRA / TUNDRA
    if (temperature < 0.40f) {
        if (moisture > 0.40f) return is_alpine ? 8 : 5; // TEMPERATE_CONIFER / TAIGA
        if (moisture > 0.20f) return 6; // BOREAL_SHRUB
        return is_alpine ? 3 : 10; // ALPINE_TUNDRA / TEMPERATE_STEPPE
    }
    if (temperature < 0.55f) {
        if (moisture > 0.55f) return is_alpine ? 8 : (is_hilly ? 7 : 7);
        if (moisture > 0.30f) return is_alpine ? 4 : 9; // ALPINE_MEADOW / TEMPERATE_GRASSLAND
        return is_alpine ? 6 : 10; // BOREAL_SHRUB / TEMPERATE_STEPPE
    }
    if (moisture > 0.65f) return 14; // TROPICAL_RAINFOREST
    if (moisture > 0.40f) return 15; // TROPICAL_DRY_FOREST
    if (moisture > 0.20f) return 13; // SAVANNA
    if (moisture < 0.10f) return 17; // XERIC_DESERT
    return 16; // DESERT_SCRUB
}

static inline uint8_t pk_derive_vegetation(uint8_t terrain, uint8_t landform, float temperature, float moisture) {
    if (terrain == 0 || terrain == 18 || terrain == 20) return 0; // NONE（开阔海/湖/海冰）
    // COAST：暖凉浅海软底育海草床(SEAGRASS)，过冷/过热裸沙底为 NONE。
    if (terrain == 1) return (temperature > 0.42f && temperature < 0.74f) ? 26 : 0; // SEAGRASS
    if (terrain == 19) return 23; // CORAL_REEF
    if (terrain == 21) return 22; // KELP_FOREST
    if (terrain == 17) return 0;  // GLACIER
    if (terrain == 9) {
        if (landform == 6 || landform == 7) return 3; // ALPINE_TUNDRA
        if (landform == 8) return 0; // PEAK
        return 1; // POLAR_DESERT
    }
    const bool is_alpine = (landform == 7 || landform == 8);
    const bool is_hilly = (landform == 6);
    if (landform == 8) return 0; // PEAK
    if (terrain == 22) return temperature < 0.55f ? 21 : 19; // MARSH / MANGROVE
    if (terrain == 23) return 18; // OASIS_VEG
    if (terrain == 24) return 0;  // SALT_FLAT
    if (terrain == 25) return 16; // DESERT_SCRUB
    // ── terrain-overhaul 新增地形 → 植被映射 ──
    if (terrain == 26) return moisture < 0.08f ? 17 : 16; // COLD_DESERT → XERIC/DESERT_SCRUB
    if (terrain == 27) return 11; // CHAPARRAL → MEDITERRANEAN_SHRUB
    if (terrain == 28) return 27; // MOOR → PEAT_BOG
    if (terrain == 29) {          // FLOODPLAIN
        if (temperature > 0.55f) return moisture > 0.60f ? 25 : 13; // MONSOON_FOREST / SAVANNA
        return moisture > 0.70f ? 21 : 9; // MARSH / TEMPERATE_GRASSLAND
    }
    if (terrain == 30) return 16; // MESA → DESERT_SCRUB（稀疏耐旱）
    if (terrain == 10) return temperature < 0.34f ? 27 : 20; // SWAMP → 冷区 PEAT_BOG / 否则 SWAMP
    if (terrain == 16) return 19; // MANGROVE
    if (terrain == 15) return 11; // MEDITERRANEAN_SHRUB
    if (terrain == 8) return is_alpine ? 3 : 2; // TUNDRA
    if (terrain == 13) return is_alpine ? 8 : 5; // TAIGA
    if (terrain == 5 || terrain == 6 || terrain == 2) {
        return pk_whittaker_vegetation(temperature, moisture, landform);
    }
    switch (terrain) {
        case 4: // FOREST
            if (is_alpine) return 8;
            // 暖湿丘陵迎风坡 → 云雾林
            if (is_hilly && temperature > 0.50f && moisture > 0.70f) return 24; // CLOUD_FOREST
            return temperature > 0.55f ? 12 : 7;
        case 11: // JUNGLE
            if ((is_alpine || is_hilly) && moisture > 0.62f) return 24; // CLOUD_FOREST（热带高地云雾林）
            if (moisture > 0.72f) return 14; // TROPICAL_RAINFOREST
            if (moisture > 0.55f) return 25; // MONSOON_FOREST（季风半落叶）
            return 15; // TROPICAL_DRY_FOREST
        case 12: // SAVANNA
            if (is_alpine) return moisture > 0.45f ? 4 : 6; // 高地稀树草原 → 高山草甸/山地灌丛
            return moisture > 0.45f ? 25 : 13; // 湿端季风林 / 否则稀树草原
        case 3:  return is_alpine ? 4 : 9; // GRASSLAND
        case 14: // STEPPE
            if (is_alpine) return temperature < 0.28f ? 3 : (moisture > 0.32f ? 4 : 6);
            return 10;
        case 7:  return moisture < 0.10f ? 17 : 16; // DESERT
        default: return pk_whittaker_vegetation(temperature, moisture, landform);
    }
}

static inline uint8_t pk_derive_cover(uint8_t terrain, float snow_cover) {
    if (terrain == 17) return 2; // GLACIER
    if (terrain == 20) return 3; // SEA_ICE
    if (terrain == 9) return 1;  // SNOW
    if (snow_cover > 0.5f && !pk_is_water_terrain(terrain)) return 1; // SNOW
    if (terrain == 8) return 4; // PERMAFROST
    return 0; // NONE
}

// DOTS-Total-CPP Phase 4 收尾迁移（plan/dots-total-cpp 任务 1+2）：season_refresh
// stage 1-8 helpers，与 GDScript map_generator.gd 1:1 同源（bit-equal epsilon 1e-5）。

static inline bool pk_is_permanent_landform(uint8_t t) {
    // OASIS=23, DELTA=22, SALT_FLAT=24, BADLANDS=25
    // terrain-overhaul 新增"特征 pass 专属"地形(分类器无法复现)也须永久固定，
    // 否则运行期 season_refresh 的 pk_decide_terrain 重判会把它们退回基础气候地形：
    //   CHAPARRAL=27, MOOR=28, FLOODPLAIN=29, MESA=30。
    // 注：COLD_DESERT=26 由 pk_decide_terrain 可确定性复现，故不入永久表(随气候动态)。
    return t == 23 || t == 22 || t == 24 || t == 25
        || t == 27 || t == 28 || t == 29 || t == 30;
}

static inline double pk_smoothstep(double a, double b, double x) {
    if (b <= a) return x < a ? 0.0 : 1.0;
    double t = (x - a) / (b - a);
    if (t < 0.0) t = 0.0;
    else if (t > 1.0) t = 1.0;
    return t * t * (3.0 - 2.0 * t);
}

// SAME_SOURCE: map_generator.gd::_alt_penalty (line 3059).
//   ALT_PEN_LINEAR=0.40, ALT_PEN_HIGH_LO=0.45, ALT_PEN_HIGH_HI=1.00, ALT_PEN_HIGH_AMP=0.22
static inline double pk_alt_penalty(double e) {
    const double lin = e * 0.40;
    const double hi = pk_smoothstep(0.45, 1.00, e) * 0.22;
    return lin + hi;
}

// SAME_SOURCE（C++ 镜像）: DCClimateMath.LAT_TEMP_CURVE_EXP —— 纬度温度钟形曲线指数的
// 唯一 C++ 值。赤道=1、两极=0，指数越大高纬越冷。2026-06-16：1.2→1.6（调低极地温度、
// 拓宽海冰带）。改这里务必同步 DCClimateMath.LAT_TEMP_CURVE_EXP（GDScript）+
// climate_season.gdshaderinc（Shader），并重编 gdext。
// terrain-overhaul（2026-06-18）：1.6→1.3，拓宽温带带——旧值钟形过窄使中纬迅速跌入
// taiga/tundra，温带森林/草原带被压扁；下调指数让温带/亚热带占据更多纬度。
static constexpr double PK_LAT_TEMP_CURVE_EXP = 1.3;

// [cylindrical-earth-daylight] 文件作用域 2π：供生成期圆柱噪声采样(cyl_noise)、经度角(θ=2π·col/width)
// 与雨影 jitter 圆环采样共用。放文件作用域而非函数内，避免无捕获 lambda 隐式捕获 constexpr 报错
// (MSVC C3493)，且让分属不同函数的 elevation / rain-shadow 两处都能访问同一常量。
static constexpr double PK_TWO_PI = 6.283185307179586;

// SAME_SOURCE（C++ 镜像）: DCClimateMath.lat_temp_bell —— 全工程纬度温度钟形的唯一 C++ 实现。
//   lat_temp = pow(cos(lat_signed * π/2), PK_LAT_TEMP_CURVE_EXP) ∈ [0,1]（cos 偶函数，传 |ls| 等价）。
// 下方 pk_compute_temperature + 洋流上升流/热盐 cold-sink 一律调用本函数，不再就地重写 pow(cos,...)。
static inline double pk_lat_temp_bell(double lat_signed) {
    const double c = std::cos(lat_signed * M_PI * 0.5);
    return std::pow(c < 0.0 ? 0.0 : c, PK_LAT_TEMP_CURVE_EXP);
}

// SAME_SOURCE: map_generator.gd::_compute_temperature —— 钟形 - 海拔惩罚，clamp[0,1]。
static inline float pk_compute_temperature(double ny, double elevation) {
    const double lat_temp = pk_lat_temp_bell((ny - 0.5) * 2.0);
    return float(pk_clamp01(lat_temp - pk_alt_penalty(elevation)));
}

// ─── [P1 hypsometric remap 2026-06-25] 高程分段重映射（治平原/阶梯）─────────────────
// 在 normalize 之后对 land_h ∈ [0,1]（陆地相对海拔）应用一条单调三段曲线：低地段压平
// （出真平原）、中段做柔和台地（可辨但非硬 staircase）、高段陡升（拉开起伏、山更挺拔）。
// 端点固定 0→0、1→1；用 PCHIP（Fritsch–Carlson 单调限幅）保证 C1 连续 + 单调（不倒置高程序
// → 山仍最高、biome 序不乱）。控制点以 constexpr 落地，可一行调参。
//   Layer B（仿真高程 E，base pass）以 mix=1.0 施全曲线定结构；
//   Layer A（bake 期 per-pixel elev_blend）以小 mix 残差重锐化台地边缘（见 run_bake_terrain_index_pass）。
// 与 map_baker.gd 的 _make_hypso_curve / _hypso_remap_landh 逐位对齐。
constexpr int    PK_HYPSO_NP = 5;
// 形态：平原(低斜率压平) → 缓坡上台 → 台地 shelf(最平,可辨) → 高山陡升(拉开起伏)。
constexpr double PK_HYPSO_XS[PK_HYPSO_NP] = { 0.0, 0.32, 0.52, 0.70, 1.0 };
constexpr double PK_HYPSO_YS[PK_HYPSO_NP] = { 0.0, 0.34, 0.54, 0.70, 1.0 };
constexpr double PK_HYPSO_LAYER_A_MIX     = 0.0;   // [bimodal 2026-06-26] 置 0：双峰地台模型已直接产出平台，Layer A 关闭

// ─── [bimodal-hypsography 2026-06-26] 大陆-海洋高程：双峰测高(地台)模型参数 ─────────────
// 取代旧"径向穹顶"(elev∝离大陆中心距离)：用锐化的大陆性 mask 在「平坦深海平原」与「平坦大陆地台」
// 之间做陡过渡(大陆坡折→海岸陡坡)，山脉由独立造山带 ridged 信号叠加 → 复现地球双峰 hypsographic 曲线。
// 同时关闭 P1 Layer B(land 压平)与 #3 距岸 BFS 海洋加深(均被本模型吸收，constexpr 开关保留可回退)。
constexpr bool   PK_BIMODAL_ENABLED   = true;   // 主开关：false 回退旧径向穹顶 + P1/#3
constexpr double PK_CONT_RADIAL_W     = 1.00;   // 大陆距离场权重（主导大陆形状）
constexpr double PK_CONT_NOISE_W      = 0.40;   // fBm 海岸线扰动幅度（居中化，仅打皱海岸不抬基线）
constexpr double PK_CONT_THRESH       = 0.19;   // 海陆阈值(对 dist_field)：调小=大陆更大更整、内陆更干→生态更多样
                                                // [water-tuning 2026-06-26] 0.16→0.22→0.19：0.22 虽减陆地，但副作用是内陆抬升
                                                // lt=(C-0.5)*2 整体变缓 → 造山带 orogeny 被 lt 乘后高差变小、达 MOUNTAIN 阈值的格变少
                                                // → 山脉变矮变不显眼（用户反馈）。深海已改由下方"距岸距离驱动洋底深度"BFS 兜底，
                                                // 不再依赖高阈值开放洋面，故回调到 0.19（仍比原 0.16 略减陆地）以恢复山脉；山脉显眼度
                                                // 另由 PK_OROGENY_AMP 解耦增强。
constexpr double PK_CONT_MARGIN       = 0.05;   // 海陆过渡带宽（小→大陆坡越陡、海岸落差/法线越强）
constexpr double PK_POLAR_OCEAN       = 0.85;   // 极地大陆性衰减（→两极偏海/冰盖）
constexpr double PK_PLATFORM_H        = 0.07;   // 大陆地台高出海平面的平坦基面
constexpr double PK_PLATFORM_UNDULATE = 0.03;   // 地台大尺度起伏(很小，保持地台平坦)
constexpr double PK_OCEAN_DEPTH_FRAC  = 0.90;   // 深海平原深度 = sea_level × 此值（越大越深）
constexpr double PK_OROGENY_AMP       = 0.48;   // 造山带最大抬升(山脉相对地台的高度)
                                                // [water-tuning 2026-06-26] 0.42→0.48：与陆地占比(CONT_THRESH)解耦地增强山脉显眼度，
                                                // 补偿 CONT_THRESH 调整对内陆抬升的影响。platform_max=PLATFORM_H+UNDULATE+AMP=0.58,
                                                // e_out_max=sea_level(0.42)+lt(≤1)*0.58=1.0 恰好不触发 clamp 削峰(平顶)。
constexpr double PK_OROG_SHARP        = 1.6;    // ridged 锐度(大→山脊更尖窄)
constexpr double PK_OROG_BELT_LO      = 0.42;   // 造山带 belt 下阈(控制山系覆盖)
constexpr double PK_OROG_BELT_HI      = 0.72;   // 造山带 belt 上阈


struct PkHypsoCurve {
    double xs[PK_HYPSO_NP], ys[PK_HYPSO_NP], m[PK_HYPSO_NP];
    // 单调 cubic Hermite 求值（x 在 [0,1]，端点外 clamp 到端点值）。
    double eval(double x) const {
        if (x <= xs[0]) return ys[0];
        if (x >= xs[PK_HYPSO_NP - 1]) return ys[PK_HYPSO_NP - 1];
        int k = 0;
        while (k < PK_HYPSO_NP - 2 && x >= xs[k + 1]) ++k;
        const double h = xs[k + 1] - xs[k];
        const double t = (x - xs[k]) / h;
        const double t2 = t * t, t3 = t2 * t;
        const double h00 =  2.0 * t3 - 3.0 * t2 + 1.0;
        const double h10 =        t3 - 2.0 * t2 + t;
        const double h01 = -2.0 * t3 + 3.0 * t2;
        const double h11 =        t3 -       t2;
        return h00 * ys[k] + h10 * h * m[k] + h01 * ys[k + 1] + h11 * h * m[k + 1];
    }
};

// 由 constexpr 控制点构造曲线切线（Fritsch–Carlson 单调限幅），每 pass 调一次（非热循环）。
static PkHypsoCurve pk_make_hypso_curve() {
    PkHypsoCurve c;
    for (int i = 0; i < PK_HYPSO_NP; ++i) { c.xs[i] = PK_HYPSO_XS[i]; c.ys[i] = PK_HYPSO_YS[i]; }
    double d[PK_HYPSO_NP - 1];
    for (int i = 0; i < PK_HYPSO_NP - 1; ++i) d[i] = (c.ys[i + 1] - c.ys[i]) / (c.xs[i + 1] - c.xs[i]);
    c.m[0] = d[0];
    c.m[PK_HYPSO_NP - 1] = d[PK_HYPSO_NP - 2];
    for (int i = 1; i < PK_HYPSO_NP - 1; ++i) {
        c.m[i] = (d[i - 1] * d[i] <= 0.0) ? 0.0 : (d[i - 1] + d[i]) * 0.5;
    }
    for (int i = 0; i < PK_HYPSO_NP - 1; ++i) {
        if (d[i] == 0.0) { c.m[i] = 0.0; c.m[i + 1] = 0.0; continue; }
        const double a = c.m[i] / d[i], b = c.m[i + 1] / d[i];
        const double s = a * a + b * b;
        if (s > 9.0) {
            const double tau = 3.0 / std::sqrt(s);
            c.m[i]     = tau * a * d[i];
            c.m[i + 1] = tau * b * d[i];
        }
    }
    return c;
}

// 锚定 sea_level 的便捷封装：仅重塑陆地段（e>sea），below-sea 原样返回；mix<1 时与原值线性混合。
static inline double pk_hypso_remap_elev(const PkHypsoCurve &c, double e,
                                         double sea, double inv_above, double above, double mix) {
    if (e <= sea || inv_above <= 0.0) return e;
    const double lh  = (e - sea) * inv_above;
    const double lhr = c.eval(lh);
    const double mixed = (mix >= 1.0) ? lhr : (lh + (lhr - lh) * mix);
    return sea + mixed * above;
}

// SAME_SOURCE: map_generator.gd::_decide_terrain (permanent_only parameter mirrored).
// 返回值是 TerrainType.TERRAIN 整数：
//   OCEAN=0 / COAST=1 / SNOW=9 / MOUNTAIN=6 / TUNDRA=8 / HILL=5 /
//   JUNGLE=11 / SAVANNA=12 / DESERT=7 / FOREST=4 / GRASSLAND=3 / STEPPE=14 /
//   TAIGA=13 / PLAIN=2.
static inline uint8_t pk_decide_terrain_ex(double elevation, double temperature,
                                           double moisture, double sea_level,
                                           bool permanent_only) {
    if (elevation < sea_level - 0.06) return 0; // OCEAN
    if (elevation < sea_level) return 1;        // COAST

    const double denom = (1.0 - sea_level) > 0.001 ? (1.0 - sea_level) : 0.001;
    const double land_h = (elevation - sea_level) / denom;

    const double snow_line = permanent_only ? 0.85 : 0.82;
    const double snow_line_temp = permanent_only ? 0.26 : 0.34;
    const double cold_snow_line = permanent_only ? 0.70 : 0.55;
    const double cold_snow_temp = permanent_only ? 0.05 : 0.08;
    const double polar_temp = permanent_only ? -1.0 : 0.03;

    if (land_h > snow_line && temperature < snow_line_temp) return 9;       // SNOW
    if (land_h > cold_snow_line && temperature < cold_snow_temp) return 9;  // SNOW
    if (temperature < polar_temp) return 9;                                 // SNOW

    // ── terrain-overhaul Phase 4 统一分类器：landform 与 biome 解耦 ──
    // 仅"真高山"保留 MOUNTAIN 地形(裸岩高差)；旧 land_h>0.22→HILL 的大面积压扁已删除——
    // 中高海拔交回气候 biome 决定，山地起伏改由 pk_derive_landform 派生(HILL/MOUNTAIN/PEAK
    // landform)，植被由 pk_derive_vegetation 按 is_alpine 给高山草甸/高山针叶林。直接提升
    // 中高海拔生物群系多样性，不再把温带森林/草原压成统一 HILL。
    const double mountain_line = permanent_only ? 0.72 : 0.70;
    if (land_h > mountain_line) return 6;  // MOUNTAIN（真高山裸岩）
    if (temperature < 0.20) return 8;      // TUNDRA（寒冷无林）

    // Whittaker：温度×湿度联立气候 biome，覆盖全部中/低海拔（起伏交给 landform）。
    if (temperature > 0.55) {              // 热带
        if (moisture > 0.65) return 11;    // JUNGLE
        if (moisture > 0.36) return 12;    // SAVANNA
        if (moisture > 0.20) return 14;    // STEPPE（干热草）
        return 7;                          // DESERT
    }
    if (temperature > 0.38) {              // 暖温带
        if (moisture > 0.55) return 4;     // FOREST
        if (moisture > 0.32) return 3;     // GRASSLAND
        if (moisture > 0.20) return 14;    // STEPPE
        return 7;                          // DESERT（副热带荒漠）
    }
    // 凉温带 / 北方带（0.20–0.38）
    if (moisture > 0.45) return 13;        // TAIGA
    // [water-tuning 2026-06-26] STEPPE(温带草原)加温度下限：实测 32.8% 的 STEPPE 落在 temp<0.30 的
    // 凉冷/亚极地带 → 视觉上"高纬出现温带草原"。仅 temp>0.30 的暖凉温带保留 STEPPE；更冷的凉温带
    // 按湿度回落到针叶林/苔原/寒漠，符合亚极地地理。
    if (temperature > 0.30) {
        if (moisture > 0.22) return 14;    // STEPPE（温带草原，限暖凉温带）
        return 26;                         // COLD_DESERT
    }
    // 冷凉温带 / 亚极地（0.20–0.30）：不再判温带草原
    if (moisture > 0.28) return 13;        // TAIGA（湿→针叶林）
    if (moisture > 0.16) return 8;         // TUNDRA（中湿→苔原/草甸）
    return 26;                             // COLD_DESERT（寒漠：冷而极旱，区别于热沙漠）
}

static inline uint8_t pk_decide_terrain(double elevation, double temperature,
                                        double moisture, double sea_level) {
    return pk_decide_terrain_ex(elevation, temperature, moisture, sea_level, false);
}

// SAME_SOURCE: wind_belt.gd::wind_at.
// Returns a normalized prevailing-wind Vector2. The orbital phase is kept in
// the signature for compatibility, but this helper no longer injects a direct
// seasonal monsoon offset; local wind evolution should come from SLP gradients.
struct PkWind2 { float x, y; };
static inline PkWind2 pk_wind_belt_wind_at(double ny, double season_phase, double lat_jitter) {
    (void)season_phase;
    constexpr double ITCZ_HALF_WIDTH = 0.05;
    constexpr double TRADE_TOP = 0.40;
    constexpr double WEST_TOP = 0.70;
    constexpr double TRADE_X = -1.0;
    constexpr double TRADE_Y_AMP = 0.20;
    constexpr double WEST_X = 1.0;
    constexpr double WEST_Y_AMP = 0.10;
    constexpr double POLAR_X = -1.0;
    constexpr double POLAR_Y_AMP = 0.20;
    constexpr double ITCZ_X = -0.20;
    constexpr double bbh = 0.06;

    const double lat_signed = (ny - 0.5) * 2.0 + lat_jitter;
    const double abs_lat = std::fabs(lat_signed);
    const double sl = (lat_signed < -0.001) ? -1.0 : (lat_signed > 0.001 ? 1.0 : 1.0);

    const double w_itcz_b  = 1.0 - pk_smoothstep(ITCZ_HALF_WIDTH - bbh, ITCZ_HALF_WIDTH + bbh, abs_lat);
    const double w_trade_b = pk_smoothstep(ITCZ_HALF_WIDTH - bbh, ITCZ_HALF_WIDTH + bbh, abs_lat)
                           * (1.0 - pk_smoothstep(TRADE_TOP - bbh, TRADE_TOP + bbh, abs_lat));
    const double w_west_b  = pk_smoothstep(TRADE_TOP - bbh, TRADE_TOP + bbh, abs_lat)
                           * (1.0 - pk_smoothstep(WEST_TOP - bbh, WEST_TOP + bbh, abs_lat));
    const double w_polar_b = pk_smoothstep(WEST_TOP - bbh, WEST_TOP + bbh, abs_lat);

    double bx = w_itcz_b * ITCZ_X
              + w_trade_b * TRADE_X
              + w_west_b * WEST_X
              + w_polar_b * POLAR_X;
    double by = w_itcz_b * 0.0
              + w_trade_b * (-TRADE_Y_AMP * sl)
              + w_west_b  * (+WEST_Y_AMP * sl)
              + w_polar_b * (-POLAR_Y_AMP * sl);

    const double len2 = bx * bx + by * by;
    if (len2 < 0.0001) {
        return PkWind2{1.0f, 0.0f};
    }
    const double inv = 1.0 / std::sqrt(len2);
    return PkWind2{float(bx * inv), float(by * inv)};
}

// 与 wind_belt.gd::upwind_hex_dir 等价但接 cube delta（int triple）。
// HexUtils.CUBE_DIRECTIONS 顺序（与 _pick_upwind_dir/upwind_hex_dir 同源）。
//   方向 0..5 : (1,0,-1) (1,-1,0) (0,-1,1) (-1,0,1) (-1,1,0) (0,1,-1)
// 注意：与 pk_upwind_dir_index_from_wind 用的 DIRS 相同（line 8113）。
// 返回值是 0..5 的索引；caller 拿后从 neighbor_indices_packed[idx*6 + dir] 取邻居。

} // namespace
} // namespace pk

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
#include "runtime_climate_formulas.h"
// S3：Climate pass 标量 helper 的唯一实现（Godot 无依赖）。这里 include 之后
// dc_*/pk_*/sea_ice_* 仍在 namespace pk 全局作用域可见，原有调用点不受影响。
#include "runtime_climate_pass_math.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
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
    PackedByteArray  lut_enum_data;          // 持久 full buffer；dirty encode 原地 patch
    PackedByteArray  lut_dyn_data;
    PackedByteArray  lut_eco_data;
    PackedByteArray  lut_weather_data;
    PackedInt32Array lut_active_transition_indices;

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


// dc_clamp01f / dc_clampf / pk_wrap_min_image_dx / dc_stabilize_tta / dc_decay_tta /
// dc_phase_progress / dc_subsolar_lat_rad / dc_sunset_hour_angle / dc_day_length_norm /
// dc_insolation_now / dc_insolation_annual_mean / dc_insolation_season_dev /
// PK_ALBEDO_* / PK_T_ICE_* / pk_surface_absorbed_factor / PK_WINTER_COOL_KNEE /
// pk_compress_season_cooling / pk_thermal_alpha_eff / pk_season_offset_continental
// 已在 S3 搬到 runtime_climate_pass_math.h（本文件顶部 include），生产与 worker 共用
// 同一份定义。名字与作用域不变。

// ════════════════════════════════════════════════════════════════════════════
// Phase F / dots-full-migration §F.1-F.6 hot pass C++ implementations
// ════════════════════════════════════════════════════════════════════════════
//
// F.1 已落地 (this PR)。F.2-F.6 仍为 stub（返回 -1.0 → GDScript fallback）。
// 后续 PR 按 charter §12.4 七步 SOP 逐个填充实际算法。

// ─── F.1 helpers ─────────────────────────────────────────────────────────────
namespace {

// stage 11 纯内核要用的无状态 weather helper 全部住在
// runtime_climate_pass_math.h（namespace pk），生产热路径与 worker 共用同一份：
//   wf_wrapped_delta / wf_smoothstep / wf_hash01 / wf_is_water_terrain /
//   wf_vegetation_transp_factor / wf_orographic_lift_from_upstream_idx /
//   wf_wind_speed_norm / wf_neighbor_average_vapor_idx /
//   wf_neighbor_aligned_idx_xy / wf_upstream_vapor_idx_from_first_xy /
//   wf_wind_convergence_idx_xy / 三个 *_cached 变体 /
//   wf_precip_terrain_damping_factor / wf_apply_precip_stability /
//   wf_classify_field_weather_at / wf_is_precip_weather_type /
//   wf_field_intensity_for_type / wf_apply_frontal_convergence_boost_idx /
//   wf_avg_ocean_anomaly_at_idx / wf_evaporation_for_cell_idx。
// 原先这里还有三份收 godot::Vector2 的便利包装（aligned_idx / upstream_vapor /
// wind_convergence），它们和 POD 版本是两份逐位相同的实现。包装被删掉而不是保留
// 转调，因为唯一的调用方是 stage 11 主循环，而主循环现在读 POD 的 pos_x/pos_y。
//
// 2026-11-20（W9）：`wf_wind_convergence_*` 的「半波整流」旧实现也已删除，现在只剩
// 「有符号净流入」一种语义（POD + 几何缓存两个变体，GDScript 镜像两份）。运行时开关
// PK_CLIMATE_CONVERGENCE_LEGACY 一并退役。别再重新引入第二套 convergence 语义。

} // anonymous namespace (F.1 helpers)

// ─── F.3 helpers ─────────────────────────────────────────────────────────────
namespace {

// wind_belt_at 已在 S3 搬到 runtime_climate_pass_math.h：pass_b 雨影上风探测
// 需要它，而那段内核现在是生产与 worker 共用的纯函数。

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

// Geological height keeps terrain thresholds stable when a profile moves the
// actual sea level. Climate/snow calculations intentionally keep their own
// actual-sea normalization.
constexpr double PK_GEOMORPH_REF_SEA_LEVEL = 0.42;
static inline double pk_geomorph_h(double elevation, double sea_level) {
    constexpr double denom = 1.0 - PK_GEOMORPH_REF_SEA_LEVEL;
    return std::max(0.0, (elevation - sea_level) / denom);
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

    const double geomorph_h = pk_geomorph_h(double(elev), double(sea_level));
    if (geomorph_h > 0.92) return 8; // PEAK（仅极端高程；普通峰顶由 post-base 局部峰顶 pass 稀疏写入）
    if (geomorph_h > 0.70) return 7; // MOUNTAIN（较高且陡峭的山地；山原由 PLATEAU override 接管）
    if (geomorph_h > 0.22) return 6; // HILL
    if (geomorph_h > 0.05) return 5; // LOWLAND
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
        // Temperate storm tracks support forest below the former 0.48 cutoff.
        if (moisture > 0.42f) return is_alpine ? 8 : (is_hilly ? 7 : 7);
        if (moisture > 0.26f) return is_alpine ? 4 : 9; // ALPINE_MEADOW / TEMPERATE_GRASSLAND
        return is_alpine ? 6 : 10; // BOREAL_SHRUB / TEMPERATE_STEPPE
    }
    // [climate-zone-fix P1] 亚热带拆出 SUBTROPICAL_FOREST；真热带湿端阈值下移适配天花板。
    // [zonal-envelope] 亚热带上缘 0.66→0.80（≈33°），SUBTROP 湿门 0.36→0.40，与 pk_decide_terrain_ex 同步。
    if (temperature < 0.80f) {       // 亚热带（33–51°）
        if (moisture > 0.40f) return 12; // SUBTROPICAL_FOREST
        if (moisture > 0.22f) return 9;  // TEMPERATE_GRASSLAND
        if (moisture < 0.12f) return 16; // DESERT_SCRUB（副热带旱坡）
        return 10;                       // TEMPERATE_STEPPE
    }
    // Continuous rainforest is the humid tail; seasonal forests own the shoulder.
    if (moisture > 0.64f) return 14; // TROPICAL_RAINFOREST
    if (moisture > 0.42f) return 25; // MONSOON_FOREST
    if (moisture > 0.34f) return 15; // TROPICAL_DRY_FOREST
    // [zonal-envelope 二轮] SAVANNA 下限 0.20→0.24，与 pk_decide_terrain_ex 热带 STEPPE 下限同步。
    if (moisture > 0.24f) return 13; // SAVANNA
    if (moisture < 0.10f) return 17; // XERIC_DESERT
    return 16; // DESERT_SCRUB
}

static inline uint8_t pk_derive_vegetation(uint8_t terrain, uint8_t landform, float temperature, float moisture) {
    if (terrain == 0 || terrain == 18 || terrain == 20) return 0; // NONE（开阔海/湖/海冰）
    // COAST：暖凉浅海软底育海草床(SEAGRASS)，过冷/过热裸沙底为 NONE。
    // [zonal-envelope] 上缘 0.74→0.82：真热带边界收窄到 0.80 后热带浅海也允许海草床。
    if (terrain == 1) return (temperature > 0.42f && temperature < 0.82f) ? 26 : 0; // SEAGRASS
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
            // 暖湿丘陵迎风坡 → 云雾林（[climate-zone-fix P1] 湿门 0.70→0.52 适配湿度天花板）
            if (is_hilly && temperature > 0.50f && moisture > 0.52f) return 24; // CLOUD_FOREST
            return temperature > 0.55f ? 12 : 7; // SUBTROPICAL_FOREST / TEMPERATE_DECIDUOUS
        case 11: // JUNGLE
            // 连续雨林只占湿尾，季风林承接中间湿度带。
            if ((is_alpine || is_hilly) && moisture > 0.60f) return 24; // CLOUD_FOREST（热带高地云雾林）
            if (moisture > 0.66f) return 14; // TROPICAL_RAINFOREST
            if (moisture > 0.50f) return 25; // MONSOON_FOREST（季风半落叶）
            return 15; // TROPICAL_DRY_FOREST
        case 12: // SAVANNA
            if (is_alpine) return moisture > 0.45f ? 4 : 6; // 高地稀树草原 → 高山草甸/山地灌丛
            // Keep SAVANNA's wet edge aligned with pk_decide_terrain_ex's JUNGLE boundary.
            // SAVANNA 湿端季风林门与 JUNGLE 0.64 边界同步。
            return moisture > 0.64f ? 25 : 13; // 湿端季风林 / 否则稀树草原
        case 3:  return is_alpine ? 4 : 9; // GRASSLAND
        case 14: // STEPPE
            if (is_alpine) return temperature < 0.28f ? 3 : (moisture > 0.32f ? 4 : 6);
            return 10;
        case 7:  return moisture < 0.10f ? 17 : 16; // DESERT
        default: return pk_whittaker_vegetation(temperature, moisture, landform);
    }
}

// pk_vegetation_* 系列（is_wet/is_alpine/is_arid/climate_score_for_type/
// candidate_allowed/biome_weight/needs_biome_reconcile/terrain_weight）已 S3 提到
// runtime_climate_pass_math.h —— stage 9 vegetation_dynamics 的共享纯内核要调它们，
// 而那一层不得 include 任何 Godot 头。本文件已 include 那个头，调用方无需改动。

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

// pk_smoothstep / PK_ALT_PEN_ABS_ELEV_BLEND / pk_alt_penalty_from_height /
// pk_land_height_for_temperature / pk_temperature_height_for_penalty / pk_alt_penalty
// 已在 S3 搬到 runtime_climate_pass_math.h。

// SAME_SOURCE（C++ 镜像）: DCClimateMath.LAT_TEMP_CURVE_EXP —— 纬度温度钟形曲线指数的
// 唯一 C++ 值。赤道=1、两极=0，指数越大高纬越冷。2026-06-16：1.2→1.6（调低极地温度、
// 拓宽海冰带）。改这里务必同步 DCClimateMath.LAT_TEMP_CURVE_EXP（GDScript）+
// climate_season.gdshaderinc（Shader），并重编 gdext。
// terrain-overhaul（2026-06-18）：1.6→1.3，拓宽温带带——旧值钟形过窄使中纬迅速跌入
// taiga/tundra，温带森林/草原带被压扁；下调指数让温带/亚热带占据更多纬度。
// PK_LAT_TEMP_CURVE_EXP 已在 S3 搬到 runtime_climate_pass_math.h。

// [cylindrical-earth-daylight] 文件作用域 2π：供生成期圆柱噪声采样(cyl_noise)、经度角(θ=2π·col/width)
// 与雨影 jitter 圆环采样共用。放文件作用域而非函数内，避免无捕获 lambda 隐式捕获 constexpr 报错
// (MSVC C3493)，且让分属不同函数的 elevation / rain-shadow 两处都能访问同一常量。
static constexpr double PK_TWO_PI = 6.283185307179586;

// SAME_SOURCE（C++ 镜像）: DCClimateMath.lat_temp_bell —— 全工程纬度温度钟形的唯一 C++ 实现。
//   lat_temp = pow(cos(lat_signed * π/2), PK_LAT_TEMP_CURVE_EXP) ∈ [0,1]（cos 偶函数，传 |ls| 等价）。
// 下方 pk_compute_temperature + 洋流上升流/热盐 cold-sink 一律调用本函数，不再就地重写 pow(cos,...)。
static inline double pk_lat_temp_bell(double lat_signed) {
    return climate_formula::lat_temp_bell(lat_signed);
}

// SAME_SOURCE: map_generator.gd::_compute_temperature —— 钟形 - 海平面相对海拔惩罚，clamp[0,1]。
static inline float pk_compute_temperature(double ny, double elevation, double sea_level) {
    const double lat_temp = pk_lat_temp_bell((ny - 0.5) * 2.0);
    return float(pk_clamp01(lat_temp - pk_alt_penalty(elevation, sea_level)));
}

#include "world_ext_internal_terrain_classification.inc"
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

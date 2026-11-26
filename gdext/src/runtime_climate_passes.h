#pragma once

// ─── Climate pass POD 缓冲区 + 纯内核（Godot 无依赖）─────────────────
//
// S3（plan「Climate 对拍可比性修复路线」）的核心产出。
//
// 背景：断点 2 是“worker kernel 只实现了 14 个 stage 中的 1 个”。plan 给出的唯一
// 可持续解法是不维护第二套 Climate 实现：把生产 pass 提取为不依赖 Godot 的纯
// 函数，生产路径与 worker 调同一份代码。这样对拍性质从“两套实现比结果”变为
// “同一套实现在两种驱动下比结果”，等价性天然成立，剩下的只是输入边界、执行
// 顺序和状态所有权差异。
//
// 关键事实（S3 策略由此从“重写”降为“搬迁”）：
//   生产侧的 async climate round 已经把 9 个 pass 写成了 std::vector 上的纯函数
//   （_async_*_kernel_pure），与 sync 路径逐行 1:1。它们只是被锁在
//   world_ext_climate.cpp 的文件作用域里（static），worker 无法调用。本文件把
//   它们搬到共享 TU：生产路径的 using namespace pk_async_climate 调用点一行不改，
//   worker 侧（runtime_climate_kernel.cpp）现在能 include 同一份定义。
//
// 约束（不可放松）：
//   1. 本文件与 runtime_climate_passes.cpp 不得 include 任何 godot_cpp 头，也不得触
//      DCWorldExt 成员。这是 worker 侧可用的充要条件。
//   2. 内核体从 world_ext_climate.cpp 逐字搬迁。提取本身必须是零行为变更，
//      否则 S2 分叉矩阵会把“提取引入的新分叉”和“真实分叉”混在一起。
//   3. buffer 结构新增字段时，生产 kick 提取代码与 worker 的 snapshot→buf 映射
//      两边都要同步；只改一边会直接表现为对拍分叉。

#include "runtime_climate_pass_math.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace pk {
namespace pk_async_climate {


// Climate 日内 stage 的位掩码，值与 pk::RuntimeClimateStage 的枚举一致
// （runtime_climate_kernel.h 里有 static_assert 保证不漂移）。
//
// 生产侧需要给**尚未**提取成共享内核的 stage 也置位——那是区分"worker 缺实现"和
// "生产这天本来也没跑"的唯一办法。而那些生产 TU 不该为了一个枚举去 include worker
// kernel 头，所以位常量放在这个双方都已经 include 的文件里。
// Number of Climate stage slots (== pk::RuntimeClimateStage::COUNT). It lives
// here for the same reason the bit constants do: RuntimeThreadReport needs to
// size its per-stage timing arrays, and runtime_pod_protocol.h sits upstream of
// the worker kernel header that owns the enum.
constexpr int CLIMATE_STAGE_SLOT_COUNT = 14;

// 低八位与 round 的 pass_bit 编码同源：pass_bit 0x02 (pass_b) 就是 stage 1 的位。
// record_production_round_scalars 靠这个对齐直接 |= pass_bit，所以两边一旦漂移，
// production_stage_mask 就会指向错的 stage —— runtime_climate_kernel.h 里的
// static_assert 把它钉住。
constexpr int CLIMATE_STAGE_BIT_PASS_A              = 1 << 0;
constexpr int CLIMATE_STAGE_BIT_PASS_B              = 1 << 1;
constexpr int CLIMATE_STAGE_BIT_OCEAN_WATER         = 1 << 2;
constexpr int CLIMATE_STAGE_BIT_OCEAN_LAND          = 1 << 3;
constexpr int CLIMATE_STAGE_BIT_WIND_AIR            = 1 << 4;
constexpr int CLIMATE_STAGE_BIT_WIND_SURFACE        = 1 << 5;
constexpr int CLIMATE_STAGE_BIT_SEA_ICE             = 1 << 6;
constexpr int CLIMATE_STAGE_BIT_TRANSPIRATION       = 1 << 7;
constexpr int CLIMATE_STAGE_BIT_ALBEDO              = 1 << 8;
constexpr int CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS = 1 << 9;
constexpr int CLIMATE_STAGE_BIT_CLIMATE_FEEDBACK    = 1 << 10;
constexpr int CLIMATE_STAGE_BIT_WEATHER             = 1 << 11;
constexpr int CLIMATE_STAGE_BIT_RUNTIME_HYDROLOGY   = 1 << 12;

// 错误码（worker 通过 atomic int 传给主线程，主线程 push_warning）。
constexpr int PK_ASYNC_ROUND_ERR_OK              = 0;
constexpr int PK_ASYNC_ROUND_ERR_INPUT_SIZE      = 1;
constexpr int PK_ASYNC_ROUND_ERR_KERNEL_FAILED   = 2;

// Round-level scalars / cp 字段（kick 时主线程从 GDScript Dictionary 提取，
// worker 在 round 内整段使用）。新增字段时同步更新 kick 提取代码 +
// _async_climate_round_run_passes 内 stub。
struct ClimateRoundScalars {
    // round 锁定的相位（kick 时刻的 season_phase）。worker 全程用这个值，
    // 不再因 round 跨多 ticks 而 stale。解决"夏至滞后"。
    double season_phase = 0.0;

    // ── 来自 cp_struct（climate_pass_a 用） ─────────────────────────────
    double axial_tilt_deg = 23.5;
    double day_length_gain = 0.35;
    double solar_gain = 1.0;
    double insol_amp = 0.20;       // sync 路径 default 0.20
    double insol_gain = 1.0;
    double moist_scale_now = 1.0;
    float  runtime_moisture_base_relax_rate = 0.24f;
    float  runtime_moisture_weather_vapor_weight = 0.12f;
    float  runtime_moisture_precip_weight = 0.78f;
    float  runtime_moisture_soil_weight = 1.82f;
    float  runtime_moisture_soil_dry_weight = 2.21f;
    float  runtime_moisture_water_balance_weight = 1.04f;
    float  runtime_moisture_water_balance_dry_weight = 1.30f;
    int    days_per_year = 365;
    double sea_level = 0.5;

    // pass_a 额外字段（cp.thermal_inertia_* / thermal_daily_delta_cap /
    // snowpack_cover_* / insol_dev_min/max）。sync 路径 default 与
    // run_climate_pass_a 顶部一致。
    double insol_dev_min = -1.0;
    double insol_dev_max = 1.0;
    double thermal_inertia_land = 0.35;
    double thermal_inertia_water = 0.045;
    double thermal_inertia_snow = 0.09;
    double thermal_inertia_high_mountain = 0.16;
    double thermal_daily_delta_cap = 0.15;
    // 加速/跳日补偿：本次 pass_a 距上次实际经过的仿真天数（默认 1.0）。
    // 热惯性松弛与 delta_cap 按此天数积分，否则加速档下海洋温度会严重欠积分、
    // 滞后于太阳直射点。见 climate_daily_system._build_async_kick_input。
    double thermal_dt_days = 1.0;
    double snowpack_cover_low = 0.05;
    double snowpack_cover_full = 0.32;
    // [climate-zone-fix P2] 沿海陆地季节振幅最大衰减比（0=关闭=原行为；0.55=海岸格季节
    // 振幅仅余 45%）。与 per-cell maritime 因子相乘后缩放 season_offset。
    double maritime_season_damp = 0.0;

    // transp pass 用（Stage 1 实装）
    float  transp_outflow_rate = 0.025f;
    float  transp_self_rate    = 0.015f;

    // pass_b knobs（Stage 2，与 sync run_climate_pass_b knobs 一一对应）
    float  pb_winter_boost  = 1.0f;
    float  pb_snow_cool     = 0.0f;
    float  pb_veg_cool      = 0.0f;
    float  pb_diurnal_amp   = 0.0f;
    float  pb_evap_gain     = 0.0f;
    float  pb_rs_threshold  = 0.0f;
    float  pb_rs_factor     = 1.0f;
    int    pb_rs_lookback   = 0;
    float  pb_t_freeze      = 0.0f;
    float  pb_coupling_gain = 0.0f;
    float  pb_coast_leak    = 0.0f;
    float  pb_sea_ice_albedo_cooling = 0.01f;

    // ocean_water / ocean_land knobs（Stage 2）
    int    ow_advect_steps = 3;
    float  ow_heat_mix     = 0.55f;
    float  ow_tta_source_cap = 0.22f;
    float  ow_tta_blend_rate = 0.70f;
    float  ow_tta_zero_current_decay = 0.06f;
    // 生产取 knobs["cold_transport_{form,melt}_threshold"]。旧 worker 拄本误用了
    // sea_ice 的 si_t_form / si_t_melt —— 两组不同的 knob，已分开。
    float  ow_cold_transport_form = 0.06f;
    float  ow_cold_transport_melt = 0.11f;
    float  ol_effective_leak = 0.55f;
    float  ol_tta_source_cap = 0.22f;
    float  ol_tta_blend_rate = 0.70f;
    float  ol_tta_decay_rate = 0.04f;

    // seam-advection-fix 2026-08-03：经度环绕周期（= map.width·√3，单位六边形空间，
    // 不含 hex_size）。pass_b 雨影 / ocean_water / ocean_land / wind_air / wind_surface
    // 五个 async 内核都用 cell_pos_x 差分求邻居方向，接缝需最小映像折叠。
    // kick 时从 DCWorldExt::_native_wrap_period_x 常驻值取（input 可显式覆盖）。
    // 0 = 无环绕域 → 内核退化为裸差分（旧行为）。
    float  wrap_period_x = 0.0f;

    // wind_air / wind_surface knobs（Stage 2）
    int    wa_advect_steps = 3;
    float  wa_heat_mix     = 0.25f;
    float  ws_air_leak     = 0.35f;
    float  ws_cold_transport_form = 0.06f;
    float  ws_cold_transport_melt = 0.11f;

    // sea_ice knobs（Stage 2）
    float si_k_freeze      = 0.40f;
    float si_k_melt        = 1.45f;
    float si_t_form        = 0.06f;
    float si_t_melt        = 0.11f;
    float si_contagion     = 0.035f;
    float si_threshold     = 0.72f;
    float si_hysteresis    = 0.18f;
    float si_ice_delay     = 1.0f;
    bool  si_enable_oht    = true;
    bool  si_apply_terrain_flips = false;
    bool  si_solar_gate_enabled = true;
    float si_freeze_insol_low  = 0.22f;
    float si_freeze_insol_high = 0.45f;
    float si_solar_melt_start  = 0.28f;
    float si_solar_melt_gain   = 1.35f;
    float si_min_thick_ice_solar_exposure = 0.32f;
    float si_daily_delta_cap   = 0.070f;
    float si_edge_mix_rate     = 0.035f;
    float si_dt_days           = 1.0f;
    int   si_terrain_lake_id    = -1;
    int   si_terrain_sea_ice_id = -1;
    int   si_terrain_ocean_id   = -1;

    // ─── finalizer pass knobs（Stage 9，2026-06-16） ──────────────────────
    // 与 GDScript _apply_daily_climate_finalizer 一一对应：
    //   temp_cap_enabled = cp.thermal_final_delta_cap_enabled
    //   temp_cap         = cp.thermal_daily_delta_cap (默认 0.15)
    //   tta_cap          = cp.temperature_transport_anomaly_daily_cap (默认 0.12)
    //   has_temp_start   = _temp_start_of_day_arr.size() == n
    //   has_tta_start    = _tta_start_of_day_arr.size() == n
    bool  fin_temp_cap_enabled = true;
    float fin_temp_cap         = 0.15f;
    float fin_tta_cap          = 0.12f;
    bool  fin_has_temp_start   = false;
    bool  fin_has_tta_start    = false;

    // ─── passes_mask（plan §async-stage-2，2026-06-14） ──────────────────
    // bit-mask 控制 worker 跑哪几个 pass。kick 时 GDScript 传入。
    //   bit 0: pass_a
    //   bit 1: pass_b
    //   bit 2: ocean_water
    //   bit 3: ocean_land
    //   bit 4: wind_air
    //   bit 5: wind_surface
    //   bit 6: sea_ice
    //   bit 7: transp
    //   bit 8: finalizer (Stage 9，2026-06-16)
    // 默认 0x1FF 全开（含 finalizer）。Stage 2 A/B 验证时 bench 单独跑一个 pass，
    // 设 mask=0x01（仅 pass_a）或 0x100（仅 finalizer）。
    // Stage 2 期间 stub 的 pass（pass_b/ocean_*/wind_*/sea_ice）即使被 mask
    // 启用，worker 内部仍是 no-op；不会影响 A/B（验证字段不被它们触碰）。
    int    passes_mask = 0x1FF;
};

// 主线程序列化进 input_buf 的字段集合。所有 cell-level 数据都是 std::vector<float>
// 或 std::vector<uint8_t>，长度 = n_cells。
//
// Stage 1 范围内只列了 transpiration 实际读的 3 个字段（landform/vegetation/
// moisture），加上少量后续 stage 会用的字段占位。其余字段 Stage 2 时按需追加。
struct ClimateInputBuf {
    int n_cells = 0;

    // U8 cell-level（transp 用 + pass_a 用 is_water/terrain/cover + pass_b 用 landform/vegetation）
    std::vector<uint8_t> landform;         // transp: is_water iff lf <= 3；pass_b: LF_LOWLAND/PEAK 等判断
    std::vector<uint8_t> vegetation;       // transp: donor_table 索引；pass_b: foliage_table 索引
    std::vector<uint8_t> is_water;         // pass_a / pass_b 都用
    std::vector<uint8_t> terrain;          // pass_a 占位（实际未读，预留）
    std::vector<uint8_t> cover;            // pass_a 用：COVER_GLACIER 判断

    // U8 in/out — pass_a 既读 ema_initialized 又会把 0 置 1。stage 2 起按
    // in_buf 提供初值，pass_a 在 out_buf 里更新（避免 in/out aliasing）。
    std::vector<uint8_t> ema_initialized;

    // F32 cell-level（transp 读 moisture；pass_a 读静态字段 + 上次温度 / 雪 / 热能；
    // pass_b 读 temp 快照 + snow_cover + elev + lat + pos + insol_dev + tta + sif）
    std::vector<float>   moisture;         // transp 输入；pass_b 输入（read + write）
    std::vector<float>   elevation;        // pass_a / pass_b 读
    std::vector<float>   base_moisture;    // pass_a 读
    std::vector<float>   weather_vapor;    // pass_a: atmospheric anomaly source
    std::vector<float>   soil_moisture;    // pass_a: signed hydrology anomaly
    std::vector<float>   water_balance_30d;// pass_a: signed long-window anomaly
    std::vector<float>   lat_norm;         // pass_a / pass_b 读
    // [climate-zone-fix P2] 海洋性因子 ∈[0,1]，1=紧贴海岸/0=深内陆（由 dist_ocean 指数衰减得到）。
    // pass_a 用它对陆地缩小季节振幅，形成沿海小年较差（温带海洋性 Cfb）。缺省空→不调温。
    std::vector<float>   maritime;         // pass_a 读（静态）
    std::vector<float>   temp_baseline_year; // pass_a 读（静态 LUT）
    // pass_a 年均日照缓存（perf 2026-07-05, Item 4）：dc_insolation_annual_mean(clamp01(ny),
    // axial_tilt, daylen) 只依赖 lat + 两个行星常数，与 season 无关，故对每 cell 逐 tick 恒等。
    // async pass_a kernel 是 static free function、跑在 worker thread，无法安全触碰 member
    // 缓存 _insol_annual_mean_cache（会 data race）。改由主线程在 kick 快照时（持锁）预计算填此
    // 字段，worker 直接读 → bit-equal（同一 dc_insolation_annual_mean(dc_clamp01f(ny),...)）。
    // 空 → worker 回退 inline 重算（旧行为，向后兼容）。
    std::vector<float>   insol_annual_mean;  // pass_a 读（主线程预烘焙）
    std::vector<float>   temp;             // pass_a 读 prev_temp；pass_b 读 temp_snapshot
    std::vector<float>   temp_30d;         // pass_a 读：EMA prev
    std::vector<float>   temp_365d;        // pass_a 读：EMA prev
    std::vector<float>   thermal_energy;   // pass_a 读：prev_energy
    std::vector<float>   snowpack;         // pass_a 读：alpha 判断 + 计算 snow_cover
    std::vector<float>   radiative_modifier_add;    // pass_a: frozen Modifier add
    std::vector<float>   radiative_modifier_factor; // pass_a: frozen Modifier factor
    // pass_b 新增字段：
    std::vector<float>   pos_x;            // pass_b: 邻居方向计算；ocean_water/land 也用
    std::vector<float>   pos_y;            // pass_b; ocean_water/land 也用
    std::vector<float>   insolation_dev;   // pass_b: solar_factor
    std::vector<float>   temp_transport_anomaly; // pass_b: TTA 输入 (海岸 leak + evap)
    std::vector<float>   sea_ice_frac;     // pass_b: 海冰反照率冷却尾循环
    // local_thermal_anomaly: pass_b 在 in 上累加（in/out 都用）
    std::vector<float>   local_thermal_anomaly;
    // ocean_water/ocean_land 新增字段
    std::vector<float>   ocean_current_x;        // ocean_water/land: 邻居方向
    std::vector<float>   ocean_current_y;
    std::vector<float>   ocean_thermal_anomaly;  // ocean_water/land 都写（in/out）
    // 生产权威的 oanom（见 WindSurfaceInput 注释）。非空时 round 会在 pass_a 之后
    // 用它覆盖 oanom —— 因为生产的 ocean stage 在 round 之外分片，worker 不是它的
    // 权威。空 = 生产这一天没跑 wind_surface，此时 worker 保留自己 pass_a 的清零。
    std::vector<float>   production_ocean_anomaly;
    // ocean_water 的两条生产权威输入（见 OceanWaterInput）。非空时 round 里的
    // ocean_water 用它们，而不是拿 temp_baseline_year / temp 当替身。
    std::vector<float>   production_ocean_baseline;
    std::vector<float>   production_ocean_temp_before;
    // wind_air / wind_surface 新增字段（Stage 2）
    std::vector<float>   wind_x;                 // wind_*: 邻居 advect direction
    std::vector<float>   wind_y;
    std::vector<float>   wind_speed;             // wind_*: speed_mix
    std::vector<float>   temp_baseline;          // wind_surface: 合成 cell_temp baseline
    std::vector<float>   air_mass_temp_anomaly;  // wind_air write / wind_surface read+write
    // wind_air 的 baseline_arr：GDScript 的 _compute_temperature(lat_norm, elevation)
    // 静态基线，按 map 缓存。它与 temp_baseline_year 不是同一条 lane，worker 早先
    // 拿后者顶替，air anomaly 因此整体偏。空 → 回退 temp_baseline_year（旧行为）。
    std::vector<float>   wind_baseline;
    // wind_air 的风场回溯轨迹表。生产命中指纹时用它做三点重心插值取上游温度；
    // 派生自物理风场，worker 无法重建，所以照抄生产当天用过的那张。两条同时非
    // 空才生效，生产未命中时为空，worker 一并走离散跳格分支。
    std::vector<int32_t> wind_traj_idx;          // [n_cells * 3]
    std::vector<float>   wind_traj_w;            // [n_cells * 3]
    // sea_ice 新增字段（Stage 2）
    std::vector<uint8_t> base_terrain;     // sea_ice: 还原 base terrain when ice melts
    std::vector<float>   upwelling_strength; // sea_ice: 海水上涌冷却
    std::vector<float>   insolation_now;   // sea_ice: solar gate
    std::vector<float>   cell_temperature_arr; // sea_ice: 主线程传 climate/ocean-adjusted T
    // sea_ice 消费点的 oanom / TTA。不能写进 ocean_thermal_anomaly /
    // temp_transport_anomaly：那两条更早的 pass 也读，sea_ice 读到的是更晚一拍。
    std::vector<float>   production_sea_ice_oanom;
    std::vector<float>   production_sea_ice_tta;
    std::vector<uint8_t> water_terrain_ids; // sea_ice: 256-entry water LUT 源
    std::vector<float>   sea_ice_frac_inout; // sea_ice: in/out（pass_b 也读它）
    // ─── finalizer pass 输入字段（Stage 9，2026-06-16） ─────────────────
    // 主线程在 begin_round 时把 round-start snapshot 传进来。worker finalizer
    // pass 用它做 clamp(temp - start ± temp_cap) + Δ 统计。GDScript 端的
    // _temp_start_of_day_arr / _tta_start_of_day_arr 一一对应。
    std::vector<float>   temp_start_of_day;     // finalizer: temp clamp baseline
    std::vector<float>   tta_start_of_day;      // finalizer: TTA clamp baseline
    std::vector<float>   sea_ice_frac_prev;     // finalizer: sea_ice_delta_max
    std::vector<float>   weather_precip;        // finalizer: precip_p95
    // ─── 后续 pass 占位 ──────────────────────────────────────────────────
    // 全部 9 pass 输入字段已覆盖

    // round-level scalars（在 kick 时设值）
    ClimateRoundScalars scalars;
};

// worker 写入的输出字段集合。同样只列 transp 真正会写的（moisture）+ Stage 2
// 后续追加。output buf 不持有 input copy，节省 220+ KB 内存。
struct ClimateOutputBuf {
    int n_cells = 0;

    // ─── pass_a 输出（Stage 2 实装） ────────────────────────────────────
    // 与 run_climate_pass_a 末尾 16 个 _flush_slot_to_map 一一对应：
    // moisture / snow_cover / temp_baseline / temp_season_offset /
    // ema_initialized / temp_30d / temp_365d / temp_anomaly / insolation_now /
    // insolation_dev / day_length / heat_input / thermal_energy / snowpack /
    // ocean_thermal_anomaly / local_thermal_anomaly
    //
    // 注意：transp 也写 moisture（覆盖 pass_a 的 moisture 输出）。Stage 2
    // 范围内 transp 在 pass_a 之后跑，但当前 worker loop pass_a 是 stub，
    // moisture 还是 transp 唯一写者。Stage 3 stub 替换后顺序自然处理。
    std::vector<float>   moisture;             // transp（Stage 1）& pass_a
    std::vector<float>   temp_baseline;
    std::vector<float>   temp_season_offset;
    std::vector<uint8_t> ema_initialized;
    std::vector<float>   temp_30d;
    std::vector<float>   temp_365d;
    std::vector<float>   temp_anomaly;
    std::vector<float>   insolation_now;
    std::vector<float>   insolation_dev;
    std::vector<float>   day_length;
    std::vector<float>   heat_input;
    std::vector<float>   thermal_energy;
    std::vector<float>   snowpack;
    std::vector<float>   ocean_thermal_anomaly;
    std::vector<float>   local_thermal_anomaly;
    // wind_air / wind_surface 输出（Stage 2）
    std::vector<float>   air_mass_temp_anomaly;   // wind_air write / wind_surface overwrite
    std::vector<float>   temp;                    // wind_surface 最终写 cell_temp (climate round 唯一)
    // sea_ice 输出（Stage 2）
    std::vector<float>   sea_ice_frac;            // sea_ice 写
    std::vector<uint8_t> terrain;                 // sea_ice 翻转写（apply_terrain_flips 时）

    // dirty 索引（transp 已计算过 dirty_indices/dirty_values，
    // 主线程 poll 时可一并取出做 mark_dirty_indexed 优化）
    std::vector<int32_t> moisture_dirty_indices;
    std::vector<float>   moisture_dirty_values;

    // ─── 占位（Stage 2 余下 pass 启用） ───────────────────────────────────
    // pass_b 输出：local_thermal_anomaly（追加）/ moisture（覆盖）
    // ocean_water 输出：ocean_thermal_anomaly
    // ocean_land 输出：ocean_thermal_anomaly（累加）
    // wind_air 输出：air_mass_temp_anomaly
    // wind_surface 输出：temp（最终）/ air_mass_temp_anomaly
    // sea_ice 输出：sea_ice_frac / terrain（flip 事件需要单独输出列表）

    // sea_ice flip events（Stage 2 sea_ice 移植时启用）。主线程 poll 时
    // 据此调用 GDScript 端的 mark_terrain_dirty / atlas update 等钩子。
    std::vector<int32_t> flipped_cell_indices;
    std::vector<uint8_t> flipped_new_terrain;

    // ─── finalizer pass diag（Stage 9，2026-06-16） ─────────────────────
    // 与 GDScript _apply_daily_climate_finalizer 返回的 diag 字段一一对应。
    // worker 写完后主线程 poll 拿来填 _last_finalizer_diag，跳过同名 GDScript loop。
    // 全部 scalars / counters，无 PackedArray，poll 端 marshalling cost 可忽略。
    bool   fin_applied = false;
    float  fin_max_temp_delta = 0.0f;
    float  fin_p95_temp_delta = 0.0f;
    float  fin_p99_temp_delta = 0.0f;
    float  fin_preclamp_max_temp_delta = 0.0f;
    float  fin_preclamp_p99_temp_delta = 0.0f;
    int32_t fin_temp_delta_gt_005_count = 0;
    int32_t fin_temp_delta_gt_010_count = 0;
    int32_t fin_temp_delta_gt_020_count = 0;
    int32_t fin_temp_delta_clamped_count = 0;
    float  fin_max_transport_anomaly = 0.0f;
    int32_t fin_tta_clamped_count = 0;
    int32_t fin_thermal_init_count = 0;
    float  fin_sea_ice_delta_max = 0.0f;
    float  fin_precip_p95 = 0.0f;
    int32_t fin_cells_seen = 0;
    // finalizer 写出的 final TTA（in/out aliasing，独立 buffer 避免和 wind_air 输出冲突）
    std::vector<float> tta_final;
};

// worker 私有临时 buffer（一次 alloc，round 间复用）。所有 pass 都从这里
// 借用 scratch 空间，不在 worker 回调内重新 resize（除非 n_cells 变了）。
struct ClimateWorkBuf {
    int n_cells = 0;
    std::vector<float> deltas;          // transp Phase 1 累加器
    std::vector<float> scratch_a;       // 后续 pass 复用
    std::vector<float> scratch_b;
    // ocean pass 内部 anomaly_inout buffer（temp_transport_anomaly per-round 累加器）。
    // ocean_water 写 water cells，ocean_land 读 water cells + 写 land cells。
    // Stage 2 期间它就是 TTA 字段在 round 内的状态——pass_b 也用这个传给 TTA 读取。
    std::vector<float> ocean_tta_inout;
};

#include "runtime_climate_passes_surface_feedback.inc"
// round-invariant 静态数据（neighbor_indices / donor_table / foliage_table），
// 在 bind_map_data 之后由 GDScript 调 set_static_knobs 注入一次。round 间复用。
struct ClimateRoundStaticKnobs {
    int                  n_cells = 0;
    std::vector<int32_t> neighbor_indices;   // size = n_cells * 6
    std::vector<float>   donor_table;        // 蒸腾贡献率（按 vegetation enum）
    std::vector<float>   foliage_table;      // pass_b 用（Stage 2）
    std::vector<float>   albedo_table;       // weather/climate 用（Stage 2）
    // sea_ice 的 water terrain LUT（OCEAN/COAST/LAKE/REEF/KELP/SEA_ICE 的 enum id）。
    // 它既不是 per-cell lane（没有 slot 可兜底）也不随 round 变，所以只能走 static
    // knobs。缺了它 sea_ice pass 会撞守卫静默跳过 —— 实测就是 starved=0x40 的成因。
    std::vector<uint8_t> water_terrain_ids;
};

// ─── Pure kernels（worker 线程与主线程 async round 共用，零 Godot API）────
//
// 定义在 runtime_climate_passes.cpp。调用方两处：
//   生产：world_ext_climate.cpp::_async_climate_round_worker_main / sync 降级路径
//   worker：runtime_climate_kernel.cpp::run_stage

bool _async_pass_a_kernel_pure(const ClimateInputBuf &in,
                                      ClimateOutputBuf &out);

bool _async_pass_b_kernel_pure(const ClimateInputBuf &in,
                                      const ClimateRoundStaticKnobs &knobs,
                                      ClimateOutputBuf &out);

bool _async_ocean_water_kernel_pure(const ClimateInputBuf &in,
                                           const ClimateRoundStaticKnobs &knobs,
                                           ClimateWorkBuf &work,
                                           ClimateOutputBuf &out);

bool _async_ocean_land_kernel_pure(const ClimateInputBuf &in,
                                          const ClimateRoundStaticKnobs &knobs,
                                          ClimateWorkBuf &work,
                                          ClimateOutputBuf &out);

bool _async_wind_air_kernel_pure(const ClimateInputBuf &in,
                                        const ClimateRoundStaticKnobs &knobs,
                                        ClimateOutputBuf &out);

bool _async_wind_surface_kernel_pure(const ClimateInputBuf &in,
                                            const ClimateRoundStaticKnobs &knobs,
                                            ClimateOutputBuf &out);

bool _async_sea_ice_kernel_pure(const ClimateInputBuf &in,
                                       const ClimateRoundStaticKnobs &knobs,
                                       ClimateOutputBuf &out);

bool _async_transp_kernel_pure(const ClimateInputBuf &in,
                                      const ClimateRoundStaticKnobs &knobs,
                                      ClimateWorkBuf &work,
                                      ClimateOutputBuf &out);

bool _async_finalizer_kernel_pure(const ClimateInputBuf &in,
                                         ClimateOutputBuf &out);

// 把生产 sync pass_a 真实用过的输入叠到一份完整的 round 输入上。
//
// 两份缓冲各有各的不完整，必须分层而不是二选一：
//   base（capture 侧，GDScript _build_async_kick_input）——9 个 pass 的 lane 都齐，但
//        它是 tick 前的快照，pass_a 那部分与生产当天真正读到的值不是一份。
//   prod（生产侧，run_climate_pass_a 里留存的 kin）——与生产 pass_a 逐位相同，但只有
//        pass_a 自己的 lane，pass_b→sea_ice 一条都没有。
// 只用 base，pass_a 立刻分叉；只用 prod，后 7 个 pass 全部因 lane 长度不足静默跳过。
//
// 所以这里显式列出"pass_a 权威"的 lane 与标量子集：prod 里非空的照抄，其余保留 base。
// 标量必须逐字段列，不能整个 scalars 结构覆盖 —— prod 只填了 pass_a 段，pb_/ow_/wa_/
// si_/transp_ 那些还是结构默认值，整体覆盖等于把后续 pass 的 knobs 全部清成默认。
void overlay_production_pass_a(ClimateInputBuf &base, const ClimateInputBuf &prod);

// 诊断（PK_CLIMATE_LANE_DIAG=1）：报告全部 production overlay 把 capture 快照的每条
// lane 挪动了多少格。capture 是在 tick 的某一刻读生产 slot 的，而生产各 pass 在一天
// 里的不同时点消费同一批 slot，中间会被前面的 pass 改写；所以被 overlay 挪动很多的
// lane，说明它的 capture 值本来就是陈旧的。这件事的意义不止于这条 lane 自己：同一个
// pass 读的**其它** lane 按同样道理也是陈旧的，只是只有带记录点的那些被纠正了。
// 两者的差集就是"还缺哪些消费点记录"的清单。
bool round_input_lane_diag_enabled();
void report_round_input_lane_delta(const ClimateInputBuf &before,
                                   const ClimateInputBuf &after,
                                   int64_t day);

// 把生产其余 6 个 sync pass 记录下来的标量段叠到 base.scalars 上。
// scalar_mask 是 passes_mask 的位；只叠真的被生产写过的段，没写过的保持 base ——
// 否则会把"生产这天没跑这个 pass"写成"用默认 knobs 跑过"。
void overlay_production_round_scalars(ClimateInputBuf &base,
                                     const ClimateRoundScalars &prod,
                                     int scalar_mask);

#include "runtime_climate_passes_round_inputs.inc"
#include "runtime_climate_passes_thermal_inputs.inc"
#include "runtime_climate_passes_weather_field.inc"
#include "runtime_climate_passes_field_commit.inc"
#include "runtime_climate_passes_hydrology.inc"

struct WeatherFieldInput;

// [begin, end) 逐 cell 独立：只写 out_*[i] / conv_inhib[i] / 过渡三条[i]，没有标量
// 累加器。staged 路径的 out_* 与 prev_* 是不同 buffer，所以可以任意并行切分。
// direct 路径 out_convergence 与 prev_convergence 同一个 buffer 且要读邻居，
// 调用方必须串行跑整段。
void weather_field_solve_pure(const WeatherFieldKnobs &knobs,
                              const WeatherFieldLanes &lanes,
                              const WeatherFieldState &state,
                              int begin,
                              int end);

// 邻域几何缓存的重建（每轮一次）。dx/dy/invd 三个数组长度必须是 n_cells * 6。
// invd 在 nb < 0 或 dl2 <= 1e-4 处写 0 作哨兵，消费方据此跳过。
void weather_field_geometry_cache_pure(int n_cells,
                                       const int32_t *neighbor_indices,
                                       const float *pos_x,
                                       const float *pos_y,
                                       float wrap_width_x,
                                       float *geom_dx,
                                       float *geom_dy,
                                       float *geom_invd);

// 逐 pass 耗时（微秒）。索引与 passes_mask 的 bit 位一致：
// 0 pass_a / 1 pass_b / 2 ocean_water / 3 ocean_land / 4 wind_air /
// 5 wind_surface / 6 sea_ice / 7 transp / 8 finalizer。
struct ClimateRoundPassTiming {
    int64_t pass_us[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
    // 实际执行过的 pass（bit 位同上）。pass 被 mask 关掉、或输入 lane 长度不足时都会
    // 被跳过，而跳过是静默的：out 里对应字段留空，调用方的 scatter 只做长度检查就成了
    // no-op。缺了这个回报，"worker 少跑了半个 round"和"算法分叉"在分叉矩阵里长得一样。
    int passes_ran = 0;
    // 被 mask 启用但因输入 lane 不完整而跳过的 pass。非 0 即"输入边界不完整"，
    // 与算法分叉是两类问题，必须分开报。
    int passes_starved = 0;
};

// 按 in.scalars.passes_mask 串联跑 9 个 pass，并在 pass 之间做 in←out 接力。
// in 是 in/out（接力目标），调用方须传私有副本。timing 可为 nullptr。
bool run_climate_round_passes(ClimateInputBuf &in,
                              const ClimateRoundStaticKnobs &knobs,
                              ClimateWorkBuf &work,
                              ClimateOutputBuf &out,
                              ClimateRoundPassTiming *timing = nullptr);

} // namespace pk_async_climate
} // namespace pk

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

// ─── albedo pass（stage 8）─────────────────────────────────────────────
//
// 生产侧 albedo 不属于 climate round：它在 native daily graph 的 stage_b 段跑，
// 用自己的 stride（cp.weather_albedo_stride，默认 10 次 weather 调用一次）。所以它
// 不能挂在 passes_mask 上跟着 round 走，只能由生产把"这一天到底跑没跑、用的什么
// 标量"如实记录下来，随 reference 一起发布给 worker。
//
// 它是 temp_arr 在一个仿真日内的最后一个写者（round 末尾 wind_surface/finalizer 之后
// 再叠一层反照率反馈）。worker 少了这一段，温度场就会在生产跑 albedo 的那些天单方面
// 落后一个 delta —— 这正是 S2 分叉矩阵里 temperature 被标成 CLIMATE_FEEDBACK 分叉的
// 真实原因（parity 的 stage 标签记的是"日内最后写者"，而写 temp 的是 albedo 段）。
struct ClimateAlbedoKnobs {
    // false = 这一天生产没跑 albedo，worker 必须也不跑。
    bool  ran = false;
    float reference_albedo = 0.0f;
    float temp_gain = 0.0f;
    float snow_cover_albedo = 0.75f;
    // CoverType.CV.SNOW = 1 / CV.GLACIER = 2（cover_type.gd）。
    uint8_t cover_snow_id = 1;
    uint8_t cover_glacier_id = 2;
};

// ─── climate_feedback pass（stage 10）──────────────────────────────────
//
// 与 albedo 同理，它也不在 climate round 里：跑在 native daily graph 的 stage_b 段、
// 用 cp.weather_feedback_stride 自己的节拍。所以同样由生产如实记录"这一天跑没跑、
// 用的什么标量"，随 reference 一起发布。
//
// 它写三个场：base_moisture / soil_moisture（都不是 worker store 的成员，worker 侧
// 只能用 scratch 承接，输出丢弃）和 vegetation_growth_pressure（是 store 成员，
// 必须写 worker 自己的那一份，否则 parity 就退化成"抄一遍生产的结果"）。
struct ClimateFeedbackKnobs {
    // false = 这一天生产没跑 feedback，worker 必须也不跑。
    bool  ran = false;
    float soil_gain = 0.0f;
    float veg_gain = 0.0f;
    float scale = 1.0f;
    float per_day_clamp = 0.0f;
    float ocean_drift_gain = 0.0f;
    // knobs["weather_to_base_moisture_gain"]，缺省 0 = 关闭这条反馈。
    float base_moisture_gain = 0.0f;
    bool  write_weather_veg_pressure = true;
    // weather 枚举 id。生产从 knobs 逐个取，缺一个就整段拒跑，所以这里没有默认值
    // 语义 —— -1 只是"没被记录过"，与任何真实 weather_type 都不相等。
    int32_t wt_rain_id = -1;
    int32_t wt_storm_id = -1;
    int32_t wt_monsoon_id = -1;
    int32_t wt_blizzard_id = -1;
    int32_t wt_drought_id = -1;
    int32_t wt_heatwave_id = -1;
};

// 生产 feedback 当天真正读到的输入。
//
// 为什么不能用 environment 快照的同名 lane：feedback 跑在 stage_b 段，也就是 weather
// 之后；而快照是 tick 起始拍的。weather_type / weather_intensity 在这两个时刻之间正好
// 被 weather pass 整场重写过，用快照那份等于拿昨天的天气算今天的反馈。
struct ClimateFeedbackInput {
    ClimateFeedbackKnobs knobs;
    int n_cells = 0;
    std::vector<uint8_t> is_water;
    std::vector<uint8_t> weather_type;
    std::vector<float>   weather_intensity;
    std::vector<uint8_t> weather_field_init;
    std::vector<float>   temp_transport_anomaly;
    // 这两条是 in/out，但都不是 worker store 的成员：记录的是生产读到的初值。
    std::vector<float>   base_moisture;
    std::vector<float>   soil_moisture;
};

// ─── vegetation_dynamics pass（stage 9）────────────────────────────────
//
// 与 albedo / feedback 同类：不在 climate round 里，跑在 native daily graph 的
// stage_b 段，用自己的节拍。所以同样由生产如实记录"这一天跑没跑、用的什么标量与表"，
// 随 reference 一起发布。
//
// 它写的场里，worker store 有对应成员的是：plant_available_water、
// vegetation_growth_pressure、vegetation_vitality、vegetation_heat_stress、
// vegetation_drought_stress、vegetation_cold_stress、vegetation_growth_streak
// （= high_streak）、vegetation_drought_streak（= low_streak）。
// regen_score 只有 uint8 的 vegetation_succession_candidate 与之近似，没有 float
// 成员可承接，所以 worker 侧用 scratch（与 feedback 的 soil_moisture 同处理）。
struct VegetationDynamicsKnobs {
    // false = 这一天生产没跑 vegetation_dynamics，worker 必须也不跑。
    bool  ran = false;
    // knobs["day_scale"] 先 max(1.0) 过一遍再存，与生产一致。
    float scale = 1.0f;
    int32_t streak_days = 0;
    float vitality_change_rate = 0.0f;
    float compat_harshness = 1.0f;
    float low_threshold = 0.0f;
    float high_threshold = 1.0f;
    int32_t succession_degrade_days = 0;
    int32_t succession_upgrade_days = 0;
    int32_t n_wt = 0;
    int32_t wt_clear_id = 0;
    uint8_t veg_none_id = 0;
    float weather_penalty_scale = 1.0f;
    float plant_water_balance_weight = 0.0f;
    float plant_soil_buffer_weight = 0.0f;
    float plant_drought_penalty = 0.0f;
    float succession_min_compat_gain = 0.0f;
    float low_vitality_damping_threshold = 0.40f;
    int32_t succession_cooldown_days = 30;
    // 生产 GDScript 演替后处理用的"降级后 vitality 重置目标"（默认 0.75；升级用
    // 固定 0.7）。worker 自持演替时必须拿到同一个值，否则同一次演替后两侧 vitality
    // 会系统性分叉。
    float degrade_reset_target = 0.75f;
    // 只有 use_soa=true 的 stage_b 路径能开；关闭时 heat/drought/cold/regen 四条
    // in/out lane 允许为 nullptr。
    bool  stress_enabled = false;
    // = clamp(scale / vegetation_stress_memory_days, 0, 1)，生产算好再存，
    // 避免两侧各自做一次除法产生 ULP 差。
    float stress_blend = 0.0f;
    int32_t wt_blizzard_id = -1;
    int32_t wt_drought_id = -1;
    int32_t wt_heatwave_id = -1;
    // 表维度。n_veg 由 ideal_temp_table 长度决定；wt_pen_size 可以 > n_wt。
    int32_t n_veg = 0;
    int32_t wt_pen_size = 0;
};

// VEG-indexed / weather-indexed 查表。生产直接传 PackedArray 的 ptr()，零拷贝。
struct VegetationDynamicsTables {
    const float   *ideal_temp = nullptr;       // [n_veg]
    const float   *ideal_moist = nullptr;      // [n_veg]
    const float   *temp_tol = nullptr;         // [n_veg]
    const float   *moist_tol = nullptr;        // [n_veg]
    const float   *weather_penalty = nullptr;  // [wt_pen_size]
    const float   *resistance = nullptr;       // [n_veg * n_wt]
    const uint8_t *next_up = nullptr;          // [n_veg]
    const uint8_t *next_down = nullptr;        // [n_veg]（当前算法未读，保留对齐生产签名）
};

// per-cell in/out lane 指针。soil_moisture 与 vegetation_growth_pressure 允许为
// nullptr（生产 stage_b 里这两个 component 可能没绑），此时按 0 处理 / 不写。
struct VegetationDynamicsLanes {
    const uint8_t *is_water = nullptr;
    const uint8_t *terrain = nullptr;
    const uint8_t *landform = nullptr;
    const uint8_t *vegetation = nullptr;
    const float   *temp_30d = nullptr;
    const float   *moisture = nullptr;
    const float   *water_balance_30d = nullptr;
    const float   *soil_moisture = nullptr;
    const uint8_t *weather_type = nullptr;
    const float   *weather_intensity = nullptr;
    const uint8_t *weather_field_init = nullptr;
    float   *plant_available_water = nullptr;
    float   *vegetation_growth_pressure = nullptr;
    float   *vitality = nullptr;
    int32_t *low_streak = nullptr;
    int32_t *high_streak = nullptr;
    float   *heat_stress = nullptr;
    float   *drought_stress = nullptr;
    float   *cold_stress = nullptr;
    float   *regen_score = nullptr;
};

// 演替候选输出。cell idx 必须严格升序 —— 生产的并行变体按 task_idx 升序 merge
// 来维持这个契约，GDScript 后处理依赖它。
struct VegetationDynamicsEmit {
    std::vector<int32_t> indices;
    std::vector<uint8_t> to_veg;

    void merge_into(VegetationDynamicsEmit &dst) const {
        dst.indices.insert(dst.indices.end(), indices.begin(), indices.end());
        dst.to_veg.insert(dst.to_veg.end(), to_veg.begin(), to_veg.end());
    }
};

// 生产 vegetation_dynamics 当天真正读到的输入。
//
// 与 ClimateFeedbackInput 同一理由：stage 9 跑在 weather 之后，environment 快照那份
// weather_type / weather_intensity 是 tick 起始拍的，用它等于拿昨天的天气算今天的植被。
// terrain / landform / vegetation 三条也必须记录 —— vegetation 会被上一天的演替后处理
// （GDScript 侧）改写，而那条写入不在任何 climate stage 里。
struct VegetationDynamicsInput {
    VegetationDynamicsKnobs knobs;
    int n_cells = 0;
    std::vector<float>   ideal_temp;
    std::vector<float>   ideal_moist;
    std::vector<float>   temp_tol;
    std::vector<float>   moist_tol;
    std::vector<float>   weather_penalty;
    std::vector<float>   resistance;
    std::vector<uint8_t> next_up;
    std::vector<uint8_t> next_down;
    std::vector<uint8_t> is_water;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> landform;
    std::vector<uint8_t> vegetation;
    std::vector<float>   temp_30d;
    std::vector<float>   moisture;
    std::vector<float>   water_balance_30d;
    std::vector<float>   soil_moisture;
    std::vector<uint8_t> weather_type;
    std::vector<float>   weather_intensity;
    std::vector<uint8_t> weather_field_init;
    // regen_score 没有 worker store 成员可承接：记录生产读到的初值，worker 用 scratch。
    std::vector<float>   regen_score;
    // soil_moisture lane 在生产 stage_b 里可能没绑（SOIL_COMP == nullptr）。
    bool has_soil_moisture = false;
    bool has_growth_pressure = false;
};

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

// wind_air 的两样东西无法从 slot 快照里取，只能由生产那一侧在跑 pass 时记下来：
//   baseline —— GDScript 按 map 缓存的 _compute_temperature(lat, elev) 静态基线，
//               不是任何一条 slot，也不等于 temp_baseline_year；
//   traj_*  —— 物理风场派生的回溯轨迹表，带指纹校验，worker 重建不出同一份。
// 生产没命中轨迹表时 traj_* 为空，worker 一并走离散跳格分支。
struct WindAirInput {
    int                  n_cells = 0;
    std::vector<float>   baseline;
    std::vector<int32_t> traj_idx;   // 空 或 [n_cells * 3]
    std::vector<float>   traj_w;     // 空 或 [n_cells * 3]
    // 风场本身也要照抄。它是 slot 产物，但 physics 的解算是跨 tick 分片的，capture
    // 抓快照的时刻与生产 wind_air 真正读 slot 的时刻不在同一片上 —— 于是两边拿到
    // 的是同一个 tick 内风向略有旋转的两份值。差得极小，却足以让整条温度链条不
    // 逐位相等。
    std::vector<float>   wind_x;
    std::vector<float>   wind_y;
    std::vector<float>   wind_speed;
};

void overlay_production_wind_air(ClimateInputBuf &base, const WindAirInput &prod);

// pass_b 的海冰浓度 lane。生产从 map.sea_ice_frac_arr（MapData 镜像）取，它既不在
// slot 覆盖清单里，也不在 pass_a 留存的那份 kin 里，于是 worker 侧一直是空的。
// 空 lane 让 pass_b 的水域尾循环整段静默跳过 —— 而那是水格唯一的 LANOM 来源
// （主循环 `if (is_water) continue`）。后果是每个水格的 local anomaly 停在 0，
// wind_surface 合成出的 cell_temp 随之偏，temperature 因此成为分叉矩阵里第一个
// 红的字段。pass_b 的守卫清单不含这条 lane，所以它连 starve 都不会报。
struct ClimatePassBInput {
    int                n_cells = 0;
    std::vector<float> sea_ice_frac;
    // TTA 同理且更隐蔽：它根本不是 slot，而是
    // knobs["temp_transport_anomaly"] —— GDScript 从
    // map.temperature_transport_anomaly_arr 传入，而那份数组由**分片的**
    // ocean pass 逐片增量写（map_generator.gd:16651）。所以它与 oanom 一样不属于
    // worker：pass_b 的 d_coastal / d_evap 两项都读邻居的 TTA，读错就会让 LANOM 偏，
    // 进而沿 wind_surface → temperature 一路传下去。
    std::vector<float> temp_transport_anomaly;
};

void overlay_production_pass_b(ClimateInputBuf &base, const ClimatePassBInput &prod);

// ─── stage 0x40 SEA_ICE ───────────────────────────────────────────────────
//
// worker 的 _async_sea_ice_kernel_pure 是 2026-06-16 那版算法的抄本：单步推进
// `d_frac = clamp(rate) * dt_days`，solar_melt 用 prev_frac 算一次遮蔽。生产在
// 2026-06-28 换成了按日子步积分（n_sub = ceil(dt_days)，每步重算 solar_exposure
// 并在饱和时提前 break），worker 没跟上。dt_days == 1 时两者逐位等价，所以这个
// 漂移只在加速档下暴露 —— 正是最难在对拍里稳定复现的那一类。合成一个内核之后
// 这种"生产改了、抄本没改"的错位不再可能。
struct SeaIceKnobs {
    int   n_cells = 0;
    float k_freeze = 0.0f;
    float k_melt = 0.0f;
    float t_form = 0.0f;
    float t_melt = 0.0f;
    float contagion = 0.0f;
    float threshold = 0.0f;
    float hysteresis = 0.0f;
    float ice_delay = 0.0f;
    bool  enable_ocean_heat_transport = false;
    bool  solar_gate_enabled = false;
    float freeze_insol_low = 0.0f;
    float freeze_insol_high = 0.0f;
    float solar_melt_start = 0.0f;
    float solar_melt_gain = 0.0f;
    float min_thick_ice_solar_exposure = 0.32f;
    float daily_delta_cap = 0.070f;
    // 未 clamp 传入即可：内核自己按 [0, 0.20] / [0, 30] 收口，两边同一份收口逻辑。
    float edge_mix_rate = 0.035f;
    float dt_days = 1.0f;
    int   terrain_lake_id = -1;
    int   terrain_sea_ice_id = -1;
    int   terrain_ocean_id = -1;
};

struct SeaIceLanes {
    // 生产读的是 cell_terrain slot；翻转由调用方在拿到 emit 之后自己落，内核只读。
    const uint8_t *terrain = nullptr;
    const uint8_t *base_terrain = nullptr;
    // 注意不是 cell_temp slot：生产刻意从 GDScript 的 cell.temperature 打包传入，
    // 与 SoA cell_temp（ocean_land 之后的修正温度）不是同一个量。读错会多算冰。
    const float   *cell_temperature = nullptr;
    const float   *temp_transport_anomaly = nullptr;
    const float   *ocean_thermal_anomaly = nullptr;
    const float   *upwelling_strength = nullptr;
    const float   *insolation_now = nullptr;
    const uint8_t *water_terrain_ids = nullptr;
    int            water_terrain_ids_size = 0;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6

    // in/out
    float *sea_ice_frac = nullptr;
};

struct SeaIceEmit {
    std::vector<int32_t> flip_to_ice;
    std::vector<int32_t> flip_to_base;
    std::vector<uint8_t> flip_to_base_terrain;
    int water_count = 0;
    int flipped_count = 0;
};

// 复用的临时 buffer；worker 侧按 round 常驻，生产侧每次现开也无妨。
struct SeaIceScratch {
    std::vector<uint8_t> has_cold_neighbor;
    std::vector<float>   prev_sif;
};

void sea_ice_pure(const SeaIceKnobs &knobs,
                  const SeaIceLanes &lanes,
                  SeaIceScratch &scratch,
                  SeaIceEmit &emit);

// sea_ice 的温度 lane 同样不是 slot 产物（见 SeaIceLanes::cell_temperature）。
struct SeaIceInput {
    int                n_cells = 0;
    std::vector<float> cell_temperature;
    // 其余消费点 lane。capture 读的是 tick 某一刻的 slot，sea_ice 读的是
    // 当天自己那一拍；只记温度会让 worker 用陈旧的 upwelling / insolation /
    // oanom 去跑同一份内核。
    std::vector<float>   upwelling_strength;
    std::vector<float>   insolation_now;
    std::vector<float>   ocean_thermal_anomaly;
    std::vector<float>   temp_transport_anomaly;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> base_terrain;
    std::vector<float>   sea_ice_frac;
    std::vector<uint8_t> water_terrain_ids;
};

void overlay_production_sea_ice(ClimateInputBuf &base, const SeaIceInput &prod);

// ─── stage 0x20 WIND_SURFACE：oanom 的权威归属 ─────────────────────────────
//
// `cell_ocean_thermal_anomaly` 是本轮定位到的分叉链头，而它**不是**算法分歧：
//
//   - pass_a 末尾把 oanom / lanom 清零，开启新一日累加；
//   - 本该由 OCEAN_WATER / OCEAN_LAND 重新填，但生产的这两个 pass 跑在 climate
//     round 之外、且按 start_idx/end_idx 跨 tick 分片（`_publish_cadence` 实测
//     `prod_knobs` 恒为 0x72，ocean 两位一次都没置位）；
//   - 于是生产的 wind_surface 读到的是一份"跨日携带"的 oanom，而 worker 一次跑完
//     整个 round，自己的 pass_a 把它清成了 0。
//
// 结论：在 SHADOW 下 worker 不是 oanom 的权威 —— 生产的分片 ocean stage 才是。
// 所以照 WindAirInput 的同一个配方，把生产 wind_surface 真正读到的那份 oanom 记下
// 来，在 worker 的 pass_a 之后重新注入。lanom 不在此列：它由 pass_b 在 round 内
// 重新累加，worker 是它的权威。
struct WindSurfaceInput {
    int                n_cells = 0;
    std::vector<float> ocean_anomaly;
};

void overlay_production_wind_surface(ClimateInputBuf &base, const WindSurfaceInput &prod);

// ─── native daily finalizer ────────────────────────────────────────────────
//
// 生产的 run_native_daily_finalizer 顶上写着一条不能忽略的约束：GDScript 的
// float 是 64 位，`clampf` / `absf` 都在 double 里算，PackedFloat32 读出来会提升成
// double，只有存回时才收窄。要跟 GDScript 逐位相等，**每一个中间量都必须是
// double，只在写回那一步收窄**——注释原话是「float32 内核会在 TTA clamp 上偏
// ~1e-5，随后传进下一轮的 ocean / weather / hydrology」。
//
// worker 的 _async_finalizer_kernel_pure 全程用 float，正好踩中这条。它是温度链上
// 最后一处平行实现：wind_surface 出口两边已逐位相等，temperature 仍差 ~4e-4，就是
// 这里来的。合成一份 double 内核之后，"照着 GDScript 抄成 float32" 不再可能。
struct FinalizerKnobs {
    int    n_cells = 0;
    bool   temp_cap_enabled = true;
    double temp_cap = 0.15;
    double tta_cap = 0.12;
    // 起始值缺失时不做 cap（与生产的 has_* 判定一致）。
    bool   has_temp_start = false;
    bool   has_tta_start = false;
};

struct FinalizerLanes {
    const float   *temp_start = nullptr;   // has_temp_start 为真时必须非空
    const float   *tta_start = nullptr;    // has_tta_start 为真时必须非空
    const uint8_t *ema = nullptr;          // 可为 nullptr
    int            ema_size = 0;

    // in/out
    float *temp = nullptr;
    float *tta = nullptr;
    float *thermal = nullptr;              // 可为 nullptr = 这一轮不初始化 thermal

    // 纯输出，可为 nullptr。worker 要拿它们算 p95/p99，生产不需要。
    float *temp_deltas = nullptr;          // 容量 n_cells
    float *preclamp_temp_deltas = nullptr; // 容量 n_cells
};

struct FinalizerStats {
    double max_temp_delta = 0.0;
    double preclamp_max_temp_delta = 0.0;
    double max_transport_anomaly = 0.0;
    int    temp_delta_gt_005 = 0;
    int    temp_delta_gt_010 = 0;
    int    temp_delta_gt_020 = 0;
    int    temp_clamped = 0;
    int    tta_clamped = 0;
    int    thermal_init = 0;
};

void finalizer_pure(const FinalizerKnobs &knobs,
                    const FinalizerLanes &lanes,
                    FinalizerStats &stats);

// ─── OCEAN_WATER / OCEAN_LAND ──────────────────────────────────────────────
//
// 这两个 pass 之前是全 Climate 里最厚的一坨平行实现：生产侧
// run_ocean_{water,land}_pass 各有 scalar / simd / thread 三份，worker 侧
// _async_ocean_{water,land}_kernel_pure 又各抄一份，共八份。而且因为生产在对拍用的
// 60×40 上从不跑 ocean（`prod_knobs` 恒 0x72，两位从不置位），worker 那两份抄本是
// **零对拍覆盖**的 —— 谁都没验证过它们对不对。
//
// 偏偏 `ocean_thermal_anomaly` 是 wind_surface → temperature 那条链的链头。也就是说
// P7 让 Climate 转 ACTIVE 之后，worker 第一件事就要靠这两份从未验证的内核自产
// oanom。所以这里先把主循环合成一份，去掉"抄本各自漂移"这个风险面。
//
// 区间语义：生产按 start_idx/end_idx 跨 tick 分片，worker 整图一次跑完。内核接
// [start_idx, end_idx) 两种都能表达，不在内核里假设任何一种。
struct OceanWaterKnobs {
    int   n_cells = 0;
    int   start_idx = 0;
    int   end_idx = 0;
    int   advect_steps = 0;
    float heat_mix = 0.0f;
    float wrap_period_x = 0.0f;
    float tta_source_cap = 0.22f;          // 调用方负责先 clamp 到 [0, 0.5]
    float tta_blend_rate = 0.70f;          // [0, 1]
    float tta_zero_current_decay = 0.06f;  // [0, 1]
    // 生产取 knobs["cold_transport_{form,melt}_threshold"]；worker 之前错用了
    // sea_ice 的 si_t_form / si_t_melt —— 是两组不同的 knob，别再混。
    float cold_transport_form = 0.06f;
    float cold_transport_melt = 0.11f;
};

struct OceanWaterLanes {
    const uint8_t *is_water = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const float   *ocean_current_x = nullptr;
    const float   *ocean_current_y = nullptr;
    // 生产传 knobs["baseline_arr"] / ["temp_before_arr"]；worker 旧抄本擅自等同为
    // temp_baseline_year / temp，并在注释里自认是"假设"。wind_air 上同样的假设已经
    // 被证伪过一次，所以这里由调用方显式给，内核不猜。
    const float   *baseline = nullptr;
    const float   *temp_before = nullptr;
    const float   *sea_ice_frac = nullptr;
    const int32_t *neighbors = nullptr;

    float *ocean_anomaly = nullptr;  // in/out：water cell 覆盖写
    float *tta_inout = nullptr;      // in/out：生产的 anomaly_out
};

void ocean_water_pure(const OceanWaterKnobs &knobs, const OceanWaterLanes &lanes);

// 生产的 ocean_water 吃 knobs["baseline_arr"] / ["temp_before_arr"]，两者都是
// map_generator 当场算出来的派生量（baseline 在 EMA 未全初始化时走一条冷启动
// 重建路径，temp_before 是专门的 work buffer）。旧 worker 拄本把它们擅自等同为
// temp_baseline_year / temp 并在注释里自认是“假设”—— wind_air 上同样的假设已经被
// 证伪过一次。在消费点抽真值，才能让 worker 自产 oanom（而不是靠 overlay 借）。
struct OceanWaterInput {
    int                n_cells = 0;
    std::vector<float> baseline;
    std::vector<float> temp_before;
};

void overlay_production_ocean_water(ClimateInputBuf &base, const OceanWaterInput &prod);

struct OceanLandKnobs {
    int   n_cells = 0;
    int   start_idx = 0;
    int   end_idx = 0;
    float effective_leak = 0.0f;
    float wrap_period_x = 0.0f;
    float tta_source_cap = 0.22f;  // 调用方负责先 clamp
    float tta_blend_rate = 0.70f;
    float tta_decay_rate = 0.04f;
};

struct OceanLandLanes {
    const uint8_t *is_water = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const float   *ocean_current_x = nullptr;
    const float   *ocean_current_y = nullptr;
    const int32_t *neighbors = nullptr;

    // land cell 读 water 邻居的 anomaly（water pass 已 finalize），写自己的。
    // 两个集合不相交，所以同一个数组 in-place 安全。
    float *tta_inout = nullptr;
    float *ocean_anomaly = nullptr;  // in/out：land cell 累加
};

void ocean_land_pure(const OceanLandKnobs &knobs, const OceanLandLanes &lanes);

// albedo：逐 cell、无邻居、原地改温度。生产侧持有的是 Godot 的 PackedArray，worker
// 侧持有的是 std::vector，所以签名走裸指针 —— 两边都不必为了调用它先拷一份 buffer。
// temp 是 in/out。albedo_table 索引是 vegetation id，越界按 0 反照率处理（与生产一致）。
void albedo_apply_pure(const ClimateAlbedoKnobs &knobs,
                       const uint8_t *is_water,
                       const uint8_t *vegetation,
                       const uint8_t *cover,
                       const float *albedo_table,
                       int albedo_size,
                       float *temp,
                       int n_cells);

// climate_feedback：逐 cell + 6 邻居 gather，但只写自身的 BM / SOIL / VGP，所以
// [begin, end) 可以任意拆分并行（生产的 _thread 变体正是这么用的）。
//
// veg_growth_pressure 允许为 nullptr —— knobs.write_weather_veg_pressure 为假时生产
// 也不碰它。base_moisture / soil_moisture 是 in/out。
void climate_feedback_apply_pure(const ClimateFeedbackKnobs &knobs,
                                 const uint8_t *is_water,
                                 const uint8_t *weather_type,
                                 const float *weather_intensity,
                                 const uint8_t *weather_field_init,
                                 const int32_t *neighbor_indices,
                                 const float *temp_transport_anomaly,
                                 float *base_moisture,
                                 float *soil_moisture,
                                 float *veg_growth_pressure,
                                 int begin,
                                 int end);

// vegetation_dynamics：逐 cell 独立（只读表 + 自身 lane，只写自身 lane），所以
// [begin, end) 可以任意拆分并行；生产的 _thread 变体按 task_idx 升序 merge emit
// 来保持 cell idx 升序契约。
void vegetation_dynamics_apply_pure(const VegetationDynamicsKnobs &knobs,
                                    const VegetationDynamicsTables &tables,
                                    const VegetationDynamicsLanes &lanes,
                                    int begin,
                                    int end,
                                    VegetationDynamicsEmit &emit);

// ─── stage 11 WEATHER：synoptic 涡旋场 ψ 的整步推进 ─────────────────────────
//
// 全场一次、不可切片：半拉格朗日平移要读全场的 ψ_prev 快照，扩散也要读邻域的
// prev 值，按 [begin, end) 切会让后半段读到已被本轮改写的值。
struct SynopticAdvanceKnobs {
    float baroclinic = 0.40f;
    float damp = 0.90f;
    float diffuse = 0.05f;
    float seed_rate = 0.015f;
    float seed_amp = 0.42f;
    int   adv_cells = 3;
    // 播种哈希的 tick。同一 tick 必须给出同一批种子，所以它是输入而非内部计数。
    int   tick = 0;
    float cell_pos_scale = 1.0f;
    float wrap_width_x = 0.0f;
};

// psi / psi_prev 是调用方持有的跨 tick lane（生产是 DCWorldExt 成员，worker 是
// scratch）。两者都会被写：psi_prev 收本轮的整步快照，psi 收推进结果。
// temp_norm 必须是归一化温度（主循环用的 TR）。传实际量纲的 cell_temp 会让斜压
// 门的 smoothstep 恒为 1，ψ 随轮次指数饱和到 ±1 并铺满全场。
void synoptic_advance_pure(int n_cells,
                           const int32_t *neighbor_indices,
                           const float *pos_x,
                           const float *pos_y,
                           const float *wind_x,
                           const float *wind_y,
                           const float *temp_norm,
                           const SynopticAdvanceKnobs &knobs,
                           std::vector<float> &psi,
                           std::vector<float> &psi_prev);

// ─── stage 11 WEATHER：tropical cyclone 推进 + stamp（B8-2 自持）────────────
//
// 生产把它放在 DCWorldExt::_advance_and_stamp_cyclones（world_ext_weather.cpp），
// 在 weather field solve 的 start_idx==0 处调用一次；worker 现在也自持同一份状态与
// 同一段数学。为了让内核不依赖 godot::Vector2，条目里的向量拆成标量、位置拆成
// pos_x/pos_y 两条 lane —— 数学逐行照搬，不做任何"顺手优化"。
//
// 状态所有权：
//   * entries / next_stable_id 是跨天状态（可变长），生产在 DCWorldExt 成员里，
//     worker 在 kernel scratch 里，两者都通过 cyclone_state_encode/decode 走同一种
//     blob（capture 播种 + CLM2 持久化）。
//   * force_tag/visit_tag/force_x/y/lift 是当天派生 lane，由调用方持有。
//
// genesis（cyclone_wake_step 从前沿注入新气旋）仍留在主线程：它消费 WeatherFront
// 对象。本内核只负责已有气旋的推进、衰减与 stamp。
struct CycloneAdvanceKnobs {
    bool    enabled = false;
    float   dt_days = 1.0f;
    float   world_bounds_pos_y = 0.0f;
    float   world_bounds_size_y = 1.0f;
    float   wrap_width_x = 0.0f;
    int32_t max_radius_cells = 5;
};

struct CycloneEntry {
    uint64_t stable_id = 0;
    int64_t  key = 0;              // cell.q * 10000 + cell.r
    int32_t  cell_idx = -1;
    float    steering_x = 0.0f;
    float    steering_y = 0.0f;
    float    vec_x = 0.0f;
    float    vec_y = 0.0f;
    float    vec_init_x = 0.0f;
    float    vec_init_y = 0.0f;
    float    intensity = 0.0f;
    float    radius_cells = 2.0f;
    float    age_days = 0.0f;
    float    move_progress = 0.0f;
    int32_t  days_left = 0;        // compatibility projection
    int32_t  init_days = 0;
};

struct CycloneLanes {
    const int32_t *neighbors = nullptr;   // [n_cells * 6]
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    // 规范纬度（cell_lat_norm，0..1，赤道=0.5）。可空。
    //
    // 为什么不能只用 pos_y / world_bounds：`_world_bounds` 是世界矩形，而
    // cell_pos_y 是格子局部世界坐标。两者尺度并不一致（例：50x48 地图上
    // water_ny ∈ [0.026,0.068]），按 world bounds 归一化得到的"纬度"会整体贴边，
    // 纬度带过滤器于是恒不命中。lat_norm 是 temp_baseline 用的同一条几何量，
    // 也是"纬度"的唯一规范来源；空指针时退回 world-y 公式（对拍/单测用）。
    const float   *lat_norm = nullptr;
    const uint8_t *terrain = nullptr;
    const float   *temp = nullptr;
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const float   *vapor = nullptr;
    const float   *instability = nullptr;
    const float   *convergence = nullptr;
};

struct CycloneStamp {
    uint32_t *force_tag = nullptr;   // [n_cells]
    uint32_t *visit_tag = nullptr;   // [n_cells]
    float    *force_x = nullptr;     // [n_cells]
    float    *force_y = nullptr;     // [n_cells]
    float    *lift = nullptr;        // [n_cells]
    uint32_t force_generation = 1u;
    uint32_t visit_generation = 1u;
};

struct CycloneStats {
    int32_t touched_cells = 0;
    int32_t decayed = 0;
    int32_t alive = 0;
    // 推进前后的最大 intensity：用来区分"出生即死"是衰减项太狠（温度/势能
    // 项）还是 evict 条件（<0.075 / age>32）本身不对。
    float   entry_intensity_max_before = 0.0f;
    float   entry_intensity_max_after = 0.0f;
};

// genesis（出生）：生产版消费 WeatherFront 对象（type==STORM && intensity>=0.8 +
// 前沿 center/velocity），而前沿由 C++-only 的 summary pass 产出、ACTIVE 下主线程
// 天气被抑制时根本不存在。共享内核因此改成**基于格子状态**的等价判据：
//   * 前沿等价物 = 当天 weather_intensity >= intensity_gate(0.8) 的格子。
//     注意不能要求 weather_type == STORM：field solve 只有在已有 cyclone stamp
//     （cyclone_lift >= 0.58）时才把 type 写成 STORM，拿它当出生条件就是闭锁
//     （new storm 永远生不出来）。require_storm_type 只为复现旧闭锁做 A/B。
//     而 front 的 intensity 本来就从这条 intensity lane 派生，所以两者同源。
//   * 前沿 velocity 等价物 = 该格当天风场（前沿本来就随风移动）；
//   * 前沿 center → 格子的 world→qr 反查不需要了：候选格自己就是注入点；
//   * 唯一键用 cell_idx（生产用 q*10000+r，只用于"同格覆盖"，在 worker 内等价）。
// 其余阈值（水陆、温度、降水、云量、对流/辐合、风切变、纬度带、容量、每次出生数）
// 与生产 native-entity 路径逐条一致；纬度带用规范 lat_norm（生产用的
// world-y/world_bounds 在小地图上是退化量，见 CycloneLanes::lat_norm 注释）。
struct CycloneGenesisKnobs {
    bool    enabled = false;
    int32_t storm_type_id = -1;
    int32_t capacity = 24;
    int32_t births_per_commit = 2;
    float   min_temp = 0.58f;
    float   min_instability = 0.40f;
    float   max_shear = 0.42f;
    float   min_lat = 0.06f;
    float   max_lat = 0.40f;
    float   world_bounds_pos_y = 0.0f;
    float   world_bounds_size_y = 1.0f;
    float   intensity_gate = 0.8f;
    float   precip_gate = 0.05f;
    float   cloud_gate = 0.22f;
    float   wake_days = 32.0f;
    // 生产 genesis 消费 WeatherFront.type（summary 段产物）。worker 里没有 front
    // 对象，等价判据是 field solve 的 intensity lane，所以默认不查 weather_type。
    // 置 true 时额外要求格子当前已被分类为 storm（只有已有 stamp 才可能成立），
    // 仅供 A/B 复现"旧闭锁奇偶"排查用。
    bool    require_storm_type = false;
};

struct CycloneGenesisLanes {
    const uint8_t *terrain = nullptr;          // [n_cells]
    const uint8_t *water_lut = nullptr;        // [256] water terrain ids
    const uint8_t *weather_type = nullptr;     // [n_cells]
    const float   *weather_intensity = nullptr;// [n_cells]
    const float   *temp = nullptr;             // [n_cells]
    const float   *precip = nullptr;           // [n_cells]
    const float   *cloud = nullptr;            // [n_cells]
    const float   *instability = nullptr;      // [n_cells]
    const float   *convergence = nullptr;      // [n_cells]
    const float   *wind_x = nullptr;           // [n_cells]
    const float   *wind_y = nullptr;           // [n_cells]
    const float   *pos_y = nullptr;            // [n_cells]
    const float   *lat_norm = nullptr;         // [n_cells]，可空，语义同 CycloneLanes
    const int32_t *neighbors = nullptr;        // [n_cells * 6]
    const uint8_t *is_water = nullptr;         // [n_cells]，可空（用 LUT 判定）
};

struct CycloneGenesisStats {
    int32_t injected = 0;
    int32_t replaced = 0;
    int32_t alive = 0;
    // 漏斗计数（诊断用）：每一格候选按顺序过闸，失败即停。soak 里
    // "injected=0" 时靠这四个数判断是水陆/纬度/物理量还是强度门槛挡住。
    int32_t cand_water = 0;     // 过水陆
    int32_t cand_lat = 0;       // 过纬度带
    int32_t cand_physical = 0;  // 过 temp/precip/cloud/instability
    int32_t cand_intensity = 0; // 过 intensity_gate
    int32_t cand_shear = 0;     // 过风切变（= 真正可出生）
    // 物理闸细分（只在纬度带内累加）：四个条件各自失败多少格。
    int32_t fail_temp = 0;
    int32_t fail_precip = 0;
    int32_t fail_cloud = 0;
    int32_t fail_instability = 0;
    // 纬度带内水格里当前 weather_type == storm_type_id 的个数。用来区分
    // "worker 分类根本没产出 STORM（气候不够强）"与"产出了但强度不够"。
    int32_t type_storm = 0;
    float   max_intensity = 0.0f;
    float   max_precip = 0.0f;
    float   max_cloud = 0.0f;
    float   max_instability = 0.0f;
    float   max_convergence = 0.0f;
};

void cyclone_genesis_pure(int n_cells,
                          const CycloneGenesisKnobs &knobs,
                          const CycloneGenesisLanes &lanes,
                          std::vector<CycloneEntry> &entries,
                          uint64_t &next_stable_id,
                          CycloneGenesisStats &stats);

void cyclone_advance_and_stamp_pure(int n_cells,
                                    const CycloneAdvanceKnobs &knobs,
                                    const CycloneLanes &lanes,
                                    std::vector<CycloneEntry> &entries,
                                    CycloneStamp &stamp,
                                    CycloneStats &stats);

// blob：u32 magic "CYC1" + u32 version + u32 count + u64 next_stable_id + count × record。
// 生产 capture、worker 冷启动播种与 CLM2 ABI 6 持久化共用同一份编码。
std::vector<uint8_t> cyclone_state_encode(const std::vector<CycloneEntry> &entries,
                                          uint64_t next_stable_id);
void cyclone_state_decode(const std::vector<uint8_t> &blob,
                          std::vector<CycloneEntry> &entries,
                          uint64_t &next_stable_id);

// ─── stage 11 WEATHER：field solve 主循环 ───────────────────────────────────
//
// 所有标量 knob 都在这里，热循环里不再有 knobs.get —— 原实现在循环内每 cell 各查
// 一次 thermal_monsoon_enabled 和 cyclone_storm_type_id（一次 Dictionary 查找 +
// 一次 Variant 转换 × n_cells），并且那两次查找是这个循环里唯一的 Godot 调用。
struct WeatherFieldKnobs {
    int   n_cells = 0;
    float climate_anomaly = 0.0f;
    bool  refresh_convergence = false;
    bool  apply_convergence_boost = true;
    // use_next_outputs：staged（native daily）路径写独立的 next buffer，direct 路径
    // 原地改 slot。它决定 weather_type 写 int32 还是 uint8，以及过渡三条与
    // weather_field_init 是否落盘 —— 不能由指针非空推断，两条路径的输出集合不同。
    bool  use_next_outputs = false;

    int   field_advect_steps = 3;
    float field_diffusion = 0.04f;
    float field_ocean_evap_gain = 0.55f;
    float field_precip_inertia = 0.40f;
    float field_precip_spatial_smooth = 0.30f;
    float field_cloud_inertia = 0.74f;
    float field_wet_terrain_precip_damping = 0.60f;
    float field_lake_precip_damping = 0.65f;
    float field_lake_evap_scale = 0.35f;
    float field_extreme_precip_soft_cap = 0.16f;
    float field_extreme_precip_softness = 0.20f;
    float field_land_evapotranspiration_gain = 0.85f;
    float field_ocean_precip_suppression = 0.95f;
    float field_frontogenesis_gain = 0.42f;
    float field_rain_shadow_drying = 0.35f;
    float field_advect_vapor = 0.95f;
    float field_advect_cloud = 0.94f;
    float field_rh_condense = 0.55f;
    float field_static_cond_w = 1.00f;
    float field_condense_rate = 0.45f;
    float field_lift_cond_gain = 0.80f;
    float field_conv_cond_gain = 1.00f;
    float field_thermal_conv_cond = 1.15f;
    float field_thermal_conv_precip = 0.30f;
    float field_autoconversion = 0.16f;
    float field_precip_base_frac = 0.08f;
    float field_lift_precip_gain = 0.45f;
    float field_conv_precip_gain = 1.95f;
    float field_oro_precip_gain = 0.30f;
    float field_stratiform_gain = 1.0f;
    float field_cool_season_vapor_floor = 0.0f;
    float field_cloud_reevap = 0.28f;

    float weather_cell_pos_scale = 1.0f;
    float weather_wrap_width_x = 0.0f;
    bool  cold_precip_as_blizzard = true;
    float snow_classification_margin = 0.03f;

    // Hadley/Ferrel omega 的纬度廓线。wb_size_y <= 0.001 时 omega_ny 退化为 0.5。
    float weather_lat_te_norm = 0.5f;
    float omega_ascent_gain = 0.40f;
    float world_bounds_pos_y = 0.0f;
    float world_bounds_size_y = 0.0f;

    // ψ 的耦合项（ψ 自身的演化 knob 在 SynopticAdvanceKnobs）。
    float syn_supp = 0.75f;
    float syn_enh = 0.45f;
    float syn_front_force = 0.55f;
    float syn_front_enh = 0.70f;
    float syn_base_lift = 1.55f;

    bool  weather_transition_enabled = false;
    float weather_transition_alpha_rate = 1.0f;
    float weather_transition_dt_days = 1.0f;

    // 原本在热循环里查 knobs 的两个。
    bool    thermal_monsoon_enabled = false;
    uint8_t cyclone_storm_type_id = 2;
};

// per-cell in/out lane。read lane 是 tick 起始快照或 slot，write lane 视
// use_next_outputs 指向 next buffer 或 slot 本身。允许为 nullptr 的：
//   river_q30 / soil_moisture / vitality / sea_ice / prev_cloud_water /
//   temp_anomaly / snow_cover（对应 component 没绑时按默认值处理）
//   out_cloud_water / out_type_u8 / out_type_i32 / out_field_init /
//   out_prev_type / out_target_type / out_alpha（按路径二选一）
struct WeatherFieldLanes {
    const float   *temp_read = nullptr;        // TR
    const float   *moisture_read = nullptr;    // MR
    const float   *air_anomaly = nullptr;      // AA
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const uint8_t *terrain = nullptr;
    const uint8_t *has_river = nullptr;
    const float   *river_q30 = nullptr;
    const float   *elevation = nullptr;
    const uint8_t *vegetation = nullptr;
    const float   *soil_moisture = nullptr;
    const float   *vitality = nullptr;
    const float   *sea_ice = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const float   *temp_anomaly = nullptr;     // 分类用的温度距平（TANO）
    const float   *snow_cover = nullptr;
    const int32_t *neighbor_indices = nullptr;
    const float   *prev_vapor = nullptr;
    const float   *prev_precip = nullptr;
    const float   *prev_cloud_water = nullptr;
    const float   *temp_transport_anomaly = nullptr;  // TA
    const float   *prev_convergence = nullptr;
    const float   *prev_cloud = nullptr;

    float   *out_vapor = nullptr;
    float   *out_cloud = nullptr;
    float   *out_cloud_water = nullptr;
    float   *out_precip = nullptr;
    float   *out_instability = nullptr;
    float   *out_intensity = nullptr;
    float   *out_convergence = nullptr;
    uint8_t *out_type_u8 = nullptr;
    int32_t *out_type_i32 = nullptr;
    uint8_t *out_prev_type = nullptr;
    uint8_t *out_target_type = nullptr;
    float   *out_alpha = nullptr;
    uint8_t *out_field_init = nullptr;
};

// 跨 tick / 每轮预算的状态。这七组在 RuntimeClimateStore 里都没有成员：
//   - conv_inhib：真正的跨 tick 状态（对流抑制的双稳记忆），in/out。
//   - psi：ψ 场，由 synoptic_advance_pure 每轮推进，这里只读。
//   - cyclone_*：气旋实体每轮 stamp 出来的 per-cell 强迫，只读。
//   - monsoon_thermal：wind pass 留下的热力季风因子，只读。
//   - traj_*：半拉格朗日轨迹表，风场指纹命中才非空，只读。
//   - geom_*：邻域几何缓存，每轮 start_idx==0 重算，只读。
// 几何缓存与轨迹表是可重算的派生量（geometry_cache_pure 就地重建），其余必须随
// reference 记录初值，否则 worker 的第一天会从零起步而生产不是。
struct WeatherFieldState {
    float *conv_inhib = nullptr;               // in/out，可为 nullptr

    const float *psi = nullptr;                // 只读；nullptr = ψ 耦合关闭

    // 气旋强迫。tag[i] == generation 才算本轮被 stamp 过。
    const uint32_t *cyclone_tag = nullptr;
    int             cyclone_tag_count = 0;
    uint32_t        cyclone_generation = 0;
    const float    *cyclone_lift = nullptr;
    const float    *cyclone_x = nullptr;
    const float    *cyclone_y = nullptr;

    const float *monsoon_thermal = nullptr;
    int          monsoon_thermal_count = 0;

    const int32_t *traj_idx = nullptr;         // [n_cells * 3]
    const float   *traj_w = nullptr;           // [n_cells * 3]

    // 三条同时非空才算命中；缺任何一条都退回逐次重算的 _xy 变体（两路 bit-equal）。
    const float *geom_dx = nullptr;
    const float *geom_dy = nullptr;
    const float *geom_invd = nullptr;
};

// ─── stage 1 PASS_B ────────────────────────────────────────────────────────
//
// 生产 run_climate_pass_b 与 worker _async_pass_b_kernel_pure 曾是两份独立实现，
// 逐行比对只差一处：worker 多了一个 cover == GLACIER 时把 snow_cover 抬到 0.80 的
// 钳位。生产 pass_b 没有这一步（albedo pass 与 weather_distribute 有，大概是照它们
// 补的），于是 d_albedo → LANOM → t_eff → d_evap → moisture 整条链偏移，moisture
// 在分叉矩阵里挂着 0.78 的最大差。两份实现合成一个内核就是为了让这种"抄漏一行"
// 不再可能。
struct ClimatePassBKnobs {
    int    n_cells = 0;
    float  winter_boost = 0.0f;
    float  snow_cool = 0.0f;
    float  veg_cool = 0.0f;
    float  diurnal_amp = 0.0f;
    float  evap_gain = 0.0f;
    float  rs_threshold = 0.0f;
    float  rs_factor = 0.0f;
    int    rs_lookback = 0;
    double wrap_period_x = 0.0;
    float  t_freeze = 0.0f;
    float  coupling_gain = 0.0f;
    float  coast_leak = 0.0f;
    // 0 = 关闭海冰反照率→温度反馈尾循环。
    float  sea_ice_albedo_cooling = 0.0f;
    double season_phase = 0.0;
    float  snowpack_cover_low = 0.05f;
    float  snowpack_cover_full = 0.32f;
    int    foliage_size = 0;
};

struct ClimatePassBLanes {
    // temp 快照：pass_b 不写 cell_temp，改累加 local_thermal_anomaly，由
    // wind_surface 末端合成回温度。d_albedo / d_coastal / d_landform 都以这份
    // 快照为基准，所以它必须是写入发生【之前】的那一份。
    const float   *temp_snapshot = nullptr;
    const float   *snowpack = nullptr;
    const float   *elevation = nullptr;
    const float   *lat_norm = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const float   *insolation_dev = nullptr;
    const float   *temp_transport_anomaly = nullptr;
    const uint8_t *is_water = nullptr;
    const uint8_t *landform = nullptr;
    const uint8_t *vegetation = nullptr;
    // 可为 nullptr：此时跳过海冰反照率尾循环。
    const float   *sea_ice_frac = nullptr;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6
    const float   *foliage_table = nullptr;      // size = knobs.foliage_size

    // in/out
    float *local_thermal_anomaly = nullptr;
    float *moisture = nullptr;
};

// 整图一次调用：跳过水域跑主循环，再跑海冰尾循环。
void climate_pass_b_pure(const ClimatePassBKnobs &knobs,
                         const ClimatePassBLanes &lanes);

// 分块驱动，供生产 _thread / _simd 变体按预筛 land_idx 切分。雨影段沿风向逐步回溯
// 上风格（rs_lookback 步），只读邻居，逐 cell 独立，所以可安全并行。
void climate_pass_b_land_range_pure(const ClimatePassBKnobs &knobs,
                                    const ClimatePassBLanes &lanes,
                                    const int *land_idx,
                                    int begin, int end);

// 海冰反照率→水域 LANOM 尾循环。必须在主循环全部写完之后跑。
void climate_pass_b_sea_ice_tail_pure(const ClimatePassBKnobs &knobs,
                                      const ClimatePassBLanes &lanes);

// ─── stage 4 WIND_AIR / stage 5 WIND_SURFACE ──────────────────────────────
//
// 这两个 pass 是 climate round 里温度链条的收尾：wind_air 算出 air-mass
// anomaly，wind_surface 把 baseline + transport(ocean + air) + local anomaly
// 合成回 cell_temp——它是 round 内 cell_temp 的唯一写者。
//
// 它们此前各有两份实现。wind_surface 的两份主循环恰好逐位相同（纯属运气），
// wind_air 的两份不同：
//   1. 生产在风场轨迹表命中时用三点重心插值取上游温度，worker 那份只有离散
//      跳格分支，永远走 fallback；
//   2. 生产对 temp_self / temp_up 各有 isfinite 兜底回 baseline，worker 那份
//      直接取原值；
//   3. 生产的 baseline_arr 是 GDScript 传进来的 _compute_temperature(lat, elev)
//      静态基线，worker 那份读的是 temp_baseline_year。
// 三条叠起来让 air_anomaly 偏，wind_surface 再把偏差合成进 cell_temp，于是
// temperature 成为分叉矩阵里第一个红的字段。合成一个内核就是让这三条不可能
// 再各自漂移。
struct WindAirKnobs {
    int   n_cells = 0;
    int   advect_steps = 0;
    float heat_mix = 0.0f;
    float wrap_period_x = 0.0f;
};

struct WindAirLanes {
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    // 生产的 TB：read_temp_from_slot 时是 cell_temp slot，否则是 temp_before_arr。
    // round 内只有 wind_surface 写 cell_temp，且它在 wind_air 之后，所以两者同值。
    const float   *temp_before = nullptr;
    // 生产的 baseline_arr = _compute_temperature(lat_norm, elevation)，按 map 缓存。
    const float   *baseline = nullptr;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6
    // 轨迹表：命中时用三点重心插值取上游温度。两者同时非空才生效，否则走离散
    // 跳格。风场派生量且带指纹校验，worker 无法重建，必须照抄生产当天用过的。
    const int32_t *traj_idx = nullptr;           // [n_cells * 3]
    const float   *traj_w = nullptr;             // [n_cells * 3]

    float *air_anomaly = nullptr;                // 纯输出，逐 cell 先清零
};

// [start_idx, end_idx) 区间版；生产分片调用，worker 一次跑全图。
void wind_air_pure(const WindAirKnobs &knobs, const WindAirLanes &lanes,
                   int start_idx, int end_idx);

struct WindSurfaceKnobs {
    int   n_cells = 0;
    float air_leak = 0.0f;
    float wrap_period_x = 0.0f;
    float cold_transport_form = 0.06f;
    float cold_transport_melt = 0.11f;
};

struct WindSurfaceLanes {
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const uint8_t *is_water = nullptr;
    // 合成的三个来源。baseline 非有限时回退到 fallback_baseline。
    const float   *baseline = nullptr;
    const float   *fallback_baseline = nullptr;
    // 可为 nullptr：此时 ocean 项按 0 计（本 round 没跑 ocean pass）。
    const float   *ocean_anomaly = nullptr;
    const float   *local_anomaly = nullptr;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6
    // air anomaly 必须是 Jacobi 读：邻居读的是本 pass 之前的整套旧值。生产用
    // arr.duplicate() 做快照，调用方须保证 air_anomaly_in 与 out 不是同一块。
    const float   *air_anomaly_in = nullptr;

    float *air_anomaly_out = nullptr;
    float *temp_out = nullptr;
};

void wind_surface_pure(const WindSurfaceKnobs &knobs,
                       const WindSurfaceLanes &lanes,
                       int start_idx, int end_idx);

// ─── stage 11 中段：weather field commit ───────────────────────────────────
//
// 生产的 weather stage 是两步的：weather_advance 把结果解算进调用方给的 next
// buffer（use_next_outputs = true，weather_type 写 int32），随后 weather_commit
// 把 next 落到 slot，并在这一步才解析 display_type / prev_type / target_type /
// alpha / field_init / dirty / LUT。
//
// worker 此前硬编码 use_next_outputs = false，走的是同一个 solve 内核的 direct
// 分支——那条分支里 transition 三条与 field_init 由 solve 自己写。两边因此在同
// 一个 stage 上跑了不同分支，worker 侧 weather_target_type /
// weather_transition_alpha / precipitation / intensity / cloud 成片写出字面零。
// 把 commit 也提成共享内核，worker 才能跟生产走同一条 staged 路径。
struct WeatherCommitKnobs {
    int   n_cells = 0;
    bool  refresh_convergence = false;
    bool  weather_transition_enabled = false;
    // 均已 clamp：rate [0,1]，dt_days [0,30]。
    float transition_rate = 1.0f;
    float transition_dt_days = 1.0f;
    // LUT 槽位数，>= n_cells；lut 为 nullptr 时忽略。
    int   lut_slots = 0;
};

struct WeatherCommitLanes {
    // solve 写出的 next buffer（只读）
    const float   *next_vapor = nullptr;
    const float   *next_cloud = nullptr;
    // 可为 nullptr：此时按 next_cloud * 0.5 推断，与生产一致。
    const float   *next_cloud_water = nullptr;
    const float   *next_precip = nullptr;
    const float   *next_instability = nullptr;
    const float   *next_intensity = nullptr;
    const float   *next_convergence = nullptr;
    const int32_t *next_type = nullptr;
    // solve 之前的 vapor，用于水量收支误差
    const float   *prev_vapor = nullptr;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6

    // slot 侧 in/out：先被读作"上一 tick 的展示态"，再被覆写
    float   *intensity = nullptr;
    float   *cloud = nullptr;
    float   *cloud_water = nullptr;          // 可为 nullptr
    float   *precip = nullptr;
    float   *vapor = nullptr;
    float   *convergence = nullptr;
    float   *instability = nullptr;
    uint8_t *type = nullptr;
    uint8_t *prev_type = nullptr;            // transition 关时可为 nullptr
    uint8_t *target_type = nullptr;          // 同上
    float   *transition_alpha = nullptr;     // 同上
    uint8_t *field_init = nullptr;
    uint8_t *dirty = nullptr;

    // 纯输出，可为 nullptr
    uint8_t *lut = nullptr;                  // lut_slots * 4
    float   *convergence_deltas = nullptr;   // 容量 n_cells，按 dirty 计数紧凑写
};

struct WeatherCommitStats {
    int    dirty_count = 0;
    int    convergence_dirty_count = 0;
    double water_budget_error_sum = 0.0;   // 调用方自行除以 n_cells
};

// 整图一次调用：dirty 会向 6 邻居扩散，逐 cell 之间有写交叉，不切片。
void weather_commit_pure(const WeatherCommitKnobs &knobs,
                         const WeatherCommitLanes &lanes,
                         WeatherCommitStats &stats);

// ─── stage 11 后段：weather distribute ─────────────────────────────────────
//
// 它是 snow_cover / snowpack / cover 当天的最后一个写者，而 sea_ice 与 albedo 都读
// snow_cover。分叉矩阵曾把 snow_cover 挂在 SEA_ICE 上，于是这一个缺口在矩阵里长成了
// 三行"算法分叉"（snow_cover / sea_ice / temperature）。
struct WeatherDistributeKnobs {
    int   n_cells = 0;
    float snow_min_intensity = 0.0f;
    float snow_freeze_t = 0.0f;
    float snow_melt_t = 0.0f;
    float snow_intensity_snow = 0.0f;
    int   snow_accum_days_req = 0;
    float flood_heavy_int = 0.0f;
    float flood_heavy_pre = 0.0f;
    float flood_low_int = 0.0f;
    float flood_low_elev = 0.0f;
    float flood_low_moist = 0.0f;
    int   wt_clear = 0;
    int   cv_snow = 0;
    int   cv_none = 0;
    int   cv_flooding = 0;
    float snowpack_accum_gain = 0.10f;
    float snowpack_melt_temp_gain = 0.22f;
    float snowpack_melt_sun_gain = 0.12f;
    float snowpack_cover_low = 0.05f;
    float snowpack_cover_full = 0.32f;
    // threshold = 0 关闭气候态物理雪线 floor。
    float snowline_temp_threshold = 0.24f;
    float snowline_band = 0.22f;
    float weather_temp_anomaly_cap = 0.025f;
    bool  direct_moisture_enabled = false;
    // 按 WeatherType 枚举索引的四张 8 项剖面表。
    float   temp_delta[8]{};
    float   moist_delta[8]{};
    uint8_t can_form_snow[8]{};
    uint8_t can_form_flood[8]{};
};

struct WeatherDistributeLanes {
    // 读写
    float   *temp = nullptr;
    float   *moisture = nullptr;              // 仅 direct_moisture_enabled 时写
    float   *snow_cover = nullptr;
    float   *snowpack = nullptr;
    float   *water_balance_30d = nullptr;
    float   *soil_moisture = nullptr;
    uint8_t *cover = nullptr;
    // 只读
    const float   *heat = nullptr;
    const float   *elevation = nullptr;
    const uint8_t *landform = nullptr;
    const uint8_t *terrain = nullptr;
    const float   *weather_intensity = nullptr;
    const float   *weather_precip = nullptr;
    const uint8_t *weather_type = nullptr;
    const uint8_t *weather_field_init = nullptr;
};

// 积雪连续天数与被雪覆盖前的 cover。两条都是 in/out 的跨 tick 状态，生产侧由
// GDScript 持有并经 knobs 往返，所以不在任何 slot 里，也不是 store 成员。
struct WeatherDistributeState {
    int32_t *accumulated_snow_days = nullptr;
    int32_t *pre_snow_cover = nullptr;
};

struct WeatherDistributeEmit {
    std::vector<int32_t> changed_cells;
    bool cover_dirty = false;
};

// 逐 cell 独立（只写 lanes.*[i] 与 state.*[i]），但 emit.changed_cells 的追加顺序
// 必须是升序 cell —— 下游把它当有序集合用。所以不暴露 range 版本。
void weather_distribute_pure(const WeatherDistributeKnobs &knobs,
                             const WeatherDistributeLanes &lanes,
                             const WeatherDistributeState &state,
                             WeatherDistributeEmit &emit);

// 生产 weather distribute 当天真正读到的输入，供 worker 对拍。
struct WeatherDistributeInput {
    WeatherDistributeKnobs knobs;
    int  n_cells = 0;
    bool ran = false;

    std::vector<float>   heat;
    std::vector<float>   elevation;
    std::vector<uint8_t> landform;
    std::vector<uint8_t> terrain;
    std::vector<float>   weather_intensity;
    std::vector<float>   weather_precip;
    std::vector<uint8_t> weather_type;
    std::vector<uint8_t> weather_field_init;
    // 没有 store 成员承接的 in/out：cover 与两条积雪计数。记初值、worker 用 scratch。
    std::vector<uint8_t> cover;
    std::vector<int32_t> accumulated_snow_days;
    std::vector<int32_t> pre_snow_cover;
    std::vector<float>   soil_moisture;
    // 两条积雪计数由谁跨天持有。
    //
    // SHADOW（record_production_* 填这份输入）留 false：那时生产是权威写者，
    // worker 每天跟着它播种，才是在对拍同一条状态链；自持会让两边从第一天就
    // 各走一条积雪账，parity 把它报成算法分叉。
    //
    // ACTIVE（capture 填这份输入）置 true：这两条没有 SoA 镜像（HexCell 的 AoS
    // 字段，不在 component_schema 里），既不在 environment 快照里也不经回灌回到
    // MapData，而生产 distribute 正是被抑制的那一方 —— 它那份缓存不再推进，
    // 每天拿它播种会让 snow_accum_days_req 永远攒不满。
    bool own_snow_state = false;
};

// ─── stage 12 RUNTIME_HYDROLOGY ────────────────────────────────────────────
//
// 标量原样带过来，派生系数（*_eff / *_alpha）由内核自己按 dt_days 算：原先生产侧
// 算一份、worker 侧再算一份，就等于把同一个公式写两遍，哪天改了一个忘了另一个就
// 是一次静默分叉。
struct HydrologyKnobs {
    int   n_cells = 0;
    float precip_scale = 1.0f;
    float snowmelt_scale = 0.55f;
    float soil_capacity = 0.75f;
    float infiltration_rate = 0.52f;
    float quickflow_fraction = 0.36f;
    float baseflow_recession = 0.035f;
    float channel_release = 0.62f;
    float lake_release = 0.18f;
    float discharge_ema = 0.08f;
    float bank_moisture_gain = 0.035f;
    float river_moisture_floor = 0.66f;
    float riparian_moisture_floor = 0.38f;
    float river_evap_gain = 0.12f;
    float moisture_response_rate = 0.08f;
    float flood_threshold = 2.2f;
    float snowpack_melt_temp_gain = 0.22f;
    float snowpack_melt_sun_gain = 0.12f;
    float plant_water_balance_weight = 0.35f;
    float plant_soil_buffer_weight = 0.25f;
    float plant_drought_penalty = 0.65f;
    float dt_days = 1.0f;
};

struct HydrologyLanes {
    // 只读
    const int32_t *hydro_parent = nullptr;      // HP，排水 DAG 的父格
    const uint8_t *has_river = nullptr;         // HAS_RIV
    const uint8_t *terrain = nullptr;           // TERR
    const uint8_t *landform = nullptr;          // LF
    const uint8_t *vegetation = nullptr;        // VEG
    const uint8_t *cover = nullptr;             // COV
    const float   *elevation = nullptr;         // ELEV
    const float   *precip = nullptr;            // PREC
    const float   *intensity = nullptr;         // INTEN
    const uint8_t *weather_type = nullptr;      // WTYPE
    const float   *temp = nullptr;              // TEMP
    const float   *heat = nullptr;              // HEAT
    const float   *snowpack = nullptr;          // SNOWP，本 pass 只读不写
    const float   *base_moisture = nullptr;     // BASE_M
    const uint8_t *is_water = nullptr;          // IS_WATER
    const float   *vitality = nullptr;          // VITAL
    const uint8_t *canal_mask = nullptr;        // CANAL_MASK，6 方向边掩码
    // nullptr 时整个运河段跳过并清空编译缓存（与生产 has_neighbor_indices 一致）。
    const int32_t *neighbor_indices = nullptr;  // NB，size = n_cells * 6

    // 读写（跨 tick 状态，属于 RuntimeClimateStore 的成员）
    float *moisture = nullptr;                  // MOIST
    float *soil_moisture = nullptr;             // SOIL
    float *water_balance_30d = nullptr;         // WB30
    float *plant_water = nullptr;               // PLANT_WATER
    float *discharge = nullptr;                 // Q
    float *discharge_30d = nullptr;             // Q30
    float *river_storage = nullptr;             // STORAGE
    float *groundwater = nullptr;               // GW
    float *runoff = nullptr;                    // RUNOFF
    float *canal_water = nullptr;               // CANAL_WATER
};

// 运河编译态。原先是 DCWorldExt 的五个成员，worker 拿不到，所以整组抬成显式参数：
// 主线程传自己那份，worker 传自己那份，各自按 topology_generation 失效。
struct HydrologyCanalState {
    uint64_t topology_generation = 0;
    uint64_t compiled_generation = ~0ull;
    int32_t  compiled_cell_count = -1;
    std::vector<int32_t> cells;
    std::vector<uint8_t> source_kind;   // 0=无 1=咸水 2=淡水
    std::vector<float>   strength;
};

// 每日重置的临时缓冲。抬成参数只为省掉每天四次分配，语义上是纯局部量。
struct HydrologyScratch {
    std::vector<int32_t> child_count;
    std::vector<float>   incoming;
    std::vector<float>   moisture_target;
    std::vector<int32_t> queue;
};

struct HydrologyStats {
    double water_in_total = 0.0;
    double outlet_total = 0.0;
    int   runoff_source_cells = 0;
    int   river_cells_processed = 0;
    int   riparian_neighbor_touches = 0;
    int   river_moisture_floor_touches = 0;
    int   riparian_moisture_floor_touches = 0;
    float river_moisture_max_delta = 0.0f;
    float riparian_moisture_max_delta = 0.0f;
    int   flood_candidate_count = 0;
    int   canal_cells_processed = 0;
    int   canal_edges_processed = 0;
    int   canal_freshwater_cells = 0;
    int   canal_saline_cells = 0;
    float q_max = 0.0f;
    float q_p95 = 0.0f;
};

// 整图一次调用，没有 [begin, end) 版本，这不是偷懒：
//   - 汇流是 Kahn 拓扑序（叶→出口），队列顺序即数据依赖，切不开；
//   - 孤儿格 flush 依赖汇流跑完后剩下的 child_count；
//   - 河岸与运河段都往邻格写 SOIL/WB30，分段就有写竞态；
//   - 运河传播是 max-heap 松弛，且淡水优先的平局规则依赖全局松弛顺序。
// 只有本地水平衡、moisture 收敛与 plant_available_water 三段是逐格独立的，单独切
// 出来并行收益不足以抵掉三次同步，所以整段串行。
void hydrology_pass_pure(const HydrologyKnobs &knobs,
                         const HydrologyLanes &lanes,
                         HydrologyCanalState &canal,
                         HydrologyScratch &scratch,
                         HydrologyStats &stats);

// 生产 stage 12 当天真正读到的输入，供 worker 对拍。与 weather 同理：hydrology 跑在
// weather 之后，environment 快照那份降水/天气类型是 tick 起始拍的。
struct HydrologyInput {
    HydrologyKnobs knobs;
    int  n_cells = 0;
    bool ran = false;
    bool has_neighbors = false;

    std::vector<uint8_t> has_river;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> landform;
    std::vector<uint8_t> vegetation;
    std::vector<uint8_t> cover;
    std::vector<float>   elevation;
    std::vector<float>   precip;
    std::vector<float>   intensity;
    std::vector<uint8_t> weather_type;
    std::vector<float>   temp;
    std::vector<float>   heat;
    std::vector<float>   snowpack;
    std::vector<float>   base_moisture;
    std::vector<uint8_t> is_water;
    std::vector<float>   vitality;
    std::vector<uint8_t> canal_mask;
    // soil_moisture 与 discharge_30d 都是 in/out 的累积量，却没有 RuntimeClimateStore
    // 成员可承接。记生产读到的初值，worker 用 scratch 接一下、输出丢弃。不记的
    // 后果很具体：Q30 从零起步 → 河岸增湿 bank_gain 偏小 → SOIL/WB30 整场偏移。
    std::vector<float>   soil_moisture;
    std::vector<float>   discharge_30d;
    // canal_water 同样是 in/out 且跨日存活。漏记它的后果比 Q30 更凶：worker 的
    // scratch 只在首次分配，之后带着自己那份独立累积往邻格灌水，几轮之后把 moisture
    // 与 plant_available_water 顶到饱和 1.0（生产侧同格是 0.2~0.36）。
    std::vector<float>   canal_water;
    // 运河拓扑代号。worker 侧的编译缓存按它失效，所以必须跟着输入一起过来。
    uint64_t canal_topology_generation = 0;
};

// 生产 stage 11 当天真正读到的输入。
//
// 与 ClimateFeedbackInput / VegetationDynamicsInput 同一理由：weather 跑在 round
// 末尾，environment 快照那份温度/风/湿度是 tick 起始拍的，用它等于拿昨天的场算
// 今天的天气。另外这里还要记那些跨 tick 状态的初值：worker 第一次跑 weather 时
// 若从零起步，ψ 与对流抑制都会与生产错开若干天才收敛，那会被记成算法分叉。
struct WeatherFieldInput {
    WeatherFieldKnobs knobs;
    SynopticAdvanceKnobs synoptic;
    int  n_cells = 0;
    bool ran = false;
    // ψ 是否参与：生产 weather_synoptic_enabled 为假时 PSI 是 nullptr。
    bool synoptic_enabled = false;

    // 读 lane。空 vector = 生产当天那条 lane 是 nullptr（component 没绑）。
    std::vector<float>   temp_read;
    std::vector<float>   moisture_read;
    std::vector<float>   air_anomaly;
    std::vector<float>   wind_x;
    std::vector<float>   wind_y;
    std::vector<float>   wind_speed;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> has_river;
    std::vector<float>   river_q30;
    std::vector<float>   elevation;
    std::vector<uint8_t> vegetation;
    std::vector<float>   soil_moisture;
    std::vector<float>   vitality;
    std::vector<float>   sea_ice;
    std::vector<float>   pos_x;
    std::vector<float>   pos_y;
    std::vector<float>   temp_anomaly;
    std::vector<float>   snow_cover;
    std::vector<float>   temp_transport_anomaly;

    // 跨 tick 状态的初值（生产读到的那一份）。worker 只在自己那份还没建立时用它
    // 播种，之后走自己的演化 —— 否则 parity 就退化成"把生产的状态抄一遍"。
    std::vector<float>    conv_inhib;
    // ψ 记的是生产在 solve 前刚推进完的那一帧（也就是 solve 实际读到的）。
    // B8-2 起 worker 自持 ψ：这一对 lane 只作为**冷启动/恢复后的播种值**，worker
    // 第一次见到齐长 lane 时把它拷进自己的 scratch，之后每个 weather 日用自己的
    // 风场与归一化温度推进（见 RuntimeClimateKernel::_synoptic_psi）。psi_prev
    // 只在播种时需要，用来给第一次推进一个正确的平流历史。
    std::vector<float>    psi;
    std::vector<float>    psi_prev;
    std::vector<uint32_t> cyclone_tag;
    uint32_t              cyclone_generation = 0;
    std::vector<float>    cyclone_lift;
    std::vector<float>    cyclone_x;
    std::vector<float>    cyclone_y;
    std::vector<float>    monsoon_thermal;
    // 轨迹表是风场的派生量且带指纹校验，worker 侧无法重建同一份，所以照抄生产当
    // 天用过的那张。生产没命中时为空，worker 也走逐次重算的分支。
    std::vector<int32_t>  traj_idx;
    std::vector<float>    traj_w;
    // 生产 cell_weather_field_init。worker 若从全零起步会按 moisture*0.15
    // 重做 spinup，而生产生成阶段通常已经把这张图标成已初始化 —— 那就是
    // vapor 全图偏 0.15 的来源。
    std::vector<uint8_t>  field_init;
    // conv_inhib 跨天由谁持有，与 WeatherDistributeInput::own_snow_state 同理。
    // SHADOW 留 false：生产是权威写者，worker 每天跟着它播种才是在对拍同一条
    // 状态链。ACTIVE 置 true：生产的对流抑制不再推进，每天拿它重置等于把这条
    // 记忆抹平，对流会一直从"无抑制"起步。
    bool own_field_state = false;
};

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

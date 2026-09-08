#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）

// MSVC 默认不定义 M_PI；必须在引入 <cmath> 之前打开 _USE_MATH_DEFINES。
// 双保险：仍未定义时手动兜底，避免某些编译器/PCH 顺序问题。
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>          // native world-gen 复刻：与 GDScript _init_noise 同一引擎噪声
#include <godot_cpp/classes/random_number_generator.hpp>  // native world-gen 复刻：与 GDScript _rng 同一引擎 PCG
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <functional>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
#  include <immintrin.h>
#endif


#include "world_ext_internal.h"

namespace pk {

using namespace godot;




Array DCWorldExt::get_native_fronts_snapshot() const {
    return _native_fronts_snapshot.duplicate();
}

Dictionary DCWorldExt::get_native_fronts_snapshot_packed() const {
    PackedFloat32Array center_x;
    PackedFloat32Array center_y;
    PackedFloat32Array intensity;
    PackedFloat32Array radius;
    PackedFloat32Array axis_x;
    PackedFloat32Array axis_y;
    PackedFloat32Array cloud_amount;
    PackedFloat32Array precip_amount;
    PackedInt32Array type;

    const int n = _native_fronts_snapshot.size();
    center_x.resize(n);
    center_y.resize(n);
    intensity.resize(n);
    radius.resize(n);
    axis_x.resize(n);
    axis_y.resize(n);
    cloud_amount.resize(n);
    precip_amount.resize(n);
    type.resize(n);

    int packed_count = 0;
    for (int i = 0; i < n; ++i) {
        if (Variant(_native_fronts_snapshot[i]).get_type() != Variant::DICTIONARY) {
            continue;
        }
        Dictionary f = _native_fronts_snapshot[i];
        Vector2 c = f.get("center", Vector2());
        Vector2 axis = f.get("axis", Vector2(1.0, 0.0));
        center_x.set(packed_count, c.x);
        center_y.set(packed_count, c.y);
        intensity.set(packed_count, float(f.get("intensity", 0.0)));
        radius.set(packed_count, float(f.get("radius", 0.0)));
        axis_x.set(packed_count, axis.x);
        axis_y.set(packed_count, axis.y);
        cloud_amount.set(packed_count, float(f.get("cloud_amount", 0.0)));
        precip_amount.set(packed_count, float(f.get("precip_amount", 0.0)));
        type.set(packed_count, int(f.get("type", 0)));
        ++packed_count;
    }
    center_x.resize(packed_count);
    center_y.resize(packed_count);
    intensity.resize(packed_count);
    radius.resize(packed_count);
    axis_x.resize(packed_count);
    axis_y.resize(packed_count);
    cloud_amount.resize(packed_count);
    precip_amount.resize(packed_count);
    type.resize(packed_count);

    Dictionary out;
    out["count"] = packed_count;
    out["source_count"] = n;
    out["center_x"] = center_x;
    out["center_y"] = center_y;
    out["intensity"] = intensity;
    out["radius"] = radius;
    out["axis_x"] = axis_x;
    out["axis_y"] = axis_y;
    out["cloud_amount"] = cloud_amount;
    out["precip_amount"] = precip_amount;
    out["type"] = type;
    return out;
}

// ─── 独立全场 ψ(synoptic eddy)推进 pass ──────────────────────────────────────
//
// 「让天气移动」架构改动：把 ψ 从切片化的 solve 热循环里抽出来，由本 pass 在每个
// weather 轮调用一次(全场、不切片)，推进 ψ 一整步。这样 ψ 的有效时间步=每轮(而非被
// 切片稀释)，且用「平滑引导流(风邻域平均)+纯取值半拉格朗日平移」保持空间连贯(修复多格
// 采样打散场的问题)。solve 循环只读 _wx_synoptic 做耦合 → ψ 移动 → 云/雨成片随风平移。
// 返回 elapsed_ms (≥0)；ψ 关闭返回 0；失败返回 -1.0。
//
// S3：数值实现已并入 pk_async_climate::synoptic_advance_pure，本 pass 只做 slot
// 取值与 knob 解析。注意它把 cell_temp slot 直接当斜压门的输入，而内核要求的是
// 归一化温度；solve pass 里的调用点传的是主循环的 TR。这条路径目前没有调用方
// （run_synoptic_advance_pass_native 全库无引用），真要启用得先接一条归一化温度。
double DCWorldExt::run_synoptic_advance_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedVector2Array;
    using godot::PackedInt32Array;
    using godot::Vector2;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning("[DCWorldExt] run_synoptic_advance_pass: ", why);
    };
    if (!_bound) { diag("not _bound"); return -1.0; }

    const bool syn_enabled = knobs.has("weather_synoptic_enabled")
                                 ? bool(knobs["weather_synoptic_enabled"]) : true;
    if (!syn_enabled) return 0.0;

    const int sid_wind_x = component_id(StringName("cell_wind_x"));
    const int sid_wind_y = component_id(StringName("cell_wind_y"));
    const int sid_temp   = component_id(StringName("cell_temp"));
    if (sid_wind_x < 0 || sid_wind_y < 0 || sid_temp < 0) { diag("missing wind/temp slot"); return -1.0; }

    if (!knobs.has("n_cells") || !knobs.has("cell_pos") || !knobs.has("neighbor_indices")) {
        diag("knobs missing n_cells/cell_pos/neighbor_indices"); return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) return -1.0;
    PackedVector2Array cell_pos_arr = knobs["cell_pos"];
    PackedInt32Array   nb_arr       = knobs["neighbor_indices"];
    if (cell_pos_arr.size() != n_cells || nb_arr.size() < n_cells * 6) { diag("pos/nb size mismatch"); return -1.0; }

    const float syn_baroclinic = knobs.has("weather_synoptic_baroclinic") ? float(knobs["weather_synoptic_baroclinic"]) : 0.40f;
    // 默认值与 run_weather_field_solve_pass 的 ψ 段一致。合并前这里是 0.94/0.12/0.05，
    // 于是同一个 knob 缺省时两条路径给出不同的 ψ 演化。
    const float syn_damp       = knobs.has("weather_synoptic_damp")       ? float(knobs["weather_synoptic_damp"])       : 0.90f;
    const float syn_diffuse    = knobs.has("weather_synoptic_diffuse")    ? float(knobs["weather_synoptic_diffuse"])    : 0.05f;
    const float syn_seed_rate  = knobs.has("weather_synoptic_seed_rate")  ? float(knobs["weather_synoptic_seed_rate"])  : 0.015f;
    const float syn_seed_amp   = knobs.has("weather_synoptic_seed_amp")   ? float(knobs["weather_synoptic_seed_amp"])   : 0.42f;
    int         syn_adv_cells  = knobs.has("weather_synoptic_adv_cells")  ? int(knobs["weather_synoptic_adv_cells"])    : 3;
    if (syn_adv_cells < 0) syn_adv_cells = 0; else if (syn_adv_cells > 16) syn_adv_cells = 16;
    const int   syn_tick       = knobs.has("weather_solve_tick")          ? int(knobs["weather_solve_tick"])            : 0;
    float wrap_width_x = knobs.has("weather_wrap_width_x") ? float(knobs["weather_wrap_width_x"]) : 0.0f;
    if (wrap_width_x < 0.0f) wrap_width_x = 0.0f;
    float pos_scale = knobs.has("weather_cell_pos_scale") ? float(knobs["weather_cell_pos_scale"]) : 1.0f;
    if (pos_scale <= 0.001f) pos_scale = 1.0f;

    Slot &s_wx = _slots.write[sid_wind_x];
    Slot &s_wy = _slots.write[sid_wind_y];
    Slot &s_tp = _slots.write[sid_temp];
    if ((int)s_wx.arr_f32.size() != n_cells || (int)s_wy.arr_f32.size() != n_cells ||
        (int)s_tp.arr_f32.size() != n_cells) { diag("wind/temp slot size mismatch"); return -1.0; }
    const float   * const __restrict WX   = s_wx.arr_f32.ptr();
    const float   * const __restrict WY   = s_wy.arr_f32.ptr();
    const float   * const __restrict TEMP = s_tp.arr_f32.ptr();
    const Vector2 * const __restrict POS  = cell_pos_arr.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();

    if (_wf_pos_x.size() != (size_t)n_cells) {
        _wf_pos_x.assign((size_t)n_cells, 0.0f);
        _wf_pos_y.assign((size_t)n_cells, 0.0f);
    }
    for (int i = 0; i < n_cells; ++i) {
        _wf_pos_x[(size_t)i] = POS[i].x;
        _wf_pos_y[(size_t)i] = POS[i].y;
    }

    pk_async_climate::SynopticAdvanceKnobs syn;
    syn.baroclinic = syn_baroclinic;
    syn.damp = syn_damp;
    syn.diffuse = syn_diffuse;
    syn.seed_rate = syn_seed_rate;
    syn.seed_amp = syn_seed_amp;
    syn.adv_cells = syn_adv_cells;
    syn.tick = syn_tick;
    syn.cell_pos_scale = pos_scale;
    syn.wrap_width_x = wrap_width_x;

    auto t0 = std::chrono::high_resolution_clock::now();
    pk_async_climate::synoptic_advance_pure(
        n_cells, NB, _wf_pos_x.data(), _wf_pos_y.data(), WX, WY, TEMP, syn,
        _wx_synoptic, _wx_synoptic_prev);
    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.1 main pass ──────────────────────────────────────────────────────────
//
// Range sweep over [start_idx, end_idx). Writes 8 cell-level SoA component
// slots in place. Read-side vapor/precip uses the begin-slice snapshots, so
// multiple native slices can safely build one hidden round before commit().
double DCWorldExt::run_weather_field_solve_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedVector2Array;
    using godot::PackedByteArray;
    using godot::Vector2;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_field_solve_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve all 16 slot ids ONCE ───────────────────────────────────
    const int sid_temp        = component_id(StringName("cell_temp"));
    const int sid_moisture    = component_id(StringName("cell_moisture"));
    const int sid_air_anom    = component_id(StringName("cell_air_mass_temp_anomaly"));
    const int sid_wind_x      = component_id(StringName("cell_wind_x"));
    const int sid_wind_y      = component_id(StringName("cell_wind_y"));
    const int sid_wind_spd    = component_id(StringName("cell_wind_speed"));
    const int sid_terrain     = component_id(StringName("cell_terrain"));
    const int sid_has_river   = component_id(StringName("cell_has_river"));
    const int sid_river_q30   = component_id(StringName("cell_river_discharge_30d"));
    const int sid_elev        = component_id(StringName("cell_elevation"));
    const int sid_vegetation  = component_id(StringName("cell_vegetation"));
    const int sid_soil_moisture = component_id(StringName("cell_soil_moisture"));
    const int sid_veg_vitality = component_id(StringName("cell_vegetation_vitality"));
    const int sid_sea_ice     = component_id(StringName("cell_sea_ice_frac"));
    const int sid_w_vapor     = component_id(StringName("cell_weather_vapor"));
    const int sid_w_cloud     = component_id(StringName("cell_weather_cloud"));
    const int sid_w_precip    = component_id(StringName("cell_weather_precip"));
    const int sid_w_inst      = component_id(StringName("cell_weather_instability"));
    const int sid_w_intens    = component_id(StringName("cell_weather_intensity"));
    const int sid_w_conv      = component_id(StringName("cell_weather_convergence"));
    const int sid_w_type      = component_id(StringName("cell_weather_type"));
    const int sid_w_prev_type = component_id(StringName("cell_weather_prev_type"));
    const int sid_w_target_type = component_id(StringName("cell_weather_target_type"));
    const int sid_w_transition_alpha = component_id(StringName("cell_weather_transition_alpha"));
    const int sid_w_finit     = component_id(StringName("cell_weather_field_init"));
    const bool weather_transition_enabled = bool(knobs.get("weather_transition_enabled", false));
    float weather_transition_alpha_rate = float(knobs.get("weather_transition_alpha_rate", 1.0));
    if (weather_transition_alpha_rate < 0.0f) weather_transition_alpha_rate = 0.0f;
    else if (weather_transition_alpha_rate > 1.0f) weather_transition_alpha_rate = 1.0f;
    // [dt-aware transition 2026-06-28] 过渡进度按"游戏天数"推进而非"求解次数"。旧实现 alpha 每次求解
    // 固定 +rate，与 dt 无关→加速档(dt≫1)每次求解推进 ~dt 天却仍只 +rate，需 ~4 次求解≈4·dt 天才完成过渡，
    // 致短暂强天气(STORM/FOG/MONSOON)永远累不满 alpha 被显示为 prev(CLEAR)。改为 alpha += rate·dt_days，
    // 并在目标切换时即把当前求解计入(alpha=rate·dt_days)，使 dt≥~1/rate 时即时切换；dt=1 时退化为原 ~3 次求解平滑。
    float weather_transition_dt_days = float(knobs.get("weather_transition_dt_days", 1.0));
    if (weather_transition_dt_days < 0.0f) weather_transition_dt_days = 0.0f;
    else if (weather_transition_dt_days > 30.0f) weather_transition_dt_days = 30.0f;
    if (sid_temp       < 0 || sid_moisture   < 0 || sid_air_anom    < 0 ||
        sid_wind_x     < 0 || sid_wind_y     < 0 || sid_wind_spd   < 0 ||
        sid_terrain    < 0 ||
        sid_has_river  < 0 || sid_elev       < 0 || sid_vegetation  < 0 ||
        sid_w_vapor    < 0 || sid_w_cloud    < 0 || sid_w_precip    < 0 ||
        sid_w_inst     < 0 || sid_w_intens   < 0 || sid_w_conv      < 0 ||
        sid_w_type     < 0 || sid_w_finit    < 0) {
        diag("missing slot id (some weather component not bound)");
        return -1.0;
    }
    if (weather_transition_enabled &&
        (sid_w_prev_type < 0 || sid_w_target_type < 0 || sid_w_transition_alpha < 0)) {
        diag("weather transition enabled but prev/target/alpha slots are missing");
        return -1.0;
    }

    // ─── Pull scalars + range from knobs ────────────────────────────────
    if (!knobs.has("start_idx")  || !knobs.has("end_idx")  ||
        !knobs.has("n_cells")    || !knobs.has("season_idx") ||
        !knobs.has("climate_anomaly") || !knobs.has("season_phase") ||
        !knobs.has("world_bounds_pos_y") || !knobs.has("world_bounds_size_y") ||
        !knobs.has("refresh_convergence")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int   start_idx       = int(knobs["start_idx"]);
    const int   end_idx         = int(knobs["end_idx"]);
    const int   n_cells         = int(knobs["n_cells"]);
    const int   season_idx      = int(knobs["season_idx"]);
    const float climate_anomaly = float(knobs["climate_anomaly"]);
    const float season_phase    = float(knobs["season_phase"]);
    // 去季节化(2026-06-20)/去纬度门：weather 分类不再消费 season_idx/season_phase/world_bounds（纬度回退
    // 路径已删）。保留 knob 读取以维持调用契约（caller 仍传、上方 knobs.has 校验不变），显式吞掉避免 unused 告警。
    (void)season_idx;
    (void)season_phase;
    const float wb_pos_y        = float(knobs["world_bounds_pos_y"]);
    const float wb_size_y       = float(knobs["world_bounds_size_y"]);
    // climate-realism Stage1 (2026-06-23): 「热赤道」纬度(norm)，GDScript begin_slice 按 zonal-max
    // 温度逐 tick 计算并经 knobs 传入；Hadley/Ferrel omega 项消费。镜像 field_solver.gd。
    const float weather_lat_te_norm = knobs.has("weather_lat_te_norm")
                                        ? float(knobs["weather_lat_te_norm"]) : 0.5f;
    // [climate-zone-fix P3] 原 constexpr 0.40 → 导出为 knob（field_omega_ascent_gain），缺 key 仍回退 0.40。
    // 下调弱化静止 ITCZ 雨带锚定，让冷季锋面/层状相对增强（镜像 field_solver.gd OMEGA_ASCENT_GAIN）。
    const float OMEGA_ASCENT_GAIN  = knobs.has("field_omega_ascent_gain")
                                        ? float(knobs["field_omega_ascent_gain"]) : 0.40f;
    constexpr float OMEGA_DESCENT_GAIN = 0.70f; // 副热带下沉带降水抑制
    constexpr float OMEGA_DESCENT_COND = 0.45f; // 副热带下沉抑制凝结→晴空
    // Stage6/6c (2026-06-23): 湿度充放电 + 对流抑制记忆。镜像 field_solver.gd。
    constexpr float VAPOR_DISCHARGE = 0.70f;    // 持续降水更快抽干本格水汽，避免固定雨核永雨
    constexpr float DISCHARGE_SUSTAIN = 0.65f;  // prev_precip 高时加强放电，让雨团下完后进入恢复期
    // Stage6e: 对流抑制=双稳弛豫振子(硬阈)，线性版会停在弱雨稳态→不消散；改硬阈 开/关 循环。镜像 field_solver.gd。
    // Stage6g: 对流抑制=按时长充放电(强度无关)，双稳两段编码于单 float。镜像 field_solver.gd。
    // inhib∈[0,1) 充能期；inhib≥1 不应期(压制降水)。
    constexpr float INHIB_CHARGE = 0.26f;       // Stage7c: 0.18→0.26 雨段≈4tick(~2天)
    constexpr float INHIB_REFRAC = 0.18f;       // Stage7c: 0.55→0.18 不应期≈5-6tick(~3天，晴天真间断)
    constexpr float INHIB_LEAK = 0.88f;         // 充能期干tick泄放
    constexpr float INHIB_STRENGTH = 0.92f;     // 不应期内 precip ×(1-此值)
    constexpr float INHIB_WET = 0.02f;          // 计为降水tick的阈
    // ── Stage7 (2026-06-23): 预报性斜压涡旋场 ψ（涌现的非季节天气变率）。镜像 field_solver.gd。
    // ψ 由"上风平流 + 斜压增长(温度梯度) + 随机种子 + 耗散"演化→自发生成、移动、消亡的过境系统；
    // 耦合进 dynamic_forcing/precip→干季偶有降水、湿季有间断，与季节解耦。可由 knob 关。
    const bool  syn_enabled   = knobs.has("weather_synoptic_enabled") ? bool(knobs["weather_synoptic_enabled"]) : true;
    // Stage13: ψ 演化(平流/增长/种子/扩散/阻尼)的 knob 已移到独立 pass run_synoptic_advance_pass。
    // 本 solve 循环只读 ψ，仅保留下面的【耦合】knob。
    const float syn_supp      = knobs.has("weather_synoptic_supp")      ? float(knobs["weather_synoptic_supp"])      : 0.75f; // Stage14 0.50→0.75 ψ<0(高压)强抑雨→移动的晴空带
    const float syn_enh       = knobs.has("weather_synoptic_enh")       ? float(knobs["weather_synoptic_enh"])       : 0.45f; // Stage14 0.20→0.45 ψ>0(低压)增雨(让降水跟 ψ)
    // Stage9 #5: ψ>0(气旋)在斜压带(锋面/中纬冷季)创造抬升+增雨→冷季锋面雨(地中海/海洋性"雨热不同期")。
    const float syn_front_force=knobs.has("weather_synoptic_front_force")?float(knobs["weather_synoptic_front_force"]): 0.55f; // ψ>0 在锋面加 dynamic_forcing(造雨)
    const float syn_front_enh = knobs.has("weather_synoptic_front_enh") ? float(knobs["weather_synoptic_front_enh"]) : 0.70f; // ψ>0 在锋面额外增雨倍率
    // Stage14「激进推 ψ 主导」：ψ>0(低压)强抬升成为降水主驱动→云雨成片随 ψ 平移。base 大幅提高让移动的
    // ψ 涡旋盖过静止地理强迫(omega/对流/辐合)。代价:过湿+扰动雨热(用户已接受)。
    const float syn_base_lift = knobs.has("weather_synoptic_base_lift") ? float(knobs["weather_synoptic_base_lift"]) : 1.55f;
    // Stage13b ψ 演化 knob（内联全场推进用：见 slot 指针后、主循环前的全场 ψ pass）。
    const int   syn_adv_cells = knobs.has("weather_synoptic_adv_cells") ? int(knobs["weather_synoptic_adv_cells"]) : 3;
    const float syn_baroclinic= knobs.has("weather_synoptic_baroclinic")? float(knobs["weather_synoptic_baroclinic"]): 0.40f;
    const float syn_seed_rate = knobs.has("weather_synoptic_seed_rate") ? float(knobs["weather_synoptic_seed_rate"]) : 0.015f; // 稀疏播种(纯取值平移无损,种子须少否则铺满)
    const float syn_seed_amp  = knobs.has("weather_synoptic_seed_amp")  ? float(knobs["weather_synoptic_seed_amp"])  : 0.42f;
    const float syn_diffuse   = knobs.has("weather_synoptic_diffuse")   ? float(knobs["weather_synoptic_diffuse"])   : 0.05f;  // 弱扩散(强了会铺满)
    const float syn_damp      = knobs.has("weather_synoptic_damp")      ? float(knobs["weather_synoptic_damp"])      : 0.90f;  // 较快衰减→无源区清空保稀疏
    const int   syn_tick      = knobs.has("weather_solve_tick")         ? int(knobs["weather_solve_tick"])           : 0;
    if (syn_enabled && _wx_synoptic.size() != (size_t)n_cells) {
        _wx_synoptic.assign((size_t)n_cells, 0.0f);
        _wx_synoptic_prev.assign((size_t)n_cells, 0.0f);
    }
    const float * const __restrict PSI = syn_enabled ? _wx_synoptic.data() : nullptr;
    (void)wb_pos_y;
    (void)wb_size_y;
    const bool  refresh_convergence = bool(knobs["refresh_convergence"]);
    const bool  apply_convergence_boost = knobs.has("apply_convergence_boost")
                                            ? bool(knobs["apply_convergence_boost"]) : true;

    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (start_idx < 0 || start_idx > n_cells || end_idx < start_idx || end_idx > n_cells) {
        diag("invalid start_idx/end_idx range");
        return -1.0;
    }

    const int   field_advect_steps      = knobs.has("field_advect_steps")
                                            ? int(knobs["field_advect_steps"]) : 3;
    const float field_diffusion         = knobs.has("field_diffusion")
                                            ? float(knobs["field_diffusion"]) : 0.04f;
    const float field_condensation_gain = knobs.has("field_condensation_gain")
                                            ? float(knobs["field_condensation_gain"]) : 0.42f;
    const float field_orographic_lift_gain = knobs.has("field_orographic_lift_gain")
                                            ? float(knobs["field_orographic_lift_gain"]) : 0.22f;
    const float field_convergence_gain  = knobs.has("field_convergence_gain")
                                            ? float(knobs["field_convergence_gain"]) : 0.18f;
    const float field_ocean_evap_gain   = knobs.has("field_ocean_evap_gain")
                                            ? float(knobs["field_ocean_evap_gain"]) : 0.55f;
    // field_precip_decay / field_precip_carryover_max：原 carryover precip_floor 的输入，已被 EMA
    // 惯性(field_precip_inertia)取代，C++ 主路径不再读取(GDScript verify 路径与 ClimateProfile 仍保留)。
    const float field_vapor_precip_sink = knobs.has("field_vapor_precip_sink")
                                            ? float(knobs["field_vapor_precip_sink"]) : 0.85f;
    // 降水惯性 EMA 系数 α(2026-06-20 根因重构)：precip = lerp(prev_precip, target, α)。默认与
    // weather_system._field_precip_inertia / climate_profile.weather_precip_inertia 对齐(0.58)。
    float field_precip_inertia = knobs.has("field_precip_inertia")
                                            ? float(knobs["field_precip_inertia"]) : 0.40f;
    if (field_precip_inertia < 0.05f) field_precip_inertia = 0.05f;
    else if (field_precip_inertia > 1.0f) field_precip_inertia = 1.0f;
    // Stage10 空间平滑强度：最终降水向邻域(上一 tick)均值轻混 → 削单格噪声/棋盘格，保连片风暴。
    float field_precip_spatial_smooth = knobs.has("field_precip_spatial_smooth")
                                            ? float(knobs["field_precip_spatial_smooth"]) : 0.30f;
    if (field_precip_spatial_smooth < 0.0f) field_precip_spatial_smooth = 0.0f;
    else if (field_precip_spatial_smooth > 0.8f) field_precip_spatial_smooth = 0.8f;
    // Stage15 云量时间惯性(EMA)：cloud 向上帧靠拢的比例，越小越平滑(减 shader 闪烁)。
    float field_cloud_inertia = knobs.has("field_cloud_inertia") ? float(knobs["field_cloud_inertia"]) : 0.74f;
    if (field_cloud_inertia < 0.05f) field_cloud_inertia = 0.05f;
    else if (field_cloud_inertia > 1.0f) field_cloud_inertia = 1.0f;
    const float field_vapor_relax_rate = knobs.has("field_vapor_relax_rate")
                                            ? float(knobs["field_vapor_relax_rate"]) : 0.08f;
    const float field_orographic_lift_cap = knobs.has("field_orographic_lift_cap")
                                            ? float(knobs["field_orographic_lift_cap"]) : 0.35f;
    const float hex_size                = knobs.has("hex_size")
                                            ? float(knobs["hex_size"]) : 22.0f;
    float weather_cell_pos_scale = knobs.has("weather_cell_pos_scale")
                                            ? float(knobs["weather_cell_pos_scale"]) : 1.0f;
    if (weather_cell_pos_scale <= 0.001f) weather_cell_pos_scale = 1.0f;
    float weather_wrap_width_x = knobs.has("weather_wrap_width_x")
                                            ? float(knobs["weather_wrap_width_x"]) : 0.0f;
    if (weather_wrap_width_x < 0.0f) weather_wrap_width_x = 0.0f;
    const bool cold_precip_as_blizzard = knobs.has("cold_precip_as_blizzard")
                                            ? bool(knobs["cold_precip_as_blizzard"]) : true;
    float snow_classification_margin = knobs.has("snow_classification_margin")
                                            ? float(knobs["snow_classification_margin"]) : 0.03f;
    if (snow_classification_margin < 0.0f) snow_classification_margin = 0.0f;
    else if (snow_classification_margin > 0.12f) snow_classification_margin = 0.12f;
    float field_wet_terrain_precip_damping = knobs.has("field_wet_terrain_precip_damping")
                                            ? float(knobs["field_wet_terrain_precip_damping"]) : 0.60f;
    float field_lake_precip_damping = knobs.has("field_lake_precip_damping")
                                            ? float(knobs["field_lake_precip_damping"]) : 0.65f;
    float field_lake_evap_scale = knobs.has("field_lake_evap_scale")
                                            ? float(knobs["field_lake_evap_scale"]) : 0.35f;
    float field_extreme_precip_soft_cap = knobs.has("field_extreme_precip_soft_cap")
                                            ? float(knobs["field_extreme_precip_soft_cap"]) : 0.16f;
    float field_extreme_precip_softness = knobs.has("field_extreme_precip_softness")
                                            ? float(knobs["field_extreme_precip_softness"]) : 0.20f;
    float field_land_evapotranspiration_gain = knobs.has("field_land_evapotranspiration_gain")
                                            ? float(knobs["field_land_evapotranspiration_gain"]) : 0.85f;
    float field_precip_rh_threshold = knobs.has("field_precip_rh_threshold")
                                            ? float(knobs["field_precip_rh_threshold"]) : 0.70f;
    float field_ocean_precip_suppression = knobs.has("field_ocean_precip_suppression")
                                            ? float(knobs["field_ocean_precip_suppression"]) : 0.95f;
    float field_frontogenesis_gain = knobs.has("field_frontogenesis_gain")
                                            ? float(knobs["field_frontogenesis_gain"]) : 0.42f;
    float field_rain_shadow_drying = knobs.has("field_rain_shadow_drying")
                                            ? float(knobs["field_rain_shadow_drying"]) : 0.35f;
    float field_vapor_transport_gain = knobs.has("field_vapor_transport_gain")
                                            ? float(knobs["field_vapor_transport_gain"]) : 0.75f;
    if (field_wet_terrain_precip_damping < 0.0f) field_wet_terrain_precip_damping = 0.0f;
    else if (field_wet_terrain_precip_damping > 1.0f) field_wet_terrain_precip_damping = 1.0f;
    if (field_lake_precip_damping < 0.0f) field_lake_precip_damping = 0.0f;
    else if (field_lake_precip_damping > 1.0f) field_lake_precip_damping = 1.0f;
    if (field_lake_evap_scale < 0.0f) field_lake_evap_scale = 0.0f;
    else if (field_lake_evap_scale > 1.0f) field_lake_evap_scale = 1.0f;
    if (field_extreme_precip_soft_cap < 0.0f) field_extreme_precip_soft_cap = 0.0f;
    else if (field_extreme_precip_soft_cap > 1.0f) field_extreme_precip_soft_cap = 1.0f;
    if (field_extreme_precip_softness < 0.0f) field_extreme_precip_softness = 0.0f;
    else if (field_extreme_precip_softness > 1.0f) field_extreme_precip_softness = 1.0f;
    if (field_land_evapotranspiration_gain < 0.0f) field_land_evapotranspiration_gain = 0.0f;
    if (field_precip_rh_threshold < 0.40f) field_precip_rh_threshold = 0.40f;
    else if (field_precip_rh_threshold > 0.95f) field_precip_rh_threshold = 0.95f;
    if (field_ocean_precip_suppression < 0.0f) field_ocean_precip_suppression = 0.0f;
    else if (field_ocean_precip_suppression > 1.0f) field_ocean_precip_suppression = 1.0f;
    if (field_frontogenesis_gain < 0.0f) field_frontogenesis_gain = 0.0f;
    if (field_rain_shadow_drying < 0.0f) field_rain_shadow_drying = 0.0f;
    else if (field_rain_shadow_drying > 1.0f) field_rain_shadow_drying = 1.0f;
    if (field_vapor_transport_gain < 0.0f) field_vapor_transport_gain = 0.0f;
    else if (field_vapor_transport_gain > 1.0f) field_vapor_transport_gain = 1.0f;

    // ─── 平流式湿团模型旋钮 (2026-06-21 重构, 离线 _wx_advect_0621.py 标定定稿默认) ──
    // vapor/cloud_water 作随风平流的守恒物质：蒸发→vapor；凝结 vapor→cw；降水消耗 cw；
    // 干空气 cw→vapor 再蒸发。地形/气候只做弱调制(供给凝结)，不再无条件主导降水。
    // 未注入时用此默认即可让新公式工作；旋钮化接入 climate_profile/KnobsHandle 见后续提交。
    // 2026-06-21 实机迭代：第一轮(rh0.55→0.32 + base0.20→0.50 + auto0.12→0.16)经 205247 复验
    // 适得其反——land_dry 49%→83%、vapor 全面崩塌(内陆 hop4 vapor 0.185→0.085、cw 0.139→0.042)。
    // 根因：降 rh_condense 降低了【全局】凝结门槛 → 整个水汽场被过度凝结+降水抽干，内陆作为水汽
    // 输送末端枯竭最重。教训：靠"多凝结多降水"增雨是零和陷阱(消耗有限水汽，加速循环只让末端更干)。
    // 第二轮：rh_condense 回滚 0.55(止抽干)，仅保留 base_frac 0.50 + autoconv 0.16 提背景 trig
    // (离线验证提 trig 不抽干 vapor)，隔离验证"trig 提升单独是否安全改善内陆"。下一轮若仍不足，
    // 走开源(提 land_evapotranspiration_gain 增内陆本地水汽)而非继续加速循环。
    const float field_advect_vapor     = knobs.has("field_advect_vapor")     ? float(knobs["field_advect_vapor"])     : 0.95f;  // 方案③ 0.82→0.95 vapor 平流主导(水汽随风成河,蒸发源退化为注入点)
    const float field_advect_cloud     = knobs.has("field_advect_cloud")     ? float(knobs["field_advect_cloud"])     : 0.94f;
    const float field_rh_condense      = knobs.has("field_rh_condense")      ? float(knobs["field_rh_condense"])      : 0.55f;
    const float field_static_cond_w    = knobs.has("field_static_cond_w")    ? float(knobs["field_static_cond_w"])    : 1.00f;
    const float field_condense_rate    = knobs.has("field_condense_rate")    ? float(knobs["field_condense_rate"])    : 0.45f;
    const float field_lift_cond_gain   = knobs.has("field_lift_cond_gain")   ? float(knobs["field_lift_cond_gain"])   : 0.80f;
    const float field_conv_cond_gain   = knobs.has("field_conv_cond_gain")   ? float(knobs["field_conv_cond_gain"])   : 1.00f;
    // 热力对流(大陆夏季雷暴)：地表加热+本地水汽驱动凝结/降水，修复内陆 rh<<静力阈的"水汽到了却凝不成雨"死结。
    const float field_thermal_conv_cond   = knobs.has("field_thermal_conv_cond")   ? float(knobs["field_thermal_conv_cond"])   : 1.15f; // 降低静态热力云源，让移动 ψ/平流主导雨云
    const float field_thermal_conv_precip = knobs.has("field_thermal_conv_precip") ? float(knobs["field_thermal_conv_precip"]) : 0.30f; // B1(2026-06-28) 0.45→0.30 进一步削弱温度锚定原地对流雨,降水改由辐合/抬升/地形主导
    const float field_autoconversion   = knobs.has("field_autoconversion")   ? float(knobs["field_autoconversion"])   : 0.16f;
    const float field_precip_base_frac = knobs.has("field_precip_base_frac") ? float(knobs["field_precip_base_frac"]) : 0.08f;
    const float field_lift_precip_gain = knobs.has("field_lift_precip_gain") ? float(knobs["field_lift_precip_gain"]) : 0.45f; // Stage14e 0.25→0.45 迎风坡(山地)致雨增强→不再绕山
    const float field_conv_precip_gain = knobs.has("field_conv_precip_gain") ? float(knobs["field_conv_precip_gain"]) : 1.95f; // B1(2026-06-28) 1.80→1.95 提辐合致雨权重,补温度对流减弱并使 r(precip,conv)↑
    const float field_oro_precip_gain  = knobs.has("field_oro_precip_gain")  ? float(knobs["field_oro_precip_gain"])  : 0.30f;  // Stage14e 0.10→0.30 地形抬升增雨(山地迎风坡)
    // Stage11 层状降水增益：补对流暖门挡死的冷/高/水区降水(地形/锋面/海面层云),0 关闭。
    const float field_stratiform_gain  = knobs.has("field_stratiform_gain")  ? float(knobs["field_stratiform_gain"])  : 1.0f;
    // [climate-zone-fix P3] 冷季蒸发地板：temp_evap=max(floor, smoothstep(0.10,0.78,T))。0=关闭=原行为。
    // 冷季低温下 smoothstep≈0 致无水汽源→冷季锋面/层状无雨；地板给冷季基础水汽(补冬雨/降雪)。镜像 field_solver.gd。
    const float field_cool_season_vapor_floor = knobs.has("field_cool_season_vapor_floor")
                                        ? float(knobs["field_cool_season_vapor_floor"]) : 0.0f;
    const float field_cloud_reevap     = knobs.has("field_cloud_reevap")     ? float(knobs["field_cloud_reevap"])     : 0.28f;
    // 诊断式旧旋钮在平流式路径不再使用(caller 仍注入；显式吞掉避免 unused 告警)。
    (void)field_condensation_gain; (void)field_orographic_lift_gain; (void)field_convergence_gain;
    (void)field_vapor_transport_gain; (void)field_vapor_precip_sink; (void)field_precip_rh_threshold;

    // ─── Pull pre-computed PackedArrays from knobs (zero-copy reads) ────
    if (!knobs.has("cell_pos") || !knobs.has("neighbor_indices") ||
        !knobs.has("prev_vapor") || !knobs.has("prev_precip") ||
        !knobs.has("temp_transport_anomaly")) {
        diag("knobs missing required PackedArray inputs");
        return -1.0;
    }
    PackedVector2Array cell_pos_arr = knobs["cell_pos"];
    PackedInt32Array   nb_arr       = knobs["neighbor_indices"];
    PackedFloat32Array prev_vapor_arr  = knobs["prev_vapor"];
    PackedFloat32Array prev_precip_arr = knobs["prev_precip"];
    PackedFloat32Array temp_anom_arr   = knobs["temp_transport_anomaly"];
    PackedFloat32Array prev_cloud_water_arr;
    PackedFloat32Array temp_read_arr;
    PackedFloat32Array moist_read_arr;
    PackedFloat32Array snow_cover_read_arr;
    PackedFloat32Array out_vapor_arr;
    PackedFloat32Array out_cloud_arr;
    PackedFloat32Array out_cloud_water_arr;
    PackedFloat32Array out_precip_arr;
    PackedFloat32Array out_instability_arr;
    PackedFloat32Array out_intensity_arr;
    PackedFloat32Array out_convergence_arr;
    PackedInt32Array out_type_arr;
    if (knobs.has("prev_cloud_water")) {
        prev_cloud_water_arr = knobs["prev_cloud_water"];
    }
    if (knobs.has("temp_read_arr")) {
        temp_read_arr = knobs["temp_read_arr"];
    }
    if (knobs.has("moisture_read_arr")) {
        moist_read_arr = knobs["moisture_read_arr"];
    }
    if (knobs.has("snow_cover_read_arr")) {
        snow_cover_read_arr = knobs["snow_cover_read_arr"];
    }
    // 涌现式分类(2026-06-20)：温度距平(cell_temp_anomaly → map.temp_anomaly_arr)，热浪门"比常态
    // 显著偏暖"的判据。与 cell_lat_norm 同走 knobs（caller 传同一 GDScript 数组）→ 保证 bit-equal、同源。
    PackedFloat32Array temp_anomaly_cls_arr;
    if (knobs.has("temp_anomaly")) {
        temp_anomaly_cls_arr = knobs["temp_anomaly"];
    }

    if (cell_pos_arr.size() != n_cells) {
        diag("cell_pos size mismatch"); return -1.0;
    }
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells * 6 (pass requires fast_indexed)");
        return -1.0;
    }
    if (prev_vapor_arr.size()  != n_cells ||
        prev_precip_arr.size() != n_cells ||
        temp_anom_arr.size()   != n_cells) {
        diag("prev/temp_anom array size mismatch"); return -1.0;
    }
    if (prev_cloud_water_arr.size() != 0 && prev_cloud_water_arr.size() != n_cells) {
        diag("prev_cloud_water array size mismatch"); return -1.0;
    }
    if (snow_cover_read_arr.size() != 0 && snow_cover_read_arr.size() != n_cells) {
        diag("snow_cover_read_arr size mismatch"); return -1.0;
    }

    const bool use_next_outputs =
        knobs.has("out_vapor") && knobs.has("out_cloud") &&
        knobs.has("out_precip") && knobs.has("out_instability") &&
        knobs.has("out_intensity") && knobs.has("out_convergence") &&
        knobs.has("out_type");
    if (use_next_outputs) {
        out_vapor_arr       = knobs["out_vapor"];
        out_cloud_arr       = knobs["out_cloud"];
        out_precip_arr      = knobs["out_precip"];
        out_instability_arr = knobs["out_instability"];
        out_intensity_arr   = knobs["out_intensity"];
        out_convergence_arr = knobs["out_convergence"];
        out_type_arr        = knobs["out_type"];
        if (knobs.has("out_cloud_water")) {
            out_cloud_water_arr = knobs["out_cloud_water"];
        }
        if (out_vapor_arr.size()       != n_cells ||
            out_cloud_arr.size()       != n_cells ||
            out_precip_arr.size()      != n_cells ||
            out_instability_arr.size() != n_cells ||
            out_intensity_arr.size()   != n_cells ||
            out_convergence_arr.size() != n_cells ||
            out_type_arr.size()        != n_cells) {
            diag("out array size mismatch");
            return -1.0;
        }
        if (out_cloud_water_arr.size() != 0 && out_cloud_water_arr.size() != n_cells) {
            diag("out_cloud_water array size mismatch");
            return -1.0;
        }
    }

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moisture];
    Slot &s_air_anom = _slots.write[sid_air_anom];
    Slot &s_wx       = _slots.write[sid_wind_x];
    Slot &s_wy       = _slots.write[sid_wind_y];
    Slot &s_wspd     = _slots.write[sid_wind_spd];
    Slot &s_terr     = _slots.write[sid_terrain];
    Slot &s_riv      = _slots.write[sid_has_river];
    Slot *s_river_q30 = (sid_river_q30 >= 0) ? &_slots.write[sid_river_q30] : nullptr;
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_veg      = _slots.write[sid_vegetation];
    Slot *s_soil     = (sid_soil_moisture >= 0) ? &_slots.write[sid_soil_moisture] : nullptr;
    Slot *s_vitality = (sid_veg_vitality >= 0) ? &_slots.write[sid_veg_vitality] : nullptr;
    Slot *s_sea_ice  = (sid_sea_ice >= 0) ? &_slots.write[sid_sea_ice] : nullptr;
    Slot &s_wvap     = _slots.write[sid_w_vapor];
    Slot &s_wcld     = _slots.write[sid_w_cloud];
    Slot &s_wpre     = _slots.write[sid_w_precip];
    Slot &s_wins     = _slots.write[sid_w_inst];
    Slot &s_wint     = _slots.write[sid_w_intens];
    Slot &s_wcnv     = _slots.write[sid_w_conv];
    Slot &s_wtyp     = _slots.write[sid_w_type];
    Slot *s_wprev    = (sid_w_prev_type >= 0) ? &_slots.write[sid_w_prev_type] : nullptr;
    Slot *s_wtarget  = (sid_w_target_type >= 0) ? &_slots.write[sid_w_target_type] : nullptr;
    Slot *s_walpha   = (sid_w_transition_alpha >= 0) ? &_slots.write[sid_w_transition_alpha] : nullptr;
    Slot &s_wfin     = _slots.write[sid_w_finit];

    if (s_temp.arr_f32.size()     != n_cells || s_moist.arr_f32.size()  != n_cells ||
        s_air_anom.arr_f32.size() != n_cells || s_wx.arr_f32.size()     != n_cells ||
        s_wy.arr_f32.size()       != n_cells || s_wspd.arr_f32.size()   != n_cells ||
        s_terr.arr_u8.size()      != n_cells ||
        s_riv.arr_u8.size()       != n_cells || s_elev.arr_f32.size()   != n_cells ||
        s_veg.arr_u8.size()       != n_cells ||
        s_wvap.arr_f32.size()     != n_cells || s_wcld.arr_f32.size()   != n_cells ||
        s_wpre.arr_f32.size()     != n_cells || s_wins.arr_f32.size()   != n_cells ||
        s_wint.arr_f32.size()     != n_cells || s_wcnv.arr_f32.size()   != n_cells ||
        s_wtyp.arr_u8.size()      != n_cells || s_wfin.arr_u8.size()    != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }
    if (weather_transition_enabled &&
        (s_wprev == nullptr || s_wtarget == nullptr || s_walpha == nullptr ||
         s_wprev->arr_u8.size() != n_cells || s_wtarget->arr_u8.size() != n_cells ||
         s_walpha->arr_f32.size() != n_cells)) {
        diag("weather transition slot size mismatch");
        return -1.0;
    }
    if (s_river_q30 != nullptr && s_river_q30->arr_f32.size() != n_cells) {
        s_river_q30 = nullptr;
    }
    if (s_soil != nullptr && s_soil->arr_f32.size() != n_cells) {
        s_soil = nullptr;
    }
    if (s_vitality != nullptr && s_vitality->arr_f32.size() != n_cells) {
        s_vitality = nullptr;
    }
    if (s_sea_ice != nullptr && s_sea_ice->arr_f32.size() != n_cells) {
        s_sea_ice = nullptr;
    }

    // ─── Hot pointers ───────────────────────────────────────────────────
    const float   * const __restrict T    = s_temp.arr_f32.ptr();
    const float   * const __restrict M    = s_moist.arr_f32.ptr();
    const float   * const __restrict TR   = (temp_read_arr.size() == n_cells) ? temp_read_arr.ptr() : T;
    const float   * const __restrict MR   = (moist_read_arr.size() == n_cells) ? moist_read_arr.ptr() : M;
    const float   * const __restrict AA   = s_air_anom.arr_f32.ptr();
    const float   * const __restrict WX   = s_wx.arr_f32.ptr();
    const float   * const __restrict WY   = s_wy.arr_f32.ptr();
    const float   * const __restrict WSPD = s_wspd.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const uint8_t * const __restrict RIV  = s_riv.arr_u8.ptr();
    const float   * const __restrict RQ30 = (s_river_q30 != nullptr) ? s_river_q30->arr_f32.ptr() : nullptr;
    const float   * const __restrict ELEV = s_elev.arr_f32.ptr();
    const uint8_t * const __restrict VEG  = s_veg.arr_u8.ptr();
    const float   * const __restrict SOIL = (s_soil != nullptr) ? s_soil->arr_f32.ptr() : nullptr;
    const float   * const __restrict VITA = (s_vitality != nullptr) ? s_vitality->arr_f32.ptr() : nullptr;
    const float   * const __restrict SICE = (s_sea_ice != nullptr) ? s_sea_ice->arr_f32.ptr() : nullptr;

    const Vector2 * const __restrict POS  = cell_pos_arr.ptr();
    const float   * const __restrict TANO = (temp_anomaly_cls_arr.size() == n_cells) ? temp_anomaly_cls_arr.ptr() : nullptr;
    const float   * const __restrict SNOWR = (snow_cover_read_arr.size() == n_cells) ? snow_cover_read_arr.ptr() : nullptr;
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict PV   = prev_vapor_arr.ptr();
    const float   * const __restrict PP   = prev_precip_arr.ptr();
    const float   * const __restrict PCW  = (prev_cloud_water_arr.size() == n_cells) ? prev_cloud_water_arr.ptr() : nullptr;
    const float   * const __restrict TA   = temp_anom_arr.ptr();
    const float   * const __restrict PREV_CNV = s_wcnv.arr_f32.ptr();

    float   * const __restrict OUT_VAP = use_next_outputs ? out_vapor_arr.ptrw() : s_wvap.arr_f32.ptrw();
    float   * const __restrict OUT_CLD = use_next_outputs ? out_cloud_arr.ptrw() : s_wcld.arr_f32.ptrw();
    const float * const __restrict PREV_CLOUD = s_wcld.arr_f32.ptr();  // Stage15 上帧云量(供时间 EMA 平滑→减 shader 闪烁)
    float   * const __restrict OUT_CW  = (use_next_outputs && out_cloud_water_arr.size() == n_cells) ? out_cloud_water_arr.ptrw() : nullptr;
    float   * const __restrict OUT_PRE = use_next_outputs ? out_precip_arr.ptrw() : s_wpre.arr_f32.ptrw();
    float   * const __restrict OUT_INS = use_next_outputs ? out_instability_arr.ptrw() : s_wins.arr_f32.ptrw();
    float   * const __restrict OUT_INT = use_next_outputs ? out_intensity_arr.ptrw() : s_wint.arr_f32.ptrw();
    float   * const __restrict OUT_CNV = use_next_outputs ? out_convergence_arr.ptrw() : s_wcnv.arr_f32.ptrw();
    uint8_t * const __restrict OUT_TYP = use_next_outputs ? nullptr : s_wtyp.arr_u8.ptrw();
    int32_t * const __restrict OUT_TYP_I32 = use_next_outputs ? out_type_arr.ptrw() : nullptr;
    if (_wx_conv_inhib.size() != (size_t)n_cells) _wx_conv_inhib.assign((size_t)n_cells, 0.0f);
    float   * const __restrict INHIB = _wx_conv_inhib.data();  // Stage6c: ext 成员，跨 tick 持久(无 CoW 回传问题)
    uint8_t * const __restrict OUT_PREV_TYP = (!use_next_outputs && weather_transition_enabled && s_wprev != nullptr) ? s_wprev->arr_u8.ptrw() : nullptr;
    uint8_t * const __restrict OUT_TARGET_TYP = (!use_next_outputs && weather_transition_enabled && s_wtarget != nullptr) ? s_wtarget->arr_u8.ptrw() : nullptr;
    float   * const __restrict OUT_ALPHA = (!use_next_outputs && weather_transition_enabled && s_walpha != nullptr) ? s_walpha->arr_f32.ptrw() : nullptr;
    uint8_t * const __restrict OUT_FIN   = use_next_outputs ? nullptr : s_wfin.arr_u8.ptrw();

    if (start_idx == 0) {
        _advance_and_stamp_cyclones(knobs, n_cells, NB, POS, TERR, TR, WX, WY,
                                    WSPD, PV, s_wins.arr_f32.ptr(), PREV_CNV,
                                    nullptr);
    }

    // ─── 计时 (返回给调用方做对账，charter §0 铁律 3) ──────────────────
    auto t0 = std::chrono::high_resolution_clock::now();

    // S3：如实上报"生产这一天跑了 stage 11 WEATHER"。field solve 还没有共享纯内核，
    // 所以 worker 侧不会跑；但把生产跑过这件事记下来，分叉矩阵才能把 WEATHER 那 8 个
    // 字段的分叉归到"worker 缺实现"，而不是与"这天两边都没跑"混在一起。
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;

    // ── Stage13b「让天气移动」：每轮(start_idx==0)在主循环前对全场推进一次 ψ ────────────────
    // 内联进 solve pass → 与 solve 必然一起执行(不依赖 GDScript 调度挂钩、换 DLL 即生效)；全场一次→
    // 不被切片稀释。平滑引导流(风邻域平均)+纯取值半拉格朗日平移→ψ 涡旋成片随风移动。主循环只读 PSI[i]。
    if (start_idx == 0) {
        // cell_pos 的 POD 视图：解交织，逐位无损。共享内核只能吃 float lane。
        if (_wf_pos_x.size() != (size_t)n_cells) {
            _wf_pos_x.assign((size_t)n_cells, 0.0f);
            _wf_pos_y.assign((size_t)n_cells, 0.0f);
        }
        for (int p = 0; p < n_cells; ++p) {
            _wf_pos_x[(size_t)p] = POS[p].x;
            _wf_pos_y[(size_t)p] = POS[p].y;
        }
    }

    if (PSI != nullptr && start_idx == 0) {
        // 斜压门用归一化温度 TR(与主循环一致)；勿用 cell_temp slot(实际量纲→smoothstep 恒1→ψ 指数爆炸饱和)。
        pk_async_climate::SynopticAdvanceKnobs syn;
        syn.baroclinic = syn_baroclinic;
        syn.damp = syn_damp;
        syn.diffuse = syn_diffuse;
        syn.seed_rate = syn_seed_rate;
        syn.seed_amp = syn_seed_amp;
        syn.adv_cells = syn_adv_cells;
        syn.tick = syn_tick;
        syn.cell_pos_scale = weather_cell_pos_scale;
        syn.wrap_width_x = weather_wrap_width_x;
        pk_async_climate::synoptic_advance_pure(
            n_cells, NB, _wf_pos_x.data(), _wf_pos_y.data(), WX, WY, TR, syn,
            _wx_synoptic, _wx_synoptic_prev);
    }

    // ── perf P2: 邻域几何缓存构建（每轮 start_idx==0）──────────────────────
    // self->nb wrapped delta(dx,dy) + inv_dist=1/sqrt(dl2)，供主循环 aligned/
    // upstream/convergence 读取（bit-equal：同 wf_wrapped_delta/Math::sqrt 同序）。
    if (start_idx == 0) {
        const size_t need = (size_t)n_cells * 6;
        if (_wf_nb_dx.size() != need) {
            _wf_nb_dx.assign(need, 0.0f);
            _wf_nb_dy.assign(need, 0.0f);
            _wf_nb_invd.assign(need, 0.0f);
        }
        pk_async_climate::weather_field_geometry_cache_pure(
            n_cells, NB, _wf_pos_x.data(), _wf_pos_y.data(),
            weather_wrap_width_x, _wf_nb_dx.data(), _wf_nb_dy.data(),
            _wf_nb_invd.data());
        _wf_nb_geom_n = n_cells;
        _wf_nb_geom_wrap = weather_wrap_width_x;
    }
    const bool use_geom_cache =
        (_wf_nb_geom_n == n_cells && _wf_nb_geom_wrap == weather_wrap_width_x);
    const float * const __restrict GEOM_DX   = use_geom_cache ? _wf_nb_dx.data()   : nullptr;
    const float * const __restrict GEOM_DY   = use_geom_cache ? _wf_nb_dy.data()   : nullptr;
    const float * const __restrict GEOM_INVD = use_geom_cache ? _wf_nb_invd.data() : nullptr;

    // ─── stage 11 的数值核心已抽成共享纯内核 ────────────────────
    // pk_async_climate::weather_field_solve_pure。这里只做 Godot 侧的装配：
    // 把 Dictionary knob 收成 POD 结构体、把 slot/PackedArray 收成裸指针 lane、
    // 把 DCWorldExt 上那七组跳 tick 状态收成 state。循环体一行数值都不在这里了，
    // 所以 worker 跑的和生产跑的是同一份代码。
    const int32_t *TRAJ_IDX = nullptr;
    const float   *TRAJ_W   = nullptr;
    if (_phys_wind_traj_valid && _phys_wind_traj_consume_enabled
            && int(_phys_wind_traj_idx.size()) == n_cells * 3) {
        if (pk_wind_state_fp(n_cells, WX, WY, WSPD) == _phys_wind_traj_fp) {
            TRAJ_IDX = _phys_wind_traj_idx.data();
            TRAJ_W   = _phys_wind_traj_w.data();
        } else {
            ++_phys_wind_traj_stale_count;
        }
    }

    pk_async_climate::WeatherFieldKnobs wfk;
    wfk.n_cells = n_cells;
    wfk.climate_anomaly = climate_anomaly;
    wfk.refresh_convergence = refresh_convergence;
    wfk.apply_convergence_boost = apply_convergence_boost;
    wfk.use_next_outputs = use_next_outputs;
    wfk.field_advect_steps = field_advect_steps;
    wfk.field_diffusion = field_diffusion;
    wfk.field_ocean_evap_gain = field_ocean_evap_gain;
    wfk.field_precip_inertia = field_precip_inertia;
    wfk.field_precip_spatial_smooth = field_precip_spatial_smooth;
    wfk.field_cloud_inertia = field_cloud_inertia;
    wfk.field_wet_terrain_precip_damping = field_wet_terrain_precip_damping;
    wfk.field_lake_precip_damping = field_lake_precip_damping;
    wfk.field_lake_evap_scale = field_lake_evap_scale;
    wfk.field_extreme_precip_soft_cap = field_extreme_precip_soft_cap;
    wfk.field_extreme_precip_softness = field_extreme_precip_softness;
    wfk.field_land_evapotranspiration_gain = field_land_evapotranspiration_gain;
    wfk.field_ocean_precip_suppression = field_ocean_precip_suppression;
    wfk.field_frontogenesis_gain = field_frontogenesis_gain;
    wfk.field_rain_shadow_drying = field_rain_shadow_drying;
    wfk.field_advect_vapor = field_advect_vapor;
    wfk.field_advect_cloud = field_advect_cloud;
    wfk.field_rh_condense = field_rh_condense;
    wfk.field_static_cond_w = field_static_cond_w;
    wfk.field_condense_rate = field_condense_rate;
    wfk.field_lift_cond_gain = field_lift_cond_gain;
    wfk.field_conv_cond_gain = field_conv_cond_gain;
    wfk.field_thermal_conv_cond = field_thermal_conv_cond;
    wfk.field_thermal_conv_precip = field_thermal_conv_precip;
    wfk.field_autoconversion = field_autoconversion;
    wfk.field_precip_base_frac = field_precip_base_frac;
    wfk.field_lift_precip_gain = field_lift_precip_gain;
    wfk.field_conv_precip_gain = field_conv_precip_gain;
    wfk.field_oro_precip_gain = field_oro_precip_gain;
    wfk.field_stratiform_gain = field_stratiform_gain;
    wfk.field_cool_season_vapor_floor = field_cool_season_vapor_floor;
    wfk.field_cloud_reevap = field_cloud_reevap;
    wfk.weather_cell_pos_scale = weather_cell_pos_scale;
    wfk.weather_wrap_width_x = weather_wrap_width_x;
    wfk.cold_precip_as_blizzard = cold_precip_as_blizzard;
    wfk.snow_classification_margin = snow_classification_margin;
    wfk.weather_lat_te_norm = weather_lat_te_norm;
    wfk.omega_ascent_gain = OMEGA_ASCENT_GAIN;
    wfk.world_bounds_pos_y = wb_pos_y;
    wfk.world_bounds_size_y = wb_size_y;
    wfk.syn_supp = syn_supp;
    wfk.syn_enh = syn_enh;
    wfk.syn_front_force = syn_front_force;
    wfk.syn_front_enh = syn_front_enh;
    wfk.syn_base_lift = syn_base_lift;
    wfk.weather_transition_enabled = weather_transition_enabled;
    wfk.weather_transition_alpha_rate = weather_transition_alpha_rate;
    wfk.weather_transition_dt_days = weather_transition_dt_days;
    // 这两个原来在每 cell 的循环体里各查一次 Dictionary。
    wfk.thermal_monsoon_enabled = bool(knobs.get("thermal_monsoon_enabled",
        _native_runtime_config.get("thermal_monsoon_enabled", false)));
    wfk.cyclone_storm_type_id = uint8_t(
        std::clamp(int(knobs.get("cyclone_storm_type_id", 2)), 0, 255));

    pk_async_climate::WeatherFieldLanes wfl;
    wfl.temp_read = TR;
    wfl.moisture_read = MR;
    wfl.air_anomaly = AA;
    wfl.wind_x = WX;
    wfl.wind_y = WY;
    wfl.wind_speed = WSPD;
    wfl.terrain = TERR;
    wfl.has_river = RIV;
    wfl.river_q30 = RQ30;
    wfl.elevation = ELEV;
    wfl.vegetation = VEG;
    wfl.soil_moisture = SOIL;
    wfl.vitality = VITA;
    wfl.sea_ice = SICE;
    wfl.pos_x = _wf_pos_x.data();
    wfl.pos_y = _wf_pos_y.data();
    wfl.temp_anomaly = TANO;
    wfl.snow_cover = SNOWR;
    wfl.neighbor_indices = NB;
    wfl.prev_vapor = PV;
    wfl.prev_precip = PP;
    wfl.prev_cloud_water = PCW;
    wfl.temp_transport_anomaly = TA;
    wfl.prev_convergence = PREV_CNV;
    wfl.prev_cloud = PREV_CLOUD;
    wfl.out_vapor = OUT_VAP;
    wfl.out_cloud = OUT_CLD;
    wfl.out_cloud_water = OUT_CW;
    wfl.out_precip = OUT_PRE;
    wfl.out_instability = OUT_INS;
    wfl.out_intensity = OUT_INT;
    wfl.out_convergence = OUT_CNV;
    wfl.out_type_u8 = OUT_TYP;
    wfl.out_type_i32 = OUT_TYP_I32;
    wfl.out_prev_type = OUT_PREV_TYP;
    wfl.out_target_type = OUT_TARGET_TYP;
    wfl.out_alpha = OUT_ALPHA;
    wfl.out_field_init = OUT_FIN;

    pk_async_climate::WeatherFieldState wfs;
    wfs.conv_inhib = INHIB;
    wfs.psi = PSI;
    wfs.cyclone_tag = _cyclone_force_tag.empty() ? nullptr : _cyclone_force_tag.data();
    wfs.cyclone_tag_count = int(_cyclone_force_tag.size());
    wfs.cyclone_generation = _cyclone_force_generation;
    wfs.cyclone_lift = _cyclone_force_lift.empty() ? nullptr : _cyclone_force_lift.data();
    wfs.cyclone_x = _cyclone_force_x.empty() ? nullptr : _cyclone_force_x.data();
    wfs.cyclone_y = _cyclone_force_y.empty() ? nullptr : _cyclone_force_y.data();
    wfs.monsoon_thermal = _phys_monsoon_thermal.empty()
        ? nullptr : _phys_monsoon_thermal.data();
    wfs.monsoon_thermal_count = int(_phys_monsoon_thermal.size());
    wfs.traj_idx = TRAJ_IDX;
    wfs.traj_w = TRAJ_W;
    wfs.geom_dx = GEOM_DX;
    wfs.geom_dy = GEOM_DY;
    wfs.geom_invd = GEOM_INVD;

    // 记录给 worker 对拍用的输入。必须在 solve 之前：conv_inhib / ψ / 过渡三条都是
    // in/out，跑完再记就变成记结果。只在 start_idx == 0 那一次记 —— sliced 路径会把
    // 同一天切成多段调用，每段重记一次的话后面几段读到的 conv_inhib 已经是本轮改过
    // 的了。stage bit 同理只置一次。
    if (start_idx == 0) {
        pk_async_climate::SynopticAdvanceKnobs syn_rec;
        if (PSI != nullptr) {
            syn_rec.baroclinic = syn_baroclinic;
            syn_rec.damp = syn_damp;
            syn_rec.diffuse = syn_diffuse;
            syn_rec.seed_rate = syn_seed_rate;
            syn_rec.seed_amp = syn_seed_amp;
            syn_rec.adv_cells = syn_adv_cells;
            syn_rec.tick = syn_tick;
            syn_rec.cell_pos_scale = weather_cell_pos_scale;
            syn_rec.wrap_width_x = weather_wrap_width_x;
        }
        record_production_weather_input(wfk, syn_rec, PSI != nullptr, wfl, wfs,
                                       n_cells, s_wfin.arr_u8.ptr());
        _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
    }

    if (use_next_outputs && (end_idx - start_idx) >= 256) {
        // staged 路径并行（native daily）。区间 [start_idx, end_idx) → 0-based n + 偏移。
        pk::parallel_for_range("pk_weather_field", end_idx - start_idx,
            [&](int b, int e) {
                pk_async_climate::weather_field_solve_pure(
                    wfk, wfl, wfs, start_idx + b, start_idx + e);
            });
    } else {
        pk_async_climate::weather_field_solve_pure(
            wfk, wfl, wfs, start_idx, end_idx);
    }

    // §11.2 flush: push CoW-detached weather output slots back to MapData
    {
        // NS 化 Phase 2 诊断键:轨迹表消费状态进 knobs(两条 return 路径共用)。
        Dictionary &diag_knobs = const_cast<Dictionary &>(knobs);
        diag_knobs["wind_traj_used"] = (TRAJ_IDX != nullptr);
        diag_knobs["wind_traj_stale_count"] = _phys_wind_traj_stale_count;
    }
    if (use_next_outputs) {
        Dictionary &mutable_knobs = const_cast<Dictionary &>(knobs);
        mutable_knobs["out_vapor"] = out_vapor_arr;
        mutable_knobs["out_cloud"] = out_cloud_arr;
        if (out_cloud_water_arr.size() == n_cells) {
            mutable_knobs["out_cloud_water"] = out_cloud_water_arr;
        }
        mutable_knobs["out_precip"] = out_precip_arr;
        mutable_knobs["out_instability"] = out_instability_arr;
        mutable_knobs["out_intensity"] = out_intensity_arr;
        mutable_knobs["out_convergence"] = out_convergence_arr;
        mutable_knobs["out_type"] = out_type_arr;
        mutable_knobs["weather_field_wrote_next"] = true;
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }

    if (!bool(knobs.get("defer_flush", false))) {
        _flush_slot_to_map(sid_w_vapor);
        _flush_slot_to_map(sid_w_cloud);
        _flush_slot_to_map(sid_w_precip);
        _flush_slot_to_map(sid_w_inst);
        _flush_slot_to_map(sid_w_intens);
        _flush_slot_to_map(sid_w_conv);
        _flush_slot_to_map(sid_w_type);
        if (weather_transition_enabled) {
            _flush_slot_to_map(sid_w_prev_type);
            _flush_slot_to_map(sid_w_target_type);
            _flush_slot_to_map(sid_w_transition_alpha);
        }
        _flush_slot_to_map(sid_w_finit);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.1b: weather field commit / publish pass ─────────────────────────────
Dictionary DCWorldExt::run_weather_field_commit_pass(Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["commit_loop_ms"] = 0.0;
    out["weather_dirty_count"] = 0;
    out["water_budget_error"] = 0.0;
    out["active_weather_ratio"] = 0.0;
    out["weather_convergence_dirty_count"] = 0;
    out["weather_convergence_deltas"] = PackedFloat32Array();
    out["convergence_published"] = false;
    out["weather_lut"] = PackedByteArray();
    out["weather_lut_changed"] = false;
    out["weather_lut_dirty_count"] = 0;
    out["weather_lut_full_rebuild"] = false;
    out["path"] = String("gdext_commit");
    out["reason"] = String();


    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_field_commit_pass: ", why,
            " — fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not _bound");

    if (!knobs.has("n_cells") || !knobs.has("neighbor_indices") ||
        !knobs.has("prev_vapor") || !knobs.has("out_vapor") ||
        !knobs.has("out_cloud") || !knobs.has("out_precip") ||
        !knobs.has("out_instability") || !knobs.has("out_intensity") ||
        !knobs.has("out_convergence") || !knobs.has("out_type")) {
        return fail("knobs missing required keys");
    }

    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) return fail("n_cells <= 0");
    const bool refresh_convergence = knobs.has("refresh_convergence")
        ? bool(knobs["refresh_convergence"]) : false;

    const bool weather_transition_enabled = bool(knobs.get("weather_transition_enabled", false));
    float transition_rate = float(knobs.get("weather_transition_alpha_rate", 1.0));
    if (transition_rate < 0.0f) transition_rate = 0.0f;
    else if (transition_rate > 1.0f) transition_rate = 1.0f;
    // [dt-aware transition 2026-06-28] 见 run_weather_field_solve_pass 同名注释：过渡按游戏天数推进，避免加速档吞短暂天气。
    float transition_dt_days = float(knobs.get("weather_transition_dt_days", 1.0));
    if (transition_dt_days < 0.0f) transition_dt_days = 0.0f;
    else if (transition_dt_days > 30.0f) transition_dt_days = 30.0f;
    const int lut_w = int(knobs.get("weather_lut_w", 0));
    const int lut_h = int(knobs.get("weather_lut_h", 0));
    const int lut_slots = (lut_w > 0 && lut_h > 0 && lut_w * lut_h >= n_cells) ? (lut_w * lut_h) : n_cells;

    PackedInt32Array nb_arr = knobs["neighbor_indices"];

    PackedFloat32Array prev_vapor_arr = knobs["prev_vapor"];
    PackedFloat32Array out_vapor_arr = knobs["out_vapor"];
    PackedFloat32Array out_cloud_arr = knobs["out_cloud"];
    PackedFloat32Array out_cloud_water_arr;
    PackedFloat32Array out_precip_arr = knobs["out_precip"];
    PackedFloat32Array out_instability_arr = knobs["out_instability"];
    PackedFloat32Array out_intensity_arr = knobs["out_intensity"];
    PackedFloat32Array out_convergence_arr = knobs["out_convergence"];
    PackedInt32Array out_type_arr = knobs["out_type"];
    if (knobs.has("out_cloud_water")) {
        out_cloud_water_arr = knobs["out_cloud_water"];
    }

    if (nb_arr.size() < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");
    if (prev_vapor_arr.size() != n_cells ||
        out_vapor_arr.size() != n_cells ||
        out_cloud_arr.size() != n_cells ||
        out_precip_arr.size() != n_cells ||
        out_instability_arr.size() != n_cells ||
        out_intensity_arr.size() != n_cells ||
        out_convergence_arr.size() != n_cells ||
        out_type_arr.size() != n_cells) {
        return fail("packed output size mismatch");
    }
    if (out_cloud_water_arr.size() != 0 && out_cloud_water_arr.size() != n_cells) {
        return fail("out_cloud_water size mismatch");
    }

    const int sid_w_intens = component_id(StringName("cell_weather_intensity"));
    const int sid_w_cloud = component_id(StringName("cell_weather_cloud"));
    const int sid_w_cloud_water = component_id(StringName("cell_weather_cloud_water"));
    const int sid_w_precip = component_id(StringName("cell_weather_precip"));
    const int sid_w_type = component_id(StringName("cell_weather_type"));
    const int sid_w_prev_type = component_id(StringName("cell_weather_prev_type"));
    const int sid_w_target_type = component_id(StringName("cell_weather_target_type"));
    const int sid_w_transition_alpha = component_id(StringName("cell_weather_transition_alpha"));
    const int sid_w_vapor = component_id(StringName("cell_weather_vapor"));
    const int sid_w_conv = component_id(StringName("cell_weather_convergence"));
    const int sid_w_inst = component_id(StringName("cell_weather_instability"));
    const int sid_w_finit = component_id(StringName("cell_weather_field_init"));
    const int sid_w_dirty = component_id(StringName("cell_weather_dirty"));

    if (sid_w_intens < 0 || sid_w_cloud < 0 || sid_w_precip < 0 ||
        sid_w_type < 0 || sid_w_vapor < 0 || sid_w_conv < 0 ||
        sid_w_inst < 0 || sid_w_finit < 0 || sid_w_dirty < 0) {
        return fail("missing required weather slot id");
    }

    Slot &s_wint = _slots.write[sid_w_intens];
    Slot &s_wcld = _slots.write[sid_w_cloud];
    Slot *s_wcw = (sid_w_cloud_water >= 0) ? &_slots.write[sid_w_cloud_water] : nullptr;
    Slot &s_wpre = _slots.write[sid_w_precip];
    Slot &s_wtyp = _slots.write[sid_w_type];
    Slot *s_wprev = (sid_w_prev_type >= 0) ? &_slots.write[sid_w_prev_type] : nullptr;
    Slot *s_wtarget = (sid_w_target_type >= 0) ? &_slots.write[sid_w_target_type] : nullptr;
    Slot *s_walpha = (sid_w_transition_alpha >= 0) ? &_slots.write[sid_w_transition_alpha] : nullptr;
    Slot &s_wvap = _slots.write[sid_w_vapor];
    Slot &s_wcnv = _slots.write[sid_w_conv];
    Slot &s_wins = _slots.write[sid_w_inst];
    Slot &s_wfin = _slots.write[sid_w_finit];
    Slot &s_wdirty = _slots.write[sid_w_dirty];

    if (s_wint.arr_f32.size() != n_cells || s_wcld.arr_f32.size() != n_cells ||
        s_wpre.arr_f32.size() != n_cells || s_wtyp.arr_u8.size() != n_cells ||
        s_wvap.arr_f32.size() != n_cells || s_wcnv.arr_f32.size() != n_cells ||
        s_wins.arr_f32.size() != n_cells || s_wfin.arr_u8.size() != n_cells ||
        s_wdirty.arr_u8.size() != n_cells) {
        return fail("slot array size mismatch");
    }
    if (s_wcw != nullptr && s_wcw->arr_f32.size() != n_cells) {
        return fail("cloud_water slot size mismatch");
    }
    if (weather_transition_enabled &&
        (s_wprev == nullptr || s_wtarget == nullptr || s_walpha == nullptr)) {
        return fail("weather transition slot size mismatch");
    }
    if (s_wprev != nullptr && s_wprev->arr_u8.size() != n_cells) {
        return fail("weather prev_type slot size mismatch");
    }
    if (s_wtarget != nullptr && s_wtarget->arr_u8.size() != n_cells) {
        return fail("weather target_type slot size mismatch");
    }
    if (s_walpha != nullptr && s_walpha->arr_f32.size() != n_cells) {
        return fail("weather transition_alpha slot size mismatch");
    }

    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict PREV_VAP = prev_vapor_arr.ptr();
    const float * const __restrict NEXT_VAP = out_vapor_arr.ptr();
    const float * const __restrict NEXT_CLD = out_cloud_arr.ptr();
    const float * const __restrict NEXT_CW =
        (out_cloud_water_arr.size() == n_cells) ? out_cloud_water_arr.ptr() : nullptr;
    const float * const __restrict NEXT_PRE = out_precip_arr.ptr();
    const float * const __restrict NEXT_INS = out_instability_arr.ptr();
    const float * const __restrict NEXT_INT = out_intensity_arr.ptr();
    const float * const __restrict NEXT_CNV = out_convergence_arr.ptr();
    const int32_t * const __restrict NEXT_TYP = out_type_arr.ptr();

    PackedByteArray weather_lut;
    weather_lut.resize(lut_slots * 4);
    uint8_t * const __restrict WX = weather_lut.ptrw();
    auto q01_byte_commit = [](float v) -> uint8_t {
        if (v <= 0.0f) return uint8_t(0);
        if (v >= 1.0f) return uint8_t(255);
        return uint8_t(std::clamp(int(std::round(double(v) * 255.0)), 0, 255));
    };

    float * const __restrict W_INT = s_wint.arr_f32.ptrw();

    float * const __restrict W_CLD = s_wcld.arr_f32.ptrw();
    float * const __restrict W_CW = (s_wcw != nullptr) ? s_wcw->arr_f32.ptrw() : nullptr;
    float * const __restrict W_PRE = s_wpre.arr_f32.ptrw();
    uint8_t * const __restrict W_TYP = s_wtyp.arr_u8.ptrw();
    uint8_t * const __restrict W_PREV = (s_wprev != nullptr) ? s_wprev->arr_u8.ptrw() : nullptr;
    uint8_t * const __restrict W_TARGET = (s_wtarget != nullptr) ? s_wtarget->arr_u8.ptrw() : nullptr;
    float * const __restrict W_ALPHA = (s_walpha != nullptr) ? s_walpha->arr_f32.ptrw() : nullptr;
    float * const __restrict W_VAP = s_wvap.arr_f32.ptrw();
    float * const __restrict W_CNV = s_wcnv.arr_f32.ptrw();
    float * const __restrict W_INS = s_wins.arr_f32.ptrw();
    uint8_t * const __restrict W_FIN = s_wfin.arr_u8.ptrw();
    uint8_t * const __restrict W_DIRTY = s_wdirty.arr_u8.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    // S3 P3：计算体已提取为 pk_async_climate::weather_commit_pure，worker 走同一份。
    PackedFloat32Array convergence_deltas;
    if (refresh_convergence) {
        convergence_deltas.resize(n_cells);
    }

    pk_async_climate::WeatherCommitKnobs wck;
    wck.n_cells                    = n_cells;
    wck.refresh_convergence        = refresh_convergence;
    wck.weather_transition_enabled = weather_transition_enabled;
    wck.transition_rate            = transition_rate;
    wck.transition_dt_days         = transition_dt_days;
    wck.lut_slots                  = lut_slots;

    pk_async_climate::WeatherCommitLanes wcl;
    wcl.next_vapor        = NEXT_VAP;
    wcl.next_cloud        = NEXT_CLD;
    wcl.next_cloud_water  = NEXT_CW;
    wcl.next_precip       = NEXT_PRE;
    wcl.next_instability  = NEXT_INS;
    wcl.next_intensity    = NEXT_INT;
    wcl.next_convergence  = NEXT_CNV;
    wcl.next_type         = NEXT_TYP;
    wcl.prev_vapor        = PREV_VAP;
    wcl.neighbor_indices  = NB;
    wcl.intensity         = W_INT;
    wcl.cloud             = W_CLD;
    wcl.cloud_water       = W_CW;
    wcl.precip            = W_PRE;
    wcl.vapor             = W_VAP;
    wcl.convergence       = W_CNV;
    wcl.instability       = W_INS;
    wcl.type              = W_TYP;
    wcl.prev_type         = W_PREV;
    wcl.target_type       = W_TARGET;
    wcl.transition_alpha  = W_ALPHA;
    wcl.field_init        = W_FIN;
    wcl.dirty             = W_DIRTY;
    wcl.lut               = WX;
    wcl.convergence_deltas = refresh_convergence ? convergence_deltas.ptrw() : nullptr;

    pk_async_climate::WeatherCommitStats wcs;
    pk_async_climate::weather_commit_pure(wck, wcl, wcs);
    const int dirty_count = wcs.dirty_count;
    const int convergence_dirty_count = wcs.convergence_dirty_count;
    const double water_budget_error_acc = wcs.water_budget_error_sum;

    _flush_slot_to_map(sid_w_intens);
    _flush_slot_to_map(sid_w_cloud);
    if (sid_w_cloud_water >= 0) _flush_slot_to_map(sid_w_cloud_water);
    _flush_slot_to_map(sid_w_precip);
    _flush_slot_to_map(sid_w_type);
    if (sid_w_prev_type >= 0) _flush_slot_to_map(sid_w_prev_type);
    if (sid_w_target_type >= 0) _flush_slot_to_map(sid_w_target_type);
    if (sid_w_transition_alpha >= 0) _flush_slot_to_map(sid_w_transition_alpha);
    _flush_slot_to_map(sid_w_vapor);
    _flush_slot_to_map(sid_w_conv);
    _flush_slot_to_map(sid_w_inst);
    _flush_slot_to_map(sid_w_finit);
    _flush_slot_to_map(sid_w_dirty);

    auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = elapsed_ms;
    out["commit_loop_ms"] = elapsed_ms;
    out["weather_dirty_count"] = dirty_count;
    out["weather_lut"] = weather_lut;
    out["weather_lut_changed"] = dirty_count > 0;
    out["weather_lut_dirty_count"] = dirty_count;
    out["weather_lut_full_rebuild"] = true;
    if (refresh_convergence && convergence_deltas.size() > convergence_dirty_count) {

        convergence_deltas.resize(convergence_dirty_count);
    }
    out["weather_convergence_dirty_count"] = convergence_dirty_count;
    out["weather_convergence_deltas"] = convergence_deltas;
    out["convergence_published"] = refresh_convergence;
    out["water_budget_error"] = water_budget_error_acc / double(std::max(n_cells, 1));
    out["active_weather_ratio"] = double(dirty_count) / double(std::max(n_cells, 1));
    return out;
}

// ─── F.2c: wind heat transport, air mass pass ───────────────────────────────
double DCWorldExt::run_wind_air_mass_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_wind_air_mass_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_y   = component_id(StringName("cell_wind_y"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_air_anom = component_id(StringName("cell_air_mass_temp_anomaly"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    if (sid_temp < 0 || sid_wind_x < 0 || sid_wind_y < 0 || sid_wind_spd < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_air_anom < 0) {
        diag("missing slot id (temp/wind/wind_speed/pos/air_anom)");
        return -1.0;
    }

    const bool read_temp_from_slot = knobs.has("read_temp_from_slot") && bool(knobs["read_temp_from_slot"]);
    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || (!read_temp_from_slot && !knobs.has("temp_before_arr"))) {
        diag("knobs missing required keys");
        return -1.0;
    }

    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    const float heat_mix     = float(knobs["heat_mix"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    const int end_idx_raw = knobs.has("end_idx") ? int(knobs["end_idx"]) : n_cells;
    if (start_idx < 0 || start_idx > n_cells) { diag("invalid start_idx"); return -1.0; }
    const int end_idx = std::min(std::max(end_idx_raw, start_idx), n_cells);

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr;
    if (!read_temp_from_slot) {
        temp_before_arr = knobs["temp_before_arr"];
    }
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (baseline_arr.size() != n_cells) { diag("baseline_arr size mismatch"); return -1.0; }
    if (!read_temp_from_slot && temp_before_arr.size() != n_cells) {
        diag("temp_before_arr size mismatch");
        return -1.0;
    }

    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_wind_x   = _slots.write[sid_wind_x];
    Slot &s_wind_y   = _slots.write[sid_wind_y];
    Slot &s_wind_spd = _slots.write[sid_wind_spd];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_air_anom = _slots.write[sid_air_anom];
    if (s_temp.arr_f32.size() != n_cells || s_wind_x.arr_f32.size() != n_cells ||
        s_wind_y.arr_f32.size() != n_cells || s_wind_spd.arr_f32.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells ||
        s_pos_y.arr_f32.size() != n_cells || s_air_anom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    const float * const __restrict WX = s_wind_x.arr_f32.ptr();
    const float * const __restrict WY = s_wind_y.arr_f32.ptr();
    const float * const __restrict WSP = s_wind_spd.arr_f32.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    float * const __restrict A = s_air_anom.arr_f32.ptrw();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict BL = baseline_arr.ptr();
    const float * const __restrict TB = read_temp_from_slot
        ? s_temp.arr_f32.ptr()
        : temp_before_arr.ptr();

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x10, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // NS 化 Phase 2:风场回溯轨迹表消费资格(与 weather field solve 同一契约:
    // 指纹失配 → 旧 hopping 并计数;knob wind_traj_weather_share=false → 仅构建不消费)。
    const int32_t *TRAJ_IDX = nullptr;
    const float   *TRAJ_W   = nullptr;
    if (_phys_wind_traj_valid && _phys_wind_traj_consume_enabled
            && int(_phys_wind_traj_idx.size()) == n_cells * 3) {
        if (pk_wind_state_fp(n_cells, WX, WY, WSP) == _phys_wind_traj_fp) {
            TRAJ_IDX = _phys_wind_traj_idx.data();
            TRAJ_W   = _phys_wind_traj_w.data();
        } else {
            ++_phys_wind_traj_stale_count;
        }
    }

    // S3：baseline 与轨迹表都不是 slot，capture 侧取不到，worker 只能靠这里照抄。
    // 分片调用时每一片都记同一份（内容与 start_idx 无关），最后一片覆盖前面的，
    // 结果一致。
    {
        auto wa_in = std::make_shared<pk_async_climate::WindAirInput>();
        wa_in->n_cells = n_cells;
        wa_in->baseline.assign(BL, BL + n_cells);
        wa_in->wind_x.assign(WX, WX + n_cells);
        wa_in->wind_y.assign(WY, WY + n_cells);
        wa_in->wind_speed.assign(WSP, WSP + n_cells);
        if (TRAJ_IDX != nullptr && TRAJ_W != nullptr) {
            wa_in->traj_idx.assign(TRAJ_IDX, TRAJ_IDX + size_t(n_cells) * 3u);
            wa_in->traj_w.assign(TRAJ_W, TRAJ_W + size_t(n_cells) * 3u);
        }
        _production_wind_air = std::move(wa_in);
    }

    // S3：这一段曾与 worker 的 _async_wind_air_kernel_pure 是两份实现，差三处
    // （轨迹表分支、isfinite 兜底、baseline 来源），温度链条因此在 round 里偏。
    // 现在两边都调这一个内核。
    {
        pk_async_climate::WindAirKnobs wa_knobs;
        wa_knobs.n_cells = n_cells;
        wa_knobs.advect_steps = advect_steps;
        wa_knobs.heat_mix = heat_mix;
        wa_knobs.wrap_period_x = wrap_period_x;

        pk_async_climate::WindAirLanes wa_lanes;
        wa_lanes.wind_x = WX;
        wa_lanes.wind_y = WY;
        wa_lanes.wind_speed = WSP;
        wa_lanes.pos_x = POSX;
        wa_lanes.pos_y = POSY;
        wa_lanes.temp_before = TB;
        wa_lanes.baseline = BL;
        wa_lanes.neighbor_indices = NB;
        wa_lanes.traj_idx = TRAJ_IDX;
        wa_lanes.traj_w = TRAJ_W;
        wa_lanes.air_anomaly = A;

        pk_async_climate::wind_air_pure(wa_knobs, wa_lanes, start_idx, end_idx);
    }

    knobs["cursor_start"] = start_idx;
    knobs["cursor_end"] = end_idx;
    knobs["processed_cells"] = end_idx - start_idx;
    knobs["wind_traj_used"] = (TRAJ_IDX != nullptr);
    knobs["wind_traj_stale_count"] = _phys_wind_traj_stale_count;

    if (!bool(knobs.get("defer_flush", false))) {
        _flush_slot_to_map(sid_air_anom);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.2d: wind heat transport, surface injection pass ──────────────────────
double DCWorldExt::run_wind_surface_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_wind_surface_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_y   = component_id(StringName("cell_wind_y"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_air_anom = component_id(StringName("cell_air_mass_temp_anomaly"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    // A 修复（2026-06）：wind_surface 是 climate-daily 链中唯一写 cell_temp 的 pass。
    // 末端把 baseline + transport(ocean+air) + local_anom 合成为 cell_temp。
    const int sid_baseline = component_id(StringName("cell_temp_baseline"));
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    const int sid_lanom    = component_id(StringName("cell_local_thermal_anomaly"));
    if (sid_temp < 0 || sid_wind_x < 0 || sid_wind_y < 0 || sid_wind_spd < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_air_anom < 0 || sid_iswater < 0 ||
        sid_baseline < 0 || sid_oanom < 0 || sid_lanom < 0) {
        diag("missing slot id (temp/wind/wind_speed/pos/air_anom/is_water/baseline/ocean_anom/local_anom)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("air_leak") ||
        !knobs.has("neighbor_indices") || !knobs.has("fallback_baseline_arr")) {
        diag("knobs missing required keys");
        return -1.0;
    }

    const int n_cells = int(knobs["n_cells"]);
    const float air_leak = float(knobs["air_leak"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    const float cold_transport_form = knobs.has("cold_transport_form_threshold")
        ? float(knobs["cold_transport_form_threshold"]) : 0.06f;
    const float cold_transport_melt = knobs.has("cold_transport_melt_threshold")
        ? float(knobs["cold_transport_melt_threshold"]) : 0.11f;
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    const int end_idx_raw = knobs.has("end_idx") ? int(knobs["end_idx"]) : n_cells;
    if (start_idx < 0 || start_idx > n_cells) { diag("invalid start_idx"); return -1.0; }
    const int end_idx = std::min(std::max(end_idx_raw, start_idx), n_cells);

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array fallback_baseline = knobs["fallback_baseline_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (fallback_baseline.size() != n_cells) { diag("fallback_baseline_arr size mismatch"); return -1.0; }

    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_wind_x   = _slots.write[sid_wind_x];
    Slot &s_wind_y   = _slots.write[sid_wind_y];
    Slot &s_wind_spd = _slots.write[sid_wind_spd];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_air_anom = _slots.write[sid_air_anom];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_baseline = _slots.write[sid_baseline];
    Slot &s_oanom    = _slots.write[sid_oanom];
    Slot &s_lanom    = _slots.write[sid_lanom];
    if (s_temp.arr_f32.size() != n_cells || s_wind_x.arr_f32.size() != n_cells ||
        s_wind_y.arr_f32.size() != n_cells || s_wind_spd.arr_f32.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells ||
        s_pos_y.arr_f32.size() != n_cells || s_air_anom.arr_f32.size() != n_cells ||
        s_iswater.arr_u8.size() != n_cells ||
        s_baseline.arr_f32.size() != n_cells || s_oanom.arr_f32.size() != n_cells ||
        s_lanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    PackedFloat32Array anomaly_src = s_air_anom.arr_f32;
    if (anomaly_src.size() != n_cells) { diag("air anomaly size mismatch"); return -1.0; }
    PackedFloat32Array anomaly_out = anomaly_src.duplicate();

    float * const __restrict T = s_temp.arr_f32.ptrw();
    const float * const __restrict WX = s_wind_x.arr_f32.ptr();
    const float * const __restrict WY = s_wind_y.arr_f32.ptr();
    const float * const __restrict WSP = s_wind_spd.arr_f32.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const float * const __restrict AIN = anomaly_src.ptr();
    float * const __restrict AOUT = anomaly_out.ptrw();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict FBL = fallback_baseline.ptr();
    // A 修复（2026-06）：合成需要 baseline / ocean anomaly / local anomaly。
    const float * const __restrict BL_RUNTIME = s_baseline.arr_f32.ptr();
    const float * const __restrict OANOM      = s_oanom.arr_f32.ptr();
    const float * const __restrict LANOM      = s_lanom.arr_f32.ptr();

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x20, knobs);
    // oanom 是分叉链头，且它的权威在生产的分片 ocean stage 手里（见
    // WindSurfaceInput 注释）。在消费点记录，抽到的就是生产真正用的那份。
    record_production_wind_surface_input(n_cells, OANOM);

    auto t0 = std::chrono::high_resolution_clock::now();

    // S3：与 worker 的 _async_wind_surface_kernel_pure 合成一个内核。两份主循环
    // 此前恰好逐位相同，但那是运气——它们连 smoothstep 都调的是不同函数，只是
    // 在当前 knobs 下数学等价。合了之后 cell_temp 只有一个写法。
    {
        pk_async_climate::WindSurfaceKnobs ws_knobs;
        ws_knobs.n_cells = n_cells;
        ws_knobs.air_leak = air_leak;
        ws_knobs.wrap_period_x = wrap_period_x;
        ws_knobs.cold_transport_form = cold_transport_form;
        ws_knobs.cold_transport_melt = cold_transport_melt;

        pk_async_climate::WindSurfaceLanes ws_lanes;
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
        ws_lanes.temp_out = T;

        pk_async_climate::wind_surface_pure(ws_knobs, ws_lanes, start_idx, end_idx);
    }

    s_air_anom.arr_f32 = anomaly_out;
    knobs["cursor_start"] = start_idx;
    knobs["cursor_end"] = end_idx;
    knobs["processed_cells"] = end_idx - start_idx;

    if (!bool(knobs.get("defer_flush", false))) {
        _flush_slot_to_map(sid_temp);
        _flush_slot_to_map(sid_air_anom);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.6 main pass ──────────────────────────────────────────────────────────
//
// 1:1 mirror of scripts/weather/weather_front.gd::advance_one_day +
// refresh_visual_lifecycle (line 74-127).
//
// fronts ≤ 16 → 不分 phase / 不需要 stage buffer，直接 in-place 改 batch
// 内的 PackedArray ptrw。emergent_coupling（decay_mul / precip_bonus）由
// caller 在 GDScript 端预算（需要 map 查询），通过：
//   1. caller 改 fronts[i].decay_per_day *= decay_mul（pack 之前）
//   2. caller 在 apply_dict_to_fronts 之后再加 precip_bonus 到 precip_amount
// C++ 端只做"机械"循环（无 map 访问 / 无 Variant）。
double DCWorldExt::run_weather_front_advect_pass(Dictionary knobs) {
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;
    using godot::PackedVector2Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_front_advect_pass: ", why,
            " — fallback to GDScript");
    };

    if (!knobs.has("n_fronts")) { diag("missing n_fronts"); return -1.0; }
    const int n = int(knobs["n_fronts"]);
    if (n <= 0) {
        // 空 front 列表是合法情况（某些季节没有活跃 front）；
        // 不打 warning，只 return 0.0（视为成功完成 0 行工作）。
        return 0.0;
    }
    const float max_turn = float(knobs.get("max_axis_turn_rad", 0.383972f));

    // 必填 keys。缺任一即 fallback。
    static const char *required_keys[] = {
        "front_center_x", "front_center_y",
        "front_velocity_x", "front_velocity_y",
        "front_axis_x", "front_axis_y",
        "front_stable_axis_x", "front_stable_axis_y",
        "front_radius", "front_intensity", "front_decay_per_day",
        "front_age_days", "front_type", "front_ttl_days",
        "front_life_progress", "front_cloud_amount",
        "front_precip_amount", "front_dissolve_amount", "front_alive",
        "wind_per_front",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_weather_front_advect_pass: missing key '", k, "'");
            return -1.0;
        }
    }

    // 取 PackedArray（CoW shared via Dictionary refcount）。
    PackedFloat32Array center_x = knobs["front_center_x"];
    PackedFloat32Array center_y = knobs["front_center_y"];
    PackedFloat32Array velocity_x = knobs["front_velocity_x"];
    PackedFloat32Array velocity_y = knobs["front_velocity_y"];
    PackedFloat32Array axis_x = knobs["front_axis_x"];
    PackedFloat32Array axis_y = knobs["front_axis_y"];
    PackedFloat32Array stable_axis_x = knobs["front_stable_axis_x"];
    PackedFloat32Array stable_axis_y = knobs["front_stable_axis_y"];
    PackedFloat32Array radius_arr = knobs["front_radius"];
    PackedFloat32Array intensity_arr = knobs["front_intensity"];
    PackedFloat32Array decay_arr = knobs["front_decay_per_day"];
    PackedInt32Array   age_days_arr = knobs["front_age_days"];
    PackedInt32Array   type_arr = knobs["front_type"];
    PackedInt32Array   ttl_arr = knobs["front_ttl_days"];
    PackedFloat32Array life_progress_arr = knobs["front_life_progress"];
    PackedFloat32Array cloud_amount_arr = knobs["front_cloud_amount"];
    PackedFloat32Array precip_amount_arr = knobs["front_precip_amount"];
    PackedFloat32Array dissolve_amount_arr = knobs["front_dissolve_amount"];
    PackedByteArray    alive_arr = knobs["front_alive"];
    PackedVector2Array wind_arr = knobs["wind_per_front"];

    // size 校验
    if (center_x.size() != n || center_y.size() != n ||
        velocity_x.size() != n || velocity_y.size() != n ||
        axis_x.size() != n || axis_y.size() != n ||
        stable_axis_x.size() != n || stable_axis_y.size() != n ||
        radius_arr.size() != n || intensity_arr.size() != n ||
        decay_arr.size() != n || age_days_arr.size() != n ||
        type_arr.size() != n || ttl_arr.size() != n ||
        life_progress_arr.size() != n || cloud_amount_arr.size() != n ||
        precip_amount_arr.size() != n || dissolve_amount_arr.size() != n ||
        alive_arr.size() != n || wind_arr.size() != n) {
        diag("PackedArray size != n_fronts");
        return -1.0;
    }

    // ptrw / ptr
    float * const __restrict CX = center_x.ptrw();
    float * const __restrict CY = center_y.ptrw();
    float * const __restrict VX = velocity_x.ptrw();
    float * const __restrict VY = velocity_y.ptrw();
    float * const __restrict AX = axis_x.ptrw();
    float * const __restrict AY = axis_y.ptrw();
    float * const __restrict SAX = stable_axis_x.ptrw();
    float * const __restrict SAY = stable_axis_y.ptrw();
    const float * const __restrict R   = radius_arr.ptr();
    float * const __restrict I_  = intensity_arr.ptrw();
    const float * const __restrict D   = decay_arr.ptr();
    int32_t * const __restrict AGE = age_days_arr.ptrw();
    const int32_t * const __restrict TY = type_arr.ptr();
    const int32_t * const __restrict TTL = ttl_arr.ptr();
    float * const __restrict LP  = life_progress_arr.ptrw();
    float * const __restrict CA  = cloud_amount_arr.ptrw();
    float * const __restrict PA  = precip_amount_arr.ptrw();
    float * const __restrict DA  = dissolve_amount_arr.ptrw();
    uint8_t * const __restrict AL = alive_arr.ptrw();
    const godot::Vector2 * const __restrict WIND = wind_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // helpers
    auto length2 = [](float x, float y) -> float { return x*x + y*y; };
    auto smoothstep_fn = [](float a, float b, float x) -> float {
        if (b <= a) return x >= b ? 1.0f : 0.0f;
        float t = (x - a) / (b - a);
        if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
        return t * t * (3.0f - 2.0f * t);
    };
    auto clampf = [](float v, float lo, float hi) -> float {
        return v < lo ? lo : (v > hi ? hi : v);
    };
    auto maxf2 = [](float a, float b) -> float { return a > b ? a : b; };

    // WeatherType.WT enum (weather_type.gd:23-32):
    //   CLEAR=0, RAIN=1, STORM=2, BLIZZARD=3, DROUGHT=4, FOG=5, HEATWAVE=6, MONSOON=7
    constexpr int WT_CLEAR    = 0;
    constexpr int WT_STORM    = 2;
    constexpr int WT_BLIZZARD = 3;
    constexpr int WT_DROUGHT  = 4;
    constexpr int WT_FOG      = 5;
    constexpr int WT_HEATWAVE = 6;
    constexpr int WT_MONSOON  = 7;

    for (int i = 0; i < n; ++i) {
        // ─── advance_one_day part ─────────────────────────────────────
        const godot::Vector2 wind = WIND[i];
        const float wind_len2 = length2(wind.x, wind.y);
        if (wind_len2 > 0.0025f /* 0.05^2 */) {
            // wind 有效 → 旋转 stable_axis 朝向 wind_axis（最多 max_turn 弧度）
            const float wind_len = std::sqrt(wind_len2);
            const float wax = wind.x / wind_len;
            const float way = wind.y / wind_len;

            // from_axis = stable_axis (or fallback Vector2.RIGHT if degenerate)
            float fx = SAX[i];
            float fy = SAY[i];
            float fl2 = length2(fx, fy);
            if (fl2 < 0.0001f) { fx = 1.0f; fy = 0.0f; fl2 = 1.0f; }
            const float fl = std::sqrt(fl2);
            fx /= fl; fy /= fl;

            // delta_angle = angle_to(from, to) = atan2(cross, dot)（与 GDScript Vector2.angle_to 等价）
            const float dot_   = fx * wax + fy * way;
            const float cross_ = fx * way - fy * wax;
            float delta = std::atan2(cross_, dot_);
            if (delta > max_turn) delta = max_turn;
            else if (delta < -max_turn) delta = -max_turn;

            // out = from.rotated(delta)
            const float cs = std::cos(delta);
            const float sn = std::sin(delta);
            float out_x = fx * cs - fy * sn;
            float out_y = fx * sn + fy * cs;
            const float ol2 = length2(out_x, out_y);
            if (ol2 > 0.0001f) {
                const float ol = std::sqrt(ol2);
                out_x /= ol; out_y /= ol;
            } else {
                // degenerate → keep from_axis
                out_x = fx; out_y = fy;
            }

            SAX[i] = out_x; SAY[i] = out_y;
            AX[i]  = out_x; AY[i]  = out_y;
            VX[i] = out_x * (R[i] * 0.4f);
            VY[i] = out_y * (R[i] * 0.4f);
        }
        // center += velocity
        CX[i] += VX[i];
        CY[i] += VY[i];
        // intensity = max(intensity - decay_per_day, 0)
        float new_i = I_[i] - D[i];
        if (new_i < 0.0f) new_i = 0.0f;
        I_[i] = new_i;
        // age_days++
        AGE[i] += 1;

        // ─── refresh_visual_lifecycle part ────────────────────────────
        const float ttl_f = (TTL[i] >= 1) ? float(TTL[i]) : 1.0f;
        float life_p = float(AGE[i]) / ttl_f;
        if (life_p < 0.0f) life_p = 0.0f; else if (life_p > 1.0f) life_p = 1.0f;
        LP[i] = life_p;

        const float dissolve = smoothstep_fn(0.58f, 1.0f, life_p);
        DA[i] = dissolve;

        // _visual_intensity(intensity)
        const float raw_i = clampf(new_i, 0.0f, 1.0f);
        float visual_i = 0.0f;
        if (raw_i > 0.0f) {
            // pow(raw_i, 0.55) * smoothstep(0, 0.08, raw_i)
            const float pw = std::pow(raw_i, 0.55f);
            const float ss = smoothstep_fn(0.0f, 0.08f, raw_i);
            visual_i = clampf(pw * ss, 0.0f, 1.0f);
        }

        const float birth = smoothstep_fn(0.0f, 0.32f, life_p);
        float cloud_retire  = 1.0f - smoothstep_fn(0.78f, 1.0f, life_p);
        float precip_retire = 1.0f - smoothstep_fn(0.56f, 0.88f, life_p);

        float cloud_mul = 1.0f;
        float precip_mul = 1.0f;
        const int t_kind = TY[i];
        switch (t_kind) {
            case WT_STORM:
                cloud_mul = 1.22f;
                precip_mul = 1.32f;
                precip_retire = 1.0f - smoothstep_fn(0.46f, 0.80f, life_p);
                break;
            case WT_MONSOON:
                cloud_mul = 1.18f;
                precip_mul = 1.22f;
                precip_retire = 1.0f - smoothstep_fn(0.70f, 0.96f, life_p);
                break;
            case WT_BLIZZARD:
                cloud_mul = 1.10f;
                precip_mul = 1.18f;
                break;
            case WT_FOG:
                cloud_mul = 1.28f;
                precip_mul = 0.0f;
                cloud_retire = 1.0f - smoothstep_fn(0.62f, 1.0f, life_p);
                break;
            case WT_DROUGHT:
            case WT_HEATWAVE:
                cloud_mul = 0.24f;
                precip_mul = 0.0f;
                break;
            case WT_CLEAR:
                cloud_mul = 0.0f;
                precip_mul = 0.0f;
                break;
            default:
                // RAIN 等：保持 1.0 / 1.0
                break;
        }
        (void) maxf2; // 未使用（保留 helper 给未来扩展）
        CA[i] = clampf(visual_i * birth * cloud_retire * cloud_mul, 0.0f, 1.0f);
        PA[i] = clampf(visual_i * birth * precip_retire * precip_mul, 0.0f, 1.0f);

        // is_alive: intensity > 0.01 && age_days < ttl_days
        AL[i] = (new_i > 0.01f && AGE[i] < TTL[i]) ? 1 : 0;
    }

    // 写回 knobs（PackedArray 是 CoW：ptrw 后已经 detach；这里赋值确保
    // GDScript 端 Dictionary 拿到的是新 buffer 而不是 stale alias）。
    knobs["front_center_x"] = center_x;
    knobs["front_center_y"] = center_y;
    knobs["front_velocity_x"] = velocity_x;
    knobs["front_velocity_y"] = velocity_y;
    knobs["front_axis_x"] = axis_x;
    knobs["front_axis_y"] = axis_y;
    knobs["front_stable_axis_x"] = stable_axis_x;
    knobs["front_stable_axis_y"] = stable_axis_y;
    knobs["front_intensity"] = intensity_arr;
    knobs["front_age_days"] = age_days_arr;
    knobs["front_life_progress"] = life_progress_arr;
    knobs["front_cloud_amount"] = cloud_amount_arr;
    knobs["front_precip_amount"] = precip_amount_arr;
    knobs["front_dissolve_amount"] = dissolve_amount_arr;
    knobs["front_alive"] = alive_arr;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）─────────────────────
//
// dist：_distribute_weather_field_to_cells C++ 化（任务 4 实装）
// summary：_build_field_summary_fronts C++ 化（任务 7 实装）
//
// 本段（任务 2）只搭骨架：
//   - 注册函数名与签名稳定，让 GDScript 端 has_method + 签名 arg-count
//     检测能识别新方法；
//   - elapsed_ms 返回 -1.0 → caller 永远走 GDScript fallback；
//   - 持久化状态容器先 lazy alloc 占位（任务 7 实装时填）。
// ───────────────────────────────────────────────────────────────────────────

// 内部持久化状态结构（仅 .cpp 可见）已在文件顶部 pk 命名空间声明
// （PrevSummarySeed / WeatherSummaryState）；本匿名 namespace 仅提供 helper。
namespace {

// 取/创建 opaque state（lazy alloc）。caller 不持有所有权。
inline WeatherSummaryState *get_or_create_summary_state(void *&opaque) {
    if (opaque == nullptr) {
        opaque = new WeatherSummaryState();
    }
    return static_cast<WeatherSummaryState *>(opaque);
}

inline void destroy_summary_state(void *&opaque) {
    if (opaque != nullptr) {
        delete static_cast<WeatherSummaryState *>(opaque);
        opaque = nullptr;
    }
}

} // namespace

Dictionary DCWorldExt::run_weather_distribute_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["cover_dirty"] = false;
    out["changed_cells"] = PackedInt32Array();

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_distribute_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return out; }

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── SoA slot resolve（一次性查 component_id）────────────────────────
    const int sid_temp        = component_id(StringName("cell_temp"));
    const int sid_moisture    = component_id(StringName("cell_moisture"));
    const int sid_snow_cover  = component_id(StringName("cell_snow_cover"));
    const int sid_snowpack    = component_id(StringName("cell_snowpack"));
    const int sid_water_bal   = component_id(StringName("cell_water_balance_30d"));
    const int sid_soil_moist  = component_id(StringName("cell_soil_moisture"));
    const int sid_heat_input  = component_id(StringName("cell_heat_input"));
    const int sid_cover       = component_id(StringName("cell_cover"));
    const int sid_landform    = component_id(StringName("cell_landform"));
    const int sid_terrain     = component_id(StringName("cell_terrain"));
    const int sid_elevation   = component_id(StringName("cell_elevation"));
    const int sid_w_intens    = component_id(StringName("cell_weather_intensity"));
    const int sid_w_precip    = component_id(StringName("cell_weather_precip"));
    const int sid_w_type      = component_id(StringName("cell_weather_type"));
    const int sid_w_finit     = component_id(StringName("cell_weather_field_init"));
    if (sid_temp     < 0 || sid_moisture  < 0 || sid_snow_cover < 0 ||
        sid_snowpack < 0 || sid_water_bal < 0 || sid_soil_moist < 0 ||
        sid_heat_input < 0 || sid_cover   < 0 ||
        sid_landform < 0 || sid_terrain  < 0 || sid_elevation < 0 || sid_w_intens  < 0 ||
        sid_w_precip < 0 || sid_w_type    < 0 || sid_w_finit   < 0) {
        diag("missing slot id (some weather/cover/landform component not bound)");
        return out;
    }

    // ─── knobs 校验 + 拉取 ──────────────────────────────────────────────
    static const char * const required_keys[] = {
        "n_cells", "snow_min_intensity",
        "snow_freeze_t", "snow_melt_t", "snow_intensity_for_snowing",
        "snow_accum_days_req",
        "flood_heavy_intensity", "flood_heavy_precip",
        "flood_lowland_intensity", "flood_lowland_elev", "flood_lowland_moisture",
        "wt_clear", "cv_snow", "cv_none", "cv_flooding",
        "accumulated_snow_days", "pre_snow_cover",
        "temp_delta_arr", "moisture_delta_arr",
        "can_form_snow_arr", "can_form_flood_arr",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_weather_distribute_pass: missing key '", k, "'");
            return out;
        }
    }

    // 标量收进 POD 结构体。span / band 的下限保护不在这里做 ——
    // weather_distribute_pure 自己按 cover_low/full 与 band 推，避免两份公式。
    pk_async_climate::WeatherDistributeKnobs wdk;
    const int n_cells = int(knobs["n_cells"]);
    wdk.n_cells = n_cells;
    wdk.snow_min_intensity = float(knobs["snow_min_intensity"]);
    wdk.snow_freeze_t = float(knobs["snow_freeze_t"]);
    wdk.snow_melt_t = float(knobs["snow_melt_t"]);
    wdk.snow_intensity_snow = float(knobs["snow_intensity_for_snowing"]);
    wdk.snow_accum_days_req = int(knobs["snow_accum_days_req"]);
    wdk.flood_heavy_int = float(knobs["flood_heavy_intensity"]);
    wdk.flood_heavy_pre = float(knobs["flood_heavy_precip"]);
    wdk.flood_low_int = float(knobs["flood_lowland_intensity"]);
    wdk.flood_low_elev = float(knobs["flood_lowland_elev"]);
    wdk.flood_low_moist = float(knobs["flood_lowland_moisture"]);
    wdk.wt_clear = int(knobs["wt_clear"]);
    wdk.cv_snow = int(knobs["cv_snow"]);
    wdk.cv_none = int(knobs["cv_none"]);
    wdk.cv_flooding = int(knobs["cv_flooding"]);
    wdk.snowpack_accum_gain = knobs.has("snowpack_accum_gain")
        ? float(knobs["snowpack_accum_gain"]) : 0.10f;
    wdk.snowpack_melt_temp_gain = knobs.has("snowpack_melt_temp_gain")
        ? float(knobs["snowpack_melt_temp_gain"]) : 0.22f;
    wdk.snowpack_melt_sun_gain = knobs.has("snowpack_melt_sun_gain")
        ? float(knobs["snowpack_melt_sun_gain"]) : 0.12f;
    wdk.snowpack_cover_low = knobs.has("snowpack_cover_low")
        ? float(knobs["snowpack_cover_low"]) : 0.05f;
    wdk.snowpack_cover_full = knobs.has("snowpack_cover_full")
        ? float(knobs["snowpack_cover_full"]) : 0.32f;
    wdk.snowline_temp_threshold = knobs.has("snowline_temp_threshold")
        ? float(knobs["snowline_temp_threshold"]) : 0.24f;
    wdk.snowline_band = knobs.has("snowline_band") ? float(knobs["snowline_band"]) : 0.22f;
    float weather_temp_anomaly_cap = knobs.has("weather_temp_anomaly_cap")
        ? float(knobs["weather_temp_anomaly_cap"]) : 0.025f;
    if (weather_temp_anomaly_cap < 0.0f) weather_temp_anomaly_cap = 0.0f;
    else if (weather_temp_anomaly_cap > 0.10f) weather_temp_anomaly_cap = 0.10f;
    wdk.weather_temp_anomaly_cap = weather_temp_anomaly_cap;
    const bool direct_moisture_enabled =
        bool(knobs.get("weather_direct_moisture_enabled", false));
    wdk.direct_moisture_enabled = direct_moisture_enabled;

    PackedInt32Array  acc_snow_days  = knobs["accumulated_snow_days"];
    PackedInt32Array  pre_snow_cover = knobs["pre_snow_cover"];
    PackedFloat32Array temp_delta_arr   = knobs["temp_delta_arr"];
    PackedFloat32Array moist_delta_arr  = knobs["moisture_delta_arr"];
    PackedByteArray   cfs_arr         = knobs["can_form_snow_arr"];
    PackedByteArray   cff_arr         = knobs["can_form_flood_arr"];

    if (n_cells <= 0) { diag("n_cells <= 0"); return out; }
    if (acc_snow_days.size() != n_cells || pre_snow_cover.size() != n_cells) {
        diag("acc_snow_days / pre_snow_cover size != n_cells");
        return out;
    }
    if (temp_delta_arr.size() != 8 || moist_delta_arr.size() != 8 ||
        cfs_arr.size() != 8 || cff_arr.size() != 8) {
        diag("WeatherType profile arrays must be length 8");
        return out;
    }

    // ─── SoA 直接走 _slots[id].arr_f32/arr_u8.ptrw（避免 local copy 触发 CoW
    // detach 把本地数据脱离 _slots）。读端用 ptr() 同样直接走 _slots。
    // 写端最后调 _flush_slot_to_map(sid) 把 CoW-detach 后的新 buffer 推回
    // GDScript MapData property（与 F.1 / F.2 / F.3 等同模式）。──────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moisture];
    Slot &s_snow_cov = _slots.write[sid_snow_cover];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_waterbal = _slots.write[sid_water_bal];
    Slot &s_soil     = _slots.write[sid_soil_moist];
    const Slot &s_heat = _slots[sid_heat_input];
    Slot &s_cover    = _slots.write[sid_cover];
    const Slot &s_lf       = _slots[sid_landform];
    const Slot &s_terrain  = _slots[sid_terrain];
    const Slot &s_elev     = _slots[sid_elevation];
    const Slot &s_w_int    = _slots[sid_w_intens];
    const Slot &s_w_pre    = _slots[sid_w_precip];
    const Slot &s_w_typ    = _slots[sid_w_type];
    const Slot &s_w_fin    = _slots[sid_w_finit];

    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow_cov.arr_f32.size() < n_cells || s_snowpack.arr_f32.size() < n_cells ||
        s_waterbal.arr_f32.size() < n_cells || s_soil.arr_f32.size() < n_cells ||
        s_heat.arr_f32.size() < n_cells ||
        s_cover.arr_u8.size() < n_cells || s_lf.arr_u8.size() < n_cells ||
        s_terrain.arr_u8.size() < n_cells ||
        s_elev.arr_f32.size() < n_cells || s_w_int.arr_f32.size() < n_cells ||
        s_w_pre.arr_f32.size() < n_cells || s_w_typ.arr_u8.size() < n_cells ||
        s_w_fin.arr_u8.size() < n_cells) {
        diag("SoA size < n_cells");
        return out;
    }

    // ─── ptrw / ptr ────────────────────────────────────────────────────
    // 四张剖面表拷进 knobs：它们是 8 项定长表，进 POD 结构体后 worker 不必再持有
    // Godot PackedArray。长度已在上面校验过恰好是 8。
    std::memcpy(wdk.temp_delta, temp_delta_arr.ptr(), 8 * sizeof(float));
    std::memcpy(wdk.moist_delta, moist_delta_arr.ptr(), 8 * sizeof(float));
    std::memcpy(wdk.can_form_snow, cfs_arr.ptr(), 8);
    std::memcpy(wdk.can_form_flood, cff_arr.ptr(), 8);

    pk_async_climate::WeatherDistributeLanes wdl;
    wdl.temp = s_temp.arr_f32.ptrw();
    wdl.moisture = s_moist.arr_f32.ptrw();
    wdl.snow_cover = s_snow_cov.arr_f32.ptrw();
    wdl.snowpack = s_snowpack.arr_f32.ptrw();
    wdl.water_balance_30d = s_waterbal.arr_f32.ptrw();
    wdl.soil_moisture = s_soil.arr_f32.ptrw();
    wdl.cover = s_cover.arr_u8.ptrw();
    wdl.landform = s_lf.arr_u8.ptr();
    wdl.terrain = s_terrain.arr_u8.ptr();
    wdl.elevation = s_elev.arr_f32.ptr();
    wdl.heat = s_heat.arr_f32.ptr();
    wdl.weather_intensity = s_w_int.arr_f32.ptr();
    wdl.weather_precip = s_w_pre.arr_f32.ptr();
    wdl.weather_type = s_w_typ.arr_u8.ptr();
    wdl.weather_field_init = s_w_fin.arr_u8.ptr();

    pk_async_climate::WeatherDistributeState wds;
    wds.accumulated_snow_days = acc_snow_days.ptrw();
    wds.pre_snow_cover = pre_snow_cover.ptrw();

    // 数值核心已抽成共享纯内核 pk_async_climate::weather_distribute_pure，那几个
    // 局部 lambda 也跟着进去了。这里只留 Godot 侧的装配、记录与 flush。
    // 记录必须在内核之前：temp / moisture / snowpack / cover / 两条积雪计数全是
    // in/out，跑完再记就变成记结果。
    record_production_weather_distribute_input(wdk, wdl, wds, n_cells);
    pk_async_climate::WeatherDistributeEmit wde;
    pk_async_climate::weather_distribute_pure(wdk, wdl, wds, wde);
    PackedInt32Array changed_cells;
    if (!wde.changed_cells.empty()) {
        changed_cells.resize(int(wde.changed_cells.size()));
        std::memcpy(changed_cells.ptrw(), wde.changed_cells.data(),
                    wde.changed_cells.size() * sizeof(int32_t));
    }
    const bool cover_dirty = wde.cover_dirty;

    // ─── §11.2 flush：把 CoW-detach 后的 temp/moisture/cover 推回 GDScript
    // MapData property（与 F.1 / F.2 等同模式）。──────────────────────────
    _flush_slot_to_map(sid_temp);
    if (direct_moisture_enabled && !bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moisture);
    }
    _flush_slot_to_map(sid_snow_cover);
    _flush_slot_to_map(sid_snowpack);
    _flush_slot_to_map(sid_water_bal);
    _flush_slot_to_map(sid_soil_moist);
    _flush_slot_to_map(sid_cover);
    out["moisture_written"] = direct_moisture_enabled;

    // ─── 把改写后的 PackedInt32Array 通过 out Dictionary 返回（PackedArray ptrw
    // 触发 CoW 后会重新分配 buffer，本地 acc_snow_days / pre_snow_cover 持有新
    // buffer；knobs Dictionary 里仍是旧 buffer ref。所以必须放进 out 让 caller 取）─
    auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = elapsed;
    out["cover_dirty"] = cover_dirty;
    out["changed_cells"] = changed_cells;
    out["accumulated_snow_days"] = acc_snow_days;
    out["pre_snow_cover"] = pre_snow_cover;
    return out;
}

Dictionary DCWorldExt::run_weather_summary_fronts_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;
    using godot::Vector2;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fronts"] = Array();

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_summary_fronts_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return out; }

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── knobs ─────────────────────────────────────────────────────────
    static const char * const required_keys[] = {
        "n_cells", "hex_size", "summary_limit",
        "intensity_enter", "intensity_hold",
        "merge_ratio", "merge_max_rounds",
        "radius_base", "radius_scale",
        "wt_clear", "cell_q_arr", "cell_r_arr",
        "neighbor_indices",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_weather_summary_fronts_pass: missing key '", k, "'");
            return out;
        }
    }

    const int   n_cells          = int(knobs["n_cells"]);
    const float hex_size         = float(knobs["hex_size"]);
    const int   summary_limit    = int(knobs["summary_limit"]);
    const float intensity_enter  = float(knobs["intensity_enter"]);
    const float intensity_hold   = float(knobs["intensity_hold"]);
    const float merge_ratio      = float(knobs["merge_ratio"]);
    const int   merge_max_rounds = int(knobs["merge_max_rounds"]);
    const float radius_base      = float(knobs["radius_base"]);
    const float radius_scale     = float(knobs["radius_scale"]);
    const int   wt_clear         = int(knobs["wt_clear"]);
    PackedInt32Array cell_q = knobs["cell_q_arr"];
    PackedInt32Array cell_r = knobs["cell_r_arr"];

    if (n_cells <= 0) { diag("n_cells <= 0"); return out; }
    if (cell_q.size() != n_cells || cell_r.size() != n_cells) {
        diag("cell_q_arr / cell_r_arr size mismatch");
        return out;
    }

    // ─── SoA slot resolve ──────────────────────────────────────────────
    const int sid_w_intens  = component_id(StringName("cell_weather_intensity"));
    const int sid_w_precip  = component_id(StringName("cell_weather_precip"));
    const int sid_w_type    = component_id(StringName("cell_weather_type"));
    const int sid_w_cloud   = component_id(StringName("cell_weather_cloud"));
    const int sid_w_finit   = component_id(StringName("cell_weather_field_init"));
    const int sid_wind_x    = component_id(StringName("cell_wind_x"));
    const int sid_wind_y    = component_id(StringName("cell_wind_y"));
    const int sid_temp      = component_id(StringName("cell_temp"));
    if (sid_w_intens < 0 || sid_w_precip < 0 || sid_w_type < 0 ||
        sid_w_cloud  < 0 || sid_w_finit  < 0 || sid_wind_x < 0 || sid_wind_y < 0 ||
        sid_temp < 0) {
        diag("missing slot id (weather_*/wind_x/wind_y/cell_temp)");
        return out;
    }
    const Slot &s_w_int   = _slots[sid_w_intens];
    const Slot &s_w_pre   = _slots[sid_w_precip];
    const Slot &s_w_typ   = _slots[sid_w_type];
    const Slot &s_w_cloud = _slots[sid_w_cloud];
    const Slot &s_w_fin   = _slots[sid_w_finit];
    const Slot &s_wind_x  = _slots[sid_wind_x];
    const Slot &s_wind_y  = _slots[sid_wind_y];
    const Slot &s_temp    = _slots[sid_temp];
    if (s_w_int.arr_f32.size()  < n_cells || s_w_pre.arr_f32.size() < n_cells ||
        s_w_typ.arr_u8.size()   < n_cells || s_w_cloud.arr_f32.size() < n_cells ||
        s_w_fin.arr_u8.size()   < n_cells || s_wind_x.arr_f32.size() < n_cells ||
        s_wind_y.arr_f32.size() < n_cells || s_temp.arr_f32.size() < n_cells) {
        diag("SoA size < n_cells");
        return out;
    }
    const float * const __restrict WI    = s_w_int.arr_f32.ptr();
    const float * const __restrict WP    = s_w_pre.arr_f32.ptr();
    const uint8_t * const __restrict WT_ = s_w_typ.arr_u8.ptr();
    const float * const __restrict WCL   = s_w_cloud.arr_f32.ptr();
    const uint8_t * const __restrict WFI = s_w_fin.arr_u8.ptr();
    const float * const __restrict WX    = s_wind_x.arr_f32.ptr();
    const float * const __restrict WY    = s_wind_y.arr_f32.ptr();
    const float * const __restrict T     = s_temp.arr_f32.ptr();

    // ─── neighbor_indices (n_cells*6, -1 = no neighbor) ────────────────
    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells*6");
        return out;
    }
    const int32_t * const __restrict NB = nb_arr.ptr();

    // ─── q/r → idx hash (lazy rebuild on size change) ──────────────────
    if (_summary_qr_to_idx_size != n_cells) {
        _summary_qr_to_idx.clear();
        _summary_qr_to_idx.reserve(n_cells * 2);
        for (int i = 0; i < n_cells; ++i) {
            const int64_t key = (int64_t(cell_q[i]) << 32) ^
                                (uint32_t(cell_r[i]) & 0xFFFFFFFFu);
            _summary_qr_to_idx[key] = i;
        }
        _summary_qr_to_idx_size = n_cells;
    }
    auto cube_to_idx = [&](int q, int r) -> int {
        const int64_t key = (int64_t(q) << 32) ^ (uint32_t(r) & 0xFFFFFFFFu);
        auto it = _summary_qr_to_idx.find(key);
        return (it == _summary_qr_to_idx.end()) ? -1 : it->second;
    };
    // Pointy-top hex 屏幕坐标（与 hex_utils.gd 严格同源）
    const double SQRT3 = 1.7320508075688772;
    auto cube_to_world_xy = [&](int q, int r) -> Vector2 {
        const double x = double(hex_size) * SQRT3 * (double(q) + double(r) * 0.5);
        const double y = double(hex_size) * 1.5 * double(r);
        return Vector2(float(x), float(y));
    };
    auto world_to_cube_idx = [&](Vector2 p) -> int {
        const double q_f = (SQRT3 / 3.0 * double(p.x) - 1.0 / 3.0 * double(p.y)) / double(hex_size);
        const double r_f = (2.0 / 3.0 * double(p.y)) / double(hex_size);
        const double s_f = -q_f - r_f;
        // _cube_round
        int rq = int(std::lround(q_f));
        int rr = int(std::lround(r_f));
        int rs = int(std::lround(s_f));
        const double dq = std::abs(double(rq) - q_f);
        const double dr = std::abs(double(rr) - r_f);
        const double ds = std::abs(double(rs) - s_f);
        if (dq > dr && dq > ds) {
            rq = -rr - rs;
        } else if (dr > ds) {
            rr = -rq - rs;
        }
        return cube_to_idx(rq, rr);
    };
    auto neighbor_aligned_idx = [&](int idx, float dir_x, float dir_y) -> int {
        const float len2 = dir_x * dir_x + dir_y * dir_y;
        if (idx < 0 || idx >= n_cells || len2 <= 0.0001f) {
            return -1;
        }
        const float inv_len = 1.0f / std::sqrt(len2);
        const float nx = dir_x * inv_len;
        const float ny = dir_y * inv_len;
        const Vector2 self_wp = cube_to_world_xy(cell_q[idx], cell_r[idx]);
        float best_dot = hex_size * 0.31176915f;
        int best_idx = -1;
        const int32_t *nb_row = NB + idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb = nb_row[d];
            if (nb < 0 || nb >= n_cells) continue;
            const Vector2 nb_wp = cube_to_world_xy(cell_q[nb], cell_r[nb]);
            const Vector2 to_nb = nb_wp - self_wp;
            const float dot = to_nb.x * nx + to_nb.y * ny;
            if (dot > best_dot) {
                best_dot = dot;
                best_idx = nb;
            }
        }
        return best_idx;
    };
    auto front_diag_kind = [](float temp_adv) -> int {
        constexpr float FRONT_TEMP_ADVECTION_THRESHOLD = 0.015f;
        if (temp_adv > FRONT_TEMP_ADVECTION_THRESHOLD) return 1;
        if (temp_adv < -FRONT_TEMP_ADVECTION_THRESHOLD) return 2;
        return 0;
    };

    // ─── opaque state ──────────────────────────────────────────────────
    auto *summary_state = get_or_create_summary_state(_summary_state);
    std::vector<PrevSummarySeed> &prev_seeds = summary_state->prev_seeds;
    std::vector<int32_t> &prev_membership = summary_state->prev_membership;
    if (int(prev_membership.size()) != n_cells) {
        prev_membership.assign(n_cells, -1);
    }

    // ─── 工作结构 ──────────────────────────────────────────────────────
    struct Comp {
        int   type;
        Vector2 sum_pos;       // build 时 / sum_pos*count
        Vector2 sum_axis;
        float sum_cloud;
        float sum_precip;
        float sum_temp_adv;
        float temp_adv_weight;
        float max_intensity;
        float area;            // 用 float 因为 merge 后会聚合权重
        int   inherited_age;   // -1 表示 step 2 新生
        bool  has_inherited_center;
        Vector2 inherited_from_center;
        Vector2 inherited_from_velocity;
    };
    std::vector<Comp> comps;
    comps.reserve(64);

    std::vector<uint8_t> visited(n_cells, 0);
    std::vector<int32_t> new_membership(n_cells, -1);

    auto threshold_for = [&](int idx) -> float {
        return prev_membership[idx] >= 0 ? intensity_hold : intensity_enter;
    };
    auto cell_wt = [&](int idx) -> int {
        return WFI[idx] != 0 ? int(WT_[idx]) : wt_clear;
    };
    auto cell_intensity = [&](int idx) -> float {
        return WFI[idx] != 0 ? WI[idx] : 0.0f;
    };

    // BFS flood-fill：返回新增 component idx，cells 为空则不入。
    std::vector<int32_t> bfs_queue;
    bfs_queue.reserve(256);
    auto flood_fill = [&](int seed, int wt, int cluster_idx) -> bool {
        bfs_queue.clear();
        bfs_queue.push_back(seed);
        visited[seed] = 1;
        Comp comp;
        comp.type = wt;
        comp.sum_pos = Vector2();
        comp.sum_axis = Vector2();
        comp.sum_cloud = 0.0f;
        comp.sum_precip = 0.0f;
        comp.sum_temp_adv = 0.0f;
        comp.temp_adv_weight = 0.0f;
        comp.max_intensity = 0.0f;
        comp.area = 0.0f;
        comp.inherited_age = 0;
        comp.has_inherited_center = false;
        size_t qi = 0;
        while (qi < bfs_queue.size()) {
            int idx = bfs_queue[qi++];
            const int cwt = cell_wt(idx);
            const float ci = cell_intensity(idx);
            const float thresh_self = threshold_for(idx);
            if (cwt != wt || ci < thresh_self) {
                continue;
            }
            // 加入 cluster
            new_membership[idx] = cluster_idx;
            comp.sum_pos += cube_to_world_xy(cell_q[idx], cell_r[idx]);
            comp.sum_axis += Vector2(WX[idx], WY[idx]);
            comp.sum_cloud += WCL[idx];
            comp.sum_precip += WP[idx];
            const float wx = WX[idx];
            const float wy = WY[idx];
            if ((wx * wx + wy * wy) > 0.0001f) {
                const int upstream = neighbor_aligned_idx(idx, -wx, -wy);
                const int downstream = neighbor_aligned_idx(idx, wx, wy);
                if (downstream >= 0) {
                    const float upstream_temp = (upstream >= 0) ? T[upstream] : T[idx];
                    const float local_adv = upstream_temp - T[downstream];
                    comp.sum_temp_adv += local_adv * ci;
                    comp.temp_adv_weight += ci;
                }
            }
            if (ci > comp.max_intensity) comp.max_intensity = ci;
            comp.area += 1.0f;
            // 邻居
            const int32_t *nb_row = NB + idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb = nb_row[d];
                if (nb < 0 || visited[nb]) continue;
                const int nwt = cell_wt(nb);
                const float ni = cell_intensity(nb);
                const float thresh_nb = threshold_for(nb);
                if (nwt == wt && ni >= thresh_nb) {
                    visited[nb] = 1;
                    bfs_queue.push_back(nb);
                }
            }
        }
        if (comp.area <= 0.0f) {
            return false;
        }
        comp.sum_pos = comp.sum_pos / comp.area;
        comp.sum_axis = comp.sum_axis / comp.area;
        comp.sum_cloud /= comp.area;
        comp.sum_precip /= comp.area;
        comp.sum_temp_adv /= std::max(comp.temp_adv_weight, 0.001f);
        comps.push_back(comp);
        return true;
    };

    // ─── Step 1：prev seeds 优先（按 area 降序，与 GDScript 一致）──────
    std::vector<size_t> seed_order(prev_seeds.size());
    for (size_t i = 0; i < seed_order.size(); ++i) seed_order[i] = i;
    std::sort(seed_order.begin(), seed_order.end(), [&](size_t a, size_t b) {
        return prev_seeds[a].area > prev_seeds[b].area;
    });
    auto pick_inheritance_seed = [&](int seed_idx, int prev_type) -> int {
        // 1. seed_idx 本身可用？
        if (!visited[seed_idx]) {
            const int swt = cell_wt(seed_idx);
            const float si = cell_intensity(seed_idx);
            const float s_thresh = threshold_for(seed_idx);
            if (swt == prev_type && si >= s_thresh) return seed_idx;
        }
        // 2. 1-ring 邻居
        const int32_t *nb_row = NB + seed_idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb = nb_row[d];
            if (nb < 0 || visited[nb]) continue;
            const int nwt = cell_wt(nb);
            const float ni = cell_intensity(nb);
            const float thresh_nb = threshold_for(nb);
            if (nwt == prev_type && ni >= thresh_nb) return nb;
        }
        return -1;
    };
    for (size_t k : seed_order) {
        const PrevSummarySeed &ps = prev_seeds[k];
        const int seed_idx = world_to_cube_idx(Vector2(ps.center_x, ps.center_y));
        if (seed_idx < 0) continue;
        const int picked = pick_inheritance_seed(seed_idx, ps.type);
        if (picked < 0) continue;
        const int cluster_idx = int(comps.size());
        if (flood_fill(picked, ps.type, cluster_idx)) {
            Comp &c = comps.back();
            c.inherited_age = ps.age + 1;
            c.has_inherited_center = true;
            c.inherited_from_center = Vector2(ps.center_x, ps.center_y);
            c.inherited_from_velocity = Vector2(ps.velocity_x, ps.velocity_y);
        }
    }

    // ─── Step 2：剩余 cell 自起新 cluster ─────────────────────────────
    for (int i = 0; i < n_cells; ++i) {
        if (visited[i]) continue;
        const int wt = cell_wt(i);
        const float ci = cell_intensity(i);
        const float thresh = threshold_for(i);
        if (ci < thresh || wt == wt_clear) {
            visited[i] = 1;
            continue;
        }
        const int cluster_idx = int(comps.size());
        if (flood_fill(i, wt, cluster_idx)) {
            comps.back().inherited_age = 0;
        }
    }

    // 跨 tick 状态：在 merge 之前记录 cell→cluster 归属（与 GDScript 一致）。
    prev_membership = new_membership;

    // ─── Step 3：merge_nearby_components ───────────────────────────────
    auto eq_radius = [&](float area) -> float {
        return hex_size * std::sqrt(std::max(area, 1.0f)) * radius_scale;
    };
    bool changed = true;
    int rounds = 0;
    while (changed && rounds < merge_max_rounds) {
        changed = false;
        rounds += 1;
        const int n = int(comps.size());
        std::vector<int32_t> merged_into(n, -1);
        for (int i = 0; i < n; ++i) {
            if (merged_into[i] >= 0) continue;
            float ai = comps[i].area;
            float ri = eq_radius(ai);
            Vector2 ci_center = comps[i].sum_pos;
            const int type_i = comps[i].type;
            for (int j = i + 1; j < n; ++j) {
                if (merged_into[j] >= 0) continue;
                if (comps[j].type != type_i) continue;
                const float aj = comps[j].area;
                const float rj = eq_radius(aj);
                const Vector2 cj_center = comps[j].sum_pos;
                const float dist = ci_center.distance_to(cj_center);
                if (dist > (ri + rj) * merge_ratio) continue;
                // merge j → i
                const float total = ai + aj;
                comps[i].sum_pos = (ci_center * ai + cj_center * aj) / total;
                comps[i].sum_axis = (comps[i].sum_axis * ai + comps[j].sum_axis * aj) / total;
                comps[i].sum_cloud = (comps[i].sum_cloud * ai + comps[j].sum_cloud * aj) / total;
                comps[i].sum_precip = (comps[i].sum_precip * ai + comps[j].sum_precip * aj) / total;
                comps[i].sum_temp_adv = (comps[i].sum_temp_adv * ai + comps[j].sum_temp_adv * aj) / total;
                comps[i].max_intensity = std::max(comps[i].max_intensity, comps[j].max_intensity);
                comps[i].area = total;
                comps[i].inherited_age = std::max(comps[i].inherited_age, comps[j].inherited_age);
                // GDScript 用先合的"老" component 保留 inherited_from_*；这里保持 i 的字段不动
                // （与 GDScript 同：i 在前，j 在后，j 被吸收到 i）。
                ai = total;
                ri = eq_radius(ai);
                ci_center = comps[i].sum_pos;
                merged_into[j] = i;
                changed = true;
            }
        }
        if (changed) {
            std::vector<Comp> next;
            next.reserve(comps.size());
            for (int i = 0; i < n; ++i) {
                if (merged_into[i] < 0) next.push_back(std::move(comps[i]));
            }
            comps = std::move(next);
        }
    }

    // ─── Step 4：score 排序 + top-N + build front Dictionary ──────────
    auto score_of = [](const Comp &c) -> float {
        return c.max_intensity * std::sqrt(std::max(c.area, 1.0f));
    };
    std::sort(comps.begin(), comps.end(), [&](const Comp &a, const Comp &b) {
        return score_of(a) > score_of(b);
    });
    const int limit = std::min(summary_limit, int(comps.size()));
    Array fronts_out;
    fronts_out.resize(limit);
    std::vector<PrevSummarySeed> next_seeds;
    next_seeds.reserve(limit);

    // ─── Phase A.1 fronts zero-copy SoA：与 fronts 数组并存输出 ─────
    // 字段命名严格沿用 scripts/data_core/fronts_schema.gd FRONTS_SCHEMA cpp_name
    // 共 23 列：18 F32 + 4 I32 + 1 U8。所有列长度=limit，按 idx 与 fronts_out[i]
    // 1:1 对齐。GDScript 端 _unpack_summary_soa_to_fronts 走列扫描，跨语言
    // Variant entry 从 ~17*N → ~24 ref（与 N 无关），marshalling ~90% 削减。
    PackedFloat32Array soa_center_x;        soa_center_x.resize(limit);
    PackedFloat32Array soa_center_y;        soa_center_y.resize(limit);
    PackedFloat32Array soa_radius;          soa_radius.resize(limit);
    PackedFloat32Array soa_velocity_x;      soa_velocity_x.resize(limit);
    PackedFloat32Array soa_velocity_y;      soa_velocity_y.resize(limit);
    PackedFloat32Array soa_axis_x;          soa_axis_x.resize(limit);
    PackedFloat32Array soa_axis_y;          soa_axis_y.resize(limit);
    PackedFloat32Array soa_stable_axis_x;   soa_stable_axis_x.resize(limit);
    PackedFloat32Array soa_stable_axis_y;   soa_stable_axis_y.resize(limit);
    PackedFloat32Array soa_major_scale;     soa_major_scale.resize(limit);
    PackedFloat32Array soa_minor_scale;     soa_minor_scale.resize(limit);
    PackedFloat32Array soa_edge_seed;       soa_edge_seed.resize(limit);
    PackedFloat32Array soa_intensity;       soa_intensity.resize(limit);
    PackedFloat32Array soa_decay_per_day;   soa_decay_per_day.resize(limit);
    PackedFloat32Array soa_life_progress;   soa_life_progress.resize(limit);
    PackedFloat32Array soa_cloud_amount;    soa_cloud_amount.resize(limit);
    PackedFloat32Array soa_precip_amount;   soa_precip_amount.resize(limit);
    PackedFloat32Array soa_dissolve_amount; soa_dissolve_amount.resize(limit);
    PackedFloat32Array soa_temp_advection;  soa_temp_advection.resize(limit);
    PackedInt32Array   soa_type;            soa_type.resize(limit);
    PackedInt32Array   soa_ttl_days;        soa_ttl_days.resize(limit);
    PackedInt32Array   soa_age_days;        soa_age_days.resize(limit);
    PackedInt32Array   soa_world_idx;       soa_world_idx.resize(limit);
    PackedInt32Array   soa_diag_kind;       soa_diag_kind.resize(limit);
    PackedByteArray    soa_alive;           soa_alive.resize(limit);
    float *p_center_x = soa_center_x.ptrw();
    float *p_center_y = soa_center_y.ptrw();
    float *p_radius = soa_radius.ptrw();
    float *p_velocity_x = soa_velocity_x.ptrw();
    float *p_velocity_y = soa_velocity_y.ptrw();
    float *p_axis_x = soa_axis_x.ptrw();
    float *p_axis_y = soa_axis_y.ptrw();
    float *p_stable_axis_x = soa_stable_axis_x.ptrw();
    float *p_stable_axis_y = soa_stable_axis_y.ptrw();
    float *p_major_scale = soa_major_scale.ptrw();
    float *p_minor_scale = soa_minor_scale.ptrw();
    float *p_edge_seed = soa_edge_seed.ptrw();
    float *p_intensity = soa_intensity.ptrw();
    float *p_decay_per_day = soa_decay_per_day.ptrw();
    float *p_life_progress = soa_life_progress.ptrw();
    float *p_cloud_amount = soa_cloud_amount.ptrw();
    float *p_precip_amount = soa_precip_amount.ptrw();
    float *p_dissolve_amount = soa_dissolve_amount.ptrw();
    float *p_temp_advection = soa_temp_advection.ptrw();
    int32_t *p_type = soa_type.ptrw();
    int32_t *p_ttl_days = soa_ttl_days.ptrw();
    int32_t *p_age_days = soa_age_days.ptrw();
    int32_t *p_world_idx = soa_world_idx.ptrw();
    int32_t *p_diag_kind = soa_diag_kind.ptrw();
    uint8_t *p_alive = soa_alive.ptrw();

    for (int i = 0; i < limit; ++i) {
        const Comp &c = comps[i];
        Dictionary fd;
        fd["type"] = int(c.type);
        fd["center"] = c.sum_pos;
        const float intensity = std::clamp(c.max_intensity, 0.0f, 1.0f);
        fd["intensity"] = intensity;
        const float area = std::max(c.area, 1.0f);
        const float radius = hex_size * (radius_base + std::sqrt(area) * radius_scale);
        fd["radius"] = radius;
        Vector2 axis_v = c.sum_axis;
        if (axis_v.length_squared() <= 0.0001f) {
            axis_v = Vector2(1.0f, 0.0f);
        }
        const Vector2 axis = axis_v.normalized();
        fd["axis"] = axis;
        fd["stable_axis"] = axis;
        // velocity = (inherited 模式) EMA(prev_velocity, observed_drift, 0.5)
        //            (新生 模式)     axis * radius * 0.4
        Vector2 measured_velocity = axis * radius * 0.4f;
        if (c.has_inherited_center) {
            Vector2 observed_drift = c.sum_pos - c.inherited_from_center;
            const float max_drift = radius * 0.6f;
            if (observed_drift.length() > max_drift) {
                observed_drift = observed_drift.normalized() * max_drift;
            }
            measured_velocity = c.inherited_from_velocity.lerp(observed_drift, 0.5f);
        }
        fd["velocity"] = measured_velocity;
        fd["major_scale"] = 1.30f;
        fd["minor_scale"] = 0.85f;
        const int inherited_age = std::max(c.inherited_age, 0);
        fd["age_days"] = inherited_age;
        const int ttl_days_v = std::max(inherited_age * 3 + 12, 12);
        fd["ttl_days"] = ttl_days_v;
        fd["decay_per_day"] = 0.0f;
        // edge_seed = (i+1)*37 + int(center.x)*3 + int(center.y)*5
        const float edge_seed = float((i + 1) * 37 +
                                       int(c.sum_pos.x) * 3 +
                                       int(c.sum_pos.y) * 5);
        fd["edge_seed"] = edge_seed;
        const float cloud_amount = std::clamp(c.sum_cloud, 0.0f, 1.0f);
        const float precip_amount = std::clamp(c.sum_precip, 0.0f, 1.0f);
        fd["cloud_amount"] = cloud_amount;
        fd["precip_amount"] = precip_amount;
        fd["dissolve_amount"] = 0.0f;
        // life_progress = clamp(0.15 + age*0.08, 0.15, 0.45)
        const float life_progress = std::clamp(0.15f + float(inherited_age) * 0.08f, 0.15f, 0.45f);
        fd["life_progress"] = life_progress;
        const float temp_advection = c.sum_temp_adv;
        const int diag_kind = front_diag_kind(temp_advection);
        fd["front_temperature_advection"] = temp_advection;
        fd["front_diagnostic_kind"] = diag_kind;
        fronts_out[i] = fd;

        // ─── SoA 镜像写入（与 fd 同语义/同步序）──
        // alive 与 WeatherFront::is_alive() 等价：intensity > 0.01 && age_days < ttl_days
        p_center_x[i]        = c.sum_pos.x;
        p_center_y[i]        = c.sum_pos.y;
        p_radius[i]          = radius;
        p_velocity_x[i]      = measured_velocity.x;
        p_velocity_y[i]      = measured_velocity.y;
        p_axis_x[i]          = axis.x;
        p_axis_y[i]          = axis.y;
        p_stable_axis_x[i]   = axis.x;
        p_stable_axis_y[i]   = axis.y;
        p_major_scale[i]     = 1.30f;
        p_minor_scale[i]     = 0.85f;
        p_edge_seed[i]       = edge_seed;
        p_intensity[i]       = intensity;
        p_decay_per_day[i]   = 0.0f;
        p_life_progress[i]   = life_progress;
        p_cloud_amount[i]    = cloud_amount;
        p_precip_amount[i]   = precip_amount;
        p_dissolve_amount[i] = 0.0f;
        p_temp_advection[i]  = temp_advection;
        p_type[i]            = int32_t(c.type);
        p_ttl_days[i]        = int32_t(ttl_days_v);
        p_age_days[i]        = int32_t(inherited_age);
        p_world_idx[i]       = -1;  // 由 sync job 后续填写
        p_diag_kind[i]       = int32_t(diag_kind);
        p_alive[i]           = (intensity > 0.01f && inherited_age < ttl_days_v) ? uint8_t(1) : uint8_t(0);

        // next_seeds
        PrevSummarySeed ns;
        ns.type = c.type;
        ns.center_x = c.sum_pos.x;
        ns.center_y = c.sum_pos.y;
        ns.age = inherited_age;
        ns.area = int(area);
        ns.velocity_x = measured_velocity.x;
        ns.velocity_y = measured_velocity.y;
        next_seeds.push_back(ns);
    }
    prev_seeds = std::move(next_seeds);

    auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = elapsed;
    out["fronts"] = fronts_out;

    // ─── Phase A.1：填 fronts_soa Dictionary 并挂回 out ─────────
    Dictionary soa;
    soa["n_fronts"] = limit;
    soa["front_center_x"]        = soa_center_x;
    soa["front_center_y"]        = soa_center_y;
    soa["front_radius"]          = soa_radius;
    soa["front_velocity_x"]      = soa_velocity_x;
    soa["front_velocity_y"]      = soa_velocity_y;
    soa["front_axis_x"]          = soa_axis_x;
    soa["front_axis_y"]          = soa_axis_y;
    soa["front_stable_axis_x"]   = soa_stable_axis_x;
    soa["front_stable_axis_y"]   = soa_stable_axis_y;
    soa["front_major_scale"]     = soa_major_scale;
    soa["front_minor_scale"]     = soa_minor_scale;
    soa["front_edge_seed"]       = soa_edge_seed;
    soa["front_intensity"]       = soa_intensity;
    soa["front_decay_per_day"]   = soa_decay_per_day;
    soa["front_life_progress"]   = soa_life_progress;
    soa["front_cloud_amount"]    = soa_cloud_amount;
    soa["front_precip_amount"]   = soa_precip_amount;
    soa["front_dissolve_amount"] = soa_dissolve_amount;
    soa["front_temperature_advection"] = soa_temp_advection;
    soa["front_type"]            = soa_type;
    soa["front_ttl_days"]        = soa_ttl_days;
    soa["front_age_days"]        = soa_age_days;
    soa["front_world_idx"]       = soa_world_idx;
    soa["front_diagnostic_kind"] = soa_diag_kind;
    soa["front_alive"]           = soa_alive;
    out["fronts_soa"] = soa;
    return out;
}

// ─── plan/weather-refresh-cpp-all: cyclone wake step ─────────────────────
//
// 1:1 移植 scripts/weather/front_advect.gd::tick_cyclone_wake。维护
// _cyclone_perturbations（跨 tick 存活）。
//
// 算法（与 GDScript 严格 bit-equal）：
//   1) 衰减/淘汰：每个 entry days_left -= 1，<=0 删除；否则
//      vec = vec_init * float(days_left) / float(max(init_days, 1))
//   2) 注入：遍历 fronts_from_summary（Array[Dictionary]），仅
//      type == STORM (knobs["cyclone_storm_type_id"]) && intensity >= 0.8,
//      warm water + active precip/cloud + convective/convergence forcing
//      且中心 cell 是水面（is_water_lut[terrain]）时注入：
//        wind = velocity；若 length_sq < 1e-4 则 wind = (1,0)
//        tangent = (-wind.y, wind.x).normalized()
//        perturb = tangent * intensity * 0.6
//        key = cell.q * 10000 + cell.r
//      若同 key 已存在则覆盖（与 GDScript Dictionary 同语义）。
//
// 知识库笔记（front_advect.gd 注释）：扰动 key 必须用 q*10000+r，不是
// summary_qr_to_idx 的 (q<<32)^r 编码，否则 GDScript 镜像 bit-not-equal。
void DCWorldExt::_advance_and_stamp_cyclones(
        const Dictionary &knobs, int n_cells, const int32_t *neighbors,
        const Vector2 *positions, const uint8_t *terrain, const float *temp,
        const float *wind_x, const float *wind_y, const float *wind_speed,
        const float *vapor, const float *instability, const float *convergence,
        const float *lat_norm) {
    const bool enabled = bool(knobs.get("native_tropical_cyclone_enabled",
        _native_runtime_config.get("native_tropical_cyclone_enabled", false)));
    if (!enabled || n_cells <= 0 || neighbors == nullptr || positions == nullptr ||
        terrain == nullptr || temp == nullptr || wind_x == nullptr || wind_y == nullptr ||
        wind_speed == nullptr || vapor == nullptr || instability == nullptr || convergence == nullptr) return;
    if (_cyclone_force_tag.size() != static_cast<size_t>(n_cells)) {
        _cyclone_force_tag.assign(static_cast<size_t>(n_cells), 0u);
        _cyclone_visit_tag.assign(static_cast<size_t>(n_cells), 0u);
        _cyclone_force_x.assign(static_cast<size_t>(n_cells), 0.0f);
        _cyclone_force_y.assign(static_cast<size_t>(n_cells), 0.0f);
        _cyclone_force_lift.assign(static_cast<size_t>(n_cells), 0.0f);
    }
    if (++_cyclone_force_generation == 0u) {
        std::fill(_cyclone_force_tag.begin(), _cyclone_force_tag.end(), 0u);
        std::fill(_cyclone_visit_tag.begin(), _cyclone_visit_tag.end(), 0u);
        _cyclone_force_generation = 1u;
    }
    _cyclone_last_touched_cells = 0;
    const float dt_total = dc_clampf(float(knobs.get("weather_transition_dt_days", 1.0)), 0.0f, 30.0f);
    const int steps = std::max(1, int(std::ceil(dt_total)));
    const float dt = dt_total / float(steps);
    const float wb_y = float(knobs.get("world_bounds_pos_y", 0.0));
    const float wb_h = std::max(0.001f, float(knobs.get("world_bounds_size_y", 1.0)));
    const float wrap_x = std::max(0.0f, float(knobs.get("weather_wrap_width_x", 0.0)));
    const int max_radius = std::clamp(int(knobs.get("tropical_cyclone_max_radius_cells",
        _native_runtime_config.get("tropical_cyclone_max_radius_cells", 5))), 2, 6);
    for (CycloneWakeEntry &e : _cyclone_perturbations) {
        for (int step = 0; step < steps; ++step) {
            const int i = e.cell_idx;
            if (i < 0 || i >= n_cells) { e.intensity = 0.0f; break; }
            const float ny = dc_clampf((positions[i].y - wb_y) / wb_h, 0.0f, 1.0f);
            const float signed_lat = (ny - 0.5f) * 2.0f;
            float shear = 0.0f;
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[i * 6 + d];
                if (ni < 0) continue;
                const float dx = wind_x[ni] - wind_x[i], dy = wind_y[ni] - wind_y[i];
                shear = std::max(shear, std::sqrt(dx * dx + dy * dy) / 2.0f);
            }
            const bool on_water = wf_is_water_terrain(terrain[i]);
            const float potential = wf_smoothstep(0.54f, 0.76f, temp[i])
                * wf_smoothstep(0.42f, 0.72f, vapor[i])
                * (0.35f + 0.65f * std::max(instability[i], convergence[i]))
                * (1.0f - dc_clampf(shear, 0.0f, 1.0f)) * (on_water ? 1.0f : 0.15f);
            e.intensity += (potential - e.intensity) * (on_water ? 0.16f : 0.38f) * dt;
            if (temp[i] < 0.50f) e.intensity -= (0.50f - temp[i]) * 0.35f * dt;
            e.intensity = dc_clampf(e.intensity, 0.0f, 1.0f);
            e.age_days += dt;
            Vector2 guide(wind_x[i] - 0.12f * std::abs(signed_lat), wind_y[i]);
            if (guide.length_squared() > 1e-5f) guide = guide.normalized();
            else guide = e.steering.length_squared() > 1e-5f ? e.steering.normalized() : Vector2(-1.0f, 0.0f);
            e.steering = e.steering.lerp(guide, 0.35f).normalized();
            e.move_progress += dt * (0.25f + dc_clampf(wind_speed[i], 0.0f, 1.5f) * 0.35f);
            if (e.move_progress >= 1.0f) {
                int best = -1; float best_dot = 0.10f;
                for (int d = 0; d < 6; ++d) {
                    const int ni = neighbors[i * 6 + d]; if (ni < 0) continue;
                    float dx = positions[ni].x - positions[i].x;
                    if (wrap_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_x);
                    const float dy = positions[ni].y - positions[i].y;
                    const float len2 = dx * dx + dy * dy; if (len2 <= 1e-6f) continue;
                    const float dot = (dx * e.steering.x + dy * e.steering.y) / std::sqrt(len2);
                    if (dot > best_dot) { best_dot = dot; best = ni; }
                }
                if (best >= 0) e.cell_idx = best;
                e.move_progress -= 1.0f;
            }
        }
        e.radius_cells = dc_clampf(2.0f + e.intensity * float(max_radius - 2), 2.0f, float(max_radius));
        e.days_left = std::max(0, int(std::ceil(32.0f - e.age_days)));
        e.init_days = 32;
    }
    const size_t before = _cyclone_perturbations.size();
    _cyclone_perturbations.erase(std::remove_if(_cyclone_perturbations.begin(), _cyclone_perturbations.end(),
        [](const CycloneWakeEntry &e) { return e.intensity < 0.075f || e.age_days > 32.0f; }),
        _cyclone_perturbations.end());
    _cyclone_total_decay += int(before - _cyclone_perturbations.size());
    std::vector<int32_t> queue;
    std::vector<int8_t> distance;
    queue.reserve(256); distance.reserve(256);
    uint32_t visit_generation = _cyclone_force_generation;
    for (const CycloneWakeEntry &e : _cyclone_perturbations) {
        if (e.cell_idx < 0 || e.cell_idx >= n_cells) continue;
        if (++visit_generation == 0u) { std::fill(_cyclone_visit_tag.begin(), _cyclone_visit_tag.end(), 0u); visit_generation = 1u; }
        queue.clear(); distance.clear(); queue.push_back(e.cell_idx); distance.push_back(0);
        _cyclone_visit_tag[static_cast<size_t>(e.cell_idx)] = visit_generation;
        const int radius = std::clamp(int(std::ceil(e.radius_cells)), 2, max_radius);
        for (size_t head = 0; head < queue.size(); ++head) {
            const int i = queue[head], dist = int(distance[head]);
            const float falloff = 1.0f - float(dist) / float(radius + 1);
            if (_cyclone_force_tag[static_cast<size_t>(i)] != _cyclone_force_generation) {
                _cyclone_force_tag[static_cast<size_t>(i)] = _cyclone_force_generation;
                _cyclone_force_x[static_cast<size_t>(i)] = 0.0f;
                _cyclone_force_y[static_cast<size_t>(i)] = 0.0f;
                _cyclone_force_lift[static_cast<size_t>(i)] = 0.0f;
                ++_cyclone_last_touched_cells;
            }
            float dx = positions[i].x - positions[e.cell_idx].x;
            if (wrap_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_x);
            const float dy = positions[i].y - positions[e.cell_idx].y;
            Vector2 tangent;
            if (dx * dx + dy * dy > 1e-6f) {
                const float ny = dc_clampf((positions[e.cell_idx].y - wb_y) / wb_h, 0.0f, 1.0f);
                const float hemi = ny < 0.5f ? 1.0f : -1.0f;
                tangent = Vector2(-dy * hemi, dx * hemi).normalized();
            } else tangent = Vector2(-e.steering.y, e.steering.x);
            const float force = e.intensity * falloff * 0.62f;
            _cyclone_force_x[static_cast<size_t>(i)] += tangent.x * force;
            _cyclone_force_y[static_cast<size_t>(i)] += tangent.y * force;
            _cyclone_force_lift[static_cast<size_t>(i)] = std::max(_cyclone_force_lift[static_cast<size_t>(i)], e.intensity * falloff);
            if (dist >= radius) continue;
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[i * 6 + d];
                if (ni < 0 || _cyclone_visit_tag[static_cast<size_t>(ni)] == visit_generation) continue;
                _cyclone_visit_tag[static_cast<size_t>(ni)] = visit_generation;
                queue.push_back(ni); distance.push_back(int8_t(dist + 1));
            }
        }
    }
    for (CycloneWakeEntry &e : _cyclone_perturbations) { e.vec = e.steering * e.intensity; e.vec_init = e.vec; }
    (void)lat_norm;
}

double DCWorldExt::cyclone_wake_step(Dictionary &knobs,
                                     const Array &fronts_from_summary) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Phase B.2 细粒度遥测计数 ────────────────────────────────────────
    int n_decayed  = 0;  // Phase 1 衰减后仍活
    int n_evicted  = 0;  // Phase 1 淘汰
    int n_replaced = 0;  // Phase 2 覆盖已有 key
    int n_injected = 0;  // Phase 2 新增 entry
    double phase1_ms = 0.0;
    double phase2_ms = 0.0;

    // helper: 早期 return 前统一写回遥测字段，确保 caller 总能拿到完整 6 字段。
    auto write_back_stats = [&]() {
        knobs["cyclone_phase1_decay_ms"]  = phase1_ms;
        knobs["cyclone_phase2_inject_ms"] = phase2_ms;
        knobs["cyclone_n_decayed"]  = n_decayed;
        knobs["cyclone_n_evicted"]  = n_evicted;
        knobs["cyclone_n_replaced"] = n_replaced;
        knobs["cyclone_n_injected"] = n_injected;
    };

    // ─── knobs ──────────────────────────────────────────────────────────
    if (!knobs.has("hex_size") || !knobs.has("cyclone_wake_days") ||
        !knobs.has("cyclone_storm_type_id") || !knobs.has("water_terrain_ids") ||
        !knobs.has("cell_q_arr") || !knobs.has("cell_r_arr") ||
        !knobs.has("n_cells")) {
        // 缺 key 则只做衰减/淘汰（不注入），保持 best-effort
        // 但发出一次 warning 便于排查
        UtilityFunctions::push_warning(
            "[DCWorldExt] cyclone_wake_step: missing knob (need hex_size/"
            "cyclone_wake_days/cyclone_storm_type_id/water_terrain_ids/"
            "cell_q_arr/cell_r_arr/n_cells)");
    }
    const float hex_size = float(knobs.get("hex_size", 1.0f));
    const int cyclone_wake_days = int(knobs.get("cyclone_wake_days", 7));
    const int storm_type_id = int(knobs.get("cyclone_storm_type_id", -1));
    const int n_cells = int(knobs.get("n_cells", 0));
    const bool native_entity_enabled = bool(knobs.get("native_tropical_cyclone_enabled",
        _native_runtime_config.get("native_tropical_cyclone_enabled", false)));
    const int cyclone_capacity = std::clamp(int(knobs.get("tropical_cyclone_capacity",
        _native_runtime_config.get("tropical_cyclone_capacity", 24))), 1, 64);
    const int births_per_commit = std::clamp(int(knobs.get("tropical_cyclone_births_per_commit",
        _native_runtime_config.get("tropical_cyclone_births_per_commit", 2))), 1, 4);
    const float min_temp = dc_clampf(float(knobs.get("tropical_cyclone_min_temp",
        _native_runtime_config.get("tropical_cyclone_min_temp", 0.58))), 0.0f, 1.0f);
    const float min_instability = dc_clampf(float(knobs.get("tropical_cyclone_min_instability",
        _native_runtime_config.get("tropical_cyclone_min_instability", 0.40))), 0.0f, 1.0f);
    const float max_shear = dc_clampf(float(knobs.get("tropical_cyclone_max_shear",
        _native_runtime_config.get("tropical_cyclone_max_shear", 0.42))), 0.0f, 1.0f);
    const float min_lat = dc_clampf(float(knobs.get("tropical_cyclone_min_lat",
        _native_runtime_config.get("tropical_cyclone_min_lat", 0.06))), 0.0f, 1.0f);
    const float max_lat = dc_clampf(float(knobs.get("tropical_cyclone_max_lat",
        _native_runtime_config.get("tropical_cyclone_max_lat", 0.40))), min_lat, 1.0f);
    const float wb_y = float(knobs.get("world_bounds_pos_y", 0.0));
    const float wb_h = std::max(0.001f, float(knobs.get("world_bounds_size_y", 1.0)));
    PackedByteArray  water_ids = knobs.get("water_terrain_ids", PackedByteArray());
    PackedInt32Array cell_q    = knobs.get("cell_q_arr", PackedInt32Array());
    PackedInt32Array cell_r    = knobs.get("cell_r_arr", PackedInt32Array());
    PackedInt32Array neighbor_idx = knobs.get("neighbor_indices", PackedInt32Array());

    // ─── Phase 1: 衰减 / 淘汰 ───────────────────────────────────────────
    // 等价 GDScript: days_left -= 1；<=0 删除；否则 vec = vec_init * days_left/init_days
    if (!native_entity_enabled) {
        auto t_p1_0 = std::chrono::high_resolution_clock::now();
        size_t write = 0;
        for (size_t read = 0; read < _cyclone_perturbations.size(); ++read) {
            CycloneWakeEntry &e = _cyclone_perturbations[read];
            const int new_days = e.days_left - 1;
            if (new_days <= 0) {
                ++n_evicted;
                continue; // 淘汰
            }
            e.days_left = new_days;
            const int denom = std::max(e.init_days, 1);
            const float scale = float(new_days) / float(denom);
            e.vec = e.vec_init * scale;
            if (write != read) {
                _cyclone_perturbations[write] = e;
            }
            ++write;
            ++n_decayed;
        }
        _cyclone_perturbations.resize(write);
        auto t_p1_1 = std::chrono::high_resolution_clock::now();
        phase1_ms = std::chrono::duration<double, std::milli>(t_p1_1 - t_p1_0).count();
    }

    // ─── Phase 2: 注入 ──────────────────────────────────────────────────
    // 前置：需要 fronts 列表 + cell terrain SoA + q/r 反查 + water LUT。
    // 任一缺失则跳过注入（衰减/淘汰仍生效）。
    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_w_inst = component_id(StringName("cell_weather_instability"));
    const int sid_w_precip = component_id(StringName("cell_weather_precip"));
    const int sid_w_cloud = component_id(StringName("cell_weather_cloud"));
    const int sid_w_conv = component_id(StringName("cell_weather_convergence"));
    const int sid_wx = component_id(StringName("cell_wind_x"));
    const int sid_wy = component_id(StringName("cell_wind_y"));
    if (sid_terrain < 0 || n_cells <= 0 || water_ids.size() <= 0 ||
        cell_q.size() < n_cells || cell_r.size() < n_cells ||
        storm_type_id < 0 || cyclone_wake_days <= 0 ||
        sid_temp < 0 || sid_w_inst < 0 || sid_w_precip < 0 ||
        sid_w_cloud < 0 || sid_w_conv < 0) {
        write_back_stats();
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_w_inst = _slots.write[sid_w_inst];
    Slot &s_w_precip = _slots.write[sid_w_precip];
    Slot &s_w_cloud = _slots.write[sid_w_cloud];
    Slot &s_w_conv = _slots.write[sid_w_conv];
    Slot *s_wx = sid_wx >= 0 ? &_slots.write[sid_wx] : nullptr;
    Slot *s_wy = sid_wy >= 0 ? &_slots.write[sid_wy] : nullptr;
    if (int(s_terrain.arr_u8.size()) < n_cells ||
        int(s_temp.arr_f32.size()) < n_cells ||
        int(s_w_inst.arr_f32.size()) < n_cells ||
        int(s_w_precip.arr_f32.size()) < n_cells ||
        int(s_w_cloud.arr_f32.size()) < n_cells ||
        int(s_w_conv.arr_f32.size()) < n_cells) {
        write_back_stats();
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
    const uint8_t * const TERR = s_terrain.arr_u8.ptr();
    const float * const T = s_temp.arr_f32.ptr();
    const float * const W_INST = s_w_inst.arr_f32.ptr();
    const float * const W_PRECIP = s_w_precip.arr_f32.ptr();
    const float * const W_CLOUD = s_w_cloud.arr_f32.ptr();
    const float * const W_CONV = s_w_conv.arr_f32.ptr();
    const float * const WIND_X = s_wx != nullptr && s_wx->arr_f32.size() >= n_cells ? s_wx->arr_f32.ptr() : nullptr;
    const float * const WIND_Y = s_wy != nullptr && s_wy->arr_f32.size() >= n_cells ? s_wy->arr_f32.ptr() : nullptr;
    const int32_t * const NB_GEN = neighbor_idx.size() >= n_cells * 6 ? neighbor_idx.ptr() : nullptr;

    // is_water LUT（与 summary / sea_ice / wind 同模式）
    bool is_water_lut[256];
    for (int i = 0; i < 256; ++i) is_water_lut[i] = false;
    for (int k = 0; k < water_ids.size(); ++k) {
        const int wid = int(water_ids[k]);
        if (wid >= 0 && wid < 256) is_water_lut[wid] = true;
    }

    // 复用 _summary_qr_to_idx（summary pass 已 lazy 填好）；若 size 不匹配
    // 则跳过注入（与 summary pass 同一防御）。
    const bool qr_idx_ready = (_summary_qr_to_idx_size == n_cells &&
                               !_summary_qr_to_idx.empty());

    // 与 summary pass 的 world_to_cube 严格 1:1（含 _cube_round）
    const double SQRT3 = 1.7320508075688772;
    auto world_to_qr = [&](Vector2 p, int &out_q, int &out_r) -> bool {
        if (hex_size <= 0.0f) return false;
        const double q_f = (SQRT3 / 3.0 * double(p.x) - 1.0 / 3.0 * double(p.y)) / double(hex_size);
        const double r_f = (2.0 / 3.0 * double(p.y)) / double(hex_size);
        const double s_f = -q_f - r_f;
        int rq = int(std::lround(q_f));
        int rr = int(std::lround(r_f));
        int rs = int(std::lround(s_f));
        const double dq = std::abs(double(rq) - q_f);
        const double dr = std::abs(double(rr) - r_f);
        const double ds = std::abs(double(rs) - s_f);
        if (dq > dr && dq > ds) {
            rq = -rr - rs;
        } else if (dr > ds) {
            rr = -rq - rs;
        }
        out_q = rq;
        out_r = rr;
        return true;
    };

    auto qr_to_cell_idx = [&](int q, int r) -> int {
        if (!qr_idx_ready) return -1;
        const int64_t key = (int64_t(q) << 32) ^ (uint32_t(r) & 0xFFFFFFFFu);
        auto it = _summary_qr_to_idx.find(key);
        return (it == _summary_qr_to_idx.end()) ? -1 : it->second;
    };

    // 注入遍历
    const int n_fronts = fronts_from_summary.size();
    {
        auto t_p2_0 = std::chrono::high_resolution_clock::now();
        for (int fi = 0; fi < n_fronts; ++fi) {
            if (native_entity_enabled && n_injected >= births_per_commit) break;
            const Dictionary f = fronts_from_summary[fi];
            const int ftype = int(f.get("type", -1));
            if (ftype != storm_type_id) continue;
            const float intensity = float(f.get("intensity", 0.0f));
            if (intensity < 0.8f) continue;
            const Vector2 center = f.get("center", Vector2());

            int q = 0, r = 0;
            if (!world_to_qr(center, q, r)) continue;
            const int idx = qr_to_cell_idx(q, r);
            if (idx < 0 || idx >= n_cells) continue;
            if (!is_water_lut[TERR[idx]]) continue;

            const float abs_lat = std::abs((center.y - wb_y) / wb_h * 2.0f - 1.0f);
            if (native_entity_enabled && (abs_lat < min_lat || abs_lat > max_lat)) continue;
            if (native_entity_enabled && WIND_X != nullptr && WIND_Y != nullptr && NB_GEN != nullptr) {
                float shear = 0.0f;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB_GEN[idx * 6 + d];
                    if (ni < 0) continue;
                    const float dx = WIND_X[ni] - WIND_X[idx], dy = WIND_Y[ni] - WIND_Y[idx];
                    shear = std::max(shear, std::sqrt(dx * dx + dy * dy) / 2.0f);
                }
                if (shear > max_shear) continue;
            }

            Vector2 wind = f.get("velocity", Vector2());
            const float front_speed_norm = wind.length() / std::max(hex_size, 0.001f);
            if (T[idx] < (native_entity_enabled ? min_temp : 0.56f)) continue;
            if (W_PRECIP[idx] < 0.05f) continue;
            if (W_CLOUD[idx] < 0.22f) continue;
            if (W_INST[idx] < (native_entity_enabled ? min_instability : 0.48f) && W_CONV[idx] < 0.30f) continue;
            if (front_speed_norm < 0.16f && intensity < 0.82f) continue;
            if (wind.length_squared() < 1e-4f) {
                wind = Vector2(1.0f, 0.0f);
            }
            Vector2 tangent = Vector2(-wind.y, wind.x).normalized();
            const Vector2 perturb = tangent * intensity * 0.6f;

            const int64_t key_gd = int64_t(cell_q[idx]) * 10000LL + int64_t(cell_r[idx]);

            // 若 key 已存在则覆盖（与 GDScript Dictionary 赋值同语义）
            bool replaced = false;
            for (auto &e : _cyclone_perturbations) {
                if (e.key == key_gd) {
                    e.cell_idx  = idx;
                    e.vec       = perturb;
                    e.vec_init  = perturb;
                    e.days_left = cyclone_wake_days;
                    e.init_days = cyclone_wake_days;
                    if (native_entity_enabled) {
                        e.steering = wind.normalized();
                        e.intensity = std::max(e.intensity, intensity);
                        e.radius_cells = 2.0f + intensity * 3.0f;
                    }
                    replaced = true;
                    break;
                }
            }
            if (replaced) {
                ++n_replaced;
            } else {
                if (native_entity_enabled && int(_cyclone_perturbations.size()) >= cyclone_capacity) continue;
                CycloneWakeEntry ne;
                ne.stable_id = _cyclone_next_stable_id++;
                ne.key       = key_gd;
                ne.cell_idx  = idx;
                ne.vec       = perturb;
                ne.vec_init  = perturb;
                ne.days_left = cyclone_wake_days;
                ne.init_days = cyclone_wake_days;
                if (native_entity_enabled) {
                    ne.steering = wind.normalized();
                    ne.intensity = intensity;
                    ne.radius_cells = 2.0f + intensity * 3.0f;
                    ne.age_days = 0.0f;
                    ne.move_progress = 0.0f;
                    ne.days_left = 32;
                    ne.init_days = 32;
                }
                _cyclone_perturbations.push_back(ne);
                ++n_injected;
                if (native_entity_enabled) ++_cyclone_total_genesis;
            }
        }
        auto t_p2_1 = std::chrono::high_resolution_clock::now();
        phase2_ms = std::chrono::duration<double, std::milli>(t_p2_1 - t_p2_0).count();
    }

    write_back_stats();
    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── plan/weather-refresh-cpp-all: cyclone perturbations 镜像导出 ────────
Dictionary DCWorldExt::get_cyclone_perturbations_dict() const {
    Dictionary out;
    out.clear();
    for (const auto &e : _cyclone_perturbations) {
        Dictionary d;
        d["vec"]        = e.vec;
        d["vec_init"]   = e.vec_init;
        d["days_left"]  = e.days_left;
        d["init_days"]  = e.init_days;
        // key 用 int64 —— GDScript Dictionary 接受 int key（自动 Variant::INT）
        out[godot::Variant(int64_t(e.key))] = d;
    }
    return out;
}

Dictionary DCWorldExt::get_active_cyclone_snapshot() const {
    Dictionary out;
    Array entries;
    entries.resize(int(_cyclone_perturbations.size()));
    for (int i = 0; i < int(_cyclone_perturbations.size()); ++i) {
        const CycloneWakeEntry &e = _cyclone_perturbations[static_cast<size_t>(i)];
        Dictionary d;
        d["stable_id"] = int64_t(e.stable_id);
        d["cell_idx"] = e.cell_idx;
        d["steering"] = e.steering;
        d["intensity"] = e.intensity;
        d["radius_cells"] = e.radius_cells;
        d["age_days"] = e.age_days;
        d["days_left"] = e.days_left;
        entries[i] = d;
    }
    out["count"] = entries.size();
    out["capacity"] = int(_native_runtime_config.get("tropical_cyclone_capacity", 24));
    out["cyclones"] = entries;
    return out;
}

Dictionary DCWorldExt::get_climate_modes_report() const {
    Dictionary out;
    out["thermal_monsoon_enabled"] = bool(_native_runtime_config.get("thermal_monsoon_enabled", false));
    out["monsoon_eligible_cells"] = _monsoon_eligible_cells;
    out["monsoon_onshore_cells"] = _monsoon_onshore_cells;
    out["monsoon_offshore_cells"] = _monsoon_offshore_cells;
    out["monsoon_contrast_abs_max"] = _monsoon_contrast_abs_max;
    out["monsoon_coast_cache_hit"] = _phys_wind_coast_last_hit;
    out["monsoon_coast_cache_build_ms"] = _phys_wind_coast_build_ms;
    out["enso_enabled"] = bool(_native_runtime_config.get("enso_basin_modes_enabled", false));
    out["enso_basin_count"] = int(_enso_states.size());
    out["enso_cache_hit"] = _enso_cache_last_hit;
    out["enso_cache_build_ms"] = _enso_cache_build_ms;
    Array basins;
    basins.resize(int(_enso_states.size()));
    for (int i = 0; i < int(_enso_states.size()); ++i) {
        const EnsoBasinState &s = _enso_states[static_cast<size_t>(i)];
        Dictionary d;
        d["signature"] = int64_t(s.signature);
        d["temp_index"] = s.temp_index;
        d["recharge_index"] = s.recharge_index;
        d["wind_anomaly"] = s.wind_anomaly;
        d["member_count"] = i < int(_enso_basins.size()) ? _enso_basins[static_cast<size_t>(i)].member_count : 0;
        basins[i] = d;
    }
    out["enso_basins"] = basins;
    out["cyclone_enabled"] = bool(_native_runtime_config.get("native_tropical_cyclone_enabled", false));
    out["cyclone_active_count"] = int(_cyclone_perturbations.size());
    out["cyclone_touched_cells"] = _cyclone_last_touched_cells;
    out["cyclone_total_genesis"] = _cyclone_total_genesis;
    out["cyclone_total_decay"] = _cyclone_total_decay;
    return out;
}

Dictionary DCWorldExt::capture_climate_modes_state() const {
    Dictionary out;
    out["schema"] = String("PKClimateModes");
    out["version"] = 1;
    out["next_cyclone_id"] = int64_t(_cyclone_next_stable_id);
    Array basins;
    for (const EnsoBasinState &s : _enso_states) {
        Dictionary d;
        d["signature"] = int64_t(s.signature);
        d["temp_index"] = s.temp_index;
        d["recharge_index"] = s.recharge_index;
        d["wind_ema"] = s.wind_ema;
        d["wind_anomaly"] = s.wind_anomaly;
        d["last_update_tick"] = s.last_update_tick;
        basins.append(d);
    }
    out["enso_basins"] = basins;
    Array cyclones;
    for (const CycloneWakeEntry &e : _cyclone_perturbations) {
        Dictionary d;
        d["stable_id"] = int64_t(e.stable_id);
        d["key"] = e.key;
        d["cell_idx"] = e.cell_idx;
        d["steering"] = e.steering;
        d["intensity"] = e.intensity;
        d["radius_cells"] = e.radius_cells;
        d["age_days"] = e.age_days;
        d["move_progress"] = e.move_progress;
        cyclones.append(d);
    }
    out["cyclones"] = cyclones;
    out["total_genesis"] = _cyclone_total_genesis;
    out["total_decay"] = _cyclone_total_decay;
    return out;
}

Dictionary DCWorldExt::restore_climate_modes_state(const Dictionary &state) {
    Dictionary out;
    if (String(state.get("schema", String())) != String("PKClimateModes") || int(state.get("version", 0)) != 1) {
        out["ok"] = false;
        out["code"] = String("climate_modes_schema_mismatch");
        return out;
    }
    _climate_modes_pending_restore = state.duplicate(true);
    _cyclone_perturbations.clear();
    Array cyclones = state.get("cyclones", Array());
    const int capacity = std::clamp(int(_native_runtime_config.get("tropical_cyclone_capacity", 24)), 1, 64);
    for (int i = 0; i < cyclones.size() && int(_cyclone_perturbations.size()) < capacity; ++i) {
        Dictionary d = cyclones[i];
        CycloneWakeEntry e;
        e.stable_id = uint64_t(int64_t(d.get("stable_id", 0)));
        e.key = int64_t(d.get("key", 0));
        e.cell_idx = int(d.get("cell_idx", -1));
        e.steering = d.get("steering", Vector2(-1.0f, 0.0f));
        e.intensity = dc_clampf(float(d.get("intensity", 0.0)), 0.0f, 1.0f);
        e.radius_cells = dc_clampf(float(d.get("radius_cells", 2.0)), 2.0f, 6.0f);
        e.age_days = dc_clampf(float(d.get("age_days", 0.0)), 0.0f, 32.0f);
        e.move_progress = dc_clampf(float(d.get("move_progress", 0.0)), 0.0f, 1.0f);
        e.vec = e.steering * e.intensity;
        e.vec_init = e.vec;
        e.days_left = std::max(0, int(std::ceil(32.0f - e.age_days)));
        e.init_days = 32;
        if (e.cell_idx >= 0 && e.intensity >= 0.075f) _cyclone_perturbations.push_back(e);
    }
    _cyclone_next_stable_id = std::max<uint64_t>(1, uint64_t(int64_t(state.get("next_cyclone_id", 1))));
    _cyclone_total_genesis = std::max(0, int(state.get("total_genesis", 0)));
    _cyclone_total_decay = std::max(0, int(state.get("total_decay", 0)));
    out["ok"] = true;
    out["code"] = String("ok");
    out["cyclone_count"] = int(_cyclone_perturbations.size());
    out["enso_state_pending"] = Array(state.get("enso_basins", Array())).size();
    return out;
}

// ─── plan/weather-refresh-cpp-all: 顶层一体化 weather refresh pass ───────
//
// 串调 5 段：① field_solve ② distribute ③ summary ④ cyclone_wake ⑤ stage_b
// 任一段失败立即短路返回 { rc:-1, fail_stage:"..." }，caller 走 GDScript fallback。
//
// 子 pass 返回类型不齐：
//   field_solve / stage_b → double (ms; <0 表 fallback)
//   distribute / summary  → Dictionary { elapsed_ms, ... }
// 顶层 pass 统一抽 ms 字段写到 breakdown。
Dictionary DCWorldExt::run_weather_refresh_daily_pass(const Dictionary &knobs) {
    Dictionary br;
    auto t_top0 = std::chrono::high_resolution_clock::now();

    auto fail = [&](const char *stage) -> Dictionary {
        br["rc"] = -1;
        br["fail_stage"] = String(stage);
        auto t_e = std::chrono::high_resolution_clock::now();
        br["total_ms"] = std::chrono::duration<double, std::milli>(t_e - t_top0).count();
        return br;
    };

    // ① field solve（返回 double ms；<0 即失败）
    const double field_ms = run_weather_field_solve_pass(knobs);
    if (field_ms < 0.0) return fail("field_solve");
    br["advance_ms"] = field_ms;

    // ①b visible commit / publish
    //
    // `run_weather_field_solve_pass` has two modes:
    // - without out_* buffers it writes weather slots directly and flushes them;
    // - with out_* buffers it writes the staged next-state arrays only.
    //
    // The combined/native-daily weather facade always uses the staged form built
    // by WeatherSystem.begin_weather_field_solve(). Distribute, summary, and
    // stage-b read weather slots, so running them before this commit leaves the
    // visible field at the previous value (or all-zero on cold start) while the
    // cadence counters still advance.
    if (knobs.has("out_vapor") && knobs.has("out_cloud") &&
        knobs.has("out_precip") && knobs.has("out_instability") &&
        knobs.has("out_intensity") && knobs.has("out_convergence") &&
        knobs.has("out_type")) {
        Dictionary commit = run_weather_field_commit_pass(knobs);
        const double commit_ms = double(commit.get("elapsed_ms", -1.0));
        if (commit_ms < 0.0) return fail("field_commit");
        br["field_commit_total_ms"] = commit_ms;
        br["field_commit_loop_ms"] = double(commit.get("commit_loop_ms", commit_ms));
        br["field_commit_path"] = commit.get("path", String("gdext_commit"));
        br["field_commit_publish_verified"] = true;
        br["field_commit_publish_repaired"] = false;
        br["field_commit_init_count"] = int(knobs.get("n_cells", 0));
        br["field_commit_publish_reason"] = String("ok_native_combined_commit");
        br["weather_dirty_count"] = int(commit.get("weather_dirty_count", 0));
        br["water_budget_error"] = double(commit.get("water_budget_error", 0.0));
        br["active_weather_ratio"] = double(commit.get("active_weather_ratio", 0.0));
        br["weather_convergence_dirty_count"] = int(commit.get("weather_convergence_dirty_count", 0));
        br["weather_convergence_deltas"] = commit.get("weather_convergence_deltas", PackedFloat32Array());
        br["convergence_published"] = bool(commit.get("convergence_published", false));
        br["weather_lut"] = commit.get("weather_lut", PackedByteArray());
        br["weather_lut_changed"] = bool(commit.get("weather_lut_changed", false));
        br["weather_lut_dirty_count"] = int(commit.get("weather_lut_dirty_count", 0));
        br["weather_lut_full_rebuild"] = bool(commit.get("weather_lut_full_rebuild", false));

    } else {
        br["field_commit_path"] = String("direct_solve_publish");
        br["field_commit_publish_verified"] = true;
        br["field_commit_publish_repaired"] = false;
        br["field_commit_init_count"] = int(knobs.get("n_cells", 0));
        br["field_commit_publish_reason"] = String("ok_direct_solve_publish");
    }

    // ② distribute（返回 Dictionary { elapsed_ms, cover_dirty }）
    const Dictionary r_dist = run_weather_distribute_pass(knobs);
    const double dist_ms = double(r_dist.get("elapsed_ms", -1.0));
    if (dist_ms < 0.0) return fail("distribute");
    br["distribute_ms"] = dist_ms;
    br["cover_dirty"]   = r_dist.get("cover_dirty", false);

    // ③ summary fronts（返回 Dictionary { elapsed_ms, fronts: Array[Dictionary] }）
    const Dictionary r_summary = run_weather_summary_fronts_pass(knobs);
    const double summary_ms = double(r_summary.get("elapsed_ms", -1.0));
    if (summary_ms < 0.0) return fail("summary");
    const Array fronts_arr = r_summary.get("fronts", Array());
    br["summary_ms"]   = summary_ms;
    br["fronts_count"] = fronts_arr.size();
    br["fronts"]       = fronts_arr;
    int cold_front_count = 0;
    int warm_front_count = 0;
    for (int i = 0; i < fronts_arr.size(); ++i) {
        const Variant v = fronts_arr[i];
        if (v.get_type() != Variant::DICTIONARY) continue;
        const Dictionary fd = v;
        const int diag_kind = int(fd.get("front_diagnostic_kind", 0));
        if (diag_kind == 1) {
            ++cold_front_count;
        } else if (diag_kind == 2) {
            ++warm_front_count;
        }
    }
    br["weather_cold_front_count"] = cold_front_count;
    br["weather_warm_front_count"] = warm_front_count;

    // ④ cyclone wake（私有 step；只产 ms，副作用维护 _cyclone_perturbations）
    //
    // Phase B.2 细粒度遥测：by-value 复制 knobs 给 cyclone_wake_step（与
    // stage_b_pass 同模式），让它写回 6 个字段：phase1/phase2 ms + 4 个 n_*
    // 计数。caller 提取到 br，map_generator._dump_weather_breakdown_if_slow
    // 触发时可立即定位是衰减循环 vs 注入循环、是大量 evict vs 大量 replace。
    Dictionary cyclone_knobs = knobs;
    const double cyclone_ms = cyclone_wake_step(cyclone_knobs, fronts_arr);
    br["cyclone_ms"] = cyclone_ms;
    br["cyclone_phase1_decay_ms"]  = cyclone_knobs.get("cyclone_phase1_decay_ms",  0.0);
    br["cyclone_phase2_inject_ms"] = cyclone_knobs.get("cyclone_phase2_inject_ms", 0.0);
    br["cyclone_n_decayed"]  = cyclone_knobs.get("cyclone_n_decayed",  0);
    br["cyclone_n_evicted"]  = cyclone_knobs.get("cyclone_n_evicted",  0);
    br["cyclone_n_replaced"] = cyclone_knobs.get("cyclone_n_replaced", 0);
    br["cyclone_n_injected"] = cyclone_knobs.get("cyclone_n_injected", 0);
    br["cyclone_pool_size"]  = int(_cyclone_perturbations.size());

    // ⑤ stage_b（返回 double ms 合计；<0 即失败）。
    // 注：stage_b_pass sig 是 by-value Dictionary（会写回 succession_indices/
    // succession_to_veg/stat_succession_count + 单段 albedo_ms/veg_dyn_ms/
    // feedback_ms）。我们 by-value 复制一份让它写回到 local 副本，再把回写
    // 字段合并到 br。
    Dictionary stage_b_knobs = knobs; // shallow copy；godot Dictionary 写回会
                                       // 在 shared backing 上发生（refcount），
                                       // 这里复制 Variant header 即可。
    const double stage_b_ms = run_stage_b_pass(stage_b_knobs);
    if (stage_b_ms < 0.0) return fail("stage_b");
    br["stage_b_ms"]   = stage_b_ms;
    br["albedo_ms"]    = stage_b_knobs.get("albedo_ms",   0.0);
    br["veg_dyn_ms"]   = stage_b_knobs.get("veg_dyn_ms",  0.0);
    br["feedback_ms"]  = stage_b_knobs.get("feedback_ms", 0.0);
    const int stage_b_call_index = int(stage_b_knobs.get("stage_b_call_index", -1));
    br["stage_b_call_index"] = stage_b_call_index;
    br["albedo_ran"] = bool(stage_b_knobs.get("run_albedo", false));
    br["veg_dyn_ran"] = bool(stage_b_knobs.get("run_veg_dyn", false));
    br["feedback_ran"] = bool(stage_b_knobs.get("run_feedback", false));
    br["stage_b_combined_done"] = true;
    br["stage_b_ext_ok"] = true;
    br["stage_b_total_runs"] = stage_b_call_index >= 0 ? stage_b_call_index + 1 : 0;
    if (stage_b_knobs.has("succession_indices")) {
        br["succession_indices"]    = stage_b_knobs["succession_indices"];
        br["succession_to_veg"]     = stage_b_knobs["succession_to_veg"];
        br["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
    }

    // 顶层 total
    auto t_top1 = std::chrono::high_resolution_clock::now();
    const double total_ms = std::chrono::duration<double, std::milli>(t_top1 - t_top0).count();
    br["weather_tick_ms"] = total_ms;
    br["total_ms"]        = total_ms;
    br["rc"]              = 0;
    return br;
}

void DCWorldExt::reset_weather_summary_state() {
    if (_summary_state == nullptr) {
        return;
    }
    auto *s = static_cast<WeatherSummaryState *>(_summary_state);
    s->prev_seeds.clear();
    s->prev_membership.clear();
}

void DCWorldExt::snapshot_weather_summary_state() {
    auto *src = get_or_create_summary_state(_summary_state);
    auto *dst = get_or_create_summary_state(_summary_state_snapshot);
    dst->prev_seeds = src->prev_seeds;
    dst->prev_membership = src->prev_membership;
}

void DCWorldExt::restore_weather_summary_state() {
    if (_summary_state_snapshot == nullptr) {
        return;
    }
    auto *src = static_cast<WeatherSummaryState *>(_summary_state_snapshot);
    auto *dst = get_or_create_summary_state(_summary_state);
    dst->prev_seeds = src->prev_seeds;
    dst->prev_membership = src->prev_membership;
}

} // namespace pk

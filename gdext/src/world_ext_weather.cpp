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
#include <godot_cpp/classes/worker_thread_pool.hpp>
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
    const float syn_damp       = knobs.has("weather_synoptic_damp")       ? float(knobs["weather_synoptic_damp"])       : 0.94f;
    const float syn_diffuse    = knobs.has("weather_synoptic_diffuse")    ? float(knobs["weather_synoptic_diffuse"])    : 0.12f;
    const float syn_seed_rate  = knobs.has("weather_synoptic_seed_rate")  ? float(knobs["weather_synoptic_seed_rate"])  : 0.05f;
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

    if (_wx_synoptic.size() != (size_t)n_cells) {
        _wx_synoptic.assign((size_t)n_cells, 0.0f);
        _wx_synoptic_prev.assign((size_t)n_cells, 0.0f);
    }
    _wx_synoptic_prev = _wx_synoptic;                  // 整步快照(脱离切片)
    float * const __restrict PSI = _wx_synoptic.data();
    const float * const __restrict PSI_PREV = _wx_synoptic_prev.data();

    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < n_cells; ++i) {
        const int base = i * 6;
        // 平滑引导流：风邻域平均(去地转风小尺度切变→departure 场平滑→平移连贯,不打散)
        float gx = WX[i], gy = WY[i];
        int gn = 1;
        for (int d = 0; d < 6; ++d) {
            const int nb = NB[base + d];
            if (nb < 0) continue;
            gx += WX[nb]; gy += WY[nb]; ++gn;
        }
        gx /= float(gn); gy /= float(gn);
        // 半拉格朗日真平移：沿 -引导流走 syn_adv_cells 格找 departure，取 ψ_prev[dep]
        int dep = i;
        for (int s = 0; s < syn_adv_cells; ++s) {
            const int up = wf_neighbor_aligned_idx(dep, -gx, -gy, POS, NB, n_cells, pos_scale, wrap_width_x);
            if (up < 0 || up >= n_cells) break;
            dep = up;
        }
        float psi = PSI_PREV[dep];
        // 斜压门：邻域温度梯度
        float tmin = TEMP[i], tmax = TEMP[i];
        for (int d = 0; d < 6; ++d) {
            const int nb = NB[base + d];
            if (nb < 0) continue;
            const float t = TEMP[nb];
            if (t < tmin) tmin = t;
            if (t > tmax) tmax = t;
        }
        const float gate = wf_smoothstep(0.04f, 0.16f, tmax - tmin);
        psi *= (1.0f + syn_baroclinic * gate);                                  // 斜压增长
        const float seed_rate = syn_seed_rate * (0.30f + 0.70f * gate);
        if (wf_hash01(i, syn_tick) < seed_rate)
            psi += syn_seed_amp * (wf_hash01(i + 50021, syn_tick) - 0.5f) * 2.0f; // 稀疏气旋生成
        psi += (wf_neighbor_average_vapor_idx(i, NB, PSI_PREV) - psi) * syn_diffuse; // 轻扩散
        psi *= syn_damp;                                                        // 阻尼
        if (psi > 1.0f) psi = 1.0f; else if (psi < -1.0f) psi = -1.0f;
        PSI[i] = psi;
    }
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

    // ─── 计时 (返回给调用方做对账，charter §0 铁律 3) ──────────────────
    auto t0 = std::chrono::high_resolution_clock::now();

    // ── Stage13b「让天气移动」：每轮(start_idx==0)在主循环前对全场推进一次 ψ ────────────────
    // 内联进 solve pass → 与 solve 必然一起执行(不依赖 GDScript 调度挂钩、换 DLL 即生效)；全场一次→
    // 不被切片稀释。平滑引导流(风邻域平均)+纯取值半拉格朗日平移→ψ 涡旋成片随风移动。主循环只读 PSI[i]。
    if (PSI != nullptr && start_idx == 0) {
        _wx_synoptic_prev = _wx_synoptic;                              // 整步快照
        float * const __restrict PSI_W = _wx_synoptic.data();
        const float * const __restrict PSI_R = _wx_synoptic_prev.data();
        // 斜压门用归一化温度 TR(与主循环一致)；勿用 cell_temp slot(实际量纲→smoothstep 恒1→ψ 指数爆炸饱和)。
        for (int p = 0; p < n_cells; ++p) {
            const int pb = p * 6;
            // 平滑引导流：风邻域平均(去地转风小尺度切变→平移连贯)
            float gx = WX[p], gy = WY[p]; int gn = 1;
            for (int dd = 0; dd < 6; ++dd) { const int nb = NB[pb + dd]; if (nb < 0) continue; gx += WX[nb]; gy += WY[nb]; ++gn; }
            gx /= float(gn); gy /= float(gn);
            // 半拉格朗日真平移：沿 -引导流走 syn_adv_cells 格取 departure 的 ψ_prev
            int dep = p;
            for (int s = 0; s < syn_adv_cells; ++s) {
                const int up = wf_neighbor_aligned_idx(dep, -gx, -gy, POS, NB, n_cells, weather_cell_pos_scale, weather_wrap_width_x);
                if (up < 0 || up >= n_cells) break; dep = up;
            }
            float ps = PSI_R[dep];
            // 斜压门：邻域温度梯度
            float tmn = TR[p], tmx = TR[p];
            for (int dd = 0; dd < 6; ++dd) { const int nb = NB[pb + dd]; if (nb < 0) continue; const float tv = TR[nb]; if (tv < tmn) tmn = tv; if (tv > tmx) tmx = tv; }
            const float g = wf_smoothstep(0.04f, 0.16f, tmx - tmn);
            const float aps0 = ps < 0.0f ? -ps : ps;
            ps *= (1.0f + syn_baroclinic * g * (1.0f - aps0));          // 斜压增长(随振幅饱和→有界,不全场饱和)
            const float sr = syn_seed_rate * (0.30f + 0.70f * g);
            if (wf_hash01(p, syn_tick) < sr)
                ps += syn_seed_amp * (wf_hash01(p + 50021, syn_tick) - 0.5f) * 2.0f; // 稀疏气旋生成
            ps += (wf_neighbor_average_vapor_idx(p, NB, PSI_R) - ps) * syn_diffuse;  // 轻扩散
            ps *= syn_damp;                                             // 阻尼
            if (ps > 1.0f) ps = 1.0f; else if (ps < -1.0f) ps = -1.0f;
            if (ps < 0.05f && ps > -0.05f) ps = 0.0f;                   // 阈值清零→防低值 ψ 经扩散/平流铺满全场，保稀疏移动涡旋
            PSI_W[p] = ps;
        }
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
        float * const __restrict GBX = _wf_nb_dx.data();
        float * const __restrict GBY = _wf_nb_dy.data();
        float * const __restrict GBI = _wf_nb_invd.data();
        for (int p = 0; p < n_cells; ++p) {
            const int b = p * 6;
            const float sx = POS[p].x;
            const float sy = POS[p].y;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb_idx = NB[b + d];
                if (nb_idx < 0) {
                    GBX[b + d] = 0.0f; GBY[b + d] = 0.0f; GBI[b + d] = 0.0f;
                    continue;
                }
                float dx = 0.0f, dy = 0.0f;
                wf_wrapped_delta(sx, sy, POS[nb_idx].x, POS[nb_idx].y,
                                 weather_wrap_width_x, dx, dy);
                GBX[b + d] = dx;
                GBY[b + d] = dy;
                const float dl2 = dx * dx + dy * dy;
                GBI[b + d] = (dl2 > 0.0001f) ? (1.0f / Math::sqrt(dl2)) : 0.0f;
            }
        }
        _wf_nb_geom_n = n_cells;
        _wf_nb_geom_wrap = weather_wrap_width_x;
    }
    const bool use_geom_cache =
        (_wf_nb_geom_n == n_cells && _wf_nb_geom_wrap == weather_wrap_width_x);
    const float * const __restrict GEOM_DX   = use_geom_cache ? _wf_nb_dx.data()   : nullptr;
    const float * const __restrict GEOM_DY   = use_geom_cache ? _wf_nb_dy.data()   : nullptr;
    const float * const __restrict GEOM_INVD = use_geom_cache ? _wf_nb_invd.data() : nullptr;

    // 几何缓存派发 wrapper（cache 命中走缓存变体，否则回退原 helper；两路 bit-equal）。
    auto wx_aligned = [&](int idx, float dx, float dy) -> int {
        return use_geom_cache
            ? wf_neighbor_aligned_idx_cached(idx, dx, dy, NB, GEOM_DX, GEOM_DY,
                                             n_cells, weather_cell_pos_scale)
            : wf_neighbor_aligned_idx(idx, dx, dy, POS, NB, n_cells,
                                      weather_cell_pos_scale, weather_wrap_width_x);
    };
    auto wx_upstream_avg = [&](int idx, int first_up, const float *FIELD,
                               float wdx, float wdy) -> float {
        return use_geom_cache
            ? wf_upstream_vapor_idx_from_first_cached(
                  idx, first_up, NB, GEOM_DX, GEOM_DY, FIELD, wdx, wdy, n_cells,
                  weather_cell_pos_scale, field_advect_steps)
            : wf_upstream_vapor_idx_from_first(
                  idx, first_up, POS, NB, FIELD, wdx, wdy, n_cells,
                  weather_cell_pos_scale, weather_wrap_width_x, field_advect_steps);
    };
    auto wx_convergence = [&](int idx) -> float {
        return use_geom_cache
            ? wf_wind_convergence_idx_cached(idx, NB, GEOM_DX, GEOM_DY, GEOM_INVD,
                                             WX, WY, WSPD)
            : wf_wind_convergence_idx(idx, POS, NB, WX, WY, WSPD,
                                      weather_wrap_width_x);
    };

    auto surface_vapor_source = [&](int src_idx, float src_temp, float src_base_m,
                                     float src_wind_mag, float src_ocean_an,
                                     bool src_on_water, bool src_is_lake,
                                     bool src_has_river, float src_river_q,
                                     float src_river_source_scale) -> float {
        // [climate-zone-fix P3] 冷季地板抬高低温端蒸发；floor=0 时与原 smoothstep 逐位一致。
        float temp_evap = wf_smoothstep(0.10f, 0.78f, src_temp);
        if (temp_evap < field_cool_season_vapor_floor) temp_evap = field_cool_season_vapor_floor;
        const float wind_evap = 0.70f + src_wind_mag * 0.55f;
        float wet_bonus = 0.0f;
        switch (TERR[src_idx]) {
            case 10: // SWAMP
            case 11: // JUNGLE
            case 22: // DELTA
                wet_bonus = 0.010f;
                break;
            case 18: // LAKE
                wet_bonus = 0.016f;
                break;
            default:
                wet_bonus = 0.0f;
                break;
        }
        if (src_on_water) {
            const float sea_ice = (SICE != nullptr) ? dc_clampf(SICE[src_idx], 0.0f, 1.0f) : 0.0f;
            float src = (0.018f + temp_evap * 0.052f) * field_ocean_evap_gain * wind_evap;
            src *= dc_clampf(1.0f + src_ocean_an * 0.55f, 0.55f, 1.45f);
            src *= (1.0f - sea_ice * 0.92f);
            if (src_is_lake) src *= field_lake_evap_scale;
            return (src > 0.0f) ? src : 0.0f;
        }
        const float soil_norm = (SOIL != nullptr)
            ? dc_clampf(0.5f + SOIL[src_idx], 0.0f, 1.0f)
            : dc_clampf(src_base_m, 0.0f, 1.0f);
        const float vitality = (VITA != nullptr) ? dc_clampf(VITA[src_idx], 0.0f, 1.0f) : 0.7f;
        const float veg_flux = wf_vegetation_transp_factor(VEG[src_idx]) * (0.45f + vitality * 0.65f);
        float src = (0.005f + src_base_m * 0.010f + soil_norm * 0.020f + veg_flux * 0.016f + wet_bonus)
            * field_land_evapotranspiration_gain * temp_evap * (0.85f + src_wind_mag * 0.25f);
        if (src_has_river) {
            const float river_scale = dc_clampf(src_river_source_scale, 0.0f, 1.0f);
            const float river_extra = (0.010f + src_river_q * 0.020f)
                * field_land_evapotranspiration_gain * temp_evap;
            src += river_extra * river_scale;
        }
        return (src > 0.0f) ? src : 0.0f;
    };

    // ─── Tight loop — 1:1 mirror of the GDScript weather field hot loop ──
    // Source of truth: field_solver.gd::run_slice (fast_indexed path). Keep this
    // loop bit-equal with that fallback; run set_field_verify_mode(true) to A/B
    // check (tol 1e-4). NOTE: hot loop moved out of weather_system.gd (PR-1..7);
    // do not chase the old weather_system.gd:678-757 citation.
    // ── perf P1: 每 cell 输出互不依赖（仅写 OUT_*[i]/INHIB[i]/transition[i]，无标量累加器；
    // staged 路径 OUT_* 与 prev 不同 buffer），故按 cell 区间并行、bit-equal、无需 reduce。
    // direct(use_next_outputs==false) 路径 OUT_CNV 与 PREV_CNV 同 buffer 且读邻居→保持串行。
    auto run_weather_cell_range = [&](int rb, int re) {
    for (int i = rb; i < re; ++i) {
        float temp = TR[i] + climate_anomaly + AA[i];
        if (temp < 0.0f) temp = 0.0f;
        else if (temp > 1.0f) temp = 1.0f;

        float base_m = MR[i];
        if (base_m < 0.0f) base_m = 0.0f;
        else if (base_m > 1.0f) base_m = 1.0f;
        float vapor_capacity = 0.18f + 0.82f * temp - 0.18f * ELEV[i];
        if (vapor_capacity < 0.14f) vapor_capacity = 0.14f;
        else if (vapor_capacity > 1.0f) vapor_capacity = 1.0f;

        const bool on_water = wf_is_water_terrain(TERR[i]);
        // ── perf P3: 融合 3 个 6-邻域 gather 为一次遍历（逐 d 顺序与原版一致→bit-equal）──
        //   ① ocean_an     = wf_avg_ocean_anomaly_at_idx(i, TERR, NB, TA)
        //   ② neighbor_vapor= wf_neighbor_average_vapor_idx(i, NB, PV)
        //   ③ temp_min/max  = 邻域温度极值（原下方 temp gradient 循环）
        float ocean_an;
        float neighbor_vapor;
        float temp_min = temp;
        float temp_max = temp;
        {
            const int fb = i * 6;
            float vap_sum = PV[i];
            int   vap_n   = 1;
            float oa_sum  = 0.0f;
            int   oa_n    = 0;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb_idx = NB[fb + d];
                if (nb_idx < 0) continue;
                vap_sum += PV[nb_idx];                // ② vapor 邻域均值（含 self）
                vap_n   += 1;
                float nb_temp = TR[nb_idx] + climate_anomaly + AA[nb_idx];  // ③ 温度梯度极值
                if (nb_temp < 0.0f) nb_temp = 0.0f;
                else if (nb_temp > 1.0f) nb_temp = 1.0f;
                if (nb_temp < temp_min) temp_min = nb_temp;
                if (nb_temp > temp_max) temp_max = nb_temp;
                if (!on_water && wf_is_water_terrain(TERR[nb_idx])) {       // ① 陆格→水邻居 TA 均值
                    oa_sum += TA[nb_idx];
                    oa_n   += 1;
                }
            }
            neighbor_vapor = vap_sum / float(vap_n);
            ocean_an = on_water ? TA[i] : ((oa_n == 0) ? 0.0f : (oa_sum / float(oa_n)));
        }
        const float local_sea_ice = (on_water && SICE != nullptr) ? dc_clampf(SICE[i], 0.0f, 1.0f) : 0.0f;

        float wind_x = WX[i];
        float wind_y = WY[i];
        const float wlen2 = wind_x * wind_x + wind_y * wind_y;
        float wind_dx, wind_dy;
        if (wlen2 < 0.0001f) {
            // Conservative fallback: dir = (1,0) like the GDScript final
            // `wind.normalized() if length_squared > 0.0001 else Vector2.RIGHT`.
            // Magnitude stays 0 → wind_mag=0 → advect_w lower bound.
            wind_dx = 1.0f;
            wind_dy = 0.0f;
        } else {
            const float inv = 1.0f / Math::sqrt(wlen2);
            wind_dx = wind_x * inv;
            wind_dy = wind_y * inv;
        }
        const float wind_len = wf_wind_speed_norm(wind_x, wind_y, WSPD[i]);

        const int upstream_idx = (field_advect_steps > 0)
            ? wx_aligned(i, -wind_dx, -wind_dy)
            : -1;

        const float advected_vapor = wx_upstream_avg(
            i, upstream_idx, PV, wind_dx, wind_dy);

        // neighbor_vapor 已在上方 P3 融合 gather 中算出。

        float wind_mag = wind_len / 1.2f;
        if (wind_mag < 0.0f) wind_mag = 0.0f;
        else if (wind_mag > 1.0f) wind_mag = 1.0f;

        const float lift = wf_orographic_lift_from_upstream_idx(
            i, upstream_idx, ELEV);
        float convergence = PREV_CNV[i];
        if (refresh_convergence) {
            convergence = wx_convergence(i);
        }

        float advect_w = 0.65f + wind_mag * 0.30f;
        if (advect_w < 0.65f) advect_w = 0.65f;
        else if (advect_w > 0.95f) advect_w = 0.95f;

        const bool is_lake = (TERR[i] == 18);
        const bool has_river = (!is_lake) && (RIV[i] != 0) && (!on_water);
        const float river_flow_feedback = has_river
            ? dc_clampf((RQ30 != nullptr ? RQ30[i] : 0.0f), 0.0f, 1.0f)
            : 0.0f;
        float river_recycle_lock = 0.0f;
        if (has_river) {
            float river_forcing_proxy = convergence * 0.65f;
            const float lift_forcing = (lift > 0.0f) ? lift * 0.80f : 0.0f;
            if (lift_forcing > river_forcing_proxy) river_forcing_proxy = lift_forcing;
            river_recycle_lock = wf_smoothstep(0.035f, 0.12f, PP[i])
                * (1.0f - wf_smoothstep(0.16f, 0.44f, river_forcing_proxy))
                * (0.35f + river_flow_feedback * 0.65f);
            river_recycle_lock = dc_clampf(river_recycle_lock, 0.0f, 1.0f);
        }
        const float river_source_scale = 1.0f - river_recycle_lock * 0.72f;
        const float river_evap_floor = has_river
            ? std::max(0.08f, river_flow_feedback * 0.22f) * (1.0f - river_recycle_lock * 0.65f)
            : 0.0f;
        if (is_lake) {
            advect_w *= 0.5f;
            if (advect_w < 0.20f) advect_w = 0.20f;
            else if (advect_w > 0.50f) advect_w = 0.50f;
        } else if (has_river) {
            advect_w *= (0.88f - river_flow_feedback * 0.10f);
            if (advect_w < 0.55f) advect_w = 0.55f;
            else if (advect_w > 0.85f) advect_w = 0.85f;
        }

        float effective_ocean_an = ocean_an;
        if (is_lake) {
            effective_ocean_an = 0.20f;
        } else if (has_river) {
            if (ocean_an > river_evap_floor) effective_ocean_an = ocean_an;
            else                             effective_ocean_an = river_evap_floor;
        }

        const float source_local = surface_vapor_source(
            i, temp, base_m, wind_mag, effective_ocean_an, on_water, is_lake,
            has_river, river_flow_feedback, river_source_scale);
        float source_upwind = source_local;
        bool upstream_on_water = false;
        if (upstream_idx >= 0 && upstream_idx < n_cells) {
            float up_temp = TR[upstream_idx] + climate_anomaly + AA[upstream_idx];
            if (up_temp < 0.0f) up_temp = 0.0f;
            else if (up_temp > 1.0f) up_temp = 1.0f;
            float up_base_m = MR[upstream_idx];
            if (up_base_m < 0.0f) up_base_m = 0.0f;
            else if (up_base_m > 1.0f) up_base_m = 1.0f;
            const bool up_on_water = wf_is_water_terrain(TERR[upstream_idx]);
            upstream_on_water = up_on_water;
            const bool up_is_lake = (TERR[upstream_idx] == 18);
            const bool up_has_river = (!up_is_lake) && (RIV[upstream_idx] != 0) && (!up_on_water);
            const float up_river_q = up_has_river
                ? dc_clampf((RQ30 != nullptr ? RQ30[upstream_idx] : 0.0f), 0.0f, 1.0f)
                : 0.0f;
            float up_river_recycle_lock = 0.0f;
            if (up_has_river) {
                const float up_forcing_proxy = dc_clampf(PREV_CNV[upstream_idx] * 0.65f, 0.0f, 1.0f);
                up_river_recycle_lock = wf_smoothstep(0.035f, 0.12f, PP[upstream_idx])
                    * (1.0f - wf_smoothstep(0.16f, 0.44f, up_forcing_proxy))
                    * (0.35f + up_river_q * 0.65f);
                up_river_recycle_lock = dc_clampf(up_river_recycle_lock, 0.0f, 1.0f);
            }
            const float up_river_source_scale = 1.0f - up_river_recycle_lock * 0.72f;
            const float up_ocean_an = up_on_water ? TA[upstream_idx] : effective_ocean_an;
            source_upwind = surface_vapor_source(
                upstream_idx, up_temp, up_base_m, wind_mag, up_ocean_an,
                up_on_water, up_is_lake, up_has_river, up_river_q, up_river_source_scale);
        }

        // 平流式湿团：vapor 去 base_m 锚定 → 本地与上风加权平流(强度随风速) + 邻域扩散 + 蒸发源。
        // 允许短暂过饱和(不夹 cap 上限)，由后续凝结消耗 → 随风移动的湿团。镜像 field_solver.gd。
        // 方案③ vapor 全预报化:平流主导(floor 0.55→0.75,低风也强输送)→水汽主要由上风决定=连续方程平流项,
        // 蒸发只是注入、降水/凝结是汇,水汽随风成河(atmospheric river)→ψ 在水汽河上移动沿途有水可榨成雨。
        float adv_w_v = field_advect_vapor * (0.75f + 0.25f * wind_mag);
        if (adv_w_v > 0.99f) adv_w_v = 0.99f;
        float vapor = PV[i] + (advected_vapor - PV[i]) * adv_w_v;
        vapor = vapor + (neighbor_vapor - vapor) * field_diffusion;
        vapor += source_local + source_upwind * wind_mag * 0.25f;
        // Stage14c ψ>0 气旋水汽辐合抽吸：向邻域较湿处靠拢(把周围湿气卷入移动涡旋)→突破"水汽静止锚定"，
        // 让降水能随 ψ 平移。仅邻域更湿时抽(不凭空造汽,有界≤邻域均值)，避免破坏水量平衡致全局过湿。
        const float psi_now = (PSI != nullptr) ? PSI[i] : 0.0f;
        if (psi_now > 0.0f && neighbor_vapor > vapor) {
            vapor += (neighbor_vapor - vapor) * psi_now * 0.78f;   // Stage14e 0.55→0.78 更强抽吸→湿气更跟 ψ→移动更明显
        }
        if (vapor < 0.0f) vapor = 0.0f;
        (void)advect_w;

        // (背风焚风干燥已移入下方凝结/降水的 lift<0 抑制，避免对 vapor 重复扣减)

        // temp_min/temp_max 已在上方 P3 融合 gather 中算出。
        const float temp_gradient = temp_max - temp_min;
        // 斜压门(温度梯度大=锋面/中纬冷季)；Stage9 #5 用于把 ψ 致雨限定在斜压带(锋面雨)。
        const float baroclinic_gate = wf_smoothstep(0.04f, 0.16f, temp_gradient);
        // Stage13「让天气移动」：ψ 的演化已抽到独立全场 pass run_synoptic_advance_pass(每轮一次、
        // 不切片、半拉格朗日平移)。本 solve 循环只【读】ψ 当前值做耦合 → ψ 移动 → 云/雨成片随风平移。
        const float psi = (PSI != nullptr) ? PSI[i] : 0.0f;
        float relative_humidity = vapor / ((vapor_capacity > 0.001f) ? vapor_capacity : 0.001f);
        if (relative_humidity < 0.0f) relative_humidity = 0.0f;
        const float frontal_convergence = wf_smoothstep(0.14f, 0.46f, convergence);
        const float humidity_front_gate = wf_smoothstep(0.25f, 0.78f, relative_humidity);  // Stage2: 0.38→0.25 冷湿锋面成雨
        float frontogenesis = frontal_convergence * wf_smoothstep(0.04f, 0.16f, temp_gradient)
                            * humidity_front_gate * field_frontogenesis_gain;
        if (frontogenesis < 0.0f) frontogenesis = 0.0f;
        else if (frontogenesis > 1.0f) frontogenesis = 1.0f;
        const float lift_pos = (lift > 0.0f) ? lift : 0.0f;

        // Stage11 层状降水(stratiform)：对流(temp>0.48 暖门)挡死的冷/高/水区水汽充足却无触发——补一支不需浮力
        // 的层状成雨：湿度 + 弱动力抬升(地形/辐合/锋面/海面层云·lake-effect),温度越低权重越高(与对流互补,
        // 不在暖区重复加雨)。海面项=海洋层云/冷湖效应(修#4湖/冷海·实测水汽0.204最足却几乎不降)。
        const float strat_cool = 1.0f - wf_smoothstep(0.40f, 0.62f, temp);       // 暖→0(交给对流) 冷→1
        const float oro_elev = wf_smoothstep(0.45f, 0.82f, ELEV[i]);             // 高地形(山地)抬升强度,供 stratiform + trig 复用
        const float strat_humid = wf_smoothstep(0.32f, 0.62f, relative_humidity); // Stage14f 0.42→0.32 中湿(山地/冷区 rh~0.39)也成层状雨
        float strat_drive = lift_pos * 0.90f + convergence * 0.60f + frontogenesis * 0.80f
                          + oro_elev * 0.35f;                                     // 弱化静态山地云源，避免固定山地永雨
        if (on_water) strat_drive += (0.22f + wind_mag * 0.30f) * (1.0f - local_sea_ice * 0.92f);
        if (strat_drive > 1.0f) strat_drive = 1.0f;
        float stratiform = strat_humid * strat_cool * strat_drive * field_stratiform_gain;
        if (stratiform < 0.0f) stratiform = 0.0f;
        else if (stratiform > 1.0f) stratiform = 1.0f;

        // 热力对流(大陆夏季雷暴/对流雨)：地表加热(高温)+本地水汽 → 浮力抬升凝结+高效降水。修复内陆
        // rh 永远<<静力阈(实测~0.15<<0.55)、lift/辐合皆缺 → 蒸散/平流来的 vapor 凝不成云的死结
        // (用户洞察:内陆本地蒸发应能成雨)。仅陆地(海洋有独立对流抑制)。季节自限:冬温<0.45 不触发;
        // 降水耗 vapor→rh 降→对流减弱→不永雨,呈"晴-积累-雷暴"间歇。rh*4.2 门控干空气(rh<0.05)不虚假对流。
        // 2026-06-22 雨云化根因修复：陆地 rh 中位仅0.18(>0.55 仅2.7% → 静力凝结 sup 基本为0=死)，
        // 成云降水 76% 靠本项热力对流。rh*5.0 门控把干空气(rh0.18)硬拉成半饱和 → 温暖陆地处处冒弱对流
        // → 产云水后平流扩散 → 遍地雾+小雨、无晴无强雨。convective 实测双峰(p50=0,p75=0.39)：在谷底
        // 0.28 硬截断 → 砍遍地弱对流(仅损失6.5%降水)使其转晴/多云，保留强对流核 → 明显降水突显、拉开
        // "晴↔强降水"对比。(GDScript field_solver 镜像同值)
        float conv_raw = wf_smoothstep(0.48f, 0.74f, temp) * dc_clampf(relative_humidity * 2.6f, 0.0f, 1.0f);
        const float convective = (on_water || conv_raw < 0.42f) ? 0.0f : conv_raw;
        float ocean_convective = 0.0f;
        if (on_water) {
            ocean_convective = wf_smoothstep(0.10f, 0.22f, ocean_an)
                * wf_smoothstep(0.58f, 0.78f, temp)
                * dc_clampf(relative_humidity, 0.0f, 1.0f);
            const float open_water = 1.0f - local_sea_ice * 0.92f;
            const float warm_humid_marine = wf_smoothstep(0.54f, 0.74f, temp)
                * wf_smoothstep(0.47f, 0.69f, relative_humidity)
                * dc_clampf(open_water, 0.0f, 1.0f);
            const float marine_convective_seed = warm_humid_marine * (0.20f + wind_mag * 0.36f);
            if (marine_convective_seed > ocean_convective) ocean_convective = marine_convective_seed;
            if (ocean_convective > 1.0f) ocean_convective = 1.0f;
        }
        float onshore_moist_flux = 0.0f;
        float coastal_monsoon_flux = 0.0f;
        if (!on_water && upstream_idx >= 0 && upstream_on_water) {
            onshore_moist_flux = wind_mag * dc_clampf(relative_humidity, 0.0f, 1.0f)
                               * wf_smoothstep(0.54f, 0.75f, temp);
            coastal_monsoon_flux = onshore_moist_flux;
        } else if (on_water && upstream_idx >= 0) {
            const int downwind_idx = wx_aligned(i, wind_dx, wind_dy);
            bool near_land = false;
            if (downwind_idx >= 0 && downwind_idx < n_cells) {
                near_land = !wf_is_water_terrain(TERR[downwind_idx]);
            }
            if (near_land) {
                coastal_monsoon_flux = wind_mag * dc_clampf(relative_humidity, 0.0f, 1.0f)
                                     * wf_smoothstep(0.56f, 0.76f, temp) * 0.75f;
            }
        }
        float dynamic_forcing = frontogenesis;
        const float convergence_forcing = convergence * 0.65f;
        if (convergence_forcing > dynamic_forcing) dynamic_forcing = convergence_forcing;
        if (convective > dynamic_forcing) dynamic_forcing = convective;
        if (ocean_convective > dynamic_forcing) dynamic_forcing = ocean_convective;
        if (coastal_monsoon_flux > dynamic_forcing) dynamic_forcing = coastal_monsoon_flux;
        if (stratiform > dynamic_forcing) dynamic_forcing = stratiform;  // Stage11 冷区层状降水
        // Stage12「让天气移动」: ψ>0(气旋/低压)在所有纬度加抬升(base)+斜压带额外强化(锋面)→移动的雨系统;
        // ψ 随流场平流→雨带跟着移动。Stage9 的纯斜压门控改为 base + 斜压 bonus(热带也吃 base,接受适度热带变率)。
        // Stage14「激进推 ψ 主导」: ψ>0(低压)强抬升成降水主驱动；ψ<0(高压)下沉【压低静止 lift】→连静止
        // 强迫的降水也压住 → 移动的晴空带。这样降水/晴空都跟 ψ 平移(天气成片移动)。代价:过湿+扰动雨热。
        if (psi > 0.0f) {
            dynamic_forcing += psi * (syn_base_lift + syn_front_force * baroclinic_gate);
        } else {
            dynamic_forcing *= (1.0f + psi * 0.85f);   // psi<0 → ×<1 压低静止抬升
            if (dynamic_forcing < 0.0f) dynamic_forcing = 0.0f;
        }
        // Stage6: post-rain 抑制留 45% 残余(辐合带雨团下完也进入不应期)。镜像 field_solver.gd。
        float post_rain_subsidence = wf_smoothstep(0.035f, 0.11f, PP[i])
            * (1.0f - 0.55f * wf_smoothstep(0.18f, 0.55f, dynamic_forcing));

        // climate-realism Stage1: Hadley/Ferrel omega (镜像 field_solver.gd)
        // dlat = 本格纬度距「热赤道」度数; ITCZ/风暴轴上升带增雨, 副热带下沉带抑制凝结+降水→晴干。
        float omega_ny = (wb_size_y > 0.001f)
            ? dc_clampf((POS[i].y - wb_pos_y) / wb_size_y, 0.0f, 1.0f) : 0.5f;
        float omega_adlat = (omega_ny - weather_lat_te_norm) * 180.0f;
        if (omega_adlat < 0.0f) omega_adlat = -omega_adlat;
        const float omega_itcz = 1.0f - wf_smoothstep(8.0f, 16.0f, omega_adlat);
        const float omega_storm = wf_smoothstep(40.0f, 48.0f, omega_adlat)
            * (1.0f - wf_smoothstep(62.0f, 70.0f, omega_adlat));
        float omega_ascent = (omega_itcz > omega_storm) ? omega_itcz : omega_storm;
        const float omega_descent = wf_smoothstep(14.0f, 22.0f, omega_adlat)
            * (1.0f - wf_smoothstep(34.0f, 42.0f, omega_adlat));
        const float omega_precip_mult = (1.0f + omega_ascent * OMEGA_ASCENT_GAIN)
            * (1.0f - omega_descent * OMEGA_DESCENT_GAIN);

        // 凝结 vapor→cloud_water：动力(抬升/辐合)主导 + 静力过饱和(rh 超阈) + 热力对流。
        float sup = relative_humidity - field_rh_condense;
        if (sup < 0.0f) sup = 0.0f;
        // Stage14「ψ 主导降水」：ψ 直接进【凝结/降水生成】(像 convective/stratiform 旁路 autoconv)，让移动的
        // ψ 涡旋成为降水主源→云雨成片随 ψ 平移。之前 base_lift 误加进 dynamic_forcing(不驱动 cond/trig)→无效。
        const float psi_lift = (psi > 0.0f) ? psi * (syn_base_lift + syn_front_force * baroclinic_gate) : 0.0f;
        const float psi_supp = (psi < 0.0f) ? (1.0f + psi * 0.50f) : 1.0f;  // ψ<0(高压)压低凝结+降水→移动晴空(Stage14c 0.80→0.50 收温和,防压太干)
        float cond_force = sup * field_static_cond_w + lift_pos * field_lift_cond_gain
                         + convergence * field_conv_cond_gain + frontogenesis * 1.35f
                         + convective * field_thermal_conv_cond
                         + ocean_convective * 0.90f
                         + stratiform * 0.75f
                         + psi_lift * 1.20f;     // 方案③+ 0.90→1.20 ψ 致凝结(移动涡旋成云,主导)
        if (cond_force < 0.0f) cond_force = 0.0f;
        else if (cond_force > 1.0f) cond_force = 1.0f;
        cond_force *= psi_supp;                  // Stage14 ψ<0 压低凝结
        cond_force *= (1.0f - post_rain_subsidence * 0.45f);
        cond_force *= (1.0f - omega_descent * OMEGA_DESCENT_COND);   // 副热带下沉抑制凝结
        float condensation = vapor * cond_force * field_condense_rate;
        if (lift < 0.0f) {                       // 背风下沉(焚风)抑制凝结
            float foehn = 1.0f + lift * field_rain_shadow_drying;
            if (foehn < 0.0f) foehn = 0.0f;
            condensation *= foehn;
        }
        if (condensation > vapor * 0.92f) condensation = vapor * 0.92f;
        if (condensation < 0.0f) condensation = 0.0f;
        vapor -= condensation;

        // cloud_water 随风平流(搬运湿团) + 凝结加入 + 邻域扩散。复用 vapor 平流 helper(传 PCW)。
        float cloud_water = (PCW != nullptr) ? PCW[i] : 0.0f;
        if (PCW != nullptr && upstream_idx >= 0 && upstream_idx < n_cells) {
            const float cw_upwind = wx_upstream_avg(
                i, upstream_idx, PCW, wind_dx, wind_dy);
            const float cw_neighbor = wf_neighbor_average_vapor_idx(i, NB, PCW);
            float adv_w_c = field_advect_cloud * (0.55f + 0.45f * wind_mag);
            if (adv_w_c > 0.98f) adv_w_c = 0.98f;
            cloud_water = cloud_water + (cw_upwind - cloud_water) * adv_w_c;
            cloud_water = cloud_water + (cw_neighbor - cloud_water) * field_diffusion;
        }
        cloud_water += condensation;
        if (cloud_water < 0.0f) cloud_water = 0.0f;
        else if (cloud_water > 1.0f) cloud_water = 1.0f;

        float instability = (temp - 0.48f) * 0.80f
                          + relative_humidity * 0.30f
                          + convergence * 0.55f
                          + lift_pos * 1.20f
                          + frontogenesis * 0.55f
                          + ocean_convective * 0.35f;
        if (instability < 0.0f) instability = 0.0f;
        else if (instability > 1.0f) instability = 1.0f;

        // 降水：autoconversion 消耗 cloud_water。动力(辐合/抬升/不稳定)触发主导，地形弱增强；
        // 背景 base_frac 很小 → 无动力区降水压到 wet 阈值以下 → 只有移动天气系统处成雨 → 雨随系统移动。
        float trig = field_autoconversion * (field_precip_base_frac
                        + lift_pos * field_lift_precip_gain
                        + convergence * field_conv_precip_gain
                        + frontogenesis * 0.85f
                        + instability * 0.30f);
        trig *= (1.0f + lift_pos * field_oro_precip_gain);
        trig += convective * field_thermal_conv_precip;   // 对流雨高效成雨，旁路 autoconv 瓶颈(内陆 cw 少)
        trig += ocean_convective * 0.95f;
        trig += stratiform * 0.80f;   // Stage11 层状降水高效成雨(冷/高/水区,旁路 autoconv)→修 #4湖/#5a雪/#6山
        trig += psi_lift * 1.50f;     // 方案③+ 1.10→1.50 ψ 致雨主驱动(降水成片随 ψ 平移,盖过静止 lift)
        trig += oro_elev * 0.18f * wf_smoothstep(0.02f, 0.10f, cloud_water);  // 弱化固定地形转化，保留迎风坡但不锁死雨核
        trig *= psi_supp;             // Stage14 ψ<0 压低降水→移动晴空
        if (trig < 0.0f) trig = 0.0f;
        else if (trig > 0.95f) trig = 0.95f;
        float precip_target = cloud_water * trig;
        precip_target *= omega_precip_mult;   // Stage1 omega: ITCZ/风暴轴增雨 + 副热带下沉抑雨(纬向廓线)
        // Stage9 #5 ψ 耦合：ψ<0(高压)强抑雨→湿季间断；ψ>0(低压)增雨——基础弱(syn_enh，热带也仅此)，
        // 斜压带额外强增(syn_front_enh×gate)→冷季锋面雨。这样热带不堆暴雨、中纬冷季出现雨热不同期降水。
        if (PSI != nullptr) {
            float syn_enh_eff = syn_enh + syn_front_enh * baroclinic_gate;
            float syn_mult = 1.0f + (psi < 0.0f ? psi * syn_supp : psi * syn_enh_eff);
            if (syn_mult < 0.0f) syn_mult = 0.0f;
            precip_target *= syn_mult;
        }
        // Stage6e 对流抑制记忆(双稳)：读累积抑制(本 tick 起始)，硬阈压制移到最终降水处(EMA 之后)。
        const float inhib_old = (INHIB != nullptr) ? INHIB[i] : 0.0f;
        if (lift < 0.0f) {
            float shadow = (-lift) * field_rain_shadow_drying;
            if (shadow > 0.85f) shadow = 0.85f;
            precip_target *= (1.0f - shadow);
        }
        if (has_river && river_recycle_lock > 0.0f) {
            const float river_relief = river_recycle_lock
                * (1.0f - wf_smoothstep(0.22f, 0.50f, dynamic_forcing));
            if (river_relief > 0.0f) {
                const float cloud_relief = cloud_water * 0.22f * river_relief;
                cloud_water -= cloud_relief;
                vapor += cloud_relief * 0.60f;
                precip_target *= (1.0f - 0.48f * river_relief);
            }
        }
        // 水面对流抑制(保留动力门控：辐合/锋生/暖流异常 释放降水；instability 仅极端深对流安全阀)。
        float ocean_drive = 0.0f;
        if (on_water) {
            float drv_an = ocean_an / 0.16f;
            if (drv_an < 0.0f) drv_an = 0.0f; else if (drv_an > 1.0f) drv_an = 1.0f;
            float drv_in = (instability - 0.52f) / 0.30f;
            if (drv_in < 0.0f) drv_in = 0.0f; else if (drv_in > 1.0f) drv_in = 1.0f;
            float drv_cv = (convergence - 0.38f) / 0.16f;
            if (drv_cv < 0.0f) drv_cv = 0.0f; else if (drv_cv > 1.0f) drv_cv = 1.0f;
            float drv_fr = frontogenesis / 0.16f;
            if (drv_fr < 0.0f) drv_fr = 0.0f; else if (drv_fr > 1.0f) drv_fr = 1.0f;
            float drv_mn = coastal_monsoon_flux / 0.18f;
            if (drv_mn < 0.0f) drv_mn = 0.0f; else if (drv_mn > 1.0f) drv_mn = 1.0f;
            float drv_hc = wf_smoothstep(0.47f, 0.69f, relative_humidity)
                * wf_smoothstep(0.040f, 0.105f, cloud_water)
                * wf_smoothstep(0.54f, 0.74f, temp);
            // Stage14e 湖泊不再额外压低 humid-convective 驱动(原 ×0.60 致湖面少雨绕湖)；湖泊像小内海正常对流。
            drv_hc *= 0.68f;
            ocean_drive = drv_an;
            if (drv_in > ocean_drive) ocean_drive = drv_in;
            if (drv_cv > ocean_drive) ocean_drive = drv_cv;
            if (drv_fr > ocean_drive) ocean_drive = drv_fr;
            if (drv_mn > ocean_drive) ocean_drive = drv_mn;
            if (drv_hc > ocean_drive) ocean_drive = drv_hc;
            if (omega_ascent > ocean_drive) ocean_drive = omega_ascent;   // ITCZ/风暴轴释放海面抑制
            float precip_suppression = field_ocean_precip_suppression;
            if (is_lake && precip_suppression > 0.10f) precip_suppression = 0.10f;  // Stage14e 湖泊几乎不抑制(像内陆水体能下雨)→不再绕湖(原0.35仍压制)
            if (!is_lake && precip_suppression > 0.78f) precip_suppression = 0.78f;
            const float ocean_lo = 1.0f - precip_suppression;
            precip_target *= ocean_lo + (1.0f - ocean_lo) * ocean_drive;
            const float marine_relief = post_rain_subsidence
                * (1.0f - wf_smoothstep(0.30f, 0.58f, ocean_drive));
            precip_target *= (1.0f - marine_relief * 0.72f);
        }
        if (precip_target > cloud_water) precip_target = cloud_water;   // 降水不超过现有云水
        if (precip_target < 0.0f) precip_target = 0.0f;
        cloud_water -= precip_target;
        if (cloud_water < 0.0f) cloud_water = 0.0f;
        const float precip_cloud_reserve = precip_target * (0.18f + dynamic_forcing * 0.18f);
        cloud_water += precip_cloud_reserve;
        if (cloud_water > 1.0f) cloud_water = 1.0f;
        const float quiet_core = 1.0f - wf_smoothstep(0.12f, 0.50f, dynamic_forcing);
        if (on_water && !is_lake && ocean_drive < 0.34f) {   // Stage14e 湖泊不刮云水(marine_scour 是海洋机制,会让小湖云存不住→绕湖)
            float marine_scour = cloud_water * (0.036f + (0.34f - ocean_drive) * 0.18f)
                               * (1.0f + post_rain_subsidence * 1.60f);
            if (marine_scour < 0.0f) marine_scour = 0.0f;
            if (marine_scour > cloud_water) marine_scour = cloud_water;
            cloud_water -= marine_scour;
            vapor += marine_scour * 0.55f;
        }

        // 干空气云水再蒸发回 vapor（湿团边缘消散 → 闭合水量收支）。
        float reevap = cloud_water * field_cloud_reevap * (1.0f - relative_humidity)
                     * (1.0f + post_rain_subsidence * 1.75f + quiet_core * 0.75f);
        if (reevap < 0.0f) reevap = 0.0f;
        if (reevap > cloud_water) reevap = cloud_water;
        cloud_water -= reevap;
        vapor += reevap;
        if (on_water) {
            vapor *= (1.0f - post_rain_subsidence
                * (1.0f - wf_smoothstep(0.28f, 0.58f, ocean_drive)) * 0.045f);
        }

        // 降水稳定性(地形阻尼 + 极端 soft cap) + EMA 时间惯性(保留)。
        precip_target = wf_apply_precip_stability(
            TERR[i], precip_target,
            field_wet_terrain_precip_damping,
            field_lake_precip_damping,
            field_extreme_precip_soft_cap,
            field_extreme_precip_softness);
        // Stage10 不应期(inhib≥1)作用于 target(EMA 前)→降水随惯性平滑衰减到近零，不再瞬间砍断(去时间跳变)。镜像 field_solver.gd。
        if (inhib_old >= 1.0f) {
            precip_target *= (1.0f - INHIB_STRENGTH);
        }
        float precip = PP[i] + (precip_target - PP[i]) * field_precip_inertia;
        if (precip_target < PP[i] && dynamic_forcing < 0.20f) {
            precip = precip + (precip_target - precip) * (post_rain_subsidence * 0.55f);
        }
        // Stage10b 空间平滑(非对称)：强填洞(precip<邻域→去棋盘洞+扩雨到干邻格，降永晴)、弱削峰(×0.30→保超级单体暴雨)。镜像 field_solver.gd。
        if (field_precip_spatial_smooth > 0.0f) {
            const float nbr_precip = wf_neighbor_average_vapor_idx(i, NB, PP);
            const float k = (nbr_precip > precip) ? field_precip_spatial_smooth
                                                  : field_precip_spatial_smooth * 0.30f;
            precip += (nbr_precip - precip) * k;
        }
        const float effective_precip_floor = on_water ? 0.014f : 0.018f;
        if (precip < 0.003f) precip = 0.0f;
        const float provisional_cloud = dc_clampf(cloud_water * 1.10f + condensation * 0.25f, 0.0f, 1.0f);
        const float temp_anom_i = (TANO != nullptr) ? TANO[i] : 0.0f;
        const float snow_cover_cls = (SNOWR != nullptr) ? SNOWR[i] : 0.0f;
        uint8_t pre_wt = wf_classify_field_weather_at(
            temp, vapor, provisional_cloud, cloud_water, precip, instability,
            ocean_an, wind_len, temp_anom_i,
            std::max(onshore_moist_flux, coastal_monsoon_flux),
            cold_precip_as_blizzard, snow_classification_margin, on_water, snow_cover_cls);
        const bool quiet_non_precip = !wf_is_precip_weather_type(pre_wt) && quiet_core > 0.0f;
        if ((precip < 0.003f || quiet_non_precip) && quiet_core > 0.0f) {
            float clear_cap = 0.065f + dynamic_forcing * 0.12f;
            if (on_water && ocean_drive < 0.20f) {
                const float ocean_cap = 0.070f + ocean_drive * 0.18f;
                if (ocean_cap < clear_cap) clear_cap = ocean_cap;
            }
            if (cloud_water > clear_cap) {
                const float excess_cloud_water = (cloud_water - clear_cap) * quiet_core;
                cloud_water -= excess_cloud_water;
                vapor += excess_cloud_water * 0.75f;
            }
        }
        if (quiet_non_precip && precip < effective_precip_floor) {
            vapor += precip * 0.65f;
            precip = 0.0f;
        }
        if (vapor < 0.0f) vapor = 0.0f;
        else if (vapor > 1.0f) vapor = 1.0f;   // 写回夹 [0,1]：下游(分类/可视/植被)按归一化消费
        float vapor_after_precip = vapor;
        (void)field_vapor_relax_rate;
        const float rain_core = wf_smoothstep(0.025f, 0.095f, precip);
        const float front_core = wf_smoothstep(0.08f, 0.55f, frontogenesis);
        float cloud_floor = rain_core * (0.14f + rain_core * 0.22f);
        const float front_cloud_floor = front_core * 0.30f;
        if (front_cloud_floor > cloud_floor) cloud_floor = front_cloud_floor;
        if (convective > 0.0f) {
            const float convective_cloud_floor = 0.06f + convective * 0.18f;
            if (convective_cloud_floor > cloud_floor) cloud_floor = convective_cloud_floor;
        }
        if (ocean_convective > 0.0f) {
            const float ocean_cloud_floor = 0.10f + ocean_convective * 0.16f;
            if (ocean_cloud_floor > cloud_floor) cloud_floor = ocean_cloud_floor;
        }
        if (quiet_non_precip) {
            const float fair_humid = wf_smoothstep(0.34f, 0.56f, relative_humidity);
            const float fair_cloud_floor = fair_humid * quiet_core * (0.050f + fair_humid * 0.070f);
            if (fair_cloud_floor > cloud_floor) cloud_floor = fair_cloud_floor;
        }
        float cloud = cloud_water * 1.10f + condensation * 0.25f;
        if (cloud < cloud_floor) cloud = cloud_floor;
        // Stage15 云量时间 EMA(减 shader 闪烁)：cloud 混入瞬时 condensation/cloud_floor(无时间惯性)→在渲染阈值
        // 附近抖动闪烁。用上帧云量做 EMA 平滑(cloud_water 本身已平滑,只需压住瞬时项的抖)。
        const float prev_cloud = PREV_CLOUD[i];
        cloud = prev_cloud + (cloud - prev_cloud) * field_cloud_inertia;
        if (cloud < 0.0f) cloud = 0.0f;
        else if (cloud > 1.0f) cloud = 1.0f;

        // classify + intensity
        uint8_t wt = wf_classify_field_weather_at(
            temp, vapor, cloud, cloud_water, precip, instability,
            ocean_an, wind_len, temp_anom_i,
            std::max(onshore_moist_flux, coastal_monsoon_flux),
            cold_precip_as_blizzard, snow_classification_margin, on_water, snow_cover_cls);
        if (!wf_is_precip_weather_type(wt) && precip > 0.0f) {
            vapor += precip * 0.65f;
            if (vapor > 1.0f) vapor = 1.0f;
            vapor_after_precip = vapor;
            precip = 0.0f;
        } else if (precip > 0.0f) {
            // Stage6 放电：实际降水抽干本格水汽→自发停雨/消散+随上风水汽移动+海面自生成。镜像 field_solver.gd。
            // Stage6b：持续降水(PP[i])放电翻倍→砍"连下一周"长尾，不动新生短雨段。
            const float discharge_amp = 1.0f + DISCHARGE_SUSTAIN * wf_smoothstep(0.04f, 0.10f, PP[i]);
            vapor_after_precip -= precip * VAPOR_DISCHARGE * discharge_amp;
            if (vapor_after_precip < 0.0f) vapor_after_precip = 0.0f;
        }
        // Stage6g 更新对流抑制(按时长两段)：充能期连续降水累加→满进不应期；不应期衰减→落回清零重启。镜像 field_solver.gd。
        if (INHIB != nullptr) {
            float ni;
            if (inhib_old >= 1.0f) {
                ni = inhib_old - INHIB_REFRAC;
                if (ni < 1.0f) ni = 0.0f;
            } else if (precip > INHIB_WET) {
                ni = inhib_old + INHIB_CHARGE;
                if (ni >= 1.0f) ni = 2.0f;
            } else {
                ni = inhib_old * INHIB_LEAK;
            }
            INHIB[i] = ni;
        }
        float intensity = wf_field_intensity_for_type(
            wt, temp, vapor, cloud, precip, instability, ocean_an);
        if (refresh_convergence && apply_convergence_boost) {
            wf_apply_frontal_convergence_boost_idx(
                i, TR, AA, NB, climate_anomaly, convergence,
                temp, vapor, ocean_an,
                cloud, precip, instability, wt, intensity);
        }

        uint8_t display_wt = wt;
        if (weather_transition_enabled && OUT_PREV_TYP != nullptr && OUT_TARGET_TYP != nullptr && OUT_ALPHA != nullptr) {
            const uint8_t current_display = OUT_TYP[i];
            uint8_t prev_type = OUT_PREV_TYP[i];
            uint8_t target_type = OUT_TARGET_TYP[i];
            float alpha = OUT_ALPHA[i];
            if (alpha < 0.0f) alpha = 0.0f;
            else if (alpha > 1.0f) alpha = 1.0f;
            if (target_type != wt) {
                prev_type = current_display;
                target_type = wt;
                alpha = weather_transition_alpha_rate * weather_transition_dt_days; // [dt-aware] 当前求解即计入
                if (alpha > 1.0f) alpha = 1.0f;
            } else if (prev_type == target_type || current_display == target_type) {
                prev_type = target_type;
                alpha = 0.0f;
            } else {
                alpha += weather_transition_alpha_rate * weather_transition_dt_days;
                if (alpha > 1.0f) alpha = 1.0f;
            }
            display_wt = (alpha >= 1.0f) ? target_type : prev_type;
            if (alpha >= 1.0f) {
                prev_type = target_type;
                alpha = 0.0f;
            }
            OUT_PREV_TYP[i] = prev_type;
            OUT_TARGET_TYP[i] = target_type;
            OUT_ALPHA[i] = alpha;
        }

        // (line 751-757) write outputs
        OUT_VAP[i] = vapor_after_precip;
        OUT_CLD[i] = cloud;
        if (OUT_CW != nullptr) {
            OUT_CW[i] = cloud_water;
        }
        OUT_PRE[i] = precip;
        OUT_INS[i] = instability;
        OUT_INT[i] = intensity;
        OUT_CNV[i] = convergence;
        if (use_next_outputs) {
            OUT_TYP_I32[i] = int32_t(wt);
        } else {
            OUT_TYP[i] = display_wt;
            OUT_FIN[i] = 1; // weather_field_initialized = true
        }
    }
    }; // run_weather_cell_range

    if (use_next_outputs && (end_idx - start_idx) >= 256) {
        // staged 路径并行（native daily）。区间 [start_idx, end_idx) → 0-based n + 偏移。
        pk::parallel_for_range("pk_weather_field", end_idx - start_idx,
            [&](int b, int e) { run_weather_cell_range(start_idx + b, start_idx + e); });
    } else {
        run_weather_cell_range(start_idx, end_idx);
    }

    // §11.2 flush: push CoW-detached weather output slots back to MapData
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

    for (int i = 0; i < n_cells; ++i) {
        W_DIRTY[i] = 0;
    }

    int dirty_count = 0;
    int convergence_dirty_count = 0;
    PackedFloat32Array convergence_deltas;
    if (refresh_convergence) {
        convergence_deltas.resize(n_cells);
    }
    float * const __restrict CONV_DELTA =
        refresh_convergence ? convergence_deltas.ptrw() : nullptr;
    double water_budget_error_acc = 0.0;
    constexpr float CHANGE_EPS = 0.002f;

    for (int i = 0; i < n_cells; ++i) {
        const float v_vapor = NEXT_VAP[i];
        const float v_cloud = NEXT_CLD[i];
        const float v_cloud_water =
            (NEXT_CW != nullptr) ? NEXT_CW[i] : (v_cloud * 0.5f);
        const float v_precip = NEXT_PRE[i];
        const float v_instability = NEXT_INS[i];
        const float v_intensity = NEXT_INT[i];
        const float v_convergence = NEXT_CNV[i];
        const uint8_t v_type = static_cast<uint8_t>(NEXT_TYP[i] & 0xFF);
        if (refresh_convergence) {
            const float conv_delta = std::fabs(W_CNV[i] - v_convergence);
            if (conv_delta > 0.0005f && CONV_DELTA != nullptr) {
                CONV_DELTA[convergence_dirty_count++] = conv_delta;
            }
        }

        const float prev_budget_cloud_water = (W_CW != nullptr) ? W_CW[i] : 0.0f;
        water_budget_error_acc += std::fabs(
            double(v_vapor + v_cloud_water + v_precip) -
            double(PREV_VAP[i] + prev_budget_cloud_water));

        uint8_t display_type = v_type;
        uint8_t prev_type = v_type;
        uint8_t target_type = v_type;
        float alpha = 1.0f;
        if (weather_transition_enabled && W_PREV != nullptr && W_TARGET != nullptr && W_ALPHA != nullptr) {
            const uint8_t current_display = W_TYP[i];
            prev_type = W_PREV[i];
            target_type = W_TARGET[i];
            alpha = W_ALPHA[i];
            if (alpha < 0.0f) alpha = 0.0f;
            else if (alpha > 1.0f) alpha = 1.0f;
            if (target_type != v_type) {
                prev_type = current_display;
                target_type = v_type;
                alpha = transition_rate * transition_dt_days; // [dt-aware] 当前求解即计入
                if (alpha > 1.0f) alpha = 1.0f;
            } else if (prev_type == target_type || current_display == target_type) {
                prev_type = target_type;
                alpha = 0.0f;
            } else {
                alpha += transition_rate * transition_dt_days;
                if (alpha > 1.0f) alpha = 1.0f;
            }
            display_type = (alpha >= 1.0f) ? target_type : prev_type;
            if (alpha >= 1.0f) {
                prev_type = target_type;
                alpha = 0.0f;
            }
        }

        bool weather_changed = false;
        weather_changed = weather_changed || (std::fabs(W_VAP[i] - v_vapor) > CHANGE_EPS);
        weather_changed = weather_changed || (std::fabs(W_CLD[i] - v_cloud) > CHANGE_EPS);
        if (W_CW != nullptr) {
            weather_changed = weather_changed || (std::fabs(W_CW[i] - v_cloud_water) > CHANGE_EPS);
        }
        weather_changed = weather_changed || (std::fabs(W_PRE[i] - v_precip) > CHANGE_EPS);
        weather_changed = weather_changed || (W_TYP[i] != display_type);

        if (weather_changed) {
            if (W_DIRTY[i] == 0) {
                W_DIRTY[i] = 1;
                ++dirty_count;
            }
            const int nb_base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb_i = NB[nb_base + d];
                if (nb_i >= 0 && nb_i < n_cells && W_DIRTY[nb_i] == 0) {
                    W_DIRTY[nb_i] = 1;
                    ++dirty_count;
                }
            }
        }

        W_INT[i] = v_intensity;
        W_CLD[i] = v_cloud;
        if (W_CW != nullptr) {
            W_CW[i] = v_cloud_water;
        }
        W_PRE[i] = v_precip;
        W_TYP[i] = display_type;
        const int w4 = i * 4;
        WX[w4] = display_type;
        WX[w4 + 1] = q01_byte_commit(v_intensity);
        WX[w4 + 2] = q01_byte_commit(v_cloud);
        WX[w4 + 3] = q01_byte_commit(v_precip);
        if (W_PREV != nullptr) {

            W_PREV[i] = prev_type;
        }
        if (W_TARGET != nullptr) {
            W_TARGET[i] = target_type;
        }
        if (W_ALPHA != nullptr) {
            W_ALPHA[i] = alpha;
        }
        W_VAP[i] = v_vapor;
        W_CNV[i] = v_convergence;
        W_INS[i] = v_instability;
        W_FIN[i] = 1;
    }

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

    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || !knobs.has("temp_before_arr")) {
        diag("knobs missing required keys");
        return -1.0;
    }

    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    const float heat_mix     = float(knobs["heat_mix"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    const int end_idx_raw = knobs.has("end_idx") ? int(knobs["end_idx"]) : n_cells;
    if (start_idx < 0 || start_idx > n_cells) { diag("invalid start_idx"); return -1.0; }
    const int end_idx = std::min(std::max(end_idx_raw, start_idx), n_cells);

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr = knobs["temp_before_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (baseline_arr.size() != n_cells) { diag("baseline_arr size mismatch"); return -1.0; }
    if (temp_before_arr.size() != n_cells) { diag("temp_before_arr size mismatch"); return -1.0; }

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
    const float * const __restrict TB = temp_before_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

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
                const float dx = POSX[ni] - swx;
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
        float speed_mix = wf_wind_speed_norm(wind_x, wind_y, WSP[i]) / 1.2f;
        if (speed_mix < 0.25f) speed_mix = 0.25f;
        else if (speed_mix > 1.35f) speed_mix = 1.35f;
        const float temp_mixed_raw = temp_self + (temp_up - temp_self) * heat_mix * speed_mix;
        A[i] = temp_mixed_raw - BL[i];
    }

    knobs["cursor_start"] = start_idx;
    knobs["cursor_end"] = end_idx;
    knobs["processed_cells"] = end_idx - start_idx;

    _flush_slot_to_map(sid_air_anom);

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

    auto t0 = std::chrono::high_resolution_clock::now();

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
            const float dx = swx - POSX[ni];
            const float dy = swy - POSY[ni];
            const float len2 = dx * dx + dy * dy;
            if (len2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(len2);
            const float weight = (dx * wind_x + dy * wind_y) * inv_len;
            if (weight <= 0.0f) continue;
            float speed_w = wf_wind_speed_norm(wind_x, wind_y, WSP[ni]) / 1.2f;
            if (speed_w < 0.20f) speed_w = 0.20f;
            else if (speed_w > 1.35f) speed_w = 1.35f;
            const float adv_weight = weight * speed_w;
            weighted_sum += AIN[ni] * adv_weight;
            weight_total += adv_weight;
        }

        // 风致 air-mass 平流：把邻接 air-mass anomaly 加权平均到本 cell 的 air anomaly。
        float anomaly_in = 0.0f;
        if (weight_total > 0.0f) {
            anomaly_in = (weighted_sum / weight_total) * air_leak;
        }
        // A 修复（2026-06）：air anomaly 是单 round 的瞬时 deviation（不持久），
        // 改为 OVERWRITE 而非 accumulate。原 scalar 实现里 AOUT[i] = anomaly_in (覆写)，
        // 后面 T[i] += anomaly_in 把本日 air 注入一次。新架构合成 T = baseline +
        // transport(ocean_anom + air_anom) + local_anom，同样要求 air_anom 每天重写
        // （否则会日复一日累加到 cap）。
        float air_final = anomaly_in;
        if (air_final < -0.08f) air_final = -0.08f;
        else if (air_final > 0.08f) air_final = 0.08f;
        AOUT[i] = air_final;

        // 合成 cell_temp：ocean 与 air 都是横向热输运，先共享同一 ±0.08 预算；
        // 对接近结冰线的水格，正向输运先被潜热/成冰门控吸收，避免无冰边缘水面
        // 被固定抬高到 melt 阈值以上而无法重新结冰。
        float base = BL_RUNTIME[i];
        // A polar-night / frozen baseline of exactly 0.0 is valid. Only non-finite
        // runtime baselines should fall back to the year/static baseline.
        if (!std::isfinite(base)) base = FBL[i];
        float transport_anom = OANOM[i] + air_final;
        if (IW[i] != 0 && transport_anom > 0.0f) {
            transport_anom *= wf_smoothstep(cold_transport_form, cold_transport_melt, base);
        }
        if (transport_anom < -0.08f) transport_anom = -0.08f;
        else if (transport_anom > 0.08f) transport_anom = 0.08f;
        float total_anom = transport_anom + LANOM[i];
        if (total_anom < -0.15f) total_anom = -0.15f;
        else if (total_anom > 0.15f) total_anom = 0.15f;
        float total = base + total_anom;
        if (total < 0.0f) total = 0.0f;
        else if (total > 1.0f) total = 1.0f;
        T[i] = total;
    }

    s_air_anom.arr_f32 = anomaly_out;
    knobs["cursor_start"] = start_idx;
    knobs["cursor_end"] = end_idx;
    knobs["processed_cells"] = end_idx - start_idx;

    _flush_slot_to_map(sid_temp);
    _flush_slot_to_map(sid_air_anom);

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

    const int   n_cells              = int(knobs["n_cells"]);
    const float snow_min_intensity   = float(knobs["snow_min_intensity"]);
    const float snow_freeze_t        = float(knobs["snow_freeze_t"]);
    const float snow_melt_t          = float(knobs["snow_melt_t"]);
    const float snow_intensity_snow  = float(knobs["snow_intensity_for_snowing"]);
    const int   snow_accum_days_req  = int(knobs["snow_accum_days_req"]);
    const float flood_heavy_int      = float(knobs["flood_heavy_intensity"]);
    const float flood_heavy_pre      = float(knobs["flood_heavy_precip"]);
    const float flood_low_int        = float(knobs["flood_lowland_intensity"]);
    const float flood_low_elev       = float(knobs["flood_lowland_elev"]);
    const float flood_low_moist      = float(knobs["flood_lowland_moisture"]);
    const int   wt_clear             = int(knobs["wt_clear"]);
    const int   cv_snow              = int(knobs["cv_snow"]);
    const int   cv_none              = int(knobs["cv_none"]);
    const int   cv_flooding          = int(knobs["cv_flooding"]);
    const float snowpack_accum_gain  = knobs.has("snowpack_accum_gain") ? float(knobs["snowpack_accum_gain"]) : 0.10f;
    const float snowpack_melt_temp_gain = knobs.has("snowpack_melt_temp_gain") ? float(knobs["snowpack_melt_temp_gain"]) : 0.22f;
    const float snowpack_melt_sun_gain = knobs.has("snowpack_melt_sun_gain") ? float(knobs["snowpack_melt_sun_gain"]) : 0.12f;
    const float snowpack_cover_low   = knobs.has("snowpack_cover_low") ? float(knobs["snowpack_cover_low"]) : 0.05f;
    const float snowpack_cover_full  = knobs.has("snowpack_cover_full") ? float(knobs["snowpack_cover_full"]) : 0.32f;
    const float snowpack_cover_span  = (snowpack_cover_full - snowpack_cover_low) > 0.001f
        ? (snowpack_cover_full - snowpack_cover_low) : 0.001f;
    // climate-loop-closure Phase 2.1：气候态物理雪线 floor 参数（threshold=0 关闭）。
    const float snowline_temp_threshold = knobs.has("snowline_temp_threshold") ? float(knobs["snowline_temp_threshold"]) : 0.24f;
    const float snowline_band = knobs.has("snowline_band") ? float(knobs["snowline_band"]) : 0.22f;
    const float snowline_band_safe = snowline_band > 0.001f ? snowline_band : 0.001f;
    float weather_temp_anomaly_cap = knobs.has("weather_temp_anomaly_cap") ? float(knobs["weather_temp_anomaly_cap"]) : 0.025f;
    if (weather_temp_anomaly_cap < 0.0f) weather_temp_anomaly_cap = 0.0f;
    else if (weather_temp_anomaly_cap > 0.10f) weather_temp_anomaly_cap = 0.10f;

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
    float * const __restrict T   = s_temp.arr_f32.ptrw();
    float * const __restrict M   = s_moist.arr_f32.ptrw();
    float * const __restrict SC  = s_snow_cov.arr_f32.ptrw();
    float * const __restrict SP  = s_snowpack.arr_f32.ptrw();
    float * const __restrict WB  = s_waterbal.arr_f32.ptrw();
    float * const __restrict SOIL = s_soil.arr_f32.ptrw();
    uint8_t * const __restrict CV = s_cover.arr_u8.ptrw();
    const uint8_t * const __restrict LF = s_lf.arr_u8.ptr();
    const uint8_t * const __restrict TERR = s_terrain.arr_u8.ptr();
    const float * const __restrict EL = s_elev.arr_f32.ptr();
    const float * const __restrict HEAT = s_heat.arr_f32.ptr();
    const float * const __restrict WI = s_w_int.arr_f32.ptr();
    const float * const __restrict WP = s_w_pre.arr_f32.ptr();
    const uint8_t * const __restrict WT_ = s_w_typ.arr_u8.ptr();
    const uint8_t * const __restrict WFI = s_w_fin.arr_u8.ptr();
    int32_t * const __restrict ACC = acc_snow_days.ptrw();
    int32_t * const __restrict PRE = pre_snow_cover.ptrw();
    const float * const __restrict TD = temp_delta_arr.ptr();
    const float * const __restrict MD = moist_delta_arr.ptr();
    const uint8_t * const __restrict CFS = cfs_arr.ptr();
    const uint8_t * const __restrict CFF = cff_arr.ptr();

    auto clamp01 = [](float v) -> float {
        if (v < 0.0f) return 0.0f;
        if (v > 1.0f) return 1.0f;
        return v;
    };
    auto clampf = [](float v, float lo, float hi) -> float {
        return v < lo ? lo : (v > hi ? hi : v);
    };
    auto smoothstep_local = [&](float a, float b, float x) -> float {
        if (b <= a) return x >= b ? 1.0f : 0.0f;
        float t = (x - a) / (b - a);
        if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
        return t * t * (3.0f - 2.0f * t);
    };
    constexpr uint8_t COVER_GLACIER = 2;

    auto snow_summer_melt_bonus = [&](float heat_input, float elevation) -> float {
        const float sun = smoothstep_local(0.55f, 0.90f, clampf(heat_input, 0.0f, 1.0f));
        const float high_elev = smoothstep_local(0.62f, 0.95f, clampf(elevation, 0.0f, 1.0f));
        return sun * (1.0f - high_elev * 0.60f) * 0.045f;
    };

    auto snowline_floor_for_cell = [&](float temp_now, float heat_input, float elevation,
                                       float snowline_temp_threshold,
                                       float snowline_band_safe) -> float {
        if (snowline_temp_threshold <= 0.0f) return 0.0f;
        const float sun = smoothstep_local(0.45f, 0.85f, clampf(heat_input, 0.0f, 1.0f));
        const float high_elev = smoothstep_local(0.60f, 0.95f, clampf(elevation, 0.0f, 1.0f));
        const float summer_drop = sun * (0.14f + (0.045f - 0.14f) * high_elev);
        const float elev_bonus = clampf((elevation - 0.30f) * 0.10f, 0.0f, 0.08f);
        const float effective_threshold = snowline_temp_threshold + elev_bonus - summer_drop;
        const float raw_floor = clampf((effective_threshold - temp_now) / snowline_band_safe, 0.0f, 1.0f);
        // Stage4(2026-06-23): 雪线 floor 只为深冻区自动铺白；雪线边缘交给 snowpack-from-snowfall。
        // 镜像 weather_system.gd _snowline_floor_for_cell。
        return smoothstep_local(0.30f, 0.80f, raw_floor);
    };

    // LandformType.is_water：DEEP_OCEAN(0) / OCEAN(1) / COAST(2) / LAKE(3) → true
    auto is_water_lf = [](uint8_t lf) -> bool {
        return lf <= 3;
    };
    auto is_water_terrain = [](uint8_t t) -> bool {
        return t == 0  ||  // OCEAN
               t == 1  ||  // COAST
               t == 18 ||  // LAKE
               t == 19 ||  // REEF
               t == 20 ||  // SEA_ICE
               t == 21;    // KELP
    };

    // ─── 主循环（1:1 复刻 _distribute_weather_field_to_cells + _apply_snow_accumulation）─
    PackedInt32Array changed_cells;
    bool cover_dirty = false;
    for (int i = 0; i < n_cells; ++i) {
        const bool field_init = WFI[i] != 0;
        const int  wt        = field_init ? int(WT_[i]) : wt_clear;
        const float intensity = field_init ? WI[i] : 0.0f;
        const float raw_precip = field_init ? WP[i] : 0.0f;
        const float precip = (field_init && wf_is_precip_weather_type(uint8_t(wt))) ? raw_precip : 0.0f;

        // CLEAR / 低强度退化分支
        if (wt == wt_clear || intensity <= snow_min_intensity) {
            const bool water_lf = is_water_lf(LF[i]) || is_water_terrain(TERR[i]);
            if (!water_lf && (ACC[i] > 0 || CV[i] == cv_snow)) {
                // _apply_snow_accumulation(cell, wt, cell.temperature, 0.0)
                // intensity = 0 ⇒ snowing 永假；只有融化 / 升级判定可能触发。
                // 2026-05-18 雪线修正：melt_t 加 elev 偏移（高山难融，平原易融）。
                //   与 GDScript SNOW_ELEV_NEUTRAL=0.30 / MELT_GAIN=0.30 / MAX_OFF=0.10 SAME_SOURCE。
                const float elev_delta_c = EL[i] - 0.30f;
                float melt_off_c = elev_delta_c * 0.30f;
                if (melt_off_c >  0.10f) melt_off_c =  0.10f;
                else if (melt_off_c < -0.10f) melt_off_c = -0.10f;
                const float melt_t_local = snow_melt_t + melt_off_c;
                const float temp_now = T[i];
                if (temp_now > melt_t_local) {
                    int new_acc = ACC[i] - 1;
                    if (new_acc < 0) new_acc = 0;
                    ACC[i] = new_acc;
                }
                // 升级 / 融化（与下方主分支同算法）
                if (ACC[i] >= snow_accum_days_req && CV[i] != cv_snow && CV[i] != COVER_GLACIER) {
                    PRE[i] = int(CV[i]);
                    CV[i] = uint8_t(cv_snow);
                    changed_cells.append(i);
                    cover_dirty = true;
                } else if (ACC[i] <= 0 && CV[i] == cv_snow) {
                    int restored = (PRE[i] >= 0) ? PRE[i] : cv_none;
                    CV[i] = uint8_t(restored);
                    PRE[i] = -1;
                    changed_cells.append(i);
                    cover_dirty = true;
                }
            }
            float sp = SP[i];
            float wb = WB[i];
            float soil = SOIL[i];
            float sc = 0.0f;
            if (water_lf) {
                SP[i] = 0.0f;
                WB[i] = wb + (0.0f - wb) * (1.0f / 30.0f);
                SC[i] = 0.0f;
            } else {
                const float elev_delta = EL[i] - 0.30f;
                float melt_off = elev_delta * 0.30f;
                if (melt_off > 0.10f) melt_off = 0.10f;
                else if (melt_off < -0.10f) melt_off = -0.10f;
                const float melt_t_local = snow_melt_t + melt_off;
                float freeze_off = elev_delta * 0.20f;
                if (freeze_off > 0.06f) freeze_off = 0.06f;
                else if (freeze_off < -0.06f) freeze_off = -0.06f;
                const float freeze_t_local = snow_freeze_t + freeze_off;
                const bool cold_precip = (T[i] < freeze_t_local) && (precip > 0.002f);
                float snow_accum = cold_precip ? precip * snowpack_accum_gain * 0.75f : 0.0f;
                if (cold_precip) {
                    snow_accum += (intensity < 0.15f ? intensity : 0.15f) * 0.006f;
                }
                const float melt = ((T[i] - melt_t_local) > 0.0f ? (T[i] - melt_t_local) : 0.0f) * snowpack_melt_temp_gain
                    + HEAT[i] * snowpack_melt_sun_gain
                    + snow_summer_melt_bonus(HEAT[i], EL[i]);
                sp = clampf(sp + snow_accum - melt, 0.0f, 1.0f);
                if (CV[i] == COVER_GLACIER && sp < 0.80f) sp = 0.80f;
                const float evap_proxy = clampf((0.01f + ((M[i] - 0.45f) > 0.0f ? (M[i] - 0.45f) : 0.0f) * 0.03f)
                    * (0.35f + T[i] * 1.05f) * 0.65f, 0.0f, 1.0f);
                const float runoff = ((M[i] - 0.82f) > 0.0f ? (M[i] - 0.82f) : 0.0f) * 0.25f
                    + ((EL[i] - 0.70f) > 0.0f ? (EL[i] - 0.70f) : 0.0f) * precip * 0.06f;
                const float daily_balance = clampf(precip - evap_proxy - runoff, -1.0f, 1.0f);
                wb = wb + (daily_balance - wb) * (1.0f / 30.0f);
                // climate-loop-closure Phase 3.1：土壤水每日衰减(×0.97)，停雨后排干。
                soil = clampf(soil * 0.97f + daily_balance * 0.08f, -0.5f, 0.5f);
                M[i] = clamp01(M[i] + precip * 0.35f
                    + ((daily_balance > 0.0f) ? daily_balance * 0.04f : 0.0f));
                // climate-loop-closure Phase 2.1/2.2：物理雪线 floor（仅陆地）。
                float snow_floor_c = 0.0f;
                if (snowline_temp_threshold > 0.0f) {
                    snow_floor_c = snowline_floor_for_cell(T[i], HEAT[i], EL[i], snowline_temp_threshold, snowline_band_safe);
                    if (snow_floor_c * snowpack_cover_full > sp) sp = snow_floor_c * snowpack_cover_full;
                }
                float u = (sp - snowpack_cover_low) / snowpack_cover_span;
                if (u < 0.0f) u = 0.0f; else if (u > 1.0f) u = 1.0f;
                sc = u * u * (3.0f - 2.0f * u);
                if (snow_floor_c > sc) sc = snow_floor_c;
                if (CV[i] == COVER_GLACIER && sc < 0.80f) sc = 0.80f;
                SP[i] = sp;
                WB[i] = wb;
                SOIL[i] = soil;
                SC[i] = sc;
            }
            continue;
        }

        const float td_v = (wt >= 0 && wt < 8) ? TD[wt] : 0.0f;
        const float md_v = (wt >= 0 && wt < 8) ? MD[wt] : 0.0f;
        const float moist_now = clamp01(M[i] + md_v * intensity + precip * 0.35f);
        float temp_delta = td_v * intensity;
        if (temp_delta > weather_temp_anomaly_cap) temp_delta = weather_temp_anomaly_cap;
        else if (temp_delta < -weather_temp_anomaly_cap) temp_delta = -weather_temp_anomaly_cap;
        const float temp_now  = clamp01(T[i] + temp_delta);
        M[i] = moist_now;
        T[i] = temp_now;

        float sp_now = SP[i];
        const float prev_sp = sp_now;
        float wb_now = WB[i];
        float soil_now = SOIL[i];
        const bool water_lf_weather = is_water_lf(LF[i]) || is_water_terrain(TERR[i]);
        if (water_lf_weather) {
            sp_now = 0.0f;
            wb_now = wb_now + (0.0f - wb_now) * (1.0f / 30.0f);
        } else {
            const float elev_delta_sp = EL[i] - 0.30f;
            float freeze_off_sp = elev_delta_sp * 0.20f;
            if (freeze_off_sp > 0.06f) freeze_off_sp = 0.06f;
            else if (freeze_off_sp < -0.06f) freeze_off_sp = -0.06f;
            float melt_off_sp = elev_delta_sp * 0.30f;
            if (melt_off_sp > 0.10f) melt_off_sp = 0.10f;
            else if (melt_off_sp < -0.10f) melt_off_sp = -0.10f;
            const float freeze_t_sp = snow_freeze_t + freeze_off_sp;
            const float melt_t_sp = snow_melt_t + melt_off_sp;
            const bool can_snow_sp = (wt >= 0 && wt < 8) && (CFS[wt] != 0);
            const bool precip_can_snow_sp = (wt != wt_clear) && (wt != 4) && (wt != 6);
            const bool snowing_sp = (can_snow_sp || precip_can_snow_sp) && (temp_now < freeze_t_sp) && (precip > 0.0f);
            float snow_accum = snowing_sp ? (precip * snowpack_accum_gain + intensity * 0.015f) : 0.0f;
            const float warm_rain_melt = (temp_now > melt_t_sp) ? precip * 0.03f : 0.0f;
            const float melt = ((temp_now - melt_t_sp) > 0.0f ? (temp_now - melt_t_sp) : 0.0f) * snowpack_melt_temp_gain
                + HEAT[i] * snowpack_melt_sun_gain
                + snow_summer_melt_bonus(HEAT[i], EL[i])
                + warm_rain_melt;
            sp_now = clampf(sp_now + snow_accum - melt, 0.0f, 1.0f);
            if (CV[i] == COVER_GLACIER && sp_now < 0.80f) sp_now = 0.80f;
            const float meltwater = (prev_sp - sp_now) > 0.0f ? (prev_sp - sp_now) : 0.0f;
            const float runoff = ((moist_now - 0.82f) > 0.0f ? (moist_now - 0.82f) : 0.0f) * 0.25f
                + ((EL[i] - 0.70f) > 0.0f ? (EL[i] - 0.70f) : 0.0f) * precip * 0.06f;
            const float evap_proxy = clampf((0.01f + ((moist_now - 0.45f) > 0.0f ? (moist_now - 0.45f) : 0.0f) * 0.03f)
                * (0.35f + temp_now * 1.05f) * 0.65f, 0.0f, 1.0f);
            const float daily_balance = clampf(precip * 1.15f + meltwater * 0.65f - evap_proxy - runoff, -1.0f, 1.0f);
            wb_now = wb_now + (daily_balance - wb_now) * (1.0f / 30.0f);
            // climate-loop-closure Phase 3.1：土壤水每日衰减(×0.97)，停雨后排干。
            soil_now = clampf(soil_now * 0.97f + daily_balance * 0.08f, -0.5f, 0.5f);
        }
        // climate-loop-closure Phase 2.1/2.2：物理雪线 floor（仅陆地）。
        float snow_floor_w = 0.0f;
        if (snowline_temp_threshold > 0.0f && !water_lf_weather) {
            snow_floor_w = snowline_floor_for_cell(temp_now, HEAT[i], EL[i], snowline_temp_threshold, snowline_band_safe);
            if (snow_floor_w * snowpack_cover_full > sp_now) sp_now = snow_floor_w * snowpack_cover_full;
        }
        float u_sp = (sp_now - snowpack_cover_low) / snowpack_cover_span;
        if (u_sp < 0.0f) u_sp = 0.0f; else if (u_sp > 1.0f) u_sp = 1.0f;
        float snow_cover_now = u_sp * u_sp * (3.0f - 2.0f * u_sp);
        if (snow_floor_w > snow_cover_now) snow_cover_now = snow_floor_w;
        if (CV[i] == COVER_GLACIER && snow_cover_now < 0.80f) snow_cover_now = 0.80f;
        SP[i] = sp_now;
        SC[i] = snow_cover_now;
        WB[i] = wb_now;
        SOIL[i] = soil_now;

        if (!water_lf_weather) {
            // 雪：累积式 _apply_snow_accumulation(cell, wt, temp_now, intensity)
            // 2026-05-18 雪线修正：freeze_t / melt_t 随 elev 偏移（与 GDScript SAME_SOURCE）。
            //   neutral=0.30；freeze_gain=0.20，max_off=±0.06；melt_gain=0.30，max_off=±0.10。
            const float elev_delta_m = EL[i] - 0.30f;
            float freeze_off_m = elev_delta_m * 0.20f;
            if (freeze_off_m >  0.06f) freeze_off_m =  0.06f;
            else if (freeze_off_m < -0.06f) freeze_off_m = -0.06f;
            float melt_off_m = elev_delta_m * 0.30f;
            if (melt_off_m >  0.10f) melt_off_m =  0.10f;
            else if (melt_off_m < -0.10f) melt_off_m = -0.10f;
            const float freeze_t_local = snow_freeze_t + freeze_off_m;
            const float melt_t_local   = snow_melt_t   + melt_off_m;
            const bool can_snow = (wt >= 0 && wt < 8) && (CFS[wt] != 0);
            const bool snowing  = can_snow && (temp_now < freeze_t_local) && (intensity > snow_intensity_snow);
            if (snowing) {
                ACC[i] += 1;
            } else if (temp_now > melt_t_local) {
                int new_acc = ACC[i] - 1;
                if (new_acc < 0) new_acc = 0;
                ACC[i] = new_acc;
            }
            if (ACC[i] >= snow_accum_days_req && CV[i] != cv_snow && CV[i] != COVER_GLACIER) {
                PRE[i] = int(CV[i]);
                CV[i] = uint8_t(cv_snow);
                changed_cells.append(i);
                cover_dirty = true;
            } else if (ACC[i] <= 0 && CV[i] == cv_snow) {
                int restored = (PRE[i] >= 0) ? PRE[i] : cv_none;
                CV[i] = uint8_t(restored);
                PRE[i] = -1;
                changed_cells.append(i);
                cover_dirty = true;
            }

            // 洪涝
            const bool can_flood = (wt >= 0 && wt < 8) && (CFF[wt] != 0);
            if (CV[i] != cv_snow && can_flood) {
                const bool heavy_flood   = (intensity > flood_heavy_int) && (precip > flood_heavy_pre);
                const bool lowland_flood = (intensity > flood_low_int) && (EL[i] < flood_low_elev) && (moist_now > flood_low_moist);
                if ((heavy_flood || lowland_flood) && CV[i] != cv_flooding) {
                    CV[i] = uint8_t(cv_flooding);
                    changed_cells.append(i);
                    cover_dirty = true;
                }
            }
            // Stage8 退水(不受 can_flood 门限制→DROUGHT/CLEAR 也能退)：修"洪泛与旱灾共存"。镜像 weather_system.gd。
            if (CV[i] == cv_flooding && moist_now < 0.50f && precip < 0.04f) {
                CV[i] = uint8_t(cv_none);
                changed_cells.append(i);
                cover_dirty = true;
            }
        }
    }

    // ─── §11.2 flush：把 CoW-detach 后的 temp/moisture/cover 推回 GDScript
    // MapData property（与 F.1 / F.2 等同模式）。──────────────────────────
    _flush_slot_to_map(sid_temp);
    _flush_slot_to_map(sid_moisture);
    _flush_slot_to_map(sid_snow_cover);
    _flush_slot_to_map(sid_snowpack);
    _flush_slot_to_map(sid_water_bal);
    _flush_slot_to_map(sid_soil_moist);
    _flush_slot_to_map(sid_cover);

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
    PackedByteArray  water_ids = knobs.get("water_terrain_ids", PackedByteArray());
    PackedInt32Array cell_q    = knobs.get("cell_q_arr", PackedInt32Array());
    PackedInt32Array cell_r    = knobs.get("cell_r_arr", PackedInt32Array());

    // ─── Phase 1: 衰减 / 淘汰 ───────────────────────────────────────────
    // 等价 GDScript: days_left -= 1；<=0 删除；否则 vec = vec_init * days_left/init_days
    {
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

            Vector2 wind = f.get("velocity", Vector2());
            const float front_speed_norm = wind.length() / std::max(hex_size, 0.001f);
            if (T[idx] < 0.56f) continue;
            if (W_PRECIP[idx] < 0.05f) continue;
            if (W_CLOUD[idx] < 0.22f) continue;
            if (W_INST[idx] < 0.48f && W_CONV[idx] < 0.30f) continue;
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
                    replaced = true;
                    break;
                }
            }
            if (replaced) {
                ++n_replaced;
            } else {
                CycloneWakeEntry ne;
                ne.key       = key_gd;
                ne.cell_idx  = idx;
                ne.vec       = perturb;
                ne.vec_init  = perturb;
                ne.days_left = cyclone_wake_days;
                ne.init_days = cyclone_wake_days;
                _cyclone_perturbations.push_back(ne);
                ++n_injected;
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

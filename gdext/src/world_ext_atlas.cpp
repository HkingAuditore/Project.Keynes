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
#include "world_ext_internal_cell_luts.h"

namespace pk {

using namespace godot;


godot::Dictionary DCWorldExt::run_sea_ice_atlas_prepare(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["prepare_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_sea_ice_atlas_prepare: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!knobs.has("n_cells") || !knobs.has("width") || !knobs.has("height") ||
        !knobs.has("pixel_to_cell_index")) {
        return fail("missing required knob");
    }
    const int n_cells = int(knobs["n_cells"]);
    const int width = int(knobs["width"]);
    const int height = int(knobs["height"]);
    if (n_cells <= 0 || width <= 0 || height <= 0) return fail("invalid dimensions");

    PackedInt32Array pix_to_cell = knobs["pixel_to_cell_index"];
    const int n_pix = width * height;
    if (pix_to_cell.size() < n_pix) return fail("pixel_to_cell_index too small");
    PackedByteArray prev_cell_bytes = knobs.get("previous_cell_bytes", PackedByteArray());

    const int sid_ice = component_id(StringName("cell_sea_ice_frac"));
    if (sid_ice < 0) return fail("missing slot id cell_sea_ice_frac");
    Slot &s_ice = _slots.write[sid_ice];
    if (s_ice.arr_f32.size() < n_cells) return fail("sea_ice_frac slot too small");

    auto t0 = std::chrono::high_resolution_clock::now();
    PackedByteArray cell_bytes;
    cell_bytes.resize(n_cells);
    uint8_t * const __restrict CB = cell_bytes.ptrw();
    const float * const __restrict ICE = s_ice.arr_f32.ptr();
    const uint8_t * const PREV = prev_cell_bytes.size() >= n_cells ? prev_cell_bytes.ptr() : nullptr;
    int dirty_cells = 0;
    for (int i = 0; i < n_cells; ++i) {
        int q = int(std::round(pk_clamp01(double(ICE[i])) * 255.0));
        if (q < 0) q = 0;
        else if (q > 255) q = 255;
        CB[i] = uint8_t(q);
        if (PREV == nullptr || PREV[i] != CB[i]) ++dirty_cells;
    }

    PackedByteArray buffer;
    buffer.resize(n_pix);
    uint8_t * const __restrict BUF = buffer.ptrw();
    const int32_t * const __restrict P2C = pix_to_cell.ptr();
    for (int p = 0; p < n_pix; ++p) {
        const int ci = P2C[p];
        BUF[p] = (ci >= 0 && ci < n_cells) ? CB[ci] : 0;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["prepare_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["buffer"] = buffer;
    out["cell_bytes"] = cell_bytes;
    out["dirty_cells"] = dirty_cells;
    out["dirty_ratio"] = n_cells > 0 ? double(dirty_cells) / double(n_cells) : 0.0;
    out["pixels"] = n_pix;
    return out;
}

#include "world_ext_atlas_section_enum_axis_patches.inc"
#include "world_ext_atlas_section_dynamic_and_ecology_encoders.inc"
#include "world_ext_atlas_section_surface_and_overlay_encoders.inc"
// ────────────────────────────────────────────────────────────────────────────
// plan/atlas-pipeline-cpp（2026-05-20）：4 张运行期视觉 atlas 全管线 C++ 主入口
//
// 设计要点（复用最大化）：
//   1) 4 张 atlas 的 byte-fill / sig 计算继续走现有 encode_* 函数（已 bit-equal
//      验证通过，sig 算法 100% 与 GDScript 镜像）。
//   2) 本入口承担 GD 端原 atlas_upload_system / map_baker.gd 的 调度 + dirty 消费
//      + value-diff + 1-跳膨胀 + ecology decay 合并 + CSR 打包构造 knobs。
//   3) prev_sigs / ecology 持久状态完全由 AtlasPipelineState 持有，跨 stride 复用，
//      消除原 GDScript Dictionary[HexCell→int] 的 hash 开销。
//   4) 4 phase 状态机内置 C++：单次 run_atlas_pipeline_step 默认一气呵成跑完
//      4 phase（soft_budget_us 是软门槛，不强制切分；GD 调一次拿 4 张 buffer）。
//      若需要时间切片，opts["enable_phase_slicing"] = true 时退化到 phase-by-phase
//      模式（每次调用前进一个 phase，与 GD 旧 4-phase 状态机调用对齐）。
// ────────────────────────────────────────────────────────────────────────────

namespace {

// 获取或创建 AtlasPipelineState（lazy alloc 模式，与 WeatherSummaryState 同构）。
inline AtlasPipelineState *get_or_create_atlas_state(void *&p) {
    if (p == nullptr) {
        p = new AtlasPipelineState();
    }
    return static_cast<AtlasPipelineState *>(p);
}

// ice byte：与 GDScript _q01_byte_ice 完全一致（v>0 时 byte≥1）。
inline uint8_t pk_atlas_byte_ice(double v) {
    return uint8_t(pk_q01_byte_ice(v));
}

// 从 World 节点拉 SoA 字段：用 .get(StringName) 反射读 PackedXxxArray。
// 与 GDScript map_baker.gd::_pack_csr_for_cells 的 SoA fast path 等价。
struct WorldSoARefs {
    bool                ok = false;
    int                 n_cells = 0;
    PackedInt32Array    cell_first_px;
    PackedInt32Array    cell_px_count;
    PackedInt32Array    flat_px_indices;
    PackedByteArray     terrain_arr;        // 用于 LUT 查 passable_sea / is_water
    PackedByteArray     passable_sea_lut;   // 256 byte LUT (航行性语义)
    PackedByteArray     is_water_lut;       // 256 byte LUT (视觉水陆语义，含 SEA_ICE)
    bool                have_lut = false;
    Dictionary          water_cell_pixel_lists; // 仅 ice phase 用 (HexCell key 无法 SoA 化)
    bool                have_water_lists = false;
};

inline WorldSoARefs fetch_world_soa(Object *world, Object *map) {
    WorldSoARefs r;
    if (world == nullptr) return r;
    Variant v_first = world->get(StringName("cell_first_px_arr"));
    Variant v_count = world->get(StringName("cell_px_count_arr"));
    Variant v_flat  = world->get(StringName("flat_px_indices_arr"));
    if (v_first.get_type() != Variant::PACKED_INT32_ARRAY ||
        v_count.get_type() != Variant::PACKED_INT32_ARRAY ||
        v_flat.get_type()  != Variant::PACKED_INT32_ARRAY) {
        return r;
    }
    r.cell_first_px = v_first;
    r.cell_px_count = v_count;
    r.flat_px_indices = v_flat;
    r.n_cells = r.cell_first_px.size();
    if (r.n_cells <= 0) return r;
    if (map != nullptr) {
        Variant v_terr = map->get(StringName("terrain_arr"));
        if (v_terr.get_type() == Variant::PACKED_BYTE_ARRAY) {
            r.terrain_arr = v_terr;
        }
        // MapData.passable_sea_lut() 是 static method；走 .call("passable_sea_lut")
        Variant v_lut = map->call(StringName("passable_sea_lut"));
        if (v_lut.get_type() == Variant::PACKED_BYTE_ARRAY) {
            r.passable_sea_lut = v_lut;
        }
        // sea-ice-render-source-unify 阶段 D：渲染语义专用 LUT（含 SEA_ICE）
        // 取代 is_water_lut——后者是通行性语义，把 SEA_ICE 当陆，会让 atlas 走错分支。
        Variant v_iwlut = map->call(StringName("is_water_render_lut"));
        if (v_iwlut.get_type() == Variant::PACKED_BYTE_ARRAY) {
            r.is_water_lut = v_iwlut;
        }
        r.have_lut = (r.terrain_arr.size() == r.n_cells &&
                      r.passable_sea_lut.size() >= 256 &&
                      r.is_water_lut.size() >= 256);
    }
    Variant v_wpl = world->get(StringName("water_cell_pixel_lists"));
    if (v_wpl.get_type() == Variant::DICTIONARY) {
        r.water_cell_pixel_lists = v_wpl;
        r.have_water_lists = !r.water_cell_pixel_lists.is_empty();
    }
    r.ok = true;
    return r;
}

// ── stride 工作集打包：把 dirty cell.index 集合 + ecology decay + 1 跳邻居膨胀 ──
// 全部走 PackedByteArray 'seen' 标记，避免重复，最终输出"按升序的 cell.index 数组"。

// 4 个 atlas 的工作集（每 stride 重建）。
struct AtlasWorkSets {
    PackedInt32Array dyn_real;   // dirty ∩ (sig 与 prev_sigs_dyn 不同)
    PackedInt32Array eco_real;   // dirty ∪ active_decay（cache_invalid 时全集 → 由调用方处理）
    PackedInt32Array smo_real;   // (eco_real ∪ dirty) 1-跳邻居膨胀
    PackedInt32Array ice_real;   // dirty ∩ water_cells
};

} // anonymous namespace

// 公开入口：使 csr_cache + prev_sigs 失效（地图重生成时由 GD 调）。
void DCWorldExt::invalidate_atlas_csr_cache() {
    if (_atlas_state == nullptr) return;
    auto *st = static_cast<AtlasPipelineState *>(_atlas_state);
    st->csr_first_px = PackedInt32Array();
    st->csr_px_count = PackedInt32Array();
    st->csr_flat_px = PackedInt32Array();
    st->csr_valid = false;
    st->prev_sigs_dyn = PackedInt32Array();
    st->prev_sigs_eco = PackedInt32Array();
    st->prev_sigs_smo = PackedInt32Array();
    st->prev_sigs_ice = PackedInt32Array();
    st->eco_foliage = PackedFloat32Array();
    st->eco_stress = PackedFloat32Array();
    st->eco_transition_age = PackedFloat32Array();
    st->eco_growth_damage = PackedFloat32Array();
    st->eco_active_decay_indices = PackedInt32Array();
    // Cell-index 间接寻址 LUT 持久状态同步失效（地图重生成 → cell.index 重排）。
    st->lut_initialized = false;
    st->lut_prev_veg = PackedByteArray();
    st->lut_prev_vit = PackedByteArray();
    st->lut_transition_age = PackedByteArray();
    st->lut_enum_data = PackedByteArray();
    st->lut_dyn_data = PackedByteArray();
    st->lut_eco_data = PackedByteArray();
    st->lut_weather_data = PackedByteArray();
    st->lut_active_transition_indices = PackedInt32Array();
    st->phase = AtlasPipelineState::IDLE;
    st->cursor = 0;
}

// 公开入口：一次性把 GD 端 ecology 持久状态迁过来。
// state Dict 字段：
//   "veg_bytes"          : PackedByteArray  (per cell, 0..255 vegetation enum byte) [可选]
//   "vitality_bytes"     : PackedByteArray  (per cell, q01 byte)                    [可选]
//   "transition_age"     : PackedByteArray  (per cell, byte 0..255)                 [可选]
//   "active_decay"       : PackedInt32Array (active decay set 的 cell.index 列表)   [可选]
// 对应 AtlasPipelineState 字段：veg/vitality 用 prev_sigs_eco 已经隐含，本接口
// 主要保留 transition_age 和 active_decay（其余字段冷启首帧自动从 SoA cur 灌入）。
void DCWorldExt::migrate_eco_persistent_from_gd(godot::Dictionary state) {
    auto *st = get_or_create_atlas_state(_atlas_state);
    // transition_age 用 PackedFloat32Array 持有（保留 byte 精度但避免 byte→float 反复转换）
    if (state.has("transition_age")) {
        Variant v = state["transition_age"];
        if (v.get_type() == Variant::PACKED_BYTE_ARRAY) {
            PackedByteArray pba = v;
            st->eco_transition_age.resize(pba.size());
            float *p = st->eco_transition_age.ptrw();
            const uint8_t *src = pba.ptr();
            for (int i = 0; i < pba.size(); ++i) p[i] = float(src[i]);
        } else if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
            st->eco_transition_age = v;
        }
    }
    if (state.has("active_decay")) {
        Variant v = state["active_decay"];
        if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
            st->eco_active_decay_indices = v;
        }
    }
    // foliage / stress / growth_damage 通常无需迁移（首帧从 SoA 计算）；
    // 仍保留可选迁移路径以备 future bit-equal 校验。
    if (state.has("foliage")) {
        Variant v = state["foliage"];
        if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) st->eco_foliage = v;
    }
    if (state.has("stress")) {
        Variant v = state["stress"];
        if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) st->eco_stress = v;
    }
    if (state.has("growth_damage")) {
        Variant v = state["growth_damage"];
        if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) st->eco_growth_damage = v;
    }
}

// 主入口：4-phase atlas pipeline 一次推进。
// opts 字段详见 world_ext.h 注释。
godot::Dictionary DCWorldExt::run_atlas_pipeline_step(godot::Dictionary opts) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["done"] = false;
    out["phase"] = int(AtlasPipelineState::IDLE);
    out["cursor"] = 0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_atlas_pipeline_step: ", why,
                                       " - GD 端应回退旧路径");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!opts.has("world")) return fail("missing world");
    Object *world = Object::cast_to<Object>(opts["world"]);
    if (world == nullptr) return fail("world is null");
    Object *map = nullptr;
    if (opts.has("map")) {
        map = Object::cast_to<Object>(opts["map"]);
    }
    // map 可空：缺 LUT 走 fallback path。但 width/height 必须有。
    if (!opts.has("width") || !opts.has("height")) return fail("missing width/height");
    const int W = int(opts["width"]);
    const int H = int(opts["height"]);
    const int n_pix = W * H;
    if (n_pix <= 0) return fail("invalid texture size");

    auto *st = get_or_create_atlas_state(_atlas_state);

    // 拉取 SoA refs（CSR + LUT）。
    // n_cells 取自 world.cell_first_px_arr.size()（CSR 主索引），与
    // map.cell_count() 等价；不再依赖 _entity_count（那是 ECS 实体计数，
    // 仅在 assign_archetype/create_entities 路径累加，atlas pipeline 不走
    // 那条路 → 长期保持为 0 会让本接口永远 fallback 到 oneshot）。
    // —— 2026-05-21 plan/atlas-phase-slicing 诊断修复
    WorldSoARefs soa = fetch_world_soa(world, map);
    if (!soa.ok) return fail("world SoA not ready");
    const int n_cells = soa.n_cells;
    if (n_cells <= 0) return fail("world SoA n_cells = 0");

    // ── plan/atlas-phase-slicing：phase-by-phase 时间切片入口判断 ──
    // phase_budget = 本次 call 最多推进的 phase 数（默认 4 = 一气呵成；GD 可传 1
    // 实现每 tick 1 phase）。in_mid_stride = 上次 call yield 时的状态延续，需要
    // 复用 st 的 stride snapshot（dirty_indices / cache_valid_* / nb_arr / prep_*）。
    int phase_budget = 4;
    bool opts_has_phase_budget = opts.has("phase_budget");
    int opts_phase_budget_raw = -1;
    if (opts_has_phase_budget) {
        opts_phase_budget_raw = int(opts["phase_budget"]);
        phase_budget = opts_phase_budget_raw;
        if (phase_budget < 1) phase_budget = 1;
        if (phase_budget > 4) phase_budget = 4;
    }
    const bool in_mid_stride =
        st->stride_active &&
        st->phase >= AtlasPipelineState::DYNAMIC &&
        st->phase <= AtlasPipelineState::ICE &&
        st->stride_n_pix == n_pix &&
        st->stride_n_cells == n_cells;
    int phases_done_this_call = 0;

    // 取 dirty_indices：mid-stride 时复用 st 缓存（GD 不应重复传）；
    // 新 stride 入口时从 opts 消费（GD 已 read_and_clear，保留 atomicity）。
    // plan/sim-2ms-simd-dirty-budget 任务 7（2026-05-21）：force_full_encode kill-switch。
    // GD 端 use_gdext_dynamic_atlas_terminal_dirty=false 时设 opts.force_full_encode=true
    // → 此处覆盖 dirty_path_used=false 让 4 phase 全部走 all_cells（A/B 对照入口）。
    PackedInt32Array dirty_indices;
    bool dirty_path_used;
    bool dirty_noop;
    bool force_full_encode = opts.has("force_full_encode")
        ? bool(opts["force_full_encode"]) : false;
    if (in_mid_stride) {
        dirty_indices = st->stride_dirty_indices;
        dirty_path_used = st->stride_dirty_path_used;
        dirty_noop = st->stride_dirty_noop;
    } else {
        if (opts.has("dirty_indices")) {
            Variant v = opts["dirty_indices"];
            if (v.get_type() == Variant::PACKED_INT32_ARRAY) dirty_indices = v;
        }
        dirty_path_used = opts.has("dirty_indices");
        dirty_noop = dirty_indices.size() == 0;
        // 任务 7 kill-switch 覆盖：force_full_encode=true 时强制走全集编码。
        // 仅在 stride 起点生效（mid-stride 复用 snapshot 不允许中途切语义）。
        if (force_full_encode) {
            dirty_path_used = false;
            dirty_noop = false;
            dirty_indices = PackedInt32Array();
        }
    }

    // SoA 槽位
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    const int sid_ice = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terr = component_id(StringName("cell_terrain"));
    const int sid_veg = component_id(StringName("cell_vegetation"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 ||
        sid_ice < 0 || sid_terr < 0 || sid_veg < 0) {
        return fail("missing component slot");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_ice = _slots.write[sid_ice];
    Slot &s_terr = _slots.write[sid_terr];
    Slot &s_veg = _slots.write[sid_veg];
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_ice.arr_f32.size() < n_cells ||
        s_terr.arr_u8.size() < n_cells || s_veg.arr_u8.size() < n_cells) {
        return fail("slot array size < entity_count");
    }
    const float * const TEMP = s_temp.arr_f32.ptr();
    const float * const MOIST = s_moist.arr_f32.ptr();
    const float * const SNOW = s_snow.arr_f32.ptr();
    const float * const VIT = s_vit.arr_f32.ptr();
    const float * const ICE = s_ice.arr_f32.ptr();
    const uint8_t * const TERR = s_terr.arr_u8.ptr();
    const uint8_t * const VEG = s_veg.arr_u8.ptr();

    // ── prev_sigs 长度对齐：首帧或 n_cells 变化时 resize/reset ──
    auto ensure_int_arr = [n_cells](PackedInt32Array &a) {
        if (a.size() != n_cells) {
            a.resize(n_cells);
            int32_t *p = a.ptrw();
            for (int i = 0; i < n_cells; ++i) p[i] = -1;
        }
    };
    ensure_int_arr(st->prev_sigs_dyn);
    ensure_int_arr(st->prev_sigs_eco);
    ensure_int_arr(st->prev_sigs_smo);
    ensure_int_arr(st->prev_sigs_ice);
    if (st->eco_transition_age.size() != n_cells) {
        st->eco_transition_age.resize(n_cells);
        float *p = st->eco_transition_age.ptrw();
        for (int i = 0; i < n_cells; ++i) p[i] = 0.0f;
    }

    // ── atlas buffer 初始化 / 大小校验 ──
    // mid-stride 时复用 st 缓存的 cache_valid_*；新 stride 时计算并缓存。
    auto ensure_buf = [&](PackedByteArray &buf, int stride) -> bool {
        if (buf.size() != n_pix * stride) {
            buf.resize(n_pix * stride);
            uint8_t *p = buf.ptrw();
            for (int i = 0; i < n_pix * stride; ++i) p[i] = 0;
            return false;  // cache invalid (新分配)
        }
        return true;
    };
    bool cache_valid_dyn, cache_valid_eco, cache_valid_smo, cache_valid_ice;
    if (in_mid_stride) {
        // buffer 大小不能在 stride 中变化（已被 stride_n_pix 校验前置兜底）；
        // 但仍需 ensure_buf 校验防御 GD 端误改 buf；不变更 cache_valid_*。
        ensure_buf(st->buf_dyn, 4);
        ensure_buf(st->buf_eco, 4);
        ensure_buf(st->buf_smo, 4);
        ensure_buf(st->buf_ice, 1);
        cache_valid_dyn = st->stride_cache_valid_dyn;
        cache_valid_eco = st->stride_cache_valid_eco;
        cache_valid_smo = st->stride_cache_valid_smo;
        cache_valid_ice = st->stride_cache_valid_ice;
    } else {
        cache_valid_dyn = ensure_buf(st->buf_dyn, 4);
        cache_valid_eco = ensure_buf(st->buf_eco, 4);
        cache_valid_smo = ensure_buf(st->buf_smo, 4);
        cache_valid_ice = ensure_buf(st->buf_ice, 1);
    }

    // ── helper: passable_sea by cell.index ──
    // 数据源切换 2026-05-25：原读 soa.terrain_arr（已废弃，本项目运行期未填充）
    // → 改读 cpp 端权威的 cell_terrain SoA slot (TERR)；passable_sea_lut 来自
    // MapData.passable_sea_lut() 的 static method，不依赖 terrain_arr 状态。
    auto cell_psea = [&](int idx) -> bool {
        if (idx < 0 || idx >= n_cells) return false;
        if (soa.passable_sea_lut.size() >= 256) {
            return soa.passable_sea_lut[TERR[idx]] != 0;
        }
        return false;
    };
    // ── helper: is_water by cell.index ──
    // sea-ice-render-source-unify 阶段 C：dyn_atlas / dyn_smooth 用此判定
    // A 通道双语义。与 cell_psea 的差异：SEA_ICE 因冰面阻断航行 cell_psea=false，
    // 但视觉上仍是水域 → cell_is_water=true，A 通道写 ice_byte 让 shader 水路径
    // 正确渲染冰。1:1 镜像 GDScript map_baker.gd::_dynamic_cell_signature 的
    // is_water 判定（基于 cell.is_water == not passable_land 语义）。
    //
    // ── helper: 视觉水陆判定 ──────────────────────────────────────
    // 数据源（关键修复 2026-05-25）：
    //   - terrain：直读 cpp 端权威 cell_terrain SoA slot (TERR 指针)；
    //     不读 MapData.terrain_arr（运行期可能未填充）。
    //   - LUT：soa.is_water_lut 已切换为 MapData.is_water_render_lut()
    //     （阶段 D），SEA_ICE(20) 已直接编为 1，无需任何散点兜底。
    auto cell_is_water = [&](int idx) -> bool {
        if (idx < 0 || idx >= n_cells) return false;
        const uint8_t terrain = TERR[idx];
        if (soa.is_water_lut.size() >= 256) {
            return soa.is_water_lut[terrain] != 0;
        }
        if (soa.passable_sea_lut.size() >= 256) {
            return soa.passable_sea_lut[terrain] != 0;
        }
        return false;
    };
    // ── helper: ice atlas 专用"水域"判定 ──
    // 与 cell_psea 的差异：把 SEA_ICE (terrain=20) 也算作"海冰图层关心的水域"。
    // 原因：sea_ice pass 把寒冷水域 cell 翻转成 terrain=SEA_ICE 后，
    //   .tres 配置 passable_sea=false → cell_psea() 返回 false →
    //   ice_real_indices 把这些 cell 排除 → ICE atlas 不再为它们写像素 →
    //   视觉上看不到冰（即便 MapData.sea_ice_frac_arr=1.0、UI 显示 100%）。
    // 这里仅扩大 ice atlas 的渲染集，不影响单位寻路（仍读 cell.passable_sea）。
    constexpr uint8_t TERRAIN_SEA_ICE = 20;  // 与 9490 行硬编码一致
    auto cell_is_ice_renderable = [&](int idx) -> bool {
        if (idx < 0 || idx >= n_cells) return false;
        if (cell_psea(idx)) return true;
        // 数据源切换 2026-05-25：从 soa.terrain_arr 改为 TERR (cell_terrain SoA slot)。
        return TERR[idx] == TERRAIN_SEA_ICE;
    };

    // ── neighbor SoA: 从 map.neighbor_indices_packed() 取 ──
    // mid-stride 时复用 st 缓存。
    PackedInt32Array nb_arr;
    bool have_nb = false;
    if (in_mid_stride) {
        nb_arr = st->stride_nb_arr;
        have_nb = st->stride_have_nb;
    } else if (map != nullptr) {
        Variant v_nb = map->call(StringName("neighbor_indices_packed"));
        if (v_nb.get_type() == Variant::PACKED_INT32_ARRAY) {
            nb_arr = v_nb;
            have_nb = (nb_arr.size() >= n_cells * 6);
        }
    }

    // ── 新 stride 入口：把入口快照写进 st，供后续 mid-stride call 复用 ──
    if (!in_mid_stride) {
        st->stride_active = true;
        st->phase = AtlasPipelineState::DYNAMIC;
        st->cursor = 0;
        st->stride_dirty_indices = dirty_indices;
        st->stride_dirty_path_used = dirty_path_used;
        st->stride_dirty_noop = dirty_noop;
        st->stride_cache_valid_dyn = cache_valid_dyn;
        st->stride_cache_valid_eco = cache_valid_eco;
        st->stride_cache_valid_smo = cache_valid_smo;
        st->stride_cache_valid_ice = cache_valid_ice;
        st->prep_smo_ready = false;
        st->prep_smo_cursor = 0;
        st->prep_smo_real_indices = PackedInt32Array();
        st->stride_have_nb = have_nb;
        st->stride_nb_arr = nb_arr;
        st->stride_n_pix = n_pix;
        st->stride_n_cells = n_cells;
        st->stride_t_start = std::chrono::high_resolution_clock::now();
        st->stride_total_ms_accum = 0.0;
        // 重置 ms_breakdown（每段 stride 独立诊断）
        st->ms_dyn_prep = st->ms_dyn_step = st->ms_dyn_fin = 0.0;
        st->ms_eco_prep = st->ms_eco_step = st->ms_eco_fin = 0.0;
        st->ms_smo_prep = st->ms_smo_step = st->ms_smo_fin = 0.0;
        st->ms_ice_prep = st->ms_ice_step = st->ms_ice_fin = 0.0;
    }

    auto t_total_start = std::chrono::high_resolution_clock::now();

    // ── plan/atlas-phase-slicing：phase gate 用变量 ──
    // yielded=true 后所有 phase 的 if(gate) 失败，控制流直奔 finalize/mid-return；
    // *_real_count 跨 phase 块保留（finalize 输出 stride_real 用）。
    bool yielded = false;
    int dyn_real_count = 0;
    int eco_real_count = 0;
    int smo_real_count = 0;
    int ice_real_count = 0;
    auto t_p = std::chrono::high_resolution_clock::now();
    auto t_q = t_p;

#include "world_ext_atlas_section_dynamic_ecology_stride.inc"
#include "world_ext_atlas_section_smooth_ice_stride.inc"
    // ── 组装返回 Dict ──
    out["fallback"] = false;
    out["reason"] = String();
    out["done"] = stride_done;
    out["phase"] = int(st->phase);
    out["cursor"] = st->cursor;
    // total_ms：stride_done 时返回整段累加；mid-stride 时返回本 call 局部
    // （GD 端用 done==true 触发 GPU commit，并据此读 total_ms 做 dashboard）
    out["total_ms"] = stride_done ? st->stride_total_ms_accum : this_call_ms;
    out["phases_done_this_call"] = phases_done_this_call;
    out["mid_stride"] = !stride_done;
    // ── plan/atlas-phase-slicing 诊断（2026-05-21）──
    // 上一次 perf 录制看到 done=true 一次跑 4 phase，但字符串确实编进 DLL 了。
    // 把"opts 里到底有没有 phase_budget / 实际生效值"原样回吐，让 GD 端能直接
    // 在 CSV 里看到——若 CSV 显示 phase_budget_effective=4 就铁证 opts 没传过来。
    out["phase_budget_effective"] = phase_budget;
    out["opts_has_phase_budget"] = opts_has_phase_budget;
    // plan/sim-2ms-simd-dirty-budget 任务 7：dirty 编码 kill-switch 诊断透传。
    // GD 端 perf log 用 force_full_encode 字段确认 use_gdext_dynamic_atlas_terminal_dirty
    // flag 是否实际生效（A/B 比对时 csv 会同时记录 path 与 force_full_encode）。
    out["force_full_encode"] = force_full_encode;
    out["dirty_path_used"] = dirty_path_used;
    out["opts_phase_budget_raw"] = opts_phase_budget_raw;

    // atlas_buffers：只在 stride_done 时输出（mid-stride 时空 Dict，GD 不应 commit）
    Dictionary atlas_buffers;
    if (stride_done) {
        atlas_buffers["dyn"] = st->buf_dyn;
        atlas_buffers["eco"] = st->buf_eco;
        atlas_buffers["smo"] = st->buf_smo;
        atlas_buffers["ice"] = st->buf_ice;
    }
    out["atlas_buffers"] = atlas_buffers;

    Dictionary stride_real;
    stride_real["dyn"] = dyn_real_count;
    stride_real["eco"] = eco_real_count;
    stride_real["smo"] = smo_real_count;
    stride_real["ice"] = ice_real_count;
    out["stride_real"] = stride_real;

    if (bool(opts.get("enable_diag", false))) {
        Dictionary ms;
        ms["dynamic_prepare_ms"] = st->ms_dyn_prep;
        ms["dynamic_step_ms"] = st->ms_dyn_step;
        ms["dynamic_finalize_ms"] = st->ms_dyn_fin;
        ms["ecology_prepare_ms"] = st->ms_eco_prep;
        ms["ecology_step_ms"] = st->ms_eco_step;
        ms["ecology_finalize_ms"] = st->ms_eco_fin;
        ms["smooth_prepare_ms"] = st->ms_smo_prep;
        ms["smooth_step_ms"] = st->ms_smo_step;
        ms["smooth_finalize_ms"] = st->ms_smo_fin;
        ms["ice_prepare_ms"] = st->ms_ice_prep;
        ms["ice_step_ms"] = st->ms_ice_step;
        ms["ice_finalize_ms"] = st->ms_ice_fin;
        out["ms_breakdown"] = ms;
    }

    return out;
}

} // namespace pk

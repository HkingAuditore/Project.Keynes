#include "world_ext.h"
#include "world_ext_internal.h"
#include "world_ext_internal_cell_luts.h"

#include <godot_cpp/core/builtin_ptrcall.hpp>
#include <godot_cpp/godot.hpp>

#include <algorithm>
#include <cstdint>

namespace pk {
using namespace godot;
namespace {

// SAME_SOURCE: DCCellLutBaker._publish_bounce_lut_gd. These bytes are derived
// rendering data. The caller owns the cache and performs ImageTexture uploads.
Dictionary encode_bounce_lut(const Dictionary &opts) {
    Dictionary out;
    out["fallback"] = true;
    const int64_t width = int64_t(opts.get("lut_w", 0));
    const int64_t height = int64_t(opts.get("lut_h", 0));
    if (width <= 0 || height <= 0 || width > INT32_MAX / 4 / height) return out;
    // The script calls the engine Color.lerp implementation. godot-cpp's
    // inline equivalent may fuse multiply/add under different compiler flags,
    // moving a channel across a byte boundary. Use that same engine function.
    // Hash: godot-cpp/gdextension/extension_api.json, Color.methods.lerp.
    static const GDExtensionPtrBuiltInMethod color_lerp = []() {
        const StringName name("lerp");
        return gdextension_interface::variant_get_ptr_builtin_method(
            GDEXTENSION_VARIANT_TYPE_COLOR, name._native_ptr(), 402949615);
    }();
    if (color_lerp == nullptr) {
        out["reason"] = String("bounce_color_lerp_builtin_unavailable");
        return out;
    }
    const int slots = int(width * height);
    const int bytes = slots * 4;
    const PackedByteArray enums = opts.get("enum_lut", PackedByteArray());
    const PackedByteArray dynamics = opts.get("dyn_lut", PackedByteArray());
    if (enums.size() < bytes || dynamics.size() < bytes) return out;

    PackedByteArray bounce = opts.get("bounce_lut", PackedByteArray());
    const bool full = bool(opts.get("force_full_encode", true)) || bounce.size() != bytes;
    const PackedInt32Array dirty = opts.get("dirty_indices", PackedInt32Array());
    bool changed = full;
    if (full) {
        bounce = PackedByteArray();
        bounce.resize(bytes);
    }
    if (full || !dirty.is_empty()) {
        // Authoritative colors and water membership remain in MapBaker. Parse
        // them once, never duplicate the palette or consult simulation terrain.
        const Array palette = opts.get("bounce_palette", Array());
        const Color fallback = opts.get("bounce_fallback", Color());
        const Color dry = opts.get("bounce_dry", Color());
        const Color snow = opts.get("bounce_snow", Color());
        const Array water = opts.get("bounce_water_terrains", Array());
        Color colors[256];
        bool is_water[256] = {};
        for (int i = 0; i < 256; ++i) {
            colors[i] = i < palette.size() ? Color(palette[i]) : fallback;
            // Array.has retains the script's membership semantics.
            is_water[i] = water.has(i);
        }
        const uint8_t *en = enums.ptr();
        const uint8_t *dyn = dynamics.ptr();
        uint8_t *dst = bounce.ptrw();
        const int count = full ? slots : dirty.size();
        for (int wi = 0; wi < count; ++wi) {
            const int i = full ? wi : dirty[wi];
            if (i < 0 || i >= slots) continue;
            const int base = i * 4;
            const int terrain = en[base];
            Color color = colors[terrain];
            if (!is_water[terrain]) {
                // Builtin ptrcall uses double for a GDScript float argument;
                // the engine performs the original conversion to lerp's float.
                const double vitality = double(dyn[base + 3]) / 255.0;
                const double dry_weight = (1.0 - vitality) * 0.25;
                color = internal::_call_builtin_method_ptr_ret<Color>(
                    color_lerp, &color, &dry, &dry_weight);
                const double snow_cover = double(dyn[base + 2]) / 255.0;
                color = internal::_call_builtin_method_ptr_ret<Color>(
                    color_lerp, &color, &snow, &snow_cover);
            }
            // Read each float channel as GDScript float (double), clamp, scale,
            // then truncate; multiplying in float would change boundary bytes.
            auto channel = [](float value) -> uint8_t {
                return uint8_t(std::clamp(double(value), 0.0, 1.0) * 255.0);
            };
            const uint8_t r = channel(color.r);
            const uint8_t g = channel(color.g);
            const uint8_t b = channel(color.b);
            const uint8_t alpha = is_water[terrain] ? 0 : 255;
            if (dst[base] != r || dst[base + 1] != g || dst[base + 2] != b || dst[base + 3] != alpha) {
                changed = true;
                dst[base] = r;
                dst[base + 1] = g;
                dst[base + 2] = b;
                dst[base + 3] = alpha;
            }
        }
    }
    out["fallback"] = false;
    out["bounce_lut"] = bounce;
    out["bounce_lut_changed"] = changed;
    return out;
}

// 与 GDScript map_baker.gd::_ecology_visual_signature / 本文件
// encode_ecology_visual_atlas（14399-14440 行）1:1 镜像。提炼成可复用 helper，
// 供 cell-index 间接寻址 LUT 路径（encode_cell_luts）与现有 fan-out 路径共用同一公式，
// 保证 eco_lut 与 ecology_visual_atlas bit-equivalent。
//   r=q01(foliage), g=q01(stress), b=transition_age(byte), a=q01(growth_damage)
inline uint32_t pk_atlas_sig_ecology(double temp, double moist, double snow,
                                     double vit, int veg_id, bool is_water,
                                     int transition_age, int prev_vit_byte,
                                     int veg_none) {
    auto smoothstep = [](double e0, double e1, double x) {
        if (e1 <= e0) return x < e0 ? 0.0 : 1.0;
        double t = (x - e0) / (e1 - e0);
        if (t < 0.0) t = 0.0;
        else if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    };
    auto clamp01 = [](double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); };
    const double vitality = clamp01(vit);
    const double m = clamp01(moist);
    const double t = clamp01(temp);
    const double sn = clamp01(snow);
    double foliage = 0.0;
    if (!is_water && veg_id != veg_none) {
        const double cold_loss = (1.0 - smoothstep(0.02, 0.18, t)) * 0.55;
        const double snow_loss = smoothstep(0.12, 0.75, sn) * 0.70;
        const double dry_loss = (1.0 - smoothstep(0.05, 0.35, m)) * 0.45;
        foliage = clamp01(vitality * 0.72 + m * 0.28 - cold_loss - snow_loss - dry_loss);
    }
    double stress = 0.0;
    if (!is_water) {
        const double dryness = 1.0 - m;
        const double heat_stress = smoothstep(0.72, 0.95, t);
        const double cold_stress = 1.0 - smoothstep(0.03, 0.20, t);
        const double vit_stress = 1.0 - vitality;
        const double a1 = dryness * 0.70;
        const double a2 = (heat_stress > cold_stress ? heat_stress : cold_stress) * 0.65;
        const double a3 = (a1 > a2 ? a1 : a2);
        stress = clamp01(a3 + vit_stress * 0.45);
    }
    const double vit_delta = (double(pk_q01_byte(vitality)) - double(prev_vit_byte)) / 255.0;
    const double growth = clamp01(0.5 + vit_delta * 5.0 + (foliage - 0.5) * 0.12 - stress * 0.10);
    const int r = pk_q01_byte(foliage);
    const int g = pk_q01_byte(stress);
    int b = transition_age;
    if (b < 0) b = 0;
    else if (b > 255) b = 255;
    const int a = pk_q01_byte(growth);
    return uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16) | (uint32_t(a) << 24);
}

} // namespace

// ────────────────────────────────────────────────────────────────────────────
// Cell-index 间接寻址（province-ID indirection）：per-cell LUT 编码
// ────────────────────────────────────────────────────────────────────────────
// SAME_SOURCE: map_baker.gd::bake_cell_luts / _bake_cell_luts_gd（GDScript fallback）。
// 本方法把"每 cell 一个 texel"的 enum/dyn/eco LUT 编码搬进 C++ 热路径——即便
// n_cells≈2400，也走 scalar C++ tight loop（用户决策 2026-06-16：严格按 skill 在
// CPP 做），与 fan-out 路径共用 pk_atlas_sig_dynamic / pk_atlas_sig_ecology 公式，
// 保证 LUT 与全分辨率 atlas bit-equivalent。
//
// 输出 3 张 LUT（行优先，宽 lut_w；texel ci 落在 (ci%lut_w, ci/lut_w)，
// 即扁平偏移恰为 ci）：
//   enum_lut : RGBA8 R=terrain G=vegetation B=cover A=迷雾知识度 k（0..255）
//   dyn_lut  : RGBA8 R=q01(temp) G=q01(moist) B=q01(snow) A=水:q01_ice(sif)/陆:q01(vit)
//   eco_lut  : RGBA8 R=q01(foliage) G=q01(stress) B=transition_age A=q01(growth)
//
// opts 字段：
//   "map"             : Object（取 is_water_render_lut；缺则 fallback）
//   "lut_w"/"lut_h"   : int（LUT 网格尺寸，lut_w*lut_h >= n_cells）
//   "n_cells"         : int（map.cell_count()）
//   "terrain_lake"/"terrain_sea_ice"/"veg_none" : int（eco is_water / VEG_NONE 透传）
//   "cache_valid"     : bool（true=日常 refresh，按 prev 推进 transition；
//                             false=初次 bake，transition 归零）
// 返回：{ enum_lut, dyn_lut, eco_lut, lut_w, lut_h, n_cells, elapsed_ms,
//         fallback, reason, path, published_to_slot=false }
godot::Dictionary DCWorldExt::encode_cell_luts(godot::Dictionary opts) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["elapsed_ms"] = -1.0;
    out["path"] = String("gdscript");
    out["published_to_slot"] = false;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] encode_cell_luts: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    // Pure byte encoding shares this API but needs no simulation slots.
    if (bool(opts.get("bounce_only", false))) return encode_bounce_lut(opts);

    if (!_bound) return fail("not bound");
    if (!opts.has("lut_w") || !opts.has("lut_h")) return fail("missing lut dims");
    const int lut_w = int(opts["lut_w"]);
    const int lut_h = int(opts["lut_h"]);
    if (lut_w <= 0 || lut_h <= 0) return fail("invalid lut dims");
    const int n_cells = opts.has("n_cells") ? int(opts["n_cells"]) : 0;
    if (n_cells <= 0) return fail("missing n_cells");
    const int slots_total = lut_w * lut_h;
    if (slots_total < n_cells) return fail("lut grid smaller than n_cells");

    Object *map = opts.has("map") ? Object::cast_to<Object>(opts["map"]) : nullptr;

    // SoA 槽位（与 run_atlas_pipeline_step / encode_ecology_visual_atlas 同源）。
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    const int sid_ice = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terr = component_id(StringName("cell_terrain"));
    const int sid_veg = component_id(StringName("cell_vegetation"));
    const int sid_cover = component_id(StringName("cell_cover"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 ||
        sid_ice < 0 || sid_terr < 0 || sid_veg < 0 || sid_cover < 0) {
        return fail("missing component slot");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_ice = _slots.write[sid_ice];
    Slot &s_terr = _slots.write[sid_terr];
    Slot &s_veg = _slots.write[sid_veg];
    Slot &s_cover = _slots.write[sid_cover];
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_ice.arr_f32.size() < n_cells || s_terr.arr_u8.size() < n_cells ||
        s_veg.arr_u8.size() < n_cells || s_cover.arr_u8.size() < n_cells) {
        return fail("slot array size < n_cells");
    }
    const float * const __restrict TEMP = s_temp.arr_f32.ptr();
    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict SNOW = s_snow.arr_f32.ptr();
    const float * const __restrict VIT = s_vit.arr_f32.ptr();
    const float * const __restrict ICE = s_ice.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const uint8_t * const __restrict VEG = s_veg.arr_u8.ptr();
    const uint8_t * const __restrict COVER = s_cover.arr_u8.ptr();

    // Visual snow is a render-facing field that weather/climate already flushes to
    // MapData. Use an explicit snapshot when provided instead of globally refreshing
    // every slot and risking overwriting native-only climate values with stale mirrors.
    PackedFloat32Array snow_override = opts.get("snow_cover_arr", PackedFloat32Array());
    const bool snow_override_valid = snow_override.size() >= n_cells;
    const float * const __restrict SNOW_VIS =
        snow_override_valid ? snow_override.ptr() : SNOW;

    // 迷雾知识度 k（VisionSolver 产出的 blur 后 per-cell 字节）走 enum_lut 的 A
    // 通道。之所以显式传数组而不是读 slot：vision 的权威实现目前在 GDScript，
    // 而 refresh_slots_from_map() 会把所有 slot 都从 MapData 拉一遍，可能用陈旧
    // 镜像覆盖 native-only 的气候值 —— 与上面 snow_cover_arr 同一个理由。
    // 未提供时 A 通道保持 255（全知），保证迷雾系统未接线时视觉不变。
    PackedByteArray fog_k = opts.get("fog_k_arr", PackedByteArray());
    const bool fog_k_valid = fog_k.size() >= n_cells;
    const uint8_t * const __restrict FOGK = fog_k_valid ? fog_k.ptr() : nullptr;
    int snow_slot_diff_count = 0;
    double snow_slot_diff_sum = 0.0;
    double snow_slot_diff_max = 0.0;

    // weather LUT 槽位（软依赖）：天气未初始化 / weather_field 未启用时这些 slot 可能
    // size < n_cells；此时 weather_lut 整段保持 0（云不显示），但 enum/dyn/eco 仍正常，
    // 不让整张 LUT 回退 GDScript。
    const int sid_w_type = component_id(StringName("cell_weather_type"));
    const int sid_w_int = component_id(StringName("cell_weather_intensity"));
    const int sid_w_cloud = component_id(StringName("cell_weather_cloud"));
    const int sid_w_vapor = component_id(StringName("cell_weather_vapor"));
    const uint8_t * __restrict WTYPE = nullptr;
    const float * __restrict WINT = nullptr;
    const float * __restrict WCLOUD = nullptr;
    const float * __restrict WVAPOR = nullptr;
    if (sid_w_type >= 0 && sid_w_int >= 0 && sid_w_cloud >= 0 && sid_w_vapor >= 0) {
        Slot &s_wt = _slots.write[sid_w_type];
        Slot &s_wi = _slots.write[sid_w_int];
        Slot &s_wc = _slots.write[sid_w_cloud];
        Slot &s_wv = _slots.write[sid_w_vapor];
        if (s_wt.arr_u8.size() >= n_cells && s_wi.arr_f32.size() >= n_cells &&
            s_wc.arr_f32.size() >= n_cells && s_wv.arr_f32.size() >= n_cells) {
            WTYPE = s_wt.arr_u8.ptr();
            WINT = s_wi.arr_f32.ptr();
            WCLOUD = s_wc.arr_f32.ptr();
            WVAPOR = s_wv.arr_f32.ptr();
        }
    }

    // is_water 渲染语义 LUT（含 SEA_ICE/LAKE）：dyn A 通道双语义 + eco is_water 判定。
    // 缺失则 fallback——C++ 路径不允许 water cell 误走陆路径。
    PackedByteArray is_water_lut;
    if (map != nullptr) {
        Variant v = map->call(StringName("is_water_render_lut"));
        if (v.get_type() == Variant::PACKED_BYTE_ARRAY) is_water_lut = v;
    }
    if (is_water_lut.size() < 256) return fail("missing is_water render lut");
    const uint8_t * const __restrict IWLUT = is_water_lut.ptr();

    const int terrain_lake = int(opts.get("terrain_lake", -1));
    const int terrain_sea_ice = int(opts.get("terrain_sea_ice", -1));
    const int veg_none = int(opts.get("veg_none", -1));
    const bool cache_valid_opt = bool(opts.get("cache_valid", false));
    const bool force_full_encode = bool(opts.get("force_full_encode", true));
    const bool include_weather_lut = bool(opts.get("include_weather_lut", true));
    const PackedInt32Array requested_dirty =
        opts.get("dirty_indices", PackedInt32Array());

    // 持久 prev 状态与 full byte buffers。日常只 patch dirty ∪ active-transition；
    // 冷启、尺寸变化或显式 force 时走全集。
    if (_atlas_state == nullptr) _atlas_state = new AtlasPipelineState();
    auto *st = static_cast<AtlasPipelineState *>(_atlas_state);
    const bool lut_state_ok = st->lut_initialized &&
        st->lut_prev_veg.size() == n_cells &&
        st->lut_prev_vit.size() == n_cells &&
        st->lut_transition_age.size() == n_cells;
    const int total_bytes = slots_total * 4;
    const bool lut_buffers_ok =
        st->lut_enum_data.size() == total_bytes &&
        st->lut_dyn_data.size() == total_bytes &&
        st->lut_eco_data.size() == total_bytes &&
        st->lut_weather_data.size() == total_bytes;
    if (!lut_state_ok) {
        st->lut_prev_veg.resize(n_cells);
        st->lut_prev_vit.resize(n_cells);
        st->lut_transition_age.resize(n_cells);
    }
    if (!lut_buffers_ok) {
        st->lut_enum_data.resize(total_bytes);
        st->lut_dyn_data.resize(total_bytes);
        st->lut_eco_data.resize(total_bytes);
        st->lut_weather_data.resize(total_bytes);
    }
    uint8_t * const __restrict PV_VEG = st->lut_prev_veg.ptrw();
    uint8_t * const __restrict PV_VIT = st->lut_prev_vit.ptrw();
    uint8_t * const __restrict TR = st->lut_transition_age.ptrw();
    const bool eff_cache_valid = cache_valid_opt && lut_state_ok;

    uint8_t * const __restrict ENUM = st->lut_enum_data.ptrw();
    uint8_t * const __restrict DYN = st->lut_dyn_data.ptrw();
    uint8_t * const __restrict ECO = st->lut_eco_data.ptrw();
    uint8_t * const __restrict WX = st->lut_weather_data.ptrw();

    const bool full_encode = force_full_encode || !lut_state_ok || !lut_buffers_ok;
    PackedByteArray seen;
    PackedInt32Array work_indices;
    auto append_work = [&](int ci) {
        if (ci < 0 || ci >= n_cells || seen[ci] != 0) return;
        seen.set(ci, uint8_t(1));
        work_indices.append(ci);
    };
    if (!full_encode) {
        seen.resize(n_cells);
        for (int i = 0; i < requested_dirty.size(); ++i) {
            append_work(requested_dirty[i]);
        }
        for (int i = 0; i < st->lut_active_transition_indices.size(); ++i) {
            append_work(st->lut_active_transition_indices[i]);
        }
    }

    auto t0 = std::chrono::high_resolution_clock::now();
    int enum_changed_cells = 0;
    int dyn_changed_cells = 0;
    int eco_changed_cells = 0;
    int weather_changed_cells = 0;
    const int processed_cells = full_encode ? n_cells : work_indices.size();
    for (int wi = 0; wi < processed_cells; ++wi) {
        const int ci = full_encode ? wi : work_indices[wi];
        const uint8_t terrain = TERR[ci];
        const bool is_water = IWLUT[terrain] != 0;

        // enum LUT：R=terrain G=vegetation B=cover A=迷雾知识度 k
        const int e4 = ci * 4;
        const uint8_t enum_0 = terrain;
        const uint8_t enum_1 = VEG[ci];
        const uint8_t enum_2 = COVER[ci];
        const uint8_t enum_3 = FOGK != nullptr ? FOGK[ci] : uint8_t(255);
        if (ENUM[e4] != enum_0 || ENUM[e4 + 1] != enum_1 ||
                ENUM[e4 + 2] != enum_2 || ENUM[e4 + 3] != enum_3) {
            ++enum_changed_cells;
        }
        ENUM[e4] = enum_0;
        ENUM[e4 + 1] = enum_1;
        ENUM[e4 + 2] = enum_2;
        ENUM[e4 + 3] = enum_3;

        // dyn LUT
        const float snow_vis = SNOW_VIS[ci];
        if (snow_override_valid) {
            const double d_snow = std::fabs(double(snow_vis) - double(SNOW[ci]));
            snow_slot_diff_sum += d_snow;
            if (d_snow > snow_slot_diff_max) snow_slot_diff_max = d_snow;
            if (d_snow > 0.0001) ++snow_slot_diff_count;
        }

        const uint32_t dsig = pk_atlas_sig_dynamic(
            double(TEMP[ci]), double(MOIST[ci]), double(snow_vis),
            double(VIT[ci]), double(ICE[ci]), is_water);
        const int d4 = ci * 4;
        const uint8_t dyn_0 = uint8_t(dsig & 0xFFu);
        const uint8_t dyn_1 = uint8_t((dsig >> 8) & 0xFFu);
        const uint8_t dyn_2 = uint8_t((dsig >> 16) & 0xFFu);
        const uint8_t dyn_3 = uint8_t((dsig >> 24) & 0xFFu);
        if (DYN[d4] != dyn_0 || DYN[d4 + 1] != dyn_1 ||
                DYN[d4 + 2] != dyn_2 || DYN[d4 + 3] != dyn_3) {
            ++dyn_changed_cells;
        }
        DYN[d4] = dyn_0;
        DYN[d4 + 1] = dyn_1;
        DYN[d4 + 2] = dyn_2;
        DYN[d4 + 3] = dyn_3;

        // eco LUT：transition_age tracking（镜像 encode_ecology_visual_atlas）
        const int cur_veg = int(VEG[ci]) & 0xFF;
        const int cur_vit_byte = pk_q01_byte(double(VIT[ci]));
        int transition_age;
        int prev_vit_byte;
        if (eff_cache_valid) {
            const int prev_veg = int(PV_VEG[ci]);
            prev_vit_byte = int(PV_VIT[ci]);
            transition_age = int(TR[ci]);
            if (cur_veg != prev_veg) transition_age = 255;
            else if (transition_age > 0) {
                transition_age -= 18;
                if (transition_age < 0) transition_age = 0;
            }
        } else {
            transition_age = 0;
            prev_vit_byte = cur_vit_byte;
        }
        const bool eco_is_water = is_water ||
            (int(terrain) == terrain_lake) || (int(terrain) == terrain_sea_ice);
        const uint32_t esig = pk_atlas_sig_ecology(
            double(TEMP[ci]), double(MOIST[ci]), double(snow_vis), double(VIT[ci]),
            cur_veg, eco_is_water, transition_age, prev_vit_byte, veg_none);
        const int c4 = ci * 4;
        const uint8_t eco_0 = uint8_t(esig & 0xFFu);
        const uint8_t eco_1 = uint8_t((esig >> 8) & 0xFFu);
        const uint8_t eco_2 = uint8_t((esig >> 16) & 0xFFu);
        const uint8_t eco_3 = uint8_t((esig >> 24) & 0xFFu);
        if (ECO[c4] != eco_0 || ECO[c4 + 1] != eco_1 ||
                ECO[c4 + 2] != eco_2 || ECO[c4 + 3] != eco_3) {
            ++eco_changed_cells;
        }
        ECO[c4] = eco_0;
        ECO[c4 + 1] = eco_1;
        ECO[c4 + 2] = eco_2;
        ECO[c4 + 3] = eco_3;

        // weather LUT：R=type(枚举), G=intensity, B=cloud, A=vapor（[0,1]→byte）。
        // WTYPE==nullptr（weather 未就绪）时保持初始化的 0。
        if (include_weather_lut && WTYPE != nullptr) {
            const int w4 = ci * 4;
            const uint8_t weather_0 = WTYPE[ci];
            const uint8_t weather_1 = uint8_t(pk_q01_byte(double(WINT[ci])));
            const uint8_t weather_2 = uint8_t(pk_q01_byte(double(WCLOUD[ci])));
            const uint8_t weather_3 = uint8_t(pk_q01_byte(double(WVAPOR[ci])));
            if (WX[w4] != weather_0 || WX[w4 + 1] != weather_1 ||
                    WX[w4 + 2] != weather_2 || WX[w4 + 3] != weather_3) {
                ++weather_changed_cells;
            }
            WX[w4] = weather_0;
            WX[w4 + 1] = weather_1;
            WX[w4 + 2] = weather_2;
            WX[w4 + 3] = weather_3;
        }

        // 写回 prev 状态
        PV_VEG[ci] = uint8_t(cur_veg);
        PV_VIT[ci] = uint8_t(cur_vit_byte);
        int tr_store = transition_age;
        if (tr_store < 0) tr_store = 0;
        else if (tr_store > 255) tr_store = 255;
        TR[ci] = uint8_t(tr_store);
    }
    st->lut_initialized = true;
    PackedInt32Array active_transitions;
    for (int ci = 0; ci < n_cells; ++ci) {
        if (TR[ci] > 0) active_transitions.append(ci);
    }
    st->lut_active_transition_indices = active_transitions;
    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["enum_lut"] = st->lut_enum_data;
    out["dyn_lut"] = st->lut_dyn_data;
    out["eco_lut"] = st->lut_eco_data;
    if (include_weather_lut) out["weather_lut"] = st->lut_weather_data;
    out["lut_w"] = lut_w;
    out["lut_h"] = lut_h;
    out["n_cells"] = n_cells;
    out["elapsed_ms"] = ms;
    out["full_encode"] = full_encode;
    out["requested_dirty_cells"] = requested_dirty.size();
    out["processed_cells"] = processed_cells;
    out["enum_changed_cells"] = enum_changed_cells;
    out["dynamic_changed_cells"] = dyn_changed_cells;
    out["ecology_changed_cells"] = eco_changed_cells;
    out["weather_changed_cells"] = weather_changed_cells;
    out["active_transition_count"] = active_transitions.size();
    out["snow_override_used"] = snow_override_valid;
    out["snow_source"] = String(snow_override_valid ? "map_snow_cover_arr" : "slot");
    out["snow_slot_diff_count"] = snow_slot_diff_count;
    out["snow_slot_diff_mean"] = snow_override_valid && processed_cells > 0
        ? (snow_slot_diff_sum / double(processed_cells)) : 0.0;
    out["snow_slot_diff_max"] = snow_slot_diff_max;
    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["published_to_slot"] = false;  // LUT 是渲染产物（ImageTexture），不进 slot
    return out;
}

} // namespace pk

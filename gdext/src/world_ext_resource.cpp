// world_ext_resource.cpp — Natural resources daily pass (economy.resources).
//
// run_natural_resource_pass: per-cell, per-resource 生成/衰减演化。固定公式模板 +
// 每资源系数（由 GDScript ResourceProfileRegistry.build_pass_knobs 组装），结合
// cell_temp / cell_moisture 计算每 tick reserve 变化，写回各资源 reserve slot 并
// flush 到 MapData。可再生 / 不可再生 仅由系数区分（见 resource_profile.gd 模板）。
//
// 与 run_runtime_hydrology_pass 同契约：Dictionary 返回，published_to_slot 标识是否
// 成功发布；失败返回 fallback_reason，GDScript 走同模板 fallback。

#include "world_ext.h"
#include "world_ext_internal.h"  // dc_clampf + Slot + 通用 includes（namespace pk 内）

#include <godot_cpp/variant/utility_functions.hpp>

#include <chrono>

namespace pk {

using namespace godot;

Dictionary DCWorldExt::run_natural_resource_pass(const Dictionary &knobs) {
    using godot::PackedFloat32Array;
    using godot::PackedStringArray;
    using godot::StringName;

    Dictionary out;
    const auto t0 = std::chrono::high_resolution_clock::now();
    auto fail = [&](const char *why) -> Dictionary {
        const auto t1 = std::chrono::high_resolution_clock::now();
        out["done"] = true;
        out["path"] = "gdext";
        out["fallback_reason"] = why;
        out["published_to_slot"] = false;
        out["published_slots"] = PackedStringArray();
        out["resource_count"] = 0;
        out["n_cells"] = 0;
        out["total_delta"] = 0.0;
        out["native_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["compute_ms"] = 0.0;
        return out;
    };

    if (!_bound) return fail("world_ext_not_bound");

    // ─── Climate input slots（热循环外解析）─────────────────────────────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_water = component_id(StringName("cell_is_water"));  // 可缺失（-1）
    if (sid_temp < 0 || sid_moist < 0) return fail("missing_climate_slot");

    const int n_cells = knobs.has("n_cells") ? int(knobs["n_cells"]) : int(_entity_archetype.size());
    if (n_cells <= 0) return fail("empty_world");

    const int resource_count = knobs.has("resource_count") ? int(knobs["resource_count"]) : 0;
    if (resource_count <= 0) return fail("no_resources");

    if (!knobs.has("reserve_slots") || !knobs.has("capacity") || !knobs.has("land_only") ||
        !knobs.has("temp_lo") || !knobs.has("temp_hi") ||
        !knobs.has("gen_base") || !knobs.has("gen_temp") || !knobs.has("gen_moisture") || !knobs.has("gen_self") ||
        !knobs.has("decay_base") || !knobs.has("decay_temp") || !knobs.has("decay_moisture") || !knobs.has("decay_self")) {
        return fail("knobs_missing_keys");
    }

    PackedStringArray reserve_slots = knobs["reserve_slots"];
    PackedFloat32Array capacity = knobs["capacity"];
    PackedFloat32Array land_only = knobs["land_only"];
    PackedFloat32Array temp_lo = knobs["temp_lo"];
    PackedFloat32Array temp_hi = knobs["temp_hi"];
    PackedFloat32Array gen_base = knobs["gen_base"];
    PackedFloat32Array gen_temp = knobs["gen_temp"];
    PackedFloat32Array gen_moisture = knobs["gen_moisture"];
    PackedFloat32Array gen_self = knobs["gen_self"];
    PackedFloat32Array decay_base = knobs["decay_base"];
    PackedFloat32Array decay_temp = knobs["decay_temp"];
    PackedFloat32Array decay_moisture = knobs["decay_moisture"];
    PackedFloat32Array decay_self = knobs["decay_self"];

    if (reserve_slots.size() < resource_count || capacity.size() < resource_count ||
        land_only.size() < resource_count || temp_lo.size() < resource_count || temp_hi.size() < resource_count ||
        gen_base.size() < resource_count || gen_temp.size() < resource_count ||
        gen_moisture.size() < resource_count || gen_self.size() < resource_count ||
        decay_base.size() < resource_count || decay_temp.size() < resource_count ||
        decay_moisture.size() < resource_count || decay_self.size() < resource_count) {
        return fail("knob_array_size_mismatch");
    }

    auto slot_ok_f32 = [&](int sid) -> bool { return int(_slots.write[sid].arr_f32.size()) >= n_cells; };
    if (!slot_ok_f32(sid_temp) || !slot_ok_f32(sid_moist)) return fail("climate_slot_size_mismatch");

    const float * const __restrict T = _slots.write[sid_temp].arr_f32.ptr();
    const float * const __restrict M = _slots.write[sid_moist].arr_f32.ptr();
    const bool have_water = (sid_water >= 0 && int(_slots.write[sid_water].arr_u8.size()) >= n_cells);
    const uint8_t * const __restrict WATER = have_water ? _slots.write[sid_water].arr_u8.ptr() : nullptr;

    const auto t_setup = std::chrono::high_resolution_clock::now();

    PackedStringArray published_slots;
    int published_count = 0;
    double total_delta = 0.0;

    for (int r = 0; r < resource_count; ++r) {
        const int sid = component_id(StringName(reserve_slots[r]));
        if (sid < 0 || !slot_ok_f32(sid)) {
            // schema 缺失或尺寸不符：跳过该资源，但不整体失败（其余资源仍可发布）。
            continue;
        }

        float * const __restrict R = _slots.write[sid].arr_f32.ptrw();

        const float cap = capacity[r];
        const float lo = temp_lo[r];
        const float hi = temp_hi[r];
        const float inv_span = (hi > lo) ? (1.0f / (hi - lo)) : 0.0f;
        const bool land_gate = land_only[r] >= 0.5f && have_water;
        const float gb = gen_base[r], gt = gen_temp[r], gm = gen_moisture[r], gs = gen_self[r];
        const float db = decay_base[r], dt = decay_temp[r], dm = decay_moisture[r], ds = decay_self[r];

        for (int i = 0; i < n_cells; ++i) {
            if (land_gate && WATER[i] != 0) continue;  // 仅陆地：水面格保持原值（初值 0）

            const float tn = dc_clampf((T[i] - lo) * inv_span, 0.0f, 1.0f);
            const float m = M[i];
            const float reserve = R[i];

            // 半隐式（IMEX）更新：把生成/衰减拆成常数生产项 P 与线性损失率 L（损失项
            // 隐式）⇒ reserve' = (reserve + P) / (1 + L)。L≥0 ⇒ 分母≥1，无条件稳定、
            // 单调趋近均衡，不会过冲/横跳；均衡点与旧显式一致（reserve* = cap·P/(gs+ds)）。
            const float gen_climate = gb + gt * tn + gm * m;
            const float decay_climate = db + dt * tn + dm * m;
            const float P = gen_climate + gs - decay_climate;
            float L = (cap > 0.0f) ? ((gs + ds) / cap) : 0.0f;
            if (L < 0.0f) L = 0.0f;  // 负自系数（误配）兜底，保持无条件稳定

            float v = (reserve + P) / (1.0f + L);
            if (cap > 0.0f && v > cap) v = cap;
            if (v < 0.0f) v = 0.0f;
            R[i] = v;
            total_delta += double(v - reserve);
        }

        _flush_slot_to_map(sid);
        published_slots.append(reserve_slots[r]);
        ++published_count;
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    out["done"] = true;
    out["path"] = "gdext";
    out["published_to_slot"] = published_count > 0;
    out["published_slots"] = published_slots;
    out["resource_count"] = published_count;
    out["n_cells"] = n_cells;
    out["total_delta"] = total_delta;
    out["native_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["compute_ms"] = std::chrono::duration<double, std::milli>(t1 - t_setup).count();
    if (published_count == 0) out["fallback_reason"] = "no_publishable_resource";
    return out;
}

} // namespace pk

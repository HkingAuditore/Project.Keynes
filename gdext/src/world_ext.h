#pragma once

// DCWorldExt — C++ mirror of `scripts/data_core/world.gd` (DCWorld).
//
// I3.A scope (this file): "zero-acceleration wrapper".
// Goal: instantiate via ClassDB("DCWorldExt"), bind to MapData, expose
// `view_f32 / view_i32 / view_u8`, support pools + archetypes — i.e. fulfil
// the same interface that GDScript-side hot loops already call. *No* hot loop
// is reimplemented in C++ yet; the run_xxx entry points belong to I3.B/C.
//
// The point of I3.A is to prove the bridging path:
//   1. world_factory.gd can ClassDB.instantiate("DCWorldExt") under
//      use_gdext_world=true.
//   2. bind_map_data shares the same PackedFloat32Array buffers as MapData
//      (zero-copy COW alias).
//   3. The existing GDScript hot loops still run, reading `world.view_f32(c)`,
//      and produce identical numerical output (= "zero-acceleration").
// Once that holds, I3.B can replace one sub-pass at a time with a C++
// implementation behind `use_gdext_climate`.

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "components/slot.h"

namespace pk {

class DCWorldExt : public godot::RefCounted {
    GDCLASS(DCWorldExt, godot::RefCounted);

public:
    DCWorldExt();
    ~DCWorldExt() override;

    // ─── Component registry ──────────────────────────────────────────────
    int register_component(const godot::StringName &name, int dtype, int stride = 1, bool track_prev = false);
    int component_id(const godot::StringName &name) const;
    int component_count() const { return _slots.size(); }
    bool has_component(const godot::StringName &name) const { return _slot_by_name.has(name); }

    // ─── Entity / Pool API (mirrors I2.A in GDScript) ────────────────────
    int  create_entities(int count);                 // grow _entity_count, returns first new idx
    int  entity_count() const { return _entity_count; }

    int           create_pool(const godot::StringName &name, int capacity);
    godot::Vector2i pool_range(int pool_id) const;
    int           pool_id(const godot::StringName &name) const;
    int           pool_count() const { return _pools.size(); }
    int           pool_free_count(int pool_id) const;

    // ─── Hot-path data views (READ-ONLY snapshot under DCWorldExt) ───────
    // Under GDExtension the returned PackedArray is a CoW *copy*, not an
    // alias to internal storage. Mutating it does NOT write back. For
    // writes, use write_f32 / write_i32 / write_u8 below.
    //
    // NOTE on naming: `view_f32` is the LEGACY name from the I3.A "zero-
    // acceleration alias" era, when we believed the returned PackedArray
    // could double as a writable view through bind_map_data CoW. The
    // climate Pass-A "all-blue bug" (2026-05-12) proved that contract
    // unreliable across pass boundaries. Under the current "Mode B" charter
    // (data Owned-by-C++, GDScript pulls read-only snapshots) callers
    // SHOULD use `snapshot_f32` instead — same return shape, but the name
    // documents the contract truthfully. `view_f32` remains as a thin
    // alias to keep older call sites compiling.
    godot::PackedFloat32Array view_f32(int comp_id);
    godot::PackedInt32Array   view_i32(int comp_id);
    godot::PackedByteArray    view_u8(int comp_id);

    // ─── Mode-B snapshot API (recommended) ──────────────────────────────
    // Returns a value-copy (Godot PackedArray COW) of `_slots[comp_id].arr_f32`.
    // The caller is free to mutate the returned array — those mutations
    // never propagate back into `_slots[]`. Use this whenever GDScript
    // needs to read the latest C++-side numerical state (UI, baker,
    // diagnostics, MapData refresh via flush_to_mapdata).
    //
    // On invalid `comp_id` or non-F32 slot: returns an empty array, no error.
    godot::PackedFloat32Array snapshot_f32(int comp_id);

    // ─── Hot-path writes (replaces `view_xxx(c)[i] = v` pattern) ─────────
    // Single-element writes; bounds-checked, no-op on invalid args.
    void write_f32(int comp_id, int idx, float v);
    void write_i32(int comp_id, int idx, int32_t v);
    void write_u8 (int comp_id, int idx, int v); // accept int from GDScript; clamp to 0..255
    // Bulk writes; copy `src[0..src.size())` into `arr[start..start+src.size())`.
    void write_f32_range(int comp_id, int start, const godot::PackedFloat32Array &src);
    void write_i32_range(int comp_id, int start, const godot::PackedInt32Array   &src);
    void write_u8_range (int comp_id, int start, const godot::PackedByteArray    &src);

    // Sparse / indexed writes; for each k in [0, indices.size()), do
    //   arr[indices[k]] = values[k]
    // Designed for Pass-B / dirty-only systems where the dirty cell list is
    // smaller than the full pool but is *not* contiguous. One trans-boundary
    // call replaces N single-cell write_xxx() calls — on a 2400-cell, 30%-
    // dirty workload this is the difference between ~15ms and ~3ms (see
    // tmp/bench_dots_vs_dict.gd, Case 3/4).
    void write_f32_indexed(int comp_id, const godot::PackedInt32Array &indices, const godot::PackedFloat32Array &values);
    void write_i32_indexed(int comp_id, const godot::PackedInt32Array &indices, const godot::PackedInt32Array   &values);
    void write_u8_indexed (int comp_id, const godot::PackedInt32Array &indices, const godot::PackedByteArray    &values);

    // Scalar variant: all dirty cells get the same value (e.g. clear flag).
    // Saves the caller from materialising a values array of constants.
    void write_f32_scalar_indexed(int comp_id, const godot::PackedInt32Array &indices, float v);
    void write_i32_scalar_indexed(int comp_id, const godot::PackedInt32Array &indices, int32_t v);
    void write_u8_scalar_indexed (int comp_id, const godot::PackedInt32Array &indices, int v);

    // ─── Bind to MapData (GDScript instance) ─────────────────────────────
    // Reflectively reads the GDScript `MapData` properties (e.g. `temp_arr`)
    // and assigns them into the matching slots. Buffers are shared via COW —
    // no copy. Returns false on any property mismatch / type mismatch.
    bool bind_map_data(godot::Object *map_data);
    bool is_bound() const { return _bound; }

    // ─── CoW flush / refresh (performance-charter §11.2) ─────────────────
    // After any C++ pass calls ptrw() on a slot, CoW detaches the buffer.
    // flush_slots_to_map() pushes the (possibly-detached) C++ buffer back
    // to the GDScript MapData property via obj->set() — O(1) ref-swap each.
    // refresh_slots_from_map() does the reverse: pulls GDScript-side
    // arrays back into the C++ slots (needed when GDScript code writes
    // map.*_arr between C++ passes).
    void flush_slots_to_map();
    void refresh_slots_from_map();

    // ─── Archetype system (mirrors I2.B in GDScript) ─────────────────────
    int  create_archetype(const godot::StringName &name, const godot::Array &comp_ids);
    void assign_archetype(int idx, int arch_id);
    int  archetype_count() const { return _archetypes.size(); }
    godot::PackedInt32Array entity_archetype_array() const { return _entity_archetype; }

    // ─── Hot-loop entry points (stubs; filled in I3.B/C) ─────────────────
    // Returning -1.0 indicates "not implemented yet, fall back to GDScript".
    // GDScript-side caller checks `< 0` and routes to the legacy path.
    double run_climate_pass_a(const godot::Dictionary &cp_struct, double phase, double season_phase);

    // ─── Phase F / dots-full-migration §F.1-F.6 hot pass C++ scaffolding ──
    //
    // 6 个待 C++ 化的 hot pass，本提交为 **stub**——每个函数 sig 已就位、
    // _bind_methods 已注册、ClimateProfile 配套 use_gdext_<name> flag 已加，
    // 函数体当前 return -1.0 → GDScript caller 走 fallback。
    //
    // 后续 PR 按 charter §12.4 七步 SOP + tools/migration_harness/template_bench.gd
    // 逐个填充实际算法 + bit-equal 验收。每个 pass 顶部注释列出对应 GDScript
    // 源文件 + 性能目标（charter §7）。
    //
    // 加入顺序按 charter §7 收益优先级：F.1 (P0) → F.2 (P1) → ... → F.6 (P3)。

    // F.1 (P0): weather field solve (vapor / cloud / precip / instability /
    //           intensity / convergence / type) — single-shot full pass.
    //
    //   GDScript 源：scripts/weather/weather_system.gd::run_weather_field_solve_slice
    //                 (line 641+, "B-full Step-2" SoA-aware fast path)
    //   ClimateProfile flag：use_gdext_weather_field
    //   性能目标：13ms → < 2ms（charter §7 第一优先级）
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包）：
    //     标量： start_idx, end_idx, n_cells, season_idx (int)
    //            climate_anomaly, season_phase (float)
    //            world_bounds_pos_y, world_bounds_size_y (float)
    //            field_advect_steps (int)
    //            field_diffusion, field_condensation_gain,
    //            field_orographic_lift_gain, field_convergence_gain,
    //            field_ocean_evap_gain, field_precip_decay (float)
    //            refresh_convergence (bool)
    //     PackedArray（zero-copy read）：
    //            cell_pos          : PackedVector2Array  (n_cells)
    //            neighbor_indices  : PackedInt32Array    (n_cells * 6)
    //            prev_vapor        : PackedFloat32Array  (n_cells)
    //            prev_precip       : PackedFloat32Array  (n_cells)
    //            temp_transport_anomaly : PackedFloat32Array  (n_cells)
    //              ↑ 由 GDScript 从 cells[i].temperature_transport_anomaly
    //                按 i 顺序提取（该字段尚未在 schema 中作 SoA 镜像；
    //                F.x phase II 数据所有权下移 PR 中再迁移到 schema）
    //
    //   写：直接写到 cell_weather_{vapor/cloud/precip/instability/intensity/
    //       convergence/type/field_init} slot 数组（=GDScript map.weather_*_arr
    //       的 CoW alias）。GDScript 调用方在调用后再把这些 SoA 拷回
    //       _field_slice_next_* 即可保持 commit_weather_field_solve() 不变。
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；
    //          < 0.0 → 任意先决条件不满足，调用方走 GDScript 回退。
    //
    //   bit-equal 容差：1e-4（含 sqrt + clamp + lerp 链）。
    //   切片限制：本实现要求 start_idx == 0 且 end_idx == n_cells（即"全量"）。
    //             因为多 slice 共享 SoA 写会污染下一 slice 的读，单元格预算 < n
    //             一律 fallback。F.x 后续 PR 可加 dirty-flag 双缓冲解锁。
    double run_weather_field_solve_pass(const godot::Dictionary &knobs);

    // F.2 (P1): ocean water + land 两个独立 pass
    //   GDScript 源：map_generator.gd::_ocean_water_pass_soa (line 4679+) +
    //                ::_ocean_land_pass_soa (line 4762+)
    //   ClimateProfile flag：use_gdext_ocean_water / use_gdext_ocean_land
    //   性能目标：6.8ms → < 1ms (两个 pass 各 ~0.5ms)
    //   依赖序：land_pass 必须在 water_pass 之后跑（land 读 water 写过的 anomaly）
    //
    //   入参 `knobs` Dictionary（与 F.1/F.3/F.5 同模板）：
    //
    //   --- run_ocean_water_pass(knobs) 字段 ---
    //     标量： n_cells (int), advect_steps (int), heat_mix (float)
    //     PackedArray（read-only 输入）：
    //            neighbor_indices  : PackedInt32Array    (n_cells * 6)
    //            baseline_arr      : PackedFloat32Array  (n_cells)
    //                ↑ GDScript 预算：if ema_init[i]: temp_baseline[i],
    //                                  else: _compute_temperature(_cube_row_norm, elev[i])
    //            temp_before_arr   : PackedFloat32Array  (n_cells)
    //                ↑ GDScript 预算：if temp[i] > 0: temp[i], else: baseline[i]
    //            ocean_current_x_arr : PackedFloat32Array (n_cells)
    //            ocean_current_y_arr : PackedFloat32Array (n_cells)
    //                ↑ 必须！由 GDScript 从 cells[i].ocean_current.x/y 提取。
    //                  schema 里的 cell_ocean_current_x/y SoA 镜像由
    //                  rebuild_soa_from_cells 仅在世界生成时填一次；
    //                  physical_circulation_solver 之后改的是 HexCell，
    //                  从不回写 SoA。如果直接读 C++ slot，advect 方向用的
    //                  是初始 (近 0) 值，cascading 全图温度雪崩。
    //                  （Demo Complex Pass 类同问题，2026-05-13 用户验收时
    //                   F.2 land 正反馈 + ocean_current stale 双重 bug 暴露。）
    //     PackedArray（write 输出）：
    //            anomaly_out      : PackedFloat32Array  (n_cells)
    //                ↑ C++ 写每个 water cell 的 anomaly = temp_mixed - baseline
    //                  （非 water cell 由 land pass 后续覆盖；初始可全 0）
    //
    //   --- run_ocean_land_pass(knobs) 字段 ---
    //     标量： n_cells (int), effective_leak (float)
    //     PackedArray（read-only 输入）：
    //            neighbor_indices       : PackedInt32Array    (n_cells * 6)
    //            fallback_baseline_arr  : PackedFloat32Array  (n_cells)
    //                ↑ 必填！T[i] <= 0 时 t_prev 的兜底值。
    //            ocean_current_x_arr    : PackedFloat32Array  (n_cells)
    //            ocean_current_y_arr    : PackedFloat32Array  (n_cells)
    //                ↑ 必填！同 water pass 一样从 cells 提取（SoA stale 问题）
    //     PackedArray（in/out）：
    //            anomaly_inout    : PackedFloat32Array  (n_cells)
    //                ↑ 既读（water 邻居的 anomaly，由 water pass 写入），
    //                  也写（land cell 自身的 anomaly）
    //
    //   读：cell_temp, cell_is_water, cell_pos_x, cell_pos_y,
    //       cell_ocean_current_x, cell_ocean_current_y
    //   写：cell_temp（mix 后）+ knobs["anomaly_inout"]
    //
    //   返回：≥ 0.0 → 接管完成 (=elapsed_ms)；< 0.0 → fallback
    //   bit-equal 容差：1e-4（含 sqrt + lerp + dot product 链）
    double run_ocean_water_pass(godot::Dictionary knobs);
    double run_ocean_land_pass (godot::Dictionary knobs);

    // F.3 (P1): climate Pass-B (local climate coupling)
    //   GDScript 源：scripts/geography/map_generator.gd::_climate_pass_b_soa
    //                 (line 4311+, SoA-aware fast path)
    //   ClimateProfile flag：use_gdext_climate_pass_b
    //   性能目标：5.2ms → < 0.5ms（charter §7 P1）
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包，与 F.1/F.5 同模板）：
    //     标量： n_cells (int)
    //            winter_boost, snow_cool, veg_cool, diurnal_amp, evap_gain,
    //            rs_threshold, rs_factor, t_freeze, coupling_gain, coast_leak,
    //            landform_phase_factor, season_phase (float)
    //            rs_lookback (int)
    //            go_sparse (bool；本实现不支持稀疏路径，go_sparse=true 时
    //                       直接 return -1.0 fallback；后续 PR 加 dirty mask
    //                       处理后再启用)
    //     PackedArray（zero-copy read）：
    //            neighbor_indices         : PackedInt32Array    (n_cells * 6)
    //            temp_transport_anomaly   : PackedFloat32Array  (n_cells)
    //                ↑ 由 GDScript 从 cells[i].temperature_transport_anomaly 提取
    //                  （schema 尚未为该字段建 SoA 镜像；同 F.1）
    //            foliage_table            : PackedFloat32Array  (按 VegetationType.VEG
    //                ↑ enum 顺序的 _vegetation_foliage_density 值，~24 个 float)
    //
    //   读：cell_temp, cell_moisture, cell_snow_cover, cell_is_water,
    //       cell_landform, cell_vegetation, cell_elevation, cell_lat_norm,
    //       cell_pos_x, cell_pos_y
    //   写：cell_temp, cell_moisture
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)
    //          < 0.0 → 任意先决条件不满足 / go_sparse=true，调用方走 GDScript
    //
    //   bit-equal 容差：1e-4（含 sqrt + sin + smoothstep + cos 链）
    //   未支持的特性：
    //     - go_sparse=true 时的稀疏路径 → fallback
    //     - cell.temperature_breakdown UI 调试 dict 写入 → 不写入（GDScript
    //       fallback 会写；F.3 ON 时 inspector 看选中 cell 的 breakdown 会空，
    //       后续 PR 用 dirty selection list 单独补回 < 100 cells 的写入即可）
    //     - [DIAG pass_b_end] 末尾统计 print（GDScript caller 在 C++ pass 之后
    //       自己 dump SoA 即可，本 C++ 不打日志）
    double run_climate_pass_b(const godot::Dictionary &knobs);

    // F.4 (P2): sea ice daily pass
    //   GDScript 源：scripts/simulation/sea_ice/daily_pass.gd
    //                 (实际仍在 map_generator.gd line 3573)
    //   ClimateProfile flag：use_gdext_sea_ice
    //   性能目标：5.1ms → < 0.5ms
    //   注：cell.terrain 翻转（罕触发）必须走 ECB（charter §2.5 STRUCT-001 反模式）
    double run_sea_ice_daily_pass(const godot::Dictionary &knobs, float season_phase);

    // F.5 (P2): transpiration pass
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_transpiration_pass (line 4938+)
    //   ClimateProfile flag：use_gdext_transpiration
    //   性能目标：3.2ms → < 0.3ms
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包，与 F.1 同模板）：
    //     标量： n_cells (int)
    //            outflow_rate, self_rate (float)
    //     PackedArray（zero-copy read）：
    //            neighbor_indices  : PackedInt32Array    (n_cells * 6)
    //            donor_table       : PackedFloat32Array  (按 VegetationType.VEG enum 顺序，
    //                                ~24 个 float；每项 = transpiration[VEG_id]，避免
    //                                hot loop 反射 VegetationProfile)
    //
    //   读：cell_landform / cell_vegetation / cell_moisture
    //   写：cell_moisture (clamp(m + delta, 0, 1))
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；
    //          < 0.0 → 任意先决条件不满足，调用方走 GDScript 回退。
    double run_transpiration_pass(const godot::Dictionary &knobs);

    // F.6 (P3): weather front advect (含 front pool DOTS 化)
    //   GDScript 源：scripts/weather/front_advect.gd
    //   ClimateProfile flag：use_gdext_weather_front
    //   性能目标：3.0ms → < 0.5ms
    //   前置：FRONT_POS_X/Y/VEL_X/Y/AGE/INTENSITY 6 个 component 升为权威而非镜像
    //   N=16 fronts 不需要 SIMD
    double run_weather_front_advect_pass(int n_fronts, float dt);

    // ─── Mode-B reference implementation: temp_drift_pass ────────────────
    // The minimal "hello world" pass that validates the full Owned-by-C++
    // communication contract end-to-end. Adds `drift_amount` to every
    // element of `_slots[CELL_TEMP].arr_f32` via a tight ptrw() loop with
    // ZERO Variant operations and ZERO obj.set() flushes.
    //
    // This is NOT a game feature. It exists so:
    //   1. We have a reference C++ writer to copy-paste from.
    //   2. We can bit-precisely cross-check against a GDScript replica
    //      (addition is exact, no FP drift).
    //   3. `docs/performance-charter.md` §12 documents this exact code as
    //      the canonical Mode-B template.
    //
    // Safety: if the slot id (looked up by StringName "cell_temp") is not
    // registered, the call is a no-op (no crash, no error spam).
    void run_temp_drift_pass(float drift_amount);

    // ─── Mode-B reference implementation: thermal_gradient_pass (Pass #2) ─
    // Pass #2 stresses the four real-business complexities that Pass #1
    // intentionally skipped:
    //   1. multi-input SoA  : reads BOTH cell_temp AND cell_elevation
    //   2. neighbour access : 4-neighbour central difference (clamp-to-edge)
    //   3. write new comp   : writes to cell_demo_thermal_gradient
    //   4. overlay surfaceable: result lives on a real component slot, so
    //                          the GDScript-side baker can sample it through
    //                          snapshot_f32() and feed it to the data overlay.
    //
    // Per-cell formula (mirrors performance-charter §12.6 spec):
    //   grad_x = (T_east - T_west) * 0.5    (clamp-to-edge at borders)
    //   grad_y = (T_south - T_north) * 0.5  (clamp-to-edge at borders)
    //   amp    = 1 + elevation_gain * cell_elevation[i]
    //   out    = clamp(sqrt(grad_x*grad_x + grad_y*grad_y) * amp * normalize_k, 0, 1)
    //
    // Hot-loop discipline (copy verbatim into new "with-neighbour" passes):
    //   * Resolve all slot ids ONCE before the loop.
    //   * Take ONE ptr() per read buffer + ONE ptrw() per write buffer.
    //   * Inner loop accesses neighbours by integer index ONLY (no Variant,
    //     no view_f32() per cell, no map->get() per cell).
    //   * Borders use "self-substitute" (Tn := T at y==0 etc.) instead of
    //     conditional branches — avoids both OOB and modulo-wrap artefacts.
    //
    // Safety: if any of the three slots is not registered or sizes do not
    // match grid_w * grid_h, the call is a no-op + a single push_warning.
    // No crash, no exception, no half-written buffer.
    void run_thermal_gradient_pass(int grid_w,
                                   int grid_h,
                                   float elevation_gain,
                                   float normalize_k);

    // ─── Mode-B reference implementation: demo_complex_pass (Pass #3) ─────
    // Pass #3 keeps every piece of Pass #2's communication scaffolding
    // (component slot, overlay mode, climate switch, baker, tick hook,
    // performance-charter §12.6 entry) and ONLY upgrades the kernel from
    // a one-shot 4-neighbour gradient to an iterated anisotropic-diffusion
    // + multi-scale wind approximation. The point is to push real ops/cell
    // up two orders of magnitude (~10 → ~2400 at default knobs) so the
    // user can both (a) see richer overlay patterns and (b) probe how far
    // C++ single-threaded can scale before climate Pass-A is revisited.
    //
    // Per-step formula (mirrors performance-charter §12.6.6 spec):
    //   for it in 0..iterations-1:
    //     smooth[i] = sum(src[nb] * gauss_weight[dx,dy]) / sum(gauss_weight)
    //     gx, gy   = sobel_3x3(src, x, y)                      (clamp-to-edge)
    //     rotate (gx, gy) by 90° * coriolis_strength * sgn(y - h/2)
    //     damp     = 1 - terrain_drag * cell_elevation[i]
    //     dst[i]   = smooth[i] + (gx' + gy') * damp * 0.05      (step constant)
    //   normalize last buffer to [0,1] then apply (1+gain*elev)*k + clamp.
    //
    // Knob clamps (silently corrected, single push_warning per process):
    //   iterations   ∈ [1, 64]   (default 16)
    //   kernel_radius∈ [1, 5]    (default 2  → 5×5 neighbourhood)
    //   coriolis     ∈ [-1, 1]   (default 0.5)
    //   terrain_drag ∈ [0, 1]    (default 0.6)
    //   elevation_gain / normalize_k: passed through unchanged from Pass #2.
    //
    // Hot-loop discipline (verbatim from §12.6 template):
    //   * Resolve all slot ids ONCE before the iteration loop.
    //   * Pre-compute the (2r+1)² Gaussian kernel ONCE on the C-stack array.
    //   * Two std::vector<float> ping-pong buffers, allocated ONCE per call.
    //   * Inner loop: only ptr/ptrw + integer index + table lookup. NO
    //     Variant, NO obj.set, NO map->get per cell.
    //   * Borders use clamp-to-edge (Neumann BC) — same as Pass #2.
    //
    // BIT-EQUAL DISCIPLINE: every intermediate runs in double on the C++
    // side and is only narrowed back to float at the FINAL store, mirroring
    // GDScript's implicit-double arithmetic in PackedFloat32Array.
    //
    // Safety: same as Pass #2 — missing slot / dtype mismatch / size
    // mismatch all yield no-op + push_warning. No crash, no half-written
    // buffer.
    void run_demo_complex_pass(int grid_w,
                               int grid_h,
                               int iterations,
                               int kernel_radius,
                               float coriolis_strength,
                               float terrain_drag,
                               float elevation_gain,
                               float normalize_k);

    // ─── DOTS-A1 EXPERIMENT: archetype-filtered demo_complex_pass ─────────
    // Identical algorithm to `run_demo_complex_pass` (same kernel, same
    // bit-equal contract), with ONE additional discipline: cells whose
    // `_entity_archetype[i]` does not equal `target_archetype` are SKIPPED
    // — their output slot is set to 0.0f and they do not contribute to the
    // post-iter normalization min/max either.
    //
    // Special semantics for `target_archetype`:
    //   ≥ 0  : only cells with _entity_archetype[i] == target_archetype run.
    //   < 0  : "no filter" — every cell runs (= equivalent to vanilla
    //          `run_demo_complex_pass`, used as the bit-equal control row).
    //
    // Why a separate function (not an extra param to the vanilla pass):
    //   * Vanilla `run_demo_complex_pass` is the canonical Mode-B template
    //     reference quoted verbatim in performance-charter §12.6.6 — we do
    //     not want to perturb its hot-loop layout.
    //   * The archetype branch adds a load+compare per cell; keeping it in
    //     a sibling function makes the cost obvious in the bench numbers.
    //
    // Safety: same as vanilla — missing slot / dtype mismatch / size
    // mismatch all yield no-op + push_warning. If `_entity_archetype.size()`
    // is smaller than the cell count and `target_archetype >= 0`, the call
    // is a no-op + push_warning (defensive: archetype assignment hasn't
    // happened yet).
    void run_demo_complex_pass_archetyped(int grid_w,
                                          int grid_h,
                                          int iterations,
                                          int kernel_radius,
                                          float coriolis_strength,
                                          float terrain_drag,
                                          float elevation_gain,
                                          float normalize_k,
                                          int target_archetype);

    // ─── Phase 3a Step 0: alias spike (TEMPORARY — to be removed) ─────────
    // Three variants probe whether `obj.set(prop, arr)` followed by
    // `arr.ptrw()[i] = v` keeps the buffer aliased between obj.<prop> and
    // the C++-side `arr` reference. Real result drives the bind_map_data
    // strategy in Step 1. See plan/dots-roadmap-to-gdextension.
    //
    // All three return the value seen by the GDScript side AFTER the C++
    // mutation, so the caller can simply compare against the sentinel.
    //   v1 : naive   — get, set, ptrw-write
    //   v2 : release — get, set, drop local ref, re-get, ptrw-write
    //   v3 : write-then-set — get, ptrw-write, set
    float _spike_alias_v1_naive          (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);
    float _spike_alias_v2_release        (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);
    float _spike_alias_v3_write_then_set (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);

    // ─── Phase 3a Step 1: alias verification helper (TEMPORARY) ──────────
    // Writes `sentinel` into _slots[comp_id].arr_f32[idx] via ptrw() — the
    // same path that hot loops will use. The companion test reads back via
    // GDScript-side `map.<prop>[idx]` to confirm the alias survives a pure
    // C++ mutation (no obj.set call after the write). If the test PASSes,
    // the bind_map_data push-back contract is correct: GDScript and C++
    // share the buffer, no per-write set needed.
    // Removed once Step 1 validation is signed off (along with the spike).
    float _debug_poke_f32(int comp_id, int idx, float sentinel);

    // T1b: same as _debug_poke_f32, but performs map_data->set(prop_name,
    // s.arr_f32) immediately after the ptrw() write to push the (possibly
    // detached) buffer back to the GDScript side. Probes whether
    // "write-then-set per pass" is the correct alias contract — if T1b
    // PASSes while T1 FAILs, then bind_map_data's one-time push-back is
    // insufficient and every C++ hot pass must re-set on exit.
    // Looks up comp_id → property_name via the BIND_TABLE.
    float _debug_poke_f32_with_flush(int comp_id, int idx, float sentinel);

    // ─── Phase-3 micro-bench API ────────────────────────────────────────
    // These are NOT production paths; they exist solely so tmp/bench_*.gd
    // can compare three optimisation strategies head-to-head:
    //   B-scalar : C++ tight loop, ptrw(), naive scalar code (compiler may
    //              auto-vectorise depending on flags / loop shape).
    //   B-simd   : C++ tight loop with explicit AVX2/SSE2 intrinsics.
    //   C-thread : same as B-simd but split across WorkerThreadPool workers.
    //
    // Workload model (mimics climate Pass-A's per-cell math):
    //   new[i] = base + lat[i]*k1 + (sum of 6 nb of prev[i])*k2 + season
    //
    // Inputs are passed explicitly (not via bind_map_data) so the bench can
    // run standalone without a real MapData. Returns the bench-internal
    // elapsed milliseconds (whatever the inside loop took, excluding the
    // GDScript dispatch overhead) — caller still wraps in get_ticks_usec
    // for a true end-to-end measurement.
    void bench_pass_a_full_scalar(int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season);
    void bench_pass_a_full_simd  (int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season);
    void bench_pass_a_full_thread(int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season,
                                  int n_tasks);

    void bench_pass_a_indexed_scalar(int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season);
    void bench_pass_a_indexed_simd  (int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season);
    void bench_pass_a_indexed_thread(int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season,
                                     int n_tasks);

    // ───────────────────────────────────────────────────────────────────
    // EXPERIMENTAL: D-async — long-lived worker thread + double buffering
    // ───────────────────────────────────────────────────────────────────
    // Goal: probe whether a "request → background compute → poll" pattern
    // gives the main thread sub-50µs dispatch cost while keeping the
    // demo_complex algorithm bit-equivalent to the synchronous path.
    //
    // Contract (CRITICAL — read before touching any of these methods):
    //   1. Worker threads NEVER call any Godot API (no Variant, no
    //      push_warning, no Object::get/set). They only read/write their
    //      own std::vector<float> buffers.
    //   2. Inputs (temp / elev) are SNAPSHOT-COPIED into worker-private
    //      buffers in `async_climate_set_inputs` — caller-side mutation
    //      after the call cannot race with the worker.
    //   3. Outputs land in a worker-private std::vector<float>; the main
    //      thread copies them into _slots[CELL_DEMO_THERMAL_GRADIENT] only
    //      inside `async_climate_poll()` (which returns true on success).
    //   4. `async_climate_shutdown_*` joins the worker(s); ~DCWorldExt
    //      calls shutdown_all() defensively.
    //   5. NEVER share an AsyncTask across DCWorldExt instances.
    //
    // Output slot: re-uses "cell_demo_thermal_gradient" so existing data
    // overlay machinery / GDScript snapshot code keeps working unchanged.
    //
    // See `.codebuddy/plan/cpp-async-experiment/requirements.md` for the
    // experiment design and 7-criteria success matrix.
    void async_climate_register_task(int task_id, int n_workers);
    void async_climate_set_inputs(int task_id,
                                  const godot::PackedFloat32Array &temp,
                                  const godot::PackedFloat32Array &elev);
    void async_climate_request(int task_id,
                               int grid_w, int grid_h,
                               int iterations, int kernel_radius,
                               float coriolis_strength,
                               float terrain_drag,
                               float elevation_gain,
                               float normalize_k);
    bool async_climate_poll(int task_id);
    godot::Dictionary async_climate_stats(int task_id);
    void async_climate_shutdown_task(int task_id);
    void async_climate_shutdown_all();

protected:
    static void _bind_methods();

private:
    // ---- registry ----
    godot::Vector<Slot>                       _slots;
    godot::HashMap<godot::StringName, int>    _slot_by_name;

    // ---- entity / pool ----
    int                                       _entity_count = 0;

    struct Pool {
        godot::StringName name;
        int               start    = 0;
        int               capacity = 0;
        // free-list (LIFO stack of indices within [start, start+capacity)).
        // empty = pool fully allocated. Initialised in create_pool().
        godot::Vector<int> free_list;
    };
    godot::Vector<Pool>                       _pools;
    godot::HashMap<godot::StringName, int>    _pool_by_name;

    // ---- bind state ----
    godot::Object                            *_map_data = nullptr; // weak (GDScript holds strong ref)
    bool                                      _bound    = false;

    // ---- archetype ----
    godot::Vector<godot::Array>               _archetypes;          // each entry = comp_ids
    godot::HashMap<godot::StringName, int>    _archetype_by_name;
    godot::PackedInt32Array                   _entity_archetype;    // index by entity idx

    // ---- EXPERIMENTAL: D-async opaque state (defined in .cpp) ----------
    // Holds the std::unordered_map<int, AsyncTask> and a global mutex.
    // Allocated lazily on first async_* call; freed in shutdown_all().
    void                                     *_async_state = nullptr;

    // ---- helpers ----
    void _ensure_slot_capacity(Slot &slot, int new_count);
    void _flush_slot_to_map(int comp_id);
};

} // namespace pk

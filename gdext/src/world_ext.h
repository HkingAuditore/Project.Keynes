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

#include <cstdint>
#include <unordered_map>

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
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_sea_ice_daily_pass
    //                 (line 3856+, 2-phase 算法)
    //   ClimateProfile flag：use_gdext_sea_ice
    //   性能目标：5.1ms → < 0.5ms（charter §7 P2）
    //
    //   算法结构（与 GDScript 1:1 镜像）：
    //     Phase A — has_cold_neighbor 快照（用前一日 sea_ice_fraction）：
    //       for each water cell：
    //         如果任一邻居是 water 且 sea_ice_fraction >= 0.6 → has_cold_neighbor[i] = 1
    //     Phase B — 主循环（fraction 增量更新 + 翻转候选收集）：
    //       for each cell：
    //         非 water → fraction = 0；continue
    //         LAKE → fraction = 0；continue
    //         t_eff = clamp(temp + ice_delay * max(0, transport_anomaly) -
    //                       (upwelling > 0.3 ? 0.5 * upwelling : 0), 0, 1)
    //         k_freeze_eff = k_freeze * (has_cold_neighbor ? 1 + contagion : 1)
    //         delta = k_freeze_eff * max(0, t_form - t_eff) - k_melt * max(0, t_eff - t_melt)
    //         new_frac = clamp(prev_frac + delta, 0, 1)
    //         写 cell_sea_ice_frac[i] = new_frac
    //         判断翻转候选：
    //           prev terrain != SEA_ICE && new_frac >= threshold → flip_to_ice
    //           prev terrain == SEA_ICE && new_frac < threshold - hysteresis →
    //               flip_to_base（保留 base_terrain，base==SEA_ICE 时回退到 OCEAN）
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包，F.5 同模板）：
    //     标量： n_cells (int)
    //            k_freeze, k_melt, t_form, t_melt, contagion (float)
    //            threshold, hysteresis (float)
    //            ice_delay (float)
    //            enable_ocean_heat_transport (bool)
    //            terrain_lake_id, terrain_sea_ice_id, terrain_ocean_id (int)
    //                ↑ TerrainType.LAKE / SEA_ICE / OCEAN 的 enum 值（C++ 不持有 enum）
    //     PackedArray（zero-copy read）：
    //            neighbor_indices       : PackedInt32Array    (n_cells * 6)
    //            base_terrain_arr       : PackedByteArray     (n_cells)
    //                ↑ cells[i].base_terrain；翻回时知道目标 terrain
    //            water_terrain_ids      : PackedByteArray     (~6 entries)
    //                ↑ 与 GDScript map_generator.gd::_is_water 1:1 对齐：
    //                  OCEAN / COAST / LAKE / REEF / KELP / SEA_ICE 共 6 种 enum 值。
    //                  C++ 端用作 256-entry is_water LUT，避免硬编码 enum。
    //            temp_transport_anomaly : PackedFloat32Array  (n_cells)
    //                ↑ 必填（schema 尚未为该字段建 SoA 镜像，与 F.2 同问题）
    //            upwelling_strength     : PackedFloat32Array  (n_cells)
    //                ↑ 必填（同上）
    //
    //   读：cell_terrain (U8), cell_sea_ice_frac (F32, prev), cell_temp (F32)
    //       + 入参 PackedArray
    //   写：cell_sea_ice_frac slot；**不**写 cell_terrain slot（terrain 翻转走
    //       GDScript 端 apply_terrain，保持 multi-axis 同步语义；charter §2.5
    //       STRUCT-001 反模式规避）
    //
    //   knobs 输出回填（C++ 写 PackedInt32Array / PackedByteArray 进 knobs）：
    //     flip_to_ice_list      : PackedInt32Array  — 当日跨过 threshold 的 cell idx
    //     flip_to_base_list     : PackedInt32Array  — 当日跌回 threshold-hysteresis 的 cell idx
    //     flip_to_base_terrain  : PackedByteArray   — 与 flip_to_base_list 同长，
    //                                                 每项 = base_terrain（base==SEA_ICE 时 = OCEAN_id）
    //     stat_water_count      : int  (写到 knobs，用 Variant int 存)
    //     stat_flipped_count    : int  (写到 knobs)
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback
    //   bit-equal 容差：1e-6（fraction 是简单 muladd / clamp，无 sqrt）
    //
    //   sig 设计：knobs 走 by-value（非 const&），让 C++ 端能写回 flip lists
    //             给 GDScript caller。Godot Dictionary 是 RefCounted，by-value
    //             实际是 ref 共享，写回是合法行为（与 F.2 ocean_water/land 同模式）。
    double run_sea_ice_daily_pass(godot::Dictionary knobs, float season_phase);

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

    // F.6 (P3): weather front advect (含 front pool 批量提取模式)
    //   GDScript 源：scripts/weather/weather_front.gd::advance_one_day +
    //                refresh_visual_lifecycle (line 74-127)
    //   ClimateProfile flag：use_gdext_weather_front
    //   性能目标：3.0ms → < 0.5ms（charter §7 P3）
    //   N=16 fronts，单线程足够
    //
    //   设计：fronts batch-extract 模式（Phase 1.2 / dots-full-migration §F.6）
    //     - WeatherFront.pack_into_dict(_active_fronts) 输出 SoA Dictionary
    //     - C++ pass(batch) 直接读写 batch 内 PackedArray
    //     - WeatherFront.apply_dict_to_fronts(batch, _active_fronts) 写回 OOP
    //     - emergent_coupling 的 decay_mul / precip_bonus 在 GDScript 端预算（map 查询），
    //       caller 在 pack 之前已经把 decay_per_day 改过；C++ 只看修改后的 decay。
    //     - wind 采样在 GDScript 端预算（一次 batch wind_per_front Vector2Array），
    //       Vector2.ZERO 表示该 front 无风（C++ 跳过旋转）。
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_fronts (int)
    //            max_axis_turn_rad (float, =0.383972 = 22°/day)
    //     PackedArray（in/out — read 旧值，write 新值）：
    //            front_center_x / .._y       : F32 (n)  — write velocity 应用后
    //            front_velocity_x / .._y     : F32 (n)  — write 重算后
    //            front_axis_x / .._y         : F32 (n)  — write 旋转后
    //            front_stable_axis_x / .._y  : F32 (n)  — write 旋转后
    //            front_radius                : F32 (n)  — read only
    //            front_intensity             : F32 (n)  — write decay 后
    //            front_decay_per_day         : F32 (n)  — read（已含 emergent decay_mul）
    //            front_age_days              : I32 (n)  — write age++
    //            front_type                  : I32 (n)  — read only (refresh_visual_lifecycle 用)
    //            front_ttl_days              : I32 (n)  — read only (refresh_visual_lifecycle 用)
    //            front_life_progress         : F32 (n)  — write
    //            front_cloud_amount          : F32 (n)  — write
    //            front_precip_amount         : F32 (n)  — write
    //            front_dissolve_amount       : F32 (n)  — write
    //            front_alive                 : U8  (n)  — write (intensity > 0.01 && age < ttl)
    //            wind_per_front              : PackedVector2Array (n)
    //                ↑ caller 用 wind_fn(front.center) 预算；ZERO 表示无风
    //
    //   读：knobs 内的 PackedArray（CoW share with GDScript）
    //   写：knobs 内的 PackedArray（in-place via ptrw）；不动任何 _slots[]
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback
    //   bit-equal 容差：1e-5（含 sin / cos / smoothstep 链）
    //
    //   sig 设计：knobs 走 by-value（非 const&），与 F.4 同模式（让 C++
    //             直接修改 PackedArray ptrw，借 Dictionary refcount 共享）。
    double run_weather_front_advect_pass(godot::Dictionary knobs);
    godot::Dictionary run_season_refresh_stage(godot::Dictionary knobs);
    godot::Dictionary run_sea_ice_atlas_prepare(godot::Dictionary knobs);

    // ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）───────────────
    //
    // dist：_distribute_weather_field_to_cells C++ 化
    //   GDScript 源：scripts/weather/weather_system.gd::_distribute_weather_field_to_cells
    //                 (line 1290+)
    //   ClimateProfile flag：use_gdext_weather_distribute（默认 true）
    //   性能目标：~11.6ms → < 1.5ms（n_cells = 2400 基线）
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包）：
    //     标量：n_cells (int)
    //           snow_threshold_temp, snow_min_intensity, flood_heavy_intensity,
    //           flood_heavy_precip, flood_lowland_intensity, flood_lowland_elev,
    //           flood_lowland_moisture (float)
    //     PackedArray（zero-copy read-write via SoA view）：
    //           weather_type, weather_intensity, weather_precip,
    //           weather_field_initialized,
    //           moisture_arr, temp_arr, cover_arr, accumulated_snow_days_arr,
    //           landform_arr, terrain_arr （详见 cpp 实装）
    //
    //   写：moisture / temperature / cover / current_state["cover"]（通过 schema
    //       回写） / accumulated_snow_days；并通过 out 字段返回 cover_dirty bool。
    //   返回：≥ 0.0 → 接管完成（=elapsed_ms）；< 0.0 → fallback。
    //
    //   sig 设计：返回 Dictionary 而非 double，包含 { "elapsed_ms", "cover_dirty" }。
    //             elapsed_ms < 0 表示 precondition 失败。
    godot::Dictionary run_weather_distribute_pass(const godot::Dictionary &knobs);

    // summary：_build_field_summary_fronts C++ 化
    //   GDScript 源：scripts/weather/weather_system.gd::_build_field_summary_fronts
    //                 (line 1322+)
    //   ClimateProfile flag：use_gdext_weather_summary（默认 true）
    //   性能目标：~17.8ms → < 3.0ms（n_cells = 2400, field_summary_limit = 16）
    //
    //   入参 `knobs` Dictionary：
    //     标量：n_cells (int), field_summary_limit (int), hex_size (float)
    //           summary_intensity_enter (float, =0.10),
    //           summary_intensity_hold  (float, =0.06),
    //           merge_ratio (float, =0.65), max_merge_rounds (int, =4)
    //           day_counter (int, 仅 debug 用)
    //     PackedArray（zero-copy read，SoA view）：
    //           cell_pos, neighbor_indices,
    //           weather_type, weather_intensity, weather_field_initialized,
    //           weather_cloud, weather_precip, wind_x, wind_y
    //     fallback：avg_wind_x, avg_wind_y (float, 新生 cluster 用)
    //
    //   读：上述 SoA + 持久化的 _prev_summary_seeds / _prev_summary_membership
    //       （C++ 内部维护，跨 tick 存活）
    //   写：返回 Dictionary { "elapsed_ms": float, "fronts": Array[Dictionary] }。
    //       每个 front Dictionary 字段：type/center/intensity/radius/axis/
    //       stable_axis/velocity/major_scale/minor_scale/age_days/ttl_days/
    //       life_progress/edge_seed/cloud_amount/precip_amount。
    //
    //   sig 设计：返回 Dictionary，字段 elapsed_ms < 0 表示 precondition 失败；
    //             此时 fronts 字段为空 Array，调用方 fallback 到 GDScript。
    godot::Dictionary run_weather_summary_fronts_pass(const godot::Dictionary &knobs);

    // 清空 C++ 端持久化的 summary 状态（_prev_summary_seeds / _prev_summary_membership）。
    // 在 GDScript 切换 use_gdext_weather_summary flag、或开关 verify mode 时调用，
    // 避免新旧实现互相污染。无副作用、O(1) 清空（vector::clear）。
    void reset_weather_summary_state();

    // verify 协议辅助：snapshot / restore 持久化状态。set_summary_verify_mode 在 dev
    // 模式下要求"先跑 C++ 再跑 GDScript"两遍，跑 GDScript 之前必须把 C++ 写脏的状态
    // 还原到本 tick 入口；这两个接口配合 GDScript 端的 prev_seeds shadow 完成往返。
    void snapshot_weather_summary_state();
    void restore_weather_summary_state();

    // ─── Block B: ocean_currents wind solver C++ pass ─────────────────────
    //
    //   GDScript 源：scripts/rendering/physical_circulation_solver.gd::solve_wind_field
    //                 (line 246-454, 195 行)
    //   ClimateProfile flag：use_gdext_wind_field（默认 false；本 PR 完成 +
    //                        SAME_SOURCE A/B 通过 + p95 ≤ 5ms 后切 true）
    //   性能目标：35.55ms p95 → < 5ms（charter §7 / dots-wind-validation.md）
    //
    //   算法结构（与 GDScript 1:1 镜像）：
    //     Pass 0 — 海岸 BFS（≤ _WIND_MONSOON_MAX_DIST=5 步）：
    //       识别每个陆地 cell 距海岸的格数 + 朝向海洋的单位向量
    //     主循环 — 每 cell：
    //       (a) 纬度基线 v_base = wind_belt_at(ny, season_phase)
    //       (b) 6 邻域离散梯度 grad_slp = (1/3)*Σ(slp_nb-slp_self)*d_unit
    //       (d) 科氏偏转：仅对 -grad_slp 做（北半球右偏 / 南半球左偏）
    //       (c) 海陆季风附加：BFS 距离权重 × sea_dir × 季节符号
    //       合成 v_sum = w_lat*v_base + w_grad*v_grad + w_monsoon*v_monsoon
    //       (e) 地形/摩擦衰减 + 山脉绕流（mountain neighbor 切向偏转）
    //       写 wind_x_arr[i], wind_y_arr[i], wind_speed_out[i]
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            hex_size (float)
    //            season_phase (float)
    //            terrain_aware (int 0/1)  — 见 ClimateProfile.enable_terrain_aware_wind
    //            world_bounds_pos_y (float)
    //            world_bounds_size_y (float)
    //     PackedArray（zero-copy read）：
    //            neighbor_indices : PackedInt32Array (n_cells * 6)
    //                ↑ 顺序与 HexUtils.CUBE_DIRECTIONS 一致
    //                  (0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE)
    //            slp_arr          : PackedFloat32Array (n_cells)
    //                ↑ 必填！由 GDScript 从 cell.slp 提取
    //                  （cell.slp 不在 schema 中）
    //            water_terrain_ids: PackedByteArray (~4 entries)
    //                ↑ TerrainType 枚举 OCEAN/COAST/REEF/KELP，
    //                  与 _is_water_terrain 1:1 对齐
    //            land_lf_mountain : int (knobs scalar) = LandformType.LF.MOUNTAIN
    //            land_lf_peak     : int (knobs scalar) = LandformType.LF.PEAK
    //            land_lf_hill     : int (knobs scalar) = LandformType.LF.HILL
    //
    //   读：cell_pos_y (lat 推导), cell_terrain (U8), cell_landform (U8) +
    //       knobs["slp_arr"] + knobs["neighbor_indices"]
    //   写：cell_wind_x slot (F32), cell_wind_y slot (F32) + flush_slot_to_map
    //   knobs 输出：
    //     wind_speed_out : PackedFloat32Array (n_cells)
    //         ↑ caller 拿这个数组写每 cell.wind_speed
    //         （cell.wind_speed 不在 schema）
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；
    //         < 0.0 → 任意先决条件不满足，调用方走 GDScript 回退。
    //
    //   bit-equal 容差：1e-4（含 sin/cos/sqrt/normalize 链）
    //   未支持的特性：none（与 GDScript 算法 1:1 镜像）
    double run_wind_field_pass(godot::Dictionary knobs);
    godot::Dictionary run_physical_circulation_pass(godot::Dictionary knobs);

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

    // ---- Weather summary pass 持久化状态（plan/weather-hotpath-cpp）------
    // GDScript 侧 _prev_summary_seeds (Array[Dictionary]) 与
    // _prev_summary_membership (Dictionary[HexCell→cluster_idx]) 的 C++ 镜像：
    //   _prev_summary_seeds_state：跨 tick 存活的 seed 列表（type/center/area/
    //                              age/velocity）；按上 tick top-N 写入。
    //   _prev_summary_membership_state：长度 n_cells，[i] = cluster_idx 或 -1。
    //
    // 通过 `void *` opaque 指针避免在 .h 引入 std::vector / 复杂结构体（与
    // _async_state 同模式）；具体类型在 .cpp 内部 forward-declare 并 lazy alloc。
    void                                     *_summary_state          = nullptr;
    void                                     *_summary_state_snapshot = nullptr;

    // q/r → cell idx 反查 hash（summary pass cube_to_idx 用）。lazy rebuild：
    // 在 run_weather_summary_fronts_pass 内部，发现 _summary_qr_to_idx_size !=
    // n_cells 时清空重建。size 不变（即 cell 拓扑稳定）时直接复用。
    std::unordered_map<int64_t, int>          _summary_qr_to_idx;
    int                                       _summary_qr_to_idx_size = -1;

    // ---- helpers ----
    void _ensure_slot_capacity(Slot &slot, int new_count);
    void _flush_slot_to_map(int comp_id);
};

} // namespace pk

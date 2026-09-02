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

#include <array>
#include <cstdint>
#include <deque>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <string>
#include <vector>

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "components/slot.h"

namespace pk {

struct NativeSliceResult {
    uint32_t status = 0;
    uint32_t work_done = 0;
    uint32_t next_cursor = 0;
    uint32_t dirty_mask = 0;
    uint32_t elapsed_us = 0;
    uint32_t flags = 0;
};

class DCWorldExt : public godot::RefCounted {
    GDCLASS(DCWorldExt, godot::RefCounted);

public:
    DCWorldExt();
    ~DCWorldExt() override;

    // ─── Diag log toggle (Fix #11 second pass, 2026-06-16) ──────────────
    // Mirror of GDScript PKLog.enabled. Pass kernels themselves don't print
    // hot-loop（all hot path are scalar tight loops），but a few startup-time
    // path-decision / commit-diag prints + native fallback warnings respect
    // this flag. Hot kernels never log inside the tight loop regardless.
    void set_diag_logs_enabled(bool v) { _diag_logs_enabled = v; }
    bool get_diag_logs_enabled() const { return _diag_logs_enabled; }

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
    // Returns a value-copy (Godot PackedArray COW) of `_slots[comp_id].arr_*`.
    // The caller is free to mutate the returned array — those mutations
    // never propagate back into `_slots[]`. Use this whenever GDScript
    // needs to read the latest C++-side numerical state (UI, baker,
    // diagnostics, MapData refresh via flush_to_mapdata).
    //
    // On invalid `comp_id` or dtype mismatch: returns an empty array, no error.
    godot::PackedFloat32Array snapshot_f32(int comp_id);
    // B3b：snapshot_i32 / snapshot_u8 — 与 snapshot_f32 形成完整的 Mode-B
    // 只读快照集合。植被动力学 streak 字段（cell.vitality_low/high_streak）走
    // I32 snapshot；后续序列化 / save / overlay 也需要 U8 snapshot 补齐。
    godot::PackedInt32Array   snapshot_i32(int comp_id);
    godot::PackedByteArray    snapshot_u8(int comp_id);

    // ─── Mode-B per-cell read API（plan/3b-single-read-source）─────────
    // 单元素直读：从 _slots[comp_id].arr_*.ptr() 直接索引，无 Variant 装箱、
    // 无 PackedArray 拷贝。供 HexCell facade 21 个 hot getter 切换 read 源
    // （由 GDScript-DCWorld 改读 C++ slot），结构性消除"C++ flush 与
    // GDScript-DCWorld SoA 脱钩"类 bug（典型表现：cell.sea_ice_frac 冻结
    // 在初始日值）。
    //
    // 越界 / dtype 不匹配 / comp_id 非法 → 返回 0；不 push_error
    // （与 GDScript DCWorld.read_f32 严厉报警不同，hot getter 容忍静默 0，
    //  避免每帧 2400 cell × 21 字段量级的错误风暴）。
    float   read_f32(int comp_id, int idx) const;
    int32_t read_i32(int comp_id, int idx) const;
    int     read_u8 (int comp_id, int idx) const; // 返回 int（与 write_u8 对称）

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

    // GDScript 在 bind_map_data 后注入 DCWorld 句柄。native flush 会对比提交前后
    // 的视觉槽，只把真实变化的 cell 传给 dirty mask；`nullptr` 关闭自动 mark。
    void bind_dirty_world(godot::Object *dirty_world);

    // Top-level native orchestration scaffold. These APIs are intentionally
    // coarse-grained: GDScript configures once after bind_map_data(), then a
    // daily tick passes only scalar clock values. Kernels can be fused behind
    // this surface without changing GDScript orchestration again.
    godot::Dictionary configure_native_world(const godot::Dictionary &knobs);
    godot::Dictionary run_native_daily_tick(const godot::Dictionary &tick_knobs);
    godot::Dictionary run_native_daily_slice(const godot::Dictionary &tick_knobs);
    // Coarse-grained native scheduler boundary. Configuration is cold-path;
    // advance_runtime_pulse is the only production bridge call needed to
    // drain cross-domain continuation work for one render frame.
    int configure_runtime_graph(const godot::Dictionary &boot_config);
    int64_t advance_runtime_pulse(int64_t day, double season_phase,
                                  double speed_scale, int budget_us, int flags = 0);
    void flush_runtime_visuals(uint32_t dirty_mask = 0);
    godot::Dictionary get_runtime_perf_snapshot(int detail_level = 0) const;
    godot::Dictionary get_runtime_graph_last_economy_report() const;
    bool is_native_daily_visual_commit_pending() const;
    void complete_native_daily_visual_commit();
    // Compatibility alias for callers predating the full visual-snapshot barrier.
    void complete_native_daily_moisture_commit();
    // ② Native finalizer kernel for the round-complete delta-cap + thermal-init loops.
    godot::Dictionary run_native_daily_finalizer(godot::Dictionary knobs);
    godot::Dictionary run_native_sim_tick(const godot::Dictionary &ctx);
    godot::Dictionary get_native_daily_report() const;
    godot::Dictionary get_native_shadow_diff_report() const;
    godot::Dictionary native_ocean_physical_begin(const godot::Dictionary &ctx);
    godot::Dictionary native_ocean_physical_step(const godot::Dictionary &ctx);
    godot::Dictionary native_ocean_physical_finish(const godot::Dictionary &ctx);
    godot::Dictionary reset_native_ocean_physical_state(godot::String reason);
    godot::Dictionary get_native_ocean_physical_state_report() const;
    godot::Dictionary get_native_ocean_physical_hot_state() const;

    // Native country authority. Only cell.country_slot is mirrored into the
    // DataCore/MapData bridge; identity, technology, treasury, and territory
    // CSR remain native-only.
    godot::Dictionary configure_country(const godot::Dictionary &catalog,
                                        const godot::Dictionary &profile,
                                        int cell_count, int64_t seed);
    godot::Dictionary bootstrap_country(const godot::Dictionary &packet,
                                        const godot::PackedByteArray &is_water);
    godot::Dictionary submit_country_commands(const godot::Dictionary &packed_batch);
    godot::Dictionary run_country_slice(const godot::Dictionary &ctx);
    bool country_should_run(int64_t day_index) const;
    godot::Dictionary get_country_report() const;
    int64_t get_country_state_hash() const;
    godot::Dictionary get_country_cell_summary(int cell_idx) const;
    godot::Dictionary get_country_snapshot(int64_t handle) const;
    godot::Dictionary get_country_treasury_snapshot(int64_t handle) const;
    godot::Dictionary get_country_research_snapshot(int64_t handle) const;
    godot::Dictionary get_country_research_signal_snapshot(int64_t handle) const;
    godot::Dictionary consume_country_visual_era_dirty_slots();
    bool has_completed_country_technology(int64_t handle,
                                          int32_t technology_id) const;
    godot::Dictionary get_country_tax_policy_snapshot(int64_t handle) const;
    godot::Dictionary get_country_cell_tax_policy_snapshot(int cell_idx) const;
    godot::Dictionary get_country_ui_snapshot(int64_t handle,
                                              int section_mask) const;
    godot::Dictionary get_country_fiscal_snapshot(int64_t handle) const;
    godot::Dictionary get_country_trade_snapshot(
        int64_t handle, const godot::String &view = "summary",
        int offset = 0, int limit = 32) const;
    godot::Dictionary poll_country_events(int64_t after_event_id, int limit = 128) const;
    godot::Dictionary reset_country(const godot::String &reason);
    godot::Dictionary begin_country_save(int chunk_bytes = 4 * 1024 * 1024);
    godot::PackedByteArray read_country_save_chunk(int max_bytes = 4 * 1024 * 1024);
    godot::Dictionary end_country_save();
    godot::Dictionary begin_country_restore();
    godot::Dictionary feed_country_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_country_restore();

    // Shared data-oriented Modifier runtime. Four domain stores are isolated;
    // this facade is the only GDScript mutation boundary.
    godot::Dictionary configure_modifiers(const godot::Dictionary &catalog,
                                          int cell_count);
    godot::Dictionary submit_modifier_commands(const godot::Dictionary &packed_batch);
    godot::Dictionary run_modifier_daily(int64_t day_index);
    bool modifier_should_run(int64_t day_index) const;
    godot::Dictionary get_modifier_command_result(int64_t request_id) const;
    godot::Dictionary list_modifiers(int domain, int64_t entity_handle,
                                     const godot::String &stat_key) const;
    godot::Dictionary explain_modifier_stat(int domain, int64_t entity_handle,
                                            int64_t group_handle,
                                            const godot::String &stat_key,
                                            double base_value) const;
    godot::Dictionary get_modifier_report() const;
    godot::Dictionary poll_modifier_events(int64_t after_event_id,
                                           int limit = 128) const;
    double evaluate_modifier_stat(int domain, int64_t entity_handle,
                                  int64_t group_handle,
                                  const godot::String &stat_key,
                                  double base_value) const;
    int64_t register_gameplay_modifier_object(const godot::String &archetype);
    godot::Dictionary unregister_gameplay_modifier_object(int64_t handle,
                                                          int64_t day_index);
    godot::Dictionary set_gameplay_modifier_base(int64_t handle,
                                                 const godot::String &stat_key,
                                                 double value);
    godot::Dictionary get_gameplay_modifier_effective(int64_t handle,
                                                      int64_t group_handle,
                                                      const godot::String &stat_key) const;
    godot::PackedByteArray capture_modifier_domain(int domain) const;
    godot::Dictionary restore_modifier_domain(int domain,
                                              const godot::PackedByteArray &bytes);
    godot::Dictionary clear_modifier_domain(int domain);

    // Generic trigger runtime. It only ingests committed facts/snapshots and
    // emits typed effects; domain stores apply those effects at their own
    // safe boundary.
    godot::Dictionary configure_triggers(const godot::Dictionary &catalog);
    godot::Dictionary submit_trigger_events(const godot::Dictionary &batch);
    godot::Dictionary submit_trigger_snapshots(const godot::Dictionary &batch);
    godot::Dictionary run_trigger_daily(int64_t day_index);
    bool trigger_should_run(int64_t day_index) const;
    godot::Dictionary poll_trigger_effects(int64_t after_effect_id,
                                            int limit = 128) const;
    godot::Dictionary ack_trigger_effects(int64_t up_to_effect_id);
    godot::Dictionary handoff_trigger_effects(int limit = 128);
    godot::Dictionary set_trigger_enabled(const godot::Dictionary &batch);
    godot::Dictionary reconcile_trigger_branch_bindings(const godot::Dictionary &batch);
    godot::Dictionary get_trigger_branch_progress(int64_t branch_handle) const;
    godot::Dictionary get_development_progress(int64_t country_handle,
                                               int32_t era_index) const;
    godot::Dictionary resync_trigger_source(const godot::Dictionary &snapshot);
    godot::Dictionary get_trigger_report() const;
    godot::PackedByteArray capture_trigger_state() const;
    godot::Dictionary restore_trigger_state(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_trigger_state();

    // Generic Effect Runtime. It owns immutable effect programs, active
    // instances, plans and cross-domain ACK state; domain runtimes own all
    // authoritative mutations.
    godot::Dictionary configure_effects(const godot::Dictionary &catalog);
    godot::Dictionary submit_effect_instances(const godot::Dictionary &batch);
    godot::Dictionary retire_effect_instance(int64_t instance_id, int64_t generation,
                                             int64_t effective_day);
    bool effect_instance_fire_acked(int64_t instance_id, int64_t generation) const;
    godot::Dictionary submit_effect_snapshots(const godot::Dictionary &batch);
    godot::Dictionary run_effect_daily(int64_t day_index);
    godot::Dictionary dispatch_effect_native_modifier();
    godot::Dictionary ack_effect_native_modifier();
    godot::Dictionary dispatch_effect_native_country();
    godot::Dictionary ack_effect_native_country();
    godot::Dictionary dispatch_effect_native_economy();
    godot::Dictionary ack_effect_native_economy();
    struct EffectGameplayCommand {
        int32_t action = 0;
        int32_t domain = -1;
        int32_t opcode = 0;
        int64_t effective_day = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int64_t value_i64 = 0;
        std::array<int64_t, 4> payload{};
        uint64_t idempotency_key = 0;
        int64_t request_id = 0;
    };
    // Native gameplay/event Effect ingress. The event journal remains the
    // authority; this queue only preserves the Effect safe-boundary ACK.
    bool submit_effect_gameplay_commands_pod(const EffectGameplayCommand *commands,
                                             size_t count,
                                             std::vector<int64_t> &request_ids,
                                             std::string &error);
    bool effect_gameplay_command_result_pod(int64_t request_id, bool &complete,
                                            bool &ok, std::string &reason) const;
    bool gameplay_effect_should_run(int64_t day_index) const;
    godot::Dictionary run_gameplay_effects(int64_t day_index);
    godot::Dictionary dispatch_effect_native_gameplay();
    godot::Dictionary ack_effect_native_gameplay();
    // Read-only state of native Effect ingress queues.  Save coordination
    // uses this to reject a cross-section snapshot before a domain ACK.
    godot::Dictionary get_effect_native_adapter_report() const;
    bool effect_should_run(int64_t day_index) const;
    godot::Dictionary poll_effect_transactions(int64_t after_transaction_id,
                                               int limit = 128) const;
    godot::Dictionary preflight_effect_transactions(const godot::Dictionary &batch);
    godot::Dictionary commit_effect_transactions(const godot::Dictionary &batch);
    godot::Dictionary ack_effect_transactions(const godot::Dictionary &batch);
    godot::Dictionary explain_effect(int64_t instance_id) const;
    godot::Dictionary get_effect_report() const;
    godot::PackedByteArray capture_effect_state() const;
    godot::Dictionary restore_effect_state(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_effect_state();
    bool commit_canal_effect(uint64_t project_handle,
                             uint32_t project_generation,
                             uint64_t idempotency_key,
                             std::string &error);
    godot::PackedInt32Array consume_canal_visual_dirty_cells();
    godot::Dictionary bind_era_reward_player_country(int64_t country_handle);
    godot::Dictionary get_era_reward_offer();
    godot::Dictionary choose_era_reward(int64_t offer_generation,
                                        int choice_index,
                                        int64_t effective_day);

    // Native ideology authority.  It owns only country-scoped ideology
    // collection/progression state and delegates domain effects elsewhere.
    godot::Dictionary configure_ideologies(const godot::Dictionary &catalog);
    godot::Dictionary submit_ideology_commands(const godot::Dictionary &batch);
    godot::Dictionary poll_ideology_receipts(int64_t after_receipt_id,
                                             int32_t limit) const;
    godot::Dictionary run_ideology_daily(int64_t day_index);
    bool ideology_should_run(int64_t day_index) const;
    godot::Dictionary get_ideology_snapshot(int64_t country_handle) const;
    godot::Dictionary explain_ideology(int64_t country_handle, int32_t ideology_id);
    godot::Dictionary explain_ideologies(
        int64_t country_handle,
        const godot::PackedInt32Array &ideology_ids);
    godot::Dictionary get_ideology_report() const;
    godot::PackedByteArray capture_ideology_state() const;
    godot::Dictionary restore_ideology_state(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_ideology_state();

    // Native-only hot-path helpers. They resolve no strings in the consumer loop.
    float modifier_climate_radiative_target(int cell, float base_value) const;
    double modifier_country_output_factor(int64_t country_handle) const;
    int64_t ensure_modifier_building_handle(int cell, int type_id,
                                            int owner_signature_id);
    double modifier_building_output_factor(int64_t building_handle,
                                           int64_t settlement_cell) const;

    // ─── Native economy runtime / ECONOMY_GRAPH ────────────────────────
    // Economy owns dynamic PopulationCohort pages, local-market matrices,
    // deterministic formula execution and committed publication. It is
    // deliberately independent from the per-cell component slots above.
    godot::Dictionary configure_economy(const godot::Dictionary &catalog,
                                        const godot::Dictionary &profile,
                                        int cell_count,
                                        int64_t seed);
    godot::Dictionary bootstrap_economy(const godot::Dictionary &population_packet,
                                        const godot::Dictionary &market_packet);
    godot::Dictionary submit_economy_commands(const godot::Dictionary &packed_batch);
    godot::Dictionary run_economy_slice(const godot::Dictionary &ctx);
    godot::Dictionary run_economy_slice_compact(const godot::Dictionary &ctx);
    bool economy_should_run(int64_t day_index) const;
    bool economy_deadline_critical(int64_t day_index) const;
    godot::PackedInt32Array get_economy_live_cells();
    godot::Dictionary get_economy_report() const;
    godot::Dictionary get_country_class_opinion_snapshot() const;
    godot::Dictionary get_population_cell_summary(int cell_idx) const;
    godot::Dictionary get_named_settlement_snapshot() const;
    godot::Dictionary get_settlement_delta(int64_t since_revision) const;
    godot::Dictionary get_population_cell_snapshot(
        int cell_idx, bool include_details = true) const;
    godot::Dictionary get_market_cell_snapshot(int cell_idx) const;
    godot::Dictionary explain_cohort_satisfaction(int64_t cohort_handle) const;
    godot::Dictionary get_cell_satisfaction_attractiveness(int cell_idx) const;
    godot::Dictionary get_trade_orders_for_cell(int cell_idx, int offset = 0,
                                                int limit = 64) const;
    godot::Dictionary capture_economy_trade_topology(
        const godot::PackedInt32Array &neighbor_indices,
        const godot::PackedByteArray &terrain,
        const godot::PackedByteArray &trade_passable_lut,
        const godot::PackedInt32Array &trade_move_cost_lut,
        int64_t generation = 0,
        const godot::PackedByteArray &landform = godot::PackedByteArray(),
        const godot::PackedByteArray &has_river = godot::PackedByteArray());
    godot::Dictionary capture_economy_trade_visibility(
        const godot::PackedByteArray &visible, bool fog_solved);
    godot::Dictionary get_building_cell_snapshot(int cell_idx) const;
    godot::Dictionary get_building_visual_snapshot(
        const godot::PackedInt32Array &requested_cells) const;
    godot::Dictionary consume_building_visual_dirty_cells();
    // Numeric 2.5D building chunk baker. The Godot side supplies only flat
    // chunk-local PackedArrays; C++ returns MultiMesh-ready 16-float buffers.
    godot::Dictionary bake_building_visual_chunk(godot::Dictionary knobs);
    godot::Dictionary get_treasury_construction_quotes(
        int64_t country_handle, int cell_idx,
        const godot::PackedInt32Array &type_ids) const;
    godot::Dictionary get_construction_command_receipts(
        int64_t after_receipt_id, int limit = 64) const;
    godot::Dictionary get_canal_route_quote(
        int64_t country_handle, int start_cell, int end_cell,
        const godot::PackedInt32Array &waypoints);
    godot::Dictionary get_canal_route_quote_detail(
        int64_t country_handle, int64_t quote_token) const;
    godot::Dictionary queue_canal_construction(
        int64_t country_handle, int64_t quote_token,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary get_canal_construction_receipts(
        int64_t country_handle, int64_t after_receipt_id,
        int limit = 64) const;
    godot::Dictionary get_family_cell_snapshot(int cell_idx, int offset = 0,
                                                int limit = 64) const;
    godot::Dictionary get_family_snapshot(int64_t family_handle) const;
    godot::Dictionary get_family_traits(int64_t family_handle) const;
    godot::Dictionary get_family_branches(int64_t family_handle, int offset = 0,
                                           int limit = 64) const;
    godot::Dictionary get_family_colonization_quotes(
        int64_t country_handle, int target_cell, int64_t family_filter = 0,
        int source_filter = -1, int offset = 0, int limit = 64);
    godot::Dictionary get_family_colonization_quote_detail(
        int64_t quote_token, int64_t population = -1) const;
    godot::Dictionary start_family_colonization(
        int64_t country_handle, int64_t family_handle, int source_cell,
        int target_cell, int64_t population, int64_t quote_token,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary cancel_family_colonization(
        int64_t country_handle, int64_t expedition_handle,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary get_family_expeditions(
        int64_t country_handle, int offset = 0, int limit = 64) const;
    godot::Dictionary get_family_expedition_snapshot(
        int64_t country_handle, int64_t expedition_handle) const;
    godot::Dictionary get_family_colonization_receipts(
        int64_t country_handle, int64_t after_receipt_id,
        int limit = 64) const;
    godot::Dictionary get_family_branch_effects(int64_t family_handle,
                                                int cell_idx) const;
    godot::Dictionary submit_family_trait_commands(
        const godot::Dictionary &packed_batch);
    godot::Dictionary get_family_industries(int64_t family_handle,
                                            int offset = 0,
                                            int limit = 64) const;
    godot::Dictionary get_family_notable_people(int64_t family_handle,
                                                int offset = 0,
                                                int limit = 64) const;
    godot::Dictionary get_notable_person_snapshot(int64_t person_handle) const;
    godot::Dictionary get_notable_person_needs(int64_t person_handle,
                                               int offset = 0,
                                               int limit = 32) const;
    godot::Dictionary get_building_notable_people(int64_t building_handle,
                                                  int offset = 0,
                                                  int limit = 64) const;
    godot::Dictionary run_economy_fixed_math_probe(const godot::Dictionary &vectors) const;
    godot::Dictionary run_economy_production_climate_math_probe(
        const godot::Dictionary &vectors) const;
    int64_t get_economy_state_hash() const;
    godot::Dictionary inject_economy_cadence_timing(double market_cycle_ms,
                                                    double slow_cycle_ms,
                                                    double investment_cycle_ms = -1.0);
    godot::Dictionary reset_economy(const godot::String &reason);
    godot::Dictionary start_economy_csv_recording(const godot::Dictionary &config);
    godot::Dictionary request_stop_economy_csv_recording();
    godot::Dictionary get_economy_csv_recording_status() const;
    godot::Dictionary begin_economy_save(int chunk_bytes = 4 * 1024 * 1024);
    godot::PackedByteArray read_economy_save_chunk(int max_bytes = 4 * 1024 * 1024);
    godot::Dictionary end_economy_save();
    godot::Dictionary begin_economy_restore();
    godot::Dictionary feed_economy_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_economy_restore();
    godot::Dictionary get_economy_event_schema() const;
    godot::Dictionary set_economy_trace_filter(const godot::Dictionary &filter);
    godot::Dictionary set_economy_inspector_trace_cell(int cell_idx);
    godot::Dictionary poll_economy_events(const godot::Dictionary &opts) const;
    godot::Dictionary ack_economy_events(godot::StringName consumer_id,
                                         int64_t up_to_event_id);
    godot::Dictionary get_economy_trace_report() const;
    godot::Dictionary begin_economy_event_archive(int chunk_bytes = 4 * 1024 * 1024);
    godot::PackedByteArray read_economy_event_archive_chunk(
        int max_bytes = 4 * 1024 * 1024);
    godot::Dictionary end_economy_event_archive();

    // ─── Gameplay event bus（2026-06-26）────────────────────────────────
    // 通用、可持久化/可回放的 gameplay event log。C++ pass 和 GDScript 都通过
    // 同一 columnar schema 发布事件；消费者用独立 cursor poll/ack，避免视觉、
    // UI、debug 互相抢事件。事件日志只保存 POD/packed payload，不持有 Godot
    // Object 引用，方便 save/replay。
    godot::Dictionary get_gameplay_event_schema() const;
    godot::Dictionary publish_gameplay_events(godot::Dictionary batch);
    godot::Dictionary poll_gameplay_events(godot::Dictionary opts);
    godot::Dictionary ack_gameplay_events(godot::StringName consumer_id, int64_t up_to_event_id);
    godot::Dictionary replay_gameplay_events(godot::Dictionary opts) const;
    godot::Dictionary snapshot_gameplay_event_journal(godot::Dictionary opts) const;
    godot::Dictionary restore_gameplay_event_journal(godot::Dictionary snapshot);
    godot::Dictionary clear_gameplay_events(godot::Dictionary opts);
    godot::Dictionary get_gameplay_event_bus_report() const;

    godot::Dictionary run_native_world_generate_base_pass(int seed,
                                                          const godot::Dictionary &cfg,
                                                          const godot::Dictionary &profile);
    godot::Dictionary run_native_world_generate_post_base_pass(int seed,
                                                               const godot::Dictionary &cfg,
                                                               const godot::Dictionary &profile,
                                                               const godot::Dictionary &input);
    // dots-total-cpp step4（2026-06-25）：base + post_base 融合单次驱动。
    // 在 C++ 进程内先跑 base、再用其结果跑 post_base，base 的 10×n_cells SoA bundle
    // 留在 C++、不出语言边界（原先 base 结果要 C++→GDScript 校验→再回 post_base）。
    // 返回 post_base 最终 bundle（合并 base 诊断键 base_water_count/base_land_count/
    // base_native_ms/native_algorithm 供 GDScript 打印）。base 失败 → 直接回传 base 结果
    // （rc/fallback 透传，caller 据此中止）。
    godot::Dictionary run_native_world_generate_full_pass(int seed,
                                                          const godot::Dictionary &cfg,
                                                          const godot::Dictionary &profile);
    // PKMAP 旁路：从冻结合成结果填 `_gen_river_*`，邻居用 index_for_qr 现场重建。
    // 跳过 post_base 读包时必须调用，否则 run_bake_river_sdf_pass 无河。
    godot::Dictionary restuff_generation_river_cache(const godot::Dictionary &input);
    // Static, generation-only research evidence. Input/output are packed arrays;
    // no MapData/Object access or per-cell Variant allocation occurs in the loop.
    godot::Dictionary run_research_signal_generation_pass(const godot::Dictionary &knobs);
    // Landmass/province topology, origin-habitat fill + niche pack, and daily occupancy.
    // Knobs in / packed arrays out; occupancy is the persisted presence bitset.
    godot::Dictionary run_bio_province_pass(const godot::Dictionary &knobs);
    godot::Dictionary run_bio_seed_pass(const godot::Dictionary &knobs);
    godot::Dictionary run_bio_bootstrap_pass(const godot::Dictionary &knobs);
    godot::Dictionary configure_bio_occupancy(const godot::Dictionary &config);
    godot::Dictionary run_bio_occupancy_pass(const godot::Dictionary &knobs);
    // Deterministic cursor continuation.  The opaque state is transient and
    // is published only after the final fixed cell range completes.
    godot::Dictionary run_bio_occupancy_slice(const godot::Dictionary &knobs);
    godot::Dictionary configure_vision_research(const godot::Dictionary &config);
    godot::Dictionary run_vision_research_pass(const godot::Dictionary &knobs);
    godot::Dictionary filter_bio_research_observations(
        const godot::PackedInt32Array &cells,
        const godot::PackedInt32Array &signals) const;
    godot::Dictionary run_native_world_generate_pass(int seed,
                                                     const godot::Dictionary &cfg,
                                                     const godot::Dictionary &profile);
    godot::Array get_native_fronts_snapshot() const;
    godot::Dictionary get_native_fronts_snapshot_packed() const;
    godot::Dictionary get_native_dirty_report() const;
    godot::Dictionary start_native_generation(int seed,
                                              const godot::Dictionary &cfg,
                                              const godot::Dictionary &profile);
    godot::Dictionary run_native_generation_slice(const godot::Dictionary &budget);
    godot::Dictionary finish_native_generation();

    // ─── CoW flush / refresh (performance-charter §11.2) ─────────────────
    // After any C++ pass calls ptrw() on a slot, CoW detaches the buffer.
    // flush_slots_to_map() pushes the (possibly-detached) C++ buffer back
    // to the GDScript MapData property via obj->set() — O(1) ref-swap each.
    // refresh_slots_from_map() does the reverse: pulls GDScript-side
    // arrays back into the C++ slots (needed when GDScript code writes
    // map.*_arr between C++ passes).
    void flush_slots_to_map();
    void flush_slots_to_map_keys(const godot::PackedStringArray &slot_names);
    void refresh_slots_from_map();
    void refresh_slots_from_map_keys(const godot::PackedStringArray &slot_names);
    // 把 native flush 累积的精确 dirty indices 一次性 emit 到 _dirty_world。
    // 保留旧方法名以兼容 GDScript 调用点；多次调用幂等。
    void flush_pending_mark_dirty_all();

    // ─── Archetype system (mirrors I2.B in GDScript) ─────────────────────
    int  create_archetype(const godot::StringName &name, const godot::Array &comp_ids);
    void assign_archetype(int idx, int arch_id);
    int  archetype_count() const { return _archetypes.size(); }
    godot::PackedInt32Array entity_archetype_array() const { return _entity_archetype; }

    // ─── Hot-loop entry points (stubs; filled in I3.B/C) ─────────────────
    // Returning -1.0 indicates "not implemented yet, fall back to GDScript".
    // GDScript-side caller checks `< 0` and routes to the legacy path.
    double run_climate_pass_a(const godot::Dictionary &cp_struct, double phase, double season_phase);

    // Returns a pointer to the per-cell annual-mean insolation cache (size n),
    // rebuilding it iff the (n, lat-array, axial_tilt, daylen) fingerprint changed.
    // Shared by run_climate_pass_a and run_climate_pass_a_thread. Bit-equal to the
    // inline dc_insolation_annual_mean(dc_clamp01f(lat[i]), ...) it replaces.
    const float *ensure_insol_annual_mean_cache(const float *lat_ptr, int n,
                                                float axial_tilt_deg, float daylen_amp);

    // [Phase C.3c] climate_pass_a 的 WorkerThreadPool 并行变体。
    // 主循环纯 cell-local map（无 race），按 cell range 拆 n_tasks 段并行；
    // n_tasks=0 时自适应（ceil(n/1024) 截 [1,16]，与 ocean_water/land_thread 一致）。
    // 算法与 run_climate_pass_a 严格 1:1（共用 prelude 与 main loop body）；返回值同语义。
    double run_climate_pass_a_thread(const godot::Dictionary &cp_struct, double phase, double season_phase, int n_tasks);

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
    // 独立全场 ψ 推进 pass（每 weather 轮一次、不切片、半拉格朗日平流）。让天气随风成片移动。
    double run_synoptic_advance_pass(const godot::Dictionary &knobs);
    godot::Dictionary run_weather_field_commit_pass(godot::Dictionary knobs);

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
    //                ↑ 必填！runtime baseline 非有限值时的兜底值。
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

    // Wind heat transport, split to match ClimateDailySystem ordering:
    // air mass writes only cell_air_mass_temp_anomaly; surface reads that
    // anomaly and is the sole wind-air stage that injects heat into cell_temp.
    bool supports_wind_air_slot_temp() { return true; }
    double run_wind_air_mass_pass(godot::Dictionary knobs);
    double run_wind_surface_pass(godot::Dictionary knobs);

    // plan/sim-2ms-simd-dirty-budget — SIMD/Thread variants for ocean passes.
    //
    // run_ocean_water_pass_simd / run_ocean_land_pass_simd:
    //   与原 scalar 版同签名 / 同输出语义；内部走 water-cell / land-cell 预筛
    //   + 直线 hot kernel，消除主循环外层 if(IW[i]==0|!=0) 分支让编译器自由
    //   auto-vectorize。CoW fix（anomaly_out / anomaly_inout 仍走 duplicate）
    //   保持不变。ulp ≤ 4 容差（charter §risk=B 已批）。
    //   仅在 ClimateProfile.use_gdext_ocean_water_simd / use_gdext_ocean_land_simd
    //   = true 时由调用方派发。
    //
    // run_ocean_water_pass_thread / run_ocean_land_pass_thread:
    //   预筛 idx 按 n_tasks 切 WorkerThreadPool；n_water / n_land < 256 时
    //   降级单线程；wtp == nullptr 时 in-thread fallback。n_tasks <= 0 时
    //   按 ~1024 cells/task 自适应（cap 至 16）。
    //   仅在 ClimateProfile.use_gdext_thread_fallback = true 且 SIMD 不达
    //   预算时由调用方派发。
    double run_ocean_water_pass_simd  (godot::Dictionary knobs);
    double run_ocean_water_pass_thread(godot::Dictionary knobs, int n_tasks);
    double run_ocean_land_pass_simd   (godot::Dictionary knobs);
    double run_ocean_land_pass_thread (godot::Dictionary knobs, int n_tasks);

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
    //            season_phase (float, orbital/year phase only)
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
    //       cell_pos_x, cell_pos_y, cell_insolation_dev
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

    // plan/sim-2ms-simd-dirty-budget — SIMD/Thread variants for hot pass-B.
    //
    // run_climate_pass_b_simd:
    //   与 run_climate_pass_b 同签名 / 同输出语义；内部走 land-cell 预筛 +
    //   直线 hot kernel（albedo / coastal / landform / write）+ scalar
    //   rain-shadow 子段。MSVC /O2 /arch:AVX2 在直线 land-only 循环上能自
    //   动向量化；显式 AVX2 8-lane block 包在 PK_HAVE_AVX2 内对最 SIMD-
    //   friendly 段（albedo）做强制向量化。
    //   ulp 容差：≤ 4（plan §验收 §B）。
    //   仅在 ClimateProfile.use_gdext_pass_b_simd = true 时由调用方派发。
    //
    // run_climate_pass_b_thread:
    //   land-cell 主段按 n_tasks 切 WorkerThreadPool；rain-shadow 子段仍
    //   单线程跑（其内含的串行 probe + 邻居最佳方向 search 无可分发性）。
    //   仅在 ClimateProfile.use_gdext_thread_fallback = true 且 SIMD 路径
    //   未达预算时由调用方派发；wtp == nullptr 时 in-thread fallback。
    double run_climate_pass_b_simd  (const godot::Dictionary &knobs);
    double run_climate_pass_b_thread(const godot::Dictionary &knobs, int n_tasks);


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
    //       + 入参 PackedArray（含 insolation_now_arr 当前辐照）
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

    // [Phase C.3d] sea_ice 并行变体
    //   行为 = run_sea_ice_daily_pass，但 Phase A (cold_neighbor 快照) +
    //   Phase B (主循环 + flip emit) 都走 WorkerThreadPool 并行。
    //   emit lists (flip_to_ice / flip_to_base / flip_to_base_terrain) 通过
    //   thread-local Emit + 串行 reduce (按 task_idx 升序) 保持与 scalar
    //   bit-equal（任务内部 cell idx 升序 + 任务顺序合并 = 整体升序）。
    //   counters (water_count / flipped_count) 同模式 reduce。
    //   仅在 ClimateProfile.use_gdext_thread_fallback = true 时调用。
    double run_sea_ice_daily_pass_thread(godot::Dictionary knobs, float season_phase, int n_tasks);

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
    double run_transpiration_pass(godot::Dictionary knobs);

    // Runtime hydrology: daily local water balance + parent-graph routing.
    // Optional knob: neighbor_indices (n_cells * 6) lets river discharge maintain
    // narrow river/riparian moisture floors and boost adjacent soil/water balance.
    godot::Dictionary run_runtime_hydrology_pass(const godot::Dictionary &knobs);

    // ─── Natural resources（economy.resources）──────────────────────────
    //   GDScript wrapper：MapGenerator.run_natural_resource_pass_native
    //   System：NaturalResourceDailySystem（每日，priority 排在 climate 之后）
    //
    //   默认资源使用半隐式（IMEX）常数生产 + 线性损失模板：
    //     tn            = clamp((temp - temp_lo[r]) / (temp_hi[r] - temp_lo[r]), 0, 1)
    //     m             = moisture
    //     gen_climate   = gen_base[r]   + gen_temp[r]*tn   + gen_moisture[r]*m
    //     decay_climate = decay_base[r] + decay_temp[r]*tn + decay_moisture[r]*m
    //     P             = gen_climate + gen_self[r] - decay_climate
    //     L             = max(0, decay_self[r])
    //     reserve'      = max(0, (reserve + P) / (1 + L))
    //   ecology_capacity[r] > 0 的种群资源走 Beverton-Holt 密度增长：适生度缩放
    //   承载量/增长/迁入，超过承载量时自然下降，气候压力增加比例死亡。多日 stride
    //   逐日迭代非线性式；extra_change 始终只应用一次。
    //
    //   knobs（GDScript 一次打包，ResourceProfileRegistry.build_pass_knobs + n_cells）：
    //     标量： n_cells (int), resource_count (int)
    //     PackedStringArray： reserve_slots（C++ slot 名，长度 resource_count）
    //     PackedFloat32Array（长度 resource_count，按资源索引对齐）：
    //       habitat_modes, temp_lo, temp_hi,
    //       gen_base/gen_temp/gen_moisture/gen_self,
    //       decay_base/decay_temp/decay_moisture/decay_self,
    //       ecology_capacity/ecology_growth_rate/ecology_immigration/
    //       ecology_stress_mortality_rate
    //
    //   读：cell_temp / cell_moisture / cell_is_water
    //   写：每个 reserve_slots[r]（clamp 后 flush 回 MapData）
    //
    //   返回 Dictionary：{ done, path, published_to_slot, published_slots,
    //     resource_count, n_cells, total_delta, native_ms, compute_ms,
    //     fallback_reason（失败时）}。
    godot::Dictionary run_natural_resource_pass(const godot::Dictionary &knobs);
    godot::Dictionary get_natural_resource_regen_factors(
        const godot::PackedStringArray &resource_ids, int32_t n_cells);

    // ─── DOTS-Final-Push（plan/dots-final-push 任务 2）：albedo pass ─────
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_albedo_pass
    //   ClimateProfile flag：use_gdext_albedo
    //   性能目标：~3.6ms → < 0.5ms
    //
    //   算法（与 GDScript 1:1 镜像）：
    //     for each cell i:
    //       if is_water[i]: continue
    //       alb = albedo_table[veg[i]]
    //       if cover[i] == CV.SNOW (=1) || cover[i] == CV.GLACIER (=2):
    //         alb = max(alb, 0.75)
    //       dt = (reference_albedo - alb) * albedo_temp_gain
    //       temp[i] = clamp(temp[i] + dt, 0, 1)
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            reference_albedo (float)         — ClimateProfile.reference_albedo
    //            albedo_temp_gain (float)          — ClimateProfile.albedo_temp_gain
    //            snow_cover_albedo (float, =0.75) — SNOW/GLACIER cover 的反照率下限
    //            cover_snow_id (int, =1)          — CoverType.CV.SNOW 枚举值
    //            cover_glacier_id (int, =2)       — CoverType.CV.GLACIER 枚举值
    //     PackedArray（zero-copy read）：
    //            albedo_table : PackedFloat32Array — 按 VegetationType.VEG enum 顺序
    //
    //   读：cell_is_water (U8) / cell_vegetation (U8) / cell_cover (U8) / cell_temp (F32)
    //   写：cell_temp (F32)
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback。
    double run_albedo_pass(const godot::Dictionary &knobs);

    // [Phase C.3c] albedo 的 WorkerThreadPool 并行变体。
    // 主循环纯 cell-local map（IW 跳水 + 自身写 T[i]），按 cell range 拆 n_tasks 段并行；
    // n_tasks=0 时自适应。算法与 run_albedo_pass 严格 1:1。
    double run_albedo_pass_thread(const godot::Dictionary &knobs, int n_tasks);

    // ─── DOTS-Final-Push（plan/dots-final-push 任务 3）：vegetation dynamics ─
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_vegetation_dynamics
    //   ClimateProfile flag：use_gdext_vegetation_dynamics
    //   性能目标：~9.2ms → < 1.0ms
    //
    //   算法分工（与 GDScript 1:1 镜像，但演替触发由 GDScript 后处理）：
    //     C++ 主循环（每 cell 独立）：
    //       if is_water[i]: continue
    //       compat = exp(-0.5 * ((t - ideal_t[v])/tol_t[v])² + ((m - ideal_m[v])/tol_m[v])²)
    //       dv = 0
    //       if v != NONE:
    //         if compat >= 0.6: dv = (compat - 0.5) * 2 * rate
    //         elif compat <= 0.4: dv = -(0.5 - compat) * 2 * rate * harshness
    //       wt = (weather_field_init[i] != 0) ? weather_type[i] : WT.CLEAR
    //       wi = (weather_field_init[i] != 0) ? weather_intensity[i] : 0
    //       base_pen = weather_penalty[wt]
    //       resist  = resistance_lut[v * n_wt + wt]
    //       dv -= base_pen * wi * (1 - resist)
    //       vitality[i] = clamp(vitality[i] + dv * scale, 0, 1)
    //       streak update（sticky in [low, high]）
    //       if low_streak[i] >= degrade_days && next_down[v] != v：候选 succession
    //       elif high_streak[i] >= upgrade_days && next_up[v] != v：候选 succession
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            day_scale (float)                 — max(day_scale, 1.0)
    //            streak_days (int)                 — round(scale)
    //            vitality_change_rate (float)
    //            compat_harshness (float)
    //            plant_water_balance_weight / plant_soil_buffer_weight (float)
    //            plant_drought_penalty / succession_min_compat_gain (float)
    //            low_threshold (float)
    //            high_threshold (float)
    //            succession_degrade_days (int)
    //            succession_upgrade_days (int)
    //            n_wt (int)                         — WeatherType.WT.size()
    //            wt_clear_id (int)                  — WeatherType.WT.CLEAR 枚举值
    //            veg_none_id (int)                  — VegetationType.VEG.NONE 枚举值
    //     PackedArray（zero-copy read）：
    //            ideal_temp_table  : PackedFloat32Array  (n_veg)
    //            ideal_moist_table : PackedFloat32Array  (n_veg)
    //            temp_tol_table    : PackedFloat32Array  (n_veg)
    //            moist_tol_table   : PackedFloat32Array  (n_veg)
    //            weather_penalty_table : PackedFloat32Array  (n_wt)
    //            resistance_table  : PackedFloat32Array  (n_veg * n_wt) — sparse 0.0 default
    //            next_up_table     : PackedByteArray     (n_veg)         — VEG.next_richer
    //            next_down_table   : PackedByteArray     (n_veg)         — VEG.next_harsher
	//     PackedArray（in/out — 仅老 caller 路径需要；B3b 后这 3 个字段已下沉到
	//     SoA schema：cell.vegetation_vitality / vitality_low_streak /
	//     vitality_high_streak。stage_b_pass 走 use_soa=true 时直读 _slots ptrw。
	//     该独立 wrapper 保留 PackedArray in/out 以保持向后兼容）：
	//            vitality_arr      : PackedFloat32Array  (n_cells)
	//            low_streak_arr    : PackedInt32Array    (n_cells)
	//            high_streak_arr   : PackedInt32Array    (n_cells)
	//
	//   读：cell_is_water (U8) / cell_vegetation (U8) / cell_temp_30d (F32) /
	//       cell_moisture / water_balance_30d / soil_moisture (F32) / cell_weather_type (U8) /
	//       cell_weather_intensity (F32) / cell_weather_field_init (U8)
	//   写：vitality_arr / low_streak_arr / high_streak_arr (in/out) /
	//       cell_vegetation_growth_pressure (target - previous vitality)
    //
    //   knobs 输出回填（C++ 写进 knobs）：
    //     succession_indices : PackedInt32Array  — 触发演替的 cell idx
    //     succession_to_veg  : PackedByteArray   — 与 indices 同长，目标新 veg id
    //                          上家：next_up[v]； 下家：next_down[v]（区分由 caller 看 streak 判断）
    //     stat_succession_count : int (写到 knobs)
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback。
    //   knobs 走 by-value（非 const&），让 C++ 端能写回 succession lists（与 sea_ice 同模式）。
    double run_vegetation_dynamics_pass(godot::Dictionary knobs);

    // [Phase C.3d] vegetation_dynamics 并行变体
    //   行为 = run_vegetation_dynamics_pass，主循环走 WorkerThreadPool 并行。
    //   thread-local emit (succession_indices / succession_to_veg) 通过
    //   Emit + 串行 reduce 保持 bit-equal。
    //   仅在 ClimateProfile.use_gdext_thread_fallback = true 时调用。
    double run_vegetation_dynamics_pass_thread(godot::Dictionary knobs, int n_tasks);

    // ─── DOTS-Final-Push（plan/dots-final-push 任务 4）：climate feedback ─
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_weather_to_map_feedback_pass
    //   ClimateProfile flag：use_gdext_climate_feedback
    //   性能目标：~6.1ms → < 0.5ms
    //
    //   算法（与 GDScript 1:1 镜像，每日小权重累加 ≤ 0.5%）：
    //     for each cell i:
    //       if is_water[i]: continue
    //       if ocean_drift_gain > 0:
    //         sum_an + n_water = sum/count(nb_water_anomaly)
    //         if n_water > 0 && |avg_an| > 0.005:
    //           coastal_ratio = clamp(n_water/6, 0, 1)
    //           d_base = clamp(ocean_drift_gain * avg_an * coastal_ratio * scale, -clamp, clamp)
    //           base_moisture[i] = clamp(base_moisture[i] + d_base, 0, 1)
    //       wt = init ? weather_type[i] : WT.CLEAR
    //       wi = init ? weather_intensity[i] : 0
    //       if wi < 0.01: continue
    //       precip = match(wt) {RAIN: wi, STORM: 0.8wi, MONSOON: 1.2wi,
    //                          BLIZZARD: 0.3wi, DROUGHT: -0.6wi, HEATWAVE: -0.4wi, _: 0}
    //       d_soil = clamp(soil_gain * precip * scale, -clamp, clamp)
    //       soil_moisture[i] = clamp(soil_moisture[i] + d_soil, -0.5, 0.5)
    //       d_veg = clamp(veg_gain * precip * scale, -clamp, clamp)
    //       vg_pressure[i] = clamp(vg_pressure[i] + d_veg, -0.5, 0.5)
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            soil_gain (float)
    //            veg_gain (float)
    //            write_weather_veg_pressure (bool, optional, default true)
    //            scale (float)              — max(day_scale, 1.0)
    //            per_day_clamp (float)      — feedback_per_day_clamp * scale
    //            ocean_drift_gain (float)   — 0 表示禁用 ocean→base 漂移
    //            wt_clear_id (int)          — WeatherType.WT.CLEAR
    //            wt_rain_id / wt_storm_id / wt_monsoon_id / wt_blizzard_id /
    //            wt_drought_id / wt_heatwave_id (int) — 6 个 WT 枚举值
	//     PackedArray（zero-copy read — 仅老 caller 路径需要；B3b 后已下沉到 SoA：
	//     cell.temperature_transport_anomaly。stage_b_pass 走 use_soa=true 时直读 _slots）：
	//            neighbor_indices       : PackedInt32Array    (n_cells * 6)
	//            temp_transport_anomaly : PackedFloat32Array  (n_cells)
	//                ↑ 与 climate_pass_b 同字段
	//     PackedArray（in/out — 仅老 caller 路径需要；B3b 后这 2 个字段已下沉到 SoA：
	//     cell.soil_moisture / cell.vegetation_growth_pressure。stage_b_pass 走
	//     use_soa=true 时直读 _slots ptrw。该独立 wrapper 保留 PackedArray in/out 以保持向后兼容）：
	//            soil_moisture_arr    : PackedFloat32Array  (n_cells)
	//            veg_growth_pressure_arr : PackedFloat32Array (n_cells)
    //
    //   读：cell_is_water (U8) / cell_weather_type (U8) /
    //       cell_weather_intensity (F32) / cell_weather_field_init (U8) /
    //       cell_base_moisture (F32) — direct write
    //       + 入参 PackedArray
    //   写：cell_base_moisture (F32) / soil_moisture_arr / veg_growth_pressure_arr (in/out)
    //       write_weather_veg_pressure=false 时保留 vegetation_dynamics 当 tick 写入的
    //       target-vitality 生态压力信号。
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback。
    double run_climate_feedback_pass(godot::Dictionary knobs);

    // [Phase C.3c] climate_feedback 的 WorkerThreadPool 并行变体。
    // 主循环：read NB+TTA+IW+WTT+WTI+WTIN，仅 write self（BM[i]+SOIL[i]+VG[i]），
    // gather neighbor 但不 scatter，无 race；按 cell range 拆 n_tasks 段并行；
    // n_tasks=0 时自适应。算法与 run_climate_feedback_pass 严格 1:1。
    double run_climate_feedback_pass_thread(godot::Dictionary knobs, int n_tasks);

    // ─── 方案 B：stage_b 三段合并（plan/stage-b-combine） ──────────────────
    //   GDScript 源：scripts/geography/map_generator.gd::refresh_daily_stage_b
    //   ClimateProfile flag：use_gdext_stage_b_combined
    //   性能目标：stage_b 累加 6–15ms → ≤ 1.5ms（消除 GDScript 端 3 次 pack/unpack
    //   围栏：vit/lo/hi、soil/vg/tta、albedo_table/8 LUT 一次性入参）
    //
	//   行为 = run_albedo_pass + run_vegetation_dynamics_pass +
	//         run_climate_feedback_pass 的顺序内联，**算法完全 1:1 复制**：
	//     ① albedo（写 cell_temp）→ 仅当 run_albedo=true
	//     ② veg_dyn（读最新 cell_temp + 写 vitality/streak/演替候选）→ 仅当 run_veg_dyn=true
	//     ③ feedback（写 cell_base_moisture / soil/vg in/out）→ 仅当 run_feedback=true
	//   cross-pass 依赖：albedo 写 cell_temp、veg_dyn 读 cell_temp，合并版本里
	//   两段共享同一份 SoA ptrw，**无需中间 _flush_slot_to_map**（对比现状 GDScript
	//   三段间需要 _flush_slot_to_map → MapData → refresh_slots_from_map 来回拷贝）。
	//
	//   B3b 数据所有权下沉（plan/b3b-data-ownership-lowering）：
	//     新增 `use_soa` 开关（bool，默认 false 兼容旧路径）。当 use_soa=true 时：
	//       - vit/streak/soil/vg/tta 五字段全部走 _slots[sid].arr_* ptrw 直读直写
	//       - knobs 中 vitality_arr / low_streak_arr / high_streak_arr /
	//         soil_moisture_arr / veg_growth_pressure_arr / temp_transport_anomaly
	//         可省略（即使存在也不读不写）
	//       - 末尾批量 flush 6 个 slot（vit/low_streak/high_streak/soil/vg）回 MapData
	//       - 消除 GDScript 端 6 段 pack/unpack hot loop（实测 ~6.5ms wall 节省）
    //
    //   入参 `knobs` Dictionary（合并版本，knobs key 命名空间用前缀避免冲突）：
	//     总开关：
	//       n_cells (int)
	//       run_albedo / run_veg_dyn / run_feedback (bool)  — stride 语义保留
	//       use_soa (bool, optional, default false)         — B3b 数据所有权下沉开关
    //
    //     albedo 段（仅 run_albedo=true 时读，其它情况可省略）：
    //       reference_albedo / albedo_temp_gain (float)
    //       snow_cover_albedo (float, =0.75)
    //       cover_snow_id / cover_glacier_id (int, =1, 2)
    //       albedo_table : PackedFloat32Array (n_veg)
    //
    //     veg_dyn 段（仅 run_veg_dyn=true 时读）：
    //       day_scale (float)
    //       streak_days (int)
    //       vitality_change_rate / compat_harshness (float)
    //       plant_water_balance_weight / plant_soil_buffer_weight (float)
    //       plant_drought_penalty / succession_min_compat_gain (float)
    //       low_threshold / high_threshold (float)
    //       succession_degrade_days / succession_upgrade_days (int)
    //       n_wt (int)
    //       wt_clear_id / veg_none_id (int)
    //       ideal_temp_table / ideal_moist_table / temp_tol_table /
    //       moist_tol_table : PackedFloat32Array (n_veg)
    //       weather_penalty_table : PackedFloat32Array (n_wt)
    //       resistance_table : PackedFloat32Array (n_veg * n_wt)
	//       next_up_table / next_down_table : PackedByteArray (n_veg)
	//       vitality_arr : PackedFloat32Array (n_cells, in/out) — 仅 use_soa=false 时必填
	//       low_streak_arr / high_streak_arr : PackedInt32Array (n_cells, in/out) — 仅 use_soa=false 时必填
    //
    //     feedback 段（仅 run_feedback=true 时读）：
    //       soil_gain / veg_gain / scale / per_day_clamp / ocean_drift_gain (float)
    //       write_weather_veg_pressure (bool, optional, default true)
    //       wt_rain_id / wt_storm_id / wt_monsoon_id /
    //       wt_blizzard_id / wt_drought_id / wt_heatwave_id (int)
	//       neighbor_indices : PackedInt32Array (n_cells * 6)
	//       temp_transport_anomaly : PackedFloat32Array (n_cells) — 仅 use_soa=false 时必填
	//       soil_moisture_arr : PackedFloat32Array (n_cells, in/out) — 仅 use_soa=false 时必填
	//       veg_growth_pressure_arr : PackedFloat32Array (n_cells, in/out) — 仅 use_soa=false 时必填
    //
    //   读：cell_is_water / cell_vegetation / cell_cover / cell_temp /
    //       cell_moisture / cell_weather_type / cell_weather_intensity /
    //       cell_weather_field_init / cell_base_moisture
    //   写：cell_temp（albedo）、cell_base_moisture（feedback）；in/out arrays
    //
	//   knobs 输出回填（C++ 写进 knobs）：
	//     albedo_ms / veg_dyn_ms / feedback_ms (float) — 每段单独 ms，供 caller 计时
	//     succession_indices : PackedInt32Array
	//     succession_to_veg  : PackedByteArray
	//     stat_succession_count : int
	//     vitality_arr / low_streak_arr / high_streak_arr (in/out 写回) — 仅 use_soa=false
	//     soil_moisture_arr / veg_growth_pressure_arr (in/out 写回) — 仅 use_soa=false
	//     注：use_soa=true 时这些字段直接 flush 到 SoA + MapData，无需 PackedArray 回写
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms 合计)；< 0.0 → fallback。
    //   knobs 走 by-value（非 const&），让 C++ 能写回 succession + ms breakdown。
    double run_stage_b_pass(godot::Dictionary knobs);

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
    // cpp-dots（temp-baseline-authority-2026-06）：cell_temp_baseline_year 的权威 C++ 烘焙。
    // 海冰 + 显示温度的运行期 baseline 原由 GDScript map_data.bake_lat_temp_year_lut 就地
    // pow(cos,..) 烤出来再推给 slot——仿真量权威落在 GDScript。本 pass 用唯一 C++ 实现
    // pk_lat_temp_bell 从 knobs["lat_norm"]（ny∈[0,1] 几何量）算 baseline，写
    // cell_temp_baseline_year slot 并 _flush_slot_to_map 回 MapData。GDScript 自烤改为 fallback。
    godot::Dictionary run_temp_baseline_year_bake(godot::Dictionary knobs);
    godot::Dictionary run_season_refresh_stage(godot::Dictionary knobs);
    godot::Dictionary run_season_refresh_micro_pass(godot::Dictionary knobs);
    // ─── Phase B+：season refresh round 一次跨界整 round 切片调度 ──────────
    // 与 run_season_refresh_stage 协作（B+ 路径下 run_season_round_slice 内部
    // 直接复用 run_season_refresh_stage 的 stage dispatch，零算法复制）。
    //
    // 用法（GDScript caller）：
    //   handle = ext.start_season_round(round_knobs)         # round 起始（一次烘焙 row tables / jitter / donor）
    //   while not done:
    //       slice = ext.run_season_round_slice(handle, max_usec)  # 每 SUS slot 调一次，b1=stage 边界粒度
    //       done = slice.done
    //   fin = ext.finish_season_round(handle)                # GDScript 拿 fin 后做一次 facade sync + history push
    //
    // round_knobs（一次塞齐 12 个 stage 所需的全部字段，B+ 内部按 stage 取用）：
    //   "season"               : int    (0..3)
    //   "n_cells"              : int
    //   "height"               : int
    //   "sea_level"            : float
    //   "moist_scale"          : float                       # stage 0
    //   "rain_shadow_lookback" : int                         # stage 1
    //   "rain_shadow_threshold": float                       # stage 1
    //   "rain_shadow_factor"   : float                       # stage 1
    //   "season_phase"         : float                       # stage 1
    //   "elev_decay"           : float                       # stage 4
    //   "decay"                : float                       # stage 11 (=feedback decay)
    //   "lat_temp_rows"        : PackedFloat32Array          # stage 2/4/9
    //   "season_offset_rows"   : PackedFloat32Array          # stage 2/9 (=sync_state)
    //   "row_indices"          : PackedInt32Array            # stage 2/3/4/5/6/7/swamp
    //   "neighbor_indices"     : PackedInt32Array            # stage 1/4/5/6/7/swamp
    //   "jitter_arr"           : PackedFloat32Array          # stage 1
    //   "donor_table"          : PackedFloat32Array          # stage 4
    //   "soil_moisture_arr"    : PackedFloat32Array (in/out) # stage 11
    //   "veg_growth_pressure_arr": PackedFloat32Array (in/out) # stage 11
    //
    // start_season_round 返回：
    //   { "handle": int (>=0 成功，<0 fallback), "fallback": bool, "reason": String }
    // run_season_round_slice 返回：
    //   { "done": bool, "stage": int (当前 round_stage 0..11),
    //     "stages_done_this_slice": int, "elapsed_ms": float,
    //     "fallback": bool, "reason": String }
    // finish_season_round 返回：
    //   { "total_native_ms": float, "slices_used": int, "stages_done": int,
    //     "soil_moisture_arr": PackedFloat32Array (decayed, write-back to map),
    //     "veg_growth_pressure_arr": PackedFloat32Array (decayed, write-back to map) }
    // abort_season_round：清 round state，让 generation +=1 让悬挂 handle 失效。
    godot::Dictionary start_season_round(godot::Dictionary round_knobs);
    godot::Dictionary run_season_round_slice(int handle, int max_usec);
    godot::Dictionary finish_season_round(int handle);
    void abort_season_round();
    godot::Dictionary run_sea_ice_atlas_prepare(godot::Dictionary knobs);
    godot::Dictionary patch_enum_atlas_axes(godot::Dictionary knobs);

    // ─── Bake-time static texture encoders（map encoder C++ 迁移）──────────
    // GDScript 仍负责 Image/ImageTexture 创建与 update；C++ 只做逐像素 byte payload。
    // 返回统一 Dictionary：{ fallback, reason, path, elapsed_ms, data, width, height, format }。
    godot::Dictionary encode_bake_height_tex_data(godot::Dictionary knobs);      // F32 [0,1] → RG8
    godot::Dictionary encode_bake_terrain_normal_tex_data(godot::Dictionary knobs); // F32 height → RG8 粗法线(nx,ny)
    godot::Dictionary encode_bake_horizon_tex_data(godot::Dictionary knobs);      // F32 height → RGBA8 packed 8-dir horizon
    godot::Dictionary encode_bake_r8_tex_data(godot::Dictionary knobs);          // U8 → L8，default_byte 可选
    godot::Dictionary encode_bake_flow_tex_data(godot::Dictionary knobs);        // F32 [0,1] → L8
    godot::Dictionary encode_bake_enum_atlas_payload(godot::Dictionary knobs);   // map_index RGBA8
    godot::Dictionary encode_bake_upwelling_tex_data(godot::Dictionary knobs);   // SoA upwelling → L8
    // 生成期 height/biome/moisture/veg/cover 逐像素烘焙。
    // 离散数据使用硬主 cell；另产出副 cell RG8 + 边界距离 R8 供屏幕空间边缘混合。
    // 复刻 map_baker.gd::_bake_height_biome_moisture；产出 7 buffer + CSR + pixel_to_cell_index。
    godot::Dictionary run_bake_terrain_index_pass(godot::Dictionary knobs);

    // ─── 生成期 per-pixel 几何场 buffer-encoder（dots-total-cpp 续，2026-06-25）────
    // 纯 buffer-encoder：不读 _slots / 不要求 _bound，全部输入由 knobs PackedArray 喂入
    // （同 encode_bake_* / run_bake_terrain_index_pass 范式，bake 期 bind 时机不定）。
    // GDScript 只发请求 + 收结果，O(n_pixels) 热循环全部在 C++。
    //
    // run_bake_latitude_field_pass：复刻 map_baker.gd::_bake_latitude_buffer。逐像素
    //   ny = y / max(H-1,1)。输入 w/h。输出 latitude_buffer(F32 PackedFloat32Array)。
    godot::Dictionary run_bake_latitude_field_pass(godot::Dictionary knobs);
    // run_bake_river_sdf_pass：复刻 map_baker.gd::_bake_river_sdf 的**全部计算**——
    //   河流图遍历（trace，读 post_base 暂存的 `_gen_river_*` ext 拓扑）+ 连续经度展开 +
    //   Catmull-Rom 致密化 + warp 噪声（FastNoiseLite 复刻 _warp_noise_lo/hi）+ 变宽 polyline
    //   stamp + chamfer 3-4 双通 SDT + 归一化 [0,1] flow。**无任何河流链/拓扑跨语言传入**：
    //   GDScript 只传 bake 几何参数，C++ 直接读自己暂存的拓扑 trace（零再传输）。
    //   前置：必须先调用 run_native_world_generate_post_base_pass（填 `_gen_river_*`）。
    //   输入 w/h/origin_x/origin_y/inv_world_x/inv_world_y/hex_size/seed/base_radius_px/
    //   sdf_max_dist_px/cr_step/wrap_period_x。输出 out_buf(F32 PackedFloat32Array，= world.flow_buffer)。
    godot::Dictionary run_bake_river_sdf_pass(godot::Dictionary knobs);
    // run_bake_coast_sdf_pass（water-bodies systemic）：海/湖统一"离岸像素距离场"。
    //   从 per-pixel terrain(biome_buffer) 的 land-water 边界做 chamfer 3-4 双通距离变换，
    //   产出每像素到最近水体的像素距离（水体=0，向内陆递增，clamp 于 coast_sdf_max_dist_px）。
    //   水集合 = {0,1,18,19,20,21}（与 terrain_index is_water / pk_is_water_terrain 对齐）。
    //   输入 width/height/biome_buffer/coast_sdf_max_dist_px/coast_sdf_wrap_x。
    //   输出 out_buf(F32 PackedFloat32Array)。供 geometry_fields 在 river carve 后刻连续岸坡。
    godot::Dictionary run_bake_coast_sdf_pass(godot::Dictionary knobs);
    // run_bake_erosion_pass：复刻 map_baker.gd::_hydraulic_erosion。droplet 水力侵蚀，
    //   用 Ref<RandomNumberGenerator>（同 seed 复刻 baker _rng PCG）逐滴随机起点/方向。
    //   in/out height buffer，内部 clamp [0,1]。输入 w/h/height_buffer（PackedFloat32Array）/seed +
    //   num_drops/max_steps/inertia/capacity_factor/min_capacity/deposit_speed/erode_speed/
    //   evaporation/gravity/brush_radius。输出 height_out(F32 PackedFloat32Array)。
    godot::Dictionary run_bake_erosion_pass(godot::Dictionary knobs);

    // run_bake_geometry_fields_pass（dots-total-cpp step2，2026-06-25）：bake 期几何场编排
    //   下沉 C++ 的单次驱动。GDScript 只发一次请求（一个 knobs Dictionary 含 terrain-index
    //   所需 cell SoA + 几何参数 + erosion 常量），C++ 在进程内依次串起已验证的
    //   terrain-index → erosion → river SDF → latitude sub-pass，中间 buffer
    //   （尤其 height_buffer）全部留在 C++、不跨语言往返；一次返回完整几何 bundle。river 读
    //   post_base 暂存的 `_gen_river_*` 拓扑（零再传输），故前置仍需先跑 post_base。
    //   输出合并 bundle：height_buffer/biome_buffer/moisture_buffer/vegetation_buffer/
    //   cover_buffer（terrain）+ flow_buffer（river out_buf）+ latitude_buffer +
    //   CSR（cell_first_px/cell_px_count/flat_px_indices）+ pixel_to_cell_index +
    //   total_px + width/height + 各 stage 的 *_elapsed_ms 诊断。
    //   terrain sub-pass 失败 → 整体 fallback=true（caller 回退旧 per-pass / GDScript 路径）；
    //   erosion sub-pass 失败 → 用未侵蚀 height 续算（非致命），不令整体 fallback。
    godot::Dictionary run_bake_geometry_fields_pass(godot::Dictionary knobs);
    // High-resolution visual-only tile. The low-resolution geometry remains
    // authoritative; this pass never creates high-resolution pixel CSR data.
    godot::Dictionary run_bake_visual_tile_layer_pass(godot::Dictionary knobs);
    // Native fallback for tiled horizon publication. Resamples one physical
    // tile (including gutters) from the authoritative low-resolution RGBA8
    // horizon without introducing a GDScript per-pixel loop.
    godot::Dictionary run_resample_visual_horizon_layer_pass(godot::Dictionary knobs);

    // ─── Dirty-Push Atlas Encode (plan/dirty-push-atlas-encode 阶段 F) ────
    // 4 张运行期 atlas baker 的 byte-fill 阶段下沉 C++/SIMD：
    //   encode_dynamic_cell_atlas：RGBA8。R=q01(temp), G=q01(moist),
    //     B=q01(snow), A = passable_sea ? 0 : q01(vitality)。镜像
    //     map_baker.gd::_dynamic_cell_signature + dynamic_cell_atlas_chunk_step。
    //   encode_ecology_visual_atlas：RGBA8。R=q01(foliage), G=q01(stress),
    //     B=transition_age, A=q01(growth_damage)。需要持久状态：
    //     prev_veg / prev_vitality_byte / prev_transition_age（per-cell byte 数组），
    //     由 GDScript 端按 cell_indices 顺序传入并由 C++ 端写出新值（同长度）返回。
    //     镜像 _ecology_visual_signature + ecology_visual_atlas_chunk_step。
    //   encode_dyn_smooth_atlas：RGBA8。中心 sig 0.5 + ≤6 邻居均值 0.5 → q01。
    //     需要 neighbor_indices PackedInt32Array（长度 n_cells*6，越界为 -1，
    //     与 run_physical_circulation_pass 同构）。镜像 dyn_atlas_smooth_chunk_step。
    //   encode_ice_state_atlas：R8。byte = sea_ice_frac > 0 ? max(1, ceil(*255)) : 0。
    //     仅水域写非零，由 GDScript 端在 cell_indices 中只放水域 dirty cell。
    //     镜像 ice_state_atlas_chunk_step（含 _q01_byte_ice）。
    //
    // ClimateProfile flag：cpp_atlas_encode_enabled（默认 false）。
    //
    // 共享 CSR 协议（所有 4 个 method 通用）：
    //   knobs Dictionary 入参：
    //     "n_pix"            : int      （= W*H）
    //     "stride_bytes"     : int      （RGBA=4，R8=1）
    //     "atlas_buffer"     : PackedByteArray（长度 n_pix * stride_bytes，C++ 端 ptrw 直写）
    //     "cell_indices"     : PackedInt32Array（dirty cell SoA idx 数组，长度 K）
    //     "cell_first_px"    : PackedInt32Array（长度 K，CSR row-ptr：第 i 个 cell 在 flat_px_indices 起始）
    //     "cell_px_count"    : PackedInt32Array（长度 K，第 i 个 cell 的像素数）
    //     "flat_px_indices"  : PackedInt32Array（长度 = sum(px_count)，所有像素 idx 顺序拼接）
    //     "cell_is_water"    : PackedByteArray（长度 K，0/1；dynamic / dyn_smooth pass 必需）
    //                          语义：is_water = not passable_land（含 SEA_ICE/LAKE 等所有水域）
    //     # ecology pass 额外：
    //     "prev_veg"         : PackedByteArray（长度 K）
    //     "prev_vitality"    : PackedByteArray（长度 K）
    //     "prev_transition"  : PackedByteArray（长度 K）
    //     "cache_valid"      : bool（false 时 transition_age 强制清 0）
    //     # dyn_smooth pass 额外：
    //     "neighbor_indices" : PackedInt32Array（长度 n_cells * 6，-1 表示越界邻居）
    //     "neighbor_is_water": PackedByteArray（长度 K * 6，按 cell_indices 顺序对每个邻居打包 is_water）
    //
    // 返回 Dictionary：
    //   "elapsed_ms"     : double（C++ 端 hot loop 耗时）
    //   "fallback"       : bool（true 表示参数非法 / 槽位缺失，调用方应走 GDScript 路径）
    //   "reason"         : String（fallback 时的理由）
    //   "pixels_written" : int（实际写入的像素数）
    //   "atlas_buffer"   : PackedByteArray（直写后的 buffer；GDScript 端取回赋给 world.*_buffer）
    //   # ecology 额外返回：
    //   "new_veg"        : PackedByteArray（长度 K，本 tick 写回 _last_ecology_veg_bytes）
    //   "new_vitality"   : PackedByteArray（长度 K）
    //   "new_transition" : PackedByteArray（长度 K，本 tick 写回 _ecology_transition_age_bytes；调用方须按 erase if==0 维护 _eco_active_decay_set）
    //   "new_sigs"       : PackedInt32Array（长度 K，写回 _last_ecology_visual_sigs；dynamic/smooth/ice 也返回，写回各自 _last_*_sigs）
    //
    // 失败模式（fallback=true）：n_pix<=0、CSR 数组长度不匹配、SoA slot 缺失或大小不够、
    // atlas_buffer 大小不匹配 stride*n_pix。
    godot::Dictionary encode_dynamic_cell_atlas(godot::Dictionary knobs);
    godot::Dictionary encode_ecology_visual_atlas(godot::Dictionary knobs);
    godot::Dictionary encode_dyn_smooth_atlas(godot::Dictionary knobs);
    godot::Dictionary encode_ice_state_atlas(godot::Dictionary knobs);

    // ─── Debug Data Overlay Atlas Encode (plan/debug-overlay-perf v2, 2026-06-12) ──
    // data_overlay_baker.gd 的 O(n_pixels) pixel fan-out 下沉 C++（debug 模式
    // 温度/天气等 overlay 卡顿主因之一）。GDScript 端仍负责 18 个 overlay mode
    // 的 per-cell 采样（仅 ~n_cells 次，分支重、含 latitude_buffer / atan2 /
    // 非 schema 字段，留 GDScript 最稳、零 bit-divergence 风险），把每个 cell
    // 编码后的 R/G byte + 有效标记打包成 per-cell 数组传入；本方法负责把每个
    // 有效 cell 的 (R, G, 0, 255) 扇出写到它覆盖的全部像素（典型 ~62 万次写），
    // 并先 memset 清零（无效/未覆盖像素 alpha=0）。
    //
    // 复用 WorldData 持久 SoA CSR（cell_first_px_arr / cell_px_count_arr /
    // flat_px_indices_arr，按 cell.index 索引，整图一次性构建），零大数组拷贝。
    // 与 encode_dynamic_cell_atlas 等共用 flat_px 复用语义（first/count 直接索
    // 引整图 flat，不要求紧凑串接）。
    //
    // 不依赖 _bound / _slots —— overlay 数据全部由 GDScript 预采样喂入，因此即
    // 便 climate slot 未绑定（或地图刚生成）也能工作。
    //
    // knobs:
    //   "n_pix"           : int  (= W*H)
    //   "n_cells"         : int  (= cell_first_px / cell_r / cell_g / cell_valid 长度)
    //   "atlas_buffer"    : PackedByteArray (n_pix*4，RGBA8，C++ ptrw 直写)
    //   "cell_first_px"   : PackedInt32Array (n_cells；world.cell_first_px_arr，-1=空)
    //   "cell_px_count"   : PackedInt32Array (n_cells；world.cell_px_count_arr)
    //   "flat_px_indices" : PackedInt32Array (整图 flat；world.flat_px_indices_arr)
    //   "cell_r"          : PackedByteArray (n_cells；按 cell.index 的 R byte)
    //   "cell_g"          : PackedByteArray (n_cells；G byte)
    //   "cell_valid"      : PackedByteArray (n_cells；0/1，0=该 cell 不写像素)
    //
    // 返回:
    //   "elapsed_ms"     : double（hot loop 耗时）
    //   "fallback"       : bool（true=参数非法，调用方走 GDScript fan-out）
    //   "reason"         : String
    //   "pixels_written" : int
    //   "atlas_buffer"   : PackedByteArray（直写后的 buffer，调用方取回上传纹理）
    godot::Dictionary encode_overlay_atlas(godot::Dictionary knobs);

    // Tile data recorder CSV encoder. GDScript remains the authority for
    // selecting MapData SoA arrays and fixed diagnostic columns; C++ only
    // formats one full tick worth of numeric rows into UTF-8 CSV bytes.
    //
    // Returns an empty PackedByteArray on invalid input so the GDScript caller
    // can fall back to the reference formatter.
    godot::PackedByteArray encode_tile_csv_rows(godot::Dictionary knobs);

    // ─── plan/atlas-pipeline-cpp（2026-05-20）：4 张 atlas 全管线主入口 ─────
    // dynamic_visual_atlas_upload_system 每帧热路径整套搬到 C++：dirty 消费 →
    // 4 张 atlas value-diff（per-atlas prev_sigs snapshot 兜底 dirty 语义 bug）
    // → 1-跳邻居膨胀（smooth 用）→ CSR 打包 → 4 张 atlas encode → 4-phase 调
    // 度节流。GD 端薄壳每 tick 只调一次本入口，拿 atlas_buffers Dict 后做
    // 4 次 ImageTexture.update。
    //
    // opts (Dictionary 输入):
    //   "world"            : Object（DCWorld 实例，必填）
    //   "soft_budget_us"   : int（本 tick 软预算，C++ 内部每 phase / chunk 边界检查；默认 1500）
    //   "max_cells"        : int（本 tick 最多处理 cell 数；默认 4096）
    //   "enable_diag"      : bool（开则填 12 个 ms_* 字段；默认 false）
    //   "encode_knobs_*"   : Dictionary（4 个 atlas 的 encode 旋钮，转发给内部 encode_*）
    //
    // 返回 (Dictionary):
    //   "done"             : bool（true 表示本 stride 4 phase 全部完成）
    //   "phase"            : int（当前 phase 枚举，0=IDLE..5=DONE）
    //   "cursor"           : int（当前 phase 内 cursor，调试用）
    //   "atlas_buffers"    : Dictionary { "dyn"/"eco"/"smo"/"ice" : PackedByteArray }（仅 finalize 阶段含）
    //   "stride_real"      : Dictionary { 4 个 atlas 的真·变化 cell 数 }
    //   "ms_breakdown"     : Dictionary（12 个 phase 细分时间，enable_diag=true 才填）
    //
    // 与现有 encode_* 关系：本方法在内部直接复用 4 个 encode_* 函数体，prev_sigs
    // 从 AtlasPipelineState::prev_sigs_* 读取，无需 GD 端来回传 snapshot。
    godot::Dictionary run_atlas_pipeline_step(godot::Dictionary opts);

    // 地图重生成 / map_regenerate 时调，使 AtlasPipelineState::csr_cache 与
    // prev_sigs 失效；下一次 run_atlas_pipeline_step 会按 dirty 全集重建。
    // 无副作用、O(1) 清空 PackedArray。
    void invalidate_atlas_csr_cache();

    // 一次性把 GD 端 ecology 持久状态（map_baker.gd _eco_foliage/_eco_stress/
    // _eco_transition_age_bytes / _eco_growth_damage / _eco_active_decay_set）
    // 迁移到 C++ 端 AtlasPipelineState。init 阶段调一次，之后完全由 C++ 维护。
    //
    // state (Dictionary):
    //   "foliage"           : PackedFloat32Array（长度 n_cells，per-cell foliage 0..1）
    //   "stress"            : PackedFloat32Array（同上，stress 0..1）
    //   "transition_age"    : PackedFloat32Array（同上，秒）
    //   "growth_damage"     : PackedFloat32Array（同上，0..1）
    //   "active_decay"      : PackedInt32Array（active decay set 的 cell.index 列表）
    //
    // 容错：缺失字段以默认 0 填充；长度不匹配以 n_cells 截断/补 0。
    void migrate_eco_persistent_from_gd(godot::Dictionary state);

    // ─── Cell-index 间接寻址（province-ID indirection）─────────────────────
    // encode_cell_luts：per-cell（n_cells texel）enum/dyn/eco LUT 编码。与 4-phase
    //   fan-out pipeline 共用 pk_atlas_sig_dynamic / pk_atlas_sig_ecology 公式，
    //   保证 LUT 与全分辨率 atlas bit-equivalent。eco transition_age 由
    //   AtlasPipelineState::lut_* 持久状态自维护（与 pipeline eco 状态独立）。
    //   可选 opts["snow_cover_arr"] 只覆盖雪盖视觉通道，避免为修复雪盖 stale
    //   而全量 refresh_slots_from_map() 覆盖 native-only 槽。
    //   SAME_SOURCE: map_baker.gd::bake_cell_luts / _bake_cell_luts_gd。
    godot::Dictionary encode_cell_luts(godot::Dictionary opts);

    // ─── Detail scatter（vegetation-visual-pcg 阶段 A）────────────────────
    //   encode_detail_scatter：植被/点缀散布的 per-instance 热循环 + MultiMesh
    //   buffer 组装下沉 C++。纯 buffer-encoder：只读 knobs 内的 flat PackedArray，
    //   不读 _slots、不写 slot；结果 MultiMesh buffer（每实例 16 float =
    //   transform2d 8 + color 4 + custom 4）直接随返回 Dict 回传，GDScript 端
    //   `multimesh.buffer = buf` 一次赋值，零逐实例 marshalling。
    //   SAME_SOURCE: shrub_layer.gd::_rebuild_instances（GDScript fallback）。
    godot::Dictionary encode_detail_scatter(godot::Dictionary knobs);
    // Dirty-cell variant for succession events. It consumes the same flat per-cell
    // arrays as encode_detail_scatter, but callers pass only the current event batch.
    godot::Dictionary encode_detail_scatter_delta(godot::Dictionary knobs);
    // Multi-profile/family bridge: one Godot→native call accepts an Array of delta
    // requests and returns tagged payloads. Requests share PackedArray references;
    // no per-instance Variant marshalling is introduced.
    godot::Dictionary encode_detail_scatter_family_cells(godot::Dictionary knobs);

    // ─── DOTS-Total-CPP（plan/dots-total-cpp 任务 4）─────────────────────
    // run_ocean_field_rasterize：ocean current + upwelling 一次性 hex→pixel byte 直出。
    //
    // GDScript 源：scripts/rendering/map_baker.gd::_rasterize_ocean_current_slice_from_hex
    //               + _rasterize_upwelling_slice_from_hex
    //
    // ClimateProfile flag：use_gdext_ocean_currents_pixel（默认 false，需求 8.5 验收后开）
    //
    // 性能目标：消除 ocean_currents 17 个 GDScript pixel slice（25ms slow slice），
    //           620544 像素一次性 C++ loop ≤ 5ms。
    //
    //   入参 `knobs` Dictionary：
    //     标量：n_cells (int), w (int), h (int), update_atlas_data (bool)
    //     可选标量：start_idx (int, 默认 0), end_idx (int, 默认 W*H)
    //               — 像素区间 [start_idx, end_idx)，用于 sub-tick 切片
    //                 把 4.7ms 整图 raster 拆成 N 片 ~1.2ms（每像素独立无依赖）
    //     PackedArray：
    //           pixel_to_cell_idx : PackedInt32Array (W*H)，每像素对应 cell index 或 -1
    //           dst_currents      : PackedByteArray  (W*H*2)，输出 R+G byte
    //           dst_upwelling     : PackedByteArray  (W*H*1)，输出 byte
    //           atlas_data        : PackedByteArray  (W*H*4)，可选；若 size 匹配则同步更新
    //   读：cell_terrain / cell_ocean_current_x / cell_ocean_current_y /
    //       cell_upwelling_strength SoA
    //   写：dst_currents / dst_upwelling / atlas_data（in/out via knobs ptrw）
    //   返回 Dictionary：{ "elapsed_ms", "fallback", "reason", "pixels",
    //                     "atlas_updated", "start_idx", "end_idx" }
    godot::Dictionary run_ocean_field_rasterize(godot::Dictionary knobs);

    // ─── DOTS-Total-CPP（A 方案 / wind raster 孪生）─────────────────────
    // run_wind_field_rasterize：wind_x / wind_y SoA → hex→pixel byte 直出。
    //
    // GDScript 源：scripts/rendering/map_baker.gd::_rasterize_wind_slice_from_hex
    //               (Stage 7 _PHYS_STAGE_WIND_RASTER 内部循环)
    //
    // ClimateProfile flag：复用 use_gdext_ocean_currents_pixel（孪生场景：
    //                       同样的 hex→pixel byte rasterize，无需新 flag）
    //
    // 性能目标：消除 ocean_currents 21 片 × 87ms 的 wind raster GDScript 循环。
    //           620544 像素一次性 C++ loop ≤ 5ms。
    //
    //   入参 `knobs` Dictionary：
    //     标量：n_cells (int), w (int), h (int), update_atlas_data (bool)
    //     PackedArray：
    //           pixel_to_cell_idx : PackedInt32Array (W*H)，每像素对应 cell index 或 -1
    //           dst_wind          : PackedByteArray  (W*H*2)，输出 wx/wy byte
    //           atlas_data        : PackedByteArray  (W*H*4)，可选；若 size 匹配则同步写 [+2]/[+3]
    //   读：cell_wind_x / cell_wind_y SoA
    //   写：dst_wind / atlas_data[i*4+2..+3]（in/out via knobs ptrw）
    //   返回 Dictionary：{ "elapsed_ms", "fallback", "reason", "pixels", "atlas_updated" }
    //
    //   ⚠️ 与 ocean 行为差异：cell idx 无效（lookup 缺失或 -1）时，wx 默认 1.0、wy 默认 0.0
    //                          （与 GDScript _rasterize_wind_slice_from_hex 严格 1:1）。
    godot::Dictionary run_wind_field_rasterize(godot::Dictionary knobs);

    // ─── DOTS-Total-CPP（A 方案 / phys nan_guard 孪生）─────────────────────
    // phys_field_nan_guard：扫 cell_wind_{x,y,speed} / cell_ocean_current_{x,y}
    // / cell_upwelling_strength 这 6 个 SoA，统计 NaN/Inf 数量。
    //
    // GDScript 源：scripts/rendering/map_baker.gd::_physical_solve_step_one
    //   _PHYS_STAGE_WIND_RASTER 第一帧的 `for c in map.all_cells(): is_finite()`
    //   循环（2400 cell × 6 字段 ≈ 22ms），是 phys_wind_raster slice 的最大头。
    //
    // 这里直接读 _slots 里的 PackedFloat32Array.ptr() 顺序扫，编译器
    // 会自动向量化成 AVX2 SIMD（_mm256_cmp_ps NaN+Inf 检测），目标
    // < 0.1ms（2400 cell × 6 ≈ 56KB 顺序读）。
    //
    // 返回 int：bad cell 数（任一字段 NaN/Inf 即 +1，不重复计数）。
    // -1 表示 SoA size mismatch / slot 缺失（GDScript 应回落到原慢路径）。
    int phys_field_nan_guard();

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

    // ─── plan/weather-refresh-cpp-all: 顶层一体化 weather refresh ────────
    //
    // 单 C++ 调用内顺序执行 5 段：
    //   ① run_weather_field_solve_pass(knobs)
    //   ② run_weather_distribute_pass(knobs)
    //   ③ run_weather_summary_fronts_pass(knobs)   ← 产 fronts Array
    //   ④ cyclone_wake_step(knobs, fronts)         ← 新增（front_advect.gd::tick_cyclone_wake 1:1 移植）
    //   ⑤ run_stage_b_pass(knobs)
    //
    // 设计原则（方案 X）：内部**直接复用已有 4 个 run_*_pass 公开 API**，
    // 不抽 *_inline，不动现有 pass 函数体。代价是顶层 pass 内会重复解析同一
    // Dictionary 4 次（每次 ~10-50μs），与节省的 4 次 GD↔CPP round-trip
    // (~0.3-0.8ms) 相比仍净赚。
    //
    // ClimateProfile flag：use_gdext_weather_refresh_daily（默认 true）
    //
    // knobs 入参：所有子 pass 的 knobs 字段合并到同一 Dictionary，
    //             各子 pass 各自只读自己需要的 key。本顶层 pass 额外要求：
    //   标量： hex_size (float, cyclone_wake 用)
    //          cyclone_wake_days (int, cyclone wake 持续天数)
    //          cyclone_storm_type_id (int, WeatherType.WT.STORM 枚举值)
    //          water_terrain_ids 已在 summary pass knobs 中存在，cyclone 复用
    //   summary pass knobs 中已含 cell q/r 反查能力（_summary_qr_to_idx），
    //     cyclone 通过 cell_q/cell_r SoA 反查注入点。
    //
    // 返回 Dictionary：
    //   { rc: 0/-1, fail_stage: String?, weather_tick_ms,
    //     advance_ms, distribute_ms, cyclone_ms, fronts_count,
    //     albedo_ms, veg_dyn_ms, feedback_ms, total_ms, fronts: Array }
    //   任一子段 rc<0 时 { rc:-1, fail_stage:"field_solve|distribute|summary|stage_b" }
    //   立即短路返回，caller 走 GDScript fallback。
    //
    // 副作用：除子 pass 自身的副作用外，本顶层 pass 维护
    //   _cyclone_perturbations (std::vector<CycloneWakeEntry>) 跨 tick 存活。
    //   GDScript 端通过 get_cyclone_perturbations_dict() 取镜像，落到
    //   weather_system.ocean_current_perturbation Dictionary。
    godot::Dictionary run_weather_refresh_daily_pass(const godot::Dictionary &knobs);

    // ─── Phase C.1（dots-total-cpp roadmap）：System schedule graph 节点 ──
    //
    // 这组 _exec_node_* 是 system_schedule.h 内 SystemNode.exec_fn 的成员函数
    // 指针目标。public 仅是为了让 `&DCWorldExt::_exec_node_xxx` 能在 cpp
    // 全局静态表 SCHEDULE_GRAPH 中取地址；**不**对外提供调用语义——只能由
    // system_schedule.cpp 的 dispatch_system_schedule loop 调用。
    //
    // 每个节点直接镜像 run_native_daily_tick line 960-1063 内对应 if-bundle
    // 块的语义：读 bundle key → 调 run_<X>_pass → 累加 breakdown（含 climate_ms
    // / ocean_ms / stage_b_ms 跨 pass 累加）→ 写节点级 side-effect（stage_b 的
    // 4 个 breakdown 回填、weather 的 _native_fronts_snapshot 写入）。
    // 返回 true=成功；false=fallback 触发，dispatch loop 走 finish_with_failure。
    bool _exec_node_climate_pass_a     (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_ocean_water        (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_ocean_land         (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_climate_pass_b     (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_wind_air           (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_wind_surface       (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_sea_ice            (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_transpiration      (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_albedo             (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_vegetation_dynamics(godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_climate_feedback   (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_stage_b            (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_stage_b_after_hydrology(godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_weather            (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_runtime_hydrology  (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);

    // 镜像 API：把 C++ 端 _cyclone_perturbations 导出成 GDScript Dictionary，
    // 结构与 weather_system.ocean_current_perturbation 1:1（key = cell.q*10000+cell.r 的
    // 64-bit int hash；value = Dictionary{ vec: Vector2, vec_init: Vector2,
    // days_left: int, init_days: int }）。
    //
    // 调用时机：refresh_weather_daily 在 ext call 成功后立即调一次，把结果
    // 回灌 weather_system.ocean_current_perturbation，下游消费方（航运 AI、
    // shader overlay、soak dump）零感知 C++ 切换。
    godot::Dictionary get_cyclone_perturbations_dict() const;
    godot::Dictionary get_active_cyclone_snapshot() const;
    godot::Dictionary get_climate_modes_report() const;
    godot::Dictionary capture_climate_modes_state() const;
    godot::Dictionary restore_climate_modes_state(const godot::Dictionary &state);

    // ─── Block B: ocean_currents wind solver C++ pass ─────────────────────
    //
    //   GDScript 源：scripts/rendering/physical_circulation_solver.gd::solve_wind_field
    //                 (line 246-454, 195 行)
    //   ClimateProfile flag：use_gdext_wind_field（默认 false；本 PR 完成 +
    //                        SAME_SOURCE A/B 通过 + p95 ≤ 5ms 后切 true）
    //   性能目标：35.55ms p95 → < 5ms（charter §7 / dots-wind-validation.md）
    //
    //   算法结构（与 GDScript 1:1 镜像）：
    //     Pass 0 — 海岸 BFS（≤ _WIND_COAST_THERMAL_MAX_DIST=5 步）：
    //       识别每个陆地 cell 距海岸的格数，用作沿海热力压差权重
    //     主循环 — 每 cell：
    //       (a) 纬度基线 v_base = wind_belt_at(ny shifted by solar declination)
    //       (b) 6 邻域离散梯度 grad_slp = (1/3)*Σ(slp_nb-slp_self)*d_unit
    //       (d) 科氏偏转：仅对 -grad_slp 做（北半球右偏 / 南半球左偏）
    //       (c) 沿海权重只放大 SLP 梯度项；方向由 pressure gradient 决定
    //       合成 v_sum = w_lat*v_base + w_grad*v_grad + synoptic perturbation
    //       (e) 地形/摩擦衰减 + 山脉绕流（mountain neighbor 切向偏转）
    //       写 wind_x_arr[i], wind_y_arr[i], wind_speed_out[i]
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            hex_size (float)
    //            season_phase (float, orbital/year phase only)
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

    // ─── plan/dots-slp-psi-cpp: SLP field solver (stage 1) ───────────────
    // Native SLP authority:
    //   Pass A: latitude pressure belts + insolation-driven land/sea thermal
    //           pressure + closed-loop thermal/ice/snow/moist terms.
    //   Pass B: smooth_passes-round 6-neighbor Jacobi smoothing
    //
    // knobs in:   n_cells, hex_size, season_phase, smooth_passes,
    //             world_bounds_pos_y, world_bounds_size_y,
    //             neighbor_indices, water_terrain_ids,
    //             slp_lat_amp, slp_land_amp, slp_water_damp,
    //             slp_interior_boost, slp_coast_damp,
    //             axial_tilt_deg, insolation_daylen_amp
    // knobs out:  slp_out (PackedFloat32Array, length n_cells)
    //
    // Dictionary out: { elapsed_ms, fallback (bool), reason (String) }
    //   elapsed_ms < 0 -> caller falls back to GDScript path.
    godot::Dictionary run_slp_field_pass(godot::Dictionary knobs);

    // ─── perf 2026-07-08, Item 1：phys pass 每调用固定开销缓存 ───────────
    // 解析四个 phys pass 共用的 cell_* slot id + 重建 is_water_lut，按
    // FNV-1a(n_cells, water_terrain_ids) 指纹失效。命中后各 pass 直接读
    // _phys_sid_* / _phys_is_water_lut 成员，省掉重复 component_id(StringName)
    // 与 256 字节 LUT 重建。邻居索引仍由 knob 传入（保留 fallback）。
    // 仅在指纹失配时重算（地图 regen / 水掩膜变化），主线程同步调用。
    void _phys_resolve_static(int n_cells, const godot::PackedByteArray &water_ids);
    // cell_lat_norm slot 的只读指针；slot 缺失或尺寸不符返回 nullptr（调用方退化为
    // 用 cell_pos_y 自归一化）。需先调用 _phys_resolve_static()。
    const float *_phys_lat_norm_ptr(int n_cells);
    // 缓存 WIND coast/sea BFS 结果（coast_dist/sea_dist 等）到成员；指纹失配才重建。
    // TR/NB/water_ids 来自当前 pass 已解析的 slot/knob（调用方传入）。
    void _phys_ensure_wind_coast(int n_cells, const uint8_t *TR, const int32_t *NB,
                                 const bool *is_water_lut, const godot::PackedByteArray &water_ids);
    // NS 化 Phase 0：在 wind pass 末尾由最终风槽构建半拉格朗日回溯轨迹表
    // （每 cell 3×i32 邻居索引 + 3×f32 权重），供动量自平流与 weather/wind_air
    // SL 平流消费。内部用 pk::parallel_for_range，只读 slots、写 own-row。
    void _phys_build_wind_traj(int n_cells, const float *POSX, const float *POSY,
                               const int32_t *NB, const float *WX, const float *WY,
                               const float *WSP, double wrap_period_x,
                               double traj_pos_scale, double traj_dt_days);

    // ─── plan/dots-slp-psi-cpp: PSI ocean stream-function solver ─────────
    // Fused stage 3 + 4 + 5 (init + SOR iters + finalize) in one C++ call:
    //   init     : enumerate water cells in cell-index order (1:1 with
    //              GDScript), build nb_idx, compute wind_stress_curl,
    //              compute beta_abs / r_factor / source per water cell.
    //   iters    : SOR Gauss-Seidel in-place iterations (psi_total_iters
    //              default 24), bit-equal to GDScript step_psi_solver.
    //   finalize : 6-neighbor gradient -> ocean_current, +/- 90 deg
    //              rotate, thermohaline high-lat overlay, clamp [-1,1].
    //
    // knobs in:   n_cells, hex_size, world_bounds_pos_y/size_y,
    //             neighbor_indices, cell_q, cell_r, water_terrain_ids,
    //             wind_x_arr, wind_y_arr, wind_speed_arr,
    //             psi_total_iters, psi_sor_omega, psi_r_base,
    //             psi_beta_floor, psi_source_scale, ocean_current_scale,
    //             thermohaline_weight, upwelling_highlat_abs,
    //             cold_sink_temp
    // knobs out:  wind_stress_curl_out, ocean_psi_out,
    //             ocean_current_x_out, ocean_current_y_out
    //             (each PackedFloat32Array of length n_cells; land cells
    //              filled with 0)
    //
    // Dictionary out: { elapsed_ms, fallback (bool), reason (String) }
    godot::Dictionary run_psi_solver_pass(godot::Dictionary knobs);

    // ─── dots-total-cpp step3（2026-06-25）：物理环流编排下沉（仅生成期一次性路径）──
    // run_physical_solve_pass：单次驱动，在 C++ 进程内按序串起 SLP → wind → PSI →
    //   upwelling 四个已验证 kernel（均读 bound slot + publish_to_slot），中间量
    //   （slp→wind 经 slp_arr、wind→psi 经 wind_*_arr）在 C++ 内从返回值/slot 串联，
    //   不跨语言往返。GDScript 一次请求（combined knobs = 4 stage 输入并集，含
    //   neighbor_indices/water_terrain_ids/prev_slp_arr + 全部标量/profile 参数 +
    //   heat_transport/solve_ocean/terrain_aware 标志），C++ 自动注入 chained 键
    //   （slp_arr/wind_x_arr/wind_y_arr/wind_speed_arr/stage）。仅 `_bake_initial_*` /
    //   `rebake_ocean_currents` 等**已经是原子完成**的路径用它（运行期逐帧分摊路径
    //   `_physical_solve_step_one` 不受影响）。任一 sub-pass fallback → 整体 fallback，
    //   GDScript 回退到原 step_one loop。NaN 守门 + 风场 RG8 光栅化仍在 GDScript
    //   （wrapper 调 phys_field_nan_guard + _bake_initial_vector_buffers）。
    //   输出 { fallback, reason, slp_ms, wind_ms, psi_ms, upwelling_ms, psi_ran,
    //   elapsed_ms }。前置：ext 必须 bind_map_data。
    godot::Dictionary run_physical_solve_pass(godot::Dictionary knobs);

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

    // ───────────────────────────────────────────────────────────────────
    // Async Climate Round（plan §async-stage-1，2026-06-14）
    //
    // Goal：把整个 climate daily round（pass_a → pass_b → ocean_water →
    // ocean_land → wind_air → wind_surface → sea_ice → transp 8 个 pass）
    // 整体扔给 worker thread 跑，主线程只做 kick/poll 和短暂 memcpy。
    // 主线程目标：每帧 climate 相关工作 < 1.5ms（kick + poll + flush）。
    //
    // 本阶段（Stage 1）：
    //   - 搭好 round-level async 框架（input/output/work buf + 单 worker
    //     thread + std::condition_variable wake/wait）
    //   - 8 pass 中只有 transpiration 实现 pure std::vector kernel；
    //     其它 7 pass 留 stub（input → output 直传，不修改）
    //   - GDScript 端用一个隔离的测试入口（cp.use_climate_round_async = true
    //     时 climate_daily_system 走 async 路径，否则走原 sync 路径）
    //
    // 线程安全契约（与 demo async 完全一致，不重复说明）：worker 全程只碰
    // std::vector / atomic / mutex / cv，绝不调任何 Godot API。
    //
    // 单例语义：本机制只支持一个 async climate round 任务（不需要 task_id
    // 多路），全局状态指针 _async_climate_round_state 由 lazy alloc 维护。
    // 析构时由 ~DCWorldExt 调 async_climate_round_shutdown 安全 join。

    // 注册并启动 worker thread。重复调用是幂等的（已 register 直接 return）。
    void async_climate_round_register();

    // 在 bind_map_data 之后 / 第一次 kick 之前调一次。把 round-invariant 的
    // 静态数据（neighbor_indices / donor_table / foliage_table）从 GDScript
    // 提取到 worker buffer。round 间复用，不在每次 kick 时重序列化。
    void async_climate_round_set_static_knobs(const godot::Dictionary &knobs);

    // 主线程入口：把当前 _slots[] 内容快照到 input_buf，传入 round-level
    // scalars（season_phase / cp 字段），唤醒 worker。返回 false 表示
    // worker 还没消费上一次 request（total_reused++），主线程应继续用
    // 上一次 result_buf。
    bool async_climate_round_kick(const godot::Dictionary &input);

    // 主线程出口：检查 worker 是否完成；完成则把 output_buf 反序列化回
    // _slots[]，并调 _flush_slot_to_map 系列推到 MapData。返回包含
    // sea_ice flip events / dirty_count / per-pass timing 的报告。
    // result_ready=false 时返回 {} 空字典。
    godot::Dictionary async_climate_round_poll();

    // 调试 / 验收用：返回 worker 计数 + 上次耗时。
    godot::Dictionary async_climate_round_stats();

    // Thin native facade over register/static/kick/poll. GDScript still owns
    // production scheduling state; these methods centralize native worker
    // lifecycle and return a structured state report.
    godot::Dictionary native_climate_round_begin(const godot::Dictionary &static_knobs);
    godot::Dictionary native_climate_round_begin_round(const godot::Dictionary &ctx);
    godot::Dictionary native_climate_round_kick(const godot::Dictionary &input);
    godot::Dictionary native_climate_round_poll();
    godot::Dictionary native_climate_round_finish_round(const godot::Dictionary &ctx);

    // Native climate round state report/reset scaffold. This is not production
    // authority yet; it exposes the native worker lifecycle so GDScript can
    // compare against its retained _round_active/_pass_cursor state.
    godot::Dictionary get_native_climate_round_state_report();
    godot::Dictionary get_native_climate_round_hot_state();
    godot::Dictionary reset_native_climate_round_state(const godot::String &reason = godot::String());

    // 析构 hook + GDScript 主动调用入口。安全 join worker。
    void async_climate_round_shutdown();

protected:
    static void _bind_methods();

private:
    godot::Dictionary run_economy_slice_internal(const godot::Dictionary &ctx,
                                                  bool compact);
    // ---- diag log toggle (Fix #11 second pass, 2026-06-16) ----
    bool _diag_logs_enabled = true;

    // ---- registry ----
    godot::Vector<Slot>                       _slots;
    godot::HashMap<godot::StringName, int>    _slot_by_name;

    // ---- climate pass-A annual-mean insolation cache (perf 2026-06) ----
    // dc_insolation_annual_mean(lat, axial_tilt, daylen) integrates 16 trig-heavy
    // insolation samples; it depends ONLY on cell latitude + two planet constants,
    // so it is IDENTICAL every day. run_climate_pass_a previously recomputed it per
    // cell per day (2464*16 trig/day ≈ 1.38ms of the round-start slice). We memoize
    // it per cell and rebuild only when a cheap fingerprint of (n, lat bits,
    // axial_tilt, daylen) changes (≈ once, at map bind / planet-param change).
    std::vector<float>                        _insol_annual_mean_cache;
    uint64_t                                  _insol_cache_fingerprint = 0;
    bool                                      _insol_cache_valid = false;

    // ---- SLP lat-LUT annual-mean sub-cache (perf 2026-07-05, Item 5) ----
    // run_slp_field_pass 每 pass 按 ny 预建 LUT_BINS 档 lut_solar_heat，其中
    // dc_insolation_annual_mean(ny_b, axial_tilt, daylen)（16×9 trig/bin）与 season 无关，
    // 每 pass 重算纯属冗余。缓存该年均 LUT，指纹 = FNV-1a(LUT_BINS, axial_tilt bits,
    // daylen bits)。insol_now / solar_dev / base_lat 仍每 pass 重建（season-dependent）。
    // 命中即逐位复用存储值 → bit-equal；仅在 bins/planet 常数变化时重建（≈一次）。
    std::vector<float>                        _slp_insol_mean_lut;
    uint64_t                                  _slp_insol_mean_lut_fp = 0;
    bool                                      _slp_insol_mean_lut_valid = false;

    // ---- PSI water-topology cache (perf 2026-07-05, Item 6) ----
    // run_psi_solver_pass 每 tick 重建 cell_to_water / water_to_cell / nb_w（水域邻接
    // 域内索引），这三者纯由水掩膜(TR+water_ids)与邻接表(NB)决定，与风/温度无关，故对
    // 静态地图逐 tick 恒等。海冰是独立 cell_sea_ice_frac F32 slot，**不改 terrain id**，
    // 所以水掩膜生成后即静态。缓存拓扑，指纹 = FNV-1a(n_cells, water_ids, 全 TR 字节,
    // 全 NB 整型) —— 自校验：地形或邻接一旦变化指纹即失配、自动重建，无需外部失效钩子。
    // 命中即逐位复用 → nb_w/water_to_cell/cell_to_water bit-identical。仅在 map regen /
    // 地形 flip 时重建（≈生成期一次）。主线程同步调用，成员存储线程安全。
    std::vector<int>                          _psi_cell_to_water;
    std::vector<int>                          _psi_water_to_cell;
    std::vector<int>                          _psi_nb_w;
    int                                       _psi_topo_n_water = 0;
    uint64_t                                  _psi_topo_fp = 0;
    bool                                      _psi_topo_valid = false;

    // ---- phys pass 每调用固定开销缓存 (perf 2026-07-08, Item 1) ----
    // run_slp_field_pass / run_wind_field_pass / run_psi_solver_pass /
    // run_physical_circulation_pass 每个调用都会 component_id(StringName("cell_*"))
    // 解析 7~13 次 slot id + 重建 256 字节 is_water_lut + 解包 neighbor_indices，
    // 这部分与 cell 内容无关、对静态地图逐调用恒等。统一在此缓存，指纹 =
    // FNV-1a(n_cells, water_ids) —— 地图 regen / 水掩膜变化即失配自动重建，不挂 _bound 钩子。
    // 命中后四个 pass 直接用成员，省掉重复 StringName 解析与 LUT 重建。
    // 注意：neighbor_indices 仍由 knob 传入（保留 fallback 路径），此处只缓存 slot id + LUT。
    int _phys_sid_pos_x = -1, _phys_sid_pos_y = -1, _phys_sid_terrain = -1;
    // 纬度归一化权威（与 world_ext_climate.cpp 同源）。物理 pass 曾用
    // (cell_pos_y - world_bounds_pos_y)/world_bounds_size_y 自行重算 ny，两者单位不同
    // 导致全图恒为极地；详见 world_ext_physical.cpp::phys_make_lat_norm 注释。
    int _phys_sid_lat_norm = -1;
    int _phys_sid_landform = -1;
    int _phys_sid_wind_x = -1, _phys_sid_wind_y = -1, _phys_sid_wind_spd = -1;
    int _phys_sid_slp = -1;
    int _phys_sid_temp = -1, _phys_sid_temp_an = -1;
    int _phys_sid_snow = -1, _phys_sid_ice = -1;
    int _phys_sid_wvap = -1, _phys_sid_wcld = -1;
    int _phys_sid_ocx = -1, _phys_sid_ocy = -1, _phys_sid_psi_prev = -1;
    int _phys_sid_upwelling = -1;
    int _phys_sid_elev = -1;  // NS 化 Phase 4:洋流深度耦合/地形转向读 elevation slot
    bool     _phys_is_water_lut[256];
    bool     _phys_is_water_valid = false;
    uint64_t _phys_static_fp = 0;
    bool     _phys_static_valid = false;

    // ---- phys pass cell-range 切片缓存 (perf 2026-07-08, Item 2) ----
    // SLP Pass A 结果跨切片累加的持久 buffer；Pass B 平滑 + recenter/p95/融合/发布
    // 只在末切片(end_idx==n_cells)对完整 buffer 跑一次 → 切片开启仍逐位等价全量 pass。
    // 大小随 n_cells 变化（无指纹，size 失配即 resize；solve 内被 Pass A 全量覆盖）。
    std::vector<float> _phys_slp_buf;
    // SLP thermal_abs（仅在 A_LAND/THERMAL_WEIGHT/ICE/SNOW 权重非 0 时填充；用于末切片
    // slp_thermal_p95 诊断）。同样持久化，使切片开启时末切片统计基于完整场而非末切片局部。
    std::vector<float> _phys_slp_thermal_abs;
    // WIND coast/sea BFS 结果缓存（指纹 = FNV(TR 字节 + water_ids + NB 整型)，
    // 地图静态恒等；与 _psi_topo 同套路，主线程同步调用、成员存储线程安全）。
    // 命中即 coast_dist/sea_dist 等逐位复用，免去每切片重建 BFS（≈地图期一次）。
    std::vector<int8_t>  _phys_wind_coast_dist;
    std::vector<float>   _phys_wind_coast_sea_x;
    std::vector<float>   _phys_wind_coast_sea_y;
    std::vector<int32_t> _phys_wind_coast_sea_anchor;
    std::vector<int8_t>  _phys_wind_sea_dist;
    std::vector<float>   _phys_wind_sea_land_x;
    std::vector<float>   _phys_wind_sea_land_y;
    std::vector<int32_t> _phys_wind_sea_land_anchor;
    // Signed, normalized land-minus-sea contrast sampled by the physical wind
    // pass.  Weather reads it as derived scratch for WT_MONSOON classification.
    std::vector<float>   _phys_monsoon_thermal;
    uint64_t _phys_wind_coast_fp = 0;
    bool     _phys_wind_coast_valid = false;
    double   _phys_wind_coast_build_ms = 0.0;
    bool     _phys_wind_coast_last_hit = false;
    int      _monsoon_eligible_cells = 0;
    int      _monsoon_onshore_cells = 0;
    int      _monsoon_offshore_cells = 0;
    float    _monsoon_contrast_abs_max = 0.0f;

    // Low-order ENSO modes. Basin topology and per-cell forcing are derived
    // caches; only EnsoBasinState is authoritative and serialized.
    struct EnsoBasinMeta {
        uint64_t signature = 0;
        int member_begin = 0;
        int member_count = 0;
        float span_x = 0.0f;
    };
    struct EnsoBasinState {
        uint64_t signature = 0;
        float temp_index = 0.0f;
        float recharge_index = 0.0f;
        float wind_ema = 0.0f;
        float wind_anomaly = 0.0f;
        int64_t last_update_tick = -1;
    };
    std::vector<int8_t> _enso_basin_id;
    std::vector<float> _enso_eastness;
    std::vector<float> _enso_prev_forcing;
    std::vector<int32_t> _enso_members;
    std::vector<EnsoBasinMeta> _enso_basins;
    std::vector<EnsoBasinState> _enso_states;
    std::vector<double> _enso_wind_sum;
    std::vector<int32_t> _enso_wind_count;
    uint64_t _enso_cache_fp = 0;
    bool _enso_cache_valid = false;
    bool _enso_cache_last_hit = false;
    double _enso_cache_build_ms = 0.0;
    godot::Dictionary _climate_modes_pending_restore;

    // ---- NS 化:风场回溯轨迹表缓存(Phase 0, plan/NS化气候动力学四方向深化) ----
    // 半拉格朗日几何缓存:每 cell 回溯终点所在三角形 (i0=self宿主, i1, i2) +
    // 重心权重 (w0,w1,w2),共 24B/cell(110k 格约 2.6MB)。wind pass 末由最终风槽
    // 构建;指纹 = pk_wind_state_fp(n_cells, WX, WY, WSP) 64 降采样。消费端
    // (weather field solve / wind_air) 复算指纹比对,失配落旧 hopping 并
    // _phys_wind_traj_stale_count++ 上报。派生 scratch,不占 component slot。
    std::vector<int32_t> _phys_wind_traj_idx;  // n*3
    std::vector<float>   _phys_wind_traj_w;    // n*3
    uint64_t _phys_wind_traj_fp = 0;
    uint32_t _phys_wind_traj_gen = 0;          // 构建代数(每次成功构建递增)
    bool     _phys_wind_traj_valid = false;
    bool     _phys_wind_traj_consume_enabled = true;  // knob wind_traj_weather_share
    int      _phys_wind_traj_stale_count = 0;
    // 动量旧通量快照(成员化):切片执行时由首切片(start_idx==0)重建、后续切片
    // 复用 → 切片==全量逐位一致(若每切片各拍,前序切片写回会污染后续邻居旧值)。
    std::vector<float> _phys_wind_snap_fx;  // n
    std::vector<float> _phys_wind_snap_fy;  // n

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
    // DCWorld 句柄。C++ pass 通过 `_flush_slot_to_map` 直写 MapData，原本绕过
    // DCWorld dirty mask；flush 现在按值差异累积精确 cell indices。
    godot::Object                            *_dirty_world = nullptr; // weak
    // 多个视觉槽共享一份 per-cell union mask，round 末尾只跨边界发布一次。
    bool                                      _pending_mark_dirty_all = false;
    godot::PackedByteArray                    _pending_visual_dirty_mask;
    int                                       _pending_visual_dirty_count = 0;
    bool                                      _pending_visual_dirty_dense = false;
    // Economy writes resource extra-change lanes directly into native slots.
    // Until the native resource pass consumes and publishes them, MapData
    // still contains the preceding committed mirror and must not overwrite
    // those slots during a generic refresh.
    std::vector<uint8_t>                      _economy_resource_slot_resident;
    // BIND_TABLE 反查记忆化。_flush_slot_to_map / refresh_slots_from_map_keys 原来
    // 每次调用都线性扫 148 条表项，每条现构一个 StringName（UTF-8 解析 + 全局
    // StringName 表加锁查找）。资源 pass 每日 flush 约 28 个 slot、refresh 约 68 个
    // key，累计上万次 StringName 构造。查找结果对 (comp_id → 表项) 是恒定的，
    // 首次解析后缓存：-2 未解析，-1 不在表内，>=0 为表项下标。
    // _slot_visual_dirty_cache 同理缓存 pk_slot_affects_visual_dirty 的 String
    // begins_with 链：0 未解析，1 否，2 是。
    std::vector<int16_t>                      _slot_bind_index_cache;
    std::vector<uint8_t>                      _slot_visual_dirty_cache;
    bool                                      _bound    = false;
    bool                                      _native_world_configured = false;
    int                                       _native_world_cell_count = 0;
    int                                       _native_daily_tick_count = 0;
    double                                    _native_daily_perf_target_ms = 1.0;
    // seam-advection-fix 2026-08-03：经度环绕周期 = map.width·√3，单位是 size=1.0 的单位
    // 六边形空间（**不含 hex_size**，因为 cell_pos_x slot 由 map_data.gd 以
    // cube_to_world(q, r, 1.0) 填充，列距恰为 √3/2）。
    // 由 configure_native_world 一次性常驻，供 climate/weather 平流与上风探测内核做
    // cell_pos_x 差分的最小映像折叠（pk_wrap_min_image_dx）。
    // 0 = 未配置环绕域 → 内核退化为裸差分（旧行为）。
    // 各 pass 的 knobs["wrap_period_x"] 仍可逐次覆盖，供单测与显式调用方使用。
    double                                    _native_wrap_period_x = 0.0;
    godot::Array                              _native_fronts_snapshot;
    godot::Dictionary                        _native_dirty_report;
    godot::Dictionary                        _native_daily_report;
    godot::Dictionary                        _native_shadow_diff_report;
    bool                                      _native_daily_slice_active = false;
    bool                                      _native_daily_visual_commit_pending = false;
    int                                       _native_daily_slice_node_index = 0;
    int                                       _native_daily_slice_cell_cursor = 0;
    int                                       _native_daily_slice_range_node_index = -1;
    int                                       _native_daily_slice_cell_budget = 0;
    uint32_t                                  _native_daily_slice_range_node_bits = 0u;
    // Bitmask of slice-graph node indices GDScript must JIT-patch before they run
    // (temp-dependent passes). C++ batches consecutive non-yield nodes in one call.
    // Default 0xFFFFFFFF = yield before every node (legacy one-node-per-call).
    uint32_t                                  _native_daily_slice_yield_bits = 0xFFFFFFFFu;
    int                                       _native_daily_slice_round_id = 0;
    double                                    _native_daily_slice_elapsed_accum_ms = 0.0;
    bool                                      _native_daily_slice_any_pass_ran = false;
    godot::Dictionary                        _native_daily_slice_tick_knobs;
    godot::Dictionary                        _native_daily_slice_bundle;
    godot::Dictionary                        _native_daily_slice_breakdown;
    godot::Array                             _native_daily_slice_bundle_pass_keys;
    godot::Array                             _native_daily_slice_retained_authority;
    godot::Dictionary                        _native_daily_slice_state_snapshot;
    godot::Dictionary                        _native_ocean_physical_state;
    godot::Dictionary                        _native_runtime_config;
    godot::Dictionary                        _native_generation_report;
    godot::Dictionary                        _native_generation_cfg;
    godot::Dictionary                        _native_generation_profile;
    bool                                      _native_generation_active = false;
    int                                       _native_generation_seed = 0;

    // NativeRuntimeGraph state. Runtime pointers above remain the authority;
    // this state stores only scheduler cursors, counters and dirty generations.
    bool                                      _runtime_graph_configured = false;
    bool                                      _runtime_graph_enabled = false;
    int64_t                                   _runtime_graph_day = -1;
    uint64_t                                  _runtime_graph_generation = 0;
    uint32_t                                  _runtime_graph_dirty_mask = 0;
    uint32_t                                  _runtime_graph_next_cursor = 0;
    uint64_t                                  _runtime_graph_pulse_count = 0;
    uint64_t                                  _runtime_graph_abi_calls = 0;
    uint64_t                                  _runtime_graph_callback_count = 0;
    uint64_t                                  _runtime_graph_work_done = 0;
    uint64_t                                  _runtime_graph_budget_yields = 0;
    uint64_t                                  _runtime_graph_economy_slices = 0;
    uint64_t                                  _runtime_graph_economy_commits = 0;
    uint64_t                                  _runtime_graph_trigger_blocked_pulses = 0;
    std::string                               _runtime_graph_trigger_blocked_reason;
    uint32_t                                  _runtime_graph_last_elapsed_us = 0;
    uint32_t                                  _runtime_graph_last_status = 0;
    godot::Dictionary                         _runtime_graph_last_economy_report;

    // ---- archetype ----
    godot::Vector<godot::Array>               _archetypes;          // each entry = comp_ids
    godot::HashMap<godot::StringName, int>    _archetype_by_name;
    godot::PackedInt32Array                   _entity_archetype;    // index by entity idx

    // ---- EXPERIMENTAL: D-async opaque state (defined in .cpp) ----------
    // Holds the std::unordered_map<int, AsyncTask> and a global mutex.
    // Allocated lazily on first async_* call; freed in shutdown_all().
    void                                     *_async_state = nullptr;

    // ---- Async Climate Round opaque state（plan §async-stage-1，2026-06-14） ----
    // 实际类型 pk_async_climate::AsyncClimateRoundState 在 .cpp 内部定义。
    // lazy alloc 在 async_climate_round_register；析构走 async_climate_round_shutdown
    // (~DCWorldExt 也会兜底调用)。与 _async_state 同模式（void* opaque pointer）。
    // 单实例：只支持一个 round-level async task。
    void                                     *_async_climate_round_state = nullptr;

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

    // ─── plan/atlas-pipeline-cpp（2026-05-20）：atlas pipeline opaque state ─
    // 实际类型 pk::AtlasPipelineState 在 .cpp 顶部定义。lazy alloc 在
    // run_atlas_pipeline_step 首次调用；析构走 PackedArray RAII。与
    // _summary_state 同模式（void* opaque pointer）。
    void                                     *_atlas_state            = nullptr;

    // Independent native economy authority. Concrete type lives in
    // economy_runtime.{h,cpp}; opaque here so the existing world header does
    // not expose the large chunk/market implementation to every pass TU.
    void                                     *_economy_runtime        = nullptr;
    uint64_t                                  _canal_topology_generation = 0;
    uint64_t                                  _canal_hydrology_compiled_generation =
        std::numeric_limits<uint64_t>::max();
    int32_t                                   _canal_hydrology_compiled_cell_count = -1;
    std::vector<int32_t>                      _canal_hydrology_cells;
    std::vector<uint8_t>                      _canal_hydrology_source_kind;
    std::vector<float>                        _canal_hydrology_strength;
    std::unordered_set<uint64_t>              _canal_commit_idempotency;
    std::vector<int32_t>                      _canal_visual_dirty_cells;
    void                                     *_economy_csv_recorder   = nullptr;
    int64_t                                   _economy_last_notified_event_id = 0;
    void                                     *_country_runtime        = nullptr;
    void                                     *_modifier_runtime       = nullptr;
    void                                     *_trigger_runtime         = nullptr;
    void                                     *_effect_runtime          = nullptr;
    void                                     *_ideology_runtime        = nullptr;
    uint64_t                                  _natural_resource_modifier_version =
        std::numeric_limits<uint64_t>::max();
    uint64_t                                  _natural_resource_modifier_catalog_hash = 0;
    uint64_t                                  _natural_resource_modifier_ids_hash = 0;
    int32_t                                   _natural_resource_modifier_cells = -1;
    int32_t                                   _natural_resource_modifier_active_factor_count = 0;
    godot::PackedFloat32Array                 _natural_resource_regen_factors;
    // 因子表只在 modifier 快照变动时重建，但 run_natural_resource_pass 原来每日
    // 重扫整表（resource_count × n_cells）做有限性校验与 active 计数，再对每个动态
    // 资源额外扫一遍 n_cells 判断 has_regen_modifier。表没变时结论恒定，故在重建
    // 处一次算清并缓存；pass 侧凭 (snapshot_version, factor_count) 命中即跳过。
    std::vector<uint8_t>                      _natural_resource_regen_resource_active;
    bool                                      _natural_resource_regen_summary_valid = false;
    bool                                      _natural_resource_regen_summary_rejected = false;

    // Bio occupancy keeps deterministic full-map semantics in phase one, but
    // reuses its cell lanes across daily calls. Published PackedArrays remain
    // transient output; these members only own native staging capacity.
    std::vector<int32_t>                      _bio_occupancy_bits_staging;
    std::vector<int32_t>                      _bio_occupancy_previous;
    std::vector<int32_t>                      _bio_occupancy_additions;
    godot::PackedInt32Array                   _bio_newly_occupied_cells;
    godot::PackedInt32Array                   _bio_newly_occupied_signals;
    void                                     *_bio_native_config_state = nullptr;
    void                                     *_bio_occupancy_slice_state = nullptr;
    void                                     *_vision_research_state = nullptr;

    // ─── Phase B+（2026-05-21）：season refresh round 切片调度 opaque state ─
    // 实际类型 pk::SeasonRoundState 在 world_ext.cpp 顶部定义（含 generation
    // 计数器 / current stage / round_knobs 缓存 / 计时累加）。lazy alloc 在
    // start_season_round 首次成功路径；abort_season_round 内手动 delete + 置
    // null；DCWorldExt 析构内自动清理（与 _summary_state / _atlas_state 同模式）。
    // B+ b1 粒度：每 slice 跑整 stage（不在 stage 内 cursor 切片）。
    void                                     *_season_round           = nullptr;

    // q/r → cell idx 反查 hash（summary pass cube_to_idx 用）。lazy rebuild：
    // 在 run_weather_summary_fronts_pass 内部，发现 _summary_qr_to_idx_size !=
    // n_cells 时清空重建。size 不变（即 cell 拓扑稳定）时直接复用。
    std::unordered_map<int64_t, int>          _summary_qr_to_idx;
    int                                       _summary_qr_to_idx_size = -1;

    // ─── plan/weather-refresh-cpp-all: cyclone wake 持久化状态 ───────────
    // 等价于 weather_system.ocean_current_perturbation Dictionary<key, entry> 的
    // C++ 镜像。key = cell.q*10000+cell.r （与 GDScript 1:1 对齐，C++ 端用 int64_t
    // 存储兼容负坐标 hash）。Entry 跨 tick 存活：每日 cyclone_wake_step 头部衰减/
    // 淘汰，尾部按 STORM front 中心 cell 注入。GDScript 端通过
    // get_cyclone_perturbations_dict() 拉镜像。
    struct CycloneWakeEntry {
        uint64_t     stable_id = 0;
        int64_t      key = 0;       // cell.q * 10000 + cell.r
        int          cell_idx = -1;
        godot::Vector2 vec;
        godot::Vector2 vec_init;
        godot::Vector2 steering;
        float        intensity = 0.0f;
        float        radius_cells = 2.0f;
        float        age_days = 0.0f;
        float        move_progress = 0.0f;
        int          days_left = 0; // compatibility projection
        int          init_days = 0;
    };
    std::vector<CycloneWakeEntry>  _cyclone_perturbations;
    uint64_t                       _cyclone_next_stable_id = 1;
    uint32_t                       _cyclone_force_generation = 0;
    std::vector<uint32_t>          _cyclone_force_tag;
    std::vector<uint32_t>          _cyclone_visit_tag;
    std::vector<float>             _cyclone_force_x;
    std::vector<float>             _cyclone_force_y;
    std::vector<float>             _cyclone_force_lift;
    int                            _cyclone_last_touched_cells = 0;
    int                            _cyclone_total_genesis = 0;
    int                            _cyclone_total_decay = 0;

    // Stage6c (2026-06-23): 对流抑制记忆，per-cell，跨 tick/slice 存活的 C++ 端权威状态。
    // 上一版走 knob in/out 数组经 const Dictionary CoW 回传失败(实测抑制 no-op)，改存为 ext 成员→
    // 无边界穿越、保证持久。run_weather_field_solve_pass 读写；尺寸变化(换地图)时清零。
    std::vector<float>             _wx_conv_inhib;
    // Synoptic eddy field ψ (emergent weather variability). Prognostic, per-cell, cross-tick.
    // Double-buffered as ext members (proven round-trip, like _wx_conv_inhib): _prev is the
    // round-start snapshot read for advection; _cur is written this round. Sized on map change.
    std::vector<float>             _wx_synoptic;
    std::vector<float>             _wx_synoptic_prev;

    // ─── 天气邻域几何缓存（perf P2，2026-06-29）────────────────────────────
    // run_weather_field_solve_pass 在每轮 start_idx==0 用 wf_wrapped_delta 预算
    // 每 cell 6 邻居的 self->nb wrapped delta (dx,dy) 与 inv_dist=1/sqrt(|d|²)。
    // 主循环 aligned_idx / upstream chain / convergence 改读缓存→消除热循环内
    // 重复 wrapped_delta/sqrt。bit-equal：缓存值由相同 wf_wrapped_delta/Math::sqrt
    // 同序算出。尺寸(换图)或 wrap 变化时由 build 逻辑重填。
    std::vector<float>             _wf_nb_dx;            // n*6, self->nb wrapped delta x
    std::vector<float>             _wf_nb_dy;            // n*6, self->nb wrapped delta y
    std::vector<float>             _wf_nb_invd;          // n*6, 1/sqrt(|d|²) 或 0 (dl2<=1e-4 哨兵)
    int                            _wf_nb_geom_n = 0;    // 已构建几何缓存的 n_cells（0=未填）
    float                          _wf_nb_geom_wrap = -1.0f;  // 构建时的 wrap_width_x（变更→失效）

    // ─── 生成期河流拓扑缓存（dots-total-cpp step1，2026-06-25）────────────
    // run_native_world_generate_post_base_pass 末尾把 river 拓扑（by cell.index）暂存为 ext 成员，
    // 供同一 generation ext 实例的 run_bake_river_sdf_pass 直接 trace（零跨语言再传输）。
    // 换图（n_cells 变化）或新生成时由 post-base 重填覆盖。tracing 复刻 map_baker.gd::_trace_all_rivers。
    int                            _gen_river_n = 0;          // n_cells（0=未填）
    std::vector<int32_t>           _gen_river_q;              // cube q
    std::vector<int32_t>           _gen_river_r;              // cube r
    std::vector<uint8_t>           _gen_river_terrain;        // 最终 terrain（含所有翻转）
    std::vector<float>             _gen_river_elev;           // 最终 elevation
    std::vector<uint8_t>           _gen_river_has;            // has_river 0/1
    std::vector<float>             _gen_river_flow;           // river_flow（生成期宽度源）
    std::vector<int32_t>           _gen_river_downstream;     // declared downstream cell index（-1=无）
    std::vector<int32_t>           _gen_river_neighbors;      // n*6 邻居 cell index（-1=越界），DQ/DR 序

    struct GameplayEventRecord {
        int64_t event_id = 0;
        int64_t tick = 0;
        int32_t phase = 0;
        int32_t type = 0;
        int32_t source = 0;
        int32_t flags = 0;
        uint64_t entity_handle = 0;
        int32_t entity_id = -1;
        int32_t cell_idx = -1;
        int32_t payload_schema = 0;
        int64_t value_i64 = 0;
        int32_t payload_i0 = 0;
        int32_t payload_i1 = 0;
        int32_t payload_i2 = 0;
        int32_t payload_i3 = 0;
    };
    struct EffectGameplayCommandResult {
        uint8_t complete = 0;
        uint8_t ok = 0;
        std::string reason;
    };
    std::deque<GameplayEventRecord>         _gameplay_events;
    godot::HashMap<godot::StringName, int64_t> _gameplay_consumer_ack;
    int64_t                                 _gameplay_next_event_id = 1;
    int64_t                                 _gameplay_dropped_event_count = 0;
    int64_t                                 _gameplay_first_dropped_event_id = 0;
    int                                     _gameplay_max_events = 8192;
    double                                  _gameplay_last_native_ms = 0.0;
    godot::String                           _gameplay_last_fallback_reason;
    std::vector<EffectGameplayCommand>      _effect_gameplay_commands;
    std::unordered_map<int64_t, EffectGameplayCommandResult>
                                                _effect_gameplay_results;
    std::unordered_map<uint64_t, int64_t>   _effect_gameplay_idempotency;
    std::unordered_map<uint64_t, int64_t>   _effect_gameplay_event_ids;
    int64_t                                 _effect_gameplay_next_request_id = 1;

    // 内部辅助：cyclone wake 一日推进。由 run_weather_refresh_daily_pass 调用。
    // fronts 入参 = run_weather_summary_fronts_pass 返回的 Array[Dictionary]
    // （含 type/center/intensity/velocity 字段，与 GDScript WeatherFront 1:1）。
    // 返回耗时 ms（含 phase1 衰减/淘汰 + phase2 注入）。
    //
    // 细粒度遥测（Phase B.2）：通过 knobs by-ref 写回 6 个字段（与 stage_b 同模式）：
    //   cyclone_phase1_decay_ms : double  Phase 1 总耗时 ms
    //   cyclone_phase2_inject_ms: double  Phase 2 总耗时 ms
    //   cyclone_n_decayed       : int     Phase 1 衰减后仍存活的 entry 数
    //   cyclone_n_evicted       : int     Phase 1 淘汰的 entry 数
    //   cyclone_n_replaced      : int     Phase 2 命中已有 key 覆盖更新的次数
    //   cyclone_n_injected      : int     Phase 2 新增 entry 的次数
    // caller 需要 by-value 复制 knobs 再传入（避免污染上游 Dictionary 引用），
    // 等价于 stage_b_pass 的处理模式（world_ext.cpp:7750）。
    double cyclone_wake_step(godot::Dictionary &knobs,
                             const godot::Array &fronts_from_summary);
    void _advance_and_stamp_cyclones(const godot::Dictionary &knobs,
                                     int n_cells, const int32_t *neighbors,
                                     const godot::Vector2 *positions,
                                     const uint8_t *terrain, const float *temp,
                                     const float *wind_x, const float *wind_y,
                                     const float *wind_speed, const float *vapor,
                                     const float *instability,
                                     const float *convergence,
                                     const float *lat_norm);
    void _ensure_enso_basin_cache(int n_cells, const uint8_t *is_water,
                                  const uint8_t *terrain, const float *lat_norm,
                                  const float *pos_x, const int32_t *neighbors,
                                  const godot::PackedByteArray &ocean_terrain_ids,
                                  float tropical_lat_limit, int max_basins,
                                  float wrap_period_x, int world_seed);
    void _apply_enso_ocean_slice(godot::Dictionary &knobs, int n_cells,
                                 int start_idx, int end_idx,
                                 const uint8_t *is_water,
                                 const uint8_t *terrain, const float *lat_norm,
                                 const float *pos_x, const int32_t *neighbors,
                                 const float *wind_x, const float *wind_speed,
                                 float *ocean_anomaly, float *transport_anomaly);

    // ---- helpers ----
    void _ensure_slot_capacity(Slot &slot, int new_count);
    void _flush_slot_to_map(int comp_id);
    int  _bind_index_for_slot(int comp_id);
    bool _slot_is_visual_dirty(int comp_id);
    godot::Dictionary _queue_bio_observations(
        int64_t country_handle, int64_t effective_day,
        const godot::PackedInt32Array &cells,
        const godot::PackedInt32Array &signals);
    int64_t _emit_gameplay_event(int64_t tick,
                                 int32_t phase,
                                 int32_t type,
                                 int32_t source,
                                 int32_t flags,
                                 uint64_t entity_handle,
                                 int32_t entity_id,
                                 int32_t cell_idx,
                                 int32_t payload_schema,
                                 int64_t value_i64,
                                 int32_t payload_i0,
                                 int32_t payload_i1,
                                 int32_t payload_i2,
                                 int32_t payload_i3);
    void _emit_succession_events(const godot::PackedInt32Array &indices,
                                 const godot::PackedByteArray &to_veg,
                                 const uint8_t *old_veg,
                                 int old_veg_size,
                                 int64_t tick,
                                 int32_t phase,
                                 int32_t source);
    void _append_gameplay_event_to_arrays(const GameplayEventRecord &ev,
                                          godot::PackedInt64Array &ids,
                                          godot::PackedInt64Array &ticks,
                                          godot::PackedInt32Array &phase,
                                          godot::PackedInt32Array &type,
                                          godot::PackedInt32Array &source,
                                          godot::PackedInt32Array &flags,
                                          godot::PackedInt64Array &entity_handle,
                                          godot::PackedInt32Array &entity,
                                          godot::PackedInt32Array &cell,
                                          godot::PackedInt32Array &schema,
                                          godot::PackedInt64Array &value,
                                          godot::PackedInt32Array &p0,
                                          godot::PackedInt32Array &p1,
                                          godot::PackedInt32Array &p2,
                                          godot::PackedInt32Array &p3) const;
    godot::Dictionary _run_native_generation_publish_pass(
        int seed,
        const godot::Dictionary &cfg,
        const godot::Dictionary &profile,
        const godot::Dictionary &budget);
};

} // namespace pk

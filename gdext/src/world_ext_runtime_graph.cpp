#include "world_ext.h"

#include "country_runtime.h"
#include "native_simulation_host.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "modifier_runtime.h"
#include "native_parallel_executor.h"
#include "trigger_runtime.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <limits>

namespace pk {

using namespace godot;

namespace {
using Clock = std::chrono::steady_clock;

enum RuntimeDirtyFamily : uint32_t {
    DIRTY_CLOCK = 1u << 0,
    DIRTY_COUNTRY_STATE = 1u << 1,
    DIRTY_COUNTRY_TERRITORY = 1u << 2,
    DIRTY_COUNTRY_VISUAL_ERA = 1u << 3,
    DIRTY_CLIMATE_FIELDS = 1u << 4,
    DIRTY_WEATHER = 1u << 5,
    DIRTY_ECONOMY_UI = 1u << 6,
    DIRTY_EVENTS = 1u << 7,
    DIRTY_OVERLAY = 1u << 8,
};

static uint32_t elapsed_us(Clock::time_point start) {
    const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
        Clock::now() - start).count();
    return static_cast<uint32_t>(std::clamp<int64_t>(us, 0, 0xffffffffll));
}

static int64_t make_token(int64_t day, uint32_t status, uint32_t dirty,
                          uint32_t flags) {
    // [63:48] status/flags, [47:32] dirty mask, [31:0] committed day.
    const uint64_t hi = (static_cast<uint64_t>(status & 0xffu) << 56) |
        (static_cast<uint64_t>(flags & 0xffu) << 48) |
        (static_cast<uint64_t>(dirty & 0xffffu) << 32);
    return static_cast<int64_t>(hi | (static_cast<uint64_t>(day) & 0xffffffffull));
}
} // namespace

int DCWorldExt::configure_runtime_graph(const Dictionary &boot_config) {
    NativeParallelExecutor::instance().set_interactive(false);
    _runtime_graph_configured = false;
    _runtime_graph_enabled = bool(boot_config.get("enabled", false));
    _runtime_graph_day = int64_t(boot_config.get("day", -1));
    _runtime_graph_generation = uint64_t(boot_config.get("generation", 0));
    _runtime_graph_dirty_mask = 0;
    _runtime_graph_next_cursor = 0;
    _runtime_graph_pulse_count = 0;
    _runtime_graph_abi_calls = 0;
    _runtime_graph_callback_count = 0;
    _runtime_graph_work_done = 0;
    _runtime_graph_budget_yields = 0;
    _runtime_graph_economy_slices = 0;
    _runtime_graph_economy_commits = 0;
    _runtime_graph_trigger_blocked_pulses = 0;
    _runtime_graph_trigger_blocked_reason.clear();
    _runtime_graph_last_elapsed_us = 0;
    _runtime_graph_last_status = 0;
    _runtime_graph_post_pulse_flush_ms = 0.0;
    _runtime_graph_country_territory_sync_ms = 0.0;
    _runtime_graph_flush_slot_count = 0;
    _runtime_graph_visual_diff_cell_count = 0;
    _runtime_graph_full_flush_count = 0;
    _runtime_graph_configured = true;
    return 0;
}

int64_t DCWorldExt::advance_runtime_pulse(int64_t day, double season_phase,
                                          double speed_scale, int budget_us,
                                          int flags) {
    const auto started = Clock::now();
    ++_runtime_graph_abi_calls;
    if (!_runtime_graph_configured || !_runtime_graph_enabled) {
        _runtime_graph_last_status = 0;
        _runtime_graph_last_elapsed_us = elapsed_us(started);
        return make_token(day, 0, _runtime_graph_dirty_mask,
                          static_cast<uint32_t>(flags));
    }

    _runtime_graph_day = day;
    const int limit_us = std::max(250, budget_us);
    uint32_t status = 1; // progressed
    uint32_t work = 0;
    uint32_t dirty = 0;
    int iterations = 0;

    auto over_budget = [&]() {
        return static_cast<int>(elapsed_us(started)) >= limit_us;
    };
    auto ctx_for = [&]() {
        Dictionary ctx;
        ctx["day_index"] = day;
        ctx["tick_index"] = static_cast<int64_t>(_runtime_graph_pulse_count);
        ctx["season_phase"] = season_phase;
        ctx["speed_scale"] = speed_scale;
        ctx["slice_budget_ms"] = static_cast<double>(limit_us) / 1000.0;
        ctx["source"] = StringName("native_runtime_graph");
        return ctx;
    };
    auto ran = [&](const Dictionary &result, uint32_t family) {
        ++work;
        const int64_t changed = static_cast<int64_t>(result.get("changed_cells", 0));
        const int64_t changed_countries =
            static_cast<int64_t>(result.get("changed_countries", 0));
        if (changed > 0 || changed_countries > 0 ||
            bool(result.get("published_to_slot", false))) dirty |= family;
        if (bool(result.get("done", false))) status = 2;
    };

    auto ingest_trigger_events = [&]() {
        if (_trigger_runtime == nullptr) return uint32_t{0};
        TriggerRuntime *trigger = static_cast<TriggerRuntime *>(_trigger_runtime);
        const StringName consumer("trigger_runtime");
        const int64_t *stored_cursor = _gameplay_consumer_ack.getptr(consumer);
        int64_t cursor = stored_cursor != nullptr ? *stored_cursor : int64_t{0};
        uint32_t ingested = 0;
        for (const GameplayEventRecord &event : _gameplay_events) {
            if (event.event_id <= cursor) continue;
            TriggerRuntime::EventInput input;
            input.source_id = event.source;
            input.event_id = event.event_id;
            input.day = day;
            input.event_type = event.type;
            input.payload_schema = event.payload_schema;
            input.entity_handle = event.entity_handle != 0
                ? event.entity_handle : static_cast<uint64_t>(std::max(0, event.entity_id));
            input.group_handle = static_cast<uint64_t>(std::max(0, event.cell_idx));
            input.value = event.value_i64;
            input.payload = {event.payload_i0, event.payload_i1,
                             event.payload_i2, event.payload_i3};
            size_t accepted = 0;
            int64_t last_accepted = 0;
            std::string error;
            if (!trigger->submit_events_pod(&input, 1, accepted,
                                            last_accepted, error) || accepted != 1) {
                break;
            }
            cursor = last_accepted;
            ++ingested;
            if (ingested >= 512) break;
        }
        if (ingested > 0) _gameplay_consumer_ack[consumer] = cursor;
        return ingested;
    };

    // TriggerRuntime::should_run() stays true while its effect queue is not
    // empty. When handoff refuses the head effect (no native adapter for that
    // action, or a peer runtime rejected it) the queue can never drain, and
    // re-entering trigger every iteration burns the whole pulse budget on an
    // effect that will be refused again. Retire trigger for the rest of this
    // pulse as soon as handoff reports blocked, and keep the reason for
    // diagnostics.
    bool trigger_handoff_blocked = false;

    // Stable order mirrors the existing GDScript ACK chain and scheduler
    // priorities. Each runtime owns its own persistent range cursor.
    while (iterations++ < 64 && !over_budget()) {
        bool progressed = false;
        Dictionary ctx = ctx_for();
        if (_country_runtime != nullptr &&
            static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_country();
            Dictionary country_result = run_country_slice(ctx);
            uint32_t country_dirty = DIRTY_COUNTRY_STATE;
            if (static_cast<int64_t>(country_result.get("changed_cells", 0)) > 0)
                country_dirty |= DIRTY_COUNTRY_TERRITORY | DIRTY_OVERLAY;
            ran(country_result, country_dirty);
            if (_effect_runtime != nullptr) ack_effect_native_country();
            progressed = true;
        }
        if (over_budget()) break;
        const uint32_t ingested_events = ingest_trigger_events();
        if (ingested_events > 0) {
            work += ingested_events;
            progressed = true;
        }
        if (_trigger_runtime != nullptr && !trigger_handoff_blocked &&
            static_cast<TriggerRuntime *>(_trigger_runtime)->should_run(day)) {
            ran(run_trigger_daily(day), DIRTY_EVENTS);
            if (_effect_runtime != nullptr) {
                const Dictionary handoff = handoff_trigger_effects(512);
                if (bool(handoff.get("blocked", false))) {
                    trigger_handoff_blocked = true;
                    const std::string reason =
                        String(handoff.get("reason", "trigger_effect_handoff_blocked"))
                            .utf8().get_data();
                    const String command_key =
                        String(handoff.get("blocked_command_key", ""));
                    const String definition_key =
                        String(handoff.get("blocked_definition_key", ""));
                    std::string snapshot_reason = reason;
                    if (!command_key.is_empty()) {
                        snapshot_reason += ":";
                        snapshot_reason += command_key.utf8().get_data();
                        snapshot_reason += "/";
                        snapshot_reason += definition_key.utf8().get_data();
                    }
                    if (snapshot_reason != _runtime_graph_trigger_blocked_reason) {
                        _runtime_graph_trigger_blocked_reason = snapshot_reason;
                        UtilityFunctions::push_warning(
                            String("[sim/graph-trigger] handoff blocked day=") +
                            String::num_int64(day) + String(" reason=") +
                            String(reason.c_str()) +
                            String(" command_key=") + command_key +
                            String(" definition_key=") + definition_key +
                            String(" action=") +
                            String::num_int64(int64_t(handoff.get("blocked_action", 0))) +
                            String(" opcode=") +
                            String::num_int64(int64_t(handoff.get("blocked_opcode", 0))) +
                            String(" — trigger effect queue cannot drain; "
                                   "trigger is retired for the rest of each pulse"));
                    }
                }
            }
            progressed = true;
        }
        if (over_budget()) break;
        if (_ideology_runtime != nullptr &&
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->should_run(day)) {
            ran(run_ideology_daily(day), DIRTY_COUNTRY_STATE | DIRTY_EVENTS);
            progressed = true;
        }
        if (over_budget()) break;
        if (_effect_runtime != nullptr &&
            static_cast<EffectRuntime *>(_effect_runtime)->should_run(day)) {
            ran(run_effect_daily(day), DIRTY_EVENTS);
            // A native effect transaction can be waiting for an ACK even when
            // the peer runtime has no independent daily work.  ACK every
            // adapter after effect evaluation so the transaction can reach a
            // terminal state instead of keeping effect_should_run() hot.
            if (_effect_runtime != nullptr) {
                dispatch_effect_native_country();
                dispatch_effect_native_economy();
                dispatch_effect_native_modifier();
                dispatch_effect_native_gameplay();
                ack_effect_native_country();
                ack_effect_native_economy();
                ack_effect_native_modifier();
                ack_effect_native_gameplay();
            }
            progressed = true;
        }
        if (over_budget()) break;
        if (_modifier_runtime != nullptr &&
            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_modifier();
            ran(run_modifier_daily(day), DIRTY_COUNTRY_STATE);
            if (_effect_runtime != nullptr) ack_effect_native_modifier();
            progressed = true;
        }
        if (over_budget()) break;
        if (_effect_runtime != nullptr && gameplay_effect_should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_gameplay();
            ran(run_gameplay_effects(day), DIRTY_EVENTS | DIRTY_OVERLAY);
            if (_effect_runtime != nullptr) ack_effect_native_gameplay();
            progressed = true;
        }
        // Economy is the terminal hard-domain in this deterministic chain. A
        // busy Effect/ACK queue may consume the pulse budget, but it must not
        // starve an overdue economy range forever. Let one native economy
        // slice start after the ordered ACK dispatch; the slice itself owns
        // its cursor and the next loop/pulse will resume from that boundary.
        if (_economy_runtime != nullptr && economy_should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_economy();
            Dictionary economy_result = run_economy_slice_compact(ctx);
            ++_runtime_graph_economy_slices;
            if (bool(economy_result.get("done", false)))
                ++_runtime_graph_economy_commits;
            ran(economy_result, DIRTY_ECONOMY_UI);
            if (_effect_runtime != nullptr) ack_effect_native_economy();
            _runtime_graph_last_economy_report = economy_result;
            progressed = true;
        }
        if (!progressed) {
            status = 2;
            break;
        }
    }
    if (over_budget()) ++_runtime_graph_budget_yields;
    if (trigger_handoff_blocked) ++_runtime_graph_trigger_blocked_pulses;
    // A runtime may still own a persistent cursor even when this pulse did not
    // hit the wall-clock budget (for example a range cap stopped the loop).
    // Keep the committed-day barrier armed until every hard domain reports idle.
    //
    // Only the hard domains below may arm it. Running out of wall-clock budget
    // is deliberately NOT sufficient: Trigger/Ideology own soft cursors that
    // legitimately carry work into tomorrow, so a pulse that spends its whole
    // budget on them must still let WorldClock commit the day. Arming on the
    // budget yield alone froze the calendar for as long as trigger stayed
    // busy, because the frozen day kept trigger's own work queued.
    const bool pending =
        (_country_runtime != nullptr &&
         static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day)) ||
        (_effect_runtime != nullptr &&
         static_cast<EffectRuntime *>(_effect_runtime)->should_run(day)) ||
        (_modifier_runtime != nullptr &&
         static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) ||
        (_effect_runtime != nullptr && gameplay_effect_should_run(day)) ||
        (_economy_runtime != nullptr && economy_should_run(day));
    if (pending) status = 3;
    _runtime_graph_dirty_mask |= dirty;
    _runtime_graph_next_cursor += work;
    _runtime_graph_work_done += work;
    ++_runtime_graph_pulse_count;
    _runtime_graph_last_status = status;
    _runtime_graph_last_elapsed_us = elapsed_us(started);
    return make_token(day, status, _runtime_graph_dirty_mask,
                      static_cast<uint32_t>(flags));
}

Dictionary DCWorldExt::get_runtime_graph_last_economy_report() const {
    return _runtime_graph_last_economy_report;
}

void DCWorldExt::flush_runtime_visuals(uint32_t dirty_mask) {
    const auto started = Clock::now();
    const uint32_t requested = dirty_mask == 0
        ? std::numeric_limits<uint32_t>::max() : dirty_mask;
    const uint32_t pending = _runtime_graph_dirty_mask & requested;
    // Domain commits already publish their concrete slots. Graph-level flush
    // is an acknowledgement boundary only; a second full-table flush caused
    // redundant CoW comparisons and MapData property writes.
    _runtime_graph_dirty_mask &= ~pending;
    if (pending != 0) ++_runtime_graph_generation;
    _runtime_graph_post_pulse_flush_ms =
        static_cast<double>(elapsed_us(started)) / 1000.0;
}

static String runtime_effective_mode_name(const RuntimeThreadReport &report) {
    if (report.mode == RuntimeSimulationMode::SHADOW) return "SHADOW";
    if (report.mode == RuntimeSimulationMode::ACTIVE && report.authority_ready)
        return "ACTIVE";
    return "OFF";
}

void DCWorldExt::set_runtime_qos(bool interactive) {
    if (_runtime_host) _runtime_host->set_interactive(interactive);
    NativeParallelExecutor::instance().set_interactive(interactive);
}

Dictionary DCWorldExt::get_runtime_thread_report() const {
    const NativeParallelExecutor::Report report =
        NativeParallelExecutor::instance().report();
    Dictionary out;
    if (_runtime_host) {
        const RuntimeThreadReport host = _runtime_host->report();
        out["runtime_domain_abi_version"] = static_cast<int>(host.domain_abi_version);
        out["pod_domain_abi_version"] = static_cast<int>(host.pod_domain_abi_version);
        const char *state = "UNKNOWN";
        switch (host.state) {
            case RuntimeWorkerState::STOPPED: state = "STOPPED"; break;
            case RuntimeWorkerState::STARTING: state = "STARTING"; break;
            case RuntimeWorkerState::RUNNING: state = "RUNNING"; break;
            case RuntimeWorkerState::PAUSED: state = "PAUSED"; break;
            case RuntimeWorkerState::SAVE_PENDING: state = "SAVE_PENDING"; break;
            case RuntimeWorkerState::STOPPING: state = "STOPPING"; break;
            case RuntimeWorkerState::FAULTED: state = "FAULTED"; break;
        }
        out["simulation_host_state"] = state;
        // Keep the raw readiness bit in the direct report.  The effective
        // mode intentionally remains OFF until every native domain is proven;
        // callers still need to distinguish a merely running SHADOW worker
        // from an authority-ready worker without relying on a missing-key
        // default.
        out["authority_ready"] = host.authority_ready;
        out["graph_coverage_complete"] = host.graph_coverage_complete;
        out["simulation_thread_mode"] = runtime_effective_mode_name(host);
        out["requested_simulation_thread_mode"] =
            host.mode == RuntimeSimulationMode::ACTIVE ? "ACTIVE" :
            host.mode == RuntimeSimulationMode::SHADOW ? "SHADOW" : "OFF";
        out["simulation_worker_ready"] = host.authority_ready;
        out["state"] = state;
        out["state_id"] = static_cast<int>(host.state);
        out["domain_abi_version"] = static_cast<int>(host.domain_abi_version);
        out["graph_coverage_state"] = String(host.graph_coverage_state);
        out["required_domain_mask"] = static_cast<int64_t>(host.required_domain_mask);
        out["implemented_domain_mask"] = static_cast<int64_t>(host.implemented_domain_mask);
        out["missing_domain_mask"] = static_cast<int64_t>(host.missing_domain_mask);
        out["simulation_worker_blocker"] = String(host.coverage_blocker).is_empty()
            ? String(host.fault_code)
            : String(host.coverage_blocker);
        out["simulation_committed_day"] = host.committed_day;
        out["simulation_generation"] = static_cast<int64_t>(host.generation);
        out["generation"] = static_cast<int64_t>(host.generation);
        out["simulation_state_hash"] = static_cast<int64_t>(host.state_hash);
        out["state_hash"] = static_cast<int64_t>(host.state_hash);
        out["last_commit_produced_at_us"] = static_cast<int64_t>(host.last_commit_produced_at_us);
        out["last_visual_publish_at_us"] = static_cast<int64_t>(host.last_visual_publish_at_us);
        out["snapshot_staleness_ms"] = host.snapshot_staleness_ms;
        out["ui_input_to_feedback_ms"] = host.ui_input_to_feedback_ms;
        out["visual_apply_ms"] = host.visual_apply_ms;
        out["gpu_upload_ms"] = host.gpu_upload_ms;
        out["main_wait_on_sim_us"] = static_cast<int64_t>(host.main_wait_on_sim_us);
        out["simulation_environment_generation"] = static_cast<int64_t>(host.environment_generation);
        out["simulation_environment_day"] = host.environment_day;
        out["simulation_environment_cell_count"] = static_cast<int>(host.environment_cell_count);
        out["simulation_environment_topology_validated"] = host.environment_topology_validated;
        out["simulation_invalid_environment_rejected"] = static_cast<int64_t>(host.invalid_environment_rejected);
        out["stale_environment_rejected"] = static_cast<int64_t>(host.stale_environment_rejected);
        out["simulation_time_debt_days"] = host.time_debt_days;
        // Keep the unprefixed spelling available to lightweight callers that
        // consume the direct host report. Both fields describe the same
        // bounded debt value; the prefixed form remains the CSV contract.
        out["time_debt_days"] = host.time_debt_days;
        out["snapshot_publish_drop_count"] = static_cast<int64_t>(host.snapshot_publish_drop_count);
        out["snapshot_publish_throttled_count"] = static_cast<int64_t>(host.snapshot_publish_throttled_count);
        out["command_queue_capacity_exceeded"] = static_cast<int64_t>(host.command_queue_capacity_exceeded);
        out["receipt_queue_capacity_exceeded"] = static_cast<int64_t>(host.receipt_queue_capacity_exceeded);
        out["worker_fault_count"] = static_cast<int64_t>(host.worker_fault_count);
        out["day_stage_count"] = static_cast<int>(host.day_stage_count);
        out["day_completed_stage_count"] = static_cast<int>(host.day_completed_stage_count);
        out["day_work_units"] = static_cast<int64_t>(host.day_work_units);
        out["completed_days"] = static_cast<int64_t>(host.completed_days);
        out["pod_completed_domain_mask"] = static_cast<int64_t>(host.pod_completed_domain_mask);
        out["pod_completed_stage_count"] = static_cast<int>(host.pod_completed_stage_count);
        out["pod_work_units"] = static_cast<int64_t>(host.pod_work_units);
        out["pod_intent_count"] = static_cast<int>(host.pod_intent_count);
        out["pod_fallback_count"] = static_cast<int>(host.pod_fallback_count);
        out["domain_authority_planned_mask"] = static_cast<int64_t>(
            host.domain_authority_planned_mask);
        out["domain_authority_committed_mask"] = static_cast<int64_t>(
            host.domain_authority_committed_mask);
        out["domain_authority_ack_count"] = static_cast<int>(
            host.domain_authority_ack_count);
        out["domain_authority_input_hash"] = static_cast<int64_t>(
            host.domain_authority_input_hash);
        out["domain_authority_state_hash"] = static_cast<int64_t>(
            host.domain_authority_state_hash);
        out["domain_authority_plan_ms"] = host.domain_authority_plan_ms;
        out["domain_authority_replay_ms"] = host.domain_authority_replay_ms;
        out["domain_authority_fallback_reason"] = String(
            host.domain_authority_fallback_reason);
        out["domain_stage_fallback_count"] = static_cast<int>(
            host.domain_stage_fallback_count);
        out["domain_stage_fallback_reason"] = String(
            host.domain_stage_fallback_reason);
        // Climate POD remains SHADOW-only diagnostic work. Keep the direct
        // thread report aligned with get_runtime_perf_snapshot() so callers
        // do not infer its availability from which facade they queried.
        out["climate_pod_ready"] = host.climate_pod_ready;
        out["climate_pod_plan_ms"] = host.climate_pod_plan_ms;
        out["climate_pod_replay_ms"] = host.climate_pod_replay_ms;
        out["climate_pod_work_units"] = static_cast<int64_t>(host.climate_pod_work_units);
        out["climate_pod_changed_cells"] = static_cast<int>(host.climate_pod_changed_cells);
        out["climate_pod_state_hash"] = static_cast<int64_t>(host.climate_pod_state_hash);
        out["climate_pod_reference_hash"] = static_cast<int64_t>(
            host.climate_pod_reference_hash);
        out["climate_pod_parity_compared"] = host.climate_pod_parity_compared;
        out["climate_pod_parity_matched"] = host.climate_pod_parity_matched;
        out["climate_pod_parity_mismatch_count"] = static_cast<int64_t>(
            host.climate_pod_parity_mismatch_count);
        out["climate_pod_parity_reason"] = String(host.climate_pod_parity_reason);
        out["climate_pod_fallback_reason"] = String(host.climate_pod_fallback_reason);
        out["climate_trace_depth"] = static_cast<int>(host.climate_trace_depth);
        out["climate_trace_front_day"] = host.climate_trace_front_day;
        out["climate_trace_lag_days"] = host.climate_trace_lag_days;
        out["climate_trace_latest_hash"] = static_cast<int64_t>(host.climate_trace_latest_hash);
        out["climate_trace_consumed"] = static_cast<int64_t>(host.climate_trace_consumed);
        out["climate_trace_missing"] = static_cast<int64_t>(host.climate_trace_missing);
        out["climate_trace_captured"] = static_cast<int>(host.climate_trace_captured);
        out["climate_trace_reference_ready"] = static_cast<int>(
            host.climate_trace_reference_ready);
        out["climate_trace_consumable"] = static_cast<int>(
            host.climate_trace_consumable);
        out["climate_trace_reference_rejected"] = static_cast<int64_t>(
            host.climate_trace_reference_rejected);
        out["climate_trace_reference_pending"] = static_cast<int64_t>(
            host.climate_trace_reference_pending);
        out["climate_trace_capacity_exceeded"] = static_cast<int64_t>(
            host.climate_trace_capacity_exceeded);
        out["climate_trace_lag_days"] = host.climate_trace_lag_days;
        out["worker_fault_count"] = static_cast<int64_t>(host.worker_fault_count);
        out["coverage_blocker"] = String(host.coverage_blocker);
        out["fault_code"] = String(host.fault_code);
        out["simulation_invalid_environment_rejected"] = static_cast<int64_t>(host.invalid_environment_rejected);
        out["country_pod_snapshot_generation"] = static_cast<int64_t>(host.country_pod_snapshot_generation);
        out["country_pod_state_hash"] = static_cast<int64_t>(host.country_pod_state_hash);
        out["country_pod_work_units"] = static_cast<int64_t>(host.country_pod_work_units);
        out["country_pod_active_country_count"] = static_cast<int>(host.country_pod_active_country_count);
        out["country_pod_active_index_count"] = static_cast<int>(host.country_pod_active_index_count);
        out["country_pod_pending_checks"] = static_cast<int>(host.country_pod_pending_checks);
        out["country_pod_ack_pending"] = host.country_pod_ack_pending;
        out["country_pod_blocker"] = String(host.country_pod_blocker);
        out["command_queue_depth"] = static_cast<int>(host.command_queue_depth);
        out["receipt_queue_depth"] = static_cast<int>(host.receipt_queue_depth);
    } else {
        out["runtime_domain_abi_version"] = static_cast<int>(RUNTIME_DOMAIN_ABI_VERSION);
        out["pod_domain_abi_version"] = static_cast<int>(RUNTIME_DOMAIN_POD_ABI_VERSION);
        out["simulation_host_state"] = "STOPPED";
        out["simulation_thread_mode"] = "OFF";
        out["requested_simulation_thread_mode"] = "OFF";
        out["simulation_worker_ready"] = false;
        out["graph_coverage_state"] = "partial";
        out["required_domain_mask"] = static_cast<int64_t>(RUNTIME_ALL_DOMAIN_MASK);
        out["implemented_domain_mask"] = 0;
        out["missing_domain_mask"] = static_cast<int64_t>(RUNTIME_ALL_DOMAIN_MASK);
        out["simulation_worker_blocker"] =
            "runtime_graph_still_uses_godot_containers_and_object_boundaries";
    }
    out["executor_backend"] = "native_fixed_pool";
    out["hardware_threads"] = static_cast<int64_t>(report.hardware_threads);
    out["worker_threads"] = static_cast<int64_t>(report.worker_threads);
    out["active_worker_limit"] =
        static_cast<int64_t>(report.active_worker_limit);
    out["interactive"] = report.interactive;
    out["dispatch_count"] = static_cast<int64_t>(report.dispatch_count);
    out["serial_dispatch_count"] =
        static_cast<int64_t>(report.serial_dispatch_count);
    out["task_count"] = static_cast<int64_t>(report.task_count);
    out["fault_count"] = static_cast<int64_t>(report.fault_count);
    out["thread_priority"] = "below_normal_windows";
    return out;
}

Dictionary DCWorldExt::get_runtime_perf_snapshot(int detail_level) const {
    Dictionary out;
    out["configured"] = _runtime_graph_configured;
    out["enabled"] = _runtime_graph_enabled;
    out["simulation_thread_mode"] = String("OFF");
    out["graph_coverage_state"] = String("partial");
    out["simulation_worker_ready"] = false;
    out["pod_domain_abi_version"] = static_cast<int>(RUNTIME_DOMAIN_POD_ABI_VERSION);
    out["pod_completed_domain_mask"] = 0;
    out["pod_completed_stage_count"] = 0;
    out["pod_work_units"] = 0;
    out["pod_intent_count"] = 0;
    out["pod_fallback_count"] = 0;
    out["domain_authority_planned_mask"] = 0;
    out["domain_authority_committed_mask"] = 0;
    out["domain_authority_ack_count"] = 0;
    out["domain_authority_input_hash"] = 0;
    out["domain_authority_state_hash"] = 0;
    out["domain_authority_plan_ms"] = 0.0;
    out["domain_authority_replay_ms"] = 0.0;
    out["domain_authority_fallback_reason"] = String();
    if (_runtime_host) {
        const RuntimeThreadReport host = _runtime_host->report();
        out["simulation_thread_mode"] = runtime_effective_mode_name(host);
        out["requested_simulation_thread_mode"] =
            host.mode == RuntimeSimulationMode::ACTIVE ? "ACTIVE" :
            host.mode == RuntimeSimulationMode::SHADOW ? "SHADOW" : "OFF";
        out["graph_coverage_state"] = String(host.graph_coverage_state);
        out["simulation_host_state"] = static_cast<int>(host.state);
        out["simulation_worker_ready"] = host.authority_ready;
        out["required_domain_mask"] = static_cast<int64_t>(host.required_domain_mask);
        out["implemented_domain_mask"] = static_cast<int64_t>(host.implemented_domain_mask);
        out["missing_domain_mask"] = static_cast<int64_t>(host.missing_domain_mask);
        out["coverage_blocker"] = String(host.coverage_blocker);
        out["simulation_committed_day"] = host.committed_day;
        out["simulation_generation"] = static_cast<int64_t>(host.generation);
        out["simulation_state_hash"] = static_cast<int64_t>(host.state_hash);
        out["last_commit_produced_at_us"] = static_cast<int64_t>(host.last_commit_produced_at_us);
        out["last_visual_publish_at_us"] = static_cast<int64_t>(host.last_visual_publish_at_us);
        out["snapshot_staleness_ms"] = host.snapshot_staleness_ms;
        out["ui_input_to_feedback_ms"] = host.ui_input_to_feedback_ms;
        out["visual_apply_ms"] = host.visual_apply_ms;
        out["gpu_upload_ms"] = host.gpu_upload_ms;
        out["main_wait_on_sim_us"] = static_cast<int64_t>(host.main_wait_on_sim_us);
        out["simulation_environment_generation"] = static_cast<int64_t>(host.environment_generation);
        out["simulation_environment_day"] = host.environment_day;
        out["simulation_environment_cell_count"] = static_cast<int>(host.environment_cell_count);
        out["simulation_environment_topology_validated"] = host.environment_topology_validated;
        out["country_pod_snapshot_generation"] = static_cast<int64_t>(host.country_pod_snapshot_generation);
        out["country_pod_state_hash"] = static_cast<int64_t>(host.country_pod_state_hash);
        out["country_pod_work_units"] = static_cast<int64_t>(host.country_pod_work_units);
        out["country_pod_active_country_count"] = static_cast<int>(host.country_pod_active_country_count);
        out["country_pod_active_index_count"] = static_cast<int>(host.country_pod_active_index_count);
        out["country_pod_pending_checks"] = static_cast<int>(host.country_pod_pending_checks);
        out["country_pod_ack_pending"] = host.country_pod_ack_pending;
        out["country_pod_blocker"] = String(host.country_pod_blocker);
        out["stale_environment_rejected"] = static_cast<int64_t>(host.stale_environment_rejected);
        out["simulation_time_debt_days"] = host.time_debt_days;
        out["time_debt_days"] = host.time_debt_days;
        out["snapshot_publish_drop_count"] = static_cast<int64_t>(host.snapshot_publish_drop_count);
        out["snapshot_publish_throttled_count"] = static_cast<int64_t>(host.snapshot_publish_throttled_count);
        out["command_queue_capacity_exceeded"] = static_cast<int64_t>(host.command_queue_capacity_exceeded);
        out["receipt_queue_capacity_exceeded"] = static_cast<int64_t>(host.receipt_queue_capacity_exceeded);
        out["day_stage_count"] = static_cast<int>(host.day_stage_count);
        out["day_completed_stage_count"] = static_cast<int>(host.day_completed_stage_count);
        out["day_work_units"] = static_cast<int64_t>(host.day_work_units);
        out["pod_domain_abi_version"] = static_cast<int>(host.pod_domain_abi_version);
        out["pod_completed_domain_mask"] = static_cast<int64_t>(host.pod_completed_domain_mask);
        out["pod_completed_stage_count"] = static_cast<int>(host.pod_completed_stage_count);
        out["pod_work_units"] = static_cast<int64_t>(host.pod_work_units);
        out["pod_intent_count"] = static_cast<int>(host.pod_intent_count);
        out["pod_fallback_count"] = static_cast<int>(host.pod_fallback_count);
        out["domain_authority_planned_mask"] = static_cast<int64_t>(
            host.domain_authority_planned_mask);
        out["domain_authority_committed_mask"] = static_cast<int64_t>(
            host.domain_authority_committed_mask);
        out["domain_authority_ack_count"] = static_cast<int>(
            host.domain_authority_ack_count);
        out["domain_authority_input_hash"] = static_cast<int64_t>(
            host.domain_authority_input_hash);
        out["domain_authority_state_hash"] = static_cast<int64_t>(
            host.domain_authority_state_hash);
        out["domain_authority_plan_ms"] = host.domain_authority_plan_ms;
        out["domain_authority_replay_ms"] = host.domain_authority_replay_ms;
        out["domain_authority_fallback_reason"] = String(
            host.domain_authority_fallback_reason);
        // Climate POD is SHADOW-only diagnostic work.  Export it through the
        // graph snapshot so the CSV has the same time series as the host
        // facade, without implying that Climate is an ACTIVE authority.
        out["climate_pod_ready"] = host.climate_pod_ready;
        out["climate_pod_plan_ms"] = host.climate_pod_plan_ms;
        out["climate_pod_replay_ms"] = host.climate_pod_replay_ms;
        out["climate_pod_work_units"] = static_cast<int64_t>(host.climate_pod_work_units);
        out["climate_pod_changed_cells"] = static_cast<int>(host.climate_pod_changed_cells);
        out["climate_pod_state_hash"] = static_cast<int64_t>(host.climate_pod_state_hash);
        out["climate_pod_fallback_reason"] = String(host.climate_pod_fallback_reason);
        out["climate_trace_depth"] = static_cast<int>(host.climate_trace_depth);
        out["climate_trace_front_day"] = host.climate_trace_front_day;
        out["climate_trace_lag_days"] = host.climate_trace_lag_days;
        out["climate_trace_latest_hash"] = static_cast<int64_t>(host.climate_trace_latest_hash);
        out["climate_trace_consumed"] = static_cast<int64_t>(host.climate_trace_consumed);
        out["climate_trace_missing"] = static_cast<int64_t>(host.climate_trace_missing);
    }
    out["day"] = _runtime_graph_day;
    out["generation"] = static_cast<int64_t>(_runtime_graph_generation);
    out["pulse_count"] = static_cast<int64_t>(_runtime_graph_pulse_count);
    out["abi_calls"] = static_cast<int64_t>(_runtime_graph_abi_calls);
    out["gdscript_callbacks"] = static_cast<int64_t>(_runtime_graph_callback_count);
    out["work_done"] = static_cast<int64_t>(_runtime_graph_work_done);
    out["budget_yields"] = static_cast<int64_t>(_runtime_graph_budget_yields);
    out["economy_slices"] = static_cast<int64_t>(_runtime_graph_economy_slices);
    out["economy_commits"] = static_cast<int64_t>(_runtime_graph_economy_commits);
    out["trigger_blocked_pulses"] =
        static_cast<int64_t>(_runtime_graph_trigger_blocked_pulses);
    out["trigger_blocked_reason"] =
        String(_runtime_graph_trigger_blocked_reason.c_str());
    out["last_elapsed_us"] = static_cast<int64_t>(_runtime_graph_last_elapsed_us);
    out["last_status"] = static_cast<int64_t>(_runtime_graph_last_status);
    out["dirty_mask"] = static_cast<int64_t>(_runtime_graph_dirty_mask);
    out["post_pulse_flush_ms"] = _runtime_graph_post_pulse_flush_ms;
    out["flush_slot_count"] =
        static_cast<int64_t>(_runtime_graph_flush_slot_count);
    out["visual_diff_cell_count"] =
        static_cast<int64_t>(_runtime_graph_visual_diff_cell_count);
    out["country_territory_sync_ms"] =
        _runtime_graph_country_territory_sync_ms;
    out["full_flush_count"] =
        static_cast<int64_t>(_runtime_graph_full_flush_count);
    const NativeParallelExecutor::Report executor =
        NativeParallelExecutor::instance().report();
    out["native_executor_workers"] =
        static_cast<int64_t>(executor.active_worker_limit);
    out["native_executor_interactive"] = executor.interactive;
    out["native_executor_fault_count"] =
        static_cast<int64_t>(executor.fault_count);
    if (detail_level > 0) {
        out["next_cursor"] = static_cast<int64_t>(_runtime_graph_next_cursor);
        out["authority"] = String("existing_native_runtimes");
        out["callbacks_in_graph"] = static_cast<int64_t>(_runtime_graph_callback_count);
        const int64_t day = _runtime_graph_day;
        out["country_pending"] = _country_runtime != nullptr &&
            static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day);
        out["trigger_pending"] = _trigger_runtime != nullptr &&
            static_cast<TriggerRuntime *>(_trigger_runtime)->should_run(day);
        out["ideology_pending"] = _ideology_runtime != nullptr &&
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->should_run(day);
        out["effect_pending"] = _effect_runtime != nullptr &&
            static_cast<EffectRuntime *>(_effect_runtime)->should_run(day);
        out["modifier_pending"] = _modifier_runtime != nullptr &&
            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day);
        out["gameplay_effect_pending"] = _effect_runtime != nullptr &&
            gameplay_effect_should_run(day);
        out["economy_pending"] = _economy_runtime != nullptr &&
            economy_should_run(day);
        out["gameplay_event_count"] = static_cast<int64_t>(_gameplay_events.size());
        const int64_t *trigger_ack = _gameplay_consumer_ack.getptr(
            StringName("trigger_runtime"));
        out["trigger_event_ack"] = trigger_ack != nullptr ? *trigger_ack : int64_t{0};
    }
    return out;
}

} // namespace pk

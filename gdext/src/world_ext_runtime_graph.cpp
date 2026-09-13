#include "world_ext.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "modifier_runtime.h"
#include "native_parallel_executor.h"
#include "trigger_runtime.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <atomic>
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

// Producer 2 on the Trigger POD command lane. Producer 1 is the Dictionary
// bridge in world_ext_trigger.cpp; the lane is drained in a deterministic
// (effective_day, producer_id, sequence, request_id) order, so the two producers
// stay replayable independently.
std::atomic<uint64_t> g_graph_trigger_request_id{1};
std::atomic<uint64_t> g_graph_trigger_sequence{1};

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
    _runtime_graph_country_peer_adapter_enabled = _runtime_graph_enabled &&
        bool(boot_config.get("country_peer_adapter_enabled", true));
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
    _runtime_graph_country_peer_service_calls = 0;
    _runtime_graph_country_peer_intents = 0;
    _runtime_graph_country_peer_completed = 0;
    _runtime_graph_country_peer_pending = 0;
    _runtime_graph_country_peer_rejected = 0;
    _runtime_graph_country_peer_faults = 0;
    _runtime_graph_country_peer_fault_reason.clear();
    _runtime_graph_trigger_blocked_pulses = 0;
    _runtime_graph_trigger_blocked_reason.clear();
    _runtime_graph_last_elapsed_us = 0;
    _runtime_graph_last_status = 0;
    _runtime_graph_post_pulse_flush_ms = 0.0;
    _runtime_graph_country_territory_sync_ms = 0.0;
    _runtime_graph_flush_slot_count = 0;
    _runtime_graph_visual_diff_cell_count = 0;
    _runtime_graph_full_flush_count = 0;
    if (_country_runtime != nullptr) {
        static_cast<NativeCountryRuntime *>(_country_runtime)->set_peer_async_mode(
            _runtime_graph_country_peer_adapter_enabled);
    }
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
            // H8: mirror the same committed fact onto the Trigger POD lane. The
            // worker dedupes by source cursor, so this is safe in SHADOW too,
            // and under ACTIVE it is the only way the worker sees the journal.
            if (_runtime_host != nullptr) {
                RuntimeTriggerCommand command;
                command.request_id = g_graph_trigger_request_id.fetch_add(
                    1, std::memory_order_relaxed);
                command.producer_id = 2u;
                command.sequence = g_graph_trigger_sequence.fetch_add(
                    1, std::memory_order_relaxed);
                command.opcode = RuntimeTriggerCommandOpcode::INGEST_EVENT;
                command.requested_day = day;
                command.effective_day = day;
                command.event.source_id = input.source_id;
                command.event.event_id = input.event_id;
                command.event.day = input.day;
                command.event.event_type = input.event_type;
                command.event.payload_schema = input.payload_schema;
                command.event.entity_handle = input.entity_handle;
                command.event.group_handle = input.group_handle;
                command.event.value = input.value;
                command.event.payload = input.payload;
                std::string queue_error;
                if (!_runtime_host->queue_trigger_pod_command(command, queue_error))
                    break;
            }
            if (trigger_worker_authoritative()) {
                // Sole writer: the worker owns ingest, so do not stage the same
                // event in the facade — the snapshot write-back would then
                // disagree with a facade that saw it twice.
                cursor = input.event_id;
                ++ingested;
                if (ingested >= 512) break;
                continue;
            }
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
    bool country_peer_adapter_fault = false;

    auto service_country_peer_adapter = [&]() {
        if (!_runtime_graph_country_peer_adapter_enabled ||
            _country_runtime == nullptr)
            return uint32_t{0};
        NativeCountryRuntime *country =
            static_cast<NativeCountryRuntime *>(_country_runtime);
        if (!country->peer_async_mode()) country->set_peer_async_mode(true);
        NativeCountryRuntime::PeerAdapterServiceReport peer_report;
        std::string peer_error;
        ++_runtime_graph_country_peer_service_calls;
        if (!country->service_peer_intents_main_thread(
                64, peer_report, peer_error)) {
            ++_runtime_graph_country_peer_faults;
            _runtime_graph_country_peer_fault_reason = peer_error.empty()
                ? "country_peer_adapter_service_failed" : peer_error;
            country_peer_adapter_fault = true;
            return uint32_t{0};
        }
        _runtime_graph_country_peer_intents += peer_report.inspected;
        _runtime_graph_country_peer_completed += peer_report.completed;
        _runtime_graph_country_peer_pending += peer_report.pending;
        _runtime_graph_country_peer_rejected += peer_report.rejected;
        if (peer_report.rejected > 0)
            _runtime_graph_country_peer_fault_reason = peer_report.last_reason;
        return peer_report.inspected;
    };

    // Apply Country/Economy ownership before any should_run / economy gate. If
    // the pulse loop never iterates (budget already spent), peers still must
    // see sync_store_writes_forbidden so they do not wait on a dead facade.
    const bool country_worker_authoritative = _runtime_host != nullptr &&
        (_runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::COUNTRY) ||
         _runtime_host->country_authority_owner_is_worker());
    const bool economy_worker_authoritative = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY);
    if (_country_runtime != nullptr) {
        static_cast<NativeCountryRuntime *>(_country_runtime)
            ->set_sync_store_writes_forbidden(country_worker_authoritative);
        if (_runtime_host != nullptr) {
            static_cast<NativeCountryRuntime *>(_country_runtime)
                ->attach_simulation_host(_runtime_host.get());
        }
    }
    if (_economy_runtime != nullptr) {
        auto *economy =
            static_cast<NativeEconomyRuntime *>(_economy_runtime);
        economy->set_sync_writes_forbidden(economy_worker_authoritative);
        if (_runtime_host != nullptr) {
            economy->attach_simulation_host(_runtime_host.get());
            _runtime_host->set_economy_sync_writes_forbidden(
                economy_worker_authoritative);
            if (economy_worker_authoritative)
                economy->open_all_d7_operation_gates();
        }
    }
    // Worker ACTIVE owns economy mutation via compact slices, but MapData /
    // DataCore environment + building context still live on the main thread.
    // Capture frozen input lanes here; do not run mutation stages.
    if (economy_worker_authoritative && _economy_runtime != nullptr) {
        auto capture_day = [&](int64_t capture_day_index) {
            Dictionary cap = capture_economy_day_inputs(capture_day_index);
            if (bool(cap.get("fatal", false))) {
                _runtime_graph_last_economy_report = cap;
                _runtime_graph_economy_capture_fatal_reason =
                    String(cap.get("fatal_reason", "economy_day_input_capture_failed"))
                        .utf8()
                        .get_data();
            } else if (!_runtime_graph_economy_capture_fatal_reason.empty() &&
                       bool(cap.get("ok", false))) {
                _runtime_graph_economy_capture_fatal_reason.clear();
            }
            return cap;
        };
        capture_day(day);
        if (_runtime_host != nullptr) {
            const RuntimeThreadReport host = _runtime_host->report();
            const int64_t need = std::max(
                day,
                std::max(host.economy_pod_committed_day + 1,
                         host.economy_pod_epoch_sample_day));
            auto *economy =
                static_cast<NativeEconomyRuntime *>(_economy_runtime);
            if (need != day && economy->needs_environment_capture(need))
                capture_day(need);
        }
    }

    // Stable order mirrors the existing GDScript ACK chain and scheduler
    // priorities. Each runtime owns its own persistent range cursor.
    while (iterations++ < 64 && !over_budget()) {
        bool progressed = false;
        Dictionary ctx = ctx_for();
        if (!country_worker_authoritative && _country_runtime != nullptr &&
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
        const uint32_t peer_work_before = service_country_peer_adapter();
        if (peer_work_before > 0) {
            work += peer_work_before;
            progressed = true;
        }
        if (country_peer_adapter_fault) break;
        if (over_budget()) break;
        const uint32_t ingested_events = ingest_trigger_events();
        if (ingested_events > 0) {
            work += ingested_events;
            progressed = true;
        }
        // H8: under worker authority the worker runs the aggregation/emission
        // day. The main thread stays the Trigger->Effect delivery cursor owner,
        // so the handoff below keeps running against the written-back facade.
        const bool trigger_worker_owns_day = trigger_worker_authoritative();
        if (_trigger_runtime != nullptr && !trigger_handoff_blocked &&
            (trigger_worker_owns_day ||
             static_cast<TriggerRuntime *>(_trigger_runtime)->should_run(day))) {
            if (!trigger_worker_owns_day) {
                ran(run_trigger_daily(day), DIRTY_EVENTS);
                progressed = true;
            }
            if (_effect_runtime != nullptr) {
                const Dictionary handoff = handoff_trigger_effects(512);
                const int64_t handed_off =
                    static_cast<int64_t>(handoff.get("handed_off", 0));
                if (handed_off > 0) {
                    work += static_cast<uint32_t>(handed_off);
                    dirty |= DIRTY_EVENTS;
                    progressed = true;
                }
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
        }
        if (over_budget()) break;
        // Publish the last committed Economy opinion before synchronous
        // Ideology runs. Economy settles later in this graph, so the worker
        // cannot form an Ideology<->Economy same-day cycle.
        if (_ideology_runtime != nullptr && _economy_runtime != nullptr &&
            _runtime_host != nullptr) {
            publish_ideology_worker_inputs();
        }
        // G8: publish_ideology_worker_inputs above still runs under worker
        // authority — the worker needs the opinion snapshot either way — but
        // the synchronous day must not.
        const bool ideology_worker_authoritative = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(
                RuntimeDomainId::IDEOLOGY);
        if (!ideology_worker_authoritative && _ideology_runtime != nullptr &&
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->should_run(day)) {
            ran(run_ideology_daily(day), DIRTY_COUNTRY_STATE | DIRTY_EVENTS);
            progressed = true;
        }
        if (over_budget()) break;
        if (_effect_runtime != nullptr &&
            static_cast<EffectRuntime *>(_effect_runtime)->should_run(day)) {
            const bool effect_worker_authoritative = _runtime_host != nullptr &&
                _runtime_host->domain_is_worker_authoritative(
                    RuntimeDomainId::EFFECT);
            if (!effect_worker_authoritative) {
                ran(run_effect_daily(day), DIRTY_EVENTS);
                // A native effect transaction can be waiting for an ACK even when
                // the peer runtime has no independent daily work.  ACK every
                // adapter after effect evaluation so the transaction can reach a
                // terminal state instead of keeping effect_should_run() hot.
                if (_effect_runtime != nullptr) {
                    dispatch_effect_native_country();
                    dispatch_effect_native_economy();
                    if (!(_runtime_host != nullptr &&
                          _runtime_host->domain_is_worker_authoritative(
                              RuntimeDomainId::MODIFIER))) {
                        dispatch_effect_native_modifier();
                    }
                    dispatch_effect_native_gameplay();
                    ack_effect_native_country();
                    ack_effect_native_economy();
                    if (!(_runtime_host != nullptr &&
                          _runtime_host->domain_is_worker_authoritative(
                              RuntimeDomainId::MODIFIER))) {
                        ack_effect_native_modifier();
                    }
                    ack_effect_native_gameplay();
                }
                progressed = true;
            }
        }
        if (over_budget()) break;
        const bool modifier_worker_authoritative = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(
                RuntimeDomainId::MODIFIER);
        if (!modifier_worker_authoritative && _modifier_runtime != nullptr &&
            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_modifier();
            ran(run_modifier_daily(day), DIRTY_COUNTRY_STATE);
            if (_effect_runtime != nullptr) ack_effect_native_modifier();
            progressed = true;
        }
        const uint32_t peer_work_after = service_country_peer_adapter();
        if (peer_work_after > 0) {
            work += peer_work_after;
            progressed = true;
        }
        if (country_peer_adapter_fault) break;
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
    //
    // Worker-owned domains must not arm this barrier: the pulse loop already
    // skips their synchronous day, but legacy facades can keep should_run()
    // hot on stale queues. Operator precedence also used to let Effect/Modifier
    // escape the Country worker gate entirely — that pinned
    // country_day_barrier/economy_day_barrier with economy_slices=0.
    const bool country_worker_owns_barrier =
        _runtime_host != nullptr &&
        (_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) ||
         _runtime_host->country_authority_owner_is_worker());
    const bool effect_worker_owns_barrier = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT);
    const bool modifier_worker_owns_barrier = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::MODIFIER);
    const bool pending =
        (!country_worker_owns_barrier && _country_runtime != nullptr &&
         static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day)) ||
        (!effect_worker_owns_barrier && _effect_runtime != nullptr &&
         static_cast<EffectRuntime *>(_effect_runtime)->should_run(day)) ||
        (!modifier_worker_owns_barrier && _modifier_runtime != nullptr &&
         static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) ||
        (!effect_worker_owns_barrier && _effect_runtime != nullptr &&
         gameplay_effect_should_run(day)) ||
        (_economy_runtime != nullptr && economy_should_run(day));
    if (pending) status = 3;
    if (country_peer_adapter_fault) status = 3;
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
    // A partial promotion is still ACTIVE: some domain's days are now produced
    // by the worker and the main thread must consume its commits. Requiring
    // authority_ready here would report OFF for a worker that already owns
    // Climate, and the commit-consumption boundary would never run.
    if (report.mode == RuntimeSimulationMode::ACTIVE &&
        (report.authority_ready || report.authoritative_domain_mask != 0u))
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
        // Ready-for-commit-consumption, which a partially promoted worker also
        // is. `authority_ready` stays available above for callers that mean the
        // whole-graph gate.
        out["simulation_worker_ready"] =
            host.authority_ready || host.authoritative_domain_mask != 0u;
        out["state"] = state;
        out["state_id"] = static_cast<int>(host.state);
        out["domain_abi_version"] = static_cast<int>(host.domain_abi_version);
        out["graph_coverage_state"] = String(host.graph_coverage_state);
        out["required_domain_mask"] = static_cast<int64_t>(host.required_domain_mask);
        out["implemented_domain_mask"] = static_cast<int64_t>(host.implemented_domain_mask);
        out["missing_domain_mask"] = static_cast<int64_t>(host.missing_domain_mask);
        out["requested_authority_mask"] =
            static_cast<int64_t>(host.requested_authority_mask);
        out["authoritative_domain_mask"] =
            static_cast<int64_t>(host.authoritative_domain_mask);
        out["climate_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
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
        out["economy_pod_ready"] = host.economy_pod_ready;
        out["economy_pod_committed"] = host.economy_pod_committed;
        out["economy_pod_authority_ready"] = host.economy_pod_authority_ready;
        out["economy_pod_committed_day"] = host.economy_pod_committed_day;
        out["economy_pod_epoch_sample_day"] = host.economy_pod_epoch_sample_day;
        out["economy_pod_generation"] = static_cast<int64_t>(host.economy_pod_generation);
        out["economy_pod_state_hash"] = static_cast<int64_t>(host.economy_pod_state_hash);
        out["economy_pod_input_generation"] = static_cast<int64_t>(host.economy_pod_input_generation);
        out["economy_pod_country_generation"] = static_cast<int64_t>(host.economy_pod_country_generation);
        out["economy_pod_completed_stage_mask"] = static_cast<int64_t>(host.economy_pod_completed_stage_mask);
        out["economy_pod_pending_outbox"] = static_cast<int>(host.economy_pod_pending_outbox);
        out["economy_pod_pending_inbox"] = static_cast<int>(host.economy_pod_pending_inbox);
        out["economy_pod_operation_gate_mask"] = static_cast<int>(host.economy_pod_operation_gate_mask);
        out["economy_pod_parity_ready_mask"] = static_cast<int>(host.economy_pod_parity_ready_mask);
        out["economy_replay_completed_stage_mask"] = static_cast<int64_t>(host.economy_replay_completed_stage_mask);
        out["economy_replay_stage_cursor"] = static_cast<int>(host.economy_replay_stage_cursor);
        out["economy_replay_input_hash"] = static_cast<int64_t>(host.economy_replay_input_hash);
        out["economy_replay_base_hash"] = static_cast<int64_t>(host.economy_replay_base_hash);
        out["economy_replay_next_hash"] = static_cast<int64_t>(host.economy_replay_next_hash);
        out["economy_replay_input_captured"] = host.economy_replay_input_captured;
        out["economy_replay_committed"] = host.economy_replay_committed;
        out["economy_replay_parity_ready"] = host.economy_replay_parity_ready;
        out["economy_replay_fallback_reason"] = String(host.economy_replay_fallback_reason);
        PackedInt64Array replay_hashes;
        PackedInt64Array replay_work;
        PackedFloat64Array replay_ms;
        replay_hashes.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
        replay_work.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
        replay_ms.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
        for (int i = 0; i < static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT); ++i) {
            replay_hashes.set(i, static_cast<int64_t>(host.economy_replay_stage_hash[i]));
            replay_work.set(i, static_cast<int64_t>(host.economy_replay_stage_work[i]));
            replay_ms.set(i, host.economy_replay_stage_ms[i]);
        }
        out["economy_replay_stage_hash"] = replay_hashes;
        out["economy_replay_stage_work"] = replay_work;
        out["economy_replay_stage_ms"] = replay_ms;
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
        append_climate_stage_cadence(out, host);
        out["climate_pod_state_hash"] = static_cast<int64_t>(host.climate_pod_state_hash);
        out["climate_pod_reference_hash"] = static_cast<int64_t>(
            host.climate_pod_reference_hash);
        out["climate_pod_parity_compared"] = host.climate_pod_parity_compared;
        out["climate_pod_parity_matched"] = host.climate_pod_parity_matched;
        out["climate_pod_parity_mismatch_count"] = static_cast<int64_t>(
            host.climate_pod_parity_mismatch_count);
        out["climate_pod_parity_reason"] = String(host.climate_pod_parity_reason);
        out["climate_pod_fallback_reason"] = String(host.climate_pod_fallback_reason);
        // 首差异槽位（S2）。少了它们，逐日报告只能说"这天不匹配"，说不出是哪个
        // 字段哪个 cell——而这正是 harness 唯一能定位分叉的信息。
        out["climate_parity_day"] = host.climate_parity_day;
        out["climate_parity_stage"] = static_cast<int>(host.climate_parity_stage);
        out["climate_parity_cell"] = static_cast<int>(host.climate_parity_cell);
        out["climate_parity_input_generation"] = static_cast<int64_t>(
            host.climate_parity_input_generation);
        out["climate_parity_base_generation"] = static_cast<int64_t>(
            host.climate_parity_base_generation);
        out["climate_parity_trace_hash"] = static_cast<int64_t>(
            host.climate_parity_trace_hash);
        out["climate_parity_field"] = String(host.climate_parity_field);
        out["climate_parity_reference_bits"] = String(
            host.climate_parity_reference_bits);
        out["climate_parity_worker_bits"] = String(host.climate_parity_worker_bits);
        // 生产 / worker 各跑过哪些 stage（1 << RuntimeClimateStage）。差集是分叉矩阵
        // 里 stage 9..13 那些字段唯一可信的归因来源。
        out["climate_production_stage_mask"] =
            static_cast<int>(host.climate_production_stage_mask);
        out["climate_worker_stage_mask"] =
            static_cast<int>(host.climate_worker_stage_mask);
        // B8-2：worker 自持 cyclone 的当日事实（soak/C3 的 JSON 证据来源）。
        out["climate_cyclone_alive"] = static_cast<int>(host.climate_cyclone_alive);
        out["climate_cyclone_injected"] =
            static_cast<int>(host.climate_cyclone_injected);
        out["climate_cyclone_replaced"] =
            static_cast<int>(host.climate_cyclone_replaced);
        out["climate_cyclone_decayed"] =
            static_cast<int>(host.climate_cyclone_decayed);
        out["climate_cyclone_touched"] =
            static_cast<int>(host.climate_cyclone_touched);
        // B8 P0：交付游标。见 RuntimeThreadReport 的注释 —— 这组数字把
        // "worker 慢"（consumed 落后 published）与"输入被覆盖"（superseded）
        // 分开，是背压策略与 50/50 验收的判据。
        out["climate_committed_day"] = host.climate_committed_day;
        out["climate_consumed_generation"] =
            static_cast<int64_t>(host.climate_consumed_generation);
        out["environment_published_days"] =
            static_cast<int64_t>(host.environment_published_days);
        out["environment_consumed_days"] =
            static_cast<int64_t>(host.environment_consumed_days);
        out["environment_superseded_days"] =
            static_cast<int64_t>(host.environment_superseded_days);
        out["environment_dropped_days"] =
            static_cast<int64_t>(host.environment_dropped_days);
        out["environment_ring_pending"] =
            static_cast<int64_t>(host.environment_ring_pending);
        out["climate_wait_total_ms"] =
            static_cast<int64_t>(host.climate_wait_total_ms);
        out["climate_wait_last_ms"] =
            static_cast<int64_t>(host.climate_wait_last_ms);
        out["climate_wait_max_ms"] =
            static_cast<int64_t>(host.climate_wait_max_ms);
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
        out["country_worker_configured"] = host.country_worker_configured;
        out["country_worker_plan_active"] = host.country_worker_plan_active;
        out["country_worker_waiting_for_peer"] = host.country_worker_waiting_for_peer;
        out["country_worker_pending_intents"] = static_cast<int64_t>(
            host.country_worker_pending_intents);
        out["country_worker_queued_intents"] = static_cast<int64_t>(
            host.country_worker_queued_intents);
        out["country_worker_result_count"] = static_cast<int64_t>(
            host.country_worker_result_count);
        out["country_worker_rejected_results"] = static_cast<int64_t>(
            host.country_worker_rejected_results);
        out["country_worker_session_epoch"] = static_cast<int64_t>(
            host.country_worker_session_epoch);
        out["country_worker_country_generation"] = static_cast<int64_t>(
            host.country_worker_country_generation);
        out["country_worker_day"] = host.country_worker_day;
        out["country_worker_continuation_index"] = static_cast<int64_t>(
            host.country_worker_continuation_index);
        out["country_worker_boundary_id"] = static_cast<int64_t>(
            host.country_worker_boundary_id);
        out["country_worker_last_admitted_submit_order"] = static_cast<int64_t>(
            host.country_worker_last_admitted_submit_order);
        out["country_worker_expected_base_generation"] = static_cast<int64_t>(
            host.country_worker_expected_base_generation);
        out["country_worker_catalog_hash"] = static_cast<int64_t>(
            host.country_worker_catalog_hash);
        out["country_worker_last_reason"] = String(host.country_worker_last_reason);
        out["country_worker_authoritative"] = host.country_worker_authoritative;
        out["modifier_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u;
        out["effect_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::EFFECT)) != 0u;
        out["ideology_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::IDEOLOGY)) != 0u;
        out["trigger_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) != 0u;
        // I8: the Events grant means the worker mirrors the committed journal in
        // POD form and owns the EVENTS stage bit. The legacy GameplayEventBus
        // journal is still the production consumer source.
        out["events_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u;
        out["country_parity_compared"] = host.country_parity_compared != 0;
        out["country_parity_matched"] = host.country_parity_matched != 0;
        out["country_parity_compared_count"] = static_cast<int64_t>(
            host.country_parity_compared_count);
        out["country_parity_matched_count"] = static_cast<int64_t>(
            host.country_parity_matched_count);
        out["country_parity_status"] = String(host.country_parity_status);
        out["country_parity_first_mismatch_day"] =
            host.country_parity_first_mismatch_day;
        out["country_parity_reference_hash"] = static_cast<int64_t>(
            host.country_parity_reference_hash);
        out["country_parity_worker_hash"] = static_cast<int64_t>(
            host.country_parity_worker_hash);
        out["country_parity_field"] = String(host.country_parity_field);
        out["country_parity_index"] = host.country_parity_index;
        out["trigger_parity_day"] = host.trigger_parity_day;
        out["trigger_reference_day"] = host.trigger_reference_day;
        out["trigger_input_hash"] = static_cast<int64_t>(host.trigger_input_hash);
        out["trigger_reference_input_hash"] = static_cast<int64_t>(host.trigger_reference_input_hash);
        out["trigger_reference_state_hash"] = static_cast<int64_t>(host.trigger_reference_state_hash);
        out["trigger_worker_state_hash"] = static_cast<int64_t>(host.trigger_worker_state_hash);
        out["trigger_reference_effect_hash"] = static_cast<int64_t>(host.trigger_reference_effect_hash);
        out["trigger_worker_effect_hash"] = static_cast<int64_t>(host.trigger_worker_effect_hash);
        out["trigger_required_ack_count"] = static_cast<int>(host.trigger_required_ack_count);
        out["trigger_received_ack_count"] = static_cast<int>(host.trigger_received_ack_count);
        out["trigger_pending_ack_count"] = static_cast<int>(host.trigger_pending_ack_count);
        out["trigger_generation"] = static_cast<int64_t>(host.trigger_generation);
        out["trigger_committed_day"] = host.trigger_committed_day;
        out["trigger_acked_effect_id"] = host.trigger_acked_effect_id;
        out["trigger_pending_command_count"] = static_cast<int>(host.trigger_pending_command_count);
        out["trigger_parity_compared"] = host.trigger_parity_compared != 0;
        out["trigger_parity_matched"] = host.trigger_parity_matched != 0;
        out["trigger_first_divergence_index"] = host.trigger_first_divergence_index;
        out["trigger_first_divergence_kind"] = String(host.trigger_first_divergence_kind);
        out["trigger_blocker"] = String(host.trigger_blocker);
        out["trigger_pod_ready"] = host.trigger_pod_ready;
        out["trigger_pod_plan_ms"] = host.trigger_pod_plan_ms;
        out["trigger_pod_replay_ms"] = host.trigger_pod_replay_ms;
        out["trigger_pod_state_hash"] = static_cast<int64_t>(
            host.trigger_pod_state_hash);
        out["trigger_pod_snapshot_generation"] = static_cast<int64_t>(
            host.trigger_pod_snapshot_generation);
        out["trigger_pod_intent_count"] = static_cast<int>(
            host.trigger_pod_intent_count);
        out["trigger_pod_ack_count"] = static_cast<int>(
            host.trigger_pod_ack_count);
        out["trigger_pod_fallback_reason"] = String(
            host.trigger_pod_fallback_reason);
        out["modifier_pod_ready"] = host.modifier_pod_ready;
        out["modifier_pod_plan_ms"] = host.modifier_pod_plan_ms;
        out["modifier_pod_replay_ms"] = host.modifier_pod_replay_ms;
        out["modifier_pod_work_units"] = static_cast<int64_t>(
            host.modifier_pod_work_units);
        out["modifier_pod_state_hash"] = static_cast<int64_t>(
            host.modifier_pod_state_hash);
        out["modifier_pod_snapshot_generation"] = static_cast<int64_t>(
            host.modifier_pod_snapshot_generation);
        out["modifier_pod_ack_count"] = static_cast<int>(
            host.modifier_pod_ack_count);
        out["modifier_pod_fallback_reason"] = String(
            host.modifier_pod_fallback_reason);
        out["effect_pod_ready"] = host.effect_pod_ready;
        out["effect_pod_plan_ms"] = host.effect_pod_plan_ms;
        out["effect_pod_replay_ms"] = host.effect_pod_replay_ms;
        out["effect_pod_state_hash"] = static_cast<int64_t>(
            host.effect_pod_state_hash);
        out["effect_pod_snapshot_generation"] = static_cast<int64_t>(
            host.effect_pod_snapshot_generation);
        out["effect_pod_ack_count"] = static_cast<int>(
            host.effect_pod_ack_count);
        out["effect_pod_intent_count"] = static_cast<int>(
            host.effect_pod_intent_count);
        out["effect_pod_fallback_reason"] = String(
            host.effect_pod_fallback_reason);
        out["ideology_pod_ready"] = host.ideology_pod_ready;
        out["ideology_pod_plan_ms"] = host.ideology_pod_plan_ms;
        out["ideology_pod_replay_ms"] = host.ideology_pod_replay_ms;
        out["ideology_pod_state_hash"] = static_cast<int64_t>(
            host.ideology_pod_state_hash);
        out["ideology_pod_snapshot_generation"] = static_cast<int64_t>(
            host.ideology_pod_snapshot_generation);
        out["ideology_pod_pending_transition_count"] = static_cast<int>(
            host.ideology_pod_pending_transition_count);
        out["ideology_pod_intent_count"] = static_cast<int>(
            host.ideology_pod_intent_count);
        out["ideology_pod_fallback_reason"] = String(
            host.ideology_pod_fallback_reason);
        out["events_probe_enabled"] = host.events_probe_enabled;
        out["events_pod_ready"] = host.events_pod_ready;
        out["events_pod_plan_ms"] = host.events_pod_plan_ms;
        out["events_pod_replay_ms"] = host.events_pod_replay_ms;
        out["events_pod_state_hash"] = static_cast<int64_t>(
            host.events_pod_state_hash);
        out["events_pod_snapshot_generation"] = static_cast<int64_t>(
            host.events_pod_snapshot_generation);
        out["events_pod_event_count"] = static_cast<int>(
            host.events_pod_event_count);
        out["events_pod_ack_count"] = static_cast<int>(
            host.events_pod_ack_count);
        out["events_pod_drop_count"] = static_cast<int64_t>(
            host.events_pod_drop_count);
        out["events_pod_fallback_reason"] = String(
            host.events_pod_fallback_reason);
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
        out["simulation_worker_ready"] =
            host.authority_ready || host.authoritative_domain_mask != 0u;
        out["required_domain_mask"] = static_cast<int64_t>(host.required_domain_mask);
        out["implemented_domain_mask"] = static_cast<int64_t>(host.implemented_domain_mask);
        out["missing_domain_mask"] = static_cast<int64_t>(host.missing_domain_mask);
        out["authoritative_domain_mask"] =
            static_cast<int64_t>(host.authoritative_domain_mask);
        out["climate_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
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
        out["country_worker_configured"] = host.country_worker_configured;
        out["country_worker_plan_active"] = host.country_worker_plan_active;
        out["country_worker_waiting_for_peer"] = host.country_worker_waiting_for_peer;
        out["country_worker_pending_intents"] = static_cast<int64_t>(
            host.country_worker_pending_intents);
        out["country_worker_queued_intents"] = static_cast<int64_t>(
            host.country_worker_queued_intents);
        out["country_worker_result_count"] = static_cast<int64_t>(
            host.country_worker_result_count);
        out["country_worker_rejected_results"] = static_cast<int64_t>(
            host.country_worker_rejected_results);
        out["country_worker_session_epoch"] = static_cast<int64_t>(
            host.country_worker_session_epoch);
        out["country_worker_country_generation"] = static_cast<int64_t>(
            host.country_worker_country_generation);
        out["country_worker_day"] = host.country_worker_day;
        out["country_worker_continuation_index"] = static_cast<int64_t>(
            host.country_worker_continuation_index);
        out["country_worker_boundary_id"] = static_cast<int64_t>(
            host.country_worker_boundary_id);
        out["country_worker_last_admitted_submit_order"] = static_cast<int64_t>(
            host.country_worker_last_admitted_submit_order);
        out["country_worker_expected_base_generation"] = static_cast<int64_t>(
            host.country_worker_expected_base_generation);
        out["country_worker_catalog_hash"] = static_cast<int64_t>(
            host.country_worker_catalog_hash);
        out["country_worker_last_reason"] = String(host.country_worker_last_reason);
        out["country_worker_authoritative"] = host.country_worker_authoritative;
        out["modifier_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u;
        out["effect_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::EFFECT)) != 0u;
        out["ideology_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::IDEOLOGY)) != 0u;
        out["trigger_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) != 0u;
        // I8: the Events grant means the worker mirrors the committed journal in
        // POD form and owns the EVENTS stage bit. The legacy GameplayEventBus
        // journal is still the production consumer source.
        out["events_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u;
        out["country_parity_compared"] = host.country_parity_compared != 0;
        out["country_parity_matched"] = host.country_parity_matched != 0;
        out["country_parity_compared_count"] = static_cast<int64_t>(
            host.country_parity_compared_count);
        out["country_parity_matched_count"] = static_cast<int64_t>(
            host.country_parity_matched_count);
        out["country_parity_status"] = String(host.country_parity_status);
        out["country_parity_first_mismatch_day"] =
            host.country_parity_first_mismatch_day;
        out["country_parity_reference_hash"] = static_cast<int64_t>(
            host.country_parity_reference_hash);
        out["country_parity_worker_hash"] = static_cast<int64_t>(
            host.country_parity_worker_hash);
        out["country_parity_field"] = String(host.country_parity_field);
        out["country_parity_index"] = host.country_parity_index;
        out["trigger_parity_day"] = host.trigger_parity_day;
        out["trigger_reference_day"] = host.trigger_reference_day;
        out["trigger_input_hash"] = static_cast<int64_t>(host.trigger_input_hash);
        out["trigger_reference_input_hash"] = static_cast<int64_t>(host.trigger_reference_input_hash);
        out["trigger_reference_state_hash"] = static_cast<int64_t>(host.trigger_reference_state_hash);
        out["trigger_worker_state_hash"] = static_cast<int64_t>(host.trigger_worker_state_hash);
        out["trigger_reference_effect_hash"] = static_cast<int64_t>(host.trigger_reference_effect_hash);
        out["trigger_worker_effect_hash"] = static_cast<int64_t>(host.trigger_worker_effect_hash);
        out["trigger_required_ack_count"] = static_cast<int>(host.trigger_required_ack_count);
        out["trigger_received_ack_count"] = static_cast<int>(host.trigger_received_ack_count);
        out["trigger_pending_ack_count"] = static_cast<int>(host.trigger_pending_ack_count);
        out["trigger_generation"] = static_cast<int64_t>(host.trigger_generation);
        out["trigger_committed_day"] = host.trigger_committed_day;
        out["trigger_acked_effect_id"] = host.trigger_acked_effect_id;
        out["trigger_pending_command_count"] = static_cast<int>(host.trigger_pending_command_count);
        out["trigger_parity_compared"] = host.trigger_parity_compared != 0;
        out["trigger_parity_matched"] = host.trigger_parity_matched != 0;
        out["trigger_first_divergence_index"] = host.trigger_first_divergence_index;
        out["trigger_first_divergence_kind"] = String(host.trigger_first_divergence_kind);
        out["trigger_blocker"] = String(host.trigger_blocker);
        out["trigger_pod_ready"] = host.trigger_pod_ready;
        out["trigger_pod_plan_ms"] = host.trigger_pod_plan_ms;
        out["trigger_pod_replay_ms"] = host.trigger_pod_replay_ms;
        out["trigger_pod_state_hash"] = static_cast<int64_t>(
            host.trigger_pod_state_hash);
        out["trigger_pod_snapshot_generation"] = static_cast<int64_t>(
            host.trigger_pod_snapshot_generation);
        out["trigger_pod_intent_count"] = static_cast<int>(
            host.trigger_pod_intent_count);
        out["trigger_pod_ack_count"] = static_cast<int>(
            host.trigger_pod_ack_count);
        out["trigger_pod_fallback_reason"] = String(
            host.trigger_pod_fallback_reason);
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
        append_climate_stage_cadence(out, host);
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
    out["economy_capture_fatal_reason"] =
        String(_runtime_graph_economy_capture_fatal_reason.c_str());
    out["country_peer_adapter_enabled"] =
        _runtime_graph_country_peer_adapter_enabled;
    out["country_peer_service_calls"] = static_cast<int64_t>(
        _runtime_graph_country_peer_service_calls);
    out["country_peer_intents"] = static_cast<int64_t>(
        _runtime_graph_country_peer_intents);
    out["country_peer_completed"] = static_cast<int64_t>(
        _runtime_graph_country_peer_completed);
    out["country_peer_pending_results"] = static_cast<int64_t>(
        _runtime_graph_country_peer_pending);
    out["country_peer_rejected"] = static_cast<int64_t>(
        _runtime_graph_country_peer_rejected);
    out["country_peer_faults"] = static_cast<int64_t>(
        _runtime_graph_country_peer_faults);
    out["country_peer_fault_reason"] = String(
        _runtime_graph_country_peer_fault_reason.c_str());
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
        const bool country_worker_owns = _runtime_host != nullptr &&
            (_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) ||
             _runtime_host->country_authority_owner_is_worker());
        const bool effect_worker_owns = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT);
        const bool modifier_worker_owns = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::MODIFIER);
        const bool trigger_worker_owns = trigger_worker_authoritative();
        const bool ideology_worker_owns = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY);
        out["country_pending"] = !country_worker_owns && _country_runtime != nullptr &&
            static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day);
        out["trigger_pending"] = !trigger_worker_owns && _trigger_runtime != nullptr &&
            static_cast<TriggerRuntime *>(_trigger_runtime)->should_run(day);
        out["ideology_pending"] = !ideology_worker_owns && _ideology_runtime != nullptr &&
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->should_run(day);
        out["effect_pending"] = !effect_worker_owns && _effect_runtime != nullptr &&
            static_cast<EffectRuntime *>(_effect_runtime)->should_run(day);
        out["modifier_pending"] = !modifier_worker_owns && _modifier_runtime != nullptr &&
            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day);
        out["gameplay_effect_pending"] = !effect_worker_owns && _effect_runtime != nullptr &&
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

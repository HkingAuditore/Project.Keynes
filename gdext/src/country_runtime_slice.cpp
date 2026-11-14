#include "country_runtime.h"
#include "country_runtime_internal.h"

#include <algorithm>
#include <cstring>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace pk {

using namespace godot;

bool NativeCountryRuntime::should_run(int64_t day_index) const {
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) return false;
    // Worker owns the Country day. The sync facade must not keep the
    // economy/runtime-graph gate hot on leftover local queues / tech state —
    // main-thread peer work goes through service_peer_intents_main_thread.
    if (_sync_store_writes_forbidden) return false;
    if (_command_batch.active) return true;
    if (!_peer_pending_intents.empty()) return true;
    if (peer_rejection_needs_service(day_index)) return true;
    // Trigger/Effect often enqueue DISCOVER with effective_day = event.day + 1.
    // Incomplete effect results for those future commands must not pin today;
    // the due-command scan below already covers same-day Effect work, and an
    // in-flight batch is handled by _command_batch.active.
    for (const Command &command : _pending_commands)
        if (command.effective_day <= day_index) return true;
    if (_technology_points_good_id >= 0) {
        if (_pending_queue_enabled) {
            if (_pending_activation_index_dirty) rebuild_pending_activation_index();
            for (int32_t slot = 0;
                 slot < static_cast<int32_t>(_pending_activation_indices.size());
                 ++slot) {
                for (const int32_t technology :
                         _pending_activation_indices[static_cast<size_t>(slot)]) {
                    if (!peer_rejection_blocks_activation(slot, technology,
                                                           day_index))
                        return true;
                }
            }
        } else {
            for (int32_t slot = 0;
                 slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
                if (_countries.active[static_cast<size_t>(slot)] == 0) continue;
                const size_t word_base = static_cast<size_t>(slot) *
                    static_cast<size_t>(_technology_words);
                for (int32_t word = 0; word < _technology_words; ++word) {
                    uint64_t pending = _country_pending_technologies[
                        word_base + static_cast<size_t>(word)];
                    while (pending != 0) {
                        uint64_t low_bit = pending;
                        int32_t bit = 0;
                        while ((low_bit & 1u) == 0u) {
                            low_bit >>= 1u;
                            ++bit;
                        }
                        const int32_t technology = word * 64 + bit;
                        if (technology < static_cast<int32_t>(_technology_ids.size()) &&
                            !peer_rejection_blocks_activation(
                                slot, technology, day_index))
                            return true;
                        pending &= pending - 1;
                    }
                }
            }
        }
        for (const int32_t active_slot : _research_active_country_slots) {
            if (active_slot < 0 ||
                active_slot >= static_cast<int32_t>(_countries.active.size())) continue;
            const size_t slot = static_cast<size_t>(active_slot);
            if (_countries.active[slot] == 0) continue;
            // A completion can be left at the queue head when the final
            // research point was consumed before the completion sweep. Keep
            // the same-day country continuation alive so it can finalize the
            // head without waiting for another enqueue command or calendar day.
            for (int32_t domain = 0; domain < 4; ++domain) {
                const size_t length_index = slot * 4U +
                    static_cast<size_t>(domain);
                if (_country_research_queue_lengths[length_index] == 0) continue;
                const size_t queue_base = length_index * 8U;
                const int32_t technology = _country_research_queues[queue_base];
                if (technology >= 0 && !has_technology(static_cast<int32_t>(slot), technology) &&
                    !peer_rejection_blocks_activation(
                        static_cast<int32_t>(slot), technology, day_index) &&
                    progress_for(static_cast<int32_t>(slot), technology) >=
                        effective_research_cost(static_cast<int32_t>(slot), technology))
                    return true;
            }
            if (day_index <= _last_research_day) continue;
            const int64_t stock = _country_goods[
                slot * _good_ids.size() + static_cast<size_t>(_technology_points_good_id)];
            if (stock <= _country_research_deferred_points[slot]) continue;
            const size_t queue_base = slot * 4U;
            for (int32_t domain = 0; domain < 4; ++domain) {
                if (_country_research_queue_lengths[
                        queue_base + static_cast<size_t>(domain)] != 0) {
                    const size_t queue_index = (slot * 4U +
                        static_cast<size_t>(domain)) * 8U;
                    const int32_t technology = _country_research_queues[queue_index];
                    if (technology >= 0 &&
                        !peer_rejection_blocks_activation(
                            static_cast<int32_t>(slot), technology, day_index))
                        return true;
                }
            }
        }
    }
    return false;
}

bool NativeCountryRuntime::run_day_pod(
        const RuntimeCountryDayContext &context,
        RuntimeCountryDayCommit &out) {
    out = RuntimeCountryDayCommit{};
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        out.error_code = RuntimeCountryPodError::NOT_BOOTSTRAPPED;
        return false;
    }
    if (context.day < 0 || !std::isfinite(context.speed_scale)) {
        out.error_code = RuntimeCountryPodError::INVALID_CONTEXT;
        return false;
    }
    // Research completion may call these peer runtimes for Effect/Modifier
    // ACK and economy milestones. They need their own POD barrier adapters
    // before Country can safely become a worker-owned domain.
    if (_effect_runtime != nullptr || _modifier_runtime != nullptr ||
        _economy_runtime != nullptr) {
        out.error_code = RuntimeCountryPodError::CROSS_DOMAIN_BARRIER_REQUIRED;
        return false;
    }

    _state_hash_cache_valid = false;
    const uint64_t visual_generation_before = _visual_era_generation;
    _pod_execution = true;
    struct PodExecutionReset {
        bool &value;
        ~PodExecutionReset() { value = false; }
    } reset{_pod_execution};
    const CountryCoreStepResult step = run_slice_core(context.day);
    if (!step.ok) {
        out.error_code = RuntimeCountryPodError::COMMAND_REJECTED;
        out.preflight_ok = 0;
        out.completed = step.done ? 1 : 0;
        return false;
    }

    out.completed = step.done ? 1 : 0;
    out.preflight_ok = 1;
    out.ack_required = step.day_barrier ? 1 : 0;
    out.changed_countries = static_cast<uint32_t>(
        std::max(0, step.changed_countries));
    out.changed_territory_cells = static_cast<uint32_t>(
        std::max(0, step.changed_cells));
    out.research_work_units = static_cast<uint64_t>(
        std::max<int64_t>(0, _research_countries_scanned)) +
        static_cast<uint64_t>(std::max<int64_t>(0, _research_pending_checks)) +
        static_cast<uint64_t>(std::max<int64_t>(0, _research_discovery_checks));
    out.country_generation = _generation;
    out.state_hash = static_cast<uint64_t>(state_hash());
    if (step.changed_countries > 0)
        out.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
    if (step.changed_cells > 0)
        out.dirty_families |= RUNTIME_DIRTY_COUNTRY_TERRITORY;
    if (_visual_era_generation != visual_generation_before)
        out.dirty_families |= RUNTIME_DIRTY_COUNTRY_VISUAL_ERA;
    return true;
}

bool NativeCountryRuntime::validate_handle(uint64_t handle, int32_t &slot) const {
    slot = static_cast<int32_t>(handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
    return slot >= 0 && slot < static_cast<int32_t>(_countries.active.size()) &&
           _countries.active[static_cast<size_t>(slot)] != 0 &&
           _countries.generation[static_cast<size_t>(slot)] == generation;
}

uint64_t NativeCountryRuntime::make_handle(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size())) return 0;
    return (static_cast<uint64_t>(_countries.generation[static_cast<size_t>(slot)]) << 32U) |
           static_cast<uint32_t>(slot);
}

Dictionary NativeCountryRuntime::run_slice(const Dictionary &ctx) {
    if (!_configured || !_bootstrapped) return fail("country_not_bootstrapped");
    const int64_t requested_day = dict_num<int64_t>(ctx, "day_index", 0);
    CountryCoreStepResult result = run_slice_core(requested_day);
    if (result.status == CountryCoreStepStatus::OFF) {
        Dictionary out;
        out["ok"] = true;
        out["done"] = true;
        out["stage"] = "idle";
        out["path"] = "off";
        out["core_status"] = country_core_step_status_name(result.status);
        return out;
    }

    publish_report(result.stage.c_str(), requested_day, result.preflight_ms,
                   result.apply_ms, result.publish_ms,
                   result.changed_cells, result.changed_countries,
                   result.published_to_slot, result.reason);
    Dictionary out = report();
    out["ok"] = result.ok;
    out["done"] = result.done;
    out["stage"] = String(result.stage.c_str());
    out["path"] = String(result.path.c_str());
    out["core_status"] = country_core_step_status_name(result.status);
    out["elapsed_ms"] = result.elapsed_ms;
    out["cursor_start"] = result.cursor_start;
    out["cursor_end"] = result.cursor_end;
    out["cursor_total"] = result.cursor_total;
    out["progress_ratio"] = result.progress_ratio;
    out["country_day_barrier"] = result.day_barrier;
    out["observation_batch_input"] = result.observation_batch_input;
    out["observation_batch_added"] = result.observation_batch_added;
    if (!result.reason.empty()) out["fatal_reason"] = result.reason.c_str();
    if (!result.changed_cell_indices.empty()) {
        PackedInt32Array changed_cells;
        PackedInt32Array changed_owners;
        changed_cells.resize(static_cast<int64_t>(result.changed_cell_indices.size()));
        changed_owners.resize(static_cast<int64_t>(result.changed_cell_owners.size()));
        std::memcpy(changed_cells.ptrw(), result.changed_cell_indices.data(),
                    result.changed_cell_indices.size() * sizeof(int32_t));
        std::memcpy(changed_owners.ptrw(), result.changed_cell_owners.data(),
                    result.changed_cell_owners.size() * sizeof(int32_t));
        out["_changed_cell_indices"] = changed_cells;
        out["_changed_cell_owners"] = changed_owners;
    }
    return out;
}

void NativeCountryRuntime::publish_report(const char *stage, int64_t day,
                                          double preflight_ms, double apply_ms,
                                          double publish_ms, int32_t changed_cells,
                                          int32_t changed_countries, bool published,
                                          const std::string &reason) {
    const Clock::time_point report_start = Clock::now();
    _report.clear();
    _report["configured"] = _configured;
    _report["bootstrapped"] = _bootstrapped;
    _report["schema_version"] = SCHEMA_VERSION;
    _report["runtime_mode"] = _mode == MODE_ACTIVE ? "ACTIVE" : (_mode == MODE_PROBE ? "PROBE" : "OFF");
    const char *report_mode = _full_diagnostics ? "FULL" : "LIGHT";
    _report["report_mode"] = report_mode;
    // Keep the explicit perf-record column names alongside the short legacy
    // names. These are transient diagnostics and are intentionally not part of
    // save/state or event hash contracts.
    _report["country_report_mode"] = report_mode;
    _report["path"] = _mode == MODE_ACTIVE ? "native_active" : (_mode == MODE_PROBE ? "native_probe" : "off");
    _report["stage"] = stage;
    _report["day_index"] = day;
    _report["country_count"] = static_cast<int64_t>(_countries.active.size());
    _report["cell_count"] = _cell_count;
    _report["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    _report["peer_async_mode"] = _peer_async_mode;
    _report["peer_pending_intents"] = static_cast<int64_t>(
        _peer_pending_intents.size());
    _report["peer_queued_intents"] = static_cast<int64_t>(
        _peer_intent_queue.size());
    _report["peer_cached_results"] = static_cast<int64_t>(
        _peer_result_cache.size());
    _report["peer_intents_emitted"] = static_cast<int64_t>(_peer_intents_emitted);
    _report["peer_results_consumed"] = static_cast<int64_t>(_peer_results_consumed);
    _report["research_queue_size"] = _pending_activation_index_dirty
        ? static_cast<int64_t>(-1) : _pending_activation_count;
    _report["research_pending_queue_enabled"] = _pending_queue_enabled;
    _report["country_light_report_enabled"] = _light_report_enabled;
    _report["research_queue_rebuilds"] = _research_queue_rebuilds;
    _report["research_full_scan_fallbacks"] = _research_full_scan_fallbacks;
    _report["fallback_reason"] = String(_research_queue_fallback_reason.c_str());
    _report["fail_stage"] = _research_queue_fallback_reason.empty()
        ? String() : String("research_pending_queue");
    _report["fallback"] = !_research_queue_fallback_reason.empty();
    _report["cursor_start"] = 0;
    _report["cursor_end"] = changed_cells + changed_countries;
    _report["changed_cells"] = changed_cells;
    _report["changed_countries"] = changed_countries;
    _report["command_preflight_ms"] = preflight_ms;
    _report["command_apply_ms"] = apply_ms;
    _report["aggregate_publish_ms"] = publish_ms;
    _report["native_ms"] = preflight_ms + apply_ms + publish_ms;
    _report["generation"] = static_cast<int64_t>(_generation);
    _report["state_generation"] = static_cast<int64_t>(_generation);
    _report["territory_generation"] =
        static_cast<int64_t>(_territory_generation);
    _report["research_generation"] =
        static_cast<int64_t>(_research_generation);
    _report["visual_generation"] =
        static_cast<int64_t>(_visual_era_generation);
    _report["research_activation_ms"] = _research_activation_ms;
    _report["research_allocation_ms"] = _research_allocation_ms;
    _report["research_effect_ack_ms"] = _research_effect_ack_ms;
    _report["research_discovery_ms"] = _research_discovery_ms;
    _report["research_modifier_ms"] = _research_modifier_ms;
    _report["research_countries_scanned"] = _research_countries_scanned;
    _report["research_active_countries"] = _research_active_countries;
    _report["research_pending_checks"] = _research_pending_checks;
    _report["research_discovery_checks"] = _research_discovery_checks;
    _report["research_discovery_frontier_mismatches"] =
        _research_discovery_frontier_mismatches;
    _report["research_modifier_queries"] = _research_modifier_queries;
    _report["research_modifier_cache_hits"] = _research_modifier_cache_hits;
    _report["research_remainder_iterations"] = _research_remainder_iterations;
    const Clock::time_point hash_start = Clock::now();
    if (_full_diagnostics) {
        _report["state_hash"] = state_hash();
        _report["state_hash_stale"] = false;
    } else {
        // Keep the compatibility field for startup/save consumers, but never
        // trigger a full-map scan from the production report path.
        _report["state_hash"] = static_cast<int64_t>(
            _state_hash_cache_valid ? _state_hash_cache : 0);
        _report["state_hash_stale"] = !_state_hash_cache_valid;
    }
    const double state_hash_ms = elapsed_ms(hash_start);
    _report["state_hash_ms"] = state_hash_ms;
    _report["country_state_hash_ms"] = state_hash_ms;
    _report["published_to_slot"] = published;
    _report["done"] = true;
    _report["country_day_barrier"] = false;
    _report["last_committed_day"] = _last_committed_day;
    // Cell tax policy statistics require walking the intern table (and can
    // approach map-sized work). Keep them out of the ACTIVE/LIGHT report;
    // FULL remains the explicit diagnostic path for these counters.
    if (_full_diagnostics) {
        int64_t authoritative_policies = 0;
        int64_t shared_policies = 0;
        int64_t cell_tax_overrides = 0;
        for (size_t id = 1; id < _cell_tax_policy_refcounts.size(); ++id) {
            if (_cell_tax_policy_refcounts[id] == 0) continue;
            ++authoritative_policies;
            if (_cell_tax_policy_refcounts[id] > 1) ++shared_policies;
            cell_tax_overrides += static_cast<int64_t>(
                _cell_tax_policies[id].overrides.size());
        }
        _report["cell_tax_authoritative_policy_count"] = authoritative_policies;
        _report["cell_tax_shared_policy_count"] = shared_policies;
        _report["cell_tax_override_count"] = cell_tax_overrides;
    } else {
        _report["cell_tax_authoritative_policy_count"] = 0;
        _report["cell_tax_shared_policy_count"] = 0;
        _report["cell_tax_override_count"] = 0;
    }
    int64_t oldest_due = day;
    for (const Command &command : _pending_commands)
        oldest_due = std::min(oldest_due, command.effective_day);
    _report["pending_latency_days"] = _pending_commands.empty()
        ? 0 : std::max<int64_t>(0, day - oldest_due);
    if (_full_diagnostics) {
        int64_t memory_bytes =
            static_cast<int64_t>(_countries.active.size() * sizeof(uint8_t) +
            _countries.generation.size() * sizeof(uint32_t) +
            _countries.territory_count.size() * sizeof(int32_t) +
            _countries.cash.size() * sizeof(int64_t) +
            _countries.state_version.size() * sizeof(uint64_t) +
            _cell_country_slot.size() * sizeof(int32_t) +
            _country_cell_offsets.size() * sizeof(int32_t) +
            _country_cells.size() * sizeof(int32_t) +
            _country_technologies.size() * sizeof(uint64_t) +
            _country_goods.size() * sizeof(int64_t) +
            _cell_tax_policy_ids.size() * sizeof(uint32_t) +
            _cell_tax_policies.size() * sizeof(CellTaxPolicy) +
            _cell_tax_policy_refcounts.size() * sizeof(uint32_t));
        for (const CellTaxPolicy &policy : _cell_tax_policies)
            memory_bytes += static_cast<int64_t>(
                policy.overrides.capacity() * sizeof(CellTaxOverride));
        for (const std::string &value : _countries.stable_id) memory_bytes += value.capacity() + 1;
        for (const std::string &value : _countries.display_name) memory_bytes += value.capacity() + 1;
        for (const std::string &value : _good_ids) memory_bytes += value.capacity() + 1;
        for (const std::string &value : _technology_ids) memory_bytes += value.capacity() + 1;
        memory_bytes += static_cast<int64_t>(_is_water.capacity() * sizeof(uint8_t) +
            _starting_technologies.capacity() * sizeof(int32_t) +
            _pending_commands.size() * sizeof(Command) + _events.size() * sizeof(Event));
        for (const Command &command : _pending_commands)
            memory_bytes += command.stable_id.capacity() + command.display_name.capacity() + 2;
        // Account conservatively for unordered-map nodes/buckets. Exact allocator
        // overhead is implementation-specific; this estimate intentionally rounds up.
        memory_bytes += static_cast<int64_t>((_good_index.size() + _technology_index.size()) * 64 +
            (_good_index.bucket_count() + _technology_index.bucket_count()) * sizeof(void *));
        _report["memory_bytes"] = memory_bytes;
    } else {
        _report["memory_bytes"] = 0;
    }
    if (!reason.empty()) {
        _report["fallback_reason"] = reason.c_str();
        _report["fail_stage"] = stage;
    }
    const double report_build_ms = elapsed_ms(report_start);
    _report["report_build_ms"] = report_build_ms;
    _report["country_report_build_ms"] = report_build_ms;
    _report["research_report_ms"] = report_build_ms;
}

Dictionary NativeCountryRuntime::report() const {
    Dictionary out = _report.duplicate();
    const Dictionary transactions = economy_asset_transaction_report();
    out["economy_asset_transactions"] = transactions;
    out["economy_asset_ledger_failures"] = transactions.get(
        "ledger_failures", 0);
    return out;
}

void NativeCountryRuntime::mark_slot_publication(bool published, double publish_ms,
                                                  const String &reason) {
    _report["published_to_slot"] = published;
    _report["slot_publish_ms"] = publish_ms;
    _report["aggregate_publish_ms"] =
        static_cast<double>(_report.get("aggregate_publish_ms", 0.0)) + publish_ms;
    _report["native_ms"] = static_cast<double>(_report.get("native_ms", 0.0)) + publish_ms;
    if (!reason.is_empty()) _report["publish_reason"] = reason;
    else _report.erase("publish_reason");
}



bool NativeCountryRuntime::report_peer_rejection(
        int64_t day, CountryCoreStepResult &result) {
    const CountryPeerProtocolStatus status = peer_protocol_status();
    if (_command_batch.active || status.has_unreported_rejection == 0 ||
        !peer_rejection_needs_service(day))
        return false;
    result.status = CountryCoreStepStatus::REJECTED;
    result.ok = false;
    result.done = true;
    result.semantic_commit = false;
    result.day_barrier = false;
    result.stage = "peer_rejection";
    result.reason = status.rejection_reason[0] != '\0'
        ? std::string(status.rejection_reason.data())
        : "country_peer_result_rejected";
    mark_peer_rejections_reported(day);
    record_reference_frame("peer_rejected", day, false, false);
    close_boundary_seal();
    return true;
}

bool NativeCountryRuntime::prepare_country_slice(
        CoreSliceContext &context) {
    auto &result = context.result;
    const int64_t requested_day = context.requested_day;
    if (!_command_batch.active) {
        if (!_boundary_seal_active) open_implicit_boundary(requested_day);
        result.seal = _boundary_seal;
        if (_boundary_seal.session_epoch != _session_epoch) {
            result.status = CountryCoreStepStatus::REJECTED;
            result.ok = false;
            result.stage = "boundary_seal";
            result.reason = "country_boundary_session_mismatch";
            close_boundary_seal();
            return false;
        }
        if (_boundary_seal.day != requested_day) {
            result.status = CountryCoreStepStatus::REJECTED;
            result.ok = false;
            result.stage = "boundary_seal";
            result.reason = "country_boundary_day_mismatch";
            close_boundary_seal();
            return false;
        }
        if (_boundary_seal.expected_base_generation != _generation ||
            _boundary_seal.catalog_hash != catalog_hash()) {
            result.status = CountryCoreStepStatus::REJECTED;
            result.ok = false;
            result.stage = "boundary_seal";
            result.reason = "country_boundary_base_mismatch";
            close_boundary_seal();
            return false;
        }
        begin_reference_boundary(requested_day);
    } else {
        result.seal = _boundary_seal;
    }

    // A slice may commit commands, research progress, goods, territory, or
    // signal evidence. Invalidate the transient hash cache at the slice
    // boundary; the generation/research/tax keys still avoid repeated scans
    // between reports and bridge queries in the same committed state.
    _state_hash_cache_valid = false;

    // A peer rejection is a durable protocol outcome, not an idle result.
    // Report it once at the next semantic boundary before admitting another
    // command batch. The committed Country state remains intact; only the
    // rejected peer operation is blocked until its retry day.
    const auto peer_rejection_result = [&]() {
        const CountryPeerProtocolStatus status = peer_protocol_status();
        if (_command_batch.active || status.has_unreported_rejection == 0 ||
            !peer_rejection_needs_service(requested_day))
            return false;
        result.status = CountryCoreStepStatus::REJECTED;
        result.ok = false;
        result.done = true;
        result.semantic_commit = false;
        result.day_barrier = false;
        result.stage = "peer_rejection";
        result.reason = status.rejection_reason[0] != '\0'
            ? std::string(status.rejection_reason.data())
            : "country_peer_result_rejected";
        mark_peer_rejections_reported(requested_day);
        record_reference_frame("peer_rejected", requested_day, false, false);
        close_boundary_seal();
        return true;
    };
    if (peer_rejection_result()) return false;

    context.start = Clock::now();
    const Clock::time_point &start = context.start;
    if (!_command_batch.active) {
        const uint64_t admitted_watermark =
            _boundary_seal.last_admitted_submit_order;
        const auto admitted_and_due = [&](const Command &command) {
            return command.submit_order <= admitted_watermark &&
                command.effective_day <= requested_day;
        };
        const bool all_selected = std::all_of(
            _pending_commands.begin(), _pending_commands.end(), admitted_and_due);
        if (all_selected) {
            _command_batch.commands.swap(_pending_commands);
        } else {
            std::vector<Command> future_commands;
            _command_batch.commands.reserve(_pending_commands.size());
            future_commands.reserve(_pending_commands.size());
            for (Command &command : _pending_commands) {
                if (admitted_and_due(command))
                    _command_batch.commands.push_back(std::move(command));
                else
                    future_commands.push_back(std::move(command));
            }
            _pending_commands.swap(future_commands);
        }
        if (_command_batch.commands.empty()) {
            CountryPeerContext peer_context;
            std::string peer_error;
            if (!capture_peer_context(requested_day,
                                      _reference_continuation_index,
                                      peer_context, peer_error)) {
                result.status = CountryCoreStepStatus::FAULTED;
                result.ok = false;
                result.done = true;
                result.stage = "peer_context_capture";
                result.reason = peer_error.empty()
                    ? "country_peer_context_capture_failed" : peer_error;
                close_boundary_seal();
                return false;
            }
            const int32_t research_changed = run_research_day(
                requested_day, &peer_context, &peer_context);
            if (!_peer_protocol_fault_reason.empty()) {
                result.status = CountryCoreStepStatus::FAULTED;
                result.ok = false;
                result.done = true;
                result.stage = "peer_retry";
                result.reason = _peer_protocol_fault_reason;
                close_boundary_seal();
                return false;
            }
            if (peer_rejection_result()) return false;
            _last_committed_day = std::max(_last_committed_day, requested_day);
            const bool day_barrier = ack_chain_due(requested_day,
                                                   &peer_context);
            const double total_ms = elapsed_ms(start);
            result.status = day_barrier
                ? CountryCoreStepStatus::NEED_PEER_RESULTS
                : CountryCoreStepStatus::DAY_QUIESCENT;
            result.semantic_commit = true;
            result.day_barrier = day_barrier;
            result.stage = research_changed > 0 ? "research_publish" : "idle";
            result.publish_ms = total_ms;
            result.elapsed_ms = total_ms;
            result.changed_countries = research_changed;
            record_reference_frame(research_changed > 0
                    ? "research_publish" : "idle",
                requested_day, true, day_barrier);
            close_boundary_seal();
            // Research completion registers Effect instances after the morning
            // Effect slot. Raise the barrier so the continuation drain can ACK
            // before the next country day; country should_run is already false
            // because _last_research_day == requested_day.
            return false;
        }
        const auto command_less = [](const Command &lhs, const Command &rhs) {
            if (lhs.effective_day != rhs.effective_day)
                return lhs.effective_day < rhs.effective_day;
            if (lhs.sequence != rhs.sequence) return lhs.sequence < rhs.sequence;
            return lhs.submit_order < rhs.submit_order;
        };
        if (!std::is_sorted(_command_batch.commands.begin(), _command_batch.commands.end(),
                            command_less))
            std::sort(_command_batch.commands.begin(), _command_batch.commands.end(), command_less);
        _command_batch.active = true;
        _command_batch.day = requested_day;
        _command_batch.cursor = 0;
        _command_batch.preflight_ms = 0.0;
        _command_batch.countries = _countries;
        _command_batch.direct_unique_territory = !_command_batch.commands.empty();
        int32_t previous_cell = -1;
        for (const Command &command : _command_batch.commands) {
            if (command.opcode == COMMAND_CREATE_COUNTRY) {
                _command_batch.stage_technologies = true;
                _command_batch.stage_goods = true;
                _command_batch.stage_research = true;
                _command_batch.stage_signals = true;
                _command_batch.stage_tax = true;
            } else if (command.opcode == COMMAND_GRANT_TECHNOLOGY) {
                _command_batch.stage_technologies = true;
                _command_batch.stage_research = true;
            } else if (command.opcode == COMMAND_CONSUME_TREASURY_GOODS ||
                       command.opcode == COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES) {
                _command_batch.stage_goods = true;
            } else if (command.opcode == COMMAND_ANNEX_COUNTRY) {
                _command_batch.stage_goods = true;
                _command_batch.stage_research = true;
                _command_batch.stage_technologies = true;
                _command_batch.stage_cell_tax = true;
            } else if (command.opcode >= COMMAND_SET_RESEARCH_WEIGHTS &&
                       command.opcode <= COMMAND_REVEAL_ALL_TECHNOLOGIES) {
                _command_batch.stage_research = true;
                _command_batch.stage_technologies = true;
            } else if (command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL) {
                _command_batch.stage_signals = true;
                _command_batch.stage_research = true;
            } else if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
                       command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE) {
                _command_batch.stage_tax = true;
                _command_batch.stage_cell_tax = true;
            } else if (command.opcode == COMMAND_TRANSFER_TERRITORY ||
                       command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY) {
                _command_batch.stage_cell_tax = true;
            } else if (command.opcode >= COMMAND_SET_CELL_TAX_DEFAULT &&
                       command.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY) {
                _command_batch.stage_cell_tax = true;
            }
            if ((command.opcode != COMMAND_TRANSFER_TERRITORY &&
                 command.opcode != COMMAND_CLAIM_UNOWNED_TERRITORY) ||
                command.cell <= previous_cell) {
                _command_batch.direct_unique_territory = false;
            } else {
                previous_cell = command.cell;
            }
        }
        if (_command_batch.stage_technologies)
            _command_batch.technologies = _country_technologies;
        if (_command_batch.stage_goods)
            _command_batch.goods = _country_goods;
        if (_command_batch.stage_research) {
            _command_batch.discovered = _country_discovered;
            _command_batch.pending = _country_pending_technologies;
            _command_batch.progress = _country_research_progress;
            _command_batch.research_queues = _country_research_queues;
            _command_batch.research_queue_lengths = _country_research_queue_lengths;
            _command_batch.research_weights_bp = _country_research_weights_bp;
            _command_batch.research_auto_purchase = _country_research_auto_purchase;
            _command_batch.research_daily_budgets = _country_research_daily_budgets;
            _command_batch.research_deferred_points = _country_research_deferred_points;
        }
        if (_command_batch.stage_research || _command_batch.stage_signals) {
            _command_batch.signals = _country_research_signals;
            _command_batch.signal_evidence = _country_research_signal_evidence;
        }
        if (_command_batch.stage_signals)
            _command_batch.signal_cells = _country_research_signal_cells;
        if (_command_batch.stage_tax) {
            _command_batch.tax_defaults = _country_tax_defaults;
            _command_batch.tax_default_modes = _country_tax_default_modes;
            _command_batch.income_tax_overrides =
                _country_income_tax_overrides;
            _command_batch.consumption_tax_overrides =
                _country_consumption_tax_overrides;
            _command_batch.business_tax_overrides =
                _country_business_tax_overrides;
            _command_batch.import_tax_overrides =
                _country_import_tax_overrides;
            _command_batch.export_tax_overrides =
                _country_export_tax_overrides;
            _command_batch.income_tax_mode_overrides =
                _country_income_tax_mode_overrides;
            _command_batch.consumption_tax_mode_overrides =
                _country_consumption_tax_mode_overrides;
            _command_batch.business_tax_mode_overrides =
                _country_business_tax_mode_overrides;
            _command_batch.import_tax_mode_overrides =
                _country_import_tax_mode_overrides;
            _command_batch.export_tax_mode_overrides =
                _country_export_tax_mode_overrides;
        }
        if (_command_batch.stage_cell_tax)
            _command_batch.cell_tax_updates.reserve(
                std::min(_command_batch.commands.size(),
                         static_cast<size_t>(_cell_count)));
        if (!_command_batch.direct_unique_territory) {
            // ANNEX can move every cell of a (possibly chained) victim, so an
            // annex batch reserves for the full map: distinct delta keys are
            // bounded by cell_count, keeping the open-addressing table sparse.
            const bool has_annex = std::any_of(
                _command_batch.commands.begin(), _command_batch.commands.end(),
                [](const Command &command) {
                    return command.opcode == COMMAND_ANNEX_COUNTRY;
                });
            _command_batch.cell_delta.reserve(has_annex
                ? std::min(_command_batch.commands.size() +
                               static_cast<size_t>(std::max(_cell_count, 0)),
                           static_cast<size_t>(std::max(_cell_count, 1)))
                : _command_batch.commands.size());
        }
        _command_batch.cell_delta_order.reserve(_command_batch.commands.size());
        if (_command_batch.direct_unique_territory)
            _command_batch.direct_cell_owners.reserve(_command_batch.commands.size());
        // The public ring is capped at 2048 entries. Reserving one Event per
        // territory command made a 100k-cell transfer allocate several MiB of
        // unused string-bearing records on the hot path.
        _command_batch.events.reserve(std::min<size_t>(_command_batch.commands.size(), 2048));
        _command_batch.changed_countries.assign(_countries.active.size(), 0);
    }
    context.day = _command_batch.day;
    context.cursor_start = _command_batch.cursor;
    context.cursor_limit = std::min(
        _command_batch.commands.size(),
        _command_batch.cursor + static_cast<size_t>(_max_commands_per_slice));
    return true;
}

} // namespace pk

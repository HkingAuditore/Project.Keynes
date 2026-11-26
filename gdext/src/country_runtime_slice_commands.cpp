#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_core_apply.h"
#include "economy_effect_forward.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <numeric>
#include <type_traits>
#include <unordered_set>

namespace pk {


bool NativeCountryRuntime::preflight_country_slice(
        CoreSliceContext &context) {
    auto &result = context.result;
    const Clock::time_point &start = context.start;
    CommandBatchState &batch = _command_batch;
    const int64_t day = context.day;
    const size_t cursor_start = context.cursor_start;
    size_t &cursor_limit = context.cursor_limit;
    std::string error;

    auto staged_handle = [&](uint64_t handle, int32_t &slot) -> bool {
        slot = static_cast<int32_t>(handle & 0xffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
        return slot >= 0 && slot < static_cast<int32_t>(batch.countries.active.size()) &&
               batch.countries.active[static_cast<size_t>(slot)] != 0 &&
               batch.countries.generation[static_cast<size_t>(slot)] == generation;
    };
    auto owner_of = [&](int32_t cell) -> int32_t {
        int32_t owner = NEUTRAL_SLOT;
        return batch.cell_delta.get(cell, owner)
            ? owner : _cell_country_slot[static_cast<size_t>(cell)];
    };
    auto mark_country = [&](int32_t slot) {
        if (slot < 0) return;
        if (slot >= static_cast<int32_t>(batch.changed_countries.size()))
            batch.changed_countries.resize(static_cast<size_t>(slot + 1), 0);
        batch.changed_countries[static_cast<size_t>(slot)] = 1;
    };
    auto staged_cell_policy = [&](int32_t cell) -> CellTaxPolicy & {
        auto [it, inserted] = batch.cell_tax_updates.try_emplace(cell);
        if (inserted) {
            const uint32_t policy_id =
                _cell_tax_policy_ids[static_cast<size_t>(cell)];
            it->second = cell_tax_policy(policy_id);
        }
        return it->second;
    };

    // Observation-only ingress is commutative. Validate the complete batch,
    // sort/unique once, then linearly merge with the authoritative ordered
    // evidence vector. This avoids O(n^2) shifts during large visibility
    // backfills while preserving the same atomic command boundary.
    const bool observation_only = batch.cursor == 0 && !batch.commands.empty() &&
        std::all_of(batch.commands.begin(), batch.commands.end(), [](const Command &command) {
            return command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL;
        });
    if (observation_only) {
        struct Observation {
            int32_t slot;
            uint64_t key;
            uint64_t handle;
            int32_t source;
            int64_t effective_day;
        };
        std::vector<Observation> incoming;
        incoming.reserve(batch.commands.size());
        for (const Command &command : batch.commands) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_research_signal_ids.size()) ||
                command.cell < 0 || command.cell >= _cell_count) {
                error = "country_research_signal_command_invalid";
                break;
            }
            incoming.push_back(Observation{
                slot,
                (uint64_t(uint32_t(command.aux)) << 32U) | uint32_t(command.cell),
                command.target_handle,
                int32_t(command.value),
                command.effective_day});
        }
        if (error.empty()) {
            std::sort(incoming.begin(), incoming.end(), [](const Observation &a,
                                                           const Observation &b) {
                if (a.slot != b.slot) return a.slot < b.slot;
                return a.key < b.key;
            });
            incoming.erase(std::unique(incoming.begin(), incoming.end(),
                [](const Observation &a, const Observation &b) {
                    return a.slot == b.slot && a.key == b.key;
                }), incoming.end());
            batch.observation_batch_input = static_cast<int64_t>(batch.commands.size());
            size_t begin = 0;
            while (begin < incoming.size()) {
                size_t end = begin + 1;
                while (end < incoming.size() && incoming[end].slot == incoming[begin].slot) ++end;
                const int32_t slot = incoming[begin].slot;
                std::vector<uint64_t> unique_keys;
                unique_keys.reserve(end - begin);
                for (size_t i = begin; i < end; ++i) unique_keys.push_back(incoming[i].key);
                std::vector<uint64_t> &existing = batch.signal_cells[size_t(slot)];
                std::vector<uint64_t> added;
                added.reserve(unique_keys.size());
                std::set_difference(unique_keys.begin(), unique_keys.end(),
                    existing.begin(), existing.end(), std::back_inserter(added));
                if (!added.empty()) {
                    std::vector<uint64_t> merged;
                    merged.reserve(existing.size() + added.size());
                    std::set_union(existing.begin(), existing.end(),
                        unique_keys.begin(), unique_keys.end(), std::back_inserter(merged));
                    existing.swap(merged);
                    batch.observation_batch_added += static_cast<int64_t>(added.size());
                    batch.countries.state_version[size_t(slot)] += added.size();
                    mark_country(slot);
                    size_t added_begin = 0;
                    while (added_begin < added.size()) {
                        const int32_t signal = int32_t(added[added_begin] >> 32U);
                        size_t added_end = added_begin + 1;
                        while (added_end < added.size() &&
                               int32_t(added[added_end] >> 32U) == signal) ++added_end;
                        const int32_t delta = int32_t(added_end - added_begin);
                        const int32_t first_cell = int32_t(added[added_begin] & 0xffffffffU);
                        int64_t first_effective_day =
                            std::numeric_limits<int64_t>::max();
                        int64_t last_effective_day = 0;
                        for (size_t added_index = added_begin;
                             added_index < added_end; ++added_index) {
                            const auto observation = std::lower_bound(
                                incoming.begin() + static_cast<ptrdiff_t>(begin),
                                incoming.begin() + static_cast<ptrdiff_t>(end),
                                added[added_index],
                                [](const Observation &candidate, uint64_t key) {
                                    return candidate.key < key;
                                });
                            if (observation ==
                                incoming.begin() + static_cast<ptrdiff_t>(end))
                                continue;
                            first_effective_day = std::min(
                                first_effective_day, observation->effective_day);
                            last_effective_day = std::max(
                                last_effective_day, observation->effective_day);
                        }
                        if (first_effective_day ==
                            std::numeric_limits<int64_t>::max()) {
                            first_effective_day = day;
                            last_effective_day = day;
                        }
                        if (_research_signal_words > 0)
                            batch.signals[size_t(slot) * _research_signal_words + signal / 64] |=
                                uint64_t{1} << (signal % 64);
                        std::vector<SignalEvidence> &evidence = batch.signal_evidence[size_t(slot)];
                        auto evidence_it = std::lower_bound(evidence.begin(), evidence.end(), signal,
                            [](const SignalEvidence &entry, int32_t value) {
                                return entry.signal < value;
                            });
                        if (evidence_it == evidence.end() || evidence_it->signal != signal) {
                            SignalEvidence entry;
                            entry.signal = signal;
                            entry.first_day = first_effective_day;
                            entry.first_cell = first_cell;
                            evidence_it = evidence.insert(evidence_it, entry);
                        }
                        evidence_it->count += delta;
                        evidence_it->last_day = std::max(
                            evidence_it->last_day, last_effective_day);
                        Event event;
                        event.day = day;
                        event.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL;
                        event.country_handle = incoming[begin].handle;
                        event.cell = first_cell;
                        event.new_country_slot = slot;
                        event.signal_id = signal;
                        event.signal_source_kind = incoming[begin].source;
                        event.evidence_delta = delta;
                        batch.events.push_back(std::move(event));
                        added_begin = added_end;
                    }
                }
                begin = end;
            }
            batch.cursor = batch.commands.size();
            cursor_limit = batch.commands.size();
        }
    }
    if (!error.empty()) batch.cursor = cursor_limit;

#include "country_runtime_slice_commands_preflight_apply.inc"
    batch.preflight_ms += elapsed_ms(start);

    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        const uint64_t command_hash = reference_command_hash(batch.commands);
        const uint64_t command_count =
            static_cast<uint64_t>(batch.commands.size());
        for (const Command &command : batch.commands) {
            push_typed_receipt(command,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION, error);
            if (command.effect_request_id == 0) continue;
            CountryEffectCommandResult &result = _effect_command_results[command.effect_request_id];
            result.complete = 1; result.ok = 0; result.reason = error;
        }
        _command_batch = {};
        record_reference_frame("command_rejected", day, false, false,
                               command_hash, command_count);
        close_boundary_seal();
        result.status = CountryCoreStepStatus::REJECTED;
        result.ok = false;
        result.stage = "command_preflight";
        result.reason = error;
        result.preflight_ms = preflight_ms;
        result.elapsed_ms = preflight_ms;
        return false;
    }

    if (batch.cursor < batch.commands.size()) {
        record_reference_frame("command_preflight", day, false, true,
            reference_command_hash(batch.commands),
            static_cast<uint64_t>(batch.commands.size()));
        result.status = CountryCoreStepStatus::PROGRESS;
        result.done = false;
        result.day_barrier = true;
        result.stage = "command_preflight";
        result.preflight_ms = batch.preflight_ms;
        result.elapsed_ms = batch.preflight_ms;
        result.cursor_start = static_cast<int64_t>(cursor_start);
        result.cursor_end = static_cast<int64_t>(batch.cursor);
        result.cursor_total = static_cast<int64_t>(batch.commands.size());
        result.progress_ratio = static_cast<double>(batch.cursor) /
            static_cast<double>(batch.commands.size());
        return false;
    }

    for (size_t slot = 0; slot < batch.countries.active.size(); ++slot) {
        if (batch.countries.active[slot] != 0 && batch.countries.territory_count[slot] <= 0) {
                error = "country_last_territory_protected";
            break;
        }
    }
    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        const uint64_t command_hash = reference_command_hash(batch.commands);
        const uint64_t command_count =
            static_cast<uint64_t>(batch.commands.size());
        for (const Command &command : batch.commands) {
            push_typed_receipt(command,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION, error);
            if (command.effect_request_id == 0) continue;
            CountryEffectCommandResult &result = _effect_command_results[command.effect_request_id];
            result.complete = 1; result.ok = 0; result.reason = error;
        }
        _command_batch = {};
        record_reference_frame("command_rejected", day, false, false,
                               command_hash, command_count);
        close_boundary_seal();
        result.status = CountryCoreStepStatus::REJECTED;
        result.ok = false;
        result.stage = "command_preflight";
        result.reason = error;
        result.preflight_ms = preflight_ms;
        result.elapsed_ms = preflight_ms;
        return false;
    }
    return true;

}


bool NativeCountryRuntime::commit_country_slice(
        CoreSliceContext &context) {
    auto &result = context.result;
    CommandBatchState &batch = _command_batch;
    const int64_t day = context.day;
    const size_t cursor_limit = context.cursor_limit;
    const double preflight_ms = batch.preflight_ms;
    const uint64_t reference_batch_hash = reference_command_hash(batch.commands);
    const uint64_t reference_batch_count =
        static_cast<uint64_t>(batch.commands.size());
    const int32_t changed_country_count = static_cast<int32_t>(std::count(
        batch.changed_countries.begin(), batch.changed_countries.end(), uint8_t{1}));
    SparseCellDelta cell_delta = std::move(batch.cell_delta);
    std::vector<int32_t> cell_delta_order = std::move(batch.cell_delta_order);
    std::vector<int32_t> direct_cell_owners = std::move(batch.direct_cell_owners);
    const bool direct_unique_territory = batch.direct_unique_territory;
    std::vector<Event> staged_events = std::move(batch.events);
    CountryStore staged_countries = std::move(batch.countries);
    std::vector<uint64_t> staged_technologies = std::move(batch.technologies);
    std::vector<int64_t> staged_goods = std::move(batch.goods);
    std::vector<uint64_t> staged_discovered = std::move(batch.discovered);
    std::vector<uint64_t> staged_pending = std::move(batch.pending);
    auto staged_progress = std::move(batch.progress);
    std::vector<int32_t> staged_research_queues = std::move(batch.research_queues);
    std::vector<uint8_t> staged_research_queue_lengths = std::move(batch.research_queue_lengths);
    std::vector<int32_t> staged_research_weights = std::move(batch.research_weights_bp);
    std::vector<uint8_t> staged_auto_purchase = std::move(batch.research_auto_purchase);
    std::vector<int64_t> staged_deferred_points = std::move(batch.research_deferred_points);
    std::vector<uint64_t> staged_signals = std::move(batch.signals);
    auto staged_signal_cells = std::move(batch.signal_cells);
    auto staged_signal_evidence = std::move(batch.signal_evidence);
    std::vector<int32_t> staged_tax_defaults =
        std::move(batch.tax_defaults);
    std::vector<int32_t> staged_tax_default_modes =
        std::move(batch.tax_default_modes);
    std::vector<int32_t> staged_income_tax =
        std::move(batch.income_tax_overrides);
    std::vector<int32_t> staged_consumption_tax =
        std::move(batch.consumption_tax_overrides);
    std::vector<int32_t> staged_business_tax =
        std::move(batch.business_tax_overrides);
    std::vector<int32_t> staged_import_tax =
        std::move(batch.import_tax_overrides);
    std::vector<int32_t> staged_export_tax =
        std::move(batch.export_tax_overrides);
    std::vector<int32_t> staged_income_tax_modes =
        std::move(batch.income_tax_mode_overrides);
    std::vector<int32_t> staged_consumption_tax_modes =
        std::move(batch.consumption_tax_mode_overrides);
    std::vector<int32_t> staged_business_tax_modes =
        std::move(batch.business_tax_mode_overrides);
    std::vector<int32_t> staged_import_tax_modes =
        std::move(batch.import_tax_mode_overrides);
    std::vector<int32_t> staged_export_tax_modes =
        std::move(batch.export_tax_mode_overrides);
    auto staged_cell_tax_updates = std::move(batch.cell_tax_updates);
    auto staged_treasury_consumed = std::move(batch.treasury_consumed);
    const bool stage_technologies = batch.stage_technologies;
    const bool stage_goods = batch.stage_goods;
    const bool stage_research = batch.stage_research;
    const bool stage_signals = batch.stage_signals;
    const bool stage_tax = batch.stage_tax;
    const bool stage_cell_tax = batch.stage_cell_tax;
    const int64_t observation_batch_input = batch.observation_batch_input;
    const int64_t observation_batch_added = batch.observation_batch_added;
    std::vector<std::pair<int32_t, int32_t>> signal_refreshes;
    if (stage_signals) {
        signal_refreshes.reserve(batch.commands.size());
        for (const Command &command : batch.commands) {
            if (command.opcode != COMMAND_DISCOVER_COUNTRY_SIGNAL) continue;
            int32_t signal_slot = -1;
            if (!validate_handle(command.target_handle, signal_slot)) continue;
            signal_refreshes.emplace_back(signal_slot, command.aux);
        }
        std::sort(signal_refreshes.begin(), signal_refreshes.end());
        signal_refreshes.erase(std::unique(signal_refreshes.begin(), signal_refreshes.end()),
                               signal_refreshes.end());
    }
    std::vector<Command> committed_typed_commands;
    for (const Command &command : batch.commands) {
        if (command.request_id != 0) {
            Command receipt_command;
            receipt_command.request_id = command.request_id;
            receipt_command.producer_id = command.producer_id;
            receipt_command.sequence = command.sequence;
            receipt_command.effective_day = command.effective_day;
            committed_typed_commands.push_back(std::move(receipt_command));
        }
        if (command.effect_request_id == 0) continue;
        CountryEffectCommandResult &result = _effect_command_results[command.effect_request_id];
        result.complete = 1; result.ok = 1; result.reason.clear();
    }
    _command_batch = {};

    const Clock::time_point apply_start = Clock::now();
    _countries = std::move(staged_countries);
    if (stage_technologies) _country_technologies = std::move(staged_technologies);
    if (stage_goods) _country_goods = std::move(staged_goods);
    if (!staged_treasury_consumed.empty()) {
        _country_treasury_goods_consumed_total.resize(_countries.active.size(), 0);
        for (const auto &entry : staged_treasury_consumed) {
            if (entry.first < 0 || static_cast<size_t>(entry.first) >=
                    _country_treasury_goods_consumed_total.size()) continue;
            int64_t &total = _country_treasury_goods_consumed_total[
                static_cast<size_t>(entry.first)];
            total = entry.second > std::numeric_limits<int64_t>::max() - total
                ? std::numeric_limits<int64_t>::max() : total + entry.second;
        }
        _state_hash_cache_valid = false;
    }
    if (stage_research) {
        _country_discovered = std::move(staged_discovered);
        _country_pending_technologies = std::move(staged_pending);
        _pending_activation_index_dirty = true;
        _country_research_progress = std::move(staged_progress);
        _country_research_queues = std::move(staged_research_queues);
        _country_research_queue_lengths = std::move(staged_research_queue_lengths);
        _country_research_weights_bp = std::move(staged_research_weights);
        _country_research_auto_purchase = std::move(staged_auto_purchase);
        _country_research_deferred_points = std::move(staged_deferred_points);
        const size_t country_count = _countries.active.size();
        _country_research_purchased_total.resize(country_count, 0);
        _country_research_consumed_total.resize(country_count, 0);
        _country_treasury_goods_consumed_total.resize(country_count, 0);
        _country_research_progress_total.resize(country_count, 0);
        _country_research_completed_total.resize(country_count, 0);
        _research_modifier_cache.resize(country_count);
        rebuild_research_active_index();
    }
    if (stage_signals) {
        _country_research_signals = std::move(staged_signals);
        _country_research_signal_cells = std::move(staged_signal_cells);
        _country_research_signal_evidence = std::move(staged_signal_evidence);
        for (const auto &entry : signal_refreshes)
            refresh_discovery_for_signal(entry.first, entry.second);
    }
    if (stage_tax) {
        _country_tax_defaults = std::move(staged_tax_defaults);
        _country_tax_default_modes = std::move(staged_tax_default_modes);
        _country_income_tax_overrides = std::move(staged_income_tax);
        _country_consumption_tax_overrides =
            std::move(staged_consumption_tax);
        _country_business_tax_overrides = std::move(staged_business_tax);
        _country_import_tax_overrides = std::move(staged_import_tax);
        _country_export_tax_overrides = std::move(staged_export_tax);
        _country_income_tax_mode_overrides =
            std::move(staged_income_tax_modes);
        _country_consumption_tax_mode_overrides =
            std::move(staged_consumption_tax_modes);
        _country_business_tax_mode_overrides =
            std::move(staged_business_tax_modes);
        _country_import_tax_mode_overrides =
            std::move(staged_import_tax_modes);
        _country_export_tax_mode_overrides =
            std::move(staged_export_tax_modes);
        ++_tax_policy_version;
    }
    if (stage_cell_tax && !staged_cell_tax_updates.empty()) {
        for (auto &entry : staged_cell_tax_updates) {
            const int32_t cell = entry.first;
            const uint32_t old_id =
                _cell_tax_policy_ids[static_cast<size_t>(cell)];
            if (cell_tax_policy(old_id) == entry.second) continue;
            const uint32_t new_id = intern_cell_tax_policy(entry.second);
            _cell_tax_policy_ids[static_cast<size_t>(cell)] = new_id;
            release_cell_tax_policy(old_id);
        }
        ++_tax_policy_version;
    }
    for (size_t i = 0; i < cell_delta_order.size(); ++i) {
        int32_t owner = NEUTRAL_SLOT;
        if (direct_unique_territory || cell_delta.get(cell_delta_order[i], owner)) {
            if (direct_unique_territory) owner = direct_cell_owners[i];
            _cell_country_slot[static_cast<size_t>(cell_delta_order[i])] = owner;
        }
    }
    const double apply_ms = elapsed_ms(apply_start);
    const Clock::time_point publish_start = Clock::now();
    if (!cell_delta_order.empty()) rebuild_cell_csr();
    ++_generation;
    for (const Command &command : committed_typed_commands)
        push_typed_receipt(command, CountryCommandReceiptCode::COMMITTED);
    if (!cell_delta_order.empty()) ++_territory_generation;
    _last_committed_day = day;
    for (Event &event : staged_events) push_event(std::move(event));
    CountryPeerContext peer_context;
    std::string peer_error;
    if (!capture_peer_context(day, _reference_continuation_index,
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
        day, &peer_context, &peer_context);
    if (!_peer_protocol_fault_reason.empty()) {
        result.status = CountryCoreStepStatus::FAULTED;
        result.ok = false;
        result.done = true;
        result.stage = "peer_retry";
        result.reason = _peer_protocol_fault_reason;
        close_boundary_seal();
        return false;
    }
    if (report_peer_rejection(day, result)) return false;
    const double aggregate_ms = elapsed_ms(publish_start);
    const bool day_barrier = should_run(day) ||
        ack_chain_due(day, &peer_context);
    result.status = CountryCoreStepStatus::BOUNDARY_COMMITTED;
    result.semantic_commit = true;
    result.day_barrier = day_barrier;
    result.stage = "aggregate_publish";
    result.preflight_ms = preflight_ms;
    result.apply_ms = apply_ms;
    result.publish_ms = aggregate_ms;
    result.elapsed_ms = preflight_ms + apply_ms + aggregate_ms;
    result.cursor_start = 0;
    result.cursor_end = static_cast<int64_t>(cursor_limit);
    result.cursor_total = static_cast<int64_t>(cursor_limit);
    result.progress_ratio = 1.0;
    result.changed_cells = static_cast<int32_t>(cell_delta_order.size());
    result.changed_countries = changed_country_count + research_changed;
    result.published_to_slot =
        _mode == MODE_ACTIVE && !cell_delta_order.empty();
    result.observation_batch_input = observation_batch_input;
    result.observation_batch_added = observation_batch_added;
    if (!cell_delta_order.empty()) {
        if (!std::is_sorted(cell_delta_order.begin(), cell_delta_order.end()))
            std::sort(cell_delta_order.begin(), cell_delta_order.end());
        result.changed_cell_indices.resize(cell_delta_order.size());
        result.changed_cell_owners.resize(cell_delta_order.size());
        for (size_t i = 0; i < cell_delta_order.size(); ++i) {
            result.changed_cell_indices[i] = cell_delta_order[i];
            int32_t owner = direct_unique_territory ? direct_cell_owners[i] : NEUTRAL_SLOT;
            if (!direct_unique_territory) cell_delta.get(cell_delta_order[i], owner);
            result.changed_cell_owners[i] = owner;
        }
    }
    record_reference_frame("aggregate_publish", day, true, day_barrier,
                           reference_batch_hash, reference_batch_count);
    close_boundary_seal();
    return true;

}

} // namespace pk

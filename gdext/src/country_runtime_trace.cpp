#include "country_runtime.h"
#include "country_runtime_internal.h"

#include <algorithm>
#include <cstring>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

NativeCountryRuntime::ReferenceHashes
NativeCountryRuntime::compute_reference_hashes() const {
    ReferenceHashes out;
    auto hash_count = [](uint64_t &hash, size_t count) {
        const uint64_t value = static_cast<uint64_t>(count);
        hash_bytes(hash, &value, sizeof(value));
    };
    auto hash_vector = [&](uint64_t &hash, const auto &values) {
        hash_count(hash, values.size());
        if (!values.empty())
            hash_bytes(hash, values.data(), values.size() * sizeof(values[0]));
    };
    auto hash_strings = [&](uint64_t &hash,
                            const std::vector<std::string> &values) {
        hash_count(hash, values.size());
        for (const std::string &value : values) hash_string(hash, value);
    };

    out.identity = FNV_OFFSET;
    hash_vector(out.identity, _countries.active);
    hash_vector(out.identity, _countries.generation);
    hash_strings(out.identity, _countries.stable_id);
    hash_strings(out.identity, _countries.display_name);
    hash_vector(out.identity, _countries.state_version);
    hash_bytes(out.identity, &_starting_country_slot,
               sizeof(_starting_country_slot));

    out.territory = FNV_OFFSET;
    hash_vector(out.territory, _countries.territory_count);
    hash_vector(out.territory, _cell_country_slot);
    hash_vector(out.territory, _country_cell_offsets);
    hash_vector(out.territory, _country_cells);

    out.treasury = FNV_OFFSET;
    hash_vector(out.treasury, _countries.cash);
    hash_vector(out.treasury, _country_goods);

    out.technology = FNV_OFFSET;
    hash_vector(out.technology, _country_technologies);
    hash_vector(out.technology, _country_discovered);
    hash_vector(out.technology, _country_pending_technologies);
    hash_vector(out.technology, _current_visual_era);
    hash_bytes(out.technology, &_era_reward_reference.plan_id,
               sizeof(_era_reward_reference.plan_id));
    hash_bytes(out.technology, &_era_reward_reference.offer_generation,
               sizeof(_era_reward_reference.offer_generation));
    hash_bytes(out.technology, &_era_reward_reference.milestone_technology,
               sizeof(_era_reward_reference.milestone_technology));
    hash_bytes(out.technology, &_era_reward_reference.status,
               sizeof(_era_reward_reference.status));

    out.research = FNV_OFFSET;
    hash_count(out.research, _country_research_progress.size());
    for (const auto &entries : _country_research_progress) {
        hash_count(out.research, entries.size());
        for (const auto &entry : entries) {
            hash_bytes(out.research, &entry.first, sizeof(entry.first));
            hash_bytes(out.research, &entry.second, sizeof(entry.second));
        }
    }
    hash_vector(out.research, _country_research_queues);
    hash_vector(out.research, _country_research_queue_lengths);
    hash_vector(out.research, _country_research_weights_bp);
    hash_vector(out.research, _country_research_auto_purchase);
    hash_vector(out.research, _country_research_daily_budgets);
    hash_vector(out.research, _country_research_deferred_points);
    hash_vector(out.research, _country_research_purchased_total);
    hash_vector(out.research, _country_research_consumed_total);
    hash_vector(out.research, _country_research_progress_total);
    hash_vector(out.research, _country_research_completed_total);
    hash_bytes(out.research, &_last_research_day,
               sizeof(_last_research_day));

    out.signals = FNV_OFFSET;
    hash_vector(out.signals, _country_research_signals);
    hash_count(out.signals, _country_research_signal_cells.size());
    for (const auto &cells : _country_research_signal_cells)
        hash_vector(out.signals, cells);
    hash_count(out.signals, _country_research_signal_evidence.size());
    for (const auto &entries : _country_research_signal_evidence) {
        hash_count(out.signals, entries.size());
        for (const SignalEvidence &entry : entries) {
            hash_bytes(out.signals, &entry.signal, sizeof(entry.signal));
            hash_bytes(out.signals, &entry.count, sizeof(entry.count));
            hash_bytes(out.signals, &entry.first_day, sizeof(entry.first_day));
            hash_bytes(out.signals, &entry.last_day, sizeof(entry.last_day));
            hash_bytes(out.signals, &entry.first_cell, sizeof(entry.first_cell));
        }
    }

    out.tax = FNV_OFFSET;
    hash_vector(out.tax, _country_tax_defaults);
    hash_vector(out.tax, _country_tax_default_modes);
    hash_vector(out.tax, _country_income_tax_overrides);
    hash_vector(out.tax, _country_consumption_tax_overrides);
    hash_vector(out.tax, _country_business_tax_overrides);
    hash_vector(out.tax, _country_import_tax_overrides);
    hash_vector(out.tax, _country_export_tax_overrides);
    hash_vector(out.tax, _country_income_tax_mode_overrides);
    hash_vector(out.tax, _country_consumption_tax_mode_overrides);
    hash_vector(out.tax, _country_business_tax_mode_overrides);
    hash_vector(out.tax, _country_import_tax_mode_overrides);
    hash_vector(out.tax, _country_export_tax_mode_overrides);
    hash_count(out.tax, _cell_tax_policy_ids.size());
    for (uint32_t policy_id : _cell_tax_policy_ids) {
        const CellTaxPolicy &policy = cell_tax_policy(policy_id);
        hash_vector(out.tax, policy.defaults);
        hash_vector(out.tax, policy.default_modes);
        hash_count(out.tax, policy.overrides.size());
        for (const CellTaxOverride &entry : policy.overrides) {
            hash_bytes(out.tax, &entry.kind, sizeof(entry.kind));
            hash_bytes(out.tax, &entry.item, sizeof(entry.item));
            hash_bytes(out.tax, &entry.rate, sizeof(entry.rate));
            hash_bytes(out.tax, &entry.mode, sizeof(entry.mode));
        }
    }

    out.effect = FNV_OFFSET;
    std::vector<std::pair<uint64_t, int64_t>> idempotency(
        _effect_command_idempotency.begin(), _effect_command_idempotency.end());
    std::sort(idempotency.begin(), idempotency.end());
    hash_count(out.effect, idempotency.size());
    for (const auto &entry : idempotency) {
        hash_bytes(out.effect, &entry.first, sizeof(entry.first));
        hash_bytes(out.effect, &entry.second, sizeof(entry.second));
    }
    std::vector<int64_t> result_ids;
    result_ids.reserve(_effect_command_results.size());
    for (const auto &entry : _effect_command_results)
        result_ids.push_back(entry.first);
    std::sort(result_ids.begin(), result_ids.end());
    hash_count(out.effect, result_ids.size());
    for (int64_t id : result_ids) {
        const EffectCommandResult &result = _effect_command_results.at(id);
        hash_bytes(out.effect, &id, sizeof(id));
        hash_bytes(out.effect, &result.complete, sizeof(result.complete));
        hash_bytes(out.effect, &result.ok, sizeof(result.ok));
        hash_string(out.effect, result.reason);
    }
    hash_bytes(out.effect, &_next_effect_request_id,
               sizeof(_next_effect_request_id));
    return out;
}

uint64_t NativeCountryRuntime::reference_command_hash(
        const std::vector<Command> &commands) const {
    uint64_t hash = FNV_OFFSET;
    const uint64_t count = static_cast<uint64_t>(commands.size());
    hash_bytes(hash, &count, sizeof(count));
    for (const Command &command : commands) {
        hash_bytes(hash, &command.request_id, sizeof(command.request_id));
        hash_bytes(hash, &command.producer_id, sizeof(command.producer_id));
        hash_bytes(hash, &command.observed_generation,
                   sizeof(command.observed_generation));
        hash_bytes(hash, &command.opcode, sizeof(command.opcode));
        hash_bytes(hash, &command.effective_day, sizeof(command.effective_day));
        hash_bytes(hash, &command.sequence, sizeof(command.sequence));
        hash_bytes(hash, &command.target_handle, sizeof(command.target_handle));
        hash_bytes(hash, &command.cell, sizeof(command.cell));
        hash_bytes(hash, &command.aux, sizeof(command.aux));
        hash_bytes(hash, &command.domain, sizeof(command.domain));
        hash_bytes(hash, &command.position, sizeof(command.position));
        hash_bytes(hash, command.weights_bp, sizeof(command.weights_bp));
        hash_bytes(hash, &command.tax_kind, sizeof(command.tax_kind));
        hash_bytes(hash, &command.tax_item, sizeof(command.tax_item));
        hash_bytes(hash, &command.tax_rate_basis_points,
                   sizeof(command.tax_rate_basis_points));
        hash_bytes(hash, &command.tax_assessment_mode,
                   sizeof(command.tax_assessment_mode));
        hash_bytes(hash, &command.value, sizeof(command.value));
        hash_string(hash, command.stable_id);
        hash_string(hash, command.display_name);
        hash_bytes(hash, &command.submit_order, sizeof(command.submit_order));
        hash_bytes(hash, &command.effect_request_id,
                   sizeof(command.effect_request_id));
        hash_bytes(hash, &command.effect_idempotency_key,
                   sizeof(command.effect_idempotency_key));
    }
    return hash;
}

void NativeCountryRuntime::begin_reference_boundary(int64_t day) {
    if (!_reference_trace_enabled) return;
    if (_boundary_seal_active &&
        _boundary_seal.session_epoch == _session_epoch) {
        _reference_boundary_id = _boundary_seal.boundary_id;
    } else {
        ++_reference_boundary_id;
    }
    _reference_boundary_day = day;
    _reference_continuation_index = 0;
    _reference_boundary_first_event_id =
        static_cast<int64_t>(_next_event_id);
}

void NativeCountryRuntime::record_reference_frame(
        const char *stage, int64_t day, bool semantic_commit,
        bool day_barrier, uint64_t command_hash, uint64_t command_count,
        int64_t first_event_id) {
    if (!_reference_trace_enabled) return;
    ReferenceFrame frame;
    frame.frame_id = _next_reference_frame_id++;
    frame.boundary_id = _reference_boundary_id;
    frame.continuation_index = _reference_continuation_index++;
    frame.day = day;
    frame.stage = stage != nullptr ? stage : "";
    frame.semantic_commit = semantic_commit;
    frame.day_barrier = day_barrier;
    frame.catalog_hash = catalog_hash();
    frame.technology_catalog_hash = _technology_catalog_identity_hash;
    frame.command_watermark = _boundary_seal_active
        ? _boundary_seal.last_admitted_submit_order : _submit_order;
    frame.command_hash = command_hash;
    frame.command_count = command_count;
    frame.business_state_hash = compute_state_hash();
    frame.hashes = compute_reference_hashes();
    frame.generation = _generation;
    frame.territory_generation = _territory_generation;
    frame.research_generation = _research_generation;
    frame.tax_generation = _tax_policy_version;
    frame.visual_generation = _visual_era_generation;
    frame.first_event_id = first_event_id != 0
        ? first_event_id : _reference_boundary_first_event_id;
    frame.last_event_id = _next_event_id > 0
        ? static_cast<int64_t>(_next_event_id - 1) : 0;
    for (const auto &entry : _effect_command_results) {
        ++frame.effect_intent_count;
        if (entry.second.complete != 0) ++frame.effect_ack_count;
    }
    _reference_frames.push_back(std::move(frame));
    while (_reference_frames.size() > _reference_trace_capacity)
        _reference_frames.pop_front();
}

void NativeCountryRuntime::record_direct_reference_frame(const char *stage) {
    if (!_reference_trace_enabled) return;
    begin_reference_boundary(_last_committed_day);
    record_reference_frame(stage, _last_committed_day, true, false);
}

Dictionary NativeCountryRuntime::configure_reference_trace(bool enabled,
                                                             int32_t max_frames) {
    Dictionary out;
    if (max_frames < 1 || max_frames > 65536) {
        out["ok"] = false;
        out["reason"] = "country_reference_capacity_invalid";
        return out;
    }
    _reference_trace_enabled = enabled;
    _reference_trace_capacity = static_cast<size_t>(max_frames);
    _reference_frames.clear();
    _next_reference_frame_id = 1;
    _reference_boundary_id = 0;
    _reference_continuation_index = 0;
    _reference_boundary_day = -1;
    _reference_boundary_first_event_id = 0;
    out["ok"] = true;
    out["enabled"] = enabled;
    out["capacity"] = max_frames;
    return out;
}

Dictionary NativeCountryRuntime::poll_reference_trace(int64_t after_frame_id,
                                                        int32_t limit) const {
    Dictionary out;
    Array frames;
    const int32_t bounded_limit = std::clamp(limit, 1, 4096);
    for (const ReferenceFrame &frame : _reference_frames) {
        if (static_cast<int64_t>(frame.frame_id) <= after_frame_id) continue;
        Dictionary item;
        item["frame_id"] = static_cast<int64_t>(frame.frame_id);
        item["boundary_id"] = static_cast<int64_t>(frame.boundary_id);
        item["continuation_index"] = static_cast<int64_t>(frame.continuation_index);
        item["day"] = frame.day;
        item["stage"] = String(frame.stage.c_str());
        item["semantic_commit"] = frame.semantic_commit;
        item["day_barrier"] = frame.day_barrier;
        item["catalog_hash"] = static_cast<int64_t>(frame.catalog_hash);
        item["technology_catalog_hash"] =
            static_cast<int64_t>(frame.technology_catalog_hash);
        item["command_watermark"] =
            static_cast<int64_t>(frame.command_watermark);
        item["command_hash"] = static_cast<int64_t>(frame.command_hash);
        item["command_count"] = static_cast<int64_t>(frame.command_count);
        item["business_state_hash"] =
            static_cast<int64_t>(frame.business_state_hash);
        item["identity_hash"] = static_cast<int64_t>(frame.hashes.identity);
        item["territory_hash"] = static_cast<int64_t>(frame.hashes.territory);
        item["treasury_hash"] = static_cast<int64_t>(frame.hashes.treasury);
        item["technology_hash"] = static_cast<int64_t>(frame.hashes.technology);
        item["research_hash"] = static_cast<int64_t>(frame.hashes.research);
        item["signal_hash"] = static_cast<int64_t>(frame.hashes.signals);
        item["tax_hash"] = static_cast<int64_t>(frame.hashes.tax);
        item["effect_hash"] = static_cast<int64_t>(frame.hashes.effect);
        item["generation"] = static_cast<int64_t>(frame.generation);
        item["territory_generation"] =
            static_cast<int64_t>(frame.territory_generation);
        item["research_generation"] =
            static_cast<int64_t>(frame.research_generation);
        item["tax_generation"] = static_cast<int64_t>(frame.tax_generation);
        item["visual_generation"] =
            static_cast<int64_t>(frame.visual_generation);
        item["first_event_id"] = frame.first_event_id;
        item["last_event_id"] = frame.last_event_id;
        item["effect_intent_count"] =
            static_cast<int64_t>(frame.effect_intent_count);
        item["effect_ack_count"] =
            static_cast<int64_t>(frame.effect_ack_count);
        frames.push_back(item);
        if (frames.size() >= bounded_limit) break;
    }
    out["ok"] = true;
    out["enabled"] = _reference_trace_enabled;
    out["frames"] = frames;
    out["retained"] = static_cast<int64_t>(_reference_frames.size());
    out["next_frame_id"] = static_cast<int64_t>(_next_reference_frame_id);
    return out;
}

Dictionary NativeCountryRuntime::capture_reference_checkpoint() const {
    Dictionary out;
    std::vector<uint8_t> bytes;
    std::string error;
    if (!encode_save(bytes, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    PackedByteArray packed;
    packed.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty())
        std::memcpy(packed.ptrw(), bytes.data(), bytes.size());
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["generation"] = static_cast<int64_t>(_generation);
    out["day"] = _last_committed_day;
    out["business_state_hash"] = static_cast<int64_t>(compute_state_hash());
    out["bytes"] = packed;
    return out;
}


} // namespace pk

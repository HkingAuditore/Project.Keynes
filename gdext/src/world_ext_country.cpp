#include "world_ext.h"
#include "country_runtime.h"
#include "effect_runtime.h"
#include "modifier_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"

#include <chrono>
#include <cstring>

namespace pk {

using namespace godot;

namespace {
NativeCountryRuntime *country_runtime_from(void *opaque) {
    return static_cast<NativeCountryRuntime *>(opaque);
}

const NativeCountryRuntime *country_runtime_from(const void *opaque) {
    return static_cast<const NativeCountryRuntime *>(opaque);
}

Dictionary country_unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "country_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_country(const Dictionary &catalog,
                                         const Dictionary &profile,
                                         int cell_count, int64_t seed) {
    if (_country_runtime == nullptr) _country_runtime = new NativeCountryRuntime();
    if (_modifier_runtime != nullptr)
        static_cast<ModifierRuntime *>(_modifier_runtime)->attach_country_runtime(
            country_runtime_from(_country_runtime));
    if (_effect_runtime != nullptr) {
        static_cast<EffectRuntime *>(_effect_runtime)->attach_country_runtime(
            country_runtime_from(_country_runtime));
        country_runtime_from(_country_runtime)->attach_effect_runtime(
            static_cast<EffectRuntime *>(_effect_runtime));
    }
    country_runtime_from(_country_runtime)->attach_modifier_runtime(
        static_cast<ModifierRuntime *>(_modifier_runtime));
    Dictionary out = country_runtime_from(_country_runtime)->configure(catalog, profile, cell_count, seed);
    if (_economy_runtime != nullptr) {
        static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_country_runtime(
            country_runtime_from(_country_runtime));
        country_runtime_from(_country_runtime)->attach_economy_runtime(
            static_cast<NativeEconomyRuntime *>(_economy_runtime));
    }
    return out;
}

Dictionary DCWorldExt::bootstrap_country(const Dictionary &packet,
                                         const PackedByteArray &is_water) {
    if (_country_runtime == nullptr) return country_unavailable();
    Dictionary out = country_runtime_from(_country_runtime)->bootstrap(packet, is_water);
    if (static_cast<bool>(out.get("ok", false)) &&
        String(out.get("runtime_mode", "ACTIVE")) == "ACTIVE") {
        NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
        const auto publish_start = std::chrono::steady_clock::now();
        const int slot = component_id(StringName("cell_country_slot"));
        if (slot >= 0) {
            write_i32_range(slot, 0, runtime->cell_country_snapshot());
            _flush_slot_to_map(slot);
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(true, publish_ms);
            out["published_to_slot"] = true;
            out["slot_publish_ms"] = publish_ms;
        } else {
            runtime->mark_slot_publication(false, 0.0, "country_slot_unavailable");
            out["published_to_slot"] = false;
            out["publish_reason"] = "country_slot_unavailable";
        }
    }
    return out;
}

Dictionary DCWorldExt::submit_country_commands(const Dictionary &packed_batch) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->submit_commands(packed_batch);
}

namespace {

int64_t country_peer_i64(const Dictionary &value, const char *key,
                         int64_t fallback = 0) {
    const StringName name(key);
    return value.has(name) ? static_cast<int64_t>(value[name]) : fallback;
}

uint32_t country_peer_u32(const Dictionary &value, const char *key,
                          uint32_t fallback = 0) {
    const int64_t parsed = country_peer_i64(value, key,
                                             static_cast<int64_t>(fallback));
    return parsed < 0 ? fallback : static_cast<uint32_t>(parsed);
}

uint64_t country_peer_u64(const Dictionary &value, const char *key,
                          uint64_t fallback = 0) {
    const int64_t parsed = country_peer_i64(value, key,
                                             static_cast<int64_t>(fallback));
    return parsed < 0 ? fallback : static_cast<uint64_t>(parsed);
}

int32_t country_peer_i32(const Dictionary &value, const char *key,
                         int32_t fallback = -1) {
    return static_cast<int32_t>(country_peer_i64(value, key, fallback));
}

String country_peer_string(const Dictionary &value, const char *key) {
    const StringName name(key);
    return value.has(name) ? String(value[name]) : String();
}

Dictionary country_peer_status_dictionary(
        const CountryPeerProtocolStatus &status) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(status.protocol_version);
    out["async_mode"] = status.async_mode != 0;
    out["pending_intents"] = static_cast<int64_t>(status.pending_intents);
    out["queued_intents"] = static_cast<int64_t>(status.queued_intents);
    out["rejected_intents"] = static_cast<int64_t>(status.rejected_intents);
    out["has_unreported_rejection"] = status.has_unreported_rejection != 0;
    out["retry_day"] = status.retry_day;
    out["rejected_request_id"] = static_cast<int64_t>(status.rejected_request_id);
    out["rejected_opcode"] = static_cast<int64_t>(status.rejected_opcode);
    out["rejection_reason"] = String(status.rejection_reason.data());
    out["has_save_barrier"] = status.has_save_barrier();
    return out;
}

Dictionary country_peer_intent_dictionary(const CountryPeerIntent &intent) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(intent.protocol_version);
    out["opcode"] = static_cast<int64_t>(intent.opcode);
    out["request_id"] = static_cast<int64_t>(intent.request_id);
    out["session_epoch"] = static_cast<int64_t>(intent.session_epoch);
    out["country_generation"] = static_cast<int64_t>(intent.country_generation);
    out["peer_generation"] = static_cast<int64_t>(intent.peer_generation);
    out["day"] = intent.day;
    out["continuation_index"] = static_cast<int64_t>(intent.continuation_index);
    out["country_slot"] = intent.country_slot;
    out["technology"] = intent.technology;
    out["target_handle"] = static_cast<int64_t>(intent.target_handle);
    out["effect_instance_id"] = static_cast<int64_t>(intent.effect_instance_id);
    out["effect_generation"] = static_cast<int64_t>(intent.effect_generation);
    out["idempotency_key"] = static_cast<int64_t>(intent.idempotency_key);
    return out;
}

} // namespace

Dictionary DCWorldExt::set_country_peer_async_mode(bool enabled) {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    runtime->set_peer_async_mode(enabled);
    Dictionary out = country_peer_status_dictionary(
        runtime->peer_protocol_status());
    out["ok"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::get_country_peer_protocol_status() const {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_peer_status_dictionary(
        country_runtime_from(_country_runtime)->peer_protocol_status());
}

Dictionary DCWorldExt::poll_country_peer_intent() {
    if (_country_runtime == nullptr) return country_unavailable();
    CountryPeerIntent intent;
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    if (!runtime->poll_peer_intent(intent)) {
        Dictionary out = country_peer_status_dictionary(
            runtime->peer_protocol_status());
        out["ok"] = true;
        out["available"] = false;
        out["code"] = "country_peer_intent_empty";
        return out;
    }
    Dictionary out = country_peer_intent_dictionary(intent);
    out["ok"] = true;
    out["available"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::submit_country_peer_result(const Dictionary &input) {
    if (_country_runtime == nullptr) return country_unavailable();
    CountryPeerResult result;
    result.protocol_version = country_peer_u32(input, "protocol_version",
                                                COUNTRY_PEER_PROTOCOL_VERSION);
    result.code = static_cast<CountryPeerResultCode>(
        country_peer_u32(input, "code"));
    result.opcode = static_cast<CountryPeerIntentCode>(
        country_peer_u32(input, "opcode"));
    result.request_id = country_peer_u64(input, "request_id");
    result.session_epoch = country_peer_u64(input, "session_epoch");
    result.country_generation = country_peer_u64(input, "country_generation");
    result.committed_peer_generation = country_peer_u64(
        input, "committed_peer_generation");
    result.peer_generation = country_peer_u64(input, "peer_generation");
    result.day = country_peer_i64(input, "day", -1);
    result.continuation_index = country_peer_u32(input, "continuation_index");
    result.country_slot = country_peer_i32(input, "country_slot");
    result.technology = country_peer_i32(input, "technology");
    result.target_handle = country_peer_u64(input, "target_handle");
    result.technology_flags = static_cast<uint8_t>(country_peer_u32(
        input, "technology_flags"));
    const std::string reason = country_peer_string(input, "reason")
        .utf8().get_data();
    country_peer_copy_reason(result.reason, reason.c_str());

    std::string error;
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    if (!runtime->submit_peer_result(result, error)) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = error.empty() ? "country_peer_result_rejected" : error.c_str();
        return out;
    }
    Dictionary out = country_peer_status_dictionary(
        runtime->peer_protocol_status());
    out["ok"] = true;
    out["code"] = "ok";
    out["request_id"] = static_cast<int64_t>(result.request_id);
    return out;
}

Dictionary DCWorldExt::service_country_peer_adapter(int max_intents) {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    NativeCountryRuntime::PeerAdapterServiceReport report;
    std::string error;
    if (!runtime->service_peer_intents_main_thread(max_intents, report, error)) {
        Dictionary out = country_peer_status_dictionary(
            runtime->peer_protocol_status());
        out["ok"] = false;
        out["code"] = error.empty()
            ? "country_peer_adapter_service_failed" : error.c_str();
        return out;
    }
    Dictionary out = country_peer_status_dictionary(
        runtime->peer_protocol_status());
    out["ok"] = true;
    out["code"] = "ok";
    out["inspected"] = static_cast<int64_t>(report.inspected);
    out["completed"] = static_cast<int64_t>(report.completed);
    out["pending"] = static_cast<int64_t>(report.pending);
    out["rejected"] = static_cast<int64_t>(report.rejected);
    out["effect_intents"] = static_cast<int64_t>(report.effect_intents);
    out["modifier_intents"] = static_cast<int64_t>(report.modifier_intents);
    out["economy_intents"] = static_cast<int64_t>(report.economy_intents);
    out["last_request_id"] = static_cast<int64_t>(report.last_request_id);
    out["last_reason"] = String(report.last_reason.c_str());
    return out;
}

Dictionary DCWorldExt::begin_country_economy_treasury_spend(
        int64_t country_handle, const PackedInt32Array &good_ids,
        const PackedInt64Array &quantities, int64_t cash,
        int64_t origin_epoch, int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_treasury_spend(
        country_handle, good_ids, quantities, cash, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_fiscal_reserve(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_fiscal_reserve(
        country_handle, requested, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_fiscal_return(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_fiscal_return(
        country_handle, offered, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_fiscal_collect(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_fiscal_collect(
        country_handle, offered, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_cash_to_cohort(
        country_handle, requested, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_cash_from_cohort(
        country_handle, offered, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_good_to_market(
        int64_t country_handle, int good_id, int64_t requested,
        int64_t origin_epoch, int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_good_to_market(
        country_handle, good_id, requested, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_good_from_market(
        int64_t country_handle, int good_id, int64_t offered,
        int64_t origin_epoch, int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_good_from_market(
        country_handle, good_id, offered, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_research_purchase(
        int64_t country_handle, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_research_purchase(
        country_handle, quantity, total_cost, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::ack_country_economy_asset_peer_prepared(
        int64_t transaction_id, int64_t session_epoch,
        int64_t country_generation, int64_t peer_generation, bool accepted,
        const String &reason) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (transaction_id <= 0 || session_epoch <= 0 || country_generation <= 0 ||
        peer_generation <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->
        acknowledge_economy_asset_peer_prepared(
            static_cast<uint64_t>(transaction_id),
            static_cast<uint64_t>(session_epoch),
            static_cast<uint64_t>(country_generation),
            static_cast<uint64_t>(peer_generation), accepted, reason);
}

Dictionary DCWorldExt::commit_country_economy_treasury_spend(
        int64_t transaction_id) {
    if (_country_runtime == nullptr || transaction_id <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->
        commit_economy_treasury_spend(static_cast<uint64_t>(transaction_id));
}

Dictionary DCWorldExt::commit_country_economy_fiscal_reserve(
        int64_t transaction_id) {
    if (_country_runtime == nullptr || transaction_id <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->commit_economy_asset_transaction(
        static_cast<uint64_t>(transaction_id));
}

Dictionary DCWorldExt::commit_country_economy_asset_transaction(
        int64_t transaction_id) {
    if (_country_runtime == nullptr || transaction_id <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->commit_economy_asset_transaction(
        static_cast<uint64_t>(transaction_id));
}

Dictionary DCWorldExt::ack_country_economy_asset_peer_applied(
        int64_t transaction_id, int64_t session_epoch,
        int64_t country_generation, int64_t peer_generation, bool accepted,
        const String &reason) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (transaction_id <= 0 || session_epoch <= 0 || country_generation <= 0 ||
        peer_generation <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->
        acknowledge_economy_asset_peer_applied(
            static_cast<uint64_t>(transaction_id),
            static_cast<uint64_t>(session_epoch),
            static_cast<uint64_t>(country_generation),
            static_cast<uint64_t>(peer_generation), accepted, reason);
}

Dictionary DCWorldExt::get_country_economy_asset_transaction(
        int64_t transaction_id) const {
    if (_country_runtime == nullptr || transaction_id <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->
        economy_asset_transaction_snapshot(static_cast<uint64_t>(transaction_id));
}

Dictionary DCWorldExt::capture_country_runtime_snapshot() {
    Dictionary out;
    if (_country_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "country_runtime_unavailable";
        return out;
    }
    RuntimeCountryPodSnapshot snapshot;
    std::string error;
    if (!country_runtime_from(_country_runtime)->export_pod_snapshot(snapshot, error)) {
        out["ok"] = false;
        out["code"] = error.empty() ? "country_snapshot_capture_failed" : error.c_str();
        return out;
    }
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    if (!_runtime_host->publish_country_snapshot(snapshot)) {
        out["ok"] = false;
        out["code"] = "country_snapshot_validation_failed";
        return out;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["state_hash"] = static_cast<int64_t>(snapshot.state_hash);
    out["committed_day"] = snapshot.committed_day;
    out["country_count"] = static_cast<int>(snapshot.country_count);
    out["cell_count"] = static_cast<int>(snapshot.cell_count);
    out["technology_count"] = static_cast<int>(snapshot.technology_count);
    return out;
}

Dictionary DCWorldExt::capture_country_pod_catalog() {
    Dictionary out;
    if (_country_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "country_runtime_unavailable";
        return out;
    }
    RuntimeCountryPodCatalog catalog;
    std::string error;
    if (!country_runtime_from(_country_runtime)->export_pod_catalog(catalog, error)) {
        out["ok"] = false;
        out["code"] = error.empty() ? "country_catalog_capture_failed" : error.c_str();
        return out;
    }
    PackedInt64Array costs;
    costs.resize(static_cast<int64_t>(catalog.technology_costs.size()));
    for (int64_t i = 0; i < costs.size(); ++i) costs.set(i, catalog.technology_costs[static_cast<size_t>(i)]);
    PackedInt32Array domains, flags, prereq_offsets, prerequisites;
    domains.resize(static_cast<int64_t>(catalog.technology_domains.size()));
    flags.resize(static_cast<int64_t>(catalog.technology_flags.size()));
    prereq_offsets.resize(static_cast<int64_t>(catalog.prerequisite_offsets.size()));
    prerequisites.resize(static_cast<int64_t>(catalog.prerequisites.size()));
    for (int64_t i = 0; i < domains.size(); ++i) domains.set(i, catalog.technology_domains[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < flags.size(); ++i) flags.set(i, catalog.technology_flags[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < prereq_offsets.size(); ++i) prereq_offsets.set(i, catalog.prerequisite_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < prerequisites.size(); ++i) prerequisites.set(i, catalog.prerequisites[static_cast<size_t>(i)]);
    PackedInt32Array condition_offsets, condition_ops, condition_refs;
    PackedInt64Array condition_values;
    condition_offsets.resize(static_cast<int64_t>(catalog.research_condition_offsets.size()));
    condition_ops.resize(static_cast<int64_t>(catalog.research_condition_ops.size()));
    condition_refs.resize(static_cast<int64_t>(catalog.research_condition_refs.size()));
    condition_values.resize(static_cast<int64_t>(catalog.research_condition_values.size()));
    for (int64_t i = 0; i < condition_offsets.size(); ++i) condition_offsets.set(i, catalog.research_condition_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_ops.size(); ++i) condition_ops.set(i, catalog.research_condition_ops[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_refs.size(); ++i) condition_refs.set(i, catalog.research_condition_refs[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_values.size(); ++i) condition_values.set(i, catalog.research_condition_values[static_cast<size_t>(i)]);
    PackedInt32Array milestone_offsets, milestone_candidates, milestone_required, entry_milestones;
    milestone_offsets.resize(static_cast<int64_t>(catalog.milestone_offsets.size()));
    milestone_candidates.resize(static_cast<int64_t>(catalog.milestone_candidates.size()));
    milestone_required.resize(static_cast<int64_t>(catalog.milestone_required_counts.size()));
    entry_milestones.resize(static_cast<int64_t>(catalog.entry_milestone_indices.size()));
    for (int64_t i = 0; i < milestone_offsets.size(); ++i) milestone_offsets.set(i, catalog.milestone_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < milestone_candidates.size(); ++i) milestone_candidates.set(i, catalog.milestone_candidates[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < milestone_required.size(); ++i) milestone_required.set(i, catalog.milestone_required_counts[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < entry_milestones.size(); ++i) entry_milestones.set(i, catalog.entry_milestone_indices[static_cast<size_t>(i)]);
    out["ok"] = true;
    out["catalog_hash"] = static_cast<int64_t>(catalog.catalog_hash);
    out["technology_count"] = static_cast<int>(catalog.technology_count);
    out["technology_words"] = static_cast<int>(catalog.technology_words);
    out["technology_points_good_id"] = catalog.technology_points_good_id;
    out["research_conditions_complete"] = catalog.research_conditions_complete;
    out["technology_costs"] = costs;
    out["technology_domains"] = domains;
    out["technology_flags"] = flags;
    out["prerequisite_offsets"] = prereq_offsets;
    out["prerequisites"] = prerequisites;
    out["milestone_offsets"] = milestone_offsets;
    out["milestone_candidates"] = milestone_candidates;
    out["milestone_required_counts"] = milestone_required;
    out["entry_milestone_indices"] = entry_milestones;
    out["research_condition_offsets"] = condition_offsets;
    out["research_condition_ops"] = condition_ops;
    out["research_condition_refs"] = condition_refs;
    out["research_condition_values"] = condition_values;
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    std::string publish_error;
    if (!_runtime_host->publish_country_catalog(catalog, publish_error)) {
        out["ok"] = false;
        out["code"] = publish_error.empty()
            ? "country_catalog_publish_failed" : publish_error.c_str();
        return out;
    }
    if (_ideology_runtime != nullptr && _economy_runtime != nullptr)
        publish_ideology_worker_inputs();
    return out;
}

Dictionary DCWorldExt::get_country_worker_protocol_status() const {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const NativeSimulationHost::CountryWorkerProtocolStatus status =
        _runtime_host->country_worker_protocol_status();
    Dictionary out;
    out["ok"] = true;
    out["code"] = "ok";
    out["protocol_version"] = static_cast<int64_t>(status.protocol_version);
    out["configured"] = status.configured;
    out["plan_active"] = status.plan_active;
    out["waiting_for_peer"] = status.waiting_for_peer;
    out["pending_intents"] = static_cast<int64_t>(status.pending_intents);
    out["queued_intents"] = static_cast<int64_t>(status.queued_intents);
    out["result_count"] = static_cast<int64_t>(status.result_count);
    out["rejected_results"] = static_cast<int64_t>(status.rejected_results);
    out["session_epoch"] = static_cast<int64_t>(status.session_epoch);
    out["country_generation"] = static_cast<int64_t>(status.country_generation);
    out["day"] = status.day;
    out["continuation_index"] = static_cast<int64_t>(status.continuation_index);
    out["last_reason"] = String(status.last_reason);
    out["has_save_barrier"] = status.plan_active || status.pending_intents != 0 ||
        status.result_count != 0;
    return out;
}

Dictionary DCWorldExt::get_country_worker_read_view(
        int64_t after_generation) const {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? 0u : static_cast<uint64_t>(after_generation);
    const RuntimeCountryReadView view =
        _runtime_host->country_worker_read_view(cursor);
    out["ok"] = true;
    out["code"] = "ok";
    out["available"] = view.available;
    out["full_snapshot_required"] = view.full_snapshot_required;
    out["generation"] = static_cast<int64_t>(view.generation);
    out["patch_base_generation"] = static_cast<int64_t>(
        view.patch_base_generation);
    out["committed_day"] = view.committed_day;
    out["state_hash"] = static_cast<int64_t>(view.state_hash);
    out["dirty_families"] = static_cast<int64_t>(view.dirty_families);
    out["territory_watermark"] = static_cast<int64_t>(view.territory_watermark);
    out["research_watermark"] = static_cast<int64_t>(view.research_watermark);
    out["tax_watermark"] = static_cast<int64_t>(view.tax_watermark);
    out["visual_watermark"] = static_cast<int64_t>(view.visual_watermark);
    out["country_count"] = static_cast<int>(view.country_count);
    out["cell_count"] = static_cast<int>(view.cell_count);
    PackedInt32Array changed_cells;
    PackedInt32Array changed_owners;
    changed_cells.resize(static_cast<int64_t>(view.changed_cells.size()));
    changed_owners.resize(static_cast<int64_t>(view.changed_owners.size()));
    for (int64_t i = 0; i < changed_cells.size(); ++i) {
        changed_cells.set(i, view.changed_cells[static_cast<size_t>(i)]);
        changed_owners.set(i, view.changed_owners[static_cast<size_t>(i)]);
    }
    out["changed_cells"] = changed_cells;
    out["changed_owners"] = changed_owners;
    if (view.snapshot != nullptr && view.full_snapshot_required) {
        PackedInt32Array owners;
        owners.resize(static_cast<int64_t>(view.snapshot->cell_country_slot.size()));
        for (int64_t i = 0; i < owners.size(); ++i)
            owners.set(i, view.snapshot->cell_country_slot[static_cast<size_t>(i)]);
        out["full_cell_owners"] = owners;
    } else {
        out["full_cell_owners"] = PackedInt32Array();
    }
    return out;
}

Dictionary DCWorldExt::poll_country_worker_intent() {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    CountryPeerIntent intent;
    if (!_runtime_host->poll_country_worker_intent(intent)) {
        Dictionary out = get_country_worker_protocol_status();
        out["available"] = false;
        out["code"] = "country_worker_intent_empty";
        return out;
    }
    Dictionary out = country_peer_intent_dictionary(intent);
    out["ok"] = true;
    out["available"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::submit_country_worker_result(const Dictionary &input) {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    CountryPeerResult result;
    result.protocol_version = country_peer_u32(
        input, "protocol_version", COUNTRY_PEER_PROTOCOL_VERSION);
    result.code = static_cast<CountryPeerResultCode>(country_peer_u32(input, "code"));
    result.opcode = static_cast<CountryPeerIntentCode>(country_peer_u32(input, "opcode"));
    result.request_id = country_peer_u64(input, "request_id");
    result.session_epoch = country_peer_u64(input, "session_epoch");
    result.country_generation = country_peer_u64(input, "country_generation");
    result.committed_peer_generation = country_peer_u64(
        input, "committed_peer_generation");
    result.peer_generation = country_peer_u64(input, "peer_generation");
    result.day = country_peer_i64(input, "day", -1);
    result.continuation_index = country_peer_u32(input, "continuation_index");
    result.country_slot = country_peer_i32(input, "country_slot");
    result.technology = country_peer_i32(input, "technology");
    result.target_handle = country_peer_u64(input, "target_handle");
    result.technology_flags = static_cast<uint8_t>(country_peer_u32(
        input, "technology_flags"));
    const std::string reason = country_peer_string(input, "reason").utf8().get_data();
    country_peer_copy_reason(result.reason, reason.c_str());
    std::string error;
    if (!_runtime_host->submit_country_worker_result(result, error)) {
        Dictionary out = get_country_worker_protocol_status();
        out["ok"] = false;
        out["code"] = error.empty()
            ? "country_worker_result_rejected" : error.c_str();
        return out;
    }
    Dictionary out = get_country_worker_protocol_status();
    out["ok"] = true;
    out["code"] = "ok";
    out["request_id"] = static_cast<int64_t>(result.request_id);
    return out;
}

Dictionary DCWorldExt::service_country_worker_peer_adapter(
        int max_intents, bool shadow_replay) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (max_intents <= 0 || max_intents > 4096) {
        out["ok"] = false;
        out["code"] = "country_worker_adapter_limit_invalid";
        return out;
    }
    if (!shadow_replay) {
        // The real peer transaction coordinator is a later K2-B/K2-C gate.
        // Refuse instead of accidentally executing a synchronous peer write
        // against the worker's independent session identity.
        out["ok"] = false;
        out["code"] = "country_worker_real_peer_adapter_not_authoritative";
        return out;
    }

    int inspected = 0;
    int replayed = 0;
    int rejected = 0;
    String last_reason;
    while (inspected < max_intents) {
        CountryPeerIntent intent;
        if (!_runtime_host->poll_country_worker_intent(intent)) break;

        CountryPeerResult result;
        result.protocol_version = intent.protocol_version;
        result.opcode = intent.opcode;
        result.request_id = intent.request_id;
        result.session_epoch = intent.session_epoch;
        result.country_generation = intent.country_generation;
        result.peer_generation = intent.peer_generation;
        result.day = intent.day;
        result.continuation_index = intent.continuation_index;
        result.country_slot = intent.country_slot;
        result.technology = intent.technology;
        result.target_handle = intent.target_handle;

        // This is deliberately a replay result, not an Effect/Modifier call.
        // It preserves the Country continuation protocol while proving that
        // SHADOW transport itself has no peer side effects.
        switch (intent.opcode) {
        case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
            result.code = CountryPeerResultCode::READY;
            result.technology_flags = static_cast<uint8_t>(
                COUNTRY_PEER_EFFECT_EXISTS | COUNTRY_PEER_EFFECT_FIRE_ACKED);
            country_peer_copy_reason(result.reason, "shadow_peer_replay");
            break;
        case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
            result.code = CountryPeerResultCode::APPLIED;
            result.technology_flags = COUNTRY_PEER_MODIFIER_APPLIED;
            country_peer_copy_reason(result.reason, "shadow_peer_replay");
            break;
        case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
        case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
            result.code = CountryPeerResultCode::APPLIED;
            country_peer_copy_reason(result.reason, "shadow_peer_replay");
            break;
        default:
            result.code = CountryPeerResultCode::REJECTED;
            country_peer_copy_reason(result.reason,
                                     "country_worker_peer_opcode_invalid");
            ++rejected;
            break;
        }
        result.committed_peer_generation = intent.peer_generation;
        std::string error;
        if (!_runtime_host->submit_country_worker_result(result, error)) {
            out["ok"] = false;
            out["code"] = error.empty()
                ? "country_worker_peer_replay_submit_failed" : error.c_str();
            out["inspected"] = inspected;
            out["replayed"] = replayed;
            out["rejected"] = rejected;
            return out;
        }
        last_reason = String(result.reason.data());
        ++inspected;
        if (result.code != CountryPeerResultCode::REJECTED) ++replayed;
    }

    const NativeSimulationHost::CountryWorkerProtocolStatus status =
        _runtime_host->country_worker_protocol_status();
    out["ok"] = true;
    out["code"] = "ok";
    out["shadow_replay"] = true;
    out["inspected"] = inspected;
    out["replayed"] = replayed;
    out["rejected"] = rejected;
    out["last_reason"] = last_reason;
    out["pending_intents"] = static_cast<int64_t>(status.pending_intents);
    out["queued_intents"] = static_cast<int64_t>(status.queued_intents);
    out["plan_active"] = status.plan_active;
    out["waiting_for_peer"] = status.waiting_for_peer;
    return out;
}

Dictionary DCWorldExt::restore_country_runtime_checkpoint(
        const PackedByteArray &canonical_pkcn) {
    Dictionary out;
    if (_runtime_host == nullptr || _country_runtime == nullptr) {
        out["ok"] = false;
        out["available"] = false;
        out["code"] = "country_checkpoint_not_pending";
        return out;
    }
    CountryCoreCheckpoint checkpoint;
    std::string error;
    if (!_runtime_host->pending_country_checkpoint(checkpoint, error)) {
        out["ok"] = false;
        out["available"] = false;
        out["code"] = String(error.c_str());
        return out;
    }
    out["available"] = true;
    if (canonical_pkcn.size() !=
            static_cast<int64_t>(checkpoint.canonical_pkcn.size()) ||
        (!checkpoint.canonical_pkcn.empty() &&
         std::memcmp(canonical_pkcn.ptr(), checkpoint.canonical_pkcn.data(),
                     checkpoint.canonical_pkcn.size()) != 0)) {
        out["ok"] = false;
        out["code"] = "country_checkpoint_pkcn_mismatch";
        return out;
    }
    if (!country_runtime_from(_country_runtime)->restore_core_checkpoint(
            checkpoint, error)) {
        out["ok"] = false;
        out["code"] = String(error.empty()
            ? "country_checkpoint_restore_failed" : error.c_str());
        return out;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["generation"] = static_cast<int64_t>(checkpoint.generation);
    out["committed_day"] = checkpoint.committed_day;
    out["business_state_hash"] =
        static_cast<int64_t>(checkpoint.business_state_hash);
    return out;
}

bool DCWorldExt::runtime_country_core_protocol_self_test() {
    if (_country_runtime == nullptr) return false;
    std::string error;
    return country_runtime_from(_country_runtime)->protocol_contract_self_test(error);
}

bool DCWorldExt::runtime_country_peer_protocol_self_test() {
    if (_country_runtime == nullptr) return false;
    std::string error;
    return country_runtime_from(_country_runtime)->peer_protocol_self_test(error);
}

Dictionary DCWorldExt::configure_country_reference_trace(bool enabled,
                                                           int max_frames) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->configure_reference_trace(
            enabled, max_frames);
}

Dictionary DCWorldExt::poll_country_reference_trace(int64_t after_frame_id,
                                                      int limit) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->poll_reference_trace(
            after_frame_id, limit);
}

Dictionary DCWorldExt::capture_country_reference_checkpoint() const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->capture_reference_checkpoint();
}

Dictionary DCWorldExt::run_country_slice(const Dictionary &ctx) {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    Dictionary out = runtime->run_slice(ctx);
    if (static_cast<bool>(out.get("ok", false)) &&
        static_cast<bool>(out.get("published_to_slot", false)) &&
        static_cast<int64_t>(out.get("changed_cells", 0)) > 0) {
        const int slot = component_id(StringName("cell_country_slot"));
        const auto publish_start = std::chrono::steady_clock::now();
        if (slot >= 0) {
            const PackedInt32Array indices = out.get("_changed_cell_indices", PackedInt32Array());
            const PackedInt32Array owners = out.get("_changed_cell_owners", PackedInt32Array());
            if (!indices.is_empty() && indices.size() == owners.size())
                write_i32_indexed(slot, indices, owners);
            else
                write_i32_range(slot, 0, runtime->cell_country_snapshot());
            _flush_slot_to_map(slot);
            ++_runtime_graph_flush_slot_count;
            _runtime_graph_visual_diff_cell_count += static_cast<uint64_t>(
                !indices.is_empty() ? indices.size() :
                static_cast<int64_t>(out.get("cell_count", 0)));
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(true, publish_ms);
            out["published_to_slot"] = true;
            out["slot_publish_ms"] = publish_ms;
            out["elapsed_ms"] = static_cast<double>(out.get("elapsed_ms", 0.0)) + publish_ms;
        } else {
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(false, publish_ms, "country_slot_unavailable");
            out["published_to_slot"] = false;
            out["publish_reason"] = "country_slot_unavailable";
        }
    }
    out.erase("_changed_cell_indices");
    out.erase("_changed_cell_owners");
    return out;
}

Dictionary DCWorldExt::sync_country_territory_to_map() {
    Dictionary out;
    out["ok"] = false;
    if (_country_runtime == nullptr) {
        out["reason"] = "country_runtime_unavailable";
        return out;
    }
    if (_map_data == nullptr) {
        out["reason"] = "map_data_unbound";
        return out;
    }
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    const int slot = component_id(StringName("cell_country_slot"));
    if (slot < 0) {
        out["reason"] = "country_slot_unavailable";
        return out;
    }
    const auto publish_start = std::chrono::steady_clock::now();
    const PackedInt32Array snapshot = runtime->cell_country_snapshot();
    write_i32_range(slot, 0, snapshot);
    _flush_slot_to_map(slot);
    const double publish_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - publish_start).count();
    ++_runtime_graph_flush_slot_count;
    _runtime_graph_visual_diff_cell_count +=
        static_cast<uint64_t>(snapshot.size());
    _runtime_graph_country_territory_sync_ms = publish_ms;
    runtime->mark_slot_publication(true, publish_ms);
    out["ok"] = true;
    out["cells"] = snapshot.size();
    out["slot_publish_ms"] = publish_ms;
    return out;
}

bool DCWorldExt::country_should_run(int64_t day_index) const {
    return _country_runtime != nullptr && country_runtime_from(_country_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::get_country_report() const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->report();
}

int64_t DCWorldExt::get_country_state_hash() const {
    return _country_runtime == nullptr ? 0 : country_runtime_from(_country_runtime)->state_hash();
}

Dictionary DCWorldExt::get_country_cell_summary(int cell_idx) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->cell_summary(cell_idx);
}

Dictionary DCWorldExt::get_country_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->country_snapshot(handle);
}

Dictionary DCWorldExt::get_country_treasury_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->treasury_snapshot(handle);
}

Dictionary DCWorldExt::get_country_research_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->research_snapshot(handle);
}

Dictionary DCWorldExt::get_country_research_signal_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->research_signal_snapshot(handle);
}

Dictionary DCWorldExt::consume_country_visual_era_dirty_slots() {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->consume_visual_era_dirty_slots();
}

bool DCWorldExt::has_completed_country_technology(
        int64_t handle, int32_t technology_id) const {
    return _country_runtime != nullptr &&
        country_runtime_from(_country_runtime)->has_completed_technology(
            handle, technology_id);
}

Dictionary DCWorldExt::get_country_tax_policy_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->tax_policy_snapshot(handle);
}

Dictionary DCWorldExt::get_country_cell_tax_policy_snapshot(int cell_idx) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->cell_tax_policy_snapshot(cell_idx);
}

Dictionary DCWorldExt::get_country_ui_snapshot(int64_t handle,
                                                int section_mask) const {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    Dictionary summary = runtime->country_summary(handle);
    if (!static_cast<bool>(summary.get("ok", false))) return summary;

    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["section"] = section_mask;
    out["section_mask"] = section_mask;
    out["country_generation"] = static_cast<int64_t>(runtime->generation());
    out["country_state_version"] = summary.get("state_version", 0);
    out["revision"] = summary.get("state_version", 0);
    out["published_day"] = runtime->report().get("last_committed_day", -1);
    out["summary"] = summary;

    Dictionary revisions;
    revisions["country_state_version"] = summary.get("state_version", 0);
    revisions["country_generation"] = static_cast<int64_t>(runtime->generation());

    if ((section_mask & 1) != 0) {
        out["research"] = runtime->research_snapshot(handle);
        out["research_signals"] = runtime->research_signal_snapshot(handle);
    }
    if ((section_mask & 2) != 0) {
        Dictionary country = summary.duplicate(false);
        country["technology_ids"] = runtime->completed_technology_ids(handle);
        out["country_snapshot"] = country;
        out["treasury"] = runtime->treasury_snapshot(handle);
        out["tax_policy"] = runtime->tax_policy_snapshot(handle);
        out["fiscal"] = get_country_fiscal_snapshot(handle);
        Dictionary trade = get_country_trade_snapshot(
            handle, String("summary"), 0, 1);
        out["trade_summary"] = trade;
        const int64_t trade_revision = trade.get("revision", int64_t{0});
        int64_t class_opinion_revision = 0;
        if (_economy_runtime != nullptr) {
            class_opinion_revision = static_cast<int64_t>(
                static_cast<NativeEconomyRuntime *>(_economy_runtime)->
                    country_class_opinion_snapshot().revision);
        }
        out["economy_trade_revision"] = trade_revision;
        out["economy_class_opinion_revision"] = class_opinion_revision;
        revisions["economy_trade_revision"] = trade_revision;
        revisions["economy_class_opinion_revision"] =
            class_opinion_revision;
    }
    if ((section_mask & 4) != 0) {
        Dictionary ideology = get_ideology_snapshot(handle);
        out["ideology"] = ideology;
        const int64_t support_revision = ideology.get(
            "support_revision", int64_t{0});
        out["ideology_support_revision"] = support_revision;
        revisions["ideology_support_revision"] = support_revision;
    }
    out["revision_components"] = revisions;
    return out;
}

Dictionary DCWorldExt::poll_country_events(int64_t after_event_id, int limit) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->poll_events(after_event_id, limit);
}

Dictionary DCWorldExt::reset_country(const String &reason) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->reset(reason);
}

Dictionary DCWorldExt::begin_country_save(int chunk_bytes) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_economy_runtime != nullptr &&
        !static_cast<NativeEconomyRuntime *>(_economy_runtime)->country_save_allowed()) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "country_save_requires_committed_economy_boundary";
        return out;
    }
    return country_runtime_from(_country_runtime)->begin_save(chunk_bytes);
}

PackedByteArray DCWorldExt::read_country_save_chunk(int max_bytes) {
    return _country_runtime == nullptr ? PackedByteArray()
        : country_runtime_from(_country_runtime)->read_save_chunk(max_bytes);
}

Dictionary DCWorldExt::end_country_save() {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->end_save();
}

Dictionary DCWorldExt::begin_country_restore() {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_economy_runtime != nullptr &&
        !static_cast<NativeEconomyRuntime *>(_economy_runtime)->country_restore_allowed()) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "country_restore_must_precede_economy_bootstrap";
        return out;
    }
    return country_runtime_from(_country_runtime)->begin_restore();
}

Dictionary DCWorldExt::feed_country_restore_chunk(const PackedByteArray &chunk) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->feed_restore_chunk(chunk);
}

Dictionary DCWorldExt::end_country_restore() {
    if (_country_runtime == nullptr) return country_unavailable();
    Dictionary out = country_runtime_from(_country_runtime)->end_restore();
    if (static_cast<bool>(out.get("ok", false))) {
        NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
        const auto publish_start = std::chrono::steady_clock::now();
        const int slot = component_id(StringName("cell_country_slot"));
        if (slot >= 0) {
            write_i32_range(slot, 0, runtime->cell_country_snapshot());
            _flush_slot_to_map(slot);
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(true, publish_ms);
            out["published_to_slot"] = true;
            out["slot_publish_ms"] = publish_ms;
        } else {
            runtime->mark_slot_publication(false, 0.0, "country_slot_unavailable");
            out["published_to_slot"] = false;
            out["publish_reason"] = "country_slot_unavailable";
        }
    }
    return out;
}

} // namespace pk

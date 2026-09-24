#include "world_ext.h"
#include "country_runtime.h"
#include "effect_runtime.h"
#include "modifier_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <vector>

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

template <size_t N>
void country_copy_fixed(std::array<char, N> &destination, const String &value) {
    const CharString utf8 = value.utf8();
    const char *source = utf8.get_data();
    size_t index = 0;
    if (source != nullptr) {
        for (; index + 1u < N && source[index] != '\0'; ++index)
            destination[index] = source[index];
    }
    destination[index] = '\0';
}

Dictionary enqueue_country_host_command_batch(
        NativeSimulationHost &host, const Dictionary &packed_batch,
        bool enforce_committed_day) {
    const PackedInt32Array opcodes = packed_batch.get(
        "opcodes", PackedInt32Array());
    const PackedInt64Array effective_days = packed_batch.get(
        "effective_days", PackedInt64Array());
    const PackedInt64Array sequences = packed_batch.get(
        "sequences", PackedInt64Array());
    const PackedInt64Array target_handles = packed_batch.get(
        "target_handles", PackedInt64Array());
    const PackedInt32Array cells = packed_batch.get(
        "cell_indices", PackedInt32Array());
    const PackedInt32Array aux = packed_batch.get(
        "aux_i32", PackedInt32Array());
    const PackedInt32Array domains = packed_batch.get(
        "domain_i32", PackedInt32Array());
    const PackedInt32Array positions = packed_batch.get(
        "position_i32", PackedInt32Array());
    const PackedInt32Array weights[4] = {
        packed_batch.get("weight0_bp", PackedInt32Array()),
        packed_batch.get("weight1_bp", PackedInt32Array()),
        packed_batch.get("weight2_bp", PackedInt32Array()),
        packed_batch.get("weight3_bp", PackedInt32Array()),
    };
    const PackedInt64Array values = packed_batch.get(
        "value_i64", PackedInt64Array());
    const PackedInt32Array tax_kinds = packed_batch.get(
        "tax_kinds", PackedInt32Array());
    const PackedInt32Array tax_items = packed_batch.get(
        "tax_item_indices", PackedInt32Array());
    const PackedInt32Array tax_rates = packed_batch.get(
        "tax_rate_basis_points", PackedInt32Array());
    const PackedInt32Array tax_modes = packed_batch.get(
        "tax_assessment_modes", PackedInt32Array());
    const PackedStringArray stable_ids = packed_batch.get(
        "stable_ids", PackedStringArray());
    const PackedStringArray display_names = packed_batch.get(
        "display_names", PackedStringArray());
    const int64_t count = opcodes.size();
    Dictionary out;
    if (count <= 0 || count > static_cast<int64_t>(RUNTIME_COUNTRY_COMMAND_BATCH_CAPACITY)) {
        out["ok"] = false;
        out["code"] = count <= 0 ? "country_command_batch_empty"
                                 : "country_command_batch_capacity_exceeded";
        return out;
    }
    const auto shape_ok = [count](int64_t size) {
        return size == count;
    };
    if (!shape_ok(effective_days.size()) || !shape_ok(sequences.size()) ||
        !shape_ok(target_handles.size()) || !shape_ok(cells.size()) ||
        !shape_ok(aux.size()) || !shape_ok(domains.size()) ||
        !shape_ok(positions.size()) || !shape_ok(values.size()) ||
        !shape_ok(tax_kinds.size()) || !shape_ok(tax_items.size()) ||
        !shape_ok(tax_rates.size()) || !shape_ok(tax_modes.size()) ||
        !shape_ok(stable_ids.size()) || !shape_ok(display_names.size())) {
        out["ok"] = false;
        out["code"] = "country_command_batch_shape_invalid";
        return out;
    }
    for (const PackedInt32Array &weight : weights) {
        if (!shape_ok(weight.size())) {
            out["ok"] = false;
            out["code"] = "country_command_batch_shape_invalid";
            return out;
        }
    }

    const RuntimeThreadReport report = host.report();
    const int64_t first_allowed_day = report.committed_day + 1;
    std::vector<RuntimeCommandPacket> packets;
    packets.reserve(static_cast<size_t>(count));
    PackedInt64Array request_ids;
    request_ids.resize(count);
    for (int64_t index = 0; index < count; ++index) {
        const uint16_t opcode = static_cast<uint16_t>(opcodes[index]);
        if (opcode < 1 || opcode > 20) {
            out["ok"] = false;
            out["code"] = "country_worker_command_opcode_invalid";
            out["opcode"] = static_cast<int64_t>(opcode);
            return out;
        }
        if (effective_days[index] < 0 || sequences[index] < 0) {
            out["ok"] = false;
            out["code"] = "country_worker_command_day_invalid";
            return out;
        }
        // A player stamps effective_day from the UI clock, which trails the
        // worker clock at high speed. Schedule the intent on the earliest day
        // the worker can still honour instead of dropping it; requested_day
        // below keeps the original intent for audit.
        const int64_t scheduled_day = enforce_committed_day
            ? std::max(effective_days[index], first_allowed_day)
            : effective_days[index];
        RuntimeCountryCommand command;
        command.request_id = host.allocate_command_request_id();
        request_ids[index] = static_cast<int64_t>(command.request_id);
        command.producer_id = 0;
        command.sequence = sequences[index] > 0
            ? static_cast<uint64_t>(sequences[index])
            : host.allocate_producer_sequence(0);
        command.observed_generation = 0;
        command.requested_day = effective_days[index];
        command.effective_day = scheduled_day;
        command.opcode = opcode;
        command.target_handle = static_cast<uint64_t>(target_handles[index]);
        command.cell = cells[index];
        command.aux = aux[index];
        command.domain = domains[index];
        command.position = positions[index];
        for (uint32_t domain = 0; domain < 4; ++domain)
            command.weights_bp[domain] = weights[domain][index];
        command.tax_kind = tax_kinds[index];
        command.tax_item = tax_items[index];
        command.tax_rate_basis_points = tax_rates[index];
        command.tax_assessment_mode = tax_modes[index];
        command.value = values[index];
        country_copy_fixed(command.stable_id, stable_ids[index]);
        country_copy_fixed(command.display_name, display_names[index]);
        RuntimeCommandPacket packet;
        packet.envelope.request_id = command.request_id;
        packet.envelope.producer_id = command.producer_id;
        packet.envelope.sequence = command.sequence;
        packet.envelope.observed_generation = command.observed_generation;
        packet.envelope.requested_day = command.requested_day;
        packet.envelope.effective_day = command.effective_day;
        packet.envelope.domain = static_cast<uint16_t>(
            RuntimeDomainId::COUNTRY);
        packet.envelope.opcode = opcode;
        packet.envelope.payload_offset = 0;
        packet.envelope.payload_size = sizeof(RuntimeCountryCommand);
        std::memcpy(packet.payload.data(), &command, sizeof(command));
        packets.push_back(packet);
    }
    if (!host.enqueue_batch(std::move(packets))) {
        out["ok"] = false;
        out["code"] = "country_worker_command_queue_capacity_exceeded";
        return out;
    }
    out["ok"] = true;
    out["code"] = "accepted";
    out["status"] = "Accepted";
    out["receipt_code"] = static_cast<int>(
        CountryCommandReceiptCode::ACCEPTED);
    out["submitted"] = count;
    out["accepted"] = count;
    out["pending"] = count;
    out["request_ids"] = request_ids;
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_country(const Dictionary &catalog,
                                         const Dictionary &profile,
                                         int cell_count, int64_t seed) {
    delete country_runtime_from(_country_query_runtime);
    _country_query_runtime = nullptr;
    _country_query_snapshot.reset();
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
            if (_runtime_host != nullptr)
                static_cast<NativeEconomyRuntime *>(_economy_runtime)
                    ->attach_simulation_host(_runtime_host.get());
        }
    if (_runtime_host != nullptr)
        country_runtime_from(_country_runtime)->attach_simulation_host(
            _runtime_host.get());
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
    if (_country_runtime == nullptr) return country_unavailable();
    const bool worker_authoritative = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::COUNTRY);
    if (worker_authoritative) {
        return enqueue_country_host_command_batch(
            *_runtime_host, packed_batch, true);
    }

    Dictionary out = country_runtime_from(_country_runtime)->submit_commands(
        packed_batch);
    if (!static_cast<bool>(out.get("ok", false))) return out;
    if (_runtime_host == nullptr) return out;
    const RuntimeWorkerState host_state = _runtime_host->state();
    const bool host_live = host_state != RuntimeWorkerState::STOPPED &&
        host_state != RuntimeWorkerState::FAULTED;
    if (!host_live || !_runtime_host->country_pod_configured()) return out;
    Dictionary mirrored = enqueue_country_host_command_batch(
        *_runtime_host, packed_batch, false);
    if (!static_cast<bool>(mirrored.get("ok", false))) {
        out["shadow_mirror_ok"] = false;
        out["shadow_mirror_code"] = String(mirrored.get("code",
            "country_shadow_command_mirror_failed"));
        if (String(out.get("shadow_mirror_code", "")).is_empty())
            out["shadow_mirror_code"] = "country_shadow_command_mirror_failed";
        return out;
    }
    out["shadow_mirror_ok"] = true;
    out["shadow_request_ids"] = mirrored.get("request_ids", PackedInt64Array());
    return out;
}

namespace {

const char *country_command_receipt_code_name(
        CountryCommandReceiptCode code) {
    switch (code) {
    case CountryCommandReceiptCode::ADMISSION_REJECTED:
        return "AdmissionRejected";
    case CountryCommandReceiptCode::ACCEPTED:
        return "Accepted";
    case CountryCommandReceiptCode::COMMITTED:
        return "Committed";
    case CountryCommandReceiptCode::REJECTED_AT_EXECUTION:
        return "RejectedAtExecution";
    }
    return "Unknown";
}

} // namespace

Dictionary DCWorldExt::poll_country_command_receipts(
        int64_t after_request_id, int limit) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    std::vector<CountryCommandReceipt> receipts;
    _runtime_host->poll_country_command_receipts(
        static_cast<uint64_t>(std::max<int64_t>(0, after_request_id)),
        static_cast<uint32_t>(std::clamp(limit, 0, 4096)), receipts);
    Array rows;
    uint64_t last_request_id = static_cast<uint64_t>(
        std::max<int64_t>(0, after_request_id));
    for (const CountryCommandReceipt &receipt : receipts) {
        Dictionary row;
        row["request_id"] = static_cast<int64_t>(receipt.request_id);
        row["producer_id"] = static_cast<int>(receipt.producer_id);
        row["sequence"] = static_cast<int64_t>(receipt.sequence);
        row["effective_day"] = receipt.effective_day;
        row["generation"] = static_cast<int64_t>(receipt.generation);
        row["code"] = static_cast<int>(receipt.code);
        row["status"] = country_command_receipt_code_name(receipt.code);
        row["reason"] = String(receipt.reason.c_str());
        rows.push_back(row);
        last_request_id = std::max(last_request_id, receipt.request_id);
    }
    out["ok"] = true;
    out["available"] = !receipts.empty();
    out["receipts"] = rows;
    out["count"] = rows.size();
    out["last_request_id"] = static_cast<int64_t>(last_request_id);
    return out;
}

bool DCWorldExt::runtime_country_host_receipt_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    const bool ok = _runtime_host->country_command_receipt_self_test(error);
    if (!ok) {
        UtilityFunctions::printerr(
            String("[country receipt self-test] ") + String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_country_host_rejection_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    const bool ok = _runtime_host->country_peer_rejection_self_test(error);
    if (!ok) {
        UtilityFunctions::printerr(
            String("[country rejection self-test] ") + String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_country_shadow_parity_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    const bool ok = _runtime_host->country_shadow_parity_self_test(error);
    if (!ok) {
        UtilityFunctions::printerr(
            String("[country shadow parity self-test] ") + String(error.c_str()));
    }
    return ok;
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

const char *country_economy_asset_operation_name(
        RuntimeEconomyAssetOperation operation) {
    switch (operation) {
    case RuntimeEconomyAssetOperation::RESEARCH_PURCHASE: return "research_purchase";
    case RuntimeEconomyAssetOperation::FISCAL_RESERVE: return "fiscal_reserve";
    case RuntimeEconomyAssetOperation::FISCAL_RETURN: return "fiscal_return";
    case RuntimeEconomyAssetOperation::FISCAL_COLLECT: return "fiscal_collect";
    case RuntimeEconomyAssetOperation::CASH_TO_COHORT: return "cash_to_cohort";
    case RuntimeEconomyAssetOperation::CASH_FROM_COHORT: return "cash_from_cohort";
    case RuntimeEconomyAssetOperation::GOOD_TO_MARKET: return "good_to_market";
    case RuntimeEconomyAssetOperation::GOOD_FROM_MARKET: return "good_from_market";
    case RuntimeEconomyAssetOperation::TREASURY_SPEND: return "treasury_spend";
    default: return "unknown";
    }
}

const char *country_economy_asset_state_name(RuntimeEconomyAssetState state) {
    // External reports use the stage-5 D7 vocabulary; wire values stay as-is.
    return runtime_d7_reservation_state_name(
        runtime_d7_reservation_state_from_asset(state));
}

const char *country_economy_asset_state_name(
        RuntimeEconomyAssetState state,
        RuntimeEconomyAssetResultCode code,
        const char *reason) {
    return runtime_d7_reservation_state_name(
        runtime_d7_reservation_state_from_asset(state, code, reason));
}

const char *country_economy_asset_result_code_name(
        RuntimeEconomyAssetResultCode code) {
    switch (code) {
    case RuntimeEconomyAssetResultCode::ACCEPTED: return "accepted";
    case RuntimeEconomyAssetResultCode::PENDING: return "pending";
    case RuntimeEconomyAssetResultCode::PEER_PREPARED: return "peer_prepared";
    case RuntimeEconomyAssetResultCode::COMMIT_DECIDED: return "commit_decided";
    case RuntimeEconomyAssetResultCode::PEER_APPLIED: return "peer_applied";
    case RuntimeEconomyAssetResultCode::COMPLETED: return "completed";
    case RuntimeEconomyAssetResultCode::REJECTED: return "rejected";
    case RuntimeEconomyAssetResultCode::FAULTED: return "faulted";
    default: return "unknown";
    }
}

const char *country_economy_asset_protocol_error_name(
        RuntimeEconomyAssetProtocolError error) {
    switch (error) {
    case RuntimeEconomyAssetProtocolError::NONE: return "none";
    case RuntimeEconomyAssetProtocolError::PROTOCOL_MISMATCH:
        return "protocol_mismatch";
    case RuntimeEconomyAssetProtocolError::REQUEST_INVALID:
        return "request_invalid";
    case RuntimeEconomyAssetProtocolError::REQUEST_UNKNOWN:
        return "request_unknown";
    case RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH:
        return "request_duplicate_mismatch";
    case RuntimeEconomyAssetProtocolError::RESULT_IDENTITY_MISMATCH:
        return "result_identity_mismatch";
    case RuntimeEconomyAssetProtocolError::RESULT_STATE_INVALID:
        return "result_state_invalid";
    case RuntimeEconomyAssetProtocolError::RESULT_DUPLICATE_MISMATCH:
        return "result_duplicate_mismatch";
    case RuntimeEconomyAssetProtocolError::SESSION_MISMATCH:
        return "session_mismatch";
    case RuntimeEconomyAssetProtocolError::GENERATION_MISMATCH:
        return "generation_mismatch";
    case RuntimeEconomyAssetProtocolError::CAPACITY_EXCEEDED:
        return "capacity_exceeded";
    default: return "unknown";
    }
}

Dictionary country_economy_asset_request_dictionary(
        const RuntimeEconomyAssetRequest &request) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(request.protocol_version);
    out["operation"] = static_cast<int64_t>(request.operation);
    out["operation_name"] = country_economy_asset_operation_name(request.operation);
    out["state"] = static_cast<int64_t>(request.state);
    out["state_name"] = country_economy_asset_state_name(request.state);
    out["reservation_state"] = static_cast<int64_t>(
        runtime_d7_reservation_state_from_asset(request.state));
    out["reservation_state_name"] = String(country_economy_asset_state_name(
        request.state));
    out["all_or_nothing"] = request.all_or_nothing != 0;
    out["session_epoch"] = static_cast<int64_t>(request.session_epoch);
    out["transaction_id"] = static_cast<int64_t>(request.transaction_id);
    out["request_id"] = static_cast<int64_t>(request.request_id);
    out["origin_domain"] = static_cast<int64_t>(request.origin_domain);
    out["origin_epoch"] = request.origin_epoch;
    out["origin_stage"] = request.origin_stage;
    out["continuation_index"] = static_cast<int64_t>(request.continuation_index);
    out["day"] = request.day;
    out["operation_sequence"] = static_cast<int64_t>(request.operation_sequence);
    out["country_generation"] = static_cast<int64_t>(request.country_generation);
    out["peer_generation"] = static_cast<int64_t>(request.peer_generation);
    out["country_handle"] = static_cast<int64_t>(request.country_handle);
    out["country_slot"] = request.country_slot;
    out["target_slot"] = request.target_slot;
    out["target_handle"] = static_cast<int64_t>(request.target_handle);
    out["good_id"] = request.good_id;
    out["good_count"] = static_cast<int>(request.good_count);
    PackedInt32Array good_ids;
    PackedInt64Array good_quantities;
    good_ids.resize(static_cast<int64_t>(request.good_count));
    good_quantities.resize(static_cast<int64_t>(request.good_count));
    for (int64_t i = 0; i < good_ids.size(); ++i) {
        good_ids.set(i, request.good_ids[static_cast<size_t>(i)]);
        good_quantities.set(i, request.good_quantities[static_cast<size_t>(i)]);
    }
    out["good_ids"] = good_ids;
    out["good_quantities"] = good_quantities;
    out["requested_quantity"] = request.requested_quantity;
    out["prepared_quantity"] = request.prepared_quantity;
    out["requested_cash"] = request.requested_cash;
    out["reserved_cash"] = request.reserved_cash;
    out["requested_goods_total"] = request.requested_goods_total;
    out["reserved_goods_total"] = request.reserved_goods_total;
    return out;
}

Dictionary country_economy_asset_result_dictionary(
        const RuntimeEconomyAssetResult &result) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(result.protocol_version);
    out["code"] = static_cast<int64_t>(result.code);
    out["result_code"] = country_economy_asset_result_code_name(result.code);
    out["state"] = static_cast<int64_t>(result.state);
    out["state_name"] = country_economy_asset_state_name(
        result.state, result.code, result.reason.data());
    out["reservation_state"] = static_cast<int64_t>(
        runtime_d7_reservation_state_from_asset(
            result.state, result.code, result.reason.data()));
    out["reservation_state_name"] = String(country_economy_asset_state_name(
        result.state, result.code, result.reason.data()));
    out["terminal_result"] = static_cast<int64_t>(
        runtime_d7_terminal_result_from_asset(
            result.code, result.state, result.reason.data()));
    out["terminal_result_name"] = String(runtime_d7_terminal_result_name(
        runtime_d7_terminal_result_from_asset(
            result.code, result.state, result.reason.data())));
    out["accepted"] = result.accepted != 0;
    out["session_epoch"] = static_cast<int64_t>(result.session_epoch);
    out["transaction_id"] = static_cast<int64_t>(result.transaction_id);
    out["request_id"] = static_cast<int64_t>(result.request_id);
    out["operation"] = static_cast<int64_t>(result.operation);
    out["operation_name"] = country_economy_asset_operation_name(result.operation);
    out["continuation_index"] = static_cast<int64_t>(result.continuation_index);
    out["day"] = result.day;
    out["country_generation"] = static_cast<int64_t>(result.country_generation);
    out["peer_generation"] = static_cast<int64_t>(result.peer_generation);
    out["committed_peer_generation"] = static_cast<int64_t>(
        result.committed_peer_generation);
    out["country_slot"] = result.country_slot;
    out["target_slot"] = result.target_slot;
    out["committed_quantity"] = result.committed_quantity;
    out["committed_cash"] = result.committed_cash;
    out["committed_goods_total"] = result.committed_goods_total;
    out["reason"] = String(result.reason.data());
    return out;
}

Dictionary country_economy_asset_protocol_status_dictionary(
        const RuntimeEconomyAssetProtocolStatus &status) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(status.protocol_version);
    out["queued_requests"] = static_cast<int64_t>(status.queued_requests);
    out["pending_requests"] = static_cast<int64_t>(status.pending_requests);
    out["terminal_requests"] = static_cast<int64_t>(status.terminal_requests);
    out["rejected_results"] = static_cast<int64_t>(status.rejected_results);
    out["faulted_transactions"] = static_cast<int64_t>(
        status.faulted_transactions);
    out["recovered_transactions"] = static_cast<int64_t>(
        status.recovered_transactions);
    out["duplicate_messages"] = static_cast<int64_t>(
        status.duplicate_messages);
    out["session_epoch"] = static_cast<int64_t>(status.session_epoch);
    out["last_transaction_id"] = static_cast<int64_t>(status.last_transaction_id);
    out["last_request_id"] = static_cast<int64_t>(status.last_request_id);
    out["last_error"] = static_cast<int64_t>(status.last_error);
    out["last_error_name"] = country_economy_asset_protocol_error_name(
        status.last_error);
    out["last_reason"] = String(status.last_reason.data());
    out["has_save_barrier"] = status.pending_requests != 0 ||
        status.queued_requests != 0;
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
    PackedByteArray effect_required;
    domains.resize(static_cast<int64_t>(catalog.technology_domains.size()));
    flags.resize(static_cast<int64_t>(catalog.technology_flags.size()));
    effect_required.resize(static_cast<int64_t>(catalog.technology_effect_required.size()));
    prereq_offsets.resize(static_cast<int64_t>(catalog.prerequisite_offsets.size()));
    prerequisites.resize(static_cast<int64_t>(catalog.prerequisites.size()));
    for (int64_t i = 0; i < domains.size(); ++i) domains.set(i, catalog.technology_domains[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < flags.size(); ++i) flags.set(i, catalog.technology_flags[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < effect_required.size(); ++i) effect_required.set(i, catalog.technology_effect_required[static_cast<size_t>(i)]);
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
    PackedInt32Array reveal_offsets, reveal_ops, reveal_refs;
    PackedInt64Array reveal_values;
    reveal_offsets.resize(static_cast<int64_t>(catalog.reveal_condition_offsets.size()));
    reveal_ops.resize(static_cast<int64_t>(catalog.reveal_condition_ops.size()));
    reveal_refs.resize(static_cast<int64_t>(catalog.reveal_condition_refs.size()));
    reveal_values.resize(static_cast<int64_t>(catalog.reveal_condition_values.size()));
    for (int64_t i = 0; i < reveal_offsets.size(); ++i) reveal_offsets.set(i, catalog.reveal_condition_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < reveal_ops.size(); ++i) reveal_ops.set(i, catalog.reveal_condition_ops[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < reveal_refs.size(); ++i) reveal_refs.set(i, catalog.reveal_condition_refs[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < reveal_values.size(); ++i) reveal_values.set(i, catalog.reveal_condition_values[static_cast<size_t>(i)]);
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
    out["technology_effect_required"] = effect_required;
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
    out["reveal_condition_offsets"] = reveal_offsets;
    out["reveal_condition_ops"] = reveal_ops;
    out["reveal_condition_refs"] = reveal_refs;
    out["reveal_condition_values"] = reveal_values;
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
    out["rejected_intents"] = static_cast<int64_t>(status.rejected_intents);
    out["has_unreported_rejection"] = status.has_unreported_rejection;
    out["retry_day"] = status.retry_day;
    out["rejected_request_id"] = static_cast<int64_t>(
        status.rejected_request_id);
    out["session_epoch"] = static_cast<int64_t>(status.session_epoch);
    out["country_generation"] = static_cast<int64_t>(status.country_generation);
    out["day"] = status.day;
    out["continuation_index"] = static_cast<int64_t>(status.continuation_index);
    out["boundary_id"] = static_cast<int64_t>(status.boundary_id);
    out["last_admitted_submit_order"] = static_cast<int64_t>(
        status.last_admitted_submit_order);
    out["expected_base_generation"] = static_cast<int64_t>(
        status.expected_base_generation);
    out["catalog_hash"] = static_cast<int64_t>(status.catalog_hash);
    out["last_reason"] = String(status.last_reason);
    out["has_save_barrier"] = status.plan_active || status.pending_intents != 0 ||
        status.result_count != 0 || status.rejected_intents != 0 ||
        status.has_unreported_rejection;
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
        const int64_t owner_count = static_cast<int64_t>(
            view.snapshot->cell_country_slot.size());
        PackedInt32Array owners;
        owners.resize(owner_count);
        if (owner_count > 0) {
            std::memcpy(owners.ptrw(), view.snapshot->cell_country_slot.data(),
                static_cast<size_t>(owner_count) * sizeof(int32_t));
        }
        out["full_cell_owners"] = owners;
    } else {
        out["full_cell_owners"] = PackedInt32Array();
    }
    PackedInt64Array country_cash;
    PackedInt64Array country_state_versions;
    if (view.snapshot != nullptr) {
        country_cash.resize(static_cast<int64_t>(view.snapshot->country_cash.size()));
        country_state_versions.resize(static_cast<int64_t>(
            view.snapshot->country_state_version.size()));
        for (int64_t i = 0; i < country_cash.size(); ++i) {
            country_cash.set(i, view.snapshot->country_cash[
                static_cast<size_t>(i)]);
        }
        for (int64_t i = 0; i < country_state_versions.size(); ++i) {
            country_state_versions.set(i, static_cast<int64_t>(
                view.snapshot->country_state_version[static_cast<size_t>(i)]));
        }
    }
    // Country ACTIVE consumers read these immutable snapshot fields instead
    // of consulting the synchronous Country store, which is deliberately not
    // mutated by the worker.
    out["country_cash"] = country_cash;
    out["country_state_versions"] = country_state_versions;
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

Dictionary DCWorldExt::get_country_economy_asset_protocol_status() const {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    Dictionary out = country_economy_asset_protocol_status_dictionary(
        _runtime_host->country_economy_asset_protocol_status());
    out["ok"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::poll_country_economy_asset_request() {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeEconomyAssetRequest request;
    if (!_runtime_host->poll_country_economy_asset_request(request)) {
        Dictionary out = country_economy_asset_protocol_status_dictionary(
            _runtime_host->country_economy_asset_protocol_status());
        out["ok"] = true;
        out["available"] = false;
        out["code"] = "country_economy_asset_request_empty";
        return out;
    }
    Dictionary out = country_economy_asset_request_dictionary(request);
    out["ok"] = true;
    out["available"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::submit_country_economy_asset_result(
        const Dictionary &input) {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeEconomyAssetResult result;
    result.protocol_version = country_peer_u32(
        input, "protocol_version", RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION);
    result.code = static_cast<RuntimeEconomyAssetResultCode>(
        country_peer_u32(input, "code"));
    result.state = static_cast<RuntimeEconomyAssetState>(
        country_peer_u32(input, "state"));
    result.accepted = static_cast<uint8_t>(country_peer_u32(
        input, "accepted"));
    result.session_epoch = country_peer_u64(input, "session_epoch");
    result.transaction_id = country_peer_u64(input, "transaction_id");
    result.request_id = country_peer_u64(input, "request_id");
    result.operation = static_cast<RuntimeEconomyAssetOperation>(
        country_peer_u32(input, "operation"));
    result.continuation_index = country_peer_u32(input, "continuation_index");
    result.day = country_peer_i64(input, "day", -1);
    result.country_generation = country_peer_u64(input, "country_generation");
    result.peer_generation = country_peer_u64(input, "peer_generation");
    result.committed_peer_generation = country_peer_u64(
        input, "committed_peer_generation");
    result.country_slot = country_peer_i32(input, "country_slot");
    result.target_slot = country_peer_i32(input, "target_slot");
    result.committed_quantity = country_peer_i64(
        input, "committed_quantity");
    result.committed_cash = country_peer_i64(input, "committed_cash");
    result.committed_goods_total = country_peer_i64(
        input, "committed_goods_total");
    const std::string reason = country_peer_string(input, "reason")
        .utf8().get_data();
    country_peer_copy_reason(result.reason, reason.c_str());

    std::string error;
    if (!_runtime_host->submit_country_economy_asset_result(result, error)) {
        Dictionary out = country_economy_asset_protocol_status_dictionary(
            _runtime_host->country_economy_asset_protocol_status());
        out["ok"] = false;
        out["code"] = error.empty()
            ? "country_economy_asset_result_rejected" : error.c_str();
        out["request_id"] = static_cast<int64_t>(result.request_id);
        out["transaction_id"] = static_cast<int64_t>(result.transaction_id);
        return out;
    }
    Dictionary out = country_economy_asset_result_dictionary(result);
    out["ok"] = true;
    out["code"] = "ok";
    return out;
}

bool DCWorldExt::runtime_country_host_economy_protocol_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    return _runtime_host->country_economy_asset_protocol_self_test(error);
}

bool DCWorldExt::runtime_country_host_handoff_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    const bool ok = _runtime_host->country_authority_handoff_self_test(error);
    if (!ok) {
        UtilityFunctions::printerr(
            String("[country handoff self-test] ") + String(error.c_str()));
    }
    return ok;
}

Dictionary DCWorldExt::prepare_country_authority_handoff(int target_owner) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (_country_runtime != nullptr) {
        const Dictionary ledger =
            country_runtime_from(_country_runtime)->economy_asset_transaction_report();
        if (int64_t(ledger.get("in_flight", 0)) > 0) {
            out["ok"] = false;
            out["code"] = "country_authority_handoff_busy";
            out["in_flight"] = ledger.get("in_flight", 0);
            return out;
        }
    }
    std::string error;
    const auto target = target_owner == 1
        ? NativeSimulationHost::CountryAuthorityOwner::WORKER
        : NativeSimulationHost::CountryAuthorityOwner::SYNC;
    const bool ok = _runtime_host->prepare_country_authority_handoff(target, error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : (error.empty() ? "country_authority_handoff_failed" : error.c_str());
    return out;
}

Dictionary DCWorldExt::install_country_authority_handoff() {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const auto before = _runtime_host->country_authority_handoff_status();
    if (!before.prepare_pending) {
        out["ok"] = false;
        out["code"] = "country_authority_handoff_not_prepared";
        return out;
    }
    // SYNC→WORKER: publish the live sync store as the handoff checkpoint before
    // flipping unique-writer ownership. Missing capture fails closed in Host.
    if (before.prepared_target ==
            NativeSimulationHost::CountryAuthorityOwner::WORKER &&
        _country_runtime != nullptr) {
        const Dictionary captured = capture_country_runtime_snapshot();
        if (!bool(captured.get("ok", false))) {
            out["ok"] = false;
            out["code"] = String(captured.get("code",
                "country_authority_handoff_checkpoint_missing"));
            std::string abort_error;
            _runtime_host->abort_country_authority_handoff(abort_error);
            return out;
        }
        out["checkpoint_generation"] = captured.get("generation", 0);
        out["checkpoint_state_hash"] = captured.get("state_hash", 0);
    }
    std::string error;
    const bool ok = _runtime_host->install_country_authority_handoff(error);
    if (!ok) {
        out["ok"] = false;
        out["code"] = error.empty() ? "country_authority_handoff_failed" : error.c_str();
        return out;
    }
    const auto after = _runtime_host->country_authority_handoff_status();
    if (_country_runtime != nullptr) {
        country_runtime_from(_country_runtime)->set_sync_store_writes_forbidden(
            after.owner == NativeSimulationHost::CountryAuthorityOwner::WORKER);
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["owner"] = static_cast<int>(after.owner);
    out["session_epoch"] = static_cast<int64_t>(after.session_epoch);
    out["implemented_domain_mask"] = static_cast<int64_t>(
        _runtime_host->implemented_domain_mask());
    return out;
}

Dictionary DCWorldExt::abort_country_authority_handoff() {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    std::string error;
    const bool ok = _runtime_host->abort_country_authority_handoff(error);
    const auto status = _runtime_host->country_authority_handoff_status();
    out["ok"] = ok;
    out["code"] = ok ? "ok" : (error.empty() ? "country_authority_handoff_failed" : error.c_str());
    out["owner"] = static_cast<int>(status.owner);
    out["prepare_pending"] = status.prepare_pending;
    out["reason"] = String(status.last_reason);
    return out;
}

Dictionary DCWorldExt::get_country_authority_handoff_status() const {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const auto status = _runtime_host->country_authority_handoff_status();
    out["ok"] = true;
    out["owner"] = static_cast<int>(status.owner);
    out["prepared_target"] = static_cast<int>(status.prepared_target);
    out["prepare_pending"] = status.prepare_pending;
    out["session_epoch"] = static_cast<int64_t>(status.session_epoch);
    out["reason"] = String(status.last_reason);
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
    const RuntimeThreadReport host_report = _runtime_host->report();
    if (!shadow_replay &&
        (host_report.mode != RuntimeSimulationMode::ACTIVE ||
         (host_report.requested_authority_mask &
          runtime_domain_mask(RuntimeDomainId::COUNTRY)) == 0u)) {
        // A real peer write is legal only for a worker that was explicitly
        // admitted in ACTIVE Country mode. In particular, SHADOW callers
        // must never accidentally mutate the legacy peer stores.
        out["ok"] = false;
        out["code"] = "country_worker_real_peer_adapter_not_authoritative";
        return out;
    }
    if (!shadow_replay && _country_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "country_worker_real_peer_adapter_country_missing";
        return out;
    }
    {
        // Distinguishes "pump never reaches the drain loop" from "pump runs but
        // Country published no intents". Rate limited; diagnostic only.
        static int s_pump_left = 20;
        const NativeSimulationHost::CountryWorkerProtocolStatus pump_status =
            _runtime_host->country_worker_protocol_status();
        if (pump_status.queued_intents > 0 && s_pump_left-- > 0) {
            UtilityFunctions::print(vformat(
                "[tech-ack-diag/pump] entering drain shadow_replay=%d "
                "queued=%d pending=%d",
                shadow_replay ? 1 : 0,
                static_cast<int64_t>(pump_status.queued_intents),
                static_cast<int64_t>(pump_status.pending_intents)));
        }
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

        if (shadow_replay) {
            // This is deliberately a replay result, not an Effect/Modifier
            // call. It proves the transport while keeping SHADOW free of
            // peer side effects.
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
                break;
            }
        } else {
            result = country_runtime_from(_country_runtime)
                ->execute_peer_intent_from_worker(intent);
        }
        if (result.code == CountryPeerResultCode::REJECTED) ++rejected;
        if (shadow_replay)
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
    out["shadow_replay"] = shadow_replay;
    out["real_adapter"] = !shadow_replay;
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
    publish_restored_country_territory(out);
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

void DCWorldExt::set_country_sync_store_writes_forbidden(bool forbidden) {
    if (_country_runtime != nullptr)
        country_runtime_from(_country_runtime)->set_sync_store_writes_forbidden(
            forbidden);
}

Dictionary DCWorldExt::run_country_slice(const Dictionary &ctx) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_runtime_host != nullptr && _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::COUNTRY)) {
        Dictionary out;
        out["ok"] = false;
        out["done"] = true;
        out["code"] = "country_worker_authoritative";
        out["path"] = "native_country_worker";
        out["authoritative"] = true;
        return out;
    }
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
    if (static_cast<bool>(out.get("ok", false)) &&
        static_cast<bool>(out.get("done", false)) &&
        _runtime_host != nullptr &&
        _runtime_host->country_pod_configured()) {
        RuntimeCountryPodSnapshot snapshot;
        std::string error;
        if (runtime->export_pod_snapshot(snapshot, error) && snapshot.state_hash != 0) {
            std::string publish_error;
            if (!_runtime_host->publish_country_reference(
                    snapshot.committed_day, snapshot.state_hash,
                    publish_error, &snapshot)) {
                out["country_reference_ok"] = false;
                out["country_reference_code"] = String(publish_error.c_str());
            } else {
                out["country_reference_ok"] = true;
                out["country_reference_hash"] = static_cast<int64_t>(snapshot.state_hash);
            }
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
    // ACTIVE Country UI revision clocks must track the worker-committed
    // replica, not the frozen sync store.
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->report();
}

int64_t DCWorldExt::get_country_state_hash() const {
    return _country_runtime == nullptr ? 0 : country_runtime_from(_country_runtime)->state_hash();
}

NativeCountryRuntime *DCWorldExt::country_query_runtime() const {
    auto *source = country_runtime_from(_country_runtime);
    if (source == nullptr || _runtime_host == nullptr ||
        !_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY))
        return source;
    const auto snapshot = _runtime_host->country_asset_snapshot();
    if (!snapshot) return source;
    if (_country_query_runtime == nullptr)
        _country_query_runtime = new NativeCountryRuntime(*source);
    auto *view = country_runtime_from(_country_query_runtime);
    if (_country_query_snapshot != snapshot) {
        // Only advance the cursor when the replica installs successfully.
        // A rejected shape must retry on the next read instead of locking the
        // UI onto the pre-ACTIVE sync copy forever.
        if (view->apply_committed_read_snapshot(*snapshot)) {
            _country_query_snapshot = snapshot;
            static int s_apply_ok_left = 8;
            if (s_apply_ok_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ui-diag/query] apply ok gen=%d day=%d "
                    "view_gen=%d progress_total=%d pending_words=%d",
                    static_cast<int64_t>(snapshot->generation),
                    snapshot->committed_day,
                    static_cast<int64_t>(view->report().get("generation", 0)),
                    snapshot->research_progress_total.empty()
                        ? 0
                        : static_cast<int64_t>(
                              snapshot->research_progress_total[0]),
                    static_cast<int64_t>(
                        snapshot->country_pending_technologies.size())));
            }
        } else {
            static int s_apply_fail_left = 12;
            if (s_apply_fail_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ui-diag/query] apply FAILED gen=%d day=%d "
                    "countries=%d cells=%d techs=%d — UI stays on sync copy",
                    static_cast<int64_t>(snapshot->generation),
                    snapshot->committed_day,
                    static_cast<int64_t>(snapshot->country_count),
                    static_cast<int64_t>(snapshot->cell_count),
                    static_cast<int64_t>(snapshot->technology_count)));
            }
        }
    }
    return view;
}

Dictionary DCWorldExt::get_country_cell_summary(int cell_idx) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->cell_summary(cell_idx);
}

Dictionary DCWorldExt::get_country_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->country_snapshot(handle);
}

Dictionary DCWorldExt::get_country_treasury_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->treasury_snapshot(handle);
}

Dictionary DCWorldExt::get_country_research_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->research_snapshot(handle);
}

Dictionary DCWorldExt::get_country_research_signal_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->research_signal_snapshot(handle);
}

Dictionary DCWorldExt::consume_country_visual_era_dirty_slots() {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->consume_visual_era_dirty_slots();
}

bool DCWorldExt::has_completed_country_technology(
        int64_t handle, int32_t technology_id) const {
    return _country_runtime != nullptr &&
        country_query_runtime()->has_completed_technology(
            handle, technology_id);
}

Dictionary DCWorldExt::get_country_tax_policy_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->tax_policy_snapshot(handle);
}

Dictionary DCWorldExt::get_country_cell_tax_policy_snapshot(int cell_idx) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->cell_tax_policy_snapshot(cell_idx);
}

Dictionary DCWorldExt::get_country_ui_snapshot(int64_t handle,
                                                int section_mask) const {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_query_runtime();
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
        Dictionary research = runtime->research_snapshot(handle);
        out["research"] = research;
        out["research_signals"] = runtime->research_signal_snapshot(handle);
        // Progress-only days must bust the GDScript section cache even when
        // the player reopens the panel without a territory dirty bit.
        revisions["research_progress_total"] = research.get("progress_total", 0);
        revisions["research_consumed_total"] = research.get("consumed_total", 0);
        revisions["research_completed_total"] = research.get(
            "completed_total", 0);
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
    if (static_cast<bool>(out.get("ok", false)))
        publish_restored_country_territory(out);
    return out;
}

// Every restore path must end here. PKCN restores native territory only; the
// cell_country_slot mirror is what MapData, vision, borders, and the player
// identity binding read. The CPD2 checkpoint path used to skip this, so a load
// through PKSR left every cell at -1 and failed the player-country binding.
void DCWorldExt::publish_restored_country_territory(Dictionary &out) {
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

} // namespace pk

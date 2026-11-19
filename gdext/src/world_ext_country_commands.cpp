// Country command admission and date semantics; state remains on DCWorldExt/Host.
#include "world_ext.h"
#include "country_ai_core.h"
#include "country_api.h"
#include "native_simulation_host.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <vector>

namespace pk {
using namespace godot;
namespace {
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
        bool enforce_committed_day, uint32_t producer_id = 0) {
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
    // A vision sweep can discover more signals than a normal player batch.
    // Admit the full sweep atomically into the Host queue.
    const bool too_many_commands =
        count > static_cast<int64_t>(RUNTIME_COMMAND_QUEUE_CAPACITY) ||
        (count > static_cast<int64_t>(RUNTIME_COUNTRY_COMMAND_BATCH_CAPACITY) &&
         !std::all_of(opcodes.ptr(), opcodes.ptr() + count, [](int32_t opcode) {
             return opcode == CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL;
         }));
    if (count <= 0 || too_many_commands) {
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

    const int64_t first_allowed_day = host.command_seal_day();
    const bool scheduled = packed_batch.get("preserve_effective_days", false);
    std::vector<RuntimeCommandPacket> packets;
    packets.reserve(static_cast<size_t>(count));
    PackedInt64Array request_ids;
    request_ids.resize(count);
    for (int64_t index = 0; index < count; ++index) {
        const uint16_t opcode = static_cast<uint16_t>(opcodes[index]);
        if (opcode < 1 ||
            opcode > CountryApi::COMMAND_OPCODE_MAX ||
            CountryApi::command_opcode_reserved(opcode)) {
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
        // Immediate player actions use the first unsealed day. Explicitly
        // dated actions and mirrors retain their promised date; the Host can
        // only move an already sealed date later, never execute it early.
        const int64_t scheduled_day = enforce_committed_day && !scheduled
            ? first_allowed_day
            : std::max<int64_t>(effective_days[index], first_allowed_day);
        RuntimeCountryCommand command;
        command.request_id = host.allocate_command_request_id();
        request_ids[index] = static_cast<int64_t>(command.request_id);
        command.producer_id = producer_id;
        command.sequence = sequences[index] > 0
            ? static_cast<uint64_t>(sequences[index])
            : host.allocate_producer_sequence(producer_id);
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
    std::vector<int64_t> admitted_days;
    if (!host.enqueue_batch(std::move(packets), &admitted_days)) {
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
    PackedInt64Array actual_days;
    for (const int64_t day : admitted_days) actual_days.push_back(day);
    out["effective_days"] = actual_days;
    if (actual_days.size() == 1) out["effective_day"] = actual_days[0];
    return out;
}
} // namespace

Dictionary DCWorldExt::submit_country_commands(const Dictionary &packed_batch) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_runtime_host != nullptr) {
        const RuntimeWorkerState host_state = _runtime_host->state();
        if (host_state == RuntimeWorkerState::FAULTED) {
            Dictionary out;
            out["ok"] = false;
            out["code"] = "runtime_worker_faulted";
            out["reason"] = "runtime_worker_faulted";
            out["message"] = "运行时已故障，无法再提交国家指令。";
            return out;
        }
    }
    // The ACTIVE executor owns admission from the start, including the
    // first-day interval before it has proved the full Country grant.
    if (_runtime_host && _runtime_host->domain_main_thread_suppressed(RuntimeDomainId::COUNTRY)) {
        return enqueue_country_host_command_batch(
            *_runtime_host, packed_batch, true);
    }

    Dictionary out = country_api::submit_commands(
        *static_cast<NativeCountryRuntime *>(_country_runtime), packed_batch);
    if (!static_cast<bool>(out.get("ok", false))) return out;
    const PackedInt64Array actual_days = packed_batch.get("effective_days", PackedInt64Array());
    out["effective_days"] = actual_days;
    if (actual_days.size() == 1) out["effective_day"] = actual_days[0];
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
    out["effective_days"] = mirrored.get("effective_days", actual_days);
    if (mirrored.has("effective_day")) out["effective_day"] = mirrored["effective_day"];
    return out;
}

Dictionary DCWorldExt::submit_country_ai_batch(const Dictionary &packed_batch) {
    if (_country_runtime == nullptr) return country_unavailable();
    Dictionary out = country_api::submit_commands(*static_cast<NativeCountryRuntime *>(_country_runtime), packed_batch);
    if (!static_cast<bool>(out.get("ok", false)) || _runtime_host == nullptr) return out;
    const RuntimeWorkerState host_state = _runtime_host->state();
    if (host_state == RuntimeWorkerState::STOPPED || host_state == RuntimeWorkerState::FAULTED ||
        !_runtime_host->country_pod_configured())
        return out;
    // SHADOW parity: the worker replays the exact AI commands on the same day.
    Dictionary mirrored = enqueue_country_host_command_batch(
        *_runtime_host, packed_batch, false, COUNTRY_AI_PRODUCER_ID);
    out["shadow_mirror_ok"] = static_cast<bool>(mirrored.get("ok", false));
    return out;
}

} // namespace pk

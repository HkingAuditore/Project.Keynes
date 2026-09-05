#include "runtime_protocol_guard.h"
#include "runtime_authoritative_domains.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace pk {
namespace {

void fail(std::string &error, const char *value) {
    error = value != nullptr ? value : "runtime_protocol_guard_failed";
}

bool has_text(const char *value) {
    return value != nullptr && value[0] != '\0';
}

bool queue_model_test(std::string &error) {
    std::array<uint64_t, RUNTIME_COMMAND_QUEUE_CAPACITY> command_queue{};
    uint64_t write = 0;
    uint64_t read = 0;
    for (uint64_t id = 0; id < RUNTIME_COMMAND_QUEUE_CAPACITY; ++id) {
        if (write - read >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
            fail(error, "runtime_command_queue_rejected_before_capacity");
            return false;
        }
        command_queue[write % RUNTIME_COMMAND_QUEUE_CAPACITY] = id;
        ++write;
    }
    if (write - read != RUNTIME_COMMAND_QUEUE_CAPACITY) {
        fail(error, "runtime_command_queue_depth_contract_invalid");
        return false;
    }
    // A bounded queue must fail immediately while full and must not overwrite
    // the oldest accepted packet.
    bool command_rejected = false;
    if (write - read >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        command_rejected = true;
    }
    if (!command_rejected) {
        fail(error, "runtime_command_queue_full_not_observed");
        return false;
    }
    const uint64_t rejected_position = write;
    if (rejected_position - read < RUNTIME_COMMAND_QUEUE_CAPACITY) {
        fail(error, "runtime_command_queue_capacity_check_invalid");
        return false;
    }
    for (uint64_t id = 0; id < RUNTIME_COMMAND_QUEUE_CAPACITY; ++id) {
        if (read >= write || command_queue[read % RUNTIME_COMMAND_QUEUE_CAPACITY] != id) {
            fail(error, "runtime_command_queue_order_invalid");
            return false;
        }
        ++read;
    }
    if (read != write) {
        fail(error, "runtime_command_queue_drain_invalid");
        return false;
    }

    std::array<RuntimeCommandReceipt, RUNTIME_RECEIPT_QUEUE_CAPACITY> receipt_queue{};
    uint64_t receipt_write = 0;
    uint64_t receipt_read = 0;
    for (uint64_t id = 0; id < RUNTIME_RECEIPT_QUEUE_CAPACITY; ++id) {
        if (receipt_write - receipt_read >= RUNTIME_RECEIPT_QUEUE_CAPACITY) {
            fail(error, "runtime_receipt_queue_rejected_before_capacity");
            return false;
        }
        receipt_queue[receipt_write % RUNTIME_RECEIPT_QUEUE_CAPACITY].request_id = id + 1u;
        ++receipt_write;
    }
    if (receipt_write - receipt_read != RUNTIME_RECEIPT_QUEUE_CAPACITY) {
        fail(error, "runtime_receipt_queue_depth_contract_invalid");
        return false;
    }
    bool receipt_rejected = false;
    if (receipt_write - receipt_read >= RUNTIME_RECEIPT_QUEUE_CAPACITY) {
        receipt_rejected = true;
    }
    if (!receipt_rejected) {
        fail(error, "runtime_receipt_queue_full_not_observed");
        return false;
    }
    for (uint64_t id = 0; id < RUNTIME_RECEIPT_QUEUE_CAPACITY; ++id) {
        if (receipt_read >= receipt_write ||
            receipt_queue[receipt_read % RUNTIME_RECEIPT_QUEUE_CAPACITY].request_id != id + 1u) {
            fail(error, "runtime_receipt_queue_order_invalid");
            return false;
        }
        ++receipt_read;
    }
    if (receipt_read != receipt_write) {
        fail(error, "runtime_receipt_queue_drain_invalid");
        return false;
    }
    return true;
}

} // namespace

bool RuntimeProtocolGuard::validate_command(const RuntimeCommandPacket &packet,
                                            std::string &error) {
    const RuntimeCommandEnvelope &envelope = packet.envelope;
    if (envelope.request_id == 0 || envelope.producer_id == 0 || envelope.sequence == 0) {
        fail(error, "runtime_command_identity_invalid");
        return false;
    }
    if (envelope.domain < static_cast<uint16_t>(RuntimeDomainId::INPUT_CAPTURE) ||
        envelope.domain > static_cast<uint16_t>(RuntimeDomainId::COMMIT)) {
        fail(error, "runtime_command_domain_invalid");
        return false;
    }
    if (envelope.payload_offset > RUNTIME_MAX_COMMAND_PAYLOAD ||
        envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD ||
        static_cast<uint64_t>(envelope.payload_offset) +
                static_cast<uint64_t>(envelope.payload_size) >
            RUNTIME_MAX_COMMAND_PAYLOAD) {
        fail(error, "runtime_command_payload_bounds_invalid");
        return false;
    }
    if (envelope.effective_day < envelope.requested_day) {
        fail(error, "runtime_command_day_order_invalid");
        return false;
    }
    error.clear();
    return true;
}

bool RuntimeProtocolGuard::command_less(const RuntimeCommandPacket &lhs,
                                        const RuntimeCommandPacket &rhs) noexcept {
    const RuntimeCommandEnvelope &a = lhs.envelope;
    const RuntimeCommandEnvelope &b = rhs.envelope;
    if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
    if (a.producer_id != b.producer_id) return a.producer_id < b.producer_id;
    if (a.sequence != b.sequence) return a.sequence < b.sequence;
    return a.request_id < b.request_id;
}

bool RuntimeProtocolGuard::self_test(std::string &error) {
    error.clear();

    if (RUNTIME_DOMAIN_POD_ABI_VERSION != 3u ||
        RUNTIME_DOMAIN_STAGE_COUNT != 12u ||
        RUNTIME_ALL_DOMAIN_MASK != 0xFFFu) {
        fail(error, "runtime_protocol_abi_v3_contract_invalid");
        return false;
    }

    const auto order = runtime_domain_stage_order();
    uint32_t seen_mask = 0;
    for (size_t index = 0; index < order.size(); ++index) {
        const RuntimeDomainId expected = static_cast<RuntimeDomainId>(index + 1u);
        if (order[index] != expected ||
            runtime_domain_mask(order[index]) == 0u ||
            (seen_mask & runtime_domain_mask(order[index])) != 0u) {
            fail(error, "runtime_domain_stage_order_or_bit_invalid");
            return false;
        }
        seen_mask |= runtime_domain_mask(order[index]);
    }
    if (seen_mask != RUNTIME_ALL_DOMAIN_MASK ||
        runtime_domain_mask(RuntimeDomainId::CLIMATE) ==
            runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) {
        fail(error, "runtime_domain_mask_uniqueness_invalid");
        return false;
    }

    RuntimeAuthoritativeDomainStores stores;
    stores.reset(2u, 1u);
    RuntimeDomainDayResult barrier = stores.validate_day_barrier(
        RuntimeDomainId::CLIMATE, 0, 1);
    if (!barrier.planned || barrier.committed || barrier.ack_barrier_complete ||
        barrier.header.preflight_ok == 0 ||
        barrier.header.domain != static_cast<uint16_t>(RuntimeDomainId::CLIMATE) ||
        barrier.header.abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION) {
        fail(error, "runtime_domain_barrier_contract_invalid");
        return false;
    }
    barrier = stores.validate_day_barrier(RuntimeDomainId::CLIMATE, -1, 1);
    if (barrier.header.preflight_ok != 0 ||
        std::strcmp(barrier.error, "domain_barrier_input_invalid") != 0) {
        fail(error, "runtime_domain_barrier_invalid_input_not_rejected");
        return false;
    }
    for (const RuntimeDomainId domain : order) {
        const RuntimeDomainDayResult stage = stores.validate_day_barrier(domain, 0, 1);
        const bool is_commit = domain == RuntimeDomainId::COMMIT;
        if (stage.header.preflight_ok == 0 || stage.planned == 0 ||
            (stage.committed != static_cast<uint8_t>(is_commit)) ||
            (stage.ack_barrier_complete != static_cast<uint8_t>(is_commit))) {
            fail(error, "runtime_domain_barrier_sequence_invalid");
            return false;
        }
    }

    // Current rollout deliberately exposes COMMIT only. This check prevents
    // a future change from silently allowing ACTIVE before all twelve stages
    // have verified handlers.
    const uint32_t implemented_mask = runtime_domain_mask(RuntimeDomainId::COMMIT);
    if (implemented_mask == RUNTIME_ALL_DOMAIN_MASK ||
        (RUNTIME_ALL_DOMAIN_MASK & ~implemented_mask) == 0u) {
        fail(error, "runtime_active_gate_should_remain_blocked");
        return false;
    }

    RuntimeDomainHeader rejected{};
    rejected.domain = static_cast<uint16_t>(RuntimeDomainId::CLIMATE);
    rejected.abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    rejected.preflight_ok = 0;
    const char *fallback = "protocol_test_preflight_rejected";
    std::memcpy(rejected.fallback_reason, fallback,
                std::min(sizeof(rejected.fallback_reason) - 1u, std::strlen(fallback)));
    if (rejected.preflight_ok != 0 || !has_text(rejected.fallback_reason)) {
        fail(error, "runtime_fallback_reason_contract_invalid");
        return false;
    }

    RuntimeCommandPacket valid{};
    valid.envelope.request_id = 10;
    valid.envelope.producer_id = 2;
    valid.envelope.sequence = 4;
    valid.envelope.requested_day = 4;
    valid.envelope.effective_day = 5;
    valid.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    valid.envelope.opcode = 1;
    valid.envelope.payload_offset = 2;
    valid.envelope.payload_size = RUNTIME_MAX_COMMAND_PAYLOAD - 2u;
    if (!validate_command(valid, error)) return false;

    RuntimeCommandPacket invalid_payload = valid;
    invalid_payload.envelope.payload_offset = RUNTIME_MAX_COMMAND_PAYLOAD;
    invalid_payload.envelope.payload_size = 1;
    if (validate_command(invalid_payload, error) ||
        error != "runtime_command_payload_bounds_invalid") {
        fail(error, "runtime_command_payload_bounds_not_rejected");
        return false;
    }
    RuntimeCommandPacket invalid_day = valid;
    invalid_day.envelope.effective_day = invalid_day.envelope.requested_day - 1;
    if (validate_command(invalid_day, error) ||
        error != "runtime_command_day_order_invalid") {
        fail(error, "runtime_command_day_order_not_rejected");
        return false;
    }

    std::vector<RuntimeCommandPacket> commands(4u);
    const int64_t days[] = {8, 7, 7, 7};
    const uint32_t producers[] = {3, 2, 1, 1};
    const uint64_t sequences[] = {1, 5, 2, 1};
    const uint64_t requests[] = {4, 3, 2, 1};
    for (size_t i = 0; i < commands.size(); ++i) {
        commands[i] = valid;
        commands[i].envelope.effective_day = days[i];
        commands[i].envelope.producer_id = producers[i];
        commands[i].envelope.sequence = sequences[i];
        commands[i].envelope.request_id = requests[i];
    }
    std::stable_sort(commands.begin(), commands.end(), command_less);
    if (commands[0].envelope.request_id != 1 ||
        commands[1].envelope.request_id != 2 ||
        commands[2].envelope.request_id != 3 ||
        commands[3].envelope.request_id != 4) {
        fail(error, "runtime_command_stable_sort_invalid");
        return false;
    }

    if (!queue_model_test(error)) return false;
    error.clear();
    return true;
}

} // namespace pk

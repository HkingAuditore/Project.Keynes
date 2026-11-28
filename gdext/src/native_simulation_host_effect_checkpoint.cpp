#include "native_simulation_host.h"
#include "runtime_checkpoint_wire.h"

namespace pk {
namespace {
constexpr uint32_t EFFECT_TRANSPORT_MARKER = 0x32515445u; // ETQ2

constexpr auto instance_fields = [](auto &io, auto &entry) {
    auto &value = entry.input;
    return io.field(entry.sequence) && io.field(entry.effective_day) &&
        io.field(value.instance_id) &&
        io.field(value.generation) && io.field(value.program_id) &&
        io.field(value.source_type) && io.field(value.source_id) &&
        io.field(value.source_handle) && io.field(value.target_handle) &&
        io.field(value.target_generation) && io.field(value.level) &&
        io.field(value.next_due_day) && io.field(value.expires_day) &&
        io.field(value.magnitude_scale_q16) && io.field(value.latched) &&
        io.field(value.active);
};

constexpr auto metric_fields = [](auto &io, auto &entry) {
    return io.field(entry.sequence) && io.field(entry.effective_day) &&
        io.field(entry.instance_id) && io.field(entry.generation) &&
        io.field(entry.metric_id) && io.field(entry.revision) && io.field(entry.value);
};

constexpr auto removal_fields = [](auto &io, auto &entry) {
    return io.field(entry.sequence) && io.field(entry.effective_day) &&
        io.field(entry.instance_id) && io.field(entry.generation);
};

constexpr auto ack_fields = [](auto &io, auto &entry) {
    return io.field(entry.request_id) && io.field(entry.transaction_id) &&
        io.field(entry.target_handle) && io.field(entry.target_generation) &&
        io.field(entry.domain) && io.field(entry.code) &&
        io.field(entry.effective_day) && io.field(entry.producer_id) &&
        io.field(entry.sequence) && io.field(entry.technology_flags);
};
} // namespace

std::vector<uint8_t> NativeSimulationHost::encode_effect_transport() const {
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    CheckpointWriter out;
    out.field(EFFECT_TRANSPORT_MARKER);
    out.field(_effect_transport_sequence);
    out.rows(_effect_instance_queue, instance_fields);
    out.rows(_effect_metric_queue, metric_fields);
    out.rows(_effect_remove_queue, removal_fields);
    out.rows(_effect_acks, ack_fields);
    return std::move(out.bytes);
}

bool NativeSimulationHost::try_restore_effect_transport(
        const std::vector<uint8_t> &bytes, std::string &error) {
    error.clear();
    CheckpointReader in{bytes.data(), bytes.size()};
    uint32_t marker = 0;
    uint64_t sequence = 0;
    decltype(_effect_instance_queue) instances;
    decltype(_effect_metric_queue) metrics;
    decltype(_effect_remove_queue) removals;
    decltype(_effect_acks) acks;
    bool valid = in.field(marker) && marker == EFFECT_TRANSPORT_MARKER &&
        in.field(sequence) && in.rows(instances, instance_fields) &&
        in.rows(metrics, metric_fields) && in.rows(removals, removal_fields) &&
        in.rows(acks, ack_fields) && in.cursor == in.size;
    if (valid) {
        for (const auto &entry : instances) {
            if (entry.effective_day < 0) { valid = false; break; }
        }
    }
    if (valid) {
        for (const auto &entry : metrics) {
            if (entry.effective_day < 0) { valid = false; break; }
        }
    }
    if (valid) {
        for (const auto &entry : removals) {
            if (entry.effective_day < 0) { valid = false; break; }
        }
    }
    if (!valid) {
        error = "effect_transport_continuation_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    _effect_transport_sequence = sequence;
    _effect_instance_queue = std::move(instances);
    _effect_metric_queue = std::move(metrics);
    _effect_remove_queue = std::move(removals);
    _effect_acks = std::move(acks);
    _effect_intents.clear();
    return true;
}

void NativeSimulationHost::restore_effect_transport(const std::vector<uint8_t> &bytes) {
    std::string error;
    if (try_restore_effect_transport(bytes, error)) return;
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    _effect_transport_sequence = 0;
    _effect_instance_queue.clear();
    _effect_metric_queue.clear();
    _effect_remove_queue.clear();
    _effect_acks.clear();
    _effect_intents.clear();
}
} // namespace pk

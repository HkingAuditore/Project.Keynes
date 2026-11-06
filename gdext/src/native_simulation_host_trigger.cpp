#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "native_simulation_host_support.h"

namespace pk {

bool NativeSimulationHost::configure_trigger_pod(
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    return _domain_authority_runner.configure_trigger_pod(catalog, error);
}

bool NativeSimulationHost::queue_trigger_pod_command(
        const RuntimeTriggerCommand &command, std::string &error) {
    return _domain_authority_runner.queue_trigger_command(command, error);
}

void NativeSimulationHost::forward_committed_events_to_trigger(int64_t day) {
    if ((_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) == 0u ||
        !_domain_authority_runner.trigger_pod_configured()) {
        return;
    }
    // An invalid ingest fails the whole Trigger day, so rows outside the
    // catalog are skipped here. The per-day cap stays under the command queue
    // and pending-event capacities; the rest carries over to the next day.
    constexpr uint32_t MAX_FORWARD_PER_DAY = 2048u;
    const RuntimeTriggerPodCatalog &catalog = _domain_authority_runner.trigger_catalog();
    uint32_t forwarded = 0;
    const auto events_view = _events_authority.copy_committed_view();
    assert(_events_authority.observe_trigger_view(events_view));
    for (const RuntimeEventsRecord &record : events_view.events) {
        if (record.event_id <= _trigger_forwarded_event_id) continue;
        if (forwarded >= MAX_FORWARD_PER_DAY) break;
        if (record.source < 0 || record.source >= catalog.source_count ||
            record.type < 0 || record.type >= catalog.event_type_span) {
            _trigger_forwarded_event_id = record.event_id;
            continue;
        }
        RuntimeTriggerCommand command;
        command.request_id = 0xE7F0000000000000ull | (_trigger_forward_sequence + 1u);
        command.producer_id = 3u;
        command.sequence = _trigger_forward_sequence + 1u;
        command.opcode = RuntimeTriggerCommandOpcode::INGEST_EVENT;
        command.requested_day = day;
        command.effective_day = day + 1;
        command.event.source_id = record.source;
        command.event.event_id = record.event_id;
        command.event.day = std::max<int64_t>(0, record.tick);
        command.event.event_type = record.type;
        command.event.payload_schema = record.payload_schema;
        command.event.entity_handle = record.entity_handle != 0
            ? record.entity_handle
            : static_cast<uint64_t>(std::max(0, record.entity_id));
        command.event.group_handle = static_cast<uint64_t>(std::max(0, record.cell_idx));
        command.event.value = record.value_i64;
        command.event.payload = {record.payload_i0, record.payload_i1,
                                 record.payload_i2, record.payload_i3};
        std::string queue_error;
        if (!_domain_authority_runner.queue_trigger_command(command, queue_error)) break;
        ++_trigger_forward_sequence;
        _trigger_forwarded_event_id = record.event_id;
        ++forwarded;
    }
}

bool NativeSimulationHost::try_acquire_trigger_snapshot(uint64_t after_generation,
                                                        uint32_t &slot) {
    return _trigger_snapshots.try_acquire_latest(after_generation, slot);
}

const RuntimeTriggerSnapshot &NativeSimulationHost::trigger_snapshot_buffer(
        uint32_t slot) const {
    return _trigger_snapshots.read_buffer(slot);
}

void NativeSimulationHost::release_trigger_snapshot(uint32_t slot) {
    _trigger_snapshots.release(slot);
}

bool NativeSimulationHost::poll_trigger_pod_intent(RuntimeDomainIntent &intent) {
    std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
    if (_trigger_intents.empty()) return false;
    const RuntimeTriggerEffectIntent source = _trigger_intents.front();
    _trigger_intents.pop_front();
    intent = RuntimeDomainIntent{};
    // Trigger identifies an effect intent by its own effect id. The ACK barrier
    // matches on (transaction_id, effective_day), so both must survive the
    // round trip through the main thread untouched.
    intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
    intent.source_id = static_cast<uint64_t>(source.id);
    intent.request_id = static_cast<uint64_t>(source.id);
    intent.target_domain = static_cast<uint16_t>(source.domain);
    intent.opcode = static_cast<uint16_t>(source.opcode);
    intent.target_handle = source.target_handle;
    intent.target_generation = source.target_generation;
    intent.effective_day = source.effective_day;
    intent.value = source.resolved_value;
    intent.duration_days = source.duration_days;
    intent.stacks = source.stacks;
    intent.payload = source.payload;
    intent.flags = RUNTIME_DOMAIN_INTENT_REQUIRES_ACK;
    return true;
}

bool NativeSimulationHost::submit_trigger_pod_ack(const RuntimeDomainAck &ack,
                                                  std::string &error) {
    error.clear();
    if (ack.transaction_id == 0) {
        error = "trigger_ack_transaction_missing";
        return false;
    }
    std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
    if (_trigger_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "trigger_ack_capacity_exceeded";
        return false;
    }
    _trigger_acks.push_back(ack);
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
    return true;
}

RuntimeTriggerPodDiagnostics NativeSimulationHost::trigger_pod_diagnostics() const {
    return _domain_authority_runner.trigger_pod_diagnostics();
}

bool NativeSimulationHost::set_trigger_reference_frame(
        int64_t day, uint64_t input_hash, uint64_t state_hash,
        uint64_t effect_hash, std::string &error) {
    return _domain_authority_runner.set_trigger_reference_frame(
        day, input_hash, state_hash, effect_hash, error);
}

const RuntimeTriggerPodCatalog &NativeSimulationHost::trigger_pod_catalog() const {
    return _domain_authority_runner.trigger_catalog();
}

bool NativeSimulationHost::encode_trigger_pod_save(std::vector<uint8_t> &bytes,
                                                   std::string &error) const {
    RuntimeTriggerPodSaveSection section;
    if (!_domain_authority_runner.encode_trigger_save(section, error)) return false;
    bytes = std::move(section.payload);
    return true;
}

bool NativeSimulationHost::restore_trigger_pod_save(const uint8_t *bytes,
                                                    size_t size,
                                                    std::string &error) {
    // TPD1 has a fixed header through state_hash plus the four bounded
    // capacity scalars: 80 bytes before any vector payload is decoded.
    if (bytes == nullptr || size < 80u) {
        error = "trigger_save_truncated";
        return false;
    }
    RuntimeTriggerPodSaveSection section;
    section.descriptor.domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
    section.descriptor.version = RUNTIME_TRIGGER_POD_ABI_VERSION;
    section.descriptor.payload_size = static_cast<uint32_t>(size);
    section.payload.assign(bytes, bytes + size);
    const auto read_u64 = [bytes, size](size_t offset) {
        uint64_t value = 0;
        if (offset + sizeof(value) > size) return value;
        for (size_t i = 0; i < sizeof(value); ++i)
            value |= static_cast<uint64_t>(bytes[offset + i]) << (i * 8u);
        return value;
    };
    const auto read_i64 = [&read_u64](size_t offset) {
        const uint64_t bits = read_u64(offset);
        int64_t value = 0;
        std::memcpy(&value, &bits, sizeof(value));
        return value;
    };
    section.catalog_hash = read_u64(12u);
    section.generation = read_u64(20u);
    section.committed_day = read_i64(28u);
    section.state_hash = read_u64(36u);
    section.descriptor.checksum = 1469598103934665603ull;
    for (const uint8_t byte : section.payload) {
        section.descriptor.checksum ^= static_cast<uint64_t>(byte);
        section.descriptor.checksum *= 1099511628211ull;
    }
    const auto &catalog = _domain_authority_runner.trigger_catalog();
    return _domain_authority_runner.restore_trigger_save(section, catalog, error);
}

void NativeSimulationHost::publish_trigger_intents_locked(
        const std::vector<RuntimeTriggerEffectIntent> &intents) {
    for (const RuntimeTriggerEffectIntent &intent : intents) {
        if (intent.id <= _trigger_published_intent_id) continue;
        if (_trigger_intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) break;
        _trigger_intents.push_back(intent);
        _trigger_published_intent_id = intent.id;
    }
}

uint32_t NativeSimulationHost::ack_trigger_intents_in_worker(int64_t day) {
    std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
    uint32_t acked = 0;
    while (!_trigger_intents.empty()) {
        if (_trigger_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) break;
        const RuntimeTriggerEffectIntent intent = _trigger_intents.front();
        _trigger_intents.pop_front();
        RuntimeDomainAck ack;
        // ack_matches() keys on (transaction_id, effective_day, OK) only; the
        // domain tag is carried for the diagnostics/report side.
        ack.domain = static_cast<uint16_t>(intent.domain);
        ack.code = RuntimeDomainAckCode::OK;
        ack.request_id = static_cast<uint64_t>(intent.id);
        ack.transaction_id = static_cast<uint64_t>(intent.id);
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.effective_day = intent.effective_day;
        _trigger_acks.push_back(ack);
        ++acked;
    }
    (void)day;
    return acked;
}

bool NativeSimulationHost::execute_trigger_worker_stage(
        int64_t day, uint64_t input_generation, RuntimeDayCommit &commit,
        std::string &error) {
    error.clear();
    if (!_domain_authority_runner.trigger_pod_configured()) {
        error = "trigger_pod_not_configured";
        return false;
    }
    // The ACK deque is copied, not drained: an incomplete barrier discards the
    // plan and replays the same intent ids next visit, so an ACK consumed by a
    // failed attempt would be lost forever.
    std::vector<RuntimeDomainAck> acks;
    {
        std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
        acks.assign(_trigger_acks.begin(), _trigger_acks.end());
    }
    const auto plan_started = std::chrono::steady_clock::now();
    std::vector<RuntimeTriggerEffectIntent> intents;
    thread_local RuntimeTriggerSnapshot snapshot;
    uint32_t required_ack_count = 0;
    uint64_t state_hash = 0;
    double replay_ms = 0.0;
    const bool ok = _domain_authority_runner.run_trigger_active_day(
        day, input_generation, acks, intents, snapshot, required_ack_count,
        state_hash, replay_ms, error);
    {
        std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
        // Publish before deciding on success: a plan whose ACK barrier is
        // incomplete is exactly the case that needs its intents delivered.
        publish_trigger_intents_locked(intents);
        if (ok) _trigger_acks.clear();
    }
    _trigger_pod_plan_ms.store(
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count(),
        std::memory_order_release);
    _trigger_pod_replay_ms.store(replay_ms, std::memory_order_release);
    _trigger_pod_intent_count.store(
        static_cast<uint32_t>(intents.size()), std::memory_order_release);
    _trigger_pod_ack_count.store(
        static_cast<uint32_t>(acks.size()), std::memory_order_release);
    if (!ok) return false;
    _trigger_pod_state_hash.store(state_hash, std::memory_order_release);
    _trigger_pod_snapshot_generation.store(snapshot.generation,
                                           std::memory_order_release);
    uint32_t trigger_slot = 0;
    if (_trigger_snapshots.try_begin_write(trigger_slot)) {
        _trigger_snapshots.write_buffer(trigger_slot) = snapshot;
        _trigger_snapshots.publish(trigger_slot);
    }
    commit.dirty_families |= RUNTIME_DIRTY_EVENTS;
    commit.work_units += intents.size() + snapshot.states.size();
    return true;
}

} // namespace pk

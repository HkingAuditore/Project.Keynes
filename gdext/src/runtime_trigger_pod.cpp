#include "runtime_resolve_contract.h"
#include "runtime_trigger_pod.h"
#include "runtime_trigger_kernel.h"
#include "economy_cost_probe.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <cstring>
#include <limits>
#include <set>
#include <tuple>
#include <type_traits>

namespace pk {
namespace {

constexpr uint32_t SAVE_MAGIC = 0x31445054u; // TPD1
constexpr uint32_t SAVE_END = 0x31444e45u; // END1
constexpr uint64_t FNV_OFFSET = 1469598103934665603ULL;
constexpr uint64_t FNV_PRIME = 1099511628211ULL;
constexpr uint64_t fnv_prime_power(unsigned exponent) {
    uint64_t value = 1;
    for (unsigned i = 0; i < exponent; ++i) value *= FNV_PRIME;
    return value;
}
constexpr uint32_t MAX_SAVE_BYTES = 64u * 1024u * 1024u;

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    using U = std::make_unsigned_t<T>;
    U bits{};
    static_assert(sizeof(U) == sizeof(T));
    std::memcpy(&bits, &value, sizeof(bits));
    for (size_t i = 0; i < sizeof(U); ++i)
        out.push_back(static_cast<uint8_t>(bits >> (i * 8u)));
}

template <typename T>
bool read_le(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    if (data == nullptr || cursor > size || sizeof(T) > size - cursor) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(U); ++i)
        bits |= static_cast<U>(data[cursor + i]) << (i * 8u);
    std::memcpy(&value, &bits, sizeof(value));
    cursor += sizeof(T);
    return true;
}

uint64_t mix(uint64_t hash, const void *data, size_t size) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

template <typename T>
uint64_t mix_value(uint64_t hash, T value) {
    return mix(hash, &value, sizeof(value));
}

bool valid_event(const RuntimeTriggerEvent &event,
                 const RuntimeTriggerPodCatalog &catalog) {
    return event.source_id >= 0 && event.source_id < catalog.source_count &&
        event.event_id > 0 && event.event_type >= 0 &&
        event.event_type < catalog.event_type_span && event.day >= 0;
}

bool ack_matches(const RuntimeDomainAck &ack, const RuntimeTriggerEffectIntent &intent) {
    return ack.transaction_id == static_cast<uint64_t>(intent.id) &&
        ack.effective_day == intent.effective_day &&
        ack.code == RuntimeDomainAckCode::OK;
}

bool command_less(const RuntimeTriggerCommand &a,
                  const RuntimeTriggerCommand &b) noexcept {
    return ResolveOrder{a.effective_day, a.producer_id, a.sequence, a.request_id} <
        ResolveOrder{b.effective_day, b.producer_id, b.sequence, b.request_id};
}

bool state_less(const RuntimeTriggerPodSnapshotState &a,
                const RuntimeTriggerPodSnapshotState &b) noexcept {
    return std::tie(a.trigger_id, a.target_handle, a.target_generation) <
        std::tie(b.trigger_id, b.target_handle, b.target_generation);
}

bool binding_less(const RuntimeTriggerBranchBinding &a,
                  const RuntimeTriggerBranchBinding &b) noexcept {
    return std::tie(a.trigger_id, a.cell, a.branch_handle) <
        std::tie(b.trigger_id, b.cell, b.branch_handle);
}

bool event_less(const RuntimeTriggerEvent &a,
                const RuntimeTriggerEvent &b) noexcept {
    return std::tie(a.day, a.source_id, a.event_id) <
        std::tie(b.day, b.source_id, b.event_id);
}

bool effect_less(const RuntimeTriggerEffectIntent &a,
                 const RuntimeTriggerEffectIntent &b) noexcept {
    return std::tie(a.effective_day, a.source_priority, a.trigger_id,
                    a.target_handle, a.fire_sequence, a.id) <
        std::tie(b.effective_day, b.source_priority, b.trigger_id,
                 b.target_handle, b.fire_sequence, b.id);
}

void canonicalize_snapshot_in_place(RuntimeTriggerSnapshot &value,
                                    bool include_generation) {
    if (!include_generation) value.generation = 0;
    if (!std::is_sorted(value.states.begin(), value.states.end(), state_less)) {
        std::stable_sort(value.states.begin(), value.states.end(), state_less);
    }
    if (!std::is_sorted(value.branch_bindings.begin(),
                        value.branch_bindings.end(), binding_less)) {
        std::stable_sort(value.branch_bindings.begin(),
                         value.branch_bindings.end(), binding_less);
    }
    if (!std::is_sorted(value.pending_events.begin(),
                        value.pending_events.end(), event_less)) {
        std::stable_sort(value.pending_events.begin(),
                         value.pending_events.end(), event_less);
    }
    if (!std::is_sorted(value.pending_effects.begin(),
                        value.pending_effects.end(), effect_less)) {
        std::stable_sort(value.pending_effects.begin(),
                         value.pending_effects.end(), effect_less);
    }
}

bool is_snapshot_canonical(const RuntimeTriggerSnapshot &value) {
    return std::is_sorted(value.states.begin(), value.states.end(), state_less) &&
        std::is_sorted(value.branch_bindings.begin(), value.branch_bindings.end(),
                       binding_less) &&
        std::is_sorted(value.pending_events.begin(), value.pending_events.end(),
                       event_less) &&
        std::is_sorted(value.pending_effects.begin(), value.pending_effects.end(),
                       effect_less);
}

void copy_trigger_snapshot_reuse_capacity(RuntimeTriggerSnapshot &dst,
                                          const RuntimeTriggerSnapshot &src) {
    dst.generation = src.generation;
    dst.catalog_hash = src.catalog_hash;
    dst.committed_day = src.committed_day;
    dst.current_day = src.current_day;
    dst.next_effect_id = src.next_effect_id;
    dst.acked_effect_id = src.acked_effect_id;
    dst.source_cursor = src.source_cursor;
    dst.source_needs_resync = src.source_needs_resync;
    dst.source_gap_begin = src.source_gap_begin;
    dst.source_gap_end = src.source_gap_end;
    dst.enabled = src.enabled;
    dst.branch_bindings = src.branch_bindings;
    dst.pending_events = src.pending_events;
    dst.pending_effects = src.pending_effects;
    dst.states.resize(src.states.size());
    for (size_t i = 0; i < src.states.size(); ++i) {
        RuntimeTriggerPodSnapshotState &d = dst.states[i];
        const RuntimeTriggerPodSnapshotState &s = src.states[i];
        d.trigger_id = s.trigger_id;
        d.target_handle = s.target_handle;
        d.target_generation = s.target_generation;
        d.accumulator = s.accumulator;
        d.remainder = s.remainder;
        d.last_event_id = s.last_event_id;
        d.fire_sequence = s.fire_sequence;
        d.cooldown_until = s.cooldown_until;
        d.window_start_day = s.window_start_day;
        d.last_observed = s.last_observed;
        d.last_sample_day = s.last_sample_day;
        d.completed = s.completed;
        d.initialized = s.initialized;
        d.needs_resync = s.needs_resync;
        d.distinct_keys = s.distinct_keys;
    }
}

void hash_snapshot_dual(const RuntimeTriggerSnapshot &snapshot,
                        uint64_t &hash_with_gen, uint64_t &hash_zero_gen) {
    EconomyCostProbe hash_cost("trigger.hash_dual", snapshot.current_day, snapshot.states.size());
    static const bool scalar_distinct = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_TRIGGER_HASH_SCALAR);
        return value && std::strcmp(value, "1") == 0;
    }();
    static const bool little_endian = [] {
        const uint64_t value = 1;
        return *reinterpret_cast<const uint8_t *>(&value) == 1;
    }();
    uint64_t empty_keys = 0;
    uint64_t h1 = mix_value(FNV_OFFSET, snapshot.generation);
    uint64_t h0 = mix_value(FNV_OFFSET, uint64_t{0});
    auto mix2_bytes = [&](const void *data, size_t size) {
        const auto *bytes = static_cast<const uint8_t *>(data);
        for (size_t i = 0; i < size; ++i) {
            const uint8_t b = bytes[i];
            h1 = (h1 ^ b) * FNV_PRIME;
            h0 = (h0 ^ b) * FNV_PRIME;
        }
    };
    auto mix2 = [&](auto value) {
        mix2_bytes(&value, sizeof(value));
    };
    mix2(snapshot.catalog_hash);
    mix2(snapshot.committed_day);
    mix2(snapshot.current_day);
    mix2(snapshot.next_effect_id);
    mix2(snapshot.acked_effect_id);
    if (!snapshot.source_cursor.empty())
        mix2_bytes(snapshot.source_cursor.data(), snapshot.source_cursor.size() * sizeof(int64_t));
    if (!snapshot.source_needs_resync.empty())
        mix2_bytes(snapshot.source_needs_resync.data(), snapshot.source_needs_resync.size());
    if (!snapshot.source_gap_begin.empty())
        mix2_bytes(snapshot.source_gap_begin.data(), snapshot.source_gap_begin.size() * sizeof(int64_t));
    if (!snapshot.source_gap_end.empty())
        mix2_bytes(snapshot.source_gap_end.data(), snapshot.source_gap_end.size() * sizeof(int64_t));
    if (!snapshot.enabled.empty())
        mix2_bytes(snapshot.enabled.data(), snapshot.enabled.size());
    for (const RuntimeTriggerPodSnapshotState &state : snapshot.states) {
        mix2(state.trigger_id);
        mix2(state.target_handle);
        mix2(state.target_generation);
        mix2(state.accumulator);
        mix2(state.remainder);
        mix2(state.last_event_id);
        mix2(state.fire_sequence);
        mix2(state.cooldown_until);
        mix2(state.window_start_day);
        mix2(state.last_observed);
        mix2(state.last_sample_day);
        mix2(state.completed);
        mix2(state.initialized);
        mix2(state.needs_resync);
        if (!state.distinct_keys.empty()) {
            if (scalar_distinct) {
                mix2_bytes(state.distinct_keys.data(),
                           state.distinct_keys.size() * sizeof(int64_t));
            } else for (const int64_t key : state.distinct_keys) {
                if (key == std::numeric_limits<int64_t>::min()) {
                    // The sentinel contains seven zero bytes and one 0x80.
                    // FNV-1a over a zero byte is exactly h * prime. Combine
                    // only that run, preserving every byte and the full hash.
                    if (little_endian) {
                        h1 = (h1 * fnv_prime_power(7) ^ uint64_t{0x80}) * FNV_PRIME;
                        h0 = (h0 * fnv_prime_power(7) ^ uint64_t{0x80}) * FNV_PRIME;
                    } else {
                        h1 = (h1 ^ uint64_t{0x80}) * fnv_prime_power(8);
                        h0 = (h0 ^ uint64_t{0x80}) * fnv_prime_power(8);
                    }
                    ++empty_keys;
                } else {
                    mix2(key);
                }
            }
        }
    }
    for (const RuntimeTriggerBranchBinding &binding : snapshot.branch_bindings) {
        mix2(binding.trigger_id); mix2(binding.branch_handle);
        mix2(binding.cell); mix2(binding.reward_target);
        mix2(binding.enabled);
    }
    for (const RuntimeTriggerEvent &event : snapshot.pending_events) {
        mix2(event.source_id); mix2(event.event_id);
        mix2(event.day); mix2(event.event_type);
        mix2(event.payload_schema); mix2(event.entity_handle);
        mix2(event.group_handle); mix2(event.value);
        mix2_bytes(event.payload.data(), event.payload.size() * sizeof(int64_t));
        mix2(event.snapshot);
    }
    for (const RuntimeTriggerEffectIntent &effect : snapshot.pending_effects) {
        mix2(effect.id); mix2(effect.effective_day);
        mix2(effect.source_priority); mix2(effect.trigger_id);
        mix2(effect.effect_definition_id); mix2(effect.target_handle);
        mix2(effect.target_generation); mix2(effect.fire_sequence);
        mix2(effect.action); mix2(effect.domain);
        mix2(effect.opcode); mix2(effect.resolved_value);
        mix2(effect.duration_days); mix2(effect.stacks);
        mix2_bytes(effect.payload.data(), effect.payload.size() * sizeof(int64_t));
    }
    hash_with_gen = h1;
    hash_zero_gen = h0;
    EconomyCostProbe::record("trigger.hash_empty_keys", snapshot.current_day, 0.0, empty_keys);
}

RuntimeTriggerSnapshot canonicalize_snapshot(const RuntimeTriggerSnapshot &source,
                                             bool include_generation) {
    RuntimeTriggerSnapshot value = source;
    canonicalize_snapshot_in_place(value, include_generation);
    return value;
}

bool valid_command_opcode(RuntimeTriggerCommandOpcode opcode) noexcept {
    const uint16_t value = static_cast<uint16_t>(opcode);
    return value >= static_cast<uint16_t>(RuntimeTriggerCommandOpcode::INGEST_EVENT) &&
        value <= static_cast<uint16_t>(RuntimeTriggerCommandOpcode::REPLAY_COMPLETED_RESEARCH_SIGNAL);
}

int32_t find_or_create_state(RuntimeTriggerSnapshot &state,
                             const RuntimeTriggerPodCatalog &catalog,
                             int32_t trigger_id, uint64_t target,
                             std::string &error) {
    for (int32_t index = 0; index < static_cast<int32_t>(state.states.size()); ++index) {
        const RuntimeTriggerPodSnapshotState &candidate = state.states[index];
        if (candidate.trigger_id == trigger_id && candidate.target_handle == target)
            return index;
    }
    if (state.states.size() >= static_cast<size_t>(catalog.max_states)) {
        error = "trigger_state_capacity_exhausted";
        return -1;
    }
    RuntimeTriggerPodSnapshotState created;
    created.trigger_id = trigger_id;
    created.target_handle = target;
    created.target_generation = static_cast<uint32_t>(target >> 32u);
    created.distinct_keys.assign(catalog.distinct_capacity,
                                 std::numeric_limits<int64_t>::min());
    state.states.push_back(std::move(created));
    return static_cast<int32_t>(state.states.size() - 1u);
}

bool validate_command_shape(const RuntimeTriggerCommand &command,
                            const RuntimeTriggerPodCatalog &catalog,
                            std::string &error) {
    error.clear();
    if (command.request_id == 0 || command.sequence == 0 ||
        command.requested_day < 0 || command.effective_day < 0 ||
        command.effective_day < command.requested_day ||
        !valid_command_opcode(command.opcode)) {
        error = "trigger_command_header_invalid";
        return false;
    }
    switch (command.opcode) {
        case RuntimeTriggerCommandOpcode::INGEST_EVENT:
        case RuntimeTriggerCommandOpcode::INGEST_SNAPSHOT:
            if (!valid_event(command.event, catalog) || command.resync_count != 0) {
                error = "trigger_event_invalid";
                return false;
            }
            break;
        case RuntimeTriggerCommandOpcode::SET_ENABLED:
            if (command.trigger_id < 0 ||
                command.trigger_id >= static_cast<int32_t>(catalog.definitions.size()) ||
                command.resync_count != 0) {
                error = "trigger_id_invalid";
                return false;
            }
            break;
        case RuntimeTriggerCommandOpcode::RECONCILE_BRANCH_BINDING:
            if (command.binding.trigger_id < 0 ||
                command.binding.trigger_id >= static_cast<int32_t>(catalog.definitions.size()) ||
                catalog.definitions[command.binding.trigger_id].dynamic_binding == 0 ||
                command.binding.branch_handle == 0 || command.binding.cell < 0 ||
                command.binding.reward_target < 0 || command.binding.reward_target > 1 ||
                command.resync_count != 0) {
                error = "trigger_branch_binding_invalid";
                return false;
            }
            break;
        case RuntimeTriggerCommandOpcode::RESYNC_SOURCE:
            if (command.source_id < 0 || command.source_id >= catalog.source_count ||
                command.cursor < 0 || command.resync_count > RUNTIME_TRIGGER_RESYNC_CAPACITY) {
                error = "trigger_resync_source_invalid";
                return false;
            }
            for (uint32_t i = 0; i < command.resync_count; ++i) {
                const int32_t trigger_id = command.resync_trigger_ids[i];
                if (trigger_id < 0 ||
                    trigger_id >= static_cast<int32_t>(catalog.definitions.size()) ||
                    catalog.definitions[trigger_id].source_id != command.source_id) {
                    error = "trigger_resync_payload_invalid";
                    return false;
                }
            }
            break;
        case RuntimeTriggerCommandOpcode::ACK_EFFECTS:
            if (command.ack_up_to_effect_id < 0 || command.resync_count != 0) {
                error = "trigger_ack_invalid";
                return false;
            }
            break;
        case RuntimeTriggerCommandOpcode::ACK_EFFECT_IDS:
            if (command.resync_count == 0 || command.resync_count > RUNTIME_TRIGGER_RESYNC_CAPACITY) {
                error = "trigger_ack_ids_invalid"; return false;
            }
            for (uint32_t i = 0; i < command.resync_count; ++i)
                if (command.resync_values[i] <= 0) {
                    error = "trigger_ack_ids_invalid"; return false;
                }
            break;
        case RuntimeTriggerCommandOpcode::REPLAY_COMPLETED_RESEARCH_SIGNAL:
            if (command.trigger_id < 0 || command.trigger_id >= static_cast<int32_t>(catalog.definitions.size()) ||
                command.event.entity_handle == 0 || command.event.group_handle > INT32_MAX ||
                command.effective_day < 1 || command.resync_count != 0) {
                error = "trigger_research_replay_invalid"; return false;
            }
            break;
        default:
            error = "trigger_command_opcode_invalid";
            return false;
    }
    return true;
}

void copy_reason(char (&dst)[64], const std::string &reason) {
    std::fill(std::begin(dst), std::end(dst), '\0');
    const size_t count = std::min(reason.size(), sizeof(dst) - 1u);
    std::memcpy(dst, reason.data(), count);
}

void copy_reason32(char (&dst)[32], const char *reason) {
    std::fill(std::begin(dst), std::end(dst), '\0');
    if (reason == nullptr) return;
    const size_t count = std::min(std::strlen(reason), sizeof(dst) - 1u);
    std::memcpy(dst, reason, count);
}

bool read_count(const uint8_t *data, size_t size, size_t &cursor,
                uint32_t &count, uint32_t capacity) {
    return read_le(data, size, cursor, count) && count <= capacity;
}

void append_event(std::vector<uint8_t> &payload, const RuntimeTriggerEvent &event) {
    append_le<int32_t>(payload, event.source_id);
    append_le<int64_t>(payload, event.event_id);
    append_le<int64_t>(payload, event.day);
    append_le<int32_t>(payload, event.event_type);
    append_le<int32_t>(payload, event.payload_schema);
    append_le<uint64_t>(payload, event.entity_handle);
    append_le<uint64_t>(payload, event.group_handle);
    append_le<int64_t>(payload, event.value);
    for (const int64_t value : event.payload) append_le<int64_t>(payload, value);
    append_le<uint8_t>(payload, event.snapshot);
}

bool read_event(const uint8_t *data, size_t size, size_t &cursor,
                RuntimeTriggerEvent &event) {
    return read_le(data, size, cursor, event.source_id) &&
        read_le(data, size, cursor, event.event_id) &&
        read_le(data, size, cursor, event.day) &&
        read_le(data, size, cursor, event.event_type) &&
        read_le(data, size, cursor, event.payload_schema) &&
        read_le(data, size, cursor, event.entity_handle) &&
        read_le(data, size, cursor, event.group_handle) &&
        read_le(data, size, cursor, event.value) &&
        read_le(data, size, cursor, event.payload[0]) &&
        read_le(data, size, cursor, event.payload[1]) &&
        read_le(data, size, cursor, event.payload[2]) &&
        read_le(data, size, cursor, event.payload[3]) &&
        read_le(data, size, cursor, event.snapshot);
}

void append_binding(std::vector<uint8_t> &payload,
                    const RuntimeTriggerBranchBinding &binding) {
    append_le<int32_t>(payload, binding.trigger_id);
    append_le<uint64_t>(payload, binding.branch_handle);
    append_le<int32_t>(payload, binding.cell);
    append_le<int32_t>(payload, binding.reward_target);
    append_le<uint8_t>(payload, binding.enabled);
}

bool read_binding(const uint8_t *data, size_t size, size_t &cursor,
                  RuntimeTriggerBranchBinding &binding) {
    return read_le(data, size, cursor, binding.trigger_id) &&
        read_le(data, size, cursor, binding.branch_handle) &&
        read_le(data, size, cursor, binding.cell) &&
        read_le(data, size, cursor, binding.reward_target) &&
        read_le(data, size, cursor, binding.enabled);
}

void append_state(std::vector<uint8_t> &payload, const RuntimeTriggerPodSnapshotState &state,
                  int32_t distinct_capacity) {
    append_le<int32_t>(payload, state.trigger_id);
    append_le<uint64_t>(payload, state.target_handle);
    append_le<uint32_t>(payload, state.target_generation);
    append_le<int64_t>(payload, state.accumulator);
    append_le<int64_t>(payload, state.remainder);
    append_le<int64_t>(payload, state.last_event_id);
    append_le<uint64_t>(payload, state.fire_sequence);
    append_le<int64_t>(payload, state.cooldown_until);
    append_le<int64_t>(payload, state.window_start_day);
    append_le<int64_t>(payload, state.last_observed);
    append_le<int64_t>(payload, state.last_sample_day);
    append_le<uint8_t>(payload, state.completed);
    append_le<uint8_t>(payload, state.initialized);
    append_le<uint8_t>(payload, state.needs_resync);
    for (int32_t i = 0; i < distinct_capacity; ++i) {
        const int64_t value = i < static_cast<int32_t>(state.distinct_keys.size())
            ? state.distinct_keys[i] : std::numeric_limits<int64_t>::min();
        append_le<int64_t>(payload, value);
    }
}

bool read_state(const uint8_t *data, size_t size, size_t &cursor,
                RuntimeTriggerPodSnapshotState &state, int32_t distinct_capacity) {
    if (!read_le(data, size, cursor, state.trigger_id) ||
        !read_le(data, size, cursor, state.target_handle) ||
        !read_le(data, size, cursor, state.target_generation) ||
        !read_le(data, size, cursor, state.accumulator) ||
        !read_le(data, size, cursor, state.remainder) ||
        !read_le(data, size, cursor, state.last_event_id) ||
        !read_le(data, size, cursor, state.fire_sequence) ||
        !read_le(data, size, cursor, state.cooldown_until) ||
        !read_le(data, size, cursor, state.window_start_day) ||
        !read_le(data, size, cursor, state.last_observed) ||
        !read_le(data, size, cursor, state.last_sample_day) ||
        !read_le(data, size, cursor, state.completed) ||
        !read_le(data, size, cursor, state.initialized) ||
        !read_le(data, size, cursor, state.needs_resync)) return false;
    state.distinct_keys.resize(distinct_capacity);
    for (int32_t i = 0; i < distinct_capacity; ++i)
        if (!read_le(data, size, cursor, state.distinct_keys[i])) return false;
    return true;
}

void append_effect(std::vector<uint8_t> &payload,
                   const RuntimeTriggerEffectIntent &effect) {
    append_le<int64_t>(payload, effect.id);
    append_le<int64_t>(payload, effect.effective_day);
    append_le<int32_t>(payload, effect.source_priority);
    append_le<int32_t>(payload, effect.trigger_id);
    append_le<int32_t>(payload, effect.effect_definition_id);
    append_le<uint64_t>(payload, effect.target_handle);
    append_le<uint32_t>(payload, effect.target_generation);
    append_le<uint64_t>(payload, effect.fire_sequence);
    append_le<int32_t>(payload, effect.action);
    append_le<int32_t>(payload, effect.domain);
    append_le<int32_t>(payload, effect.opcode);
    append_le<int64_t>(payload, effect.resolved_value);
    append_le<int32_t>(payload, effect.duration_days);
    append_le<int32_t>(payload, effect.stacks);
    for (const int64_t value : effect.payload) append_le<int64_t>(payload, value);
}

bool read_effect(const uint8_t *data, size_t size, size_t &cursor,
                 RuntimeTriggerEffectIntent &effect) {
    return read_le(data, size, cursor, effect.id) &&
        read_le(data, size, cursor, effect.effective_day) &&
        read_le(data, size, cursor, effect.source_priority) &&
        read_le(data, size, cursor, effect.trigger_id) &&
        read_le(data, size, cursor, effect.effect_definition_id) &&
        read_le(data, size, cursor, effect.target_handle) &&
        read_le(data, size, cursor, effect.target_generation) &&
        read_le(data, size, cursor, effect.fire_sequence) &&
        read_le(data, size, cursor, effect.action) &&
        read_le(data, size, cursor, effect.domain) &&
        read_le(data, size, cursor, effect.opcode) &&
        read_le(data, size, cursor, effect.resolved_value) &&
        read_le(data, size, cursor, effect.duration_days) &&
        read_le(data, size, cursor, effect.stacks) &&
        read_le(data, size, cursor, effect.payload[0]) &&
        read_le(data, size, cursor, effect.payload[1]) &&
        read_le(data, size, cursor, effect.payload[2]) &&
        read_le(data, size, cursor, effect.payload[3]);
}

void append_command(std::vector<uint8_t> &payload,
                    const RuntimeTriggerCommand &command) {
    append_le<uint64_t>(payload, command.request_id);
    append_le<uint32_t>(payload, command.producer_id);
    append_le<uint64_t>(payload, command.sequence);
    append_le<uint64_t>(payload, command.observed_generation);
    append_le<int64_t>(payload, command.requested_day);
    append_le<int64_t>(payload, command.effective_day);
    append_le<uint16_t>(payload, static_cast<uint16_t>(command.opcode));
    append_event(payload, command.event);
    append_le<int32_t>(payload, command.trigger_id);
    append_le<uint8_t>(payload, command.enabled);
    append_binding(payload, command.binding);
    append_le<int32_t>(payload, command.source_id);
    append_le<int64_t>(payload, command.cursor);
    append_le<int64_t>(payload, command.ack_up_to_effect_id);
    append_le<uint32_t>(payload, command.resync_count);
    for (uint32_t i = 0; i < RUNTIME_TRIGGER_RESYNC_CAPACITY; ++i)
        append_le<int32_t>(payload, command.resync_trigger_ids[i]);
    for (uint32_t i = 0; i < RUNTIME_TRIGGER_RESYNC_CAPACITY; ++i)
        append_le<uint64_t>(payload, command.resync_target_handles[i]);
    for (uint32_t i = 0; i < RUNTIME_TRIGGER_RESYNC_CAPACITY; ++i)
        append_le<int64_t>(payload, command.resync_values[i]);
}

bool read_command(const uint8_t *data, size_t size, size_t &cursor,
                  RuntimeTriggerCommand &command) {
    uint16_t opcode = 0;
    if (!read_le(data, size, cursor, command.request_id) ||
        !read_le(data, size, cursor, command.producer_id) ||
        !read_le(data, size, cursor, command.sequence) ||
        !read_le(data, size, cursor, command.observed_generation) ||
        !read_le(data, size, cursor, command.requested_day) ||
        !read_le(data, size, cursor, command.effective_day) ||
        !read_le(data, size, cursor, opcode) ||
        !read_event(data, size, cursor, command.event) ||
        !read_le(data, size, cursor, command.trigger_id) ||
        !read_le(data, size, cursor, command.enabled) ||
         !read_binding(data, size, cursor, command.binding) ||
         !read_le(data, size, cursor, command.source_id) ||
         !read_le(data, size, cursor, command.cursor) ||
         !read_le(data, size, cursor, command.ack_up_to_effect_id) ||
         !read_le(data, size, cursor, command.resync_count)) return false;
    for (uint32_t i = 0; i < RUNTIME_TRIGGER_RESYNC_CAPACITY; ++i)
        if (!read_le(data, size, cursor, command.resync_trigger_ids[i])) return false;
    for (uint32_t i = 0; i < RUNTIME_TRIGGER_RESYNC_CAPACITY; ++i)
        if (!read_le(data, size, cursor, command.resync_target_handles[i])) return false;
    for (uint32_t i = 0; i < RUNTIME_TRIGGER_RESYNC_CAPACITY; ++i)
        if (!read_le(data, size, cursor, command.resync_values[i])) return false;
    command.opcode = static_cast<RuntimeTriggerCommandOpcode>(opcode);
    return true;
}

} // namespace

RuntimeTriggerPodAuthority::RuntimeTriggerPodAuthority() = default;

#include "runtime_trigger_pod_bootstrap_validation.inc"
bool RuntimeTriggerPodAuthority::queue_command(const RuntimeTriggerCommand &command,
                                               std::string &error) {
    error.clear();
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    if (!validate_command_shape(command, _catalog, error)) return false;
    const bool delivery_ack = command.opcode == RuntimeTriggerCommandOpcode::ACK_EFFECTS ||
        command.opcode == RuntimeTriggerCommandOpcode::ACK_EFFECT_IDS;
    if (delivery_ack) {
        // A busy event producer must not starve delivery acknowledgments. One
        // monotonic cursor covers every older ACK, so retain only the maximum.
        for (RuntimeTriggerCommand &pending : _pending_commands) {
            if (pending.opcode != command.opcode ||
                pending.effective_day != command.effective_day ||
                pending.observed_generation != command.observed_generation) continue;
            if (command.opcode == RuntimeTriggerCommandOpcode::ACK_EFFECT_IDS) {
                std::vector<int64_t> ids(pending.resync_values.begin(),
                    pending.resync_values.begin() + pending.resync_count);
                ids.insert(ids.end(), command.resync_values.begin(),
                    command.resync_values.begin() + command.resync_count);
                std::sort(ids.begin(), ids.end());
                ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
                if (ids.size() > RUNTIME_TRIGGER_RESYNC_CAPACITY) continue;
                pending.resync_count = static_cast<uint32_t>(ids.size());
                std::copy(ids.begin(), ids.end(), pending.resync_values.begin());
                return true;
            }
            pending.ack_up_to_effect_id = std::max(pending.ack_up_to_effect_id,
                                                   command.ack_up_to_effect_id);
            return true;
        }
    }
    const size_t capacity = RUNTIME_COMMAND_QUEUE_CAPACITY - (delivery_ack ? 0u : 1u);
    if (_pending_commands.size() >= capacity) {
        error = "trigger_command_capacity_exhausted";
        return false;
    }
    return resolve_enqueue<ResolveFlow::TriggerCommand>(_pending_commands, command, capacity) == ResolveResult::Accepted;
}

#include "runtime_trigger_pod_daily_authority.inc"
#include "runtime_trigger_pod_reference_hashes.inc"
#include "runtime_trigger_pod_checkpoint.inc"
#include "runtime_trigger_pod_selftest.inc"


} // namespace pk

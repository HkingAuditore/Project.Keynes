#include "runtime_trigger_pod.h"
#include "runtime_trigger_kernel.h"

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
    return std::tie(a.effective_day, a.producer_id, a.sequence, a.request_id) <
        std::tie(b.effective_day, b.producer_id, b.sequence, b.request_id);
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

RuntimeTriggerSnapshot canonicalize_snapshot(const RuntimeTriggerSnapshot &source,
                                             bool include_generation) {
    RuntimeTriggerSnapshot value = source;
    if (!include_generation) value.generation = 0;
    std::stable_sort(value.states.begin(), value.states.end(), state_less);
    std::stable_sort(value.branch_bindings.begin(), value.branch_bindings.end(),
                     binding_less);
    std::stable_sort(value.pending_events.begin(), value.pending_events.end(),
                     event_less);
    std::stable_sort(value.pending_effects.begin(), value.pending_effects.end(),
                     effect_less);
    return value;
}

bool valid_command_opcode(RuntimeTriggerCommandOpcode opcode) noexcept {
    const uint16_t value = static_cast<uint16_t>(opcode);
    return value >= static_cast<uint16_t>(RuntimeTriggerCommandOpcode::INGEST_EVENT) &&
        value <= static_cast<uint16_t>(RuntimeTriggerCommandOpcode::ACK_EFFECTS);
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

bool RuntimeTriggerPodAuthority::validate_catalog(
        const RuntimeTriggerPodCatalog &catalog, std::string &error) const {
    error.clear();
    if (catalog.definitions.size() > RUNTIME_TRIGGER_MAX_DEFINITIONS ||
        catalog.effects.size() > RUNTIME_TRIGGER_MAX_EFFECT_DEFINITIONS ||
        catalog.condition_ops.size() > RUNTIME_TRIGGER_MAX_CONDITION_OPS *
            catalog.definitions.size() || catalog.max_states <= 0 ||
        catalog.max_states > static_cast<int32_t>(RUNTIME_TRIGGER_MAX_DEFINITIONS) ||
        catalog.max_pending_events <= 0 ||
        catalog.max_pending_events > static_cast<int32_t>(RUNTIME_TRIGGER_MAX_PENDING_EVENTS) ||
        catalog.distinct_capacity <= 0 || catalog.distinct_capacity > 4096 ||
        catalog.source_count <= 0 || catalog.event_type_span <= 0) {
        error = "trigger_catalog_shape_invalid";
        return false;
    }
    if (catalog.catalog_hash == 0) {
        error = "trigger_catalog_hash_missing";
        return false;
    }
    for (const RuntimeTriggerDefinition &definition : catalog.definitions) {
        const bool invalid =
            definition.source_id < 0 || definition.source_id >= catalog.source_count ||
            definition.event_type < 0 || definition.event_type >= catalog.event_type_span ||
            definition.threshold <= 0 ||
            definition.condition_begin > catalog.condition_ops.size() ||
            definition.condition_count > catalog.condition_ops.size() - definition.condition_begin ||
            definition.effect_begin > catalog.effects.size() ||
            definition.effect_count > catalog.effects.size() - definition.effect_begin ||
            definition.aggregator < static_cast<int32_t>(RuntimeTriggerAggregator::COUNT) ||
            definition.aggregator > static_cast<int32_t>(RuntimeTriggerAggregator::CONSECUTIVE_DURATION) ||
            definition.value_field < 0 || definition.value_field > 7 ||
            definition.distinct_field < 0 || definition.distinct_field > 7 ||
            definition.scope < 0 || definition.scope > 2 ||
            definition.target_resolver < static_cast<int32_t>(RuntimeTriggerTargetResolver::STATIC) ||
            definition.target_resolver > static_cast<int32_t>(RuntimeTriggerTargetResolver::SNAPSHOT) ||
            (definition.mode != static_cast<int32_t>(RuntimeTriggerMode::REPEAT) &&
             definition.mode != static_cast<int32_t>(RuntimeTriggerMode::ONE_SHOT) ) ||
            definition.cooldown_days < 0 || definition.window_days < 0 ||
            ((definition.aggregator == static_cast<int32_t>(RuntimeTriggerAggregator::WINDOW_COUNT) ||
              definition.aggregator == static_cast<int32_t>(RuntimeTriggerAggregator::WINDOW_SUM)) &&
             definition.window_days <= 0) ||
            (definition.aggregator == static_cast<int32_t>(RuntimeTriggerAggregator::CONSECUTIVE_DURATION) &&
             (definition.duration_field < 0 || definition.duration_field > 7));
        if (invalid) {
            error = "trigger_definition_invalid";
            return false;
        }
    }
    for (const int32_t opcode : catalog.condition_ops) {
        if (opcode < static_cast<int32_t>(RuntimeTriggerConditionOp::PUSH_TRUE) ||
            opcode > static_cast<int32_t>(RuntimeTriggerConditionOp::BOOL_NOT)) {
            error = "trigger_condition_opcode_invalid";
            return false;
        }
    }
    for (const RuntimeTriggerEffectDefinition &effect : catalog.effects) {
        const int32_t action = effect.action;
        const bool action_valid = action == static_cast<int32_t>(RuntimeTriggerAction::MODIFIER_APPLY) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::MODIFIER_REMOVE) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::MODIFIER_REFRESH) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::MODIFIER_SET_STACKS) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::COUNTRY_COMMAND) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::ECONOMY_COMMAND) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::GAMEPLAY_COMMAND) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::PUBLISH_EVENT) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::CUSTOM_DOMAIN_COMMAND) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::IDEOLOGY_COMMAND);
        if (!action_valid ||
            effect.target_resolver < static_cast<int32_t>(RuntimeTriggerTargetResolver::STATIC) ||
            effect.target_resolver > static_cast<int32_t>(RuntimeTriggerTargetResolver::SNAPSHOT) ||
            effect.value_mode < static_cast<int32_t>(RuntimeTriggerValueMode::CONSTANT) ||
            effect.value_mode > static_cast<int32_t>(RuntimeTriggerValueMode::EVENT_VALUE) ||
            effect.domain < 0 || effect.opcode < 0) {
            error = "trigger_effect_definition_invalid";
            return false;
        }
    }
    return true;
}

bool RuntimeTriggerPodAuthority::validate_state(
        const RuntimeTriggerSnapshot &snapshot, std::string &error) const {
    error.clear();
    if (!_catalog.definitions.empty() && snapshot.enabled.size() != _catalog.definitions.size()) {
        error = "trigger_enabled_shape_invalid";
        return false;
    }
    if (snapshot.source_cursor.size() != static_cast<size_t>(_catalog.source_count) ||
        snapshot.source_needs_resync.size() != snapshot.source_cursor.size() ||
        snapshot.source_gap_begin.size() != snapshot.source_cursor.size() ||
        snapshot.source_gap_end.size() != snapshot.source_cursor.size() ||
        snapshot.states.size() > static_cast<size_t>(_catalog.max_states) ||
        snapshot.pending_events.size() > static_cast<size_t>(_catalog.max_pending_events) ||
        snapshot.pending_effects.size() > RUNTIME_TRIGGER_MAX_PENDING_EFFECTS ||
        snapshot.next_effect_id <= 0 || snapshot.acked_effect_id < 0 ||
        snapshot.current_day < snapshot.committed_day) {
        error = "trigger_snapshot_shape_invalid";
        return false;
    }
    for (size_t source = 0; source < snapshot.source_needs_resync.size(); ++source) {
        const uint8_t value = snapshot.source_needs_resync[source];
        if (value > 1) { error = "trigger_source_resync_flag_invalid"; return false; }
        if (value == 0 && (snapshot.source_gap_begin[source] != 0 ||
                           snapshot.source_gap_end[source] != 0)) {
            error = "trigger_source_gap_without_resync";
            return false;
        }
        if (value != 0 && (snapshot.source_gap_begin[source] <= 0 ||
                           snapshot.source_gap_end[source] <
                               snapshot.source_gap_begin[source])) {
            error = "trigger_source_gap_invalid";
            return false;
        }
    }
    for (const uint8_t value : snapshot.enabled) {
        if (value > 1) { error = "trigger_enabled_value_invalid"; return false; }
    }
    for (size_t i = 0; i < snapshot.states.size(); ++i) {
        const RuntimeTriggerPodSnapshotState &state = snapshot.states[i];
        if (state.trigger_id < 0 || state.trigger_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            state.distinct_keys.size() != static_cast<size_t>(_catalog.distinct_capacity) ||
            state.target_generation != static_cast<uint32_t>(state.target_handle >> 32u) ||
            state.completed > 1 || state.initialized > 1 || state.needs_resync > 1) {
            error = "trigger_state_shape_invalid";
            return false;
        }
        if (i > 0 && !state_less(snapshot.states[i - 1], state)) {
            error = "trigger_state_order_invalid";
            return false;
        }
        if (i > 0 && snapshot.states[i - 1].trigger_id == state.trigger_id &&
            snapshot.states[i - 1].target_handle == state.target_handle) {
            error = "trigger_state_duplicate";
            return false;
        }
    }
    for (size_t i = 0; i < snapshot.pending_events.size(); ++i) {
        const RuntimeTriggerEvent &event = snapshot.pending_events[i];
        if (!valid_event(event, _catalog) || event.snapshot > 1) {
            error = "trigger_pending_event_invalid";
            return false;
        }
        if (i > 0 && !event_less(snapshot.pending_events[i - 1], event)) {
            error = "trigger_pending_event_order_invalid";
            return false;
        }
        if (i > 0 && snapshot.pending_events[i - 1].source_id == event.source_id &&
            snapshot.pending_events[i - 1].event_id == event.event_id) {
            error = "trigger_pending_event_duplicate";
            return false;
        }
    }
    int64_t maximum_effect_id = 0;
    for (size_t i = 0; i < snapshot.pending_effects.size(); ++i) {
        const RuntimeTriggerEffectIntent &effect = snapshot.pending_effects[i];
        if (effect.id <= 0 || effect.effective_day < 0 ||
            effect.trigger_id < 0 ||
            effect.trigger_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            effect.effect_definition_id < 0 ||
            effect.effect_definition_id >= static_cast<int32_t>(_catalog.effects.size()) ||
            effect.target_generation != static_cast<uint32_t>(effect.target_handle >> 32u)) {
            error = "trigger_pending_effect_invalid";
            return false;
        }
        maximum_effect_id = std::max(maximum_effect_id, effect.id);
        if (i > 0 && !effect_less(snapshot.pending_effects[i - 1], effect)) {
            error = "trigger_pending_effect_order_invalid";
            return false;
        }
        if (i > 0 && snapshot.pending_effects[i - 1].id == effect.id) {
            error = "trigger_pending_effect_duplicate";
            return false;
        }
    }
    if (snapshot.acked_effect_id >= snapshot.next_effect_id ||
        maximum_effect_id >= snapshot.next_effect_id) {
        error = "trigger_effect_cursor_invalid";
        return false;
    }
    for (size_t i = 0; i < snapshot.branch_bindings.size(); ++i) {
        const RuntimeTriggerBranchBinding &binding = snapshot.branch_bindings[i];
        if (binding.trigger_id < 0 ||
            binding.trigger_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            _catalog.definitions[binding.trigger_id].dynamic_binding == 0 ||
            binding.branch_handle == 0 || binding.cell < 0 ||
            binding.reward_target < 0 || binding.reward_target > 1 ||
            binding.enabled > 1) {
            error = "trigger_branch_binding_invalid";
            return false;
        }
        if (i > 0 && !binding_less(snapshot.branch_bindings[i - 1], binding)) {
            error = "trigger_branch_binding_order_invalid";
            return false;
        }
        if (i > 0 && snapshot.branch_bindings[i - 1].trigger_id == binding.trigger_id &&
            snapshot.branch_bindings[i - 1].branch_handle == binding.branch_handle &&
            snapshot.branch_bindings[i - 1].cell == binding.cell) {
            error = "trigger_branch_binding_duplicate";
            return false;
        }
    }
    return true;
}

bool RuntimeTriggerPodAuthority::bootstrap(
        const RuntimeTriggerSnapshot &snapshot,
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    error.clear();
    if (!validate_catalog(catalog, error)) return false;
    _catalog = catalog;
    RuntimeTriggerSnapshot initial = snapshot;
    initial.catalog_hash = catalog.catalog_hash;
    if (initial.source_cursor.empty()) initial.source_cursor.assign(catalog.source_count, 0);
    if (initial.source_needs_resync.empty()) initial.source_needs_resync.assign(catalog.source_count, 0);
    if (initial.source_gap_begin.empty()) initial.source_gap_begin.assign(catalog.source_count, 0);
    if (initial.source_gap_end.empty()) initial.source_gap_end.assign(catalog.source_count, 0);
    if (initial.enabled.empty()) {
        initial.enabled.resize(catalog.definitions.size());
        for (size_t i = 0; i < catalog.definitions.size(); ++i)
            initial.enabled[i] = catalog.definitions[i].enabled;
    }
    if (initial.next_effect_id <= 0) initial.next_effect_id = 1;
    // Facade exports are dense snapshots, but their state insertion order is
    // an implementation detail of the legacy lookup table. Normalize it at
    // the worker boundary so validation and every later hash use one order.
    initial = canonicalize_snapshot(initial, true);
    if (!validate_state(initial, error)) return false;
    _state = std::move(initial);
    _pending_commands.clear();
    _diagnostics = RuntimeTriggerPodDiagnostics{};
    _state_hash = hash_snapshot(_state);
    _next_generation = _state.generation + 1u;
    _bootstrapped = true;
    _plan_active = false;
    _reference_pending = false;
    _reference_day = -1;
    _reference_input_hash = 0;
    _reference_state_hash = 0;
    _reference_effect_hash = 0;
    return true;
}

bool RuntimeTriggerPodAuthority::queue_command(const RuntimeTriggerCommand &command,
                                               std::string &error) {
    error.clear();
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    if (!validate_command_shape(command, _catalog, error)) return false;
    if (_pending_commands.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "trigger_command_capacity_exhausted";
        return false;
    }
    _pending_commands.push_back(command);
    return true;
}

bool RuntimeTriggerPodAuthority::apply_command(RuntimeTriggerSnapshot &state,
                                                const RuntimeTriggerCommand &command,
                                                std::string &error) const {
    error.clear();
    if (!validate_command_shape(command, _catalog, error)) return false;
    if (command.observed_generation != 0 &&
        command.observed_generation != state.generation) {
        error = "stale_generation";
        return false;
    }
    switch (command.opcode) {
        case RuntimeTriggerCommandOpcode::INGEST_EVENT:
        case RuntimeTriggerCommandOpcode::INGEST_SNAPSHOT: {
            RuntimeTriggerEvent event = command.event;
            if (command.opcode == RuntimeTriggerCommandOpcode::INGEST_SNAPSHOT)
                event.snapshot = 1;
            if (!valid_event(event, _catalog)) { error = "trigger_event_invalid"; return false; }
            const size_t source = static_cast<size_t>(event.source_id);
            if (state.source_needs_resync[source] != 0) {
                error = "trigger_source_needs_resync";
                return false;
            }
            const int64_t cursor = state.source_cursor[source];
            if (event.event_id <= cursor) return true;
            if (_catalog.strict_source_cursors && cursor > 0 && event.event_id != cursor + 1) {
                state.source_needs_resync[source] = 1;
                state.source_gap_begin[source] = cursor + 1;
                state.source_gap_end[source] = event.event_id;
                for (RuntimeTriggerPodSnapshotState &trigger_state : state.states) {
                    if (trigger_state.trigger_id >= 0 &&
                        _catalog.definitions[trigger_state.trigger_id].source_id == event.source_id)
                        trigger_state.needs_resync = 1;
                }
                error = "trigger_source_gap";
                return false;
            }
            if (state.pending_events.size() >= static_cast<size_t>(_catalog.max_pending_events)) {
                error = "trigger_pending_event_capacity_exhausted";
                return false;
            }
            state.pending_events.push_back(event);
            state.source_cursor[source] = event.event_id;
            return true;
        }
        case RuntimeTriggerCommandOpcode::SET_ENABLED:
            if (command.trigger_id < 0 ||
                command.trigger_id >= static_cast<int32_t>(_catalog.definitions.size())) {
                error = "trigger_id_invalid"; return false;
            }
            state.enabled[command.trigger_id] = command.enabled != 0 ? 1 : 0;
            return true;
        case RuntimeTriggerCommandOpcode::RECONCILE_BRANCH_BINDING: {
            const RuntimeTriggerBranchBinding binding = command.binding;
            if (binding.trigger_id < 0 ||
                binding.trigger_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
                _catalog.definitions[binding.trigger_id].dynamic_binding == 0 ||
                binding.branch_handle == 0 || binding.cell < 0 ||
                binding.reward_target < 0 || binding.reward_target > 1) {
                error = "trigger_branch_binding_invalid"; return false;
            }
            auto found = std::find_if(state.branch_bindings.begin(), state.branch_bindings.end(),
                [&binding](const RuntimeTriggerBranchBinding &candidate) {
                    return candidate.trigger_id == binding.trigger_id &&
                        candidate.branch_handle == binding.branch_handle &&
                        candidate.cell == binding.cell;
                });
            if (binding.enabled == 0) {
                if (found != state.branch_bindings.end()) {
                    state.states.erase(std::remove_if(state.states.begin(), state.states.end(),
                        [&binding](const RuntimeTriggerPodSnapshotState &candidate) {
                            return candidate.trigger_id == binding.trigger_id &&
                                candidate.target_handle == binding.branch_handle;
                        }), state.states.end());
                    state.pending_effects.erase(std::remove_if(state.pending_effects.begin(),
                        state.pending_effects.end(),
                        [&binding](const RuntimeTriggerEffectIntent &candidate) {
                            return candidate.trigger_id == binding.trigger_id &&
                                candidate.target_handle == binding.branch_handle;
                        }), state.pending_effects.end());
                    state.branch_bindings.erase(found);
                }
                return true;
            }
            if (found == state.branch_bindings.end()) state.branch_bindings.push_back(binding);
            else *found = binding;
            std::stable_sort(state.branch_bindings.begin(), state.branch_bindings.end(),
                [](const RuntimeTriggerBranchBinding &a, const RuntimeTriggerBranchBinding &b) {
                    return std::tie(a.trigger_id, a.cell, a.branch_handle) <
                        std::tie(b.trigger_id, b.cell, b.branch_handle);
                });
            return true;
        }
        case RuntimeTriggerCommandOpcode::RESYNC_SOURCE: {
            if (command.source_id < 0 || command.source_id >= _catalog.source_count ||
                command.cursor < 0) { error = "trigger_resync_source_invalid"; return false; }
            state.source_cursor[command.source_id] = command.cursor;
            state.source_needs_resync[command.source_id] = 0;
            state.source_gap_begin[command.source_id] = 0;
            state.source_gap_end[command.source_id] = 0;
            for (RuntimeTriggerPodSnapshotState &trigger_state : state.states) {
                if (trigger_state.trigger_id >= 0 &&
                    _catalog.definitions[trigger_state.trigger_id].source_id == command.source_id)
                    trigger_state.needs_resync = 0;
            }
            for (uint32_t i = 0; i < command.resync_count; ++i) {
                const int32_t trigger_id = command.resync_trigger_ids[i];
                const uint64_t target = command.resync_target_handles[i];
                const int32_t state_index = find_or_create_state(
                    state, _catalog, trigger_id, target, error);
                if (state_index < 0) return false;
                RuntimeTriggerPodSnapshotState &trigger_state = state.states[state_index];
                const int64_t value = command.resync_values[i];
                trigger_state.accumulator = value;
                trigger_state.remainder = value %
                    std::max<int64_t>(1, _catalog.definitions[trigger_id].threshold);
                trigger_state.last_event_id = command.cursor;
                trigger_state.needs_resync = 0;
                trigger_state.initialized = 1;
            }
            return true;
        }
        case RuntimeTriggerCommandOpcode::ACK_EFFECTS:
            state.acked_effect_id = std::max(state.acked_effect_id,
                                             command.ack_up_to_effect_id);
            state.pending_effects.erase(std::remove_if(state.pending_effects.begin(),
                state.pending_effects.end(), [&state](const RuntimeTriggerEffectIntent &effect) {
                    return effect.id <= state.acked_effect_id;
                }), state.pending_effects.end());
            return true;
        default:
            error = "trigger_command_opcode_invalid";
            return false;
    }
}

bool RuntimeTriggerPodAuthority::plan_day(int64_t day, uint64_t input_generation,
                                          RuntimeTriggerPodPlan &plan,
                                          std::string &error) {
    error.clear();
    plan = RuntimeTriggerPodPlan{};
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    if (_plan_active) { error = "trigger_plan_already_pending"; return false; }
    if (day < 0 || day < _state.committed_day) { error = "trigger_day_invalid"; return false; }
    plan.header.domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
    plan.header.day = day;
    plan.header.input_generation = input_generation;
    plan.header.base_generation = _state.generation;
    plan.next_state = _state;
    std::vector<RuntimeTriggerCommand> ordered = _pending_commands;
    std::stable_sort(ordered.begin(), ordered.end(),
        [](const RuntimeTriggerCommand &a, const RuntimeTriggerCommand &b) {
            return std::tie(a.effective_day, a.producer_id, a.sequence,
                            a.request_id) <
                std::tie(b.effective_day, b.producer_id, b.sequence, b.request_id);
        });
    std::vector<RuntimeTriggerCommand> retained;
    retained.reserve(ordered.size());
    for (const RuntimeTriggerCommand &command : ordered) {
        if (command.effective_day > day) { retained.push_back(command); continue; }
        if (!apply_command(plan.next_state, command, error)) {
            plan.header.preflight_ok = 0;
            copy_reason(plan.header.fallback_reason, error);
            _diagnostics.day = day;
            copy_reason(_diagnostics.blocker, error);
            return false;
        }
        plan.consumed_commands.push_back(command);
    }
    std::string kernel_error;
    if (!RuntimeTriggerKernel::evaluate_day(_catalog, plan.next_state, day,
                                            plan.intents, kernel_error)) {
        error = kernel_error.empty() ? "trigger_kernel_failed" : kernel_error;
        plan.header.preflight_ok = 0;
        copy_reason(plan.header.fallback_reason, error);
        _diagnostics.day = day;
        copy_reason(_diagnostics.blocker, error);
        return false;
    }
    plan.next_state.generation = _state.generation + 1u;
    plan.next_state.committed_day = day;
    plan.header.state_hash = hash_snapshot(plan.next_state);
    plan.header.intent_count = static_cast<uint32_t>(plan.intents.size());
    plan.required_ack_count = static_cast<uint32_t>(plan.intents.size());
    plan.header.ack_count = plan.required_ack_count;
    for (const RuntimeTriggerEffectIntent &intent : plan.intents) {
        RuntimeDomainAck ack;
        ack.transaction_id = static_cast<uint64_t>(intent.id);
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = static_cast<uint16_t>(intent.domain);
        ack.effective_day = intent.effective_day;
        plan.acks.push_back(ack);
    }
    plan.header.preflight_ok = 1;
    _active_plan = &plan;
    _plan_active = true;
    _diagnostics.day = day;
    _diagnostics.input_hash = input_generation;
    _diagnostics.generation = _state.generation;
    _diagnostics.committed_day = _state.committed_day;
    _diagnostics.acked_effect_id = _state.acked_effect_id;
    _diagnostics.pending_command_count = static_cast<uint32_t>(_pending_commands.size());
    _diagnostics.worker_state_hash = canonical_state_hash(plan.next_state);
    _diagnostics.worker_effect_hash = hash_effects(plan.intents);
    _diagnostics.required_ack_count = plan.required_ack_count;
    _diagnostics.received_ack_count = 0;
    _diagnostics.pending_ack_count = plan.required_ack_count;
    _diagnostics.parity_compared = 0;
    _diagnostics.parity_matched = 0;
    _diagnostics.first_divergence_index = -1;
    copy_reason32(_diagnostics.first_divergence_kind, "");
    copy_reason(_diagnostics.blocker, "trigger_reference_pending");
    _pending_commands.swap(retained);
    return true;
}

bool RuntimeTriggerPodAuthority::commit_day(RuntimeTriggerPodPlan &plan,
                                            const std::vector<RuntimeDomainAck> &acks,
                                            std::string &error) {
    error.clear();
    if (!_plan_active || _active_plan != &plan) { error = "trigger_plan_missing"; return false; }
    std::set<int64_t> received;
    for (const RuntimeDomainAck &ack : acks) {
        for (const RuntimeTriggerEffectIntent &intent : plan.intents) {
            if (ack_matches(ack, intent)) received.insert(intent.id);
        }
        if (ack.code == RuntimeDomainAckCode::RETRY ||
            ack.code == RuntimeDomainAckCode::STALE_GENERATION) {
            _pending_commands.insert(_pending_commands.end(), plan.consumed_commands.begin(),
                                     plan.consumed_commands.end());
            std::stable_sort(_pending_commands.begin(), _pending_commands.end(),
                [](const RuntimeTriggerCommand &a, const RuntimeTriggerCommand &b) {
                    return std::tie(a.effective_day, a.producer_id, a.sequence, a.request_id) <
                        std::tie(b.effective_day, b.producer_id, b.sequence, b.request_id);
                });
            _plan_active = false;
            _active_plan = nullptr;
            _diagnostics.received_ack_count = static_cast<uint32_t>(received.size());
            _diagnostics.pending_ack_count = plan.required_ack_count -
                std::min<uint32_t>(plan.required_ack_count, _diagnostics.received_ack_count);
            copy_reason(_diagnostics.blocker,
                        ack.code == RuntimeDomainAckCode::RETRY ? "ack_retry" : "stale_generation");
            error = ack.code == RuntimeDomainAckCode::RETRY ? "ack_retry" : "stale_generation";
            return false;
        }
        if (ack.code == RuntimeDomainAckCode::REJECTED) {
            _pending_commands.insert(_pending_commands.end(), plan.consumed_commands.begin(),
                                     plan.consumed_commands.end());
            std::stable_sort(_pending_commands.begin(), _pending_commands.end(), command_less);
            _plan_active = false;
            _active_plan = nullptr;
            copy_reason(_diagnostics.blocker, "ack_rejected");
            error = "ack_rejected";
            return false;
        }
    }
    _diagnostics.received_ack_count = static_cast<uint32_t>(received.size());
    _diagnostics.pending_ack_count = plan.required_ack_count > received.size()
        ? plan.required_ack_count - static_cast<uint32_t>(received.size()) : 0;
    if (received.size() < plan.required_ack_count) {
        error = "ack_barrier_incomplete";
        copy_reason(_diagnostics.blocker, error);
        return false;
    }
    _state = plan.next_state;
    _state_hash = hash_snapshot(_state);
    plan.committed = 1;
    _plan_active = false;
    _active_plan = nullptr;
    _diagnostics.worker_state_hash = canonical_state_hash(_state);
    _diagnostics.worker_effect_hash = hash_effects(_state.pending_effects);
    _diagnostics.generation = _state.generation;
    _diagnostics.committed_day = _state.committed_day;
    _diagnostics.acked_effect_id = _state.acked_effect_id;
    _diagnostics.pending_command_count = static_cast<uint32_t>(_pending_commands.size());
    compare_reference_frame();
    return true;
}

void RuntimeTriggerPodAuthority::discard_plan() {
    if (_plan_active && _active_plan != nullptr) {
        _pending_commands.insert(_pending_commands.end(),
            _active_plan->consumed_commands.begin(), _active_plan->consumed_commands.end());
        std::stable_sort(_pending_commands.begin(), _pending_commands.end(),
            [](const RuntimeTriggerCommand &a, const RuntimeTriggerCommand &b) {
                return std::tie(a.effective_day, a.producer_id, a.sequence, a.request_id) <
                    std::tie(b.effective_day, b.producer_id, b.sequence, b.request_id);
            });
    }
    _active_plan = nullptr;
    _plan_active = false;
}

bool RuntimeTriggerPodAuthority::snapshot(RuntimeTriggerSnapshot &out,
                                          std::string &error) const {
    error.clear();
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    out = _state;
    return true;
}

uint64_t RuntimeTriggerPodAuthority::hash_snapshot_impl(
        const RuntimeTriggerSnapshot &snapshot) {
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, snapshot.generation);
    hash = mix_value(hash, snapshot.catalog_hash);
    hash = mix_value(hash, snapshot.committed_day);
    hash = mix_value(hash, snapshot.current_day);
    hash = mix_value(hash, snapshot.next_effect_id);
    hash = mix_value(hash, snapshot.acked_effect_id);
    for (const int64_t value : snapshot.source_cursor) hash = mix_value(hash, value);
    for (const uint8_t value : snapshot.source_needs_resync) hash = mix_value(hash, value);
    for (const int64_t value : snapshot.source_gap_begin) hash = mix_value(hash, value);
    for (const int64_t value : snapshot.source_gap_end) hash = mix_value(hash, value);
    for (const uint8_t value : snapshot.enabled) hash = mix_value(hash, value);
    for (const RuntimeTriggerPodSnapshotState &state : snapshot.states) {
        hash = mix_value(hash, state.trigger_id);
        hash = mix_value(hash, state.target_handle);
        hash = mix_value(hash, state.target_generation);
        hash = mix_value(hash, state.accumulator);
        hash = mix_value(hash, state.remainder);
        hash = mix_value(hash, state.last_event_id);
        hash = mix_value(hash, state.fire_sequence);
        hash = mix_value(hash, state.cooldown_until);
        hash = mix_value(hash, state.window_start_day);
        hash = mix_value(hash, state.last_observed);
        hash = mix_value(hash, state.last_sample_day);
        hash = mix_value(hash, state.completed);
        hash = mix_value(hash, state.initialized);
        hash = mix_value(hash, state.needs_resync);
        for (const int64_t key : state.distinct_keys) hash = mix_value(hash, key);
    }
    for (const RuntimeTriggerBranchBinding &binding : snapshot.branch_bindings) {
        hash = mix_value(hash, binding.trigger_id); hash = mix_value(hash, binding.branch_handle);
        hash = mix_value(hash, binding.cell); hash = mix_value(hash, binding.reward_target);
        hash = mix_value(hash, binding.enabled);
    }
    for (const RuntimeTriggerEvent &event : snapshot.pending_events) {
        hash = mix_value(hash, event.source_id); hash = mix_value(hash, event.event_id);
        hash = mix_value(hash, event.day); hash = mix_value(hash, event.event_type);
        hash = mix_value(hash, event.payload_schema); hash = mix_value(hash, event.entity_handle);
        hash = mix_value(hash, event.group_handle); hash = mix_value(hash, event.value);
        for (const int64_t value : event.payload) hash = mix_value(hash, value);
        hash = mix_value(hash, event.snapshot);
    }
    for (const RuntimeTriggerEffectIntent &effect : snapshot.pending_effects) {
        hash = mix_value(hash, effect.id); hash = mix_value(hash, effect.effective_day);
        hash = mix_value(hash, effect.source_priority); hash = mix_value(hash, effect.trigger_id);
        hash = mix_value(hash, effect.effect_definition_id); hash = mix_value(hash, effect.target_handle);
        hash = mix_value(hash, effect.target_generation); hash = mix_value(hash, effect.fire_sequence);
        hash = mix_value(hash, effect.action); hash = mix_value(hash, effect.domain);
        hash = mix_value(hash, effect.opcode); hash = mix_value(hash, effect.resolved_value);
        hash = mix_value(hash, effect.duration_days); hash = mix_value(hash, effect.stacks);
        for (const int64_t value : effect.payload) hash = mix_value(hash, value);
    }
    return hash;
}

uint64_t RuntimeTriggerPodAuthority::hash_snapshot(
        const RuntimeTriggerSnapshot &snapshot) {
    return hash_snapshot_impl(canonicalize_snapshot(snapshot, true));
}

uint64_t RuntimeTriggerPodAuthority::hash_effects(
        const std::vector<RuntimeTriggerEffectIntent> &effects) {
    return canonical_effect_hash(effects);
}

uint64_t RuntimeTriggerPodAuthority::canonical_state_hash(
        const RuntimeTriggerSnapshot &snapshot) {
    // Generation is a worker transaction detail. The facade exports zero
    // because it has no corresponding POD commit generation; excluding it
    // makes the reference and worker hashes describe the same semantic state.
    return hash_snapshot_impl(canonicalize_snapshot(snapshot, false));
}

uint64_t RuntimeTriggerPodAuthority::canonical_effect_hash(
        const std::vector<RuntimeTriggerEffectIntent> &effects) {
    std::vector<RuntimeTriggerEffectIntent> ordered = effects;
    std::stable_sort(ordered.begin(), ordered.end(), effect_less);
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, static_cast<uint64_t>(ordered.size()));
    for (const RuntimeTriggerEffectIntent &effect : ordered) {
        hash = mix_value(hash, effect.id);
        hash = mix_value(hash, effect.effective_day);
        hash = mix_value(hash, effect.source_priority);
        hash = mix_value(hash, effect.trigger_id);
        hash = mix_value(hash, effect.effect_definition_id);
        hash = mix_value(hash, effect.target_handle);
        hash = mix_value(hash, effect.target_generation);
        hash = mix_value(hash, effect.fire_sequence);
        hash = mix_value(hash, effect.action);
        hash = mix_value(hash, effect.domain);
        hash = mix_value(hash, effect.opcode);
        hash = mix_value(hash, effect.resolved_value);
        hash = mix_value(hash, effect.duration_days);
        hash = mix_value(hash, effect.stacks);
        for (const int64_t value : effect.payload) hash = mix_value(hash, value);
    }
    return hash;
}

bool RuntimeTriggerPodAuthority::compare_reference_frame() {
    if (!_reference_pending) return false;
    _diagnostics.reference_day = _reference_day;
    _diagnostics.reference_input_hash = _reference_input_hash;
    _diagnostics.reference_state_hash = _reference_state_hash;
    _diagnostics.reference_effect_hash = _reference_effect_hash;
    if (_state.committed_day != _reference_day) {
        _diagnostics.parity_compared = 0;
        _diagnostics.parity_matched = 0;
        copy_reason(_diagnostics.blocker, _state.committed_day < _reference_day
            ? "trigger_reference_pending" : "trigger_reference_stale");
        return false;
    }
    _diagnostics.parity_compared = 1;
    _diagnostics.parity_matched =
        _reference_state_hash == canonical_state_hash(_state) &&
        _reference_effect_hash == canonical_effect_hash(_state.pending_effects);
    _diagnostics.first_divergence_index = _diagnostics.parity_matched ? -1 : 0;
    copy_reason32(_diagnostics.first_divergence_kind,
                  _diagnostics.parity_matched ? "" : "hash");
    copy_reason(_diagnostics.blocker,
                _diagnostics.parity_matched ? "" : "trigger_parity_mismatch");
    _reference_pending = false;
    return true;
}

bool RuntimeTriggerPodAuthority::set_reference_frame(
        int64_t day, uint64_t input_hash, uint64_t state_hash,
        uint64_t effect_hash, std::string &error) {
    error.clear();
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    if (day < 0 || input_hash == 0 || state_hash == 0 || effect_hash == 0) {
        error = "trigger_reference_invalid";
        return false;
    }
    _reference_pending = true;
    _reference_day = day;
    _reference_input_hash = input_hash;
    _reference_state_hash = state_hash;
    _reference_effect_hash = effect_hash;
    _diagnostics.day = day;
    _diagnostics.input_hash = input_hash;
    compare_reference_frame();
    return true;
}

bool RuntimeTriggerPodAuthority::encode_save(RuntimeTriggerPodSaveSection &out,
                                             std::string &error) const {
    error.clear();
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    out = RuntimeTriggerPodSaveSection{};
    out.descriptor.domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
    out.descriptor.version = RUNTIME_TRIGGER_POD_ABI_VERSION;
    out.catalog_hash = _catalog.catalog_hash;
    out.committed_day = _state.committed_day;
    out.generation = _state.generation;
    out.state_hash = _state_hash;
    std::vector<uint8_t> payload;
    append_le<uint32_t>(payload, SAVE_MAGIC);
    append_le<uint32_t>(payload, RUNTIME_TRIGGER_POD_ABI_VERSION);
    append_le<uint16_t>(payload, static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT));
    append_le<uint16_t>(payload, 0);
    append_le<uint64_t>(payload, _catalog.catalog_hash);
    append_le<uint64_t>(payload, _state.generation);
    append_le<int64_t>(payload, _state.committed_day);
    append_le<uint64_t>(payload, _state_hash);
    append_le<int32_t>(payload, _catalog.source_count);
    append_le<int32_t>(payload, _catalog.max_states);
    append_le<int32_t>(payload, _catalog.distinct_capacity);
    append_le<int32_t>(payload, _catalog.max_pending_events);
    append_le<int64_t>(payload, _state.next_effect_id);
    append_le<int64_t>(payload, _state.acked_effect_id);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.source_cursor.size()));
    for (size_t i = 0; i < _state.source_cursor.size(); ++i) {
        append_le<int64_t>(payload, _state.source_cursor[i]);
        append_le<uint8_t>(payload, _state.source_needs_resync[i]);
        append_le<int64_t>(payload, _state.source_gap_begin[i]);
        append_le<int64_t>(payload, _state.source_gap_end[i]);
    }
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.enabled.size()));
    for (const uint8_t enabled : _state.enabled) append_le<uint8_t>(payload, enabled);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.states.size()));
    for (const RuntimeTriggerPodSnapshotState &state : _state.states)
        append_state(payload, state, _catalog.distinct_capacity);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.branch_bindings.size()));
    for (const RuntimeTriggerBranchBinding &binding : _state.branch_bindings)
        append_binding(payload, binding);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.pending_events.size()));
    for (const RuntimeTriggerEvent &event : _state.pending_events) append_event(payload, event);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.pending_effects.size()));
    for (const RuntimeTriggerEffectIntent &effect : _state.pending_effects) append_effect(payload, effect);
    std::vector<RuntimeTriggerCommand> ordered_commands = _pending_commands;
    std::stable_sort(ordered_commands.begin(), ordered_commands.end(), command_less);
    append_le<uint32_t>(payload, static_cast<uint32_t>(ordered_commands.size()));
    for (const RuntimeTriggerCommand &command : ordered_commands)
        append_command(payload, command);
    append_le<uint32_t>(payload, SAVE_END);
    if (payload.size() > MAX_SAVE_BYTES) { error = "trigger_save_size_exceeded"; return false; }
    out.payload = std::move(payload);
    out.descriptor.payload_size = static_cast<uint32_t>(out.payload.size());
    out.descriptor.checksum = FNV_OFFSET;
    for (const uint8_t byte : out.payload) out.descriptor.checksum = mix_value(out.descriptor.checksum, byte);
    return true;
}

bool RuntimeTriggerPodAuthority::restore_save(
        const RuntimeTriggerPodSaveSection &section,
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    error.clear();
    if (section.descriptor.domain != static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT) ||
        section.descriptor.version != RUNTIME_TRIGGER_POD_ABI_VERSION) {
        error = "trigger_save_domain_version_invalid"; return false;
    }
    if (section.payload.empty() || section.payload.size() != section.descriptor.payload_size ||
        section.payload.size() > MAX_SAVE_BYTES || section.catalog_hash != catalog.catalog_hash) {
        error = "trigger_save_catalog_or_size_invalid"; return false;
    }
    uint64_t checksum = FNV_OFFSET;
    for (const uint8_t byte : section.payload) checksum = mix_value(checksum, byte);
    if (checksum != section.descriptor.checksum) { error = "trigger_save_checksum_failed"; return false; }
    RuntimeTriggerPodAuthority candidate;
    RuntimeTriggerSnapshot restored;
    if (!candidate.bootstrap(RuntimeTriggerSnapshot{}, catalog, error)) return false;
    const uint8_t *data = section.payload.data(); const size_t size = section.payload.size(); size_t cursor = 0;
    uint32_t magic = 0, version = 0; uint16_t domain = 0, reserved = 0;
    uint64_t catalog_hash = 0, generation = 0, state_hash = 0; int64_t committed_day = -1;
    int32_t source_count = 0, max_states = 0, distinct_capacity = 0, max_pending_events = 0;
    if (!read_le(data,size,cursor,magic) || !read_le(data,size,cursor,version) ||
        !read_le(data,size,cursor,domain) || !read_le(data,size,cursor,reserved) ||
        !read_le(data,size,cursor,catalog_hash) || !read_le(data,size,cursor,generation) ||
        !read_le(data,size,cursor,committed_day) || !read_le(data,size,cursor,state_hash) ||
        !read_le(data,size,cursor,source_count) || !read_le(data,size,cursor,max_states) ||
        !read_le(data,size,cursor,distinct_capacity) || !read_le(data,size,cursor,max_pending_events)) {
        error = "trigger_save_header_truncated"; return false;
    }
    if (magic != SAVE_MAGIC || version != RUNTIME_TRIGGER_POD_ABI_VERSION ||
        domain != static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT) ||
        reserved != 0 ||
        catalog_hash != catalog.catalog_hash || generation != section.generation ||
        committed_day != section.committed_day || source_count != catalog.source_count ||
        max_states != catalog.max_states || distinct_capacity != catalog.distinct_capacity ||
        max_pending_events != catalog.max_pending_events || state_hash != section.state_hash) {
        error = "trigger_save_header_invalid"; return false;
    }
    restored.catalog_hash = catalog_hash; restored.generation = generation;
    restored.committed_day = committed_day; restored.current_day = committed_day;
    if (!read_le(data,size,cursor,restored.next_effect_id) ||
        !read_le(data,size,cursor,restored.acked_effect_id)) { error = "trigger_save_cursor_truncated"; return false; }
    uint32_t count = 0;
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.source_count))) { error = "trigger_save_source_shape_invalid"; return false; }
    restored.source_cursor.resize(count); restored.source_needs_resync.resize(count);
    restored.source_gap_begin.resize(count); restored.source_gap_end.resize(count);
    for (uint32_t i=0;i<count;++i) if (!read_le(data,size,cursor,restored.source_cursor[i]) || !read_le(data,size,cursor,restored.source_needs_resync[i]) || !read_le(data,size,cursor,restored.source_gap_begin[i]) || !read_le(data,size,cursor,restored.source_gap_end[i])) { error="trigger_save_source_truncated"; return false; }
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.definitions.size()))) { error="trigger_save_enabled_shape_invalid"; return false; }
    restored.enabled.resize(count); for (uint32_t i=0;i<count;++i) if(!read_le(data,size,cursor,restored.enabled[i])) { error="trigger_save_enabled_truncated"; return false; }
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.max_states))) { error="trigger_save_state_count_invalid"; return false; }
    restored.states.resize(count); for (RuntimeTriggerPodSnapshotState &state : restored.states) if(!read_state(data,size,cursor,state,catalog.distinct_capacity)) { error="trigger_save_state_truncated"; return false; }
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.max_states))) { error="trigger_save_binding_count_invalid"; return false; }
    restored.branch_bindings.resize(count); for (RuntimeTriggerBranchBinding &binding : restored.branch_bindings) if(!read_binding(data,size,cursor,binding)) { error="trigger_save_binding_truncated"; return false; }
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.max_pending_events))) { error="trigger_save_event_count_invalid"; return false; }
    restored.pending_events.resize(count); for (RuntimeTriggerEvent &event : restored.pending_events) if(!read_event(data,size,cursor,event)) { error="trigger_save_event_truncated"; return false; }
    if (!read_count(data,size,cursor,count,RUNTIME_TRIGGER_MAX_PENDING_EFFECTS)) { error="trigger_save_effect_count_invalid"; return false; }
    restored.pending_effects.resize(count); for (RuntimeTriggerEffectIntent &effect : restored.pending_effects) if(!read_effect(data,size,cursor,effect)) { error="trigger_save_effect_truncated"; return false; }
    if (!read_count(data,size,cursor,count,RUNTIME_COMMAND_QUEUE_CAPACITY)) { error="trigger_save_command_count_invalid"; return false; }
    candidate._pending_commands.resize(count);
    for (size_t i = 0; i < candidate._pending_commands.size(); ++i) {
        RuntimeTriggerCommand &command = candidate._pending_commands[i];
        if (!read_command(data, size, cursor, command)) {
            error = "trigger_save_command_truncated";
            return false;
        }
        if (!validate_command_shape(command, catalog, error) ||
            (command.observed_generation != 0 &&
             command.observed_generation > generation)) {
            if (error.empty()) error = "trigger_save_command_invalid";
            return false;
        }
        if (i > 0 && !command_less(candidate._pending_commands[i - 1], command)) {
            error = "trigger_save_command_order_invalid";
            return false;
        }
    }
    uint32_t end = 0; if(!read_le(data,size,cursor,end) || end != SAVE_END || cursor != size) { error="trigger_save_trailing_bytes"; return false; }
    if (!candidate.validate_state(restored,error) || hash_snapshot(restored) != state_hash) { if(error.empty()) error="trigger_save_state_hash_failed"; return false; }
    candidate._state = std::move(restored); candidate._state_hash = state_hash; candidate._bootstrapped = true; candidate._next_generation = candidate._state.generation + 1u;
    *this = std::move(candidate);
    return true;
}

bool RuntimeTriggerPodAuthority::self_test(std::string &error) {
    error.clear(); RuntimeTriggerPodCatalog catalog; catalog.catalog_hash = 0x1234; catalog.source_count = 2; catalog.event_type_span = 4; catalog.max_states = 32; catalog.max_pending_events = 32; catalog.distinct_capacity = 8;
    RuntimeTriggerDefinition definition; definition.source_id=0; definition.event_type=1; definition.aggregator=static_cast<int32_t>(RuntimeTriggerAggregator::COUNT); definition.threshold=2; definition.effect_begin=0; definition.effect_count=1; catalog.definitions.push_back(definition);
    RuntimeTriggerEffectDefinition effect; effect.action=static_cast<int32_t>(RuntimeTriggerAction::COUNTRY_COMMAND); effect.opcode=14; effect.value_mode=static_cast<int32_t>(RuntimeTriggerValueMode::FIRE_COUNT); catalog.effects.push_back(effect);
    RuntimeTriggerPodAuthority authority; RuntimeTriggerSnapshot initial; if(!authority.bootstrap(initial,catalog,error)) return false;
    RuntimeTriggerCommand command; command.request_id=1; command.sequence=1; command.effective_day=0; command.requested_day=0; command.opcode=RuntimeTriggerCommandOpcode::INGEST_EVENT; command.event.source_id=0; command.event.event_id=1; command.event.day=0; command.event.event_type=1; if(!authority.queue_command(command,error)) return false;
    command.request_id=2; command.sequence=2; command.event.event_id=2; if(!authority.queue_command(command,error)) return false;
    RuntimeTriggerPodPlan plan; if(!authority.plan_day(0,1,plan,error) || plan.intents.size()!=1 || !authority.commit_day(plan,plan.acks,error)) return false;
    RuntimeTriggerPodSaveSection save; if(!authority.encode_save(save,error)) return false; RuntimeTriggerPodAuthority restored; if(!restored.restore_save(save,catalog,error)) return false;
    return restored.state_hash() == authority.state_hash();
}

} // namespace pk

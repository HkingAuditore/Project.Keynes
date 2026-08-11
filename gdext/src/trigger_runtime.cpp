#include "trigger_runtime.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>
#include <tuple>
#include <unordered_set>

namespace pk {

using namespace godot;

namespace {

constexpr uint32_t SAVE_MAGIC = 0x52544b50U; // PKTR
constexpr uint32_t SAVE_END = 0x454e4421U;
constexpr int32_t MAX_DEFINITIONS = 65536;
constexpr int32_t MAX_EFFECT_DEFINITIONS = 262144;
constexpr int32_t MAX_CONDITION_OPS = 64;
constexpr int64_t EMPTY_DISTINCT_KEY = std::numeric_limits<int64_t>::min();

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    const uint8_t *ptr = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), ptr, ptr + sizeof(T));
}

template <typename T>
bool read_le(const uint8_t *bytes, size_t size, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > size) return false;
    std::memcpy(&value, bytes + cursor, sizeof(T));
    cursor += sizeof(T);
    return true;
}

void append_string(std::vector<uint8_t> &out, const std::string &value) {
    append_le<uint32_t>(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

bool read_string(const uint8_t *bytes, size_t size, size_t &cursor,
                 std::string &value) {
    uint32_t length = 0;
    if (!read_le(bytes, size, cursor, length) || length > 1024 * 1024U ||
        cursor + length > size) return false;
    value.assign(reinterpret_cast<const char *>(bytes + cursor), length);
    cursor += length;
    return true;
}

uint64_t fnv_mix(uint64_t hash, const void *data, size_t size) {
    const uint8_t *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

uint64_t fnv_string(uint64_t hash, const std::string &value) {
    return fnv_mix(hash, value.data(), value.size());
}

int64_t saturating_add(int64_t a, int64_t b) {
    if (b > 0 && a > std::numeric_limits<int64_t>::max() - b)
        return std::numeric_limits<int64_t>::max();
    if (b < 0 && a < std::numeric_limits<int64_t>::min() - b)
        return std::numeric_limits<int64_t>::min();
    return a + b;
}

int64_t saturating_sub(int64_t a, int64_t b) {
    if (b > 0 && a < std::numeric_limits<int64_t>::min() + b)
        return std::numeric_limits<int64_t>::min();
    if (b < 0 && a > std::numeric_limits<int64_t>::max() + b)
        return std::numeric_limits<int64_t>::max();
    return a - b;
}

int32_t i32_at(const PackedInt32Array &values, int32_t index, int32_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

int64_t i64_at(const PackedInt64Array &values, int32_t index, int64_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

uint8_t u8_at(const PackedByteArray &values, int32_t index, uint8_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

std::string string_at(const PackedStringArray &values, int32_t index,
                      const std::string &fallback = {}) {
    if (index < 0 || index >= values.size()) return fallback;
    return String(values[index]).utf8().get_data();
}

PackedInt32Array get_i32(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt32Array());
    return value.get_type() == Variant::PACKED_INT32_ARRAY
        ? static_cast<PackedInt32Array>(value) : PackedInt32Array();
}

PackedInt64Array get_i64(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt64Array());
    return value.get_type() == Variant::PACKED_INT64_ARRAY
        ? static_cast<PackedInt64Array>(value) : PackedInt64Array();
}

PackedByteArray get_u8(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedByteArray());
    return value.get_type() == Variant::PACKED_BYTE_ARRAY
        ? static_cast<PackedByteArray>(value) : PackedByteArray();
}

PackedStringArray get_strings(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedStringArray());
    return value.get_type() == Variant::PACKED_STRING_ARRAY
        ? static_cast<PackedStringArray>(value) : PackedStringArray();
}

Dictionary failure(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = reason;
    return out;
}

uint64_t state_hash(int32_t trigger_id, uint64_t target) {
    uint64_t hash = static_cast<uint32_t>(trigger_id) * 0x9e3779b185ebca87ULL;
    hash ^= target + 0x9e3779b97f4a7c15ULL + (hash << 6U) + (hash >> 2U);
    return hash;
}

uint32_t generation_from_handle(uint64_t handle) {
    return static_cast<uint32_t>(handle >> 32U);
}

uint64_t branch_event_cell_key(int32_t source_id, int32_t event_type,
                               int32_t cell) {
    uint64_t key = static_cast<uint32_t>(source_id);
    key = (key << 16U) | static_cast<uint16_t>(event_type);
    key = (key << 32U) | static_cast<uint32_t>(cell);
    return key;
}

} // namespace

Dictionary TriggerRuntime::configure(const Dictionary &catalog) {
    if (int32_t(catalog.get("protocol_version", PROTOCOL_VERSION)) !=
        PROTOCOL_VERSION) return failure("trigger_protocol_version_invalid");

    const PackedStringArray keys = get_strings(catalog, "trigger_keys");
    const int32_t count = keys.size();
    if (count < 0 || count > MAX_DEFINITIONS)
        return failure("trigger_definition_count_invalid");

    const PackedInt32Array versions = get_i32(catalog, "versions");
    const PackedInt32Array source_ids = get_i32(catalog, "source_ids");
    const PackedInt32Array event_types = get_i32(catalog, "event_types");
    const PackedInt32Array schemas = get_i32(catalog, "payload_schemas");
    const PackedInt32Array aggregators = get_i32(catalog, "aggregators");
    const PackedInt32Array value_fields = get_i32(catalog, "value_fields");
    const PackedInt32Array distinct_fields = get_i32(catalog, "distinct_fields");
    const PackedInt32Array scopes = get_i32(catalog, "scopes");
    const PackedInt32Array target_resolvers = get_i32(catalog, "target_resolvers");
    const PackedInt64Array static_targets = get_i64(catalog, "static_targets");
    const PackedInt64Array thresholds = get_i64(catalog, "thresholds");
    const PackedInt32Array modes = get_i32(catalog, "modes");
    const PackedInt32Array cooldown_days = get_i32(catalog, "cooldown_days");
    const PackedInt32Array window_days = get_i32(catalog, "window_days");
    const PackedByteArray enabled = get_u8(catalog, "enabled");
    const PackedByteArray dynamic_bindings = get_u8(catalog, "dynamic_bindings");
    const PackedInt32Array selector_fields = get_i32(catalog, "selector_fields");
    const PackedInt64Array selector_values = get_i64(catalog, "selector_values");
    const PackedByteArray selector_negated = get_u8(catalog, "selector_negated");
    const PackedInt32Array condition_offsets = get_i32(catalog, "condition_offsets");
    const PackedInt32Array condition_ops = get_i32(catalog, "condition_ops");
    const PackedInt32Array effect_offsets = get_i32(catalog, "effect_offsets");

    if ((count > 0 && (event_types.size() != count || source_ids.size() != count ||
        aggregators.size() != count || thresholds.size() != count)) ||
        condition_offsets.size() != count + 1 || effect_offsets.size() != count + 1)
        return failure("trigger_catalog_columns_invalid");

    _max_states = std::max(1, int32_t(catalog.get("max_state_instances", 4096)));
    _max_pending_events = std::max(1, int32_t(catalog.get("max_pending_events", 8192)));
    _distinct_capacity = std::max(1, int32_t(catalog.get("distinct_capacity", 64)));
    _source_count = std::max(1, int32_t(catalog.get("source_count", 64)));
    _event_type_span = std::max(1, int32_t(catalog.get("event_type_span", 256)));
    _strict_source_cursors = bool(catalog.get("strict_source_cursors", false));
    if (_max_states > 1000000 || _max_pending_events > 1000000 ||
        _distinct_capacity > 4096 || _source_count > 4096 ||
        _event_type_span > 65536)
        return failure("trigger_catalog_capacity_invalid");

    _definitions.clear();
    _definitions.reserve(count);
    _condition_ops.clear();
    if (!condition_ops.is_empty())
        _condition_ops.assign(condition_ops.ptr(),
                              condition_ops.ptr() + condition_ops.size());
    uint64_t catalog_hash = 1469598103934665603ULL;
    catalog_hash = fnv_mix(catalog_hash, &_max_states, sizeof(_max_states));
    catalog_hash = fnv_mix(catalog_hash, &_max_pending_events, sizeof(_max_pending_events));
    catalog_hash = fnv_mix(catalog_hash, &_distinct_capacity, sizeof(_distinct_capacity));
    catalog_hash = fnv_mix(catalog_hash, &_source_count, sizeof(_source_count));
    catalog_hash = fnv_mix(catalog_hash, &_event_type_span, sizeof(_event_type_span));
    catalog_hash = fnv_mix(catalog_hash, &_strict_source_cursors, sizeof(_strict_source_cursors));
    for (int32_t i = 0; i < count; ++i) {
        Definition definition;
        definition.key = string_at(keys, i);
        definition.version = i32_at(versions, i, 1);
        definition.source_id = i32_at(source_ids, i, 0);
        definition.event_type = i32_at(event_types, i, 0);
        definition.payload_schema = i32_at(schemas, i, 0);
        definition.aggregator = i32_at(aggregators, i, COUNT);
        definition.value_field = i32_at(value_fields, i, VALUE_ONE);
        definition.distinct_field = i32_at(distinct_fields, i, VALUE_I64);
        definition.scope = i32_at(scopes, i, GLOBAL);
        definition.target_resolver = i32_at(target_resolvers, i, TARGET_STATIC);
        definition.static_target = static_cast<uint64_t>(i64_at(static_targets, i, 0));
        definition.threshold = i64_at(thresholds, i, 1);
        definition.mode = i32_at(modes, i, REPEAT);
        definition.cooldown_days = std::max(0, i32_at(cooldown_days, i, 0));
        definition.window_days = std::max(0, i32_at(window_days, i, 0));
        definition.enabled = u8_at(enabled, i, 1) != 0 ? 1 : 0;
        definition.dynamic_binding = u8_at(dynamic_bindings, i, 0) != 0 ? 1 : 0;
        definition.selector_field = i32_at(selector_fields, i, -1);
        definition.selector_value = i64_at(selector_values, i, 0);
        definition.selector_negated = u8_at(selector_negated, i, 0) != 0 ? 1 : 0;
        definition.condition_begin = condition_offsets[i];
        definition.condition_count = condition_offsets[i + 1] - condition_offsets[i];
        definition.effect_begin = effect_offsets[i];
        definition.effect_count = effect_offsets[i + 1] - effect_offsets[i];
        if (definition.key.empty() || definition.source_id < 0 ||
            definition.source_id >= _source_count || definition.event_type < 0 ||
            definition.event_type >= _event_type_span || definition.threshold <= 0 ||
            definition.aggregator < COUNT || definition.aggregator > SNAPSHOT_DIFF ||
            definition.value_field < VALUE_ONE || definition.value_field > GROUP_HANDLE ||
            definition.distinct_field < VALUE_ONE || definition.distinct_field > GROUP_HANDLE ||
            definition.scope < GLOBAL || definition.scope > ENTITY ||
            definition.target_resolver < TARGET_STATIC ||
            definition.target_resolver > TARGET_SNAPSHOT ||
            (definition.mode != REPEAT && definition.mode != ONE_SHOT) ||
            ((definition.aggregator == WINDOW_COUNT ||
              definition.aggregator == WINDOW_SUM) && definition.window_days <= 0) ||
            definition.condition_begin < 0 || definition.condition_count < 0 ||
            definition.condition_count > MAX_CONDITION_OPS ||
            definition.condition_begin + definition.condition_count > condition_ops.size() ||
            definition.effect_begin < 0 || definition.effect_count < 0 ||
            definition.selector_field < -1 ||
            definition.selector_field > GROUP_HANDLE) {
            return failure("trigger_definition_invalid");
        }
        catalog_hash = fnv_string(catalog_hash, definition.key);
        catalog_hash = fnv_mix(catalog_hash, &definition.version, sizeof(definition.version));
        catalog_hash = fnv_mix(catalog_hash, &definition.source_id, sizeof(definition.source_id));
        catalog_hash = fnv_mix(catalog_hash, &definition.event_type, sizeof(definition.event_type));
        catalog_hash = fnv_mix(catalog_hash, &definition.payload_schema, sizeof(definition.payload_schema));
        catalog_hash = fnv_mix(catalog_hash, &definition.aggregator, sizeof(definition.aggregator));
        catalog_hash = fnv_mix(catalog_hash, &definition.value_field, sizeof(definition.value_field));
        catalog_hash = fnv_mix(catalog_hash, &definition.scope, sizeof(definition.scope));
        catalog_hash = fnv_mix(catalog_hash, &definition.target_resolver, sizeof(definition.target_resolver));
        catalog_hash = fnv_mix(catalog_hash, &definition.static_target, sizeof(definition.static_target));
        catalog_hash = fnv_mix(catalog_hash, &definition.threshold, sizeof(definition.threshold));
        catalog_hash = fnv_mix(catalog_hash, &definition.mode, sizeof(definition.mode));
        catalog_hash = fnv_mix(catalog_hash, &definition.distinct_field, sizeof(definition.distinct_field));
        catalog_hash = fnv_mix(catalog_hash, &definition.cooldown_days, sizeof(definition.cooldown_days));
        catalog_hash = fnv_mix(catalog_hash, &definition.window_days, sizeof(definition.window_days));
        catalog_hash = fnv_mix(catalog_hash, &definition.enabled, sizeof(definition.enabled));
        catalog_hash = fnv_mix(catalog_hash, &definition.dynamic_binding,
                               sizeof(definition.dynamic_binding));
        catalog_hash = fnv_mix(catalog_hash, &definition.selector_field,
                               sizeof(definition.selector_field));
        catalog_hash = fnv_mix(catalog_hash, &definition.selector_value,
                               sizeof(definition.selector_value));
        catalog_hash = fnv_mix(catalog_hash, &definition.selector_negated,
                               sizeof(definition.selector_negated));
        for (int32_t op_index = definition.condition_begin;
             op_index < definition.condition_begin + definition.condition_count; ++op_index)
            catalog_hash = fnv_mix(catalog_hash, &_condition_ops[op_index], sizeof(int32_t));
        _definitions.push_back(std::move(definition));
    }

    const PackedInt32Array effect_actions = get_i32(catalog, "effect_actions");
    const int32_t effect_count = effect_actions.size();
    if (effect_count > MAX_EFFECT_DEFINITIONS ||
        (count > 0 && effect_offsets[count] != effect_count))
        return failure("trigger_effect_count_invalid");
    const PackedInt32Array effect_domains = get_i32(catalog, "effect_domains");
    const PackedInt32Array effect_priorities = get_i32(catalog, "effect_source_priorities");
    const PackedInt32Array effect_opcodes = get_i32(catalog, "effect_opcodes");
    const PackedInt32Array effect_target_resolvers = get_i32(catalog, "effect_target_resolvers");
    const PackedInt64Array effect_static_targets = get_i64(catalog, "effect_static_targets");
    const PackedInt32Array effect_value_modes = get_i32(catalog, "effect_value_modes");
    const PackedInt64Array effect_values = get_i64(catalog, "effect_values");
    const PackedInt32Array effect_durations = get_i32(catalog, "effect_duration_days");
    const PackedInt32Array effect_stacks = get_i32(catalog, "effect_stacks");
    const PackedStringArray command_keys = get_strings(catalog, "effect_command_keys");
    const PackedStringArray definition_keys = get_strings(catalog, "effect_definition_keys");
    const PackedInt64Array effect_p0 = get_i64(catalog, "effect_payload_i0");
    const PackedInt64Array effect_p1 = get_i64(catalog, "effect_payload_i1");
    const PackedInt64Array effect_p2 = get_i64(catalog, "effect_payload_i2");
    const PackedInt64Array effect_p3 = get_i64(catalog, "effect_payload_i3");
    _effect_definitions.clear();
    _effect_definitions.reserve(effect_count);
    for (int32_t i = 0; i < effect_count; ++i) {
        EffectDefinition effect;
        effect.action = effect_actions[i];
        effect.source_priority = i32_at(effect_priorities, i, 0);
        effect.domain = i32_at(effect_domains, i, 0);
        effect.opcode = i32_at(effect_opcodes, i, 0);
        effect.target_resolver = i32_at(effect_target_resolvers, i, TARGET_STATIC);
        effect.static_target = static_cast<uint64_t>(i64_at(effect_static_targets, i, 0));
        effect.value_mode = i32_at(effect_value_modes, i, EFFECT_CONSTANT);
        effect.value = i64_at(effect_values, i, 0);
        effect.duration_days = i32_at(effect_durations, i, -1);
        effect.stacks = i32_at(effect_stacks, i, 1);
        effect.command_key = string_at(command_keys, i);
        effect.definition_key = string_at(definition_keys, i);
        effect.payload = {i64_at(effect_p0, i, 0), i64_at(effect_p1, i, 0),
                          i64_at(effect_p2, i, 0), i64_at(effect_p3, i, 0)};
        const bool valid_action = effect.action == MODIFIER_APPLY ||
            effect.action == MODIFIER_REMOVE || effect.action == MODIFIER_REFRESH ||
            effect.action == MODIFIER_SET_STACKS || effect.action == COUNTRY_COMMAND ||
            effect.action == ECONOMY_COMMAND || effect.action == GAMEPLAY_COMMAND ||
            effect.action == PUBLISH_EVENT || effect.action == CUSTOM_DOMAIN_COMMAND ||
            effect.action == IDEOLOGY_COMMAND;
        if (!valid_action ||
            effect.target_resolver < TARGET_STATIC ||
            effect.target_resolver > TARGET_SNAPSHOT ||
            effect.value_mode < EFFECT_CONSTANT || effect.value_mode > EFFECT_EVENT_VALUE)
            return failure("trigger_effect_definition_invalid");
        catalog_hash = fnv_mix(catalog_hash, &effect.action, sizeof(effect.action));
        catalog_hash = fnv_mix(catalog_hash, &effect.source_priority, sizeof(effect.source_priority));
        catalog_hash = fnv_mix(catalog_hash, &effect.domain, sizeof(effect.domain));
        catalog_hash = fnv_mix(catalog_hash, &effect.opcode, sizeof(effect.opcode));
        catalog_hash = fnv_mix(catalog_hash, &effect.target_resolver, sizeof(effect.target_resolver));
        catalog_hash = fnv_mix(catalog_hash, &effect.static_target, sizeof(effect.static_target));
        catalog_hash = fnv_mix(catalog_hash, &effect.value_mode, sizeof(effect.value_mode));
        catalog_hash = fnv_mix(catalog_hash, &effect.value, sizeof(effect.value));
        catalog_hash = fnv_mix(catalog_hash, &effect.duration_days, sizeof(effect.duration_days));
        catalog_hash = fnv_mix(catalog_hash, &effect.stacks, sizeof(effect.stacks));
        catalog_hash = fnv_string(catalog_hash, effect.command_key);
        catalog_hash = fnv_string(catalog_hash, effect.definition_key);
        catalog_hash = fnv_mix(catalog_hash, effect.payload.data(), sizeof(effect.payload));
        _effect_definitions.push_back(std::move(effect));
    }

    _catalog_hash = catalog_hash;
    _branch_bindings.clear();
    _branch_index_by_event_cell.clear();
    _index_by_source_event.assign(
        static_cast<size_t>(_source_count) * _event_type_span, {});
    for (int32_t i = 0; i < count; ++i) {
        const Definition &definition = _definitions[i];
        _index_by_source_event[static_cast<size_t>(definition.source_id) *
            _event_type_span + definition.event_type].push_back(i);
    }
    reset_runtime_state();
    _configured = true;
    Dictionary out = report();
    out["ok"] = true;
    return out;
}

void TriggerRuntime::reset_runtime_state() {
    _current_day = -1;
    _state_count = 0;
    _next_effect_id = 1;
    _acked_effect_id = 0;
    _source_cursor.assign(_source_count, 0);
    _source_needs_resync.assign(_source_count, 0);
    _source_gap_begin.assign(_source_count, 0);
    _source_gap_end.assign(_source_count, 0);
    _pending_events.clear();
    _pending_events.reserve(_max_pending_events);
    _effects.clear();
    _effects.reserve(std::max(256, _max_states));
    _state.trigger_id.assign(_max_states, -1);
    _state.target_handle.assign(_max_states, 0);
    _state.target_generation.assign(_max_states, 0);
    _state.accumulator.assign(_max_states, 0);
    _state.remainder.assign(_max_states, 0);
    _state.last_event_id.assign(_max_states, 0);
    _state.fire_sequence.assign(_max_states, 0);
    _state.cooldown_until.assign(_max_states, 0);
    _state.window_start_day.assign(_max_states, -1);
    _state.last_observed.assign(_max_states, 0);
    _state.completed.assign(_max_states, 0);
    _state.initialized.assign(_max_states, 0);
    _state.needs_resync.assign(_max_states, 0);
    size_t lookup_size = 1;
    while (lookup_size < static_cast<size_t>(_max_states) * 2U) lookup_size <<= 1U;
    _lookup.assign(lookup_size, {});
    _distinct_keys.assign(static_cast<size_t>(_max_states) * _distinct_capacity,
                          EMPTY_DISTINCT_KEY);
    _events_ingested = _events_deduplicated = _events_rejected = 0;
    _rules_evaluated = _effects_emitted = _gap_count = _resync_count = 0;
    _last_ingest_ms = _last_evaluate_ms = 0.0;
    _last_error.clear();
}

int32_t TriggerRuntime::find_or_create_state(int32_t trigger_id,
                                             uint64_t target_handle,
                                             uint32_t target_generation) {
    if (_lookup.empty()) return -1;
    const size_t mask = _lookup.size() - 1U;
    size_t slot = static_cast<size_t>(state_hash(trigger_id, target_handle)) & mask;
    for (size_t probe = 0; probe < _lookup.size(); ++probe) {
        LookupSlot &entry = _lookup[slot];
        if (entry.trigger_id == trigger_id && entry.target_handle == target_handle)
            return entry.state_index;
        if (entry.trigger_id < 0) {
            if (_state_count >= _max_states) {
                _last_error = "trigger_state_capacity_exhausted";
                return -1;
            }
            const int32_t index = _state_count++;
            entry.trigger_id = trigger_id;
            entry.target_handle = target_handle;
            entry.state_index = index;
            _state.trigger_id[index] = trigger_id;
            _state.target_handle[index] = target_handle;
            _state.target_generation[index] = target_generation;
            _state.accumulator[index] = 0;
            _state.remainder[index] = 0;
            _state.last_event_id[index] = 0;
            _state.fire_sequence[index] = 0;
            _state.cooldown_until[index] = 0;
            _state.window_start_day[index] = -1;
            _state.last_observed[index] = 0;
            _state.completed[index] = 0;
            _state.initialized[index] = 0;
            _state.needs_resync[index] = 0;
            const size_t distinct_begin =
                static_cast<size_t>(index) * _distinct_capacity;
            std::fill_n(_distinct_keys.begin() + distinct_begin,
                        _distinct_capacity, EMPTY_DISTINCT_KEY);
            return index;
        }
        slot = (slot + 1U) & mask;
    }
    _last_error = "trigger_state_lookup_full";
    return -1;
}

int32_t TriggerRuntime::trigger_id_for_key(const std::string &key) const {
    for (int32_t trigger = 0;
         trigger < static_cast<int32_t>(_definitions.size()); ++trigger) {
        if (_definitions[trigger].key == key) return trigger;
    }
    return -1;
}

void TriggerRuntime::erase_state(int32_t trigger_id, uint64_t target_handle) {
    int32_t state_index = -1;
    for (int32_t index = 0; index < _state_count; ++index) {
        if (_state.trigger_id[index] == trigger_id &&
            _state.target_handle[index] == target_handle) {
            state_index = index;
            break;
        }
    }
    if (state_index < 0) return;
    const int32_t last = _state_count - 1;
    auto move = [&](auto &values) { values[state_index] = values[last]; };
    move(_state.trigger_id); move(_state.target_handle);
    move(_state.target_generation); move(_state.accumulator);
    move(_state.remainder); move(_state.last_event_id);
    move(_state.fire_sequence); move(_state.cooldown_until);
    move(_state.window_start_day); move(_state.last_observed);
    move(_state.completed); move(_state.initialized); move(_state.needs_resync);
    const size_t dst = static_cast<size_t>(state_index) * _distinct_capacity;
    const size_t src = static_cast<size_t>(last) * _distinct_capacity;
    std::copy_n(_distinct_keys.begin() + src, _distinct_capacity,
                _distinct_keys.begin() + dst);
    std::fill_n(_distinct_keys.begin() + src, _distinct_capacity,
                EMPTY_DISTINCT_KEY);
    --_state_count;
    size_t lookup_size = 1;
    while (lookup_size < static_cast<size_t>(_max_states) * 2U) lookup_size <<= 1U;
    _lookup.assign(lookup_size, {});
    for (LookupSlot &entry : _lookup) entry.trigger_id = -1;
    for (int32_t index = 0; index < _state_count; ++index) {
        const size_t mask = _lookup.size() - 1U;
        size_t slot = static_cast<size_t>(state_hash(
            _state.trigger_id[index], _state.target_handle[index])) & mask;
        while (_lookup[slot].trigger_id >= 0) slot = (slot + 1U) & mask;
        _lookup[slot] = {_state.trigger_id[index], _state.target_handle[index], index};
    }
}

void TriggerRuntime::rebuild_branch_index() {
    _branch_index_by_event_cell.clear();
    for (int32_t binding = 0;
         binding < static_cast<int32_t>(_branch_bindings.size()); ++binding) {
        const BranchBinding &row = _branch_bindings[binding];
        if (row.trigger_id < 0 || row.trigger_id >= static_cast<int32_t>(
                _definitions.size()) || row.cell < 0) continue;
        const Definition &definition = _definitions[row.trigger_id];
        _branch_index_by_event_cell[branch_event_cell_key(
            definition.source_id, definition.event_type, row.cell)].push_back(binding);
    }
}

uint64_t TriggerRuntime::resolve_target(const Definition &definition,
                                        const Event &event) const {
    switch (definition.target_resolver) {
        case TARGET_SOURCE_ENTITY:
        case TARGET_EVENT_ENTITY: return event.entity_handle;
        case TARGET_EVENT_GROUP: return event.group_handle;
        case TARGET_SNAPSHOT: return event.entity_handle != 0
            ? event.entity_handle : event.group_handle;
        default: return definition.static_target;
    }
}

uint64_t TriggerRuntime::resolve_effect_target(const EffectDefinition &effect,
                                               uint64_t state_target,
                                               const Event &event) const {
    switch (effect.target_resolver) {
        case TARGET_SOURCE_ENTITY:
        case TARGET_EVENT_ENTITY: return event.entity_handle;
        case TARGET_EVENT_GROUP: return event.group_handle;
        case TARGET_SNAPSHOT: return state_target;
        default: return effect.static_target != 0 ? effect.static_target : state_target;
    }
}

int64_t TriggerRuntime::event_field(const Event &event, int32_t field) const {
    switch (field) {
        case VALUE_ONE: return 1;
        case VALUE_I64: return event.value;
        case PAYLOAD_I0: return event.payload[0];
        case PAYLOAD_I1: return event.payload[1];
        case PAYLOAD_I2: return event.payload[2];
        case PAYLOAD_I3: return event.payload[3];
        case ENTITY_HANDLE: return static_cast<int64_t>(event.entity_handle);
        case GROUP_HANDLE: return static_cast<int64_t>(event.group_handle);
        default: return 0;
    }
}

bool TriggerRuntime::event_matches(const Definition &definition,
                                   const Event &event) const {
    if (definition.selector_field < 0) return true;
    const bool equal = event_field(event, definition.selector_field) ==
        definition.selector_value;
    return definition.selector_negated != 0 ? !equal : equal;
}

void TriggerRuntime::mark_source_gap(int32_t source_id, int64_t expected,
                                     int64_t actual) {
    if (source_id >= 0 && source_id < _source_count) {
        _source_needs_resync[source_id] = 1;
        _source_gap_begin[source_id] = expected;
        _source_gap_end[source_id] = actual;
    }
    for (int32_t i = 0; i < _state_count; ++i) {
        const int32_t trigger_id = _state.trigger_id[i];
        if (trigger_id >= 0 && _definitions[trigger_id].source_id == source_id)
            _state.needs_resync[i] = 1;
    }
    ++_gap_count;
    _last_error = "trigger_source_gap:" + std::to_string(source_id) + ":" +
        std::to_string(expected) + ":" + std::to_string(actual);
}

Dictionary TriggerRuntime::submit_events(const Dictionary &batch) {
    if (!_configured) return failure("trigger_runtime_not_configured");
    const auto started = std::chrono::steady_clock::now();
    const PackedInt32Array source_ids = get_i32(batch, "source_ids");
    const PackedInt64Array event_ids = get_i64(batch, "event_ids");
    const PackedInt64Array days = get_i64(batch, "days");
    const PackedInt32Array event_types = get_i32(batch, "event_types");
    const PackedInt32Array schemas = get_i32(batch, "payload_schemas");
    const PackedInt64Array entities = get_i64(batch, "entity_handles");
    const PackedInt64Array groups = get_i64(batch, "group_handles");
    const PackedInt64Array values = get_i64(batch, "values");
    const PackedInt64Array p0 = get_i64(batch, "payload_i0");
    const PackedInt64Array p1 = get_i64(batch, "payload_i1");
    const PackedInt64Array p2 = get_i64(batch, "payload_i2");
    const PackedInt64Array p3 = get_i64(batch, "payload_i3");
    const int32_t source_scalar = int32_t(batch.get("source_id_scalar", 0));
    int32_t count = int32_t(batch.get("count", event_ids.size()));
    count = std::min<int32_t>(count, static_cast<int32_t>(event_ids.size()));
    int32_t accepted = 0;
    int32_t deduplicated = 0;
    int64_t last_accepted = 0;
    for (int32_t i = 0; i < count; ++i) {
        const int32_t source = i32_at(source_ids, i, source_scalar);
        const int64_t id = event_ids[i];
        if (source < 0 || source >= _source_count || id <= 0) {
            ++_events_rejected;
            continue;
        }
        if (_source_needs_resync[source] != 0) {
            ++_events_rejected;
            continue;
        }
        const int64_t cursor = _source_cursor[source];
        if (id <= cursor) {
            ++deduplicated;
            ++_events_deduplicated;
            continue;
        }
        if (_strict_source_cursors && cursor > 0 && id != cursor + 1) {
            mark_source_gap(source, cursor + 1, id);
            ++_events_rejected;
            continue;
        }
        if (static_cast<int32_t>(_pending_events.size()) >= _max_pending_events) {
            mark_source_gap(source, cursor + 1, id);
            _last_error = "trigger_pending_event_capacity_exhausted";
            ++_events_rejected;
            continue;
        }
        Event event;
        event.source_id = source;
        event.event_id = id;
        event.day = i64_at(days, i, _current_day < 0 ? 0 : _current_day);
        event.event_type = i32_at(event_types, i, 0);
        event.payload_schema = i32_at(schemas, i, 0);
        event.entity_handle = static_cast<uint64_t>(i64_at(entities, i, 0));
        event.group_handle = static_cast<uint64_t>(i64_at(groups, i, 0));
        event.value = i64_at(values, i, 1);
        event.payload = {i64_at(p0, i, 0), i64_at(p1, i, 0),
                         i64_at(p2, i, 0), i64_at(p3, i, 0)};
        _pending_events.push_back(event);
        _source_cursor[source] = id;
        last_accepted = id;
        ++accepted;
        ++_events_ingested;
    }
    _last_ingest_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    Dictionary out;
    out["ok"] = true;
    out["accepted"] = accepted;
    out["deduplicated"] = deduplicated;
    out["last_accepted_event_id"] = last_accepted;
    out["pending_events"] = static_cast<int64_t>(_pending_events.size());
    out["needs_resync"] = !_last_error.empty();
    out["reason"] = String(_last_error.c_str());
    return out;
}

Dictionary TriggerRuntime::submit_snapshots(const Dictionary &batch) {
    const size_t pending_before = _pending_events.size();
    Dictionary normalized = batch.duplicate();
    normalized["source_id_scalar"] = int32_t(batch.get("source_id_scalar", 0));
    Dictionary result = submit_events(normalized);
    if (bool(result.get("ok", false))) {
        for (size_t index = pending_before; index < _pending_events.size(); ++index)
            _pending_events[index].snapshot = true;
    }
    return result;
}

bool TriggerRuntime::update_aggregate(int32_t state_index,
                                      const Definition &definition,
                                      const Event &event, int64_t &old_value,
                                      int64_t &new_value, int64_t &event_value) {
    old_value = _state.accumulator[state_index];
    event_value = event_field(event, definition.value_field);
    if (event.snapshot) {
        const int64_t previous = _state.last_observed[state_index];
        _state.last_observed[state_index] = event_value;
        if (definition.aggregator == SNAPSHOT_DIFF) {
            _state.accumulator[state_index] = _state.initialized[state_index] == 0
                ? 0 : saturating_sub(event_value, previous);
        } else {
            _state.accumulator[state_index] = event_value;
        }
        _state.initialized[state_index] = 1;
        new_value = _state.accumulator[state_index];
        return true;
    }
    if ((definition.aggregator == WINDOW_COUNT ||
         definition.aggregator == WINDOW_SUM) && definition.window_days > 0) {
        int64_t &window_start = _state.window_start_day[state_index];
        if (window_start < 0 || event.day >= window_start + definition.window_days) {
            window_start = event.day;
            _state.accumulator[state_index] = 0;
            _state.remainder[state_index] = 0;
            old_value = 0;
        }
    }
    switch (definition.aggregator) {
        case COUNT:
        case WINDOW_COUNT:
            _state.accumulator[state_index] = saturating_add(
                _state.accumulator[state_index], event_value > 0 ? event_value : 1);
            break;
        case SUM:
        case WINDOW_SUM:
        case SNAPSHOT_DIFF:
            _state.accumulator[state_index] = saturating_add(
                _state.accumulator[state_index], event_value);
            break;
        case MINIMUM:
            _state.accumulator[state_index] = _state.initialized[state_index] == 0
                ? event_value : std::min(_state.accumulator[state_index], event_value);
            break;
        case MAXIMUM:
            _state.accumulator[state_index] = _state.initialized[state_index] == 0
                ? event_value : std::max(_state.accumulator[state_index], event_value);
            break;
        case STATE_LEVEL:
            _state.last_observed[state_index] = _state.accumulator[state_index];
            _state.accumulator[state_index] = event_value;
            break;
        case DISTINCT_COUNT: {
            const int64_t distinct = event_field(event, definition.distinct_field);
            const size_t begin = static_cast<size_t>(state_index) * _distinct_capacity;
            size_t slot = static_cast<size_t>(state_hash(state_index,
                static_cast<uint64_t>(distinct))) % _distinct_capacity;
            bool inserted = false;
            for (int32_t probe = 0; probe < _distinct_capacity; ++probe) {
                int64_t &key = _distinct_keys[begin + slot];
                if (key == distinct) break;
                if (key == EMPTY_DISTINCT_KEY) {
                    key = distinct;
                    inserted = true;
                    break;
                }
                slot = (slot + 1U) % _distinct_capacity;
            }
            if (inserted) _state.accumulator[state_index] = saturating_add(
                _state.accumulator[state_index], 1);
            else if (_state.accumulator[state_index] >= _distinct_capacity) {
                _state.needs_resync[state_index] = 1;
                _last_error = "trigger_distinct_capacity_exhausted";
                return false;
            }
            break;
        }
        default: return false;
    }
    _state.initialized[state_index] = 1;
    new_value = _state.accumulator[state_index];
    return true;
}

bool TriggerRuntime::evaluate_conditions(const Definition &definition,
                                         int32_t state_index,
                                         int64_t old_value, int64_t new_value,
                                         int64_t old_level,
                                         int64_t new_level) const {
    if (definition.condition_count == 0)
        return new_level > old_level;
    bool stack[MAX_CONDITION_OPS] = {};
    int32_t depth = 0;
    for (int32_t i = 0; i < definition.condition_count; ++i) {
        const int32_t op = _condition_ops[definition.condition_begin + i];
        if (op >= PUSH_TRUE && op <= PUSH_NOT_COMPLETED) {
            if (depth >= MAX_CONDITION_OPS) return false;
            bool value = false;
            switch (op) {
                case PUSH_TRUE: value = true; break;
                case PUSH_ACC_GTE: value = new_value >= definition.threshold; break;
                case PUSH_CROSSING: value = new_level > old_level; break;
                case PUSH_LEVEL_CHANGE: value = new_level != old_level; break;
                case PUSH_COOLDOWN_READY:
                    value = _current_day >= _state.cooldown_until[state_index]; break;
                case PUSH_NOT_COMPLETED:
                    value = _state.completed[state_index] == 0; break;
                default: break;
            }
            stack[depth++] = value;
        } else if (op == BOOL_NOT) {
            if (depth < 1) return false;
            stack[depth - 1] = !stack[depth - 1];
        } else if (op == BOOL_AND || op == BOOL_OR) {
            if (depth < 2) return false;
            const bool right = stack[--depth];
            const bool left = stack[depth - 1];
            stack[depth - 1] = op == BOOL_AND ? left && right : left || right;
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0];
}

int64_t TriggerRuntime::fire_count_for(const Definition &definition,
                                       int32_t state_index,
                                       int64_t old_value, int64_t new_value,
                                       int64_t old_level,
                                       int64_t new_level) const {
    if (definition.mode == ONE_SHOT)
        return _state.completed[state_index] == 0 && new_value >= definition.threshold ? 1 : 0;
    if (new_level > old_level) return new_level - old_level;
    return new_level != old_level ? 1 : 0;
}

void TriggerRuntime::emit_effects(int32_t trigger_id, int32_t state_index,
                                  const Event &event, int64_t fire_count,
                                  int64_t level, int64_t event_value) {
    const Definition &definition = _definitions[trigger_id];
    const uint64_t sequence = ++_state.fire_sequence[state_index];
    const uint64_t state_target = _state.target_handle[state_index];
    for (int32_t i = 0; i < definition.effect_count; ++i) {
        const EffectDefinition &source =
            _effect_definitions[definition.effect_begin + i];
        Effect effect;
        effect.id = _next_effect_id++;
        effect.effective_day = event.day + 1;
        effect.source_priority = source.source_priority;
        effect.trigger_id = trigger_id;
        effect.target_handle = resolve_effect_target(source, state_target, event);
        effect.target_generation = generation_from_handle(effect.target_handle);
        effect.fire_sequence = sequence;
        effect.action = source.action;
        effect.domain = source.domain;
        effect.opcode = source.opcode;
        effect.duration_days = source.duration_days;
        effect.stacks = source.stacks;
        effect.command_key = source.command_key;
        effect.definition_key = source.definition_key;
        effect.payload = source.payload;
        if (effect.action == COUNTRY_COMMAND &&
            effect.opcode == 14) { // NativeCountryRuntime::COMMAND_DISCOVER_COUNTRY_SIGNAL
            const uint64_t signal = static_cast<uint64_t>(effect.payload[0]) & 0xffffffffULL;
            const uint64_t cell = event.group_handle & 0xffffffffULL;
            effect.payload[0] = static_cast<int64_t>((signal << 32U) | cell);
        }
        for (const BranchBinding &binding : _branch_bindings) {
            if (binding.trigger_id == trigger_id &&
                binding.branch_handle == state_target) {
                effect.payload[0] = binding.reward_target;
                break;
            }
        }
        switch (source.value_mode) {
            case EFFECT_FIRE_COUNT: effect.resolved_value = fire_count; break;
            case EFFECT_LEVEL: effect.resolved_value = level; break;
            case EFFECT_ACCUMULATOR:
                effect.resolved_value = _state.accumulator[state_index]; break;
            case EFFECT_EVENT_VALUE: effect.resolved_value = event_value; break;
            default: effect.resolved_value = source.value; break;
        }
        if (source.value_mode == EFFECT_LEVEL && effect.stacks <= 0)
            effect.stacks = static_cast<int32_t>(std::max<int64_t>(0, level));
        _effects.push_back(std::move(effect));
        ++_effects_emitted;
    }
}

Dictionary TriggerRuntime::run_daily(int64_t day_index) {
    if (!_configured) return failure("trigger_runtime_not_configured");
    if (day_index < _current_day) return failure("trigger_day_regression");
    const auto started = std::chrono::steady_clock::now();
    _current_day = day_index;
    std::stable_sort(_pending_events.begin(), _pending_events.end(),
        [](const Event &a, const Event &b) {
            if (a.day != b.day) return a.day < b.day;
            if (a.source_id != b.source_id) return a.source_id < b.source_id;
            return a.event_id < b.event_id;
        });
    size_t retained = 0;
    int64_t processed = 0;
    int64_t fired = 0;
    for (size_t event_index = 0; event_index < _pending_events.size(); ++event_index) {
        const Event event = _pending_events[event_index];
        if (event.day > day_index) {
            _pending_events[retained++] = event;
            continue;
        }
        ++processed;
        if (event.source_id < 0 || event.source_id >= _source_count ||
            event.event_type < 0 || event.event_type >= _event_type_span ||
            _source_needs_resync[event.source_id] != 0) continue;
        auto process_rule = [&](int32_t trigger_id, uint64_t target) {
            Definition &definition = _definitions[trigger_id];
            if (definition.enabled == 0 ||
                (definition.payload_schema > 0 &&
                 definition.payload_schema != event.payload_schema) ||
                !event_matches(definition, event)) return;
            const int32_t state_index = find_or_create_state(
                trigger_id, target, generation_from_handle(target));
            if (state_index < 0 || _state.needs_resync[state_index] != 0) return;
            if (_state.last_event_id[state_index] >= event.event_id) return;
            int64_t old_value = 0, new_value = 0, event_value = 0;
            if (!update_aggregate(state_index, definition, event,
                                  old_value, new_value, event_value)) return;
            _state.last_event_id[state_index] = event.event_id;
            const int64_t old_level = old_value >= 0 ? old_value / definition.threshold : 0;
            const int64_t new_level = new_value >= 0 ? new_value / definition.threshold : 0;
            _state.remainder[state_index] = new_value >= 0
                ? new_value % definition.threshold : 0;
            ++_rules_evaluated;
            if (!evaluate_conditions(definition, state_index, old_value,
                                     new_value, old_level, new_level)) return;
            const int64_t fire_count = fire_count_for(definition, state_index,
                old_value, new_value, old_level, new_level);
            if (fire_count <= 0) return;
            emit_effects(trigger_id, state_index, event, fire_count,
                         new_level, event_value);
            fired += fire_count;
            if (definition.mode == ONE_SHOT) _state.completed[state_index] = 1;
            if (definition.cooldown_days > 0)
                _state.cooldown_until[state_index] = day_index + definition.cooldown_days;
        };
        const auto &rules = _index_by_source_event[
            static_cast<size_t>(event.source_id) * _event_type_span + event.event_type];
        for (int32_t trigger_id : rules) {
            if (_definitions[trigger_id].dynamic_binding != 0) continue;
            process_rule(trigger_id, resolve_target(_definitions[trigger_id], event));
        }
        const auto branch_it = _branch_index_by_event_cell.find(
            branch_event_cell_key(event.source_id, event.event_type,
                                  static_cast<int32_t>(event.group_handle)));
        if (branch_it != _branch_index_by_event_cell.end()) {
            for (const int32_t binding_index : branch_it->second) {
                if (binding_index < 0 || binding_index >= static_cast<int32_t>(
                        _branch_bindings.size())) continue;
                const BranchBinding &binding = _branch_bindings[binding_index];
                process_rule(binding.trigger_id, binding.branch_handle);
            }
        }
    }
    _pending_events.resize(retained);
    std::stable_sort(_effects.begin(), _effects.end(),
        [](const Effect &a, const Effect &b) {
            if (a.effective_day != b.effective_day)
                return a.effective_day < b.effective_day;
            if (a.source_priority != b.source_priority)
                return a.source_priority < b.source_priority;
            if (a.trigger_id != b.trigger_id) return a.trigger_id < b.trigger_id;
            if (a.target_handle != b.target_handle)
                return a.target_handle < b.target_handle;
            return a.fire_sequence < b.fire_sequence;
        });
    _last_evaluate_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    Dictionary out = report();
    out["ok"] = true;
    out["done"] = true;
    out["path"] = "TRIGGER_GRAPH";
    out["stage"] = "trigger_evaluate";
    out["day_index"] = day_index;
    out["events_processed"] = processed;
    out["firings"] = fired;
    out["effects_pending"] = static_cast<int64_t>(_effects.size());
    out["work_done"] = processed + fired;
    return out;
}

Dictionary TriggerRuntime::poll_effects(int64_t after_effect_id,
                                        int32_t limit) const {
    PackedInt64Array ids, days, targets, sequences, values, p0, p1, p2, p3;
    PackedInt32Array priorities, triggers, generations, actions, domains,
        opcodes, durations, stacks;
    PackedStringArray trigger_keys, command_keys, definition_keys;
    const int32_t max_count = std::max(0, limit);
    for (const Effect &effect : _effects) {
        if (effect.id <= after_effect_id || effect.id <= _acked_effect_id) continue;
        ids.append(effect.id);
        days.append(effect.effective_day);
        priorities.append(effect.source_priority);
        triggers.append(effect.trigger_id);
        trigger_keys.append(effect.trigger_id >= 0 &&
            effect.trigger_id < static_cast<int32_t>(_definitions.size())
                ? _definitions[effect.trigger_id].key.c_str() : "");
        targets.append(static_cast<int64_t>(effect.target_handle));
        generations.append(static_cast<int32_t>(effect.target_generation));
        sequences.append(static_cast<int64_t>(effect.fire_sequence));
        actions.append(effect.action);
        domains.append(effect.domain);
        opcodes.append(effect.opcode);
        values.append(effect.resolved_value);
        durations.append(effect.duration_days);
        stacks.append(effect.stacks);
        command_keys.append(effect.command_key.c_str());
        definition_keys.append(effect.definition_key.c_str());
        p0.append(effect.payload[0]); p1.append(effect.payload[1]);
        p2.append(effect.payload[2]); p3.append(effect.payload[3]);
        if (max_count > 0 && ids.size() >= max_count) break;
    }
    Dictionary out;
    out["ok"] = true;
    out["effect_ids"] = ids;
    out["effective_days"] = days;
    out["source_priorities"] = priorities;
    out["trigger_ids"] = triggers;
    out["trigger_keys"] = trigger_keys;
    out["target_handles"] = targets;
    out["target_generations"] = generations;
    out["fire_sequences"] = sequences;
    out["actions"] = actions;
    out["domains"] = domains;
    out["opcodes"] = opcodes;
    out["resolved_values"] = values;
    out["duration_days"] = durations;
    out["stacks"] = stacks;
    out["command_keys"] = command_keys;
    out["definition_keys"] = definition_keys;
    out["payload_i0"] = p0; out["payload_i1"] = p1;
    out["payload_i2"] = p2; out["payload_i3"] = p3;
    out["count"] = ids.size();
    return out;
}

Dictionary TriggerRuntime::ack_effects(int64_t up_to_effect_id) {
    if (up_to_effect_id > _acked_effect_id) _acked_effect_id = up_to_effect_id;
    size_t keep = 0;
    while (keep < _effects.size() && _effects[keep].id <= _acked_effect_id) ++keep;
    if (keep > 0) _effects.erase(_effects.begin(), _effects.begin() + keep);
    Dictionary out;
    out["ok"] = true;
    out["acked_effect_id"] = _acked_effect_id;
    out["pending_effects"] = static_cast<int64_t>(_effects.size());
    return out;
}

Dictionary TriggerRuntime::handoff_effects(EffectRuntime *effect_runtime,
                                           NativeIdeologyRuntime *ideology_runtime,
                                           int32_t limit) {
    if (!_configured || effect_runtime == nullptr) return failure("trigger_effect_handoff_unavailable");
    const int32_t max_count = std::max(1, std::min(limit, 4096));
    int32_t handed_off = 0;
    int64_t last_effect_id = _acked_effect_id;
    std::string blocked_reason;
    for (const Effect &effect : _effects) {
        if (effect.id <= _acked_effect_id) continue;
        if (handed_off >= max_count) break;
        if (effect.action == IDEOLOGY_COMMAND) {
            if (ideology_runtime == nullptr) {
                blocked_reason = "trigger_ideology_runtime_unavailable";
                break;
            }
            std::string error;
            if (!ideology_runtime->submit_trigger_command_pod(effect.opcode,
                    effect.effective_day, effect.source_priority,
                    static_cast<int64_t>(effect.fire_sequence), effect.target_handle,
                    static_cast<int32_t>(effect.payload[0]), effect.resolved_value,
                    static_cast<uint32_t>(std::max<int64_t>(0, effect.payload[1])),
                    static_cast<int32_t>(effect.payload[2]),
                    static_cast<int32_t>(effect.payload[3]), error)) {
                blocked_reason = error.empty() ? "trigger_ideology_handoff_failed" : error;
                break;
            }
            last_effect_id = effect.id;
            ++handed_off;
            continue;
        }
        // Modifier and Country actions have native EffectRuntime adapters.
        // Other domains stay on the TriggerFacade compatibility path until
        // their own safe-boundary adapter is migrated.
        const bool native_modifier = effect.action >= MODIFIER_APPLY &&
            effect.action <= MODIFIER_SET_STACKS;
        if (!native_modifier && effect.action != COUNTRY_COMMAND) {
            blocked_reason = "trigger_effect_domain_adapter_required";
            break;
        }
        std::string error;
        const int32_t effect_action = effect.action == COUNTRY_COMMAND
            ? EffectRuntime::COUNTRY_COMMAND : effect.action;
        if (!effect_runtime->enqueue_trigger_effect_pod(
                effect.id, effect.effective_day, effect.trigger_id,
                effect.target_handle, effect.target_generation,
                effect.fire_sequence, effect_action, effect.domain, effect.opcode,
                effect.resolved_value, effect.duration_days, effect.stacks,
                effect.command_key, effect.definition_key, effect.payload, error)) {
            blocked_reason = error.empty() ? "trigger_effect_handoff_failed" : error;
            break;
        }
        last_effect_id = effect.id;
        ++handed_off;
    }
    if (handed_off > 0) ack_effects(last_effect_id);
    Dictionary out;
    out["ok"] = blocked_reason.empty();
    out["native_supported"] = true;
    out["handed_off"] = handed_off;
    out["last_effect_id"] = last_effect_id;
    out["blocked"] = !blocked_reason.empty();
    if (!blocked_reason.empty()) out["reason"] = String(blocked_reason.c_str());
    return out;
}

Dictionary TriggerRuntime::set_enabled(const Dictionary &batch) {
    const PackedInt32Array ids = get_i32(batch, "trigger_ids");
    const PackedByteArray values = get_u8(batch, "enabled");
    if (ids.size() != values.size()) return failure("trigger_control_columns_invalid");
    int32_t changed = 0;
    for (int32_t i = 0; i < ids.size(); ++i) {
        const int32_t id = ids[i];
        if (id < 0 || id >= static_cast<int32_t>(_definitions.size())) continue;
        _definitions[id].enabled = values[i] != 0 ? 1 : 0;
        ++changed;
    }
    Dictionary out;
    out["ok"] = true;
    out["changed"] = changed;
    return out;
}

Dictionary TriggerRuntime::reconcile_branch_bindings(const Dictionary &batch) {
    if (!_configured) return failure("trigger_runtime_not_configured");
    const PackedStringArray keys = get_strings(batch, "trigger_keys");
    const PackedInt64Array branches = get_i64(batch, "branch_handles");
    const PackedInt32Array cells = get_i32(batch, "cells");
    const PackedInt32Array rewards = get_i32(batch, "reward_targets");
    const PackedByteArray enabled = get_u8(batch, "enabled");
    const int32_t count = keys.size();
    if (branches.size() != count || cells.size() != count ||
        rewards.size() != count || enabled.size() != count)
        return failure("trigger_branch_binding_columns_invalid");
    int32_t changed = 0;
    for (int32_t row = 0; row < count; ++row) {
        const int32_t trigger_id = trigger_id_for_key(string_at(keys, row));
        const uint64_t branch = static_cast<uint64_t>(branches[row]);
        const int32_t cell = cells[row];
        const int32_t reward = rewards[row];
        if (trigger_id < 0 || _definitions[trigger_id].dynamic_binding == 0 ||
            branch == 0 || cell < 0 || reward < 0 || reward > 1)
            continue;
        auto found = std::find_if(_branch_bindings.begin(), _branch_bindings.end(),
            [&](const BranchBinding &binding) {
                return binding.trigger_id == trigger_id &&
                    binding.branch_handle == branch && binding.cell == cell;
            });
        if (enabled[row] == 0) {
            if (found != _branch_bindings.end()) {
                erase_state(trigger_id, branch);
                _effects.erase(std::remove_if(_effects.begin(), _effects.end(),
                    [&](const Effect &effect) {
                        return effect.trigger_id == trigger_id &&
                            effect.target_handle == branch;
                    }), _effects.end());
                _branch_bindings.erase(found);
                ++changed;
            }
            continue;
        }
        if (found == _branch_bindings.end()) {
            _branch_bindings.push_back({trigger_id, branch, cell, reward});
            ++changed;
        } else if (found->reward_target != reward) {
            found->reward_target = reward;
            ++changed;
        }
    }
    std::sort(_branch_bindings.begin(), _branch_bindings.end(),
        [](const BranchBinding &a, const BranchBinding &b) {
            return std::tie(a.trigger_id, a.cell, a.branch_handle) <
                std::tie(b.trigger_id, b.cell, b.branch_handle);
        });
    rebuild_branch_index();
    Dictionary out;
    out["ok"] = true;
    out["changed"] = changed;
    out["binding_count"] = static_cast<int64_t>(_branch_bindings.size());
    return out;
}

Dictionary TriggerRuntime::branch_progress(uint64_t branch_handle) const {
    Dictionary out;
    PackedStringArray keys;
    PackedInt64Array progress, remainders, thresholds;
    PackedInt32Array cells, completed, rewards;
    for (const BranchBinding &binding : _branch_bindings) {
        if (binding.branch_handle != branch_handle || binding.trigger_id < 0 ||
            binding.trigger_id >= static_cast<int32_t>(_definitions.size())) continue;
        keys.push_back(_definitions[binding.trigger_id].key.c_str());
        cells.push_back(binding.cell);
        rewards.push_back(binding.reward_target);
        thresholds.push_back(_definitions[binding.trigger_id].threshold);
        int32_t state_index = -1;
        for (int32_t index = 0; index < _state_count; ++index) {
            if (_state.trigger_id[index] == binding.trigger_id &&
                _state.target_handle[index] == branch_handle) {
                state_index = index;
                break;
            }
        }
        progress.push_back(state_index >= 0 ? _state.accumulator[state_index] : 0);
        remainders.push_back(state_index >= 0 ? _state.remainder[state_index] : 0);
        completed.push_back(state_index >= 0 ? _state.completed[state_index] : 0);
    }
    out["ok"] = true;
    out["branch_handle"] = static_cast<int64_t>(branch_handle);
    out["trigger_definition_keys"] = keys;
    out["trigger_cells"] = cells;
    out["trigger_reward_targets"] = rewards;
    out["trigger_thresholds"] = thresholds;
    out["trigger_progress"] = progress;
    out["trigger_remainders"] = remainders;
    out["trigger_completed"] = completed;
    return out;
}

Dictionary TriggerRuntime::resync_source(const Dictionary &snapshot) {
    if (!_configured) return failure("trigger_runtime_not_configured");
    const int32_t source = int32_t(snapshot.get("source_id", -1));
    const int64_t cursor = int64_t(snapshot.get("cursor", 0));
    if (source < 0 || source >= _source_count || cursor < 0)
        return failure("trigger_resync_source_invalid");
    const PackedInt32Array trigger_ids = get_i32(snapshot, "trigger_ids");
    const PackedInt64Array targets = get_i64(snapshot, "target_handles");
    const PackedInt64Array values = get_i64(snapshot, "values");
    if (trigger_ids.size() != targets.size() || trigger_ids.size() != values.size())
        return failure("trigger_resync_columns_invalid");
    for (int32_t i = 0; i < trigger_ids.size(); ++i) {
        const int32_t trigger_id = trigger_ids[i];
        if (trigger_id < 0 || trigger_id >= static_cast<int32_t>(_definitions.size()) ||
            _definitions[trigger_id].source_id != source) continue;
        const uint64_t target = static_cast<uint64_t>(targets[i]);
        const int32_t state_index = find_or_create_state(
            trigger_id, target, generation_from_handle(target));
        if (state_index < 0) continue;
        _state.accumulator[state_index] = values[i];
        _state.remainder[state_index] = values[i] >= 0
            ? values[i] % _definitions[trigger_id].threshold : 0;
        _state.last_event_id[state_index] = cursor;
        _state.needs_resync[state_index] = 0;
        _state.initialized[state_index] = 1;
    }
    _source_cursor[source] = cursor;
    _source_needs_resync[source] = 0;
    _source_gap_begin[source] = 0;
    _source_gap_end[source] = 0;
    ++_resync_count;
    _last_error.clear();
    Dictionary out;
    out["ok"] = true;
    out["source_id"] = source;
    out["cursor"] = cursor;
    out["states"] = trigger_ids.size();
    return out;
}

bool TriggerRuntime::should_run(int64_t day_index) const {
    return _configured && (!_pending_events.empty() || !_effects.empty() ||
        day_index > _current_day);
}

Dictionary TriggerRuntime::report() const {
    Dictionary out;
    out["configured"] = _configured;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["current_day"] = _current_day;
    out["definition_count"] = static_cast<int64_t>(_definitions.size());
    out["effect_definition_count"] = static_cast<int64_t>(_effect_definitions.size());
    out["branch_binding_count"] = static_cast<int64_t>(_branch_bindings.size());
    out["state_count"] = _state_count;
    out["state_capacity"] = _max_states;
    out["pending_events"] = static_cast<int64_t>(_pending_events.size());
    out["pending_effects"] = static_cast<int64_t>(_effects.size());
    out["events_ingested"] = static_cast<int64_t>(_events_ingested);
    out["events_deduplicated"] = static_cast<int64_t>(_events_deduplicated);
    out["events_rejected"] = static_cast<int64_t>(_events_rejected);
    out["rules_evaluated"] = static_cast<int64_t>(_rules_evaluated);
    out["effects_emitted"] = static_cast<int64_t>(_effects_emitted);
    out["gap_count"] = static_cast<int64_t>(_gap_count);
    out["resync_count"] = static_cast<int64_t>(_resync_count);
    out["last_ingest_ms"] = _last_ingest_ms;
    out["last_evaluate_ms"] = _last_evaluate_ms;
    out["last_error"] = String(_last_error.c_str());
    PackedInt64Array cursors;
    PackedInt64Array gap_begin;
    PackedInt64Array gap_end;
    PackedByteArray gaps;
    for (int32_t source = 0; source < _source_count; ++source) {
        cursors.append(_source_cursor[source]);
        gaps.append(_source_needs_resync[source]);
        gap_begin.append(_source_gap_begin[source]);
        gap_end.append(_source_gap_end[source]);
    }
    out["source_cursors"] = cursors;
    out["source_needs_resync"] = gaps;
    out["source_gap_begin"] = gap_begin;
    out["source_gap_end"] = gap_end;
    return out;
}

PackedByteArray TriggerRuntime::capture() const {
    PackedByteArray packed;
    if (!_configured) return packed;
    std::vector<uint8_t> bytes;
    append_le<uint32_t>(bytes, SAVE_MAGIC);
    append_le<uint32_t>(bytes, SAVE_SCHEMA_VERSION);
    append_le<uint64_t>(bytes, _catalog_hash);
    append_le<int64_t>(bytes, _current_day);
    append_le<int64_t>(bytes, _next_effect_id);
    append_le<int64_t>(bytes, _acked_effect_id);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_source_count));
    for (int32_t source = 0; source < _source_count; ++source) {
        append_le<int64_t>(bytes, _source_cursor[source]);
        append_le<uint8_t>(bytes, _source_needs_resync[source]);
        append_le<int64_t>(bytes, _source_gap_begin[source]);
        append_le<int64_t>(bytes, _source_gap_end[source]);
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_state_count));
    for (int32_t i = 0; i < _state_count; ++i) {
        append_string(bytes, _definitions[_state.trigger_id[i]].key);
        append_le<uint64_t>(bytes, _state.target_handle[i]);
        append_le<uint32_t>(bytes, _state.target_generation[i]);
        append_le<int64_t>(bytes, _state.accumulator[i]);
        append_le<int64_t>(bytes, _state.remainder[i]);
        append_le<int64_t>(bytes, _state.last_event_id[i]);
        append_le<uint64_t>(bytes, _state.fire_sequence[i]);
        append_le<int64_t>(bytes, _state.cooldown_until[i]);
        append_le<int64_t>(bytes, _state.window_start_day[i]);
        append_le<int64_t>(bytes, _state.last_observed[i]);
        append_le<uint8_t>(bytes, _state.completed[i]);
        append_le<uint8_t>(bytes, _state.initialized[i]);
        append_le<uint8_t>(bytes, _state.needs_resync[i]);
        const size_t begin = static_cast<size_t>(i) * _distinct_capacity;
        for (int32_t d = 0; d < _distinct_capacity; ++d)
            append_le<int64_t>(bytes, _distinct_keys[begin + d]);
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_pending_events.size()));
    for (const Event &event : _pending_events) {
        append_le<int32_t>(bytes, event.source_id);
        append_le<int64_t>(bytes, event.event_id);
        append_le<int64_t>(bytes, event.day);
        append_le<int32_t>(bytes, event.event_type);
        append_le<int32_t>(bytes, event.payload_schema);
        append_le<uint64_t>(bytes, event.entity_handle);
        append_le<uint64_t>(bytes, event.group_handle);
        append_le<int64_t>(bytes, event.value);
        for (int p = 0; p < 4; ++p) append_le<int64_t>(bytes, event.payload[p]);
        append_le<uint8_t>(bytes, event.snapshot ? 1 : 0);
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_effects.size()));
    for (const Effect &effect : _effects) {
        append_le<int64_t>(bytes, effect.id);
        append_le<int64_t>(bytes, effect.effective_day);
        append_le<int32_t>(bytes, effect.source_priority);
        append_string(bytes, _definitions[effect.trigger_id].key);
        append_le<uint64_t>(bytes, effect.target_handle);
        append_le<uint32_t>(bytes, effect.target_generation);
        append_le<uint64_t>(bytes, effect.fire_sequence);
        append_le<int32_t>(bytes, effect.action);
        append_le<int32_t>(bytes, effect.domain);
        append_le<int32_t>(bytes, effect.opcode);
        append_le<int64_t>(bytes, effect.resolved_value);
        append_le<int32_t>(bytes, effect.duration_days);
        append_le<int32_t>(bytes, effect.stacks);
        append_string(bytes, effect.command_key);
        append_string(bytes, effect.definition_key);
        for (int p = 0; p < 4; ++p) append_le<int64_t>(bytes, effect.payload[p]);
    }
    append_le<uint32_t>(bytes, SAVE_END);
    packed.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(packed.ptrw(), bytes.data(), bytes.size());
    return packed;
}

Dictionary TriggerRuntime::restore(const PackedByteArray &packed) {
    if (!_configured) return failure("trigger_runtime_not_configured");
    const uint8_t *bytes = packed.ptr();
    const size_t size = static_cast<size_t>(packed.size());
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, source_count = 0, state_count = 0,
             pending_count = 0, effect_count = 0, end = 0;
    uint64_t catalog_hash = 0;
    int64_t current_day = -1, next_effect = 1, acked_effect = 0;
    if (!read_le(bytes, size, cursor, magic) ||
        !read_le(bytes, size, cursor, version) ||
        !read_le(bytes, size, cursor, catalog_hash) ||
        !read_le(bytes, size, cursor, current_day) ||
        !read_le(bytes, size, cursor, next_effect) ||
        !read_le(bytes, size, cursor, acked_effect) ||
        !read_le(bytes, size, cursor, source_count))
        return failure("trigger_restore_header_truncated");
    if (magic != SAVE_MAGIC)
        return failure("trigger_restore_magic_invalid");
    if (version != SAVE_SCHEMA_VERSION || catalog_hash != _catalog_hash ||
        source_count != static_cast<uint32_t>(_source_count))
        return failure("catalog_hash_mismatch");

    reset_runtime_state();
    _current_day = current_day;
    _next_effect_id = next_effect;
    _acked_effect_id = acked_effect;
    for (uint32_t source = 0; source < source_count; ++source) {
        if (!read_le(bytes, size, cursor, _source_cursor[source]) ||
            !read_le(bytes, size, cursor, _source_needs_resync[source]) ||
            !read_le(bytes, size, cursor, _source_gap_begin[source]) ||
            !read_le(bytes, size, cursor, _source_gap_end[source]))
            return failure("trigger_restore_source_truncated");
    }
    if (!read_le(bytes, size, cursor, state_count) ||
        state_count > static_cast<uint32_t>(_max_states))
        return failure("trigger_restore_state_count_invalid");
    for (uint32_t saved = 0; saved < state_count; ++saved) {
        std::string key;
        uint64_t target = 0;
        uint32_t generation = 0;
        if (!read_string(bytes, size, cursor, key) ||
            !read_le(bytes, size, cursor, target) ||
            !read_le(bytes, size, cursor, generation))
            return failure("trigger_restore_state_truncated");
        int32_t trigger_id = -1;
        for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i)
            if (_definitions[i].key == key) { trigger_id = i; break; }
        if (trigger_id < 0) return failure("trigger_restore_definition_missing");
        const int32_t state_index = find_or_create_state(trigger_id, target, generation);
        if (state_index < 0 ||
            !read_le(bytes, size, cursor, _state.accumulator[state_index]) ||
            !read_le(bytes, size, cursor, _state.remainder[state_index]) ||
            !read_le(bytes, size, cursor, _state.last_event_id[state_index]) ||
            !read_le(bytes, size, cursor, _state.fire_sequence[state_index]) ||
            !read_le(bytes, size, cursor, _state.cooldown_until[state_index]) ||
            !read_le(bytes, size, cursor, _state.window_start_day[state_index]) ||
            !read_le(bytes, size, cursor, _state.last_observed[state_index]) ||
            !read_le(bytes, size, cursor, _state.completed[state_index]) ||
            !read_le(bytes, size, cursor, _state.initialized[state_index]) ||
            !read_le(bytes, size, cursor, _state.needs_resync[state_index]))
            return failure("trigger_restore_state_payload_invalid");
        const size_t begin = static_cast<size_t>(state_index) * _distinct_capacity;
        for (int32_t d = 0; d < _distinct_capacity; ++d)
            if (!read_le(bytes, size, cursor, _distinct_keys[begin + d]))
                return failure("trigger_restore_distinct_truncated");
    }
    if (!read_le(bytes, size, cursor, pending_count) ||
        pending_count > static_cast<uint32_t>(_max_pending_events))
        return failure("trigger_restore_pending_count_invalid");
    for (uint32_t saved = 0; saved < pending_count; ++saved) {
        Event event;
        uint8_t snapshot = 0;
        if (!read_le(bytes, size, cursor, event.source_id) ||
            !read_le(bytes, size, cursor, event.event_id) ||
            !read_le(bytes, size, cursor, event.day) ||
            !read_le(bytes, size, cursor, event.event_type) ||
            !read_le(bytes, size, cursor, event.payload_schema) ||
            !read_le(bytes, size, cursor, event.entity_handle) ||
            !read_le(bytes, size, cursor, event.group_handle) ||
            !read_le(bytes, size, cursor, event.value))
            return failure("trigger_restore_pending_truncated");
        for (int p = 0; p < 4; ++p)
            if (!read_le(bytes, size, cursor, event.payload[p]))
                return failure("trigger_restore_pending_payload_truncated");
        if (!read_le(bytes, size, cursor, snapshot))
            return failure("trigger_restore_pending_flag_truncated");
        event.snapshot = snapshot != 0;
        _pending_events.push_back(event);
    }
    if (!read_le(bytes, size, cursor, effect_count) || effect_count > 1000000U)
        return failure("trigger_restore_effect_count_invalid");
    for (uint32_t saved = 0; saved < effect_count; ++saved) {
        Effect effect;
        std::string trigger_key;
        if (!read_le(bytes, size, cursor, effect.id) ||
            !read_le(bytes, size, cursor, effect.effective_day) ||
            !read_le(bytes, size, cursor, effect.source_priority) ||
            !read_string(bytes, size, cursor, trigger_key) ||
            !read_le(bytes, size, cursor, effect.target_handle) ||
            !read_le(bytes, size, cursor, effect.target_generation) ||
            !read_le(bytes, size, cursor, effect.fire_sequence) ||
            !read_le(bytes, size, cursor, effect.action) ||
            !read_le(bytes, size, cursor, effect.domain) ||
            !read_le(bytes, size, cursor, effect.opcode) ||
            !read_le(bytes, size, cursor, effect.resolved_value) ||
            !read_le(bytes, size, cursor, effect.duration_days) ||
            !read_le(bytes, size, cursor, effect.stacks) ||
            !read_string(bytes, size, cursor, effect.command_key) ||
            !read_string(bytes, size, cursor, effect.definition_key))
            return failure("trigger_restore_effect_truncated");
        effect.trigger_id = -1;
        for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i)
            if (_definitions[i].key == trigger_key) { effect.trigger_id = i; break; }
        if (effect.trigger_id < 0) return failure("trigger_restore_effect_definition_missing");
        for (int p = 0; p < 4; ++p)
            if (!read_le(bytes, size, cursor, effect.payload[p]))
                return failure("trigger_restore_effect_payload_truncated");
        _effects.push_back(std::move(effect));
    }
    if (!read_le(bytes, size, cursor, end) || end != SAVE_END || cursor != size)
        return failure("trigger_restore_end_invalid");
    Dictionary out = report();
    out["ok"] = true;
    return out;
}

Dictionary TriggerRuntime::clear_state() {
    if (!_configured) return failure("trigger_runtime_not_configured");
    reset_runtime_state();
    Dictionary out;
    out["ok"] = true;
    out["migration"] = "legacy_empty_trigger_state";
    return out;
}

} // namespace pk

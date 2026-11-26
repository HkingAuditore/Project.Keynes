#include "trigger_runtime.h"
#include "runtime_trigger_conditions.h"
#include "effect_runtime.h"
#include "economy_api.h"
#include "ideology_runtime.h"
#include "native_simulation_host.h"
#include "runtime_trigger_kernel.h"

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
#include <unordered_map>
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
    const PackedInt64Array qualifier_thresholds = get_i64(
        catalog, "qualifier_thresholds");
    const PackedInt32Array duration_fields = get_i32(catalog, "duration_fields");
    const PackedInt32Array development_metric_ids = get_i32(
        catalog, "development_metric_ids");
    const PackedInt32Array development_era_indices = get_i32(
        catalog, "development_era_indices");
    const PackedByteArray enabled = get_u8(catalog, "enabled");
    const PackedByteArray dynamic_bindings = get_u8(catalog, "dynamic_bindings");
    const PackedInt32Array selector_fields = get_i32(catalog, "selector_fields");
    const PackedInt64Array selector_values = get_i64(catalog, "selector_values");
    const PackedByteArray selector_negated = get_u8(catalog, "selector_negated");
    const PackedInt32Array condition_offsets = get_i32(catalog, "condition_offsets");
    const PackedInt32Array condition_ops = get_i32(catalog, "condition_ops");
    const PackedInt32Array effect_offsets = get_i32(catalog, "effect_offsets");

    if ((versions.size() != count || source_ids.size() != count ||
        event_types.size() != count || schemas.size() != count ||
        aggregators.size() != count || value_fields.size() != count ||
        distinct_fields.size() != count || scopes.size() != count ||
        target_resolvers.size() != count || static_targets.size() != count ||
        thresholds.size() != count || modes.size() != count ||
        cooldown_days.size() != count || window_days.size() != count ||
        qualifier_thresholds.size() != count || duration_fields.size() != count ||
        development_metric_ids.size() != count ||
        development_era_indices.size() != count || enabled.size() != count ||
        dynamic_bindings.size() != count || selector_fields.size() != count ||
        selector_values.size() != count || selector_negated.size() != count) ||
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
        definition.qualifier_threshold = i64_at(qualifier_thresholds, i, 0);
        definition.duration_field = i32_at(duration_fields, i, VALUE_ONE);
        definition.development_metric_id = i32_at(development_metric_ids, i, -1);
        definition.development_era_index = i32_at(development_era_indices, i, -1);
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
            definition.aggregator < COUNT || definition.aggregator > CONSECUTIVE_DURATION ||
            definition.value_field < VALUE_ONE || definition.value_field > GROUP_HANDLE ||
            definition.distinct_field < VALUE_ONE || definition.distinct_field > GROUP_HANDLE ||
            definition.scope < GLOBAL || definition.scope > ENTITY ||
            definition.target_resolver < TARGET_STATIC ||
            definition.target_resolver > TARGET_SNAPSHOT ||
            (definition.mode != REPEAT && definition.mode != ONE_SHOT) ||
            ((definition.aggregator == WINDOW_COUNT ||
              definition.aggregator == WINDOW_SUM) && definition.window_days <= 0) ||
            (definition.aggregator == CONSECUTIVE_DURATION &&
             (definition.duration_field < VALUE_ONE ||
              definition.duration_field > GROUP_HANDLE)) ||
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
        catalog_hash = fnv_mix(catalog_hash, &definition.qualifier_threshold,
                               sizeof(definition.qualifier_threshold));
        catalog_hash = fnv_mix(catalog_hash, &definition.duration_field,
                               sizeof(definition.duration_field));
        catalog_hash = fnv_mix(catalog_hash, &definition.development_metric_id,
                               sizeof(definition.development_metric_id));
        catalog_hash = fnv_mix(catalog_hash, &definition.development_era_index,
                               sizeof(definition.development_era_index));
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
    _pod_snapshot_generation = 0;
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
    _state.last_sample_day.assign(_max_states, -1);
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
            _state.last_sample_day[index] = -1;
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
    move(_state.last_sample_day);
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

#include "trigger_runtime_section_event_ingress.inc"

#include "trigger_runtime_section_daily_evaluation.inc"

#include "trigger_runtime_section_effect_transport.inc"

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

Dictionary TriggerRuntime::development_progress(uint64_t country_handle,
                                                int32_t era_index) const {
    Dictionary out;
    PackedInt32Array metric_ids;
    PackedInt64Array current_values, qualifier_thresholds;
    PackedInt64Array consecutive_days, last_sample_days;
    PackedInt32Array target_days, completed;
    for (int32_t trigger_id = 0;
         trigger_id < static_cast<int32_t>(_definitions.size()); ++trigger_id) {
        const Definition &definition = _definitions[trigger_id];
        if (definition.development_metric_id < 0 ||
            definition.development_era_index != era_index) continue;
        int32_t state_index = -1;
        for (int32_t index = 0; index < _state_count; ++index) {
            if (_state.trigger_id[index] == trigger_id &&
                _state.target_handle[index] == country_handle) {
                state_index = index;
                break;
            }
        }
        metric_ids.push_back(definition.development_metric_id);
        current_values.push_back(state_index >= 0
            ? _state.last_observed[state_index] : 0);
        qualifier_thresholds.push_back(definition.qualifier_threshold);
        consecutive_days.push_back(state_index >= 0
            ? _state.accumulator[state_index] : 0);
        last_sample_days.push_back(state_index >= 0
            ? _state.last_sample_day[state_index] : -1);
        target_days.push_back(static_cast<int32_t>(definition.threshold));
        completed.push_back(state_index >= 0
            ? _state.completed[state_index] : 0);
    }
    out["ok"] = true;
    out["country_handle"] = static_cast<int64_t>(country_handle);
    out["era_index"] = era_index;
    out["metric_ids"] = metric_ids;
    out["current_values"] = current_values;
    out["qualifier_thresholds"] = qualifier_thresholds;
    out["consecutive_days"] = consecutive_days;
    out["target_days"] = target_days;
    out["last_sample_days"] = last_sample_days;
    out["completed"] = completed;
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

#include "trigger_runtime_section_checkpoint.inc"

#include "trigger_runtime_section_pod_exchange.inc"

} // namespace pk

#include "effect_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "modifier_runtime.h"
#include "world_ext.h"
#include "parallel_dispatcher.h"

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_set>

namespace pk {

using namespace godot;

namespace {

constexpr uint32_t SAVE_MAGIC = 0x46454b50U; // PKEF
constexpr uint32_t SAVE_END = 0x21444e45U;
constexpr int32_t MAX_DEFINITIONS = 65536;
constexpr int32_t MAX_METRICS = 65536;
constexpr int32_t MAX_INSTRUCTIONS = 1048576;
constexpr int32_t MAX_COMMANDS = 1048576;
constexpr int32_t MAX_STACK = 256;

// Native Effect ABI registration.  These are deliberately fixed at startup
// rather than discovered from strings in the daily path.  Country/Economy
// opcodes mirror their authoritative runtime enums; gameplay/custom rows are
// routed through the native gameplay journal consumer below.
bool native_command_shape_valid(int32_t action, int32_t domain, int32_t opcode,
                                int32_t target_resolver, int32_t duration_days,
                                int32_t stacks, std::string &reason) {
    if (action < EffectRuntime::MODIFIER_COMMAND ||
        action > EffectRuntime::CUSTOM_DOMAIN_COMMAND) {
        reason = "effect_command_action_unregistered";
        return false;
    }
    if (domain < 0 || domain >= 32 || stacks <= 0 || duration_days < -1 ||
        target_resolver < EffectRuntime::TARGET_STATIC ||
        target_resolver > EffectRuntime::TARGET_SOURCE) {
        reason = "effect_command_layout_invalid";
        return false;
    }
    switch (action) {
        case EffectRuntime::MODIFIER_COMMAND:
            if (domain > 3 || (opcode != ModifierRuntime::COMMAND_APPLY &&
                               opcode != ModifierRuntime::COMMAND_REMOVE)) {
                reason = "effect_modifier_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::COUNTRY_COMMAND:
            if (domain != 1 || opcode < NativeCountryRuntime::COMMAND_CREATE_COUNTRY ||
                opcode > NativeCountryRuntime::COMMAND_DISCOVER_COUNTRY_SIGNAL) {
                reason = "effect_country_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::ECONOMY_COMMAND:
            if (domain != 2 || opcode < NativeEconomyRuntime::COMMAND_TRANSFER_TO_COHORT ||
                opcode > NativeEconomyRuntime::COMMAND_FAMILY_POPULATION_REWARD) {
                reason = "effect_economy_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::GAMEPLAY_COMMAND:
            if (domain != 3 || opcode <= 0) {
                reason = "effect_gameplay_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::PUBLISH_EVENT:
            if (domain != 4 || opcode <= 0) {
                reason = "effect_publish_event_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::CUSTOM_DOMAIN_COMMAND:
            // The first native custom consumer is the journal-backed audit
            // command. New custom domains must register a C++ adapter and add
            // an explicit shape check here before content can compile.
            if (domain != 6 || opcode != 1) {
                reason = "effect_custom_domain_adapter_unregistered";
                return false;
            }
            break;
        default:
            reason = "effect_command_action_unregistered";
            return false;
    }
    return true;
}

// Effect content has two domain concepts.  `Command::domain` names the target
// domain (and, for Modifier, its subdomain).  ACKs instead belong to the
// native adapter that crosses a distinct safe boundary.  Keep that mapping
// fixed and POD-only so a Country modifier cannot accidentally acknowledge a
// CountryRuntime command in the same transaction.
uint32_t native_adapter_ack_bit(int32_t action) {
    if (action < EffectRuntime::MODIFIER_COMMAND ||
        action > EffectRuntime::CUSTOM_DOMAIN_COMMAND)
        return 0;
    return 1u << static_cast<uint32_t>(action - EffectRuntime::MODIFIER_COMMAND);
}

std::unordered_map<std::string, EffectRuntime::BehaviorFn> &behavior_registry() {
    static std::unordered_map<std::string, EffectRuntime::BehaviorFn> registry;
    return registry;
}
std::mutex &behavior_registry_mutex() {
    static std::mutex mutex;
    return mutex;
}

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
    const uint64_t length = static_cast<uint64_t>(value.size());
    hash = fnv_mix(hash, &length, sizeof(length));
    return fnv_mix(hash, value.data(), value.size());
}

template <typename T>
uint64_t fnv_value(uint64_t hash, T value) {
    return fnv_mix(hash, &value, sizeof(T));
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

int32_t i32_at(const PackedInt32Array &values, int32_t index, int32_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

int64_t i64_at(const PackedInt64Array &values, int32_t index, int64_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

uint8_t u8_at(const PackedByteArray &values, int32_t index, uint8_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

std::string string_at(const PackedStringArray &values, int32_t index) {
    if (index < 0 || index >= values.size()) return {};
    return String(values[index]).utf8().get_data();
}

Dictionary failure(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = reason;
    return out;
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

int64_t mul_q16(int64_t a, int64_t b) {
    const long double value = static_cast<long double>(a) * static_cast<long double>(b) /
        static_cast<long double>(EffectRuntime::Q16_ONE);
    if (value > static_cast<long double>(std::numeric_limits<int64_t>::max()))
        return std::numeric_limits<int64_t>::max();
    if (value < static_cast<long double>(std::numeric_limits<int64_t>::min()))
        return std::numeric_limits<int64_t>::min();
    return static_cast<int64_t>(std::floor(value));
}

int64_t floor_div(int64_t a, int64_t b) {
    if (b == 0) return 0;
    int64_t q = a / b;
    int64_t r = a % b;
    if (r != 0 && ((r > 0) != (b > 0))) --q;
    return q;
}

uint64_t make_hash(uint64_t instance_id, uint32_t generation,
                   uint64_t fire_sequence, uint32_t command_index) {
    uint64_t hash = 1469598103934665603ULL;
    hash = fnv_value(hash, instance_id);
    hash = fnv_value(hash, generation);
    hash = fnv_value(hash, fire_sequence);
    hash = fnv_value(hash, command_index);
    return hash;
}

uint64_t splitmix64_next(uint64_t &state) {
    uint64_t z = (state += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27U)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31U);
}

} // namespace

bool EffectRuntime::register_behavior(const std::string &behavior_id,
                                      BehaviorFn fn) {
    if (behavior_id.empty() || fn == nullptr) return false;
    std::lock_guard<std::mutex> lock(behavior_registry_mutex());
    return behavior_registry().emplace(behavior_id, fn).second;
}

bool EffectRuntime::unregister_behavior(const std::string &behavior_id) {
    std::lock_guard<std::mutex> lock(behavior_registry_mutex());
    return behavior_registry().erase(behavior_id) != 0;
}

Dictionary EffectRuntime::configure(const Dictionary &catalog) {
    // A failed reconfigure must never leave a half-compiled catalog exposed
    // through the runtime facade. The next successful configure starts from a
    // clean lifecycle; callers must treat a failed configure as unavailable.
    _configured = false;
    _catalog_hash = 0;
    reset_runtime_state();
    if (int32_t(catalog.get("protocol_version", PROTOCOL_VERSION)) !=
        PROTOCOL_VERSION) return failure("effect_protocol_version_invalid");

    const PackedStringArray keys = get_strings(catalog, "effect_keys");
    const int32_t count = keys.size();
    if (count > MAX_DEFINITIONS) return failure("effect_definition_count_invalid");
    const PackedStringArray metric_keys = get_strings(catalog, "metric_keys");
    if (metric_keys.size() > MAX_METRICS) return failure("effect_metric_count_invalid");
    const PackedStringArray behavior_command_keys =
        get_strings(catalog, "behavior_command_keys");
    if (behavior_command_keys.size() > MAX_COMMANDS)
        return failure("effect_behavior_command_key_count_invalid");

    const PackedInt32Array versions = get_i32(catalog, "versions");
    const PackedInt32Array cadence_days = get_i32(catalog, "cadence_days");
    const PackedInt32Array max_work = get_i32(catalog, "max_work");
    const PackedByteArray enabled = get_u8(catalog, "enabled");
    const PackedStringArray behavior_keys = get_strings(catalog, "behavior_keys");
    const PackedInt32Array condition_offsets = get_i32(catalog, "condition_offsets");
    const PackedInt32Array condition_ops = get_i32(catalog, "condition_ops");
    const PackedInt32Array condition_arg0 = get_i32(catalog, "condition_arg0");
    const PackedInt64Array condition_values = get_i64(catalog, "condition_values");
    const PackedInt32Array instruction_offsets = get_i32(catalog, "instruction_offsets");
    const PackedInt32Array instruction_ops = get_i32(catalog, "instruction_ops");
    const PackedInt32Array instruction_arg0 = get_i32(catalog, "instruction_arg0");
    const PackedInt32Array instruction_arg1 = get_i32(catalog, "instruction_arg1");
    const PackedInt64Array instruction_values = get_i64(catalog, "instruction_values");
    const PackedInt32Array command_offsets = get_i32(catalog, "command_offsets");
    const PackedInt32Array command_actions = get_i32(catalog, "command_actions");
    const PackedInt32Array command_domains = get_i32(catalog, "command_domains");
    const PackedInt32Array command_opcodes = get_i32(catalog, "command_opcodes");
    const PackedInt32Array command_target_resolvers = get_i32(catalog, "command_target_resolvers");
    const PackedInt64Array command_static_targets = get_i64(catalog, "command_static_targets");
    const PackedInt32Array command_value_modes = get_i32(catalog, "command_value_modes");
    const PackedInt64Array command_values = get_i64(catalog, "command_values");
    const PackedInt32Array command_duration_days = get_i32(catalog, "command_duration_days");
    const PackedInt32Array command_stacks = get_i32(catalog, "command_stacks");
    const PackedStringArray command_keys = get_strings(catalog, "command_keys");
    const PackedStringArray command_definition_keys = get_strings(catalog, "command_definition_keys");
    const PackedInt64Array command_payload_i0 = get_i64(catalog, "command_payload_i0");
    const PackedInt64Array command_payload_i1 = get_i64(catalog, "command_payload_i1");
    const PackedInt64Array command_payload_i2 = get_i64(catalog, "command_payload_i2");
    const PackedInt64Array command_payload_i3 = get_i64(catalog, "command_payload_i3");

    if (condition_offsets.size() != count + 1 ||
        instruction_offsets.size() != count + 1 ||
        command_offsets.size() != count + 1 ||
        condition_ops.size() != condition_arg0.size() ||
        condition_ops.size() != condition_values.size() ||
        instruction_ops.size() != instruction_arg0.size() ||
        instruction_ops.size() != instruction_arg1.size() ||
        instruction_ops.size() != instruction_values.size() ||
        command_actions.size() != command_domains.size() ||
        command_actions.size() != command_opcodes.size() ||
        command_actions.size() != command_target_resolvers.size() ||
        command_actions.size() != command_static_targets.size() ||
        command_actions.size() != command_value_modes.size() ||
        command_actions.size() != command_values.size() ||
        command_actions.size() != command_duration_days.size() ||
        command_actions.size() != command_stacks.size() ||
        command_actions.size() != command_keys.size() ||
        command_actions.size() != command_definition_keys.size() ||
        command_actions.size() != command_payload_i0.size() ||
        command_actions.size() != command_payload_i1.size() ||
        command_actions.size() != command_payload_i2.size() ||
        command_actions.size() != command_payload_i3.size())
        return failure("effect_catalog_columns_invalid");
    auto valid_offsets = [](const PackedInt32Array &offsets, int32_t total) {
        if (offsets.is_empty() || offsets[0] != 0 || offsets[offsets.size() - 1] != total)
            return false;
        for (int32_t i = 1; i < offsets.size(); ++i) {
            if (offsets[i] < offsets[i - 1]) return false;
        }
        return true;
    };
    if (!valid_offsets(condition_offsets, condition_ops.size()) ||
        !valid_offsets(instruction_offsets, instruction_ops.size()) ||
        !valid_offsets(command_offsets, command_actions.size()))
        return failure("effect_catalog_offsets_invalid");
    if (condition_ops.size() > MAX_INSTRUCTIONS || instruction_ops.size() > MAX_INSTRUCTIONS ||
        command_actions.size() > MAX_COMMANDS)
        return failure("effect_catalog_capacity_invalid");

    _max_instances = std::max(1, int32_t(catalog.get("max_instances", 4096)));
    _max_transactions = std::max(1, int32_t(catalog.get("max_transactions", 8192)));
    _max_work_per_slice = std::max(1, int32_t(catalog.get("max_work_per_slice", 1024)));
    _max_native_modifier_commands = std::max(1, int32_t(
        catalog.get("max_native_modifier_commands", 4096)));
    if (_max_instances > 16000000 || _max_transactions > 16000000 ||
        _max_work_per_slice > 1000000 || _max_native_modifier_commands > 4000000)
        return failure("effect_runtime_capacity_invalid");

    _metric_keys.clear();
    _metric_ids.clear();
    for (int32_t i = 0; i < metric_keys.size(); ++i) {
        const std::string key = string_at(metric_keys, i);
        if (key.empty() || !_metric_ids.emplace(key, i).second)
            return failure("effect_metric_key_invalid_or_duplicate");
        _metric_keys.push_back(key);
    }
    _metric_count = static_cast<int32_t>(_metric_keys.size());
    _behavior_command_keys.clear();
    std::unordered_set<std::string> behavior_key_seen;
    _behavior_command_keys.reserve(behavior_command_keys.size());
    for (int32_t i = 0; i < behavior_command_keys.size(); ++i) {
        const std::string key = string_at(behavior_command_keys, i);
        if (key.empty() || !behavior_key_seen.emplace(key).second)
            return failure("effect_behavior_command_key_invalid_or_duplicate");
        _behavior_command_keys.push_back(key);
    }

    _definitions.clear();
    _definition_ids.clear();
    _conditions.clear();
    _instructions.clear();
    _command_definitions.clear();
    _behavior_command_buffer.clear();
    _definitions.reserve(count);
    _conditions.reserve(condition_ops.size());
    _instructions.reserve(instruction_ops.size());
    _command_definitions.reserve(command_actions.size());
    _behavior_command_buffer.resize(std::max(1, _max_work_per_slice));
    for (int32_t i = 0; i < count; ++i) {
        Definition definition;
        definition.key = string_at(keys, i);
        definition.version = i32_at(versions, i, 1);
        definition.cadence_days = std::max(1, i32_at(cadence_days, i, 1));
        definition.max_work = std::max(1, i32_at(max_work, i, _max_work_per_slice));
        definition.enabled = u8_at(enabled, i, 1);
        definition.behavior_id = string_at(behavior_keys, i);
        if (definition.key.empty() || definition.version <= 0 ||
            !_definition_ids.emplace(definition.key, i).second)
            return failure("effect_definition_key_invalid_or_duplicate");
        definition.condition_begin = i32_at(condition_offsets, i, 0);
        definition.condition_count = i32_at(condition_offsets, i + 1, 0) - definition.condition_begin;
        definition.instruction_begin = i32_at(instruction_offsets, i, 0);
        definition.instruction_count = i32_at(instruction_offsets, i + 1, 0) - definition.instruction_begin;
        definition.command_begin = i32_at(command_offsets, i, 0);
        definition.command_count = i32_at(command_offsets, i + 1, 0) - definition.command_begin;
        if (definition.condition_begin < 0 || definition.condition_count < 0 ||
            definition.condition_begin + definition.condition_count > condition_ops.size() ||
            definition.instruction_begin < 0 || definition.instruction_count < 0 ||
            definition.instruction_begin + definition.instruction_count > instruction_ops.size() ||
            definition.command_begin < 0 || definition.command_count < 0 ||
            definition.command_begin + definition.command_count > command_actions.size())
            return failure("effect_catalog_offsets_invalid");
        if (definition.behavior_id.empty() && definition.instruction_count == 0)
            return failure("effect_definition_has_no_program");
        _definitions.push_back(definition);
    }
    for (int32_t i = 0; i < condition_ops.size(); ++i) {
        Condition condition;
        condition.op = condition_ops[i];
        condition.arg0 = condition_arg0[i];
        condition.value = condition_values[i];
        if (condition.op < CONDITION_TRUE || condition.op > BOOL_NOT)
            return failure("effect_condition_opcode_invalid");
        if ((condition.op == METRIC_GTE || condition.op == METRIC_LTE ||
             condition.op == METRIC_EQ) &&
            (condition.arg0 < 0 || condition.arg0 >= _metric_count))
            return failure("effect_condition_metric_invalid");
        if (condition.op == STATE_GTE && (condition.arg0 < 0 || condition.arg0 > 2))
            return failure("effect_condition_state_invalid");
        _conditions.push_back(condition);
    }
    for (int32_t i = 0; i < instruction_ops.size(); ++i) {
        InstructionRow row;
        row.op = instruction_ops[i];
        row.arg0 = instruction_arg0[i];
        row.arg1 = instruction_arg1[i];
        row.value = instruction_values[i];
        if (row.op < CONST || row.op > END)
            return failure("effect_instruction_opcode_invalid");
        if (row.op == READ_METRIC && (row.arg0 < 0 || row.arg0 >= _metric_count))
            return failure("effect_instruction_metric_invalid");
        if (row.op == READ_STATE && (row.arg0 < 0 || row.arg0 > 2))
            return failure("effect_instruction_state_invalid");
        if (row.op == CLAMP && row.value > static_cast<int64_t>(row.arg0))
            return failure("effect_instruction_clamp_invalid");
        _instructions.push_back(row);
    }
    for (int32_t i = 0; i < command_actions.size(); ++i) {
        CommandDefinition command;
        command.action = command_actions[i];
        command.domain = command_domains[i];
        command.opcode = command_opcodes[i];
        command.target_resolver = command_target_resolvers[i];
        command.static_target = static_cast<uint64_t>(command_static_targets[i]);
        command.value_mode = command_value_modes[i];
        command.value = command_values[i];
        command.duration_days = command_duration_days[i];
        command.stacks = std::max(1, command_stacks[i]);
        command.command_key = string_at(command_keys, i);
        command.definition_key = string_at(command_definition_keys, i);
        if (command.action == MODIFIER_COMMAND) {
            if (command.command_key == "technology.modifier")
                command.native_modifier_adapter = NATIVE_MODIFIER_TECHNOLOGY;
            else if (command.command_key == "family.modifier")
                command.native_modifier_adapter = NATIVE_MODIFIER_FAMILY;
            else if (command.command_key == "person.modifier")
                command.native_modifier_adapter = NATIVE_MODIFIER_PERSON;
            else if (command.command_key == "trigger.modifier")
                command.native_modifier_adapter = NATIVE_MODIFIER_TRIGGER;
        }
        command.payload = {command_payload_i0[i], command_payload_i1[i],
                           command_payload_i2[i], command_payload_i3[i]};
        std::string command_error;
        if (!native_command_shape_valid(command.action, command.domain, command.opcode,
                command.target_resolver, command.duration_days, command.stacks,
                command_error) ||
            command.value_mode < VALUE_CONSTANT || command.value_mode > VALUE_STACK_TOP ||
            command.command_key.empty() ||
            (command.action != MODIFIER_COMMAND && command.definition_key.empty()) ||
            (command.target_resolver == TARGET_STATIC && command.static_target == 0))
            return failure(command_error.empty() ? "effect_command_definition_invalid"
                                                 : command_error.c_str());
        _command_definitions.push_back(command);
    }

    for (const Definition &definition : _definitions) {
        const int32_t declared_work = definition.condition_count +
            definition.instruction_count;
        if (declared_work > definition.max_work)
            return failure("effect_definition_work_exceeded");

        int32_t condition_depth = 0;
        for (int32_t i = definition.condition_begin;
             i < definition.condition_begin + definition.condition_count; ++i) {
            const int32_t op = _conditions[i].op;
            if (op == BOOL_AND || op == BOOL_OR) {
                if (condition_depth < 2) return failure("effect_condition_stack_invalid");
                --condition_depth;
            } else if (op == BOOL_NOT) {
                if (condition_depth < 1) return failure("effect_condition_stack_invalid");
            } else if (++condition_depth > MAX_STACK) {
                return failure("effect_condition_stack_invalid");
            }
        }
        if (definition.condition_count > 0 && condition_depth != 1)
            return failure("effect_condition_stack_invalid");

        int32_t value_depth = 0;
        for (int32_t i = definition.instruction_begin;
             i < definition.instruction_begin + definition.instruction_count; ++i) {
            const InstructionRow &row = _instructions[i];
            if (row.op == CONST || row.op == READ_METRIC || row.op == READ_STATE) {
                if (++value_depth > MAX_STACK)
                    return failure("effect_value_stack_invalid");
            } else if (row.op == ADD || row.op == SUB || row.op == MUL_Q16 ||
                       row.op == DIV_FLOOR || row.op == MIN || row.op == MAX) {
                if (value_depth < 2) return failure("effect_value_stack_invalid");
                --value_depth;
            } else if (row.op == CLAMP) {
                if (value_depth < 1) return failure("effect_value_stack_invalid");
            } else if (row.op == EMIT_COMMAND) {
                if (row.arg0 < 0 || row.arg0 >= definition.command_count)
                    return failure("effect_command_index_invalid");
                const CommandDefinition &command =
                    _command_definitions[definition.command_begin + row.arg0];
                if (command.value_mode == VALUE_STACK_TOP && value_depth < 1)
                    return failure("effect_value_stack_invalid");
            }
        }
    }

    std::string era_reward_error;
    if (!compile_era_reward_catalog(catalog, era_reward_error))
        return failure(era_reward_error.c_str());

    uint64_t hash = 1469598103934665603ULL;
    hash = fnv_value(hash, PROTOCOL_VERSION);
    hash = fnv_value(hash, _max_instances);
    hash = fnv_value(hash, _max_transactions);
    hash = fnv_value(hash, _max_work_per_slice);
    hash = fnv_value(hash, _max_native_modifier_commands);
    hash = fnv_value(hash, _metric_count);
    hash = fnv_value(hash, static_cast<int32_t>(_definitions.size()));
    for (const std::string &key : _metric_keys) hash = fnv_string(hash, key);
    for (const std::string &key : _behavior_command_keys) hash = fnv_string(hash, key);
    for (const Definition &definition : _definitions) {
        hash = fnv_string(hash, definition.key);
        hash = fnv_value(hash, definition.version);
        hash = fnv_value(hash, definition.cadence_days);
        hash = fnv_value(hash, definition.max_work);
        hash = fnv_value(hash, definition.enabled);
        hash = fnv_value(hash, definition.condition_begin);
        hash = fnv_value(hash, definition.condition_count);
        hash = fnv_value(hash, definition.instruction_begin);
        hash = fnv_value(hash, definition.instruction_count);
        hash = fnv_value(hash, definition.command_begin);
        hash = fnv_value(hash, definition.command_count);
        hash = fnv_string(hash, definition.behavior_id);
    }
    for (const Condition &condition : _conditions) {
        hash = fnv_value(hash, condition.op);
        hash = fnv_value(hash, condition.arg0);
        hash = fnv_value(hash, condition.value);
    }
    for (const InstructionRow &row : _instructions) {
        hash = fnv_value(hash, row.op);
        hash = fnv_value(hash, row.arg0);
        hash = fnv_value(hash, row.arg1);
        hash = fnv_value(hash, row.value);
    }
    for (const CommandDefinition &command : _command_definitions) {
        hash = fnv_value(hash, command.action);
        hash = fnv_value(hash, command.domain);
        hash = fnv_value(hash, command.opcode);
        hash = fnv_value(hash, command.target_resolver);
        hash = fnv_value(hash, command.static_target);
        hash = fnv_value(hash, command.value_mode);
        hash = fnv_value(hash, command.value);
        hash = fnv_value(hash, command.duration_days);
        hash = fnv_value(hash, command.stacks);
        hash = fnv_string(hash, command.command_key);
        hash = fnv_string(hash, command.definition_key);
        for (int64_t payload_value : command.payload)
            hash = fnv_value(hash, payload_value);
    }
    for (const EraRewardPool &pool : _era_reward_pools) {
        hash = fnv_string(hash, pool.id);
        hash = fnv_string(hash, pool.title);
        hash = fnv_value(hash, pool.trigger_technology);
        hash = fnv_value(hash, pool.final_pool);
    }
    for (const EraRewardOption &option : _era_reward_options) {
        hash = fnv_string(hash, option.id);
        hash = fnv_string(hash, option.title);
        hash = fnv_string(hash, option.description);
        hash = fnv_string(hash, option.icon);
        hash = fnv_value(hash, option.base_weight);
        hash = fnv_value(hash, option.fallback);
        hash = fnv_value(hash, option.eligibility_code);
        hash = fnv_value(hash, option.eligibility_threshold);
        hash = fnv_value(hash, option.program_id);
    }
    for (const EraRewardRule &rule : _era_reward_rules) {
        hash = fnv_value(hash, rule.code);
        hash = fnv_value(hash, rule.threshold);
        hash = fnv_value(hash, rule.multiplier_q16);
        hash = fnv_value(hash, rule.signal_index);
        hash = fnv_value(hash, rule.route_technology_begin);
        hash = fnv_value(hash, rule.route_technology_count);
        hash = fnv_string(hash, rule.reason);
    }
    for (int32_t technology : _era_reward_route_technology_indices)
        hash = fnv_value(hash, technology);
    _catalog_hash = hash;
    _configured = true;
    reset_runtime_state();
    Dictionary out;
    out["ok"] = true;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["definitions"] = count;
    out["metrics"] = _metric_count;
    return out;
}

bool EffectRuntime::compile_era_reward_catalog(const Dictionary &catalog,
                                               std::string &error) {
    _era_reward_pools.clear();
    _era_reward_options.clear();
    _era_reward_rules.clear();
    _era_reward_route_technology_indices.clear();
    _era_reward_pool_by_technology.clear();
    const PackedStringArray pool_ids = get_strings(catalog, "era_reward_pool_ids");
    // Focused Effect catalogs may intentionally omit the optional gameplay
    // extension. The production EffectDomainCatalog always supplies it and
    // the strict 11x9 validation below then applies.
    if (!catalog.has("era_reward_pool_ids")) return true;
    const auto reward_command_whitelisted = [](const CommandDefinition &command) {
        if (command.action == MODIFIER_COMMAND)
            return command.domain >= 0 && command.domain <= 3 &&
                (command.opcode == ModifierRuntime::COMMAND_APPLY ||
                 command.opcode == ModifierRuntime::COMMAND_REMOVE);
        if (command.action == COUNTRY_COMMAND)
            return command.domain == 1 &&
                command.opcode == NativeCountryRuntime::COMMAND_GRANT_TECHNOLOGY;
        if (command.action == ECONOMY_COMMAND)
            return command.domain == 2 && command.opcode >= 1 && command.opcode <= 8;
        if (command.action == GAMEPLAY_COMMAND || command.action == PUBLISH_EVENT)
            return command.opcode > 0;
        return false;
    };
    const PackedStringArray pool_titles = get_strings(catalog, "era_reward_pool_titles");
    const PackedInt32Array trigger_tech = get_i32(
        catalog, "era_reward_trigger_technology_indices");
    const PackedByteArray pool_final = get_u8(catalog, "era_reward_pool_final");
    const PackedInt32Array option_offsets = get_i32(
        catalog, "era_reward_option_offsets");
    const PackedStringArray option_ids = get_strings(catalog, "era_reward_option_ids");
    const PackedStringArray option_titles = get_strings(
        catalog, "era_reward_option_titles");
    const PackedStringArray option_descriptions = get_strings(
        catalog, "era_reward_option_descriptions");
    const PackedStringArray option_icons = get_strings(
        catalog, "era_reward_option_icons");
    const PackedInt32Array option_weights = get_i32(
        catalog, "era_reward_option_weights");
    const PackedByteArray option_fallback = get_u8(
        catalog, "era_reward_option_fallback");
    const PackedInt32Array eligibility_codes = get_i32(
        catalog, "era_reward_option_eligibility_codes");
    const PackedInt64Array eligibility_thresholds = get_i64(
        catalog, "era_reward_option_eligibility_thresholds");
    const PackedInt32Array rule_offsets = get_i32(catalog, "era_reward_rule_offsets");
    const PackedInt32Array rule_codes = get_i32(catalog, "era_reward_rule_codes");
    const PackedInt64Array rule_thresholds = get_i64(
        catalog, "era_reward_rule_thresholds");
    const PackedInt32Array rule_multipliers = get_i32(
        catalog, "era_reward_rule_multipliers_q16");
    const PackedStringArray rule_reasons = get_strings(
        catalog, "era_reward_rule_reasons");
    const PackedInt32Array rule_signal_indices = get_i32(
        catalog, "era_reward_rule_signal_indices");
    const PackedInt32Array rule_route_offsets = get_i32(
        catalog, "era_reward_rule_route_technology_offsets");
    const PackedInt32Array rule_route_technologies = get_i32(
        catalog, "era_reward_rule_route_technology_indices");
    const PackedInt32Array command_offsets = get_i32(
        catalog, "era_reward_command_offsets");
    const PackedStringArray command_definition_keys = get_strings(
        catalog, "era_reward_command_definition_keys");
    const PackedStringArray command_effect_keys = get_strings(
        catalog, "era_reward_command_effect_keys");
    const PackedInt32Array selector_entity_types = get_i32(
        catalog, "era_reward_selector_entity_types");
    const PackedInt32Array selector_filter_codes = get_i32(
        catalog, "era_reward_selector_filter_codes");
    const PackedInt32Array selector_rankings = get_i32(
        catalog, "era_reward_selector_rankings");
    const PackedInt32Array selector_top_n = get_i32(
        catalog, "era_reward_selector_top_n");
    const PackedInt32Array selector_minimum = get_i32(
        catalog, "era_reward_selector_minimum");
    if (pool_ids.size() != 11 || pool_titles.size() != 11 ||
        trigger_tech.size() != 11 || pool_final.size() != 11 ||
        option_offsets.size() != 12 || option_offsets[0] != 0 ||
        option_offsets[11] != 99 || option_ids.size() != 99 ||
        option_titles.size() != 99 || option_descriptions.size() != 99 ||
        option_icons.size() != 99 || option_weights.size() != 99 ||
        option_fallback.size() != 99 || eligibility_codes.size() != 99 ||
        eligibility_thresholds.size() != 99 || rule_offsets.size() != 100 ||
        command_offsets.size() != 100 || rule_offsets[0] != 0 ||
        command_offsets[0] != 0 ||
        rule_codes.size() != rule_thresholds.size() ||
        rule_codes.size() != rule_multipliers.size() ||
        rule_codes.size() != rule_reasons.size() ||
        rule_codes.size() != rule_signal_indices.size() ||
        rule_route_offsets.size() != rule_codes.size() + 1 ||
        rule_route_offsets[0] != 0 ||
        rule_route_offsets[rule_route_offsets.size() - 1] !=
            rule_route_technologies.size() ||
        command_definition_keys.size() != command_effect_keys.size() ||
        command_effect_keys.size() != selector_entity_types.size() ||
        command_effect_keys.size() != selector_filter_codes.size() ||
        command_effect_keys.size() != selector_rankings.size() ||
        command_effect_keys.size() != selector_top_n.size() ||
        command_effect_keys.size() != selector_minimum.size()) {
        error = "era_reward_catalog_shape_invalid";
        return false;
    }
    std::unordered_set<std::string> seen;
    for (int32_t pool_index = 0; pool_index < 11; ++pool_index) {
        const int32_t begin = option_offsets[pool_index];
        const int32_t end = option_offsets[pool_index + 1];
        if (end - begin != 9 || trigger_tech[pool_index] < 0 ||
            !_era_reward_pool_by_technology.emplace(
                trigger_tech[pool_index], pool_index).second) {
            error = "era_reward_pool_shape_invalid";
            return false;
        }
        EraRewardPool pool;
        pool.id = string_at(pool_ids, pool_index);
        pool.title = string_at(pool_titles, pool_index);
        pool.trigger_technology = trigger_tech[pool_index];
        pool.final_pool = pool_final[pool_index];
        pool.option_begin = begin;
        pool.option_count = end - begin;
        if (pool.id.empty() || pool.title.empty() || !seen.emplace(pool.id).second) {
            error = "era_reward_pool_identity_invalid";
            return false;
        }
        _era_reward_pools.push_back(std::move(pool));
    }
    seen.clear();
    for (int32_t option_index = 0; option_index < 99; ++option_index) {
        if (rule_offsets[option_index] > rule_offsets[option_index + 1] ||
            command_offsets[option_index] > command_offsets[option_index + 1] ||
            command_offsets[option_index + 1] - command_offsets[option_index] < 1 ||
            command_offsets[option_index + 1] - command_offsets[option_index] > 128) {
            error = "era_reward_option_offsets_invalid";
            return false;
        }
        const int32_t command_begin = command_offsets[option_index];
        int32_t expanded_bound = 0;
        int32_t program_id = -1;
        for (int32_t row = command_begin; row < command_offsets[option_index + 1]; ++row) {
            if (row < 0 || row >= command_effect_keys.size() ||
                string_at(command_definition_keys, row).empty() ||
                selector_entity_types[row] < 0 || selector_entity_types[row] > 6 ||
                selector_filter_codes[row] < 0 ||
                selector_rankings[row] < 0 || selector_rankings[row] > 4 ||
                selector_top_n[row] < 1 || selector_top_n[row] > 32 ||
                selector_minimum[row] < 1 ||
                selector_minimum[row] > selector_top_n[row]) {
                error = "era_reward_selector_invalid";
                return false;
            }
            if (option_fallback[option_index] != 0 &&
                (selector_entity_types[row] != 0 || selector_top_n[row] != 1)) {
                error = "era_reward_fallback_target_invalid";
                return false;
            }
            expanded_bound += selector_top_n[row];
            const auto found = _definition_ids.find(string_at(command_effect_keys, row));
            if (found == _definition_ids.end() ||
                (program_id >= 0 && program_id != found->second)) {
                error = "era_reward_effect_program_missing";
                return false;
            }
            program_id = found->second;
            const Definition &reward_definition = _definitions[
                static_cast<size_t>(program_id)];
            for (int32_t command_index = reward_definition.command_begin;
                 command_index < reward_definition.command_begin +
                     reward_definition.command_count; ++command_index) {
                if (command_index < 0 ||
                    command_index >= static_cast<int32_t>(_command_definitions.size()) ||
                    !reward_command_whitelisted(_command_definitions[
                        static_cast<size_t>(command_index)])) {
                    error = "era_reward_command_not_whitelisted";
                    return false;
                }
            }
        }
        if (expanded_bound > 128 || program_id < 0) {
            error = "era_reward_expanded_command_limit_invalid";
            return false;
        }
        EraRewardOption option;
        option.id = string_at(option_ids, option_index);
        option.title = string_at(option_titles, option_index);
        option.description = string_at(option_descriptions, option_index);
        option.icon = string_at(option_icons, option_index);
        option.base_weight = option_weights[option_index];
        option.fallback = option_fallback[option_index];
        option.eligibility_code = eligibility_codes[option_index];
        option.eligibility_threshold = eligibility_thresholds[option_index];
        option.rule_begin = rule_offsets[option_index];
        option.rule_count = rule_offsets[option_index + 1] - option.rule_begin;
        option.program_id = program_id;
        if (option.id.empty() || option.title.empty() || option.base_weight <= 0 ||
            !seen.emplace(option.id).second ||
            (option.fallback != 0 && option.eligibility_code != 0)) {
            error = "era_reward_option_identity_invalid";
            return false;
        }
        _era_reward_options.push_back(std::move(option));
    }
    if (rule_offsets[99] != rule_codes.size() ||
        command_offsets[99] != command_effect_keys.size()) {
        error = "era_reward_catalog_terminal_offset_invalid";
        return false;
    }
    for (int32_t row = 0; row < rule_codes.size(); ++row) {
        if (rule_codes[row] < 0 || rule_codes[row] > 6 ||
            rule_route_offsets[row] > rule_route_offsets[row + 1] ||
            rule_multipliers[row] <= 0 || rule_multipliers[row] > 262144) {
            error = "era_reward_weight_rule_invalid";
            return false;
        }
        if ((rule_codes[row] == 5 && rule_signal_indices[row] < 0) ||
            (rule_codes[row] == 6 &&
             rule_route_offsets[row] == rule_route_offsets[row + 1])) {
            error = "era_reward_context_rule_invalid";
            return false;
        }
        _era_reward_rules.push_back({rule_codes[row], rule_thresholds[row],
            rule_multipliers[row], rule_signal_indices[row],
            rule_route_offsets[row],
            rule_route_offsets[row + 1] - rule_route_offsets[row],
            string_at(rule_reasons, row)});
    }
    _era_reward_route_technology_indices.reserve(
        static_cast<size_t>(rule_route_technologies.size()));
    for (int32_t technology : rule_route_technologies) {
        if (technology < 0) {
            error = "era_reward_route_technology_invalid";
            return false;
        }
        _era_reward_route_technology_indices.push_back(technology);
    }
    for (const EraRewardPool &pool : _era_reward_pools) {
        int32_t fallbacks = 0;
        for (int32_t i = pool.option_begin;
             i < pool.option_begin + pool.option_count; ++i)
            fallbacks += _era_reward_options[i].fallback != 0 ? 1 : 0;
        if (fallbacks != 3) {
            error = "era_reward_fallback_count_invalid";
            return false;
        }
    }
    return true;
}

bool EffectRuntime::bind_era_reward_player_country_pod(uint64_t country_handle,
                                                       std::string &error) {
    if (!_configured || _country_runtime == nullptr) {
        error = "era_reward_runtime_unavailable";
        return false;
    }
    if (country_handle == 0 ||
        !_country_runtime->valid_handle(static_cast<int64_t>(country_handle))) {
        error = "era_reward_player_country_invalid";
        return false;
    }
    if (_era_reward_player_country != 0 &&
        _era_reward_player_country != country_handle &&
        _era_reward_offer.status != 0 && _era_reward_offer.status != 3) {
        error = "era_reward_player_rebind_while_offer_open";
        return false;
    }
    _era_reward_player_country = country_handle;
    return true;
}

bool EffectRuntime::notify_era_reward_technology_activated_pod(
        uint64_t country_handle, int32_t technology_id, int64_t day_index,
        std::string &error) {
    if (!_configured || _country_runtime == nullptr) {
        error = "era_reward_runtime_unavailable";
        return false;
    }
    if (_era_reward_player_country == 0 ||
        country_handle != _era_reward_player_country)
        return true;
    const auto found = _era_reward_pool_by_technology.find(technology_id);
    if (found == _era_reward_pool_by_technology.end()) return true;
    refresh_era_reward_offer_status();
    if (_era_reward_offer.status == 1 || _era_reward_offer.status == 2 ||
        _era_reward_offer.status == 4) {
        error = "era_reward_previous_offer_unresolved";
        return false;
    }
    return plan_era_reward_offer(found->second, country_handle, day_index, error);
}

bool EffectRuntime::era_reward_option_eligible(
        const EraRewardOption &option, int64_t cash, int32_t territory,
        int64_t completed, int64_t signals) const {
    switch (option.eligibility_code) {
        case 0: return true;
        case 1: return territory >= option.eligibility_threshold;
        case 2: return cash >= option.eligibility_threshold;
        case 3: return completed < option.eligibility_threshold;
        case 4: return signals >= option.eligibility_threshold;
        case 5: return false; // Requires a registered frozen goods selector.
        default: return false;
    }
}

int64_t EffectRuntime::era_reward_option_weight(
        const EraRewardOption &option, int64_t cash, int32_t territory,
        int64_t completed, int64_t signals,
        const PackedInt32Array &signal_counts,
        const PackedInt32Array &technology_states,
        std::array<std::string, 2> &reasons, int32_t &reason_count) const {
    int64_t weight = option.base_weight;
    reason_count = 0;
    struct Hit { int64_t impact = 0; std::string reason; };
    std::vector<Hit> hits;
    for (int32_t i = option.rule_begin;
         i < option.rule_begin + option.rule_count; ++i) {
        const EraRewardRule &rule = _era_reward_rules[static_cast<size_t>(i)];
        bool hit = false;
        switch (rule.code) {
            case 0: hit = true; break;
            case 1: hit = cash < std::max<int64_t>(1, territory) * 500000; break;
            case 2: hit = territory >= rule.threshold; break;
            case 3: hit = completed < 64; break;
            case 4: hit = signals >= rule.threshold; break;
            case 5:
                hit = rule.signal_index >= 0 &&
                    rule.signal_index < signal_counts.size() &&
                    signal_counts[rule.signal_index] > 0;
                break;
            case 6:
                for (int32_t route = rule.route_technology_begin;
                     route < rule.route_technology_begin +
                         rule.route_technology_count; ++route) {
                    if (route < 0 || route >= static_cast<int32_t>(
                            _era_reward_route_technology_indices.size()))
                        continue;
                    const int32_t technology =
                        _era_reward_route_technology_indices[
                            static_cast<size_t>(route)];
                    if (technology >= 0 && technology < technology_states.size() &&
                        technology_states[technology] >= 4) {
                        hit = true;
                        break;
                    }
                }
                break;
            default: break;
        }
        if (!hit) continue;
        const int64_t before = weight;
        weight = std::max<int64_t>(1, mul_q16(weight, rule.multiplier_q16));
        if (!rule.reason.empty())
            hits.push_back({std::llabs(weight - before), rule.reason});
    }
    std::stable_sort(hits.begin(), hits.end(), [](const Hit &lhs, const Hit &rhs) {
        if (lhs.impact != rhs.impact) return lhs.impact > rhs.impact;
        return lhs.reason < rhs.reason;
    });
    reason_count = std::min<int32_t>(2, static_cast<int32_t>(hits.size()));
    for (int32_t i = 0; i < reason_count; ++i) reasons[i] = hits[i].reason;
    return weight;
}

bool EffectRuntime::plan_era_reward_offer(int32_t pool_index,
                                          uint64_t country_handle,
                                          int64_t day_index,
                                          std::string &error) {
    const auto plan_start = std::chrono::steady_clock::now();
    if (pool_index < 0 || pool_index >= static_cast<int32_t>(_era_reward_pools.size()) ||
        _country_runtime == nullptr ||
        !_country_runtime->valid_handle(static_cast<int64_t>(country_handle))) {
        error = "era_reward_plan_input_invalid";
        return false;
    }
    const Dictionary country = _country_runtime->country_snapshot(
        static_cast<int64_t>(country_handle));
    const Dictionary treasury = _country_runtime->treasury_snapshot(
        static_cast<int64_t>(country_handle));
    const Dictionary research = _country_runtime->research_snapshot(
        static_cast<int64_t>(country_handle));
    const Dictionary signals_snapshot = _country_runtime->research_signal_snapshot(
        static_cast<int64_t>(country_handle));
    if (!static_cast<bool>(country.get("ok", false)) ||
        !static_cast<bool>(treasury.get("ok", false)) ||
        !static_cast<bool>(research.get("ok", false)) ||
        !static_cast<bool>(signals_snapshot.get("ok", false))) {
        error = "era_reward_frozen_snapshot_unavailable";
        return false;
    }
    const PackedInt32Array territory_cells = country.get(
        "territory_cells", PackedInt32Array());
    const int32_t territory = territory_cells.size();
    const int64_t cash = treasury.get("cash", 0);
    const int64_t completed = research.get("completed_total", 0);
    const PackedInt32Array evidence_signal_ids = signals_snapshot.get(
        "signal_ids", PackedInt32Array());
    const PackedInt32Array evidence_signal_counts = signals_snapshot.get(
        "counts", PackedInt32Array());
    PackedInt32Array signal_counts;
    int32_t maximum_signal = -1;
    for (int32_t i = 0; i < evidence_signal_ids.size(); ++i)
        maximum_signal = std::max(maximum_signal, evidence_signal_ids[i]);
    if (maximum_signal >= 0) signal_counts.resize(maximum_signal + 1);
    const PackedInt32Array technology_states = research.get(
        "technology_states", PackedInt32Array());
    int64_t signals = 0;
    for (int32_t i = 0; i < evidence_signal_ids.size(); ++i) {
        const int32_t signal = evidence_signal_ids[i];
        const int32_t count = i < evidence_signal_counts.size()
            ? evidence_signal_counts[i] : 0;
        if (signal >= 0 && signal < signal_counts.size())
            signal_counts.set(signal, count);
        signals += count;
    }
    const EraRewardPool &pool = _era_reward_pools[static_cast<size_t>(pool_index)];
    struct WeightedCandidate {
        int32_t option = -1;
        int64_t weight = 0;
        std::array<std::string, 2> reasons{};
        int32_t reason_count = 0;
    };
    std::vector<WeightedCandidate> normal;
    std::vector<WeightedCandidate> fallbacks;
    for (int32_t option_index = pool.option_begin;
         option_index < pool.option_begin + pool.option_count; ++option_index) {
        const EraRewardOption &option = _era_reward_options[
            static_cast<size_t>(option_index)];
        if (!era_reward_option_eligible(option, cash, territory, completed, signals))
            continue;
        WeightedCandidate candidate;
        candidate.option = option_index;
        candidate.weight = era_reward_option_weight(option, cash, territory,
            completed, signals, signal_counts, technology_states,
            candidate.reasons, candidate.reason_count);
        (option.fallback != 0 ? fallbacks : normal).push_back(std::move(candidate));
    }
    uint64_t seed = static_cast<uint64_t>(_country_runtime->world_seed());
    seed = fnv_string(seed, String(country.get("country_id", "")).utf8().get_data());
    seed = fnv_string(seed, pool.id);
    seed = fnv_value(seed, _era_reward_next_generation);
    std::array<WeightedCandidate, 3> selected{};
    int32_t selected_count = 0;
    while (selected_count < 3 && !normal.empty()) {
        uint64_t total = 0;
        for (const WeightedCandidate &candidate : normal)
            total += static_cast<uint64_t>(std::max<int64_t>(1, candidate.weight));
        const uint64_t pick = total > 0 ? splitmix64_next(seed) % total : 0;
        uint64_t cursor = 0;
        size_t chosen = 0;
        for (; chosen < normal.size(); ++chosen) {
            cursor += static_cast<uint64_t>(std::max<int64_t>(1, normal[chosen].weight));
            if (pick < cursor) break;
        }
        if (chosen >= normal.size()) chosen = normal.size() - 1;
        selected[selected_count++] = normal[chosen];
        normal.erase(normal.begin() + static_cast<ptrdiff_t>(chosen));
    }
    while (selected_count < 3 && !fallbacks.empty()) {
        const size_t chosen = static_cast<size_t>(
            splitmix64_next(seed) % fallbacks.size());
        selected[selected_count++] = fallbacks[chosen];
        fallbacks.erase(fallbacks.begin() + static_cast<ptrdiff_t>(chosen));
    }
    if (selected_count != 3) {
        error = "era_reward_offer_cannot_fill_three";
        return false;
    }
    EraRewardOffer offer;
    offer.plan_id = _era_reward_next_plan_id++;
    offer.generation = _era_reward_next_generation++;
    offer.pool_index = pool_index;
    offer.milestone_technology = pool.trigger_technology;
    offer.country_handle = country_handle;
    offer.country_generation = static_cast<uint32_t>(country_handle >> 32U);
    offer.status = 1;
    offer.plan_hash = 1469598103934665603ULL;
    offer.plan_hash = fnv_value(offer.plan_hash, offer.plan_id);
    offer.plan_hash = fnv_value(offer.plan_hash, offer.generation);
    offer.plan_hash = fnv_value(offer.plan_hash, day_index);
    offer.plan_hash = fnv_string(offer.plan_hash, pool.id);
    for (int32_t i = 0; i < 3; ++i) {
        EraRewardAlternative &alternative = offer.alternatives[i];
        alternative.option_index = selected[i].option;
        alternative.weight = selected[i].weight;
        alternative.target_handle = country_handle;
        alternative.target_generation = offer.country_generation;
        alternative.reasons = selected[i].reasons;
        alternative.reason_count = selected[i].reason_count;
        alternative.target_summary = String(country.get("country_name", "")).utf8().get_data();
        const EraRewardOption &option = _era_reward_options[
            static_cast<size_t>(alternative.option_index)];
        offer.plan_hash = fnv_string(offer.plan_hash, option.id);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.weight);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.target_handle);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.target_generation);
        for (int32_t reason = 0; reason < alternative.reason_count; ++reason)
            offer.plan_hash = fnv_string(offer.plan_hash, alternative.reasons[reason]);
    }
    _era_reward_offer = std::move(offer);
    _last_era_reward_expanded_commands = 0;
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        const int32_t option_index = alternative.option_index;
        if (option_index < 0 ||
            option_index >= static_cast<int32_t>(_era_reward_options.size()))
            continue;
        const int32_t program_id = _era_reward_options[
            static_cast<size_t>(option_index)].program_id;
        if (program_id >= 0 && program_id < static_cast<int32_t>(_definitions.size()))
            _last_era_reward_expanded_commands += _definitions[
                static_cast<size_t>(program_id)].command_count;
    }
    _last_era_reward_plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - plan_start).count();
    ++_era_reward_offers_planned;
    _country_runtime->set_era_reward_reference_pod(
        _era_reward_offer.plan_id, _era_reward_offer.generation,
        _era_reward_offer.milestone_technology, _era_reward_offer.status);
    return true;
}

Dictionary EffectRuntime::choose_era_reward(int64_t offer_generation,
                                             int32_t choice_index,
                                             int64_t effective_day) {
    refresh_era_reward_offer_status();
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (_era_reward_offer.status != 1 ||
        _era_reward_offer.generation != offer_generation)
        return failure("era_reward_offer_generation_stale");
    if (choice_index < 0 || choice_index >= 3 || effective_day < 0)
        return failure("era_reward_choice_invalid");
    const EraRewardAlternative &alternative =
        _era_reward_offer.alternatives[static_cast<size_t>(choice_index)];
    if (alternative.option_index < 0 ||
        alternative.option_index >= static_cast<int32_t>(_era_reward_options.size()))
        return failure("era_reward_frozen_alternative_invalid");
    const EraRewardOption &option = _era_reward_options[
        static_cast<size_t>(alternative.option_index)];
    if (option.program_id < 0 ||
        option.program_id >= static_cast<int32_t>(_definitions.size()))
        return failure("era_reward_program_invalid");
    const Definition &definition = _definitions[static_cast<size_t>(option.program_id)];
    const int64_t instance_id = static_cast<int64_t>(
        0x4552410000000000ULL | (static_cast<uint64_t>(_era_reward_offer.plan_id) &
                                0x000000ffffffffffULL));
    std::string error;
    if (!upsert_instance_pod(instance_id, definition.key, 1, 0x45524152,
            _era_reward_offer.generation, _era_reward_offer.country_handle,
            alternative.target_handle, alternative.target_generation, 0,
            effective_day, false, error))
        return failure(error.c_str());
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions)
            return failure("effect_transaction_capacity_exceeded");
    }
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = instance_id;
    transaction.source_generation = 1;
    transaction.program_id = option.program_id;
    transaction.effective_day = effective_day;
    for (int32_t ordinal = 0; ordinal < definition.command_count; ++ordinal) {
        const int32_t command_definition_id = definition.command_begin + ordinal;
        const CommandDefinition &source = _command_definitions[
            static_cast<size_t>(command_definition_id)];
        Command command;
        command.action = source.action;
        command.domain = source.domain;
        command.opcode = source.opcode;
        command.target_handle = alternative.target_handle;
        command.target_generation = alternative.target_generation;
        command.value_q16 = source.value;
        command.duration_days = source.duration_days;
        command.stacks = source.stacks;
        command.command_key_id = command_definition_id;
        command.command_definition_id = command_definition_id;
        command.payload = source.payload;
        command.idempotency_key = make_hash(
            static_cast<uint64_t>(instance_id), 1,
            static_cast<uint64_t>(_era_reward_offer.generation), ordinal);
        append_command(transaction, command);
    }
    if (transaction.command_count == 0 || transaction.command_count > 128)
        return failure("era_reward_transaction_command_count_invalid");
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_instance_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.program_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.effective_day);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *stored = command_at(transaction, ordinal);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_generation);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->value_q16);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->duration_days);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->stacks);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->command_key_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->command_definition_id);
        for (int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->idempotency_key);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    _era_reward_offer.status = 2;
    _era_reward_offer.selected_choice = choice_index;
    _era_reward_offer.transaction_id = _transactions.back().id;
    if (_country_runtime != nullptr)
        _country_runtime->set_era_reward_reference_pod(
            _era_reward_offer.plan_id, _era_reward_offer.generation,
            _era_reward_offer.milestone_technology, _era_reward_offer.status);
    Dictionary out;
    out["ok"] = true;
    out["offer_generation"] = offer_generation;
    out["choice_index"] = choice_index;
    out["transaction_id"] = _era_reward_offer.transaction_id;
    return out;
}

void EffectRuntime::refresh_era_reward_offer_status() {
    if (_era_reward_offer.status != 2 || _era_reward_offer.transaction_id <= 0)
        return;
    const int32_t status = transaction_status_pod(
        _era_reward_offer.transaction_id);
    if (status == ACKED) {
        _era_reward_offer.status = 3;
    } else if (status == REJECTED || status == RESYNC_REQUIRED || status == 0) {
        _era_reward_offer.status = 4;
        _era_reward_offer.error = status == RESYNC_REQUIRED
            ? "era_reward_resync_required" : "era_reward_transaction_rejected";
    }
    if (_country_runtime != nullptr &&
        (_era_reward_offer.status == 3 || _era_reward_offer.status == 4))
        _country_runtime->set_era_reward_reference_pod(
            _era_reward_offer.plan_id, _era_reward_offer.generation,
            _era_reward_offer.milestone_technology, _era_reward_offer.status);
}

Dictionary EffectRuntime::era_reward_offer_snapshot() {
    refresh_era_reward_offer_status();
    Dictionary out;
    out["ok"] = true;
    const char *status = "NONE";
    if (_era_reward_offer.status == 1) status = "OPEN";
    else if (_era_reward_offer.status == 2) status = "SELECTED_PENDING";
    else if (_era_reward_offer.status == 3) status = "RESOLVED";
    else if (_era_reward_offer.status == 4) status = "ERROR";
    out["status"] = status;
    out["plan_id"] = _era_reward_offer.plan_id;
    out["offer_generation"] = _era_reward_offer.generation;
    out["country_handle"] = static_cast<int64_t>(_era_reward_offer.country_handle);
    out["milestone_technology"] = _era_reward_offer.milestone_technology;
    out["selected_choice"] = _era_reward_offer.selected_choice;
    out["transaction_id"] = _era_reward_offer.transaction_id;
    out["plan_hash"] = static_cast<int64_t>(_era_reward_offer.plan_hash);
    out["error"] = String(_era_reward_offer.error.c_str());
    if (_era_reward_offer.pool_index >= 0 &&
        _era_reward_offer.pool_index < static_cast<int32_t>(_era_reward_pools.size())) {
        const EraRewardPool &pool = _era_reward_pools[
            static_cast<size_t>(_era_reward_offer.pool_index)];
        out["pool_id"] = String(pool.id.c_str());
        out["era_title"] = String::utf8(pool.title.c_str());
        out["final_pool"] = pool.final_pool != 0;
    }
    Array alternatives;
    if (_era_reward_offer.status != 0) {
        for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
            if (alternative.option_index < 0 || alternative.option_index >=
                static_cast<int32_t>(_era_reward_options.size())) continue;
            const EraRewardOption &option = _era_reward_options[
                static_cast<size_t>(alternative.option_index)];
            Dictionary row;
            row["option_id"] = String(option.id.c_str());
            row["title"] = String::utf8(option.title.c_str());
            row["description"] = String::utf8(option.description.c_str());
            row["icon_id"] = String(option.icon.c_str());
            row["weight"] = alternative.weight;
            row["target_handle"] = static_cast<int64_t>(alternative.target_handle);
            row["target_generation"] = static_cast<int64_t>(
                alternative.target_generation);
            row["target_summary"] = String::utf8(alternative.target_summary.c_str());
            PackedStringArray reasons;
            for (int32_t i = 0; i < alternative.reason_count; ++i)
                reasons.push_back(String::utf8(alternative.reasons[i].c_str()));
            row["reasons"] = reasons;
            alternatives.push_back(row);
        }
    }
    out["alternatives"] = alternatives;
    return out;
}

void EffectRuntime::reset_runtime_state() {
    _current_day = -1;
    _last_completed_day = -1;
    _run_day = -1;
    _run_cursor = 0;
    _next_transaction_id = 1;
    _acked_transaction_id = 0;
    _instances.clear();
    _free_instance_indices.clear();
    _instance_ids.clear();
    _metric_values.clear();
    _metric_present.clear();
    _dirty_queue.clear();
    _dirty_epoch_counter = 1;
    while (!_due_heap.empty()) _due_heap.pop();
    _run_candidates.clear();
    _candidate_cursor = 0;
    _schedule_token = 1;
    _command_arena.clear();
    _transactions.clear();
    _transaction_ids.clear();
    _pending_transactions_by_instance.clear();
    _pending_command_idempotency.clear();
    _native_request_ids.clear();
    _native_ack_bindings.clear();
    _native_bound_transaction_ids.clear();
    _native_country_request_ids.clear();
    _native_country_ack_bindings.clear();
    _native_country_bound_transaction_ids.clear();
    _native_economy_request_ids.clear();
    _native_economy_ack_bindings.clear();
    _native_economy_bound_transaction_ids.clear();
    _native_gameplay_request_ids.clear();
    _native_gameplay_ack_bindings.clear();
    _native_gameplay_bound_transaction_ids.clear();
    _external_bindings.clear();
    _external_binding_ids.clear();
    _era_reward_player_country = 0;
    _era_reward_next_plan_id = 1;
    _era_reward_next_generation = 1;
    _era_reward_offer = EraRewardOffer{};
    _last_era_reward_plan_ms = 0.0;
    _era_reward_offers_planned = 0;
    _last_era_reward_expanded_commands = 0;
    _instances_submitted = 0;
    _programs_evaluated = 0;
    _commands_emitted = 0;
    _transactions_acked = 0;
    _preflight_rejects = 0;
    _behavior_failures = 0;
    _overflow_count = 0;
    _native_modifier_transactions = 0;
    _native_modifier_commands = 0;
    _native_modifier_acks = 0;
    _native_country_transactions = 0;
    _native_country_commands = 0;
    _native_country_acks = 0;
    _native_economy_transactions = 0;
    _native_economy_commands = 0;
    _native_economy_acks = 0;
    _native_gameplay_transactions = 0;
    _native_gameplay_commands = 0;
    _native_gameplay_acks = 0;
    _last_native_dispatch_ms = 0.0;
    _last_native_ack_ms = 0.0;
    _last_parallel_planning_ms = 0.0;
    _last_parallel_merge_ms = 0.0;
    _last_parallel_worker_count = 1;
    _parallel_dispatches = 0;
    _serial_fallback_dispatches = 0;
    _last_parallel_path = "serial";
    _last_parallel_fallback_reason.clear();
    _last_error.clear();
}

int64_t *EffectRuntime::metric_ptr(Instance &instance, int32_t metric_id) {
    if (metric_id < 0 || metric_id >= _metric_count) return nullptr;
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    return offset < _metric_values.size() ? &_metric_values[offset] : nullptr;
}

const int64_t *EffectRuntime::metric_ptr(const Instance &instance,
                                         int32_t metric_id) const {
    if (metric_id < 0 || metric_id >= _metric_count) return nullptr;
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    return offset < _metric_values.size() ? &_metric_values[offset] : nullptr;
}

void EffectRuntime::schedule_instance(int32_t index, int64_t day) {
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return;
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (!instance.active || instance.generation == 0) return;
    const uint64_t token = _schedule_token++;
    instance.schedule_token = token;
    _due_heap.push({day, index, instance.generation, token});
    compact_due_heap_if_needed();
}

void EffectRuntime::compact_due_heap_if_needed() {
    const size_t threshold = std::max<size_t>(1024, _instances.size() * 4 + 1024);
    if (_due_heap.size() <= threshold) return;
    std::priority_queue<DueNode, std::vector<DueNode>, std::greater<DueNode>> compacted;
    for (int32_t index = 0; index < static_cast<int32_t>(_instances.size()); ++index) {
        Instance &instance = _instances[static_cast<size_t>(index)];
        if (!instance.active || instance.generation == 0) continue;
        if (instance.schedule_token == 0) instance.schedule_token = _schedule_token++;
        compacted.push({instance.next_due_day, index, instance.generation,
                        instance.schedule_token});
    }
    _due_heap.swap(compacted);
}

void EffectRuntime::mark_dirty(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return;
    if (_dirty_epoch_counter == 0) {
        for (Instance &instance : _instances) instance.dirty_epoch = 0;
        _dirty_epoch_counter = 1;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.dirty_epoch == _dirty_epoch_counter) return;
    instance.dirty_epoch = _dirty_epoch_counter;
    _dirty_queue.push_back(index);
}

void EffectRuntime::rebuild_run_candidates(int64_t day_index) {
    _run_candidates.clear();
    ++_dirty_epoch_counter;
    if (_dirty_epoch_counter == 0) {
        for (Instance &instance : _instances) instance.dirty_epoch = 0;
        _dirty_epoch_counter = 1;
    }
    while (!_due_heap.empty() && _due_heap.top().day <= day_index) {
        const DueNode node = _due_heap.top();
        _due_heap.pop();
        if (node.instance_index < 0 ||
            node.instance_index >= static_cast<int32_t>(_instances.size())) continue;
        Instance &instance = _instances[static_cast<size_t>(node.instance_index)];
        if (!instance.active || instance.generation != node.generation ||
            instance.next_due_day > day_index ||
            instance.schedule_token != node.schedule_token) continue;
        if (instance.dirty_epoch != _dirty_epoch_counter) {
            instance.dirty_epoch = _dirty_epoch_counter;
            _run_candidates.push_back(node.instance_index);
        }
    }
    for (const int32_t index : _dirty_queue) {
        if (index < 0 || index >= static_cast<int32_t>(_instances.size())) continue;
        Instance &instance = _instances[static_cast<size_t>(index)];
        if (!instance.active) continue;
        if (instance.dirty_epoch != _dirty_epoch_counter) {
            instance.dirty_epoch = _dirty_epoch_counter;
            _run_candidates.push_back(index);
        }
    }
    _dirty_queue.clear();
    std::sort(_run_candidates.begin(), _run_candidates.end(),
        [&](int32_t a, int32_t b) {
            const Instance &lhs = _instances[static_cast<size_t>(a)];
            const Instance &rhs = _instances[static_cast<size_t>(b)];
            if (lhs.program_id != rhs.program_id) return lhs.program_id < rhs.program_id;
            if (lhs.id != rhs.id) return lhs.id < rhs.id;
            return a < b;
        });
    _run_candidates.erase(std::unique(_run_candidates.begin(), _run_candidates.end()),
                          _run_candidates.end());
    _candidate_cursor = 0;
}

int32_t EffectRuntime::definition_id_for_key(const std::string &key) const {
    auto it = _definition_ids.find(key);
    return it == _definition_ids.end() ? -1 : it->second;
}

int32_t EffectRuntime::instance_index_for_id(int64_t id) const {
    auto it = _instance_ids.find(id);
    return it == _instance_ids.end() ? -1 : it->second;
}

bool EffectRuntime::upsert_instance_pod(int64_t instance_id,
                                        const std::string &program_key,
                                        uint32_t generation,
                                        int32_t source_type,
                                        int64_t source_id,
                                        uint64_t source_handle,
                                        uint64_t target_handle,
                                        uint32_t target_generation,
                                        int32_t level,
                                        int64_t next_due_day,
                                        bool active,
                                        std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (instance_id <= 0 || generation == 0) {
        error = "effect_instance_identity_invalid"; return false;
    }
    const int32_t program_id = definition_id_for_key(program_key);
    if (program_id < 0) { error = "effect_program_unknown"; return false; }
    int32_t index = instance_index_for_id(instance_id);
    if (index < 0) {
        if (static_cast<int32_t>(_instance_ids.size()) >= _max_instances) {
            ++_overflow_count; error = "effect_instance_capacity_exceeded"; return false;
        }
        if (!_free_instance_indices.empty()) {
            index = _free_instance_indices.back();
            _free_instance_indices.pop_back();
            Instance &slot = _instances[static_cast<size_t>(index)];
            const uint32_t metric_base = slot.metric_base;
            slot = Instance{};
            slot.metric_base = metric_base;
            std::fill(_metric_values.begin() + metric_base,
                      _metric_values.begin() + metric_base + _metric_count, 0);
            std::fill(_metric_present.begin() + metric_base,
                      _metric_present.begin() + metric_base + _metric_count, 0);
        } else {
            Instance instance;
            instance.metric_base = static_cast<uint32_t>(_metric_values.size());
            _metric_values.resize(_metric_values.size() + static_cast<size_t>(_metric_count), 0);
            _metric_present.resize(_metric_present.size() + static_cast<size_t>(_metric_count), 0);
            _instances.push_back(std::move(instance));
            index = static_cast<int32_t>(_instances.size() - 1);
        }
        Instance &slot = _instances[static_cast<size_t>(index)];
        slot.id = instance_id;
        slot.generation = generation;
        slot.program_id = program_id;
        _instance_ids[instance_id] = index;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    const bool generation_changed = instance.generation != generation;
    instance.generation = generation;
    instance.program_id = program_id;
    instance.source_type = source_type;
    instance.source_id = source_id;
    instance.source_handle = source_handle;
    instance.target_handle = target_handle;
    instance.target_generation = target_generation;
    instance.level = level;
    instance.next_due_day = next_due_day;
    instance.active = active ? 1 : 0;
    if (generation_changed) {
        for (Transaction &transaction : _transactions) {
            if (transaction.source_instance_id == instance.id &&
                transaction.source_generation != generation &&
                transaction.status != ACKED && transaction.status != REJECTED) {
                untrack_pending_transaction(transaction);
                transaction.status = REJECTED;
                ++_preflight_rejects;
            }
        }
        instance.fire_sequence = 0;
        instance.input_revision = 0;
        instance.last_evaluated_input_revision = 0;
        std::fill(_metric_present.begin() + instance.metric_base,
                  _metric_present.begin() + instance.metric_base + _metric_count, 0);
    }
    mark_dirty(index);
    schedule_instance(index, instance.next_due_day);
    _run_cursor = 0;
    ++_instances_submitted;
    return true;
}

bool EffectRuntime::has_instance_pod(int64_t instance_id, uint32_t generation) const {
    const int32_t index = instance_index_for_id(instance_id);
    return index >= 0 && index < static_cast<int32_t>(_instances.size()) &&
        _instances[static_cast<size_t>(index)].generation == generation;
}

bool EffectRuntime::upsert_external_binding_pod(
        int64_t binding_id, uint32_t generation, int32_t source_type,
        int64_t source_id, uint64_t target_handle, uint32_t target_generation,
        int32_t level, uint8_t location, uint64_t template_signature,
        uint64_t program_hash, std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (binding_id <= 0 || generation == 0 || target_handle == 0 ||
        target_generation == 0 || level < -1 || location > 2) {
        error = "effect_external_binding_invalid";
        return false;
    }
    const auto found = _external_binding_ids.find(binding_id);
    if (found != _external_binding_ids.end()) {
        ExternalSourceBinding &binding = _external_bindings[
            static_cast<size_t>(found->second)];
        // A rejected transition may roll a stable external identity back to
        // its previously durable generation.  This is safe only after that
        // binding was explicitly retired: an active binding must remain
        // monotonic so no live source can be overwritten by a stale command.
        if (binding.generation != generation && generation < binding.generation &&
            binding.active != 0) {
            error = "effect_external_binding_generation_regressed";
            return false;
        }
        binding.generation = generation;
        binding.source_type = source_type;
        binding.source_id = source_id;
        binding.target_handle = target_handle;
        binding.target_generation = target_generation;
        binding.level = level;
        binding.location = location;
        binding.active = 1;
        binding.template_signature = template_signature;
        binding.program_hash = program_hash;
        return true;
    }
    if (static_cast<int32_t>(_external_bindings.size()) >= _max_instances) {
        ++_overflow_count;
        error = "effect_external_binding_capacity_exceeded";
        return false;
    }
    ExternalSourceBinding binding;
    binding.binding_id = binding_id;
    binding.generation = generation;
    binding.source_type = source_type;
    binding.source_id = source_id;
    binding.target_handle = target_handle;
    binding.target_generation = target_generation;
    binding.level = level;
    binding.location = location;
    binding.active = 1;
    binding.template_signature = template_signature;
    binding.program_hash = program_hash;
    _external_binding_ids[binding_id] = static_cast<int32_t>(_external_bindings.size());
    _external_bindings.push_back(binding);
    return true;
}

bool EffectRuntime::retire_external_binding_pod(int64_t binding_id,
                                                uint32_t generation,
                                                std::string &error) {
    const auto found = _external_binding_ids.find(binding_id);
    if (found == _external_binding_ids.end()) {
        error = "effect_external_binding_unknown";
        return false;
    }
    ExternalSourceBinding &binding = _external_bindings[
        static_cast<size_t>(found->second)];
    if (binding.generation != generation) {
        error = "effect_external_binding_generation_mismatch";
        return false;
    }
    binding.active = 0;
    return true;
}

bool EffectRuntime::has_external_binding_pod(int64_t binding_id,
                                             uint32_t generation,
                                             int32_t source_type,
                                             int64_t source_id,
                                             uint64_t target_handle,
                                             uint32_t target_generation,
                                             int32_t level,
                                             uint8_t location,
                                             uint64_t template_signature,
                                             uint64_t program_hash) const {
    const auto found = _external_binding_ids.find(binding_id);
    if (found == _external_binding_ids.end()) return false;
    const ExternalSourceBinding &binding = _external_bindings[
        static_cast<size_t>(found->second)];
    return binding.active != 0 && binding.generation == generation &&
        binding.source_type == source_type && binding.source_id == source_id &&
        binding.target_handle == target_handle &&
        binding.target_generation == target_generation && binding.level == level &&
        binding.location == location &&
        binding.template_signature == template_signature &&
        binding.program_hash == program_hash;
}

bool EffectRuntime::verify_external_pending_transactions_pod(
        int32_t source_type, uint64_t target_handle, uint64_t source_id_mask,
        const std::vector<int64_t> &expected_transaction_ids,
        const std::vector<uint64_t> &expected_source_ids,
        std::string &error) const {
    if (target_handle == 0 || source_id_mask == 0 ||
        expected_transaction_ids.size() != expected_source_ids.size()) {
        error = "effect_external_pending_audit_invalid";
        return false;
    }
    std::unordered_map<int64_t, uint64_t> expected;
    expected.reserve(expected_transaction_ids.size());
    for (size_t i = 0; i < expected_transaction_ids.size(); ++i) {
        const int64_t transaction_id = expected_transaction_ids[i];
        const uint64_t source_id = expected_source_ids[i] & source_id_mask;
        if (transaction_id <= 0 || source_id == 0 ||
            !expected.emplace(transaction_id, source_id).second) {
            error = "effect_external_pending_expected_invalid";
            return false;
        }
    }
    auto source_for = [&](const Transaction &transaction) -> const Instance * {
        const int32_t index = instance_index_for_id(transaction.source_instance_id);
        if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return nullptr;
        const Instance &instance = _instances[static_cast<size_t>(index)];
        return instance.source_type == source_type &&
            instance.target_handle == target_handle ? &instance : nullptr;
    };
    for (const auto &entry : expected) {
        const int32_t transaction_index = transaction_index_for_id(entry.first);
        if (transaction_index < 0 ||
            transaction_index >= static_cast<int32_t>(_transactions.size())) {
            error = "effect_external_pending_transaction_missing";
            return false;
        }
        const Transaction &transaction = _transactions[
            static_cast<size_t>(transaction_index)];
        if (transaction.status != PLANNED && transaction.status != PREFLIGHTED &&
            transaction.status != COMMITTED) {
            error = "effect_external_pending_transaction_terminal";
            return false;
        }
        const Instance *instance = source_for(transaction);
        if (instance == nullptr ||
            (static_cast<uint64_t>(instance->source_id) & source_id_mask) !=
                entry.second) {
            error = "effect_external_pending_source_mismatch";
            return false;
        }
    }
    for (const Transaction &transaction : _transactions) {
        if (transaction.status != PLANNED && transaction.status != PREFLIGHTED &&
            transaction.status != COMMITTED)
            continue;
        const Instance *instance = source_for(transaction);
        if (instance == nullptr) continue;
        const auto found = expected.find(transaction.id);
        if (found == expected.end() ||
            (static_cast<uint64_t>(instance->source_id) & source_id_mask) !=
                found->second) {
            error = "effect_external_pending_transaction_unknown";
            return false;
        }
    }
    return true;
}

bool EffectRuntime::instance_fire_acked_pod(int64_t instance_id,
                                            uint32_t generation) const {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return false;
    const Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != generation || instance.fire_sequence == 0) return false;
    // A fire is domain-complete when nothing is still in flight. ACKED rows may
    // already have been compacted, so fire_sequence is the durable evidence of
    // a successful path. REJECTED rows must not poison a later ACKED fire.
    bool saw_acked = false;
    bool saw_rejected = false;
    for (const Transaction &transaction : _transactions) {
        if (transaction.source_instance_id != instance_id ||
            transaction.source_generation != generation) continue;
        if (transaction.status != ACKED && transaction.status != REJECTED) return false;
        if (transaction.status == ACKED) saw_acked = true;
        else saw_rejected = true;
    }
    if (saw_acked) return true;
    if (saw_rejected) return false;
    return true;
}

bool EffectRuntime::nudge_unacked_instance_pod(int64_t instance_id,
                                               uint32_t generation,
                                               int64_t day_index) {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return false;
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != generation || instance.active == 0) return false;
    if (instance_fire_acked_pod(instance_id, generation)) return true;
    instance.next_due_day = day_index;
    mark_dirty(index);
    schedule_instance(index, day_index);
    return true;
}

bool EffectRuntime::set_metric_pod(int64_t instance_id, int32_t metric_id,
                                   int64_t revision, int64_t value_q16,
                                   std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0) { error = "effect_instance_unknown"; return false; }
    if (metric_id < 0 || metric_id >= _metric_count) {
        error = "effect_snapshot_metric_invalid"; return false;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (revision <= instance.input_revision) return true;
    int64_t *metric = metric_ptr(instance, metric_id);
    if (metric == nullptr) { error = "effect_snapshot_metric_invalid"; return false; }
    *metric = value_q16;
    _metric_present[static_cast<size_t>(instance.metric_base) +
                    static_cast<size_t>(metric_id)] = 1;
    instance.input_revision = revision;
    mark_dirty(index);
    return true;
}

bool EffectRuntime::retire_instance_pod(int64_t instance_id,
                                        uint32_t generation,
                                        int64_t effective_day,
                                        std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) {
        // No Effect instance means no Effect-owned Modifier was committed.
        return true;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != generation) {
        error = "effect_instance_generation_stale";
        return false;
    }
    if (instance.active == 0) return true;
    return create_retirement_transaction(index, effective_day, error);
}

bool EffectRuntime::enqueue_trigger_effect_pod(
        int64_t effect_id, int64_t effective_day, int32_t trigger_id,
        uint64_t target_handle, uint32_t target_generation,
        uint64_t fire_sequence, int32_t action, int32_t domain, int32_t opcode,
        int64_t resolved_value, int32_t duration_days, int32_t stacks,
        const std::string &command_key, const std::string &definition_key,
        const std::array<int64_t, 4> &payload, std::string &error) {
    const std::string program_key = action == COUNTRY_COMMAND
        ? std::string("trigger.country.") + definition_key
        : std::string("trigger.modifier.") + definition_key;
    return enqueue_external_effect_pod(effect_id, effective_day, 0x54524947,
        trigger_id, program_key, target_handle,
        target_handle, target_generation, fire_sequence, action, domain, opcode,
        resolved_value, duration_days, stacks, command_key, definition_key, payload, error);
}

bool EffectRuntime::enqueue_external_effect_pod(
        int64_t effect_id, int64_t effective_day, int32_t source_type,
        int64_t source_id, const std::string &program_key, uint64_t source_handle,
        uint64_t target_handle, uint32_t target_generation, uint64_t fire_sequence,
        int32_t action, int32_t domain, int32_t opcode, int64_t resolved_value,
        int32_t duration_days, int32_t stacks, const std::string &command_key,
        const std::string &definition_key, const std::array<int64_t, 4> &payload,
        std::string &error, int64_t *out_transaction_id) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effect_id <= 0 || target_generation == 0 || target_handle == 0 ||
        domain < 0 || domain >= 32 || stacks <= 0 || command_key.empty() ||
        definition_key.empty()) {
        error = "trigger_effect_shape_invalid";
        return false;
    }
    const uint64_t idempotency = make_hash(static_cast<uint64_t>(effect_id),
        target_generation, fire_sequence, 0);
    if (_pending_command_idempotency.find(idempotency) !=
        _pending_command_idempotency.end()) {
        if (out_transaction_id != nullptr) {
            for (const Transaction &transaction : _transactions) {
                for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
                    const Command *existing = command_at(transaction, ordinal);
                    if (existing != nullptr && existing->idempotency_key == idempotency) {
                        *out_transaction_id = transaction.id;
                        return true;
                    }
                }
            }
        }
        return true;
    }
    const bool modifier_remove = action == MODIFIER_COMMAND &&
        opcode == ModifierRuntime::COMMAND_REMOVE;
    int32_t command_definition_id = -1;
    for (int32_t i = 0; i < static_cast<int32_t>(_command_definitions.size()); ++i) {
        const CommandDefinition &candidate = _command_definitions[i];
        const bool dynamic_country_signal_payload =
            action == COUNTRY_COMMAND &&
            opcode == NativeCountryRuntime::COMMAND_DISCOVER_COUNTRY_SIGNAL &&
            candidate.action == action && candidate.opcode == opcode &&
            (static_cast<uint64_t>(candidate.payload[0]) >> 32U) ==
                (static_cast<uint64_t>(payload[0]) >> 32U) &&
            candidate.payload[1] == payload[1] &&
            candidate.payload[2] == payload[2] &&
            candidate.payload[3] == payload[3];
        if (candidate.command_key == command_key &&
            candidate.definition_key == definition_key &&
            candidate.action == action && candidate.domain == domain &&
            (candidate.opcode == opcode || (modifier_remove &&
                candidate.opcode == ModifierRuntime::COMMAND_APPLY)) &&
            candidate.target_resolver == TARGET_INSTANCE &&
            candidate.duration_days == duration_days &&
            candidate.stacks == stacks &&
            (candidate.payload == payload || dynamic_country_signal_payload)) {
            command_definition_id = i;
            break;
        }
    }
    if (command_definition_id < 0) {
        error = "trigger_effect_definition_not_compiled";
        return false;
    }
    const int64_t instance_id = static_cast<int64_t>(make_hash(
        static_cast<uint64_t>(source_type), static_cast<uint32_t>(source_id),
        static_cast<uint64_t>(effect_id), static_cast<uint32_t>(target_generation)) &
        0x7fffffffffffffffULL);
    const uint32_t generation = std::max<uint32_t>(1, target_generation);
    if (instance_index_for_id(instance_id) < 0) {
        if (!upsert_instance_pod(instance_id, program_key, generation,
                source_type, source_id, source_handle, target_handle,
                target_generation, 0, effective_day, false, error)) return false;
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            ++_overflow_count;
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    const Instance &source = _instances[static_cast<size_t>(instance_index_for_id(instance_id))];
    Command command;
    command.action = action;
    command.domain = domain;
    command.opcode = opcode;
    command.target_handle = target_handle;
    command.target_generation = target_generation;
    command.value_q16 = resolved_value;
    command.duration_days = duration_days;
    command.stacks = stacks;
    command.command_key_id = command_definition_id;
    command.command_definition_id = command_definition_id;
    command.payload = payload;
    command.idempotency_key = idempotency;
    command.external_effect_id = effect_id;
    command.external_source_id = source_id;
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = source.id;
    transaction.source_generation = source.generation;
    transaction.program_id = source.program_id;
    transaction.effective_day = effective_day;
    append_command(transaction, command);
    if (transaction.command_count == 0) {
        error = "trigger_effect_transaction_empty";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_instance_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.program_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *stored = command_at(transaction, ordinal);
        if (stored == nullptr) continue;
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_generation);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->value_q16);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->duration_days);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->stacks);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->command_key_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->command_definition_id);
        for (const int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->idempotency_key);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->external_effect_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->external_source_id);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr) *out_transaction_id = _transactions.back().id;
    return true;
}

bool EffectRuntime::enqueue_external_effect_batch_pod(
        int64_t effective_day, int32_t source_type,
        int64_t transition_source_id, uint64_t source_handle,
        uint64_t target_handle, uint32_t target_generation,
        const ExternalEffectCommandPod *commands, size_t command_count,
        std::string &error, int64_t *out_transaction_id) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effective_day < 0 || transition_source_id == 0 || source_handle == 0 ||
            target_handle == 0 || target_generation == 0 || commands == nullptr ||
            command_count == 0 || command_count > 4096) {
        error = "effect_external_batch_shape_invalid";
        return false;
    }
    std::vector<Command> staged;
    staged.reserve(command_count);
    int64_t replay_transaction_id = 0;
    size_t replayed = 0;
    for (size_t row = 0; row < command_count; ++row) {
        const ExternalEffectCommandPod &source = commands[row];
        if (source.effect_id <= 0 || source.source_id == 0 ||
                source.program_key.empty() || source.domain < 0 ||
                source.domain >= 32 || source.stacks <= 0 ||
                source.command_key.empty() || source.definition_key.empty()) {
            error = "effect_external_batch_command_invalid";
            return false;
        }
        const uint64_t idempotency = make_hash(
            static_cast<uint64_t>(source.effect_id), target_generation,
            source.fire_sequence, 0);
        if (_pending_command_idempotency.find(idempotency) !=
                _pending_command_idempotency.end()) {
            int64_t matched_transaction_id = 0;
            for (const Transaction &transaction : _transactions) {
                for (uint32_t ordinal = 0;
                        ordinal < transaction.command_count; ++ordinal) {
                    const Command *existing = command_at(transaction, ordinal);
                    if (existing != nullptr &&
                            existing->idempotency_key == idempotency) {
                        matched_transaction_id = transaction.id;
                        break;
                    }
                }
                if (matched_transaction_id != 0) break;
            }
            if (matched_transaction_id == 0 ||
                    (replay_transaction_id != 0 &&
                     replay_transaction_id != matched_transaction_id)) {
                error = "effect_external_batch_partial_replay";
                return false;
            }
            replay_transaction_id = matched_transaction_id;
            ++replayed;
            continue;
        }
        const bool modifier_remove =
            source.action == MODIFIER_COMMAND &&
            source.opcode == ModifierRuntime::COMMAND_REMOVE;
        int32_t command_definition_id = -1;
        for (int32_t definition_index = 0;
                definition_index <
                    static_cast<int32_t>(_command_definitions.size());
                ++definition_index) {
            const CommandDefinition &candidate =
                _command_definitions[static_cast<size_t>(definition_index)];
            const bool dynamic_country_signal_payload =
                source.action == COUNTRY_COMMAND &&
                source.opcode ==
                    NativeCountryRuntime::COMMAND_DISCOVER_COUNTRY_SIGNAL &&
                candidate.action == source.action &&
                candidate.opcode == source.opcode &&
                (static_cast<uint64_t>(candidate.payload[0]) >> 32U) ==
                    (static_cast<uint64_t>(source.payload[0]) >> 32U) &&
                candidate.payload[1] == source.payload[1] &&
                candidate.payload[2] == source.payload[2] &&
                candidate.payload[3] == source.payload[3];
            if (candidate.command_key == source.command_key &&
                    candidate.definition_key == source.definition_key &&
                    candidate.action == source.action &&
                    candidate.domain == source.domain &&
                    (candidate.opcode == source.opcode ||
                     (modifier_remove &&
                      candidate.opcode == ModifierRuntime::COMMAND_APPLY)) &&
                    candidate.target_resolver == TARGET_INSTANCE &&
                    candidate.duration_days == source.duration_days &&
                    candidate.stacks == source.stacks &&
                    (candidate.payload == source.payload ||
                     dynamic_country_signal_payload)) {
                command_definition_id = definition_index;
                break;
            }
        }
        if (command_definition_id < 0) {
            error = "effect_external_batch_definition_not_compiled";
            return false;
        }
        if (definition_id_for_key(source.program_key) < 0) {
            error = "effect_external_batch_program_unknown";
            return false;
        }
        Command command;
        command.action = source.action;
        command.domain = source.domain;
        command.opcode = source.opcode;
        command.target_handle = target_handle;
        command.target_generation = target_generation;
        command.value_q16 = source.resolved_value;
        command.duration_days = source.duration_days;
        command.stacks = source.stacks;
        command.command_key_id = command_definition_id;
        command.command_definition_id = command_definition_id;
        command.payload = source.payload;
        command.idempotency_key = idempotency;
        command.external_effect_id = source.effect_id;
        command.external_source_id = source.source_id;
        staged.push_back(command);
    }
    if (replayed != 0) {
        if (replayed != command_count || !staged.empty()) {
            error = "effect_external_batch_partial_replay";
            return false;
        }
        if (out_transaction_id != nullptr)
            *out_transaction_id = replay_transaction_id;
        return true;
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            ++_overflow_count;
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    const ExternalEffectCommandPod &first = commands[0];
    const int64_t instance_id = static_cast<int64_t>(make_hash(
        static_cast<uint64_t>(source_type),
        static_cast<uint32_t>(transition_source_id),
        static_cast<uint64_t>(first.effect_id),
        static_cast<uint32_t>(first.fire_sequence)) &
        0x7fffffffffffffffULL);
    const uint32_t generation = std::max<uint32_t>(1, target_generation);
    if (!upsert_instance_pod(instance_id, first.program_key, generation,
            source_type, transition_source_id, source_handle, target_handle,
            target_generation, 0, effective_day, false, error))
        return false;
    const int32_t source_index = instance_index_for_id(instance_id);
    if (source_index < 0) {
        error = "effect_external_batch_source_missing";
        return false;
    }
    const Instance &source =
        _instances[static_cast<size_t>(source_index)];
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = source.id;
    transaction.source_generation = source.generation;
    transaction.program_id = source.program_id;
    transaction.effective_day = effective_day;
    _command_arena.reserve(_command_arena.size() + staged.size());
    for (const Command &command : staged) append_command(transaction, command);
    if (transaction.command_count != staged.size()) {
        error = "effect_external_batch_command_collision";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_instance_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.program_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.effective_day);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *stored = command_at(transaction, ordinal);
        if (stored == nullptr) continue;
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->target_generation);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->value_q16);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->duration_days);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->stacks);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->command_key_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->command_definition_id);
        for (const int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->idempotency_key);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->external_effect_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->external_source_id);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr)
        *out_transaction_id = _transactions.back().id;
    return true;
}

bool EffectRuntime::enqueue_family_colonization_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t country_handle, uint32_t country_generation,
        uint64_t expedition_handle, uint32_t expedition_generation,
        int32_t target_cell, uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id, bool claim_unowned) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effect_id <= 0 || effective_day < 0 || country_handle == 0 ||
        country_generation == 0 || expedition_handle == 0 ||
        expedition_generation == 0 || target_cell < 0) {
        error = "family_colonization_effect_shape_invalid";
        return false;
    }
    const uint64_t base_key = make_hash(static_cast<uint64_t>(effect_id),
        expedition_generation, fire_sequence, 0x434f4c4fU);
    const uint64_t settle_key = make_hash(static_cast<uint64_t>(effect_id),
        expedition_generation, fire_sequence, 1);
    for (const Transaction &existing : _transactions) {
        if (existing.program_id != -1 ||
            existing.source_generation != expedition_generation) continue;
        for (uint32_t ordinal = 0; ordinal < existing.command_count; ++ordinal) {
            const Command *command = command_at(existing, ordinal);
            if (command == nullptr) continue;
            if (command->idempotency_key == base_key ||
                command->idempotency_key == settle_key) {
                if (out_transaction_id != nullptr)
                    *out_transaction_id = existing.id;
                return true;
            }
        }
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = source_id;
    transaction.source_generation = expedition_generation;
    transaction.program_id = -1;
    transaction.effective_day = effective_day;

    if (claim_unowned) {
        Command claim;
        claim.action = COUNTRY_COMMAND;
        claim.domain = 7;
        claim.opcode = NativeCountryRuntime::COMMAND_CLAIM_UNOWNED_TERRITORY;
        claim.target_handle = country_handle;
        claim.target_generation = country_generation;
        claim.command_key_id = -1;
        claim.command_definition_id = -1;
        claim.payload[0] = static_cast<int64_t>(static_cast<uint32_t>(target_cell));
        claim.idempotency_key = base_key;
        append_command(transaction, claim);
    }

    Command settle;
    settle.action = ECONOMY_COMMAND;
    settle.domain = 8;
    settle.opcode = NativeEconomyRuntime::COMMAND_SETTLE_FAMILY_EXPEDITION;
    settle.target_handle = expedition_handle;
    settle.target_generation = expedition_generation;
    settle.command_key_id = -1;
    settle.command_definition_id = -1;
    settle.payload[0] = static_cast<int64_t>(static_cast<uint32_t>(target_cell));
    settle.payload[1] = static_cast<int64_t>(country_handle);
    settle.payload[2] = claim_unowned ? 1 : 0;
    settle.idempotency_key = settle_key;
    append_command(transaction, settle);
    const uint32_t expected_commands = claim_unowned ? 2U : 1U;
    if (transaction.command_count != expected_commands) {
        error = "family_colonization_transaction_capacity_exceeded";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *stored = command_at(transaction, ordinal);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_generation);
        for (const int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
                                           stored->idempotency_key);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr) *out_transaction_id = _transactions.back().id;
    return true;
}

uint64_t EffectRuntime::family_colonization_settle_idempotency_key(
        int64_t effect_id, uint32_t expedition_generation,
        uint64_t fire_sequence) const {
    return make_hash(static_cast<uint64_t>(effect_id), expedition_generation,
                     fire_sequence, 1);
}

bool EffectRuntime::family_colonization_includes_claim(
        int64_t transaction_id) const {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index < 0) return false;
    const Transaction &transaction = _transactions[static_cast<size_t>(index)];
    if (transaction.program_id != -1) return false;
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *command = command_at(transaction, ordinal);
        if (command == nullptr) continue;
        if (command->action == COUNTRY_COMMAND &&
            command->opcode == NativeCountryRuntime::COMMAND_CLAIM_UNOWNED_TERRITORY)
            return true;
        if (command->action == ECONOMY_COMMAND &&
            command->opcode == NativeEconomyRuntime::COMMAND_SETTLE_FAMILY_EXPEDITION &&
            command->payload[2] != 0)
            return true;
    }
    return false;
}

bool EffectRuntime::enqueue_canal_commit_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t project_handle, uint32_t project_generation,
        uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effect_id <= 0 || effective_day < 0 || source_id <= 0 ||
        project_handle == 0 || project_generation == 0) {
        error = "canal_effect_shape_invalid";
        return false;
    }
    const uint64_t idempotency = make_hash(static_cast<uint64_t>(effect_id),
        project_generation, fire_sequence, 0x43414e4cU);
    for (const Transaction &existing : _transactions) {
        const Command *first = command_at(existing, 0);
        if (first != nullptr && first->idempotency_key == idempotency) {
            if (out_transaction_id != nullptr) *out_transaction_id = existing.id;
            return true;
        }
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = source_id;
    transaction.source_generation = project_generation;
    transaction.program_id = -2;
    transaction.effective_day = effective_day;

    Command commit;
    commit.action = CUSTOM_DOMAIN_COMMAND;
    commit.domain = 6;
    commit.opcode = 2; // geography.canal.commit
    commit.target_handle = project_handle;
    commit.target_generation = project_generation;
    commit.command_key_id = -1;
    commit.command_definition_id = -1;
    commit.idempotency_key = idempotency;
    append_command(transaction, commit);
    if (transaction.command_count != 1) {
        error = "canal_effect_transaction_capacity_exceeded";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.action);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.domain);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.opcode);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.target_handle);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.target_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.idempotency_key);
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr) *out_transaction_id = _transactions.back().id;
    return true;
}

int32_t EffectRuntime::transaction_status_pod(int64_t transaction_id) const {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index >= 0 && index < static_cast<int32_t>(_transactions.size()))
        return _transactions[static_cast<size_t>(index)].status;
    return transaction_id > 0 && transaction_id <= _acked_transaction_id ? ACKED : 0;
}

bool EffectRuntime::consume_rejected_transaction_pod(
        int64_t transaction_id, int64_t source_id) {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
        return false;
    Transaction &transaction = _transactions[static_cast<size_t>(index)];
    if (transaction.source_instance_id != source_id ||
        (transaction.status != REJECTED &&
         transaction.status != RESYNC_REQUIRED)) return false;
    // The producer has converted the failure into its own durable state. Mark
    // the row terminal so the generic arena compactor can retire it without
    // retaining rejected expedition transactions for the rest of the session.
    transaction.status = ACKED;
    compact_terminal_transactions();
    return true;
}

Dictionary EffectRuntime::submit_instances(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "instance_ids");
    const PackedStringArray program_keys = get_strings(batch, "program_keys");
    const int32_t count = ids.size();
    const PackedInt32Array generations = get_i32(batch, "generations");
    const PackedInt32Array source_types = get_i32(batch, "source_types");
    const PackedInt64Array source_ids = get_i64(batch, "source_ids");
    const PackedInt64Array source_handles = get_i64(batch, "source_handles");
    const PackedInt64Array target_handles = get_i64(batch, "target_handles");
    const PackedInt32Array target_generations = get_i32(batch, "target_generations");
    const PackedInt32Array levels = get_i32(batch, "levels");
    const PackedInt64Array next_due_days = get_i64(batch, "next_due_days");
    const PackedByteArray active = get_u8(batch, "active");
    if (count <= 0 || count > _max_instances || program_keys.size() != count)
        return failure("effect_instance_columns_invalid");
    int32_t accepted = 0;
    int32_t rejected = 0;
    std::unordered_set<int64_t> batch_ids;
    PackedInt64Array accepted_ids;
    for (int32_t i = 0; i < count; ++i) {
        const int64_t id = ids[i];
        const int32_t program_id = definition_id_for_key(program_keys[i].utf8().get_data());
        if (id <= 0 || program_id < 0 || !batch_ids.emplace(id).second) {
            ++rejected;
            continue;
        }
        int32_t index = instance_index_for_id(id);
        const uint32_t generation = static_cast<uint32_t>(std::max(1, i32_at(generations, i, 1)));
        if (index < 0) {
            if (static_cast<int32_t>(_instance_ids.size()) >= _max_instances) {
                ++_overflow_count;
                _last_error = "effect_instance_capacity_exceeded";
                break;
            }
            if (!_free_instance_indices.empty()) {
                index = _free_instance_indices.back();
                _free_instance_indices.pop_back();
                Instance &slot = _instances[static_cast<size_t>(index)];
                const uint32_t metric_base = slot.metric_base;
                slot = Instance{};
                slot.metric_base = metric_base;
                std::fill(_metric_values.begin() + metric_base,
                          _metric_values.begin() + metric_base + _metric_count, 0);
                std::fill(_metric_present.begin() + metric_base,
                          _metric_present.begin() + metric_base + _metric_count, 0);
            } else {
                Instance instance;
                instance.metric_base = static_cast<uint32_t>(_metric_values.size());
                _metric_values.resize(_metric_values.size() + static_cast<size_t>(_metric_count), 0);
                _metric_present.resize(_metric_present.size() + static_cast<size_t>(_metric_count), 0);
                _instances.push_back(std::move(instance));
                index = static_cast<int32_t>(_instances.size() - 1);
            }
            Instance &slot = _instances[static_cast<size_t>(index)];
            slot.id = id;
            slot.generation = generation;
            slot.program_id = program_id;
            _instance_ids[id] = index;
        }
        Instance &instance = _instances[index];
        const bool generation_changed = instance.generation != generation;
        instance.generation = generation;
        instance.program_id = program_id;
        instance.source_type = i32_at(source_types, i, 0);
        instance.source_id = i64_at(source_ids, i, 0);
        instance.source_handle = static_cast<uint64_t>(i64_at(source_handles, i, 0));
        instance.target_handle = static_cast<uint64_t>(i64_at(target_handles, i, 0));
        instance.target_generation = static_cast<uint32_t>(std::max(0, i32_at(target_generations, i, 0)));
        instance.level = i32_at(levels, i, 0);
        instance.next_due_day = i64_at(next_due_days, i,
                                       _current_day >= 0 ? _current_day : 0);
        instance.active = u8_at(active, i, 1) != 0 ? 1 : 0;
        if (generation_changed) {
            for (Transaction &transaction : _transactions) {
                if (transaction.source_instance_id == instance.id &&
                    transaction.source_generation != generation &&
                    transaction.status != ACKED &&
                    transaction.status != REJECTED) {
                    untrack_pending_transaction(transaction);
                    transaction.status = REJECTED;
                    ++_preflight_rejects;
                }
            }
            instance.fire_sequence = 0;
            instance.input_revision = 0;
            instance.last_evaluated_input_revision = 0;
            std::fill(_metric_present.begin() + instance.metric_base,
                      _metric_present.begin() + instance.metric_base + _metric_count, 0);
        }
        mark_dirty(index);
        schedule_instance(index, instance.next_due_day);
        ++accepted;
        accepted_ids.append(id);
    }
    _instances_submitted += static_cast<uint64_t>(accepted);
    _run_cursor = 0;
    Dictionary out;
    out["ok"] = true;
    out["accepted"] = accepted;
    out["rejected"] = rejected;
    out["instance_ids"] = accepted_ids;
    return out;
}

Dictionary EffectRuntime::submit_snapshots(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array instance_ids = get_i64(batch, "instance_ids");
    const PackedInt64Array revisions = get_i64(batch, "revisions");
    const PackedInt32Array offsets = get_i32(batch, "metric_offsets");
    const PackedInt32Array metric_ids = get_i32(batch, "metric_ids");
    const PackedInt64Array metric_values = get_i64(batch, "metric_values_q16");
    const int32_t count = instance_ids.size();
    if (count <= 0 || offsets.size() != count + 1 ||
        metric_ids.size() != metric_values.size() ||
        offsets[0] != 0 || offsets[count] != metric_ids.size())
        return failure("effect_snapshot_columns_invalid");
    for (int32_t i = 1; i < offsets.size(); ++i) {
        if (offsets[i] < offsets[i - 1] || offsets[i] < 0 ||
            offsets[i] > metric_ids.size())
            return failure("effect_snapshot_offsets_invalid");
    }
    int32_t accepted = 0;
    for (int32_t i = 0; i < count; ++i) {
        const int32_t instance_index = instance_index_for_id(instance_ids[i]);
        if (instance_index < 0) continue;
        const int32_t begin = offsets[i];
        const int32_t end = offsets[i + 1];
        if (begin < 0 || end < begin || end > metric_ids.size())
            return failure("effect_snapshot_offsets_invalid");
        Instance &instance = _instances[instance_index];
        const int64_t revision = i64_at(revisions, i, instance.input_revision + 1);
        if (revision <= instance.input_revision) continue;
        std::fill(_metric_present.begin() + instance.metric_base,
                  _metric_present.begin() + instance.metric_base + _metric_count, 0);
        for (int32_t j = begin; j < end; ++j) {
            const int32_t metric_id = metric_ids[j];
            if (metric_id < 0 || metric_id >= _metric_count)
                return failure("effect_snapshot_metric_invalid");
            int64_t *metric = metric_ptr(instance, metric_id);
            if (metric == nullptr) return failure("effect_snapshot_metric_invalid");
            *metric = metric_values[j];
            _metric_present[static_cast<size_t>(instance.metric_base) +
                            static_cast<size_t>(metric_id)] = 1;
        }
        instance.input_revision = revision;
        mark_dirty(instance_index);
        ++accepted;
    }
    Dictionary out;
    out["ok"] = true;
    out["accepted"] = accepted;
    out["metrics_written"] = metric_values.size();
    return out;
}

int64_t EffectRuntime::metric_value(const Instance &instance, int32_t metric_id) const {
    const int64_t *metric = metric_ptr(instance, metric_id);
    return metric != nullptr ? *metric : 0;
}

int64_t EffectRuntime::state_value(const Instance &instance, int32_t state_id) const {
    switch (state_id) {
        case 0: return static_cast<int64_t>(instance.level) * Q16_ONE;
        case 1: return static_cast<int64_t>(instance.fire_sequence) * Q16_ONE;
        case 2: return instance.input_revision;
        default: return 0;
    }
}

std::string EffectRuntime::command_key_for(const Command &command) const {
    if (command.command_definition_id >= 0 &&
        command.command_definition_id < static_cast<int32_t>(_command_definitions.size()))
        return _command_definitions[command.command_definition_id].command_key;
    if (command.command_key_id >= 0 &&
        command.command_key_id < static_cast<int32_t>(_behavior_command_keys.size()))
        return _behavior_command_keys[command.command_key_id];
    return {};
}

std::string EffectRuntime::command_definition_key_for(
        const Transaction &transaction, const Command &command) const {
    if (command.command_definition_id >= 0 &&
        command.command_definition_id < static_cast<int32_t>(_command_definitions.size()))
        return _command_definitions[command.command_definition_id].definition_key;
    if (transaction.program_id >= 0 &&
        transaction.program_id < static_cast<int32_t>(_definitions.size()))
        return _definitions[transaction.program_id].key;
    return {};
}

bool EffectRuntime::evaluate_condition(const Definition &definition,
                                       const Instance &instance) const {
    if (definition.condition_count <= 0) return true;
    std::array<uint8_t, MAX_STACK> stack{};
    int32_t sp = 0;
    const int32_t begin = definition.condition_begin;
    const int32_t end = begin + definition.condition_count;
    for (int32_t i = begin; i < end; ++i) {
        const Condition &condition = _conditions[i];
        bool value = false;
        switch (condition.op) {
            case CONDITION_TRUE: value = true; break;
            case METRIC_GTE: value = metric_value(instance, condition.arg0) >= condition.value; break;
            case METRIC_LTE: value = metric_value(instance, condition.arg0) <= condition.value; break;
            case METRIC_EQ: value = metric_value(instance, condition.arg0) == condition.value; break;
            case STATE_GTE: value = state_value(instance, condition.arg0) >= condition.value; break;
            case BOOL_AND:
                if (sp < 2) return false;
                value = stack[sp - 2] != 0 && stack[sp - 1] != 0;
                --sp;
                stack[sp - 1] = value ? 1 : 0;
                continue;
            case BOOL_OR:
                if (sp < 2) return false;
                value = stack[sp - 2] != 0 || stack[sp - 1] != 0;
                --sp;
                stack[sp - 1] = value ? 1 : 0;
                continue;
            case BOOL_NOT:
                if (sp < 1) return false;
                stack[sp - 1] = stack[sp - 1] == 0 ? 1 : 0;
                continue;
            default: return false;
        }
        if (sp >= MAX_STACK) return false;
        stack[sp++] = value ? 1 : 0;
    }
    return sp > 0 && stack[sp - 1] != 0;
}

uint64_t EffectRuntime::command_idempotency_key(const Instance &instance,
                                                 uint32_t command_index) const {
    return make_hash(static_cast<uint64_t>(instance.id), instance.generation,
                     instance.fire_sequence, command_index);
}

const EffectRuntime::Command *EffectRuntime::command_at(
        const Transaction &transaction, uint32_t ordinal) const {
    if (ordinal >= transaction.command_count) return nullptr;
    const size_t index = static_cast<size_t>(transaction.command_begin) + ordinal;
    return index < _command_arena.size() ? &_command_arena[index] : nullptr;
}

int32_t EffectRuntime::transaction_index_for_id(int64_t transaction_id) const {
    const auto found = _transaction_ids.find(transaction_id);
    return found == _transaction_ids.end() ? -1 : found->second;
}

void EffectRuntime::append_command(Transaction &transaction, const Command &command) {
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *existing = command_at(transaction, ordinal);
        if (existing != nullptr && existing->idempotency_key == command.idempotency_key)
            return;
    }
    if (_pending_command_idempotency.find(command.idempotency_key) !=
        _pending_command_idempotency.end()) return;
    if (transaction.command_count == 0)
        transaction.command_begin = static_cast<uint32_t>(_command_arena.size());
    _command_arena.push_back(command);
    ++transaction.command_count;
    ++_commands_emitted;
    transaction.required_ack_mask |= adapter_ack_bit_for(command);
}

void EffectRuntime::index_transaction_commands(const Transaction &transaction) {
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *command = command_at(transaction, ordinal);
        if (command != nullptr) ++_pending_command_idempotency[command->idempotency_key];
    }
}

void EffectRuntime::unindex_transaction_commands(const Transaction &transaction) {
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *command = command_at(transaction, ordinal);
        if (command == nullptr) continue;
        auto found = _pending_command_idempotency.find(command->idempotency_key);
        if (found == _pending_command_idempotency.end()) continue;
        if (found->second <= 1) _pending_command_idempotency.erase(found);
        else --found->second;
    }
}

void EffectRuntime::track_pending_transaction(const Transaction &transaction) {
    if (transaction.status == ACKED || transaction.status == REJECTED) return;
    ++_pending_transactions_by_instance[transaction.source_instance_id];
}

void EffectRuntime::untrack_pending_transaction(const Transaction &transaction) {
    if (transaction.status == ACKED || transaction.status == REJECTED) return;
    const auto found = _pending_transactions_by_instance.find(
        transaction.source_instance_id);
    if (found == _pending_transactions_by_instance.end()) return;
    if (found->second <= 1) _pending_transactions_by_instance.erase(found);
    else --found->second;
}

bool EffectRuntime::acknowledge_native_domain(Transaction &transaction,
                                              uint32_t domain_bit) {
    if (domain_bit == 0 || (domain_bit & transaction.required_ack_mask) == 0) {
        transaction.status = RESYNC_REQUIRED;
        _last_error = "effect_native_ack_domain_mask_invalid";
        return false;
    }
    transaction.received_ack_mask |= domain_bit;
    if ((transaction.received_ack_mask & transaction.required_ack_mask) !=
            transaction.required_ack_mask) {
        transaction.status = COMMITTED;
        return false;
    }
    untrack_pending_transaction(transaction);
    transaction.status = ACKED;
    unindex_transaction_commands(transaction);
    _acked_transaction_id = std::max(_acked_transaction_id, transaction.id);
    ++_transactions_acked;
    return true;
}

void EffectRuntime::rebuild_command_idempotency_index() {
    _pending_command_idempotency.clear();
    _pending_transactions_by_instance.clear();
    for (const Transaction &transaction : _transactions) {
        // ACKED commands have reached their durable destination and do not
        // block the next fire sequence. REJECTED rows retain their key until
        // terminal compaction, matching the previous vector scan behavior.
        if (transaction.status == ACKED || transaction.status == REJECTED) continue;
        index_transaction_commands(transaction);
        track_pending_transaction(transaction);
    }
}

void EffectRuntime::release_retired_instance_if_terminal(int32_t instance_index) {
    if (instance_index < 0 || instance_index >= static_cast<int32_t>(_instances.size()))
        return;
    Instance &instance = _instances[static_cast<size_t>(instance_index)];
    if (instance.active != 0 || instance.id <= 0) return;
    if (_pending_transactions_by_instance.find(instance.id) !=
        _pending_transactions_by_instance.end()) return;
    // Keep the backing slab allocation stable; it is reused when a later
    // upsert reuses the slot. Removing the ID releases lifecycle and
    // scheduling capacity immediately after the domain safe boundary.
    const uint32_t metric_base = instance.metric_base;
    _instance_ids.erase(instance.id);
    instance = Instance{};
    instance.metric_base = metric_base;
    instance.generation = 0;
    instance.active = 0;
    // A terminal ACK may arrive after planning but before the next save or
    // slice. Remove this slot from queued candidate/dirty work so a reused
    // index cannot inherit an old same-day evaluation and PKEF never records a
    // candidate pointing at a tombstone.
    const int32_t consumed = std::min<int32_t>(
        _candidate_cursor, static_cast<int32_t>(_run_candidates.size()));
    int32_t removed_before_cursor = 0;
    for (int32_t i = 0; i < consumed; ++i)
        if (_run_candidates[static_cast<size_t>(i)] == instance_index)
            ++removed_before_cursor;
    _run_candidates.erase(std::remove(_run_candidates.begin(), _run_candidates.end(),
                                      instance_index), _run_candidates.end());
    _candidate_cursor = std::min<int32_t>(
        std::max(0, _candidate_cursor - removed_before_cursor),
        static_cast<int32_t>(_run_candidates.size()));
    _run_cursor = _candidate_cursor;
    _dirty_queue.erase(std::remove(_dirty_queue.begin(), _dirty_queue.end(),
                                   instance_index), _dirty_queue.end());
    _free_instance_indices.push_back(instance_index);
}

void EffectRuntime::compact_terminal_transactions() {
    if (_transactions.empty()) return;
    std::vector<int32_t> retired_candidates;
    retired_candidates.reserve(_transactions.size());
    std::vector<Transaction> retained;
    retained.reserve(_transactions.size());
    std::vector<Command> compacted_commands;
    compacted_commands.reserve(_command_arena.size());
    for (Transaction &transaction : _transactions) {
        if (transaction.status == ACKED) {
            // Built-in transactions (negative program IDs) are owned by a
            // peer runtime and do not have an Effect instance. Their numeric
            // source IDs may legitimately overlap an unrelated instance ID.
            if (transaction.program_id >= 0) {
                const int32_t instance_index =
                    instance_index_for_id(transaction.source_instance_id);
                if (instance_index >= 0)
                    retired_candidates.push_back(instance_index);
            }
            continue;
        }
        const uint32_t new_begin = static_cast<uint32_t>(compacted_commands.size());
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command != nullptr) compacted_commands.push_back(*command);
        }
        transaction.command_begin = new_begin;
        retained.push_back(std::move(transaction));
    }
    if (retained.size() == _transactions.size()) return;
    _transactions.swap(retained);
    _command_arena.swap(compacted_commands);
    _transaction_ids.clear();
    _transaction_ids.reserve(_transactions.size());
    for (size_t i = 0; i < _transactions.size(); ++i)
        _transaction_ids[_transactions[i].id] = static_cast<int32_t>(i);
    rebuild_command_idempotency_index();
    std::sort(retired_candidates.begin(), retired_candidates.end());
    retired_candidates.erase(std::unique(retired_candidates.begin(),
                                         retired_candidates.end()),
                             retired_candidates.end());
    for (const int32_t index : retired_candidates)
        release_retired_instance_if_terminal(index);
}

bool EffectRuntime::create_retirement_transaction(int32_t instance_index,
                                                  int64_t effective_day,
                                                  std::string &error) {
    if (instance_index < 0 || instance_index >= static_cast<int32_t>(_instances.size())) {
        error = "effect_instance_unknown";
        return false;
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            ++_overflow_count;
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    Instance &instance = _instances[static_cast<size_t>(instance_index)];
    if (instance.program_id < 0 ||
        instance.program_id >= static_cast<int32_t>(_definitions.size())) {
        error = "effect_instance_program_invalid";
        return false;
    }
    const Definition &definition = _definitions[instance.program_id];
    int32_t command_definition_id = -1;
    for (int32_t ordinal = 0; ordinal < definition.command_count; ++ordinal) {
        const int32_t id = definition.command_begin + ordinal;
        if (_command_definitions[id].action == MODIFIER_COMMAND) {
            command_definition_id = id;
            break;
        }
    }
    if (command_definition_id < 0) {
        error = "effect_retire_modifier_command_missing";
        return false;
    }
    const CommandDefinition &definition_command =
        _command_definitions[command_definition_id];
    Command command;
    command.action = MODIFIER_COMMAND;
    command.domain = definition_command.domain;
    command.opcode = ModifierRuntime::COMMAND_REMOVE;
    command.duration_days = -1;
    command.stacks = 1;
    command.command_key_id = command_definition_id;
    command.command_definition_id = command_definition_id;
    if (definition_command.target_resolver == TARGET_STATIC) {
        command.target_handle = definition_command.static_target;
    } else if (definition_command.target_resolver == TARGET_SOURCE) {
        command.target_handle = instance.source_handle;
        command.target_generation = instance.generation;
    } else {
        command.target_handle = instance.target_handle;
        command.target_generation = instance.target_generation;
    }
    ++instance.fire_sequence;
    command.idempotency_key = command_idempotency_key(instance,
        static_cast<uint32_t>(definition.command_count));
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = instance.id;
    transaction.source_generation = instance.generation;
    transaction.program_id = instance.program_id;
    transaction.effective_day = effective_day;
    append_command(transaction, command);
    if (transaction.command_count == 0 || transaction.required_ack_mask == 0) {
        error = "effect_retire_command_invalid";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_instance_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.program_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.action);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.domain);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.opcode);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.target_handle);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.target_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.value_q16);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.duration_days);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.stacks);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.command_key_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        command.command_definition_id);
    for (const int64_t payload_value : command.payload)
        transaction.plan_hash = fnv_value(transaction.plan_hash, payload_value);
    transaction.plan_hash = fnv_value(transaction.plan_hash, command.idempotency_key);
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    instance.active = 0;
    instance.schedule_token = 0;
    return true;
}

bool EffectRuntime::execute_program(const Definition &definition, Instance &instance,
                                     int64_t day, Transaction &transaction,
                                     std::string &error) {
    std::array<int64_t, MAX_STACK> stack{};
    int32_t sp = 0;
    const int32_t begin = definition.instruction_begin;
    const int32_t end = begin + definition.instruction_count;
    for (int32_t i = begin; i < end; ++i) {
        const InstructionRow &row = _instructions[i];
        switch (row.op) {
            case CONST:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = row.value;
                break;
            case READ_METRIC:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = metric_value(instance, row.arg0);
                break;
            case READ_STATE:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = state_value(instance, row.arg0);
                break;
            case ADD:
            case SUB:
            case MUL_Q16:
            case DIV_FLOOR:
            case MIN:
            case MAX:
                if (sp < 2) { error = "effect_value_stack_underflow"; return false; }
                if (row.op == ADD) stack[sp - 2] = saturating_add(stack[sp - 2], stack[sp - 1]);
                else if (row.op == SUB) stack[sp - 2] = saturating_sub(stack[sp - 2], stack[sp - 1]);
                else if (row.op == MUL_Q16) stack[sp - 2] = mul_q16(stack[sp - 2], stack[sp - 1]);
                else if (row.op == DIV_FLOOR) {
                    if (stack[sp - 1] == 0) { error = "effect_division_by_zero"; return false; }
                    const int64_t quotient = floor_div(stack[sp - 2], stack[sp - 1]);
                    if (quotient > std::numeric_limits<int64_t>::max() / Q16_ONE ||
                        quotient < std::numeric_limits<int64_t>::min() / Q16_ONE) {
                        error = "effect_division_overflow";
                        return false;
                    }
                    stack[sp - 2] = quotient * Q16_ONE;
                } else if (row.op == MIN) stack[sp - 2] = std::min(stack[sp - 2], stack[sp - 1]);
                else stack[sp - 2] = std::max(stack[sp - 2], stack[sp - 1]);
                --sp;
                break;
            case CLAMP:
                if (sp < 1) { error = "effect_value_stack_underflow"; return false; }
                stack[sp - 1] = std::max(row.value, std::min(stack[sp - 1],
                    static_cast<int64_t>(row.arg0)));
                break;
            case EMIT_COMMAND: {
                if (row.arg0 < 0 || row.arg0 >= definition.command_count) {
                    error = "effect_command_index_invalid"; return false;
                }
                const CommandDefinition &definition_command =
                    _command_definitions[definition.command_begin + row.arg0];
                Command command;
                command.action = definition_command.action;
                command.domain = definition_command.domain;
                command.opcode = definition_command.opcode;
                command.duration_days = definition_command.duration_days;
                command.stacks = definition_command.stacks;
                command.payload = definition_command.payload;
                command.value_q16 = definition_command.value_mode == VALUE_STACK_TOP
                    ? (sp > 0 ? stack[sp - 1] : 0) : definition_command.value;
                const int32_t command_definition_id =
                    definition.command_begin + row.arg0;
                command.command_definition_id = command_definition_id;
                command.command_key_id = command_definition_id;
                if (definition_command.target_resolver == TARGET_STATIC)
                    command.target_handle = definition_command.static_target;
                else if (definition_command.target_resolver == TARGET_SOURCE) {
                    command.target_handle = instance.source_handle;
                    command.target_generation = instance.generation;
                } else {
                    command.target_handle = instance.target_handle;
                    command.target_generation = instance.target_generation;
                }
                command.idempotency_key = command_idempotency_key(
                    instance, static_cast<uint32_t>(row.arg0));
                append_command(transaction, command);
                break;
            }
            case END:
                return true;
            default:
                error = "effect_instruction_opcode_invalid";
                return false;
        }
    }
    (void)day;
    return true;
}

void EffectRuntime::append_planned_command(std::vector<Command> &commands,
                                           uint32_t &required_ack_mask,
                                           const Command &command) {
    for (const Command &existing : commands) {
        if (existing.idempotency_key == command.idempotency_key) return;
    }
    commands.push_back(command);
    required_ack_mask |= adapter_ack_bit_for(command);
}

uint32_t EffectRuntime::adapter_ack_bit_for(const Command &command) {
    return native_adapter_ack_bit(command.action);
}

bool EffectRuntime::execute_program_plan(const Definition &definition,
                                         const Instance &instance,
                                         int64_t day,
                                         std::vector<Command> &commands,
                                         uint32_t &required_ack_mask,
                                         std::string &error) const {
    std::array<int64_t, MAX_STACK> stack{};
    int32_t sp = 0;
    const int32_t begin = definition.instruction_begin;
    const int32_t end = begin + definition.instruction_count;
    for (int32_t i = begin; i < end; ++i) {
        const InstructionRow &row = _instructions[i];
        switch (row.op) {
            case CONST:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = row.value;
                break;
            case READ_METRIC:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = metric_value(instance, row.arg0);
                break;
            case READ_STATE:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = state_value(instance, row.arg0);
                break;
            case ADD:
            case SUB:
            case MUL_Q16:
            case DIV_FLOOR:
            case MIN:
            case MAX:
                if (sp < 2) { error = "effect_value_stack_underflow"; return false; }
                if (row.op == ADD) stack[sp - 2] = saturating_add(stack[sp - 2], stack[sp - 1]);
                else if (row.op == SUB) stack[sp - 2] = saturating_sub(stack[sp - 2], stack[sp - 1]);
                else if (row.op == MUL_Q16) stack[sp - 2] = mul_q16(stack[sp - 2], stack[sp - 1]);
                else if (row.op == DIV_FLOOR) {
                    if (stack[sp - 1] == 0) { error = "effect_division_by_zero"; return false; }
                    const int64_t quotient = floor_div(stack[sp - 2], stack[sp - 1]);
                    if (quotient > std::numeric_limits<int64_t>::max() / Q16_ONE ||
                        quotient < std::numeric_limits<int64_t>::min() / Q16_ONE) {
                        error = "effect_division_overflow";
                        return false;
                    }
                    stack[sp - 2] = quotient * Q16_ONE;
                } else if (row.op == MIN) stack[sp - 2] = std::min(stack[sp - 2], stack[sp - 1]);
                else stack[sp - 2] = std::max(stack[sp - 2], stack[sp - 1]);
                --sp;
                break;
            case CLAMP:
                if (sp < 1) { error = "effect_value_stack_underflow"; return false; }
                stack[sp - 1] = std::max(row.value, std::min(stack[sp - 1],
                    static_cast<int64_t>(row.arg0)));
                break;
            case EMIT_COMMAND: {
                if (row.arg0 < 0 || row.arg0 >= definition.command_count) {
                    error = "effect_command_index_invalid"; return false;
                }
                const CommandDefinition &definition_command =
                    _command_definitions[definition.command_begin + row.arg0];
                Command command;
                command.action = definition_command.action;
                command.domain = definition_command.domain;
                command.opcode = definition_command.opcode;
                command.duration_days = definition_command.duration_days;
                command.stacks = definition_command.stacks;
                command.payload = definition_command.payload;
                command.value_q16 = definition_command.value_mode == VALUE_STACK_TOP
                    ? (sp > 0 ? stack[sp - 1] : 0) : definition_command.value;
                const int32_t command_definition_id = definition.command_begin + row.arg0;
                command.command_definition_id = command_definition_id;
                command.command_key_id = command_definition_id;
                if (definition_command.target_resolver == TARGET_STATIC)
                    command.target_handle = definition_command.static_target;
                else if (definition_command.target_resolver == TARGET_SOURCE) {
                    command.target_handle = instance.source_handle;
                    command.target_generation = instance.generation;
                } else {
                    command.target_handle = instance.target_handle;
                    command.target_generation = instance.target_generation;
                }
                command.idempotency_key = command_idempotency_key(
                    instance, static_cast<uint32_t>(row.arg0));
                append_planned_command(commands, required_ack_mask, command);
                break;
            }
            case END:
                return true;
            default:
                error = "effect_instruction_opcode_invalid";
                return false;
        }
    }
    (void)day;
    return true;
}

bool EffectRuntime::build_planned_candidate(int32_t candidate_cursor,
                                            int32_t instance_index,
                                            int64_t day,
                                            PlannedCandidate &plan) const {
    plan = PlannedCandidate();
    plan.candidate_cursor = candidate_cursor;
    plan.instance_index = instance_index;
    if (instance_index < 0 || instance_index >= static_cast<int32_t>(_instances.size())) return true;
    const Instance &instance = _instances[static_cast<size_t>(instance_index)];
    const Definition *definition =
        (instance.program_id >= 0 && instance.program_id < static_cast<int32_t>(_definitions.size()))
        ? &_definitions[instance.program_id] : nullptr;
    plan.work = std::max(1, definition != nullptr ? definition->max_work : 1);
    if (!instance.active || definition == nullptr ||
        (instance.next_due_day > day &&
         instance.input_revision <= instance.last_evaluated_input_revision))
        return true;
    plan.eligible = 1;
    if (!definition->enabled) return true;
    plan.enabled = 1;
    if (!evaluate_condition(*definition, instance)) return true;
    plan.passes = 1;
    if (!definition->behavior_id.empty()) {
        plan.error = "effect_behavior_requires_serial";
        plan.behavior_failure = 1;
        return false;
    }
    Instance planning_instance = instance;
    planning_instance.fire_sequence = instance.fire_sequence + 1;
    plan.planned_fire_sequence = planning_instance.fire_sequence;
    if (definition->instruction_count > 0 &&
        !execute_program_plan(*definition, planning_instance, day, plan.commands,
                              plan.required_ack_mask, plan.error))
        return false;
    return true;
}

Dictionary EffectRuntime::run_daily(int64_t day_index) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (day_index < _last_completed_day) return failure("effect_day_rewind");
    if (_run_day >= 0 && _run_day != day_index &&
        _candidate_cursor < static_cast<int32_t>(_run_candidates.size()) &&
        _run_day != _last_completed_day) {
        // An unfinished same-day slice must not freeze Effect across calendar
        // days. Re-queue remaining candidates for today and rebuild.
        for (int32_t cursor = _candidate_cursor;
             cursor < static_cast<int32_t>(_run_candidates.size()); ++cursor) {
            const int32_t index = _run_candidates[static_cast<size_t>(cursor)];
            if (index < 0 || index >= static_cast<int32_t>(_instances.size())) continue;
            Instance &instance = _instances[static_cast<size_t>(index)];
            if (!instance.active) continue;
            instance.next_due_day = std::min(instance.next_due_day, day_index);
            schedule_instance(index, day_index);
        }
        _candidate_cursor = static_cast<int32_t>(_run_candidates.size());
        _last_completed_day = _run_day;
        _run_cursor = _candidate_cursor;
    }
    const auto started = std::chrono::steady_clock::now();
    if (_run_day != day_index) {
        _run_day = day_index;
        rebuild_run_candidates(day_index);
        _candidate_cursor = 0;
        _run_cursor = 0;
    } else if (_candidate_cursor >= static_cast<int32_t>(_run_candidates.size()) &&
               (!_dirty_queue.empty() ||
                (!_due_heap.empty() && _due_heap.top().day <= day_index))) {
        // New snapshots/submissions can make a completed same-day run dirty.
        // Rebuild only when there is actual work; never scan dormant instances.
        rebuild_run_candidates(day_index);
        _run_cursor = 0;
    }
    _current_day = day_index;
    int32_t work = 0;
    const int32_t budget = std::max(1, _max_work_per_slice);
    const bool has_evaluation_work =
        _candidate_cursor < static_cast<int32_t>(_run_candidates.size());
    if (!has_evaluation_work) {
        _last_completed_day = day_index;
        _last_evaluate_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        Dictionary out;
        out["ok"] = true;
        out["done"] = true;
        out["stage"] = "effect_dispatch";
        out["path"] = "EFFECT_GRAPH";
        out["work_done"] = 0;
        out["progress_ratio"] = 1.0;
        out["transactions_planned"] = static_cast<int64_t>(_transactions.size());
        out["candidate_count"] = static_cast<int64_t>(_run_candidates.size());
        out["evaluated_count"] = 0;
        out["elapsed_ms"] = _last_evaluate_ms;
        out["last_error"] = String(_last_error.c_str());
        return out;
    }
    auto evaluation_failure = [&](const std::string &reason) {
        _last_error = reason;
        _last_evaluate_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        Dictionary out;
        out["ok"] = false;
        out["done"] = false;
        out["reason"] = String(reason.c_str());
        out["stage"] = "effect_evaluate";
        out["path"] = "EFFECT_GRAPH";
        out["work_done"] = work;
        out["run_cursor"] = _candidate_cursor;
        out["progress_ratio"] = _run_candidates.empty() ? 1.0 :
            static_cast<double>(_candidate_cursor) /
            static_cast<double>(_run_candidates.size());
        out["elapsed_ms"] = _last_evaluate_ms;
        out["last_error"] = String(_last_error.c_str());
        return out;
    };

    // Declarative IR evaluation is read-only over the frozen instance/metric
    // slabs. Plan a contiguous slice in workers, then replay it in candidate
    // order so fire sequences, transaction ids, capacity backpressure and
    // idempotency remain bit-identical to the serial path. Behavior callbacks
    // deliberately stay on the existing serial path until a callback is
    // explicitly certified thread-safe by its owner.
    int32_t batch_end = _candidate_cursor;
    int32_t batch_work = 0;
    bool batch_declarative = true;
    while (batch_end < static_cast<int32_t>(_run_candidates.size())) {
        const int32_t index = _run_candidates[static_cast<size_t>(batch_end)];
        const Definition *definition = nullptr;
        if (index >= 0 && index < static_cast<int32_t>(_instances.size())) {
            const Instance &instance = _instances[static_cast<size_t>(index)];
            if (instance.program_id >= 0 &&
                instance.program_id < static_cast<int32_t>(_definitions.size()))
                definition = &_definitions[instance.program_id];
        }
        const int32_t cost = std::max(1, definition != nullptr ? definition->max_work : 1);
        if (batch_end > _candidate_cursor && batch_work + cost > budget) break;
        if (definition != nullptr && !definition->behavior_id.empty()) {
            batch_declarative = false;
            break;
        }
        batch_work += cost;
        ++batch_end;
        if (batch_work >= budget) break;
    }
    const int32_t batch_count = batch_end - _candidate_cursor;
    const bool has_workers = parallel_has_real_worker_threads();
    const bool use_parallel_plan = batch_declarative && batch_count >= 64;
    if (batch_count > 1 && batch_declarative && !has_workers) {
        _last_parallel_path = "serial_fallback";
        _last_parallel_fallback_reason = "no_worker_threads";
        ++_serial_fallback_dispatches;
    } else if (batch_count < 64 || !batch_declarative) {
        _last_parallel_path = "serial";
        _last_parallel_fallback_reason = !batch_declarative
            ? "behavior_callback_requires_serial" : "batch_below_parallel_threshold";
        ++_serial_fallback_dispatches;
    }
    if (use_parallel_plan) {
        const auto planning_started = std::chrono::steady_clock::now();
        _last_parallel_path = has_workers ? "parallel_plan_serial_merge"
                                          : "serial_fallback_plan_merge";
        _last_parallel_fallback_reason = has_workers ? "" : "no_worker_threads";
        _last_parallel_worker_count = has_workers ? parallel_default_n_tasks(batch_count) : 1;
        std::vector<PlannedCandidate> plans(static_cast<size_t>(batch_count));
        auto plan_range = [&](int begin, int end) {
            for (int offset = begin; offset < end; ++offset) {
                const int32_t cursor = _candidate_cursor + offset;
                const int32_t instance_index = _run_candidates[static_cast<size_t>(cursor)];
                build_planned_candidate(cursor, instance_index, day_index,
                                        plans[static_cast<size_t>(offset)]);
            }
        };
        parallel_for_range("pk_effect_plan", batch_count, 0, 64, plan_range);
        _last_parallel_planning_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - planning_started).count();
        if (has_workers) ++_parallel_dispatches;

        const auto merge_started = std::chrono::steady_clock::now();
        for (int32_t offset = 0; offset < batch_count; ++offset) {
            PlannedCandidate &plan = plans[static_cast<size_t>(offset)];
            const int32_t instance_cursor = _candidate_cursor;
            if (plan.candidate_cursor != instance_cursor) {
                _last_error = "effect_parallel_candidate_order_invalid";
                return evaluation_failure(_last_error);
            }
            if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                compact_terminal_transactions();
                if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                    ++_overflow_count;
                    return evaluation_failure("effect_transaction_capacity_exceeded");
                }
            }
            if (plan.instance_index < 0 ||
                plan.instance_index >= static_cast<int32_t>(_instances.size())) {
                ++_candidate_cursor;
                _run_cursor = _candidate_cursor;
                continue;
            }
            Instance &instance = _instances[static_cast<size_t>(plan.instance_index)];
            if (!plan.eligible) {
                ++_candidate_cursor;
                _run_cursor = _candidate_cursor;
                continue;
            }
            ++_programs_evaluated;
            if (!plan.enabled || !plan.passes) {
                const Definition &definition = _definitions[instance.program_id];
                instance.next_due_day = day_index + std::max<int32_t>(1, definition.cadence_days);
                instance.last_evaluated_input_revision = instance.input_revision;
                schedule_instance(plan.instance_index, instance.next_due_day);
                instance.dirty_epoch = 0;
                ++_candidate_cursor;
                _run_cursor = _candidate_cursor;
                continue;
            }
            if (!plan.error.empty()) {
                if (plan.behavior_failure) ++_behavior_failures;
                if (plan.overflowed) ++_overflow_count;
                return evaluation_failure(plan.error);
            }
            if (!plan.commands.empty()) {
                if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                    ++_overflow_count;
                    return evaluation_failure("effect_transaction_capacity_exceeded");
                }
            }
            instance.fire_sequence = plan.planned_fire_sequence;
            Transaction transaction;
            transaction.source_instance_id = instance.id;
            transaction.source_generation = instance.generation;
            transaction.program_id = instance.program_id;
            transaction.effective_day = day_index;
            for (const Command &command : plan.commands)
                append_command(transaction, command);
            if (transaction.command_count != 0) {
                transaction.plan_hash = 1469598103934665603ULL;
                transaction.plan_hash = fnv_value(transaction.plan_hash,
                    transaction.source_instance_id);
                transaction.plan_hash = fnv_value(transaction.plan_hash,
                    transaction.source_generation);
                transaction.plan_hash = fnv_value(transaction.plan_hash,
                    transaction.program_id);
                transaction.plan_hash = fnv_value(transaction.plan_hash,
                    transaction.effective_day);
                for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
                    const Command *command = command_at(transaction, ordinal);
                    if (command == nullptr) continue;
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->action);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->domain);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->opcode);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_handle);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_generation);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->value_q16);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->duration_days);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->stacks);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->command_key_id);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        command->command_definition_id);
                    for (int64_t payload_value : command->payload)
                        transaction.plan_hash = fnv_value(transaction.plan_hash, payload_value);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->idempotency_key);
                }
                transaction.id = _next_transaction_id++;
                if (transaction.required_ack_mask == 0) transaction.status = COMMITTED;
                _transactions.push_back(std::move(transaction));
                _transaction_ids[_transactions.back().id] =
                    static_cast<int32_t>(_transactions.size() - 1);
                track_pending_transaction(_transactions.back());
                index_transaction_commands(_transactions.back());
            }
            const Definition &definition = _definitions[instance.program_id];
            instance.next_due_day = day_index + std::max<int32_t>(1, definition.cadence_days);
            instance.last_evaluated_input_revision = instance.input_revision;
            schedule_instance(plan.instance_index, instance.next_due_day);
            instance.dirty_epoch = 0;
            ++_candidate_cursor;
            _run_cursor = _candidate_cursor;
        }
        _last_parallel_merge_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - merge_started).count();
        work = batch_work;
    }
    while (_candidate_cursor < static_cast<int32_t>(_run_candidates.size()) && work < budget) {
        // Terminal transactions no longer participate in replay. Reclaim them
        // before evaluating a new instance so a bounded queue applies
        // backpressure instead of dropping the current effect.
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            compact_terminal_transactions();
            if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                ++_overflow_count;
                return evaluation_failure("effect_transaction_capacity_exceeded");
            }
        }
        const int32_t instance_cursor = _candidate_cursor;
        const int32_t instance_index = _run_candidates[static_cast<size_t>(_candidate_cursor)];
        if (instance_index < 0 || instance_index >= static_cast<int32_t>(_instances.size())) {
            ++_candidate_cursor;
            _run_cursor = _candidate_cursor;
            continue;
        }
        Instance &instance = _instances[static_cast<size_t>(instance_index)];
        const uint64_t prior_fire_sequence = instance.fire_sequence;
        const int64_t prior_next_due_day = instance.next_due_day;
        const uint64_t prior_commands_emitted = _commands_emitted;
        const Definition *work_definition =
            (instance.program_id >= 0 &&
             instance.program_id < static_cast<int32_t>(_definitions.size()))
            ? &_definitions[instance.program_id] : nullptr;
        // max_work is the scheduler charge for one definition evaluation. A
        // single definition is always allowed to run once even when its
        // charge exceeds the slice budget; otherwise it could starve forever.
        const int32_t definition_work = std::max(1,
            work_definition != nullptr ? work_definition->max_work : 1);
        if (work > 0 && work + definition_work > budget) break;
        ++_candidate_cursor;
        _run_cursor = _candidate_cursor;
        work += definition_work;
        if (!instance.active || instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_definitions.size()) ||
            (instance.next_due_day > day_index &&
             instance.input_revision <= instance.last_evaluated_input_revision))
            continue;
        const Definition &definition = _definitions[instance.program_id];
        ++_programs_evaluated;
        if (!definition.enabled) {
            instance.next_due_day = day_index + std::max<int32_t>(1, definition.cadence_days);
            instance.last_evaluated_input_revision = instance.input_revision;
            schedule_instance(instance_index, instance.next_due_day);
            instance.dirty_epoch = 0;
            continue;
        }
        const bool passes = evaluate_condition(definition, instance);
        if (passes) {
            ++instance.fire_sequence;
            Transaction transaction;
            transaction.source_instance_id = instance.id;
            transaction.source_generation = instance.generation;
            transaction.program_id = instance.program_id;
            transaction.effective_day = day_index;
            std::string error;
            if (!definition.behavior_id.empty()) {
                BehaviorFn behavior = nullptr;
                {
                    std::lock_guard<std::mutex> lock(behavior_registry_mutex());
                    auto it = behavior_registry().find(definition.behavior_id);
                    if (it != behavior_registry().end()) behavior = it->second;
                }
                if (behavior == nullptr) {
                    ++_behavior_failures;
                    error = "effect_behavior_not_registered:" + definition.behavior_id;
                    _last_error = error;
                } else {
                    BehaviorInput input;
                    input.instance_id = instance.id;
                    input.instance_generation = instance.generation;
                    input.program_id = instance.program_id;
                    input.level = instance.level;
                    input.day = day_index;
                    input.target_handle = instance.target_handle;
                    input.source_handle = instance.source_handle;
                    input.metrics = metric_ptr(instance, 0);
                    input.metric_count = _metric_count;
                    BehaviorOutput output;
                    output.commands = _behavior_command_buffer.data();
                    output.capacity = std::min<int32_t>(definition.max_work,
                        static_cast<int32_t>(_behavior_command_buffer.size()));
                    if (!behavior(input, output, error)) {
                        ++_behavior_failures;
                        _last_error = error.empty() ? "effect_behavior_failed" : error;
                    } else {
                        if (output.overflowed || output.count < 0 || output.count > output.capacity) {
                            ++_behavior_failures;
                            ++_overflow_count;
                            _last_error = "effect_behavior_output_capacity_exceeded";
                            error = _last_error;
                        }
                        for (int32_t command_index = 0;
                             error.empty() && command_index < output.count; ++command_index) {
                            const BehaviorCommand &source = output.commands[command_index];
                            Command command;
                            command.action = source.action;
                            command.domain = source.domain;
                            command.opcode = source.opcode;
                            command.target_handle = source.target_handle;
                            command.target_generation = source.target_generation;
                            command.value_q16 = source.value_q16;
                            command.duration_days = source.duration_days;
                            command.stacks = source.stacks;
                            if (source.command_key_id < -1 ||
                                source.command_key_id >= static_cast<int32_t>(
                                    _behavior_command_keys.size())) {
                                error = "effect_behavior_command_key_invalid";
                                break;
                            }
                            command.command_key_id = source.command_key_id;
                            command.command_definition_id = -1;
                            command.payload = source.payload;
                            command.idempotency_key = command_idempotency_key(instance,
                                static_cast<uint32_t>(command_index));
                            append_command(transaction, command);
                        }
                    }
                }
            }
            if (error.empty() && definition.instruction_count > 0 &&
                !execute_program(definition, instance, day_index, transaction, error)) {
                _last_error = error;
            }
            if (!error.empty()) {
                // Do not advance a failing effect. The same frozen input can
                // be retried after the missing behavior/adapter/configuration
                // is repaired, without producing a duplicate fire sequence.
                _commands_emitted = prior_commands_emitted;
                instance.fire_sequence = prior_fire_sequence;
                instance.next_due_day = prior_next_due_day;
                    _candidate_cursor = instance_cursor;
                    _run_cursor = _candidate_cursor;
                    return evaluation_failure(error);
            }
            if (transaction.command_count != 0) {
                if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                    // Completed transactions are no longer needed for replay:
                    // `_acked_transaction_id` and command idempotency keys
                    // already make retries safe. Reclaim them before treating
                    // the bounded pending queue as overflowed.
                    compact_terminal_transactions();
                }
                if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                    ++_overflow_count;
                    _last_error = "effect_transaction_capacity_exceeded";
                    _commands_emitted = prior_commands_emitted;
                    instance.fire_sequence = prior_fire_sequence;
                    instance.next_due_day = prior_next_due_day;
                    _candidate_cursor = instance_cursor;
                    _run_cursor = _candidate_cursor;
                    return evaluation_failure(_last_error);
                }
                transaction.plan_hash = 1469598103934665603ULL;
                transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.source_instance_id);
                transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.source_generation);
                transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.program_id);
                transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
                for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
                    const Command *command = command_at(transaction, ordinal);
                    if (command == nullptr) continue;
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->action);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->domain);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->opcode);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_handle);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_generation);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->value_q16);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->duration_days);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->stacks);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        command->command_key_id);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        command->command_definition_id);
                    for (int64_t payload_value : command->payload)
                        transaction.plan_hash = fnv_value(transaction.plan_hash, payload_value);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->idempotency_key);
                }
                transaction.id = _next_transaction_id++;
                if (transaction.required_ack_mask == 0)
                    transaction.status = COMMITTED;
                _transactions.push_back(std::move(transaction));
                _transaction_ids[_transactions.back().id] =
                    static_cast<int32_t>(_transactions.size() - 1);
                track_pending_transaction(_transactions.back());
                index_transaction_commands(_transactions.back());
            }
        }
        instance.next_due_day = day_index + std::max<int32_t>(1, definition.cadence_days);
        instance.last_evaluated_input_revision = instance.input_revision;
        schedule_instance(instance_index, instance.next_due_day);
        // The candidate has consumed its current frozen snapshot. A later
        // same-day publish must be able to enqueue one new dirty candidate.
        instance.dirty_epoch = 0;
    }
    const bool done = _candidate_cursor >= static_cast<int32_t>(_run_candidates.size());
    if (done) _last_completed_day = day_index;
    _last_evaluate_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    Dictionary out;
    out["ok"] = true;
    out["done"] = done;
    out["stage"] = "effect_evaluate";
    out["path"] = "EFFECT_GRAPH";
    out["work_done"] = work;
    out["progress_ratio"] = _run_candidates.empty() ? 1.0 :
        static_cast<double>(_candidate_cursor) /
        static_cast<double>(_run_candidates.size());
    out["transactions_planned"] = static_cast<int64_t>(_transactions.size());
    out["candidate_count"] = static_cast<int64_t>(_run_candidates.size());
    out["evaluated_count"] = work;
    out["elapsed_ms"] = _last_evaluate_ms;
    out["last_error"] = String(_last_error.c_str());
    return out;
}

Dictionary EffectRuntime::dispatch_native_modifier(ModifierRuntime *modifier_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (modifier_runtime == nullptr || !modifier_runtime->configured())
        return failure("modifier_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();

    auto binding_exists = [&](int64_t transaction_id) {
        return _native_bound_transaction_ids.find(transaction_id) !=
            _native_bound_transaction_ids.end();
    };
    auto definition_key_ptr = [&](const Command &command) -> const std::string * {
        if (command.command_definition_id >= 0 &&
            command.command_definition_id < static_cast<int32_t>(_command_definitions.size()))
            return &_command_definitions[command.command_definition_id].definition_key;
        return nullptr;
    };

    struct PendingTransaction {
        int32_t transaction_index = -1;
        uint32_t request_offset = 0;
        uint32_t request_count = 0;
        uint32_t domain_mask = 0;
    };
    std::vector<ModifierRuntime::NativeCommand> native_commands;
    std::vector<PendingTransaction> pending_transactions;
    native_commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    pending_transactions.reserve(std::min<int32_t>(_max_transactions, 4096));

    // A transaction may contain commands for several native domains. Each
    // adapter claims only its own command subset; the shared ACK mask keeps the
    // transaction hidden from fallback polling until every domain is done.
    for (int32_t tx_index = 0;
         tx_index < static_cast<int32_t>(_transactions.size());
         ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        if (binding_exists(transaction.id) || transaction.command_count == 0 ||
            transaction.required_ack_mask == 0)
            continue;

        const int32_t instance_index = instance_index_for_id(transaction.source_instance_id);
        const Instance *source_instance = instance_index >= 0 &&
            instance_index < static_cast<int32_t>(_instances.size())
            ? &_instances[static_cast<size_t>(instance_index)] : nullptr;
        if (source_instance == nullptr ||
            source_instance->generation != transaction.source_generation)
            continue;

        const uint32_t request_offset = static_cast<uint32_t>(native_commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) { supported = false; break; }
            if (command->action != MODIFIER_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            const std::string *definition_key = definition_key_ptr(*command);
            if (definition_key == nullptr || definition_key->empty()) {
                supported = false;
                break;
            }
            int32_t adapter_kind = NATIVE_MODIFIER_GENERIC;
            if (command->command_definition_id >= 0 &&
                command->command_definition_id < static_cast<int32_t>(
                    _command_definitions.size())) {
                adapter_kind = _command_definitions[
                    static_cast<size_t>(command->command_definition_id)]
                    .native_modifier_adapter;
            } else {
                // Behavior commands are a compile-time extension point. Keep
                // their legacy key compatibility outside declarative content;
                // ordinary catalog/template commands never execute this
                // string branch in the native daily adapter path.
                const std::string behavior_key = command_key_for(*command);
                if (behavior_key == "technology.modifier")
                    adapter_kind = NATIVE_MODIFIER_TECHNOLOGY;
                else if (behavior_key == "family.modifier")
                    adapter_kind = NATIVE_MODIFIER_FAMILY;
                else if (behavior_key == "person.modifier")
                    adapter_kind = NATIVE_MODIFIER_PERSON;
                else if (behavior_key == "trigger.modifier")
                    adapter_kind = NATIVE_MODIFIER_TRIGGER;
            }
            ModifierRuntime::NativeCommand native;
            native.opcode = command->opcode;
            native.sequence = static_cast<int64_t>(command->idempotency_key &
                0x7fffffffffffffffULL);
            native.effective_day = transaction.effective_day;
            native.definition_key = definition_key->c_str();
            native.duration_days = command->duration_days;
            native.stacks = std::max(1, command->stacks);
            native.modifier_handle = 0;

            if (adapter_kind == NATIVE_MODIFIER_TECHNOLOGY) {
                native.producer = 180;
                native.domain = ModifierRuntime::COUNTRY;
                native.scope = ModifierRuntime::ENTITY;
                native.entity_handle = command->target_handle;
                native.source_type = 0x54454348ULL; // TECH
                native.source_id = static_cast<uint64_t>(transaction.source_instance_id) & 0xffffULL;
                native.magnitude_q16 = ModifierRuntime::Q16_ONE;
            } else if (adapter_kind == NATIVE_MODIFIER_FAMILY) {
                native.producer = 160;
                native.domain = ModifierRuntime::ECONOMY;
                native.scope = ModifierRuntime::GROUP;
                native.group_handle = command->target_generation;
                native.source_type = 0x46414d494c59ULL; // FAMILY
                native.source_id = command->target_handle;
                native.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
                    command->value_q16, 0, ModifierRuntime::MAX_MAGNITUDE_Q16));
            } else if (adapter_kind == NATIVE_MODIFIER_PERSON) {
                native.producer = 170;
                native.domain = command->domain;
                native.scope = ModifierRuntime::ENTITY;
                native.entity_handle = command->target_handle;
                native.source_type = 0x504552534f4eULL; // PERSON
                native.source_id = static_cast<uint64_t>(transaction.source_instance_id);
                native.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
                    std::max<int64_t>(1, command->value_q16), 0,
                    ModifierRuntime::MAX_MAGNITUDE_Q16));
            } else if (adapter_kind == NATIVE_MODIFIER_TRIGGER) {
                native.producer = 175;
                native.domain = command->domain;
                native.scope = ModifierRuntime::ENTITY;
                native.entity_handle = command->target_handle;
                native.source_type = 0x54524947474552ULL; // TRIGGER
                native.source_id = static_cast<uint64_t>(
                    transaction.source_instance_id);
                native.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
                    command->value_q16, 0, ModifierRuntime::MAX_MAGNITUDE_Q16));
            } else if (command->action == MODIFIER_COMMAND) {
                // Generic declarative Modifier command. Complex target/source
                // resolvers stay on the adapter path until declared natively.
                native.producer = 200;
                native.domain = command->domain;
                native.scope = ModifierRuntime::ENTITY;
                native.entity_handle = command->target_handle;
                native.source_type = static_cast<uint64_t>(source_instance->source_type);
                native.source_id = static_cast<uint64_t>(source_instance->source_id);
                native.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
                    command->value_q16, 0, ModifierRuntime::MAX_MAGNITUDE_Q16));
            } else {
                supported = false;
                break;
            }
            if (command->domain >= 0 && command->domain < 32)
                domain_mask |= adapter_ack_bit_for(*command);
            native_commands.push_back(native);
        }
        if (!supported) {
            native_commands.resize(request_offset);
            break;
        }
        const uint32_t request_count = static_cast<uint32_t>(native_commands.size()) -
            request_offset;
        if (request_count == 0 || domain_mask == 0) continue;
        if (native_commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            native_commands.resize(request_offset);
            continue;
        }
        pending_transactions.push_back({tx_index, request_offset, request_count, domain_mask});
    }

    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    if (native_commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }

    std::vector<int64_t> request_ids;
    std::string error;
    if (!modifier_runtime->submit_commands_pod(native_commands.data(), native_commands.size(),
                                               request_ids, error) ||
        request_ids.size() != native_commands.size()) {
        _last_error = error.empty() ? "effect_native_modifier_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    for (const PendingTransaction &pending : pending_transactions) {
        Transaction &transaction = _transactions[static_cast<size_t>(pending.transaction_index)];
        const uint32_t request_begin = static_cast<uint32_t>(_native_request_ids.size());
        _native_request_ids.insert(_native_request_ids.end(),
            request_ids.begin() + pending.request_offset,
            request_ids.begin() + pending.request_offset + pending.request_count);
        _native_ack_bindings.push_back({transaction.id, request_begin,
            pending.request_count, pending.domain_mask});
        _native_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending_transactions.size());
    out["submitted_commands"] = static_cast<int32_t>(native_commands.size());
    _native_modifier_transactions += pending_transactions.size();
    _native_modifier_commands += native_commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_modifier(ModifierRuntime *modifier_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (modifier_runtime == nullptr || !modifier_runtime->configured())
        return failure("modifier_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();

    int32_t acknowledged = 0;
    int32_t rejected = 0;
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_request_ids;
    retained.reserve(_native_ack_bindings.size());
    retained_request_ids.reserve(_native_request_ids.size());
    for (const NativeAckBinding &binding : _native_ack_bindings) {
        const int32_t tx_index = transaction_index_for_id(binding.transaction_id);
        Transaction *transaction = tx_index >= 0 &&
            tx_index < static_cast<int32_t>(_transactions.size())
            ? &_transactions[static_cast<size_t>(tx_index)] : nullptr;
        if (transaction == nullptr || transaction->status == ACKED ||
            transaction->status == REJECTED || transaction->status == RESYNC_REQUIRED)
            continue;
        bool pending = false;
        bool failed = false;
        std::string failure_reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_request_ids.size()) {
                failed = true;
                failure_reason = "effect_native_modifier_binding_invalid";
                break;
            }
            bool complete = false, ok = false;
            std::string reason;
            modifier_runtime->command_result_pod(_native_request_ids[request_index],
                                                 complete, ok, reason);
            if (!complete) {
                pending = true;
                break;
            }
            if (!ok) {
                failed = true;
                failure_reason = reason.empty() ? "effect_native_modifier_rejected" : reason;
                break;
            }
        }
        if (pending) {
            NativeAckBinding kept = binding;
            kept.request_begin = static_cast<uint32_t>(retained_request_ids.size());
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_request_ids.push_back(_native_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(*transaction);
            transaction->status = REJECTED;
            ++_preflight_rejects;
            ++rejected;
            _last_error = failure_reason;
            continue;
        }
        acknowledge_native_domain(*transaction, binding.domain_bit);
        ++acknowledged;
    }
    for (const NativeAckBinding &binding : _native_ack_bindings) {
        if (std::find_if(retained.begin(), retained.end(),
                [&](const NativeAckBinding &candidate) {
                    return candidate.transaction_id == binding.transaction_id;
                }) == retained.end())
            _native_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_ack_bindings.swap(retained);
    _native_request_ids.swap(retained_request_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_modifier_acks += static_cast<uint64_t>(acknowledged);
    _last_native_ack_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::dispatch_native_country(NativeCountryRuntime *country_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (country_runtime == nullptr) return failure("country_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<NativeCountryRuntime::EffectCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        if (_native_country_bound_transaction_ids.find(transaction.id) !=
                _native_country_bound_transaction_ids.end())
            continue;
        if (transaction.command_count == 0) continue;
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            if (command->action != COUNTRY_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            if (command->domain < 0 || command->domain >= 32 ||
                command->opcode < NativeCountryRuntime::COMMAND_CREATE_COUNTRY ||
                command->opcode > NativeCountryRuntime::COMMAND_CLAIM_UNOWNED_TERRITORY ||
                (command->command_definition_id < 0 &&
                 command->opcode != NativeCountryRuntime::COMMAND_CLAIM_UNOWNED_TERRITORY) ||
                command->command_definition_id >= static_cast<int32_t>(_command_definitions.size())) {
                supported = false;
                break;
            }
            NativeCountryRuntime::EffectCommand native;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.sequence = static_cast<int64_t>(command->idempotency_key &
                0x7fffffffffffffffULL);
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            native.value = command->value_q16;
            native.payload = command->payload;
            native.idempotency_key = command->idempotency_key;
            // For structural country commands the catalog carries immutable
            // names in the existing cold string columns.  No Godot Variant is
            // built in this bridge.
            if (command->command_definition_id >= 0) {
                const CommandDefinition &definition = _command_definitions[
                    static_cast<size_t>(command->command_definition_id)];
                native.stable_id = definition.definition_key.c_str();
                native.display_name = definition.command_key.c_str();
            }
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) { commands.resize(begin); continue; }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true; out["submitted_transactions"] = 0; out["submitted_commands"] = 0;
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!country_runtime->submit_effect_commands_pod(commands.data(), commands.size(), request_ids, error) ||
        request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_country_enqueue_failed" : error;
        out["ok"] = false; out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(_native_country_request_ids.size());
        _native_country_request_ids.insert(_native_country_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_country_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_country_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_country_transactions += pending.size();
    _native_country_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_country(NativeCountryRuntime *country_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (country_runtime == nullptr) return failure("country_runtime_unavailable");
    int32_t acknowledged = 0, rejected = 0;
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_country_ack_bindings.size());
    retained_ids.reserve(_native_country_request_ids.size());
    for (const NativeAckBinding &binding : _native_country_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false, failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_country_request_ids.size()) { failed = true; reason = "effect_native_country_binding_invalid"; break; }
            bool complete = false, ok = false;
            if (!country_runtime->effect_command_result_pod(_native_country_request_ids[request_index],
                    complete, ok, reason)) { failed = true; break; }
            if (!complete) { pending = true; break; }
            if (!ok) { failed = true; break; }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count,
                binding.domain_bit};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_country_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction); transaction.status = REJECTED;
            ++_preflight_rejects; ++rejected; _last_error = reason.empty() ? "effect_native_country_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_country_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_country_ack_bindings.swap(retained);
    _native_country_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0; out["acknowledged"] = acknowledged;
    out["rejected"] = rejected; out["pending"] = static_cast<int32_t>(_native_country_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_country_acks += static_cast<uint64_t>(acknowledged);
    return out;
}

Dictionary EffectRuntime::dispatch_native_economy(NativeEconomyRuntime *economy_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (economy_runtime == nullptr) return failure("economy_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<NativeEconomyRuntime::EffectCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED ||
            _native_economy_bound_transaction_ids.find(transaction.id) !=
                _native_economy_bound_transaction_ids.end() ||
            transaction.command_count == 0)
            continue;
        if (transaction.program_id == -1) {
            // Colonization is intentionally ordered: Economy may consume the
            // transit payload only after the Country claim has committed and
            // ACKed. A rejected claim therefore never reaches Economy.
            uint32_t prerequisite_mask = 0;
            for (uint32_t ordinal = 0; ordinal < transaction.command_count;
                    ++ordinal) {
                const Command *command = command_at(transaction, ordinal);
                if (command != nullptr && command->action == COUNTRY_COMMAND)
                    prerequisite_mask |= adapter_ack_bit_for(*command);
            }
            if (prerequisite_mask != 0 &&
                (transaction.received_ack_mask & prerequisite_mask) !=
                    prerequisite_mask) continue;
        }
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            if (command->action != ECONOMY_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            if (command->domain < 0 || command->domain >= 32 ||
                command->opcode < NativeEconomyRuntime::COMMAND_TRANSFER_TO_COHORT ||
                command->opcode > NativeEconomyRuntime::COMMAND_SETTLE_FAMILY_EXPEDITION) {
                supported = false;
                break;
            }
            NativeEconomyRuntime::EffectCommand native;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.sequence = static_cast<int64_t>(command->idempotency_key &
                0x7fffffffffffffffULL);
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            const uint64_t packed_i32 = static_cast<uint64_t>(command->payload[0]);
            native.i32_0 = static_cast<int32_t>(packed_i32 & 0xffffffffULL);
            native.i32_1 = static_cast<int32_t>((packed_i32 >> 32U) & 0xffffffffULL);
            native.i64_0 = command->opcode ==
                NativeEconomyRuntime::COMMAND_SETTLE_FAMILY_EXPEDITION
                ? command->payload[2] : command->value_q16;
            native.i64_1 = command->payload[1];
            native.idempotency_key = command->idempotency_key;
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) {
            commands.resize(begin);
            continue;
        }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!economy_runtime->submit_effect_commands_pod(commands.data(), commands.size(),
            request_ids, error) || request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_economy_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(
            _native_economy_request_ids.size());
        _native_economy_request_ids.insert(_native_economy_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_economy_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_economy_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_economy_transactions += pending.size();
    _native_economy_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_economy(NativeEconomyRuntime *economy_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (economy_runtime == nullptr) return failure("economy_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_economy_ack_bindings.size());
    retained_ids.reserve(_native_economy_request_ids.size());
    int32_t acknowledged = 0;
    int32_t rejected = 0;
    for (const NativeAckBinding &binding : _native_economy_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false;
        bool failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_economy_request_ids.size()) {
                failed = true;
                reason = "effect_native_economy_binding_invalid";
                break;
            }
            bool complete = false;
            bool ok = false;
            if (!economy_runtime->effect_command_result_pod(
                    _native_economy_request_ids[request_index], complete, ok, reason)) {
                failed = true;
                break;
            }
            if (!complete) {
                pending = true;
                break;
            }
            if (!ok) {
                failed = true;
                break;
            }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count,
                binding.domain_bit};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_economy_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction);
            transaction.status = REJECTED;
            ++_preflight_rejects;
            ++rejected;
            _last_error = reason.empty() ? "effect_native_economy_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_economy_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_economy_ack_bindings.swap(retained);
    _native_economy_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_economy_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_economy_acks += static_cast<uint64_t>(acknowledged);
    _last_native_ack_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::dispatch_native_gameplay(DCWorldExt *world_ext) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (world_ext == nullptr) return failure("gameplay_effect_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<DCWorldExt::EffectGameplayCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if ((transaction.status != PLANNED && transaction.status != PREFLIGHTED &&
             transaction.status != COMMITTED) || transaction.command_count == 0 ||
            _native_gameplay_bound_transaction_ids.find(transaction.id) !=
                _native_gameplay_bound_transaction_ids.end())
            continue;
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            const bool native_gameplay = command != nullptr &&
                command->action == GAMEPLAY_COMMAND && command->domain == 3 &&
                command->opcode > 0;
            const bool native_publish = command != nullptr &&
                command->action == PUBLISH_EVENT && command->domain == 4 &&
                command->opcode > 0;
            const bool native_custom = command != nullptr &&
                command->action == CUSTOM_DOMAIN_COMMAND && command->domain == 6 &&
                (command->opcode == 1 || command->opcode == 2);
            if (!native_gameplay && !native_publish && !native_custom) {
                continue;
            }
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            DCWorldExt::EffectGameplayCommand native;
            native.action = command->action;
            native.domain = command->domain;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            native.value_i64 = command->value_q16;
            native.payload = command->payload;
            native.idempotency_key = command->idempotency_key;
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) {
            commands.resize(begin);
            continue;
        }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!world_ext->submit_effect_gameplay_commands_pod(commands.data(),
            commands.size(), request_ids, error) || request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_gameplay_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(
            _native_gameplay_request_ids.size());
        _native_gameplay_request_ids.insert(_native_gameplay_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_gameplay_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_gameplay_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_gameplay_transactions += pending.size();
    _native_gameplay_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_gameplay(DCWorldExt *world_ext) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (world_ext == nullptr) return failure("gameplay_effect_runtime_unavailable");
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_gameplay_ack_bindings.size());
    retained_ids.reserve(_native_gameplay_request_ids.size());
    int32_t acknowledged = 0;
    int32_t rejected = 0;
    for (const NativeAckBinding &binding : _native_gameplay_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false;
        bool failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            bool complete = false;
            bool ok = false;
            if (request_index >= _native_gameplay_request_ids.size() ||
                !world_ext->effect_gameplay_command_result_pod(
                    _native_gameplay_request_ids[request_index], complete, ok, reason)) {
                failed = true;
                if (reason.empty()) reason = "effect_native_gameplay_binding_invalid";
                break;
            }
            if (!complete) { pending = true; failed = false; break; }
            if (!ok) { failed = true; break; }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_gameplay_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction);
            transaction.status = REJECTED;
            ++_preflight_rejects;
            ++rejected;
            _last_error = reason.empty() ? "effect_native_gameplay_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_gameplay_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_gameplay_ack_bindings.swap(retained);
    _native_gameplay_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_gameplay_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_gameplay_acks += static_cast<uint64_t>(acknowledged);
    return out;
}

bool EffectRuntime::should_run(int64_t day_index) const {
    if (!_configured) return false;
    if (_run_day == day_index &&
        _candidate_cursor < static_cast<int32_t>(_run_candidates.size())) return true;
    auto transaction_due = [&](int64_t transaction_id) -> bool {
        const int32_t index = transaction_index_for_id(transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
            return false;
        const Transaction &transaction = _transactions[static_cast<size_t>(index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            return false;
        return transaction.effective_day <= day_index;
    };
    auto bindings_due = [&](const std::vector<NativeAckBinding> &bindings) -> bool {
        for (const NativeAckBinding &binding : bindings)
            if (transaction_due(binding.transaction_id)) return true;
        return false;
    };
    if (bindings_due(_native_ack_bindings) ||
        bindings_due(_native_country_ack_bindings) ||
        bindings_due(_native_economy_ack_bindings) ||
        bindings_due(_native_gameplay_ack_bindings))
        return true;
    for (const Transaction &transaction : _transactions) {
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        if (transaction.effective_day <= day_index) return true;
    }
    for (const int32_t index : _dirty_queue) {
        if (index < 0 || index >= static_cast<int32_t>(_instances.size())) continue;
        const Instance &instance = _instances[static_cast<size_t>(index)];
        if (instance.active != 0 && instance.next_due_day <= day_index) return true;
    }
    if (!_due_heap.empty() && _due_heap.top().day <= day_index) return true;
    return false;
}

Dictionary EffectRuntime::poll_transactions(int64_t after_transaction_id,
                                            int32_t limit) const {
    Dictionary out;
    out["ok"] = true;
    PackedInt64Array ids;
    PackedInt64Array source_instances;
    PackedInt32Array source_generations;
    PackedInt32Array program_ids;
    PackedInt64Array effective_days;
    PackedInt64Array plan_hashes;
    PackedInt32Array required_masks;
    PackedInt32Array received_masks;
    PackedInt32Array statuses;
    PackedInt32Array command_offsets;
    PackedInt32Array command_actions;
    PackedInt32Array command_domains;
    PackedInt32Array command_opcodes;
    PackedInt64Array command_targets;
    PackedInt32Array command_target_generations;
    PackedInt64Array command_values;
    PackedInt32Array command_durations;
    PackedInt32Array command_stacks;
    PackedInt64Array command_idempotency_keys;
    PackedStringArray command_keys;
    PackedStringArray command_definition_keys;
    PackedInt64Array payload_i0;
    PackedInt64Array payload_i1;
    PackedInt64Array payload_i2;
    PackedInt64Array payload_i3;
    command_offsets.append(0);
    int32_t emitted = 0;
    int32_t native_claimed = 0;
    limit = std::max(1, std::min(limit, 1024));
    for (const Transaction &transaction : _transactions) {
        if (transaction.id <= after_transaction_id || transaction.status == ACKED ||
            transaction.status == REJECTED || transaction.status == RESYNC_REQUIRED)
            continue;
        // Native-owned transactions must never be handed back to the legacy
        // GDScript transport.  This matters for ideology: a transaction is
        // already PREFLIGHTED by a POD adapter while the domain waits for its
        // own safe boundary, and a second transport must not try to resolve
        // its command keys or create a duplicate request.
        const bool native_owned_pending =
            _native_bound_transaction_ids.find(transaction.id) !=
                _native_bound_transaction_ids.end() ||
            _native_country_bound_transaction_ids.find(transaction.id) !=
                _native_country_bound_transaction_ids.end() ||
            _native_economy_bound_transaction_ids.find(transaction.id) !=
                _native_economy_bound_transaction_ids.end() ||
            _native_gameplay_bound_transaction_ids.find(transaction.id) !=
                _native_gameplay_bound_transaction_ids.end();
        if (native_owned_pending) {
            ++native_claimed;
            continue;
        }
        if (emitted >= limit) break;
        ids.append(transaction.id);
        source_instances.append(transaction.source_instance_id);
        source_generations.append(static_cast<int32_t>(transaction.source_generation));
        program_ids.append(transaction.program_id);
        effective_days.append(transaction.effective_day);
        plan_hashes.append(static_cast<int64_t>(transaction.plan_hash));
        required_masks.append(static_cast<int32_t>(transaction.required_ack_mask));
        received_masks.append(static_cast<int32_t>(transaction.received_ack_mask));
        statuses.append(transaction.status);
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) continue;
            command_actions.append(command->action);
            command_domains.append(command->domain);
            command_opcodes.append(command->opcode);
            command_targets.append(static_cast<int64_t>(command->target_handle));
            command_target_generations.append(static_cast<int32_t>(command->target_generation));
            command_values.append(command->value_q16);
            command_durations.append(command->duration_days);
            command_stacks.append(command->stacks);
            command_idempotency_keys.append(static_cast<int64_t>(command->idempotency_key));
            const std::string command_key = command_key_for(*command);
            const std::string definition_key = command_definition_key_for(transaction, *command);
            command_keys.append(String(command_key.c_str()));
            command_definition_keys.append(String(definition_key.c_str()));
            payload_i0.append(command->payload[0]); payload_i1.append(command->payload[1]);
            payload_i2.append(command->payload[2]); payload_i3.append(command->payload[3]);
        }
        command_offsets.append(command_actions.size());
        ++emitted;
    }
    out["transaction_ids"] = ids;
    out["source_instance_ids"] = source_instances;
    out["source_generations"] = source_generations;
    out["program_ids"] = program_ids;
    out["effective_days"] = effective_days;
    out["plan_hashes"] = plan_hashes;
    out["required_ack_masks"] = required_masks;
    out["received_ack_masks"] = received_masks;
    out["statuses"] = statuses;
    out["command_offsets"] = command_offsets;
    out["command_actions"] = command_actions;
    out["command_domains"] = command_domains;
    out["command_opcodes"] = command_opcodes;
    out["command_targets"] = command_targets;
    out["command_target_generations"] = command_target_generations;
    out["command_values_q16"] = command_values;
    out["command_duration_days"] = command_durations;
    out["command_stacks"] = command_stacks;
    out["command_idempotency_keys"] = command_idempotency_keys;
    out["command_keys"] = command_keys;
    out["command_definition_keys"] = command_definition_keys;
    out["command_payload_i0"] = payload_i0;
    out["command_payload_i1"] = payload_i1;
    out["command_payload_i2"] = payload_i2;
    out["command_payload_i3"] = payload_i3;
    out["count"] = emitted;
    out["native_claimed_transactions"] = native_claimed;
    return out;
}

Dictionary EffectRuntime::preflight_transactions(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "transaction_ids");
    const PackedInt32Array masks = get_i32(batch, "ack_masks");
    if (ids.is_empty() || masks.size() != ids.size())
        return failure("effect_preflight_columns_invalid");
    std::vector<int32_t> indices;
    indices.reserve(ids.size());
    std::unordered_set<int64_t> seen;
    for (int32_t i = 0; i < ids.size(); ++i) {
        if (!seen.emplace(ids[i]).second) return failure("effect_preflight_duplicate_transaction");
        const int32_t index = transaction_index_for_id(ids[i]);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
            return failure("effect_preflight_unknown_transaction");
        const Transaction &transaction = _transactions[static_cast<size_t>(index)];
        const uint32_t mask = static_cast<uint32_t>(masks[i]);
        if (mask != transaction.required_ack_mask ||
            transaction.status == REJECTED || transaction.status == RESYNC_REQUIRED)
            return failure("effect_preflight_mask_or_status_invalid");
        indices.push_back(index);
    }
    int32_t preflighted = 0;
    for (int32_t index : indices) {
        Transaction &transaction = _transactions[index];
        if (transaction.status == PLANNED) {
            transaction.status = PREFLIGHTED;
            ++preflighted;
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["preflighted"] = preflighted;
    return out;
}

Dictionary EffectRuntime::commit_transactions(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "transaction_ids");
    const PackedInt32Array masks = get_i32(batch, "ack_masks");
    if (ids.is_empty() || masks.size() != ids.size())
        return failure("effect_commit_columns_invalid");
    std::vector<int32_t> indices;
    indices.reserve(ids.size());
    std::unordered_set<int64_t> seen;
    for (int32_t i = 0; i < ids.size(); ++i) {
        if (!seen.emplace(ids[i]).second) return failure("effect_commit_duplicate_transaction");
        const int32_t index = transaction_index_for_id(ids[i]);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
            return failure("effect_commit_unknown_transaction");
        const Transaction &transaction = _transactions[static_cast<size_t>(index)];
        const uint32_t mask = static_cast<uint32_t>(masks[i]);
        if (mask != transaction.required_ack_mask ||
            (transaction.status != PREFLIGHTED && transaction.status != COMMITTED &&
             transaction.status != ACKED))
            return failure("effect_commit_mask_or_status_invalid");
        indices.push_back(index);
    }
    int32_t committed = 0;
    for (int32_t index : indices) {
        Transaction &transaction = _transactions[index];
        if (transaction.status == PREFLIGHTED) {
            transaction.status = COMMITTED;
            ++committed;
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["committed"] = committed;
    return out;
}

Dictionary EffectRuntime::ack_transactions(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "transaction_ids");
    const PackedInt32Array masks = get_i32(batch, "ack_masks");
    if (ids.is_empty() || masks.size() != ids.size())
        return failure("effect_ack_columns_invalid");
    int32_t acknowledged = 0;
    int32_t rejected = 0;
    for (int32_t i = 0; i < ids.size(); ++i) {
        const int32_t index = transaction_index_for_id(ids[i]);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) {
            if (ids[i] <= _acked_transaction_id) continue;
            ++rejected;
            continue;
        }
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        const uint32_t mask = static_cast<uint32_t>(masks[i]);
        if ((mask & ~transaction.required_ack_mask) != 0 ||
            (transaction.status != COMMITTED && transaction.status != ACKED)) {
            ++rejected;
            continue;
        }
        if (transaction.status == ACKED) continue;
        transaction.received_ack_mask |= mask;
        const bool fully_acknowledged =
            (transaction.received_ack_mask & transaction.required_ack_mask) ==
            transaction.required_ack_mask;
        if (fully_acknowledged) {
            untrack_pending_transaction(transaction);
            transaction.status = ACKED;
            unindex_transaction_commands(transaction);
            _acked_transaction_id = std::max(_acked_transaction_id, transaction.id);
            ++_transactions_acked;
            ++acknowledged;
        } else {
            transaction.status = COMMITTED;
        }
    }
    if (acknowledged != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["acked_transaction_id"] = _acked_transaction_id;
    if (rejected != 0) out["reason"] = "effect_ack_unknown_transaction";
    return out;
}

Dictionary EffectRuntime::explain(int64_t instance_id) const {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0) return failure("effect_instance_not_found");
    const Instance &instance = _instances[index];
    const Definition &definition = _definitions[instance.program_id];
    Dictionary out;
    out["ok"] = true;
    out["instance_id"] = instance.id;
    out["generation"] = static_cast<int64_t>(instance.generation);
    out["program_key"] = String(definition.key.c_str());
    out["program_version"] = definition.version;
    out["level"] = instance.level;
    out["next_due_day"] = instance.next_due_day;
    out["input_revision"] = instance.input_revision;
    out["last_evaluated_input_revision"] = instance.last_evaluated_input_revision;
    out["fire_sequence"] = static_cast<int64_t>(instance.fire_sequence);
    out["condition_passes"] = evaluate_condition(definition, instance);
    return out;
}

Dictionary EffectRuntime::report() const {
    Dictionary out;
    std::array<int32_t, RESYNC_REQUIRED + 1> status_counts{};
    for (const Transaction &transaction : _transactions) {
        if (transaction.status >= PLANNED && transaction.status <= RESYNC_REQUIRED)
            ++status_counts[transaction.status];
    }
    out["configured"] = _configured;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["current_day"] = _current_day;
    out["last_completed_day"] = _last_completed_day;
    out["definitions"] = static_cast<int32_t>(_definitions.size());
    out["metrics"] = _metric_count;
    out["instances"] = static_cast<int32_t>(_instance_ids.size());
    out["instance_storage_slots"] = static_cast<int32_t>(_instances.size());
    out["free_instance_slots"] = static_cast<int32_t>(_free_instance_indices.size());
    out["transactions"] = static_cast<int32_t>(_transactions.size());
    out["external_bindings"] = static_cast<int32_t>(_external_binding_ids.size());
    out["pending_command_idempotency_count"] = static_cast<int64_t>(
        _pending_command_idempotency.size());
    out["pending_transactions"] = static_cast<int32_t>(std::count_if(
        _transactions.begin(), _transactions.end(), [](const Transaction &transaction) {
            return transaction.status == PLANNED || transaction.status == PREFLIGHTED ||
                transaction.status == COMMITTED;
        }));
    out["planned_transactions"] = status_counts[PLANNED];
    out["preflighted_transactions"] = status_counts[PREFLIGHTED];
    out["committed_transactions"] = status_counts[COMMITTED];
    out["acked_transactions"] = status_counts[ACKED];
    out["rejected_transactions"] = status_counts[REJECTED];
    out["resync_required_transactions"] = status_counts[RESYNC_REQUIRED];
    out["max_work_per_slice"] = _max_work_per_slice;
    out["instances_submitted"] = static_cast<int64_t>(_instances_submitted);
    out["programs_evaluated"] = static_cast<int64_t>(_programs_evaluated);
    out["commands_emitted"] = static_cast<int64_t>(_commands_emitted);
    out["transactions_acked"] = static_cast<int64_t>(_transactions_acked);
    out["preflight_rejects"] = static_cast<int64_t>(_preflight_rejects);
    out["behavior_failures"] = static_cast<int64_t>(_behavior_failures);
    out["overflow_count"] = static_cast<int64_t>(_overflow_count);
    out["last_evaluate_ms"] = _last_evaluate_ms;
    out["last_native_modifier_dispatch_ms"] = _last_native_dispatch_ms;
    out["last_native_modifier_ack_ms"] = _last_native_ack_ms;
    out["last_parallel_planning_ms"] = _last_parallel_planning_ms;
    out["last_parallel_merge_ms"] = _last_parallel_merge_ms;
    out["last_parallel_worker_count"] = _last_parallel_worker_count;
    out["parallel_dispatches"] = static_cast<int64_t>(_parallel_dispatches);
    out["serial_fallback_dispatches"] = static_cast<int64_t>(_serial_fallback_dispatches);
    out["last_parallel_path"] = String(_last_parallel_path.c_str());
    out["last_parallel_fallback_reason"] = String(_last_parallel_fallback_reason.c_str());
    out["native_modifier_transactions"] = static_cast<int64_t>(_native_modifier_transactions);
    out["native_modifier_commands"] = static_cast<int64_t>(_native_modifier_commands);
    out["native_modifier_acks"] = static_cast<int64_t>(_native_modifier_acks);
    out["native_country_transactions"] = static_cast<int64_t>(_native_country_transactions);
    out["native_country_commands"] = static_cast<int64_t>(_native_country_commands);
    out["native_country_acks"] = static_cast<int64_t>(_native_country_acks);
    out["native_economy_transactions"] = static_cast<int64_t>(_native_economy_transactions);
    out["native_economy_commands"] = static_cast<int64_t>(_native_economy_commands);
    out["native_economy_acks"] = static_cast<int64_t>(_native_economy_acks);
    out["native_gameplay_transactions"] = static_cast<int64_t>(_native_gameplay_transactions);
    out["native_gameplay_commands"] = static_cast<int64_t>(_native_gameplay_commands);
    out["native_gameplay_acks"] = static_cast<int64_t>(_native_gameplay_acks);
    out["due_queue_count"] = static_cast<int64_t>(_due_heap.size());
    out["dirty_queue_count"] = static_cast<int64_t>(_dirty_queue.size());
    out["candidate_count"] = static_cast<int64_t>(_run_candidates.size());
    out["candidate_cursor"] = _candidate_cursor;
    out["native_modifier_ack_pending"] = static_cast<int64_t>(
        _native_ack_bindings.size());
    out["native_country_ack_pending"] = static_cast<int64_t>(
        _native_country_ack_bindings.size());
    out["native_economy_ack_pending"] = static_cast<int64_t>(
        _native_economy_ack_bindings.size());
    out["native_gameplay_ack_pending"] = static_cast<int64_t>(
        _native_gameplay_ack_bindings.size());
    out["dormant_instances_scanned"] = 0;
    out["metric_slab_bytes"] = static_cast<int64_t>(
        _metric_values.capacity() * sizeof(int64_t) +
        _metric_present.capacity() * sizeof(uint8_t));
    out["instance_storage_bytes"] = static_cast<int64_t>(
        _instances.capacity() * sizeof(Instance));
    out["era_reward_last_plan_ms"] = _last_era_reward_plan_ms;
    out["era_reward_offers_planned"] = static_cast<int64_t>(
        _era_reward_offers_planned);
    out["era_reward_last_expanded_commands"] =
        _last_era_reward_expanded_commands;
    int64_t era_reward_storage_bytes = static_cast<int64_t>(
        _era_reward_pools.capacity() * sizeof(EraRewardPool) +
        _era_reward_options.capacity() * sizeof(EraRewardOption) +
        _era_reward_rules.capacity() * sizeof(EraRewardRule) +
        sizeof(EraRewardOffer));
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        era_reward_storage_bytes += static_cast<int64_t>(
            alternative.target_summary.capacity());
        for (const std::string &reason : alternative.reasons)
            era_reward_storage_bytes += static_cast<int64_t>(reason.capacity());
    }
    out["era_reward_storage_bytes"] = era_reward_storage_bytes;
    out["last_error"] = String(_last_error.c_str());
    out["run_cursor"] = _run_cursor;
    return out;
}

PackedByteArray EffectRuntime::capture() const {
    if (!_configured) return PackedByteArray();
    std::vector<uint8_t> bytes;
    append_le<uint32_t>(bytes, SAVE_MAGIC);
    append_le<int32_t>(bytes, SAVE_SCHEMA_VERSION);
    append_le<int32_t>(bytes, PROTOCOL_VERSION);
    append_le<uint64_t>(bytes, _catalog_hash);
    append_le<int64_t>(bytes, _current_day);
    append_le<int64_t>(bytes, _last_completed_day);
    append_le<int64_t>(bytes, _run_day);
    append_le<int32_t>(bytes, _run_cursor);
    append_le<int64_t>(bytes, _next_transaction_id);
    append_le<int64_t>(bytes, _acked_transaction_id);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_instances.size()));
    for (const Instance &instance : _instances) {
        append_le<int64_t>(bytes, instance.id);
        append_le<uint32_t>(bytes, instance.generation);
        append_le<int32_t>(bytes, instance.program_id);
        append_le<int32_t>(bytes, instance.source_type);
        append_le<int64_t>(bytes, instance.source_id);
        append_le<uint64_t>(bytes, instance.source_handle);
        append_le<uint64_t>(bytes, instance.target_handle);
        append_le<uint32_t>(bytes, instance.target_generation);
        append_le<int32_t>(bytes, instance.level);
        append_le<int64_t>(bytes, instance.next_due_day);
        append_le<int64_t>(bytes, instance.input_revision);
        append_le<int64_t>(bytes, instance.last_evaluated_input_revision);
        append_le<uint64_t>(bytes, instance.fire_sequence);
        append_le<uint8_t>(bytes, instance.active);
        append_le<uint32_t>(bytes, static_cast<uint32_t>(_metric_count));
        for (int32_t metric_id = 0; metric_id < _metric_count; ++metric_id) {
            const int64_t *value = metric_ptr(instance, metric_id);
            append_le<int64_t>(bytes, value != nullptr ? *value : 0);
        }
        for (int32_t metric_id = 0; metric_id < _metric_count; ++metric_id) {
            const size_t offset = static_cast<size_t>(instance.metric_base) +
                static_cast<size_t>(metric_id);
            append_le<uint8_t>(bytes,
                offset < _metric_present.size() ? _metric_present[offset] : 0);
        }
    }
    append_le<int32_t>(bytes, _candidate_cursor);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_run_candidates.size()));
    for (const int32_t index : _run_candidates) append_le<int32_t>(bytes, index);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_transactions.size()));
    for (const Transaction &transaction : _transactions) {
        append_le<int64_t>(bytes, transaction.id);
        append_le<int64_t>(bytes, transaction.source_instance_id);
        append_le<uint32_t>(bytes, transaction.source_generation);
        append_le<int32_t>(bytes, transaction.program_id);
        append_le<int64_t>(bytes, transaction.effective_day);
        append_le<uint64_t>(bytes, transaction.plan_hash);
        append_le<uint32_t>(bytes, transaction.required_ack_mask);
        append_le<uint32_t>(bytes, transaction.received_ack_mask);
        // Native request ids are intentionally not persisted. A save taken
        // before the Modifier safe boundary must replay the transaction from
        // PLANNED so the restored runtime can submit it again idempotently.
        const int32_t persisted_status =
            transaction.status == PREFLIGHTED &&
            (_native_bound_transaction_ids.find(transaction.id) !=
                _native_bound_transaction_ids.end() ||
             _native_country_bound_transaction_ids.find(transaction.id) !=
                _native_country_bound_transaction_ids.end() ||
             _native_economy_bound_transaction_ids.find(transaction.id) !=
                _native_economy_bound_transaction_ids.end() ||
             _native_gameplay_bound_transaction_ids.find(transaction.id) !=
                _native_gameplay_bound_transaction_ids.end())
            ? PLANNED : transaction.status;
        append_le<int32_t>(bytes, persisted_status);
        append_le<uint32_t>(bytes, transaction.command_count);
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) continue;
            append_le<int32_t>(bytes, command->action);
            append_le<int32_t>(bytes, command->domain);
            append_le<int32_t>(bytes, command->opcode);
            append_le<uint64_t>(bytes, command->target_handle);
            append_le<uint32_t>(bytes, command->target_generation);
            append_le<int64_t>(bytes, command->value_q16);
            append_le<int32_t>(bytes, command->duration_days);
            append_le<int32_t>(bytes, command->stacks);
            append_le<uint64_t>(bytes, command->idempotency_key);
            append_le<int32_t>(bytes, command->command_key_id);
            append_le<int32_t>(bytes, command->command_definition_id);
            append_le<int64_t>(bytes, command->external_effect_id);
            append_le<int64_t>(bytes, command->external_source_id);
            for (int64_t value : command->payload) append_le<int64_t>(bytes, value);
        }
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_external_bindings.size()));
    for (const ExternalSourceBinding &binding : _external_bindings) {
        append_le<int64_t>(bytes, binding.binding_id);
        append_le<uint32_t>(bytes, binding.generation);
        append_le<int32_t>(bytes, binding.source_type);
        append_le<int64_t>(bytes, binding.source_id);
        append_le<uint64_t>(bytes, binding.target_handle);
        append_le<uint32_t>(bytes, binding.target_generation);
        append_le<int32_t>(bytes, binding.level);
        append_le<uint8_t>(bytes, binding.location);
        append_le<uint8_t>(bytes, binding.active);
        append_le<uint64_t>(bytes, binding.template_signature);
        append_le<uint64_t>(bytes, binding.program_hash);
    }
    append_le<uint64_t>(bytes, _era_reward_player_country);
    append_le<int64_t>(bytes, _era_reward_next_plan_id);
    append_le<int64_t>(bytes, _era_reward_next_generation);
    append_le<int64_t>(bytes, _era_reward_offer.plan_id);
    append_le<int64_t>(bytes, _era_reward_offer.generation);
    append_le<int32_t>(bytes, _era_reward_offer.pool_index);
    append_le<int32_t>(bytes, _era_reward_offer.milestone_technology);
    append_le<uint64_t>(bytes, _era_reward_offer.country_handle);
    append_le<uint32_t>(bytes, _era_reward_offer.country_generation);
    append_le<int32_t>(bytes, _era_reward_offer.status);
    append_le<int32_t>(bytes, _era_reward_offer.selected_choice);
    append_le<int64_t>(bytes, _era_reward_offer.transaction_id);
    append_le<uint64_t>(bytes, _era_reward_offer.plan_hash);
    append_string(bytes, _era_reward_offer.error);
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        append_le<int32_t>(bytes, alternative.option_index);
        append_le<int64_t>(bytes, alternative.weight);
        append_le<uint64_t>(bytes, alternative.target_handle);
        append_le<uint32_t>(bytes, alternative.target_generation);
        append_le<int32_t>(bytes, alternative.reason_count);
        append_string(bytes, alternative.reasons[0]);
        append_string(bytes, alternative.reasons[1]);
        append_string(bytes, alternative.target_summary);
    }
    append_le<uint32_t>(bytes, SAVE_END);
    PackedByteArray out;
    out.resize(bytes.size());
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

Dictionary EffectRuntime::restore(const PackedByteArray &packed) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (packed.size() < sizeof(uint32_t) * 2) return failure("pkef_truncated");
    const uint8_t *bytes = packed.ptr();
    const size_t size = packed.size();
    size_t cursor = 0;
    uint32_t magic = 0, end_magic = 0;
    int32_t schema = 0, protocol = 0;
    uint64_t hash = 0;
    if (!read_le(bytes, size, cursor, magic) || magic != SAVE_MAGIC ||
        !read_le(bytes, size, cursor, schema))
        return failure("pkef_header_incompatible");
    if (schema != SAVE_SCHEMA_VERSION)
        return failure("catalog_hash_mismatch");
    if (!read_le(bytes, size, cursor, protocol) || protocol != PROTOCOL_VERSION ||
        !read_le(bytes, size, cursor, hash) || hash != _catalog_hash)
        return failure("catalog_hash_mismatch");
    int64_t current_day = -1, last_day = -1, run_day = -1, next_tx = 1, acked_tx = 0;
    int32_t run_cursor = 0;
    uint32_t instance_count = 0, candidate_count = 0, transaction_count = 0;
    if (!read_le(bytes, size, cursor, current_day) || !read_le(bytes, size, cursor, last_day) ||
        !read_le(bytes, size, cursor, run_day) || !read_le(bytes, size, cursor, run_cursor) ||
        !read_le(bytes, size, cursor, next_tx) || !read_le(bytes, size, cursor, acked_tx) ||
        !read_le(bytes, size, cursor, instance_count) || instance_count > static_cast<uint32_t>(_max_instances))
        return failure("pkef_instances_invalid");
    if (current_day < -1 || last_day < -1 || run_day < -1 || run_cursor < 0 ||
        next_tx <= 0 || acked_tx < 0 || acked_tx >= next_tx)
        return failure("pkef_runtime_cursor_invalid");
    std::vector<Instance> restored_instances;
    std::vector<int64_t> restored_metric_values;
    std::vector<uint8_t> restored_metric_present;
    restored_metric_values.reserve(static_cast<size_t>(instance_count) *
                                   static_cast<size_t>(_metric_count));
    restored_metric_present.reserve(static_cast<size_t>(instance_count) *
                                    static_cast<size_t>(_metric_count));
    std::unordered_map<int64_t, int32_t> restored_instance_ids;
    restored_instances.reserve(instance_count);
    for (uint32_t i = 0; i < instance_count; ++i) {
        Instance instance;
        uint32_t metric_count = 0;
        if (!read_le(bytes, size, cursor, instance.id) || !read_le(bytes, size, cursor, instance.generation) ||
            !read_le(bytes, size, cursor, instance.program_id) || !read_le(bytes, size, cursor, instance.source_type) ||
            !read_le(bytes, size, cursor, instance.source_id) || !read_le(bytes, size, cursor, instance.source_handle) ||
            !read_le(bytes, size, cursor, instance.target_handle) || !read_le(bytes, size, cursor, instance.target_generation) ||
            !read_le(bytes, size, cursor, instance.level) || !read_le(bytes, size, cursor, instance.next_due_day) ||
            !read_le(bytes, size, cursor, instance.input_revision) ||
            !read_le(bytes, size, cursor, instance.last_evaluated_input_revision) ||
            !read_le(bytes, size, cursor, instance.fire_sequence) ||
            !read_le(bytes, size, cursor, instance.active) || !read_le(bytes, size, cursor, metric_count) ||
            metric_count != static_cast<uint32_t>(_metric_count))
            return failure("pkef_instance_truncated_or_metric_mismatch");
        if (instance.active > 1 || instance.input_revision < 0 ||
            instance.last_evaluated_input_revision < 0 ||
            instance.last_evaluated_input_revision > instance.input_revision)
            return failure("pkef_instance_identity_invalid");
        if (instance.id == 0) {
            // Retired slots are persisted so their metric slab rows and free
            // list can be reconstructed without renumbering live instances.
            if (instance.generation != 0 || instance.program_id != -1 ||
                instance.active != 0)
                return failure("pkef_instance_tombstone_invalid");
        } else if (instance.id < 0 || instance.generation == 0 ||
                   instance.program_id < 0 ||
                   instance.program_id >= static_cast<int32_t>(_definitions.size()) ||
                   !restored_instance_ids.emplace(instance.id,
                       static_cast<int32_t>(restored_instances.size())).second) {
            return failure("pkef_instance_identity_invalid");
        }
        for (uint32_t j = 0; j < metric_count; ++j) {
            int64_t value = 0;
            if (!read_le(bytes, size, cursor, value))
                return failure("pkef_instance_metrics_truncated");
            restored_metric_values.push_back(value);
        }
        for (uint32_t j = 0; j < metric_count; ++j) {
            uint8_t present = 0;
            if (!read_le(bytes, size, cursor, present))
                return failure("pkef_instance_presence_truncated");
            if (present > 1) return failure("pkef_instance_presence_invalid");
            restored_metric_present.push_back(present);
        }
        restored_instances.push_back(std::move(instance));
    }
    int32_t candidate_cursor = 0;
    if (!read_le(bytes, size, cursor, candidate_cursor) ||
        !read_le(bytes, size, cursor, candidate_count) ||
        candidate_count > instance_count || candidate_cursor < 0 ||
        candidate_cursor > static_cast<int32_t>(candidate_count))
        return failure("pkef_candidate_cursor_invalid");
    std::vector<int32_t> restored_candidates;
    restored_candidates.reserve(candidate_count);
    std::vector<uint8_t> candidate_seen(instance_count, 0);
    for (uint32_t i = 0; i < candidate_count; ++i) {
        int32_t index = -1;
        if (!read_le(bytes, size, cursor, index) || index < 0 ||
            index >= static_cast<int32_t>(instance_count) ||
            restored_instances[static_cast<size_t>(index)].id == 0 ||
            candidate_seen[static_cast<size_t>(index)] != 0)
            return failure("pkef_candidate_invalid");
        candidate_seen[static_cast<size_t>(index)] = 1;
        restored_candidates.push_back(index);
    }
    if (!read_le(bytes, size, cursor, transaction_count) ||
        transaction_count > static_cast<uint32_t>(_max_transactions))
        return failure("pkef_transactions_invalid");
    std::vector<Transaction> restored_transactions;
    std::vector<Command> restored_command_arena;
    std::unordered_set<int64_t> restored_transaction_ids;
    restored_transactions.reserve(transaction_count);
    restored_command_arena.reserve(std::min<size_t>(
        static_cast<size_t>(_max_native_modifier_commands),
        static_cast<size_t>(transaction_count) * 4));
    int64_t max_transaction_id = 0;
    for (uint32_t i = 0; i < transaction_count; ++i) {
        Transaction transaction;
        uint32_t command_count = 0;
        if (!read_le(bytes, size, cursor, transaction.id) ||
            !read_le(bytes, size, cursor, transaction.source_instance_id) ||
            !read_le(bytes, size, cursor, transaction.source_generation) ||
            !read_le(bytes, size, cursor, transaction.program_id) ||
            !read_le(bytes, size, cursor, transaction.effective_day) ||
            !read_le(bytes, size, cursor, transaction.plan_hash) ||
            !read_le(bytes, size, cursor, transaction.required_ack_mask) ||
            !read_le(bytes, size, cursor, transaction.received_ack_mask) ||
            !read_le(bytes, size, cursor, transaction.status) ||
            !read_le(bytes, size, cursor, command_count) || command_count > 4096)
            return failure("pkef_transaction_truncated");
        const bool builtin_family_colonization = transaction.program_id == -1;
        const bool builtin_canal_commit = transaction.program_id == -2;
        const bool builtin_transaction = builtin_family_colonization ||
            builtin_canal_commit;
        if (transaction.id <= 0 || transaction.source_instance_id <= 0 ||
            transaction.source_generation == 0 ||
            (!builtin_transaction &&
             (transaction.program_id < 0 ||
              transaction.program_id >= static_cast<int32_t>(_definitions.size()) ||
              restored_instance_ids.find(transaction.source_instance_id) == restored_instance_ids.end())) ||
            transaction.status < PLANNED || transaction.status > RESYNC_REQUIRED ||
            !restored_transaction_ids.emplace(transaction.id).second ||
            (transaction.received_ack_mask & ~transaction.required_ack_mask) != 0)
            return failure("pkef_transaction_identity_invalid");
        if (!builtin_transaction) {
            const Instance &source_instance = restored_instances[
                restored_instance_ids[transaction.source_instance_id]];
            if ((transaction.status == PLANNED || transaction.status == PREFLIGHTED ||
                 transaction.status == COMMITTED) &&
                source_instance.generation != transaction.source_generation)
                return failure("pkef_transaction_source_generation_invalid");
        }
        if ((transaction.status == PLANNED || transaction.status == PREFLIGHTED) &&
            transaction.received_ack_mask != 0)
            return failure("pkef_transaction_state_invalid");
        if (transaction.status == ACKED &&
            (transaction.received_ack_mask & transaction.required_ack_mask) !=
                transaction.required_ack_mask)
            return failure("pkef_transaction_ack_incomplete");
        transaction.command_begin = static_cast<uint32_t>(restored_command_arena.size());
        transaction.command_count = 0;
        uint32_t derived_ack_mask = 0;
        std::unordered_set<uint64_t> command_idempotency_keys;
        for (uint32_t j = 0; j < command_count; ++j) {
            Command command;
            if (!read_le(bytes, size, cursor, command.action) || !read_le(bytes, size, cursor, command.domain) ||
                !read_le(bytes, size, cursor, command.opcode) || !read_le(bytes, size, cursor, command.target_handle) ||
                !read_le(bytes, size, cursor, command.target_generation) ||
                !read_le(bytes, size, cursor, command.value_q16) || !read_le(bytes, size, cursor, command.duration_days) ||
                !read_le(bytes, size, cursor, command.stacks) ||
                !read_le(bytes, size, cursor, command.idempotency_key) ||
                !read_le(bytes, size, cursor, command.command_key_id) ||
                !read_le(bytes, size, cursor, command.command_definition_id))
                return failure("pkef_command_truncated");
            if (schema >= 10 &&
                (!read_le(bytes, size, cursor, command.external_effect_id) ||
                 !read_le(bytes, size, cursor, command.external_source_id)))
                return failure("pkef_command_external_identity_truncated");
            if (command.action < MODIFIER_COMMAND || command.action > CUSTOM_DOMAIN_COMMAND ||
                command.domain < -1 || command.domain >= 32 || command.stacks <= 0 ||
                command.duration_days < -1 || command.command_key_id < -1 ||
                command.command_definition_id < -1 ||
                ((command.external_effect_id == 0) !=
                 (command.external_source_id == 0)) ||
                command.external_effect_id < 0 ||
                (command.command_definition_id >= static_cast<int32_t>(_command_definitions.size())) ||
                (command.command_definition_id >= 0 &&
                 command.command_key_id != command.command_definition_id) ||
                (command.command_definition_id < 0 &&
                 command.command_key_id >= static_cast<int32_t>(_behavior_command_keys.size())) ||
                !command_idempotency_keys.emplace(command.idempotency_key).second)
                return failure("pkef_command_invalid");
            if (command.command_definition_id >= 0) {
                const CommandDefinition &definition = _command_definitions[
                    static_cast<size_t>(command.command_definition_id)];
                std::string command_error;
                const bool remove_alias = command.action == MODIFIER_COMMAND &&
                    command.opcode == ModifierRuntime::COMMAND_REMOVE &&
                    definition.opcode == ModifierRuntime::COMMAND_APPLY;
                if ((!remove_alias && (definition.action != command.action ||
                                       definition.domain != command.domain ||
                                       definition.opcode != command.opcode)) ||
                    definition.duration_days != command.duration_days ||
                    definition.stacks != command.stacks ||
                    !native_command_shape_valid(command.action, command.domain,
                        command.opcode, definition.target_resolver,
                        command.duration_days, command.stacks, command_error))
                    return failure(command_error.empty()
                        ? "pkef_command_definition_mismatch" : command_error.c_str());
            }
            derived_ack_mask |= adapter_ack_bit_for(command);
            for (int64_t &value : command.payload)
                if (!read_le(bytes, size, cursor, value)) return failure("pkef_command_payload_truncated");
            restored_command_arena.push_back(std::move(command));
            ++transaction.command_count;
        }
        if (builtin_family_colonization) {
            const Command *first = transaction.command_count > 0
                ? &restored_command_arena[transaction.command_begin] : nullptr;
            const bool settle_only = transaction.command_count == 1 &&
                first != nullptr && first->action == ECONOMY_COMMAND &&
                first->domain == 8 &&
                first->opcode == NativeEconomyRuntime::COMMAND_SETTLE_FAMILY_EXPEDITION &&
                first->command_key_id == -1 && first->command_definition_id == -1;
            const bool claim_and_settle = transaction.command_count == 2;
            if (settle_only) {
                // Own-country relocation: Economy SETTLE only.
            } else if (claim_and_settle) {
                const Command &claim = restored_command_arena[transaction.command_begin];
                const Command &settle = restored_command_arena[transaction.command_begin + 1];
                if (claim.action != COUNTRY_COMMAND || claim.domain != 7 ||
                    claim.opcode != NativeCountryRuntime::COMMAND_CLAIM_UNOWNED_TERRITORY ||
                    claim.command_key_id != -1 || claim.command_definition_id != -1 ||
                    settle.action != ECONOMY_COMMAND || settle.domain != 8 ||
                    settle.opcode != NativeEconomyRuntime::COMMAND_SETTLE_FAMILY_EXPEDITION ||
                    settle.command_key_id != -1 || settle.command_definition_id != -1 ||
                    claim.target_handle != settle.payload[1] ||
                    claim.payload[0] != settle.payload[0])
                    return failure("pkef_colonization_transaction_shape_invalid");
            } else {
                return failure("pkef_colonization_transaction_shape_invalid");
            }
        } else if (builtin_canal_commit) {
            if (transaction.command_count != 1)
                return failure("pkef_canal_transaction_shape_invalid");
            const Command &commit = restored_command_arena[transaction.command_begin];
            if (commit.action != CUSTOM_DOMAIN_COMMAND || commit.domain != 6 ||
                commit.opcode != 2 || commit.target_handle == 0 ||
                commit.target_generation == 0 || commit.command_key_id != -1 ||
                commit.command_definition_id != -1)
                return failure("pkef_canal_transaction_shape_invalid");
        }
        if (derived_ack_mask != transaction.required_ack_mask)
            return failure("pkef_transaction_ack_mask_invalid");
        uint64_t expected_plan_hash = 1469598103934665603ULL;
        if (builtin_transaction) {
            expected_plan_hash = fnv_value(expected_plan_hash, transaction.id);
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.effective_day);
        } else {
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.source_instance_id);
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.source_generation);
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.program_id);
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.effective_day);
        }
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command &command = restored_command_arena[
                static_cast<size_t>(transaction.command_begin) + ordinal];
            expected_plan_hash = fnv_value(expected_plan_hash, command.action);
            expected_plan_hash = fnv_value(expected_plan_hash, command.domain);
            expected_plan_hash = fnv_value(expected_plan_hash, command.opcode);
            expected_plan_hash = fnv_value(expected_plan_hash, command.target_handle);
            expected_plan_hash = fnv_value(expected_plan_hash, command.target_generation);
            if (!builtin_transaction) {
                expected_plan_hash = fnv_value(expected_plan_hash, command.value_q16);
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.duration_days);
                expected_plan_hash = fnv_value(expected_plan_hash, command.stacks);
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.command_key_id);
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.command_definition_id);
            }
            if (!builtin_canal_commit) {
                for (int64_t payload_value : command.payload)
                    expected_plan_hash = fnv_value(expected_plan_hash,
                                                   payload_value);
            }
            expected_plan_hash = fnv_value(expected_plan_hash, command.idempotency_key);
            if (schema >= 10 && command.external_effect_id != 0) {
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.external_effect_id);
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.external_source_id);
            }
        }
        if (expected_plan_hash != transaction.plan_hash)
            return failure("pkef_transaction_plan_hash_invalid");
        max_transaction_id = std::max(max_transaction_id, transaction.id);
        restored_transactions.push_back(std::move(transaction));
    }
    std::vector<ExternalSourceBinding> restored_bindings;
    std::unordered_map<int64_t, int32_t> restored_binding_ids;
    if (schema >= 5) {
        uint32_t binding_count = 0;
        if (!read_le(bytes, size, cursor, binding_count) ||
            binding_count > static_cast<uint32_t>(_max_instances))
            return failure("pkef_external_binding_count_invalid");
        restored_bindings.reserve(binding_count);
        for (uint32_t i = 0; i < binding_count; ++i) {
            ExternalSourceBinding binding;
            if (!read_le(bytes, size, cursor, binding.binding_id) ||
                !read_le(bytes, size, cursor, binding.generation) ||
                !read_le(bytes, size, cursor, binding.source_type) ||
                !read_le(bytes, size, cursor, binding.source_id) ||
                !read_le(bytes, size, cursor, binding.target_handle) ||
                !read_le(bytes, size, cursor, binding.target_generation) ||
                !read_le(bytes, size, cursor, binding.level) ||
                !read_le(bytes, size, cursor, binding.location) ||
                !read_le(bytes, size, cursor, binding.active) ||
                !read_le(bytes, size, cursor, binding.template_signature) ||
                !read_le(bytes, size, cursor, binding.program_hash))
                return failure("pkef_external_binding_truncated");
            if (binding.binding_id <= 0 || binding.generation == 0 ||
                binding.target_handle == 0 || binding.target_generation == 0 ||
                binding.level < -1 || binding.location > 2 || binding.active > 1 ||
                !restored_binding_ids.emplace(binding.binding_id,
                    static_cast<int32_t>(restored_bindings.size())).second)
                return failure("pkef_external_binding_invalid");
            restored_bindings.push_back(binding);
        }
    }
    uint64_t restored_player_country = 0;
    int64_t restored_next_plan_id = 1;
    int64_t restored_next_generation = 1;
    EraRewardOffer restored_offer;
    if (!read_le(bytes, size, cursor, restored_player_country) ||
        !read_le(bytes, size, cursor, restored_next_plan_id) ||
        !read_le(bytes, size, cursor, restored_next_generation) ||
        !read_le(bytes, size, cursor, restored_offer.plan_id) ||
        !read_le(bytes, size, cursor, restored_offer.generation) ||
        !read_le(bytes, size, cursor, restored_offer.pool_index) ||
        !read_le(bytes, size, cursor, restored_offer.milestone_technology) ||
        !read_le(bytes, size, cursor, restored_offer.country_handle) ||
        !read_le(bytes, size, cursor, restored_offer.country_generation) ||
        !read_le(bytes, size, cursor, restored_offer.status) ||
        !read_le(bytes, size, cursor, restored_offer.selected_choice) ||
        !read_le(bytes, size, cursor, restored_offer.transaction_id) ||
        !read_le(bytes, size, cursor, restored_offer.plan_hash) ||
        !read_string(bytes, size, cursor, restored_offer.error))
        return failure("pkef_era_reward_truncated");
    for (EraRewardAlternative &alternative : restored_offer.alternatives) {
        if (!read_le(bytes, size, cursor, alternative.option_index) ||
            !read_le(bytes, size, cursor, alternative.weight) ||
            !read_le(bytes, size, cursor, alternative.target_handle) ||
            !read_le(bytes, size, cursor, alternative.target_generation) ||
            !read_le(bytes, size, cursor, alternative.reason_count) ||
            !read_string(bytes, size, cursor, alternative.reasons[0]) ||
            !read_string(bytes, size, cursor, alternative.reasons[1]) ||
            !read_string(bytes, size, cursor, alternative.target_summary))
            return failure("pkef_era_reward_alternative_truncated");
    }
    if (restored_next_plan_id <= 0 || restored_next_generation <= 0 ||
        restored_offer.status < 0 || restored_offer.status > 4 ||
        restored_offer.pool_index < -1 ||
        restored_offer.pool_index >= static_cast<int32_t>(_era_reward_pools.size()) ||
        restored_offer.selected_choice < -1 || restored_offer.selected_choice > 2 ||
        (restored_offer.status == 0 &&
         (restored_offer.plan_id != 0 || restored_offer.transaction_id != 0)) ||
        (restored_offer.status != 0 &&
         (restored_offer.plan_id <= 0 || restored_offer.generation <= 0 ||
          restored_offer.country_handle == 0 || restored_offer.country_generation == 0)) ||
        (restored_offer.status == 1 && restored_offer.transaction_id != 0) ||
        (restored_offer.status == 2 &&
         (restored_offer.transaction_id <= 0 ||
          restored_transaction_ids.find(restored_offer.transaction_id) ==
              restored_transaction_ids.end())))
        return failure("pkef_era_reward_identity_invalid");
    if (restored_offer.status != 0) {
        for (const EraRewardAlternative &alternative : restored_offer.alternatives) {
            if (alternative.option_index < 0 ||
                alternative.option_index >= static_cast<int32_t>(_era_reward_options.size()) ||
                alternative.weight <= 0 || alternative.target_handle == 0 ||
                alternative.target_generation == 0 ||
                alternative.reason_count < 0 || alternative.reason_count > 2)
                return failure("pkef_era_reward_alternative_invalid");
        }
    }
    if (_country_runtime != nullptr) {
        const NativeCountryRuntime::EraRewardReference country_reference =
            _country_runtime->era_reward_reference_pod();
        if (country_reference.plan_id != restored_offer.plan_id ||
            country_reference.offer_generation != restored_offer.generation ||
            country_reference.milestone_technology !=
                restored_offer.milestone_technology ||
            country_reference.status != restored_offer.status)
            return failure("era_reward_cross_section_mismatch");
    }
    if (!read_le(bytes, size, cursor, end_magic) || end_magic != SAVE_END)
        return failure("pkef_end_marker_missing");
    if (cursor != size || run_cursor > static_cast<int32_t>(restored_instances.size()) ||
        next_tx <= max_transaction_id)
        return failure("pkef_trailing_or_cursor_invalid");

    // Commit the parsed snapshot only after every bound and marker has passed.
    // A malformed/truncated save therefore cannot destroy the live runtime.
    reset_runtime_state();
    _current_day = current_day;
    _last_completed_day = last_day;
    _run_day = run_day;
    _run_cursor = candidate_cursor;
    _candidate_cursor = candidate_cursor;
    _run_candidates = std::move(restored_candidates);
    _next_transaction_id = next_tx;
    _acked_transaction_id = acked_tx;
    _instances = std::move(restored_instances);
    _metric_values = std::move(restored_metric_values);
    _metric_present = std::move(restored_metric_present);
    _command_arena = std::move(restored_command_arena);
    for (size_t i = 0; i < _instances.size(); ++i) {
        _instances[i].metric_base = static_cast<uint32_t>(i *
            static_cast<size_t>(_metric_count));
        _instances[i].dirty_epoch = 0;
        _instances[i].schedule_token = 0;
        if (_instances[i].active)
            schedule_instance(static_cast<int32_t>(i), _instances[i].next_due_day);
    }
    _instance_ids = std::move(restored_instance_ids);
    _free_instance_indices.clear();
    for (size_t i = 0; i < _instances.size(); ++i)
        if (_instances[i].id == 0)
            _free_instance_indices.push_back(static_cast<int32_t>(i));
    _transactions = std::move(restored_transactions);
    _transaction_ids.clear();
    _transaction_ids.reserve(_transactions.size());
    for (size_t i = 0; i < _transactions.size(); ++i)
        _transaction_ids[_transactions[i].id] = static_cast<int32_t>(i);
    _external_bindings = std::move(restored_bindings);
    _external_binding_ids = std::move(restored_binding_ids);
    _era_reward_player_country = restored_player_country;
    _era_reward_next_plan_id = restored_next_plan_id;
    _era_reward_next_generation = restored_next_generation;
    _era_reward_offer = std::move(restored_offer);
    rebuild_command_idempotency_index();
    Dictionary out;
    out["ok"] = true;
    out["instances"] = static_cast<int32_t>(_instances.size());
    out["transactions"] = static_cast<int32_t>(_transactions.size());
    return out;
}

Dictionary EffectRuntime::clear_state() {
    if (!_configured) return failure("effect_runtime_unconfigured");
    reset_runtime_state();
    Dictionary out;
    out["ok"] = true;
    return out;
}

} // namespace pk

#include "runtime_effect_pod.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <type_traits>

namespace pk {
namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;
constexpr uint32_t MAX_SAVE_BYTES = 64u * 1024u * 1024u;
constexpr uint32_t SAVE_MAGIC = 0x31504645u; // EFP1
constexpr uint32_t SAVE_END = 0x21444e45u; // END!
constexpr int32_t Q16_ONE = 65536;

template <typename T, bool = std::is_enum_v<std::remove_cv_t<T>>>
struct le_raw_type {
    using type = std::remove_cv_t<T>;
};

template <typename T>
struct le_raw_type<T, true> {
    using type = std::underlying_type_t<std::remove_cv_t<T>>;
};

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    using Raw = std::remove_cv_t<T>;
    using U = typename le_raw_type<Raw>::type;
    using Unsigned = std::make_unsigned_t<U>;
    Unsigned bits = static_cast<Unsigned>(
        static_cast<U>(value));
    for (size_t i = 0; i < sizeof(U); ++i) {
        out.push_back(static_cast<uint8_t>(bits & static_cast<Unsigned>(0xffu)));
        bits >>= 8u;
    }
}

template <typename T>
bool read_le(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    using Raw = std::remove_cv_t<T>;
    using U = typename le_raw_type<Raw>::type;
    using Unsigned = std::make_unsigned_t<U>;
    if (data == nullptr || cursor > size || size - cursor < sizeof(U)) return false;
    Unsigned bits = 0;
    for (size_t i = 0; i < sizeof(U); ++i)
        bits |= static_cast<Unsigned>(data[cursor + i]) << (i * 8u);
    cursor += sizeof(U);
    if constexpr (std::is_enum_v<Raw>) {
        value = static_cast<Raw>(static_cast<U>(bits));
    } else {
        value = static_cast<T>(static_cast<U>(bits));
    }
    return true;
}

uint64_t mix_bytes(uint64_t hash, const void *data, size_t size) noexcept {
    const auto *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

template <typename T>
uint64_t mix_value(uint64_t hash, const T &value) noexcept {
    return mix_bytes(hash, &value, sizeof(value));
}

bool read_count(const uint8_t *data, size_t size, size_t &cursor,
                uint32_t &count, uint32_t capacity) {
    return read_le(data, size, cursor, count) && count <= capacity;
}

bool is_action_valid(RuntimeEffectPodAction action) noexcept {
    const uint8_t value = static_cast<uint8_t>(action);
    return value >= 1u && value <= 6u;
}

bool is_condition_valid(RuntimeEffectPodConditionOp op) noexcept {
    const uint8_t value = static_cast<uint8_t>(op);
    return value >= 1u && value <= 8u;
}

bool is_instruction_valid(RuntimeEffectPodInstructionOp op) noexcept {
    const uint8_t value = static_cast<uint8_t>(op);
    return value >= 1u && value <= 12u;
}

void copy_string(char (&destination)[64], const char *source) noexcept {
    size_t index = 0;
    if (source != nullptr) {
        for (; index + 1u < sizeof(destination) && source[index] != '\0'; ++index)
            destination[index] = source[index];
    }
    destination[index] = '\0';
    for (++index; index < sizeof(destination); ++index) destination[index] = '\0';
}

} // namespace

RuntimeEffectPodAuthority::RuntimeEffectPodAuthority() {
    reset();
}

void RuntimeEffectPodAuthority::reset(uint32_t instance_capacity,
                                      uint32_t transaction_capacity,
                                      uint32_t command_capacity) {
    _instance_capacity = std::max(1u, std::min(instance_capacity,
        RUNTIME_EFFECT_POD_MAX_INSTANCES));
    _transaction_capacity = std::max(1u, std::min(transaction_capacity,
        RUNTIME_EFFECT_POD_MAX_TRANSACTIONS));
    _command_capacity = std::max(1u, std::min(command_capacity,
        RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA));
    _current = State{};
    _next = State{};
    _current.instances.reserve(std::min<uint32_t>(_instance_capacity, 4096u));
    _next.instances.reserve(std::min<uint32_t>(_instance_capacity, 4096u));
    _current.transactions.reserve(std::min<uint32_t>(_transaction_capacity, 1024u));
    _next.transactions.reserve(std::min<uint32_t>(_transaction_capacity, 1024u));
    _current.command_arena.reserve(std::min<uint32_t>(_command_capacity, 4096u));
    _next.command_arena.reserve(std::min<uint32_t>(_command_capacity, 4096u));
    _current.deterministic_state_hash = state_hash(_current);
    _next.deterministic_state_hash = state_hash(_next);
    _next_transaction_id = 1;
    _active_plan = nullptr;
    _plan_ready = false;
    _snapshot = RuntimeEffectPodSnapshot{};
    _snapshot.abi_version = RUNTIME_EFFECT_POD_ABI_VERSION;
    _snapshot.catalog_version = RUNTIME_EFFECT_POD_CATALOG_VERSION;
    _snapshot.catalog_hash = _catalog.catalog_hash;
    _snapshot.catalog_revision = _catalog_revision;
    build_snapshot(_current, _snapshot);
    rebuild_report();
}

uint64_t RuntimeEffectPodAuthority::hash_text(const char *text) noexcept {
    uint64_t hash = FNV_OFFSET;
    if (text == nullptr) return hash;
    for (const uint8_t *cursor = reinterpret_cast<const uint8_t *>(text);
         *cursor != 0; ++cursor) {
        hash ^= *cursor;
        hash *= FNV_PRIME;
    }
    return hash;
}

uint64_t RuntimeEffectPodAuthority::hash_mix(uint64_t hash, const void *data,
                                             size_t size) noexcept {
    return mix_bytes(hash, data, size);
}

uint32_t RuntimeEffectPodAuthority::adapter_ack_bit(
        RuntimeEffectPodAction action) noexcept {
    const uint8_t value = static_cast<uint8_t>(action);
    return value >= 1u && value <= 6u ? (1u << (value - 1u)) : 0u;
}

uint16_t RuntimeEffectPodAuthority::adapter_domain(
        RuntimeEffectPodAction action) noexcept {
    switch (action) {
        case RuntimeEffectPodAction::MODIFIER_COMMAND:
            return static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        case RuntimeEffectPodAction::COUNTRY_COMMAND:
            return static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
        case RuntimeEffectPodAction::ECONOMY_COMMAND:
            return static_cast<uint16_t>(RuntimeDomainId::ECONOMY);
        case RuntimeEffectPodAction::GAMEPLAY_COMMAND:
            return static_cast<uint16_t>(RuntimeDomainId::GAMEPLAY_EFFECT);
        case RuntimeEffectPodAction::PUBLISH_EVENT:
            return static_cast<uint16_t>(RuntimeDomainId::EVENTS);
        case RuntimeEffectPodAction::CUSTOM_DOMAIN_COMMAND:
            return static_cast<uint16_t>(RuntimeDomainId::EFFECT);
    }
    return 0;
}

void RuntimeEffectPodAuthority::copy_error(char (&destination)[64],
                                           const char *source) noexcept {
    copy_string(destination, source);
}

void RuntimeEffectPodAuthority::set_blocker(const char *reason) noexcept {
    copy_error(_report.blocker, reason);
}

uint64_t RuntimeEffectPodAuthority::catalog_hash(
        const RuntimeEffectPodCatalog &catalog) noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, catalog.abi_version);
    hash = mix_value(hash, catalog.catalog_version);
    hash = mix_value(hash, catalog.max_instances);
    hash = mix_value(hash, catalog.max_transactions);
    hash = mix_value(hash, catalog.max_work_per_slice);
    hash = mix_value(hash, catalog.max_commands_per_transaction);
    hash = mix_value(hash, static_cast<uint32_t>(catalog.metric_key_hashes.size()));
    for (const uint64_t value : catalog.metric_key_hashes) hash = mix_value(hash, value);
    hash = mix_value(hash, static_cast<uint32_t>(catalog.behaviors.size()));
    for (const auto &behavior : catalog.behaviors) {
        hash = mix_value(hash, behavior.behavior_id_hash);
        hash = mix_value(hash, behavior.version);
        hash = mix_value(hash, behavior.max_output);
        hash = mix_value(hash, behavior.thread_safe);
        hash = mix_value(hash, behavior.implemented);
    }
    hash = mix_value(hash, static_cast<uint32_t>(catalog.definitions.size()));
    for (const auto &definition : catalog.definitions) {
        hash = mix_value(hash, definition.key_hash);
        hash = mix_value(hash, definition.version);
        hash = mix_value(hash, definition.cadence_days);
        hash = mix_value(hash, definition.max_work);
        hash = mix_value(hash, definition.enabled);
        hash = mix_value(hash, definition.condition_begin);
        hash = mix_value(hash, definition.condition_count);
        hash = mix_value(hash, definition.instruction_begin);
        hash = mix_value(hash, definition.instruction_count);
        hash = mix_value(hash, definition.command_begin);
        hash = mix_value(hash, definition.command_count);
        hash = mix_value(hash, definition.behavior_id_hash);
        hash = mix_value(hash, definition.source_kind);
        hash = mix_value(hash, definition.target_domain);
        hash = mix_value(hash, definition.operation);
        hash = mix_value(hash, definition.lifecycle);
        hash = mix_value(hash, definition.duration_days);
        hash = mix_value(hash, definition.stack_policy);
        hash = mix_value(hash, definition.stack_key_hash);
        hash = mix_value(hash, definition.max_stacks);
        hash = mix_value(hash, definition.priority);
        hash = mix_value(hash, definition.target_selector_kind);
        hash = mix_value(hash, definition.target_selector_hash);
        for (const int32_t value : definition.magnitude_by_prestige_q16)
            hash = mix_value(hash, value);
    }
    hash = mix_value(hash, static_cast<uint32_t>(catalog.conditions.size()));
    for (const auto &condition : catalog.conditions) {
        hash = mix_value(hash, condition.op);
        hash = mix_value(hash, condition.arg0);
        hash = mix_value(hash, condition.value);
    }
    hash = mix_value(hash, static_cast<uint32_t>(catalog.instructions.size()));
    for (const auto &instruction : catalog.instructions) {
        hash = mix_value(hash, instruction.op);
        hash = mix_value(hash, instruction.arg0);
        hash = mix_value(hash, instruction.arg1);
        hash = mix_value(hash, instruction.value);
    }
    hash = mix_value(hash, static_cast<uint32_t>(catalog.commands.size()));
    for (const auto &command : catalog.commands) {
        hash = mix_value(hash, command.action);
        hash = mix_value(hash, command.domain);
        hash = mix_value(hash, command.opcode);
        hash = mix_value(hash, command.target_resolver);
        hash = mix_value(hash, command.static_target);
        hash = mix_value(hash, command.value_mode);
        hash = mix_value(hash, command.value);
        hash = mix_value(hash, command.duration_days);
        hash = mix_value(hash, command.stacks);
        hash = mix_value(hash, command.command_key_hash);
        hash = mix_value(hash, command.definition_key_hash);
        for (const int64_t value : command.payload) hash = mix_value(hash, value);
    }
    return hash;
}

bool RuntimeEffectPodAuthority::validate_catalog(
        const RuntimeEffectPodCatalog &catalog, std::string &error) const {
    error.clear();
    if (catalog.abi_version != RUNTIME_EFFECT_POD_ABI_VERSION ||
        catalog.catalog_version != RUNTIME_EFFECT_POD_CATALOG_VERSION) {
        error = "effect_pod_catalog_version_invalid";
        return false;
    }
    if (catalog.max_instances == 0 || catalog.max_instances > RUNTIME_EFFECT_POD_MAX_INSTANCES ||
        catalog.max_transactions == 0 || catalog.max_transactions > RUNTIME_EFFECT_POD_MAX_TRANSACTIONS ||
        catalog.max_work_per_slice == 0 || catalog.max_work_per_slice > 1000000u ||
        catalog.max_commands_per_transaction == 0 ||
        catalog.max_commands_per_transaction > RUNTIME_EFFECT_POD_MAX_COMMANDS ||
        catalog.metric_key_hashes.size() > RUNTIME_EFFECT_POD_MAX_METRICS ||
        catalog.behaviors.size() > RUNTIME_EFFECT_POD_MAX_DEFINITIONS ||
        catalog.definitions.size() > RUNTIME_EFFECT_POD_MAX_DEFINITIONS ||
        catalog.conditions.size() > RUNTIME_EFFECT_POD_MAX_CONDITIONS ||
        catalog.instructions.size() > RUNTIME_EFFECT_POD_MAX_INSTRUCTIONS ||
        catalog.commands.size() > RUNTIME_EFFECT_POD_MAX_COMMAND_DEFINITIONS) {
        error = "effect_pod_catalog_capacity_invalid";
        return false;
    }
    for (size_t i = 0; i < catalog.metric_key_hashes.size(); ++i) {
        if (catalog.metric_key_hashes[i] == 0) {
            error = "effect_pod_metric_hash_invalid";
            return false;
        }
        for (size_t j = 0; j < i; ++j) {
            if (catalog.metric_key_hashes[i] == catalog.metric_key_hashes[j]) {
                error = "effect_pod_metric_hash_duplicate";
                return false;
            }
        }
    }
    for (const auto &behavior : catalog.behaviors) {
        if (behavior.behavior_id_hash == 0 || behavior.version == 0 ||
            behavior.max_output > RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT ||
            behavior.thread_safe > 1u || behavior.implemented > 1u ||
            (behavior.implemented != 0 && behavior.function == nullptr)) {
            error = "effect_pod_behavior_metadata_invalid";
            return false;
        }
    }
    const auto valid_range = [](uint32_t begin, uint32_t count, size_t size) {
        return begin <= size && count <= size - begin;
    };
    for (const auto &definition : catalog.definitions) {
        if (definition.key_hash == 0 || definition.version <= 0 ||
            definition.cadence_days <= 0 || definition.max_work <= 0 ||
            !valid_range(definition.condition_begin, definition.condition_count,
                         catalog.conditions.size()) ||
            !valid_range(definition.instruction_begin, definition.instruction_count,
                         catalog.instructions.size()) ||
            !valid_range(definition.command_begin, definition.command_count,
                         catalog.commands.size()) ||
            definition.max_stacks <= 0 || definition.duration_days == 0 ||
            definition.target_selector_kind < 0 ||
            definition.target_selector_kind > 7) {
            error = "effect_pod_definition_invalid";
            return false;
        }
        if (definition.behavior_id_hash != 0) {
            bool found = false;
            for (const auto &behavior : catalog.behaviors) {
                if (behavior.behavior_id_hash == definition.behavior_id_hash) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                error = "effect_pod_behavior_metadata_missing";
                return false;
            }
        }
        if (definition.lifecycle == RuntimeEffectPodLifecycle::DURATION &&
            (definition.duration_days <= 0 || definition.command_count == 0)) {
            error = "effect_pod_duration_definition_invalid";
            return false;
        }
    }
    for (const auto &condition : catalog.conditions) {
        if (!is_condition_valid(condition.op) ||
            ((condition.op == RuntimeEffectPodConditionOp::METRIC_GTE ||
              condition.op == RuntimeEffectPodConditionOp::METRIC_LTE ||
              condition.op == RuntimeEffectPodConditionOp::METRIC_EQ) &&
             (condition.arg0 < 0 ||
              condition.arg0 >= static_cast<int32_t>(catalog.metric_key_hashes.size()))) ||
            (condition.op == RuntimeEffectPodConditionOp::STATE_GTE &&
             (condition.arg0 < 0 || condition.arg0 > 3))) {
            error = "effect_pod_condition_invalid";
            return false;
        }
    }
    for (const auto &instruction : catalog.instructions) {
        if (!is_instruction_valid(instruction.op) ||
            (instruction.op == RuntimeEffectPodInstructionOp::READ_METRIC &&
             (instruction.arg0 < 0 ||
              instruction.arg0 >= static_cast<int32_t>(catalog.metric_key_hashes.size()))) ||
            (instruction.op == RuntimeEffectPodInstructionOp::READ_STATE &&
             (instruction.arg0 < 0 || instruction.arg0 > 3))) {
            error = "effect_pod_instruction_invalid";
            return false;
        }
    }
    for (const auto &command : catalog.commands) {
        if (!is_action_valid(command.action) || command.domain < 0 ||
            command.domain >= 32 || command.opcode <= 0 || command.stacks <= 0 ||
            command.duration_days == 0 || command.command_key_hash == 0 ||
            (command.target_resolver == RuntimeEffectPodTargetResolver::STATIC &&
             command.static_target == 0)) {
            error = "effect_pod_command_invalid";
            return false;
        }
        switch (command.action) {
            case RuntimeEffectPodAction::MODIFIER_COMMAND:
                if (command.domain > 3 || (command.opcode != 1 && command.opcode != 2)) {
                    error = "effect_pod_modifier_command_invalid";
                    return false;
                }
                break;
            case RuntimeEffectPodAction::COUNTRY_COMMAND:
                if (command.domain != 1 || command.opcode > 14) {
                    error = "effect_pod_country_command_invalid";
                    return false;
                }
                break;
            case RuntimeEffectPodAction::ECONOMY_COMMAND:
                if (command.domain != 2) {
                    error = "effect_pod_economy_command_invalid";
                    return false;
                }
                break;
            case RuntimeEffectPodAction::GAMEPLAY_COMMAND:
                if (command.domain != 3) {
                    error = "effect_pod_gameplay_command_invalid";
                    return false;
                }
                break;
            case RuntimeEffectPodAction::PUBLISH_EVENT:
                if (command.domain != 4) {
                    error = "effect_pod_event_command_invalid";
                    return false;
                }
                break;
            case RuntimeEffectPodAction::CUSTOM_DOMAIN_COMMAND:
                if (command.domain != 6) {
                    error = "effect_pod_custom_command_invalid";
                    return false;
                }
                break;
        }
    }
    const uint64_t expected = catalog_hash(catalog);
    if (catalog.catalog_hash != 0 && catalog.catalog_hash != expected) {
        error = "effect_pod_catalog_hash_invalid";
        return false;
    }
    return true;
}

bool RuntimeEffectPodAuthority::configure(
        const RuntimeEffectPodCatalog &catalog, std::string &error) {
    if (!validate_catalog(catalog, error)) {
        _configured = false;
        set_blocker(error.c_str());
        return false;
    }
    _catalog = catalog;
    _catalog.catalog_hash = catalog_hash(_catalog);
    ++_catalog_revision;
    _configured = true;
    reset(_catalog.max_instances, _catalog.max_transactions,
          std::min<uint32_t>(RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA,
                             std::max<uint32_t>(4096u,
                                 _catalog.max_commands_per_transaction * 4u)));
    _snapshot.catalog_hash = _catalog.catalog_hash;
    _snapshot.catalog_revision = _catalog_revision;
    _report.configured = 1;
    _report.catalog_hash = _catalog.catalog_hash;
    return true;
}

bool RuntimeEffectPodAuthority::validate_instance(
        const RuntimeEffectPodInstanceInput &input, std::string &error) const {
    if (!_configured) { error = "effect_pod_not_configured"; return false; }
    if (input.instance_id <= 0 || input.generation == 0 || input.program_id < 0 ||
        input.program_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
        input.next_due_day < 0 || input.target_handle == 0 ||
        input.target_generation == 0) {
        error = "effect_pod_instance_invalid";
        return false;
    }
    return true;
}

int32_t RuntimeEffectPodAuthority::instance_index(
        int64_t instance_id, uint32_t generation) const {
    for (size_t i = 0; i < _current.instances.size(); ++i) {
        const auto &instance = _current.instances[i];
        if (instance.instance_id == instance_id && instance.generation == generation)
            return static_cast<int32_t>(i);
    }
    return -1;
}

int32_t RuntimeEffectPodAuthority::transaction_index(int64_t transaction_id) const {
    for (size_t i = 0; i < _current.transactions.size(); ++i) {
        if (_current.transactions[i].transaction_id == transaction_id)
            return static_cast<int32_t>(i);
    }
    return -1;
}

bool RuntimeEffectPodAuthority::upsert_instance(
        const RuntimeEffectPodInstanceInput &input, std::string &error) {
    error.clear();
    if (!validate_instance(input, error)) return false;
    const auto &definition = _catalog.definitions[static_cast<size_t>(input.program_id)];
    int32_t index = -1;
    for (size_t i = 0; i < _current.instances.size(); ++i) {
        if (_current.instances[i].instance_id == input.instance_id) {
            index = static_cast<int32_t>(i);
            break;
        }
    }
    if (index < 0) {
        if (_current.instances.size() >= _instance_capacity) {
            error = "effect_pod_instance_capacity_exhausted";
            return false;
        }
        index = static_cast<int32_t>(_current.instances.size());
        _current.instances.emplace_back();
        _current.metric_values.resize(
            (static_cast<size_t>(index) + 1u) * _catalog.metric_key_hashes.size());
        _current.metric_revisions.resize(
            (static_cast<size_t>(index) + 1u) * _catalog.metric_key_hashes.size());
    }
    RuntimeEffectPodInstance &instance = _current.instances[static_cast<size_t>(index)];
    const uint32_t metric_base = static_cast<uint32_t>(
        static_cast<size_t>(index) * _catalog.metric_key_hashes.size());
    const int64_t old_revision = instance.input_revision;
    instance = RuntimeEffectPodInstance{};
    instance.instance_id = input.instance_id;
    instance.generation = input.generation;
    instance.program_id = input.program_id;
    instance.source_type = input.source_type;
    instance.source_id = input.source_id;
    instance.source_handle = input.source_handle;
    instance.target_handle = input.target_handle;
    instance.target_generation = input.target_generation;
    instance.level = input.level;
    instance.metric_base = metric_base;
    instance.input_revision = old_revision;
    instance.next_due_day = input.next_due_day;
    instance.cadence_days = definition.cadence_days;
    instance.lifecycle = definition.lifecycle;
    instance.stack_policy = definition.stack_policy;
    instance.max_stacks = definition.max_stacks;
    instance.stack_key_hash = definition.stack_key_hash;
    instance.active = input.active ? 1 : 0;
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

bool RuntimeEffectPodAuthority::remove_instance(int64_t instance_id,
                                                uint32_t generation,
                                                std::string &error) {
    error.clear();
    const int32_t index = instance_index(instance_id, generation);
    if (index < 0) { error = "effect_pod_instance_stale_generation"; return false; }
    auto &instance = _current.instances[static_cast<size_t>(index)];
    instance.active = 0;
    instance.retire_requested = 1;
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

bool RuntimeEffectPodAuthority::set_metric(int64_t instance_id, uint32_t generation,
                                           int32_t metric_id, int64_t revision,
                                           int64_t value, std::string &error) {
    error.clear();
    const int32_t index = instance_index(instance_id, generation);
    if (index < 0) { error = "effect_pod_metric_stale_generation"; return false; }
    if (metric_id < 0 || metric_id >= static_cast<int32_t>(_catalog.metric_key_hashes.size()) ||
        revision < 0) {
        error = "effect_pod_metric_invalid";
        return false;
    }
    auto &instance = _current.instances[static_cast<size_t>(index)];
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    if (offset >= _current.metric_values.size()) {
        error = "effect_pod_metric_slab_invalid";
        return false;
    }
    if (revision < _current.metric_revisions[offset]) return true;
    _current.metric_revisions[offset] = revision;
    _current.metric_values[offset] = value;
    instance.input_revision = std::max(instance.input_revision, revision);
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

bool RuntimeEffectPodAuthority::evaluate_conditions(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, const State &state) const {
    if (definition.condition_count == 0) return true;
    std::array<uint8_t, 256> stack{};
    uint32_t depth = 0;
    const auto metric = [&](int32_t id) -> int64_t {
        const size_t offset = static_cast<size_t>(instance.metric_base) +
            static_cast<size_t>(id);
        return offset < state.metric_values.size() ? state.metric_values[offset] : 0;
    };
    const auto state_value = [&](int32_t id) -> int64_t {
        switch (id) {
            case 0: return instance.level;
            case 1: return static_cast<int64_t>(instance.fire_sequence);
            case 2: return instance.stack_count;
            case 3: return instance.input_revision;
        }
        return 0;
    };
    for (uint32_t i = 0; i < definition.condition_count; ++i) {
        const auto &condition = _catalog.conditions[definition.condition_begin + i];
        switch (condition.op) {
            case RuntimeEffectPodConditionOp::CONDITION_TRUE:
                if (depth >= stack.size()) return false;
                stack[depth++] = 1;
                break;
            case RuntimeEffectPodConditionOp::METRIC_GTE:
            case RuntimeEffectPodConditionOp::METRIC_LTE:
            case RuntimeEffectPodConditionOp::METRIC_EQ: {
                if (depth >= stack.size()) return false;
                const int64_t actual = metric(condition.arg0);
                stack[depth++] = condition.op == RuntimeEffectPodConditionOp::METRIC_GTE
                    ? actual >= condition.value
                    : condition.op == RuntimeEffectPodConditionOp::METRIC_LTE
                        ? actual <= condition.value : actual == condition.value;
                break;
            }
            case RuntimeEffectPodConditionOp::STATE_GTE:
                if (depth >= stack.size()) return false;
                stack[depth++] = state_value(condition.arg0) >= condition.value;
                break;
            case RuntimeEffectPodConditionOp::BOOL_AND:
            case RuntimeEffectPodConditionOp::BOOL_OR:
                if (depth < 2) return false;
                --depth;
                stack[depth - 1u] = condition.op == RuntimeEffectPodConditionOp::BOOL_AND
                    ? (stack[depth - 1u] && stack[depth])
                    : (stack[depth - 1u] || stack[depth]);
                break;
            case RuntimeEffectPodConditionOp::BOOL_NOT:
                if (depth < 1) return false;
                stack[depth - 1u] = stack[depth - 1u] == 0;
                break;
        }
    }
    return depth == 1 && stack[0] != 0;
}

bool RuntimeEffectPodAuthority::compile_command(
        const RuntimeEffectPodCommandDefinition &definition,
        const RuntimeEffectPodInstance &instance, int64_t value, int64_t day,
        uint64_t fire_sequence, uint32_t command_index,
        RuntimeEffectPodCommand &out) const {
    out = RuntimeEffectPodCommand{};
    out.action = definition.action;
    out.domain = definition.domain;
    out.opcode = definition.opcode;
    out.source_instance_id = static_cast<uint64_t>(instance.instance_id);
    out.source_generation = instance.generation;
    out.source_handle = instance.source_handle;
    out.target_handle = definition.target_resolver == RuntimeEffectPodTargetResolver::STATIC
        ? definition.static_target
        : definition.target_resolver == RuntimeEffectPodTargetResolver::SOURCE
            ? instance.source_handle : instance.target_handle;
    out.target_generation = instance.target_generation;
    out.value = definition.value_mode == RuntimeEffectPodValueMode::CONSTANT
        ? definition.value : value;
    out.duration_days = definition.duration_days;
    out.stacks = definition.stacks;
    out.command_definition_id = static_cast<uint32_t>(
        &definition - _catalog.commands.data());
    out.command_key_hash = definition.command_key_hash;
    out.definition_key_hash = definition.definition_key_hash;
    out.effective_day = day;
    out.payload = definition.payload;
    uint64_t key = FNV_OFFSET;
    key = mix_value(key, instance.instance_id);
    key = mix_value(key, instance.generation);
    key = mix_value(key, fire_sequence);
    key = mix_value(key, command_index);
    key = mix_value(key, out.action);
    key = mix_value(key, out.domain);
    key = mix_value(key, out.opcode);
    out.idempotency_key = key;
    return out.target_handle != 0 && out.target_generation != 0;
}

bool RuntimeEffectPodAuthority::invoke_behavior(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, const State &state,
        int64_t day, std::vector<RuntimeEffectPodCommand> &commands,
        std::string &error) const {
    if (definition.behavior_id_hash == 0) return true;
    const RuntimeEffectPodBehaviorMetadata *metadata = nullptr;
    for (const auto &candidate : _catalog.behaviors) {
        if (candidate.behavior_id_hash == definition.behavior_id_hash) {
            metadata = &candidate;
            break;
        }
    }
    if (metadata == nullptr || metadata->implemented == 0 ||
        metadata->function == nullptr || metadata->thread_safe == 0) {
        error = "effect_behavior_not_registered";
        return false;
    }
    std::array<RuntimeEffectPodBehaviorCommand, RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT> buffer{};
    RuntimeEffectPodBehaviorOutput output;
    output.commands = buffer.data();
    output.capacity = std::min<uint32_t>(metadata->max_output,
                                         RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT);
    const size_t metric_count = _catalog.metric_key_hashes.size();
    const int64_t *metrics = instance.metric_base < state.metric_values.size()
        ? state.metric_values.data() + instance.metric_base : nullptr;
    RuntimeEffectPodBehaviorInput input;
    input.instance_id = instance.instance_id;
    input.instance_generation = instance.generation;
    input.level = instance.level;
    input.day = day;
    input.source_handle = instance.source_handle;
    input.target_handle = instance.target_handle;
    input.metrics = metrics;
    input.metric_count = static_cast<uint32_t>(metric_count);
    if (!metadata->function(input, output, error) || output.overflowed) {
        if (error.empty()) error = output.overflowed
            ? "effect_behavior_output_capacity_exceeded" : "effect_behavior_failed";
        return false;
    }
    for (uint32_t i = 0; i < output.count; ++i) {
        const auto &behavior_command = output.commands[i];
        RuntimeEffectPodCommand command;
        command.action = behavior_command.action;
        command.domain = behavior_command.domain;
        command.opcode = behavior_command.opcode;
        command.source_instance_id = static_cast<uint64_t>(instance.instance_id);
        command.source_generation = instance.generation;
        command.source_handle = instance.source_handle;
        command.target_handle = behavior_command.target_handle == 0
            ? instance.target_handle : behavior_command.target_handle;
        command.target_generation = behavior_command.target_generation == 0
            ? instance.target_generation : behavior_command.target_generation;
        command.value = behavior_command.value;
        command.duration_days = behavior_command.duration_days;
        command.stacks = behavior_command.stacks;
        command.effective_day = day;
        command.payload = behavior_command.payload;
        command.idempotency_key = FNV_OFFSET;
        command.idempotency_key = mix_value(command.idempotency_key,
                                            instance.instance_id);
        command.idempotency_key = mix_value(command.idempotency_key,
                                            instance.generation);
        command.idempotency_key = mix_value(command.idempotency_key,
                                            instance.fire_sequence + 1u);
        command.idempotency_key = mix_value(command.idempotency_key, i);
        commands.push_back(command);
    }
    return true;
}

bool RuntimeEffectPodAuthority::execute_program(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, const State &state,
        int64_t day, std::vector<RuntimeEffectPodCommand> &commands,
        std::string &error) const {
    error.clear();
    if (!invoke_behavior(definition, instance, state, day, commands, error)) return false;
    if (definition.instruction_count == 0) return true;
    std::array<int64_t, 256> stack{};
    uint32_t depth = 0;
    const auto metric = [&](int32_t id) -> int64_t {
        const size_t offset = static_cast<size_t>(instance.metric_base) +
            static_cast<size_t>(id);
        return offset < state.metric_values.size() ? state.metric_values[offset] : 0;
    };
    const auto state_value = [&](int32_t id) -> int64_t {
        switch (id) {
            case 0: return instance.level;
            case 1: return static_cast<int64_t>(instance.fire_sequence);
            case 2: return instance.stack_count;
            case 3: return instance.input_revision;
        }
        return 0;
    };
    for (uint32_t i = 0; i < definition.instruction_count; ++i) {
        const auto &instruction = _catalog.instructions[definition.instruction_begin + i];
        switch (instruction.op) {
            case RuntimeEffectPodInstructionOp::CONST:
                if (depth >= stack.size()) { error = "effect_value_stack_overflow"; return false; }
                stack[depth++] = instruction.value;
                break;
            case RuntimeEffectPodInstructionOp::READ_METRIC:
                if (depth >= stack.size()) { error = "effect_value_stack_overflow"; return false; }
                stack[depth++] = metric(instruction.arg0);
                break;
            case RuntimeEffectPodInstructionOp::READ_STATE:
                if (depth >= stack.size()) { error = "effect_value_stack_overflow"; return false; }
                stack[depth++] = state_value(instruction.arg0);
                break;
            case RuntimeEffectPodInstructionOp::ADD:
            case RuntimeEffectPodInstructionOp::SUB:
            case RuntimeEffectPodInstructionOp::MUL_Q16:
            case RuntimeEffectPodInstructionOp::DIV_FLOOR:
            case RuntimeEffectPodInstructionOp::MIN:
            case RuntimeEffectPodInstructionOp::MAX: {
                if (depth < 2) { error = "effect_value_stack_underflow"; return false; }
                const int64_t rhs = stack[--depth];
                int64_t &lhs = stack[depth - 1u];
                if (instruction.op == RuntimeEffectPodInstructionOp::ADD) lhs += rhs;
                else if (instruction.op == RuntimeEffectPodInstructionOp::SUB) lhs -= rhs;
                else if (instruction.op == RuntimeEffectPodInstructionOp::MUL_Q16)
                    lhs = static_cast<int64_t>((static_cast<long double>(lhs) * rhs) / Q16_ONE);
                else if (instruction.op == RuntimeEffectPodInstructionOp::DIV_FLOOR)
                    lhs = rhs == 0 ? 0 : lhs / rhs;
                else if (instruction.op == RuntimeEffectPodInstructionOp::MIN) lhs = std::min(lhs, rhs);
                else lhs = std::max(lhs, rhs);
                break;
            }
            case RuntimeEffectPodInstructionOp::CLAMP:
                if (depth == 0) { error = "effect_value_stack_underflow"; return false; }
                stack[depth - 1u] = std::clamp(stack[depth - 1u],
                                               static_cast<int64_t>(instruction.arg0),
                                               instruction.value);
                break;
            case RuntimeEffectPodInstructionOp::EMIT_COMMAND: {
                if (instruction.arg0 < 0 ||
                    static_cast<uint32_t>(instruction.arg0) >= definition.command_count) {
                    error = "effect_command_index_invalid";
                    return false;
                }
                const auto &command_definition = _catalog.commands[
                    definition.command_begin + static_cast<uint32_t>(instruction.arg0)];
                int64_t value = 0;
                if (command_definition.value_mode == RuntimeEffectPodValueMode::STACK_TOP) {
                    if (depth == 0) { error = "effect_value_stack_underflow"; return false; }
                    value = stack[--depth];
                }
                RuntimeEffectPodCommand command;
                if (!compile_command(command_definition, instance, value, day,
                                     instance.fire_sequence + 1u,
                                     static_cast<uint32_t>(instruction.arg0), command)) {
                    error = "effect_command_target_invalid";
                    return false;
                }
                commands.push_back(command);
                break;
            }
            case RuntimeEffectPodInstructionOp::END:
                return true;
        }
        if (i >= static_cast<uint32_t>(definition.max_work)) {
            error = "effect_definition_work_exceeded";
            return false;
        }
    }
    return true;
}

bool RuntimeEffectPodAuthority::append_transaction(
        State &state, const RuntimeEffectPodInstance &instance, int64_t day,
        const std::vector<RuntimeEffectPodCommand> &commands,
        RuntimeEffectPodTransaction &transaction, std::string &error) const {
    if (commands.empty()) return false;
    if (state.transactions.size() >= _transaction_capacity ||
        state.command_arena.size() + commands.size() > _command_capacity) {
        error = state.transactions.size() >= _transaction_capacity
            ? "effect_transaction_capacity_exhausted"
            : "effect_command_arena_exhausted";
        return false;
    }
    transaction = RuntimeEffectPodTransaction{};
    transaction.transaction_id = _next_transaction_id;
    transaction.source_instance_id = instance.instance_id;
    transaction.source_generation = instance.generation;
    transaction.effective_day = day;
    transaction.command_begin = static_cast<uint32_t>(state.command_arena.size());
    transaction.command_count = static_cast<uint32_t>(commands.size());
    transaction.status = RuntimeEffectPodTransactionStatus::PREFLIGHTED;
    transaction.fire_sequence = instance.fire_sequence + 1u;
    transaction.input_revision = instance.input_revision;
    for (const auto &command : commands) {
        transaction.required_ack_mask |= adapter_ack_bit(command.action);
        state.command_arena.push_back(command);
    }
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, transaction.source_instance_id);
    hash = mix_value(hash, transaction.source_generation);
    hash = mix_value(hash, transaction.effective_day);
    hash = mix_value(hash, transaction.fire_sequence);
    for (uint32_t i = 0; i < transaction.command_count; ++i)
        hash = command_hash(hash, state.command_arena[transaction.command_begin + i]);
    transaction.plan_hash = hash;
    state.transactions.push_back(transaction);
    return true;
}

uint64_t RuntimeEffectPodAuthority::command_hash(
        uint64_t hash, const RuntimeEffectPodCommand &command) noexcept {
    hash = mix_value(hash, command.action);
    hash = mix_value(hash, command.domain);
    hash = mix_value(hash, command.opcode);
    hash = mix_value(hash, command.source_instance_id);
    hash = mix_value(hash, command.source_generation);
    hash = mix_value(hash, command.source_handle);
    hash = mix_value(hash, command.target_handle);
    hash = mix_value(hash, command.target_generation);
    hash = mix_value(hash, command.value);
    hash = mix_value(hash, command.duration_days);
    hash = mix_value(hash, command.stacks);
    hash = mix_value(hash, command.command_definition_id);
    hash = mix_value(hash, command.command_key_hash);
    hash = mix_value(hash, command.definition_key_hash);
    hash = mix_value(hash, command.idempotency_key);
    hash = mix_value(hash, command.effective_day);
    for (const int64_t value : command.payload) hash = mix_value(hash, value);
    return hash;
}

uint64_t RuntimeEffectPodAuthority::transaction_hash(
        uint64_t hash, const RuntimeEffectPodTransaction &transaction) noexcept {
    hash = mix_value(hash, transaction.transaction_id);
    hash = mix_value(hash, transaction.source_instance_id);
    hash = mix_value(hash, transaction.source_generation);
    hash = mix_value(hash, transaction.effective_day);
    hash = mix_value(hash, transaction.plan_hash);
    hash = mix_value(hash, transaction.command_begin);
    hash = mix_value(hash, transaction.command_count);
    hash = mix_value(hash, transaction.required_ack_mask);
    hash = mix_value(hash, transaction.received_ack_mask);
    hash = mix_value(hash, transaction.status);
    hash = mix_value(hash, transaction.retry_count);
    hash = mix_value(hash, transaction.duplicate_ack_count);
    hash = mix_value(hash, transaction.last_ack_code);
    hash = mix_value(hash, transaction.fire_sequence);
    hash = mix_value(hash, transaction.input_revision);
    hash = mix_value(hash, transaction.transition_stack_count);
    return hash;
}

uint64_t RuntimeEffectPodAuthority::state_hash(const State &state) noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, state.generation);
    hash = mix_value(hash, state.committed_day);
    for (const int64_t value : state.metric_values) hash = mix_value(hash, value);
    for (const int64_t value : state.metric_revisions) hash = mix_value(hash, value);
    for (const auto &instance : state.instances) {
        hash = mix_value(hash, instance.instance_id);
        hash = mix_value(hash, instance.generation);
        hash = mix_value(hash, instance.program_id);
        hash = mix_value(hash, instance.source_type);
        hash = mix_value(hash, instance.source_id);
        hash = mix_value(hash, instance.source_handle);
        hash = mix_value(hash, instance.target_handle);
        hash = mix_value(hash, instance.target_generation);
        hash = mix_value(hash, instance.level);
        hash = mix_value(hash, instance.metric_base);
        hash = mix_value(hash, instance.input_revision);
        hash = mix_value(hash, instance.last_evaluated_input_revision);
        hash = mix_value(hash, instance.next_due_day);
        hash = mix_value(hash, instance.cadence_days);
        hash = mix_value(hash, instance.lifecycle);
        hash = mix_value(hash, instance.stack_policy);
        hash = mix_value(hash, instance.stack_count);
        hash = mix_value(hash, instance.applied_stack_count);
        hash = mix_value(hash, instance.max_stacks);
        hash = mix_value(hash, instance.expires_day);
        hash = mix_value(hash, instance.stack_key_hash);
        hash = mix_value(hash, instance.fire_sequence);
        hash = mix_value(hash, instance.pending_transaction_id);
        hash = mix_value(hash, instance.pending_idempotency_key);
        hash = mix_value(hash, instance.last_acked_fire_sequence);
        hash = mix_value(hash, instance.active);
        hash = mix_value(hash, instance.retire_requested);
        hash = mix_value(hash, instance.needs_resync);
    }
    for (const auto &command : state.command_arena) hash = command_hash(hash, command);
    for (const auto &transaction : state.transactions)
        hash = transaction_hash(hash, transaction);
    return hash;
}

bool RuntimeEffectPodAuthority::command_less(
        const RuntimeEffectPodCommand &a,
        const RuntimeEffectPodCommand &b) noexcept {
    if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
    if (a.source_instance_id != b.source_instance_id)
        return a.source_instance_id < b.source_instance_id;
    if (a.idempotency_key != b.idempotency_key)
        return a.idempotency_key < b.idempotency_key;
    if (a.action != b.action) return static_cast<uint8_t>(a.action) < static_cast<uint8_t>(b.action);
    if (a.domain != b.domain) return a.domain < b.domain;
    return a.opcode < b.opcode;
}

bool RuntimeEffectPodAuthority::ack_matches(
        const RuntimeDomainAck &ack,
        const RuntimeEffectPodCommand &command) noexcept {
    const uint16_t expected_domain = adapter_domain(command.action);
    if (ack.domain != expected_domain && ack.domain != static_cast<uint16_t>(
            std::max(0, command.domain))) return false;
    if (ack.effective_day != command.effective_day) return false;
    if (ack.target_handle != 0 && ack.target_handle != command.target_handle) return false;
    if (ack.target_generation != 0 && ack.target_generation != command.target_generation)
        return false;
    return true;
}

bool RuntimeEffectPodAuthority::finite_or_zero(int64_t) noexcept {
    return true;
}

void RuntimeEffectPodAuthority::build_snapshot(const State &state,
                                               RuntimeEffectPodSnapshot &out) const {
    out = RuntimeEffectPodSnapshot{};
    out.abi_version = RUNTIME_EFFECT_POD_ABI_VERSION;
    out.catalog_version = RUNTIME_EFFECT_POD_CATALOG_VERSION;
    out.catalog_hash = _catalog.catalog_hash;
    out.catalog_revision = _catalog_revision;
    out.generation = state.generation;
    out.deterministic_state_hash = state.deterministic_state_hash;
    out.committed_day = state.committed_day;
    out.metric_values = state.metric_values;
    out.metric_revisions = state.metric_revisions;
    out.instances = state.instances;
    out.command_arena = state.command_arena;
    out.transactions = state.transactions;
}

void RuntimeEffectPodAuthority::rebuild_report(const RuntimeEffectPodPlan *plan) {
    _report = RuntimeEffectPodReport{};
    _report.catalog_hash = _catalog.catalog_hash;
    _report.generation = _current.generation;
    _report.deterministic_state_hash = _current.deterministic_state_hash;
    _report.committed_day = _current.committed_day;
    _report.instance_count = static_cast<uint32_t>(_current.instances.size());
    _report.transaction_count = static_cast<uint32_t>(_current.transactions.size());
    _report.configured = _configured ? 1 : 0;
    _report.plan_ready = _plan_ready ? 1 : 0;
    for (const auto &transaction : _current.transactions) {
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED)
            ++_report.acked_transaction_count;
        else if (transaction.status == RuntimeEffectPodTransactionStatus::REJECTED)
            ++_report.rejected_transaction_count;
        else if (transaction.status == RuntimeEffectPodTransactionStatus::RESYNC_REQUIRED)
            ++_report.resync_required_count;
        else
            ++_report.pending_transaction_count;
        _report.retry_count += transaction.retry_count;
        _report.duplicate_ack_count += transaction.duplicate_ack_count;
        _report.emitted_command_count += transaction.command_count;
    }
    if (plan != nullptr) {
        _report.deterministic_plan_hash = plan->deterministic_plan_hash;
        _report.emitted_command_count = plan->emitted_command_count;
        _report.plan_ready = 1;
    }
}

bool RuntimeEffectPodAuthority::plan_day(int64_t day, uint64_t input_generation,
                                         RuntimeEffectPodPlan &plan,
                                         std::string &error) {
    error.clear();
    plan = RuntimeEffectPodPlan{};
    if (!_configured) { error = "effect_pod_not_configured"; set_blocker(error.c_str()); return false; }
    if (day < 0 || input_generation == 0 ||
        (_current.committed_day >= 0 && day != _current.committed_day + 1)) {
        error = _current.committed_day >= 0 ? "effect_pod_day_not_sequential"
                                            : "effect_pod_context_invalid";
        set_blocker(error.c_str());
        return false;
    }
    if (_plan_ready) { error = "effect_pod_plan_already_pending"; set_blocker(error.c_str()); return false; }
    _next = _current;
    std::vector<RuntimeEffectPodCommand> emitted;
    emitted.reserve(std::min<uint32_t>(_command_capacity, 4096u));
    plan.base_generation = _current.generation;
    plan.input_generation = input_generation;
    uint64_t plan_hash = FNV_OFFSET;
    plan_hash = mix_value(plan_hash, day);
    plan_hash = mix_value(plan_hash, input_generation);
    plan_hash = mix_value(plan_hash, _current.generation);

    for (size_t instance_index_value = 0;
         instance_index_value < _next.instances.size(); ++instance_index_value) {
        RuntimeEffectPodInstance &instance = _next.instances[instance_index_value];
        if (instance.active == 0) continue;
        if (instance.expires_day >= 0 && instance.expires_day <= day) {
            instance.active = 0;
            if (instance.pending_transaction_id == 0) continue;
        }
        if (instance.pending_transaction_id != 0) {
            int32_t tx_index = -1;
            for (size_t i = 0; i < _next.transactions.size(); ++i) {
                if (_next.transactions[i].transaction_id == instance.pending_transaction_id) {
                    tx_index = static_cast<int32_t>(i);
                    break;
                }
            }
            if (tx_index >= 0 && _next.transactions[static_cast<size_t>(tx_index)].status ==
                    RuntimeEffectPodTransactionStatus::PLANNED) {
                auto &transaction = _next.transactions[static_cast<size_t>(tx_index)];
                transaction.status = RuntimeEffectPodTransactionStatus::PREFLIGHTED;
                ++plan.retried_transaction_count;
                plan.required_ack_mask |= transaction.required_ack_mask;
                for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
                    if (transaction.command_begin + ordinal >= _next.command_arena.size()) {
                        error = "effect_pod_transaction_command_offset_invalid";
                        set_blocker(error.c_str());
                        return false;
                    }
                    const auto &command = _next.command_arena[transaction.command_begin + ordinal];
                    emitted.push_back(command);
                    RuntimeDomainIntent intent;
                    intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
                    intent.target_domain = adapter_domain(command.action);
                    intent.opcode = static_cast<uint16_t>(command.opcode);
                    intent.effect_action = static_cast<uint16_t>(command.action);
                    intent.source_id = static_cast<uint64_t>(command.source_instance_id);
                    intent.target_handle = command.target_handle;
                    intent.target_generation = command.target_generation;
                    intent.value = command.value;
                    intent.effective_day = command.effective_day;
                    intent.payload = command.payload;
                    intent.request_id = static_cast<uint64_t>(transaction.transaction_id);
                    intent.producer_id = static_cast<uint32_t>(RuntimeDomainId::EFFECT);
                    intent.sequence = transaction.fire_sequence * 16u + ordinal;
                    intent.idempotency_key = command.idempotency_key;
                    plan.intents.push_back(intent);
                    plan_hash = command_hash(plan_hash, command);
                }
            }
            continue;
        }
        if (instance.next_due_day < 0 || instance.next_due_day > day) continue;
        if (instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_catalog.definitions.size())) {
            error = "effect_pod_program_invalid";
            set_blocker(error.c_str());
            return false;
        }
        const auto &definition = _catalog.definitions[static_cast<size_t>(instance.program_id)];
        if (definition.enabled == 0) {
            instance.next_due_day = day + definition.cadence_days;
            continue;
        }
        if (!evaluate_conditions(definition, instance, _current)) {
            instance.last_evaluated_input_revision = instance.input_revision;
            instance.next_due_day = day + definition.cadence_days;
            continue;
        }
        emitted.clear();
        if (!execute_program(definition, instance, _current, day, emitted, error)) {
            set_blocker(error.c_str());
            return false;
        }
        if (emitted.empty()) {
            instance.last_evaluated_input_revision = instance.input_revision;
            instance.next_due_day = day + definition.cadence_days;
            continue;
        }
        std::stable_sort(emitted.begin(), emitted.end(), command_less);
        RuntimeEffectPodTransaction transaction;
        if (!append_transaction(_next, instance, day, emitted, transaction, error)) {
            set_blocker(error.c_str());
            return false;
        }
        ++_next_transaction_id;
        instance.fire_sequence += 1u;
        instance.pending_transaction_id = transaction.transaction_id;
        instance.pending_idempotency_key = emitted.front().idempotency_key;
        instance.last_evaluated_input_revision = instance.input_revision;
        instance.next_due_day = day + definition.cadence_days;
        instance.expires_day = definition.lifecycle == RuntimeEffectPodLifecycle::DURATION
            ? day + definition.duration_days : -1;
        plan.required_ack_mask |= transaction.required_ack_mask;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const auto &command = _next.command_arena[transaction.command_begin + ordinal];
            RuntimeDomainIntent intent;
            intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
            intent.target_domain = adapter_domain(command.action);
            intent.opcode = static_cast<uint16_t>(command.opcode);
            intent.effect_action = static_cast<uint16_t>(command.action);
            intent.source_id = static_cast<uint64_t>(command.source_instance_id);
            intent.target_handle = command.target_handle;
            intent.target_generation = command.target_generation;
            intent.value = command.value;
            intent.effective_day = command.effective_day;
            intent.payload = command.payload;
            intent.request_id = static_cast<uint64_t>(transaction.transaction_id);
            intent.producer_id = static_cast<uint32_t>(RuntimeDomainId::EFFECT);
            intent.sequence = transaction.fire_sequence * 16u + ordinal;
            intent.idempotency_key = command.idempotency_key;
            plan.intents.push_back(intent);
            plan_hash = command_hash(plan_hash, command);
        }
    }
    _next.generation = _current.generation + 1u;
    _next.committed_day = day;
    _next.deterministic_state_hash = state_hash(_next);
    plan.deterministic_plan_hash = plan_hash;
    plan.next_snapshot = RuntimeEffectPodSnapshot{};
    build_snapshot(_next, plan.next_snapshot);
    plan.emitted_command_count = static_cast<uint32_t>(plan.intents.size());
    plan.preflight_ok = 1;
    _active_plan = &plan;
    _plan_ready = true;
    rebuild_report(&plan);
    return true;
}

bool RuntimeEffectPodAuthority::commit_day(RuntimeEffectPodPlan &plan,
                                            std::string &error) {
    error.clear();
    if (!_plan_ready || _active_plan != &plan || plan.preflight_ok == 0) {
        error = "effect_pod_plan_missing";
        return false;
    }
    if (plan.base_generation != _current.generation ||
        plan.next_snapshot.catalog_hash != _catalog.catalog_hash ||
        plan.next_snapshot.generation != _next.generation) {
        error = "effect_pod_plan_generation_mismatch";
        _plan_ready = false;
        _active_plan = nullptr;
        return false;
    }
    for (auto &transaction : _next.transactions) {
        if (transaction.status == RuntimeEffectPodTransactionStatus::PREFLIGHTED)
            transaction.status = RuntimeEffectPodTransactionStatus::COMMITTED;
    }
    _next.deterministic_state_hash = state_hash(_next);
    _current = std::move(_next);
    _next = State{};
    build_snapshot(_current, _snapshot);
    plan.next_snapshot = _snapshot;
    plan.committed = 1;
    _plan_ready = false;
    _active_plan = nullptr;
    rebuild_report();
    return true;
}

void RuntimeEffectPodAuthority::discard_plan() {
    _active_plan = nullptr;
    _plan_ready = false;
    _next = _current;
    rebuild_report();
}

bool RuntimeEffectPodAuthority::apply_ack(const RuntimeDomainAck &ack,
                                          std::string &error) {
    error.clear();
    if (!_configured) { error = "effect_pod_not_configured"; return false; }
    const int32_t tx_index = transaction_index(static_cast<int64_t>(ack.transaction_id));
    if (tx_index < 0) { error = "effect_pod_ack_transaction_unknown"; return false; }
    auto &transaction = _current.transactions[static_cast<size_t>(tx_index)];
    bool matched = false;
    uint32_t matched_bit = 0;
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const size_t command_index = static_cast<size_t>(transaction.command_begin) + ordinal;
        if (command_index >= _current.command_arena.size()) continue;
        const auto &command = _current.command_arena[command_index];
        if (ack_matches(ack, command)) {
            matched = true;
            matched_bit |= adapter_ack_bit(command.action);
        }
    }
    if (!matched) { error = "effect_pod_ack_command_mismatch"; return false; }
    transaction.last_ack_code = static_cast<uint16_t>(ack.code);
    if (ack.code == RuntimeDomainAckCode::OK) {
        if ((transaction.received_ack_mask & matched_bit) != 0u) {
            ++transaction.duplicate_ack_count;
            _current.deterministic_state_hash = state_hash(_current);
            build_snapshot(_current, _snapshot);
            rebuild_report();
            return true;
        }
        transaction.received_ack_mask |= matched_bit;
        if ((transaction.received_ack_mask & transaction.required_ack_mask) ==
                transaction.required_ack_mask) {
            transaction.status = RuntimeEffectPodTransactionStatus::ACKED;
            const int32_t instance_index_value = instance_index(
                transaction.source_instance_id, transaction.source_generation);
            if (instance_index_value >= 0) {
                auto &instance = _current.instances[static_cast<size_t>(instance_index_value)];
                instance.pending_transaction_id = 0;
                instance.pending_idempotency_key = 0;
                instance.applied_stack_count = instance.stack_count;
                instance.last_acked_fire_sequence = transaction.fire_sequence;
                if (instance.retire_requested) instance.active = 0;
            }
        }
    } else if (ack.code == RuntimeDomainAckCode::RETRY) {
        transaction.status = RuntimeEffectPodTransactionStatus::PLANNED;
        ++transaction.retry_count;
    } else if (ack.code == RuntimeDomainAckCode::REJECTED) {
        transaction.status = RuntimeEffectPodTransactionStatus::REJECTED;
        const int32_t instance_index_value = instance_index(
            transaction.source_instance_id, transaction.source_generation);
        if (instance_index_value >= 0)
            _current.instances[static_cast<size_t>(instance_index_value)].pending_transaction_id = 0;
    } else if (ack.code == RuntimeDomainAckCode::STALE_GENERATION) {
        transaction.status = RuntimeEffectPodTransactionStatus::RESYNC_REQUIRED;
        const int32_t instance_index_value = instance_index(
            transaction.source_instance_id, transaction.source_generation);
        if (instance_index_value >= 0)
            _current.instances[static_cast<size_t>(instance_index_value)].needs_resync = 1;
    }
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

bool RuntimeEffectPodAuthority::apply_acks(
        const std::vector<RuntimeDomainAck> &acks, std::string &error) {
    for (const auto &ack : acks) {
        if (!apply_ack(ack, error)) return false;
    }
    return true;
}

bool RuntimeEffectPodAuthority::snapshot(RuntimeEffectPodSnapshot &out,
                                         std::string &error) const {
    error.clear();
    if (!_configured) { error = "effect_pod_not_configured"; return false; }
    out = _snapshot;
    return true;
}

void RuntimeEffectPodAuthority::serialize(std::vector<uint8_t> &out) const {
    // Adapter request IDs are intentionally not persisted. Any transaction
    // that was in flight at the save barrier must be replayable after restart,
    // so native-bound PREFLIGHTED/COMMITTED states are encoded as PLANNED
    // while retaining their command arena, ACK mask, plan hash, and keys.
    State persisted = _current;
    for (auto &transaction : persisted.transactions) {
        if (transaction.status == RuntimeEffectPodTransactionStatus::PREFLIGHTED ||
            transaction.status == RuntimeEffectPodTransactionStatus::COMMITTED) {
            transaction.status = RuntimeEffectPodTransactionStatus::PLANNED;
        }
    }
    persisted.deterministic_state_hash = state_hash(persisted);
    out.clear();
    out.reserve(256 + persisted.instances.size() * 128u +
                persisted.command_arena.size() * 192u +
                persisted.transactions.size() * 96u);
    append_le<uint32_t>(out, SAVE_MAGIC);
    append_le<uint32_t>(out, RUNTIME_EFFECT_POD_ABI_VERSION);
    append_le<uint32_t>(out, RUNTIME_EFFECT_POD_CATALOG_VERSION);
    append_le<uint64_t>(out, _catalog.catalog_hash);
    append_le<uint64_t>(out, _catalog_revision);
    append_le<int64_t>(out, _next_transaction_id);
    append_le<uint64_t>(out, persisted.generation);
    append_le<uint64_t>(out, persisted.deterministic_state_hash);
    append_le<int64_t>(out, persisted.committed_day);
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.metric_values.size()));
    for (const int64_t value : persisted.metric_values) append_le<int64_t>(out, value);
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.metric_revisions.size()));
    for (const int64_t value : persisted.metric_revisions) append_le<int64_t>(out, value);
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.instances.size()));
    for (const auto &instance : persisted.instances) {
        append_le<int64_t>(out, instance.instance_id);
        append_le<uint32_t>(out, instance.generation);
        append_le<int32_t>(out, instance.program_id);
        append_le<int32_t>(out, instance.source_type);
        append_le<int64_t>(out, instance.source_id);
        append_le<uint64_t>(out, instance.source_handle);
        append_le<uint64_t>(out, instance.target_handle);
        append_le<uint32_t>(out, instance.target_generation);
        append_le<int32_t>(out, instance.level);
        append_le<uint32_t>(out, instance.metric_base);
        append_le<int64_t>(out, instance.input_revision);
        append_le<int64_t>(out, instance.last_evaluated_input_revision);
        append_le<int64_t>(out, instance.next_due_day);
        append_le<int32_t>(out, instance.cadence_days);
        append_le<uint8_t>(out, static_cast<uint8_t>(instance.lifecycle));
        append_le<uint8_t>(out, static_cast<uint8_t>(instance.stack_policy));
        append_le<int32_t>(out, instance.stack_count);
        append_le<int32_t>(out, instance.applied_stack_count);
        append_le<int32_t>(out, instance.max_stacks);
        append_le<int64_t>(out, instance.expires_day);
        append_le<uint64_t>(out, instance.stack_key_hash);
        append_le<uint64_t>(out, instance.fire_sequence);
        append_le<int64_t>(out, instance.pending_transaction_id);
        append_le<uint64_t>(out, instance.pending_idempotency_key);
        append_le<uint64_t>(out, instance.last_acked_fire_sequence);
        append_le<uint8_t>(out, instance.active);
        append_le<uint8_t>(out, instance.retire_requested);
        append_le<uint8_t>(out, instance.needs_resync);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.command_arena.size()));
    for (const auto &command : persisted.command_arena) {
        append_le<uint8_t>(out, static_cast<uint8_t>(command.action));
        append_le<int32_t>(out, command.domain);
        append_le<int32_t>(out, command.opcode);
        append_le<uint64_t>(out, command.source_instance_id);
        append_le<uint32_t>(out, command.source_generation);
        append_le<uint64_t>(out, command.source_handle);
        append_le<uint64_t>(out, command.target_handle);
        append_le<uint32_t>(out, command.target_generation);
        append_le<int64_t>(out, command.value);
        append_le<int32_t>(out, command.duration_days);
        append_le<int32_t>(out, command.stacks);
        append_le<uint32_t>(out, command.command_definition_id);
        append_le<uint64_t>(out, command.command_key_hash);
        append_le<uint64_t>(out, command.definition_key_hash);
        append_le<uint64_t>(out, command.idempotency_key);
        append_le<int64_t>(out, command.effective_day);
        for (const int64_t value : command.payload) append_le<int64_t>(out, value);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.transactions.size()));
    for (const auto &transaction : persisted.transactions) {
        append_le<int64_t>(out, transaction.transaction_id);
        append_le<int64_t>(out, transaction.source_instance_id);
        append_le<uint32_t>(out, transaction.source_generation);
        append_le<int64_t>(out, transaction.effective_day);
        append_le<uint64_t>(out, transaction.plan_hash);
        append_le<uint32_t>(out, transaction.command_begin);
        append_le<uint32_t>(out, transaction.command_count);
        append_le<uint32_t>(out, transaction.required_ack_mask);
        append_le<uint32_t>(out, transaction.received_ack_mask);
        append_le<uint8_t>(out, static_cast<uint8_t>(transaction.status));
        append_le<uint8_t>(out, transaction.retry_count);
        append_le<uint8_t>(out, transaction.duplicate_ack_count);
        append_le<uint16_t>(out, transaction.last_ack_code);
        append_le<uint64_t>(out, transaction.fire_sequence);
        append_le<int64_t>(out, transaction.input_revision);
        append_le<int32_t>(out, transaction.transition_stack_count);
    }
    append_le<uint32_t>(out, SAVE_END);
    const uint64_t checksum = mix_bytes(FNV_OFFSET, out.data(), out.size());
    append_le<uint64_t>(out, checksum);
}

bool RuntimeEffectPodAuthority::restore(const uint8_t *data, size_t size,
                                        std::string &error) {
    error.clear();
    if (!_configured || data == nullptr || size < 64u || size > MAX_SAVE_BYTES) {
        error = !_configured ? "effect_pod_not_configured" : "effect_pod_save_invalid";
        return false;
    }
    if (std::memcmp(data, "EFP1", 4) != 0) {
        error = "effect_pod_save_marker_invalid";
        return false;
    }
    uint64_t encoded_checksum = 0;
    size_t checksum_cursor = size - sizeof(uint64_t);
    if (!read_le(data, size, checksum_cursor, encoded_checksum) ||
        mix_bytes(FNV_OFFSET, data, size - sizeof(uint64_t)) != encoded_checksum) {
        error = "effect_pod_save_checksum_failed";
        return false;
    }
    const size_t payload_end = size - sizeof(uint64_t);
    size_t cursor = 0;
    uint32_t magic = 0, abi = 0, catalog_version = 0;
    uint64_t catalog_hash_value = 0, catalog_revision = 0;
    int64_t next_transaction_id = 0, committed_day = -1;
    uint64_t generation = 0, saved_state_hash = 0;
    if (!read_le(data, payload_end, cursor, magic) ||
        !read_le(data, payload_end, cursor, abi) ||
        !read_le(data, payload_end, cursor, catalog_version) ||
        !read_le(data, payload_end, cursor, catalog_hash_value) ||
        !read_le(data, payload_end, cursor, catalog_revision) ||
        !read_le(data, payload_end, cursor, next_transaction_id) ||
        !read_le(data, payload_end, cursor, generation) ||
        !read_le(data, payload_end, cursor, saved_state_hash) ||
        !read_le(data, payload_end, cursor, committed_day) ||
        magic != SAVE_MAGIC || abi != RUNTIME_EFFECT_POD_ABI_VERSION ||
        catalog_version != RUNTIME_EFFECT_POD_CATALOG_VERSION ||
        catalog_hash_value != _catalog.catalog_hash || next_transaction_id <= 0) {
        error = "effect_pod_save_header_invalid";
        return false;
    }
    State restored;
    restored.generation = generation;
    restored.committed_day = committed_day;
    uint32_t count = 0;
    if (!read_count(data, payload_end, cursor, count, RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA)) {
        error = "effect_pod_metric_count_invalid"; return false;
    }
    restored.metric_values.resize(count);
    for (int64_t &value : restored.metric_values)
        if (!read_le(data, payload_end, cursor, value)) { error = "effect_pod_metric_truncated"; return false; }
    if (!read_count(data, payload_end, cursor, count, RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA)) {
        error = "effect_pod_metric_revision_count_invalid"; return false;
    }
    restored.metric_revisions.resize(count);
    for (int64_t &value : restored.metric_revisions)
        if (!read_le(data, payload_end, cursor, value)) { error = "effect_pod_metric_revision_truncated"; return false; }
    if (restored.metric_revisions.size() != restored.metric_values.size()) {
        error = "effect_pod_metric_slab_shape_invalid"; return false;
    }
    if (!read_count(data, payload_end, cursor, count, _instance_capacity)) {
        error = "effect_pod_instance_count_invalid"; return false;
    }
    restored.instances.resize(count);
    for (auto &instance : restored.instances) {
        if (!read_le(data,payload_end,cursor,instance.instance_id) ||
            !read_le(data,payload_end,cursor,instance.generation) ||
            !read_le(data,payload_end,cursor,instance.program_id) ||
            !read_le(data,payload_end,cursor,instance.source_type) ||
            !read_le(data,payload_end,cursor,instance.source_id) ||
            !read_le(data,payload_end,cursor,instance.source_handle) ||
            !read_le(data,payload_end,cursor,instance.target_handle) ||
            !read_le(data,payload_end,cursor,instance.target_generation) ||
            !read_le(data,payload_end,cursor,instance.level) ||
            !read_le(data,payload_end,cursor,instance.metric_base) ||
            !read_le(data,payload_end,cursor,instance.input_revision) ||
            !read_le(data,payload_end,cursor,instance.last_evaluated_input_revision) ||
            !read_le(data,payload_end,cursor,instance.next_due_day) ||
            !read_le(data,payload_end,cursor,instance.cadence_days) ||
            !read_le(data,payload_end,cursor,instance.lifecycle) ||
            !read_le(data,payload_end,cursor,instance.stack_policy) ||
            !read_le(data,payload_end,cursor,instance.stack_count) ||
            !read_le(data,payload_end,cursor,instance.applied_stack_count) ||
            !read_le(data,payload_end,cursor,instance.max_stacks) ||
            !read_le(data,payload_end,cursor,instance.expires_day) ||
            !read_le(data,payload_end,cursor,instance.stack_key_hash) ||
            !read_le(data,payload_end,cursor,instance.fire_sequence) ||
            !read_le(data,payload_end,cursor,instance.pending_transaction_id) ||
            !read_le(data,payload_end,cursor,instance.pending_idempotency_key) ||
            !read_le(data,payload_end,cursor,instance.last_acked_fire_sequence) ||
            !read_le(data,payload_end,cursor,instance.active) ||
            !read_le(data,payload_end,cursor,instance.retire_requested) ||
            !read_le(data,payload_end,cursor,instance.needs_resync) ||
            instance.instance_id <= 0 || instance.generation == 0 ||
            instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            instance.target_handle == 0 || instance.target_generation == 0 ||
            instance.metric_base > restored.metric_values.size()) {
            error = "effect_pod_instance_truncated_or_invalid"; return false;
        }
        if (instance.metric_base + _catalog.metric_key_hashes.size() >
                restored.metric_values.size()) {
            error = "effect_pod_instance_metric_range_invalid"; return false;
        }
    }
    if (!read_count(data, payload_end, cursor, count, _command_capacity)) {
        error = "effect_pod_command_count_invalid"; return false;
    }
    restored.command_arena.resize(count);
    for (auto &command : restored.command_arena) {
        if (!read_le(data,payload_end,cursor,command.action) ||
            !read_le(data,payload_end,cursor,command.domain) ||
            !read_le(data,payload_end,cursor,command.opcode) ||
            !read_le(data,payload_end,cursor,command.source_instance_id) ||
            !read_le(data,payload_end,cursor,command.source_generation) ||
            !read_le(data,payload_end,cursor,command.source_handle) ||
            !read_le(data,payload_end,cursor,command.target_handle) ||
            !read_le(data,payload_end,cursor,command.target_generation) ||
            !read_le(data,payload_end,cursor,command.value) ||
            !read_le(data,payload_end,cursor,command.duration_days) ||
            !read_le(data,payload_end,cursor,command.stacks) ||
            !read_le(data,payload_end,cursor,command.command_definition_id) ||
            !read_le(data,payload_end,cursor,command.command_key_hash) ||
            !read_le(data,payload_end,cursor,command.definition_key_hash) ||
            !read_le(data,payload_end,cursor,command.idempotency_key) ||
            !read_le(data,payload_end,cursor,command.effective_day) ||
            !read_le(data,payload_end,cursor,command.payload[0]) ||
            !read_le(data,payload_end,cursor,command.payload[1]) ||
            !read_le(data,payload_end,cursor,command.payload[2]) ||
            !read_le(data,payload_end,cursor,command.payload[3]) ||
            !is_action_valid(command.action) || command.target_handle == 0 ||
            command.target_generation == 0 || command.idempotency_key == 0 ||
            command.command_definition_id >= _catalog.commands.size()) {
            error = "effect_pod_command_truncated_or_invalid"; return false;
        }
    }
    if (!read_count(data, payload_end, cursor, count, _transaction_capacity)) {
        error = "effect_pod_transaction_count_invalid"; return false;
    }
    restored.transactions.resize(count);
    for (auto &transaction : restored.transactions) {
        if (!read_le(data,payload_end,cursor,transaction.transaction_id) ||
            !read_le(data,payload_end,cursor,transaction.source_instance_id) ||
            !read_le(data,payload_end,cursor,transaction.source_generation) ||
            !read_le(data,payload_end,cursor,transaction.effective_day) ||
            !read_le(data,payload_end,cursor,transaction.plan_hash) ||
            !read_le(data,payload_end,cursor,transaction.command_begin) ||
            !read_le(data,payload_end,cursor,transaction.command_count) ||
            !read_le(data,payload_end,cursor,transaction.required_ack_mask) ||
            !read_le(data,payload_end,cursor,transaction.received_ack_mask) ||
            !read_le(data,payload_end,cursor,transaction.status) ||
            !read_le(data,payload_end,cursor,transaction.retry_count) ||
            !read_le(data,payload_end,cursor,transaction.duplicate_ack_count) ||
            !read_le(data,payload_end,cursor,transaction.last_ack_code) ||
            !read_le(data,payload_end,cursor,transaction.fire_sequence) ||
            !read_le(data,payload_end,cursor,transaction.input_revision) ||
            !read_le(data,payload_end,cursor,transaction.transition_stack_count) ||
            transaction.transaction_id <= 0 ||
            transaction.command_begin > restored.command_arena.size() ||
            transaction.command_count > restored.command_arena.size() - transaction.command_begin ||
            transaction.required_ack_mask == 0 ||
            (transaction.received_ack_mask & ~transaction.required_ack_mask) != 0u) {
            error = "effect_pod_transaction_truncated_or_invalid"; return false;
        }
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED &&
            transaction.received_ack_mask != transaction.required_ack_mask) {
            error = "effect_pod_transaction_ack_mask_invalid"; return false;
        }
    }
    uint32_t end_marker = 0;
    if (!read_le(data, payload_end, cursor, end_marker) || end_marker != SAVE_END ||
        cursor != payload_end) {
        error = "effect_pod_save_trailing_bytes"; return false;
    }
    restored.deterministic_state_hash = state_hash(restored);
    if (restored.deterministic_state_hash != saved_state_hash) {
        error = "effect_pod_save_state_hash_failed";
        return false;
    }
    for (const auto &transaction : restored.transactions) {
        const int32_t index = [&]() {
            for (size_t i = 0; i < restored.instances.size(); ++i)
                if (restored.instances[i].instance_id == transaction.source_instance_id &&
                    restored.instances[i].generation == transaction.source_generation)
                    return static_cast<int32_t>(i);
            return -1;
        }();
        if (index < 0) { error = "effect_pod_transaction_instance_missing"; return false; }
    }
    // Install only after the complete candidate has passed every check.
    _catalog_revision = catalog_revision;
    _next_transaction_id = next_transaction_id;
    _current = std::move(restored);
    _next = _current;
    build_snapshot(_current, _snapshot);
    _plan_ready = false;
    _active_plan = nullptr;
    rebuild_report();
    return true;
}

bool RuntimeEffectPodAuthority::self_test(std::string &error) {
    error.clear();
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {hash_text("metric")};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = hash_text("fixture");
    definition.cadence_days = 1;
    definition.max_work = 64;
    definition.instruction_begin = 0;
    definition.instruction_count = 12;
    definition.command_begin = 0;
    definition.command_count = 6;
    catalog.definitions.push_back(definition);
    const std::array<RuntimeEffectPodCommandDefinition, 6> command_definitions{
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::MODIFIER_COMMAND, 0, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("modifier"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::COUNTRY_COMMAND, 1, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("country"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::ECONOMY_COMMAND, 2, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("economy"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::GAMEPLAY_COMMAND, 3, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("gameplay"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::PUBLISH_EVENT, 4, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("event"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::CUSTOM_DOMAIN_COMMAND, 6, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("custom"), 0, {}},
    };
    catalog.commands.assign(command_definitions.begin(), command_definitions.end());
    for (uint32_t i = 0; i < 6; ++i) {
        RuntimeEffectPodInstruction constant;
        constant.op = RuntimeEffectPodInstructionOp::CONST;
        constant.value = Q16_ONE;
        catalog.instructions.push_back(constant);
        RuntimeEffectPodInstruction emit;
        emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
        emit.arg0 = static_cast<int32_t>(i);
        catalog.instructions.push_back(emit);
    }
    RuntimeEffectPodAuthority authority;
    if (!authority.configure(catalog, error)) return false;
    RuntimeEffectPodInstanceInput input;
    input.instance_id = 1;
    input.generation = 2;
    input.program_id = 0;
    input.source_handle = 9;
    input.target_handle = 99;
    input.target_generation = 3;
    if (!authority.upsert_instance(input, error)) return false;
    if (!authority.set_metric(1, 2, 0, 1, 7, error)) return false;
    RuntimeEffectPodPlan plan;
    if (!authority.plan_day(0, 1, plan, error) || plan.intents.size() != 6u ||
        plan.required_ack_mask != 0x3fu || plan.deterministic_plan_hash == 0)
        return fail("effect_self_test_initial_plan_failed");
    const int64_t transaction_id = plan.next_snapshot.transactions.front().transaction_id;
    if (!authority.commit_day(plan, error)) return false;
    RuntimeDomainAck first;
    first.transaction_id = static_cast<uint64_t>(transaction_id);
    first.target_handle = 99;
    first.target_generation = 3;
    first.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    first.effective_day = 0;
    if (!authority.apply_ack(first, error)) return false;
    if (authority.snapshot().transactions.front().received_ack_mask != 1u)
        return fail("effect_self_test_first_ack_failed");
    if (!authority.apply_ack(first, error) ||
        authority.snapshot().transactions.front().duplicate_ack_count != 1u) {
        error = "effect_self_test_duplicate_ack_failed:" +
            std::to_string(authority.snapshot().transactions.front().received_ack_mask) +
            ":" + std::to_string(authority.snapshot().transactions.front().duplicate_ack_count) +
            ":" + std::to_string(static_cast<int>(authority.snapshot().transactions.front().status)) +
            ":" + error;
        return false;
    }
    RuntimeDomainAck retry = first;
    retry.code = RuntimeDomainAckCode::RETRY;
    if (!authority.apply_ack(retry, error) ||
        authority.snapshot().transactions.front().status != RuntimeEffectPodTransactionStatus::PLANNED)
        return fail("effect_self_test_retry_failed");
    RuntimeEffectPodPlan retry_plan;
    if (!authority.plan_day(1, 2, retry_plan, error) || retry_plan.intents.size() != 6u ||
        !authority.commit_day(retry_plan, error)) return fail("effect_self_test_retry_plan_failed");
    for (const RuntimeEffectPodCommand &command : authority.snapshot().command_arena) {
        RuntimeDomainAck ack;
        ack.transaction_id = static_cast<uint64_t>(transaction_id);
        ack.target_handle = command.target_handle;
        ack.target_generation = command.target_generation;
        ack.domain = adapter_domain(command.action);
        ack.effective_day = command.effective_day;
        if (!authority.apply_ack(ack, error)) return false;
    }
    if (authority.snapshot().transactions.front().status != RuntimeEffectPodTransactionStatus::ACKED)
        return fail("effect_self_test_final_ack_failed");
    std::vector<uint8_t> bytes;
    authority.serialize(bytes);
    RuntimeEffectPodAuthority restored;
    if (!restored.configure(catalog, error) || !restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().deterministic_state_hash != authority.snapshot().deterministic_state_hash)
        return fail("effect_self_test_save_roundtrip_failed");
    const uint64_t before = restored.snapshot().deterministic_state_hash;
    bytes.back() ^= 0x5a;
    if (restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().deterministic_state_hash != before)
        return fail("effect_self_test_corrupt_restore_mutated_state");
    return true;
}

} // namespace pk

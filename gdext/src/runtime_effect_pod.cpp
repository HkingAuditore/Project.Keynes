#include "runtime_effect_pod.h"
#include "effect_magnitude.h"
#include "runtime_text_hash.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <type_traits>
#include <unordered_map>

namespace pk {
namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;
constexpr uint32_t MAX_SAVE_BYTES = 64u * 1024u * 1024u;
constexpr uint32_t SAVE_MAGIC = 0x31504645u; // EFP1
constexpr uint32_t SAVE_END = 0x21444e45u; // END!
constexpr int32_t Q16_ONE = 65536;

// Which target fields may legitimately be zero, per compiled target_domain.
//
// Both conventions are about cell 0 being a real target, but the family runtime
// puts the cell index in a different field depending on which path created the
// instance, and the main thread accepts both:
//
// - Cell-domain programs (settlement cell 2, climate cell 4, in-cell selector 5)
//   address a raw cell index in `target_handle` -- this is the family.effect.*
//   path, where target_generation is the literal 1.
// - Family-domain programs (0) carry the cell in `target_generation` -- this is
//   the family.modifier.* path, and EffectRuntime's FAMILY adapter hands that
//   field to the Modifier POD as the GROUP handle. ModifierRuntime accepts
//   group_handle 0 for ECONOMY (validate_target), so cell 0 is legal there too.
//
// Neither value is validated on the main thread (upsert_instance_pod only checks
// instance_id and generation), so a "zero means unset" rule here would make a
// cell-0 family effect work on the main thread and fail on the worker.
struct InstanceZeroPolicy {
    bool handle_allowed = false;
    bool generation_allowed = false;
};

InstanceZeroPolicy instance_zero_policy(int32_t target_domain) {
    InstanceZeroPolicy policy;
    policy.handle_allowed =
        target_domain == 2 || target_domain == 4 || target_domain == 5;
    policy.generation_allowed = target_domain == 0;
    return policy;
}

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
    _plan_ready = false; _view_cursor = {};
    _snapshot = RuntimeEffectPodSnapshot{};
    _snapshot.abi_version = RUNTIME_EFFECT_POD_ABI_VERSION;
    _snapshot.catalog_version = RUNTIME_EFFECT_POD_CATALOG_VERSION;
    _snapshot.catalog_hash = _catalog.catalog_hash;
    _snapshot.catalog_revision = _catalog_revision;
    build_snapshot(_current, _snapshot);
    rebuild_report();
}

uint64_t RuntimeEffectPodAuthority::hash_text(const char *text) noexcept {
    return runtime_text_hash(text);
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
        hash = mix_value(hash, definition.managed);
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
        hash = mix_value(hash, definition.min_magnitude_scale_q16);
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
            (behavior.implemented != 0 && behavior.function == nullptr &&
             runtime_effect_pod_behavior_resolver() == nullptr)) {
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
            definition.managed > 1u ||
            definition.target_selector_kind < 0 ||
            definition.target_selector_kind > MAX_SELECTOR_KIND) {
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
             (condition.arg0 < 0 || condition.arg0 > MAX_STATE_ID))) {
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
             (instruction.arg0 < 0 || instruction.arg0 > MAX_STATE_ID))) {
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
                // ModifierRuntime::Domain is {CLIMATE=0, COUNTRY=1, ECONOMY=2,
                // GAMEPLAY=3}, so CLIMATE is 0 and `> 3` already admits every
                // modifier domain. Do not widen this to 5 chasing a "CLIMATE=4"
                // that belongs to the ideology target_domain enum, not this one.
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
        input.next_due_day < 0) {
        error = "effect_pod_instance_invalid";
        return false;
    }
    // The program_id range is already proven, so the domain is readable.
    const InstanceZeroPolicy policy = instance_zero_policy(
        _catalog.definitions[static_cast<size_t>(input.program_id)].target_domain);
    if ((input.target_handle == 0 && !policy.handle_allowed) ||
        (input.target_generation == 0 && !policy.generation_allowed)) {
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

#include "runtime_effect_pod_instances.inc"
#include "runtime_effect_pod_managed_programs.inc"
#include "runtime_effect_pod_transactions.inc"
#include "runtime_effect_pod_daily_authority.inc"
#include "runtime_effect_pod_checkpoint.inc"
bool RuntimeEffectPodAuthority::definition_is_managed(
        int32_t program_id) const noexcept {
    return program_id >= 0 &&
        program_id < static_cast<int32_t>(_catalog.definitions.size()) &&
        _catalog.definitions[static_cast<size_t>(program_id)].managed != 0;
}

int32_t RuntimeEffectPodAuthority::program_id_for_instance(
        int64_t instance_id, uint32_t generation) const noexcept {
    for (const RuntimeEffectPodInstance &instance : _current.instances) {
        if (instance.instance_id == instance_id &&
            instance.generation == generation) {
            return instance.program_id;
        }
    }
    return -1;
}

int32_t RuntimeEffectPodAuthority::instance_index_for_id(
        int64_t instance_id) const noexcept {
    for (size_t i = 0; i < _current.instances.size(); ++i) {
        if (_current.instances[i].instance_id == instance_id) {
            return static_cast<int32_t>(i);
        }
    }
    return -1;
}

#include "runtime_effect_pod_selftest.inc"
#include "runtime_effect_pod_selftest_targets.inc"
namespace {
RuntimeEffectPodBehaviorResolver g_effect_behavior_resolver = nullptr;
} // namespace

void runtime_effect_pod_set_behavior_resolver(
        RuntimeEffectPodBehaviorResolver resolver) {
    g_effect_behavior_resolver = resolver;
}

RuntimeEffectPodBehaviorResolver runtime_effect_pod_behavior_resolver() {
    return g_effect_behavior_resolver;
}


} // namespace pk

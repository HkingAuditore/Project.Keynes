#include "runtime_effect_pod.h"
#include "effect_magnitude.h"

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
    // Re-ENSURE from Country soft-skip must not wipe an in-flight fire ACK
    // sequence. Preserve fire / ack / pending transaction identity when the
    // same (instance_id, generation) is upserted again.
    const bool same_identity =
        instance.instance_id == input.instance_id &&
        instance.generation == input.generation;
    // A managed level/location transition advances the generation while the
    // downstream Modifier row still belongs to this instance identity. Losing
    // effect_applied or an in-flight transaction here would make a later
    // condition-false evaluation look "never applied", so no REMOVE is emitted
    // and the old tier stays live. Carry the lifecycle across that replacement;
    // the next true evaluation is forced to re-fire the new generation.
    const bool managed_replacement =
        same_identity == false &&
        instance.instance_id == input.instance_id &&
        definition.managed != 0 &&
        (instance.effect_applied != 0 ||
         instance.pending_transaction_id != 0);
    const bool carry_lifecycle = same_identity || managed_replacement;
    const uint64_t keep_fire =
        carry_lifecycle ? instance.fire_sequence : 0;
    const uint64_t keep_acked =
        carry_lifecycle ? instance.last_acked_fire_sequence : 0;
    const int64_t keep_pending_tx =
        carry_lifecycle ? instance.pending_transaction_id : 0;
    const uint64_t keep_pending_key =
        carry_lifecycle ? instance.pending_idempotency_key : 0;
    const int64_t keep_revision = instance.input_revision;
    const uint8_t keep_effect_applied =
        carry_lifecycle ? instance.effect_applied : 0;
    const int64_t keep_applied_revision =
        carry_lifecycle ? instance.applied_input_revision : 0;
    // The old generation's APPLY may still be the row that exists downstream.
    // Keep effect_applied so a false condition can remove it. A replacement
    // forces the next evaluation through needs_resync, which re-fires the new
    // tier without leaving an effect_applied=1 / applied_stack_count=0 wire
    // pair that restore() would reject.
    const int32_t keep_applied_stack_count =
        carry_lifecycle ? instance.applied_stack_count : 0;
    const uint8_t keep_needs_resync = managed_replacement
        ? 1 : (same_identity ? instance.needs_resync : 0);
    // A re-ENSURE can race an explicit remove. Keep the retire request when it
    // belongs to an instance that has already applied (or has an in-flight
    // APPLY); the trailing ENSURE must not erase the only record that the row
    // still needs a REMOVE. A never-applied tombstone may still be reinstalled,
    // which is the recoverable retire/upsert ordering used by the transport.
    // The same applies when a level transition replaces the generation while a
    // REMOVE is pending.
    const uint8_t keep_retire_requested =
        carry_lifecycle && (instance.effect_applied != 0 ||
                            instance.pending_transaction_id != 0)
            ? instance.retire_requested
            : 0;
    // The latch belongs to whoever is evaluating. A same-identity re-ENSURE
    // (Country soft-skip) must not wipe it; a new generation is a new card tier
    // and starts the band over, so it takes the wire value.
    const uint8_t keep_latched = same_identity ? instance.latched : input.latched;
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
    instance.magnitude_scale_q16 = input.magnitude_scale_q16;
    instance.latched = keep_latched;
    instance.metric_base = metric_base;
    instance.input_revision = keep_revision;
    instance.next_due_day = input.next_due_day;
    instance.expires_day = input.expires_day;
    instance.cadence_days = definition.cadence_days;
    instance.lifecycle = definition.lifecycle;
    instance.stack_policy = definition.stack_policy;
    instance.max_stacks = definition.max_stacks;
    instance.stack_key_hash = definition.stack_key_hash;
    instance.active = input.active ? 1 : 0;
    instance.fire_sequence = keep_fire;
    instance.effect_applied = keep_effect_applied;
    instance.applied_input_revision = keep_applied_revision;
    instance.applied_stack_count = keep_applied_stack_count;
    instance.needs_resync = keep_needs_resync;
    instance.last_acked_fire_sequence = keep_acked;
    instance.pending_transaction_id = keep_pending_tx;
    instance.pending_idempotency_key = keep_pending_key;
    instance.retire_requested = keep_retire_requested;
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
    const auto &definition =
        _catalog.definitions[static_cast<size_t>(instance.program_id)];
    // An explicit retire must undo what the instance actually applied. Let the
    // next plan emit a REMOVE transaction; planning handles inactive tombstones
    // while their pending transaction is live, and the ACK clears lifecycle
    // state. Unmanaged instances keep the old immediate tombstone behaviour.
    if (definition.managed != 0 &&
        (instance.effect_applied != 0 ||
         instance.pending_transaction_id != 0)) {
        instance.retire_requested = 1;
        _current.deterministic_state_hash = state_hash(_current);
        build_snapshot(_current, _snapshot);
        rebuild_report();
        return true;
    }
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
    // `metric_revisions` is the per-column CHANGE watermark, not "highest
    // revision seen": it feeds deterministic_state_hash and the EFP1 payload,
    // so advancing it for an unchanged value would republish the snapshot and
    // read downstream as a real input change. Revision 0 means "never
    // observed" -- every producer starts at day * 4 + 1.
    if (_current.metric_revisions[offset] != 0 &&
            _current.metric_values[offset] == value)
        return true;
    _current.metric_revisions[offset] = revision;
    _current.metric_values[offset] = value;
    instance.input_revision = std::max(instance.input_revision, revision);
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

uint32_t RuntimeEffectPodAuthority::reschedule_unfired_due_instances(
        int64_t committed_day) {
    if (!_configured || committed_day < 0 || _plan_ready) return 0;
    const int64_t next_day = committed_day + 1;
    uint32_t nudged = 0;
    for (auto &instance : _current.instances) {
        if (instance.active == 0 || instance.fire_sequence != 0) continue;
        if (instance.next_due_day < 0) continue;
        // Never-fired instances must land on the next sequential plan day.
        // They may sit on the already-closed committed day (late ENSURE) or
        // far in the future after a cadence-days failure backoff (technology
        // programs author cadence_days=3650).
        if (instance.next_due_day == next_day) continue;
        instance.next_due_day = next_day;
        ++nudged;
    }
    if (nudged == 0) return 0;
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return nudged;
}

uint32_t RuntimeEffectPodAuthority::catchup_fire_never_fired_instances(
        int64_t fire_day, std::vector<RuntimeDomainIntent> &out_intents,
        std::string &error) {
    error.clear();
    if (!_configured || fire_day < 0 || _plan_ready) return 0;
    // Only catch up the immediate next Effect day. Firing further ahead would
    // desync committed_day sequencing for the real plan_day lane.
    if (_current.committed_day < 0 || fire_day != _current.committed_day + 1)
        return 0;
    uint32_t fired = 0;
    std::vector<RuntimeEffectPodCommand> emitted;
    emitted.reserve(16);
    for (size_t instance_index_value = 0;
         instance_index_value < _current.instances.size(); ++instance_index_value) {
        RuntimeEffectPodInstance &instance =
            _current.instances[instance_index_value];
        if (instance.active == 0 || instance.fire_sequence != 0) continue;
        if (instance.pending_transaction_id != 0) continue;
        if (instance.next_due_day < 0 || instance.next_due_day > fire_day)
            continue;
        if (instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_catalog.definitions.size())) {
            error = "effect_pod_program_invalid";
            return fired;
        }
        const auto &definition =
            _catalog.definitions[static_cast<size_t>(instance.program_id)];
        if (definition.enabled == 0) {
            instance.next_due_day = fire_day + 1;
            continue;
        }
        if (instance.retire_requested != 0) {
            if (definition.managed == 0) {
                instance.active = 0;
                instance.retire_requested = 0;
                continue;
            }
            // A never-applied instance has no downstream row to remove, even
            // though its reference object may carry an unresolved command.
            // Retire the row now so a later ENSURE cannot resurrect it.
            if (instance.effect_applied == 0) {
                instance.active = 0;
                instance.retire_requested = 0;
                instance.next_due_day = fire_day + 1;
                continue;
            }
            RuntimeEffectPodTransaction transaction;
            if (!append_retirement_transaction(
                    _current, definition, instance, fire_day, emitted,
                    transaction, error)) {
                return fired;
            }
            _current.transactions.back().status =
                RuntimeEffectPodTransactionStatus::COMMITTED;
            append_transaction_intents(_current, definition, instance,
                                       transaction, out_intents);
            ++fired;
            continue;
        }
        const ManagedLifecycleDecision decision = evaluate_managed_lifecycle(
            definition, instance, _current, fire_day);
        if (decision == ManagedLifecycleDecision::RETIRE) {
            RuntimeEffectPodTransaction transaction;
            if (!append_retirement_transaction(
                    _current, definition, instance, fire_day, emitted,
                    transaction, error)) {
                return fired;
            }
            _current.transactions.back().status =
                RuntimeEffectPodTransactionStatus::COMMITTED;
            append_transaction_intents(_current, definition, instance,
                                       transaction, out_intents);
            ++fired;
            continue;
        }
        if (decision == ManagedLifecycleDecision::IDLE) {
            instance.last_evaluated_input_revision = instance.input_revision;
            instance.next_due_day = fire_day + 1;
            continue;
        }
        emitted.clear();
        if (!execute_program(definition, instance, _current, fire_day, emitted,
                             error)) {
            return fired;
        }
        if (emitted.empty()) {
            instance.last_evaluated_input_revision = instance.input_revision;
            if (definition.command_count > 0) {
                instance.next_due_day = fire_day + 1;
                continue;
            }
            instance.fire_sequence += 1u;
            instance.next_due_day =
                fire_day + std::max<int32_t>(1, definition.cadence_days);
            ++fired;
            continue;
        }
        RuntimeEffectPodTransaction transaction;
        if (!schedule_application(_current, definition, instance, fire_day,
                                  emitted, transaction, error)) {
            return fired;
        }
        // Mirror commit_day: catch-up emits are already live on _current.
        _current.transactions.back().status =
            RuntimeEffectPodTransactionStatus::COMMITTED;
        append_transaction_intents(_current, definition, instance,
                                   transaction, out_intents);
        ++fired;
    }
    if (fired == 0) return 0;
    _current.generation += 1u;
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return fired;
}

int64_t RuntimeEffectPodAuthority::state_value(
        const RuntimeEffectPodInstance &instance, int32_t state_id,
        int64_t day) noexcept {
    // Ids and scaling mirror EffectRuntime::state_value (effect_runtime.cpp:3840).
    // The Q16 factor is not cosmetic: authored content writes thresholds in Q16
    // ("level >= 2" is 131072), so returning a raw count here makes every such
    // condition permanently false on the worker while passing on the main thread.
    switch (state_id) {
        case 0:  // STATE_LEVEL
            return static_cast<int64_t>(instance.level) * Q16_ONE;
        case 1:  // STATE_FIRE_SEQUENCE
            return static_cast<int64_t>(instance.fire_sequence) * Q16_ONE;
        case 2:  // STATE_INPUT_REVISION - deliberately raw, it is a token.
            return instance.input_revision;
        case 3: {  // STATE_REMAINING_DAYS
            if (instance.expires_day < 0) return 0;
            const int64_t remaining =
                std::max<int64_t>(0, instance.expires_day - day);
            if (remaining > std::numeric_limits<int64_t>::max() / Q16_ONE)
                return std::numeric_limits<int64_t>::max();
            return remaining * Q16_ONE;
        }
        case 4:  // STATE_STACK_COUNT
            return static_cast<int64_t>(std::max(0, instance.stack_count)) * Q16_ONE;
        case 5:  // STATE_LATCHED - 0 or Q16_ONE, same as the main thread.
            return instance.latched != 0 ? Q16_ONE : 0;
        default:
            return 0;
    }
}

int32_t RuntimeEffectPodAuthority::scaled_command_stacks(
        int32_t base_stacks, int32_t stack_count, int32_t max_stacks) noexcept {
    // Shared with EffectRuntime so a stacked instance emits the same weight on
    // both threads. Shape mirrors the original main-thread formula:
    // base * max(1, depth), clamped to the program's max_stacks.
    return static_cast<int32_t>(std::min<int64_t>(
        std::max(1, max_stacks),
        static_cast<int64_t>(base_stacks) *
            static_cast<int64_t>(std::max(1, stack_count))));
}

bool RuntimeEffectPodAuthority::evaluate_conditions(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, const State &state,
        int64_t day) const {
    if (definition.condition_count == 0) return true;
    std::array<uint8_t, 256> stack{};
    uint32_t depth = 0;
    const auto metric = [&](int32_t id) -> int64_t {
        const size_t offset = static_cast<size_t>(instance.metric_base) +
            static_cast<size_t>(id);
        return offset < state.metric_values.size() ? state.metric_values[offset] : 0;
    };
    const auto read_state = [&](int32_t id) -> int64_t {
        return RuntimeEffectPodAuthority::state_value(instance, id, day);
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
                stack[depth++] = read_state(condition.arg0) >= condition.value;
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

RuntimeEffectPodAuthority::ManagedLifecycleDecision
RuntimeEffectPodAuthority::evaluate_managed_lifecycle(
        const RuntimeEffectPodDefinition &definition,
        RuntimeEffectPodInstance &instance, const State &state,
        int64_t day) const {
    const bool condition_passed =
        evaluate_conditions(definition, instance, state, day);
    // Latch the raw result before any stack arbitration, exactly like the main
    // thread. A hysteresis band describes the metric, not the outcome of this
    // tick's stack fight.
    instance.latched = condition_passed ? 1 : 0;
    if (definition.managed == 0)
        return condition_passed ? ManagedLifecycleDecision::FIRE
                                : ManagedLifecycleDecision::IDLE;
    if (!condition_passed)
        return instance.effect_applied != 0
            ? ManagedLifecycleDecision::RETIRE
            : ManagedLifecycleDecision::IDLE;
    if (instance.needs_resync == 0 && instance.effect_applied != 0 &&
        instance.input_revision <= instance.applied_input_revision &&
        instance.applied_stack_count == std::max(1, instance.stack_count)) {
        return ManagedLifecycleDecision::IDLE;
    }
    return ManagedLifecycleDecision::FIRE;
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
    // Depth multiplies the command exactly like the main thread. instance
    // .max_stacks is seeded from the program definition at :555, so it is the
    // same ceiling the main thread uses.
    out.stacks = scaled_command_stacks(
        definition.stacks, instance.stack_count, instance.max_stacks);
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
    const int32_t program = instance.program_id;
    const InstanceZeroPolicy policy =
        program >= 0 &&
        program < static_cast<int32_t>(_catalog.definitions.size())
        ? instance_zero_policy(
              _catalog.definitions[static_cast<size_t>(program)].target_domain)
        : InstanceZeroPolicy{};
    // target_generation is copied from the instance whatever the resolver is, so
    // a policy-exempt zero survives; an unexempt zero still means "unset".
    if (out.target_generation == 0 && !policy.generation_allowed) return false;
    if (out.target_handle != 0) return true;
    // A zero handle is real only when the command resolves to the instance's own
    // target. A STATIC 0 or a SOURCE 0 carries no cell index. Returning false
    // here is not a dropped command: execute_program turns it into
    // effect_command_target_invalid and fails the whole transaction, so a cell-0
    // family effect used to make the Effect stage fail every single day.
    return policy.handle_allowed &&
        definition.target_resolver == RuntimeEffectPodTargetResolver::INSTANCE;
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
        metadata->thread_safe == 0) {
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
    bool invoked = false;
    if (metadata->function != nullptr) {
        invoked = metadata->function(input, output, error);
    } else if (RuntimeEffectPodBehaviorResolver resolver =
                   runtime_effect_pod_behavior_resolver()) {
        invoked = resolver(definition.behavior_id_hash, input, output, error);
    } else {
        error = "effect_behavior_not_registered";
        return false;
    }
    if (!invoked || output.overflowed) {
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

bool RuntimeEffectPodAuthority::build_retirement_commands(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, int64_t day,
        std::vector<RuntimeEffectPodCommand> &commands,
        std::string &error) const {
    commands.clear();
    error.clear();
    uint32_t command_position = 0;
    for (uint32_t i = 0; i < definition.command_count; ++i) {
        const uint32_t command_index = definition.command_begin + i;
        if (command_index >= _catalog.commands.size()) {
            error = "effect_pod_retirement_command_missing";
            return false;
        }
        const auto &apply = _catalog.commands[command_index];
        if (apply.action != RuntimeEffectPodAction::MODIFIER_COMMAND ||
            apply.opcode != 1) {
            ++command_position;
            continue;
        }
        RuntimeEffectPodCommand command;
        if (!compile_command(apply, instance, 0, day,
                             instance.fire_sequence + 1u, command_position++,
                             command)) {
            error = "effect_command_target_invalid";
            return false;
        }
        command.opcode = 2;
        command.value = 0;
        command.duration_days = -1;
        command.stacks = 1;
        if (apply.target_resolver == RuntimeEffectPodTargetResolver::SOURCE) {
            command.target_generation = instance.generation;
        }
        // Mirror EffectRuntime::create_retirement_transaction(): the REMOVE
        // names the same reversible command definition but is not the APPLY
        // key, so it cannot collide with the row it removes.
        uint64_t key = FNV_OFFSET;
        key = mix_value(key, instance.instance_id);
        key = mix_value(key, instance.generation);
        key = mix_value(key, instance.fire_sequence + 1u);
        key = mix_value(key, command_index);
        key = mix_value(key, static_cast<uint8_t>(
            RuntimeEffectPodAction::MODIFIER_COMMAND));
        key = mix_value(key, command.domain);
        key = mix_value(key, command.opcode);
        key = mix_value(key, 1u);
        command.idempotency_key = key;
        commands.push_back(command);
    }
    if (commands.empty()) {
        error = "effect_retire_reversible_command_missing";
        return false;
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
    const auto read_state = [&](int32_t id) -> int64_t {
        return RuntimeEffectPodAuthority::state_value(instance, id, day);
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
                stack[depth++] = read_state(instruction.arg0);
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
        bool retirement,
        RuntimeEffectPodTransaction &transaction, std::string &error) {
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
    transaction.transition_stack_count =
        retirement ? 0 : std::max(1, instance.stack_count);
    for (const auto &command : commands) {
        transaction.required_ack_mask |= adapter_ack_bit(command.action);
        state.command_arena.push_back(command);
    }
    transaction.plan_hash = calculate_plan_hash(transaction.source_instance_id,
        transaction.source_generation, transaction.effective_day,
        transaction.fire_sequence, commands);
    state.transactions.push_back(transaction);
    return true;
}

bool RuntimeEffectPodAuthority::append_retirement_transaction(
        State &state, const RuntimeEffectPodDefinition &definition,
        RuntimeEffectPodInstance &instance, int64_t day,
        std::vector<RuntimeEffectPodCommand> &commands,
        RuntimeEffectPodTransaction &transaction, std::string &error,
        bool retire_instance) {
    commands.clear();
    if (!build_retirement_commands(definition, instance, day, commands, error))
        return false;
    std::stable_sort(commands.begin(), commands.end(), command_less);
    if (!append_transaction(state, instance, day, commands, true, transaction,
                            error))
        return false;
    ++_next_transaction_id;
    instance.fire_sequence += 1u;
    instance.pending_transaction_id = transaction.transaction_id;
    instance.pending_idempotency_key = commands.front().idempotency_key;
    instance.last_evaluated_input_revision = instance.input_revision;
    instance.next_due_day = day + 1;
    if (retire_instance) instance.retire_requested = 1;
    return true;
}

void RuntimeEffectPodAuthority::append_transaction_intents(
        const State &state, const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance,
        const RuntimeEffectPodTransaction &transaction,
        std::vector<RuntimeDomainIntent> &out_intents,
        uint64_t *plan_hash) const {
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const size_t command_index =
            static_cast<size_t>(transaction.command_begin) + ordinal;
        if (command_index >= state.command_arena.size()) return;
        const auto &command = state.command_arena[command_index];
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        intent.target_domain = adapter_domain(command.action);
        intent.opcode = static_cast<uint16_t>(command.opcode);
        intent.effect_action = static_cast<uint16_t>(command.action);
        intent.source_id = static_cast<uint64_t>(command.source_instance_id);
        intent.target_handle = command.target_handle;
        intent.target_generation = command.target_generation;
        intent.value = command.value;
        intent.reserved_effect_flags |= RUNTIME_DOMAIN_INTENT_HAS_EFFECT_VALUE;
        intent.effective_day = command.effective_day;
        intent.payload = command.payload;
        intent.request_id = static_cast<uint64_t>(transaction.transaction_id);
        intent.producer_id = static_cast<uint32_t>(RuntimeDomainId::EFFECT);
        intent.sequence = transaction.fire_sequence * 16u + ordinal;
        intent.idempotency_key = command.idempotency_key;
        intent.duration_days = command.duration_days;
        intent.stacks = command.stacks;
        intent.magnitude_q16 = effect_scaled_magnitude_q16(
            command.value, instance.magnitude_scale_q16);
        if (command.action == RuntimeEffectPodAction::MODIFIER_COMMAND &&
            intent.payload[1] == 0 && command.domain >= 0 &&
            command.domain < 4) {
            intent.payload[1] = command.domain;
        }
        if (command.action == RuntimeEffectPodAction::MODIFIER_COMMAND) {
            int32_t adapter = 0;
            if (command.command_definition_id <
                _catalog.command_native_adapters.size()) {
                adapter =
                    _catalog.command_native_adapters[
                        command.command_definition_id];
            }
            intent.reserved =
                adapter | ((definition.target_domain & 0xFF) << 8);
        }
        out_intents.push_back(intent);
        if (plan_hash != nullptr)
            *plan_hash = command_hash(*plan_hash, command);
    }
}

bool RuntimeEffectPodAuthority::schedule_application(
        State &state, const RuntimeEffectPodDefinition &definition,
        RuntimeEffectPodInstance &instance, int64_t day,
        std::vector<RuntimeEffectPodCommand> &commands,
        RuntimeEffectPodTransaction &transaction, std::string &error) {
    if (commands.empty()) return false;
    std::stable_sort(commands.begin(), commands.end(), command_less);
    if (!append_transaction(state, instance, day, commands, false, transaction,
                            error))
        return false;
    ++_next_transaction_id;
    instance.fire_sequence += 1u;
    instance.pending_transaction_id = transaction.transaction_id;
    instance.pending_idempotency_key = commands.front().idempotency_key;
    instance.last_evaluated_input_revision = instance.input_revision;
    instance.next_due_day = day + definition.cadence_days;
    instance.expires_day =
        definition.lifecycle == RuntimeEffectPodLifecycle::DURATION
            ? day + definition.duration_days
            : -1;
    return true;
}

void RuntimeEffectPodAuthority::compact_acked_transactions(State &state) const {
    if (state.transactions.empty()) return;
    std::vector<RuntimeEffectPodTransaction> retained;
    retained.reserve(state.transactions.size());
    std::vector<RuntimeEffectPodCommand> compacted_commands;
    compacted_commands.reserve(state.command_arena.size());
    for (RuntimeEffectPodTransaction transaction : state.transactions) {
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED)
            continue;
        const uint32_t begin =
            static_cast<uint32_t>(compacted_commands.size());
        for (uint32_t ordinal = 0; ordinal < transaction.command_count;
             ++ordinal) {
            const size_t command_index =
                static_cast<size_t>(transaction.command_begin) + ordinal;
            if (command_index >= state.command_arena.size()) break;
            compacted_commands.push_back(state.command_arena[command_index]);
        }
        transaction.command_begin = begin;
        transaction.command_count = static_cast<uint32_t>(
            compacted_commands.size()) - begin;
        retained.push_back(std::move(transaction));
    }
    if (retained.size() == state.transactions.size()) return;
    state.transactions.swap(retained);
    state.command_arena.swap(compacted_commands);
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

uint64_t RuntimeEffectPodAuthority::calculate_plan_hash(int64_t source_id,
        uint32_t generation, int64_t day, uint64_t fire_sequence,
        const std::vector<RuntimeEffectPodCommand> &commands) noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, source_id);
    hash = mix_value(hash, generation);
    hash = mix_value(hash, day);
    hash = mix_value(hash, fire_sequence);
    for (const auto &command : commands) hash = command_hash(hash, command);
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
        hash = mix_value(hash, instance.magnitude_scale_q16);
        hash = mix_value(hash, instance.latched);
        hash = mix_value(hash, instance.metric_base);
        hash = mix_value(hash, instance.input_revision);
        hash = mix_value(hash, instance.last_evaluated_input_revision);
        hash = mix_value(hash, instance.next_due_day);
        hash = mix_value(hash, instance.cadence_days);
        hash = mix_value(hash, instance.lifecycle);
        hash = mix_value(hash, instance.stack_policy);
        hash = mix_value(hash, instance.stack_count);
        hash = mix_value(hash, instance.applied_stack_count);
        hash = mix_value(hash, instance.effect_applied);
        hash = mix_value(hash, instance.applied_input_revision);
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
        // An explicit retire keeps the tombstone active only until its REMOVE
        // ACKs. Planning the removal is the whole point of that state.
        if (instance.active == 0 && instance.retire_requested == 0) continue;
        if (instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_catalog.definitions.size())) {
            error = "effect_pod_program_invalid";
            set_blocker(error.c_str());
            return false;
        }
        const auto &definition =
            _catalog.definitions[static_cast<size_t>(instance.program_id)];
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
                append_transaction_intents(_next, definition, instance, transaction,
                                           plan.intents, &plan_hash);
            }
            continue;
        }
        if (instance.expires_day >= 0 && instance.expires_day <= day) {
            if (definition.managed != 0 && instance.effect_applied != 0) {
                RuntimeEffectPodTransaction transaction;
                if (!append_retirement_transaction(
                        _next, definition, instance, day, emitted, transaction,
                        error, true)) {
                    set_blocker(error.c_str());
                    return false;
                }
                plan.required_ack_mask |= transaction.required_ack_mask;
                append_transaction_intents(_next, definition, instance, transaction,
                                           plan.intents, &plan_hash);
                continue;
            }
            instance.active = 0;
            continue;
        }
        // An explicit retire is a request to remove the live row now, not a
        // cadence event. Let it through even when the APPLY parked the instance
        // on a future due day.
        if (instance.retire_requested == 0 &&
            (instance.next_due_day < 0 || instance.next_due_day > day)) {
            continue;
        }
        if (instance.retire_requested != 0) {
            if (definition.managed == 0 || instance.effect_applied == 0) {
                instance.active = 0;
                instance.retire_requested = 0;
                continue;
            }
            RuntimeEffectPodTransaction transaction;
            if (!append_retirement_transaction(
                    _next, definition, instance, day, emitted, transaction,
                    error)) {
                set_blocker(error.c_str());
                return false;
            }
            plan.required_ack_mask |= transaction.required_ack_mask;
            append_transaction_intents(_next, definition, instance, transaction,
                                       plan.intents, &plan_hash);
            continue;
        }
        // Cadence is the gap after a successful fire. A never-fired instance
        // (fire_sequence==0) must retry on the next calendar day — technology
        // programs author cadence_days=3650, and using that as a failure
        // backoff parks Country pending activation for a decade.
        const int64_t retry_due = instance.fire_sequence == 0
            ? day + 1
            : day + std::max<int32_t>(1, definition.cadence_days);
        if (definition.enabled == 0) {
            instance.next_due_day = retry_due;
            continue;
        }
        const ManagedLifecycleDecision decision = evaluate_managed_lifecycle(
            definition, instance, _current, day);
        if (decision == ManagedLifecycleDecision::RETIRE) {
            RuntimeEffectPodTransaction transaction;
            if (!append_retirement_transaction(
                    _next, definition, instance, day, emitted, transaction,
                    error)) {
                set_blocker(error.c_str());
                return false;
            }
            plan.required_ack_mask |= transaction.required_ack_mask;
            append_transaction_intents(_next, definition, instance,
                                       transaction, plan.intents,
                                       &plan_hash);
            continue;
        }
        if (decision == ManagedLifecycleDecision::IDLE) {
            instance.last_evaluated_input_revision = instance.input_revision;
            instance.next_due_day = retry_due;
            continue;
        }
        emitted.clear();
        if (!execute_program(definition, instance, _current, day, emitted, error)) {
            set_blocker(error.c_str());
            return false;
        }
        if (emitted.empty()) {
            instance.last_evaluated_input_revision = instance.input_revision;
            if (definition.command_count > 0 && instance.fire_sequence == 0) {
                // Declarative commands exist but none emitted — retry tomorrow
                // instead of applying the multi-year cadence backoff.
                instance.next_due_day = day + 1;
                continue;
            }
            // Match sync EffectRuntime: a passed evaluation with zero commands
            // still advances fire_sequence so fire_acked observes the one-shot.
            instance.fire_sequence += 1u;
            instance.next_due_day = day + std::max<int32_t>(1, definition.cadence_days);
            continue;
        }
        RuntimeEffectPodTransaction transaction;
        if (!schedule_application(_next, definition, instance, day, emitted,
                                  transaction, error)) {
            set_blocker(error.c_str());
            return false;
        }
        plan.required_ack_mask |= transaction.required_ack_mask;
        append_transaction_intents(_next, definition, instance, transaction,
                                   plan.intents, &plan_hash);
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
    compact_acked_transactions(_next);
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
                instance.last_acked_fire_sequence = transaction.fire_sequence;
                const auto &definition = _catalog.definitions[
                    static_cast<size_t>(instance.program_id)];
                const bool retirement =
                    transaction.transition_stack_count == 0;
                if (definition.managed != 0 && retirement) {
                    instance.effect_applied = 0;
                    instance.applied_input_revision = 0;
                    instance.applied_stack_count = 0;
                    if (instance.retire_requested) {
                        instance.active = 0;
                        instance.retire_requested = 0;
                    }
                } else if (definition.managed != 0) {
                    instance.effect_applied = 1;
                    instance.applied_input_revision =
                        std::max(instance.applied_input_revision,
                                 transaction.input_revision);
                    instance.applied_stack_count = std::max(
                        1, transaction.transition_stack_count);
                } else {
                    // Unmanaged programs keep their historical bookkeeping.
                    instance.applied_stack_count = instance.stack_count;
                    if (instance.retire_requested) instance.active = 0;
                }
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
        append_le<int32_t>(out, instance.magnitude_scale_q16);
        append_le<uint8_t>(out, instance.effect_applied);
        append_le<int64_t>(out, instance.applied_input_revision);
        append_le<uint8_t>(out, instance.latched);
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
            !read_le(data,payload_end,cursor,instance.magnitude_scale_q16) ||
            !read_le(data,payload_end,cursor,instance.effect_applied) ||
            !read_le(data,payload_end,cursor,instance.applied_input_revision) ||
            !read_le(data,payload_end,cursor,instance.latched) ||
            !read_le(data,payload_end,cursor,instance.active) ||
            !read_le(data,payload_end,cursor,instance.retire_requested) ||
            !read_le(data,payload_end,cursor,instance.needs_resync) ||
            instance.instance_id <= 0 || instance.generation == 0 ||
            instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            (instance.target_handle == 0 && !instance_zero_policy(
                _catalog.definitions[static_cast<size_t>(
                    instance.program_id)].target_domain).handle_allowed) ||
            (instance.target_generation == 0 && !instance_zero_policy(
                _catalog.definitions[static_cast<size_t>(
                    instance.program_id)].target_domain).generation_allowed) ||
            instance.metric_base > restored.metric_values.size() ||
            instance.magnitude_scale_q16 <
                _catalog.definitions[static_cast<size_t>(
                    instance.program_id)].min_magnitude_scale_q16 ||
            instance.magnitude_scale_q16 > 65536 * 4 ||
            instance.effect_applied > 1 ||
            (_catalog.definitions[static_cast<size_t>(
                  instance.program_id)].managed != 0 &&
              (((instance.effect_applied == 0) !=
                (instance.applied_stack_count == 0)) ||
               instance.applied_input_revision < 0 ||
               instance.applied_input_revision > instance.input_revision)) ||
            instance.latched > 1) {
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
    // A command emitted for a cell-0 instance carries a zero in one of its two
    // target fields (which one depends on the program's domain -- see
    // instance_zero_policy). The instance table is already parsed, so the domain
    // is readable through source_instance_id. An unknown source instance keeps
    // the strict reading, and a STATIC 0 can never be saved in the first place
    // because compile_command refuses to emit it.
    const auto command_zero_fields_allowed =
            [this, &restored](const RuntimeEffectPodCommand &command) {
        InstanceZeroPolicy policy;
        for (const auto &instance : restored.instances) {
            if (static_cast<uint64_t>(instance.instance_id) !=
                command.source_instance_id) continue;
            const int32_t program = instance.program_id;
            if (program >= 0 &&
                program < static_cast<int32_t>(_catalog.definitions.size())) {
                policy = instance_zero_policy(_catalog.definitions[
                    static_cast<size_t>(program)].target_domain);
            }
            break;
        }
        return (command.target_handle != 0 || policy.handle_allowed) &&
            (command.target_generation != 0 || policy.generation_allowed);
    };
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
            !is_action_valid(command.action) ||
            !command_zero_fields_allowed(command) ||
            command.idempotency_key == 0 ||
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
    // Several historical ACKED transitions may legitimately remain for one
    // instance until the next commit compacts them (for example APPLY then
    // RETIRE). Only the latest ACKED transition must agree with the final ACKed
    // lifecycle state.
    std::unordered_map<int64_t, const RuntimeEffectPodTransaction *> latest_acked;
    for (const auto &transaction : restored.transactions) {
        if (transaction.status != RuntimeEffectPodTransactionStatus::ACKED)
            continue;
        auto it = latest_acked.find(transaction.source_instance_id);
        if (it == latest_acked.end() ||
            transaction.transaction_id > it->second->transaction_id) {
            latest_acked[transaction.source_instance_id] = &transaction;
        }
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
        const auto &instance = restored.instances[static_cast<size_t>(index)];
        const auto latest = latest_acked.find(instance.instance_id);
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED &&
            latest != latest_acked.end() &&
            latest->second != &transaction) {
            continue;
        }
        const auto &definition = _catalog.definitions[
            static_cast<size_t>(instance.program_id)];
        if (definition.managed != 0 &&
            transaction.status == RuntimeEffectPodTransactionStatus::ACKED &&
            ((transaction.transition_stack_count == 0 &&
              instance.effect_applied != 0) ||
             (transaction.transition_stack_count > 0 &&
              instance.effect_applied == 0))) {
            error = "effect_pod_managed_transaction_state_invalid";
            return false;
        }
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

bool RuntimeEffectPodAuthority::magnitude_scale_self_test(std::string &error) {
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    // One MODIFIER command whose compiled value is 1.0, armed with a 2x scale.
    // Under worker authority the main thread's dispatch_native_modifier is
    // suppressed, so this intent is the ONLY place the multiplier can land: a
    // pod that ignored `magnitude_scale_q16` would emit 1.0 and every synergy
    // would silently be a no-op on the worker.
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = hash_text("scale.fixture");
    definition.cadence_days = 1;
    definition.max_work = 8;
    definition.instruction_begin = 0;
    definition.instruction_count = 2;
    definition.command_begin = 0;
    definition.command_count = 1;
    catalog.definitions.push_back(definition);
    catalog.commands.push_back(RuntimeEffectPodCommandDefinition{
        RuntimeEffectPodAction::MODIFIER_COMMAND, 0, 1,
        RuntimeEffectPodTargetResolver::INSTANCE, 0,
        RuntimeEffectPodValueMode::STACK_TOP, 0, -1, 1,
        hash_text("modifier"), 0, {}});
    RuntimeEffectPodInstruction constant;
    constant.op = RuntimeEffectPodInstructionOp::CONST;
    constant.value = Q16_ONE;
    catalog.instructions.push_back(constant);
    RuntimeEffectPodInstruction emit;
    emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
    emit.arg0 = 0;
    catalog.instructions.push_back(emit);

    RuntimeEffectPodAuthority authority;
    if (!authority.configure(catalog, error)) return false;
    RuntimeEffectPodInstanceInput input;
    input.instance_id = 11;
    input.generation = 1;
    input.program_id = 0;
    input.source_handle = 5;
    input.target_handle = 6;
    input.target_generation = 1;
    input.magnitude_scale_q16 = Q16_ONE * 2;
    if (!authority.upsert_instance(input, error))
        return fail("effect_scale_instance_rejected");
    RuntimeEffectPodPlan plan;
    if (!authority.plan_day(0, 1, plan, error) || plan.intents.size() != 1u)
        return fail("effect_scale_plan_failed");
    if (plan.intents.front().magnitude_q16 != static_cast<int32_t>(Q16_ONE * 2))
        return fail("effect_scale_not_applied_on_worker");
    // Unscaled control: the same program with the default 1.0 must come out at
    // exactly the compiled value, otherwise "2x" could be an off-by-one clamp.
    RuntimeEffectPodAuthority plain;
    if (!plain.configure(catalog, error)) return false;
    input.instance_id = 12;
    input.magnitude_scale_q16 = Q16_ONE;
    if (!plain.upsert_instance(input, error))
        return fail("effect_scale_control_rejected");
    RuntimeEffectPodPlan plain_plan;
    if (!plain.plan_day(0, 1, plain_plan, error) || plain_plan.intents.size() != 1u)
        return fail("effect_scale_control_plan_failed");
    if (plain_plan.intents.front().magnitude_q16 != static_cast<int32_t>(Q16_ONE))
        return fail("effect_scale_control_changed");

    // Kind 16 derives its scale from the source cap. A cap of 6 yields 1/6,
    // below the generic 0.25x authoring floor, but it is a valid count step.
    definition.key_hash = hash_text("scale.source_count.fixture");
    definition.target_selector_kind = MAX_SELECTOR_KIND;
    definition.min_magnitude_scale_q16 = Q16_ONE / 6;
    catalog.definitions.clear();
    catalog.definitions.push_back(definition);
    RuntimeEffectPodAuthority source_count;
    if (!source_count.configure(catalog, error))
        return fail("effect_source_count_scale_configure_failed");
    input.instance_id = 13;
    input.magnitude_scale_q16 = Q16_ONE / 6;
    if (!source_count.upsert_instance(input, error))
        return fail("effect_source_count_scale_rejected");
    RuntimeEffectPodPlan source_count_plan;
    if (!source_count.plan_day(0, 1, source_count_plan, error) ||
            source_count_plan.intents.size() != 1u)
        return fail("effect_source_count_scale_plan_failed");
    if (source_count_plan.intents.front().magnitude_q16 != Q16_ONE / 6)
        return fail("effect_source_count_scale_clamped");
    return true;
}

bool RuntimeEffectPodAuthority::self_test(std::string &error) {
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    // Cell 0 is a real target on the main thread, so the pod has to agree. Kept
    // as its own fixture because this one pins exact plan hashes and adding a
    // second program to its catalog would move all of them.
    if (!cell_target_self_test(error)) return false;
    if (!latch_self_test(error)) return false;
    if (!magnitude_scale_self_test(error)) return false;
    // Managed lifecycle: one apply, one deactivation after the condition
    // falls, and no idle churn while the same input stays applied. The
    // fixture also pins ACK semantics and ACKED transaction compaction.
    {
        RuntimeEffectPodCatalog managed_catalog;
        managed_catalog.metric_key_hashes = {hash_text("managed.metric")};
        RuntimeEffectPodDefinition managed;
        managed.key_hash = hash_text("managed.program");
        managed.cadence_days = 1;
        managed.max_work = 8;
        managed.managed = 1;
        managed.condition_begin = 0;
        managed.condition_count = 1;
        managed.instruction_begin = 0;
        managed.instruction_count = 2;
        managed.command_begin = 0;
        managed.command_count = 1;
        managed_catalog.definitions.push_back(managed);
        RuntimeEffectPodCondition condition;
        condition.op = RuntimeEffectPodConditionOp::METRIC_GTE;
        condition.arg0 = 0;
        condition.value = Q16_ONE;
        managed_catalog.conditions.push_back(condition);
        RuntimeEffectPodInstruction constant;
        constant.op = RuntimeEffectPodInstructionOp::CONST;
        constant.value = 0;  // not used: command value is constant
        managed_catalog.instructions.push_back(constant);
        RuntimeEffectPodInstruction emit;
        emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
        emit.arg0 = 0;
        managed_catalog.instructions.push_back(emit);
        RuntimeEffectPodCommandDefinition apply;
        apply.action = RuntimeEffectPodAction::MODIFIER_COMMAND;
        apply.domain = 2;
        apply.opcode = 1;
        apply.target_resolver = RuntimeEffectPodTargetResolver::INSTANCE;
        apply.value_mode = RuntimeEffectPodValueMode::CONSTANT;
        apply.value = Q16_ONE;
        apply.duration_days = -1;
        apply.stacks = 1;
        apply.command_key_hash = hash_text("managed.command");
        apply.definition_key_hash = hash_text("managed.stat");
        managed_catalog.commands.push_back(apply);

        RuntimeEffectPodAuthority authority;
        if (!authority.configure(managed_catalog, error)) return false;
        RuntimeEffectPodInstanceInput input;
        input.instance_id = 7001;
        input.generation = 1;
        input.program_id = 0;
        input.source_handle = 3;
        input.target_handle = 4;
        input.target_generation = 1;
        input.next_due_day = 0;
        if (!authority.upsert_instance(input, error))
            return fail("effect_managed_setup_failed");
        if (!authority.set_metric(7001, 1, 0, 1, 2 * Q16_ONE, error))
            return fail("effect_managed_metric_failed");

        int64_t transaction_id = 0;
        for (int64_t day = 0; day < 3; ++day) {
            RuntimeEffectPodPlan plan;
            if (!authority.plan_day(day, static_cast<uint64_t>(day + 1),
                                    plan, error)) {
                return fail("effect_managed_true_plan_failed");
            }
            if (day == 0) {
                if (plan.intents.size() != 1u)
                    return fail("effect_managed_initial_apply_missing");
                transaction_id = plan.next_snapshot.transactions.empty()
                    ? 0 : plan.next_snapshot.transactions.front().transaction_id;
                if (!authority.commit_day(plan, error))
                    return fail("effect_managed_initial_commit_failed");
                RuntimeDomainAck ack;
                ack.transaction_id = static_cast<uint64_t>(transaction_id);
                ack.target_handle = 4;
                ack.target_generation = 1;
                ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
                ack.effective_day = day;
                ack.code = RuntimeDomainAckCode::OK;
                if (!authority.apply_ack(ack, error))
                    return fail("effect_managed_initial_ack_failed");
                const auto &applied = authority.snapshot().instances.front();
                if (applied.effect_applied != 1 ||
                        applied.applied_input_revision != 1 ||
                        applied.applied_stack_count != 1) {
                    return fail("effect_managed_ack_state_not_recorded");
                }
            } else {
                if (!plan.intents.empty())
                    return fail("effect_managed_true_days_refired");
                if (!authority.commit_day(plan, error))
                    return fail("effect_managed_true_commit_failed");
                if (!authority.snapshot().transactions.empty())
                    return fail("effect_managed_acked_transaction_not_compacted");
            }
        }

        // Falling condition: exactly one REMOVE, then silence until applied.
        if (!authority.set_metric(7001, 1, 0, 2, 0, error))
            return fail("effect_managed_metric_lower_failed");
        RuntimeEffectPodPlan retire_plan;
        if (!authority.plan_day(3, 4, retire_plan, error) ||
                retire_plan.intents.size() != 1u)
            return fail("effect_managed_retire_missing");
        const auto &retire_command = retire_plan.next_snapshot.command_arena[
            retire_plan.next_snapshot.transactions.front().command_begin];
        if (retire_command.action != RuntimeEffectPodAction::MODIFIER_COMMAND ||
                retire_command.opcode != 2 ||
                retire_plan.next_snapshot.transactions.front()
                    .transition_stack_count != 0) {
            return fail("effect_managed_retire_shape_invalid");
        }
        transaction_id = retire_plan.next_snapshot.transactions.front()
            .transaction_id;
        if (!authority.commit_day(retire_plan, error))
            return fail("effect_managed_retire_commit_failed");
        RuntimeDomainAck retire_ack;
        retire_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        retire_ack.target_handle = 4;
        retire_ack.target_generation = 1;
        retire_ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        retire_ack.effective_day = 3;
        retire_ack.code = RuntimeDomainAckCode::OK;
        if (!authority.apply_ack(retire_ack, error))
            return fail("effect_managed_retire_ack_failed");
        const auto &retired = authority.snapshot().instances.front();
        if (retired.effect_applied != 0 ||
                retired.applied_input_revision != 0 ||
                retired.applied_stack_count != 0 ||
                authority.snapshot().transactions.empty() ||
                authority.snapshot().transactions.front().status !=
                    RuntimeEffectPodTransactionStatus::ACKED) {
            return fail("effect_managed_retire_state_not_cleared");
        }
        RuntimeEffectPodPlan idle_plan;
        if (!authority.plan_day(4, 5, idle_plan, error) ||
                !idle_plan.intents.empty() ||
                !authority.commit_day(idle_plan, error)) {
            return fail("effect_managed_false_day_refired");
        }
        if (!authority.snapshot().transactions.empty() ||
                !authority.snapshot().command_arena.empty()) {
            return fail("effect_managed_acked_transaction_not_compacted");
        }

        // Re-apply, then exercise the explicit remove path. This is the
        // cell-instance case: the instance must stay scheduled long enough to
        // emit a REMOVE and only become a tombstone after that REMOVE ACKs.
        const int64_t reapply_day = 5;
        if (!authority.set_metric(7001, 1, 0, 3, 2 * Q16_ONE, error))
            return fail("effect_managed_reapply_metric_failed");
        RuntimeEffectPodPlan reapply_plan;
        if (!authority.plan_day(reapply_day, 6, reapply_plan, error) ||
                reapply_plan.intents.size() != 1u) {
            return fail("effect_managed_reapply_missing");
        }
        transaction_id = reapply_plan.next_snapshot.transactions.front()
            .transaction_id;
        if (!authority.commit_day(reapply_plan, error))
            return fail("effect_managed_reapply_commit_failed");
        RuntimeDomainAck reapply_ack;
        reapply_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        reapply_ack.target_handle = 4;
        reapply_ack.target_generation = 1;
        reapply_ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        reapply_ack.effective_day = reapply_day;
        reapply_ack.code = RuntimeDomainAckCode::OK;
        if (!authority.apply_ack(reapply_ack, error))
            return fail("effect_managed_reapply_ack_failed");
        if (!authority.remove_instance(7001, 1, error))
            return fail("effect_managed_remove_request_failed");
        // A same-identity re-ENSURE may arrive after the explicit remove while
        // the APPLY is still settling. It must not erase the pending REMOVE.
        input.next_due_day = 6;
        if (!authority.upsert_instance(input, error) ||
                authority.snapshot().instances.front().retire_requested == 0) {
            return fail("effect_managed_remove_request_erased");
        }
        RuntimeEffectPodPlan remove_plan;
        if (!authority.plan_day(6, 7, remove_plan, error) ||
                remove_plan.intents.size() != 1u) {
            return fail("effect_managed_remove_missing");
        }
        const auto &remove_snapshot = remove_plan.next_snapshot;
        // The re-apply transaction is ACKED but remains until this commit
        // compacts it, so the newly planned retirement is the last row.
        const auto &remove_transaction = remove_snapshot.transactions.back();
        const auto &remove_command = remove_snapshot.command_arena[
            remove_transaction.command_begin];
        if (remove_transaction.transition_stack_count != 0 ||
                remove_command.opcode != 2) {
            return fail("effect_managed_remove_shape_invalid");
        }
        transaction_id = remove_transaction.transaction_id;
        if (!authority.commit_day(remove_plan, error))
            return fail("effect_managed_remove_commit_failed");
        RuntimeDomainAck remove_ack;
        remove_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        remove_ack.target_handle = 4;
        remove_ack.target_generation = 1;
        remove_ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        remove_ack.effective_day = 6;
        remove_ack.code = RuntimeDomainAckCode::OK;
        if (!authority.apply_ack(remove_ack, error))
            return fail("effect_managed_remove_ack_failed");
        const auto &removed = authority.snapshot().instances.front();
        if (removed.active != 0 || removed.effect_applied != 0 ||
                removed.retire_requested != 0) {
            return fail("effect_managed_remove_tombstone_invalid");
        }

        // Duration expiry uses the same retirement transaction rather than
        // silently tombstoning an applied managed row.
        RuntimeEffectPodCatalog duration_catalog = managed_catalog;
        duration_catalog.definitions[0].lifecycle =
            RuntimeEffectPodLifecycle::DURATION;
        duration_catalog.definitions[0].duration_days = 2;
        RuntimeEffectPodAuthority duration_authority;
        if (!duration_authority.configure(duration_catalog, error))
            return fail("effect_managed_duration_configure_failed");
        RuntimeEffectPodInstanceInput duration_input;
        duration_input.instance_id = 7002;
        duration_input.generation = 1;
        duration_input.program_id = 0;
        duration_input.source_handle = 3;
        duration_input.target_handle = 4;
        duration_input.target_generation = 1;
        duration_input.next_due_day = 0;
        if (!duration_authority.upsert_instance(duration_input, error) ||
                !duration_authority.set_metric(
                    7002, 1, 0, 1, 2 * Q16_ONE, error)) {
            return fail("effect_managed_duration_setup_failed");
        }
        RuntimeEffectPodPlan duration_apply;
        if (!duration_authority.plan_day(0, 1, duration_apply, error) ||
                duration_apply.intents.size() != 1u) {
            return fail("effect_managed_duration_apply_missing");
        }
        transaction_id = duration_apply.next_snapshot.transactions.front()
            .transaction_id;
        if (!duration_authority.commit_day(duration_apply, error))
            return fail("effect_managed_duration_apply_commit_failed");
        RuntimeDomainAck duration_ack;
        duration_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        duration_ack.target_handle = 4;
        duration_ack.target_generation = 1;
        duration_ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        duration_ack.effective_day = 0;
        duration_ack.code = RuntimeDomainAckCode::OK;
        if (!duration_authority.apply_ack(duration_ack, error))
            return fail("effect_managed_duration_apply_ack_failed");
        for (int64_t day = 1; day < 2; ++day) {
            RuntimeEffectPodPlan plan;
            if (!duration_authority.plan_day(
                    day, static_cast<uint64_t>(day + 1), plan, error) ||
                    !plan.intents.empty() ||
                    !duration_authority.commit_day(plan, error)) {
                return fail("effect_managed_duration_idle_failed");
            }
        }
        RuntimeEffectPodPlan duration_retire;
        if (!duration_authority.plan_day(2, 3, duration_retire, error) ||
                duration_retire.intents.size() != 1u ||
                duration_retire.next_snapshot.command_arena[
                    duration_retire.next_snapshot.transactions.front().command_begin]
                    .opcode != 2) {
            return fail("effect_managed_duration_retire_missing");
        }

        for (int64_t day = 7; day < 105; ++day) {
            RuntimeEffectPodPlan plan;
            if (!authority.plan_day(day, static_cast<uint64_t>(day + 1),
                                    plan, error) ||
                    !plan.intents.empty() ||
                    !authority.commit_day(plan, error)) {
                return fail("effect_managed_idle_day_churned");
            }
        }
        if (!authority.snapshot().transactions.empty() ||
                !authority.snapshot().command_arena.empty()) {
            return fail("effect_managed_compaction_invalid");
        }

        // Removing an instance while its APPLY is in flight must still retire
        // the row the APPLY is about to create. Keep the request across the
        // APPLY ACK, then emit exactly one REMOVE on the next plan.
        RuntimeEffectPodAuthority pending_remove_authority;
        if (!pending_remove_authority.configure(managed_catalog, error))
            return fail("effect_managed_pending_remove_configure_failed");
        RuntimeEffectPodInstanceInput pending_remove_input;
        pending_remove_input.instance_id = 7003;
        pending_remove_input.generation = 1;
        pending_remove_input.program_id = 0;
        pending_remove_input.source_handle = 3;
        pending_remove_input.target_handle = 4;
        pending_remove_input.target_generation = 1;
        pending_remove_input.next_due_day = 0;
        if (!pending_remove_authority.upsert_instance(
                pending_remove_input, error) ||
                !pending_remove_authority.set_metric(
                    7003, 1, 0, 1, 2 * Q16_ONE, error)) {
            return fail("effect_managed_pending_remove_setup_failed");
        }
        RuntimeEffectPodPlan pending_apply;
        if (!pending_remove_authority.plan_day(0, 1, pending_apply, error) ||
                pending_apply.intents.size() != 1u) {
            return fail("effect_managed_pending_remove_apply_missing");
        }
        transaction_id = pending_apply.next_snapshot.transactions.front()
            .transaction_id;
        if (!pending_remove_authority.commit_day(pending_apply, error) ||
                !pending_remove_authority.remove_instance(7003, 1, error)) {
            return fail("effect_managed_pending_remove_request_failed");
        }
        const auto &pending_removed =
            pending_remove_authority.snapshot().instances.front();
        if (pending_removed.active == 0 ||
                pending_removed.effect_applied != 0 ||
                pending_removed.retire_requested == 0 ||
                pending_removed.pending_transaction_id == 0) {
            return fail("effect_managed_pending_remove_tombstoned_early");
        }
        RuntimeDomainAck pending_apply_ack;
        pending_apply_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        pending_apply_ack.target_handle = 4;
        pending_apply_ack.target_generation = 1;
        pending_apply_ack.domain =
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        pending_apply_ack.effective_day = 0;
        pending_apply_ack.code = RuntimeDomainAckCode::OK;
        if (!pending_remove_authority.apply_ack(pending_apply_ack, error))
            return fail("effect_managed_pending_remove_apply_ack_failed");
        const auto &pending_applied =
            pending_remove_authority.snapshot().instances.front();
        if (pending_applied.active == 0 ||
                pending_applied.effect_applied == 0 ||
                pending_applied.retire_requested == 0 ||
                pending_applied.pending_transaction_id != 0) {
            return fail("effect_managed_pending_remove_ack_state_invalid");
        }
        RuntimeEffectPodPlan pending_retire;
        if (!pending_remove_authority.plan_day(1, 2, pending_retire, error) ||
                pending_retire.intents.size() != 1u ||
                pending_retire.next_snapshot.transactions.back().status !=
                    RuntimeEffectPodTransactionStatus::PREFLIGHTED) {
            return fail("effect_managed_pending_remove_retire_missing");
        }
        const auto &pending_retire_transaction =
            pending_retire.next_snapshot.transactions.back();
        const auto &pending_retire_command =
            pending_retire.next_snapshot.command_arena[
                pending_retire_transaction.command_begin];
        if (pending_retire_transaction.transition_stack_count != 0 ||
                pending_retire_command.opcode != 2) {
            return fail("effect_managed_pending_remove_retire_shape_invalid");
        }
        transaction_id = pending_retire_transaction.transaction_id;
        if (!pending_remove_authority.commit_day(pending_retire, error))
            return fail("effect_managed_pending_remove_retire_commit_failed");
        RuntimeDomainAck pending_retire_ack;
        pending_retire_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        pending_retire_ack.target_handle = 4;
        pending_retire_ack.target_generation = 1;
        pending_retire_ack.domain =
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        pending_retire_ack.effective_day = 1;
        pending_retire_ack.code = RuntimeDomainAckCode::OK;
        if (!pending_remove_authority.apply_ack(
                pending_retire_ack, error)) {
            return fail("effect_managed_pending_remove_retire_ack_failed");
        }
        const auto &pending_retired =
            pending_remove_authority.snapshot().instances.front();
        if (pending_retired.active != 0 ||
                pending_retired.effect_applied != 0 ||
                pending_retired.retire_requested != 0) {
            return fail("effect_managed_pending_remove_tombstone_invalid");
        }
        RuntimeEffectPodPlan pending_compaction;
        if (!pending_remove_authority.plan_day(
                2, 3, pending_compaction, error) ||
                !pending_compaction.intents.empty() ||
                !pending_remove_authority.commit_day(
                    pending_compaction, error) ||
                !pending_remove_authority.snapshot().transactions.empty() ||
                !pending_remove_authority.snapshot().command_arena.empty()) {
            return fail("effect_managed_pending_remove_compaction_failed");
        }
    }
    error.clear();
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

    // R-2: the latch must survive the worker's own save/restore.
    //
    // `latched` is evaluated state the worker owns (STATE_LATCHED reads it), and it
    // was already in the snapshot layout. What this pins is that a LATCHED instance
    // stays latched across serialize -> restore: without it, a restored day re-passes
    // a condition that had already latched, so a "hold while the condition is still
    // true" card silently re-fires on every load.
    //
    // Seeded through `upsert_instance` with a NEW identity, which is the one path
    // that takes `latched` from the input (a same-identity re-ensure deliberately
    // keeps the local latch, so it could not seed this).
    {
        error.clear();
        RuntimeEffectPodInstanceInput seed;
        seed.instance_id = 990001;
        seed.generation = 1;
        seed.program_id = 0;
        seed.latched = 1;
        seed.active = true;
        // The catalog's definition 0 targets a settlement cell, whose zero policy
        // requires a real handle and generation. Passing 0 fails
        // `validate_instance` with `effect_pod_instance_invalid`, which is why the
        // first attempt could not seed this instance at all.
        seed.target_handle = 1;
        seed.target_generation = 1;
        seed.source_handle = 1;
        std::string seed_error;
        if (!authority.upsert_instance(seed, seed_error)) {
            error = "effect_self_test_latched_setup_failed:" + seed_error;
            return false;
        }
        bool seeded = false;
        for (const auto &instance : authority.snapshot().instances) {
            if (instance.instance_id != seed.instance_id) continue;
            if (instance.latched != 1) {
                error = "effect_self_test_latched_not_set"; return false;
            }
            seeded = true;
        }
        if (!seeded) { error = "effect_self_test_latched_missing"; return false; }
        std::vector<uint8_t> latched_bytes;
        authority.serialize(latched_bytes);
        RuntimeEffectPodAuthority latched_restored;
        if (!latched_restored.configure(catalog, error) ||
            !latched_restored.restore(latched_bytes.data(), latched_bytes.size(),
                                      error)) {
            error = "effect_self_test_latched_restore_failed"; return false;
        }
        bool restored_latched = false;
        for (const auto &instance : latched_restored.snapshot().instances) {
            if (instance.instance_id != seed.instance_id) continue;
            if (instance.latched != 1) {
                error = "effect_self_test_latched_not_preserved_by_restore";
                return false;
            }
            // And the answer STATE_LATCHED reads must survive with it, not just
            // the byte.
            if (RuntimeEffectPodAuthority::state_value(instance, 5, 0) != Q16_ONE) {
                error = "effect_self_test_latched_state_value_lost"; return false;
            }
            restored_latched = true;
        }
        if (!restored_latched) {
            error = "effect_self_test_latched_lost_by_restore"; return false;
        }
    }
    return true;
}

bool RuntimeEffectPodAuthority::cell_target_self_test(std::string &error) {
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {hash_text("metric")};
    // Definition 0 addresses a settlement cell, definition 1 a family. They
    // differ in nothing but target_domain, so a guard that ignores that field
    // fails one of the cases below instead of passing both.
    for (int32_t program = 0; program < 2; ++program) {
        RuntimeEffectPodDefinition definition;
        definition.key_hash = hash_text(program == 0 ? "cell.program"
                                                     : "family.program");
        definition.cadence_days = 1;
        definition.max_work = 8;
        definition.instruction_begin = 0;
        definition.instruction_count = 2;
        definition.command_begin = 0;
        definition.command_count = 1;
        definition.target_domain = program == 0 ? 2 : 0;
        catalog.definitions.push_back(definition);
    }
    RuntimeEffectPodCommandDefinition command_definition;
    command_definition.action = RuntimeEffectPodAction::MODIFIER_COMMAND;
    command_definition.domain = 0;
    command_definition.opcode = 1;
    command_definition.target_resolver = RuntimeEffectPodTargetResolver::INSTANCE;
    command_definition.value_mode = RuntimeEffectPodValueMode::CONSTANT;
    command_definition.value = Q16_ONE;
    command_definition.command_key_hash = hash_text("cell.modifier");
    catalog.commands.push_back(command_definition);
    RuntimeEffectPodInstruction constant;
    constant.op = RuntimeEffectPodInstructionOp::CONST;
    constant.value = Q16_ONE;
    catalog.instructions.push_back(constant);
    RuntimeEffectPodInstruction emit;
    emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
    emit.arg0 = 0;
    catalog.instructions.push_back(emit);

    const auto install = [&error](RuntimeEffectPodAuthority &authority,
                                  int32_t program, uint64_t target_handle,
                                  int64_t instance_id,
                                  uint32_t target_generation = 1) {
        RuntimeEffectPodInstanceInput input;
        input.instance_id = instance_id;
        input.generation = 1;
        input.program_id = program;
        input.source_handle = 11;
        input.target_handle = target_handle;
        input.target_generation = target_generation;
        input.next_due_day = 0;
        return authority.upsert_instance(input, error);
    };

    // Cell 0: the case the main thread has always supported and the pod used to
    // read as "unset". Covers validation, command compilation and the EFP1 round
    // trip, because all three carried their own handle != 0 check.
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (!install(authority, 0, 0, 1))
            return fail("effect_cell_target_zero_instance_rejected");
        RuntimeEffectPodPlan plan;
        if (!authority.plan_day(0, 1, plan, error) || plan.intents.empty())
            return fail("effect_cell_target_zero_plan_failed");
        if (plan.intents.front().target_handle != 0 ||
            plan.intents.front().target_generation != 1)
            return fail("effect_cell_target_zero_handle_changed");
        if (!authority.commit_day(plan, error)) return false;
        std::vector<uint8_t> bytes;
        authority.serialize(bytes);
        RuntimeEffectPodAuthority restored;
        if (!restored.configure(catalog, error) ||
            !restored.restore(bytes.data(), bytes.size(), error))
            return fail("effect_cell_target_zero_restore_failed");
        if (restored.snapshot().instances.empty() ||
            restored.snapshot().instances.front().target_handle != 0)
            return fail("effect_cell_target_zero_restore_changed");
    }

    // A non-cell program still reads handle 0 as "unset".
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (install(authority, 1, 0, 2))
            return fail("effect_family_target_zero_accepted");
        if (error != "effect_pod_instance_invalid") return false;
    }

    // family.modifier.* puts the cell in target_generation, and EffectRuntime's
    // FAMILY adapter hands that field to the Modifier as the GROUP handle, where
    // ModifierRuntime accepts 0 for ECONOMY. So generation 0 is a real cell-0
    // target on this path -- and compile_command copies it straight through.
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (!install(authority, 1, 11, 5, 0))
            return fail("effect_family_target_generation_zero_rejected");
        RuntimeEffectPodPlan plan;
        if (!authority.plan_day(0, 1, plan, error) || plan.intents.empty())
            return fail("effect_family_target_generation_zero_plan_failed");
        if (plan.intents.front().target_generation != 0 ||
            plan.intents.front().target_handle != 11)
            return fail("effect_family_target_generation_zero_changed");
        if (!authority.commit_day(plan, error)) return false;
        std::vector<uint8_t> bytes;
        authority.serialize(bytes);
        RuntimeEffectPodAuthority restored;
        if (!restored.configure(catalog, error) ||
            !restored.restore(bytes.data(), bytes.size(), error))
            return fail("effect_family_target_generation_zero_restore_failed");
    }

    // The two exemptions are per field, not "any zero goes": a cell-domain
    // program still needs a real generation, and a family program still needs a
    // real handle.
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (install(authority, 0, 5, 6, 0))
            return fail("effect_cell_target_generation_zero_accepted");
        if (error != "effect_pod_instance_invalid") return false;
    }

    // A real cell index still works: the exemption is about which domain, not
    // about "zero is always fine".
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (!install(authority, 0, 5, 3))
            return fail("effect_cell_target_nonzero_rejected");
        RuntimeEffectPodPlan plan;
        if (!authority.plan_day(0, 1, plan, error) || plan.intents.empty() ||
            plan.intents.front().target_handle != 5)
            return fail("effect_cell_target_nonzero_plan_failed");
    }

    // STATIC 0 on a cell program is still unset -- neither STATIC nor SOURCE
    // carries a cell index, so the exemption must not leak to them. It is
    // already refused at catalog level, which this pins so the guarantee cannot
    // quietly move into (or out of) compile_command later.
    {
        RuntimeEffectPodCatalog static_catalog = catalog;
        static_catalog.commands[0].target_resolver =
            RuntimeEffectPodTargetResolver::STATIC;
        static_catalog.commands[0].static_target = 0;
        RuntimeEffectPodAuthority authority;
        if (authority.configure(static_catalog, error))
            return fail("effect_cell_target_static_zero_catalog_accepted");
        if (error != "effect_pod_command_invalid") return false;
    }
    return true;
}

bool RuntimeEffectPodAuthority::latch_self_test(std::string &error) {
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    // NOT(STATE_GTE(LATCHED, Q16_ONE)): "last time did NOT pass".
    // Day 0 latched=0 -> not(false)=true  -> pass, latch 1
    // Day 1 latched=1 -> not(true) =false -> fail, latch 0
    // Day 2 latched=0 -> not(false)=true  -> pass, latch 1
    // Alternating is the point: a one-shot assertion cannot tell "the latch was
    // written" from "the condition happened to be true".
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = hash_text("latch.program");
    definition.cadence_days = 1;
    definition.max_work = 8;
    definition.condition_begin = 0;
    definition.condition_count = 2;
    // No instructions and no commands, deliberately. A firing instance would
    // otherwise open a transaction, and a transaction that is not acked parks
    // the instance on `pending_transaction_id` -- day 1 would then emit nothing
    // for a reason that has nothing to do with the latch, and the fixture would
    // pass while proving the opposite of what it claims. A commandless program
    // still records pass/fail: see the fire_sequence assertions below.
    definition.instruction_begin = 0;
    definition.instruction_count = 0;
    definition.command_begin = 0;
    definition.command_count = 0;
    catalog.definitions.push_back(definition);

    RuntimeEffectPodCondition read_latch;
    read_latch.op = RuntimeEffectPodConditionOp::STATE_GTE;
    read_latch.arg0 = 5;  // STATE_LATCHED
    read_latch.value = Q16_ONE;
    catalog.conditions.push_back(read_latch);
    RuntimeEffectPodCondition negate;
    negate.op = RuntimeEffectPodConditionOp::BOOL_NOT;
    catalog.conditions.push_back(negate);

    RuntimeEffectPodAuthority authority;
    if (!authority.configure(catalog, error)) return false;
    RuntimeEffectPodInstanceInput input;
    input.instance_id = 7;
    input.generation = 1;
    input.program_id = 0;
    input.source_handle = 3;
    input.target_handle = 4;
    input.target_generation = 1;
    input.next_due_day = 0;
    if (!authority.upsert_instance(input, error))
        return fail("effect_latch_instance_rejected");

    // day 0: latched 0 -> NOT(false) = pass. latching 1.  fire_sequence 0 -> 1
    // day 1: latched 1 -> NOT(true)  = fail. latching 0.  fire_sequence stays 1
    // day 2: latched 0 -> NOT(false) = pass. latching 1.  fire_sequence 1 -> 2
    //
    // Both columns matter, and they catch different bugs:
    //   * write-back missing  -> latched stays 0, so every day passes and
    //     fire_sequence climbs 1/2/3. Caught by the latched column.
    //   * read path missing   -> STATE_GTE(LATCHED) answers 0 forever, so
    //     again every day passes. Caught by day 1 of either column.
    const uint8_t expected_latched[3] = {1, 0, 1};
    const uint64_t expected_fire_sequence[3] = {1, 1, 2};
    for (int64_t day = 0; day < 3; ++day) {
        RuntimeEffectPodPlan plan;
        // A fresh input_generation per day: the authority rejects a repeat plan
        // for the same generation, and this fixture is about the latch, not
        // about idempotent replanning. Sequential days also require committing,
        // since plan_day refuses to skip ahead of `committed_day`.
        if (!authority.plan_day(day, static_cast<uint64_t>(day + 1u), plan,
                                error))
            return fail("effect_latch_plan_failed");
        if (plan.next_snapshot.instances.empty())
            return fail("effect_latch_instance_missing_from_snapshot");
        const RuntimeEffectPodInstance &after = plan.next_snapshot.instances.front();
        if (after.latched != expected_latched[day] ||
                after.fire_sequence != expected_fire_sequence[day]) {
            error = std::string("effect_latch_oscillation_broken day=") +
                std::to_string(day) + " latched=" +
                std::to_string(after.latched) + " expected=" +
                std::to_string(expected_latched[day]) + " fire_sequence=" +
                std::to_string(after.fire_sequence) + " expected=" +
                std::to_string(expected_fire_sequence[day]);
            return false;
        }
        if (!authority.commit_day(plan, error))
            return fail("effect_latch_commit_failed");
    }
    return true;
}

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

RuntimeEffectSnapshotRing::RuntimeEffectSnapshotRing() { reset(); }

void RuntimeEffectSnapshotRing::reset() {
    for (Slot &slot : _slots) {
        slot.snapshot = RuntimeEffectPodSnapshot{};
        slot.state.store(FREE, std::memory_order_relaxed);
    }
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeEffectSnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        uint8_t expected = FREE;
        if (_slots[i].state.compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            index = i;
            return true;
        }
    }
    uint64_t oldest_generation = std::numeric_limits<uint64_t>::max();
    uint32_t oldest_index = 0;
    bool ready_found = false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if (!ready_found || generation < oldest_generation) {
            oldest_generation = generation;
            oldest_index = i;
            ready_found = true;
        }
    }
    if (ready_found) {
        uint8_t expected = READY;
        if (_slots[oldest_index].state.compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
            index = oldest_index;
            return true;
        }
    }
    _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    return false;
}

void RuntimeEffectSnapshotRing::publish(uint32_t index) {
    if (index >= _slots.size()) return;
    _published_generation.store(_slots[index].snapshot.generation,
                                std::memory_order_relaxed);
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeEffectSnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                   uint32_t &index) {
    const bool accept_initial =
        after_generation == std::numeric_limits<uint64_t>::max();
    uint64_t best = 0;
    uint32_t best_index = 0;
    bool found = false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if ((accept_initial || generation > after_generation) &&
            (!found || generation > best)) {
            best = generation;
            best_index = i;
            found = true;
        }
    }
    if (!found) return false;
    uint8_t expected = READY;
    if (!_slots[best_index].state.compare_exchange_strong(expected, READING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    index = best_index;
    return true;
}

void RuntimeEffectSnapshotRing::release(uint32_t index) {
    if (index >= _slots.size()) return;
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeEffectSnapshotRing::self_test() {
    RuntimeEffectSnapshotRing ring;
    uint32_t slot = 0;
    if (!ring.try_begin_write(slot)) return false;
    ring.write_buffer(slot).generation = 7;
    ring.publish(slot);
    uint32_t acquired = 0;
    if (!ring.try_acquire_latest(0, acquired)) return false;
    if (ring.read_buffer(acquired).generation != 7) return false;
    ring.release(acquired);
    return true;
}

} // namespace pk

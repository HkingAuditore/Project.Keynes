#pragma once

#include "runtime_pod_protocol.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <type_traits>
#include <vector>

namespace pk {

// F2-F6 Effect worker ABI.  This header intentionally contains no Godot type,
// allocator, callback, or object reference.  The main thread compiles the
// catalog once and the worker only sees the immutable numeric projection.
constexpr uint32_t RUNTIME_EFFECT_POD_ABI_VERSION = 1u;
constexpr uint32_t RUNTIME_EFFECT_POD_CATALOG_VERSION = 1u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_DEFINITIONS = 65536u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_METRICS = 65536u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_CONDITIONS = 1048576u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_INSTRUCTIONS = 1048576u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_COMMAND_DEFINITIONS = 1048576u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_INSTANCES = 16000000u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_TRANSACTIONS = 8192u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_COMMANDS = 1048576u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA = 1048576u;
constexpr uint32_t RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT = 4096u;

enum class RuntimeEffectPodAction : uint8_t {
    MODIFIER_COMMAND = 1,
    COUNTRY_COMMAND = 2,
    ECONOMY_COMMAND = 3,
    GAMEPLAY_COMMAND = 4,
    PUBLISH_EVENT = 5,
    CUSTOM_DOMAIN_COMMAND = 6,
};

enum class RuntimeEffectPodConditionOp : uint8_t {
    CONDITION_TRUE = 1,
    METRIC_GTE = 2,
    METRIC_LTE = 3,
    METRIC_EQ = 4,
    STATE_GTE = 5,
    BOOL_AND = 6,
    BOOL_OR = 7,
    BOOL_NOT = 8,
};

enum class RuntimeEffectPodInstructionOp : uint8_t {
    CONST = 1,
    READ_METRIC = 2,
    READ_STATE = 3,
    ADD = 4,
    SUB = 5,
    MUL_Q16 = 6,
    DIV_FLOOR = 7,
    MIN = 8,
    MAX = 9,
    CLAMP = 10,
    EMIT_COMMAND = 11,
    END = 12,
};

enum class RuntimeEffectPodTargetResolver : uint8_t {
    STATIC = 0,
    INSTANCE = 1,
    SOURCE = 2,
};

enum class RuntimeEffectPodValueMode : uint8_t {
    CONSTANT = 0,
    STACK_TOP = 1,
};

enum class RuntimeEffectPodTransactionStatus : uint8_t {
    PLANNED = 1,
    PREFLIGHTED = 2,
    COMMITTED = 3,
    ACKED = 4,
    REJECTED = 5,
    RESYNC_REQUIRED = 6,
};

enum class RuntimeEffectPodLifecycle : uint8_t {
    NONE = 0,
    DURATION = 1,
    EVENT = 2,
};

enum class RuntimeEffectPodStackPolicy : uint8_t {
    INDEPENDENT = 0,
    REPLACE = 1,
    ADD = 2,
    CAP = 3,
    REFRESH = 4,
};

struct RuntimeEffectPodCondition {
    RuntimeEffectPodConditionOp op = RuntimeEffectPodConditionOp::CONDITION_TRUE;
    int32_t arg0 = 0;
    int64_t value = 0;
};

struct RuntimeEffectPodInstruction {
    RuntimeEffectPodInstructionOp op = RuntimeEffectPodInstructionOp::END;
    int32_t arg0 = 0;
    int32_t arg1 = 0;
    int64_t value = 0;
};

struct RuntimeEffectPodCommandDefinition {
    RuntimeEffectPodAction action = RuntimeEffectPodAction::CUSTOM_DOMAIN_COMMAND;
    int32_t domain = -1;
    int32_t opcode = 0;
    RuntimeEffectPodTargetResolver target_resolver =
        RuntimeEffectPodTargetResolver::INSTANCE;
    uint64_t static_target = 0;
    RuntimeEffectPodValueMode value_mode = RuntimeEffectPodValueMode::STACK_TOP;
    int64_t value = 0;
    int32_t duration_days = -1;
    int32_t stacks = 1;
    uint64_t command_key_hash = 0;
    uint64_t definition_key_hash = 0;
    std::array<int64_t, 4> payload{};
};

// Behavior functions are registered during cold bootstrap.  The function
// pointer is never serialized; the save stores only behavior metadata and the
// catalog hash.  A missing implementation is a hard plan failure, never a
// reference-only fallback.
struct RuntimeEffectPodBehaviorInput {
    int64_t instance_id = 0;
    uint32_t instance_generation = 0;
    int32_t level = 0;
    int64_t day = 0;
    uint64_t source_handle = 0;
    uint64_t target_handle = 0;
    const int64_t *metrics = nullptr;
    uint32_t metric_count = 0;
};

struct RuntimeEffectPodBehaviorCommand {
    RuntimeEffectPodAction action = RuntimeEffectPodAction::CUSTOM_DOMAIN_COMMAND;
    int32_t domain = -1;
    int32_t opcode = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int64_t value = 0;
    int32_t duration_days = -1;
    int32_t stacks = 1;
    std::array<int64_t, 4> payload{};
};

struct RuntimeEffectPodBehaviorOutput {
    RuntimeEffectPodBehaviorCommand *commands = nullptr;
    uint32_t capacity = 0;
    uint32_t count = 0;
    bool overflowed = false;

    bool emit(const RuntimeEffectPodBehaviorCommand &command) noexcept {
        if (commands == nullptr || count >= capacity) {
            overflowed = true;
            return false;
        }
        commands[count++] = command;
        return true;
    }
};

using RuntimeEffectPodBehaviorFn = bool (*)(
    const RuntimeEffectPodBehaviorInput &, RuntimeEffectPodBehaviorOutput &,
    std::string &error);

struct RuntimeEffectPodBehaviorMetadata {
    uint64_t behavior_id_hash = 0;
    uint32_t version = 1;
    uint32_t max_output = 0;
    uint8_t thread_safe = 1;
    uint8_t implemented = 0;
    uint16_t reserved = 0;
    RuntimeEffectPodBehaviorFn function = nullptr;
};

struct RuntimeEffectPodDefinition {
    uint64_t key_hash = 0;
    int32_t version = 1;
    int32_t cadence_days = 1;
    int32_t max_work = 1024;
    uint8_t enabled = 1;
    uint8_t reserved[3]{};
    uint32_t condition_begin = 0;
    uint32_t condition_count = 0;
    uint32_t instruction_begin = 0;
    uint32_t instruction_count = 0;
    uint32_t command_begin = 0;
    uint32_t command_count = 0;
    uint64_t behavior_id_hash = 0;
    int32_t source_kind = 0;
    int32_t target_domain = 0;
    int32_t operation = 0;
    RuntimeEffectPodLifecycle lifecycle = RuntimeEffectPodLifecycle::NONE;
    int32_t duration_days = -1;
    RuntimeEffectPodStackPolicy stack_policy = RuntimeEffectPodStackPolicy::INDEPENDENT;
    uint64_t stack_key_hash = 0;
    int32_t max_stacks = 1;
    int32_t priority = 0;
    int32_t target_selector_kind = 0;
    uint64_t target_selector_hash = 0;
    std::array<int32_t, 6> magnitude_by_prestige_q16{
        {65536, 65536, 65536, 65536, 65536, 65536}};
};

struct RuntimeEffectPodCatalog {
    uint32_t abi_version = RUNTIME_EFFECT_POD_ABI_VERSION;
    uint32_t catalog_version = RUNTIME_EFFECT_POD_CATALOG_VERSION;
    uint64_t catalog_hash = 0;
    uint32_t max_instances = 4096;
    uint32_t max_transactions = 8192;
    uint32_t max_work_per_slice = 1024;
    uint32_t max_commands_per_transaction = 4096;
    std::vector<uint64_t> metric_key_hashes;
    std::vector<RuntimeEffectPodBehaviorMetadata> behaviors;
    std::vector<RuntimeEffectPodDefinition> definitions;
    std::vector<RuntimeEffectPodCondition> conditions;
    std::vector<RuntimeEffectPodInstruction> instructions;
    std::vector<RuntimeEffectPodCommandDefinition> commands;
};

struct RuntimeEffectPodInstanceInput {
    int64_t instance_id = 0;
    uint32_t generation = 1;
    int32_t program_id = -1;
    int32_t source_type = 0;
    int64_t source_id = 0;
    uint64_t source_handle = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int32_t level = 0;
    int64_t next_due_day = 0;
    bool active = true;
};

struct RuntimeEffectPodInstance {
    int64_t instance_id = 0;
    uint32_t generation = 1;
    int32_t program_id = -1;
    int32_t source_type = 0;
    int64_t source_id = 0;
    uint64_t source_handle = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int32_t level = 0;
    uint32_t metric_base = 0;
    int64_t input_revision = 0;
    int64_t last_evaluated_input_revision = 0;
    int64_t next_due_day = 0;
    int32_t cadence_days = 1;
    RuntimeEffectPodLifecycle lifecycle = RuntimeEffectPodLifecycle::NONE;
    RuntimeEffectPodStackPolicy stack_policy = RuntimeEffectPodStackPolicy::INDEPENDENT;
    int32_t stack_count = 1;
    int32_t applied_stack_count = 0;
    int32_t max_stacks = 1;
    int64_t expires_day = -1;
    uint64_t stack_key_hash = 0;
    uint64_t fire_sequence = 0;
    int64_t pending_transaction_id = 0;
    uint64_t pending_idempotency_key = 0;
    uint64_t last_acked_fire_sequence = 0;
    uint8_t active = 1;
    uint8_t retire_requested = 0;
    uint8_t needs_resync = 0;
    uint8_t reserved = 0;
};

struct RuntimeEffectPodCommand {
    RuntimeEffectPodAction action = RuntimeEffectPodAction::CUSTOM_DOMAIN_COMMAND;
    int32_t domain = -1;
    int32_t opcode = 0;
    uint64_t source_instance_id = 0;
    uint32_t source_generation = 0;
    uint64_t source_handle = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int64_t value = 0;
    int32_t duration_days = -1;
    int32_t stacks = 1;
    uint32_t command_definition_id = 0;
    uint64_t command_key_hash = 0;
    uint64_t definition_key_hash = 0;
    uint64_t idempotency_key = 0;
    int64_t effective_day = 0;
    std::array<int64_t, 4> payload{};
};

struct RuntimeEffectPodTransaction {
    int64_t transaction_id = 0;
    int64_t source_instance_id = 0;
    uint32_t source_generation = 0;
    int64_t effective_day = 0;
    uint64_t plan_hash = 0;
    uint32_t command_begin = 0;
    uint32_t command_count = 0;
    uint32_t required_ack_mask = 0;
    uint32_t received_ack_mask = 0;
    RuntimeEffectPodTransactionStatus status = RuntimeEffectPodTransactionStatus::PLANNED;
    uint8_t retry_count = 0;
    uint8_t duplicate_ack_count = 0;
    uint16_t last_ack_code = 0;
    uint64_t fire_sequence = 0;
    int64_t input_revision = 0;
    int32_t transition_stack_count = 0;
};

struct RuntimeEffectPodSnapshot {
    uint32_t abi_version = RUNTIME_EFFECT_POD_ABI_VERSION;
    uint32_t catalog_version = RUNTIME_EFFECT_POD_CATALOG_VERSION;
    uint64_t catalog_hash = 0;
    uint64_t catalog_revision = 0;
    uint64_t generation = 0;
    uint64_t deterministic_state_hash = 0;
    int64_t committed_day = -1;
    std::vector<int64_t> metric_values;
    std::vector<int64_t> metric_revisions;
    std::vector<RuntimeEffectPodInstance> instances;
    std::vector<RuntimeEffectPodCommand> command_arena;
    std::vector<RuntimeEffectPodTransaction> transactions;
};

struct RuntimeEffectPodPlan {
    RuntimeEffectPodSnapshot next_snapshot;
    std::vector<RuntimeDomainIntent> intents;
    uint64_t base_generation = 0;
    uint64_t input_generation = 0;
    uint64_t deterministic_plan_hash = 0;
    uint32_t required_ack_mask = 0;
    uint32_t received_ack_mask = 0;
    uint32_t emitted_command_count = 0;
    uint32_t retried_transaction_count = 0;
    uint8_t preflight_ok = 0;
    uint8_t committed = 0;
    char error[64]{};
};

struct RuntimeEffectPodReport {
    uint64_t catalog_hash = 0;
    uint64_t generation = 0;
    uint64_t deterministic_state_hash = 0;
    uint64_t deterministic_plan_hash = 0;
    int64_t committed_day = -1;
    uint32_t instance_count = 0;
    uint32_t transaction_count = 0;
    uint32_t pending_transaction_count = 0;
    uint32_t emitted_command_count = 0;
    uint32_t acked_transaction_count = 0;
    uint32_t rejected_transaction_count = 0;
    uint32_t resync_required_count = 0;
    uint32_t retry_count = 0;
    uint32_t duplicate_ack_count = 0;
    uint8_t configured = 0;
    uint8_t plan_ready = 0;
    char blocker[64]{};
};

class RuntimeEffectPodAuthority {
public:
    RuntimeEffectPodAuthority();

    void reset(uint32_t instance_capacity = 4096u,
               uint32_t transaction_capacity = RUNTIME_EFFECT_POD_MAX_TRANSACTIONS,
               uint32_t command_capacity = RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA);
    bool configure(const RuntimeEffectPodCatalog &catalog, std::string &error);
    bool configured() const noexcept { return _configured; }
    uint64_t catalog_hash() const noexcept { return _catalog.catalog_hash; }
    uint64_t catalog_revision() const noexcept { return _catalog_revision; }

    bool upsert_instance(const RuntimeEffectPodInstanceInput &input,
                         std::string &error);
    bool remove_instance(int64_t instance_id, uint32_t generation,
                         std::string &error);
    bool set_metric(int64_t instance_id, uint32_t generation, int32_t metric_id,
                    int64_t revision, int64_t value, std::string &error);

    bool plan_day(int64_t day, uint64_t input_generation,
                  RuntimeEffectPodPlan &plan, std::string &error);
    bool commit_day(RuntimeEffectPodPlan &plan, std::string &error);
    void discard_plan();

    // ACKs are accepted only from the typed downstream protocol.  No method
    // in this class manufactures an OK ACK.  Repeated ACKs are idempotent.
    bool apply_ack(const RuntimeDomainAck &ack, std::string &error);
    bool apply_acks(const std::vector<RuntimeDomainAck> &acks,
                    std::string &error);

    bool snapshot(RuntimeEffectPodSnapshot &out, std::string &error) const;
    const RuntimeEffectPodSnapshot &snapshot() const noexcept { return _snapshot; }
    const RuntimeEffectPodReport &report() const noexcept { return _report; }

    void serialize(std::vector<uint8_t> &out) const;
    bool restore(const uint8_t *data, size_t size, std::string &error);

    static uint64_t hash_text(const char *text) noexcept;
    static uint32_t adapter_ack_bit(RuntimeEffectPodAction action) noexcept;
    static uint16_t adapter_domain(RuntimeEffectPodAction action) noexcept;
    static bool self_test(std::string &error);

private:
    struct State {
        uint64_t generation = 0;
        uint64_t deterministic_state_hash = 1469598103934665603ull;
        int64_t committed_day = -1;
        std::vector<int64_t> metric_values;
        std::vector<int64_t> metric_revisions;
        std::vector<RuntimeEffectPodInstance> instances;
        std::vector<RuntimeEffectPodCommand> command_arena;
        std::vector<RuntimeEffectPodTransaction> transactions;
    };

    static uint64_t hash_mix(uint64_t hash, const void *data, size_t size) noexcept;
    template <typename T>
    static uint64_t hash_value(uint64_t hash, const T &value) noexcept {
        return hash_mix(hash, &value, sizeof(value));
    }
    static uint64_t catalog_hash(const RuntimeEffectPodCatalog &catalog) noexcept;
    static uint64_t state_hash(const State &state) noexcept;
    static uint64_t command_hash(uint64_t hash,
                                 const RuntimeEffectPodCommand &command) noexcept;
    static uint64_t transaction_hash(uint64_t hash,
                                     const RuntimeEffectPodTransaction &transaction) noexcept;
    static bool command_less(const RuntimeEffectPodCommand &a,
                             const RuntimeEffectPodCommand &b) noexcept;
    static bool ack_matches(const RuntimeDomainAck &ack,
                            const RuntimeEffectPodCommand &command) noexcept;
    static bool finite_or_zero(int64_t value) noexcept;
    static void copy_error(char (&destination)[64], const char *source) noexcept;
    void set_blocker(const char *reason) noexcept;
    bool validate_catalog(const RuntimeEffectPodCatalog &catalog,
                          std::string &error) const;
    bool validate_instance(const RuntimeEffectPodInstanceInput &input,
                           std::string &error) const;
    bool evaluate_conditions(const RuntimeEffectPodDefinition &definition,
                             const RuntimeEffectPodInstance &instance,
                             const State &state) const;
    bool execute_program(const RuntimeEffectPodDefinition &definition,
                         const RuntimeEffectPodInstance &instance,
                         const State &state, int64_t day,
                         std::vector<RuntimeEffectPodCommand> &commands,
                         std::string &error) const;
    bool compile_command(const RuntimeEffectPodCommandDefinition &definition,
                         const RuntimeEffectPodInstance &instance,
                         int64_t value, int64_t day, uint64_t fire_sequence,
                         uint32_t command_index,
                         RuntimeEffectPodCommand &out) const;
    bool invoke_behavior(const RuntimeEffectPodDefinition &definition,
                         const RuntimeEffectPodInstance &instance,
                         const State &state, int64_t day,
                         std::vector<RuntimeEffectPodCommand> &commands,
                         std::string &error) const;
    int32_t instance_index(int64_t instance_id, uint32_t generation) const;
    int32_t transaction_index(int64_t transaction_id) const;
    bool append_transaction(State &state, const RuntimeEffectPodInstance &instance,
                            int64_t day,
                            const std::vector<RuntimeEffectPodCommand> &commands,
                            RuntimeEffectPodTransaction &transaction,
                            std::string &error) const;
    void build_snapshot(const State &state, RuntimeEffectPodSnapshot &out) const;
    void rebuild_report(const RuntimeEffectPodPlan *plan = nullptr);

    RuntimeEffectPodCatalog _catalog;
    uint64_t _catalog_revision = 0;
    uint32_t _instance_capacity = 4096u;
    uint32_t _transaction_capacity = RUNTIME_EFFECT_POD_MAX_TRANSACTIONS;
    uint32_t _command_capacity = RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA;
    int64_t _next_transaction_id = 1;
    State _current;
    State _next;
    RuntimeEffectPodSnapshot _snapshot;
    RuntimeEffectPodPlan *_active_plan = nullptr;
    RuntimeEffectPodReport _report{};
    bool _configured = false;
    bool _plan_ready = false;
};

static_assert(std::is_trivially_copyable_v<RuntimeEffectPodCondition>);
static_assert(std::is_trivially_copyable_v<RuntimeEffectPodInstruction>);
static_assert(std::is_trivially_copyable_v<RuntimeEffectPodCommandDefinition>);
static_assert(std::is_trivially_copyable_v<RuntimeEffectPodDefinition>);
static_assert(std::is_trivially_copyable_v<RuntimeEffectPodInstance>);
static_assert(std::is_trivially_copyable_v<RuntimeEffectPodCommand>);
static_assert(std::is_trivially_copyable_v<RuntimeEffectPodTransaction>);

} // namespace pk

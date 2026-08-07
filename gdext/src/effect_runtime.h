#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <queue>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

class ModifierRuntime;

// Generic effect plan/transaction authority. It evaluates immutable catalog
// programs against submitted POD snapshots and emits typed commands. Domain
// runtimes remain the owners of all authoritative state and acknowledge the
// resulting transactions at their safe commit boundaries.
class EffectRuntime {
public:
    static constexpr int32_t PROTOCOL_VERSION = 1;
    static constexpr int32_t SAVE_SCHEMA_VERSION = 4;
    static constexpr int64_t Q16_ONE = 65536;

    enum Instruction : int32_t {
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
    enum ConditionOp : int32_t {
        CONDITION_TRUE = 1,
        METRIC_GTE = 2,
        METRIC_LTE = 3,
        METRIC_EQ = 4,
        STATE_GTE = 5,
        BOOL_AND = 6,
        BOOL_OR = 7,
        BOOL_NOT = 8,
    };
    enum Action : int32_t {
        MODIFIER_COMMAND = 1,
        COUNTRY_COMMAND = 2,
        ECONOMY_COMMAND = 3,
        GAMEPLAY_COMMAND = 4,
        PUBLISH_EVENT = 5,
        CUSTOM_DOMAIN_COMMAND = 6,
    };
    enum TargetResolver : int32_t {
        TARGET_STATIC = 0,
        TARGET_INSTANCE = 1,
        TARGET_SOURCE = 2,
    };
    enum ValueMode : int32_t {
        VALUE_CONSTANT = 0,
        VALUE_STACK_TOP = 1,
    };
    enum TransactionStatus : int32_t {
        PLANNED = 1,
        PREFLIGHTED = 2,
        COMMITTED = 3,
        ACKED = 4,
        REJECTED = 5,
        RESYNC_REQUIRED = 6,
    };

    struct BehaviorCommand {
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t domain = -1;
        int32_t opcode = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int64_t value_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        // Index into the catalog's behavior_command_keys table. -1 means the
        // behavior uses the domain/opcode default adapter key.
        int32_t command_key_id = -1;
        std::array<int64_t, 4> payload{};
    };

    struct BehaviorInput {
        int64_t instance_id = 0;
        uint32_t instance_generation = 0;
        int32_t program_id = -1;
        int32_t level = 0;
        int64_t day = 0;
        uint64_t target_handle = 0;
        uint64_t source_handle = 0;
        const int64_t *metrics = nullptr;
        int32_t metric_count = 0;
    };
    struct BehaviorOutput {
        BehaviorCommand *commands = nullptr;
        int32_t capacity = 0;
        int32_t count = 0;
        bool overflowed = false;

        bool emit(const BehaviorCommand &command) {
            if (commands == nullptr || count < 0 || count >= capacity) {
                overflowed = true;
                return false;
            }
            commands[count++] = command;
            return true;
        }
    };
    using BehaviorFn = bool (*)(const BehaviorInput &, BehaviorOutput &,
                                std::string &error);

    // Compile-time C++ extension point. Registration is cold-path only.
    static bool register_behavior(const std::string &behavior_id,
                                  BehaviorFn fn);
    static bool unregister_behavior(const std::string &behavior_id);

    godot::Dictionary configure(const godot::Dictionary &catalog);
    // Native domain runtimes use this POD entry point at structural commit
    // boundaries. It avoids constructing Godot Dictionaries in hot loops while
    // keeping EffectRuntime as the sole owner of instance lifecycle.
    bool upsert_instance_pod(int64_t instance_id, const std::string &program_key,
                             uint32_t generation, int32_t source_type,
                             int64_t source_id, uint64_t source_handle,
                             uint64_t target_handle, uint32_t target_generation,
                             int32_t level, int64_t next_due_day, bool active,
                             std::string &error);
    bool has_instance_pod(int64_t instance_id, uint32_t generation) const;
    bool instance_fire_acked_pod(int64_t instance_id, uint32_t generation) const;
    bool set_metric_pod(int64_t instance_id, int32_t metric_id,
                        int64_t revision, int64_t value_q16,
                        std::string &error);
    // Emits the final native Modifier removal. The instance is reclaimed only
    // after its transaction receives the domain ACK.
    bool retire_instance_pod(int64_t instance_id, uint32_t generation,
                             int64_t effective_day, std::string &error);
    // Converts one already-evaluated Trigger effect into an Effect-owned
    // one-shot transaction. The trigger remains the fact/state owner.
    bool enqueue_trigger_effect_pod(int64_t effect_id, int64_t effective_day,
                                    int32_t trigger_id, uint64_t target_handle,
                                    uint32_t target_generation,
                                    uint64_t fire_sequence, int32_t action,
                                    int32_t domain, int32_t opcode,
                                    int64_t resolved_value, int32_t duration_days,
                                    int32_t stacks, const std::string &command_key,
                                    const std::string &definition_key,
                                    const std::array<int64_t, 4> &payload,
                                    std::string &error);
    godot::Dictionary submit_instances(const godot::Dictionary &batch);
    godot::Dictionary submit_snapshots(const godot::Dictionary &batch);
    godot::Dictionary run_daily(int64_t day_index);
    // Native production bridge. It submits typed Modifier commands without
    // constructing a Godot Dictionary/Callable per effect transaction.
    godot::Dictionary dispatch_native_modifier(ModifierRuntime *modifier_runtime);
    godot::Dictionary ack_native_modifier(ModifierRuntime *modifier_runtime);
    bool should_run(int64_t day_index) const;
    godot::Dictionary poll_transactions(int64_t after_transaction_id,
                                         int32_t limit) const;
    godot::Dictionary preflight_transactions(const godot::Dictionary &batch);
    godot::Dictionary commit_transactions(const godot::Dictionary &batch);
    godot::Dictionary ack_transactions(const godot::Dictionary &batch);
    godot::Dictionary explain(int64_t instance_id) const;
    godot::Dictionary report() const;
    godot::PackedByteArray capture() const;
    godot::Dictionary restore(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_state();

private:
    struct Condition {
        int32_t op = CONDITION_TRUE;
        int32_t arg0 = 0;
        int64_t value = 0;
    };
    struct InstructionRow {
        int32_t op = END;
        int32_t arg0 = 0;
        int32_t arg1 = 0;
        int64_t value = 0;
    };
    struct CommandDefinition {
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t domain = -1;
        int32_t opcode = 0;
        int32_t target_resolver = TARGET_INSTANCE;
        uint64_t static_target = 0;
        int32_t value_mode = VALUE_STACK_TOP;
        int64_t value = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        std::array<int64_t, 4> payload{};
    };
    struct Definition {
        std::string key;
        int32_t version = 1;
        int32_t cadence_days = 1;
        int32_t max_work = 1024;
        uint8_t enabled = 1;
        int32_t condition_begin = 0;
        int32_t condition_count = 0;
        int32_t instruction_begin = 0;
        int32_t instruction_count = 0;
        int32_t command_begin = 0;
        int32_t command_count = 0;
        std::string behavior_id;
    };
    struct Instance {
        int64_t id = 0;
        uint32_t generation = 1;
        int32_t program_id = -1;
        int32_t source_type = 0;
        int64_t source_id = 0;
        uint64_t source_handle = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int32_t level = 0;
        int64_t next_due_day = 0;
        int64_t input_revision = 0;
        // A newer frozen input revision may be evaluated before cadence so an
        // event-driven metric publish is visible in the current simulation day.
        int64_t last_evaluated_input_revision = 0;
        uint64_t fire_sequence = 0;
        uint8_t active = 1;
        // Metrics live in the runtime-wide flat slabs. Keeping only the base
        // row here avoids one heap allocation per instance.
        uint32_t metric_base = 0;
        uint32_t dirty_epoch = 0;
        uint64_t schedule_token = 0;
    };
    struct Command {
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t domain = -1;
        int32_t opcode = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int64_t value_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        // Config commands reference CommandDefinition rows; behavior commands
        // reference the optional behavior_command_keys table.
        int32_t command_key_id = -1;
        int32_t command_definition_id = -1;
        std::array<int64_t, 4> payload{};
        uint64_t idempotency_key = 0;
    };
    struct Transaction {
        int64_t id = 0;
        int64_t source_instance_id = 0;
        uint32_t source_generation = 0;
        int32_t program_id = -1;
        int64_t effective_day = 0;
        uint64_t plan_hash = 0;
        uint32_t required_ack_mask = 0;
        uint32_t received_ack_mask = 0;
        int32_t status = PLANNED;
        uint32_t command_begin = 0;
        uint32_t command_count = 0;
    };
    struct PlannedCandidate {
        int32_t candidate_cursor = -1;
        int32_t instance_index = -1;
        int32_t work = 1;
        uint8_t eligible = 0;
        uint8_t enabled = 0;
        uint8_t passes = 0;
        uint8_t behavior_failure = 0;
        uint8_t overflowed = 0;
        uint64_t planned_fire_sequence = 0;
        uint32_t required_ack_mask = 0;
        std::vector<Command> commands;
        std::string error;
    };
    struct DueNode {
        int64_t day = 0;
        int32_t instance_index = -1;
        uint32_t generation = 0;
        uint64_t schedule_token = 0;
        bool operator>(const DueNode &other) const {
            if (day != other.day) return day > other.day;
            if (instance_index != other.instance_index)
                return instance_index > other.instance_index;
            return schedule_token > other.schedule_token;
        }
    };
    struct NativeAckBinding {
        int64_t transaction_id = 0;
        uint32_t request_begin = 0;
        uint32_t request_count = 0;
    };

    bool evaluate_condition(const Definition &definition,
                            const Instance &instance) const;
    bool execute_program(const Definition &definition, Instance &instance,
                         int64_t day, Transaction &transaction,
                         std::string &error);
    bool execute_program_plan(const Definition &definition, const Instance &instance,
                              int64_t day, std::vector<Command> &commands,
                              uint32_t &required_ack_mask, std::string &error) const;
    bool build_planned_candidate(int32_t candidate_cursor, int32_t instance_index,
                                 int64_t day, PlannedCandidate &plan) const;
    static void append_planned_command(std::vector<Command> &commands,
                                       uint32_t &required_ack_mask,
                                       const Command &command);
    void append_command(Transaction &transaction, const Command &command);
    void index_transaction_commands(const Transaction &transaction);
    void unindex_transaction_commands(const Transaction &transaction);
    void track_pending_transaction(const Transaction &transaction);
    void untrack_pending_transaction(const Transaction &transaction);
    void rebuild_command_idempotency_index();
    void compact_terminal_transactions();
    bool create_retirement_transaction(int32_t instance_index,
                                       int64_t effective_day,
                                       std::string &error);
    void release_retired_instance_if_terminal(int32_t instance_index);
    const Command *command_at(const Transaction &transaction,
                               uint32_t ordinal) const;
    int32_t transaction_index_for_id(int64_t transaction_id) const;
    int64_t *metric_ptr(Instance &instance, int32_t metric_id);
    const int64_t *metric_ptr(const Instance &instance, int32_t metric_id) const;
    void schedule_instance(int32_t index, int64_t day);
    void compact_due_heap_if_needed();
    void mark_dirty(int32_t index);
    void rebuild_run_candidates(int64_t day_index);
    uint64_t command_idempotency_key(const Instance &instance,
                                     uint32_t command_index) const;
    int32_t definition_id_for_key(const std::string &key) const;
    int32_t instance_index_for_id(int64_t id) const;
    int64_t metric_value(const Instance &instance, int32_t metric_id) const;
    int64_t state_value(const Instance &instance, int32_t state_id) const;
    std::string command_key_for(const Command &command) const;
    std::string command_definition_key_for(const Transaction &transaction,
                                           const Command &command) const;
    void reset_runtime_state();

    bool _configured = false;
    uint64_t _catalog_hash = 0;
    int32_t _metric_count = 0;
    int32_t _max_instances = 4096;
    int32_t _max_transactions = 8192;
    int32_t _max_work_per_slice = 1024;
    int64_t _current_day = -1;
    int64_t _last_completed_day = -1;
    int64_t _run_day = -1;
    int32_t _run_cursor = 0;
    int64_t _next_transaction_id = 1;
    int64_t _acked_transaction_id = 0;
    uint64_t _instances_submitted = 0;
    uint64_t _programs_evaluated = 0;
    uint64_t _commands_emitted = 0;
    uint64_t _transactions_acked = 0;
    uint64_t _preflight_rejects = 0;
    uint64_t _behavior_failures = 0;
    uint64_t _overflow_count = 0;
    uint64_t _native_modifier_transactions = 0;
    uint64_t _native_modifier_commands = 0;
    uint64_t _native_modifier_acks = 0;
    double _last_evaluate_ms = 0.0;
    double _last_native_dispatch_ms = 0.0;
    double _last_native_ack_ms = 0.0;
    double _last_parallel_planning_ms = 0.0;
    double _last_parallel_merge_ms = 0.0;
    int32_t _last_parallel_worker_count = 1;
    uint64_t _parallel_dispatches = 0;
    uint64_t _serial_fallback_dispatches = 0;
    std::string _last_parallel_path = "serial";
    std::string _last_parallel_fallback_reason;
    std::string _last_error;

    std::vector<std::string> _metric_keys;
    std::vector<std::string> _behavior_command_keys;
    std::unordered_map<std::string, int32_t> _metric_ids;
    std::vector<Definition> _definitions;
    std::unordered_map<std::string, int32_t> _definition_ids;
    std::vector<Condition> _conditions;
    std::vector<InstructionRow> _instructions;
    std::vector<CommandDefinition> _command_definitions;
    std::vector<BehaviorCommand> _behavior_command_buffer;
    std::vector<Instance> _instances;
    // Retired instances keep their metric slab row and backing slot stable;
    // future upserts reuse these indices without growing instance capacity.
    std::vector<int32_t> _free_instance_indices;
    std::unordered_map<int64_t, int32_t> _instance_ids;
    std::vector<int64_t> _metric_values;
    std::vector<uint8_t> _metric_present;
    std::vector<int32_t> _dirty_queue;
    uint32_t _dirty_epoch_counter = 1;
    std::priority_queue<DueNode, std::vector<DueNode>, std::greater<DueNode>> _due_heap;
    std::vector<int32_t> _run_candidates;
    int32_t _candidate_cursor = 0;
    uint64_t _schedule_token = 1;
    std::vector<Command> _command_arena;
    std::vector<Transaction> _transactions;
    std::unordered_map<int64_t, int32_t> _transaction_ids;
    std::unordered_map<int64_t, uint32_t> _pending_transactions_by_instance;
    std::unordered_map<uint64_t, uint32_t> _pending_command_idempotency;
    std::vector<int64_t> _native_request_ids;
    std::vector<NativeAckBinding> _native_ack_bindings;
    std::unordered_set<int64_t> _native_bound_transaction_ids;
    int32_t _max_native_modifier_commands = 4096;
};

} // namespace pk

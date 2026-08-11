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
class NativeCountryRuntime;
class NativeEconomyRuntime;
class DCWorldExt;

// Generic effect plan/transaction authority. It evaluates immutable catalog
// programs against submitted POD snapshots and emits typed commands. Domain
// runtimes remain the owners of all authoritative state and acknowledge the
// resulting transactions at their safe commit boundaries.
class EffectRuntime {
public:
    static constexpr int32_t PROTOCOL_VERSION = 1;
    static constexpr int32_t SAVE_SCHEMA_VERSION = 9;
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

    // Durable identity for an external owner (ideology, trigger, etc.).  The
    // transaction row is intentionally reclaimable after ACK; this binding is
    // the compact proof that a peer-owned persistent effect still exists.
    struct ExternalSourceBinding {
        int64_t binding_id = 0;
        uint32_t generation = 1;
        int32_t source_type = 0;
        int64_t source_id = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int32_t level = -1;
        uint8_t location = 0;
        uint8_t active = 0;
        uint64_t template_signature = 0;
        uint64_t program_hash = 0;
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
    bool upsert_external_binding_pod(int64_t binding_id, uint32_t generation,
                                     int32_t source_type, int64_t source_id,
                                     uint64_t target_handle,
                                     uint32_t target_generation, int32_t level,
                                     uint8_t location, uint64_t template_signature,
                                     uint64_t program_hash, std::string &error);
    bool retire_external_binding_pod(int64_t binding_id, uint32_t generation,
                                     std::string &error);
    bool has_external_binding_pod(int64_t binding_id, uint32_t generation,
                                  int32_t source_type, int64_t source_id,
                                  uint64_t target_handle,
                                  uint32_t target_generation, int32_t level,
                                  uint8_t location,
                                  uint64_t template_signature,
                                  uint64_t program_hash) const;
    // Strict restore audit for peer-owned transitions. Every expected
    // transaction must still be pending under the declared external source,
    // and no other pending transaction for the same target may exist.
    bool verify_external_pending_transactions_pod(
        int32_t source_type, uint64_t target_handle, uint64_t source_id_mask,
        const std::vector<int64_t> &expected_transaction_ids,
        const std::vector<uint64_t> &expected_source_ids,
        std::string &error) const;
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
    // Typed ingress for peer authorities (currently ideology).  The caller
    // supplies a precompiled program and command-template identity; Effect
    // Runtime still owns the transaction, idempotency and domain ACK.
    bool enqueue_external_effect_pod(int64_t effect_id, int64_t effective_day,
                                     int32_t source_type, int64_t source_id,
                                     const std::string &program_key,
                                     uint64_t source_handle, uint64_t target_handle,
                                     uint32_t target_generation,
                                     uint64_t fire_sequence, int32_t action,
                                     int32_t domain, int32_t opcode,
                                     int64_t resolved_value, int32_t duration_days,
                                     int32_t stacks, const std::string &command_key,
                                     const std::string &definition_key,
                                     const std::array<int64_t, 4> &payload,
                                     std::string &error,
                                     int64_t *out_transaction_id = nullptr);
    // Built-in two-domain transaction used by the Economy-owned expedition
    // state machine. Both commands share one transaction and therefore remain
    // unpublished until Country and Economy have independently ACKed.
    bool enqueue_family_colonization_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t country_handle, uint32_t country_generation,
        uint64_t expedition_handle, uint32_t expedition_generation,
        int32_t target_cell, uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id = nullptr);
    // Built-in geography transaction used by Economy-owned canal projects.
    // The command payload is deliberately only the project handle; the
    // gameplay adapter resolves the bounded route from EconomyRuntime.
    bool enqueue_canal_commit_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t project_handle, uint32_t project_generation,
        uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id = nullptr);
    // Peer runtimes retain only transaction IDs. ACKED rows can be compacted,
    // while REJECTED rows remain queryable until their producer observes them.
    int32_t transaction_status_pod(int64_t transaction_id) const;
    bool consume_rejected_transaction_pod(int64_t transaction_id,
                                          int64_t source_id);
    godot::Dictionary submit_instances(const godot::Dictionary &batch);
    godot::Dictionary submit_snapshots(const godot::Dictionary &batch);
    godot::Dictionary run_daily(int64_t day_index);
    // Native production bridge. It submits typed Modifier commands without
    // constructing a Godot Dictionary/Callable per effect transaction.
    godot::Dictionary dispatch_native_modifier(ModifierRuntime *modifier_runtime);
    godot::Dictionary ack_native_modifier(ModifierRuntime *modifier_runtime);
    godot::Dictionary dispatch_native_country(NativeCountryRuntime *country_runtime);
    godot::Dictionary ack_native_country(NativeCountryRuntime *country_runtime);
    godot::Dictionary dispatch_native_economy(NativeEconomyRuntime *economy_runtime);
    godot::Dictionary ack_native_economy(NativeEconomyRuntime *economy_runtime);
    godot::Dictionary dispatch_native_gameplay(DCWorldExt *world_ext);
    godot::Dictionary ack_native_gameplay(DCWorldExt *world_ext);
    bool should_run(int64_t day_index) const;
    uint64_t catalog_hash() const { return _catalog_hash; }
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
    void attach_country_runtime(NativeCountryRuntime *runtime) {
        _country_runtime = runtime;
    }
    bool bind_era_reward_player_country_pod(uint64_t country_handle,
                                            std::string &error);
    bool notify_era_reward_technology_activated_pod(
        uint64_t country_handle, int32_t technology_id, int64_t day_index,
        std::string &error);
    godot::Dictionary era_reward_offer_snapshot();
    godot::Dictionary choose_era_reward(int64_t offer_generation,
                                        int32_t choice_index,
                                        int64_t effective_day);

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
    enum NativeModifierAdapterKind : int32_t {
        NATIVE_MODIFIER_GENERIC = 0,
        NATIVE_MODIFIER_TECHNOLOGY = 1,
        NATIVE_MODIFIER_FAMILY = 2,
        NATIVE_MODIFIER_PERSON = 3,
        NATIVE_MODIFIER_TRIGGER = 4,
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
        int32_t native_modifier_adapter = NATIVE_MODIFIER_GENERIC;
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
        uint32_t domain_bit = 0;
    };
    struct EraRewardRule {
        int32_t code = 0;
        int64_t threshold = 0;
        int32_t multiplier_q16 = Q16_ONE;
        int32_t signal_index = -1;
        int32_t route_technology_begin = 0;
        int32_t route_technology_count = 0;
        std::string reason;
    };
    struct EraRewardOption {
        std::string id;
        std::string title;
        std::string description;
        std::string icon;
        int32_t base_weight = 1;
        uint8_t fallback = 0;
        int32_t eligibility_code = 0;
        int64_t eligibility_threshold = 0;
        int32_t rule_begin = 0;
        int32_t rule_count = 0;
        int32_t program_id = -1;
    };
    struct EraRewardPool {
        std::string id;
        std::string title;
        int32_t trigger_technology = -1;
        uint8_t final_pool = 0;
        int32_t option_begin = 0;
        int32_t option_count = 0;
    };
    struct EraRewardAlternative {
        int32_t option_index = -1;
        int64_t weight = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        std::array<std::string, 2> reasons{};
        int32_t reason_count = 0;
        std::string target_summary;
    };
    struct EraRewardOffer {
        int64_t plan_id = 0;
        int64_t generation = 0;
        int32_t pool_index = -1;
        int32_t milestone_technology = -1;
        uint64_t country_handle = 0;
        uint32_t country_generation = 0;
        int32_t status = 0;
        int32_t selected_choice = -1;
        int64_t transaction_id = 0;
        uint64_t plan_hash = 0;
        std::array<EraRewardAlternative, 3> alternatives{};
        std::string error;
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
    // The content domain on a Modifier command is a ModifierRuntime subdomain
    // (country/economy/gameplay), not an Effect adapter identity.  ACK state
    // must therefore be keyed by the adapter/action that owns the safe commit
    // boundary, otherwise a Country modifier (domain 1) aliases a Country
    // command (also domain 1) in a mixed transaction.
    static uint32_t adapter_ack_bit_for(const Command &command);
    void append_command(Transaction &transaction, const Command &command);
    void index_transaction_commands(const Transaction &transaction);
    void unindex_transaction_commands(const Transaction &transaction);
    void track_pending_transaction(const Transaction &transaction);
    void untrack_pending_transaction(const Transaction &transaction);
    // Returns true only when this domain ACK completed the transaction's full
    // domain mask. A transaction may otherwise remain COMMITTED while another
    // native domain is still pending at its own safety boundary.
    bool acknowledge_native_domain(Transaction &transaction, uint32_t domain_bit);
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
    bool compile_era_reward_catalog(const godot::Dictionary &catalog,
                                    std::string &error);
    bool plan_era_reward_offer(int32_t pool_index, uint64_t country_handle,
                               int64_t day_index, std::string &error);
    void refresh_era_reward_offer_status();
    bool era_reward_option_eligible(const EraRewardOption &option,
                                    int64_t cash, int32_t territory,
                                    int64_t completed, int64_t signals) const;
    int64_t era_reward_option_weight(const EraRewardOption &option,
                                     int64_t cash, int32_t territory,
                                     int64_t completed, int64_t signals,
                                     const godot::PackedInt32Array &signal_counts,
                                     const godot::PackedInt32Array &technology_states,
                                     std::array<std::string, 2> &reasons,
                                     int32_t &reason_count) const;

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
    uint64_t _native_country_transactions = 0;
    uint64_t _native_country_commands = 0;
    uint64_t _native_country_acks = 0;
    uint64_t _native_economy_transactions = 0;
    uint64_t _native_economy_commands = 0;
    uint64_t _native_economy_acks = 0;
    uint64_t _native_gameplay_transactions = 0;
    uint64_t _native_gameplay_commands = 0;
    uint64_t _native_gameplay_acks = 0;
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
    NativeCountryRuntime *_country_runtime = nullptr;

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
    std::vector<ExternalSourceBinding> _external_bindings;
    std::unordered_map<int64_t, int32_t> _external_binding_ids;
    std::vector<int64_t> _native_request_ids;
    std::vector<NativeAckBinding> _native_ack_bindings;
    std::unordered_set<int64_t> _native_bound_transaction_ids;
    std::vector<int64_t> _native_country_request_ids;
    std::vector<NativeAckBinding> _native_country_ack_bindings;
    std::unordered_set<int64_t> _native_country_bound_transaction_ids;
    std::vector<int64_t> _native_economy_request_ids;
    std::vector<NativeAckBinding> _native_economy_ack_bindings;
    std::unordered_set<int64_t> _native_economy_bound_transaction_ids;
    std::vector<int64_t> _native_gameplay_request_ids;
    std::vector<NativeAckBinding> _native_gameplay_ack_bindings;
    std::unordered_set<int64_t> _native_gameplay_bound_transaction_ids;
    int32_t _max_native_modifier_commands = 4096;
    std::vector<EraRewardPool> _era_reward_pools;
    std::vector<EraRewardOption> _era_reward_options;
    std::vector<EraRewardRule> _era_reward_rules;
    std::vector<int32_t> _era_reward_route_technology_indices;
    std::unordered_map<int32_t, int32_t> _era_reward_pool_by_technology;
    uint64_t _era_reward_player_country = 0;
    int64_t _era_reward_next_plan_id = 1;
    int64_t _era_reward_next_generation = 1;
    EraRewardOffer _era_reward_offer;
    double _last_era_reward_plan_ms = 0.0;
    uint64_t _era_reward_offers_planned = 0;
    int32_t _last_era_reward_expanded_commands = 0;
};

} // namespace pk

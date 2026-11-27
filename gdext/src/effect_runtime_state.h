// Private catalog definitions, active instances, transaction queues, and persistence.

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
        NATIVE_MODIFIER_FAMILY_EFFECT = 5,
        // Declarative managed programs owned by a domain that is not family
        // (ideology today). Same lifecycle / stack / target semantics, but the
        // modifier producer and source_type stay with the owning domain.
        NATIVE_MODIFIER_IDEOLOGY = 6,
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
        int32_t owner_program_id = -1;
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
        int32_t source_kind = 0;
        int32_t target_domain = 0;
        int32_t operation = 0;
        int32_t lifecycle = 0;
        int32_t duration_days = -1;
        int32_t stack_policy = 0;
        std::string stack_key;
        int32_t max_stacks = 1;
        int32_t priority = 0;
        int32_t target_selector_kind = 0;
        std::string target_selector_id;
        // [0] = cell cap for the generalised selectors, [1] = terrain id /
        // resource id / predicate id. Both default to 0, which every consumer
        // reads as "unset" rather than "first terrain".
        int32_t target_selector_param[2] = {0, 0};
        // Declared ownership of the managed lifecycle instead of inferring it
        // from a "family.effect." key prefix. Catalog column `managed_flags`
        // wins when present; otherwise the legacy prefix rule applies so every
        // pre-existing catalog and test fixture keeps its behaviour.
        bool managed_declared = false;
        int32_t magnitude_by_prestige_q16[6] = {
            Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE};
    };
    // The stack machine, parameterised on where metric reads come from.
    //
    // Declared AFTER `struct Definition` because it names that type; an earlier
    // placement above the struct failed to compile (C4430/C2143).
    //
    // Extracted from `preview_family_effect_value` so a caller with its own
    // per-cell samples can run the SAME bytecode without an `Instance`. A second
    // evaluator for the derived layer would be one more place to keep in step with
    // the instruction set, and plan §15.5 forbids the simplification that would
    // follow (freezing a Ramp into a threshold bucket).
    bool run_program_machine(
        const Definition &definition,
        const std::function<int64_t(int32_t)> &metric_accessor,
        const std::function<int64_t(int32_t)> &state_accessor,
        int64_t &value, std::string &error) const;
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
        // Highest revision this instance has SEEN, independent of whether that
        // publish changed anything. `input_revision` is the change watermark:
        // it only advances when a metric value actually differs, because
        // downstream work (dirty groups, Modifier remove/re-add, ACK) keys off
        // `input_revision > applied_input_revision`. Splitting the two keeps a
        // genuinely stale snapshot detectable without letting an unchanged
        // publish look like a change. Derived, never serialised.
        int64_t metric_observed_revision = 0;
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
        int32_t source_kind = 0;
        int32_t target_domain = 0;
        int32_t operation = 0;
        int32_t lifecycle = 0;
        int32_t duration_days = -1;
        int32_t stack_policy = 0;
        int32_t max_stacks = 1;
        // Requested source contribution. Group arbitration derives the
        // applied count without destroying this value, so a capped source can
        // become active when another source leaves the same stack group.
        int32_t stack_count = 1;
        // How many of those stacks the owning domain has actually applied.
        // PKEF carries BOTH this and `effect_applied`, and `restore()` requires them
        // to agree ONLY for a managed definition (`uses_managed_lifecycle`), which is
        // the only place both are advanced together. An unmanaged program's worker
        // write-back legitimately carries `(0, N)`: the POD keeps this count as fire
        // bookkeeping and never sets the latch, because nothing reads the latch for a
        // one-shot program. Reading the two as an unconditional pair is what used to
        // make an EFFECT-worker PKEF unloadable -- see `EffectRuntime::restore`.
        int32_t applied_stack_count = 0;
        int32_t priority = 0;
        // Per-instance magnitude multiplier (L3-9 second slice). The program's
        // compiled `value_q16` is the base; this scales it for THIS instance
        // only, which is the one thing a card can rewrite about another card's
        // program without turning the shared program template into per-instance
        // data. 1.0 means "no override" and is what every pre-existing caller
        // gets, because the batch column is optional.
        int32_t magnitude_scale_q16 = Q16_ONE;
        uint64_t activation_sequence = 0;
        int64_t expires_day = -1;
        uint64_t stack_key_hash = 0;
        // Last evaluation's raw condition result, exposed as STATE_LATCHED.
        // Written wherever a condition is actually evaluated: the day pass on
        // this side, plan_day / set_metric on the worker. The one place that
        // deliberately does NOT write is build_planned_candidate -- it is a dry
        // run whose result may be discarded, so advancing the latch there would
        // let a plan that never executed move the hysteresis band.
        uint8_t latched = 0;
        // Domain-ACKed application state. Managed definitions only emit when
        // this state or the frozen input revision changes.
        uint8_t effect_applied = 0;
        uint8_t retire_requested = 0;
        int64_t applied_input_revision = 0;
        uint64_t last_acked_fire_sequence = 0;
        // Transient arbitration cache. Recomputed once per dirty candidate
        // epoch and intentionally excluded from PKEF.
        uint32_t stack_decision_epoch = 0;
        int32_t desired_stack_count = 0;
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
        int64_t external_effect_id = 0;
        int64_t external_source_id = 0;
        // Mirrors `ExternalEffectCommandPod::stable_source_identity`: when set, the
        // Modifier row this command produces is keyed by `external_source_id` rather than
        // by the per-fire instance id. Only synergy rows opt in (see that field's comment).
        bool external_source_is_stable = false;
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
        int32_t instance_transition = TRANSITION_NONE;
        int64_t transition_input_revision = 0;
        uint64_t transition_fire_sequence = 0;
        int32_t transition_stack_count = 0;
        uint32_t command_begin = 0;
        uint32_t command_count = 0;
    };
    struct FamilyEffectGroupKey {
        int32_t target_domain = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        uint64_t stack_key_hash = 0;
        bool operator==(const FamilyEffectGroupKey &other) const {
            return target_domain == other.target_domain &&
                target_handle == other.target_handle &&
                target_generation == other.target_generation &&
                stack_key_hash == other.stack_key_hash;
        }
    };
    struct FamilyEffectGroupKeyHash {
        size_t operator()(const FamilyEffectGroupKey &key) const {
            uint64_t value = key.stack_key_hash;
            value ^= key.target_handle + 0x9e3779b97f4a7c15ULL +
                (value << 6U) + (value >> 2U);
            value ^= static_cast<uint64_t>(key.target_generation) << 32U;
            value ^= static_cast<uint32_t>(key.target_domain);
            return static_cast<size_t>(value);
        }
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
    template <typename MetricFn, typename StateFn>
    bool run_condition_machine(const Definition &definition, MetricFn metric,
                               StateFn state) const;
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
    // THE Effect->Modifier row mapping. `dispatch_native_modifier` and
    // `collect_worker_modifier_rows` both call this: how strong a row is
    // (`magnitude_scale_q16` from the source instance), which source identity it
    // carries (adapter-specific, and the synergy `stable_source_identity` opt-in)
    // and which Modifier scope/handles it targets are all decided HERE, once.
    bool map_modifier_row(const Transaction &transaction,
                          const Instance &source_instance,
                          const Command &command,
                          ModifierRow &out) const;
    int32_t finish_worker_modifier_bindings(
        const std::vector<int64_t> &transaction_ids, bool confirm);
    void append_command(Transaction &transaction, const Command &command);
    void index_transaction_commands(const Transaction &transaction);
    void unindex_transaction_commands(const Transaction &transaction);
    void track_pending_transaction(const Transaction &transaction);
    void untrack_pending_transaction(const Transaction &transaction);
    // Returns true only when this domain ACK completed the transaction's full
    // domain mask. A transaction may otherwise remain COMMITTED while another
    // native domain is still pending at its own safety boundary.
    bool acknowledge_native_domain(Transaction &transaction, uint32_t domain_bit);
    void apply_acked_instance_transition(const Transaction &transaction);
    void apply_rejected_instance_transition(const Transaction &transaction);
    static bool uses_managed_lifecycle(const Definition &definition);
    bool is_family_effect_instance(const Instance &instance) const;
    FamilyEffectGroupKey family_effect_group_key(const Instance &instance) const;
    void add_family_effect_group_member(int32_t instance_index);
    void remove_family_effect_group_member(int32_t instance_index,
                                           const FamilyEffectGroupKey &key);
    void rebuild_family_effect_groups();
    void mark_family_effect_group_dirty(int32_t instance_index);
    bool resolve_family_effect_group(int32_t instance_index, int64_t day,
                                     std::string &error);
    bool preview_family_effect_value(const Definition &definition,
                                     const Instance &instance,
                                     int64_t &value, std::string &error) const;
    void rebuild_command_idempotency_index();
    void compact_terminal_transactions();
    bool create_retirement_transaction(int32_t instance_index,
                                       int64_t effective_day,
                                       std::string &error,
                                       bool retire_instance = true);
    void release_retired_instance_if_terminal(int32_t instance_index);
    const Command *command_at(const Transaction &transaction,
                               uint32_t ordinal) const;
    uint64_t persisted_plan_hash(const Transaction &transaction,
                                const std::vector<Command> &arena) const;
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
    void advance_committed_generation();
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
    uint64_t _committed_generation = 1;
    int32_t _metric_count = 0;
    int32_t _max_instances = 4096;
    int32_t _max_transactions = 8192;
    int32_t _max_work_per_slice = 1024;
    int64_t _current_day = -1;
    int64_t _last_completed_day = -1;
    int64_t _run_day = -1;
    int32_t _run_cursor = 0;
    int64_t allocate_builtin_transaction_id();
    int64_t _next_transaction_id = 1;
    int64_t _acked_transaction_id = 0;
    uint64_t _next_activation_sequence = 1;
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
    const NativeCountryRuntime *_era_reward_country_view = nullptr;

    std::vector<std::string> _metric_keys;
    std::vector<std::string> _behavior_command_keys;
    std::unordered_map<std::string, int32_t> _metric_ids;
    // Optional tag predicate table (see target_tag.h). Owned here because it is
    // catalog data and shares the catalog's lifecycle; consumed by the economy's
    // territory selector, which copies it once instead of reaching through this
    // pointer from a const query path.
    TargetTagTable _target_tags;
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
    uint32_t _stack_decision_epoch = 1;
    std::unordered_map<FamilyEffectGroupKey, std::vector<int32_t>,
                       FamilyEffectGroupKeyHash> _family_effect_groups;
    std::vector<int32_t> _family_effect_candidate_scratch;
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
    // Split-authority settle ledger. Deliberately separate from
    // `_native_*_request_ids`: `apply_pod_snapshot` clears those on every
    // write-back, and losing "already submitted" there would re-enqueue the same
    // row every frame and STACK it (the 1.03 -> 1.0609 defect).
    std::vector<ModifierRow> _split_settle_rows;
    std::vector<ModifierBinding> _split_settle_bindings;
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
    // F8: last applied worker snapshot generation (0 = never applied).
    uint64_t _pod_snapshot_generation = 0;

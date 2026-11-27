// Effect behavior input, command transport, and evaluation and dispatch interface.

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
    struct ExternalEffectCommandPod {
        int64_t effect_id = 0;
        int64_t source_id = 0;
        // When true, the Modifier row this command produces is keyed by `source_id`
        // instead of by the per-fire Effect instance id.
        //
        // Synergy rows need this: an activation and its later deactivation are separate
        // fires (different days, and the removal additionally flips bit 63), so an
        // instance-derived identity can never match and the REMOVE silently misses,
        // leaving the row alive forever. A stable `source_id` makes the pair reconcile.
        //
        // Deliberately opt-in. Card tier rows and on-enter one-shots must NOT use it:
        // their identity has to stay per-fire, or a repeated on-enter would be mistaken
        // for "the row already exists" and be swallowed.
        bool stable_source_identity = false;
        std::string program_key;
        uint64_t fire_sequence = 0;
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t domain = -1;
        int32_t opcode = 0;
        int64_t resolved_value = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        std::array<int64_t, 4> payload{};
    };
    struct FamilyEffectMetadataPod {
        int32_t source_kind = 0;
        int32_t target_domain = 0;
        int32_t operation = 0;
        int32_t lifecycle = 0;
        int32_t duration_days = -1;
        int32_t stack_policy = 0;
        int32_t max_stacks = 1;
        int32_t priority = 0;
        int32_t target_selector_kind = 0;
        std::string target_selector_id;
        int32_t target_selector_param[2] = {0, 0};
        uint64_t stack_key_hash = 0;
        // Which catalog metrics this program reads. Computed from the program's
        // METRIC_* conditions and READ_METRIC instructions on every request, so
        // it can never go stale against a reloaded catalog. Empty means "this
        // program reads no metrics" and lets the economy skip the cell outright.
        MetricMask metric_mask;
        int32_t magnitude_by_prestige_q16[6] = {
            Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE};
        // Thresholds this program compares metrics against. The economy buckets
        // a metric change by "how many of these did it cross", which is exactly
        // "could a condition have flipped" -- and it needs no per-metric unit
        // knowledge, so it works for population, counts and category ids alike
        // (review §3). Filled on every request like the rest of this struct; it
        // is NOT serialised, so adding it costs no ABI.
        //
        // Overflow past the cap is not an error: that metric simply has an
        // incomplete threshold set, and the digest falls back to exact for it.
        static constexpr int32_t METRIC_THRESHOLD_CAP = 8;
        int32_t metric_threshold_count = 0;
        int32_t metric_threshold_ids[METRIC_THRESHOLD_CAP] = {0};
        // Bucket BOUNDARIES, not raw thresholds: GTE N contributes N, LTE N
        // contributes N+1, EQ N contributes both. Counting "how many boundaries
        // are <= value" then flips exactly where the condition flips, for all
        // three operators. Passing the raw N would leave LTE one boundary late.
        int64_t metric_threshold_values[METRIC_THRESHOLD_CAP] = {0};
        // Metrics that must NOT be bucketed: anything read by READ_METRIC (a Ramp
        // consumes the continuous value, so a bucket would freeze its strength),
        // and anything whose boundaries did not all fit in the cap. Empty
        // threshold set == exact comparison, so marking is all it takes.
        MetricMask exact_metric_mask;
        // Ideology-local scalars live above the Economy range in the same
        // catalog but have no Economy sampler or threshold consumer.
        MetricMask scalar_mask;
        // Program-level conditions gate each target. The derived layer evaluates
        // them per cell; a STATE condition has no instance to read there.
        int32_t condition_count = 0;
        bool condition_reads_state = false;
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
    // F8: POD catalog compile / invoke resolve registered behaviors by id or
    // hash. Missing implementations are hard failures (no silent fallback).
    static BehaviorFn find_behavior(const std::string &behavior_id);
    static BehaviorFn find_behavior_hash(uint64_t behavior_id_hash);
    static bool has_behavior(const std::string &behavior_id);
    static bool invoke_pod_behavior(
        uint64_t behavior_id_hash,
        const struct RuntimeEffectPodBehaviorInput &input,
        struct RuntimeEffectPodBehaviorOutput &output, std::string &error);

    godot::Dictionary configure(const godot::Dictionary &catalog);
    bool pod_snapshot_persistence_self_test(std::string &error) const;
    // M1 acceptance gate: proves the worker POD and this runtime answer every
    // StateId identically. The worker used to carry a second, hand-written
    // state switch that was ordered differently, which made every Q16-authored
    // state threshold permanently false on the worker while it passed here.
    // Runs the full (level, fire_sequence, stack_count, remaining_days) matrix
    // and also pins the POD's capability ceilings to be no narrower than this
    // runtime's, because a narrower ceiling rejects the whole catalog at once.
    bool pod_state_parity_self_test(std::string &error) const;
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
    bool family_effect_metadata_pod(const std::string &program_key,
                                    FamilyEffectMetadataPod &out) const;
    // Catalog-declared cell tags. Empty when the catalog predates the tag
    // tables, which is the normal state for every catalog today. The economy
    // copies this at attach time; nothing here is mutated at runtime.
    const TargetTagTable &target_tags() const { return _target_tags; }
    // Native Modifier adapter of a compiled command definition, indexed the
    // same way the compiled catalog indexes commands. The worker POD must hand
    // the Modifier stage the same adapter the main thread would have used;
    // guessing it from the Modifier domain instead marked ideology cards as
    // TECHNOLOGY and clamped their magnitude to 1.0. Exposed rather than
    // re-derived so the rule has exactly one home (effect_runtime.cpp:1003).
    int32_t native_command_definition_count() const;
    int32_t native_modifier_adapter_for_command(int32_t command_index) const;
    // M2a: the declarative facts EffectRuntime::submit_instances validates with
    // (effect_declarative_validation.h). The worker transport path must reject
    // exactly the rows this returns facts for, so the facts are read here
    // instead of being re-derived from the godot Dictionary columns.
    // Returns false when the program key is unknown or the runtime is
    // unconfigured; `program_id` then stays -1 and callers treat the row as
    // UNKNOWN_PROGRAM.
    bool declarative_facts_for_key(const std::string &key, int32_t &program_id,
                                   int32_t &source_kind,
                                   bool &managed_declared,
                                   int32_t &target_selector_kind,
                                   int32_t *target_selector_param) const;
    // Absolute expiry write. The previous refresh_managed_duration_pod recomputed
    // the day from the definition; callers that already resolved the definition
    // (the family path reads FamilyEffectMetadataPod) pass the absolute day
    // instead, so the main thread and the worker receive the exact same value
    // through EffectInstanceForwarder::InstanceRow::expires_day.
    bool set_instance_expiry_pod(int64_t instance_id, uint32_t generation,
                                 int64_t expires_day);
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
    // Re-queue an existing instance that has not reached a domain ACK, without
    // resetting generation, cadence identity, or fire_sequence.
    bool nudge_unacked_instance_pod(int64_t instance_id, uint32_t generation,
                                    int64_t day_index);
    bool set_metric_pod(int64_t instance_id, int32_t metric_id,
                        int64_t revision, int64_t value_q16,
                        std::string &error);
    // Read back one published metric of one instance.
    //
    // `present` distinguishes "the publisher wrote 0" from "nobody ever wrote".
    // That distinction is the whole point: a METRIC_GTE condition reading a
    // column that was never published is permanently false, and without a
    // presence bit a test cannot tell a correct 0 from a missing pipeline.
    //
    // Returns false when the instance or metric id is unknown. Like
    // instance_fire_acked_pod, this answers from the legacy authority: under
    // EFFECT worker ownership this EffectRuntime is writeback-only and the
    // instance reads as absent, which is why the callers are diagnostics/tests.
    bool instance_metric_pod(int64_t instance_id, int32_t metric_id,
                             int64_t &out_value, bool &out_present) const;
    int32_t metric_count() const noexcept { return _metric_count; }
    int32_t metric_id_for_key(const std::string &key) const;
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
    // Atomically validates and plans one peer-owned transition. Individual
    // command source identities remain on the command rows, while all domains
    // share one transaction reserve, status and aggregate ACK.
    bool enqueue_external_effect_batch_pod(
        int64_t effective_day, int32_t source_type,
        int64_t transition_source_id, uint64_t source_handle,
        uint64_t target_handle, uint32_t target_generation,
        const ExternalEffectCommandPod *commands, size_t command_count,
        std::string &error, int64_t *out_transaction_id = nullptr);
    // Built-in colonization transaction used by the Economy-owned expedition
    // state machine. Unowned targets emit CLAIM then SETTLE and stay unpublished
    // until Country and Economy ACK. Own-country relocation emits SETTLE only.
    static constexpr int64_t BUILTIN_TRANSACTION_ID_BASE = int64_t{1} << 50;

    bool enqueue_family_colonization_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t country_handle, uint32_t country_generation,
        uint64_t expedition_handle, uint32_t expedition_generation,
        int32_t target_cell, uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id = nullptr,
        bool claim_unowned = true,
        int32_t population_reward = 0);
    int32_t family_colonization_transaction_status_pod(
        int64_t transaction_id, int64_t effect_id,
        uint32_t expedition_generation, uint64_t fire_sequence,
        int64_t *out_resolved_transaction_id = nullptr) const;
    uint64_t family_colonization_settle_idempotency_key(
        int64_t effect_id, uint32_t expedition_generation,
        uint64_t fire_sequence) const;
    bool family_colonization_includes_claim(int64_t transaction_id) const;
    int32_t family_colonization_population_reward(int64_t transaction_id) const;
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
    // F8 ACTIVE write-back: replace instance/transaction/metric state from the
    // worker-committed POD snapshot. Generation must be monotonic.
    bool apply_pod_snapshot(const struct RuntimeEffectPodSnapshot &snapshot,
                            std::string &error);
    void begin_executor_transaction_namespace() noexcept;
    uint64_t pod_snapshot_generation() const { return _pod_snapshot_generation; }
    // Day the committed Effect state belongs to. The split-authority settle uses
    // it as the submission watermark: a worker Modifier snapshot whose
    // `committed_day` is not past it cannot prove anything about rows enqueued
    // today.
    int64_t committed_day() const { return _current_day; }
    // Native production bridge. It submits typed Modifier commands without
    // constructing a Godot Dictionary/Callable per effect transaction.
    godot::Dictionary dispatch_native_modifier(ModifierRuntime *modifier_runtime);
    godot::Dictionary ack_native_modifier(ModifierRuntime *modifier_runtime);

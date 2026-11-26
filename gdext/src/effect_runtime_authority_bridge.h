// Worker authority, Modifier handoff, and era reward interface.

    // ── Split authority: IDEOLOGY on the main thread, EFFECT + MODIFIER on the
    //    worker (mask 0xFEF = 0xFFF with only the ideology bit 0x010 cleared) ──
    //
    // An ideology equip plans its batch HERE, on this main-thread runtime, even
    // when the worker owns EFFECT. Nothing drained it: `run_effect_daily`,
    // `dispatch_effect_native_modifier` and `ack_effect_native_modifier` all
    // report `path=EFFECT_WORKER`, and the POD write-back rebuilt `_transactions`
    // from the worker's table, which by construction never carries a transaction
    // this thread created. The row was therefore erased one day after it was
    // planned: `transaction_status_pod` answered 0 (MISSING) and
    // `poll_pending_transition` reads 0 as failure -> rollback.
    //
    // `apply_pod_snapshot` now PRESERVES these batches and their source
    // instances, and the three calls below finish them. Both sides go through
    // `map_modifier_row`, the single Effect->Modifier mapping
    // `dispatch_native_modifier` also uses, so one row can never be built two
    // different ways.
    static constexpr int32_t IDEOLOGY_SOURCE_TYPE = 0x4944454F; // 'IDEO'
    // One Effect->Modifier row, flattened so it can outlive the transaction
    // arena (no pointer into `_command_definitions`).
    struct ModifierRow {
        int32_t opcode = 0;
        int32_t producer = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        std::string definition_key;
        int32_t domain = 0;
        int32_t scope = 0;
        uint64_t entity_handle = 0;
        uint64_t group_handle = 0;
        uint64_t source_type = 0;
        uint64_t source_id = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        int32_t magnitude_q16 = 65536;
        uint32_t domain_bit = 0;
        // A REMOVE row is confirmed by its ABSENCE from the committed store, an
        // APPLY row by its presence. The distinction is the difference between
        // "the settle worked" and "the settle is waiting".
        bool expect_present = true;
    };
    struct ModifierBinding {
        int64_t transaction_id = 0;
        uint32_t domain_bit = 0;
        int32_t row_begin = 0;
        int32_t row_count = 0;
        int64_t submitted_day = 0;
    };
    // Returns the rows that still need a worker commit, one binding per source
    // transaction. Idempotent: a transaction already bound is not re-collected,
    // which is what keeps a re-entrant settle from stacking the same row twice.
    std::vector<ModifierRow> collect_worker_modifier_rows(int64_t day_index,
                                                          std::vector<ModifierBinding> &out_bindings);
    int32_t worker_modifier_binding_count() const {
        return static_cast<int32_t>(_split_settle_bindings.size());
    }
    const ModifierBinding *worker_modifier_binding(int32_t index) const;
    const ModifierRow *worker_modifier_row(int32_t index) const;
    // Completes each transaction's MODIFIER ack bit. A transaction whose
    // `required_ack_mask` covers more than MODIFIER stays COMMITTED, exactly as
    // the main-thread adapter path leaves it for the other adapters.
    int32_t acknowledge_worker_modifier_rows(const std::vector<int64_t> &transaction_ids);
    // The enqueue failed, so nothing was submitted: forget the binding and put
    // the transaction back to PLANNED so the next settle retries it. Without this
    // a single rejected enqueue would stall the equip forever.
    void discard_worker_modifier_rows(const std::vector<int64_t> &transaction_ids);
    godot::Dictionary dispatch_native_country(NativeCountryRuntime *country_runtime,
                                               bool trigger_delivery = false);
    godot::Dictionary ack_native_country(NativeCountryRuntime *country_runtime);
    // Soft-settle leftover PREFLIGHTED Country bindings after a real Host
    // receipt drain under COUNTRY worker authority. Colonization CLAIM/SETTLE
    // still goes through dispatch_native_country + ack_native_country even when
    // EFFECT POD evaluation is worker-owned; do not use this as a substitute
    // for never dispatching those adapters.
    godot::Dictionary settle_orphaned_native_country_acks();
    godot::Dictionary dispatch_native_economy(NativeEconomyRuntime *economy_runtime);
    godot::Dictionary ack_native_economy(NativeEconomyRuntime *economy_runtime);
    godot::Dictionary dispatch_native_gameplay(DCWorldExt *world_ext);
    godot::Dictionary ack_native_gameplay(DCWorldExt *world_ext);
    // Worker-authoritative Effect still needs a main-thread pump for the
    // built-in family colonization transaction.  A freshly created transaction
    // has not reached an adapter binding yet, so expose it to the wake-up
    // predicate instead of reporting the adapters as idle.
    bool has_pending_family_colonization_transactions() const;
    bool should_run(int64_t day_index) const;
    uint64_t catalog_hash() const { return _catalog_hash; }
    // Mutable peer-domain watermark.  This is deliberately distinct from the
    // immutable catalog hash and advances at Effect state commit boundaries.
    uint64_t committed_generation() const { return _committed_generation; }
    godot::Dictionary poll_transactions(int64_t after_transaction_id,
                                         int32_t limit) const;
    godot::Dictionary preflight_transactions(const godot::Dictionary &batch);
    godot::Dictionary commit_transactions(const godot::Dictionary &batch);
    godot::Dictionary ack_transactions(const godot::Dictionary &batch);
    godot::Dictionary explain(int64_t instance_id) const;
    // One authored MODIFIER command of a program, without resolving it.
    // The coefficient plane composes this with ModifierRuntime's
    // definition->(stat, op, value) lookup to learn "which per-cell stat does
    // this card touch, and by how much". Resolving it here would mean Effect
    // knowing about Modifier stat ids, which it deliberately does not.
    struct ProgramModifierCommand {
        std::string definition_key;
        int64_t value_q16 = 0;
        int32_t stacks = 1;
        int32_t duration_days = -1;
        // How `value_q16` is produced. Plan 22 §4.4 condition 4 needs this: a
        // command whose magnitude is `VALUE_CONSTANT` is expressible in the derived
        // layer, while one that reads the stack top (or a metric) is not. Assuming
        // "every city command is stack-top" only holds for today's content, which
        // is why this used to be hard-coded in `cell_program_facts_for`.
        int32_t value_mode = VALUE_STACK_TOP;
    };
    // Evaluates one program against caller-supplied per-cell metric samples.
    // `metric_values` is indexed by metric id. Returns false with `error` when the
    // program is unknown or the stream fails, so the caller can fall back to the
    // instance path rather than silently using 0.
    bool evaluate_program_magnitude_for_metrics(
        const std::string &program_key,
        const int64_t *metric_values, int32_t metric_count,
        int64_t &out_value, std::string &error) const;
    // The condition-side twin: does the program's condition pass for these
    // samples. A program without conditions passes.
    bool evaluate_program_conditions_for_metrics(
        const std::string &program_key,
        const int64_t *metric_values, int32_t metric_count,
        bool &passes, std::string &error) const;
    bool program_modifier_commands(const std::string &program_key,
                                   std::vector<ProgramModifierCommand> &out) const;
    godot::Dictionary report() const;
    godot::PackedByteArray capture() const;
    godot::Dictionary restore(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_state();
    void attach_country_runtime(NativeCountryRuntime *runtime) {
        _country_runtime = runtime;
    }
    // Read-only Country state frozen for era-reward planning. Under worker
    // Country authority the attached store is not the committed state, so the
    // caller supplies the committed boundary for the duration of one notify.
    void set_era_reward_country_view(const NativeCountryRuntime *view) {
        _era_reward_country_view = view;
    }
    bool bind_era_reward_player_country_pod(uint64_t country_handle,
                                            std::string &error);
    bool notify_era_reward_technology_activated_pod(
        uint64_t country_handle, int32_t technology_id, int64_t day_index,
        std::string &error);
    godot::Dictionary era_reward_offer_snapshot() const;
    bool era_reward_requires_choice() const noexcept {
        return _era_reward_offer.status == 1 || _era_reward_offer.status == 4;
    }
    bool has_pending_research_discovery(uint64_t country, int32_t signal) const;
    // host_commit: under worker Effect authority this runtime is a read
    // replica and cannot own transactions. The selection is then recorded
    // without one (transaction_id 0) and the caller commits the selected
    // Modifier commands through the Host, settling via
    // settle_era_reward_selection_pod once they are committed.
    godot::Dictionary choose_era_reward(int64_t offer_generation,
                                        int32_t choice_index,
                                        int64_t effective_day,
                                        bool host_commit = false);
    static constexpr int32_t ERA_REWARD_SOURCE_TYPE = 0x45524152; // ERAR
    struct EraRewardModifierCommand {
        std::string definition_key;
        int32_t domain = 0;
        uint64_t target_handle = 0;
        int32_t magnitude_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        int64_t source_id = 0;
    };
    bool era_reward_host_selection_pending() const {
        return _era_reward_offer.status == 2 && _era_reward_offer.transaction_id == 0;
    }
    bool era_reward_selected_modifier_commands(
        std::vector<EraRewardModifierCommand> &out, std::string &error) const;
    void settle_era_reward_selection_pod(bool ok, const char *error);

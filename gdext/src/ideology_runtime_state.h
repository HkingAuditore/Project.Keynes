// Catalog settings, country state, and derived layer rebuild state.

                            uint8_t location) const;
    uint64_t binding_signature_for(int32_t ideology_id, int32_t level) const;
    bool sync_external_binding(uint64_t country_handle, IdeaState &state,
                               std::string &error);

    bool _configured = false;
    uint64_t _catalog_hash = 0;
    // World seed mixed into each country's offer RNG. Optional catalog key
    // (`world_seed`); zero means "no world seed available", in which case the RNG
    // is seeded from the handle alone -- same as the worker, so parity is intact
    // either way.
    uint64_t _world_seed = 0;
    int32_t _ideology_capacity = 6;
    int32_t _spirit_capacity = 3;
    int32_t _draw_count = 3;
    int64_t _offer_cost_q16 = Q16_ONE;
    int64_t _starting_points_q16 = 0;
    int32_t _ideology_capacity_max = 6;
    int32_t _spirit_capacity_max = 3;
    int64_t _offer_cost_growth_percent = 100;
    int64_t _offer_cost_max_q16 = Q16_ONE;
    int32_t _reroll_cost_percent = 50;
    int64_t _point_population_weight_q16 = 0;
    int64_t _point_building_weight_q16 = 0;
    int64_t _point_trade_weight_q16 = 0;
    int64_t _point_gain_cap_q16 = 0;
    std::string _point_gain_stat_key;
    // X6-a: per-term point multipliers. Empty keys disable each factor.
    std::string _point_population_factor_stat_key;
    std::string _point_building_factor_stat_key;
    std::string _point_trade_factor_stat_key;
    // social_media: floor under the opinion factor. Empty preserves 0.5.
    std::string _opinion_factor_floor_stat_key;
    std::vector<std::string> _school_strength_factor_stat_keys;
    // Same shape as _point_gain_stat_key, separate consumption points. Kept as
    // three keys rather than one table because each is optional independently:
    // a catalog that only wants faster studying leaves reroll alone.
    std::string _understanding_gain_stat_key;
    std::string _reroll_cost_stat_key;
    // Per-country floor under the era decay table (史馆-type cards), and the
    // additive offer-row bonus. Both optional: an empty key means the stat does
    // not exist and the pre-existing behaviour is preserved exactly.
    std::string _era_decay_floor_stat_key;
    std::string _offer_choice_bonus_stat_key;
    // Filled on first use, reset by configure(). Mutable because the accessors
    // are const and the hot path must not repeat the string lookup.
    mutable int32_t _understanding_gain_stat_id = -1;
    mutable int32_t _reroll_cost_stat_id = -1;
    mutable int32_t _era_decay_floor_stat_id = -1;
    mutable int32_t _offer_choice_bonus_stat_id = -1;
    mutable int32_t _point_population_factor_stat_id = -1;
    mutable int32_t _point_building_factor_stat_id = -1;
    mutable int32_t _point_trade_factor_stat_id = -1;
    mutable int32_t _opinion_factor_floor_stat_id = -1;
    mutable std::vector<int32_t> _school_strength_factor_stat_ids;
    RuntimeIdeologyOpinionSnapshot _worker_opinion_inputs;
    bool _worker_opinion_inputs_valid = false;
    // Weight of an owned-but-not-maxed card offered again as 精进, on the same
    // x10000 scale as rarity weight. 0 keeps every owned card out of the pool,
    // which is the pre-L4-11 behaviour.
    int32_t _refine_weight_bp = 0;
    // Understanding granted when a 精进 row is picked. Authored in Q16; the
    // default of 4.0 units matches the design note "约等于直接升一级".
    int64_t _refine_understanding_q16 = 4 * Q16_ONE;
    std::vector<CapacityUnlock> _capacity_unlocks;
    uint64_t _points_revision_seen = 0;
    // True once a worker snapshot wrote this facade. Worker transitions bind
    // through Modifier UniqueSource rows (PKCM + IDP2), not PKEF bindings.
    bool _worker_origin = false;
    int32_t _max_commands_per_slice = 4096;
    int32_t _max_transition_commands = 256;
    int32_t _max_transition_polls_per_slice = 4096;
    int32_t _max_active_visits_per_slice = 1024;
    int32_t _gate_count = 0;
    int32_t _idea_words = 0;
    int32_t _gate_words = 0;
    // Draw-weight decay by (unlocked_era - idea.era_index). Index 0 is the card's
    // own era; the last row is reused for anything older; 0 retires the card.
    std::vector<int32_t> _era_decay_bp;
    // Dense technology index of each era's milestone. Index i answers "has this
    // country reached era i"; -1 means the era has no milestone and is skipped.
    std::vector<int32_t> _era_milestone_technologies;
    std::vector<Definition> _definitions;
    std::vector<std::string> _route_keys;
    std::unordered_map<std::string, int32_t> _route_indices;
    std::vector<std::string> _school_keys;
    std::vector<Level> _levels;
    std::vector<EffectTemplate> _persistent_templates;
    std::vector<EffectTemplate> _on_enter_templates;
    std::vector<EffectTemplate> _synergy_templates;
    std::vector<ClassStance> _class_stances;
    // Material support model: one dense Q16 channel row per card level, plus the
    // profile knobs. Empty (channel_count == 0) falls back to the authored stance
    // rows, which is what an older catalog compiles to.
    ideology_incidence::IdeologyIncidenceTable _incidence;
    // Reused by evaluate_support so the explain path can report per-class deltas
    // without allocating on every gate check. Sized class_count, never persisted.
    std::vector<int32_t> _support_delta_scratch;
    std::vector<int32_t> _support_stance_scratch;
    std::vector<SynergyRequirement> _synergy_requirements;
    // L3-9 synergy magnitude overrides, flattened. Kept as three parallel arrays
    // (program key, scale, per-synergy span on Synergy) rather than a map so the
    // catalog hash is a straight walk and the order is whatever the catalog says.
    std::vector<std::string> _synergy_override_programs;
    // program -> [(synergy index, scale)]. magnitude_scale_for used to scan every
    // synergy for every program on every country; the reverse index makes it
    // proportional to the rewrites that actually name the program.
    std::unordered_map<std::string, std::vector<std::pair<int32_t, int32_t>>>
        _synergy_override_index;
    // Review §4: "idle = 0" for this counter is the acceptance criterion for the
    // index -- a scan means the index missed and the old path ran.
    mutable uint64_t _synergy_scale_scans = 0;
    mutable uint64_t _synergy_scale_lookups = 0;
    std::vector<int32_t> _synergy_override_scales;
    // Lazily resolved derived data: configuration may run before the Effect
    // catalog exists, while selector lookup is const. Only the cache and the
    // resolved ids are mutable; authored catalog rows never change after load.
    mutable std::vector<SynergyOverride> _synergy_overrides;
    // program -> override row indices, and resolved tag id -> override row
    // indices. Both are built once per catalog; selector rewrite is on the
    // reconcile path, so scanning every synergy per target would be avoidable
    // work.
    std::unordered_map<std::string, std::vector<int32_t>>
        _synergy_program_overrides;
    mutable std::unordered_map<int32_t, std::vector<int32_t>>
        _synergy_tag_overrides;
    mutable bool _synergy_override_tags_resolved = false;
    std::vector<Synergy> _synergies;
    std::vector<int32_t> _ideology_synergy_offsets;
    std::vector<int32_t> _ideology_synergy_ids;
    std::vector<uint32_t> _synergy_candidate_stamps;
    uint32_t _synergy_candidate_generation = 0;
    std::vector<int32_t> _synergy_candidate_scratch;
    uint64_t _political_class_hash = 0;
    int32_t _political_class_count = 0;
    int32_t _opinion_owner_influence_weight = 2;
    int64_t _opinion_funds_per_influence = 1000000;
    std::vector<int32_t> _technology_requirements;
    std::vector<int32_t> _signal_requirements;
    std::vector<int32_t> _gate_requirements;
    std::vector<EffectRuntime::ExternalEffectCommandPod>
        _transition_command_scratch;
    // REMOVE rows during a level change / relocation, kept apart from the apply batch.
    //
    // The two sides must name DIFFERENT generations: a row is removed under the
    // generation that applied it (`previous_generation`) and added under the new one.
    // Sharing one scratch vector forced a single batch id onto both, which is how a
    // level-up ended up keeping BOTH the old and the new level's national row.
    std::vector<EffectRuntime::ExternalEffectCommandPod>
        _removed_command_scratch;
    std::vector<CountryState> _countries;
    std::vector<Command> _commands;
    size_t _command_cursor = 0;
    std::unordered_map<int32_t, int64_t> _producer_high_watermarks;
    std::vector<Receipt> _receipts;
    int64_t _next_receipt_id = 1;
    int32_t _max_receipts = 2048;
    int32_t _applying_producer_id = 0;
    int64_t _applying_sequence = 0;
    int32_t _applying_opcode = 0;
    std::vector<PendingTransitionRef> _pending_transitions;
    size_t _pending_transition_cursor = 0;
    int64_t _active_progress_day = -1;
    int64_t _daily_continuation_day = -1;
    int32_t _active_country_cursor = 0;
    int32_t _active_item_cursor = 0;
    uint64_t _submit_order = 0;
    // G8 ACTIVE write-back：最近一次 apply_pod_snapshot 的代次。apply 侧用它拒绝
    // 回退代次，所以同一天重复回灌是幂等的。
    uint64_t _pod_snapshot_generation = 0;
    // See `pod_catalog_hash()`: recorded by `export_pod_catalog`, which is where the POD
    // computes it, so `export_pod_import_state` can stamp the POD's identity on a payload
    // rather than this runtime's (`_catalog_hash`), which the POD would refuse. `mutable`
    // because that exporter is const (it reads this runtime and writes the POD's catalog).
    mutable uint64_t _pod_catalog_hash = 0;
    // See `mark_worker_import_pending()`. Kept here rather than on `DCWorldExt` so the
    // belief "the worker has not adopted the restore yet" lives with the restored state
    // itself and dies with it (`clear_state` / `configure`).
    bool _worker_import_pending = false;
    std::string _worker_import_last_code;
    int64_t _worker_import_attempts = 0;
    int64_t _last_day = -1;
    uint64_t _active_visits = 0;
    uint64_t _dormant_scan_count = 0;
    uint64_t _sparse_idea_scan_count = 0;
    uint64_t _pending_transition_visits = 0;
    uint64_t _command_queue_resorts = 0;
    uint64_t _command_queue_shift_steps = 0;
    uint64_t _command_queue_merge_steps = 0;
    uint64_t _derived_rebuild_visits = 0;
    uint64_t _commands_applied = 0;
    uint64_t _commands_rejected = 0;
    uint64_t _offers_opened = 0;
    uint64_t _levels_advanced = 0;
    uint64_t _class_snapshot_reads = 0;
    uint64_t _support_evaluations = 0;
    // Why the last `accrue_points` call did or did not settle. A parity failure
    // that shows an empty main-thread snapshot cannot be diagnosed from the
    // resulting numbers; these say which early return fired.
    //   0 = settled, 1 = no economy, 2 = revision 0, 3 = revision already seen,
    //   4 = shape mismatch, 5 = class hash/count mismatch.
    int32_t _points_accrue_result = -1;
    uint64_t _points_accrue_revision = 0;
    uint64_t _synergy_candidates_visited = 0;
    // P1-C evidence. `metric_publishes_skipped` counts rows whose sampled
    // values matched the previous publish; on a quiescent day every managed
    // instance must land there and `metric_publishes` must not move.
    uint64_t _metric_publishes = 0;
    uint64_t _metric_publishes_skipped = 0;
    // P2-B: how many selections the cap actually cut, and how many cells the
    // last one matched BEFORE the cap. `mutable` because resolve is const.
    mutable EffectSelectorStats _selector_stats;
    mutable uint64_t _selector_truncations = 0;
    // X1-b evidence: incremented once per kind-16 target whose source count was
    // evaluated during reconcile. A catalog without a kind-16 card must leave
    // this at exactly zero (declaration-driven work, not a daily scan).
    mutable uint64_t _source_count_evaluations = 0;
    // Bumped on every build; Economy keys its per-cell cache on (this, input revision).
    uint64_t _cell_program_generation = 0;
    // Independent execution-contract identity (plan §11.5). Modifier's own
    // catalog hash does NOT cover ideology wording or this layer's execution
    // semantics, so a save must carry this separately or an old save would be
    // silently accepted after a semantic change.

    // Last materializer report, for §12.4 diagnostics. Carries `truncated`,
    // which must stay 0: a non-zero value means the derived path silently
    // dropped targets, which is the exact failure the migration exists to remove.
    DerivedMaterializeReport _last_derived_materialize;
    // Sharded rebuild state (plan §14.3: a slice must stay under 1 ms).
    //
    // `_derived_rebuild_day < 0` means "no build in flight". The accumulator lives
    // here rather than on the stack because the build spans slices; the cursor is
    // the NEXT country slot to visit so a resumed call continues where the last
    // one stopped.
    double _derived_collect_ms = 0.0;
    double _derived_materialise_ms = 0.0;
    int64_t _derived_rebuild_day = -1;
    int32_t _derived_rebuild_cursor = 0;
    // Index into `_derived_rebuild_accumulator` -- the next CONTRIBUTION to fold.
    size_t _derived_rebuild_index = 0;
    // Set once the accumulator is filled for this day. Distinct from the cursor
    // because a step can park on budget AFTER collecting.
    bool _derived_rebuild_collected = false;
    // Per-step wall budget. Plan §14.3 targets 1 ms per slice; the margin keeps the
    // whole slice (not just this stage) inside it.
    static constexpr double DERIVED_REBUILD_STEP_BUDGET_MS = 0.45;
    int32_t _derived_rebuild_slices = 0;

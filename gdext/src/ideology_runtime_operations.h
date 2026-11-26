// Admission, offer handling, program evaluation, and panel projection operations.

    bool validate_catalog(const godot::Dictionary &catalog, std::string &error);
    bool validate_command_shape(const Command &command, std::string &error) const;
    bool validate_country(uint64_t handle, int32_t &slot) const;
    CountryState *country_state_for(uint64_t handle, bool create);
    const CountryState *country_state_for(uint64_t handle) const;
    IdeaState *idea_state_for(CountryState &country, int32_t ideology_id, bool create);
    const IdeaState *idea_state_for(const CountryState &country, int32_t ideology_id) const;
    bool known(const CountryState &country, int32_t ideology_id) const;
    void set_known(CountryState &country, int32_t ideology_id);
    bool gate(const CountryState &country, int32_t gate_id) const;
    void set_gate(CountryState &country, int32_t gate_id, bool value);
    bool requirements_met(const CountryState &country, int32_t country_slot,
                          const Definition &definition) const;
    SupportResult evaluate_support(CountryState &country, int32_t ideology_id,
                                   SupportDirection direction);
    bool support_gate(CountryState &country, int32_t ideology_id,
                      SupportDirection direction, std::string &error);
    bool exclusion_allows(const CountryState &country, int32_t ideology_id,
                          std::string &error) const;
    bool synergy_active(const CountryState &country, int32_t synergy_id) const;
    void set_synergy_active(CountryState &country, int32_t synergy_id,
                            bool active);
    bool synergy_requirements_met(const CountryState &country,
                                  int32_t synergy_id) const;
    bool collect_affected_synergies(CountryState &country, int32_t ideology_id,
                                    int64_t day,
                                    IdeaState::Transition &transition,
                                    std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
                                    std::string &error);
    void rollback_synergies(CountryState &country,
                            const IdeaState::Transition &transition);
    void rebuild_synergies(CountryState &country);
    bool apply_command(const Command &command, int64_t day, std::string &error);
    bool open_offer(CountryState &country, int32_t country_slot, std::string &error);
    bool reroll_offer(CountryState &country, int32_t country_slot,
                      const Command &command, std::string &error);
    bool draw_offer(CountryState &country, int32_t country_slot, std::string &error);
    // Deepest era whose milestone technology the country already holds. Both
    // authorities derive this the same way so the decay inputs agree.
    int32_t unlocked_era_for(int32_t country_slot) const;
    int32_t draw_pool_size(const CountryState &country, int32_t country_slot) const;
    int32_t ideology_capacity_for(int32_t country_slot) const;
    int32_t spirit_capacity_for(int32_t country_slot) const;
    int64_t offer_cost_for(uint64_t draw_sequence) const;
    // `handle` is needed from here on: the reroll share is per-country now, so
    // the caller must say whose modifiers to read. There is no useful default —
    // 0 is not a valid handle and would silently read the global bucket.
    int64_t reroll_cost_for(uint64_t draw_sequence, uint64_t handle) const;
    // Resolve `country.ideology.*` stat ids once and cache them. -1 means "not
    // resolvable": either no key is authored or the modifier runtime is not
    // configured yet. Both read as 1.0, so a catalog without these keys behaves
    // byte-identically to before they existed.
    int32_t resolve_ideology_stat_id(const std::string &key, int32_t &cache) const;
    // Q16 multiplier for one country, clamped to [0, 4] like every other
    // ideology-facing factor. Returns Q16_ONE when the key is absent.
    int32_t ideology_stat_factor_q16(const std::string &key, int32_t &cache,
                                     uint64_t handle) const;
    // Basis points (0..10000) for one country. Unlike the Q16 factor this is an
    // additive-shaped value, so "absent" reads as 0 rather than 1.0 -- 0 is the
    // era-decay floor's identity element.
    int32_t ideology_stat_bp(const std::string &key, int32_t &cache,
                             uint64_t handle) const;
    // Additive non-negative count for one country, pre-clamped to `cap`.
    int32_t ideology_stat_count(const std::string &key, int32_t &cache,
                                uint64_t handle, int32_t cap) const;
    bool program_writes_school_strength(const std::string &program,
                                        int32_t school_index) const;
    int32_t school_strength_scale_q16(
        const CountryState &country, int32_t school_index) const;
    // Rows this country's next offer may hold, already clamped to the array.
    int32_t offer_choice_count_for(const CountryState &country) const;
    // Product of every ACTIVE synergy override that targets `program`, clamped
    // to [0.25x, 4x]. Returns 1.0 when nothing rewrites it.
    int32_t magnitude_scale_for(const CountryState &country,
                                const std::string &program) const;
    // X5: copy the base metadata and apply the highest-priority ACTIVE rewrite
    // per rewritten field. TAG/KIND/CAP do not compose; scales keep their
    // independent product path in magnitude_scale_for().
    EffectRuntime::FamilyEffectMetadataPod effective_selector_metadata(
        const CountryState &country, const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata) const;
    bool banned(const CountryState &country, int32_t ideology_id) const;
    void set_banned(CountryState &country, int32_t ideology_id);
    void accrue_points(int64_t day);
    // R9-1: the single settlement body. `accrue_points(day)` feeds it Economy's
    // snapshot; the parity path feeds it the worker's snapshot.
    void accrue_points_from(const RuntimeIdeologyOpinionSnapshot &opinion,
                            int64_t day);
    // Slices of one day, shared by the settlement entry point. Kept separate so
    // the day's command/transition work has exactly one implementation (R9-1).
    godot::Dictionary run_daily_slices(int64_t day_index);
    void init_country_state(CountryState &state, uint64_t handle) const;
    bool choose_offer(CountryState &country, const Command &command, std::string &error);
    // 封存: permanently retires one card from this country's draw pool for the
    // price of one draw.
    bool ban_card(CountryState &country, const Command &command, std::string &error);
    bool equip(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    bool unequip(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    bool promote(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    void reconcile_level(IdeaState &state);
    int32_t unlocked_level(const IdeaState &state) const;
    bool start_transition(CountryState &country, IdeaState &state,
                          uint8_t location, int32_t level,
                          uint8_t slot_index,
                          bool remove_previous_persistent,
                          bool apply_current_persistent,
                          uint64_t entered_on_success, int64_t day,
                          std::string &error);
    bool emit_level_effects(CountryState &country, IdeaState &state,
                            int32_t level, bool remove_persistent,
                            bool include_on_enter, int64_t day,
                            std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
                            std::string &error);
    bool emit_templates(uint64_t country_handle, int32_t ideology_id,
                        int32_t level, int32_t begin, int32_t count,
                        bool remove, int64_t day, uint64_t salt,
                        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
                        std::string &error);
    // Declarative effect programs. A card row whose definition_key resolves to
    // a managed `ideology.effect.*` program is driven as a reconciled Effect
    // instance instead of a one-shot external batch, so it can carry
    // conditions, targets and lifecycle. Rows without a program keep the
    // legacy batch path unchanged.
    static std::string effect_program_key(const std::string &definition_key);
    // `layer` distinguishes the per-stack instances of an ADD_STACK program. It
    // is mixed in ONLY when non-zero, so layer 0 hashes exactly like the pre-L2-8
    // id: every instance that is not a stack keeps its old identity and existing
    // saves stay valid. A layer that took part in the hash as 0 would renumber
    // every instance in the game.
    static int64_t effect_instance_id(uint64_t country_handle,
                                      int32_t ideology_id, uint8_t location,
                                      int32_t level, const std::string &program,
                                      uint64_t target_handle, int32_t layer = 0);
    // Expands one declared program into its concrete targets. Country-scoped
    // programs resolve to the country handle; cell-scoped programs resolve the
    // anchor cell and then run the shared target selector, producing one entry
    // per cell. Fails closed (empty) when the domain cannot be resolved, so a
    // mis-authored program never silently widens to the whole country.
    bool resolve_effect_targets(
        const CountryState &country, const IdeaState &state,
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        uint64_t selection_salt,
        std::vector<EffectTarget> &out) const;
    // `out_derived` (optional) receives the contributions of programs whose
    // backend is DerivedCell (plan 22 §4.5). Those programs create NO instance
    // and are NOT subject to `SELECTOR_MAX_CELLS`, because that cap exists only
    // to bound the instance table.
    //
    // Kept as an out-param rather than a second pass so the eligibility column is
    // consulted exactly once per program, in one place (I01).
    bool collect_effect_activations(
        const CountryState &country, const IdeaState &state,
        std::vector<EffectActivation> &out,
        std::vector<DerivedProgramContribution> *out_derived = nullptr) const;
    // Builds the plain-data facts the backend decision needs from already
    // resolved metadata. No runtime state beyond the catalog, so the decision
    // stays reproducible (§4.5).
    CellProgramFacts cell_program_facts_for(
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const IdeaState &state) const;
    // Which level does this card contribute at, and which program templates does
    // that level carry? (plan §10.1: a pending transition serves the OLD level, and
    // a pending equip serves nothing.) Returns false when it contributes nothing.
    //
    // Extracted from `collect_effect_activations` so the applied-program basis
    // (plan §18.2) cannot disagree with the collector about which level is in
    // force. Two copies of this rule is exactly the defect M5-69 was: the
    // contribution half and the accrual half read different levels.
    bool resolve_contribution_templates(
        const CountryState &country, const IdeaState &state,
        int32_t &contribution_level,
        std::vector<const EffectTemplate *> &out) const;
    // The fold inputs of one program, BEFORE the per-target magnitude scale is
    // applied: one row per resolved modifier term, flattened across the program's
    // modifier commands, exactly as the derived fold consumes them.
    //
    // `count_diagnostics` is false for callers that only need the digest (the
    // applied-basis rebuild): the ramp counters are read by fixtures as exact
    // numbers, so a save must not move them.
    void resolve_program_fold_terms(
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const std::string &program,
        std::vector<DerivedProgramContribution::Term> &out,
        bool count_diagnostics) const;
    // One basis row for (country, program), or false when the program does not
    // occupy the derived backend in this configuration.
    bool build_applied_program_basis_row(
        const CountryState &country, const IdeaState &state,
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        AppliedProgramBasis &out) const;
    // Re-derives the whole basis from `countries` under the CURRENT catalogs.
    //
    // Pure: no runtime member is touched, so restore can validate a payload's basis
    // before anything is installed and a failed check needs no rollback of its own.
    // Ordered by (country handle, program key) and de-duplicated per key, which is
    // what makes the payload's byte layout independent of iteration order.
    void rebuild_applied_program_basis(
        const std::vector<CountryState> &countries,
        std::vector<AppliedProgramBasis> &out) const;
    static uint64_t mix_applied_program_basis(
        uint64_t hash, const std::vector<AppliedProgramBasis> &basis);
    // ── plan §18.2 / §18.5: the local scalar basis ──────────────────────────
    //
    // The per-country scalar values, keyed by the slab metric id a card program
    // actually reads. Built from ONE `collect_local_scalars` call and then resolved
    // through the Effect catalog, so this record and the slab that
    // `fill_ideology_scalars` publishes can never describe different numbers.
    bool build_local_scalar_basis(const CountryState &country,
        std::vector<LocalScalarValue> &out,
        std::vector<LocalScalarValue> *cross_domain_rows = nullptr) const;
    // Re-derives the whole block from `countries` under the CURRENT catalogs.
    //
    // Pure, for the same reason `rebuild_applied_program_basis` is: restore validates
    // a payload's block BEFORE anything is installed, so a refusal needs no rollback
    // of its own. Ordered by (country handle, metric id) and de-duplicated per pair,
    // which is what makes the payload's byte layout independent of iteration order.
    //
    // A key the current Effect catalog cannot resolve contributes no row: the metric
    // does not exist, so no value could ever be read from it. That is also how the
    // content check fires -- a payload row whose id this catalog does not produce
    // survives into `restored` but never into `rebuilt`, and the two vectors differ.
    //
    // `cross_domain_rows`, when supplied, receives the rows whose value is NOT a
    // function of this payload plus the catalogs, so the caller can exclude exactly
    // those rows from the content comparison. There is exactly one such key today:
    // `ideology.scalar.unlocked_era`, whose input is the COUNTRY domain's technology
    // set. PKCN owns and restores that domain, not PKID, so a world that has not
    // restored it yet -- or whose era legitimately moved -- would otherwise refuse its
    // own save. Those rows are still persisted, shape-checked and covered by the state
    // hash, so a corrupted one is still caught, by the layer that can see it.
    void rebuild_local_scalar_basis(
        const std::vector<CountryState> &countries,
        std::vector<LocalScalarValue> &out,
        std::vector<LocalScalarValue> *cross_domain_rows = nullptr) const;
    static uint64_t mix_local_scalar_basis(
        uint64_t hash, const std::vector<LocalScalarValue> &rows);
    // The scalar values themselves, as (Effect catalog key, Q16 value), in a
    // deterministic key order. Split out of `fill_ideology_scalars` so the slab the
    // cards read and the rows the save records are computed by ONE piece of code:
    // two copies of "how many cards are equipped" is how a basis drifts from the
    // thing it describes.
    void collect_local_scalars(const CountryState &country,
        std::vector<std::pair<std::string, int64_t>> &out) const;
    // X6-c: the copier owns fresh Effect instances but reads the persistent
    // program list of the card in the immediately-left slot. The callers branch
    // on `copy_left_programs` first: only a non-copier falls back to its own
    // managed list.
    bool copy_source_state(const CountryState &country, const IdeaState &state,
                           const IdeaState *&source) const;
    bool copy_source_programs(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const;
    // The legacy Modifier path keeps the copier's own non-managed rows and adds
    // the source's non-managed rows. Managed rows stay with the Effect
    // reconciler.
    void collect_copied_legacy_templates(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const;
    // program_hash -> declared target_domain, for the programs this idea's
    // *current* level expands into. The reconciler derives the same hashes in
    // collect_effect_activations, so a report row can be labelled with its
    // domain without persisting one: EffectInstanceRef intentionally stores no
    // domain, and widening the save layout for a display bit would force a
    // schema bump on every existing campaign.
    //
    // A miss is reported as absent, never guessed. If the level moved between
    // reconciliation and this call the refs are stale and will be rebuilt on
    // the next tick anyway; labelling a country handle as a cell index in that
    // window would paint the wrong hex.
    void collect_idea_program_domains(const CountryState &country,
        const IdeaState &state,
        std::unordered_map<uint64_t, int32_t> &out) const;
    bool reconcile_effect_activations(const CountryState &country,
                                      IdeaState &state, int64_t day,
                                      std::string &error);
    void retire_effect_activations(IdeaState &state, int64_t day);
    void reconcile_country_effect_activations(CountryState &country,
                                              int64_t day);
    // P1-A: per-(definition, level) facts derived from the Effect catalog.
    // `mutable` because should_run() is const but still has to know whether any
    // managed card is in play.
    struct LevelManagedInfo {
        uint8_t has_managed = 0;
        uint8_t uses_economy_inputs = 0;
        uint8_t uses_tags = 0;
        // The 0-based tag indices this level's programs actually read. Filled from
        // `target_selector_param[1] - 1` (1-based in content). A synergy override can
        // add tags, which is why the publisher marks the set "incomplete" instead of
        // claiming it is exhaustive.
        std::vector<int32_t> tag_ids;
        uint8_t tag_ids_incomplete = 0;
        uint8_t uses_families = 0;
        uint8_t scale_capable = 0;
        MetricMask consumer_mask;
        MetricMask scalar_mask;
        uint64_t program_mix = 1469598103934665603ULL;
        // Thresholds this level's programs compare metrics against, copied from
        // the effect metadata so the economy can bucket by "did a condition
        // cross" instead of hashing raw values (review §3). Runtime-only cache,
        // never serialised.
        uint8_t threshold_count = 0;
        int32_t threshold_ids[8] = {0};
        int64_t threshold_values[8] = {0};
        MetricMask exact_mask;
    };
    void rebuild_level_managed_if_needed() const;
    bool level_is_managed(int32_t ideology_id, int32_t level) const;
    const LevelManagedInfo *level_managed_info(int32_t ideology_id,
                                               int32_t level) const;
    // Fill the reserved scalar ids of the Effect metric slab from this
    // country's authoritative ideology state. Economy never sees these ids.
    void fill_ideology_scalars(const CountryState &country,
        const IdeaState &state, std::vector<int64_t> &values) const;
    uint64_t compute_activation_signature(const CountryState &country,
                                          const IdeaState &state) const;
    void recount_managed_active();
    bool start_next_level_transition(CountryState &country, IdeaState &state,
                                     int64_t day, std::string &error);
    uint64_t unentered_level_mask(const IdeaState &state, int32_t through_level) const;
    void rebuild_country_derived(CountryState &country);
    void rebuild_pending_transition_index();
    void set_state_location(CountryState &country, int32_t idea_slot, uint8_t location);
    uint8_t next_free_slot(const CountryState &country, uint8_t location,
                           int32_t exclude_ideology_id) const;
    void insert_active_state(CountryState &country, int32_t idea_slot);
    void remove_active_state(CountryState &country, int32_t idea_slot);
    void append_pending_transition(CountryState &country, int32_t idea_slot);
    bool poll_pending_transition(PendingTransitionRef &ref, int64_t day);
    void merge_staged_commands(std::vector<Command> &&staged);
    void append_receipt(const Command &command, int32_t status, int64_t day,
                        const std::string &reason = {});
    void append_transition_receipt(const IdeaState::Transition &transition,
                                   const IdeaState &state, uint64_t country_handle,
                                   int32_t status, int64_t day,
                                   const std::string &reason = {});
    size_t pending_command_count() const;
    const Command *next_command() const;
    int32_t ideology_slot_cost(const CountryState &country) const;
    int32_t spirit_slot_cost(const CountryState &country) const;
    uint64_t next_random(CountryState &country);
    int32_t sample_weighted(CountryState &country, const std::vector<int32_t> &pool,
                            const std::vector<int64_t> &weights) const;
    void reset_runtime_state();
    uint64_t compute_catalog_hash() const;
    // Plan §11.5: the execution-contract identity. Computed at configure time from the
    // version vector plus the compile identities, persisted in PKID, validated on restore.
    uint64_t compute_execution_contract_hash() const;
    uint64_t compute_state_hash() const;
    // Same hash over an ALREADY-DERIVED basis. Capture and restore both need the
    // rows for the payload anyway; recomputing them inside `compute_state_hash()`
    // would resolve every program twice on a save.
    //
    // §18.5 extends it with the two pieces of the local scalar basis that are not a
    // function of the country rows alone: the scalar value rows themselves and the
    // sample day the projection was built from. Both are persisted, so both are
    // hashed -- the same argument the two §9.3 dates already make.
    uint64_t compute_state_hash_with(
        const std::vector<AppliedProgramBasis> &basis,
        const std::vector<LocalScalarValue> &scalars,
        int64_t sample_day) const;
    uint64_t binding_id_for(uint64_t country_handle, int32_t ideology_id,

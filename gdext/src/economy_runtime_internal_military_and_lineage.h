// Military projection state and cohort, people, and lineage transfer operations.

    // ---- NativeEconomyRuntime military read view (state)
    // Resolved lazily from the profession catalog (contract §3): a catalog
    // that predates the military content simply reports zero soldiers.
    int32_t _soldier_profession_id = -1;
    // Signature -> profession lane, rebuilt on every military_read_cell_view
    // call. Transient: never saved, never hashed.
    mutable std::vector<int32_t> _military_signature_profession;
    mutable bool _military_cell_view_published = false;
    void fire_family_event_once_effect(int32_t family_index,
                                       const std::string &program_key);
    void apply_pending_family_split_gifts();
    void ensure_family_policy_factors();
    bool sync_owned_columns_to_production(const RuntimeEconomyOwnedState &owned,
                                          std::string &error);
    void sync_production_core_columns_to_owned(
        RuntimeEconomyOwnedState &owned) const;
    void capture_owned_mirror_stores(RuntimeEconomyOwnedState &owned) const;
    void reset_family_policy_factors(int32_t family_index);
    int32_t family_colonization_population_reward_amount(
        uint64_t family_handle) const;
    void apply_family_colonization_population_reward(int32_t destination,
                                                     uint64_t family_handle,
                                                     int64_t amount);
    int32_t family_consumption_factor_q16(int32_t cohort_slot,
                                          int32_t need_id) const;
    int32_t family_good_consumption_factor_q16(int32_t cohort_slot,
                                               int32_t good_id) const;
    int32_t family_variant_preference_factor_q16(int32_t cohort_slot,
                                                 int32_t variant_id,
                                                 int64_t &sat, int32_t *good_factors = nullptr) const;
    uint64_t preferred_family_for_cohort(int32_t cohort_slot,
                                         int32_t axis,
                                         int32_t selector_kind,
                                         int32_t selector_id) const;
    int64_t building_reset_capital_value(BuildingGroupConstRef group) const;
    bool family_free_building_resources_legal(int32_t cell, int32_t type_id,
                                              int64_t count) const;
    void dissolve_family(uint64_t family_handle);
    // Applies _family_move_plan after the cohort lanes have moved.
    void move_family_membership(int32_t source_slot, int32_t destination_slot,
                                int64_t moved_funds);
    // Splits a move of `moved_population` from a cohort across anonymous
    // people and family edges; returns the anonymous share and fills
    // _family_move_plan with (edge index, people, claim).
    int64_t plan_family_membership_move(int32_t source_slot,
                                        int32_t destination_cell,
                                        int64_t moved_population,
                                        uint64_t preferred_family_handle,
                                        bool preferred_family_strict);
    struct FamilyMovePlanRow {
        int32_t edge = -1;
        int64_t people = 0;
        int64_t claim = 0;
    };
    std::vector<FamilyMovePlanRow> _family_move_plan;
    std::vector<int32_t> _family_destination_edge_scratch;
    // Sponsor of the build command being committed; 0 picks the cohort's
    // largest-claim family as before.
    uint64_t _construction_sponsor_override = 0;
    bool _construction_sponsor_override_set = false;
    uint64_t sponsor_family_for_cohort(uint64_t cohort_handle,
                                       int32_t cell) const;
    int32_t building_index_for_handle(uint64_t building_handle) const;
    void rebuild_building_handle_index() const;
    const std::unordered_map<uint64_t, int32_t> &building_handle_index() const;
    int64_t family_population(uint64_t family_handle) const;
    int64_t family_cash_claim(uint64_t family_handle) const;
    int64_t family_owned_buildings(uint64_t family_handle) const;
    bool compile_person_catalog(const godot::Dictionary &catalog,
                                std::string &error);
    bool run_person_commit_slice(int64_t &work_done, std::string &error);
    void rebuild_person_indices();
    void compact_person_needs();
    void normalize_person_needs();
    void bind_notable_person_jobs();
    void reconcile_person_claims();
    void update_person_equity_shares();
    void review_person_promotions();
    void promote_person_for_family(int32_t family_index);
    void register_person_effect(int32_t person_index);
    void retire_person(int32_t person_index);
    // An expedition payload detaches its people from the cohort lane on
    // purpose (cohort_handle == 0). `person_in_expedition_transit` marks such a
    // travelling person so PERSON_COMMIT does not retire them mid-voyage, and
    // `drop_expedition_transit_person` keeps the payload lanes consistent when
    // some other authority (family dissolution) does retire one.
    bool person_in_expedition_transit(uint64_t person_handle) const;
    void drop_expedition_transit_person(uint64_t person_handle);
    void record_person_demography(int32_t cohort_slot,
                                  int64_t population_before,
                                  int64_t deaths);
    void move_notable_people(uint64_t source_cohort_handle,
                             uint64_t destination_cohort_handle,
                             uint64_t family_handle,
                             int64_t family_people_before,
                             int64_t moved_family_people);
    int32_t family_membership_index(uint64_t family_handle,
                                    uint64_t cohort_handle) const;
    int64_t desired_need_units_for_actor(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t actor_population, int64_t actor_funds,
        int64_t &saturation_count) const;
    bool slot_has_merchant_profession(int32_t slot) const;
    bool is_merchant_slot(int32_t slot) const;
    int64_t living_merchant_population(int32_t cell) const;
    bool market_has_living_merchant(int32_t market) const;
    void collect_living_merchant_slots(int32_t market,
                                       std::vector<int32_t> &out) const;
    bool ensure_market_has_living_merchant(int32_t market, int64_t &repair_count,
                                           std::string &error);
    void touch_accounting_slot(int32_t slot);
    void record_cohort_fiscal(int32_t slot, int64_t signed_amount);
    void rebuild_incremental_audit_shadow();
    void begin_incremental_audit_epoch();
    // Continuous audit (touched-lane shadow carried across epochs) is on unless
    // PK_ECONOMY_AUDIT_SHADOW_REUSE=0. The 25-day full audit still runs.
    static bool audit_shadow_reuse_enabled();
    void audit_touch_population_lane(int32_t slot);
    void audit_touch_market_lane(size_t index);
    void sum_family_expedition_holdings(int64_t &population, int64_t &funds,
                                        int64_t &goods, int64_t &saturation) const;
    int64_t family_expedition_payload_people(int32_t expedition) const;
    int64_t family_expedition_payload_family_people(int32_t expedition) const;
    int64_t family_expedition_anonymous_people(int32_t expedition) const;
    void note_family_expedition_audit_invalidation();

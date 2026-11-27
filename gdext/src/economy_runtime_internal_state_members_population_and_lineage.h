// Population stores, family expeditions, and derived lineage and settlement worksets.

    // Local fallback when formula stores are not bound to OwnedState.
    PopulationStore _population_local;
    RuntimeEconomyOwnedState *_formula_owned = nullptr;
    RuntimeEconomyResourceStore *_resource_store_alias = nullptr;
    PopulationStore &population_store() noexcept {
        return _formula_owned != nullptr ? _formula_owned->population
                                         : _population_local;
    }
    const PopulationStore &population_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->population
                                         : _population_local;
    }
    // A+Y N3/N4: unbound fallback only; see families_store().
    FamilyStore _families_local;
    // A+Y N5: unbound fallback only; see family_expeditions_store() and the
    // companion CSR accessors below.
    FamilyExpeditionStore _family_expeditions_local;
    EconomyOwnedColumn<int32_t> _family_expedition_route_cells_local{{{11, 1}, "expedition_side.route_cells", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _family_expedition_route_costs_local{{{11, 2}, "expedition_side.route_costs", EconomyFieldEncoding::I32, 4}};
    EconomyTrackedRecords<FamilyExpeditionPayload> _family_expedition_payloads_local{{{12, 5}, "family_records.family_expedition_payloads", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyOwnedColumn<uint64_t> _family_expedition_person_handles_local{{{11, 3}, "expedition_side.person_handles", EconomyFieldEncoding::U64, 8}};
    EconomyTrackedRecords<FamilyExpeditionCargoLine> _family_expedition_cargo_local{{{12, 6}, "family_records.family_expedition_cargo", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyTrackedRecords<FamilyExpeditionKitBuilding> _family_expedition_kit_buildings_local{{{12, 7}, "family_records.family_expedition_kit_buildings", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyOwnedColumn<int32_t> _family_expedition_missing_good_ids_local{{{11, 4}, "expedition_side.missing_good_ids", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int64_t> _family_expedition_missing_good_quantities_local{{{11, 5}, "expedition_side.missing_good_quantities", EconomyFieldEncoding::I64, 8}};
    // Derived lookup/scheduling caches over the expedition store. Rebuilt from
    // the authoritative columns, so they stay NER-local across bind/unbind.
    std::unordered_map<uint64_t, int32_t> _family_expedition_target_index;
    std::vector<std::pair<int64_t, int32_t>> _family_expedition_due_heap;
    std::vector<ColonizationReceipt> _colonization_receipts;
    EconomyTrackedScalar<int64_t> _next_colonization_receipt_id{_metadata_changes, {{15, 69}, "config.next_colonization_receipt_id", EconomyFieldEncoding::I64, 8}, 1};
    EconomyTrackedScalar<int64_t> _next_family_expedition_stable_id{_metadata_changes, {{15, 71}, "config.next_family_expedition_stable_id", EconomyFieldEncoding::I64, 8}, 1};
    std::vector<ColonizationQuoteCacheEntry> _colonization_quote_cache;
    std::unordered_map<uint64_t, int32_t> _colonization_quote_index;
    std::vector<int32_t> _colonization_quote_route_cells;
    std::vector<int32_t> _colonization_quote_route_costs;
    std::vector<int64_t> _colonization_distance;
    std::vector<uint32_t> _colonization_distance_stamp;
    std::vector<int32_t> _colonization_parent;
    std::vector<uint32_t> _colonization_parent_stamp;
    std::vector<std::pair<int64_t, int32_t>> _colonization_route_heap;
    uint32_t _colonization_search_stamp = 0;
    std::vector<int32_t> _transport_succ_cells;
    std::vector<int32_t> _transport_succ_costs;
    double _colonization_route_query_ms = 0.0;
    double _colonization_payload_split_ms = 0.0;
    double _colonization_cross_domain_ms = 0.0;
    EconomyKeyedVariableRecords<CanalQuote> _canal_quotes{{{27, 2}, "canal.quotes", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyTrackedJournal<uint64_t, int32_t> _canal_quote_index{{{27, 3}, "canal.active_quote_index", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyKeyedVariableRecords<CanalProject> _canal_projects{
        {{27, 1}, "infrastructure.canal_projects", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::unordered_map<uint64_t, int32_t> _canal_project_index;
    std::vector<CanalConstructionReceipt> _canal_receipts;
    EconomyTrackedScalar<uint64_t> _next_canal_quote_token{_metadata_changes, {{15, 67}, "config.next_canal_quote_token", EconomyFieldEncoding::U64, 8}, 1};
    EconomyTrackedScalar<uint64_t> _next_canal_project_id{_metadata_changes, {{15, 23}, "metadata.next_canal_project_id", EconomyFieldEncoding::U64, 8}, 1};
    EconomyTrackedScalar<int64_t> _next_canal_receipt_id{_metadata_changes, {{15, 68}, "config.next_canal_receipt_id", EconomyFieldEncoding::I64, 8}, 1};
    // A+Y N5: unbound fallback only; see the accessors below.
    FamilyCellInfluenceStore _family_influences_local;
    NotablePersonStore _persons_local;
    EconomyTrackedRecords<FamilyMembershipEdge> _family_memberships_local{{{12, 1}, "family_records.family_memberships", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyTrackedRecords<FamilyBuildingOwnership> _family_ownerships_local{{{12, 2}, "family_records.family_ownerships", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyTrackedRecords<FamilyTraitRoll> _family_traits_local{{{12, 3}, "family_records.family_trait_rolls", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _family_behavior_factor_offsets;
    std::vector<FamilyBehaviorFactorRow> _family_behavior_factor_rows;
    std::vector<FamilyBehaviorSourceRow> _family_behavior_source_rows;
    std::vector<int32_t> _family_purchase_factor_q16;
    std::vector<int32_t> _family_investment_factor_q16;
    std::vector<int32_t> _family_birth_factor_q16;
    std::vector<int32_t> _family_absorb_bonus_q16;
    std::vector<int32_t> _family_colonization_population_reward;
    // A population reward frozen by family.population_reward must survive
    // policy recomputation until the next successful SETTLE ACK. It is stored
    // in PKEC family records and the economy state hash, separately from the
    // per-epoch expansionism effect scalar.
    std::vector<int32_t> _family_colonization_population_reward_pending;
    EconomyTrackedRecords<FamilyTraitCommand> _family_trait_commands{{{14, 4}, "commands.family_trait_commands", EconomyFieldEncoding::CanonicalRecord, 1}};
    // Milestone founding: per-cell count of population milestones that have
    // produced a family, offers awaiting a player choice, queued choices, and
    // the random-pool effect preselected on the chosen card (by stable id).
    EconomyOwnedColumn<uint8_t> _family_milestones_reached{
        {{16, 27}, "family.milestones_reached", EconomyFieldEncoding::U8, 1}};
    EconomyKeyedVariableRecords<FamilyFoundingOffer> _family_founding_offers{{{24, 1}, "family_variable.family_founding_offers", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyTrackedRecords<FamilyFoundingChoiceCommand> _family_founding_choices{{{14, 5}, "commands.family_founding_choices", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyKeyedVariableRecords<std::pair<int64_t, int32_t>> _family_founding_effects{
        {{24, 5}, "family.founding_effects", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyKeyedVariableRecords<std::pair<int64_t, int64_t>> _family_split_parents{
        {{24, 6}, "family.split_parents", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyTrackedScalar<int64_t> _next_family_founding_offer_id{_metadata_changes,
        {{15, 31}, "family.next_founding_offer_id", EconomyFieldEncoding::I64, 8}, 1};
    godot::Array _family_founding_receipts;
    std::vector<int32_t> _family_founding_offer_by_cell;
    bool _family_founding_offer_index_dirty = true;
    EconomyKeyedVariableRecords<FamilyModifierBinding> _family_modifier_bindings{{{24, 2}, "family_variable.family_modifier_bindings", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyKeyedVariableRecords<FamilyEffectBinding> _family_effect_bindings{{{24, 4}, "family_variable.family_effect_bindings", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::unordered_map<int64_t, size_t> _family_effect_binding_by_instance;
    std::unordered_map<uint64_t, std::vector<int64_t>>
        _family_effect_instances_by_branch;
    std::unordered_map<int32_t, std::vector<int64_t>>
        _family_effect_instances_by_cell;
    EconomyKeyedVariableRecords<FamilyTriggerBinding> _family_trigger_bindings{{{24, 3}, "family_variable.family_trigger_bindings", EconomyFieldEncoding::CanonicalRecord, 1}};
    // A+Y N5: unbound fallback only; see person_needs().
    EconomyTrackedRecords<PersonNeedState> _person_needs_local{{{12, 4}, "family_records.person_needs", EconomyFieldEncoding::CanonicalRecord, 1}};
    // Set when a retirement leaves need rows behind. Compaction is deferred to
    // one pass so retiring N people costs O(rows) instead of O(N * rows).
    bool _person_needs_orphaned = false;
    // Cleared whenever the row set is replaced. While set, the rows are already
    // pruned, sorted and deduped, so a second rebuild in the same commit can
    // skip straight to the CSR construction.
    bool _person_needs_normalized = false;
    std::vector<PersonNeedState> _person_need_scratch;
    std::vector<int32_t> _person_need_owner_scratch;
    std::vector<int32_t> _person_need_cursor_scratch;
    // Influence shares move slowly and are only consumed by the per-branch
    // prestige review, which is itself on a 30-day phased cadence. Refresh runs
    // on this epoch stride, and always on a commit that changed the edge set so
    // branch creation and release are never deferred.
    static constexpr int64_t FAMILY_INFLUENCE_REFRESH_EPOCHS = 4;
    // Derived, transient CSR. Authoritative edges above remain sparse and are
    // rebuilt only at FAMILY_COMMIT or after structural restore.
    std::vector<int32_t> _family_member_offsets;
    std::vector<int32_t> _family_member_edge_indices;
    std::vector<int32_t> _family_owned_offsets;
    std::vector<int32_t> _family_owned_edge_indices;
    std::vector<int32_t> _family_cohort_offsets;
    std::vector<int32_t> _family_cohort_edge_indices;
    std::vector<int32_t> _family_building_offsets;
    std::vector<int32_t> _family_building_edge_indices;
    std::vector<int32_t> _family_cell_offsets;
    std::vector<int32_t> _family_cell_indices;
    std::vector<FamilyIndustryStats> _family_industry_stats;
    std::vector<FamilyOwnedOutputRow> _family_owned_output_rows;
    bool _family_indices_dirty = true;
    // Membership rows covered by the cohort CSR. Rows are only appended
    // between rebuilds, so [count, size) is the unindexed tail; SIZE_MAX
    // after an erase forces a full scan until the next rebuild.
    size_t _family_csr_edge_count = std::numeric_limits<size_t>::max();
    // Derived branch demography frozen at epoch begin from persisted state;
    // sorted by (cell, family_handle). Never persisted or hashed.
    struct FamilyDemographyRow {
        int32_t cell = -1;
        uint64_t family_handle = 0;
        int32_t family_index = -1;
        int32_t ethnicity = -1;
        int64_t people = 0;
        int64_t ethnic_population = 0;
        int32_t share_q16 = 0;
        int32_t target_share_q16 = 0;
        int32_t distress_q16 = 0;
        int32_t health_q16 = 0;
        int32_t birth_weight_q16 = 0;
        int32_t death_weight_q16 = 0;
    };
    std::vector<FamilyDemographyRow> _family_demography_rows;
    // Owner seats a family's owned units need in each owner cohort, frozen
    // with the demography rows; sorted by (cohort_handle, family_handle).
    struct FamilyOwnerSeatRow {
        uint64_t cohort_handle = 0;
        uint64_t family_handle = 0;
        int64_t seats = 0;
    };
    std::vector<FamilyOwnerSeatRow> _family_owner_seat_rows;
    std::vector<int32_t> _family_edge_scratch;
    std::vector<int64_t> _family_ledger_business_by_slot;
    std::vector<int32_t> _family_ledger_touched_slots;
    std::vector<int64_t> _family_ledger_business_by_edge;
    int64_t _family_births_attributed = 0;
    int64_t _family_deaths_attributed = 0;
    int64_t _family_reconcile_corrections = 0;
    int64_t _family_ledger_clamps = 0;
    int64_t _family_people_recruited = 0;
    int64_t _family_units_released = 0;
    int64_t _family_release_deferred = 0;
    int64_t _family_owner_seats_guarded = 0;
    double _family_demography_weights_ms = 0.0;
    // Derived notable-person CSR; rebuilt at PERSON_COMMIT and restore.
    std::vector<int32_t> _person_family_offsets;
    std::vector<int32_t> _person_family_indices;
    std::vector<int32_t> _person_cohort_offsets;
    std::vector<int32_t> _person_cohort_indices;
    std::vector<int32_t> _person_index_building_scratch;
    std::vector<int32_t> _person_index_family_scratch, _person_index_cohort_scratch;
    std::vector<int32_t> _person_index_cell_scratch, _person_index_building_cursor_scratch;
    std::vector<int32_t> _pending_construction_cursor_scratch;
    std::vector<int32_t> _person_cell_offsets;
    std::vector<int32_t> _person_cell_indices;
    std::vector<int32_t> _person_building_offsets;
    std::vector<int32_t> _person_building_indices;
    std::vector<int32_t> _person_need_offsets;
    bool _person_indices_dirty = true;
    // Frozen claim and epoch attribution scratch. Excluded from PKEC/hash.
    std::vector<int64_t> _person_opening_cash_claim;
    std::vector<PersonNeedState> _person_epoch_needs;
    std::vector<uint64_t> _person_previous_building_handle;
    std::vector<uint8_t> _person_previous_job_kind;
    std::vector<int32_t> _person_previous_employee_role_index;
    SettlementStore _settlements;
    MarketStore _market_local;
    mutable RuntimeEconomyBuildingStore _buildings_soa_local;
    MarketStore &market_store() noexcept {
        return _formula_owned != nullptr ? _formula_owned->market
                                         : _market_local;
    }
    const MarketStore &market_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->market
                                         : _market_local;
    }
    MarketSignalStore _market_signals;
    MarketSignalStore _market_signals_rebuild_scratch;
    // Phase-1 dirty rebuild: only recompute CSR lanes for dirty cells unless a
    // catalog/save restore forces a full rebuild.
    std::vector<uint8_t> _market_signal_cell_dirty;
    std::vector<uint8_t> _labor_signal_cell_dirty;
    std::vector<uint8_t> _input_reserve_cell_dirty;
    bool _market_signal_force_full = true;
    bool _labor_signal_force_full = true;
    bool _input_reserve_force_full = true;
    std::string _market_signal_full_rebuild_reason = "bootstrap";
    std::string _labor_signal_full_rebuild_reason = "bootstrap";
    std::string _input_reserve_full_rebuild_reason = "bootstrap";
    int64_t _market_signal_cells_rebuilt = 0;
    int64_t _labor_signal_cells_rebuilt = 0;
    int64_t _input_reserve_groups_rebuilt = 0;
    std::vector<int64_t> _epoch_business_demand_ema;
    // Leontief shadow derived demand from unmet final/business deficits through
    // preferred producer BOMs. Recomputed each sample; excluded from PKEC/hash.
    std::vector<int64_t> _epoch_derived_business_demand;
    // Per-signal Leontief shadow value anchor used only for price adjustment
    // when no real producer cost anchor exists.
    std::vector<int64_t> _epoch_derived_anchor_price;
    std::vector<int64_t> _track_b_derived_anchor_carry;
    int32_t _derived_shadow_anchor_weight_q16 = Q16_ONE / 32;
    int32_t _derived_startup_absorption_q16 = Q16_ONE;
    // Track B (user-approved approximation): carry the last computed derived
    // business demand so every N-th day can reuse it instead of running the
    // full BFS/preview pass. Exact mode is restored with PK_ECONOMY_TRACK_B=0.
    std::vector<int64_t> _track_b_derived_carry;
    // Track B commit spread: investment review cells still waiting for their
    // turn (processed incrementally across epochs, 1/N per day).
    std::vector<int32_t> _track_b_investment_cells_pending;
    // Track B: per-runtime carry for the cadenced AGGREGATE_PUBLISH state hash.
    // Must be per-runtime (not file-static): parity tests boot two runtimes in
    // one process and interleave their days.
    int64_t _track_b_hash_last_day = -1000000;
    uint64_t _track_b_hash_last_value = 0;

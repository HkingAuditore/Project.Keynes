// Included inside NativeEconomyRuntime; preserve declaration order and access.
    enum HouseholdSlicePhase : size_t {
        HOUSEHOLD_PREPARE = 0,
        HOUSEHOLD_WORKER,
        HOUSEHOLD_MERGE_AGGREGATE,
        HOUSEHOLD_MERGE_TRADE,
        HOUSEHOLD_TRACE,
        HOUSEHOLD_OTHER,
        HOUSEHOLD_POST_BUILDINGS,
        HOUSEHOLD_RESERVE_SHORTFALL,
        HOUSEHOLD_INCOME_SUBSIDY,
        HOUSEHOLD_STRUCTURAL_SORT,
        HOUSEHOLD_SLICE_PHASE_COUNT,
    };
    std::array<double, HOUSEHOLD_SLICE_PHASE_COUNT> _household_slice_phase_ms{};
    std::array<int64_t, HOUSEHOLD_SLICE_PHASE_COUNT> _household_slice_phase_work{};

    AuditTotals _opening_totals;
    AuditTotals _closing_totals;
    AuditTotals _publish_accum;
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
    // Track B spread mode: per-live-cell derived work cache so each day only a
    // 1/N slice of cells is recomputed and the ordered merge covers all cells.
    std::vector<TrackBDerivedCellWork> _track_b_derived_cell_cache;
    int64_t _track_b_derived_cell_cache_day = -1000000;
    int32_t _track_b_derived_cell_cache_cells = -1;
    struct DerivedHouseholdPreview {
        std::vector<int64_t> goods;
        int64_t saturations = 0;
        bool ready = false;
    };
    std::vector<DerivedHouseholdPreview> _derived_household_preview_scratch;
    // Same-input-edge substitutes that were not selected for procurement still
    // receive this shadow demand so producers of eligible SKUs (e.g. chipped
    // stone when bronze was chosen) can see category-level unmet need. Price,
    // investment, and Leontief seeding read it; merchant targets do not.
    std::vector<int64_t> _epoch_substitute_business_demand;
    std::vector<int64_t> _epoch_desired_business_demand;
    std::vector<int64_t> _epoch_funded_business_demand;
    // Confidence weight for folding derived demand into price pressure.
    int32_t _derived_business_demand_weight_q16 = Q16_ONE / 2;
    int64_t _derived_business_demand_total = 0;
    int64_t _derived_business_demand_lanes = 0;
    int64_t _derived_business_demand_edges = 0;
    std::vector<int64_t> _epoch_offered_supply_ema;
    // Current and previous-cycle producer absorption observations, aligned to
    // sparse (cell, good) market-signal lanes. These are transient and excluded
    // from PKEC and the authoritative state hash.
    std::vector<int64_t> _epoch_producer_sellable_current;
    std::vector<int64_t> _epoch_producer_merchant_sold_current;
    std::vector<int64_t> _epoch_previous_producer_sellable;
    std::vector<int64_t> _epoch_previous_producer_merchant_sold;
    std::vector<int64_t> _epoch_producer_discarded_current;
    std::vector<int64_t> _epoch_nonhousehold_withdrawals;
    std::vector<int32_t> _epoch_cost_anchor_price;
    std::vector<int64_t> _production_input_reserve;
    std::vector<int64_t> _construction_material_reserve;
    // Country research demand is derived once from the frozen country policy,
    // prices, and population at epoch begin. It is deliberately transient:
    // country treasury/goods remain Country authority and this cache is not
    // part of PKEC or the economy state hash.
    // Frozen one-shot procurement backlog, sparse sorted (cell/market, good).
    // Rebuilt from PREPARING custody and spendable Country cash each epoch;
    // not an order, withdrawal, wallet, persistent EMA, or save/hash lane.
    std::vector<std::pair<uint64_t, int64_t>> _epoch_colonization_demand_by_cell;
    std::vector<std::pair<uint64_t, int64_t>> _epoch_colonization_demand_by_market;
    // Derived daily military demand. The standing snapshot itself reuses the
    // persisted owner command queue (opcode 36); no second ingress/save lane.
    std::vector<std::pair<uint64_t, int64_t>> _epoch_military_demand_by_cell;
    std::vector<std::pair<uint64_t, int64_t>> _epoch_military_demand_by_market;
    int32_t _epoch_research_good_id = -1;
    std::vector<int64_t> _epoch_research_demand_by_cell;
    std::vector<int64_t> _epoch_research_demand_by_market;
    // One shared, deterministic mint budget per cell across all monetary goods.
    // Production and investment read the same remaining quota; no candidate can value the
    // complete global cap independently.
    std::vector<uint64_t> _epoch_bullion_quota_keys;
    std::vector<int64_t> _epoch_bullion_quota_initial;
    std::vector<int64_t> _epoch_bullion_quota_remaining;
    int64_t _epoch_bullion_quota_initial_total = 0;
    int64_t _epoch_bullion_quota_remaining_total = 0;
    int64_t _epoch_bullion_quota_remainder_units = 0;
    // Building retention and household clearing share the same frozen basis.
    // These non-authoritative arrays avoid repeating elasticity/pow work.
    std::vector<int64_t> _demand_basis_cache_day;
    std::vector<int64_t> _demand_basis_variant_scores;
    std::vector<int64_t> _demand_basis_variant_prices;
    std::vector<int64_t> _demand_basis_need_score_sums;
    std::vector<int64_t> _demand_basis_need_composites;
    std::vector<int64_t> _demand_basis_need_environment;
    // Persistent per-cell rolling settlement state. Phase is derived from the
    // Stable cell id; last day and generation are PKEC v16 authority.
    EconomyOwnedColumn<int64_t> _cell_last_settlement_day{{{16, 9}, "native_columns.cell_last_settlement_day", EconomyFieldEncoding::I64, 8}};
    // Q32 fractional births accumulated per cell and ethnicity.
    EconomyOwnedColumn<int64_t> _birth_residual_q32{{{16, 1}, "native_columns.birth_residual_q32", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<uint32_t> _cell_settlement_generation{{{16, 13}, "native_columns.cell_settlement_generation", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_price_stock_gen{{{16, 12}, "native_columns.cell_price_stock_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_owner_cash_gen{{{16, 10}, "native_columns.cell_owner_cash_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_population_gen{{{16, 11}, "native_columns.cell_population_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_building_structure_gen{{{16, 2}, "native_columns.cell_building_structure_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_technology_gen{{{16, 16}, "native_columns.cell_technology_gen", EconomyFieldEncoding::U32, 4}};
    ChangeRegistry _resource_changes_local;
    EconomyTrackedColumn<uint32_t> _cell_resource_gen{_resource_changes_local,
        {{3, 2}, "resource.cell_generation", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_trade_gen{{{16, 17}, "native_columns.cell_trade_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<int32_t> _cell_effect_shortage_q16{{{16, 28}, "persisted_columns.cell_effect_shortage_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_essentials_shortage_q16{{{16, 29}, "persisted_columns.cell_essentials_shortage_q16", EconomyFieldEncoding::I32, 4}};
    std::vector<int32_t> _cell_resource_abundance_q16;
    std::vector<int32_t> _cell_previous_precipitation_q16;
    std::vector<int32_t> _cell_rain_event_q16;
    std::vector<uint8_t> _good_is_essential;
    int32_t _max_building_upgrade_tier = 0;
    // Transaction worksets are deterministic, sorted and never persisted.
    std::vector<int32_t> _epoch_market_ids;
    std::vector<int64_t> _epoch_market_work_weights;
    // Scratch union of populated / building / pending-construction cells.
    // Rebuilt each epoch_begin; never saved or hashed.
    std::vector<int32_t> _economy_live_cells;
    // Copy for main-thread readers: the worker iterates _economy_live_cells
    // (tax, investment) during an epoch, so queries must never rebuild it.
    mutable std::mutex _economy_live_cells_published_mutex;
    std::shared_ptr<const std::vector<int32_t>> _economy_live_cells_published;
    std::vector<int32_t> _epoch_settlement_cells;
    std::vector<int32_t> _epoch_building_cells;
    // Subset of today's market workset whose plan evaluation is due on the
    // locked slow cycle S. Cells that are S-due but not in today's market
    // bucket wait until their next market day. Production still consumes the
    // last computed plan.
    std::vector<int32_t> _epoch_plan_cells;
    std::vector<int64_t> _household_post_saturation_scratch;
    std::vector<int64_t> _household_post_restarted_scratch;
    std::vector<int64_t> _household_post_failed_scratch;
    std::vector<int64_t> _household_reserve_shortfall_scratch;
    // Diagnostic-only per-cell contributions for the current rolling epoch.
    // Employment can be recomputed after structural changes; replacing the
    // cached contribution avoids subtracting a cell that was never counted in
    // this epoch and keeps the published totals non-negative.
    std::vector<int64_t> _employment_metrics_epoch_by_cell;
    std::vector<int64_t> _employment_owner_jobs_by_cell;
    std::vector<int64_t> _employment_employee_jobs_by_cell;
    std::vector<int64_t> _employment_unemployed_by_cell;
    // Epoch-transient lanes. They are rebuilt from the frozen sample and are
    // intentionally excluded from save data and the authoritative state hash.
    std::vector<int64_t> _building_survival_utilization_floor_q16;
    std::vector<int64_t> _building_planned_capacity_before_climate_q16;
    std::vector<int64_t> _building_funded_capacity_q16;
    std::vector<int64_t> _building_working_capital_allocated;
    std::vector<int64_t> _building_owner_livelihood_credit;
    std::vector<int64_t> _building_merchant_credit_limit;
    // Suspended producers keep no production, labor, or input demand. Permanent
    // liquidation is reviewed only when a full restart is physically and
    // financially executable but still economically unviable.
    std::vector<int64_t> _building_recovery_probe_capacity_q16;
    std::vector<uint8_t> _building_recovery_liquidation_eligible;
    // Phase-1 BuildingOutputFactorKey: shared identity for country/type/terrain/
    // landform/sector composite factors. Per-group cache still also keys owner
    // and family-owned mix; this struct documents the Plan key and is used when
    // comparing the geography/policy half of a cache entry.
    struct BuildingOutputFactorKey {
        int32_t country = -1;
        int32_t building_type = -1;
        int32_t terrain = -1;
        int32_t landform = -1;
        int32_t sector = -1;

        bool operator==(const BuildingOutputFactorKey &other) const noexcept {
            return country == other.country &&
                   building_type == other.building_type &&
                   terrain == other.terrain &&
                   landform == other.landform &&
                   sector == other.sector;
        }
    };
    // Per-group cache for refresh_building_modifier_factors, keyed on every
    // input of group.output_factor_q16 / modifier_handle: every frozen
    // country factor value, country handle, ECONOMY store snapshot_version,
    // and the (type, owner) identity. During a frozen epoch the group lane is
    // append-only; topology rebuilds permute the compact lane only at
    // BUILDING_COMMIT / idle boundaries and remap this cache with them.
    // Cache hits skip both ensure_building_identity and the ECONOMY
    // effective_value query. Transient; never saved or hashed.
    struct BuildingFactorCacheEntry {
        BuildingOutputFactorKey output_key{};
        int64_t country_factor_q16 = std::numeric_limits<int64_t>::min();
        int64_t sector_factor_q16 = 0;
        int64_t research_factor_q16 = 0;
        int64_t family_factor_q16 = 0;
        int64_t building_type_factor_q16 = 0;
        int64_t terrain_sector_factor_q16 = 0;
        int64_t landform_sector_factor_q16 = 0;
        uint64_t country_handle = 0;
        uint64_t mod_version = 0;
        uint64_t exact_building_mod_version = 0;
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int32_t family_owned_factor_q16 = Q16_ONE;
        int32_t cell_sector_factor_q16 = Q16_ONE;
        // 空组（count==0，含拆除后留下的墓碑槽）的 family-owned 混合因子恒为
        // Q16_ONE，与家族持股无关。把「当时是否为空」纳入身份判据后，空组可以
        // 完全跳过重算而不会在 count 变正时错误命中旧值。
        uint8_t count_positive = 0;
    };
    std::vector<BuildingFactorCacheEntry> _building_factor_cache;
    std::vector<BuildingFactorCacheEntry> _building_factor_cache_rebuild_scratch;
    // Persons whose cohort changed since the last CSR rebuild, keyed by the
    // cohort they landed in. Lets move_notable_people read the cohort CSR
    // instead of the whole person table without losing candidates the stale
    // CSR no longer lists.
    std::unordered_map<uint64_t, std::vector<int32_t>> _person_cohort_migrations;
    // Same idea for the person-family CSR, which promotion reads before the
    // next PERSON_COMMIT rebuild.
    std::unordered_map<uint64_t, std::vector<int32_t>> _person_family_migrations;
    // Live notable-person stable ids, so identity assignment can test for a
    // collision without walking the person table once per hash probe.
    std::unordered_set<int64_t> _person_stable_ids;
    std::unordered_set<int64_t> _family_stable_ids;
    // Live family indices grouped by surname, compacted lazily on read.
    std::vector<std::vector<int32_t>> _family_surname_members;
    std::vector<uint32_t> _person_candidate_stamp;
    uint32_t _person_candidate_generation = 0;
    int64_t _building_factor_cache_hits = 0;
    int64_t _building_factor_cache_misses = 0;
    std::vector<int64_t> _building_investment_score_q16;
    std::vector<int64_t> _building_investment_payback_days;
    std::vector<int32_t> _building_investment_rejection;
    // Review-only watermark: which economy epoch last rebuilt the transient
    // investment incumbent index. The Track-B spread path can carry review
    // cells into a later epoch without running the phase-4 prepare.
    int64_t _investment_prepared_epoch = -1;
    // Bounded cold-path diagnostics for the one inspector-selected cell. These
    // are transient, excluded from save/hash, and include absent building types.
    int32_t _investment_diagnostic_cell = -1;
    int64_t _investment_diagnostic_day = -1;
    std::vector<InvestmentDiagnostic> _investment_diagnostics;
    // Same cold-path contract as the investment diagnostics above: one
    // inspector-selected cell, transient, excluded from save/hash.
    int32_t _employment_diagnostic_cell = -1;
    int64_t _employment_diagnostic_day = -1;
    std::vector<EmploymentDiagnostic> _employment_diagnostics;
    static constexpr size_t EMPLOYMENT_DIAGNOSTIC_LIMIT = 512;
    // Scratch for the current cell only; consumed by the employment pass in the
    // same call that fills it.
    std::vector<FamilyOwnerClampTrace> _family_clamp_traces;
    std::unordered_map<uint64_t, int64_t> _investment_pending_by_cell_type;
    std::unordered_map<uint64_t, InvestmentExistingType>
        _investment_existing_by_cell_type;
    // Peak daily extraction already committed by installed and pending groups,
    // indexed as resource * cell_count + cell for the investment review only.
    std::vector<int64_t> _investment_resource_committed_by_cell;
    std::vector<int64_t> _investment_merchant_cash_by_cell;
    std::vector<int64_t> _investment_outstanding_credit_by_cell;
    std::vector<uint32_t> _investment_resource_commitment_stamp;
    std::vector<uint32_t> _investment_cell_finance_stamp;
    uint32_t _investment_scratch_generation = 0;
    std::vector<OutputInvestmentSignal> _investment_output_signals_scratch;
    std::vector<InvestmentIncumbentLane> _investment_incumbent_lanes_scratch;
    // Persistent settled incumbents keyed by (cell, output_good, type_id).
    // Updated only after a successful aggregate publish.
    std::vector<InvestmentIncumbentRecord> _investment_incumbent_records;
    std::vector<OwnerMobilityCooldown> _owner_mobility_cooldowns;
    std::vector<int32_t> _investment_employment_cells;
    std::vector<int32_t> _investment_review_cell_indices;
    // Catalog-derived output-good -> building-type CSR plus the current review
    // cell's sparse active-good set. These lanes are rebuildable scheduling
    // data and are excluded from PKEC and the authoritative state hash.
    std::vector<int32_t> _investment_good_type_offsets;
    std::vector<int32_t> _investment_good_type_indices;
    std::vector<uint64_t> _investment_active_good_words;
    std::vector<int32_t> _investment_active_goods_scratch;
    std::vector<uint32_t> _investment_type_stamp;
    std::vector<uint32_t> _investment_good_stamp;
    uint32_t _investment_review_stamp_generation = 0;
    std::vector<int32_t> _investment_review_types_scratch;
    std::vector<int32_t> _investment_good_queue_scratch;
    // Per-cell active plus pending monetary capacity, prepared once per
    // investment batch so candidate evaluation does not rescan building groups.
    std::vector<int64_t> _investment_monetary_units_by_cell;
    // v44 transient startup-demand graph. The dense value/stamp pair is the
    // fixed 12-byte (cell, good) budget; only stamped/touched lanes are read.
    // Remote/inbound lanes are sparse, rebuilt once per investment batch, and
    // excluded from PKEC and the authoritative state hash.
    std::vector<int64_t> _startup_demand_values;
    std::vector<uint32_t> _startup_demand_stamps;
    uint32_t _startup_demand_generation = 0;
    std::vector<uint64_t> _startup_demand_touched_keys;
    std::vector<int32_t> _startup_monetary_good_indices;
    std::vector<StartupRemoteLane> _startup_remote_lanes;
    std::vector<StartupRemoteGroup> _startup_remote_groups;
    std::vector<StartupInboundLane> _startup_inbound_lanes;
    std::vector<StartupRemoteAccumulator> _startup_remote_accumulator_scratch;
    // Epoch-transient worker outputs. Keeping the nested vector capacities
    // avoids rebuilding thousands of small buffers every household slice.
    std::vector<MarketResult> _market_results_scratch;
    std::vector<ProductionResult> _production_results_scratch;
    // Production uses stable contiguous weighted ranges. These transient
    // buffers are diagnostics/scheduling scratch only and never enter PKEC or
    // the authoritative state hash.
    std::vector<int64_t> _production_cell_weights_scratch;
    std::vector<int32_t> _production_task_offsets_scratch;
    std::vector<int64_t> _production_task_weights_scratch;
    std::vector<double> _production_task_ms_scratch;
    std::vector<AuditTotals> _audit_task_totals_scratch;
    std::vector<int64_t> _audit_task_saturation_scratch;
    std::vector<double> _audit_task_ms_scratch;
    std::vector<BuildingPlanResult> _building_plan_results_scratch;
    CompletedEpochPerf _last_completed_perf;
    std::vector<uint64_t> _trade_active_keys;
    std::vector<uint8_t> _trade_active_key_present;
    std::unordered_map<uint64_t, uint8_t> _trade_active_key_idle_cycles;
    // Diagnostic-only sparse clocks keyed independently from authoritative EMA state.
    std::vector<uint64_t> _trade_signal_clock_keys;
    std::vector<uint64_t> _trade_signal_bulk_keys_scratch;
    std::vector<int64_t> _trade_signal_first_seen_day;
    std::vector<int64_t> _trade_signal_first_dispatch_day;
    std::vector<int64_t> _trade_signal_last_attempt_day;
    std::vector<int32_t> _trade_signal_last_rejection_reason;
    std::vector<uint8_t> _trade_signal_deadline_reported;
    // Investment-only append lanes. Entries are immediately visible through
    // dense_index, then stably merged into the authoritative CSR before publish.
    std::vector<int32_t> _market_signal_overflow_cells;
    std::vector<OwnerRetainedOutput> _owner_retained_outputs;
    TradeTopologyStore _trade_topology;
    TradePlanStore _trade_plan;
    // A+Y N3/N4: unbound fallback only; see trade_orders_store().
    TradeOrderStore _trade_orders_local;
    TradeFlowSignalStore _trade_flows;
    CountryGoodTradeAggregateStore _country_good_trade;
    CountryPartnerTradeAggregateStore _country_partner_trade;
    TariffHistoryStore _tariff_history;
    // Rebuildable sparse lookup/display indices.  The authoritative aggregate
    // columns above remain the only persisted/hashed state; these maps remove
    // the former O(total aggregates) rebuild from every dispatch, while the
    // per-country sorted row lists make paged UI queries O(limit).
    std::unordered_map<uint64_t, int32_t> _country_good_trade_index;
    std::unordered_map<uint64_t, int32_t> _country_partner_trade_index;
    std::unordered_map<uint64_t, int32_t> _tariff_history_index;
    std::vector<std::vector<int32_t>> _country_good_display_rows;
    std::vector<std::vector<int32_t>> _country_partner_display_rows;
    std::vector<uint8_t> _country_good_display_dirty;
    std::vector<uint8_t> _country_partner_display_dirty;
    EconomyTrackedScalar<uint64_t> _country_trade_revision{_metadata_changes, {{15, 5}, "metadata.country_trade_revision", EconomyFieldEncoding::U64, 8}, 0};
    LaborMarketStore _labor_signals;
    LaborMarketStore _labor_signals_rebuild_scratch;
    std::vector<FormulaDefinition> _formulas;
    std::unordered_map<std::string, int32_t> _formula_by_id;
    std::vector<Signature> _signatures;
    // Dense (profession_id * n_ethnicity + ethnicity_id) -> signature_id lookup,
    // -1 when absent. Built once alongside _signatures. Lets the employment pass
    // resolve "the signature for this profession worker of this ethnicity" and
    // "the unemployed signature for this ethnicity" in O(1) without scanning.
    std::vector<int32_t> _signature_by_profession_ethnicity;
    std::vector<Plan> _plans;
    std::vector<Need> _needs;
    std::vector<VariantChoice> _variants;
    std::vector<NeedComponent> _components;
    // Catalog-only equivalence for the market/environment part of preview.
    // Actor wealth, family preferences and quantities still run per cohort.
    std::vector<int32_t> _preview_need_basis_source;
    std::vector<EnvironmentCurve> _environment_curves;
    std::vector<std::string> _need_ids;
    std::vector<int32_t> _ethnicity_need_factor_q16;
    std::vector<Rule> _rules;
    std::vector<int64_t> _rule_params;
    EconomyKeyedVariableRecords<std::string> _profession_ids{{{26, 9}, "catalog_ids.profession_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _profession_class_index;
    // Days of the cell's per-capita living cost a cohort must hold per person
    // before members may move into this profession from a lower-entry one.
    std::vector<int32_t> _profession_entry_savings_days;
    // Military v1 (design §5.1). `state_service_only` professions (the soldier)
    // may only be filled as employee roles of state buildings and never transfer
    // OUT of their own signature along any recruitment/reflux/migration lane.
    // `_profession_state_supplied_need_mask` is laid out as
    // [profession * _need_ids.size() + stable_need]; a need flagged here is a
    // military ration need whose satisfaction comes from
    // `set_military_ration_satisfaction` instead of a market purchase.
    std::vector<uint8_t> _profession_state_service_only;
    std::vector<uint8_t> _profession_state_supplied_need_mask;
    // Any nonzero entry means some profession has state-supplied needs, so the
    // household and employment hot loops can keep their fast path.
    int32_t _state_supplied_need_columns = 0;
    // Reserved owner sentinel for state buildings. The signature id is resolved
    // from the reserved flag so no real cohort can ever collide with it.
    int32_t _state_owner_signature = -1;
    // Per-cell military ration satisfaction (Q16, 1.0 = fully supplied).
    // Deterministic scratch cache owned by Military via
    // set_military_ration_satisfaction; absent cells read Q16_ONE so a world
    // without soldiers is bit-identical to the pre-military behaviour.
    std::vector<int32_t> _military_ration_sat_q16;
    std::vector<uint8_t> _military_ration_sat_present;

    enum StateBuildingRole : int32_t {
        STATE_ROLE_NONE = 0,
        STATE_ROLE_BARRACKS = 1,
        STATE_ROLE_FORTIFICATION = 2,
        STATE_ROLE_WAR_COLLEGE = 3,
    };
    std::vector<std::string> _carrying_class_ids;
    std::vector<int32_t> _profession_political_class_index;
    std::vector<std::string> _political_class_ids;
    uint64_t _political_class_hash = 0;
    RuntimeCommittedViewVersion _lineage_opinion_view_version;
    std::array<CountryClassOpinionSnapshot, 2> _class_opinion_buffers;
    int32_t _class_opinion_committed_buffer = 0;
    uint64_t _class_opinion_revision = 0;
    std::unique_ptr<struct CountryAiShared> _country_ai;
    void reset_country_ai_pending();
    CountryReadView country_reads() const;
    void publish_country_ai_digest();
    void process_country_ai_colonization_intents(int64_t day_index);
    int32_t family_founding_ai_choice(const FamilyFoundingOffer &offer) const;
    uint64_t _class_opinion_cells_scanned = 0;
    uint64_t _class_opinion_slots_scanned = 0;
    uint64_t _class_opinion_zero_population_rows = 0;
    uint64_t _last_class_opinion_cells_scanned = 0;
    uint64_t _last_class_opinion_slots_scanned = 0;
    uint64_t _last_class_opinion_zero_population_rows = 0;
    double _class_opinion_ms = 0.0;
    std::vector<std::string> _carrying_family_ids;
    std::vector<int32_t> _carrying_family_need_stable;
    std::vector<int32_t> _carrying_family_good_offsets;
    std::vector<int32_t> _carrying_family_goods;
    std::vector<int32_t> _need_carrying_family;
    std::vector<int32_t> _carrying_support_resource_ids;
    std::vector<int32_t> _carrying_food_yield_offsets;
    std::vector<CarryingSupportYield> _carrying_food_yields;
    int64_t _carrying_survival_food_per_person = 1;
    std::vector<CarryingSupportYield> _epoch_country_support_yield;
    std::vector<int32_t> _profession_technology_offsets;
    std::vector<int32_t> _profession_required_technologies;
    EconomyKeyedVariableRecords<std::string> _ethnicity_ids{{{26, 6}, "catalog_ids.ethnicity_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _ethnicity_culture_group_ids;
    EconomyKeyedVariableRecords<std::string> _good_ids{{{26, 7}, "catalog_ids.good_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _good_occupancy_bit_offsets;
    std::vector<int32_t> _good_occupancy_bits;
    std::vector<int32_t> _bio_introduce_cells;
    std::vector<int32_t> _bio_introduce_bits;
    // Main-thread only. Production workers land introductions in
    // ProductionResult; merge_building_production_result commits them here.
    std::unordered_set<uint64_t> _bio_introduce_keys;
    EconomyKeyedVariableRecords<std::string> _plan_ids{{{26, 8}, "catalog_ids.plan_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _good_default_price;
    std::vector<int64_t> _good_default_stock;
    std::vector<int32_t> _good_reference_max_price;
    std::vector<int32_t> _good_price_adjust_q16;
    std::vector<int32_t> _good_demand_price_elasticity_q16;
    std::vector<int32_t> _good_household_wealth_elasticity_q16;
    std::vector<int32_t> _good_household_savings_threshold_months_q16;
    std::vector<int32_t> _good_demand_ema_alpha_q16;
    std::vector<int32_t> _good_target_inventory_days_q16;
    std::vector<int32_t> _good_inventory_weight_q16;
    std::vector<int32_t> _good_shortage_weight_q16;
    std::vector<int32_t> _good_excess_demand_weight_q16;
    std::vector<int32_t> _good_cost_anchor_weight_q16;
    std::vector<int32_t> _good_inactive_reversion_weight_q16;
    std::vector<int32_t> _good_business_demand_ema_alpha_q16;
    std::vector<int32_t> _good_supply_ema_alpha_q16;
    std::vector<int32_t> _good_cost_ema_alpha_q16;
    std::vector<int32_t> _good_max_price_rise_q16;
    std::vector<int32_t> _good_max_price_fall_q16;
    std::vector<int32_t> _good_merchant_buy_factor_q16;
	std::vector<uint8_t> _good_trade_enabled;
	std::vector<int32_t> _good_transport_load_per_unit_q16;
	std::vector<std::string> _good_category_ids;
	std::vector<int32_t> _good_storage_modes;
	std::vector<int64_t> _good_monetary_issue_values;
	std::vector<int32_t> _cycle_flow_good_ids;
	std::vector<int32_t> _good_technology_tag_offsets;
	std::vector<std::string> _good_technology_tags;
    std::vector<int32_t> _good_technology_offsets;
    std::vector<int32_t> _good_required_technologies;
    std::vector<int32_t> _merchant_primary_slot;
    std::vector<int32_t> _merchant_offsets;
    std::vector<int32_t> _merchant_slots;
    // Derived CSR invalidation; never persisted or hashed.
    bool _merchant_ranges_dirty = false;
    // 有商人的格，按格号升序，与 CSR 同一次构建产出。capture_country_epoch 原来
    // 为聚合每国商人人口扫整张地图；商人只存在于少数有人口的格，列表让它按实际
    // 端点数走。_valid=false 时消费方退回全图循环，语义不变。
    std::vector<int32_t> _merchant_nonempty_cells;
    bool _merchant_nonempty_cells_valid = false;
    EconomyOwnedColumn<int32_t> _environment_temperature_q16{{{16, 42}, "persisted_columns.environment_temperature_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_temperature_30d_q16{{{16, 41}, "persisted_columns.environment_temperature_30d_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_moisture_q16{{{16, 37}, "persisted_columns.environment_moisture_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_plant_available_water_q16{{{16, 38}, "persisted_columns.environment_plant_available_water_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_precipitation_q16{{{16, 39}, "persisted_columns.environment_precipitation_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_snow_q16{{{16, 40}, "persisted_columns.environment_snow_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_weather_q16{{{16, 43}, "persisted_columns.environment_weather_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_temperature_annual_q16{{{16, 52}, "persisted_columns.cell_temperature_annual_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_temperature_anomaly_q16{{{16, 53}, "persisted_columns.cell_temperature_anomaly_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_hazard_today_mask{{{16, 54}, "persisted_columns.cell_hazard_today_mask", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_dry_streak_days{{{16, 55}, "persisted_columns.cell_dry_streak_days", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_days_since_hazard{{{16, 56}, "persisted_columns.cell_days_since_hazard", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<uint8_t> _cell_previous_hazard_mask{{{16, 57}, "persisted_columns.cell_previous_hazard_mask", EconomyFieldEncoding::U8, 1}};
    EconomyOwnedColumn<uint8_t> _cell_weather_type{{{16, 58}, "persisted_columns.cell_weather_type", EconomyFieldEncoding::U8, 1}};
    EconomyOwnedColumn<uint8_t> _cell_cover{{{16, 59}, "persisted_columns.cell_cover", EconomyFieldEncoding::U8, 1}};
    std::vector<int32_t> _building_elevation_q16;
    std::vector<uint8_t> _building_terrain;
    std::vector<uint8_t> _building_landform;
    std::vector<uint8_t> _building_vegetation;
    std::vector<uint8_t> _building_is_water;
    std::vector<uint8_t> _building_has_river;
    std::vector<int32_t> _building_neighbors;
    // X12 derived geography columns. Rebuilt only when the territory hash or
    // canal topology hash changes; never persisted.
    std::vector<int32_t> _epoch_cell_geo_flags;
    std::vector<int32_t> _epoch_cell_waterway_component_size;
    uint64_t _geo_flags_territory_hash = 0;
    uint64_t _geo_flags_canal_hash = 0;
    std::atomic<uint64_t> _geo_flags_rebuilds{0};
    // X9-a derived family aggregates. Rebuilt only when the authoritative
    // branch columns change; a daily seal is not a content change.
    std::vector<int32_t> _epoch_cell_family_branch_count;
    std::vector<int64_t> _epoch_cell_max_branch_prestige_q16;
    std::vector<int32_t> _epoch_cell_family_asset_share_q16;
    uint64_t _family_cell_metric_signature = 0;
    std::vector<uint8_t> _family_cell_metric_changed_cells;
    std::atomic<uint64_t> _family_cell_metric_rebuilds{0};
    // X9-b derived country columns. Rebuilt in the same FAMILY_COMMIT pass as
    // the cell aggregates, then published to each country's anchor cell.
    std::vector<int32_t> _epoch_country_family_remote_branch_count;
    std::vector<int32_t> _epoch_country_families_with_at_least_3_branches;
    std::vector<int64_t> _epoch_country_oldest_family_founded_day;
    std::vector<int64_t> _epoch_country_family_founded_day_sum;
    std::vector<int32_t> _epoch_country_family_count;
    uint64_t _family_country_metric_signature = 0;
    std::vector<uint8_t> _family_country_metric_changed_countries;
    std::atomic<uint64_t> _family_country_metric_rebuilds{0};
    // X14 derived country columns. Copied from the last COMMITTED class
    // opinion snapshot at commit finalize; never persisted.
    std::vector<int64_t> _epoch_country_class_satisfaction_q16;
    std::vector<int64_t> _epoch_country_weighted_satisfaction_q16;
    std::vector<int64_t> _epoch_country_farmer_satisfaction_q16;
    std::vector<int64_t> _epoch_country_worker_satisfaction_q16;
    std::vector<int64_t> _class_opinion_override_population;
    std::vector<int32_t> _class_opinion_override_satisfaction_q16;
    std::vector<int64_t> _class_opinion_override_weighted;
    bool _class_opinion_source_override_enabled = false;
    // Test-only synthetic publication identity. The worker settles once per
    // committed day, so reusing the frozen source's identity would make every
    // controlled row update after the first one a no-op.
    uint64_t _class_opinion_override_revision = 0;
    int64_t _class_opinion_override_commit_day = -1;
    uint64_t _class_metric_source_revision = 0;
    uint64_t _class_metric_source_content_hash = 0;
    int64_t _class_metric_source_epoch_day = -1;
    std::atomic<uint64_t> _class_metric_rebuilds{0};
    // X10 derived country columns. The domain table is copied once from the
    // immutable Country catalog at configure; `_technology_domain_masks` holds
    // one mask per technology word per domain (the shipped catalog has >64
    // technologies). Counts are rebuilt only when the technology bitset content
    // changes, never on ordinary country state.
    std::vector<int32_t> _technology_domain_ids;
    std::vector<uint64_t> _technology_domain_masks;
    std::vector<int64_t> _epoch_country_completed_tech_count;
    std::vector<int64_t> _epoch_country_completed_tech_count_domain_0;
    std::vector<int64_t> _epoch_country_completed_tech_count_domain_1;
    std::vector<int64_t> _epoch_country_completed_tech_count_domain_2;
    std::vector<int64_t> _epoch_country_completed_tech_count_domain_3;
    // X13 residual: derived from the frozen climate counters and the country
    // territory CSR once per capture. Never persisted or hashed.
    std::vector<int32_t> _epoch_country_hazard_free_cell_share_q16;
    std::vector<uint64_t> _technology_metric_input_override;
    bool _technology_metric_input_override_enabled = false;
    uint64_t _technology_metric_source_hash = 0;
    std::atomic<uint64_t> _technology_metric_rebuilds{0};
    // X7-b frozen Country projection. Signal words are copied from the same
    // immutable Country commit as technologies; the three Economy counts are
    // derived from committed building/geography columns during epoch capture.
    std::vector<uint64_t> _epoch_country_research_signals;
    int32_t _epoch_country_research_signal_words = 0;
    std::vector<int32_t> _epoch_country_energy_cell_count;
    std::vector<int32_t> _epoch_country_abundant_mountain_forest_cell_count;
    std::vector<int32_t> _epoch_country_landform_signal_count;
    std::vector<int32_t> _epoch_country_weather_signal_count;
    std::vector<int32_t> _epoch_country_bio_signal_count;
    // X8 derived cell column. `_neighbor_distinct_goods_source_hash` is the
    // committed production shape (building groups, neighbour graph, and each
    // cell's dominant output) that can change the answer. A hash miss rebuilds
    // the column and advances the counter; an unchanged idle day does neither.
    std::vector<int32_t> _epoch_cell_neighbor_distinct_goods;
    uint64_t _neighbor_distinct_goods_source_hash = 0;
    std::atomic<uint64_t> _neighbor_distinct_goods_rebuilds{0};
    // A+Y N5/N9: unbound fallback for the live resource lanes. While a store is
    // bound these stay empty and the accessors alias OwnedState::resources.
    EconomyTrackedColumn<int64_t> _resource_snapshot{_resource_changes_local,
        {{3, 1}, "resource.stock", EconomyFieldEncoding::I64, 8}};
    std::vector<int64_t> _resource_remaining;
    // Per-epoch extract allowance for renewable resources. This is derived from
    // the frozen reserve, never serialized, and is shared by all local extractors.
    std::vector<int64_t> _resource_harvest_remaining;
    std::vector<int64_t> _resource_gen_base;
    std::vector<int64_t> _resource_gen_temp;
    std::vector<int64_t> _resource_gen_moisture;
    std::vector<int64_t> _resource_gen_self;
    std::vector<int64_t> _resource_decay_base;
    std::vector<int64_t> _resource_decay_temp;
    std::vector<int64_t> _resource_decay_moisture;
    std::vector<int32_t> _resource_decay_self_q16;
    std::vector<int64_t> _resource_ecology_capacity;
    std::vector<int32_t> _resource_ecology_growth_q16;
    std::vector<int32_t> _resource_temp_lo_q16;
    std::vector<int32_t> _resource_temp_hi_q16;
    std::vector<int32_t> _resource_climate_temp_opt_q16;
    std::vector<int32_t> _resource_climate_temp_tol_q16;
    std::vector<int32_t> _resource_climate_moisture_opt_q16;
    std::vector<int32_t> _resource_climate_moisture_tol_q16;
    std::vector<int32_t> _resource_runtime_fit_weight_q16;
    std::vector<int32_t> _resource_temperature_signal;
    std::vector<int32_t> _resource_moisture_signal;
    std::vector<int64_t> _resource_deltas;
    std::vector<uint32_t> _resource_lane_generation;
    // A restored resource stock is authoritative until the first post-restore
    // building-context capture has consumed the matching map snapshot.
    bool _resource_stock_restored_pending_capture = false;
    // Worker-owned reserves: after the first worker capture the main-thread
    // reserve/extra slots are only a display mirror. Their content at capture
    // time depends on how far the main thread ran ahead of the worker.
    std::vector<WorkerNaturalResource> _worker_natural_resources;
    bool _worker_resource_seeded = false;
    std::vector<float> _worker_resource_reserve;
    std::vector<float> _worker_resource_extra;
    std::vector<uint8_t> _worker_resource_extra_dirty;
    std::vector<int32_t> _worker_resource_last_day;
    std::vector<uint8_t> _worker_resource_was_live;
    std::vector<uint8_t> _worker_resource_cell_live;
    std::vector<uint8_t> _worker_resource_mirror_mark;
    std::vector<int32_t> _worker_resource_mirror_cells;
    std::vector<float> _worker_resource_regen_factors;
    bool advance_worker_resource_reserves(const RuntimeEconomyDayInput &input,
                                          std::string &error);
    void fold_worker_resource_deltas();
    void write_worker_resource_stock(size_t lane);
    void mark_worker_resource_mirror_cell(int32_t cell);
    std::vector<size_t> _resource_touched_lanes;
    std::vector<size_t> _last_published_resource_touched_lanes;
    uint32_t _resource_current_generation = 0;
    // Debug/recording visibility for the most recently published building
    // resource changes. It is derived epoch output, not save/hash authority.
    std::vector<int64_t> _last_published_resource_deltas;
    std::vector<std::string> _resource_ids;
    std::vector<std::string> _modifier_sector_ids;
    std::vector<std::string> _modifier_terrain_ids;
    std::vector<std::string> _modifier_landform_ids;
    std::vector<std::string> _resource_reserve_slots;
    std::vector<std::string> _resource_extra_slots;
    int64_t _building_context_day = -1;
    bool _resource_deltas_ready = false;
    EconomyTrackedScalar<int64_t> _environment_day{_metadata_changes, {{15, 10}, "metadata.environment_day", EconomyFieldEncoding::I64, 8}, -1};
    EconomyTrackedScalar<int64_t> _environment_hash{_metadata_changes, {{15, 11}, "metadata.environment_hash", EconomyFieldEncoding::I64, 8}, 0};
    std::vector<int32_t> _market_cell_offsets;
    std::vector<int32_t> _market_cells;
    EconomyTrackedRecords<Command> _pending_commands{{{14, 1}, "commands.pending_commands", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyTrackedRecords<Command> _epoch_commands{{{14, 2}, "commands.epoch_commands", EconomyFieldEncoding::CanonicalRecord, 1}};
    // Player commands submitted from the main thread while a worker owns this
    // runtime. Tracked command records and submit order may only be written
    // by the owning thread, so the worker folds these in at epoch start.
    struct WorkerCommandInbox {
        std::mutex mutex;
        std::vector<Command> commands;
    };
    std::unique_ptr<WorkerCommandInbox> _worker_command_inbox =
        std::make_unique<WorkerCommandInbox>();
    void enqueue_worker_command(const Command &command);
    void drain_worker_command_inbox();
    std::unordered_map<int64_t, EffectCommandResult> _effect_command_results;
    std::unordered_map<uint64_t, int64_t> _effect_idempotency_requests;
    int64_t _next_effect_request_id = 1;
    EconomyTrackedRecords<StructuralCommand> _structural_commands{{{14, 3}, "commands.structural_commands", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<CellSummary> _committed_cells;
    std::vector<CellSummary> _staging_cells;
    std::vector<int32_t> _staging_touched_cells;
    // Per-task landing buffers for the market worker fan-out. Cells are
    // partitioned one-per-market, so summary/generation writes never alias
    // across tasks, but the touched list is a shared vector and must not be
    // grown concurrently. Merged back into _staging_touched_cells after join.
    std::vector<std::vector<int32_t>> _staging_touched_task_scratch;
    std::vector<uint32_t> _staging_cell_generation;
    uint32_t _staging_current_generation = 0;
    std::vector<int32_t> _structural_touched_cells;
    // BEGIN army personnel lane state (contract §1.1).
    // One row per army that currently holds embarked people. Authoritative,
    // persisted in PKEC schema 59 (SAVE_SECTION_ARMY_PERSONNEL); the handle ->
    // row index inside the store is derived and never saved.
    ArmyPersonnelStore _army_personnel;
    // END army personnel lane state
    std::vector<int32_t> _population_changed_cells;
    // Number of _structural_touched_cells entries already covered by this
    // epoch's structural_commit employment reconcile. building_commit.finalize
    // re-reconciles only the tail appended after that point (investment
    // profession transitions), instead of double-reconciling the full set.
    int64_t _structural_reconciled_upto = 0;
    // Cells whose cohorts were moved at the idle boundary between epochs
    // (colonization launch/landing/return). Epoch begin clears the touched
    // list, so these are handed to the next structural employment reconcile.
    std::vector<int32_t> _deferred_population_reconcile_cells;
    std::vector<int64_t> _prosperity_thresholds;
    std::vector<std::string> _prosperity_ids;
    std::vector<std::string> _prosperity_names;
    EconomyKeyedVariableRecords<std::string> _settlement_prefix_ids{{{26, 2}, "name_catalog.settlement_prefix_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<std::string> _settlement_prefix_text;
    std::vector<int32_t> _settlement_prefix_weights;
    std::vector<std::string> _settlement_prefix_alias_ids;
    std::vector<std::string> _settlement_prefix_alias_targets;
    EconomyKeyedVariableRecords<std::string> _settlement_root_ids{{{26, 3}, "name_catalog.settlement_root_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<std::string> _settlement_root_text;
    std::vector<int32_t> _settlement_root_weights;
    std::vector<std::string> _settlement_root_alias_ids;
    std::vector<std::string> _settlement_root_alias_targets;
    EconomyKeyedVariableRecords<std::string> _settlement_suffix_ids{{{26, 4}, "name_catalog.settlement_suffix_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<std::string> _settlement_suffix_text;
    std::vector<int32_t> _settlement_suffix_weights;
    std::vector<std::string> _settlement_suffix_alias_ids;
    std::vector<std::string> _settlement_suffix_alias_targets;
    EconomyOwnedRecordValue<std::string> _settlement_name_pack_id{
        {{26, 5}, "name_catalog.pack_id", EconomyFieldEncoding::CanonicalRecord, 1}, "default_zh"};
    EconomyKeyedVariableRecords<std::string> _settlement_full_name_ids{{{26, 1}, "name_catalog.settlement_full_name_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<std::string> _settlement_full_name_text;
    std::vector<int32_t> _settlement_full_name_weights;
    std::vector<std::string> _settlement_full_name_alias_ids;
    std::vector<std::string> _settlement_full_name_alias_targets;
    int32_t _settlement_full_name_share_q16 = 32768;
    int32_t _settlement_named_tier = 2;
    int32_t _settlement_downgrade_bp = 9000;
    EconomyTrackedScalar<int64_t> _prosperity_profile_hash{_metadata_changes, {{15, 27}, "metadata.prosperity_profile_hash", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _settlement_catalog_hash = 0;
    int64_t _prosperity_changed_cells = 0;
    int64_t _prosperity_promotions = 0;
    int64_t _prosperity_demotions = 0;
    int64_t _settlement_names_assigned = 0;
    int64_t _settlement_names_released = 0;
    int64_t _settlement_name_collision_probes = 0;
    double _prosperity_update_ms = 0.0;
    int64_t _structural_funds_to_treasury = 0;

    std::vector<std::string> _building_type_ids;
	std::vector<int32_t> _building_kinds;
    std::vector<int32_t> _building_economic_sectors;
	std::vector<std::string> _building_upgrade_family_ids;
	std::vector<int32_t> _building_upgrade_family_indices;
	std::vector<int32_t> _building_upgrade_tiers;
	std::vector<int32_t> _building_technology_tag_offsets;
	std::vector<std::string> _building_technology_tags;
	std::vector<int32_t> _building_required_technology_tag_offsets;
	std::vector<std::string> _building_required_technology_tags;
    std::vector<uint32_t> _building_technology_practice_masks;
    std::array<int32_t, 28> _breakthrough_signal_ids{};
    int32_t _bio_maize_signal_id = -1;
    std::array<int32_t, 8> _metal_resource_signal_ids{
        -1, -1, -1, -1, -1, -1, -1, -1};
    std::vector<uint64_t> _research_signal_prefix_masks;
    int32_t _research_signal_prefix_words = 0;
    int32_t _abundant_mountain_landform_id = -1;
    int32_t _abundant_forest_terrain_id = -1;
    bool _catalog_geography_lookup_warning_emitted = false;
    std::vector<int32_t> _building_technology_offsets;
    std::vector<int32_t> _building_required_technologies;
    std::vector<int32_t> _building_all_technology_offsets;
    std::vector<int32_t> _building_all_required_technologies;
    // Material/resource dependency gates compiled from Good/Resource technology
    // tags. Operating availability requires every input/output/resource group
    // to have at least one completed technology tag. Construction-good groups
    // (kind 1) gate new builds via good_market_available / material planning,
    // not already-standing lots.
    std::vector<int32_t> _building_dependency_branch_offsets;
    std::vector<int32_t> _building_dependency_branch_technologies;
    std::vector<int32_t> _building_dependency_branch_technology_offsets;
    std::vector<int32_t> _building_dependency_branch_group_offsets;
    std::vector<uint8_t> _building_dependency_kinds;
    std::vector<int32_t> _building_dependency_ids;
    std::vector<int32_t> _building_dependency_tag_offsets;
    std::vector<int32_t> _building_dependency_tags;
    std::vector<std::string> _technology_ids;
    int32_t _water_tech_river = -1;
    int32_t _water_tech_shallow = -1;
    int32_t _water_tech_far = -1;
    int32_t _water_tech_deep = -1;
    std::vector<int32_t> _development_metric_signal_indices;
    std::vector<int32_t> _development_metric_era_indices;
    std::vector<int32_t> _development_metric_types;
    std::vector<int32_t> _development_metric_subject_kinds;
    std::vector<int32_t> _development_metric_subject_offsets;
    std::vector<int32_t> _development_metric_subject_indices;
    std::vector<int64_t> _development_metric_qualifier_thresholds;
    std::vector<int32_t> _development_metric_duration_days;
    // Per country x metric publication state: below-qualifier samples only feed
    // the progress display, so they are throttled; qualified samples and the
    // drop below the qualifier are always published.
    static constexpr int64_t DEVELOPMENT_IDLE_FACT_INTERVAL_DAYS = 30;
    std::vector<uint64_t> _development_fact_country_handles;
    std::vector<int64_t> _development_fact_last_day;
    std::vector<uint8_t> _development_fact_qualified;
    int32_t _technology_words = 0;
    NativeCountryRuntime *_country_runtime = nullptr;
    EconomyHostPort *_simulation_host = nullptr;
    std::array<int64_t, ANNUAL_METRIC_COUNT> _annual_epoch_events{};
    std::vector<AnnualBreakdown> _annual_epoch_industries;
    EconomyCsvRecorder *_csv_recorder = nullptr; // facade-owned; destroyed after worker joins
    bool _sync_writes_forbidden = false;
    uint32_t _d7_operation_gate_mask = RUNTIME_ECONOMY_D7_FISCAL_GATE_MASK;
    ModifierRuntime *_modifier_runtime = nullptr;
    int32_t _family_scoped_output_stat_id = -1;
    int32_t _family_target_min_branches_override_for_test = 0;
    EffectRuntime *_effect_runtime = nullptr;
    EffectInstanceForwarder *_effect_forwarder = nullptr;
    TriggerRuntime *_trigger_runtime = nullptr;
    std::vector<int32_t> _epoch_cell_country;
    // Country territory CSR, rebuilt from _epoch_cell_country by
    // rebuild_country_territory_index() at the same moment the ownership column
    // is taken. Derived: never persisted, never hashed.
    //
    // Why a copy on this side instead of reading the country pod's own CSR: the
    // pod rebuilds on its own schedule, and a target set that disagrees with the
    // ownership column the economy already trusts is worse than no target set at
    // all. Building from _epoch_cell_country makes "anchor cell" and "territory"
    // true statements about the same bytes by construction.
    //
    // When _epoch_country_cell_offsets is empty the consumers fall back to a
    // linear scan of _epoch_cell_country, so hand-built fixtures and the pre-index
    // path keep the old semantics.
    std::vector<int32_t> _epoch_country_cell_offsets;
    std::vector<int32_t> _epoch_country_cells;
    // Tag predicate table, copied from EffectRuntime at attach time.
    TargetTagTable _target_tags;
    // Per-epoch tag tables (tag bitset + X7 per-country counts), published as ONE
    // immutable snapshot.
    //
    // R-3: these used to be plain `std::vector` members. `capture_country_epoch`
    // cleared and refilled them on the owning thread while
    // `step_ideology_instance_refresh` -> `reconcile` iterated them on the main
    // thread without holding anything, so a reader could walk a buffer that had just
    // been freed. "Build it eagerly at commit" (R-3 first pass) did not fix that: it
    // still wrote the same vectors the reader was walking.
    //
    // Now the writer builds a `TagSnapshot` and `atomic_store`s it; every reader does
    // ONE `atomic_load` into a local shared_ptr and uses that for the whole read.
    // Swapping is therefore safe against a concurrent read by construction. Derived,
    // never persisted, never hashed.
    std::shared_ptr<const TagSnapshot> _tag_snapshot;
    // Monotone publish counter, so a snapshot can say which epoch it describes.
    //
    // R-3b: SINGLE WRITER. Assigned only inside `rebuild_epoch_tag_snapshot`, which
    // runs either from `capture_country_epoch` (the economy commit thread) or from
    // `set_target_tags` (config time, or a caller holding the boundary lock -- see
    // the assertion there). Two concurrent writers would not corrupt the swapped
    // pointer (that store is atomic) but they WOULD race on this counter and can
    // publish two snapshots with the same generation.
    uint64_t _published_tag_snapshot_generation = 0;
    // R-3b: evidence that an epoch which nobody reads costs nothing. One increment
    // per snapshot actually built, one per epoch where both halves were skipped.
    std::atomic<uint64_t> _tag_snapshot_builds{0};
    std::atomic<uint64_t> _tag_snapshot_skips{0};
    // R-3b: "only one builder at a time" assertion (see rebuild_epoch_tag_snapshot).
    // Atomic so a second caller can see it without holding a lock; `exchange(false)`
    // in the guard's destructor is what makes the early-outs below leak-free.
    std::atomic<bool> _tag_snapshot_building{false};
    // `set_target_tags` calls that arrived while a rebuild was in flight. Must stay 0:
    // it is the only observable form of "someone called outside the config phase
    // without holding the boundary lock".
    std::atomic<uint64_t> _tag_snapshot_concurrent_writes{0};
    // Readers that arrived before the first publish. Must be 0 after the first
    // commit; exported as `tag_snapshot_miss_count`.
    mutable std::atomic<int64_t> _last_tag_snapshot_miss_count{0};
    // M4: see `last_tag_snapshot_build_ms`. Relaxed is enough -- these are
    // diagnostics, never control flow.
    mutable std::atomic<double> _last_tag_snapshot_build_ms{0.0};
    mutable std::atomic<int64_t> _tag_snapshot_build_count{0};
    // How many tags the table DECLARES versus how many have rows and can match. The
    // gap is pure waste in the `cells x tags` sweep.
    mutable std::atomic<int64_t> _tag_declared_tag_count{0};
    mutable std::atomic<int64_t> _tag_active_tag_count{0};
    // How many tag ids the CONSUMER set named. 0 means "all tags" (the conservative
    // fallback), so this is the number that explains why the sweep did or did not
    // narrow.
    mutable std::atomic<int64_t> _tag_consumed_tag_count{0};
    int64_t tag_declared_tag_count() const {
        return _tag_declared_tag_count.load(std::memory_order_relaxed);
    }
    int64_t tag_active_tag_count() const {
        return _tag_active_tag_count.load(std::memory_order_relaxed);
    }
    int64_t tag_consumed_tag_count() const {
        return _tag_consumed_tag_count.load(std::memory_order_relaxed);
    }
    // R-3b: how many `tag_snapshot()` loads happened, so "one load per scan" is a
    // measured property rather than a code-review claim.
    mutable std::atomic<int64_t> _tag_snapshot_loads{0};
    // ── Effect input revision (P1-A) ────────────────────────────────────────
    // A monotone count of "an input an ideology program reads actually changed".
    // Deliberately a CONTENT digest, not a clock: bumping once per economy epoch
    // would make every managed card refresh every day, which is exactly the
    // no-op churn this revision exists to prevent (see 04-review-verification
    // §3.1). All fields below are derived and never persisted.
    mutable std::atomic<uint64_t> _effect_input_revision{0};
    uint64_t _published_effect_input_digest = 0;
    // Declared by the ideology catalog: the union of the per-cell metrics its
    // managed programs read, and whether any of them selects targets by tag.
    // Both empty/false means "no managed card reads economy input", and the
    // digest then costs nothing at all.
    // P3-B, second half: the consumer set moves behind one immutable object.
    // Previously `metric_mask`, `tags_needed` and the "force republish" flag were
    // plain fields written by the catalog configurer on the main thread and read
    // by the digest on the economy thread -- the same data race the revisions had.
    struct EffectInputConsumers {
        MetricMask metric_mask;
        bool tags_needed = false;
        // WHICH tags are consumed, as 0-based indices.
        //
        // `tags_needed` alone forces the rebuild to evaluate every declared tag: a
        // world whose cards use one tag still paid `cells x 296` matches, measured at
        // 35.66 ms for 6400 cells (M4-22). With the set, the sweep narrows to the tags
        // that can actually be read.
        //
        // Empty + `tags_needed == false` means "no tags". Empty + true is a caller that
        // declared the need but not the ids, and is treated as "all tags" so a
        // conservative publisher cannot silently narrow the target set.
        std::vector<int32_t> tag_ids;
        bool families_needed = false;
        // Bumped on every swap so the digest can tell "the consumer set changed"
        // without the writer touching the digest's own published state.
        uint64_t generation = 0;
        std::array<std::vector<int64_t>, FAMILY_METRIC_COUNT> thresholds;
    };
    std::shared_ptr<const EffectInputConsumers> _effect_input_consumers;
    uint64_t _published_consumers_generation = 0;
    // Published revision snapshot (see EffectInputSnapshot at namespace scope).
    std::shared_ptr<const EffectInputSnapshot> _effect_input_snapshot;
    // Per-metric revisions (review §3, second half). The global revision stays a
    // union -- "something moved" -- so the existing refresh/should_run gates keep
    // their meaning; these let a card's signature depend only on the metrics it
    // actually reads, instead of re-signing every economy-input card whenever any
    // metric moves.
    // Test hook: a metric value forced for every cell. The gate's job is to react
    // to *threshold crossings*, and the only way to test that deterministically is
    // to move one metric by a chosen amount -- the simulation cannot be steered
    // that precisely. Unset means "use the sampled value".
    // The override is a test hook, but it was still a main-thread write into the
    // digest thread's state. Same treatment as everything else on this path: one
    // immutable object, swapped atomically.
    struct EffectMetricOverrideSet {
        std::array<int64_t, FAMILY_METRIC_COUNT> values{};
        std::array<uint8_t, FAMILY_METRIC_COUNT> set{};
        uint64_t generation = 0;
    };
    std::shared_ptr<const EffectMetricOverrideSet> _effect_metric_override_snapshot;
    uint64_t _published_override_generation = 0;
    // Test-only tag overrides, consulted while sampling a cell's effect metrics.
    // Unlike the metric override, these are scoped to one cell: a card's tagged
    // fixture cell and an untagged control cell can coexist in one world.
    struct CellTagOverride {
        uint8_t force_true = 0;
        uint8_t force_false = 0;
    };
    struct CellTagOverrideSet {
        std::unordered_map<int32_t, std::vector<CellTagOverride>> cells;
        uint64_t generation = 0;
    };
    std::shared_ptr<const CellTagOverrideSet> _cell_tag_override_snapshot;
    uint64_t _tag_override_published_generation = 0;
    uint64_t _tag_snapshot_override_generation = 0;
    // Last published digests, used only by the digest pass itself (single writer,
    // single thread) to decide what moved.
    std::array<uint64_t, FAMILY_METRIC_COUNT> _effect_metric_published{};
    uint64_t _effect_territory_published = 0;
    uint64_t _effect_tag_published = 0;
    uint64_t _effect_family_published = 0;

    uint64_t _effect_input_digest_computations = 0;
    double _effect_input_digest_ms = 0.0;
    // X7 second half: distinct specialized goods per country. One small bitset
    // per country while building, then collapsed to a count. Derived from a
    // per-cell sample of (dominant output good, its share), so it carries its
    // own valid flag and is dropped with the rest of the epoch state.
    //
    // Nested vectors instead of one flat country x good matrix: the good id
    // space is data-driven (data/goods), and a flat matrix would need a good
    // count the runtime does not hold. Growing each country's bitset on demand
    // keeps this exact without inventing a cap.
    // X7b (metric 67) now lives inside the published `TagSnapshot`; readers go
    // through `tag_snapshot()`. The `mutable` lazy-build trio it used to have is
    // gone with R-3.
    std::vector<uint8_t> _epoch_cell_visible;
    int32_t _epoch_player_country_slot = -1;
    bool _epoch_trade_vision_gated = false;
    bool _trade_visibility_manual = false;
    std::vector<uint64_t> _epoch_country_technologies;
    EconomyOwnedColumn<uint64_t> _epoch_country_handles{{{16, 18}, "native_columns.epoch_country_handles", EconomyFieldEncoding::U64, 8}};
    std::vector<uint32_t> _epoch_country_political_regime_capabilities;
    // Catalog-resolved tax stat ids and the per-epoch effective integer rates.
    // Only configure/capture touches ModifierRuntime; workers read these dense arrays.
    std::vector<int32_t> _income_tax_stat_ids;
    std::vector<int32_t> _consumption_tax_stat_ids;
    std::vector<int32_t> _business_tax_stat_ids;
    std::vector<int32_t> _import_tax_stat_ids;
    std::vector<int32_t> _export_tax_stat_ids;
    std::vector<int32_t> _country_family_output_stat_ids;
    std::vector<int32_t> _country_good_output_stat_ids;
    std::vector<int32_t> _country_good_input_stat_ids;
    std::vector<int32_t> _country_good_consumption_stat_ids;
    std::vector<int32_t> _country_resource_use_stat_ids;
    std::vector<int32_t> _country_resource_generation_stat_ids;
    // X16: indexed by `profession_id`; -1 means the stat is absent.
    std::vector<int32_t> _profession_tax_tolerance_stat_ids;
    std::vector<int32_t> _profession_satisfaction_bp_stat_ids;
    std::vector<int32_t> _country_terrain_sector_output_stat_ids;
    std::vector<int32_t> _country_landform_sector_output_stat_ids;
    std::vector<int32_t> _country_building_output_stat_ids;
    int32_t _country_production_input_stat_id = -1;
    int32_t _country_household_consumption_stat_id = -1;
    int32_t _country_population_death_stat_id = -1;
    int32_t _country_resource_use_stat_id = -1;
    std::array<int32_t, 4> _country_climate_loss_stat_ids{-1, -1, -1, -1};
    // Dense [production climate profile][hazard] stat IDs, resolved at configure.
    std::vector<int32_t> _country_climate_profile_loss_stat_ids;
    int32_t _city_birth_stat_id = -1;
    int32_t _city_consumption_stat_id = -1;
    std::vector<int32_t> _city_need_consumption_stat_ids;
    std::vector<int32_t> _city_good_consumption_stat_ids;
    std::vector<int32_t> _city_good_output_stat_ids;
    std::vector<int32_t> _city_building_output_stat_ids;
    std::vector<int32_t> _epoch_income_tax_rates;
    std::vector<int32_t> _epoch_consumption_tax_rates;
    std::vector<int32_t> _epoch_business_tax_rates;
    std::vector<int32_t> _epoch_import_tax_rates;
    std::vector<int32_t> _epoch_export_tax_rates;
    std::vector<int32_t> _epoch_income_tax_modes;
    std::vector<int32_t> _epoch_consumption_tax_modes;
    std::vector<int32_t> _epoch_business_tax_modes;
    std::vector<int32_t> _epoch_import_tax_modes;
    std::vector<int32_t> _epoch_export_tax_modes;
    static constexpr size_t CELL_TAX_KIND_COUNT = 5;
    struct CompiledCellTaxOverride {
        int32_t item = -1;
        int32_t rate = 0;
        int32_t mode = 0; // TAX_MODE_PERCENT_BP
    };
    struct CompiledCellTaxPolicy {
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            default_row_ids{-1, -1, -1, -1, -1};
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            override_begin{};
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            override_end{};
        uint8_t active_mask = 0;
        uint8_t negative_mask = 0;
        uint8_t absolute_mask = 0;
    };
    struct CompiledCellTaxDefaultRow {
        int32_t kind = -1;
        int32_t country = -1;
        int32_t base_rate = 0;
        int32_t base_mode = 0; // TAX_MODE_PERCENT_BP
        int32_t offset = 0;
        int32_t count = 0;
    };
    std::vector<uint32_t> _epoch_cell_compiled_tax_policy;
    std::vector<uint8_t> _epoch_cell_active_tax_mask;
    // Per-cell tax mode masks keep fiscal post-processing data-oriented.  The
    // active mask answers whether a lane has any non-zero rate; these masks
    // answer whether the lane can actually enter the negative-tax or absolute
    // settlement paths, so ordinary positive percentage tax does not trigger
    // a full cohort/building scan.
    std::vector<uint8_t> _epoch_cell_negative_tax_mask;
    std::vector<uint8_t> _epoch_cell_absolute_tax_mask;
    std::vector<CompiledCellTaxPolicy> _epoch_compiled_cell_tax_policies;
    std::vector<CompiledCellTaxOverride> _epoch_compiled_cell_tax_overrides;
    std::vector<CompiledCellTaxDefaultRow> _epoch_compiled_cell_tax_default_rows;
    std::vector<int32_t> _epoch_compiled_cell_tax_default_rates;
    std::vector<int32_t> _epoch_compiled_cell_tax_default_modes;
    int64_t _epoch_cell_tax_cache_bytes = 0;
    double _epoch_cell_tax_compile_ms = 0.0;
    bool _epoch_has_cell_tax_policies = false;
    uint64_t _epoch_tax_policy_version = 0;
    uint8_t _epoch_active_tax_mask = 0;
    uint8_t _epoch_negative_tax_mask = 0;
    uint8_t _epoch_absolute_tax_mask = 0;
    static constexpr int32_t ACTIVE_TAX_KIND_COUNT = 3;
    EconomyOwnedColumn<int64_t> _fiscal_previous_requests{{{16, 26}, "native_columns.fiscal_previous_requests", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<uint64_t> _fiscal_previous_country_handles{{{16, 25}, "native_columns.fiscal_previous_country_handles", EconomyFieldEncoding::U64, 8}};
    // Epoch-transient reservation weights. Income lanes are seeded from the
    // frozen minimum-living subsidy floor for current cohorts plus a bounded
    // prospective floor for available owner/employee professions, so a newly
    // enabled negative income rate can attract a transition without waiting
    // for one historical batch. Business lanes get the matching prospective
    // floor on investment-review cells only, bounded by one building of the
    // single most valuable subsidised type.
    std::vector<int64_t> _fiscal_reservation_requests;
    int64_t _fiscal_business_prospective_lanes = 0;
    int64_t _fiscal_business_prospective_request = 0;
    std::vector<int64_t> _fiscal_current_requests;
    std::vector<int64_t> _fiscal_budgets;
    std::vector<int64_t> _fiscal_remaining;
    // Frozen promise ratio shared by forecasts and settlement. This prevents
    // iteration order from changing which rational actor receives a subsidy.
    std::vector<int32_t> _fiscal_fulfillment_q16;
    std::vector<int64_t> _fiscal_epoch_bases;
    std::vector<int64_t> _fiscal_epoch_assessed;
    std::vector<int64_t> _fiscal_epoch_collected;
    std::vector<int64_t> _fiscal_epoch_paid;
    EconomyOwnedColumn<int64_t> _fiscal_escrow_by_country{{{16, 23}, "native_columns.fiscal_escrow_by_country", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedJournal<uint64_t, AssetPeerJournalRecord> _asset_peer_journal{
        {{13, 1}, "fiscal.peer_journal", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyOwnedColumn<int64_t> _fiscal_last_bases{{{16, 45}, "persisted_columns.fiscal_last_bases", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_assessed{{{16, 44}, "persisted_columns.fiscal_last_assessed", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_collected{{{16, 46}, "persisted_columns.fiscal_last_collected", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_requests{{{16, 48}, "persisted_columns.fiscal_last_requests", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_reserved{{{16, 49}, "persisted_columns.fiscal_last_reserved", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_paid{{{16, 47}, "persisted_columns.fiscal_last_paid", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_unmet{{{16, 50}, "persisted_columns.fiscal_last_unmet", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_events{{{16, 24}, "native_columns.fiscal_last_events", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_cumulative_bases{{{16, 19}, "native_columns.fiscal_cumulative_bases", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_cumulative_collected{{{16, 20}, "native_columns.fiscal_cumulative_collected", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_cumulative_requests{{{16, 22}, "native_columns.fiscal_cumulative_requests", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_cumulative_paid{{{16, 21}, "native_columns.fiscal_cumulative_paid", EconomyFieldEncoding::I64, 8}};
    // Non-tax treasury outflows. Every one of these pays treasury cash OUT to a
    // merchant (or into an expedition) without being a tax kind, so none of them
    // could ever appear on the five-lane fiscal grid. They share one
    // country x kind lane instead, published beside the tax lanes so 国库支出
    // reconciles with the treasury the player actually owns.
    enum NonTaxOutflow : int32_t {
        NON_TAX_RESEARCH_PURCHASE = 0,
        NON_TAX_EXPEDITION_PROCUREMENT = 1,
        NON_TAX_CONSTRUCTION = 2,
        NON_TAX_CANAL = 3,
        // Era advancement procurement (market -> treasury). Transient lane:
        // PKEC schema 58 persists only the first NON_TAX_PERSISTED_KIND_COUNT
        // kinds, so this slot restores as zero.
        NON_TAX_ERA_PROCUREMENT = 4,
        NON_TAX_KIND_COUNT = 5,
        NON_TAX_PERSISTED_KIND_COUNT = 4,
    };
    EconomyOwnedColumn<int64_t> _fiscal_last_non_tax_outflow{{{16, 60}, "persisted_columns.fiscal_last_non_tax_outflow", EconomyFieldEncoding::I64, 8}};
    // Outflows booked since the last published batch, keyed by generation-safe
    // country handle rather than by epoch country index: family expedition
    // procurement settles at the idle day boundary, when the country set may
    // already have changed. commit_fiscal drains this buffer into the batch.
    struct PendingNonTaxOutflow {
        uint64_t country_handle = 0;
        int64_t cash[NON_TAX_KIND_COUNT] = {0, 0, 0, 0, 0};
    };
    std::vector<PendingNonTaxOutflow> _pending_non_tax_outflow;
    FiscalReservationContinuation _fiscal_reservation_continuation;
    FiscalSettlementContinuation _fiscal_settlement_continuation;
    // Tariffs stay on a sparse cell x {import, export} lane separate from the
    // domestic cell x 3 fiscal arrays. The dense generation-stamped lookup is
    // transient metadata; monetary columns exist only for endpoint lanes
    // touched in the current epoch.
    std::vector<int32_t> _tariff_epoch_cells;
    std::vector<uint8_t> _tariff_epoch_kinds;
    std::vector<int64_t> _tariff_epoch_bases;
    std::vector<int64_t> _tariff_epoch_assessed;
    std::vector<int64_t> _tariff_epoch_collected;
    std::vector<int64_t> _tariff_epoch_requests;
    std::vector<int64_t> _tariff_epoch_reserved;
    std::vector<int64_t> _tariff_epoch_paid;
    std::vector<int64_t> _tariff_epoch_events;
    std::vector<int32_t> _tariff_lane_index;
    std::vector<uint32_t> _tariff_lane_stamp;
    uint32_t _tariff_lane_generation = 0;
    // Tariff subsidies share the country escrow with domestic subsidies. The
    // country vectors are the authoritative reservation budget consumed by
    // dispatch; cell lanes remain the sparse reporting surface.
    std::vector<int64_t> _tariff_country_requests;
    std::vector<int64_t> _tariff_country_budgets;
    std::vector<int64_t> _tariff_country_remaining;
    // Per-slot derived epoch scratch; intentionally excluded from save/hash.
    std::vector<int64_t> _income_taxable_base_by_slot;
    std::vector<int64_t> _income_subsidy_floor_by_slot;
    std::vector<int32_t> _epoch_country_output_factor_q16;
    std::vector<int32_t> _epoch_country_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_research_output_factor_q16;
    std::vector<int32_t> _epoch_country_family_output_factor_q16;
    std::vector<int32_t> _epoch_country_good_output_factor_q16;
    std::vector<int32_t> _epoch_country_good_input_factor_q16;
    std::vector<int32_t> _epoch_country_good_consumption_factor_q16;
    std::vector<int32_t> _epoch_country_resource_use_factor_q16;
    std::vector<int32_t> _epoch_country_resource_generation_factor_q16;
    // X16 frozen per (country slot, profession id), stride = profession count.
    //
    // Frozen once per epoch like every other country modifier read: the satisfaction
    // loop runs per cell per cohort, and resolving a modifier stat there would both
    // cost a lookup per cohort and let the value change mid-epoch (two cohorts in the
    // same country could then see different tolerances). Q16 factor and basis points,
    // clamped to [0.5, 3.0] and [-2500, 2500] respectively.
    std::vector<int32_t> _epoch_country_profession_tax_tolerance_q16;
    std::vector<int32_t> _epoch_country_profession_satisfaction_bp;
    // R-4 metric 69: per-country treasury reserve ratio, in percentage points.
    // v0 denominator is a 365-day extrapolation of the live income EMA (no new save
    // state); the true rolling-year accumulator is deferred to M4 (09 §8).
    std::vector<int32_t> _epoch_country_reserve_pct;
    std::vector<int32_t> _epoch_country_terrain_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_landform_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_building_output_factor_q16;
    std::vector<int32_t> _epoch_country_production_input_factor_q16;
    std::vector<int32_t> _epoch_country_household_consumption_factor_q16;
    std::vector<int32_t> _epoch_country_death_factor_q16;
    std::vector<int32_t> _epoch_country_resource_global_use_factor_q16;
    std::vector<int32_t> _epoch_country_climate_loss_factor_q16;
    // Dense [country][production climate profile][hazard] Q16 loss factors.
    std::vector<int32_t> _epoch_country_climate_profile_loss_factor_q16;
    std::vector<int32_t> _epoch_country_trade_capacity_factor_q16;
    std::vector<int32_t> _epoch_country_trade_speed_factor_q16;
    std::vector<uint8_t> _epoch_country_water_capability;
    std::vector<int32_t> _epoch_country_construction_cost_factor_q16;
    std::vector<int32_t> _epoch_country_construction_time_factor_q16;
    std::vector<int32_t> _epoch_cell_birth_factor_q16;
    std::vector<int32_t> _epoch_cell_need_consumption_factor_q16;
    std::vector<int32_t> _epoch_cell_good_consumption_factor_q16;
    std::vector<int32_t> _epoch_cell_rain_event_threshold_q16;
    std::vector<int32_t> _epoch_cell_cold_capacity_factor_q16;
    std::vector<int32_t> _epoch_cell_sector_output_factor_q16;
    std::vector<int32_t> _family_policy_stamped_cells;
    // The city factor tables are pure functions of the city stat buckets in the
    // ECONOMY modifier store, so they survive across epochs and are rebuilt only
    // when those buckets (or the catalog shape behind the tables) change. The
    // cached shared row is what every cell without a group bucket holds, so a
    // rebuild only has to repaint the cells listed in _city_factor_dirty_cells.
    uint64_t _epoch_city_factor_stat_version = 0;
    bool _epoch_city_factor_valid = false;
    int32_t _city_factor_shared_birth_q16 = Q16_ONE;
    std::vector<int32_t> _city_factor_shared_needs_q16;
    std::vector<int32_t> _city_factor_shared_goods_q16;
    std::vector<int32_t> _city_factor_dirty_cells;
    std::vector<uint64_t> _city_factor_group_cells_scratch;
    // Resume cursor for `refresh_city_modifier_factors` (plan 14.3 sharding).
    // < 0 means "no shard in flight": the next call repaints the shared row and
    // re-collects the scope list. >= 0 is the next index into
    // `_city_factor_group_cells_scratch`.
    // Cells processed per `refresh_city_modifier_factors` slice. M1-6 measured
    // ~6.0 us per covered cell at B7 scale, so 64 cells ~= 0.38 ms, leaving
    // headroom inside the plan §14.3 1 ms slice budget for the surrounding
    // epoch-open work. A fixed count beats a wall-clock check here because it is
    // deterministic and therefore assertable in a test (plan §14.4).
    static constexpr int32_t CITY_FACTOR_SHARD_CELLS = 64;
    int32_t _city_factor_shard_cursor = -1;
    // The stat version the in-flight shard was built against. A resume under a
    // different version restarts instead of finishing a stale work set.
    uint64_t _city_factor_shard_version = 0;
    // Resume cursor for `refresh_city_output_modifier_factors`, independent of
    // the city-factor cursor so neither reader blocks the other.
    int32_t _city_output_shard_cursor = -1;
    uint64_t _city_output_shard_version = 0;
    // Intermediate collector for the sharded output reader. The per-cell query
    // loop can stop between cells, but the sort + CSR rebuild that consumes its
    // output cannot, so the partial result has to survive across slices. Empty
    // when no shard is in flight.
    struct CityOutputOverrideRow {
        int32_t cell = -1;
        int32_t good = -1;
        int32_t factor_q16 = Q16_ONE;
    };
    std::vector<CityOutputOverrideRow> _city_output_shard_partial;
    // Work-set size of the LAST pass that actually collected one. Kept separate
    // from `_city_factor_group_cells_scratch.size()` because a pass that
    // short-circuits on the version gate never re-collects, so reading the
    // scratch afterwards reports a stale (or empty) number -- which is exactly
    // what made a shard test read `work=0` while 255 cells had been painted.
    int64_t _city_factor_work_cells = 0;
    // Cells ACTUALLY processed by the most recent pass, incremented INSIDE the
    // cell loop. `_city_factor_work_cells` above only records what the last
    // collect produced, so on a day where the version gate short-circuits it
    // still reports the previous pass's size -- and a reader that skipped the
    // work set becomes indistinguishable from one that finished it in
    // microseconds. That exact confusion produced a "2000 cells in 0.003 ms"
    // reading (M2-10) which is physically impossible.
    int64_t _city_factor_cells_processed = 0;
    // Size of the work set collected by the CURRENT pass, distinct from
    // `_city_factor_work_cells` which persists across passes. M2-11 reasoned that
    // a `processed=16` reading implied `total=16`; this field makes that
    // verifiable instead of inferred.
    int64_t _city_factor_collected_cells = 0;
    // Cumulative cost of the WHOLE city-factor build across every shard of the
    // current epoch, plus how many shard calls it took.
    //
    // `_epoch_begin_city_factor_ms` only measures ONE call (`economy_runtime.cpp:
    // 5542`), and a full build is spread over `work_cells / CITY_FACTOR_SHARD_CELLS`
    // calls, so that field reports the LAST shard -- typically the small remainder.
    // A 2000-cell work set therefore read as "16 cells, 0.002 ms" and looked
    // thousands of times faster than it is (M2-11).
    //
    // These two fields are the number §14.3 actually needs: total time and total
    // work for the whole materialisation, not the tail of it.
    double _city_factor_epoch_ms = 0.0;
    int64_t _city_factor_epoch_slices = 0;
    int64_t _city_factor_epoch_cells = 0;
    bool _city_factor_epoch_in_progress = false;
    std::vector<int32_t> _city_factor_stat_ids_scratch;
    // Exact city-good production factors use one shared global row plus sparse
    // per-cell overrides. The CSR scales with authored effects, not
    // `cell_count * good_count`, and is rebuilt only when one of those stats
    // changes. Transient; never saved or hashed.
    uint64_t _epoch_city_output_factor_stat_version = 0;
    bool _epoch_city_output_factor_valid = false;
    std::vector<int32_t> _city_output_shared_goods_q16;
    std::vector<int32_t> _city_output_cell_offsets;
    std::vector<int32_t> _city_output_good_indices;
    std::vector<int32_t> _city_output_factors_q16;
    std::vector<uint64_t> _city_output_scope_cells_scratch;
    std::vector<int32_t> _city_output_scope_stat_ids_scratch;
    // Epoch-transient country/type availability cache. Technology authority is
    // frozen once per daily transaction, so every cell in a country shares the
    // same result and hot loops can consume the ascending CSR directly.
    std::vector<uint8_t> _epoch_country_building_available;
    std::vector<uint8_t> _epoch_country_good_available;
    std::vector<uint8_t> _epoch_country_market_available;
    std::vector<uint8_t> _epoch_country_profession_available;
    std::vector<uint8_t> _epoch_country_variant_available;
    std::vector<int32_t> _epoch_country_building_type_offsets;
    std::vector<int32_t> _epoch_country_building_type_indices;
    // Social-development inputs frozen with the country epoch. Technology
    // progress is one popcount per country; the per-cell value additionally
    // folds in settlement tier and local built-industry variety so the hot loop
    // only reads a single Q16 per cell.
    std::vector<int32_t> _epoch_country_technology_progress_q16;
    std::vector<int32_t> _epoch_cell_development_q16;
    // Population-weighted survival-plan cost per person per day, refreshed by
    // compute_cell_living_costs_from_basis. Derived diagnostics only: it is the
    // savings dimension's denominator and never moves money.
    std::vector<int64_t> _cell_living_cost_per_capita;
    // Last published social-pressure level per cell. Persisted so a reload does
    // not replay a level-crossing event that already fired.
    EconomyOwnedColumn<uint8_t> _cell_social_pressure_level{{{16, 14}, "native_columns.cell_social_pressure_level", EconomyFieldEncoding::U8, 1}};
    // Slow EMA of the surplus×sat mix factor. Fertility reads this so a single
    // harvest spike does not jump K_eff. Persisted in PKEC v36.
    EconomyOwnedColumn<int32_t> _cell_support_ema_q16{{{16, 15}, "native_columns.cell_support_ema_q16", EconomyFieldEncoding::I32, 4}};
    // Derived carrying diagnostics. Not hashed except support EMA; Inspector only.
    std::vector<int64_t> _cell_carrying_k_geo;
    std::vector<int64_t> _cell_carrying_k_eff;
    std::vector<int32_t> _cell_carrying_surplus_q16;
    std::vector<int32_t> _cell_carrying_sat_q16;
    std::vector<int32_t> _cell_carrying_family_surplus_q16;
    std::vector<uint8_t> _cell_carrying_family_bindable;
    // Previous completed-period food-flow authority. The *_period lanes are
    // worker/settlement accumulators for the current epoch; demography reads
    // only the *_previous lanes.
    std::vector<int64_t> _cell_food_output_eq_period;
    std::vector<int64_t> _cell_food_input_eq_period;
    std::vector<int64_t> _cell_food_import_eq_period;
    std::vector<int64_t> _cell_food_export_eq_period;
    std::vector<int64_t> _cell_food_access_eq_period;
    EconomyOwnedColumn<int64_t> _cell_food_output_eq_previous{{{16, 8}, "native_columns.cell_food_output_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_food_input_eq_previous{{{16, 7}, "native_columns.cell_food_input_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_food_import_eq_previous{{{16, 6}, "native_columns.cell_food_import_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_food_export_eq_previous{{{16, 4}, "native_columns.cell_food_export_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_food_access_eq_previous{{{16, 3}, "native_columns.cell_food_access_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<uint8_t> _cell_food_flow_valid{{{16, 5}, "native_columns.cell_food_flow_valid", EconomyFieldEncoding::U8, 1}};
    EconomyTrackedScalar<int32_t> _food_flow_previous_period_days{_metadata_changes, {{15, 16}, "metadata.food_flow_previous_period_days", EconomyFieldEncoding::I32, 4}, 0};
    int64_t _food_output_events = 0;
    int64_t _food_input_events = 0;
    int64_t _food_trade_events = 0;
    int64_t _food_access_events = 0;
    int64_t _carrying_old_resource_scan_steps = 0;
    int32_t _epoch_country_count = 0;
    int32_t _epoch_country_technology_words = 0;
    uint64_t _epoch_country_generation = 0;
    uint64_t _epoch_country_hash = 0;
    uint64_t _epoch_country_topology_hash = 0;
    // Merchant capacity is frozen with the country snapshot so dispatch does
    // not rescan every map cell on each trade slice.
    std::vector<int64_t> _epoch_country_merchant_population;
    // Frozen at the same epoch boundary for the small-country birth bonus.
    std::vector<int64_t> _epoch_country_population;
    std::vector<BuildingType> _building_types;
    std::vector<std::string> _production_climate_profile_ids;
    std::vector<ProductionClimateProfile> _production_climate_profiles;
    // Catalog-baked, sorted unique signal edges per building type. Topology
    // rebuilds consume these spans instead of walking nested recipe columns.
    std::vector<int32_t> _building_type_market_signal_goods;
    std::vector<int32_t> _building_type_labor_signal_professions;
    std::vector<JobRole> _building_employee_roles;
    std::vector<GoodAmount> _building_construction_goods;
    // Candidate CSR is parallel to _building_construction_goods. The legacy
    // preferred good remains the first-class group identity; each slice is an
    // OR list of regional substitutes for that required group.
    std::vector<int32_t> _building_construction_candidate_offsets;
    std::vector<ConstructionCandidate> _building_construction_candidates;
    std::vector<int32_t> _building_maintenance_author_offsets;
    std::vector<GoodAmount> _building_maintenance_author_goods;
    std::vector<GoodAmount> _building_maintenance_goods;
    std::vector<ProductionInput> _building_inputs;
    // Catalogue-static physical quantity for each input candidate row
    // (input quantity / candidate efficiency, rounded up). Recomputed by the
    // selection hot path before; only depends on catalogue data.
    std::vector<int64_t> _building_input_candidate_physical_daily;
    std::vector<InputCandidate> _building_input_candidates;
    std::vector<GoodAmount> _building_outputs;
    std::vector<int32_t> _building_output_cost_shares_q16;
    std::vector<ResourceAmount> _building_resources;
    std::vector<ResourceAmount> _building_resource_generation;
    std::vector<ConditionToken> _building_conditions;
    // A+Y N2: buildings_store() is the sole building-group storage. Hot paths
    // read and write it through building_at() / building_count(); there is no
    // AoS scratch lane to materialize or flush.
    // Kit settlement may append groups during LEDGER_APPLY. Reordering and
    // market-signal rebuild wait for BUILDING_COMMIT so frozen epoch group
    // indices and production reserves stay aligned. Idle-boundary landings
    // rebuild immediately and leave this false.
    bool _pending_building_topology_rebuild = false;
    // Handle -> compact group index acceleration for the group lane. Rebuilt
    // lazily whenever the group lane changes size and verified on every hit,
    // so a stale entry degrades into a rebuild instead of a wrong index.
    mutable std::unordered_map<uint64_t, int32_t> _building_handle_index;
    mutable size_t _building_handle_index_stamp = static_cast<size_t>(-1);
    mutable bool _building_handle_index_clean = false;
    // Transient topology scratch and reusable role/input spans. Structural
    // commits swap the compact group lane but keep authoritative role arrays
    // in place; these caches are reconstructed after configure/restore.
    // Destination order over the current group lane plus the matching
    // is-new flags, consumed by permute_building_group_columns().
    std::vector<int32_t> _building_group_order_scratch;
    std::vector<uint8_t> _building_group_is_new_scratch;
    std::vector<int32_t> _building_existing_indices_scratch;
    std::vector<int32_t> _building_new_indices_scratch;
    std::vector<int64_t> _building_investment_score_rebuild_scratch;
    std::vector<int64_t> _building_investment_payback_rebuild_scratch;
    std::vector<int32_t> _building_investment_rejection_rebuild_scratch;
    std::vector<std::vector<BuildingRoleSpan>> _building_free_role_spans_by_type;
    std::vector<uint32_t> _building_market_signal_stamp;
    std::vector<uint32_t> _building_labor_signal_stamp;
    uint32_t _building_market_signal_stamp_generation = 0;
    uint32_t _building_labor_signal_stamp_generation = 0;
    std::vector<int32_t> _building_cell_offsets;
    std::vector<int32_t> _building_active_cells;
    std::vector<int32_t> _building_visual_cell_offsets;
    std::vector<int32_t> _building_visual_type_indices;
    std::vector<int64_t> _building_visual_counts;
    std::vector<int32_t> _building_visual_dirty_cells;
    uint64_t _building_visual_generation = 0;
    // Presentation-only social bands with hysteresis: not persisted and not
    // part of the state hash; rebuilt from cohorts on read_view_reset().
    std::vector<uint8_t> _visual_living_level;
    std::vector<uint8_t> _visual_rich_bucket;
    std::vector<uint8_t> _visual_poor_bucket;

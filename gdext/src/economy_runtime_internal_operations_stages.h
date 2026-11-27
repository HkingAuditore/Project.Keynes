// Per-stage plan, commit, runtime inputs, and accounting operations.

    void refresh_building_modifier_factors();
    // Returns true when the whole refresh finished, false when it yielded with a
    // resume cursor. Plan §14.3 requires "each derived native slice <= 1 ms";
    // M1-6 measured this reader at 0.465 ms (2400 cells) and 1.264 ms (6400
    // cells) while running to completion inside ONE
    // `run_economy_slice` (it is reached from `capture_country_epoch`, itself
    // inside `start_epoch`). With a derived layer adding work in the same
    // indivisible window there is no budget left, so the loop must be able to
    // stop between cells.
    //
    // The first call after `_city_factor_shard_cursor < 0` performs the
    // whole-matrix paint and the scope collection, then advances a cell cursor.
    // Subsequent calls resume at that cursor until the work set is exhausted.
    bool refresh_city_modifier_factors();
    // Returns true when the whole refresh finished, false when it yielded.
    //
    // Why the output reader needs its own cursor rather than waiting for the
    // city reader to finish: chaining the two made the output factors update
    // only on the LAST city shard, so on a multi-shard epoch the production
    // factors were half-refreshed for the intermediate slices. Two independent
    // cursors keep both readers' progress monotonic and keep the total work
    // unchanged.
    bool refresh_city_output_modifier_factors();
    int32_t city_good_output_factor_q16(int32_t cell, int32_t good_id) const;
    int64_t planned_owner_demand(BuildingGroupConstRef group,
                                 int64_t &sat) const;
    int64_t building_debt_due(BuildingGroupConstRef group, int64_t &sat) const;
    int64_t repay_building_debt(int32_t cell, int32_t owner_slot,
                                BuildingGroupRef group, int64_t payment_cap,
                                int64_t &premium_paid);
    int64_t available_resource_amount(const ResourceAmount &item, int32_t cell) const;
    void ensure_resource_lane(size_t index);
    void consume_resource_amount(const ResourceAmount &item, int32_t cell, int64_t quantity);
    void queue_bio_introduce_from_good(int32_t cell, int32_t good_id);
    void commit_bio_introduce(int32_t cell, int32_t bit);
    bool resource_is_renewable(int32_t resource_id) const;
    int32_t resource_stock_density_q16(int32_t resource_id, int32_t cell) const;
    int64_t renewable_safe_harvest(int32_t resource_id, int32_t cell) const;
    bool commit_ready_construction(std::vector<int32_t> &changed_cells,
                                   bool prune_empty_groups = true);
    void initialize_building_role_span(BuildingGroupRef group);
    void release_building_role_span(BuildingGroupConstRef group);
    void rebuild_building_role_storage();
    void rebuild_building_cell_offsets();
    void rebuild_building_visual_snapshot();
    void publish_building_visual_changes(
        const std::vector<int32_t> &changed_cells);
    void rebuild_building_review_buckets();
    void review_recovery_building_group(int32_t group_index);
    void finalize_household_building_cell(int32_t cell, int64_t &saturation,
                                          int64_t &restarted,
                                          int64_t &failed);
    int64_t production_reserve_shortfall_cell(int32_t cell,
                                              int64_t &saturation) const;
    void add_trade_active_key(int32_t market, int32_t good);
    void rebuild_market_signals();
    void rebuild_market_signal_lookup();
    bool flush_market_signal_overflow(std::string &error);
    int32_t ensure_market_signal_index(int32_t cell, int32_t good);
    void mark_market_signal_cell_dirty(int32_t cell);
    void mark_market_signal_full_rebuild(const char *reason);
    void mark_labor_signal_cell_dirty(int32_t cell);
    void mark_labor_signal_full_rebuild(const char *reason);
    void mark_input_reserve_cell_dirty(int32_t cell);
    void mark_input_reserve_full_rebuild(const char *reason);
    void rebuild_production_input_reserves(int32_t active_begin = 0,
                                           int32_t active_end = -1,
                                           bool initialize = true);
    int64_t rebuild_production_input_reserves_for_cell(int32_t cell);
    void recount_production_input_reserve_totals();
    void resolve_building_maintenance_csr();
    bool is_storable_nonmonetary_good(int32_t good) const;
    int32_t resolved_maintenance_horizon_days(const BuildingType &type) const;
    int64_t merchant_protected_reserve(int32_t signal) const;
    int64_t daily_maintenance_cost_for_type(
        int32_t cell, const BuildingType &type, int64_t &sat) const;
    int64_t maintenance_settlement_price(
        int32_t cell, int32_t good, int64_t &sat) const;
    void rebuild_labor_signals();
    int32_t labor_signal_index(int32_t cell, int32_t profession) const;
    int64_t living_cost_for_signature(int32_t cell, int32_t signature_id,
                                      int32_t plan_override, int64_t &sat) const;
    int64_t essential_living_cost_for_signature(int32_t cell, int32_t signature_id,
                                                int32_t plan_override, int64_t &sat) const;
    int64_t living_cost_for_signature_impl(int32_t cell, int32_t signature_id,
                                           int32_t plan_override, bool essentials_only,
                                           int64_t &sat) const;
    void compute_cell_living_costs_from_basis(
        int32_t cell, const std::vector<int64_t> &variant_scores,
        const std::vector<int64_t> &variant_prices,
        const std::vector<int64_t> &need_score_sums,
        const std::vector<int64_t> &need_environment, int64_t &sat);
    bool prepare_cell_wages(int32_t cell, std::string &error);
    void update_cell_labor_signals(int32_t cell);
    int64_t production_climate_capacity_q16(
        const BuildingType &type, int32_t cell,
        int64_t *temperature_fit_q16, int64_t *water_fit_q16,
        int64_t &saturation_count) const;
    void prepare_group_climate_capacity(BuildingGroupRef group,
                                        const BuildingType &type);
    // SHADOW-only parity: publish graph stage hash/work to Host when the sync
    // ECONOMY_GRAPH stage completes and ECONOMY is not worker-authoritative.
    void publish_shadow_graph_stage_reference(RuntimeEconomyGraphStage stage);
    // Shared BUILDING_PLAN entry: routes through economy_kernel_prepare_building_plan
    // so sync and future worker probe worlds share one boundary (no second formula).
    bool evaluate_building_plan_range(int32_t active_begin, int32_t active_end, std::string &error);
    bool prepare_building_economic_plan(int32_t active_begin, int32_t active_end,
                                        const std::vector<int32_t> *cells_override,
                                        BuildingPlanResult &result,
                                        std::string &error);
    // Mutation body owned by NativeEconomyRuntime SoA; invoked only via the
    // EconomyBuildingPlanExecutor adapter registered with the shared kernel.
    bool prepare_building_economic_plan_body(int32_t active_begin, int32_t active_end,
                                             const std::vector<int32_t> *cells_override,
                                             BuildingPlanResult &result,
                                             std::string &error);
    int32_t market_signal_index(int32_t cell, int32_t good) const;
    int64_t epoch_research_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_research_demand_daily_for_market(int32_t market,
                                                   int32_t good) const;
    void refresh_epoch_research_demand();
    void refresh_epoch_colonization_demand();
    bool military_procurement_demand_valid(const Command &cmd) const;
    bool retain_military_procurement_demand(const Command &cmd, std::string &error);
    void refresh_epoch_military_demand(int64_t day);
    int64_t epoch_military_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_military_demand_daily_for_market(int32_t market, int32_t good) const;
    int64_t epoch_colonization_demand(int32_t cell, int32_t good) const;
    int64_t epoch_colonization_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_procurement_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_procurement_demand_daily_for_market(int32_t market,
                                                       int32_t good) const;
    void refresh_epoch_bullion_quota();
    int64_t bullion_cell_quota_remaining(int32_t cell) const;
    int64_t bullion_cell_quota_initial(int32_t cell) const;
    int64_t bullion_quota_remaining(int32_t cell, int32_t good) const;
    int64_t consume_bullion_quota(int32_t cell, int32_t good,
                                  int64_t requested, int64_t &sat);
    PricePressure price_pressure(int32_t market, int32_t good, int64_t household_demand,
                                 int64_t stock, int64_t shortage_q16,
                                 int32_t signal_index, int64_t &saturation_count) const;
    int64_t next_price_v6(int32_t good, int64_t current_price,
                          const PricePressure &pressure, int32_t days,
                          int64_t &saturation_count, bool &rate_clamped,
                          bool &rise_damped, bool *minimum_tick = nullptr) const;
    // Settlement / trade projection share this clamp. Economic prices are not
    // capped by catalog reference_max_price; only the i32 numeric guard applies.
    // The reference/default/cost arguments are retained for call-site ABI and
    // ignored by the current formula.
    static int32_t base_price_ceiling(int32_t reference, int32_t default_price,
                                       int64_t cost_anchor);
    static PriceCeilingState advance_price_ceiling(PriceCeilingState state,
        int32_t base, int32_t price, int64_t funded_shortage_q16, int32_t days,
        int32_t confirm_days, int32_t expand_bp, int32_t recover_bp);
    int32_t market_price_ceiling(int32_t market, int32_t good,
                                 int64_t cost_anchor) const;
    int64_t price_ceiling_state_count() const;
    void commit_price_ceilings();
    std::vector<PriceCeilingObservation> _epoch_price_ceiling_observations;
    std::vector<PriceCeilingState> _price_ceiling_merge_scratch;
    std::vector<int64_t> _epoch_ceiling_business_requested, _epoch_ceiling_business_unfilled;
    std::vector<int64_t> _epoch_ceiling_research_requested, _epoch_ceiling_research_delivered;
    std::vector<int32_t> _epoch_ceiling_research_touched;

    EconomyTrackedScalar<int32_t> _price_ceiling_confirm_days{_metadata_changes, {{15, 24}, "metadata.price_ceiling_confirm_days", EconomyFieldEncoding::I32, 4}, 30};
    EconomyTrackedScalar<int32_t> _price_ceiling_expand_bp{_metadata_changes, {{15, 25}, "metadata.price_ceiling_expand_bp", EconomyFieldEncoding::I32, 4}, 50};
    EconomyTrackedScalar<int32_t> _price_ceiling_recover_bp{_metadata_changes, {{15, 26}, "metadata.price_ceiling_recover_bp", EconomyFieldEncoding::I32, 4}, 10};
    int64_t _price_ceiling_expansions = 0;
    int64_t _price_ceiling_recoveries = 0;
    int64_t _price_ceiling_blocked_rises = 0;
    static int64_t shape_price(int32_t ceiling, int64_t current_price, int64_t next_price,
                        int64_t &saturation_count, bool *headroom_damped,
                        bool *catalog_bound, bool *minimum_tick = nullptr);
    int32_t find_building_group(int32_t cell, int32_t type_id,
                                int32_t owner_signature_id) const;
    int32_t find_cohort_slot(int32_t cell, int32_t signature_id) const;
    int64_t credit_local_merchants(int32_t cell, int64_t amount,
                                   int32_t cashflow_source = CASHFLOW_MERCHANT_BUSINESS,
                                   int64_t *saturation_override = nullptr);
    // Same denominator as credit_local_merchants: false when every local
    // merchant cohort is empty, so a market purchase has no seller to pay.
    bool local_merchants_can_receive(int32_t cell) const;
    int64_t debit_local_merchants(int32_t cell, int64_t amount,
                                  int32_t cashflow_source = CASHFLOW_MERCHANT_PROCUREMENT,
                                  int64_t *saturation_override = nullptr);
    int64_t pay_building_wage_amount(int32_t cell, int32_t owner_slot,
                                     int32_t profession_id, int64_t filled_jobs,
                                     int64_t due, int64_t payment_cap,
                                     int64_t *saturation_override = nullptr);
    void fail(const std::string &reason);
    void capture_fatal_context(const std::string &reason);
    void park_on_country_asset_pending(const char *substage);
    void clear_epoch_metrics();
    void capture_completed_perf_snapshot();
    void rebuild_committed_summaries();
    CellSummary build_cell_summary(int32_t cell) const;
    void stage_cell_summary(int32_t cell, const CellSummary &summary);
    void finalize_market_result(int32_t market, MarketResult &result);
    void refresh_investment_active_goods_for_cell(int32_t cell,
                                                  int64_t &saturation_count);
    bool rebuild_market_cell_ranges(std::string &error);
    bool ensure_merchant_invariant(int32_t cell, int64_t &repair_count,
                                   std::string &error);
    bool rebuild_merchant_ranges(std::string &error);
    bool refresh_merchant_ranges_if_dirty(std::string &error);
    bool repair_cell_merchant_and_rebuild(int32_t cell, std::string &error);
    bool run_government_research_procurement(std::string &error);
    bool advance_country_research_procurement(
        CountryResearchProcurementContinuation &continuation,
        std::string &error);
    CountryWorkerAssetRoute block_or_enqueue_country_worker_asset(
        uint16_t operation, int64_t country_handle, int64_t cash,
        int64_t quantity, int32_t good_id, std::string &error,
        uint64_t *request_id = nullptr);
    CountryWorkerAssetRoute block_or_enqueue_country_worker_asset(
        uint16_t operation, int64_t country_handle, int64_t cash,
        int64_t quantity, const std::vector<int32_t> &good_ids,
        const std::vector<int64_t> &good_quantities, std::string &error,
        uint64_t *request_id = nullptr, int32_t target_slot = -1);
    bool coordinate_country_fiscal_transaction(
        int32_t country, int32_t operation, int64_t amount,
        int64_t &committed, std::string &error,
        uint64_t *transport_request_id = nullptr);
    bool finish_country_fiscal_asset(
        uint64_t request_id, RuntimeEconomyAssetResult &terminal,
        std::string &error);
    // M1+ peer service. Economy consumes Country-authorized asset requests and
    // never writes the Country store. Fiscal ops mutate escrow; non-fiscal ops
    // (when the D7 gate is open) apply local cohort/market side effects then
    // journal COMPLETED using Country-prepared quantities.
    bool service_country_economy_asset_peer(uint32_t max_requests,
                                            std::string &error);
    bool fiscal_peer_journal_matches(
        const RuntimeEconomyAssetRequest &request,
        const FiscalPeerJournalRecord &record, std::string &error) const;
    RuntimeEconomyAssetResult fiscal_peer_result_from_journal(
        const RuntimeEconomyAssetRequest &request,
        const FiscalPeerJournalRecord &record) const;
    void record_fiscal_peer_terminal(
        const RuntimeEconomyAssetRequest &request,
        RuntimeEconomyAssetResultCode code,
        RuntimeEconomyAssetState state,
        int64_t committed_quantity, int64_t committed_cash,
        const char *reason);
    // Economy-side apply for M2–M5 after Country has already committed value.
    // RESEARCH_PURCHASE / TREASURY_SPEND complete without local mutation when
    // Country transferred treasury goods/cash on its path.
    bool apply_peer_asset_side_effects(const RuntimeEconomyAssetRequest &request,
                                       std::string &error);
    // Economy-owned peer coordinator for Country/cohort cash transfers. The
    // cohort is prepared before Country commit, then mutated exactly once and
    // acknowledged with the same transaction identity.
    bool coordinate_country_cohort_cash(
        int32_t cohort_slot, int64_t country_handle, int32_t operation,
        int64_t amount, int64_t &committed, std::string &error);
    // Economy-owned coordinator for Country/market inventory transfers. The
    // market lane is preflighted before Country commit and mutated once after
    // the commit decision.
    bool coordinate_country_market_goods(
        int32_t market, int32_t good, int64_t country_handle,
        int32_t operation, int64_t amount, int64_t &committed,
        std::string &error);
    bool coordinate_country_treasury_spend(
        int32_t merchant_cell, int32_t market, int64_t country_handle,
        const std::vector<int32_t> &good_ids,
        const std::vector<int64_t> &treasury_quantities,
        const std::vector<int64_t> &market_quantities, int64_t cash,
        int64_t &committed_cash, std::string &error);
    void refresh_country_research_goods_consumed();
    // Re-pin closing country goods/cash with research_consumed from one Country
    // snapshot immediately before VERIFY. Peer-wait previews / late-fold
    // research catch-up can otherwise advance consumed after closing goods were
    // frozen and trip goods_conservation_failed. Opening pins the same triple
    // atomically in begin_epoch (see economy_runtime_epoch.cpp).
    void resync_closing_country_goods_audit();
    bool compile_family_catalog(const godot::Dictionary &catalog,
                                std::string &error);
    bool compile_family_trait_catalog(const godot::Dictionary &catalog,
                                      std::string &error);
    bool compile_family_effect_catalog(const godot::Dictionary &catalog,
                                       std::string &error);
    bool run_family_commit_slice(int64_t &work_done, std::string &error);
    // Phase-2.4.3.3: StageOps mutate drains (compact keeps per-slice calls).
    bool run_family_commit_drain(int64_t &work_done, std::string &error);
    bool run_person_commit_drain(int64_t &work_done, std::string &error);
    bool run_aggregate_publish_drain(int64_t &work_done, std::string &error);
    // Phase-2.4.3.1: shared BUILDING_COMMIT phase driver (no run_slice_compact).
    // ContinueFusing = stay in stage, outer loop may fuse; StopSlice = yield;
    // LeftStage = _stage moved past BUILDING_COMMIT; Fatal = fail() already called.
    enum class BuildingCommitChunkResult : uint8_t {
        ContinueFusing = 0,
        StopSlice = 1,
        LeftStage = 2,
        Fatal = 3,
    };
    BuildingCommitChunkResult advance_building_commit_chunk(
        int64_t &work_done, int32_t &cursor_start, int32_t &cursor_end,
        bool &building_range_used, std::string &error, bool yield_enabled,
        int32_t *chunks_completed, int32_t max_chunks_per_slice,
        int32_t *phase_fusions, const char **yield_reason,
        const std::chrono::steady_clock::time_point *slice_start,
        double slice_budget_ms);
    // Phase-2.2/2.4.3.1: StageOps mutate entry for BUILDING_COMMIT. Drains the
    // shared phase driver until the runtime leaves BUILDING_COMMIT — never
    // re-enters run_slice_compact. Phase-2.4.3.2 then drains fiscal settlement
    // so FAMILY_COMMIT sees settled escrow (graph has no FISCAL stage).
    bool run_building_commit_slice(int64_t &work_done, std::string &error);
    // Phase-2.4.4.3: shared HOUSEHOLD_MARKET phase driver (no run_slice_compact).
    enum class HouseholdMarketChunkResult : uint8_t {
        ContinueFusing = 0,
        StopSlice = 1,
        LeftStage = 2,
        Fatal = 3,
    };
    HouseholdMarketChunkResult advance_household_market_chunk(
        int64_t &work_done, int32_t &cursor_start, int32_t &cursor_end,
        bool &building_range_used, bool &cell_range_used, std::string &error,
        bool yield_enabled, int32_t batch_multiplier, int32_t *chunks_completed,
        int32_t max_chunks_per_slice, int32_t *phase_fusions,
        const char **yield_reason,
        const std::chrono::steady_clock::time_point *slice_start,
        double slice_budget_ms);
    bool run_household_market_drain(int64_t &work_done, std::string &error);
    // Phase-2.4.3.2: StageOps-only fiscal bridge after BUILDING_COMMIT.
    // Fail-closed on country peer pending (compact yields; StageOps cannot).
    bool run_fiscal_settlement_drain(std::string &error);
    void diag_stage_money_probe(const char *where, bool force = false);
    // Phase-2.4.4.3: StageOps bounded mid-graph drains (cursor + slice caps).
    // Compact keeps its own slice loops; these drains never re-enter
    // run_slice_compact.
    bool run_building_employment_drain(int64_t &work_done, std::string &error);
    bool run_building_production_drain(int64_t &work_done, std::string &error);
    struct BuildingInvestmentCellContext;
    enum class InvestmentPreflightResult : uint8_t {
        Skip = 0,
        Ready = 1,
        Fatal = 2,
    };
    bool investment_prepare_cell(BuildingInvestmentCellContext &ctx);
    bool investment_evaluate_cell_types(BuildingInvestmentCellContext &ctx);
    struct InvestmentSparseFilter {
        uint32_t stamp = 0;
        bool ready = false;
        bool active = false;
    };
    InvestmentSparseFilter prepare_investment_sparse_filter(const BuildingInvestmentCellContext &ctx);
    void investment_mark_rejection(const InvestmentExistingType *existing,
                                   int32_t reason);
    void investment_allocate_portfolio(BuildingInvestmentCellContext &ctx);
    InvestmentPreflightResult investment_preflight_portfolio(
        BuildingInvestmentCellContext &ctx, std::string &error);
    bool investment_commit_portfolio(BuildingInvestmentCellContext &ctx,
                                     bool &population_changed,
                                     std::string &error);
    // Records the failing investment leg for fatal_context_report(). Called by
    // investment_commit_portfolio immediately before it returns false, so the
    // next player report names the cell, type, leg and the two numbers the
    // assertion compared instead of reporting a bare reason string.
    void record_investment_fatal_row(int32_t cell,
                                     const InvestmentCandidatePlan &plan,
                                     int32_t portfolio_index,
                                     int32_t portfolio_size, int32_t branch,
                                     int64_t owner_population,
                                     int64_t required_capital, int64_t carried,
                                     int64_t correction, int32_t owner_slot,
                                     int64_t owner_funds, bool source_drained);
    // Records the failing construction-material payment for
    // fatal_context_report(). commit_preflighted_build_command() calls it at its
    // two drift assertions (funds / stock); without it a
    // building_construction_preflight_*_drift stop names no cell, type or number.
    void record_construction_fatal_row(int32_t cell, int32_t type_id,
                                       int64_t allocated_count,
                                       int64_t total_cost, int32_t owner_slot,
                                       int64_t owner_funds, int64_t funding_gap,
                                       int64_t debt_principal,
                                       bool material_feasible,
                                       int32_t good_count, int32_t first_good_id,
                                       int64_t first_required,
                                       int64_t first_stock,
                                       const char *reason);
    // Phase-2.4.4.4: StageOps drains for early/late graph stages that were still
    // single-slice in dispatch (Host advances stage_index once per pulse).
    bool run_ledger_apply_drain(int64_t &work_done, std::string &error);
    bool run_government_research_drain(int64_t &work_done, std::string &error);
    bool run_structural_commit_drain(int64_t &work_done, std::string &error);
    // Phase-2.4.5: BUILDING_PLAN evaluate+reserve drain (matches compact).
    bool run_building_plan_drain(int64_t &work_done, std::string &error);
    void rebuild_family_indices(bool rebuild_derived = true);
    void rebuild_family_industry_metrics();
    void rebuild_family_owned_output_csr();
    bool rebuild_family_behavior_cache();
    void mark_family_behavior_cache_dirty(uint32_t reason);
    // Track B cadenced AGGREGATE_PUBLISH state hash carry (per runtime).

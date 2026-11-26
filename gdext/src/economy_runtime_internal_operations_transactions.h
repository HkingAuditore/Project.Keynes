// Fiscal and market quotes, construction settlement, and managed goods calculations.

    struct TransactionQuote {
        int64_t base_value = 0;
        int64_t buyer_outlay = 0;
        int64_t seller_receipt = 0;
        int64_t fiscal_transfer = 0;
    };
    struct BuildingTaxQuote {
        int64_t business_transfer = 0;
        int64_t income_transfer = 0;
        int64_t after_tax_cash = 0;
    };
    TransactionQuote quote_transaction(int32_t cell, int32_t good,
                                        int64_t base_value,
                                        bool settle,
                                        bool subsidy_eligible,
                                        int64_t &saturation_count,
                                        int64_t filled_quantity);
    void settle_income_subsidies_for_cell(int32_t cell,
                                          int64_t &saturation_count);
    void settle_absolute_daily_taxes_for_cell(int32_t cell,
                                              int64_t &saturation_count);
    bool commit_fiscal(std::string &error);
    // Books one non-tax treasury outflow for the batch summary. `country_handle`
    // is the generation-safe payer handle; 0 is a no-op so callers may pass an
    // unresolved payer without inventing an attribution.
    void note_non_tax_outflow(uint64_t country_handle, int32_t kind, int64_t cash);
    int32_t epoch_country_index(uint64_t handle) const;
    bool advance_fiscal_reservation(std::string &error);
    bool advance_fiscal_settlement(std::string &error);
    int32_t frozen_tax_rate(int32_t cell, int32_t kind, int32_t item) const;
    int32_t frozen_tax_mode(int32_t cell, int32_t kind, int32_t item) const;
    int64_t apply_fiscal_tax(int32_t cell, int32_t kind, int64_t base,
                             int32_t rate, int64_t &saturation_count);
    int64_t apply_fiscal_tax(int32_t cell, int32_t kind, int64_t base,
                             int32_t rate, int32_t mode,
                             int64_t &saturation_count);
    struct FiscalLaneSnapshot {
        size_t lane = SIZE_MAX;
        int64_t bases = 0;
        int64_t assessed = 0;
        int64_t collected = 0;
        int64_t current_requests = 0;
        int64_t remaining = 0;
        int64_t paid = 0;
    };
    // apply_fiscal_tax settles immediately; callers that may abandon the
    // purchase afterwards must restore the lane so tax never outlives payment.
    FiscalLaneSnapshot snapshot_fiscal_lane(int32_t cell, int32_t kind) const;
    void restore_fiscal_lane(const FiscalLaneSnapshot &snapshot);
    int64_t expected_fiscal_transfer(int32_t cell, int32_t kind, int64_t base,
                                     int32_t rate,
                                     int64_t &saturation_count) const;
    int64_t expected_fiscal_transfer(int32_t cell, int32_t kind, int64_t base,
                                     int32_t rate, int32_t mode,
                                     int64_t &saturation_count) const;
    // Resolve frozen mode: percent uses money base, absolute uses unit count
    // (person-days, building-days, or goods quantity).
    int64_t expected_resolved_fiscal_transfer(
            int32_t cell, int32_t kind, int32_t item, int64_t percent_base,
            int64_t absolute_units, int64_t &saturation_count) const;
    int64_t producer_support_receipt_value(int32_t cell, int32_t good,
                                           int64_t quantity,
                                           int64_t &saturation_count) const;
    BuildingTaxQuote expected_building_tax_quote(
            int32_t cell, int32_t type_id, int32_t owner_profession,
            int64_t merchant_cash, int64_t producer_support_cash,
            int64_t business_eligible_cost, int64_t operating_cost,
            int64_t owner_living_cost, int64_t building_days,
            int64_t owner_days, int64_t &saturation_count) const;
    int32_t tariff_epoch_lane_index(int32_t cell, int32_t tariff_kind,
                                    bool create);
    int64_t expected_after_tax_income(int32_t cell, int32_t profession,
                                      int64_t gross_income,
                                      int64_t &saturation_count) const;
    int64_t fiscal_escrow_total() const;
    bool apply_build_command(const Command &cmd, int32_t owner_slot,
                             std::string &error, bool allow_obsolete_tier = false);
    bool investment_portfolio_funds_feasible(int32_t cell,
        const InvestmentCandidatePlan *const *plans,
        const ConstructionMaterialPlan *materials, int32_t count) const;
    bool commit_preflighted_build_command(
        const Command &cmd, int32_t owner_slot,
        const ConstructionMaterialPlan &material_plan,
        int32_t effective_construction_days,
        int64_t construction_debt_principal,
        int64_t construction_debt_premium,
        int64_t funding_gap,
        std::string &error);
    bool plan_construction_materials(int32_t cell, int32_t type_id,
                                     int64_t count, int32_t cost_factor_q16,
                                     ConstructionMaterialPlan &plan,
                                     const std::vector<int64_t> *additional_stock = nullptr,
                                     std::vector<int64_t> *stock_inout = nullptr,
        bool split_candidates = false, bool forecast_missing = false) const;
    bool apply_demolish_command(const Command &cmd, int32_t owner_slot, std::string &error);
    bool run_building_employment_cell(int32_t cell,
                                      bool allow_owner_job_reallocation,
                                      std::string &error);
    void replace_employment_metrics_for_cell(int32_t cell, int64_t owner_jobs,
                                             int64_t employee_jobs,
                                             int64_t unemployed_population);
    bool reconcile_building_employment_after_population_change(
        const std::vector<int32_t> &affected_cells, std::string &error);
    bool reconcile_building_employment_cells_range(
        const std::vector<int32_t> &stable_cells, int32_t begin, int32_t end,
        std::string &error);
    bool run_building_production_cell(int32_t cell, ProductionResult &result,
                                      std::string &error);
    void merge_building_production_result(ProductionResult &result);
    bool run_endogenous_building_investment(int32_t ordinal_begin,
                                            int32_t ordinal_end,
                                            bool initialize,
                                            bool &population_changed,
                                            std::string &error);
    void prepare_investment_review_cells();
    void begin_investment_scratch_generation();
    void ensure_investment_cell_finance_lane(int32_t cell);
    void ensure_investment_resource_commitment_lane(size_t index);
    int64_t investment_merchant_cash(int32_t cell) const;
    int64_t investment_outstanding_credit(int32_t cell) const;
    int64_t investment_resource_committed(size_t index) const;
    void record_investment_material_demand(int32_t cell, int32_t type_id,
        int64_t count, int32_t cost_factor_q16);
    void reserve_first_research_construction(int32_t cell);
    void prepare_startup_demand();
    void propagate_startup_demand_for_cell(int32_t cell);
    void begin_startup_demand_generation();
    void record_startup_demand(int32_t cell, int32_t good_id,
                               int64_t daily_quantity);
    int64_t startup_demand_for(int32_t cell, int32_t good_id) const;
    int64_t remote_startup_demand_for(int32_t cell, int32_t good_id) const;
    void consume_remote_startup_demand(int32_t cell, int32_t good_id,
                                       int64_t daily_capacity);
    // Sparse Leontief explosion of unmet deficits into intermediate-good
    // shadow demand for pricing and investment. Sample-boundary only.
    void refresh_derived_business_demand();
    // Credit non-selected co-candidates on the same input edge with shadow
    // substitute demand equal to the selected planned quantity.
    void credit_input_substitute_demand(int32_t cell, const ProductionInput &input,
                                        int32_t selected_candidate_index,
                                        int64_t planned);
    int64_t market_flow_deficit_daily(int32_t cell, int32_t good_id,
                                      bool include_derived,
                                      int64_t &sat) const;
    int64_t startup_producer_output_quantity(int32_t cell, int32_t type_id,
                                             int32_t good_id,
                                             int64_t &sat) const;
    int32_t select_startup_producer(int32_t cell, int32_t good_id) const;
    int32_t select_startup_producer(int32_t cell, int32_t good_id,
                                    InvestmentCandidatePlan *plan) const;
    // Cold-start ranking aid: how well the preferred producer of `good_id`
    // can cover its hard inputs from current local stock. Used when every
    // soft-input substitute is out of stock so ghost market prices alone
    // do not steer demand onto an unbuildable higher-tier good. Soft-only /
    // input-free recipes return 0 (not Q16_ONE) so they cannot beat a
    // hard-input cold-start lane that is merely empty this epoch.
    int64_t startup_producer_hard_input_cover_q16(int32_t cell, int32_t good_id,
                                                 int64_t &sat) const;
    bool startup_candidate_better(int64_t coverage, int64_t cold_cover,
                                  int64_t price, int32_t good_id,
                                  int64_t best_coverage, int64_t best_cold_cover,
                                  int64_t best_price, int32_t best_good) const;
    bool resolve_startup_construction_material(int32_t cell, int32_t bom,
                                               int32_t cost_factor_q16,
                                               int32_t &good,
                                               int64_t &physical) const;
    void initialize_investment_candidate_plan(
        InvestmentCandidatePlan &plan, int32_t cell, int32_t type_id,
        int32_t owner_signature_id, int64_t utilization_q16,
        int64_t construction_cost, int64_t required_capital,
        int64_t payback_days, int64_t profit_per_day,
        int64_t return_on_capital_q16, int64_t owner_slots,
        int64_t employee_slots,
        const EconomicOpportunityQuote &quote) const;
    // Final shared financial normalization for every investment trigger.
    // Startup, research, recovery and ordinary expansion may discover a
    // candidate differently, but they all publish the same plan economics.
    bool evaluate_investment_candidate(
        InvestmentCandidatePlan &plan, int32_t cell, int32_t type_id,
        int32_t owner_signature_id, int64_t utilization_q16,
        int64_t construction_cost, int64_t required_capital,
        int64_t owner_slots, int64_t employee_slots,
        const EconomicOpportunityQuote &quote) const;
    int32_t select_startup_input_candidate(int32_t cell,
                                           const ProductionInput &input,
                                           int64_t &physical_daily) const;
    int32_t select_startup_construction_candidate(int32_t cell,
                                                  int32_t group,
                                                  int64_t &physical_quantity) const;
    int32_t find_entrepreneur_source(int32_t cell, int32_t target_signature,
                                     int64_t required_capital,
                                     int64_t target_income_per_day,
                                     int64_t target_living_cost_per_day,
                                     int64_t owner_slots_per_building,
                                     int32_t building_type_id,
                                     bool &had_eligible_sponsor,
                                     int64_t &willing_population,
                                     int64_t &transferable_capital,
                                     int64_t &income_improvement_q16,
                                     uint64_t &sponsor_family_handle,
                                     const std::vector<int64_t> *living_cost_cache = nullptr) const;
    int64_t projected_owner_income_per_day(BuildingGroupConstRef group,
                                           int64_t &sat) const;
    // Owner cash a merchant post can claim from its market's settled household
    // retail pool. `extra_slots` is the number of owner seats that will be
    // added to the market's merchant population by the decision being priced:
    // 0 for an already staffed lot, the seat count for a vacancy or a new
    // building. Dilution is what caps free entry.
    int64_t merchant_retail_owner_income_per_day(int32_t cell,
                                                 int64_t owner_slots,
                                                 int64_t extra_slots,
                                                 int64_t &sat) const;
    // True for the zero-output building types whose owner income is the
    // market retail pool rather than a goods receipt.
    bool is_merchant_service_post(const BuildingType &type) const;
    OwnerOpportunityQuote owner_opportunity_quote(
        BuildingGroupConstRef group, int64_t owner_fillability_q16,
        int64_t employee_fillability_q16, int64_t &sat) const;
    OwnerOpportunityQuote owner_opportunity_quote_uncached(
        BuildingGroupConstRef group, int64_t owner_fillability_q16,
        int64_t employee_fillability_q16, int64_t &sat) const;
    int64_t projected_employee_tax_retention_q16(
        BuildingGroupConstRef group, int64_t &sat) const;
    int64_t effective_building_output_quantity(
        BuildingGroupConstRef group, int32_t good_id, int64_t base_quantity,
        int64_t utilization_q16, int64_t building_days,
        int64_t &sat) const;
    // Same math for a synthetic target that has no row in the group lane.
    int64_t effective_building_output_quantity_at(
        int32_t cell, int32_t output_factor_q16, int32_t good_id,
        int64_t base_quantity, int64_t utilization_q16, int64_t building_days,
        int64_t &sat) const;
    int64_t effective_building_output_quantity_for_target(
        int32_t cell, int32_t type_id, int32_t owner_signature_id,
        int32_t good_id, int64_t base_quantity, int64_t utilization_q16,
        int64_t building_days, int64_t &sat);
    int64_t effective_production_input_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_resource_use_quantity(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_managed_resource_generation(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_household_good_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const;

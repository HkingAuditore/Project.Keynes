// Trade plan initialization, market orders, household settlement results, and goods bills.

    struct TradePlanInitState {
        TradePlanInitPhase phase = TradePlanInitPhase::IDLE;
        size_t cursor = 0;
        int32_t order_cursor = 0;
        int32_t line_cursor = 0;
        size_t active_before_prune = 0;
        size_t rotation = 0;
        int32_t component_seed = 0;
        int32_t next_component = 0;
        size_t component_queue_cursor = 0;
        std::vector<int32_t> component_queue;
        std::vector<uint64_t> inflight_keys;
        std::vector<uint64_t> retained_active_keys;
        std::vector<int64_t> rotated_inbound;

        void clear() {
            phase = TradePlanInitPhase::IDLE;
            cursor = 0;
            order_cursor = 0;
            line_cursor = 0;
            active_before_prune = 0;
            rotation = 0;
            component_seed = 0;
            next_component = 0;
            component_queue_cursor = 0;
            component_queue.clear();
            inflight_keys.clear();
            retained_active_keys.clear();
            rotated_inbound.clear();
        }
    };

    struct Order {
        int32_t local_cohort = -1;
        int32_t slot = -1;
        int32_t good = -1;
        int32_t priority = 0;
        int64_t desired_qty = 0;
        int64_t funded_qty = 0;
        int64_t filled_qty = 0;
    };

    struct BundleOrder {
        int32_t local_cohort = -1;
        int32_t slot = -1;
        int32_t need_index = -1;
        int32_t variant_index = -1;
        int32_t priority = 0;
        int64_t desired_units = 0;
        int64_t funded_units = 0;
        int64_t filled_units = 0;
        int64_t unit_price = 0;
        int64_t base_unit_price = 0;
        int64_t quoted_subsidy_per_unit = 0;
    };

    struct OwnerRetainedOutput {
        int32_t owner_slot = -1;
        int32_t good_id = -1;
        int32_t building_group = -1;
        int64_t quantity = 0;
    };

    struct BuildingInKindCredit {
        int32_t building_group = -1;
        int64_t frozen_value = 0;
    };

    struct EventLeg;
    struct CashflowEntry;

    struct CohortWelfareEntry {
        uint64_t cohort_handle = 0;
        // Mirrors of the authoritative columns, copied here so the Inspector can
        // read per-need detail and the composite from one trace payload.
        int32_t overall_satisfaction_q16 = 0;
        int32_t living_standard_level = 0;
        int32_t worst_dimension_id = -1;
        std::array<int32_t, SAT_DIM_COUNT> satisfaction_dims_q16{};
        std::vector<int32_t> need_ids;
        std::vector<int32_t> need_satisfaction_q16;
        std::vector<int32_t> need_weight_q16;
        std::vector<int32_t> need_tiers;
        std::vector<int64_t> previous_demand_per_capita_daily;
        std::vector<int64_t> wealth_demand_delta_per_capita_daily;
        std::vector<int64_t> price_demand_delta_per_capita_daily;
    };

    struct MarketResult {
        struct FoodAccessEntry {
            int32_t cell = -1;
            int64_t food_eq = 0;
        };
        bool ok = true;
        int32_t market = -1;
        std::string error;
        int64_t processed_cohorts = 0;
        int64_t processed_rules = 0;
        int64_t processed_needs = 0;
        int64_t processed_variants = 0;
        int64_t processed_components = 0;
        int64_t saturation_count = 0;
        int64_t consumed_goods = 0;
        int64_t cycle_flow_consumed = 0;
        int64_t cycle_flow_discarded = 0;
        int64_t food_access_eq = 0;
        int64_t food_access_events = 0;
        // Sparse per-cell attribution for markets that span legacy multiple
        // cells. The scalar above remains a cheap aggregate diagnostic.
        std::vector<FoodAccessEntry> food_access_by_cell;
        int64_t retained_output_consumed = 0;
        int64_t retained_output_discarded = 0;
        // Markets run on parallel tasks, so producer-support ledgers are
        // accumulated here and folded into the runtime totals serially.
        int64_t supported_output = 0;
        int64_t supported_cycle_flow_output = 0;
        int64_t supported_money = 0;
        int64_t bullion_money = 0;
        int64_t bullion_stock = 0;
        int64_t gold_accepted = 0;
        int64_t gold_money = 0;
        int64_t silver_accepted = 0;
        int64_t silver_money = 0;
        std::vector<int64_t> retained_consumed_by_good;
        std::vector<BuildingInKindCredit> building_in_kind_credits;
        int64_t owner_working_capital_reserved = 0;
        int64_t births = 0;
        int64_t deaths = 0;
        std::vector<int32_t> population_changed_cells;
        std::vector<PersonNeedState> person_needs;
        std::vector<PersonMarketAttribution> person_attributions;
        std::vector<PersonDemographyEvent> person_demography;
        // Deaths in cohorts with family members; split across membership
        // edges on the main thread when the result is merged.
        std::vector<PersonDemographyEvent> family_demography;
        int64_t closing_population = 0;
        int64_t closing_cohort_funds = 0;
        int64_t closing_goods_stock = 0;
        double formula_ms = 0.0;
        double clear_ms = 0.0;
        double fallback_ms = 0.0;
        double merchant_settle_ms = 0.0;
        double price_ms = 0.0;
        int64_t merchant_count = 0;
        int64_t merchant_repairs = 0;
        // Net-of-income-tax household retail share this market distributed to
        // its living merchants, and the merchant population it divided by.
        // Merged into the epoch metric used by the merchant post projection.
        int64_t merchant_household_retail = 0;
        int64_t merchant_population = 0;
        // Union of every price-shaping event below. Kept so existing
        // diagnostics and tests keep reading one headline number.
        std::vector<PriceCeilingObservation> price_ceiling_observations;
        int64_t price_ceiling_expansions = 0;
        int64_t price_ceiling_recoveries = 0;
        int64_t price_ceiling_blocked_rises = 0;
        int64_t price_cap_hits = 0;
        int64_t price_rate_clamp_hits = 0;
        int64_t price_numeric_floor_hits = 0;
        int64_t price_numeric_ceiling_hits = 0;
        int64_t price_min_tick_hits = 0;
        int64_t price_glut_cost_damp_hits = 0;
        int64_t small_payment_roundups = 0;
        int64_t price_rise_fade_hits = 0;
        int64_t price_headroom_damp_hits = 0;
        int64_t price_catalog_bound_hits = 0;
        int64_t price_cost_anchor_hits = 0;
        int64_t price_inactive_reversions = 0;
        int64_t revenue = 0;
        int64_t changed_prices = 0;
        uint64_t mutation_hash = 1469598103934665603ULL;
        std::vector<EventLeg> trace_legs;
        std::vector<CashflowEntry> cashflows;
        std::vector<CohortWelfareEntry> welfare_entries;
        std::vector<StructuralCommand> structural_commands;
        std::vector<int32_t> trade_active_goods;
        // Worker-local audit lanes. Worker mutation sites cannot append to the
        // shared audit vectors; the owning thread registers these during merge.
        std::vector<size_t> audit_population_lanes;
        std::vector<size_t> audit_market_lanes;
        EconomyWorkerChanges market_changes;
        int64_t allocation_growth_count = 0;
        int64_t allocation_growth_bytes = 0;
        int64_t approximation_decisions = 0;
        int64_t approximation_exact_probes = 0;
        int64_t approximation_certificate_failures = 0;
        int64_t approximation_exact_fallbacks = 0;
        int64_t approximation_frontier_candidates = 0;
        int64_t approximation_frontier_pruned = 0;
        int64_t approximation_max_certified_regret_q16 = 0;
        int64_t approximation_probe_violations = 0;
        int64_t approximation_probe_max_spend_error_q16 = 0;
        int64_t approximation_probe_max_demand_error_q16 = 0;
        std::vector<uint8_t> approximation_variant_active;

        void reset();
        int64_t capacity_bytes() const;
    };

    enum TraceMode : int32_t {
        TRACE_OFF = 0,
        TRACE_SUMMARY = 1,
        TRACE_SELECTIVE = 2,
        TRACE_FULL_DEBUG = 3,
    };

    enum CashflowSource : int32_t {
        CASHFLOW_WAGES = 1,
        CASHFLOW_OWNER_OPERATIONS = 2,
        CASHFLOW_MERCHANT_HOUSEHOLD = 3,
        CASHFLOW_MERCHANT_BUSINESS = 4,
        CASHFLOW_TRANSFER = 5,
        CASHFLOW_HOUSEHOLD_CONSUMPTION = 6,
        CASHFLOW_PRODUCTION_INPUT = 7,
        CASHFLOW_OWNER_WAGES = 8,
        CASHFLOW_CONSTRUCTION = 9,
        CASHFLOW_MERCHANT_PROCUREMENT = 10,
        CASHFLOW_OTHER = 11,
        CASHFLOW_PRODUCER_SUPPORT = 12,
        CASHFLOW_INCOME_TAX = 13,
        CASHFLOW_CONSUMPTION_TAX = 14,
        CASHFLOW_BUSINESS_TAX = 15,
        CASHFLOW_INCOME_SUBSIDY = 16,
        CASHFLOW_CONSUMPTION_SUBSIDY = 17,
        CASHFLOW_BUSINESS_SUBSIDY = 18,
        CASHFLOW_FISCAL_ESCROW = 19,
        CASHFLOW_IMPORT_TAX = 20,
        CASHFLOW_EXPORT_TAX = 21,
        CASHFLOW_IMPORT_SUBSIDY = 22,
        CASHFLOW_EXPORT_SUBSIDY = 23,
    };

    using EventKind = EconomyApi::EventKind;

    enum EventFlags : int32_t {
        EVENT_FLAG_DETAIL_PRESENT = 1 << 0,
        EVENT_FLAG_DETAIL_TRUNCATED = 1 << 1,
        EVENT_FLAG_TRADE_FOREIGN = 1 << 8,
        EVENT_FLAG_TRADE_RELIEF = 1 << 9,
        EVENT_FLAG_TRADE_IMPORT_SUBSIDY = 1 << 10,
        EVENT_FLAG_TRADE_EXPORT_SUBSIDY = 1 << 11,
        EVENT_FLAG_TRADE_IMPORT_TAX = 1 << 12,
        EVENT_FLAG_TRADE_EXPORT_TAX = 1 << 13,
    };

    enum EventField : int32_t {
        FIELD_COHORT_POPULATION = 1,
        FIELD_COHORT_FUNDS = 2,
        FIELD_COHORT_EPOCH_INCOME = 3,
        FIELD_COHORT_EPOCH_EXPENSE = 4,
        FIELD_COHORT_INCOME_EMA = 5,
        FIELD_COHORT_SATISFACTION = 6,
        FIELD_COHORT_WORST_NEED = 7,
        FIELD_COHORT_OWNER_EMPLOYED = 8,
        FIELD_COHORT_EMPLOYEE_EMPLOYED = 9,
        FIELD_COHORT_SIGNATURE = 10,
        FIELD_TREASURY_CASH = 11,
        FIELD_MARKET_STOCK = 12,
        FIELD_MARKET_PRICE = 13,
        FIELD_MARKET_DEMAND_EMA = 14,
        FIELD_MARKET_SHORTAGE = 15,
        FIELD_BUILDING_COUNT = 16,
        FIELD_BUILDING_OWNER_FILLED = 17,
        FIELD_BUILDING_EMPLOYEE_FILLED = 18,
        FIELD_BUILDING_CAPACITY = 19,
        FIELD_BUILDING_INPUT = 20,
        FIELD_BUILDING_OUTPUT = 21,
        FIELD_BUILDING_SOLD = 22,
        FIELD_BUILDING_DISCARDED = 23,
        FIELD_BUILDING_RESOURCE = 24,
        FIELD_BUILDING_RESOURCE_GENERATED = 25,
        FIELD_BUILDING_REVENUE = 26,
        FIELD_BUILDING_INPUT_COST = 27,
        FIELD_BUILDING_WAGES_PAID = 28,
        FIELD_RESOURCE_DELTA = 29,
        FIELD_COHORT_DEMOGRAPHY_RESIDUAL = 30,
        FIELD_BUILDING_WAGES_DUE = 31,
        FIELD_BUILDING_EXPECTED_REVENUE = 32,
        FIELD_BUILDING_OPERATING_COST = 33,
        FIELD_BUILDING_MARGIN_GAP = 34,
        FIELD_BUILDING_PLANNED_UTILIZATION = 35,
        FIELD_BUILDING_BASE_WAGES_PAID = 36,
        FIELD_BUILDING_BASE_WAGES_DUE = 37,
        FIELD_BUILDING_BONUS_PAID = 38,
        FIELD_BUILDING_BONUS_DUE = 39,
        FIELD_BUILDING_WAGE_SUSPENDED = 40,
        FIELD_TRADE_QUANTITY = 41,
        FIELD_TRADE_BASE_VALUE = 42,
        FIELD_TRADE_RETAIL_VALUE = 43,
        FIELD_TRADE_IMPORT_TRANSFER = 44,
        FIELD_TRADE_EXPORT_TRANSFER = 45,
        FIELD_TRADE_TRANSACTION_TRANSFER = 46,
    };

    enum EventSubjectKind : int32_t {
        SUBJECT_NONE = 0,
        SUBJECT_COHORT = 1,
        SUBJECT_MARKET = 2,
        SUBJECT_BUILDING_GROUP = 3,
        SUBJECT_COMMAND = 4,
        SUBJECT_TREASURY = 5,
        SUBJECT_RESOURCE = 6,
        SUBJECT_TRADE_ORDER = 7,
        SUBJECT_FAMILY_BRANCH = 8,
    };


    // Ephemeral bill: sum exact q*p/GOODS_SCALE, then round once. No save state.
    friend struct EconomyPricingTests;
    struct GoodsBill {
        int64_t charged = 0;
        int32_t remainder = 0;
        int64_t add(int64_t quantity, int64_t price, int64_t &sat);
        int64_t total(int64_t &sat) const;
    };

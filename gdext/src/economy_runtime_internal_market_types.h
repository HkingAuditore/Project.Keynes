// Included inside NativeEconomyRuntime; preserve declaration order and access.
    enum InvestmentRejection : int32_t {
        INVESTMENT_REJECTION_NONE = 0,
        INVESTMENT_REJECTION_PENDING_CONSTRUCTION = 1,
        INVESTMENT_REJECTION_SUSPENDED_CAPACITY = 2,
        INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY = 3,
        INVESTMENT_REJECTION_INSTALLED_CAPACITY_SUFFICIENT = 4,
        INVESTMENT_REJECTION_OWNER_LIVELIHOOD = 5,
        INVESTMENT_REJECTION_SELL_THROUGH = 6,
        INVESTMENT_REJECTION_DISCARD = 7,
        INVESTMENT_REJECTION_INPUT_CHAIN = 8,
        INVESTMENT_REJECTION_TARGET_MARGIN = 9,
        INVESTMENT_REJECTION_PAYBACK = 10,
        INVESTMENT_REJECTION_SPONSOR_CAPITAL = 11,
        INVESTMENT_REJECTION_MATERIALS = 12,
        INVESTMENT_REJECTION_RESOURCE = 13,
        INVESTMENT_REJECTION_PROBABILITY = 14,
        INVESTMENT_REJECTION_MARKET_SIGNAL = 15,
        INVESTMENT_REJECTION_GROWTH_LIMIT = 16,
        INVESTMENT_REJECTION_UNSUPPORTED_KIND = 17,
        INVESTMENT_REJECTION_NO_COST_ADVANTAGE = 18,
        // State-owned building types are never reviewed by private capital.
        INVESTMENT_REJECTION_STATE_OWNED = 19,
    };

    // One quote type is shared by employment, investment and diagnostics.
    // Keep the historical OwnerOpportunityQuote name as the storage type so
    // existing employment callers do not create a second economic path.
    using EconomicOpportunityQuote = OwnerOpportunityQuote;

    enum InvestmentRequestReason : int32_t {
        INVESTMENT_REQUEST_ORDINARY_EXPANSION = 0,
        INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP = 1,
        INVESTMENT_REQUEST_STARTUP_DEMAND = 2,
        INVESTMENT_REQUEST_RESEARCH_DEMAND = 3,
        INVESTMENT_REQUEST_RECOVERY = 4,
    };

    struct InvestmentRequestContext {
        int32_t reason = INVESTMENT_REQUEST_ORDINARY_EXPANSION;
        int64_t demand_pressure = 0;
        bool allow_credit = true;
        bool allow_reallocation = false;
        int64_t max_batch_count = 0;
    };

    // One proposed investment, regardless of whether it came from startup,
    // research construction, recovery or ordinary expansion.  The plan owns
    // the physical requirements; the quote above owns the economics.
    struct InvestmentCandidatePlan {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        InvestmentRequestContext request;
        int32_t rejection_reason = INVESTMENT_REJECTION_NONE;
        int64_t utilization_q16 = 0;
        int64_t construction_cost = 0;
        int64_t required_capital = 0;
        // Funding terms are filled after sponsor/credit discovery. They are
        // kept on the same candidate plan consumed by allocation and commit.
        int64_t funding_capital = 0;
        int64_t merchant_credit = 0;
        int64_t payback_days = 0;
        int64_t target_profit_per_day = 0;
        int64_t target_return_on_capital_q16 = 0;
        int64_t planned_output_quantity = 0;
        int64_t employee_slots = 0;
        int64_t owner_slots = 0;
        int64_t max_batch_count = 0;
        int64_t allocated_count = 0;
        int32_t sponsor = -1;
        uint64_t sponsor_family_handle = 0;
        bool uses_merchant_credit = false;
        std::vector<int32_t> input_good_ids;
        std::vector<int64_t> input_quantities;
        std::vector<int32_t> material_good_ids;
        std::vector<int64_t> material_quantities;
        EconomicOpportunityQuote quote;
    };

    // Startup-producer selection reads frozen catalog/epoch lanes plus market
    // price, stock and offered supply. A scope may only span work that changes
    // none of those for its cell. The key carries the cover recursion depth,
    // because nesting is truncated at a fixed depth.
    struct StartupProducerMemoState {
        const NativeEconomyRuntime *owner = nullptr;
        int32_t depth = 0;
        uint64_t hits = 0, misses = 0;
        int32_t fast_cell = -1;
        uint32_t fast_gen = 1;
        std::vector<uint32_t> producer_stamp;
        std::vector<int32_t> producer_type;
        std::vector<InvestmentCandidatePlan> producer_plan;
        std::vector<uint32_t> cover_stamp;
        std::vector<int64_t> cover_value;
        std::vector<int64_t> cover_sat_delta;
        std::vector<uint32_t> construction_stamp;
        std::vector<int32_t> construction_good;
        std::vector<int64_t> construction_physical;
        std::vector<uint32_t> input_stamp;
        std::vector<int32_t> input_good;
        std::vector<int64_t> input_physical;
        std::vector<uint32_t> type_cond_stamp;
        std::vector<uint8_t> type_cond_ok;
        std::vector<uint32_t> type_climate_stamp;
        std::vector<int64_t> type_climate_q16;
        std::vector<uint32_t> type_wage_stamp;
        std::vector<int64_t> type_wage_cost;
        std::vector<int64_t> type_employee_slots;
        std::vector<uint32_t> type_construct_stamp;
        std::vector<int64_t> type_construct_cost;
        std::vector<int32_t> type_construct_count;
        std::vector<int32_t> type_construct_goods;
        std::vector<int64_t> type_construct_physical;

        void ensure_cell(int32_t cell, size_t good_count, size_t bom_count,
                         size_t input_count, size_t type_count) {
            const size_t prod_slots = good_count * 4u;
            const size_t bom_slots = bom_count * 4u;
            if (producer_stamp.size() < prod_slots) {
                producer_stamp.assign(prod_slots, 0);
                producer_type.resize(prod_slots, -1);
                producer_plan.resize(prod_slots);
                cover_stamp.assign(prod_slots, 0);
                cover_value.resize(prod_slots, 0);
                cover_sat_delta.resize(prod_slots, 0);
            }
            if (construction_stamp.size() < bom_slots) {
                construction_stamp.assign(bom_slots, 0);
                construction_good.resize(bom_slots, -1);
                construction_physical.resize(bom_slots, 0);
            }
            if (input_stamp.size() < input_count) {
                input_stamp.assign(input_count, 0);
                input_good.resize(input_count, -1);
                input_physical.resize(input_count, 0);
            }
            if (type_cond_stamp.size() < type_count) {
                type_cond_stamp.assign(type_count, 0);
                type_cond_ok.assign(type_count, 0);
                type_climate_stamp.assign(type_count, 0);
                type_climate_q16.assign(type_count, 0);
                type_wage_stamp.assign(type_count, 0);
                type_wage_cost.assign(type_count, 0);
                type_employee_slots.assign(type_count, 0);
                type_construct_stamp.assign(type_count, 0);
                type_construct_cost.assign(type_count, 0);
                type_construct_count.assign(type_count, 0);
                type_construct_goods.assign(static_cast<size_t>(type_count) * 4u, -1);
                type_construct_physical.assign(
                    static_cast<size_t>(type_count) * 4u, 0);
            }
            if (fast_cell != cell) {
                fast_cell = cell;
                if (++fast_gen == 0) {
                    std::fill(producer_stamp.begin(), producer_stamp.end(), 0);
                    std::fill(cover_stamp.begin(), cover_stamp.end(), 0);
                    std::fill(construction_stamp.begin(), construction_stamp.end(), 0);
                    std::fill(input_stamp.begin(), input_stamp.end(), 0);
                    std::fill(type_cond_stamp.begin(), type_cond_stamp.end(), 0);
                    std::fill(type_climate_stamp.begin(), type_climate_stamp.end(), 0);
                    std::fill(type_wage_stamp.begin(), type_wage_stamp.end(), 0);
                    std::fill(type_construct_stamp.begin(), type_construct_stamp.end(), 0);
                    fast_gen = 1;
                }
            }
        }
        void invalidate() {
            fast_cell = -1;
            if (++fast_gen == 0) {
                std::fill(producer_stamp.begin(), producer_stamp.end(), 0);
                std::fill(cover_stamp.begin(), cover_stamp.end(), 0);
                std::fill(construction_stamp.begin(), construction_stamp.end(), 0);
                fast_gen = 1;
            }
        }
    };
    static StartupProducerMemoState &startup_producer_memo_state() {
        thread_local StartupProducerMemoState state;
        return state;
    }
    static int32_t &startup_cover_depth() {
        thread_local int32_t depth = 0;
        return depth;
    }
    struct StartupProducerMemoScope {
        const NativeEconomyRuntime &runtime;
        bool active = false;
        explicit StartupProducerMemoScope(const NativeEconomyRuntime &owner);
        ~StartupProducerMemoScope();
        StartupProducerMemoScope(const StartupProducerMemoScope &) = delete;
        StartupProducerMemoScope &operator=(const StartupProducerMemoScope &) = delete;
    };
    static bool same_startup_plan(const InvestmentCandidatePlan &a,
                                  const InvestmentCandidatePlan &b);

    struct InvestmentDiagnostic {
        int32_t type_id = -1;
        int32_t rejection_reason = INVESTMENT_REJECTION_NONE;
        int64_t shortage_q16 = 0;
        int64_t utilization_q16 = 0;
        int32_t driver_good_id = -1;
        int64_t driver_pressure_q16 = 0;
        int64_t driver_utilization_q16 = 0;
        int64_t driver_sellable = 0;
        int64_t driver_merchant_sold = 0;
        int64_t driver_sell_through_q16 = 0;
        int64_t driver_discard_q16 = 0;
        int64_t stealable = 0;
        int64_t challenger_unit_cost = 0;
        int64_t incumbent_unit_cost = 0;
        int64_t score_q16 = 0;
        int64_t payback_days = 0;
        int64_t required_capital = 0;
        int64_t projected_profit_per_day = 0;
        int64_t return_on_capital_q16 = 0;
        int64_t cost_advantage_q16 = 0;
        int64_t monetary_quota_initial = 0;
        int64_t monetary_quota_daily = 0;
        int64_t monetary_units = 0;
        int64_t monetary_candidate_slots = 0;
        int64_t monetary_request_money_per_day = 0;
        int64_t monetary_expected_revenue_per_day = 0;
        int32_t failed_material_group = -1;
        std::vector<int32_t> selected_material_good_ids;
        std::vector<int64_t> selected_material_quantities;
        EconomicOpportunityQuote opportunity_quote;
        InvestmentCandidatePlan candidate_plan;
    };

    // One value per `continue`/skip site on the unemployed-hiring path in
    // run_building_employment_cell. A vacancy that stays open while an
    // unemployed pool exists must always carry one of these.
    enum EmploymentRejection : int32_t {
        EMPLOYMENT_REJECTION_NONE = 0,
        EMPLOYMENT_REJECTION_POOL_MISSING = 1,
        EMPLOYMENT_REJECTION_POOL_EMPTY = 2,
        EMPLOYMENT_REJECTION_SOURCE_SIGNATURE = 3,
        EMPLOYMENT_REJECTION_TARGET_SIGNATURE = 4,
        EMPLOYMENT_REJECTION_TARGET_DISPOSABLE = 5,
        EMPLOYMENT_REJECTION_SURVIVAL_FLOOR = 6,
        EMPLOYMENT_REJECTION_HURDLE = 7,
        EMPLOYMENT_REJECTION_NO_ALLOCATION = 8,
        EMPLOYMENT_REJECTION_ENTRY_SAVINGS = 9,
        EMPLOYMENT_REJECTION_SIGNATURE_SELF = 10,
        EMPLOYMENT_REJECTION_PROFESSION_UNAVAILABLE = 11,
        EMPLOYMENT_REJECTION_ZERO_TAKE = 12,
    };

    struct EmploymentDiagnostic {
        int32_t group_index = -1;
        int32_t type_id = -1;
        // -1 marks an owner vacancy; otherwise the employee role index.
        int32_t role = -1;
        int32_t target_signature = -1;
        int32_t profession_id = -1;
        int32_t source_ethnicity = -1;
        int32_t pool_slot = -1;
        int32_t pool_signature = -1;
        int64_t pool_population = 0;
        int64_t vacancy = 0;
        int64_t target_disposable = 0;
        int64_t source_disposable = 0;
        int64_t improvement_q16 = 0;
        int64_t hurdle_q16 = 0;
        int64_t weight_q16 = 0;
        int64_t budget = 0;
        int64_t allocation = 0;
        int64_t take = 0;
        bool eligible = false;
        int32_t rejection_reason = EMPLOYMENT_REJECTION_NONE;
        // Owner-slot clamp chain for the group behind this candidate. A vacancy
        // can exist either because the group never had owners or because a
        // clamp shed incumbents earlier in the same pass; only the chain tells
        // the two apart.
        int64_t owner_target = 0;
        int64_t filled_before_clamp = 0;
        int64_t filled_after_profession_clamp = 0;
        int64_t filled_after_family_clamp = 0;
        int64_t family_owned = 0;
        int64_t family_member_people = 0;
        int64_t anonymous_people = 0;
        int64_t owner_cohort_population = 0;
        int64_t shed_surplus = 0;
    };

    // Per-group output of clamp_family_owner_employment_for_cell, published
    // only for the inspector cell so the employment diagnostics can attribute
    // a lost owner seat to the family overlay rather than the profession clamp.
    struct FamilyOwnerClampTrace {
        int32_t group_index = -1;
        int64_t family_owned = 0;
        int64_t family_member_people = 0;
        int64_t anonymous_people = 0;
        int64_t owner_cohort_population = 0;
        int64_t filled_before = 0;
        int64_t filled_after = 0;
    };

    struct OutputInvestmentSignal {
        int32_t good_id = -1;
        int64_t pressure_q16 = 0;
        int64_t utilization_q16 = 0;
        int64_t deficit = 0;
        int64_t sellable = 0;
        int64_t merchant_sold = 0;
        int64_t discarded = 0;
        int64_t sell_through_q16 = 0;
        int64_t discard_q16 = 0;
        int64_t driver_strength_q16 = 0;
        // Forecast cash value used to choose a multi-output driver. This is a
        // revenue signal, not an independent shortage or inventory preference.
        int64_t expected_cash_value = 0;
        int64_t nameplate_output = 0;
        int64_t demand = 0;
        int64_t startup_demand = 0;
        int64_t remote_startup_demand = 0;
        bool startup_incremental = false;
    };

    // Scratch lane used while evaluating one cell's investment review. The
    // authoritative history lives in InvestmentIncumbentRecord after publish.
    struct InvestmentIncumbentLane {
        int32_t good_id = -1;
        int32_t type_id = -1;
        int64_t unit_cost = 0;
        int64_t daily_offered = 0;
        int64_t stealable_capacity = 0;
        int64_t owner_fill = 0;
        int64_t employee_fill = 0;
    };

    // quote → reserve → commit → publish transaction records. Quote stages
    // freeze selections; commit must not re-pick inputs, prices, or owners.
    enum class EconomyReservationState : uint8_t {
        EMPTY = 0,
        QUOTED = 1,
        RESERVED = 2,
        COMMITTED = 3,
        ROLLED_BACK = 4,
    };

    struct ProductionQuote {
        int32_t cell = -1;
        int32_t group_index = -1;
        int32_t type_id = -1;
        int64_t target_capacity_q16 = 0;
        int64_t real_business_demand = 0;
        int64_t shadow_derived_demand = 0;
        int64_t selected_input_good = -1;
        int64_t selected_input_quantity = 0;
        int64_t resource_demand = 0;
        int64_t owner_cash = 0;
        int64_t merchant_credit = 0;
        int64_t debt_service = 0;
        int64_t minimum_production_floor_q16 = 0;
        uint8_t active_unfunded = 0;
    };

    struct EconomyReservation {
        int64_t request_id = 0;
        int64_t generation = 0;
        int32_t cell = -1;
        int32_t group_index = -1;
        int64_t market_stock_delta = 0;
        int64_t owner_cash_delta = 0;
        int64_t merchant_cash_delta = 0;
        int64_t credit_principal = 0;
        int64_t credit_premium = 0;
        int64_t wages = 0;
        int64_t livelihood = 0;
        int64_t output_sale_slot = -1;
        EconomyReservationState state = EconomyReservationState::EMPTY;
    };

    struct EmploymentMoveReservation {
        int32_t cell = -1;
        int32_t source_handle = -1;
        int32_t target_handle = -1;
        int32_t source_group = -1;
        int32_t target_group = -1;
        int32_t profession = -1;
        int32_t role = -1; // 0=owner, 1=employee, 2=employee_to_owner.
        int64_t quantity = 0;
        int64_t expected_income = 0;
        int64_t hurdle_q16 = 0;
        int64_t cooldown_until_day = 0;
        EconomyReservationState state = EconomyReservationState::EMPTY;
        uint8_t last_merchant_protected = 0;
    };

    struct InvestmentIncumbentRecord {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t output_good = -1;
        int64_t settled_unit_cost = 0;
        int64_t daily_offered_capacity = 0;
        int64_t owner_fill = 0;
        int64_t employee_fill = 0;
        int64_t settled_day = -1;
        int64_t generation = 0;
        int64_t stealable_capacity = 0;
    };

    struct ActiveEvidenceRecord {
        int32_t domain = -1;
        int64_t day = -1;
        int64_t generation = 0;
        uint64_t input_hash = 0;
        uint64_t state_hash = 0;
        uint64_t audit_hash = 0;
        int64_t real_work_units = 0;
        std::string failure_reason;
    };

    struct OwnerMobilityCooldown {
        int32_t cell = -1;
        int32_t source_group = -1;
        int32_t target_group = -1;
        int64_t until_day = -1;
    };

    struct StartupRemoteLane {
        int32_t country = -1;
        int32_t component = -1;
        int32_t good_id = -1;
        int64_t remaining_daily = 0;
    };

    struct StartupRemoteGroup {
        int32_t country = -1;
        int32_t component = -1;
        int32_t lane_begin = 0;
        int32_t lane_end = 0;
    };

    struct StartupInboundLane {
        uint64_t cell_good_key = 0;
        int64_t quantity = 0;
    };

    struct StartupRemoteAccumulator {
        int32_t country = -1;
        int32_t component = -1;
        int32_t good_id = -1;
        int64_t demand = 0;
        int64_t available = 0;
    };

    using PopulationStore = RuntimeEconomyPopulationStore;

    struct SettlementChange {
        int32_t cell = -1;
        uint8_t tier = 0;
        uint8_t name_active = 0;
    };

    struct SettlementRevision {
        int64_t revision = 0;
        std::vector<SettlementChange> changes;
    };

    struct SettlementStore {
        EconomyOwnedColumn<uint8_t> tier{{{17, 1}, "SettlementStore.tier", EconomyFieldEncoding::U8, 1}};
        EconomyOwnedColumn<uint8_t> name_active{{{17, 2}, "SettlementStore.name_active", EconomyFieldEncoding::U8, 1}};
        EconomyOwnedColumn<uint8_t> name_forced{{{17, 3}, "SettlementStore.name_forced", EconomyFieldEncoding::U8, 1}};
        EconomyOwnedColumn<uint32_t> prosperity_generation{{{17, 4}, "SettlementStore.prosperity_generation", EconomyFieldEncoding::U32, 4}};
        EconomyOwnedColumn<uint32_t> name_roll_generation{{{17, 5}, "SettlementStore.name_roll_generation", EconomyFieldEncoding::U32, 4}};
        EconomyOwnedColumn<int32_t> prefix{{{17, 6}, "SettlementStore.prefix", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> root{{{17, 7}, "SettlementStore.root", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> suffix{{{17, 8}, "SettlementStore.suffix", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<uint32_t> disambiguator{{{17, 9}, "SettlementStore.disambiguator", EconomyFieldEncoding::U32, 4}};
        std::unordered_map<std::string, int32_t> active_names;
        std::deque<SettlementRevision> revisions;
        int64_t revision = 0;

        void clear(int32_t cells) {
            tier.assign(cells, 0);
            name_active.assign(cells, 0);
            name_forced.assign(cells, 0);
            prosperity_generation.assign(cells, 0);
            name_roll_generation.assign(cells, 0);
            prefix.assign(cells, -1);
            root.assign(cells, -1);
            suffix.assign(cells, -1);
            disambiguator.assign(cells, 0);
            active_names.clear();
            revisions.clear();
            revision = 0;
        }
    };

    using PriceCeilingState = RuntimeEconomyPriceCeilingState;
    struct PriceCeilingObservation {
        int32_t market = -1, good = -1, price = 1, base = 1, days = 0;
        int64_t requested = 0, unfilled = 0;
    };
    using MarketStore = RuntimeEconomyMarketStore;
    using ResourceStore = RuntimeEconomyResourceStore;

    struct MarketSignalStore {
        EconomyOwnedColumn<int32_t> cell_offsets{{{18, 1}, "MarketSignalStore.cell_offsets", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> good_ids{{{18, 2}, "MarketSignalStore.good_ids", EconomyFieldEncoding::I32, 4}};
        // Optional O(1) (cell, good) -> sparse signal index. Rebuilt from the
        // authoritative ascending CSR and excluded from save/hash state.
        std::vector<int32_t> dense_index;
        EconomyOwnedColumn<int64_t> business_demand_ema{{{18, 3}, "MarketSignalStore.business_demand_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> offered_supply_ema{{{18, 4}, "MarketSignalStore.offered_supply_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> realized_withdrawal_ema{{{18, 5}, "MarketSignalStore.realized_withdrawal_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int32_t> cost_anchor_price{{{18, 6}, "MarketSignalStore.cost_anchor_price", EconomyFieldEncoding::I32, 4}};

        void clear(int32_t cells) {
            cell_offsets.assign(static_cast<size_t>(std::max(0, cells)) + 1, 0);
            good_ids.clear();
            dense_index.clear();
            business_demand_ema.clear();
            offered_supply_ema.clear();
            realized_withdrawal_ema.clear();
            cost_anchor_price.clear();
        }
    };

    struct WaterPortalGraph {
        std::vector<int32_t> cell_portal;
        std::vector<int32_t> portal_cells;
        std::vector<int32_t> offsets;
        std::vector<int32_t> targets;
        std::vector<int32_t> costs;
        std::vector<int32_t> reverse_offsets;
        std::vector<int32_t> reverse_targets;
        std::vector<int32_t> reverse_costs;

        void clear() {
            cell_portal.clear();
            portal_cells.clear();
            offsets.clear();
            targets.clear();
            costs.clear();
            reverse_offsets.clear();
            reverse_targets.clear();
            reverse_costs.clear();
        }
    };

    struct TradeTopologyStore {
        std::vector<int32_t> neighbors;
        std::vector<uint8_t> passable;
        std::vector<int32_t> enter_cost;
        std::vector<int32_t> edge_cost;
        std::vector<uint8_t> canal_edge_mask;
        std::vector<float> canal_water;
        std::vector<int32_t> component;
        std::vector<uint8_t> water_class;
        std::vector<uint8_t> has_river;
        WaterPortalGraph water_portals[WATER_PORTAL_GRAPH_COUNT];
        std::vector<int32_t> component_layers;
        uint64_t topology_generation = 0;
        uint64_t topology_hash = 0;
        // Hash of the frozen cell->country ownership map used to build
        // components. Country cash/treasury generations must not invalidate
        // routing when borders did not change.
        uint64_t component_country_hash = 0;
        bool ready = false;

        void clear() {
            neighbors.clear();
            passable.clear();
            enter_cost.clear();
            edge_cost.clear();
            canal_edge_mask.clear();
            canal_water.clear();
            component.clear();
            water_class.clear();
            has_river.clear();
            for (WaterPortalGraph &graph : water_portals) graph.clear();
            component_layers.clear();
            topology_generation = 0;
            topology_hash = 0;
            component_country_hash = 0;
            ready = false;
        }
    };

    struct TradeSignal {
        int32_t cell = -1;
        int32_t good = -1;
        int32_t country = -1;
        int32_t price = 0;
        int64_t quantity = 0;
        int32_t age_days = 0;
        int32_t response_priority = 0;
    };

    struct TradeCandidate {
        int32_t source = -1;
        int32_t destination = -1;
        int32_t good = -1;
        int32_t country = -1;
        // `country` is retained as the source-country compatibility field.
        int32_t source_country = -1;
        int32_t destination_country = -1;
        uint64_t source_country_handle = 0;
        uint64_t destination_country_handle = 0;
        int32_t route_cost = 0;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        int64_t quantity = 0;
        int64_t expected_profit = 0;
        int64_t base_value = 0;
        int64_t retail_value = 0;
        int64_t import_transfer = 0;
        int64_t export_transfer = 0;
        int64_t transaction_transfer = 0;
        int64_t capacity_work = 0;
        int64_t density_q16 = 0;
        int32_t signal_age_days = 0;
        int32_t response_priority = 0;
        uint32_t source_price_stock_generation = 0;
        uint32_t destination_price_stock_generation = 0;
        int64_t planned_day = -1;
        uint64_t topology_generation = 0;
        uint64_t country_topology_hash = 0;
        uint8_t flags = 0;
    };

    enum TradeLineFlags : uint8_t {
        TRADE_LINE_FOREIGN = 1U << 0,
        TRADE_LINE_RELIEF = 1U << 1,
        TRADE_LINE_IMPORT_SUBSIDY = 1U << 2,
        TRADE_LINE_EXPORT_SUBSIDY = 1U << 3,
        TRADE_LINE_IMPORT_TAX = 1U << 4,
        TRADE_LINE_EXPORT_TAX = 1U << 5,
    };

    struct TradeQuote {
        int64_t base = 0;
        int64_t retail = 0;
        int64_t import_transfer = 0;
        int64_t export_transfer = 0;
        int64_t transaction_transfer = 0;
        int64_t importer_outlay = 0;
        int64_t exporter_receipt = 0;
        int64_t importer_profit = 0;
        int64_t combined_profit = 0;
        int64_t margin_q16 = 0;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        bool foreign = false;
        bool relief = false;
    };

    struct TradePlanStore {
        enum Phase : int32_t { IDLE = 0, SCAN = 1, ROUTE = 2 };
        int32_t phase = IDLE;
        int64_t scan_cursor = 0;
        int32_t route_cursor = 0;
        int64_t scan_total = 0;
        std::vector<int32_t> scan_cells;
        std::vector<int32_t> scan_goods;
        std::vector<int64_t> scan_inbound;
        uint64_t country_topology_hash = 0;
        uint64_t topology_generation = 0;
        std::vector<TradeSignal> sources;
        std::vector<TradeSignal> destinations;
        std::vector<TradeCandidate> working_candidates;
        std::vector<TradeCandidate> ready_candidates;
        // Rebuildable one-batch retry queue for nominally viable routes that
        // emitted a tariff subsidy intent. It is deliberately not persisted or
        // hashed; dispatch revalidates every endpoint, price and resource bound.
        std::vector<TradeCandidate> deferred_subsidy_candidates;
        std::vector<int64_t> distance;
        std::vector<uint32_t> distance_stamp;
        std::vector<int32_t> target_signal;
        std::vector<uint32_t> target_stamp;
        std::vector<std::pair<int64_t, int32_t>> heap;
        uint32_t search_stamp = 0;
        std::vector<uint64_t> route_cache_keys;
        std::vector<int32_t> route_cache_costs;
        uint64_t route_cache_country_topology_hash = 0;
        uint64_t route_cache_topology_generation = 0;
        bool route_search_active = false;
        int32_t route_search_source = -1;
        int32_t route_search_accepted = 0;
        int32_t route_search_pending_targets = 0;
        int32_t route_search_expansions = 0;
        int64_t completed_scans = 0;

        void clear_transient() {
            phase = IDLE;
            scan_cursor = 0;
            route_cursor = 0;
            scan_total = 0;
            scan_cells.clear();
            scan_goods.clear();
            scan_inbound.clear();
            sources.clear();
            destinations.clear();
            working_candidates.clear();
            ready_candidates.clear();
            deferred_subsidy_candidates.clear();
            distance.clear();
            distance_stamp.clear();
            target_signal.clear();
            target_stamp.clear();
            heap.clear();
            route_cache_keys.clear();
            route_cache_costs.clear();
            route_cache_country_topology_hash = 0;
            route_cache_topology_generation = 0;
            route_search_active = false;
            route_search_source = -1;
            route_search_accepted = 0;
            route_search_pending_targets = 0;
            route_search_expansions = 0;
            search_stamp = 0;
            completed_scans = 0;
            country_topology_hash = 0;
            topology_generation = 0;
        }
    };

    // Sole live trade/family storage accessors (see sync/flush helpers above).
    // A+Y N3/N4: these alias RuntimeEconomyOwnedState while a formula state is
    // bound; `_trade_orders_local` / `_families_local` are the unbound fallback.
    TradeOrderStore &trade_orders_store() noexcept {
        return _formula_owned != nullptr ? _formula_owned->live_trade_orders
                                         : _trade_orders_local;
    }
    const TradeOrderStore &trade_orders_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->live_trade_orders
                                         : _trade_orders_local;
    }
    FamilyStore &families_store() noexcept {
        return _formula_owned != nullptr ? _formula_owned->live_families
                                         : _families_local;
    }
    const FamilyStore &families_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->live_families
                                         : _families_local;
    }

    // A+Y N5: the notable-family side tables follow the same rule. Every
    // authoritative person/membership/ownership/expedition/influence/trait/
    // need row lives on RuntimeEconomyOwnedState while a formula state is
    // bound; the `_*_local` members are the unbound fallback only.
    //
    // Derived CSR rebuild caches (_family_member_offsets,
    // _person_family_offsets, _person_need_offsets, _family_cell_offsets,
    // _family_expedition_target_index, _family_expedition_due_heap, ...) are
    // deliberately NOT moved: they are recomputed from the tables below at
    // FAMILY_COMMIT / PERSON_COMMIT and after a structural restore, so they
    // carry no authority and stay NER-local across bind/unbind.
#define PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(type, name, owned, local)       \
    type &name() noexcept {                                                   \
        return _formula_owned != nullptr ? _formula_owned->owned : local;     \
    }                                                                         \
    const type &name() const noexcept {                                       \
        return _formula_owned != nullptr ? _formula_owned->owned : local;     \
    }

    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(NotablePersonStore, persons_store,
                                          live_persons, _persons_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyMembershipEdge>,
                                          family_memberships, live_memberships,
                                          _family_memberships_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyBuildingOwnership>,
                                          family_ownerships, live_ownerships,
                                          _family_ownerships_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(FamilyExpeditionStore,
                                          family_expeditions_store,
                                          live_expeditions,
                                          _family_expeditions_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyOwnedColumn<int32_t>,
                                          family_expedition_route_cells,
                                          live_expedition_route_cells,
                                          _family_expedition_route_cells_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyOwnedColumn<int32_t>,
                                          family_expedition_route_costs,
                                          live_expedition_route_costs,
                                          _family_expedition_route_costs_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyExpeditionPayload>,
                                          family_expedition_payloads,
                                          live_expedition_payloads,
                                          _family_expedition_payloads_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyOwnedColumn<uint64_t>,
                                          family_expedition_person_handles,
                                          live_expedition_person_handles,
                                          _family_expedition_person_handles_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyExpeditionCargoLine>,
                                          family_expedition_cargo,
                                          live_expedition_cargo,
                                          _family_expedition_cargo_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(
        EconomyTrackedRecords<FamilyExpeditionKitBuilding>,
        family_expedition_kit_buildings, live_expedition_kit_buildings,
        _family_expedition_kit_buildings_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(
        EconomyOwnedColumn<int32_t>, family_expedition_missing_good_ids,
        live_expedition_missing_good_ids,
        _family_expedition_missing_good_ids_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(
        EconomyOwnedColumn<int64_t>, family_expedition_missing_good_quantities,
        live_expedition_missing_good_quantities,
        _family_expedition_missing_good_quantities_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(FamilyCellInfluenceStore,
                                          family_influences, live_influences,
                                          _family_influences_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyTraitRoll>,
                                          family_trait_rolls, live_traits,
                                          _family_traits_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<PersonNeedState>,
                                          person_needs, live_person_needs,
                                          _person_needs_local)

#undef PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR

    struct TradeFlowSignalStore {
        EconomyOwnedColumn<int32_t> cells{{{20, 1}, "TradeFlowSignalStore.cells", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> goods{{{20, 2}, "TradeFlowSignalStore.goods", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int64_t> import_ema{{{20, 3}, "TradeFlowSignalStore.import_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_ema{{{20, 4}, "TradeFlowSignalStore.export_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> period_import{{{20, 5}, "TradeFlowSignalStore.period_import", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> period_export{{{20, 6}, "TradeFlowSignalStore.period_export", EconomyFieldEncoding::I64, 8}};

        void clear() {
            cells.clear(); goods.clear(); import_ema.clear(); export_ema.clear();
            period_import.clear(); period_export.clear();
        }
    };

    struct CountryGoodTradeAggregateStore {
        EconomyOwnedColumn<int32_t> countries{{{21, 1}, "CountryGoodTradeAggregateStore.countries", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> goods{{{21, 2}, "CountryGoodTradeAggregateStore.goods", EconomyFieldEncoding::I32, 4}};
        // Cumulative authority.
        EconomyOwnedColumn<int64_t> import_quantity{{{21, 3}, "CountryGoodTradeAggregateStore.import_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_quantity{{{21, 4}, "CountryGoodTradeAggregateStore.export_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> import_base{{{21, 5}, "CountryGoodTradeAggregateStore.import_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_base{{{21, 6}, "CountryGoodTradeAggregateStore.export_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> import_tariff{{{21, 7}, "CountryGoodTradeAggregateStore.import_tariff", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_tariff{{{21, 8}, "CountryGoodTradeAggregateStore.export_tariff", EconomyFieldEncoding::I64, 8}};
        // Latest touched epoch. Query treats rows from an older epoch as a
        // lazy-zero previous batch while retaining the cumulative columns.
        EconomyOwnedColumn<int64_t> batch_epoch{{{21, 9}, "CountryGoodTradeAggregateStore.batch_epoch", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_quantity{{{21, 10}, "CountryGoodTradeAggregateStore.batch_import_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_quantity{{{21, 11}, "CountryGoodTradeAggregateStore.batch_export_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_base{{{21, 12}, "CountryGoodTradeAggregateStore.batch_import_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_base{{{21, 13}, "CountryGoodTradeAggregateStore.batch_export_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_tariff{{{21, 14}, "CountryGoodTradeAggregateStore.batch_import_tariff", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_tariff{{{21, 15}, "CountryGoodTradeAggregateStore.batch_export_tariff", EconomyFieldEncoding::I64, 8}};
        void clear() {
            countries.clear(); goods.clear(); import_quantity.clear();
            export_quantity.clear(); import_base.clear(); export_base.clear();
            import_tariff.clear(); export_tariff.clear();
            batch_epoch.clear(); batch_import_quantity.clear();
            batch_export_quantity.clear(); batch_import_base.clear();
            batch_export_base.clear(); batch_import_tariff.clear();
            batch_export_tariff.clear();
        }
    };

    struct CountryPartnerTradeAggregateStore {
        EconomyOwnedColumn<int32_t> countries{{{22, 1}, "CountryPartnerTradeAggregateStore.countries", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> partners{{{22, 2}, "CountryPartnerTradeAggregateStore.partners", EconomyFieldEncoding::I32, 4}};
        // Cumulative authority.
        EconomyOwnedColumn<int64_t> import_quantity{{{22, 3}, "CountryPartnerTradeAggregateStore.import_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_quantity{{{22, 4}, "CountryPartnerTradeAggregateStore.export_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> import_base{{{22, 5}, "CountryPartnerTradeAggregateStore.import_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_base{{{22, 6}, "CountryPartnerTradeAggregateStore.export_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> order_count{{{22, 7}, "CountryPartnerTradeAggregateStore.order_count", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_epoch{{{22, 8}, "CountryPartnerTradeAggregateStore.batch_epoch", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_quantity{{{22, 9}, "CountryPartnerTradeAggregateStore.batch_import_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_quantity{{{22, 10}, "CountryPartnerTradeAggregateStore.batch_export_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_base{{{22, 11}, "CountryPartnerTradeAggregateStore.batch_import_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_base{{{22, 12}, "CountryPartnerTradeAggregateStore.batch_export_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_order_count{{{22, 13}, "CountryPartnerTradeAggregateStore.batch_order_count", EconomyFieldEncoding::I64, 8}};
        void clear() {
            countries.clear(); partners.clear(); import_quantity.clear();
            export_quantity.clear(); import_base.clear(); export_base.clear();
            order_count.clear();
            batch_epoch.clear(); batch_import_quantity.clear();
            batch_export_quantity.clear(); batch_import_base.clear();
            batch_export_base.clear(); batch_order_count.clear();
        }
    };

    struct TariffHistoryStore {
        EconomyOwnedColumn<int32_t> countries{{{23, 1}, "TariffHistoryStore.countries", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> kinds{{{23, 2}, "TariffHistoryStore.kinds", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int64_t> bases{{{23, 3}, "TariffHistoryStore.bases", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> assessed{{{23, 4}, "TariffHistoryStore.assessed", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> collected{{{23, 5}, "TariffHistoryStore.collected", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> requests{{{23, 6}, "TariffHistoryStore.requests", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> reserved{{{23, 7}, "TariffHistoryStore.reserved", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> paid{{{23, 8}, "TariffHistoryStore.paid", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> cumulative_bases{{{23, 9}, "TariffHistoryStore.cumulative_bases", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> cumulative_collected{{{23, 10}, "TariffHistoryStore.cumulative_collected", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> cumulative_requests{{{23, 11}, "TariffHistoryStore.cumulative_requests", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> cumulative_paid{{{23, 12}, "TariffHistoryStore.cumulative_paid", EconomyFieldEncoding::I64, 8}};
        void clear() {
            countries.clear(); kinds.clear(); bases.clear(); assessed.clear();
            collected.clear(); requests.clear(); reserved.clear(); paid.clear();
            cumulative_bases.clear(); cumulative_collected.clear();
            cumulative_requests.clear(); cumulative_paid.clear();
        }
    };

    struct LaborMarketStore {
        EconomyOwnedColumn<int32_t> cell_offsets{{{19, 1}, "LaborMarketStore.cell_offsets", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> profession_ids{{{19, 2}, "LaborMarketStore.profession_ids", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int64_t> base_living_cost{{{19, 3}, "LaborMarketStore.base_living_cost", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> role_living_cost{{{19, 4}, "LaborMarketStore.role_living_cost", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> contract_wage_ema{{{19, 5}, "LaborMarketStore.contract_wage_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> paid_wage_ema{{{19, 6}, "LaborMarketStore.paid_wage_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> job_days{{{19, 7}, "LaborMarketStore.job_days", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int32_t> pay_ratio_q16{{{19, 8}, "LaborMarketStore.pay_ratio_q16", EconomyFieldEncoding::I32, 4}};

        void clear(int32_t cells) {
            cell_offsets.assign(static_cast<size_t>(std::max(0, cells)) + 1, 0);
            profession_ids.clear();
            base_living_cost.clear();
            role_living_cost.clear();
            contract_wage_ema.clear();
            paid_wage_ema.clear();
            job_days.clear();
            pay_ratio_q16.clear();
        }
    };

    struct PricePressure {
        int64_t derived_q16 = 0;
        int64_t household_demand = 0;
        int64_t business_demand = 0;
        int64_t supply = 0;
        int64_t excess_q16 = 0;
        int64_t inventory_target = 0;
        int64_t inventory_q16 = 0;
        int64_t shortage_q16 = 0;
        int64_t cost_q16 = 0;
        bool glut_cost_damped = false;
        int64_t idle_q16 = 0;
        int64_t total_q16 = 0;
        int64_t change_q16 = 0;
        int64_t adjustment_anchor_price = 1;
        int64_t inactive_reversion_alpha_q16 = 0;
    };

    struct Command {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t target_handle = 0;
        int32_t i32_0 = 0;
        int32_t i32_1 = 0;
        int64_t i64_0 = 0;
        int64_t i64_1 = 0;
        uint64_t submit_order = 0;
        int64_t effect_request_id = 0;
        uint64_t effect_idempotency_key = 0;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(opcode);
            visit(effective_day);
            visit(sequence);
            visit(target_handle);
            visit(i32_0);
            visit(i32_1);
            visit(i64_0);
            visit(i64_1);
            visit(submit_order);
            visit(effect_request_id);
            visit(effect_idempotency_key);
        }
    };

    struct EffectCommandResult {
        uint8_t complete = 0;
        uint8_t ok = 0;
        std::string reason;
    };

    struct StructuralCommand {
        int32_t opcode = 0;
        int32_t source_slot = -1;
        int32_t cell = -1;
        int32_t signature = -1;
        int64_t population = 0;
        int64_t funds = 0;
        int64_t sequence = 0;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(opcode);
            visit(source_slot);
            visit(cell);
            visit(signature);
            visit(population);
            visit(funds);
            visit(sequence);
        }
    };

    struct CellSummary {
        int64_t population = 0;
        int64_t funds = 0;
        int64_t epoch_income = 0;
        int64_t epoch_expense = 0;
        int32_t cohort_count = 0;
        int32_t satisfaction_q16 = 0;
    };

    struct AuditTotals {
        int64_t population = 0;
        int64_t cohort_funds = 0;
        int64_t country_cash = 0;
        int64_t goods_stock = 0;
        int64_t country_goods = 0;
        int64_t transit_goods = 0;
        int64_t transit_population = 0;
        int64_t escrow_cash = 0;
        int64_t expedition_funds = 0;
        int64_t expedition_goods = 0;
        // BEGIN army personnel lane (contract §1.2): embarked people/funds.
        // Reported separately for diagnostics; already folded into
        // transit_population / escrow_cash so no conservation formula changes.
        int64_t army_lane_population = 0;
        int64_t army_lane_funds = 0;
        // END army personnel lane
        int64_t merchant_cash = 0;
        int64_t merchant_inventory_retail_value = 0;
        int64_t merchant_inventory_liquidation_value = 0;
    };
    // The audited epoch precedes Effect command drain; never interpret this
    // revision as an audit of arbitrary live post-command lanes.
    struct CommittedAuditView {
        uint64_t generation = 0;
        int64_t day = -1;
        int64_t population_actual = 0, population_expected = 0;
        int64_t money_actual = 0, money_expected = 0;
        int64_t goods_actual = 0, goods_expected = 0;
        bool full_verification = false;
    };
    CommittedAuditView _verified_epoch_audit;
    std::shared_ptr<const CommittedAuditView> _committed_audit_view;

    struct GoodsAuditLaneDiagnostic {
        int32_t market = -1;
        int32_t cell = -1;
        int32_t good = -1;
        int64_t opening_stock = 0;
        int64_t closing_stock = 0;
        int64_t net_change = 0;
    };

    struct MoneyAuditAccountDiagnostic {
        int32_t slot = -1;
        int32_t cell = -1;
        int32_t signature = -1;
        int32_t profession = -1;
        uint64_t handle = 0;
        int64_t opening_funds = 0;
        int64_t closing_funds = 0;
        int64_t net_change = 0;
    };

    struct MoneyStageDiagnostic {
        int64_t day = -1;
        int64_t epoch_id = -1;
        int32_t stage = -1;
        int32_t executed_stage = -1;
        int64_t money_open = 0;
        int64_t money_now = 0;
        int64_t money_expected = 0;
        int64_t diff = 0;
        int64_t delta = 0;
        int64_t cohort_funds = 0;
        int64_t country_cash = 0;
        int64_t escrow_cash = 0;
        int64_t explicit_money_mint = 0;
        int64_t explicit_money_burn = 0;
        std::array<char, 32> where{};
        std::array<char, 96> substage{};
    };

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


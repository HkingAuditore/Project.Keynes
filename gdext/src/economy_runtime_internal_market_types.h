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

#include "economy_runtime_internal_market_types_topology.h"
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
        uint64_t expedition_route_hash = 0;
        bool military_construction() const {
            return (opcode == COMMAND_TREASURY_SPONSORED_BUILD ||
                    opcode == COMMAND_TREASURY_SPONSORED_DEMOLISH) &&
                i64_1 == OWNERSHIP_TREASURY_MILITARY_ORDER;
        }
        bool treasury_construction_policy_valid() const {
            return military_construction() || i64_1 == OWNERSHIP_TREASURY_SPONSORED_PRIVATE;
        }

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
            visit(opcode == COMMAND_START_FAMILY_EXPEDITION
                ? expedition_route_hash : effect_idempotency_key);
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

#include "economy_runtime_internal_market_types_settlement.h"

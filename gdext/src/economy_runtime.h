#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace pk {

class NativeCountryRuntime;
class EconomyCsvRecorder;

// NativeEconomyRuntime is the sole mutable authority for population cohorts
// and markets. Godot containers are accepted/emitted only at coarse API
// boundaries; every graph stage operates on POD/std::vector storage.
class NativeEconomyRuntime {
public:
    static constexpr int32_t SCHEMA_VERSION = 19;
    static constexpr int32_t ROLLING_PHASE_COUNT = 5;
    static constexpr int32_t PAGE_SIZE = 64;
    static constexpr int64_t MONEY_SCALE = 10000;
    static constexpr int64_t GOODS_SCALE = 1000;
    static constexpr int64_t Q16_ONE = 65536;
    static constexpr int64_t MERCHANT_INVENTORY_HIGH_WATER_Q16 =
        Q16_ONE + Q16_ONE / 5;
    static constexpr int64_t Q32_ONE = 4294967296LL;
    static constexpr int32_t MAX_RULES_PER_PLAN = 32;
    static constexpr int32_t MAX_NEEDS_PER_PLAN = 16;
    static constexpr int32_t MAX_VARIANTS_PER_NEED = 8;
    static constexpr int32_t MAX_COMPONENTS_PER_VARIANT = 4;
    static constexpr int32_t ENV_CURVE_SAMPLES = 17;
    static constexpr int32_t PUBLISH_ENTRIES_PER_SLICE = 4096;
    static constexpr int32_t PUBLISH_AUDIT_ENTRIES_PER_SLICE = 131072;
    static constexpr int32_t BUILDING_REVIEW_GROUPS_PER_SLICE = 4096;
    static constexpr int32_t AUTO_BUILDING_CELLS_PER_SLICE = 256;
    static constexpr int32_t AUTO_INVESTMENT_CELLS_PER_SLICE = 96;
    static constexpr int32_t AUTO_BUILDING_FINALIZE_CELLS_PER_SLICE = 128;
    // Cooperative planner budget. Route searches retain their heap/cursors
    // across native slices, so this is a deterministic work cap rather than a
    // wall-clock deadline.
    static constexpr int32_t TRADE_ROUTE_EXPANSIONS_PER_SLICE = 256;

    enum CommandOpcode : int32_t {
        COMMAND_TRANSFER_TO_COHORT = 1,
        COMMAND_MINT_TO_COHORT = 2,
        COMMAND_BURN_FROM_COHORT = 3,
        COMMAND_ADD_STOCK = 4,
        COMMAND_REMOVE_STOCK = 5,
        COMMAND_ADD_POPULATION = 6,
        COMMAND_MOVE_POPULATION = 7,
        COMMAND_CHANGE_SIGNATURE = 8,
        COMMAND_TRANSFER_FROM_COHORT = 9,
        COMMAND_BUILD = 10,
        COMMAND_DEMOLISH = 11,
        COMMAND_COUNTRY_GOOD_TO_MARKET = 12,
        COMMAND_MARKET_GOOD_TO_COUNTRY = 13,
    };

    NativeEconomyRuntime();
    ~NativeEconomyRuntime();
    void attach_country_runtime(NativeCountryRuntime *runtime) { _country_runtime = runtime; }
    bool country_restore_allowed() const {
        return !_bootstrapped && !_save.active && !_restore.active;
    }
    bool country_save_allowed() const {
        return !_epoch_active && !_save.active && !_restore.active && !_fatal;
    }

    godot::Dictionary configure(const godot::Dictionary &catalog,
                                const godot::Dictionary &profile,
                                int32_t cell_count,
                                int64_t seed);
    godot::Dictionary bootstrap(const godot::Dictionary &population_packet,
                                const godot::Dictionary &market_packet);
    godot::Dictionary submit_commands(const godot::Dictionary &batch);
    godot::Dictionary run_slice(const godot::Dictionary &ctx);
    godot::Dictionary run_slice_compact(const godot::Dictionary &ctx);
    bool capture_environment(int64_t day_index, const float *temperature,
                             const float *moisture, const float *snow_cover,
                             const float *weather_intensity, int32_t count,
                             std::string &error);
    bool needs_environment_capture(int64_t day_index) const {
        return !_epoch_active && day_index > _last_committed_day &&
               _environment_day != day_index;
    }
    bool should_run(int64_t day_index) const;
    godot::Dictionary report() const;
    godot::Dictionary population_cell_summary(int32_t cell_idx) const;
    godot::Dictionary population_cell_snapshot(int32_t cell_idx) const;
    godot::Dictionary population_cell_snapshot(int32_t cell_idx,
                                                float temperature,
                                                float moisture,
                                                float snow_cover,
                                                float weather_intensity,
                                                bool environment_ready) const;
    godot::Dictionary market_cell_snapshot(int32_t cell_idx) const;
    godot::Dictionary trade_orders_for_cell(int32_t cell_idx, int32_t offset,
                                             int32_t limit) const;
    godot::Dictionary building_cell_snapshot(int32_t cell_idx) const;
    godot::Dictionary fixed_math_probe(const godot::Dictionary &vectors) const;
    int64_t state_hash() const;
    godot::Dictionary reset(const godot::String &reason);

    godot::Dictionary begin_save(int32_t chunk_bytes);
    godot::PackedByteArray read_save_chunk(int32_t max_bytes);
    godot::Dictionary end_save();
    godot::Dictionary begin_restore();
    godot::Dictionary feed_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_restore();

    // Committed, read-only economy event stream. Events produced by an active
    // frozen epoch remain private until aggregate_publish succeeds.
    godot::Dictionary event_schema() const;
    godot::Dictionary set_trace_filter(const godot::Dictionary &filter);
    godot::Dictionary set_inspector_trace_cell(int32_t cell_idx);
    godot::Dictionary poll_events(const godot::Dictionary &opts) const;
    godot::Dictionary ack_events(const godot::StringName &consumer_id,
                                 int64_t up_to_event_id);
    godot::Dictionary trace_report() const;
    godot::Dictionary begin_event_archive(int32_t chunk_bytes);
    godot::PackedByteArray read_event_archive_chunk(int32_t max_bytes);
    godot::Dictionary end_event_archive();

    // Building context is captured once at the frozen sample boundary. Natural
    // resources are resource-major and use GOODS_SCALE units in native state.
    bool capture_building_context(int64_t day_index, const float *elevation,
                                  const uint8_t *terrain, const uint8_t *landform,
                                  const uint8_t *vegetation, const uint8_t *is_water,
                                  const uint8_t *has_river, const int32_t *neighbor_indices,
                                  const std::vector<const float *> &resources,
                                  const std::vector<const float *> &resource_changes,
                                  int32_t count, std::string &error);
    bool needs_building_context_capture(int64_t day_index) const {
        return !_epoch_active && day_index > _last_committed_day &&
               _building_context_day != day_index;
    }
    const std::vector<std::string> &building_resource_reserve_slots() const {
        return _resource_reserve_slots;
    }
    const std::vector<std::string> &building_resource_extra_slots() const {
        return _resource_extra_slots;
    }
    bool drain_building_resource_deltas(std::vector<int64_t> &out);
    int32_t building_resource_access_cells(int32_t cell, int32_t resource_id,
                                           int32_t *out_cells, int32_t capacity) const;
    bool capture_trade_topology(const int32_t *neighbor_indices,
                                const uint8_t *terrain,
                                const uint8_t *trade_passable_lut,
                                const int32_t *trade_move_cost_lut,
                                int32_t count, uint64_t generation,
                                std::string &error);

private:
    friend class EconomyCsvRecorder;
    enum StructuralOpcode : int32_t {
        STRUCTURAL_BIRTH = -1,
        STRUCTURAL_REMOVE_EMPTY = 0,
    };
    enum class Stage : int32_t {
        IDLE = 0,
        EPOCH_BEGIN = 1,
        LEDGER_APPLY = 2,
        HOUSEHOLD_MARKET = 3,
        STRUCTURAL_COMMIT = 4,
        WAIT_COMMIT = 5,
        BUILDING_EMPLOYMENT = 6,
        BUILDING_PRODUCTION = 7,
        BUILDING_COMMIT = 8,
        AGGREGATE_PUBLISH = 9,
        FATAL = 10,
        TRADE_SETTLE = 11,
        TRADE_DISPATCH = 12,
        TRADE_PLANNING = 13,
        BUILDING_PLAN = 14,
    };

    enum class PublishPhase : uint8_t {
        PREPARE = 0,
        AUDIT_POPULATION = 1,
        AUDIT_MARKET = 2,
        AUDIT_TRANSIT = 3,
        AUDIT_ESCROW = 4,
        AUDIT_COUNTRY = 5,
        VERIFY = 6,
        WATERMARK = 7,
        TRADE_FLOW = 8,
        TRADE_DIAGNOSTICS = 9,
        TRADE_INIT = 10,
        COMMIT = 11,
        DONE = 12,
        COUNT = 13,
    };

    static constexpr size_t BUILDING_COMMIT_PHASE_COUNT = 7;

    enum class TradePlanInitPhase : uint8_t {
        IDLE = 0,
        COMPONENT_PREPARE = 1,
        COMPONENT_CLEAR = 2,
        COMPONENT_BUILD = 3,
        PREPARE = 4,
        INFLIGHT_BUILD = 5,
        INFLIGHT_SORT = 6,
        PRUNE = 7,
        INBOUND_BUILD = 8,
        ROTATE = 9,
        WORKSPACE_CLEAR = 10,
        FINALIZE = 11,
        DONE = 12,
    };

    struct FormulaBatchInput {
        const int64_t *population = nullptr;
        const int64_t *funds = nullptr;
        const int64_t *income_ema = nullptr;
        int32_t count = 0;
        int32_t price = 0;
        int32_t dt_days = 1;
        const int64_t *params = nullptr;
        int32_t param_count = 0;
    };
    using FormulaBatchFn = void (*)(const FormulaBatchInput &, int64_t *, int64_t &);

    struct FormulaDefinition {
        std::string stable_id;
        int32_t version = 1;
        int32_t min_params = 0;
        int32_t max_params = 0;
        FormulaBatchFn batch = nullptr;
    };

    struct Rule {
        int32_t good_id = -1;
        int32_t formula_id = -1;
        int32_t formula_version = 0;
        int32_t priority = 0;
        int32_t param_begin = 0;
        int32_t param_count = 0;
    };

    struct Plan {
        int32_t need_begin = 0;
        int32_t need_count = 0;
    };

    struct Need {
        int32_t stable_id = -1;
        int32_t priority = 0;
        int32_t variant_begin = 0;
        int32_t variant_count = 0;
        int64_t base_qty_per_person = 0;
        int32_t wealth_elasticity_q16 = 0;
        int32_t wealth_min_q16 = 0;
        int32_t wealth_max_q16 = Q16_ONE;
        int32_t price_quantity_elasticity_q16 = Q16_ONE;
        int32_t price_quantity_floor_q16 = 0;
        int32_t quantity_env_curve = -1;
        int32_t living_cost_weight_q16 = 0;
    };

    struct VariantChoice {
        int32_t component_begin = 0;
        int32_t component_count = 0;
        int32_t preference_q16 = Q16_ONE;
        int32_t price_elasticity_q16 = Q16_ONE;
        int32_t preference_env_curve = -1;
        int64_t reference_unit_price = MONEY_SCALE;
    };

    struct NeedComponent {
        int32_t good_id = -1;
        int64_t qty_per_need = GOODS_SCALE;
    };

    struct EnvironmentCurve {
        int32_t signal_id = 0;
        int32_t values_q16[ENV_CURVE_SAMPLES]{};
    };

    struct EnvironmentSample {
        int32_t temperature_q16 = Q16_ONE / 2;
        int32_t moisture_q16 = Q16_ONE / 2;
        int32_t snow_q16 = 0;
        int32_t weather_q16 = 0;
        bool ready = false;
    };

    struct Signature {
        int32_t profession_id = -1;
        int32_t ethnicity_id = -1;
        int32_t plan_id = -1;
        int64_t birth_rate_q32 = 0;
        int64_t death_rate_q32 = 0;
        int64_t satisfaction_birth_weight_q16 = Q16_ONE;
    };

    struct BuildingType {
		int32_t kind = 1; // 0=collector, 1=industrial.
        int32_t upgrade_family_id = -1;
        int32_t upgrade_tier = 0;
        int32_t owner_profession_id = -1;
        int64_t owner_slots_per_building = 0;
        int64_t wage_per_employee_per_day = 0;
        int32_t employee_begin = 0;
        int32_t employee_count = 0;
        int32_t construction_begin = 0;
        int32_t construction_count = 0;
        int32_t input_begin = 0;
        int32_t input_count = 0;
        int32_t output_begin = 0;
        int32_t output_count = 0;
        int32_t resource_begin = 0;
        int32_t resource_count = 0;
        int32_t generation_begin = 0;
        int32_t generation_count = 0;
        int32_t generation_floor_q16 = 0;
        int32_t condition_begin = 0;
        int32_t condition_count = 0;
        int32_t construction_days = 0;
        int32_t behavior_id = 0; // 0=none, 1=consume, 2=cultivate+consume.
        int32_t behavior_version = 1;
        int32_t target_operating_margin_q16 = 0;
        int32_t supply_price_elasticity_q16 = Q16_ONE;
        int32_t output_cost_share_begin = 0;
        int32_t output_cost_share_count = 0;
        int32_t market_signal_begin = 0;
        int32_t market_signal_count = 0;
        int32_t labor_signal_begin = 0;
        int32_t labor_signal_count = 0;
    };

    struct JobRole {
        int32_t profession_id = -1;
        int64_t slots_per_building = 0;
        int32_t wage_policy = 0; // 0=none, 1=fixed, 2=adaptive.
        int64_t reference_wage_per_day = 0;
    };

    struct GoodAmount {
        int32_t good_id = -1;
        int64_t quantity = 0;
    };

    struct ProductionInput {
        int32_t preferred_good_id = -1;
        int64_t quantity = 0;
        int32_t candidate_begin = 0;
        int32_t candidate_count = 0;
        int32_t required_q16 = Q16_ONE;
    };

    struct InputCandidate {
        int32_t good_id = -1;
        int32_t efficiency_q16 = Q16_ONE;
    };

    struct ResourceAmount {
        int32_t resource_id = -1;
        int64_t quantity = 0;
        int32_t mode = 0; // 0=extract per day, 1=capacity per building.
        int32_t access_mode = 0; // 0=local, 1=local plus six hex neighbors.
    };

    struct ConditionToken {
        int32_t opcode = 0; // 1=predicate, 2=and, 3=or, 4=not.
        int32_t signal = 0;
        int32_t compare = 0;
        int32_t reference = -1;
        int64_t value = 0;
    };

    struct BuildingGroup {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t count = 0;
        int64_t filled_owner = 0;
        int32_t employee_fill_begin = -1;
        int32_t last_input_selection_begin = -1;
        int64_t last_capacity_q16 = 0;
        int64_t last_input = 0;
        int64_t last_output = 0;
        int64_t last_sold = 0;
        int64_t last_discarded = 0;
        int64_t last_resource = 0;
        int64_t last_resource_generated = 0;
        int64_t last_revenue = 0;
        int64_t last_input_cost = 0;
        int64_t last_wages_paid = 0;
        int64_t last_wages_due = 0;
        int64_t last_expected_revenue = 0;
        int64_t last_operating_cost = 0;
        int32_t last_margin_gap_q16 = 0;
        int32_t planned_utilization_q16 = Q16_ONE;
        int64_t sample_unit_input_cost = 0;
        int64_t last_base_wages_paid = 0;
        int64_t last_base_wages_due = 0;
        int64_t last_bonus_paid = 0;
        int64_t last_bonus_due = 0;
        int64_t purchase_intent_capacity_q16 = 0;
        int32_t realized_profit_margin_q16 = 0;
        uint16_t severe_loss_cycles = 0;
        uint16_t recovery_cycles = 0;
        uint16_t recovery_failed_reviews = 0;
        uint16_t merchant_debt_term_cycles_left = 0;
        uint16_t merchant_debt_delinquent_cycles = 0;
        uint8_t operating_state = 0; // 0=ACTIVE, 1=SUSPENDED_LOSS, 2=RECOVERY_PROBE.
        uint8_t wage_suspended = 0;
        int64_t merchant_debt_principal = 0;
        int64_t merchant_debt_premium = 0;
        int64_t last_in_kind_livelihood_value = 0;
        uint8_t pending_operating_state = 255; // 255=NONE; applied at next due-cell epoch.
        uint16_t recovery_cooldown_cycles = 0;
    };

    struct PendingConstruction {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t count = 0;
        int64_t ready_day = 0;
        int64_t sequence = 0;
        int64_t merchant_debt_principal = 0;
        int64_t merchant_debt_premium = 0;
        uint16_t merchant_debt_term_cycles_left = 0;
    };

    struct BuildingRoleSpan {
        int32_t employee_begin = -1;
        int32_t input_begin = -1;
    };

    struct InvestmentExistingType {
        int32_t first_group = -1;
        int32_t last_group = -1;
        int32_t representative_group = -1;
        int64_t installed_count = 0;
        int64_t active_count = 0;
        int64_t suspended_count = 0;
        // Building-equivalent unused capacity in Q16. This is transient review
        // state: offered supply already accounts for the utilized share, so only
        // the unused share is reserved against the remaining demand gap.
        int64_t idle_capacity_q16 = 0;
        int64_t filled_owner = 0;
        int64_t owner_required = 0;
        int64_t last_sold = 0;
        int64_t last_discarded = 0;
    };

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
    };

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
        int64_t score_q16 = 0;
        int64_t payback_days = 0;
        int64_t required_capital = 0;
        int64_t projected_profit_per_day = 0;
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
    };

    struct PopulationStore {
        std::vector<int32_t> cell_first_page;
        std::vector<int32_t> page_next;
        std::vector<int32_t> page_cell;
        std::vector<int32_t> free_pages;

        std::vector<uint8_t> active;
        std::vector<uint32_t> signature_id;
        std::vector<uint32_t> generation;
        std::vector<int64_t> population;
        std::vector<int64_t> funds;
        std::vector<int64_t> epoch_income;
        std::vector<int64_t> epoch_expense;
        // Derived diagnostic: retail value of goods consumed from producer-retained output.
        // It is reset with the epoch and intentionally excluded from save/hash authority.
        std::vector<int64_t> epoch_in_kind_income;
        std::vector<int64_t> income_ema;
        std::vector<uint16_t> needs_satisfaction;
        std::vector<uint16_t> worst_need_id;
        std::vector<uint16_t> flags;
        std::vector<int64_t> demography_residual;
        std::vector<int64_t> owner_employed;
        std::vector<int64_t> employee_employed;

        int64_t active_count = 0;
        int64_t high_water_slots = 0;

        void clear(int32_t cells);
        int32_t allocate_page(int32_t cell);
        int32_t find_signature(int32_t cell, uint32_t signature) const;
        int32_t allocate_slot(int32_t cell, uint32_t signature);
        bool valid_handle(uint64_t handle, int32_t &slot_out) const;
        uint64_t handle_for_slot(int32_t slot) const;
        void release_slot(int32_t slot);
        void reclaim_empty_pages(int32_t cell);
        template <typename F> void for_each_in_cell(int32_t cell, F &&fn) const {
            if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return;
            for (int32_t p = cell_first_page[cell]; p >= 0; p = page_next[p]) {
                const int32_t base = p * PAGE_SIZE;
                for (int32_t lane = 0; lane < PAGE_SIZE; ++lane) {
                    const int32_t slot = base + lane;
                    if (active[slot] != 0) fn(slot);
                }
            }
        }
    };

    struct MarketStore {
        int32_t market_count = 0;
        int32_t good_count = 0;
        std::vector<int64_t> stock;
        std::vector<int32_t> price;
        std::vector<int64_t> demand_ema;
        std::vector<uint16_t> last_shortage_q16;
        std::vector<int32_t> cell_to_market;

        void clear();
        int64_t index(int32_t market, int32_t good) const {
            return static_cast<int64_t>(market) * good_count + good;
        }
    };

    struct MarketSignalStore {
        std::vector<int32_t> cell_offsets;
        std::vector<int32_t> good_ids;
        // Optional O(1) (cell, good) -> sparse signal index. Rebuilt from the
        // authoritative ascending CSR and excluded from save/hash state.
        std::vector<int32_t> dense_index;
        std::vector<int64_t> business_demand_ema;
        std::vector<int64_t> offered_supply_ema;
        std::vector<int64_t> realized_withdrawal_ema;
        std::vector<int32_t> cost_anchor_price;

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

    struct TradeTopologyStore {
        std::vector<int32_t> neighbors;
        std::vector<uint8_t> passable;
        std::vector<int32_t> enter_cost;
        std::vector<int32_t> component;
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
            component.clear();
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
        int32_t route_cost = 0;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        int64_t quantity = 0;
        int64_t expected_profit = 0;
        int64_t capacity_work = 0;
        int64_t density_q16 = 0;
        int32_t signal_age_days = 0;
        int32_t response_priority = 0;
        uint32_t source_price_stock_generation = 0;
        uint32_t destination_price_stock_generation = 0;
        int64_t planned_day = -1;
        uint64_t topology_generation = 0;
        uint64_t country_topology_hash = 0;
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

    struct TradeOrderStore {
        enum State : uint8_t { IN_TRANSIT = 0, WAITING_RECEIVER = 1 };
        std::vector<int64_t> ids;
        std::vector<int32_t> sources;
        std::vector<int32_t> destinations;
        std::vector<int32_t> countries;
        std::vector<int64_t> departure_days;
        std::vector<int64_t> arrival_days;
        std::vector<int64_t> cash_escrow;
        std::vector<int64_t> capacity_work;
        std::vector<uint8_t> states;
        std::vector<uint8_t> cargo_delivered;
        std::vector<int32_t> line_offsets;
        std::vector<int32_t> line_goods;
        std::vector<int64_t> line_quantities;
        std::vector<int32_t> line_unit_prices;
        std::vector<int32_t> seller_offsets;
        std::vector<uint64_t> seller_handles;
        std::vector<int64_t> seller_weights;
        // Derived CSR time buckets. Arrival days remain the persisted authority;
        // these vectors are rebuilt after dispatch, compaction, and restore.
        std::vector<int64_t> arrival_bucket_days;
        std::vector<int32_t> arrival_bucket_offsets;
        std::vector<int32_t> arrival_bucket_orders;
        bool arrival_buckets_dirty = true;
        int64_t next_id = 1;

        void clear() {
            ids.clear(); sources.clear(); destinations.clear(); countries.clear();
            departure_days.clear(); arrival_days.clear(); cash_escrow.clear();
            capacity_work.clear(); states.clear(); cargo_delivered.clear();
            line_offsets.assign(1, 0); line_goods.clear(); line_quantities.clear();
            line_unit_prices.clear(); seller_offsets.assign(1, 0);
            seller_handles.clear(); seller_weights.clear();
            arrival_bucket_days.clear(); arrival_bucket_offsets.assign(1, 0);
            arrival_bucket_orders.clear(); arrival_buckets_dirty = true;
            next_id = 1;
        }
        int32_t size() const { return static_cast<int32_t>(ids.size()); }
    };

    struct TradeFlowSignalStore {
        std::vector<int32_t> cells;
        std::vector<int32_t> goods;
        std::vector<int64_t> import_ema;
        std::vector<int64_t> export_ema;
        std::vector<int64_t> period_import;
        std::vector<int64_t> period_export;

        void clear() {
            cells.clear(); goods.clear(); import_ema.clear(); export_ema.clear();
            period_import.clear(); period_export.clear();
        }
    };

    struct LaborMarketStore {
        std::vector<int32_t> cell_offsets;
        std::vector<int32_t> profession_ids;
        std::vector<int64_t> base_living_cost;
        std::vector<int64_t> role_living_cost;
        std::vector<int64_t> contract_wage_ema;
        std::vector<int64_t> paid_wage_ema;
        std::vector<int64_t> job_days;
        std::vector<int32_t> pay_ratio_q16;

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
        int64_t household_demand = 0;
        int64_t business_demand = 0;
        int64_t supply = 0;
        int64_t excess_q16 = 0;
        int64_t inventory_target = 0;
        int64_t inventory_q16 = 0;
        int64_t shortage_q16 = 0;
        int64_t cost_q16 = 0;
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
    };

    struct StructuralCommand {
        int32_t opcode = 0;
        int32_t source_slot = -1;
        int32_t cell = -1;
        int32_t signature = -1;
        int64_t population = 0;
        int64_t funds = 0;
        int64_t sequence = 0;
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
        int64_t escrow_cash = 0;
        int64_t merchant_cash = 0;
        int64_t merchant_inventory_retail_value = 0;
        int64_t merchant_inventory_liquidation_value = 0;
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
        int32_t overall_satisfaction_q16 = 0;
        int32_t living_standard_level = 0;
        std::vector<int32_t> need_ids;
        std::vector<int32_t> need_satisfaction_q16;
        std::vector<int64_t> previous_demand_per_capita_daily;
        std::vector<int64_t> wealth_demand_delta_per_capita_daily;
        std::vector<int64_t> price_demand_delta_per_capita_daily;
    };

    struct MarketResult {
        bool ok = true;
        std::string error;
        int64_t processed_cohorts = 0;
        int64_t processed_rules = 0;
        int64_t processed_needs = 0;
        int64_t processed_variants = 0;
        int64_t processed_components = 0;
        int64_t saturation_count = 0;
        int64_t consumed_goods = 0;
        int64_t retained_output_consumed = 0;
        int64_t retained_output_discarded = 0;
        std::vector<int64_t> retained_consumed_by_good;
        std::vector<BuildingInKindCredit> building_in_kind_credits;
        int64_t owner_working_capital_reserved = 0;
        int64_t births = 0;
        int64_t deaths = 0;
        std::vector<int32_t> population_changed_cells;
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
        int64_t price_cap_hits = 0;
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
    };

    enum EventKind : int32_t {
        EVENT_COMMAND_SETTLED = 1,
        EVENT_MARKET_SETTLED = 2,
        EVENT_STRUCTURAL_CHANGE = 3,
        EVENT_CONSTRUCTION_STARTED = 4,
        EVENT_CONSTRUCTION_COMPLETED = 5,
        EVENT_BUILDING_DEMOLISHED = 6,
        EVENT_EMPLOYMENT_SETTLED = 7,
        EVENT_WAGE_SETTLED = 8,
        EVENT_BUILDING_PRODUCTION_SETTLED = 9,
        EVENT_EPOCH_COMMITTED = 10,
        EVENT_RESTORE_BOUNDARY = 11,
        EVENT_TRADE_DISPATCHED = 12,
        EVENT_TRADE_ARRIVED = 13,
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
    };

    struct EventLeg {
        int32_t field = 0;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t key_id = -1;
        int64_t before = 0;
        int64_t after = 0;
    };

    struct EventRecord {
        int64_t event_id = 0;
        int32_t stage = 0;
        int32_t kind = 0;
        int32_t flags = 0;
        int32_t cell = -1;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t subject_i0 = -1;
        int32_t subject_i1 = -1;
        uint32_t leg_begin = 0;
        uint32_t leg_count = 0;
        int64_t value0 = 0;
        int64_t value1 = 0;
        int64_t value2 = 0;
        int64_t value3 = 0;
    };

    struct CashflowEntry {
        uint64_t cohort_handle = 0;
        int32_t source = CASHFLOW_OTHER;
        int64_t income = 0;
        int64_t expense = 0;
    };

    enum TradeSignalDiagnosticReason : int32_t {
        TRADE_SIGNAL_DIAG_NONE = 0,
        TRADE_SIGNAL_DIAG_NO_SPREAD = 1,
        TRADE_SIGNAL_DIAG_MARGIN = 2,
        TRADE_SIGNAL_DIAG_ROUTE = 3,
        TRADE_SIGNAL_DIAG_STOCK = 4,
        TRADE_SIGNAL_DIAG_CAPACITY = 5,
        TRADE_SIGNAL_DIAG_CASH = 6,
        TRADE_SIGNAL_DIAG_ORDER_CAP = 7,
        TRADE_SIGNAL_DIAG_DISPATCHED = 8,
        TRADE_SIGNAL_DIAG_ARBITRATED_OUT = 9,
    };

    struct ProductionTraceDraft {
        int32_t kind = 0;
        int32_t stage = 0;
        int32_t cell = -1;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t subject_i0 = -1;
        int32_t subject_i1 = -1;
        int64_t value0 = 0;
        int64_t value1 = 0;
        int64_t value2 = 0;
        int64_t value3 = 0;
        int32_t flags = 0;
        std::vector<EventLeg> legs;
    };

    struct ProductionCashflowDraft {
        int32_t cell = -1;
        CashflowEntry entry;
    };

    struct ProductionResult {
        bool ok = true;
        std::string error;
        int64_t saturation_count = 0;
        int64_t processed_building_groups = 0;
        int64_t merchant_procurement_budget = 0;
        int64_t merchant_procurement_opportunity = 0;
        int64_t merchant_procurement_allocated = 0;
        int64_t merchant_procurement_unspent_allocated = 0;
        int64_t merchant_procurement_reserved = 0;
        int64_t merchant_procurement_spent = 0;
        int64_t merchant_procurement_retail_value = 0;
        int64_t merchant_procurement_factor_weighted_cash_q16 = 0;
        int64_t merchant_survival_procurement_required = 0;
        int64_t merchant_survival_procurement_allocated = 0;
        int64_t merchant_input_procurement_required = 0;
        int64_t merchant_input_procurement_allocated = 0;
        int64_t owner_working_capital_allocated = 0;
        int64_t working_capital_scale_error_bound_q16 = 0;
        int64_t building_resource_capacity_checks = 0;
        int64_t building_resource_limited_groups = 0;
        int64_t building_resource_capacity_limited_groups = 0;
        int64_t building_resource_generated = 0;
        int64_t building_resource_consumed = 0;
        int64_t production_inputs_consumed = 0;
        int64_t production_output_stock = 0;
        int64_t production_output_discarded = 0;
        int64_t production_output_supported = 0;
        int64_t producer_revenue = 0;
        int64_t producer_support_money_issued = 0;
        int64_t explicit_money_mint = 0;
        int64_t bullion_money_issued = 0;
        int64_t bullion_stock_consumed = 0;
        int64_t gold_accepted = 0;
        int64_t silver_accepted = 0;
        int64_t gold_money_issued = 0;
        int64_t silver_money_issued = 0;
        int64_t cycle_flow_produced = 0;
        int64_t cycle_flow_consumed = 0;
        int64_t cycle_flow_discarded = 0;
        int64_t building_wages_paid = 0;
        int64_t building_wages_unpaid = 0;
        int64_t building_base_wages_paid = 0;
        int64_t building_base_wages_due = 0;
        int64_t building_bonus_paid = 0;
        int64_t building_bonus_due = 0;
        int64_t wage_suspended_building_groups = 0;
        int64_t desired_business_demand = 0;
        int64_t funded_business_demand = 0;
        int64_t unfunded_business_demand = 0;
        int64_t market_signal_updates = 0;
        int64_t merchant_credit_committed = 0;
        int64_t merchant_credit_drawn = 0;
        int64_t merchant_credit_repaid = 0;
        int64_t merchant_credit_premium_repaid = 0;
        double market_signal_ms = 0.0;
        std::vector<size_t> resource_touched_lanes;
        std::vector<OwnerRetainedOutput> retained_outputs;
        std::vector<ProductionTraceDraft> trace_drafts;
        std::vector<ProductionCashflowDraft> cashflow_drafts;
        int64_t allocation_growth_count = 0;
        int64_t allocation_growth_bytes = 0;

        void reset();
        int64_t capacity_bytes() const;
    };

    struct BuildingPlanResult {
        bool ok = true;
        std::string error;
        int64_t saturation_count = 0;
        int64_t merchant_credit_budget = 0;
        int64_t merchant_credit_committed = 0;
        int64_t recovery_candidates = 0;
        int64_t recovery_approved = 0;
        int64_t loss_suspended_building_groups = 0;
        int64_t unprofitable_building_groups = 0;
        int64_t utilization_sum_q16 = 0;
        double worker_ms = 0.0;

        void reset() {
            *this = {};
        }
    };

    struct CompletedEpochPerf {
        bool valid = false;
        int64_t epoch_id = -1;
        int64_t sample_day = -1;
        int64_t continuation_slices = 0;
        int32_t market_worker_tasks_max = 1;
        int64_t market_worker_task_sum = 0;
        int64_t market_worker_dispatches = 0;
        int32_t production_worker_tasks_max = 1;
        int64_t production_worker_task_sum = 0;
        int64_t production_worker_dispatches = 0;
        int64_t production_worker_parallel_dispatches = 0;
        int64_t production_worker_weight_total = 0;
        int64_t production_worker_task_weight_min = 0;
        int64_t production_worker_task_weight_max = 0;
        int64_t production_worker_imbalance_q16_max = 0;
        double production_worker_cpu_ms = 0.0;
        int32_t audit_worker_tasks_max = 1;
        int64_t audit_worker_dispatches = 0;
        double audit_worker_cpu_ms = 0.0;
        int32_t building_plan_worker_tasks_max = 1;
        int64_t building_plan_worker_parallel_dispatches = 0;
        double building_plan_worker_cpu_ms = 0.0;
        int64_t opening_audit_fast_paths = 0;
        int64_t opening_audit_full_verifications = 0;
        int64_t closing_audit_fast_paths = 0;
        int64_t closing_audit_full_verifications = 0;
        int64_t closing_audit_mismatches = 0;
        std::string closing_audit_mismatch_ledger = "none";
        int64_t closing_audit_mismatch_lane = -1;
        int64_t closing_audit_population_touched_lanes = 0;
        int64_t closing_audit_market_touched_lanes = 0;
        int64_t closing_audit_population_full_scan_entries = 0;
        int64_t closing_audit_market_full_scan_entries = 0;
        int64_t investment_scheduled_review_cells = 0;
        int64_t investment_review_cells = 0;
        int64_t investment_type_evaluations = 0;
        int64_t investment_market_signal_rejections = 0;
        int64_t investment_ethnicity_evaluations = 0;
        int64_t investment_sparse_considered_types = 0;
        int64_t investment_sparse_selected_types = 0;
        int64_t investment_sparse_skipped_types = 0;
        int64_t investment_sparse_mismatches = 0;
        int64_t investment_sparse_dense_fallbacks = 0;
        int64_t approximation_decisions = 0;
        int64_t approximation_exact_probes = 0;
        int64_t approximation_certificate_failures = 0;
        int64_t approximation_exact_fallbacks = 0;
        int64_t approximation_frontier_candidates = 0;
        int64_t approximation_frontier_pruned = 0;
        int64_t approximation_max_observed_regret_q16 = 0;
        int64_t approximation_probe_violations = 0;
        int64_t approximation_probe_max_spend_error_q16 = 0;
        int64_t approximation_probe_max_demand_error_q16 = 0;
        int32_t approximation_cooldown_epochs_left = 0;
        int32_t high_speed_batch_multiplier = 1;
        int64_t high_speed_market_dispatches_saved = 0;
        int64_t high_speed_production_dispatches_saved = 0;
        int64_t budgeted_building_commit_phase_fusions = 0;
        int64_t budgeted_publish_phase_fusions = 0;
        double building_plan_ms = 0.0;
        double building_plan_evaluate_ms = 0.0;
        double building_plan_reserve_ms = 0.0;
        double building_employment_ms = 0.0;
        double building_production_ms = 0.0;
        double building_production_worker_ms = 0.0;
        double building_production_merge_ms = 0.0;
        double household_market_worker_ms = 0.0;
        double household_market_merge_ms = 0.0;
        double household_market_merge_aggregate_ms = 0.0;
        double household_market_merge_trade_ms = 0.0;
        double building_investment_ms = 0.0;
        double aggregate_publish_ms = 0.0;
        double aggregate_audit_ms = 0.0;
        int64_t market_result_allocation_growth_count = 0;
        int64_t market_result_allocation_growth_bytes = 0;
        int64_t production_result_allocation_growth_count = 0;
        int64_t production_result_allocation_growth_bytes = 0;
        int64_t building_structure_count_only_updates = 0;
        int64_t building_structure_new_groups = 0;
        int64_t building_structure_removed_groups = 0;
        int64_t building_structure_topology_rebuilds = 0;
        int64_t building_structure_role_span_reuses = 0;
        int64_t building_structure_role_span_appends = 0;
        double building_structure_group_merge_ms = 0.0;
        double building_structure_market_cache_ms = 0.0;
        double building_structure_labor_cache_ms = 0.0;
    };

    struct EventBatch {
        int64_t epoch_id = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int32_t period_days = 1;
        int64_t first_event_id = 0;
        int64_t last_event_id = 0;
        uint64_t stream_hash = 1469598103934665603ULL;
        std::vector<EventRecord> events;
        std::vector<EventLeg> legs;
        int32_t cashflow_cell = -1;
        bool cashflow_complete = false;
        std::vector<CashflowEntry> cashflows;
        std::vector<CohortWelfareEntry> welfare_entries;
        int64_t bytes() const {
            int64_t welfare_bytes = 0;
            for (const CohortWelfareEntry &entry : welfare_entries) {
                welfare_bytes += static_cast<int64_t>(
                    entry.need_ids.capacity() * sizeof(int32_t) +
                    entry.need_satisfaction_q16.capacity() * sizeof(int32_t) +
                    entry.previous_demand_per_capita_daily.capacity() * sizeof(int64_t) +
                    entry.wealth_demand_delta_per_capita_daily.capacity() * sizeof(int64_t) +
                    entry.price_demand_delta_per_capita_daily.capacity() * sizeof(int64_t));
            }
            return static_cast<int64_t>(events.capacity() * sizeof(EventRecord) +
                                        legs.capacity() * sizeof(EventLeg) +
                                        cashflows.capacity() * sizeof(CashflowEntry) +
                                        welfare_entries.capacity() * sizeof(CohortWelfareEntry)) +
                   welfare_bytes;
        }
    };

    struct AuditFrame {
        int64_t epoch_id = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int64_t event_count = 0;
        int64_t leg_count = 0;
        int64_t population_error = 0;
        int64_t money_error = 0;
        int64_t goods_error = 0;
        uint64_t stream_hash = 1469598103934665603ULL;
    };

    struct SaveState {
        bool active = false;
        int32_t chunk_bytes = 4 * 1024 * 1024;
        int32_t section = 0;
        int32_t page_cursor = 0;
        int32_t market_cursor = 0;
        int32_t cell_cursor = 0;
        int32_t command_cursor = 0;
        int32_t building_cursor = 0;
        int32_t construction_cursor = 0;
        int32_t audit_cursor = 0;
        int32_t signal_cursor = 0;
        int32_t labor_signal_cursor = 0;
        int32_t trade_order_cursor = 0;
        int32_t trade_flow_cursor = 0;
        bool end_emitted = false;
    };

    struct RestoreState {
        bool active = false;
        bool header_seen = false;
        bool end_seen = false;
        bool failed = false;
        std::string error;
        int32_t expected_pages = 0;
        int32_t expected_commands = 0;
        int32_t expected_buildings = 0;
        int32_t expected_construction = 0;
        int32_t restored_pages = 0;
        int32_t restored_markets = 0;
        int32_t restored_cells = 0;
        int32_t restored_commands = 0;
        int32_t schema_version = 0;
        int32_t restored_buildings = 0;
        int32_t restored_construction = 0;
        int32_t expected_audits = 0;
        int32_t restored_audits = 0;
        int32_t expected_signals = 0;
        int32_t restored_signals = 0;
        int32_t expected_labor_signals = 0;
        int32_t restored_labor_signals = 0;
        int32_t expected_trade_orders = 0;
        int32_t restored_trade_orders = 0;
        int32_t expected_trade_flows = 0;
        int32_t restored_trade_flows = 0;
        int32_t last_signal_cell = -1;
        int32_t last_signal_good = -1;
        int32_t last_labor_cell = -1;
        int32_t last_labor_profession = -1;
    };

    struct EventArchiveState {
        bool active = false;
        bool header_emitted = false;
        bool end_emitted = false;
        int32_t chunk_bytes = 4 * 1024 * 1024;
        size_t batch_limit = 0;
        size_t batch_cursor = 0;
        size_t event_cursor = 0;
    };

    bool _configured = false;
    bool _bootstrapped = false;
    bool _epoch_active = false;
    bool _fatal = false;
    std::string _fatal_reason;
    Stage _stage = Stage::IDLE;
    Stage _executed_stage = Stage::IDLE;
    std::string _executed_substage;
    PublishPhase _publish_phase = PublishPhase::PREPARE;
    size_t _publish_cursor = 0;
    int32_t _publish_order_cursor = 0;
    int32_t _publish_line_cursor = 0;
    int64_t _publish_valuation_sat = 0;
    int64_t _publish_trade_alpha = 0;
    bool _publish_have_populated = false;
    TradePlanInitState _trade_plan_init;

    int32_t _cell_count = 0;
    int32_t _cells_per_slice = 256;
    bool _auto_slice_by_scale = true;
    int32_t _building_cells_per_slice = AUTO_BUILDING_CELLS_PER_SLICE;
    int32_t _building_groups_per_slice = 512;
    int32_t _building_plan_cells_per_slice_override = 0;
    int32_t _household_post_building_cells_per_slice_override = 0;
    int32_t _investment_cells_per_slice =
        AUTO_INVESTMENT_CELLS_PER_SLICE;
    int32_t _building_finalize_cells_per_slice =
        AUTO_BUILDING_FINALIZE_CELLS_PER_SLICE;
    int32_t _building_output_efficiency_q16 = Q16_ONE;
    bool _auto_building_slice_by_scale = true;
    int32_t _commands_per_slice = 16384;
    int32_t _epoch_days = 1;
    int32_t _configured_epoch_days = 0;
    int32_t _min_epoch_days = 5;
    int32_t _max_epoch_days = 365;
    int32_t _estimated_market_slices_per_epoch = 1;
    int32_t _estimated_building_slices_per_epoch = 0;
    int32_t _estimated_total_slices_per_epoch = 1;
    bool _workload_deadline_feasible = true;
    bool _workload_cycle_clamped = false;
    int64_t _configured_target_cohorts_per_slice = 0;
    int64_t _target_cohorts_per_slice = 30000;
    int32_t _commit_lag_budget_days = 0;
    int32_t _max_rules_per_plan = MAX_RULES_PER_PLAN;
    int64_t _wealth_reference_per_capita = MONEY_SCALE * 10;
    int32_t _living_cost_base_plan_id = -1;
    std::string _living_cost_base_plan_stable_id = "survival_household";
    std::vector<int32_t> _survival_food_need_stable_ids;
    std::vector<uint8_t> _survival_food_need_mask;
    std::vector<int32_t> _survival_required_need_indices;
    std::vector<uint8_t> _survival_food_good_mask;
    std::vector<uint8_t> _survival_staple_good_mask;
    std::vector<uint8_t> _survival_clothing_good_mask;
    int32_t _survival_staple_need_stable_id = -1;
    int32_t _survival_clothing_need_stable_id = -1;
    int32_t _starvation_satisfaction_threshold_q16 = Q16_ONE / 2;
    int32_t _survival_production_target_q16 = Q16_ONE;
    int64_t _starvation_death_rate_q32 = Q32_ONE / 200;
    int32_t _wage_ema_alpha_q16 = 8192;
    int32_t _wage_max_rise_q16_per_day = 1311;
    int32_t _wage_max_fall_q16_per_day = 1311;
    // Damping: contract wage floor may not exceed the building's per-employee
    // affordable revenue times this ratio (Q16). Prevents living-cost floor from
    // pushing wages far beyond what the employer can pay. 0 disables the cap.
    int32_t _wage_income_cap_ratio_q16 = 78643; // ~1.2x
    int32_t _employee_profit_share_q16 = 16384;
    int32_t _building_severe_loss_threshold_q16 = -16384;
    int32_t _building_severe_loss_cycles = 3;
    int32_t _building_restart_margin_q16 = 6554;
    int32_t _building_restart_cycles = 2;
    int32_t _merchant_procurement_cash_reserve_q16 = 8192;
    int32_t _merchant_market_making_days_q16 = Q16_ONE * 60;
    int32_t _merchant_credit_runtime_mode = 2; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int32_t _merchant_credit_exposure_q16 = 16384;
    int32_t _merchant_credit_premium_q16 = 3277;
    int32_t _merchant_credit_term_cycles = 6;
    int32_t _recovery_success_cycles = 2;
    int32_t _recovery_liquidation_failed_reviews = 6;
    int32_t _merchant_profession_id = -1;
    std::string _merchant_profession_stable_id = "merchant";
    // Reserved profession representing unemployed population. Resolved from the
    // catalog like the merchant profession; used by the employment pass to keep
    // laid-off / idle population in dedicated unemployed signatures instead of
    // deriving unemployment as population - owner - employee. Never a building role.
    int32_t _unemployed_profession_id = -1;
    std::string _unemployed_profession_stable_id = "unemployed";
    int32_t _market_runtime_mode = 1; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int32_t _trade_runtime_mode = 2; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int64_t _trade_capacity_per_merchant_q16 = 64 * Q16_ONE;
    int32_t _trade_speed_cost_per_day = 4;
    int32_t _trade_min_margin_q16 = 3277;
    int32_t _trade_target_count = 4;
    int32_t _trade_signal_pairs_per_slice = 4096;
    int32_t _trade_route_searches_per_slice = 32;
    int32_t _trade_max_route_expansions = 8192;
    int32_t _trade_route_cache_entries = 16384;
    int32_t _trade_max_signals = 32768;
    int32_t _trade_max_candidates = 8192;
    int32_t _trade_max_orders = 4096;
    int32_t _trade_flow_ema_alpha_q16 = 8192;
    int32_t _trade_max_stock_share_q16 = 16384;
    int32_t _trade_export_floor_days = 5;
    int32_t _trade_export_inventory_fraction_q16 = Q16_ONE / 2;
    int32_t _trade_import_fill_fraction_q16 = Q16_ONE / 2;
    int32_t _trade_response_days = 15;
    int32_t _investment_review_days = 10;
    int32_t _investment_min_shortage_q16 = Q16_ONE / 8;
    int32_t _investment_min_utilization_q16 = 42598;
    int32_t _investment_max_payback_days = 365;
    int32_t _investment_operating_cycles = 2;
    int32_t _investment_gap_fill_share_q16 = Q16_ONE / 4;
    int32_t _investment_portfolio_max_types = 4;
    int32_t _investment_max_type_owner_share_q16 = Q16_ONE / 2;
    int32_t _investment_max_growth_share_q16 = 6554;
    int32_t _investment_new_type_seed_buildings = 1;
    int32_t _investment_merchant_transition_min_improvement_q16 = Q16_ONE / 2;
    int32_t _investment_sparse_mode = 2;
    int32_t _recovery_liquidation_max_share_q16 = Q16_ONE / 4;
    int32_t _resource_min_reserve_q16 = 22938;
    int32_t _resource_safe_harvest_q16 = Q16_ONE / 2;
    int32_t _resource_min_horizon_days = 3650;
    int32_t _bullion_monthly_issue_cap_q16 = 655;
    int32_t _producer_support_monthly_cap_q16 = 3277;
    bool _worker_enabled = true;
    int32_t _worker_market_threshold = 256;
    int32_t _worker_tasks_hint = 0;
    int32_t _worker_task_cap = 6;
    bool _high_speed_batching_enabled = true;
    int32_t _full_audit_verify_interval_days = 25;
    // Closing audit mode: 0=FULL, 1=PROBE, 2=INCREMENTAL.
    int32_t _closing_audit_mode = 2;
    bool _closing_audit_runtime_disabled = false;
    bool _closing_audit_force_full = true;
    bool _closing_audit_incremental_this_epoch = false;
    // Accuracy policy: 0=EXACT, 1=BALANCED, 2=FAST, 3=CUSTOM.
    // Runtime mode: 0=OFF, 1=PROBE (exact authority), 2=ACTIVE.
    int32_t _accuracy_preset = 1;
    int32_t _approximation_runtime_mode = 2;
    int32_t _accuracy_max_regret_q16 = 1966;
    int32_t _accuracy_household_tail_share_q16 = 655;
    int32_t _accuracy_candidate_top_k = 2;
    int32_t _accuracy_choice_temperature_q16 = 983;
    int32_t _accuracy_exact_probe_rate_q16 = 655;
    int32_t _accuracy_fallback_cooldown_epochs = 10;
    int64_t _seed = 0;
    int64_t _catalog_hash = 0;
    int64_t _catalog_compat_hash_v6 = 0;
    int64_t _epoch_id = 0;
    int64_t _sample_day = -1;
    int64_t _current_day = -1;
    int64_t _commit_day = -1;
    int64_t _last_committed_day = -1;
    int64_t _explicit_money_mint = 0;
    int64_t _explicit_money_burn = 0;
    int64_t _external_population_delta = 0;
    int64_t _explicit_stock_delta = 0;
    int64_t _consumed_goods = 0;
    int64_t _births = 0;
    int64_t _deaths = 0;
    int64_t _saturation_count = 0;
    uint64_t _next_submit_order = 1;

    int32_t _cell_cursor = 0;
    int32_t _command_cursor = 0;
    int32_t _structural_cursor = 0;
    int32_t _building_cell_cursor = 0;
    int32_t _building_plan_phase = 0;
    int32_t _household_market_phase = 0;
    int32_t _household_post_cursor = 0;
    int32_t _building_commit_phase = 0;
    int32_t _building_commit_cursor = 0;
    int32_t _building_finalize_phase = 0;
    int32_t _processed_cells = 0;
    int64_t _processed_cohorts = 0;
    int64_t _processed_rules = 0;
    int64_t _processed_needs = 0;
    int64_t _processed_variants = 0;
    int64_t _processed_components = 0;
    int64_t _processed_commands = 0;
    int64_t _rejected_commands = 0;
    int64_t _merchant_repairs = 0;
    int64_t _price_cap_hits = 0;
    int64_t _price_cost_anchor_hits = 0;
    int64_t _price_inactive_reversions = 0;
    int64_t _continuation_slices = 0;
    int64_t _processed_building_groups = 0;
    int64_t _filled_owner_jobs = 0;
    int64_t _filled_employee_jobs = 0;
    int64_t _unemployed_population = 0;
    int64_t _construction_goods_consumed = 0;
    int64_t _building_structure_count_only_updates = 0;
    int64_t _building_structure_new_groups = 0;
    int64_t _building_structure_removed_groups = 0;
    int64_t _building_structure_topology_rebuilds = 0;
    int64_t _building_structure_role_span_reuses = 0;
    int64_t _building_structure_role_span_appends = 0;
    int64_t _building_investment_candidates = 0;
    int64_t _building_owner_mobility = 0;
    int64_t _building_owner_job_reallocations = 0;
    int64_t _building_owner_job_profession_changes = 0;
    int64_t _building_owner_job_probability_skips = 0;
    int64_t _building_investments_started = 0;
    int64_t _building_investment_blocked_funds = 0;
    int64_t _building_investment_blocked_materials = 0;
    int64_t _building_investment_blocked_sponsor_capital = 0;
    int64_t _building_investment_blocked_resources = 0;
    int64_t _building_investment_probability_skips = 0;
    int64_t _building_investment_capital_transferred = 0;
    int64_t _building_investment_buildings_started = 0;
    int64_t _building_investment_portfolios_started = 0;
    int64_t _building_investment_types_started = 0;
    int64_t _building_investment_owner_population_moved = 0;
    int64_t _building_investment_max_type_owner_share_q16 = 0;
    int64_t _building_investment_demand_limited = 0;
    int64_t _building_investment_material_limited = 0;
    int64_t _building_investment_capital_limited = 0;
    int64_t _building_investment_owner_population_limited = 0;
    int64_t _desired_business_demand = 0;
    int64_t _funded_business_demand = 0;
    int64_t _unfunded_business_demand = 0;
    int64_t _owner_working_capital_allocated = 0;
    int64_t _merchant_credit_budget = 0;
    int64_t _merchant_credit_committed = 0;
    int64_t _merchant_credit_drawn = 0;
    int64_t _merchant_credit_repaid = 0;
    int64_t _merchant_credit_premium_repaid = 0;
    int64_t _merchant_credit_outstanding = 0;
    int64_t _merchant_credit_bad_debt = 0;
    int64_t _recovery_candidates = 0;
    int64_t _recovery_approved = 0;
    int64_t _recovery_restarted = 0;
    int64_t _recovery_failed = 0;
    int64_t _recovery_liquidated_buildings = 0;
    int64_t _recovery_partially_liquidated_buildings = 0;
    int64_t _recovery_fully_liquidated_groups = 0;
    int64_t _working_capital_scale_error_bound_q16 = 0;
    int64_t _production_inputs_consumed = 0;
    int64_t _production_output_stock = 0;
    int64_t _production_output_discarded = 0;
    int64_t _production_output_retained = 0;
    int64_t _production_output_supported = 0;
    int64_t _owner_output_consumed = 0;
    int64_t _producer_revenue = 0;
	int64_t _producer_support_money_issued = 0;
	int64_t _bullion_money_issued = 0;
	// Bullion (gold/silver) physically absorbed by the mint each epoch. The
	// monetary system consumes the sold batch: the coined goods leave market
	// stock instead of accumulating as ghost inventory. Tracked as an explicit
	// goods-conservation sink so closing stock stays balanced.
	int64_t _bullion_stock_consumed = 0;
	int64_t _gold_accepted = 0;
	int64_t _silver_accepted = 0;
	int64_t _gold_money_issued = 0;
	int64_t _silver_money_issued = 0;
	int64_t _cycle_flow_produced = 0;
	int64_t _cycle_flow_consumed = 0;
	int64_t _cycle_flow_discarded = 0;
    int64_t _building_wages_paid = 0;
    int64_t _building_wages_unpaid = 0;
    int64_t _building_base_wages_paid = 0;
    int64_t _building_base_wages_due = 0;
    int64_t _building_bonus_paid = 0;
    int64_t _building_bonus_due = 0;
    int64_t _wage_suspended_building_groups = 0;
    int64_t _loss_suspended_building_groups = 0;
    int64_t _merchant_procurement_budget = 0;
    int64_t _merchant_procurement_opportunity = 0;
    int64_t _merchant_procurement_allocated = 0;
    int64_t _merchant_procurement_unspent_allocated = 0;
    int64_t _merchant_procurement_reserved = 0;
    int64_t _owner_working_capital_reserved = 0;
    int64_t _merchant_procurement_spent = 0;
    int64_t _merchant_procurement_retail_value = 0;
    int64_t _merchant_procurement_factor_weighted_cash_q16 = 0;
    int64_t _merchant_survival_procurement_required = 0;
    int64_t _merchant_survival_procurement_allocated = 0;
    int64_t _merchant_input_procurement_required = 0;
    int64_t _merchant_input_procurement_allocated = 0;
    int64_t _merchant_trade_purchase_cash = 0;
    int64_t _merchant_trade_sale_cash = 0;
    std::vector<int64_t> _merchant_procurement_paid_by_cell;
    std::vector<int64_t> _merchant_procurement_retail_by_cell;
    std::vector<int64_t> _merchant_procurement_factor_weighted_cash_by_cell;
    std::vector<int64_t> _merchant_trade_purchase_by_cell;
    std::vector<int64_t> _merchant_trade_sale_by_cell;
    std::vector<int64_t> _merchant_credit_drawn_by_cell;
    int64_t _production_input_reserved = 0;
    int64_t _production_input_reserve_shortfall = 0;
    int64_t _labor_signal_updates = 0;
    int64_t _building_resource_generated = 0;
    int64_t _building_resource_consumed = 0;
    int64_t _building_resource_limited_groups = 0;
    int64_t _unprofitable_building_groups = 0;
    int64_t _zero_utilization_building_groups = 0;
    int64_t _utilization_sum_q16 = 0;
    int64_t _market_signal_updates = 0;
    int64_t _trade_route_expansions = 0;
    int64_t _trade_route_cache_hits = 0;
    int64_t _trade_route_cache_misses = 0;
    int64_t _trade_candidates_generated = 0;
    int64_t _trade_candidates_accepted = 0;
    int64_t _trade_rejected_profit = 0;
    int64_t _trade_rejected_no_spread = 0;
    int64_t _trade_rejected_margin = 0;
    int64_t _trade_quantity_profit_clips = 0;
    int64_t _trade_relief_candidates = 0;
    int64_t _trade_rejected_capacity = 0;
    int64_t _trade_rejected_stock = 0;
    int64_t _trade_rejected_cash = 0;
    int64_t _trade_rejected_route = 0;
    int64_t _trade_rejected_order_cap = 0;
    int64_t _trade_orders_dispatched = 0;
    int64_t _trade_orders_arrived = 0;
    int64_t _trade_unclaimed_orders = 0;
    int64_t _trade_capacity_available = 0;
    int64_t _trade_capacity_used = 0;
    int64_t _trade_settlement_lag_days = 0;
    int64_t _trade_plan_reset_count = 0;
    int64_t _trade_signal_max_age_days = 0;
    int64_t _trade_first_dispatch_delay_max_days = 0;
    int64_t _trade_response_deadline_misses = 0;
    int64_t _trade_response_deadline_misses_cumulative = 0;
    int64_t _trade_unresolved_no_attempt = 0;
    int64_t _trade_unresolved_no_spread = 0;
    int64_t _trade_unresolved_margin = 0;
    int64_t _trade_unresolved_route = 0;
    int64_t _trade_unresolved_stock = 0;
    int64_t _trade_unresolved_capacity = 0;
    int64_t _trade_unresolved_cash = 0;
    int64_t _trade_unresolved_order_cap = 0;
    int64_t _trade_active_keys_pruned = 0;
    int64_t _trade_deficit_episodes_started = 0;
    int64_t _trade_deficit_episodes_resolved = 0;
    int64_t _trade_candidates_stale_generation = 0;
    int64_t _trade_candidates_arbitrated_out = 0;
    int64_t _trade_true_source_stock_failures = 0;
    int64_t _trade_topology_content_change_count = 0;
    std::string _trade_last_plan_reset_reason = "none";
    int64_t _building_resource_capacity_checks = 0;
    int64_t _building_resource_capacity_limited_groups = 0;
    std::string _last_building_rejection_reason;
    int32_t _worker_tasks = 1;
    int32_t _production_worker_tasks = 1;
    int32_t _market_worker_tasks_max = 1;
    int64_t _market_worker_task_sum = 0;
    int64_t _market_worker_dispatches = 0;
    int32_t _production_worker_tasks_max = 1;
    int64_t _production_worker_task_sum = 0;
    int64_t _production_worker_dispatches = 0;
    int64_t _production_worker_parallel_dispatches = 0;
    int64_t _production_worker_weight_total = 0;
    int64_t _production_worker_task_weight_min = 0;
    int64_t _production_worker_task_weight_max = 0;
    int64_t _production_worker_imbalance_q16_max = 0;
    double _production_worker_cpu_ms = 0.0;
    int32_t _audit_worker_tasks_max = 1;
    int64_t _audit_worker_dispatches = 0;
    double _audit_worker_cpu_ms = 0.0;
    int32_t _building_plan_worker_tasks_max = 1;
    int64_t _building_plan_worker_parallel_dispatches = 0;
    double _building_plan_worker_cpu_ms = 0.0;
    int64_t _opening_audit_fast_paths = 0;
    int64_t _opening_audit_full_verifications = 0;
    int64_t _closing_audit_fast_paths = 0;
    int64_t _closing_audit_full_verifications = 0;
    int64_t _closing_audit_mismatches = 0;
    int64_t _closing_audit_population_full_scan_entries = 0;
    int64_t _closing_audit_market_full_scan_entries = 0;
    AuditTotals _incremental_closing_totals;
    std::vector<int64_t> _audit_shadow_population;
    std::vector<int64_t> _audit_shadow_funds;
    std::vector<int64_t> _audit_shadow_market_stock;
    std::vector<uint32_t> _audit_population_lane_stamp;
    std::vector<uint32_t> _audit_market_lane_stamp;
    std::vector<size_t> _audit_population_touched_lanes;
    std::vector<size_t> _audit_market_touched_lanes;
    uint32_t _audit_mutation_generation = 0;
    std::string _closing_audit_mismatch_ledger = "none";
    int64_t _closing_audit_mismatch_lane = -1;
    int64_t _investment_scheduled_review_cells = 0;
    int64_t _investment_review_cells = 0;
    int64_t _investment_type_evaluations = 0;
    int64_t _investment_market_signal_rejections = 0;
    int64_t _investment_ethnicity_evaluations = 0;
    int64_t _investment_sparse_considered_types = 0;
    int64_t _investment_sparse_selected_types = 0;
    int64_t _investment_sparse_skipped_types = 0;
    int64_t _investment_sparse_mismatches = 0;
    int64_t _investment_sparse_dense_fallbacks = 0;
    int64_t _approximation_decisions = 0;
    int64_t _approximation_exact_probes = 0;
    int64_t _approximation_certificate_failures = 0;
    int64_t _approximation_exact_fallbacks = 0;
    int64_t _approximation_frontier_candidates = 0;
    int64_t _approximation_frontier_pruned = 0;
    int64_t _approximation_max_observed_regret_q16 = 0;
    int64_t _approximation_probe_violations = 0;
    int64_t _approximation_probe_max_spend_error_q16 = 0;
    int64_t _approximation_probe_max_demand_error_q16 = 0;
    int32_t _approximation_cooldown_epochs_left = 0;
    int32_t _approximation_low_prune_epochs = 0;
    int32_t _active_batch_multiplier = 1;
    int64_t _high_speed_market_dispatches_saved = 0;
    int64_t _high_speed_production_dispatches_saved = 0;
    int64_t _budgeted_building_commit_phase_fusions = 0;
    int64_t _budgeted_publish_phase_fusions = 0;
    bool _investment_sparse_runtime_disabled = false;
    double _production_merge_ms = 0.0;
    double _production_worker_ms = 0.0;
    double _market_worker_ms = 0.0;
    double _market_merge_ms = 0.0;
    double _market_merge_aggregate_ms = 0.0;
    double _market_merge_trade_ms = 0.0;
    int64_t _market_result_allocation_growth_count = 0;
    int64_t _market_result_allocation_growth_bytes = 0;
    int64_t _production_result_allocation_growth_count = 0;
    int64_t _production_result_allocation_growth_bytes = 0;
    int32_t _rolling_phase = 0;
    int32_t _rolling_due_cells = 0;
    int32_t _rolling_processed_cells = 0;
    int32_t _rolling_deferred_cells = 0;
    int64_t _settlement_watermark = -1;
    int64_t _settlement_newest_day = -1;
    int64_t _settlement_max_age_days = 0;
    int64_t _rolling_deadline_violations = 0;

    int32_t _trace_mode = TRACE_SELECTIVE;
    int64_t _trace_memory_budget = 32LL * 1024 * 1024;
    int32_t _trace_retention_epochs = 8;
    int64_t _trace_detail_epoch_budget = 8LL * 1024 * 1024;
    int32_t _trace_poll_max_events = 4096;
    std::vector<uint8_t> _trace_cell_mask;
    std::vector<uint8_t> _pending_trace_cell_mask;
    bool _trace_filter_pending = false;
    int32_t _inspector_trace_cell = -1;
    int32_t _pending_inspector_trace_cell = -1;
    bool _inspector_trace_pending = false;
    EventBatch _staging_events;
    std::deque<EventBatch> _committed_event_batches;
    std::deque<AuditFrame> _audit_history;
    std::unordered_map<std::string, int64_t> _event_consumer_ack;
    int64_t _next_event_id = 1;
    int64_t _event_evicted_count = 0;
    int64_t _first_evicted_event_id = 0;
    int64_t _trace_detail_truncated = 0;
    int64_t _trace_uncommitted_discarded = 0;
    uint64_t _event_stream_hash = 1469598103934665603ULL;
    double _event_summary_ms = 0.0;
    double _event_detail_ms = 0.0;
    double _event_publish_ms = 0.0;
    EventArchiveState _event_archive;

    double _formula_ms = 0.0;
    double _clear_ms = 0.0;
    double _ledger_ms = 0.0;
    double _fallback_ms = 0.0;
    double _merchant_settle_ms = 0.0;
    double _price_ms = 0.0;
    double _structure_ms = 0.0;
    double _publish_ms = 0.0;
    double _employment_ms = 0.0;
    double _production_ms = 0.0;
    double _building_plan_ms = 0.0;
    double _building_plan_evaluate_ms = 0.0;
    double _building_plan_reserve_ms = 0.0;
    double _building_structure_group_merge_ms = 0.0;
    double _building_structure_market_cache_ms = 0.0;
    double _building_structure_labor_cache_ms = 0.0;
    double _investment_ms = 0.0;
    double _market_signal_ms = 0.0;
    double _market_signal_insert_ms = 0.0;
    double _market_signal_flush_ms = 0.0;
    int64_t _market_signal_insert_count = 0;
    double _wage_plan_ms = 0.0;
    double _labor_signal_ms = 0.0;
    double _trade_plan_ms = 0.0;
    double _trade_plan_scan_body_ms = 0.0;
    double _trade_plan_scan_finalize_ms = 0.0;
    double _trade_plan_route_prepare_ms = 0.0;
    double _trade_plan_route_expand_ms = 0.0;
    double _trade_plan_route_finalize_ms = 0.0;
    int64_t _trade_plan_scan_pairs_slice = 0;
    int64_t _trade_plan_route_sources_prepared_slice = 0;
    int64_t _trade_plan_route_expansions_slice = 0;
    int64_t _trade_plan_candidates_finalized_slice = 0;
    double _trade_settle_ms = 0.0;
    double _trade_dispatch_ms = 0.0;
    double _epoch_begin_ms = 0.0;
    double _epoch_preflight_ms = 0.0;
    double _prepare_ms = 0.0;
    double _audit_ms = 0.0;
    double _watermark_ms = 0.0;
    std::array<double, static_cast<size_t>(PublishPhase::COUNT)> _publish_phase_ms{};
    std::array<int64_t, static_cast<size_t>(PublishPhase::COUNT)> _publish_phase_work{};
    std::array<double, static_cast<size_t>(PublishPhase::COUNT)> _publish_slice_phase_ms{};
    std::array<int64_t, static_cast<size_t>(PublishPhase::COUNT)> _publish_slice_phase_work{};
    std::array<double, BUILDING_COMMIT_PHASE_COUNT> _building_commit_slice_phase_ms{};
    std::array<int64_t, BUILDING_COMMIT_PHASE_COUNT> _building_commit_slice_phase_work{};

    AuditTotals _opening_totals;
    AuditTotals _closing_totals;
    AuditTotals _publish_accum;
    PopulationStore _population;
    MarketStore _market;
    MarketSignalStore _market_signals;
    MarketSignalStore _market_signals_rebuild_scratch;
    std::vector<int64_t> _epoch_business_demand_ema;
    std::vector<int64_t> _epoch_desired_business_demand;
    std::vector<int64_t> _epoch_funded_business_demand;
    std::vector<int64_t> _epoch_offered_supply_ema;
    // Current-cycle producer absorption diagnostics, aligned to the sparse
    // (cell, good) market-signal lanes. These are transient and excluded from
    // PKEC and the authoritative state hash.
    std::vector<int64_t> _epoch_producer_sellable_current;
    std::vector<int64_t> _epoch_producer_merchant_sold_current;
    std::vector<int64_t> _epoch_producer_discarded_current;
    std::vector<int64_t> _epoch_nonhousehold_withdrawals;
    std::vector<int32_t> _epoch_cost_anchor_price;
    std::vector<int64_t> _production_input_reserve;
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
    std::vector<int64_t> _cell_last_settlement_day;
    std::vector<uint32_t> _cell_settlement_generation;
    std::vector<uint32_t> _cell_price_stock_gen;
    std::vector<uint32_t> _cell_owner_cash_gen;
    std::vector<uint32_t> _cell_population_gen;
    std::vector<uint32_t> _cell_building_structure_gen;
    std::vector<uint32_t> _cell_technology_gen;
    std::vector<uint32_t> _cell_resource_gen;
    std::vector<uint32_t> _cell_trade_gen;
    // Transaction worksets are deterministic, sorted and never persisted.
    std::vector<int32_t> _epoch_market_ids;
    std::vector<int64_t> _epoch_market_work_weights;
    std::vector<int32_t> _epoch_settlement_cells;
    std::vector<int32_t> _epoch_building_cells;
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
    std::vector<int64_t> _building_funded_capacity_q16;
    std::vector<int64_t> _building_working_capital_allocated;
    std::vector<int64_t> _building_owner_livelihood_credit;
    std::vector<int64_t> _building_merchant_credit_limit;
    // Suspended producers keep a bounded upstream demand signal without
    // retaining labor. Permanent liquidation is reviewed only when a probe is
    // physically and financially executable but still economically unviable.
    std::vector<int64_t> _building_recovery_probe_capacity_q16;
    std::vector<uint8_t> _building_recovery_liquidation_eligible;
    std::vector<int64_t> _building_investment_score_q16;
    std::vector<int64_t> _building_investment_payback_days;
    std::vector<int32_t> _building_investment_rejection;
    // Bounded cold-path diagnostics for the one inspector-selected cell. These
    // are transient, excluded from save/hash, and include absent building types.
    int32_t _investment_diagnostic_cell = -1;
    int64_t _investment_diagnostic_day = -1;
    std::vector<InvestmentDiagnostic> _investment_diagnostics;
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
    std::vector<int32_t> _investment_employment_cells;
    std::vector<int32_t> _investment_review_cell_indices;
    // Catalog-derived output-good -> building-type CSR plus per-market active
    // output bitsets. These lanes are rebuildable scheduling data and are
    // excluded from PKEC and the authoritative state hash.
    std::vector<int32_t> _investment_good_type_offsets;
    std::vector<int32_t> _investment_good_type_indices;
    std::vector<uint64_t> _investment_active_good_words;
    std::vector<uint32_t> _investment_type_stamp;
    std::vector<uint32_t> _investment_good_stamp;
    uint32_t _investment_review_stamp_generation = 0;
    std::vector<int32_t> _investment_review_types_scratch;
    std::vector<int32_t> _investment_good_queue_scratch;
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
    TradeOrderStore _trade_orders;
    TradeFlowSignalStore _trade_flows;
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
    std::vector<EnvironmentCurve> _environment_curves;
    std::vector<std::string> _need_ids;
    std::vector<int32_t> _ethnicity_need_factor_q16;
    std::vector<Rule> _rules;
    std::vector<int64_t> _rule_params;
    std::vector<std::string> _profession_ids;
    std::vector<int32_t> _profession_technology_offsets;
    std::vector<int32_t> _profession_required_technologies;
    std::vector<std::string> _ethnicity_ids;
    std::vector<std::string> _good_ids;
    std::vector<std::string> _plan_ids;
    std::vector<int32_t> _good_default_price;
    std::vector<int64_t> _good_default_stock;
    std::vector<int32_t> _good_min_price;
    std::vector<int32_t> _good_max_price;
    std::vector<int32_t> _good_price_adjust_q16;
    std::vector<int32_t> _good_demand_price_elasticity_q16;
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
    std::vector<int32_t> _environment_temperature_q16;
    std::vector<int32_t> _environment_moisture_q16;
    std::vector<int32_t> _environment_snow_q16;
    std::vector<int32_t> _environment_weather_q16;
    std::vector<int32_t> _building_elevation_q16;
    std::vector<uint8_t> _building_terrain;
    std::vector<uint8_t> _building_landform;
    std::vector<uint8_t> _building_vegetation;
    std::vector<uint8_t> _building_is_water;
    std::vector<uint8_t> _building_has_river;
    std::vector<int32_t> _building_neighbors;
    std::vector<int64_t> _resource_snapshot;
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
    std::vector<int64_t> _resource_deltas;
    std::vector<uint32_t> _resource_lane_generation;
    std::vector<size_t> _resource_touched_lanes;
    std::vector<size_t> _last_published_resource_touched_lanes;
    uint32_t _resource_current_generation = 0;
    // Debug/recording visibility for the most recently published building
    // resource changes. It is derived epoch output, not save/hash authority.
    std::vector<int64_t> _last_published_resource_deltas;
    std::vector<std::string> _resource_ids;
    std::vector<std::string> _resource_reserve_slots;
    std::vector<std::string> _resource_extra_slots;
    int64_t _building_context_day = -1;
    bool _resource_deltas_ready = false;
    int64_t _environment_day = -1;
    int64_t _environment_hash = 0;
    std::vector<int32_t> _market_cell_offsets;
    std::vector<int32_t> _market_cells;
    std::vector<Command> _pending_commands;
    std::vector<Command> _epoch_commands;
    std::vector<StructuralCommand> _structural_commands;
    std::vector<CellSummary> _committed_cells;
    std::vector<CellSummary> _staging_cells;
    std::vector<int32_t> _staging_touched_cells;
    std::vector<uint32_t> _staging_cell_generation;
    uint32_t _staging_current_generation = 0;
    std::vector<int32_t> _structural_touched_cells;
    std::vector<int32_t> _population_changed_cells;
    int64_t _structural_funds_to_treasury = 0;

    std::vector<std::string> _building_type_ids;
	std::vector<int32_t> _building_kinds;
	std::vector<std::string> _building_upgrade_family_ids;
	std::vector<int32_t> _building_upgrade_family_indices;
	std::vector<int32_t> _building_upgrade_tiers;
	std::vector<int32_t> _building_technology_tag_offsets;
	std::vector<std::string> _building_technology_tags;
    std::vector<int32_t> _building_technology_offsets;
    std::vector<int32_t> _building_required_technologies;
    std::vector<std::string> _technology_ids;
    int32_t _technology_words = 0;
    NativeCountryRuntime *_country_runtime = nullptr;
    std::vector<int32_t> _epoch_cell_country;
    std::vector<uint64_t> _epoch_country_technologies;
    // Epoch-transient country/type availability cache. Technology authority is
    // frozen once per daily transaction, so every cell in a country shares the
    // same result and hot loops can consume the ascending CSR directly.
    std::vector<uint8_t> _epoch_country_building_available;
    std::vector<uint8_t> _epoch_country_good_available;
    std::vector<uint8_t> _epoch_country_profession_available;
    std::vector<uint8_t> _epoch_country_variant_available;
    std::vector<int32_t> _epoch_country_building_type_offsets;
    std::vector<int32_t> _epoch_country_building_type_indices;
    int32_t _epoch_country_count = 0;
    int32_t _epoch_country_technology_words = 0;
    uint64_t _epoch_country_generation = 0;
    uint64_t _epoch_country_hash = 0;
    uint64_t _epoch_country_topology_hash = 0;
    std::vector<BuildingType> _building_types;
    // Catalog-baked, sorted unique signal edges per building type. Topology
    // rebuilds consume these spans instead of walking nested recipe columns.
    std::vector<int32_t> _building_type_market_signal_goods;
    std::vector<int32_t> _building_type_labor_signal_professions;
    std::vector<JobRole> _building_employee_roles;
    std::vector<GoodAmount> _building_construction_goods;
    std::vector<ProductionInput> _building_inputs;
    std::vector<InputCandidate> _building_input_candidates;
    std::vector<GoodAmount> _building_outputs;
    std::vector<int32_t> _building_output_cost_shares_q16;
    std::vector<ResourceAmount> _building_resources;
    std::vector<ResourceAmount> _building_resource_generation;
    std::vector<ConditionToken> _building_conditions;
    std::vector<BuildingGroup> _buildings;
    // Transient topology scratch and reusable role/input spans. Structural
    // commits swap the compact group lane but keep authoritative role arrays
    // in place; these caches are reconstructed after configure/restore.
    std::vector<BuildingGroup> _building_groups_rebuild_scratch;
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
    // Transient CSR baked from stable building order. Recovery reviews touch
    // only the current cell-modulo-review bucket instead of scanning all groups.
    std::vector<int32_t> _building_review_phase_offsets;
    std::vector<int32_t> _building_review_group_indices;
    std::vector<int32_t> _building_special_reset_group_indices;
    std::vector<int64_t> _building_employee_filled;
    // Inspector-only last purchased good per (building group, input slot).
    // This diagnostic lane is intentionally excluded from save and state hash.
    std::vector<int32_t> _building_last_input_selected_goods;
    std::vector<int64_t> _building_role_contract_wage;
    std::vector<int64_t> _building_role_base_living_cost;
    std::vector<int64_t> _building_role_living_cost;
    std::vector<int64_t> _building_role_local_average_wage;
    std::vector<int64_t> _building_role_base_wage_due;
    std::vector<int64_t> _building_role_base_wage_paid;
    std::vector<int64_t> _building_role_bonus_due;
    std::vector<int64_t> _building_role_bonus_paid;
    std::vector<PendingConstruction> _pending_construction;
    // Epoch-transient stable CSR over pending construction. This removes the
    // previous all-pending scan from every active building cell.
    std::vector<int32_t> _pending_construction_cell_offsets;
    std::vector<int32_t> _pending_construction_cell_indices;
    int64_t _building_catalog_hash = 0;
    int64_t _building_catalog_compat_hash_v6 = 0;
    int64_t _building_catalog_compat_hash_v7 = 0;
    int64_t _building_catalog_compat_hash_v13 = 0;
    int64_t _catalog_compat_hash_v7 = 0;
    int64_t _catalog_compat_hash_v8 = 0;
    int64_t _catalog_compat_hash_v10 = 0;
    int64_t _catalog_compat_hash_v13 = 0;

    SaveState _save;
    RestoreState _restore;

    void register_builtin_formulas();
    bool compile_catalog(const godot::Dictionary &catalog, std::string &error);
    bool configure_profile(const godot::Dictionary &profile, std::string &error);
    godot::Dictionary run_slice_internal(const godot::Dictionary &ctx, bool compact);
    godot::Dictionary compact_report() const;
    bool start_epoch(int64_t day_index, std::string &error);
    bool trade_planner_should_run() const;
    bool run_trade_planner_slice(int64_t &work_done, std::string &error);
    bool begin_trade_plan_slice(int64_t &work_done, std::string &error);
    bool route_trade_source(int32_t source_index, int32_t expansion_budget,
                            int32_t &expansions_done, bool &source_done,
                            std::string &error);
    int32_t cached_trade_route_cost(int32_t source, int32_t destination,
                                    int32_t country, int32_t &expansions);
    int32_t estimate_trade_price(int32_t market, int32_t good,
                                 int64_t stock_after, int64_t &sat) const;
    int64_t trade_relief_pressure_q16(int32_t market, int32_t good,
                                      int64_t &sat) const;
    int64_t trade_local_stock_target(int32_t market, int32_t good,
                                     int64_t &sat) const;
    int64_t trade_export_floor(int32_t market, int32_t good,
                               int64_t &sat) const;
    int64_t profitable_trade_quantity(int32_t source, int32_t destination,
                                      int32_t good, int64_t max_quantity,
                                      bool relief_route, int32_t &source_price,
                                      int32_t &destination_price,
                                      int64_t &profit, int64_t &margin_q16,
                                      int64_t &sat) const;
    int64_t merchant_inventory_target(int32_t market, int32_t good,
                                      int32_t signal_index,
                                      int64_t realized_withdrawal,
                                      int64_t export_ema,
                                      int64_t cold_start_daily_supply,
                                      int64_t &sat) const;
    int64_t merchant_procurement_quota(int32_t market, int32_t good,
                                       int32_t signal_index,
                                       int64_t sellable,
                                       int64_t target,
                                       int64_t stock,
                                       int64_t realized_withdrawal,
                                       int64_t export_ema,
                                       int64_t &sat) const;
    int32_t effective_merchant_buy_factor_q16(
        int32_t market, int32_t good, int64_t target, int64_t stock,
        int64_t &sat) const;
    bool settle_due_trade_orders(std::string &error);
    bool dispatch_trade_candidates(std::string &error);
    void update_trade_flow_ema();
    int32_t trade_flow_index(int32_t cell, int32_t good, bool create);
    int32_t trade_signal_clock_index(int32_t cell, int32_t good) const;
    int32_t ensure_trade_signal_clock_index(int32_t cell, int32_t good);
    void ensure_trade_signal_clock_keys_bulk(
        const std::vector<uint64_t> &sorted_unique_keys);
    void record_trade_signal_attempt(int32_t cell, int32_t good, int32_t reason);
    void refresh_trade_response_diagnostics();
    int64_t credit_trade_sellers(int32_t order_index, int64_t amount);
    void rebuild_trade_arrival_buckets();
    void compact_trade_orders(const std::vector<uint8_t> &remove);
    int64_t trade_transit_goods() const;
    int64_t trade_escrow_cash() const;
    bool apply_command(const Command &cmd, std::string &error);
    bool process_market_cell(int32_t market, MarketResult &result, std::string &error);
    bool commit_structural(const StructuralCommand &cmd, std::string &error);
    // Core cohort migration primitive extracted from commit_structural. Moves up
    // to `requested_pop` people from `source` into the (dest_cell, dest_signature)
    // cohort, carrying a proportional share of funds/income/expense/ema/residual,
    // population-weighting needs_satisfaction, and transferring any rounding
    // residue of a fully-drained source to the treasury (never burned). Pushes
    // both cells onto _structural_touched_cells and appends a structural trace.
    // Callers are responsible for command-level guards (profession_available,
    // same-cell/same-signature no-op) before invoking it. Returns false only on a
    // hard failure (allocation / treasury transfer); an empty move is a no-op true.
    //
    // `source_drained_out` (optional): set to true when the move emptied `source`
    // and released its slot, false otherwise. The employment pass (in-line layoff
    // / hiring) iterates a *snapshot* of a cell's slots -- it must never migrate
    // from inside for_each_in_cell -- and uses this flag to skip a snapshot slot
    // that a prior migration in the same loop already released, preventing
    // stale-slot reuse. When null it is ignored (commit_structural path).
    bool move_cohort_population(int32_t source, int32_t dest_cell,
                                int32_t dest_signature, int64_t requested_pop,
                                std::string &error,
                                bool *source_drained_out = nullptr);
    bool publish_epoch_slice(int64_t &work_done, std::string &error);
    void reset_publish_state();
    bool compile_building_catalog(const godot::Dictionary &catalog, std::string &error);
    bool evaluate_building_conditions(int32_t type_id, int32_t cell) const;
    bool cell_has_technology(int32_t cell, int32_t technology_id, bool frozen) const;
    bool cell_has_requirements(int32_t cell, int32_t begin, int32_t end,
                               const std::vector<int32_t> &requirements,
                               bool frozen) const;
    bool good_available(int32_t cell, int32_t good_id, bool frozen = true) const;
    bool profession_available(int32_t cell, int32_t profession_id,
                              bool frozen = true) const;
    bool building_available(int32_t cell, int32_t type_id,
                            bool frozen = true) const;
    bool building_constructible(int32_t cell, int32_t type_id,
                                bool frozen = true) const;
    // O(1) signature lookup helpers backed by _signature_by_profession_ethnicity.
    // Return -1 when no such signature exists (e.g. unemployed profession absent).
    inline int32_t signature_for_profession_ethnicity(int32_t profession_id,
                                                       int32_t ethnicity_id) const {
        if (profession_id < 0 || ethnicity_id < 0) return -1;
        const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());
        if (ethnicity_id >= n_eth) return -1;
        const size_t idx = static_cast<size_t>(profession_id) * static_cast<size_t>(n_eth) +
                           static_cast<size_t>(ethnicity_id);
        if (idx >= _signature_by_profession_ethnicity.size()) return -1;
        return _signature_by_profession_ethnicity[idx];
    }
    inline int32_t unemployed_signature_for_ethnicity(int32_t ethnicity_id) const {
        return signature_for_profession_ethnicity(_unemployed_profession_id, ethnicity_id);
    }
    bool capture_country_epoch(std::string &error);
    bool apply_build_command(const Command &cmd, int32_t owner_slot,
                             std::string &error, bool allow_obsolete_tier = false);
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
    int32_t find_entrepreneur_source(int32_t cell, int32_t target_signature,
                                     int64_t required_capital,
                                     int64_t target_income_per_day,
                                     int64_t target_living_cost_per_day,
                                     int64_t owner_slots_per_building,
                                     int32_t building_type_id,
                                     bool &had_eligible_sponsor,
                                     int64_t &willing_population,
                                     int64_t &transferable_capital,
                                     int64_t &income_improvement_q16) const;
    int64_t projected_owner_income_per_day(const BuildingGroup &group,
                                           int64_t &sat) const;
    int64_t planned_owner_demand(const BuildingGroup &group,
                                 int64_t &sat) const;
    int64_t building_debt_due(const BuildingGroup &group, int64_t &sat) const;
    int64_t repay_building_debt(int32_t cell, int32_t owner_slot,
                                BuildingGroup &group, int64_t payment_cap,
                                int64_t &premium_paid);
    int64_t available_resource_amount(const ResourceAmount &item, int32_t cell) const;
    void ensure_resource_lane(size_t index);
    void consume_resource_amount(const ResourceAmount &item, int32_t cell, int64_t quantity);
    bool resource_is_renewable(int32_t resource_id) const;
    int64_t renewable_safe_harvest(int32_t resource_id, int32_t cell) const;
    bool commit_ready_construction(std::vector<int32_t> &changed_cells,
                                   bool prune_empty_groups = true);
    void initialize_building_role_span(BuildingGroup &group);
    void release_building_role_span(const BuildingGroup &group);
    void rebuild_building_role_storage();
    void rebuild_building_cell_offsets();
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
    void rebuild_production_input_reserves(int32_t active_begin = 0,
                                           int32_t active_end = -1,
                                           bool initialize = true);
    void rebuild_labor_signals();
    int32_t labor_signal_index(int32_t cell, int32_t profession) const;
    int64_t living_cost_for_signature(int32_t cell, int32_t signature_id,
                                      int32_t plan_override, int64_t &sat) const;
    void compute_cell_living_costs_from_basis(
        int32_t cell, const std::vector<int64_t> &variant_scores,
        const std::vector<int64_t> &variant_prices,
        const std::vector<int64_t> &need_score_sums,
        const std::vector<int64_t> &need_environment, int64_t &sat);
    bool prepare_cell_wages(int32_t cell, std::string &error);
    void update_cell_labor_signals(int32_t cell);
    bool prepare_building_economic_plan(int32_t active_begin, int32_t active_end,
                                        BuildingPlanResult &result,
                                        std::string &error);
    int32_t market_signal_index(int32_t cell, int32_t good) const;
    PricePressure price_pressure(int32_t market, int32_t good, int64_t household_demand,
                                 int64_t stock, int64_t shortage_q16,
                                 int32_t signal_index, int64_t &saturation_count) const;
    int64_t next_price_v4(int32_t good, int64_t current_price,
                          const PricePressure &pressure, int32_t days,
                          int64_t &saturation_count, bool &rate_clamped) const;
    int32_t find_building_group(int32_t cell, int32_t type_id,
                                int32_t owner_signature_id) const;
    int32_t find_cohort_slot(int32_t cell, int32_t signature_id) const;
    int64_t credit_local_merchants(int32_t cell, int64_t amount,
                                   int32_t cashflow_source = CASHFLOW_MERCHANT_BUSINESS,
                                   int64_t *saturation_override = nullptr);
    int64_t debit_local_merchants(int32_t cell, int64_t amount,
                                  int32_t cashflow_source = CASHFLOW_MERCHANT_PROCUREMENT,
                                  int64_t *saturation_override = nullptr);
    int64_t pay_building_wage_amount(int32_t cell, int32_t owner_slot,
                                     int32_t profession_id, int64_t filled_jobs,
                                     int64_t due, int64_t payment_cap,
                                     int64_t *saturation_override = nullptr);
    void fail(const std::string &reason);
    void clear_epoch_metrics();
    void capture_completed_perf_snapshot();
    void rebuild_committed_summaries();
    CellSummary build_cell_summary(int32_t cell) const;
    void stage_cell_summary(int32_t cell, const CellSummary &summary);
    void finalize_market_result(int32_t market, MarketResult &result);
    void refresh_investment_active_goods_for_market(int32_t market,
                                                    int64_t &saturation_count);
    bool rebuild_market_cell_ranges(std::string &error);
    bool ensure_merchant_invariant(int32_t cell, int64_t &repair_count,
                                   std::string &error);
    bool rebuild_merchant_ranges(std::string &error);
    bool is_merchant_slot(int32_t slot) const;
    void touch_accounting_slot(int32_t slot);
    void rebuild_incremental_audit_shadow();
    void begin_incremental_audit_epoch();
    void audit_touch_population_lane(int32_t slot);
    void audit_touch_market_lane(size_t index);
    AuditTotals incremental_audit_totals() const;
    void commit_incremental_audit_shadow();
    void diagnose_incremental_audit_mismatch(const AuditTotals &full);
    AuditTotals audit_totals() const;
    int64_t memory_bytes() const;
    int32_t choose_epoch_days(int64_t cohort_count);
    int32_t building_slice_end(int32_t active_begin) const;
    int32_t building_slice_end(int32_t active_begin, int32_t cell_cap,
                               int32_t group_cap) const;
    int32_t building_plan_slice_end(int32_t active_begin) const;
    int32_t household_post_slice_end(int32_t active_begin) const;
    int32_t estimate_building_ranges() const;
    int32_t stage_progress_q16() const;
    const char *stage_name() const;
    const char *stage_name(Stage stage) const;
    const char *publish_phase_name(PublishPhase phase) const;
    const char *trade_plan_init_phase_name(TradePlanInitPhase phase) const;

    static int64_t saturating_add(int64_t a, int64_t b, int64_t &saturation_count);
    static int64_t saturating_sub(int64_t a, int64_t b, int64_t &saturation_count);
    static int64_t saturating_mul(int64_t a, int64_t b, int64_t &saturation_count);
    static int64_t mul_div_sat(int64_t a, int64_t b, int64_t divisor,
                               int64_t &saturation_count);
    static int64_t pow_q16(int64_t ratio_q16, int64_t exponent_q16,
                           int64_t &saturation_count);
    int32_t sample_environment_curve(int32_t curve_id, int32_t cell) const;
    int32_t sample_environment_curve(int32_t curve_id,
                                     const EnvironmentSample &sample) const;
    EnvironmentSample environment_sample_for_cell(int32_t cell) const;
    static EnvironmentSample environment_sample_from_float(float temperature,
                                                            float moisture,
                                                            float snow_cover,
                                                            float weather_intensity,
                                                            bool ready);
    int64_t variant_unit_price(int32_t market, int32_t variant_id,
                               int64_t &saturation_count) const;
    void build_demand_basis(int32_t market, const EnvironmentSample &sample,
                            std::vector<int64_t> &variant_scores,
                            std::vector<int64_t> &variant_prices,
                            std::vector<int64_t> &need_score_sums,
                            std::vector<int64_t> &need_composites,
                            std::vector<int64_t> &need_environment,
                            int64_t &saturation_count) const;
    void build_demand_basis_cached(int32_t cell, int32_t market,
                                   const EnvironmentSample &sample,
                                   std::vector<int64_t> &variant_scores,
                                   std::vector<int64_t> &variant_prices,
                                   std::vector<int64_t> &need_score_sums,
                                   std::vector<int64_t> &need_composites,
                                   std::vector<int64_t> &need_environment,
                                   int64_t &saturation_count);
    void prepare_due_demand_basis_cache();
    int64_t desired_need_units(int32_t slot, int32_t need_index, int32_t dt_days,
                               int64_t environment_factor_q16,
                               int64_t composite_factor_q16,
                               int64_t &saturation_count) const;
    int64_t desired_need_units_for_funds(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t funds, int64_t &saturation_count) const;
    void compute_cohort_demand_preview(
        int32_t slot, int32_t market, const EnvironmentSample &sample,
        const std::vector<int32_t> *price_override, int64_t funds_override,
        std::vector<int64_t> &good_per_capita_daily,
        int64_t &saturation_count) const;
    int64_t survival_required_units(int32_t slot, int32_t stable_need_id,
                                    int32_t dt_days,
                                    const EnvironmentSample &sample,
                                    int64_t &saturation_count) const;
    godot::Dictionary population_cell_snapshot_impl(
        int32_t cell_idx, const EnvironmentSample &sample) const;
    static void formula_fixed_per_capita(const FormulaBatchInput &in, int64_t *out,
                                         int64_t &saturation_count);
    static void formula_income_price_linear(const FormulaBatchInput &in, int64_t *out,
                                            int64_t &saturation_count);

    bool decode_restore_chunk(const std::vector<uint8_t> &bytes, std::string &error);

    bool trace_detail_for_cell(int32_t cell) const;
    void trace_record_cashflow(int32_t cell, uint64_t cohort_handle, int32_t source,
                               int64_t income, int64_t expense);
    void trace_reconcile_inspector_cashflows();
    void trace_begin_epoch();
    void trace_append(int32_t kind, int32_t stage, int32_t cell,
                      int32_t subject_kind, int64_t subject_id,
                      int32_t subject_i0, int32_t subject_i1,
                      int64_t value0, int64_t value1, int64_t value2,
                      int64_t value3, const std::vector<EventLeg> *legs = nullptr,
                      int32_t flags = 0);
    void trace_commit_epoch(int64_t population_error, int64_t money_error,
                            int64_t goods_error);
    void trace_abort_epoch();
    void trace_evict_to_budget();
    int64_t trace_memory_bytes() const;
    static uint64_t trace_hash_mix(uint64_t hash, uint64_t value);
    static thread_local ProductionResult *_production_result_sink;
    static thread_local MarketResult *_market_result_sink;
};

} // namespace pk

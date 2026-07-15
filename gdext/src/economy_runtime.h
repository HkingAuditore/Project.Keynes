#pragma once

#include <algorithm>
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
    static constexpr int32_t SCHEMA_VERSION = 12;
    static constexpr int32_t PAGE_SIZE = 64;
    static constexpr int64_t MONEY_SCALE = 10000;
    static constexpr int64_t GOODS_SCALE = 1000;
    static constexpr int64_t Q16_ONE = 65536;
    static constexpr int64_t Q32_ONE = 4294967296LL;
    static constexpr int32_t MAX_RULES_PER_PLAN = 32;
    static constexpr int32_t MAX_NEEDS_PER_PLAN = 16;
    static constexpr int32_t MAX_VARIANTS_PER_NEED = 8;
    static constexpr int32_t MAX_COMPONENTS_PER_VARIANT = 4;
    static constexpr int32_t ENV_CURVE_SAMPLES = 17;

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
    bool capture_environment(int64_t day_index, const float *temperature,
                             const float *moisture, const float *snow_cover,
                             const float *weather_intensity, int32_t count,
                             std::string &error);
    bool needs_environment_capture(int64_t day_index) const {
        return !_epoch_active && day_index - _last_committed_day >= _epoch_days &&
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
        return !_epoch_active && day_index - _last_committed_day >= _epoch_days &&
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
        int32_t employee_fill_begin = 0;
        int32_t last_input_selection_begin = 0;
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
        uint8_t operating_state = 0; // 0=ACTIVE, 1=SUSPENDED_LOSS.
        uint8_t wage_suspended = 0;
    };

    struct PendingConstruction {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t count = 0;
        int64_t ready_day = 0;
        int64_t sequence = 0;
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
        std::vector<int64_t> business_demand_ema;
        std::vector<int64_t> offered_supply_ema;
        std::vector<int64_t> realized_withdrawal_ema;
        std::vector<int32_t> cost_anchor_price;

        void clear(int32_t cells) {
            cell_offsets.assign(static_cast<size_t>(std::max(0, cells)) + 1, 0);
            good_ids.clear();
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
        uint64_t component_country_generation = 0;
        bool ready = false;

        void clear() {
            neighbors.clear();
            passable.clear();
            enter_cost.clear();
            component.clear();
            topology_generation = 0;
            topology_hash = 0;
            component_country_generation = 0;
            ready = false;
        }
    };

    struct TradeSignal {
        int32_t cell = -1;
        int32_t good = -1;
        int32_t country = -1;
        int32_t price = 0;
        int64_t quantity = 0;
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
        uint64_t topology_generation = 0;
        uint64_t country_generation = 0;
    };

    struct TradePlanStore {
        enum Phase : int32_t { IDLE = 0, SCAN = 1, ROUTE = 2 };
        int32_t phase = IDLE;
        int64_t scan_cursor = 0;
        int32_t route_cursor = 0;
        int64_t scan_total = 0;
        uint64_t country_generation = 0;
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
        int64_t completed_scans = 0;

        void clear_transient() {
            phase = IDLE;
            scan_cursor = 0;
            route_cursor = 0;
            scan_total = 0;
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
            search_stamp = 0;
            completed_scans = 0;
            country_generation = 0;
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
        int64_t inventory_q16 = 0;
        int64_t shortage_q16 = 0;
        int64_t cost_q16 = 0;
        int64_t cost_floor_price = 0;
        int64_t idle_q16 = 0;
        int64_t total_q16 = 0;
        int64_t change_q16 = 0;
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
        int64_t transit_goods = 0;
        int64_t escrow_cash = 0;
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

    struct EventLeg;
    struct CashflowEntry;

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
        int64_t births = 0;
        int64_t deaths = 0;
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
        std::vector<StructuralCommand> structural_commands;
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
        int64_t bytes() const {
            return static_cast<int64_t>(events.capacity() * sizeof(EventRecord) +
                                        legs.capacity() * sizeof(EventLeg) +
                                        cashflows.capacity() * sizeof(CashflowEntry));
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

    int32_t _cell_count = 0;
    int32_t _cells_per_slice = 256;
    bool _auto_slice_by_scale = true;
    int32_t _commands_per_slice = 16384;
    int32_t _epoch_days = 1;
    int32_t _configured_epoch_days = 5;
    int32_t _max_epoch_days = 365;
    int64_t _configured_target_cohorts_per_slice = 0;
    int64_t _target_cohorts_per_slice = 30000;
    int32_t _commit_lag_budget_days = 0;
    int32_t _max_rules_per_plan = MAX_RULES_PER_PLAN;
    int64_t _wealth_reference_per_capita = MONEY_SCALE * 10;
    int32_t _living_cost_base_plan_id = -1;
    std::string _living_cost_base_plan_stable_id = "survival_household";
    std::vector<int32_t> _survival_food_need_stable_ids;
    int32_t _survival_staple_need_stable_id = -1;
    int32_t _survival_clothing_need_stable_id = -1;
    int32_t _starvation_satisfaction_threshold_q16 = Q16_ONE / 2;
    int64_t _starvation_death_rate_q32 = Q32_ONE / 200;
    int32_t _wage_ema_alpha_q16 = 8192;
    int32_t _wage_max_rise_q16_per_day = 6554;
    int32_t _wage_max_fall_q16_per_day = 1311;
    int32_t _employee_profit_share_q16 = 16384;
    int32_t _building_severe_loss_threshold_q16 = -16384;
    int32_t _building_severe_loss_cycles = 3;
    int32_t _building_restart_margin_q16 = 6554;
    int32_t _building_restart_cycles = 2;
    int32_t _merchant_procurement_cash_reserve_q16 = 16384;
    int32_t _merchant_market_making_days_q16 = Q16_ONE;
    int32_t _merchant_profession_id = -1;
    std::string _merchant_profession_stable_id = "merchant";
    int32_t _market_runtime_mode = 1; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int32_t _trade_runtime_mode = 2; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int64_t _trade_capacity_per_merchant_q16 = 64 * Q16_ONE;
    int32_t _trade_speed_cost_per_day = 4;
    int32_t _trade_min_margin_q16 = 3277;
    int32_t _trade_target_count = 4;
    int32_t _trade_signal_pairs_per_slice = 16384;
    int32_t _trade_route_searches_per_slice = 2;
    int32_t _trade_max_route_expansions = 8192;
    int32_t _trade_route_cache_entries = 16384;
    int32_t _trade_max_signals = 32768;
    int32_t _trade_max_candidates = 8192;
    int32_t _trade_max_orders = 4096;
    int32_t _trade_flow_ema_alpha_q16 = 8192;
    int32_t _trade_max_stock_share_q16 = 16384;
    bool _worker_enabled = true;
    int32_t _worker_market_threshold = 256;
    int32_t _worker_tasks_hint = 0;
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
    int64_t _production_inputs_consumed = 0;
    int64_t _production_output_stock = 0;
    int64_t _production_output_discarded = 0;
    int64_t _production_output_retained = 0;
    int64_t _owner_output_consumed = 0;
    int64_t _producer_revenue = 0;
	int64_t _bullion_money_issued = 0;
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
    int64_t _merchant_procurement_reserved = 0;
    int64_t _merchant_procurement_spent = 0;
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
    int64_t _building_resource_capacity_checks = 0;
    int64_t _building_resource_capacity_limited_groups = 0;
    std::string _last_building_rejection_reason;
    int32_t _worker_tasks = 1;

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
    double _market_signal_ms = 0.0;
    double _wage_plan_ms = 0.0;
    double _labor_signal_ms = 0.0;
    double _trade_plan_ms = 0.0;
    double _trade_settle_ms = 0.0;
    double _trade_dispatch_ms = 0.0;

    AuditTotals _opening_totals;
    AuditTotals _closing_totals;
    AuditTotals _publish_accum;
    PopulationStore _population;
    MarketStore _market;
    MarketSignalStore _market_signals;
    std::vector<int64_t> _epoch_business_demand_ema;
    std::vector<int64_t> _epoch_offered_supply_ema;
    std::vector<int64_t> _epoch_nonhousehold_withdrawals;
    std::vector<int32_t> _epoch_cost_anchor_price;
    std::vector<OwnerRetainedOutput> _owner_retained_outputs;
    TradeTopologyStore _trade_topology;
    TradePlanStore _trade_plan;
    TradeOrderStore _trade_orders;
    TradeFlowSignalStore _trade_flows;
    LaborMarketStore _labor_signals;
    std::vector<FormulaDefinition> _formulas;
    std::unordered_map<std::string, int32_t> _formula_by_id;
    std::vector<Signature> _signatures;
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
    std::vector<uint8_t> _resource_adjacent_access;
    std::vector<int64_t> _resource_snapshot;
    std::vector<int64_t> _resource_remaining;
    std::vector<int64_t> _resource_deltas;
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
    std::vector<int32_t> _structural_touched_cells;
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
    int32_t _epoch_country_count = 0;
    int32_t _epoch_country_technology_words = 0;
    uint64_t _epoch_country_generation = 0;
    uint64_t _epoch_country_hash = 0;
    std::vector<BuildingType> _building_types;
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
    std::vector<int32_t> _building_cell_offsets;
    std::vector<int32_t> _building_active_cells;
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
    int64_t _building_catalog_hash = 0;
    int64_t _building_catalog_compat_hash_v6 = 0;
    int64_t _building_catalog_compat_hash_v7 = 0;
    int64_t _catalog_compat_hash_v7 = 0;
    int64_t _catalog_compat_hash_v8 = 0;
    int64_t _catalog_compat_hash_v10 = 0;

    SaveState _save;
    RestoreState _restore;

    void register_builtin_formulas();
    bool compile_catalog(const godot::Dictionary &catalog, std::string &error);
    bool configure_profile(const godot::Dictionary &profile, std::string &error);
    bool start_epoch(int64_t day_index, std::string &error);
    bool trade_planner_should_run() const;
    bool run_trade_planner_slice(int64_t &work_done, std::string &error);
    bool begin_trade_plan(std::string &error);
    bool rebuild_trade_components(std::string &error);
    bool route_trade_source(int32_t source_index, std::string &error);
    int32_t cached_trade_route_cost(int32_t source, int32_t destination,
                                    int32_t country, int32_t &expansions);
    int32_t estimate_trade_price(int32_t market, int32_t good,
                                 int64_t stock_after, int64_t &sat) const;
    bool settle_due_trade_orders(std::string &error);
    bool dispatch_trade_candidates(std::string &error);
    void update_trade_flow_ema();
    int32_t trade_flow_index(int32_t cell, int32_t good, bool create);
    int64_t credit_trade_sellers(int32_t order_index, int64_t amount);
    void rebuild_trade_arrival_buckets();
    void compact_trade_orders(const std::vector<uint8_t> &remove);
    int64_t trade_transit_goods() const;
    int64_t trade_escrow_cash() const;
    bool apply_command(const Command &cmd, std::string &error);
    bool process_market_cell(int32_t market, MarketResult &result, std::string &error);
    bool commit_structural(const StructuralCommand &cmd, std::string &error);
    bool publish_epoch(std::string &error);
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
    bool capture_country_epoch(std::string &error);
    bool apply_build_command(const Command &cmd, int32_t owner_slot, std::string &error);
    bool apply_demolish_command(const Command &cmd, int32_t owner_slot, std::string &error);
    bool run_building_employment_cell(int32_t cell, std::string &error);
    bool run_building_production_cell(int32_t cell, std::string &error);
    int32_t gather_resource_cells(int32_t cell, int32_t access_mode,
                                  int32_t *out_cells, int32_t capacity) const;
    int64_t available_resource_amount(const ResourceAmount &item, int32_t cell) const;
    void consume_resource_amount(const ResourceAmount &item, int32_t cell, int64_t quantity);
    void commit_ready_construction();
    void rebuild_building_role_storage();
    void rebuild_building_cell_offsets();
    void rebuild_market_signals();
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
    bool prepare_building_economic_plan(std::string &error);
    int32_t market_signal_index(int32_t cell, int32_t good) const;
    PricePressure price_pressure(int32_t market, int32_t good, int64_t household_demand,
                                 int64_t stock, int64_t shortage_q16,
                                 int32_t signal_index, int64_t &saturation_count) const;
    int32_t find_building_group(int32_t cell, int32_t type_id,
                                int32_t owner_signature_id) const;
    int32_t find_cohort_slot(int32_t cell, int32_t signature_id) const;
    int64_t credit_local_merchants(int32_t cell, int64_t amount,
                                   int32_t cashflow_source = CASHFLOW_MERCHANT_BUSINESS);
    int64_t debit_local_merchants(int32_t cell, int64_t amount,
                                  int32_t cashflow_source = CASHFLOW_MERCHANT_PROCUREMENT);
    int64_t pay_building_wage_amount(int32_t cell, int32_t owner_slot,
                                     int32_t profession_id, int64_t filled_jobs,
                                     int64_t due, int64_t payment_cap);
    void fail(const std::string &reason);
    void clear_epoch_metrics();
    void rebuild_committed_summaries();
    CellSummary build_cell_summary(int32_t cell) const;
    void finalize_market_result(int32_t market, MarketResult &result);
    bool rebuild_market_cell_ranges(std::string &error);
    bool ensure_merchant_invariant(int32_t cell, int64_t &repair_count,
                                   std::string &error);
    bool rebuild_merchant_ranges(std::string &error);
    bool is_merchant_slot(int32_t slot) const;
    void touch_accounting_slot(int32_t slot);
    AuditTotals audit_totals() const;
    int64_t memory_bytes() const;
    int32_t choose_epoch_days(int64_t cohort_count) const;
    int32_t stage_progress_q16() const;
    const char *stage_name() const;

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
    int64_t desired_need_units(int32_t slot, int32_t need_index, int32_t dt_days,
                               int64_t environment_factor_q16,
                               int64_t composite_factor_q16,
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
};

} // namespace pk

#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace pk {

// NativeEconomyRuntime is the sole mutable authority for population cohorts
// and markets. Godot containers are accepted/emitted only at coarse API
// boundaries; every graph stage operates on POD/std::vector storage.
class NativeEconomyRuntime {
public:
    static constexpr int32_t SCHEMA_VERSION = 3;
    static constexpr int32_t PAGE_SIZE = 64;
    static constexpr int64_t MONEY_SCALE = 10000;
    static constexpr int64_t GOODS_SCALE = 1000;
    static constexpr int64_t Q16_ONE = 65536;
    static constexpr int64_t Q32_ONE = 4294967296LL;
    static constexpr int32_t MAX_RULES_PER_PLAN = 32;
    static constexpr int32_t MAX_NEEDS_PER_PLAN = 16;
    static constexpr int32_t MAX_VARIANTS_PER_NEED = 4;
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
    };

    NativeEconomyRuntime();
    ~NativeEconomyRuntime();

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
        return !_epoch_active && _environment_day != day_index;
    }
    bool should_run(int64_t day_index) const;
    godot::Dictionary report() const;
    godot::Dictionary population_cell_snapshot(int32_t cell_idx) const;
    godot::Dictionary population_cell_snapshot(int32_t cell_idx,
                                                float temperature,
                                                float moisture,
                                                float snow_cover,
                                                float weather_intensity,
                                                bool environment_ready) const;
    godot::Dictionary market_cell_snapshot(int32_t cell_idx) const;
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

    // Building context is captured once at the frozen sample boundary. Natural
    // resources are resource-major and use GOODS_SCALE units in native state.
    bool capture_building_context(int64_t day_index, const float *elevation,
                                  const uint8_t *terrain, const uint8_t *landform,
                                  const uint8_t *vegetation, const uint8_t *is_water,
                                  const uint8_t *has_river,
                                  const std::vector<const float *> &resources,
                                  int32_t count, std::string &error);
    bool needs_building_context_capture(int64_t day_index) const {
        return !_epoch_active && _building_context_day != day_index;
    }
    const std::vector<std::string> &building_resource_reserve_slots() const {
        return _resource_reserve_slots;
    }
    const std::vector<std::string> &building_resource_extra_slots() const {
        return _resource_extra_slots;
    }
    bool drain_building_resource_deltas(std::vector<int64_t> &out);

private:
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
        int32_t quantity_env_curve = -1;
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
        int32_t condition_begin = 0;
        int32_t condition_count = 0;
        int32_t construction_days = 0;
        int32_t behavior_id = 0; // 0=none, 1=consume_local_resources.
        int32_t behavior_version = 1;
    };

    struct JobRole {
        int32_t profession_id = -1;
        int64_t slots_per_building = 0;
    };

    struct GoodAmount {
        int32_t good_id = -1;
        int64_t quantity = 0;
    };

    struct ResourceAmount {
        int32_t resource_id = -1;
        int64_t quantity = 0;
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
        int64_t last_capacity_q16 = 0;
        int64_t last_input = 0;
        int64_t last_output = 0;
        int64_t last_sold = 0;
        int64_t last_discarded = 0;
        int64_t last_resource = 0;
        int64_t last_revenue = 0;
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
        int64_t treasury_cash = 0;
        int64_t goods_stock = 0;
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
        std::vector<StructuralCommand> structural_commands;
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
    int32_t _merchant_profession_id = -1;
    std::string _merchant_profession_stable_id = "merchant";
    int32_t _market_runtime_mode = 1; // 0=OFF, 1=PROBE, 2=ACTIVE.
    bool _worker_enabled = true;
    int32_t _worker_market_threshold = 256;
    int32_t _worker_tasks_hint = 0;
    int64_t _seed = 0;
    int64_t _catalog_hash = 0;
    int64_t _epoch_id = 0;
    int64_t _sample_day = -1;
    int64_t _current_day = -1;
    int64_t _commit_day = -1;
    int64_t _last_committed_day = -1;
    int64_t _treasury_cash = 0;
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
    int64_t _continuation_slices = 0;
    int64_t _processed_building_groups = 0;
    int64_t _filled_owner_jobs = 0;
    int64_t _filled_employee_jobs = 0;
    int64_t _unemployed_population = 0;
    int64_t _construction_goods_consumed = 0;
    int64_t _production_inputs_consumed = 0;
    int64_t _production_output_stock = 0;
    int64_t _production_output_discarded = 0;
    int64_t _producer_revenue = 0;
    int64_t _building_wages_paid = 0;
    int64_t _building_wages_unpaid = 0;
    std::string _last_building_rejection_reason;
    int32_t _worker_tasks = 1;

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

    AuditTotals _opening_totals;
    AuditTotals _closing_totals;
    AuditTotals _publish_accum;
    PopulationStore _population;
    MarketStore _market;
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
    std::vector<int32_t> _good_max_price_rise_q16;
    std::vector<int32_t> _good_max_price_fall_q16;
    std::vector<int32_t> _good_merchant_buy_factor_q16;
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
    std::vector<BuildingType> _building_types;
    std::vector<JobRole> _building_employee_roles;
    std::vector<GoodAmount> _building_construction_goods;
    std::vector<GoodAmount> _building_inputs;
    std::vector<GoodAmount> _building_outputs;
    std::vector<ResourceAmount> _building_resources;
    std::vector<ConditionToken> _building_conditions;
    std::vector<BuildingGroup> _buildings;
    std::vector<int32_t> _building_cell_offsets;
    std::vector<int32_t> _building_active_cells;
    std::vector<int64_t> _building_employee_filled;
    std::vector<PendingConstruction> _pending_construction;
    int64_t _building_catalog_hash = 0;

    SaveState _save;
    RestoreState _restore;

    void register_builtin_formulas();
    bool compile_catalog(const godot::Dictionary &catalog, std::string &error);
    bool configure_profile(const godot::Dictionary &profile, std::string &error);
    bool start_epoch(int64_t day_index, std::string &error);
    bool apply_command(const Command &cmd, std::string &error);
    bool process_market_cell(int32_t market, MarketResult &result, std::string &error);
    bool commit_structural(const StructuralCommand &cmd, std::string &error);
    bool publish_epoch(std::string &error);
    bool compile_building_catalog(const godot::Dictionary &catalog, std::string &error);
    bool evaluate_building_conditions(int32_t type_id, int32_t cell) const;
    bool apply_build_command(const Command &cmd, int32_t owner_slot, std::string &error);
    bool apply_demolish_command(const Command &cmd, int32_t owner_slot, std::string &error);
    bool run_building_employment_cell(int32_t cell, std::string &error);
    bool run_building_production_cell(int32_t cell, std::string &error);
    void commit_ready_construction();
    void rebuild_building_role_storage();
    void rebuild_building_cell_offsets();
    int32_t find_building_group(int32_t cell, int32_t type_id,
                                int32_t owner_signature_id) const;
    int32_t find_cohort_slot(int32_t cell, int32_t signature_id) const;
    int64_t credit_local_merchants(int32_t cell, int64_t amount);
    int64_t debit_local_merchants(int32_t cell, int64_t amount);
    int64_t pay_building_wages(int32_t cell, int32_t owner_slot,
                               int32_t profession_id, int64_t filled_jobs,
                               int64_t wage_per_employee_per_day);
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
};

} // namespace pk

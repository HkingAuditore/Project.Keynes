#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

class NativeEconomyRuntime;

// Debug-only committed economy recorder. The main thread copies native state
// into one of two POD buffers; the worker owns CSV encoding and file I/O.
class EconomyCsvRecorder {
public:
    static constexpr int32_t SCHEMA_VERSION = 21;
    static constexpr int32_t DIM_COUNT = 5;
    enum Dimension : int32_t { SUMMARY = 0, COHORTS = 1, BUILDINGS = 2, RESOURCES = 3, MARKET = 4 };

    struct Config {
        std::array<bool, DIM_COUNT> enabled{{true, true, true, true, true}};
        std::array<std::string, DIM_COUNT> paths;
        int32_t cell_stride = 1;
        // Empty selects the stride-based world sample. Non-empty indices are
        // normalized once at start and override cell_stride.
        std::vector<int32_t> cell_indices;
        int64_t max_rows = 5'000'000;
        int32_t test_write_delay_ms = 0;
        int64_t test_fail_after_bytes = -1;
        std::vector<int32_t> q;
        std::vector<int32_t> r;
        std::vector<int32_t> s;
        std::vector<int32_t> resource_slot_ids;
        std::vector<std::string> resource_ids;
    };

    EconomyCsvRecorder();
    ~EconomyCsvRecorder();

    EconomyCsvRecorder(const EconomyCsvRecorder &) = delete;
    EconomyCsvRecorder &operator=(const EconomyCsvRecorder &) = delete;

    bool start(const Config &config, NativeEconomyRuntime &runtime, std::string &error);
    bool capture_committed(NativeEconomyRuntime &runtime,
                           const std::vector<const float *> &resource_arrays,
                           std::string &reason);
    void request_stop();
    void shutdown();
    godot::Dictionary status() const;

    bool wants_capture() const;
    const std::vector<int32_t> &resource_slot_ids() const { return _config.resource_slot_ids; }
    int32_t configured_cell_count() const { return static_cast<int32_t>(_config.q.size()); }

public:
    struct CommonCell {
        int64_t epoch_row_id = 0;
        int64_t epoch_id = 0;
        int64_t day_index = 0;
        int32_t cell = 0;
        int32_t q = 0;
        int32_t r = 0;
        int32_t s = 0;
    };

    struct SummaryRow {
        int64_t epoch_row_id = 0;
        int64_t epoch_id = 0;
        int64_t day_index = 0;
        bool epoch_active = false;
        int32_t stage = 0;
        int32_t progress_q16 = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int64_t cohort_count = 0;
        int64_t market_count = 0;
        int64_t good_count = 0;
        int64_t building_type_count = 0;
        int64_t building_group_count = 0;
        int64_t pending_construction_count = 0;
        int64_t filled_owner_jobs = 0;
        int64_t filled_employee_jobs = 0;
        int64_t unemployed_population = 0;
        int64_t births = 0;
        int64_t deaths = 0;
        int64_t production_inputs_consumed = 0;
        int64_t production_output_stock = 0;
        int64_t production_output_discarded = 0;
        int64_t production_output_retained = 0;
        int64_t production_output_supported = 0;
        int64_t owner_output_consumed = 0;
        int64_t producer_revenue = 0;
        int64_t producer_support_money_issued = 0;
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
        int64_t building_resource_generated = 0;
        int64_t building_resource_consumed = 0;
        int64_t building_resource_net_delta = 0;
        int64_t loss_suspended_building_groups = 0;
        int64_t merchant_procurement_budget = 0;
        int64_t merchant_procurement_opportunity = 0;
        int64_t merchant_procurement_allocated = 0;
        int64_t merchant_procurement_unspent_allocated = 0;
        int64_t merchant_procurement_reserved = 0;
        int64_t merchant_procurement_spent = 0;
        int64_t owner_working_capital_reserved = 0;
        int64_t production_input_reserved = 0;
        int64_t production_input_reserve_shortfall = 0;
        int32_t trade_runtime_mode = 0;
        bool trade_topology_ready = false;
        int64_t trade_topology_generation = 0;
        int64_t trade_topology_hash = 0;
        int64_t trade_country_generation = 0;
        int32_t trade_plan_phase = 0;
        int64_t trade_scan_cursor = 0;
        int64_t trade_scan_total = 0;
        int64_t trade_route_cursor = 0;
        int64_t trade_route_total = 0;
        int64_t trade_completed_scans = 0;
        int64_t trade_plan_reset_count = 0;
        int64_t trade_topology_content_change_count = 0;
        std::string trade_last_plan_reset_reason;
        int64_t trade_source_signals = 0;
        int64_t trade_destination_signals = 0;
        int64_t trade_ready_candidates = 0;
        int64_t trade_route_expansions = 0;
        int64_t trade_route_cache_hits = 0;
        int64_t trade_route_cache_misses = 0;
        int64_t trade_candidates_generated = 0;
        int64_t trade_candidates_accepted = 0;
        int64_t trade_rejected_profit = 0;
        int64_t trade_rejected_no_spread = 0;
        int64_t trade_rejected_margin = 0;
        int64_t trade_quantity_profit_clips = 0;
        int64_t trade_relief_candidates = 0;
        int64_t trade_rejected_capacity = 0;
        int64_t trade_rejected_stock = 0;
        int64_t trade_rejected_cash = 0;
        int64_t trade_rejected_route = 0;
        int64_t trade_rejected_order_cap = 0;
        int64_t trade_orders_in_flight = 0;
        int64_t trade_orders_dispatched = 0;
        int64_t trade_orders_arrived = 0;
        int64_t trade_unclaimed_orders = 0;
        int64_t trade_capacity_available = 0;
        int64_t trade_capacity_used = 0;
        int64_t population_error = 0;
        int64_t money_error = 0;
        int64_t goods_error = 0;
        int64_t construction_goods_consumed = 0;
        int64_t building_investment_candidates = 0;
        int64_t building_owner_mobility = 0;
        int64_t building_owner_job_reallocations = 0;
        int64_t building_owner_job_profession_changes = 0;
        int64_t building_owner_job_probability_skips = 0;
        int64_t building_investments_started = 0;
        int64_t building_investment_blocked_funds = 0;
        int64_t building_investment_blocked_materials = 0;
        int64_t building_investment_blocked_sponsor_capital = 0;
        int64_t building_investment_blocked_resources = 0;
        int64_t building_investment_probability_skips = 0;
        int64_t building_investment_capital_transferred = 0;
        int64_t building_investment_buildings_started = 0;
        int64_t building_investment_portfolios_started = 0;
        int64_t building_investment_types_started = 0;
        int64_t building_investment_owner_population_moved = 0;
        int64_t building_investment_max_type_owner_share_q16 = 0;
        int64_t building_investment_demand_limited = 0;
        int64_t building_investment_material_limited = 0;
        int64_t building_investment_capital_limited = 0;
        int64_t building_investment_owner_population_limited = 0;
        int64_t desired_business_demand = 0;
        int64_t funded_business_demand = 0;
        int64_t unfunded_business_demand = 0;
        int64_t owner_working_capital_allocated = 0;
        int64_t trade_signal_max_age_days = 0;
        int64_t trade_first_dispatch_delay_max_days = 0;
        int64_t trade_response_deadline_misses = 0;
        int64_t trade_response_deadline_misses_cumulative = 0;
        int64_t trade_unresolved_no_attempt = 0;
        int64_t trade_unresolved_no_spread = 0;
        int64_t trade_unresolved_margin = 0;
        int64_t trade_unresolved_route = 0;
        int64_t trade_unresolved_stock = 0;
        int64_t trade_unresolved_capacity = 0;
        int64_t trade_unresolved_cash = 0;
        int64_t trade_unresolved_order_cap = 0;
        int64_t merchant_credit_budget = 0;
        int64_t merchant_credit_committed = 0;
        int64_t merchant_credit_drawn = 0;
        int64_t merchant_credit_repaid = 0;
        int64_t merchant_credit_premium_repaid = 0;
        int64_t merchant_credit_outstanding = 0;
        int64_t merchant_credit_bad_debt = 0;
        int64_t recovery_candidates = 0;
        int64_t recovery_approved = 0;
        int64_t recovery_restarted = 0;
        int64_t recovery_failed = 0;
        int64_t recovery_liquidated_buildings = 0;
        int64_t recovery_partially_liquidated_buildings = 0;
        int64_t recovery_fully_liquidated_groups = 0;
        int64_t merchant_survival_procurement_required = 0;
        int64_t merchant_survival_procurement_allocated = 0;
        int64_t merchant_input_procurement_required = 0;
        int64_t merchant_input_procurement_allocated = 0;
        int64_t trade_active_keys_pruned = 0;
        int64_t trade_deficit_episodes_started = 0;
        int64_t trade_deficit_episodes_resolved = 0;
        int64_t trade_candidates_stale_generation = 0;
        int64_t trade_candidates_arbitrated_out = 0;
        int64_t trade_true_source_stock_failures = 0;
        int64_t merchant_cash = 0;
        int64_t merchant_inventory_retail_value = 0;
        int64_t merchant_inventory_liquidation_value = 0;
        int64_t merchant_economic_assets = 0;
        int64_t merchant_procurement_margin_value = 0;
        int64_t merchant_trade_purchase_cash = 0;
        int64_t merchant_trade_sale_cash = 0;
        int64_t merchant_operating_outflow = 0;
        int64_t merchant_liquidity_coverage_q16 = 0;
        int32_t merchant_effective_buy_factor_q16 = 0;
    };

    struct CohortRow {
        CommonCell c;
        int32_t cohort_index = 0;
        uint64_t handle = 0;
        int32_t signature_id = 0;
        int32_t profession_id = 0;
        int32_t ethnicity_id = 0;
        int64_t population = 0;
        int64_t funds = 0;
        int64_t epoch_income = 0;
        int64_t epoch_expense = 0;
        int64_t epoch_in_kind_income = 0;
        int64_t cash_expense_coverage_q16 = 0;
        int64_t livelihood_coverage_q16 = 0;
        int64_t income_ema = 0;
        int32_t satisfaction_q16 = 0;
        int32_t worst_need_id = -1;
        bool merchant = false;
        int64_t owner_employed = 0;
        int64_t employee_employed = 0;
        int64_t unemployed = 0;
    };

    struct BuildingRow {
        CommonCell c;
        bool construction = false;
        int32_t group_index = 0;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t count = 0;
        int64_t owner_capacity = 0;
        int64_t owner_required = 0;
        int64_t planned_owner_equivalent = 0;
        int64_t filled_owner = 0;
        int64_t owner_openings = 0;
        int64_t employee_required = 0;
        int64_t employee_filled = 0;
        bool wage_suspended = false;
        int64_t capacity_q16 = 0;
        int64_t purchase_intent_capacity_q16 = 0;
        int64_t funded_capacity_q16 = 0;
        int64_t owner_working_capital_allocated = 0;
        int64_t investment_score_q16 = 0;
        int64_t investment_payback_days = 0;
        int32_t investment_rejection_reason = 0;
        bool investment_candidate = false;
        int64_t investment_shortage_q16 = 0;
        int64_t investment_utilization_q16 = 0;
        int64_t investment_required_capital = 0;
        int64_t investment_projected_profit_per_day = 0;
        int32_t investment_driver_good_id = -1;
        int64_t investment_driver_pressure_q16 = 0;
        int64_t investment_driver_utilization_q16 = 0;
        int64_t investment_driver_sellable = 0;
        int64_t investment_driver_merchant_sold = 0;
        int64_t investment_driver_sell_through_q16 = 0;
        int64_t investment_driver_discard_q16 = 0;
        int32_t realized_profit_margin_q16 = 0;
        int32_t severe_loss_cycles = 0;
        int32_t recovery_cycles = 0;
        int32_t operating_state = 0;
        int64_t last_input = 0;
        int64_t last_output = 0;
        int64_t last_sold = 0;
        int64_t last_discarded = 0;
        int64_t last_retained = 0;
        int64_t last_resource = 0;
        int64_t last_resource_generated = 0;
        int64_t last_revenue = 0;
        int64_t last_input_cost = 0;
        int64_t last_wages_paid = 0;
        int64_t last_wages_due = 0;
        int64_t last_expected_revenue = 0;
        int64_t last_operating_cost = 0;
        int32_t last_margin_gap_q16 = 0;
        int32_t planned_utilization_q16 = 0;
        int64_t last_base_wages_due = 0;
        int64_t last_base_wages_paid = 0;
        int64_t last_bonus_due = 0;
        int64_t last_bonus_paid = 0;
        int64_t owner_living_cost_per_day = 0;
        int64_t owner_livelihood_required = 0;
        int64_t viability_operating_cost = 0;
        int64_t viability_income_gap = 0;
        int64_t projected_owner_income_per_day = 0;
        int64_t construction_ready_day = 0;
        int64_t merchant_debt_principal = 0;
        int64_t merchant_debt_premium = 0;
        int32_t merchant_debt_term_cycles_left = 0;
        int32_t merchant_debt_delinquent_cycles = 0;
        int64_t last_in_kind_livelihood_value = 0;
        int32_t recovery_failed_reviews = 0;
    };

    struct ResourceRow {
        CommonCell c;
        int32_t resource_index = -1;
        float opening_reserve = 0.0f;
        float natural_net_change = 0.0f;
        float natural_positive_change = 0.0f;
        float natural_negative_change = 0.0f;
        float artificial_change_applied = 0.0f;
        float artificial_change_pending = 0.0f;
        float artificial_generation_applied = 0.0f;
        float artificial_extraction_applied = 0.0f;
        float artificial_generation_pending = 0.0f;
        float artificial_extraction_pending = 0.0f;
        float reserve = 0.0f;
        int64_t safe_yield = 0;
        int64_t projected_life_days = 0;
    };

    struct MarketRow {
        CommonCell c;
        int32_t good_index = -1;
        int64_t stock = 0;
        int32_t price = 0;
        int64_t demand_ema = 0;
        int64_t business_demand_ema = 0;
        int64_t desired_business_demand = 0;
        int64_t funded_business_demand = 0;
        int64_t unfunded_business_demand = 0;
        int64_t offered_supply_ema = 0;
        int64_t realized_withdrawal_ema = 0;
        int64_t production_input_reserve = 0;
        int64_t household_available_stock = 0;
        int64_t merchant_inventory_target = 0;
        int64_t merchant_procurement_shortfall = 0;
        int64_t trade_export_safety_stock = 0;
        int64_t trade_import_fill_target = 0;
        int32_t trade_relief_pressure_q16 = 0;
        int32_t trade_signal_age_days = 0;
        int32_t trade_first_dispatch_delay_days = -1;
        int64_t trade_last_attempt_day = -1;
        int32_t trade_last_rejection_reason = 0;
        bool trade_deadline_exceeded = false;
        int32_t cost_anchor_price = 0;
        int32_t shortage_q16 = 0;
        int64_t pressure_business_demand = 0;
        int64_t pressure_supply = 0;
        int32_t pressure_cost_anchor = 0;
        int32_t category_index = -1;
        int32_t storage_mode = 0;
        bool trade_enabled = false;
        int64_t trade_import_ema = 0;
        int64_t trade_export_ema = 0;
        int64_t trade_inbound = 0;
        int64_t trade_outbound = 0;
        int64_t merchant_cash = 0;
        int64_t merchant_inventory_retail_value = 0;
        int64_t merchant_inventory_liquidation_value = 0;
        int64_t merchant_economic_assets = 0;
        int64_t merchant_procurement_margin_value = 0;
        int64_t merchant_trade_purchase_cash = 0;
        int64_t merchant_trade_sale_cash = 0;
        int64_t merchant_operating_outflow = 0;
        int64_t merchant_liquidity_coverage_q16 = 0;
        int32_t merchant_effective_buy_factor_q16 = 0;
    };

private:
    struct Batch {
        int64_t epoch_id = -1;
        int64_t row_count = 0;
        std::vector<SummaryRow> summary;
        std::vector<CohortRow> cohorts;
        std::vector<BuildingRow> buildings;
        std::vector<ResourceRow> resources;
        std::vector<MarketRow> market;
        std::vector<int64_t> scratch_trade_inbound;
        std::vector<int64_t> scratch_trade_outbound;
        void clear_rows();
    };

    enum BufferState : uint8_t { FREE = 0, FILLING = 1, READY = 2, WRITING = 3 };

    void worker_main();
    bool open_files(std::string &error);
    void close_files();
    bool write_batch(const Batch &batch, int64_t &bytes, std::string &error);
    bool fill_batch(Batch &batch, NativeEconomyRuntime &runtime,
                    const std::vector<const float *> &resource_arrays,
                    int64_t epoch_row_id, int64_t projected_rows, std::string &error);
    int64_t projected_rows(const NativeEconomyRuntime &runtime) const;
    int32_t price_pressure_total_q16(const MarketRow &row) const;
    void set_terminal_locked(const std::string &code, const std::string &message,
                             int64_t first_unrecorded_epoch);
    static const char *state_name(int32_t state);

    Config _config;
    std::vector<std::string> _good_ids;
    std::vector<std::string> _good_category_ids;
    std::vector<int32_t> _good_default_price;
    std::vector<int32_t> _good_storage_modes;
    std::vector<int32_t> _good_target_inventory_days_q16;
    std::vector<int32_t> _good_inventory_weight_q16;
    std::vector<int32_t> _good_shortage_weight_q16;
    std::vector<int32_t> _good_excess_demand_weight_q16;
    std::vector<int32_t> _good_cost_anchor_weight_q16;
    std::vector<int32_t> _good_inactive_reversion_weight_q16;
    std::vector<int64_t> _good_monetary_issue_values;
    std::vector<int32_t> _sample_cells;
    std::vector<int32_t> _sample_cell_positions;
    // Recorder resource rows follow the caller's slot order, while native
    // building deltas follow the economy catalog's stable-id order.
    std::vector<int32_t> _resource_runtime_indices;
    std::vector<float> _previous_resource_reserve;
    std::vector<int64_t> _pending_resource_artificial;
    std::vector<uint8_t> _resource_history_valid;
    std::array<Batch, 2> _buffers;
    std::array<BufferState, 2> _buffer_states{{FREE, FREE}};
    std::deque<int32_t> _ready;
    std::array<std::ofstream, DIM_COUNT> _files;

    mutable std::mutex _mutex;
    std::condition_variable _cv;
    std::condition_variable _open_cv;
    std::thread _worker;
    bool _open_done = false;
    bool _open_ok = false;
    bool _accepting = false;
    bool _stop_requested = false;
    bool _worker_busy = false;
    bool _worker_finished = false;
    int32_t _state = 0; // 0 idle, 1 opening, 2 recording, 3 draining, 4 completed, 5 error.
    std::string _error_code;
    std::string _error_message;
    int64_t _last_captured_epoch = -1;
    int64_t _first_unrecorded_epoch = -1;
    int64_t _captured_epochs = 0;
    int64_t _written_epochs = 0;
    int64_t _captured_rows = 0;
    int64_t _written_rows = 0;
    int64_t _bytes_written = 0;
    int64_t _capture_us_last = 0;
    int64_t _capture_us_max = 0;
    std::deque<int64_t> _capture_samples_us;
    int64_t _backpressure_wait_count = 0;
    int64_t _backpressure_wait_us = 0;
    int64_t _encode_us_last = 0;
    int64_t _write_us_last = 0;
};

} // namespace pk

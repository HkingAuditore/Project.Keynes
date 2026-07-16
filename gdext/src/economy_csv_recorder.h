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
    static constexpr int32_t SCHEMA_VERSION = 5;
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
        int64_t production_output_stock = 0;
        int64_t production_output_discarded = 0;
        int64_t production_output_retained = 0;
        int64_t production_output_supported = 0;
        int64_t producer_support_money_issued = 0;
        int64_t building_wages_paid = 0;
        int64_t building_wages_unpaid = 0;
        int64_t building_resource_generated = 0;
        int64_t building_resource_consumed = 0;
        int64_t building_resource_net_delta = 0;
        int64_t loss_suspended_building_groups = 0;
        int64_t merchant_procurement_budget = 0;
        int64_t merchant_procurement_reserved = 0;
        int64_t merchant_procurement_spent = 0;
        int64_t owner_working_capital_reserved = 0;
        int64_t production_input_reserved = 0;
        int64_t production_input_reserve_shortfall = 0;
        int32_t trade_runtime_mode = 0;
        bool trade_topology_ready = false;
        int64_t population_error = 0;
        int64_t money_error = 0;
        int64_t goods_error = 0;
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
        int64_t filled_owner = 0;
        int64_t employee_required = 0;
        int64_t employee_filled = 0;
        bool wage_suspended = false;
        int64_t capacity_q16 = 0;
        int64_t purchase_intent_capacity_q16 = 0;
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
        int64_t construction_ready_day = 0;
    };

    struct ResourceRow { CommonCell c; int32_t resource_index = -1; float reserve = 0.0f; };

    struct MarketRow {
        CommonCell c;
        int32_t good_index = -1;
        int64_t stock = 0;
        int32_t price = 0;
        int64_t demand_ema = 0;
        int64_t business_demand_ema = 0;
        int64_t offered_supply_ema = 0;
        int64_t realized_withdrawal_ema = 0;
        int64_t production_input_reserve = 0;
        int64_t household_available_stock = 0;
        int64_t merchant_inventory_target = 0;
        int64_t merchant_procurement_shortfall = 0;
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
    int64_t _encode_us_last = 0;
    int64_t _write_us_last = 0;
};

} // namespace pk

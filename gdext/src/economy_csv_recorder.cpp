#include "economy_csv_recorder.h"

#include "economy_runtime.h"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <limits>
#include <system_error>

#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace pk {
using namespace godot;
namespace {

using Clock = std::chrono::steady_clock;
constexpr size_t WRITE_CHUNK_BYTES = 1024 * 1024;

constexpr const char *HEADERS[EconomyCsvRecorder::DIM_COUNT] = {
    "epoch_row_id,epoch_id,day_index,epoch_active,stage,progress_q16,sample_day,commit_day,cohort_count,market_count,good_count,building_type_count,building_group_count,pending_construction_count,filled_owner_jobs,filled_employee_jobs,unemployed_population,births,deaths,production_inputs_consumed,production_output_stock,production_output_discarded,production_output_retained,production_output_supported,owner_output_consumed,producer_revenue,producer_support_money_issued,bullion_money_issued,bullion_stock_consumed,gold_accepted,silver_accepted,gold_money_issued,silver_money_issued,cycle_flow_produced,cycle_flow_consumed,cycle_flow_discarded,building_wages_paid,building_wages_unpaid,building_resource_generated,building_resource_consumed,building_resource_net_delta,loss_suspended_building_groups,merchant_procurement_budget,merchant_procurement_reserved,merchant_procurement_spent,owner_working_capital_reserved,production_input_reserved,production_input_reserve_shortfall,trade_runtime_mode,trade_topology_ready,trade_topology_generation,trade_topology_hash,trade_country_generation,trade_plan_phase,trade_scan_cursor,trade_scan_total,trade_route_cursor,trade_route_total,trade_completed_scans,trade_plan_reset_count,trade_topology_content_change_count,trade_last_plan_reset_reason,trade_source_signals,trade_destination_signals,trade_ready_candidates,trade_route_expansions,trade_route_cache_hits,trade_route_cache_misses,trade_candidates_generated,trade_candidates_accepted,trade_rejected_profit,trade_rejected_capacity,trade_rejected_stock,trade_rejected_cash,trade_rejected_route,trade_rejected_order_cap,trade_orders_in_flight,trade_orders_dispatched,trade_orders_arrived,trade_unclaimed_orders,trade_capacity_available,trade_capacity_used,population_error,money_error,goods_error\n",
    "epoch_row_id,epoch_id,day_index,cell_idx,q,r,s,cohort_index,handle,signature_id,profession_id,ethnicity_id,population,funds,epoch_income,epoch_expense,income_ema,satisfaction_q16,worst_need_id,is_merchant,owner_employed,employee_employed,unemployed\n",
    "epoch_row_id,epoch_id,day_index,cell_idx,q,r,s,is_construction,group_index,type_id,owner_signature_id,count,owner_capacity,owner_required,planned_owner_equivalent,filled_owner,owner_openings,employee_required,employee_filled,wage_suspended,capacity_q16,purchase_intent_capacity_q16,realized_profit_margin_q16,severe_loss_cycles,recovery_cycles,operating_state,last_input,last_output,last_sold,last_discarded,last_retained,last_resource,last_resource_generated,last_revenue,last_input_cost,last_wages_paid,last_wages_due,last_expected_revenue,last_operating_cost,last_margin_gap_q16,planned_utilization_q16,last_base_wages_due,last_base_wages_paid,last_bonus_due,last_bonus_paid,construction_ready_days\n",
    "epoch_row_id,epoch_id,day_index,cell_idx,q,r,s,resource_id,reserve\n",
    "epoch_row_id,epoch_id,day_index,cell_idx,q,r,s,good_id,stock,price,demand_ema,business_demand_ema,offered_supply_ema,realized_withdrawal_ema,production_input_reserve,household_available_stock,merchant_inventory_target,merchant_procurement_shortfall,cost_anchor_price,shortage_q16,price_pressure_total_q16,category_id,storage_mode,trade_enabled,trade_import_ema,trade_export_ema,trade_inbound,trade_outbound\n",
};

template <typename T>
void append_int(std::string &out, T value) {
    char buf[48];
    auto result = std::to_chars(buf, buf + sizeof(buf), value);
    if (result.ec == std::errc()) out.append(buf, result.ptr);
}

void append_float(std::string &out, float value) {
    if (!std::isfinite(value)) return;
    char buf[64];
    auto result = std::to_chars(buf, buf + sizeof(buf), value,
                                std::chars_format::general);
    if (result.ec == std::errc()) out.append(buf, result.ptr);
}

void append_csv_string(std::string &out, const std::string &value) {
    const bool quote = value.find_first_of(",\"\r\n") != std::string::npos;
    if (!quote) {
        out.append(value);
        return;
    }
    out.push_back('"');
    for (char c : value) {
        if (c == '"') out.push_back('"');
        out.push_back(c);
    }
    out.push_back('"');
}

template <typename T>
void field(std::string &out, T value) {
    if (!out.empty() && out.back() != '\n') out.push_back(',');
    append_int(out, value);
}

void text_field(std::string &out, const std::string &value) {
    if (!out.empty() && out.back() != '\n') out.push_back(',');
    append_csv_string(out, value);
}

void bool_field(std::string &out, bool value) { text_field(out, value ? "true" : "false"); }
void blank_field(std::string &out) { out.push_back(','); }

void append_common(std::string &out, const EconomyCsvRecorder::CommonCell &c) {
    append_int(out, c.epoch_row_id);
    field(out, c.epoch_id); field(out, c.day_index); field(out, c.cell);
    field(out, c.q); field(out, c.r); field(out, c.s);
}

const char *trade_mode_name(int32_t mode) {
    return mode == 0 ? "OFF" : (mode == 1 ? "PROBE" : "ACTIVE");
}

const char *trade_plan_phase_name(int32_t phase) {
    return phase == 1 ? "SCAN" : (phase == 2 ? "ROUTE" : "IDLE");
}

const char *economy_stage_name(int32_t stage) {
    switch (stage) {
        case 0: return "idle";
        case 1: return "epoch_begin";
        case 2: return "ledger_apply";
        case 3: return "household_market";
        case 4: return "structural_commit";
        case 5: return "wait_commit";
        case 6: return "building_employment";
        case 7: return "building_production";
        case 8: return "building_commit";
        case 9: return "aggregate_publish";
        case 10: return "fatal";
        case 11: return "trade_settle";
        case 12: return "trade_dispatch";
        case 13: return "trade_planning";
        default: return "unknown";
    }
}

bool write_chunked(std::ofstream &file, const std::string &bytes,
                   int64_t &written, int64_t &write_us, int64_t fail_after_bytes,
                   std::string &error) {
    size_t offset = 0;
    while (offset < bytes.size()) {
        if (fail_after_bytes >= 0 && written >= fail_after_bytes) {
            error = "csv_test_injected_write_failure";
            return false;
        }
        size_t count = std::min(WRITE_CHUNK_BYTES, bytes.size() - offset);
        if (fail_after_bytes >= 0)
            count = std::min<size_t>(count, static_cast<size_t>(fail_after_bytes - written));
        const auto write_start = Clock::now();
        file.write(bytes.data() + offset, static_cast<std::streamsize>(count));
        write_us += std::chrono::duration_cast<std::chrono::microseconds>(
            Clock::now() - write_start).count();
        if (!file.good()) {
            error = "csv_write_failed";
            return false;
        }
        written += static_cast<int64_t>(count);
        offset += count;
        if (fail_after_bytes >= 0 && written >= fail_after_bytes) {
            error = "csv_test_injected_write_failure";
            return false;
        }
    }
    return true;
}

} // namespace

void EconomyCsvRecorder::Batch::clear_rows() {
    epoch_id = -1;
    row_count = 0;
    summary.clear(); cohorts.clear(); buildings.clear(); resources.clear(); market.clear();
}

EconomyCsvRecorder::EconomyCsvRecorder() = default;
EconomyCsvRecorder::~EconomyCsvRecorder() { shutdown(); }

const char *EconomyCsvRecorder::state_name(int32_t state) {
    switch (state) {
        case 1: return "opening";
        case 2: return "recording";
        case 3: return "draining";
        case 4: return "completed";
        case 5: return "error";
        default: return "idle";
    }
}

bool EconomyCsvRecorder::start(const Config &config, NativeEconomyRuntime &runtime,
                               std::string &error) {
    shutdown();
    if (!runtime._configured || !runtime._bootstrapped || runtime._fatal) {
        error = "economy_not_ready";
        return false;
    }
    if (config.q.size() != static_cast<size_t>(runtime._cell_count) ||
        config.r.size() != config.q.size() || config.s.size() != config.q.size()) {
        error = "coordinate_size_mismatch";
        return false;
    }
    bool any = false;
    for (int32_t i = 0; i < DIM_COUNT; ++i) {
        if (!config.enabled[i]) continue;
        any = true;
        if (config.paths[i].empty()) {
            error = "enabled_path_missing";
            return false;
        }
    }
    if (!any) {
        error = "no_dimensions_enabled";
        return false;
    }
    if (config.resource_slot_ids.size() != config.resource_ids.size()) {
        error = "resource_config_size_mismatch";
        return false;
    }

    _config = config;
    _config.cell_stride = std::max(1, _config.cell_stride);
    _config.max_rows = std::max<int64_t>(1, _config.max_rows);
    if (!_config.cell_indices.empty()) {
        std::sort(_config.cell_indices.begin(), _config.cell_indices.end());
        _config.cell_indices.erase(
            std::unique(_config.cell_indices.begin(), _config.cell_indices.end()),
            _config.cell_indices.end());
        for (const int32_t cell : _config.cell_indices) {
            if (cell < 0 || cell >= runtime._cell_count) {
                error = "cell_index_out_of_range";
                return false;
            }
        }
        _sample_cells = _config.cell_indices;
    } else {
        _sample_cells.clear();
        _sample_cells.reserve(static_cast<size_t>(
            (runtime._cell_count + _config.cell_stride - 1) / _config.cell_stride));
        for (int32_t cell = 0; cell < runtime._cell_count; cell += _config.cell_stride)
            _sample_cells.push_back(cell);
    }
    _sample_cell_positions.assign(static_cast<size_t>(runtime._cell_count), -1);
    for (int32_t i = 0; i < static_cast<int32_t>(_sample_cells.size()); ++i)
        _sample_cell_positions[_sample_cells[i]] = i;
    _good_ids = runtime._good_ids;
    _good_category_ids = runtime._good_category_ids;
    _good_default_price = runtime._good_default_price;
    _good_storage_modes = runtime._good_storage_modes;
    _good_target_inventory_days_q16 = runtime._good_target_inventory_days_q16;
    _good_inventory_weight_q16 = runtime._good_inventory_weight_q16;
    _good_shortage_weight_q16 = runtime._good_shortage_weight_q16;
    _good_excess_demand_weight_q16 = runtime._good_excess_demand_weight_q16;
    _good_cost_anchor_weight_q16 = runtime._good_cost_anchor_weight_q16;
    _good_inactive_reversion_weight_q16 = runtime._good_inactive_reversion_weight_q16;
    _good_monetary_issue_values = runtime._good_monetary_issue_values;
    const size_t sampled_cells = _sample_cells.size();
    size_t sampled_cohorts = 0;
    size_t sampled_buildings = 0;
    for (const int32_t cell : _sample_cells) {
        if (_config.enabled[COHORTS])
            runtime._population.for_each_in_cell(cell, [&](int32_t) { ++sampled_cohorts; });
        if (_config.enabled[BUILDINGS]) {
            if (runtime._building_cell_offsets.size() ==
                static_cast<size_t>(runtime._cell_count + 1)) {
                sampled_buildings += static_cast<size_t>(
                    runtime._building_cell_offsets[cell + 1] -
                    runtime._building_cell_offsets[cell]);
            }
            for (const auto &pending : runtime._pending_construction)
                if (pending.cell == cell) ++sampled_buildings;
        }
    }
    for (Batch &batch : _buffers) {
        batch.clear_rows();
        batch.summary.reserve(_config.enabled[SUMMARY] ? 1 : 0);
        batch.cohorts.reserve(_config.enabled[COHORTS] ? sampled_cohorts : 0);
        batch.buildings.reserve(_config.enabled[BUILDINGS] ? sampled_buildings : 0);
        batch.resources.reserve(_config.enabled[RESOURCES]
            ? sampled_cells * _config.resource_ids.size() : 0);
        batch.market.reserve(_config.enabled[MARKET]
            ? sampled_cells * static_cast<size_t>(runtime._market.good_count) : 0);
        const size_t trade_cells = _config.enabled[MARKET]
            ? sampled_cells * runtime._market.good_count : 0;
        batch.scratch_trade_inbound.reserve(trade_cells);
        batch.scratch_trade_outbound.reserve(trade_cells);
    }
    _buffer_states = {{FREE, FREE}};
    _ready.clear();
    _error_code.clear(); _error_message.clear();
    _last_captured_epoch = -1; _first_unrecorded_epoch = -1;
    _captured_epochs = 0; _written_epochs = 0;
    _captured_rows = 0; _written_rows = 0; _bytes_written = 0;
    _capture_us_last = 0; _capture_us_max = 0;
    _capture_samples_us.clear();
    _encode_us_last = 0; _write_us_last = 0;
    _open_done = false; _open_ok = false;
    _accepting = false; _stop_requested = false;
    _worker_busy = false; _worker_finished = false;
    _state = 1;
    _worker = std::thread(&EconomyCsvRecorder::worker_main, this);

    std::unique_lock<std::mutex> lock(_mutex);
    _open_cv.wait(lock, [&] { return _open_done; });
    if (!_open_ok) {
        error = _error_message.empty() ? "csv_open_failed" : _error_message;
        lock.unlock();
        if (_worker.joinable()) _worker.join();
        return false;
    }
    _accepting = true;
    _state = 2;
    return true;
}

bool EconomyCsvRecorder::wants_capture() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _accepting && _state == 2;
}

int64_t EconomyCsvRecorder::projected_rows(const NativeEconomyRuntime &runtime) const {
    int64_t rows = _config.enabled[SUMMARY] ? 1 : 0;
    for (const int32_t cell : _sample_cells) {
        if (_config.enabled[COHORTS]) {
            runtime._population.for_each_in_cell(cell, [&](int32_t) { ++rows; });
        }
        if (_config.enabled[BUILDINGS]) {
            if (runtime._building_cell_offsets.size() == static_cast<size_t>(runtime._cell_count + 1)) {
                for (int32_t i = runtime._building_cell_offsets[cell];
                     i < runtime._building_cell_offsets[cell + 1]; ++i) {
                    if (runtime._buildings[i].count > 0) ++rows;
                }
            }
            for (const auto &pending : runtime._pending_construction)
                if (pending.cell == cell) ++rows;
        }
        if (_config.enabled[MARKET]) rows += runtime._market.good_count;
    }
    if (_config.enabled[RESOURCES]) {
        rows += static_cast<int64_t>(_sample_cells.size()) *
                static_cast<int64_t>(_config.resource_ids.size());
    }
    return rows;
}

int32_t EconomyCsvRecorder::price_pressure_total_q16(const MarketRow &row) const {
    const int32_t good = row.good_index;
    int64_t sat = 0;
    const int64_t demand = NativeEconomyRuntime::saturating_add(
        std::max<int64_t>(0, row.demand_ema), row.pressure_business_demand, sat);
    const int64_t flow = NativeEconomyRuntime::saturating_add(
        demand, row.pressure_supply, sat);
    const int64_t excess = std::clamp<int64_t>(NativeEconomyRuntime::mul_div_sat(
        NativeEconomyRuntime::saturating_sub(demand, row.pressure_supply, sat),
        NativeEconomyRuntime::Q16_ONE,
        std::max<int64_t>(NativeEconomyRuntime::GOODS_SCALE, flow), sat),
        -NativeEconomyRuntime::Q16_ONE, NativeEconomyRuntime::Q16_ONE);
    int64_t inventory = 0;
    int64_t shortage = 0;
    if (_good_storage_modes[good] == 0) {
        const int64_t target = NativeEconomyRuntime::mul_div_sat(
            demand, _good_target_inventory_days_q16[good],
            NativeEconomyRuntime::Q16_ONE, sat);
        inventory = std::clamp<int64_t>(NativeEconomyRuntime::mul_div_sat(
            NativeEconomyRuntime::saturating_sub(target, row.stock, sat),
            NativeEconomyRuntime::Q16_ONE,
            std::max<int64_t>(NativeEconomyRuntime::GOODS_SCALE, target), sat),
            -NativeEconomyRuntime::Q16_ONE, NativeEconomyRuntime::Q16_ONE);
        shortage = std::clamp<int64_t>(row.shortage_q16, 0, NativeEconomyRuntime::Q16_ONE);
    }
    const int64_t price = std::max<int64_t>(1, row.price);
    int64_t cost = 0;
    if (_good_monetary_issue_values[good] == 0 && row.pressure_cost_anchor > 0) {
        const int64_t confidence = std::min<int64_t>(NativeEconomyRuntime::Q16_ONE,
            NativeEconomyRuntime::mul_div_sat(row.pressure_supply,
                NativeEconomyRuntime::Q16_ONE,
                std::max<int64_t>(NativeEconomyRuntime::GOODS_SCALE, demand), sat));
        cost = NativeEconomyRuntime::mul_div_sat(std::clamp<int64_t>(
            NativeEconomyRuntime::mul_div_sat(
                static_cast<int64_t>(row.pressure_cost_anchor) - price,
                NativeEconomyRuntime::Q16_ONE,
                std::max<int64_t>(row.pressure_cost_anchor, price), sat),
            -NativeEconomyRuntime::Q16_ONE, NativeEconomyRuntime::Q16_ONE),
            confidence, NativeEconomyRuntime::Q16_ONE, sat);
    }
    int64_t idle = 0;
    if (demand == 0 && row.pressure_supply == 0 && row.stock == 0) {
        idle = std::clamp<int64_t>(NativeEconomyRuntime::mul_div_sat(
            static_cast<int64_t>(_good_default_price[good]) - price,
            NativeEconomyRuntime::Q16_ONE,
            std::max<int64_t>(1, std::max<int64_t>(_good_default_price[good], price)), sat),
            -NativeEconomyRuntime::Q16_ONE, NativeEconomyRuntime::Q16_ONE);
    }
    int64_t total = 0;
    auto weighted = [&](int64_t value, int32_t weight) {
        total = NativeEconomyRuntime::saturating_add(total,
            NativeEconomyRuntime::mul_div_sat(value, weight,
                NativeEconomyRuntime::Q16_ONE, sat), sat);
    };
    weighted(excess, _good_excess_demand_weight_q16[good]);
    weighted(inventory, _good_inventory_weight_q16[good]);
    weighted(shortage, _good_shortage_weight_q16[good]);
    weighted(cost, _good_cost_anchor_weight_q16[good]);
    weighted(idle, _good_inactive_reversion_weight_q16[good]);
    return static_cast<int32_t>(std::clamp<int64_t>(
        total, std::numeric_limits<int32_t>::min(), std::numeric_limits<int32_t>::max()));
}

void EconomyCsvRecorder::set_terminal_locked(const std::string &code,
                                               const std::string &message,
                                               int64_t first_unrecorded_epoch) {
    _accepting = false;
    _stop_requested = true;
    _state = 3;
    _error_code = code;
    _error_message = message;
    _first_unrecorded_epoch = first_unrecorded_epoch;
}

bool EconomyCsvRecorder::capture_committed(
        NativeEconomyRuntime &runtime, const std::vector<const float *> &resource_arrays,
        std::string &reason) {
    if (!runtime._bootstrapped || runtime._epoch_active || runtime._fatal ||
        runtime._commit_day < 0) {
        reason = "not_committed";
        return false;
    }
    const int64_t epoch_id = runtime._epoch_id;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!_accepting || _state != 2) {
            reason = "not_recording";
            return false;
        }
        if (epoch_id == _last_captured_epoch) {
            reason = "same_epoch";
            return false;
        }
    }
    const int64_t rows = projected_rows(runtime);
    int32_t buffer_index = -1;
    int64_t epoch_row_id = 0;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!_accepting || _state != 2) {
            reason = "not_recording";
            return false;
        }
        if (epoch_id == _last_captured_epoch) {
            reason = "same_epoch";
            return false;
        }
        if (_captured_rows + rows > _config.max_rows) {
            set_terminal_locked("row_limit", "next committed epoch exceeds max_rows", epoch_id);
            reason = "row_limit";
            _cv.notify_one();
            return false;
        }
        for (int32_t i = 0; i < 2; ++i) {
            if (_buffer_states[i] == FREE) { buffer_index = i; break; }
        }
        if (buffer_index < 0) {
            set_terminal_locked("queue_full", "CSV writer did not keep up with committed epochs", epoch_id);
            reason = "queue_full";
            _cv.notify_one();
            return false;
        }
        _buffer_states[buffer_index] = FILLING;
        epoch_row_id = _captured_epochs + 1;
    }

    const auto start_time = Clock::now();
    Batch &batch = _buffers[buffer_index];
    batch.clear_rows();
    std::string fill_error;
    const bool filled = fill_batch(batch, runtime, resource_arrays, epoch_row_id, rows, fill_error);
    const int64_t elapsed_us = std::chrono::duration_cast<std::chrono::microseconds>(
        Clock::now() - start_time).count();
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _capture_us_last = elapsed_us;
        _capture_us_max = std::max(_capture_us_max, elapsed_us);
        _capture_samples_us.push_back(elapsed_us);
        if (_capture_samples_us.size() > 256) _capture_samples_us.pop_front();
        if (!filled) {
            _buffer_states[buffer_index] = FREE;
            set_terminal_locked("capture_failed", fill_error, epoch_id);
            reason = fill_error;
            _cv.notify_one();
            return false;
        }
        _buffer_states[buffer_index] = READY;
        _ready.push_back(buffer_index);
        _last_captured_epoch = epoch_id;
        ++_captured_epochs;
        _captured_rows += batch.row_count;
    }
    _cv.notify_one();
    reason.clear();
    return true;
}

bool EconomyCsvRecorder::fill_batch(
        Batch &batch, NativeEconomyRuntime &runtime,
        const std::vector<const float *> &resource_arrays,
        int64_t epoch_row_id, int64_t expected_rows, std::string &error) {
    if (_config.enabled[RESOURCES] && resource_arrays.size() != _config.resource_ids.size()) {
        error = "resource_array_count_mismatch";
        return false;
    }
    batch.epoch_id = runtime._epoch_id;
    const int64_t day = runtime._commit_day;

    if (_config.enabled[SUMMARY]) {
        SummaryRow row;
        row.epoch_row_id = epoch_row_id; row.epoch_id = runtime._epoch_id; row.day_index = day;
        row.epoch_active = runtime._epoch_active; row.stage = static_cast<int32_t>(runtime._stage);
        row.progress_q16 = runtime.stage_progress_q16(); row.sample_day = runtime._sample_day;
        row.commit_day = runtime._commit_day; row.cohort_count = runtime._population.active_count;
        row.market_count = runtime._market.market_count; row.good_count = runtime._market.good_count;
        row.building_type_count = runtime._building_types.size();
        row.building_group_count = runtime._buildings.size();
        row.pending_construction_count = runtime._pending_construction.size();
        row.filled_owner_jobs = runtime._filled_owner_jobs;
        row.filled_employee_jobs = runtime._filled_employee_jobs;
        row.unemployed_population = runtime._unemployed_population;
        row.births = runtime._births;
        row.deaths = runtime._deaths;
        row.production_inputs_consumed = runtime._production_inputs_consumed;
        row.production_output_stock = runtime._production_output_stock;
        row.production_output_discarded = runtime._production_output_discarded;
        row.production_output_retained = runtime._production_output_retained;
        row.production_output_supported = runtime._production_output_supported;
        row.owner_output_consumed = runtime._owner_output_consumed;
        row.producer_revenue = runtime._producer_revenue;
        row.producer_support_money_issued = runtime._producer_support_money_issued;
        row.bullion_money_issued = runtime._bullion_money_issued;
        row.bullion_stock_consumed = runtime._bullion_stock_consumed;
        row.gold_accepted = runtime._gold_accepted;
        row.silver_accepted = runtime._silver_accepted;
        row.gold_money_issued = runtime._gold_money_issued;
        row.silver_money_issued = runtime._silver_money_issued;
        row.cycle_flow_produced = runtime._cycle_flow_produced;
        row.cycle_flow_consumed = runtime._cycle_flow_consumed;
        row.cycle_flow_discarded = runtime._cycle_flow_discarded;
        row.building_wages_paid = runtime._building_wages_paid;
        row.building_wages_unpaid = runtime._building_wages_unpaid;
        row.building_resource_generated = runtime._building_resource_generated;
        row.building_resource_consumed = runtime._building_resource_consumed;
        row.building_resource_net_delta = runtime._building_resource_generated -
                                          runtime._building_resource_consumed;
        row.loss_suspended_building_groups = runtime._loss_suspended_building_groups;
        row.merchant_procurement_budget = runtime._merchant_procurement_budget;
        row.merchant_procurement_reserved = runtime._merchant_procurement_reserved;
        row.merchant_procurement_spent = runtime._merchant_procurement_spent;
        row.owner_working_capital_reserved = runtime._owner_working_capital_reserved;
        row.production_input_reserved = runtime._production_input_reserved;
        row.production_input_reserve_shortfall =
            runtime._production_input_reserve_shortfall;
        row.trade_runtime_mode = runtime._trade_runtime_mode;
        row.trade_topology_ready = runtime._trade_topology.ready;
        row.trade_topology_generation = runtime._trade_topology.topology_generation;
        row.trade_topology_hash = runtime._trade_topology.topology_hash;
        row.trade_country_generation = runtime._trade_topology.component_country_hash;
        row.trade_plan_phase = runtime._trade_plan.phase;
        row.trade_scan_cursor = runtime._trade_plan.scan_cursor;
        row.trade_scan_total = runtime._trade_plan.scan_total;
        row.trade_route_cursor = runtime._trade_plan.route_cursor;
        row.trade_route_total = runtime._trade_plan.sources.size();
        row.trade_completed_scans = runtime._trade_plan.completed_scans;
        row.trade_plan_reset_count = runtime._trade_plan_reset_count;
        row.trade_topology_content_change_count =
            runtime._trade_topology_content_change_count;
        row.trade_last_plan_reset_reason = runtime._trade_last_plan_reset_reason;
        row.trade_source_signals = runtime._trade_plan.sources.size();
        row.trade_destination_signals = runtime._trade_plan.destinations.size();
        row.trade_ready_candidates = runtime._trade_plan.ready_candidates.size();
        row.trade_route_expansions = runtime._trade_route_expansions;
        row.trade_route_cache_hits = runtime._trade_route_cache_hits;
        row.trade_route_cache_misses = runtime._trade_route_cache_misses;
        row.trade_candidates_generated = runtime._trade_candidates_generated;
        row.trade_candidates_accepted = runtime._trade_candidates_accepted;
        row.trade_rejected_profit = runtime._trade_rejected_profit;
        row.trade_rejected_capacity = runtime._trade_rejected_capacity;
        row.trade_rejected_stock = runtime._trade_rejected_stock;
        row.trade_rejected_cash = runtime._trade_rejected_cash;
        row.trade_rejected_route = runtime._trade_rejected_route;
        row.trade_rejected_order_cap = runtime._trade_rejected_order_cap;
        row.trade_orders_in_flight = runtime._trade_orders.size();
        row.trade_orders_dispatched = runtime._trade_orders_dispatched;
        row.trade_orders_arrived = runtime._trade_orders_arrived;
        row.trade_unclaimed_orders = runtime._trade_unclaimed_orders;
        row.trade_capacity_available = runtime._trade_capacity_available;
        row.trade_capacity_used = runtime._trade_capacity_used;
        batch.summary.push_back(row);
    }

    std::vector<int64_t> &inbound = batch.scratch_trade_inbound;
    std::vector<int64_t> &outbound = batch.scratch_trade_outbound;
    if (_config.enabled[MARKET]) {
        const size_t total = _sample_cells.size() * runtime._market.good_count;
        inbound.assign(total, 0); outbound.assign(total, 0);
        for (int32_t order = 0; order < runtime._trade_orders.size(); ++order) {
            if (runtime._trade_orders.cargo_delivered[order] != 0) continue;
            const int32_t src = runtime._trade_orders.sources[order];
            const int32_t dst = runtime._trade_orders.destinations[order];
            for (int32_t line = runtime._trade_orders.line_offsets[order];
                 line < runtime._trade_orders.line_offsets[order + 1]; ++line) {
                const int32_t good = runtime._trade_orders.line_goods[line];
                const int64_t qty = runtime._trade_orders.line_quantities[line];
                const int32_t src_pos = src >= 0 && src < runtime._cell_count
                    ? _sample_cell_positions[src] : -1;
                const int32_t dst_pos = dst >= 0 && dst < runtime._cell_count
                    ? _sample_cell_positions[dst] : -1;
                if (src_pos >= 0)
                    outbound[static_cast<size_t>(src_pos) * runtime._market.good_count + good] += qty;
                if (dst_pos >= 0)
                    inbound[static_cast<size_t>(dst_pos) * runtime._market.good_count + good] += qty;
            }
        }
    }

    batch.cohorts.reserve(_config.enabled[COHORTS] ? runtime._population.active_count : 0);
    batch.buildings.reserve(_config.enabled[BUILDINGS]
        ? runtime._buildings.size() + runtime._pending_construction.size() : 0);
    if (_config.enabled[MARKET]) batch.market.reserve(
        _sample_cells.size() * runtime._market.good_count);
    if (_config.enabled[RESOURCES]) batch.resources.reserve(
        _sample_cells.size() * resource_arrays.size());

    for (const int32_t cell : _sample_cells) {
        CommonCell common{epoch_row_id, runtime._epoch_id, day, cell,
                          _config.q[cell], _config.r[cell], _config.s[cell]};
        if (_config.enabled[COHORTS]) {
            int32_t cohort_index = 0;
            runtime._population.for_each_in_cell(cell, [&](int32_t slot) {
                CohortRow row;
                row.c = common; row.cohort_index = cohort_index++;
                row.handle = runtime._population.handle_for_slot(slot);
                row.signature_id = static_cast<int32_t>(runtime._population.signature_id[slot]);
                const auto &signature = runtime._signatures[row.signature_id];
                row.profession_id = signature.profession_id; row.ethnicity_id = signature.ethnicity_id;
                row.population = runtime._population.population[slot];
                row.funds = runtime._population.funds[slot];
                row.epoch_income = runtime._population.epoch_income[slot];
                row.epoch_expense = runtime._population.epoch_expense[slot];
                row.income_ema = runtime._population.income_ema[slot];
                row.satisfaction_q16 = runtime._population.needs_satisfaction[slot];
                const uint16_t worst = runtime._population.worst_need_id[slot];
                row.worst_need_id = worst == std::numeric_limits<uint16_t>::max() ? -1 : worst;
                row.merchant = runtime.is_merchant_slot(slot);
                row.owner_employed = runtime._population.owner_employed[slot];
                row.employee_employed = runtime._population.employee_employed[slot];
                row.unemployed = std::max<int64_t>(0, row.population - row.owner_employed - row.employee_employed);
                batch.cohorts.push_back(row);
            });
        }
        if (_config.enabled[BUILDINGS]) {
            int32_t group_index = 0;
            if (runtime._building_cell_offsets.size() == static_cast<size_t>(runtime._cell_count + 1)) {
                for (int32_t index = runtime._building_cell_offsets[cell];
                     index < runtime._building_cell_offsets[cell + 1]; ++index) {
                    const auto &group = runtime._buildings[index];
                    if (group.count <= 0) continue;
                    BuildingRow row;
                    row.c = common; row.group_index = group_index++; row.type_id = group.type_id;
                    row.owner_signature_id = group.owner_signature_id; row.count = group.count;
                    const auto &type = runtime._building_types[group.type_id];
                    int64_t snapshot_sat = 0;
                    row.owner_capacity = runtime.saturating_mul(
                        group.count, type.owner_slots_per_building, snapshot_sat);
                    row.owner_required = group.planned_utilization_q16 > 0
                        ? row.owner_capacity : 0;
                    row.planned_owner_equivalent = runtime.mul_div_sat(
                        row.owner_capacity, group.planned_utilization_q16,
                        NativeEconomyRuntime::Q16_ONE, snapshot_sat);
                    if (row.planned_owner_equivalent == 0 && row.owner_capacity > 0 &&
                        group.planned_utilization_q16 > 0) row.planned_owner_equivalent = 1;
                    row.filled_owner = group.filled_owner;
                    row.owner_openings = std::max<int64_t>(
                        0, row.owner_required - row.filled_owner);
                    row.wage_suspended = group.wage_suspended != 0;
                    row.capacity_q16 = group.last_capacity_q16; row.last_input = group.last_input;
                    row.purchase_intent_capacity_q16 = group.purchase_intent_capacity_q16;
                    row.realized_profit_margin_q16 = group.realized_profit_margin_q16;
                    row.severe_loss_cycles = group.severe_loss_cycles;
                    row.recovery_cycles = group.recovery_cycles;
                    row.operating_state = group.operating_state;
                    row.last_output = group.last_output; row.last_sold = group.last_sold;
                    row.last_discarded = group.last_discarded;
                    row.last_retained = std::max<int64_t>(0, group.last_output - group.last_sold - group.last_discarded);
                    row.last_resource = group.last_resource;
                    row.last_resource_generated = group.last_resource_generated;
                    row.last_revenue = group.last_revenue; row.last_input_cost = group.last_input_cost;
                    row.last_wages_paid = group.last_wages_paid; row.last_wages_due = group.last_wages_due;
                    row.last_expected_revenue = group.last_expected_revenue;
                    row.last_operating_cost = group.last_operating_cost;
                    row.last_margin_gap_q16 = group.last_margin_gap_q16;
                    row.planned_utilization_q16 = group.planned_utilization_q16;
                    row.last_base_wages_due = group.last_base_wages_due;
                    row.last_base_wages_paid = group.last_base_wages_paid;
                    row.last_bonus_due = group.last_bonus_due; row.last_bonus_paid = group.last_bonus_paid;
                    for (int32_t role = 0; role < type.employee_count; ++role) {
                        const auto &job = runtime._building_employee_roles[type.employee_begin + role];
                        const int64_t full = runtime.saturating_mul(group.count, job.slots_per_building, snapshot_sat);
                        int64_t required = runtime.mul_div_sat(full, group.planned_utilization_q16,
                                                               NativeEconomyRuntime::Q16_ONE, snapshot_sat);
                        if (required == 0 && full > 0 && group.planned_utilization_q16 > 0) required = 1;
                        row.employee_required += required;
                        row.employee_filled += runtime._building_employee_filled[group.employee_fill_begin + role];
                    }
                    batch.buildings.push_back(row);
                }
            }
            int32_t construction_index = 0;
            for (const auto &pending : runtime._pending_construction) {
                if (pending.cell != cell) continue;
                BuildingRow row;
                row.c = common; row.construction = true; row.group_index = construction_index++;
                row.type_id = pending.type_id; row.owner_signature_id = pending.owner_signature_id;
                row.count = pending.count; row.construction_ready_day = pending.ready_day;
                batch.buildings.push_back(row);
            }
        }
        if (_config.enabled[RESOURCES]) {
            for (int32_t resource = 0; resource < static_cast<int32_t>(resource_arrays.size()); ++resource) {
                if (resource_arrays[resource] == nullptr) {
                    error = "resource_slot_unavailable";
                    return false;
                }
                batch.resources.push_back(ResourceRow{common, resource, resource_arrays[resource][cell]});
            }
        }
        if (_config.enabled[MARKET]) {
            const int32_t market = runtime._market.cell_to_market[cell];
            const bool frozen_signals =
                runtime._epoch_business_demand_ema.size() ==
                    runtime._market_signals.business_demand_ema.size() &&
                runtime._epoch_offered_supply_ema.size() ==
                    runtime._market_signals.offered_supply_ema.size();
            for (int32_t good = 0; good < runtime._market.good_count; ++good) {
                MarketRow row;
                row.c = common; row.good_index = good;
                const int64_t mi = runtime._market.index(market, good);
                row.stock = runtime._market.stock[mi]; row.price = runtime._market.price[mi];
                row.demand_ema = runtime._market.demand_ema[mi];
                row.shortage_q16 = runtime._market.last_shortage_q16[mi];
                const int32_t signal = runtime.market_signal_index(cell, good);
                row.business_demand_ema = signal >= 0 ? runtime._market_signals.business_demand_ema[signal] : 0;
                row.offered_supply_ema = signal >= 0 ? runtime._market_signals.offered_supply_ema[signal] : 0;
                row.realized_withdrawal_ema = signal >= 0
                    ? runtime._market_signals.realized_withdrawal_ema[signal] : 0;
                row.production_input_reserve = signal >= 0 && signal <
                        static_cast<int32_t>(runtime._production_input_reserve.size())
                    ? runtime._production_input_reserve[signal] : 0;
                row.household_available_stock = std::max<int64_t>(
                    0, row.stock - row.production_input_reserve);
                row.cost_anchor_price = signal >= 0 ? runtime._market_signals.cost_anchor_price[signal] : 0;
                row.pressure_business_demand = signal < 0 ? 0 : (frozen_signals
                    ? runtime._epoch_business_demand_ema[signal]
                    : runtime._market_signals.business_demand_ema[signal]);
                row.pressure_supply = signal < 0 ? 0 : (frozen_signals
                    ? runtime._epoch_offered_supply_ema[signal]
                    : runtime._market_signals.offered_supply_ema[signal]);
                row.pressure_cost_anchor = signal < 0 ? 0 : (
                    runtime._epoch_cost_anchor_price.size() ==
                        runtime._market_signals.cost_anchor_price.size()
                    ? runtime._epoch_cost_anchor_price[signal]
                    : runtime._market_signals.cost_anchor_price[signal]);
                row.category_index = good; row.storage_mode = runtime._good_storage_modes[good];
                row.trade_enabled = runtime._good_trade_enabled[good] != 0;
                const int32_t flow = runtime.trade_flow_index(cell, good, false);
                row.trade_import_ema = flow >= 0 ? runtime._trade_flows.import_ema[flow] : 0;
                row.trade_export_ema = flow >= 0 ? runtime._trade_flows.export_ema[flow] : 0;
                int64_t target_sat = 0;
                row.merchant_inventory_target = runtime.merchant_inventory_target(
                    market, good, signal, row.realized_withdrawal_ema,
                    row.trade_export_ema, row.offered_supply_ema, target_sat);
                row.merchant_procurement_shortfall = std::max<int64_t>(
                    0, row.merchant_inventory_target - row.stock);
                const size_t flat = static_cast<size_t>(_sample_cell_positions[cell]) *
                                    runtime._market.good_count + good;
                row.trade_inbound = inbound[flat]; row.trade_outbound = outbound[flat];
                batch.market.push_back(row);
            }
        }
    }
    batch.row_count = static_cast<int64_t>(batch.summary.size() + batch.cohorts.size() +
        batch.buildings.size() + batch.resources.size() + batch.market.size());
    if (batch.row_count != expected_rows) {
        error = "projected_row_count_changed";
        return false;
    }
    return true;
}

bool EconomyCsvRecorder::open_files(std::string &error) {
    for (int32_t dim = 0; dim < DIM_COUNT; ++dim) {
        if (!_config.enabled[dim]) continue;
        const std::filesystem::path path = std::filesystem::u8path(_config.paths[dim]);
        _files[dim].open(path, std::ios::binary | std::ios::trunc);
        if (!_files[dim].is_open()) {
            error = "csv_open_failed: " + _config.paths[dim];
            close_files();
            return false;
        }
        static constexpr char bom[] = {'\xEF', '\xBB', '\xBF'};
        _files[dim].write(bom, 3);
        _files[dim].write(HEADERS[dim], static_cast<std::streamsize>(std::char_traits<char>::length(HEADERS[dim])));
        if (!_files[dim].good()) {
            error = "csv_header_write_failed: " + _config.paths[dim];
            close_files();
            return false;
        }
    }
    return true;
}

void EconomyCsvRecorder::close_files() {
    for (auto &file : _files) if (file.is_open()) file.close();
}

bool EconomyCsvRecorder::write_batch(const Batch &batch, int64_t &bytes, std::string &error) {
    std::array<std::uintmax_t, DIM_COUNT> rollback{};
    for (int32_t dim = 0; dim < DIM_COUNT; ++dim) {
        if (!_config.enabled[dim]) continue;
        const std::streampos pos = _files[dim].tellp();
        if (pos < 0) { error = "csv_tell_failed"; return false; }
        rollback[dim] = static_cast<std::uintmax_t>(pos);
    }
    const auto encode_start = Clock::now();
    int64_t local_bytes = 0;
    int64_t local_write_us = 0;
    std::string chunk;
    chunk.reserve(WRITE_CHUNK_BYTES + 4096);
    auto flush = [&](int32_t dim) -> bool {
        if (chunk.empty()) return true;
        const bool ok = write_chunked(
            _files[dim], chunk, local_bytes, local_write_us,
            _config.test_fail_after_bytes, error);
        chunk.clear();
        return ok;
    };
    auto maybe_flush = [&](int32_t dim) -> bool {
        return chunk.size() < WRITE_CHUNK_BYTES || flush(dim);
    };

    if (_config.enabled[SUMMARY]) for (const SummaryRow &row : batch.summary) {
        append_int(chunk, row.epoch_row_id); field(chunk, row.epoch_id); field(chunk, row.day_index);
        bool_field(chunk, row.epoch_active); text_field(chunk, economy_stage_name(row.stage));
        field(chunk, row.progress_q16); field(chunk, row.sample_day); field(chunk, row.commit_day);
        field(chunk, row.cohort_count); field(chunk, row.market_count); field(chunk, row.good_count);
        field(chunk, row.building_type_count); field(chunk, row.building_group_count);
        field(chunk, row.pending_construction_count); field(chunk, row.filled_owner_jobs);
        field(chunk, row.filled_employee_jobs); field(chunk, row.unemployed_population);
        field(chunk, row.births); field(chunk, row.deaths);
        field(chunk, row.production_inputs_consumed);
        field(chunk, row.production_output_stock); field(chunk, row.production_output_discarded);
        field(chunk, row.production_output_retained); field(chunk, row.production_output_supported);
        field(chunk, row.owner_output_consumed); field(chunk, row.producer_revenue);
        field(chunk, row.producer_support_money_issued); field(chunk, row.bullion_money_issued);
        field(chunk, row.bullion_stock_consumed); field(chunk, row.gold_accepted);
        field(chunk, row.silver_accepted); field(chunk, row.gold_money_issued);
        field(chunk, row.silver_money_issued); field(chunk, row.cycle_flow_produced);
        field(chunk, row.cycle_flow_consumed); field(chunk, row.cycle_flow_discarded);
        field(chunk, row.building_wages_paid);
        field(chunk, row.building_wages_unpaid); field(chunk, row.building_resource_generated);
        field(chunk, row.building_resource_consumed); field(chunk, row.building_resource_net_delta);
        field(chunk, row.loss_suspended_building_groups);
        field(chunk, row.merchant_procurement_budget); field(chunk, row.merchant_procurement_reserved);
        field(chunk, row.merchant_procurement_spent);
        field(chunk, row.owner_working_capital_reserved);
        field(chunk, row.production_input_reserved);
        field(chunk, row.production_input_reserve_shortfall);
        text_field(chunk, trade_mode_name(row.trade_runtime_mode)); bool_field(chunk, row.trade_topology_ready);
        field(chunk, row.trade_topology_generation); field(chunk, row.trade_topology_hash);
        field(chunk, row.trade_country_generation);
        text_field(chunk, trade_plan_phase_name(row.trade_plan_phase));
        field(chunk, row.trade_scan_cursor); field(chunk, row.trade_scan_total);
        field(chunk, row.trade_route_cursor); field(chunk, row.trade_route_total);
        field(chunk, row.trade_completed_scans); field(chunk, row.trade_plan_reset_count);
        field(chunk, row.trade_topology_content_change_count);
        text_field(chunk, row.trade_last_plan_reset_reason);
        field(chunk, row.trade_source_signals); field(chunk, row.trade_destination_signals);
        field(chunk, row.trade_ready_candidates); field(chunk, row.trade_route_expansions);
        field(chunk, row.trade_route_cache_hits); field(chunk, row.trade_route_cache_misses);
        field(chunk, row.trade_candidates_generated); field(chunk, row.trade_candidates_accepted);
        field(chunk, row.trade_rejected_profit); field(chunk, row.trade_rejected_capacity);
        field(chunk, row.trade_rejected_stock); field(chunk, row.trade_rejected_cash);
        field(chunk, row.trade_rejected_route); field(chunk, row.trade_rejected_order_cap);
        field(chunk, row.trade_orders_in_flight); field(chunk, row.trade_orders_dispatched);
        field(chunk, row.trade_orders_arrived); field(chunk, row.trade_unclaimed_orders);
        field(chunk, row.trade_capacity_available); field(chunk, row.trade_capacity_used);
        field(chunk, row.population_error); field(chunk, row.money_error); field(chunk, row.goods_error);
        chunk.push_back('\n'); if (!maybe_flush(SUMMARY)) goto write_failed;
    }
    if (!flush(SUMMARY)) goto write_failed;

    if (_config.enabled[COHORTS]) for (const CohortRow &row : batch.cohorts) {
        append_common(chunk, row.c); field(chunk, row.cohort_index); field(chunk, row.handle);
        field(chunk, row.signature_id); field(chunk, row.profession_id); field(chunk, row.ethnicity_id);
        field(chunk, row.population); field(chunk, row.funds); field(chunk, row.epoch_income);
        field(chunk, row.epoch_expense); field(chunk, row.income_ema); field(chunk, row.satisfaction_q16);
        field(chunk, row.worst_need_id); field(chunk, row.merchant ? 1 : 0);
        field(chunk, row.owner_employed); field(chunk, row.employee_employed); field(chunk, row.unemployed);
        chunk.push_back('\n'); if (!maybe_flush(COHORTS)) goto write_failed;
    }
    if (!flush(COHORTS)) goto write_failed;

    if (_config.enabled[BUILDINGS]) for (const BuildingRow &row : batch.buildings) {
        append_common(chunk, row.c); field(chunk, row.construction ? 1 : 0); field(chunk, row.group_index);
        field(chunk, row.type_id); field(chunk, row.owner_signature_id); field(chunk, row.count);
        if (row.construction) {
            for (int i = 0; i < 33; ++i) blank_field(chunk);
            append_int(chunk, row.construction_ready_day);
        } else {
            field(chunk, row.owner_capacity); field(chunk, row.owner_required);
            field(chunk, row.planned_owner_equivalent);
            field(chunk, row.filled_owner); field(chunk, row.owner_openings);
            field(chunk, row.employee_required); field(chunk, row.employee_filled);
            field(chunk, row.wage_suspended ? 1 : 0); field(chunk, row.capacity_q16);
            field(chunk, row.purchase_intent_capacity_q16);
            field(chunk, row.realized_profit_margin_q16); field(chunk, row.severe_loss_cycles);
            field(chunk, row.recovery_cycles); field(chunk, row.operating_state);
            field(chunk, row.last_input); field(chunk, row.last_output); field(chunk, row.last_sold);
            field(chunk, row.last_discarded); field(chunk, row.last_retained); field(chunk, row.last_resource);
            field(chunk, row.last_resource_generated); field(chunk, row.last_revenue); field(chunk, row.last_input_cost);
            field(chunk, row.last_wages_paid); field(chunk, row.last_wages_due); field(chunk, row.last_expected_revenue);
            field(chunk, row.last_operating_cost); field(chunk, row.last_margin_gap_q16);
            field(chunk, row.planned_utilization_q16); field(chunk, row.last_base_wages_due);
            field(chunk, row.last_base_wages_paid); field(chunk, row.last_bonus_due); field(chunk, row.last_bonus_paid);
            blank_field(chunk);
        }
        chunk.push_back('\n'); if (!maybe_flush(BUILDINGS)) goto write_failed;
    }
    if (!flush(BUILDINGS)) goto write_failed;

    if (_config.enabled[RESOURCES]) for (const ResourceRow &row : batch.resources) {
        append_common(chunk, row.c); text_field(chunk, _config.resource_ids[row.resource_index]);
        chunk.push_back(','); append_float(chunk, row.reserve); chunk.push_back('\n');
        if (!maybe_flush(RESOURCES)) goto write_failed;
    }
    if (!flush(RESOURCES)) goto write_failed;

    if (_config.enabled[MARKET]) for (const MarketRow &row : batch.market) {
        append_common(chunk, row.c); text_field(chunk, _good_ids[row.good_index]);
        field(chunk, row.stock); field(chunk, row.price); field(chunk, row.demand_ema);
        field(chunk, row.business_demand_ema); field(chunk, row.offered_supply_ema);
        field(chunk, row.realized_withdrawal_ema); field(chunk, row.production_input_reserve);
        field(chunk, row.household_available_stock); field(chunk, row.merchant_inventory_target);
        field(chunk, row.merchant_procurement_shortfall);
        field(chunk, row.cost_anchor_price); field(chunk, row.shortage_q16);
        field(chunk, price_pressure_total_q16(row));
        text_field(chunk, _good_category_ids[row.category_index]); field(chunk, row.storage_mode);
        field(chunk, row.trade_enabled ? 1 : 0); field(chunk, row.trade_import_ema);
        field(chunk, row.trade_export_ema); field(chunk, row.trade_inbound); field(chunk, row.trade_outbound);
        chunk.push_back('\n'); if (!maybe_flush(MARKET)) goto write_failed;
    }
    if (!flush(MARKET)) goto write_failed;
    for (int32_t dim = 0; dim < DIM_COUNT; ++dim) {
        if (!_config.enabled[dim]) continue;
        const auto flush_start = Clock::now();
        _files[dim].flush();
        local_write_us += std::chrono::duration_cast<std::chrono::microseconds>(
            Clock::now() - flush_start).count();
        if (!_files[dim].good()) {
            error = "csv_flush_failed";
            goto write_failed;
        }
    }
    const int64_t total_us = std::chrono::duration_cast<std::chrono::microseconds>(
        Clock::now() - encode_start).count();
    _write_us_last = local_write_us;
    _encode_us_last = std::max<int64_t>(0, total_us - local_write_us);
    bytes = local_bytes;
    return true;

write_failed:
    close_files();
    for (int32_t dim = 0; dim < DIM_COUNT; ++dim) {
        if (!_config.enabled[dim]) continue;
        std::error_code ec;
        std::filesystem::resize_file(std::filesystem::u8path(_config.paths[dim]), rollback[dim], ec);
    }
    return false;
}

void EconomyCsvRecorder::worker_main() {
    std::string open_error;
    const bool opened = open_files(open_error);
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _open_ok = opened; _open_done = true;
        if (!opened) {
            _state = 5; _error_code = "open_failed"; _error_message = open_error;
            _worker_finished = true;
        }
    }
    _open_cv.notify_one();
    if (!opened) return;

    for (;;) {
        int32_t index = -1;
        {
            std::unique_lock<std::mutex> lock(_mutex);
            _cv.wait(lock, [&] { return !_ready.empty() || _stop_requested; });
            if (_ready.empty()) {
                if (_stop_requested) break;
                continue;
            }
            index = _ready.front(); _ready.pop_front();
            _buffer_states[index] = WRITING; _worker_busy = true;
        }
        int64_t bytes = 0;
        std::string write_error;
        if (_config.test_write_delay_ms > 0)
            std::this_thread::sleep_for(std::chrono::milliseconds(_config.test_write_delay_ms));
        const bool ok = write_batch(_buffers[index], bytes, write_error);
        {
            std::lock_guard<std::mutex> lock(_mutex);
            _worker_busy = false;
            if (ok) {
                ++_written_epochs; _written_rows += _buffers[index].row_count;
                _bytes_written += bytes;
                _buffers[index].clear_rows(); _buffer_states[index] = FREE;
            } else {
                _buffer_states[index] = FREE;
                _accepting = false; _stop_requested = true; _state = 5;
                _error_code = "write_failed"; _error_message = write_error;
                while (!_ready.empty()) {
                    const int32_t pending = _ready.front(); _ready.pop_front();
                    _buffers[pending].clear_rows(); _buffer_states[pending] = FREE;
                }
                break;
            }
        }
    }
    close_files();
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _worker_finished = true; _worker_busy = false;
        if (_state != 5) _state = _error_code.empty() ? 4 : 5;
    }
}

void EconomyCsvRecorder::request_stop() {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_state != 1 && _state != 2 && _state != 3) return;
        _accepting = false; _stop_requested = true;
        if (_state != 5) _state = 3;
    }
    _cv.notify_one();
}

void EconomyCsvRecorder::shutdown() {
    request_stop();
    if (_worker.joinable()) _worker.join();
    close_files();
    std::lock_guard<std::mutex> lock(_mutex);
    if (_state == 1 || _state == 2 || _state == 3) _state = _error_code.empty() ? 4 : 5;
}

godot::Dictionary EconomyCsvRecorder::status() const {
    std::lock_guard<std::mutex> lock(_mutex);
    godot::Dictionary out;
    int64_t buffer_memory_bytes = 0;
    for (const Batch &batch : _buffers) {
        buffer_memory_bytes += static_cast<int64_t>(batch.summary.capacity() * sizeof(SummaryRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.cohorts.capacity() * sizeof(CohortRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.buildings.capacity() * sizeof(BuildingRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.resources.capacity() * sizeof(ResourceRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.market.capacity() * sizeof(MarketRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.scratch_trade_inbound.capacity() * sizeof(int64_t));
        buffer_memory_bytes += static_cast<int64_t>(batch.scratch_trade_outbound.capacity() * sizeof(int64_t));
    }
    std::vector<int64_t> capture_samples(_capture_samples_us.begin(), _capture_samples_us.end());
    std::sort(capture_samples.begin(), capture_samples.end());
    const int64_t capture_p95_us = capture_samples.empty() ? 0 : capture_samples[
        std::min(capture_samples.size() - 1,
                 static_cast<size_t>(std::ceil(capture_samples.size() * 0.95)) - 1)];
    out["state"] = state_name(_state);
    out["schema_version"] = SCHEMA_VERSION;
    out["recording"] = _accepting && _state == 2;
    out["draining"] = _state == 3;
    out["captured_epochs"] = _captured_epochs;
    out["written_epochs"] = _written_epochs;
    out["last_captured_epoch"] = _last_captured_epoch;
    out["captured_rows"] = _captured_rows;
    out["written_rows"] = _written_rows;
    out["bytes_written"] = _bytes_written;
    out["buffer_memory_bytes"] = buffer_memory_bytes;
    out["queued_batches"] = static_cast<int64_t>(_ready.size()) + (_worker_busy ? 1 : 0);
    out["writer_busy"] = _worker_busy;
    out["capture_ms_last"] = static_cast<double>(_capture_us_last) / 1000.0;
    out["capture_ms_p95"] = static_cast<double>(capture_p95_us) / 1000.0;
    out["capture_ms_max"] = static_cast<double>(_capture_us_max) / 1000.0;
    out["worker_encode_ms_last"] = static_cast<double>(_encode_us_last) / 1000.0;
    out["worker_write_ms_last"] = static_cast<double>(_write_us_last) / 1000.0;
    out["max_rows"] = _config.max_rows;
    out["sampled_cell_count"] = static_cast<int64_t>(_sample_cells.size());
    out["cell_scope"] = _config.cell_indices.empty() ? "all" : "selected";
    out["selected_cell_index"] = _config.cell_indices.size() == 1
        ? _config.cell_indices.front() : -1;
    out["error_code"] = godot::String(_error_code.c_str());
    out["error_message"] = godot::String(_error_message.c_str());
    out["hit_limit"] = _error_code == "row_limit";
    out["first_unrecorded_epoch"] = _first_unrecorded_epoch;
    godot::PackedStringArray paths;
    for (int32_t dim = 0; dim < DIM_COUNT; ++dim)
        if (_config.enabled[dim]) paths.push_back(godot::String::utf8(_config.paths[dim].c_str()));
    out["paths"] = paths;
    return out;
}

} // namespace pk

#include "economy_csv_recorder.h"

#include "economy_record_source.h"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
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
    "epoch_row_id,epoch_id,day_index,epoch_active,stage,progress_q16,sample_day,commit_day,cohort_count,market_count,good_count,building_type_count,building_group_count,pending_construction_count,filled_owner_jobs,filled_employee_jobs,unemployed_population,births,deaths,production_inputs_consumed,production_output_stock,production_output_discarded,production_output_retained,production_output_supported,owner_output_consumed,producer_revenue,producer_support_money_issued,bullion_money_issued,bullion_stock_consumed,gold_accepted,silver_accepted,gold_money_issued,silver_money_issued,cycle_flow_produced,cycle_flow_consumed,cycle_flow_discarded,building_wages_paid,building_wages_unpaid,building_resource_generated,building_resource_consumed,building_resource_net_delta,loss_suspended_building_groups,merchant_procurement_budget,merchant_procurement_opportunity,merchant_procurement_allocated,merchant_procurement_unspent_allocated,merchant_procurement_reserved,merchant_procurement_spent,owner_working_capital_reserved,production_input_reserved,production_input_reserve_shortfall,construction_material_reserved,maintenance_goods_consumed,maintenance_unmet,trade_runtime_mode,trade_topology_ready,trade_topology_generation,trade_topology_hash,trade_country_generation,trade_plan_phase,trade_scan_cursor,trade_scan_total,trade_route_cursor,trade_route_total,trade_completed_scans,trade_plan_reset_count,trade_topology_content_change_count,trade_last_plan_reset_reason,trade_source_signals,trade_destination_signals,trade_ready_candidates,trade_route_expansions,trade_route_cache_hits,trade_route_cache_misses,trade_candidates_generated,trade_candidates_accepted,trade_rejected_profit,trade_rejected_no_spread,trade_rejected_margin,trade_quantity_profit_clips,trade_relief_candidates,trade_rejected_capacity,trade_rejected_stock,trade_rejected_cash,trade_rejected_route,trade_rejected_order_cap,trade_orders_in_flight,trade_orders_dispatched,trade_orders_arrived,trade_unclaimed_orders,trade_capacity_available,trade_capacity_used,population_error,money_error,goods_error,construction_goods_consumed,building_investment_candidates,building_owner_mobility,building_owner_job_reallocations,building_owner_job_profession_changes,building_owner_job_probability_skips,building_employee_to_owner_reallocations,building_investments_started,building_investment_blocked_funds,building_investment_blocked_materials,building_investment_blocked_sponsor_capital,building_investment_blocked_resources,building_investment_probability_skips,building_investment_capital_transferred,desired_business_demand,funded_business_demand,unfunded_business_demand,owner_working_capital_allocated,trade_signal_max_age_days,trade_first_dispatch_delay_max_days,trade_response_deadline_misses,trade_response_deadline_misses_cumulative,trade_unresolved_no_attempt,trade_unresolved_no_spread,trade_unresolved_margin,trade_unresolved_route,trade_unresolved_stock,trade_unresolved_capacity,trade_unresolved_cash,trade_unresolved_order_cap,merchant_credit_budget,merchant_credit_committed,merchant_credit_drawn,merchant_credit_repaid,merchant_credit_premium_repaid,merchant_credit_outstanding,merchant_credit_bad_debt,recovery_candidates,recovery_approved,recovery_restarted,recovery_failed,recovery_liquidated_buildings,trade_active_keys_pruned,trade_deficit_episodes_started,trade_deficit_episodes_resolved,trade_candidates_stale_generation,trade_candidates_arbitrated_out,trade_true_source_stock_failures,merchant_cash,merchant_inventory_retail_value,merchant_inventory_liquidation_value,merchant_economic_assets,merchant_procurement_margin_value,merchant_trade_purchase_cash,merchant_trade_sale_cash,merchant_operating_outflow,merchant_liquidity_coverage_q16,merchant_effective_buy_factor_q16\n",
    "epoch_row_id,epoch_id,day_index,cell_idx,q,r,s,cohort_index,handle,signature_id,profession_id,ethnicity_id,population,funds,epoch_income,epoch_expense,epoch_in_kind_income,cash_expense_coverage_q16,livelihood_coverage_q16,income_ema,satisfaction_q16,worst_need_id,is_merchant,owner_employed,employee_employed,unemployed,epoch_tax_paid,epoch_subsidy_received,cell_births,cell_deaths,cell_moved_in,cell_moved_out\n",
    "epoch_row_id,epoch_id,day_index,cell_idx,q,r,s,is_construction,group_index,type_id,owner_signature_id,count,owner_capacity,owner_required,planned_owner_equivalent,filled_owner,owner_openings,employee_required,employee_filled,wage_suspended,capacity_q16,purchase_intent_capacity_q16,realized_profit_margin_q16,severe_loss_cycles,recovery_cycles,operating_state,last_input,last_output,last_sold,last_discarded,last_retained,last_resource,last_resource_generated,last_revenue,last_input_cost,last_wages_paid,last_wages_due,last_expected_revenue,last_operating_cost,last_margin_gap_q16,planned_utilization_q16,last_base_wages_due,last_base_wages_paid,last_bonus_due,last_bonus_paid,owner_living_cost_per_day,owner_livelihood_required,viability_operating_cost,viability_income_gap,projected_owner_income_per_day,construction_ready_days,funded_capacity_q16,owner_working_capital_allocated,investment_score_q16,investment_payback_days,investment_rejection_reason,merchant_debt_principal,merchant_debt_premium,merchant_debt_term_cycles_left,merchant_debt_delinquent_cycles,last_in_kind_livelihood_value,recovery_failed_reviews,investment_candidate,investment_shortage_q16,investment_utilization_q16,investment_required_capital,investment_projected_profit_per_day,investment_driver_good_id,investment_driver_pressure_q16,investment_driver_utilization_q16,investment_driver_sellable,investment_driver_merchant_sold,investment_driver_sell_through_q16,investment_driver_discard_q16\n",
    "epoch_row_id,epoch_id,day_index,cell_idx,q,r,s,resource_id,opening_reserve,natural_net_change,natural_positive_change,natural_negative_change,artificial_change_applied,artificial_change_pending,artificial_generation_applied,artificial_extraction_applied,artificial_generation_pending,artificial_extraction_pending,reserve,stock_density_q16,managed_harvest_enabled,safe_yield,projected_life_days\n",
    "epoch_row_id,epoch_id,day_index,cell_idx,q,r,s,good_id,stock,price,demand_ema,business_demand_ema,offered_supply_ema,realized_withdrawal_ema,production_input_reserve,construction_material_reserve,household_available_stock,merchant_inventory_target,merchant_procurement_shortfall,cost_anchor_price,shortage_q16,price_pressure_total_q16,category_id,storage_mode,trade_enabled,trade_import_ema,trade_export_ema,trade_inbound,trade_outbound,desired_business_demand,funded_business_demand,unfunded_business_demand,trade_export_safety_stock,trade_import_fill_target,trade_relief_pressure_q16,trade_signal_age_days,trade_first_dispatch_delay_days,trade_last_attempt_day,trade_last_rejection_reason,trade_deadline_exceeded,merchant_cash,merchant_inventory_retail_value,merchant_inventory_liquidation_value,merchant_economic_assets,merchant_procurement_margin_value,merchant_trade_purchase_cash,merchant_trade_sale_cash,merchant_operating_outflow,merchant_liquidity_coverage_q16,merchant_effective_buy_factor_q16\n",
};
constexpr const char *SUMMARY_V25_SUFFIX =
    ",building_investment_buildings_started"
    ",building_investment_portfolios_started"
    ",building_investment_types_started"
    ",building_investment_owner_population_moved"
    ",building_investment_max_type_owner_share_q16"
    ",building_investment_demand_limited"
    ",building_investment_material_limited"
    ",building_investment_capital_limited"
    ",building_investment_owner_population_limited"
    ",recovery_partially_liquidated_buildings"
    ",recovery_fully_liquidated_groups"
    ",merchant_survival_procurement_required"
    ",merchant_survival_procurement_allocated"
    ",merchant_input_procurement_required"
    ",merchant_input_procurement_allocated"
    ",climate_profiled_building_groups"
    ",climate_limited_building_groups"
    ",average_climate_capacity_q16"
    ",suspended_restart_candidates"
    ",suspended_restart_approved"
    ",suspended_restart_restarted"
    ",suspended_restart_failed"
    ",suspended_liquidated_buildings"
    ",suspended_partially_liquidated_buildings"
    ",suspended_fully_liquidated_groups"
    ",building_investment_jobs_started"
    ",building_investment_employment_gap"
    ",building_investment_employment_catchup_cells"
    ",building_investment_displacement_starts"
    ",investment_displacement_type_evaluations"
    ",bullion_quota_initial"
    ",bullion_quota_remaining"
    ",bullion_quota_remainder_units\n";
constexpr const char *MARKET_V25_SUFFIX =
    ",derived_business_demand"
    ",shadow_anchor_price"
    ",price_pressure_derived_q16\n";
constexpr const char *BUILDING_V25_SUFFIX =
    ",last_temperature_fit_q16"
    ",last_water_fit_q16"
    ",last_climate_capacity_q16"
    ",last_climate_lost_output"
    ",suspended_restart_cycles"
    ",suspended_liquidation_failed_reviews"
    ",investment_failed_material_group"
    ",investment_selected_material_good_ids"
    ",investment_selected_material_quantities"
    ",investment_stealable"
    ",investment_challenger_unit_cost"
    ",investment_incumbent_unit_cost"
    ",investment_return_on_capital_q16"
    ",investment_cost_advantage_q16"
    ",investment_monetary_quota_initial"
    ",investment_monetary_quota_daily"
    ",investment_monetary_units"
    ",investment_monetary_candidate_slots"
    ",investment_monetary_request_money_per_day"
    ",investment_monetary_expected_revenue_per_day"
    ",opportunity_owner_income_per_day"
    ",opportunity_disposable_survival_power_per_day"
    ",opportunity_executable_capacity_q16"
    ",opportunity_in_kind_retail_value"
    ",survival_priority"
    ",survival_shortage_q16"
    ",monetary_quota_absorption_q16"
    ",monetary_quote_capped"
    ",employment_candidate"
    ",employment_diagnostic_day"
    ",employment_role"
    ",employment_target_signature"
    ",employment_profession_id"
    ",employment_source_ethnicity"
    ",employment_pool_slot"
    ",employment_pool_signature"
    ",employment_pool_population"
    ",employment_vacancy"
    ",employment_target_disposable"
    ",employment_source_disposable"
    ",employment_improvement_q16"
    ",employment_hurdle_q16"
    ",employment_weight_q16"
    ",employment_budget"
    ",employment_allocation"
    ",employment_take"
    ",employment_eligible"
    ",employment_rejection_reason"
    ",employment_group"
    ",employment_owner_target"
    ",employment_filled_before_clamp"
    ",employment_filled_after_profession_clamp"
    ",employment_filled_after_family_clamp"
    ",employment_family_owned"
    ",employment_family_member_people"
    ",employment_anonymous_people"
    ",employment_owner_cohort_population"
    ",employment_shed_surplus\n";

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

EconomyCsvRecorder::EconomyCsvRecorder() : _source(std::make_unique<EconomyRecordSource>()) {}
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
    if (!_source->configure(config, runtime, _buffers, error)) return false;
    _config = _source->config();
    _good_ids = _source->good_ids();
    _good_category_ids = _source->good_category_ids();
    _good_storage_modes = _source->good_storage_modes();
    _buffer_states = {{FREE, FREE}};
    _ready.clear();
    _error_code.clear(); _error_message.clear();
    _last_captured_epoch = -1; _first_unrecorded_epoch = -1;
    _captured_epochs = 0; _written_epochs = 0;
    _captured_rows = 0; _written_rows = 0; _bytes_written = 0;
    _capture_us_last = 0; _capture_us_max = 0;
    _capture_samples_us.clear();
    _backpressure_wait_count = 0; _backpressure_wait_us = 0;
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

bool EconomyCsvRecorder::capture_worker_committed(
        NativeEconomyRuntime &runtime, std::string &reason) {
    std::vector<std::vector<float>> lanes;
    _source->worker_resources(runtime, lanes);
    std::vector<const float *> arrays;
    arrays.reserve(lanes.size());
    for (const auto &lane : lanes) arrays.push_back(lane.empty() ? nullptr : lane.data());
    return capture_committed(runtime, arrays, reason);
}

bool EconomyCsvRecorder::capture_committed(
        NativeEconomyRuntime &runtime, const std::vector<const float *> &resource_arrays,
        std::string &reason) {
    const int64_t epoch_id = EconomyRecordSource::committed_epoch(runtime);
    if (epoch_id < 0) {
        reason = "not_committed";
        return false;
    }
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
    const int64_t rows = _source->projected_rows(runtime);
    int32_t buffer_index = -1;
    int64_t epoch_row_id = 0;
    {
        std::unique_lock<std::mutex> lock(_mutex);
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
            _cv.notify_all();
            return false;
        }
        auto find_free_buffer = [&]() {
            for (int32_t i = 0; i < 2; ++i)
                if (_buffer_states[i] == FREE) return i;
            return int32_t{-1};
        };
        buffer_index = find_free_buffer();
        if (buffer_index < 0) {
            const auto wait_start = Clock::now();
            ++_backpressure_wait_count;
            _cv.wait(lock, [&] {
                return find_free_buffer() >= 0 || !_accepting || _state != 2;
            });
            _backpressure_wait_us += std::chrono::duration_cast<std::chrono::microseconds>(
                Clock::now() - wait_start).count();
            if (!_accepting || _state != 2) {
                reason = _error_code.empty() ? "not_recording" : _error_code;
                return false;
            }
            buffer_index = find_free_buffer();
        }
        _buffer_states[buffer_index] = FILLING;
        epoch_row_id = _captured_epochs + 1;
    }

    const auto start_time = Clock::now();
    Batch &batch = _buffers[buffer_index];
    batch.clear_rows();
    std::string fill_error;
    const bool filled = _source->fill_batch(batch, runtime, resource_arrays, epoch_row_id, rows, fill_error);
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
            _cv.notify_all();
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
        const size_t header_length =
            std::char_traits<char>::length(HEADERS[dim]);
        if ((dim == SUMMARY || dim == BUILDINGS || dim == MARKET) &&
            header_length > 0 && HEADERS[dim][header_length - 1] == '\n') {
            _files[dim].write(HEADERS[dim],
                static_cast<std::streamsize>(header_length - 1));
            const char *suffix = dim == SUMMARY ? SUMMARY_V25_SUFFIX
                : dim == BUILDINGS ? BUILDING_V25_SUFFIX : MARKET_V25_SUFFIX;
            _files[dim].write(suffix, static_cast<std::streamsize>(
                std::char_traits<char>::length(suffix)));
        } else {
            _files[dim].write(HEADERS[dim],
                static_cast<std::streamsize>(header_length));
        }
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
        field(chunk, row.merchant_procurement_budget);
        field(chunk, row.merchant_procurement_opportunity); field(chunk, row.merchant_procurement_allocated);
        field(chunk, row.merchant_procurement_unspent_allocated); field(chunk, row.merchant_procurement_reserved);
        field(chunk, row.merchant_procurement_spent);
        field(chunk, row.owner_working_capital_reserved);
        field(chunk, row.production_input_reserved);
        field(chunk, row.production_input_reserve_shortfall);
        field(chunk, row.construction_material_reserved);
        field(chunk, row.maintenance_goods_consumed);
        field(chunk, row.maintenance_unmet);
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
        field(chunk, row.trade_rejected_profit); field(chunk, row.trade_rejected_no_spread);
        field(chunk, row.trade_rejected_margin); field(chunk, row.trade_quantity_profit_clips);
        field(chunk, row.trade_relief_candidates); field(chunk, row.trade_rejected_capacity);
        field(chunk, row.trade_rejected_stock); field(chunk, row.trade_rejected_cash);
        field(chunk, row.trade_rejected_route); field(chunk, row.trade_rejected_order_cap);
        field(chunk, row.trade_orders_in_flight); field(chunk, row.trade_orders_dispatched);
        field(chunk, row.trade_orders_arrived); field(chunk, row.trade_unclaimed_orders);
        field(chunk, row.trade_capacity_available); field(chunk, row.trade_capacity_used);
        field(chunk, row.population_error); field(chunk, row.money_error); field(chunk, row.goods_error);
        field(chunk, row.construction_goods_consumed);
        field(chunk, row.building_investment_candidates);
        field(chunk, row.building_owner_mobility);
        field(chunk, row.building_owner_job_reallocations);
        field(chunk, row.building_owner_job_profession_changes);
        field(chunk, row.building_owner_job_probability_skips);
        field(chunk, row.building_employee_to_owner_reallocations);
        field(chunk, row.building_investments_started);
        field(chunk, row.building_investment_blocked_funds);
        field(chunk, row.building_investment_blocked_materials);
        field(chunk, row.building_investment_blocked_sponsor_capital);
        field(chunk, row.building_investment_blocked_resources);
        field(chunk, row.building_investment_probability_skips);
        field(chunk, row.building_investment_capital_transferred);
        field(chunk, row.desired_business_demand);
        field(chunk, row.funded_business_demand);
        field(chunk, row.unfunded_business_demand);
        field(chunk, row.owner_working_capital_allocated);
        field(chunk, row.trade_signal_max_age_days);
        field(chunk, row.trade_first_dispatch_delay_max_days);
        field(chunk, row.trade_response_deadline_misses);
        field(chunk, row.trade_response_deadline_misses_cumulative);
        field(chunk, row.trade_unresolved_no_attempt);
        field(chunk, row.trade_unresolved_no_spread);
        field(chunk, row.trade_unresolved_margin);
        field(chunk, row.trade_unresolved_route);
        field(chunk, row.trade_unresolved_stock);
        field(chunk, row.trade_unresolved_capacity);
        field(chunk, row.trade_unresolved_cash);
        field(chunk, row.trade_unresolved_order_cap);
        field(chunk, row.merchant_credit_budget);
        field(chunk, row.merchant_credit_committed);
        field(chunk, row.merchant_credit_drawn);
        field(chunk, row.merchant_credit_repaid);
        field(chunk, row.merchant_credit_premium_repaid);
        field(chunk, row.merchant_credit_outstanding);
        field(chunk, row.merchant_credit_bad_debt);
        field(chunk, row.recovery_candidates);
        field(chunk, row.recovery_approved);
        field(chunk, row.recovery_restarted);
        field(chunk, row.recovery_failed);
        field(chunk, row.recovery_liquidated_buildings);
        field(chunk, row.trade_active_keys_pruned);
        field(chunk, row.trade_deficit_episodes_started);
        field(chunk, row.trade_deficit_episodes_resolved);
        field(chunk, row.trade_candidates_stale_generation);
        field(chunk, row.trade_candidates_arbitrated_out);
        field(chunk, row.trade_true_source_stock_failures);
        field(chunk, row.merchant_cash);
        field(chunk, row.merchant_inventory_retail_value);
        field(chunk, row.merchant_inventory_liquidation_value);
        field(chunk, row.merchant_economic_assets);
        field(chunk, row.merchant_procurement_margin_value);
        field(chunk, row.merchant_trade_purchase_cash);
        field(chunk, row.merchant_trade_sale_cash);
        field(chunk, row.merchant_operating_outflow);
        field(chunk, row.merchant_liquidity_coverage_q16);
        field(chunk, row.merchant_effective_buy_factor_q16);
        field(chunk, row.building_investment_buildings_started);
        field(chunk, row.building_investment_portfolios_started);
        field(chunk, row.building_investment_types_started);
        field(chunk, row.building_investment_owner_population_moved);
        field(chunk, row.building_investment_max_type_owner_share_q16);
        field(chunk, row.building_investment_demand_limited);
        field(chunk, row.building_investment_material_limited);
        field(chunk, row.building_investment_capital_limited);
        field(chunk, row.building_investment_owner_population_limited);
        field(chunk, row.recovery_partially_liquidated_buildings);
        field(chunk, row.recovery_fully_liquidated_groups);
        field(chunk, row.merchant_survival_procurement_required);
        field(chunk, row.merchant_survival_procurement_allocated);
        field(chunk, row.merchant_input_procurement_required);
        field(chunk, row.merchant_input_procurement_allocated);
        field(chunk, row.climate_profiled_building_groups);
        field(chunk, row.climate_limited_building_groups);
        field(chunk, row.average_climate_capacity_q16);
        // Keep the legacy recovery_* values above for CSV consumers, while
        // exposing lifecycle terminology that no longer implies trial mode.
        field(chunk, row.recovery_candidates);
        field(chunk, row.recovery_approved);
        field(chunk, row.recovery_restarted);
        field(chunk, row.recovery_failed);
        field(chunk, row.recovery_liquidated_buildings);
        field(chunk, row.recovery_partially_liquidated_buildings);
        field(chunk, row.recovery_fully_liquidated_groups);
        field(chunk, row.building_investment_jobs_started);
        field(chunk, row.building_investment_employment_gap);
        field(chunk, row.building_investment_employment_catchup_cells);
        field(chunk, row.building_investment_displacement_starts);
        field(chunk, row.investment_displacement_type_evaluations);
        field(chunk, row.bullion_quota_initial);
        field(chunk, row.bullion_quota_remaining);
        field(chunk, row.bullion_quota_remainder_units);
        chunk.push_back('\n'); if (!maybe_flush(SUMMARY)) goto write_failed;
    }
    if (!flush(SUMMARY)) goto write_failed;

    if (_config.enabled[COHORTS]) for (const CohortRow &row : batch.cohorts) {
        append_common(chunk, row.c); field(chunk, row.cohort_index); field(chunk, row.handle);
        field(chunk, row.signature_id); field(chunk, row.profession_id); field(chunk, row.ethnicity_id);
        field(chunk, row.population); field(chunk, row.funds); field(chunk, row.epoch_income);
        field(chunk, row.epoch_expense); field(chunk, row.epoch_in_kind_income);
        field(chunk, row.cash_expense_coverage_q16); field(chunk, row.livelihood_coverage_q16);
        field(chunk, row.income_ema); field(chunk, row.satisfaction_q16);
        field(chunk, row.worst_need_id); field(chunk, row.merchant ? 1 : 0);
        field(chunk, row.owner_employed); field(chunk, row.employee_employed); field(chunk, row.unemployed);
        field(chunk, row.epoch_tax_paid); field(chunk, row.epoch_subsidy_received);
         field(chunk, row.cell_births); field(chunk, row.cell_deaths);
         field(chunk, row.cell_moved_in); field(chunk, row.cell_moved_out);
        chunk.push_back('\n'); if (!maybe_flush(COHORTS)) goto write_failed;
    }
    if (!flush(COHORTS)) goto write_failed;

    if (_config.enabled[BUILDINGS]) for (const BuildingRow &row : batch.buildings) {
        append_common(chunk, row.c); field(chunk, row.construction ? 1 : 0); field(chunk, row.group_index);
        field(chunk, row.type_id); field(chunk, row.owner_signature_id); field(chunk, row.count);
        if (row.construction) {
            for (int i = 0; i < 38; ++i) blank_field(chunk);
            append_int(chunk, row.construction_ready_day);
            for (int i = 0; i < 5; ++i) blank_field(chunk);
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
            field(chunk, row.owner_living_cost_per_day);
            field(chunk, row.owner_livelihood_required);
            field(chunk, row.viability_operating_cost);
            field(chunk, row.viability_income_gap);
            field(chunk, row.projected_owner_income_per_day);
            blank_field(chunk);
            field(chunk, row.funded_capacity_q16);
            field(chunk, row.owner_working_capital_allocated);
            field(chunk, row.investment_score_q16);
            field(chunk, row.investment_payback_days);
            field(chunk, row.investment_rejection_reason);
        }
        field(chunk, row.merchant_debt_principal);
        field(chunk, row.merchant_debt_premium);
        field(chunk, row.merchant_debt_term_cycles_left);
        field(chunk, row.merchant_debt_delinquent_cycles);
        field(chunk, row.last_in_kind_livelihood_value);
        field(chunk, row.recovery_failed_reviews);
        field(chunk, row.investment_candidate ? 1 : 0);
        field(chunk, row.investment_shortage_q16);
        field(chunk, row.investment_utilization_q16);
        field(chunk, row.investment_required_capital);
        field(chunk, row.investment_projected_profit_per_day);
        field(chunk, row.investment_driver_good_id);
        field(chunk, row.investment_driver_pressure_q16);
        field(chunk, row.investment_driver_utilization_q16);
        field(chunk, row.investment_driver_sellable);
        field(chunk, row.investment_driver_merchant_sold);
        field(chunk, row.investment_driver_sell_through_q16);
        field(chunk, row.investment_driver_discard_q16);
        field(chunk, row.last_temperature_fit_q16);
        field(chunk, row.last_water_fit_q16);
        field(chunk, row.last_climate_capacity_q16);
        field(chunk, row.last_climate_lost_output);
        field(chunk, 0);
        field(chunk, row.recovery_failed_reviews);
        field(chunk, row.investment_failed_material_group);
        text_field(chunk, row.investment_selected_material_good_ids);
        text_field(chunk, row.investment_selected_material_quantities);
        field(chunk, row.investment_stealable);
        field(chunk, row.investment_challenger_unit_cost);
        field(chunk, row.investment_incumbent_unit_cost);
        field(chunk, row.investment_return_on_capital_q16);
        field(chunk, row.investment_cost_advantage_q16);
        field(chunk, row.investment_monetary_quota_initial);
        field(chunk, row.investment_monetary_quota_daily);
        field(chunk, row.investment_monetary_units);
        field(chunk, row.investment_monetary_candidate_slots);
        field(chunk, row.investment_monetary_request_money_per_day);
        field(chunk, row.investment_monetary_expected_revenue_per_day);
        field(chunk, row.opportunity_owner_income_per_day);
        field(chunk, row.opportunity_disposable_survival_power_per_day);
        field(chunk, row.opportunity_executable_capacity_q16);
        field(chunk, row.opportunity_in_kind_retail_value);
        field(chunk, row.survival_priority ? 1 : 0);
        field(chunk, row.survival_shortage_q16);
        field(chunk, row.monetary_quota_absorption_q16);
        field(chunk, row.monetary_quote_capped ? 1 : 0);
        field(chunk, row.employment_candidate ? 1 : 0);
        field(chunk, row.employment_diagnostic_day);
        field(chunk, row.employment_role);
        field(chunk, row.employment_target_signature);
        field(chunk, row.employment_profession_id);
        field(chunk, row.employment_source_ethnicity);
        field(chunk, row.employment_pool_slot);
        field(chunk, row.employment_pool_signature);
        field(chunk, row.employment_pool_population);
        field(chunk, row.employment_vacancy);
        field(chunk, row.employment_target_disposable);
        field(chunk, row.employment_source_disposable);
        field(chunk, row.employment_improvement_q16);
        field(chunk, row.employment_hurdle_q16);
        field(chunk, row.employment_weight_q16);
        field(chunk, row.employment_budget);
        field(chunk, row.employment_allocation);
        field(chunk, row.employment_take);
        field(chunk, row.employment_eligible ? 1 : 0);
        field(chunk, row.employment_rejection_reason);
        field(chunk, row.employment_group);
        field(chunk, row.employment_owner_target);
        field(chunk, row.employment_filled_before_clamp);
        field(chunk, row.employment_filled_after_profession_clamp);
        field(chunk, row.employment_filled_after_family_clamp);
        field(chunk, row.employment_family_owned);
        field(chunk, row.employment_family_member_people);
        field(chunk, row.employment_anonymous_people);
        field(chunk, row.employment_owner_cohort_population);
        field(chunk, row.employment_shed_surplus);
        chunk.push_back('\n'); if (!maybe_flush(BUILDINGS)) goto write_failed;
    }
    if (!flush(BUILDINGS)) goto write_failed;

    if (_config.enabled[RESOURCES]) for (const ResourceRow &row : batch.resources) {
        append_common(chunk, row.c); text_field(chunk, _config.resource_ids[row.resource_index]);
        chunk.push_back(','); append_float(chunk, row.opening_reserve);
        chunk.push_back(','); append_float(chunk, row.natural_net_change);
        chunk.push_back(','); append_float(chunk, row.natural_positive_change);
        chunk.push_back(','); append_float(chunk, row.natural_negative_change);
        chunk.push_back(','); append_float(chunk, row.artificial_change_applied);
        chunk.push_back(','); append_float(chunk, row.artificial_change_pending);
        chunk.push_back(','); append_float(chunk, row.artificial_generation_applied);
        chunk.push_back(','); append_float(chunk, row.artificial_extraction_applied);
        chunk.push_back(','); append_float(chunk, row.artificial_generation_pending);
        chunk.push_back(','); append_float(chunk, row.artificial_extraction_pending);
        chunk.push_back(','); append_float(chunk, row.reserve);
        field(chunk, row.stock_density_q16);
        field(chunk, row.managed_harvest_enabled);
        field(chunk, row.safe_yield); field(chunk, row.projected_life_days);
        chunk.push_back('\n');
        if (!maybe_flush(RESOURCES)) goto write_failed;
    }
    if (!flush(RESOURCES)) goto write_failed;

    if (_config.enabled[MARKET]) for (const MarketRow &row : batch.market) {
        append_common(chunk, row.c); text_field(chunk, _good_ids[row.good_index]);
        field(chunk, row.stock); field(chunk, row.price); field(chunk, row.demand_ema);
        field(chunk, row.business_demand_ema); field(chunk, row.offered_supply_ema);
        field(chunk, row.realized_withdrawal_ema); field(chunk, row.production_input_reserve);
        field(chunk, row.construction_material_reserve);
        field(chunk, row.household_available_stock); field(chunk, row.merchant_inventory_target);
        field(chunk, row.merchant_procurement_shortfall);
        field(chunk, row.cost_anchor_price); field(chunk, row.shortage_q16);
        field(chunk, row.price_pressure_total_q16);
        text_field(chunk, _good_category_ids[row.category_index]); field(chunk, row.storage_mode);
        field(chunk, row.trade_enabled ? 1 : 0); field(chunk, row.trade_import_ema);
        field(chunk, row.trade_export_ema); field(chunk, row.trade_inbound); field(chunk, row.trade_outbound);
        field(chunk, row.desired_business_demand); field(chunk, row.funded_business_demand);
        field(chunk, row.unfunded_business_demand); field(chunk, row.trade_export_safety_stock);
        field(chunk, row.trade_import_fill_target); field(chunk, row.trade_relief_pressure_q16);
        field(chunk, row.trade_signal_age_days);
        field(chunk, row.trade_first_dispatch_delay_days);
        field(chunk, row.trade_last_attempt_day);
        field(chunk, row.trade_last_rejection_reason);
        field(chunk, row.trade_deadline_exceeded ? 1 : 0);
        field(chunk, row.merchant_cash);
        field(chunk, row.merchant_inventory_retail_value);
        field(chunk, row.merchant_inventory_liquidation_value);
        field(chunk, row.merchant_economic_assets);
        field(chunk, row.merchant_procurement_margin_value);
        field(chunk, row.merchant_trade_purchase_cash);
        field(chunk, row.merchant_trade_sale_cash);
        field(chunk, row.merchant_operating_outflow);
        field(chunk, row.merchant_liquidity_coverage_q16);
        field(chunk, row.merchant_effective_buy_factor_q16);
        field(chunk, row.derived_business_demand);
        field(chunk, row.shadow_anchor_price);
        field(chunk, row.price_pressure_derived_q16);
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
    // 成功分支的尾部必须自成作用域：total_us 带初始化，而它若与 write_failed
    // 同处一个作用域，上面每一条 goto 都算「跳过带初始化的声明」——MSVC 放行，
    // clang（web/wasm 走 emcc）按标准直接报错。
    {
        const int64_t total_us = std::chrono::duration_cast<std::chrono::microseconds>(
            Clock::now() - encode_start).count();
        _write_us_last = local_write_us;
        _encode_us_last = std::max<int64_t>(0, total_us - local_write_us);
        bytes = local_bytes;
        return true;
    }

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
                _cv.notify_all();
                break;
            }
        }
        _cv.notify_all();
    }
    close_files();
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _worker_finished = true; _worker_busy = false;
        if (_state != 5) _state = _error_code.empty() ? 4 : 5;
    }
    _cv.notify_all();
}

void EconomyCsvRecorder::request_stop() {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_state != 1 && _state != 2 && _state != 3) return;
        _accepting = false; _stop_requested = true;
        if (_state != 5) _state = 3;
    }
    _cv.notify_all();
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
    out["backpressure_wait_count"] = _backpressure_wait_count;
    out["backpressure_wait_ms_total"] =
        static_cast<double>(_backpressure_wait_us) / 1000.0;
    out["worker_encode_ms_last"] = static_cast<double>(_encode_us_last) / 1000.0;
    out["worker_write_ms_last"] = static_cast<double>(_write_us_last) / 1000.0;
    out["max_rows"] = _config.max_rows;
    out["sampled_cell_count"] = static_cast<int64_t>(_source->sample_cells().size());
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

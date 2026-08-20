#include "economy_runtime.h"
#include "country_runtime.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <chrono>
#include <limits>
#include <numeric>
#include <vector>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

void NativeEconomyRuntime::reset_publish_state() {
    _publish_phase = PublishPhase::PREPARE;
    _publish_cursor = 0;
    _publish_order_cursor = 0;
    _publish_line_cursor = 0;
    _publish_valuation_sat = 0;
    _publish_trade_alpha = 0;
    _publish_have_populated = false;
    _trade_plan_init.clear();
    _publish_phase_ms.fill(0.0);
    _publish_phase_work.fill(0);
    _publish_slice_phase_ms.fill(0.0);
    _publish_slice_phase_work.fill(0);
}

bool NativeEconomyRuntime::publish_epoch_slice(
        int64_t &work_done, std::string &error) {
    const auto started = Clock::now();
    const PublishPhase executed_phase = _publish_phase;
    const int64_t work_before = work_done;
    _executed_substage = publish_phase_name(executed_phase);
    const size_t budget = static_cast<size_t>(PUBLISH_ENTRIES_PER_SLICE);
    const size_t audit_budget = static_cast<size_t>(
        PUBLISH_AUDIT_ENTRIES_PER_SLICE);

    if (_publish_phase == PublishPhase::PREPARE) {
        if (_publish_cursor == 0) {
            std::sort(_structural_touched_cells.begin(), _structural_touched_cells.end());
            _structural_touched_cells.erase(
                std::unique(_structural_touched_cells.begin(),
                            _structural_touched_cells.end()),
                _structural_touched_cells.end());
        }
        const size_t start = _publish_cursor;
        const size_t end = std::min(
            _structural_touched_cells.size(), start + budget);
        for (; _publish_cursor < end; ++_publish_cursor) {
            const int32_t cell = _structural_touched_cells[_publish_cursor];
            if (cell < 0 || cell >= _cell_count) continue;
            const CellSummary summary = build_cell_summary(cell);
            stage_cell_summary(cell, summary);
            if (summary.population != 0) continue;
            const int32_t market = _market.cell_to_market[cell];
            for (int32_t good = 0; good < _market.good_count; ++good) {
                if (_market.stock[_market.index(market, good)] > 0) {
                    error = "empty_cell_cannot_retain_owned_stock";
                    return false;
                }
            }
        }
        work_done += static_cast<int64_t>(end - start);
        if (_publish_cursor >= _structural_touched_cells.size()) {
            _incremental_closing_totals =
                _closing_audit_mode != 0 &&
                        !_closing_audit_runtime_disabled
                    ? incremental_audit_totals()
                    : AuditTotals{};
            const bool periodic_full =
                _full_audit_verify_interval_days > 0 &&
                _current_day % _full_audit_verify_interval_days == 0;
            const bool full_required = _closing_audit_mode != 2 ||
                _closing_audit_runtime_disabled ||
                _closing_audit_force_full || periodic_full;
            _closing_audit_incremental_this_epoch = !full_required;
            if (full_required) {
                ++_closing_audit_full_verifications;
                _closing_totals = {};
            } else {
                ++_closing_audit_fast_paths;
                _closing_totals = _incremental_closing_totals;
            }
            _publish_valuation_sat = 0;
            _publish_cursor = 0;
            _publish_phase = full_required
                ? PublishPhase::AUDIT_POPULATION : PublishPhase::VERIFY;
        }
    } else if (_publish_phase == PublishPhase::AUDIT_POPULATION) {
        const size_t start = _publish_cursor;
        const size_t end = std::min(_population.active.size(), start + audit_budget);
        for (; _publish_cursor < end; ++_publish_cursor) {
            if (_population.active[_publish_cursor] == 0) continue;
            _closing_totals.population += _population.population[_publish_cursor];
            _closing_totals.cohort_funds += _population.funds[_publish_cursor];
            if (is_merchant_slot(static_cast<int32_t>(_publish_cursor))) {
                _closing_totals.merchant_cash = saturating_add(
                    _closing_totals.merchant_cash,
                    std::max<int64_t>(0, _population.funds[_publish_cursor]),
                    _publish_valuation_sat);
            }
        }
        _closing_audit_population_full_scan_entries +=
            static_cast<int64_t>(end - start);
        work_done += static_cast<int64_t>(end - start);
        if (_publish_cursor >= _population.active.size()) {
            _closing_totals.country_cash =
                _country_runtime == nullptr ? 0 : _country_runtime->total_cash();
            int64_t expedition_population = 0;
            for (int32_t expedition = 0; expedition < static_cast<int32_t>(
                    _family_expeditions.active.size()); ++expedition) {
                if (_family_expeditions.active[expedition] == 0) continue;
                expedition_population += _family_expeditions.population[expedition];
            }
            _closing_totals.transit_population = expedition_population;
            _closing_totals.population += expedition_population;
            _publish_cursor = 0;
            _publish_phase = PublishPhase::AUDIT_MARKET;
        }
    } else if (_publish_phase == PublishPhase::AUDIT_MARKET) {
        const size_t total = static_cast<size_t>(_market.market_count) *
                             static_cast<size_t>(_market.good_count);
        const size_t start = _publish_cursor;
        const size_t end = std::min(total, start + audit_budget);
        const int32_t entry_count = static_cast<int32_t>(end - start);
        _closing_audit_market_full_scan_entries += entry_count;
        const int32_t audit_tasks = _worker_enabled &&
                entry_count >= 32768 &&
                godot::WorkerThreadPool::get_singleton() != nullptr
            ? std::min<int32_t>(_worker_task_cap, _worker_tasks_hint > 0
                ? _worker_tasks_hint
                : std::max<int32_t>(2, (entry_count + 32767) / 32768))
            : 1;
        _audit_worker_tasks_max = std::max(
            _audit_worker_tasks_max, audit_tasks);
        ++_audit_worker_dispatches;
        if (audit_tasks > 1) {
            _audit_task_totals_scratch.assign(
                static_cast<size_t>(audit_tasks), {});
            _audit_task_saturation_scratch.assign(
                static_cast<size_t>(audit_tasks), 0);
            _audit_task_ms_scratch.assign(
                static_cast<size_t>(audit_tasks), 0.0);
            auto audit_task_range = [&](int32_t task_begin, int32_t task_end) {
                for (int32_t task = task_begin; task < task_end; ++task) {
                    const auto task_started = Clock::now();
                    AuditTotals &local = _audit_task_totals_scratch[task];
                    int64_t &local_sat =
                        _audit_task_saturation_scratch[task];
                    const int32_t relative_begin =
                        entry_count * task / audit_tasks;
                    const int32_t relative_end =
                        entry_count * (task + 1) / audit_tasks;
                    for (int32_t relative = relative_begin;
                         relative < relative_end; ++relative) {
                        const size_t index =
                            start + static_cast<size_t>(relative);
                        const int32_t good = static_cast<int32_t>(
                            index % static_cast<size_t>(_market.good_count));
                        local.goods_stock += _market.stock[index];
                        const int64_t retail_value = mul_div_sat(
                            std::max<int64_t>(0, _market.stock[index]),
                            std::max<int64_t>(0, _market.price[index]),
                            GOODS_SCALE, local_sat);
                        local.merchant_inventory_retail_value = saturating_add(
                            local.merchant_inventory_retail_value,
                            retail_value, local_sat);
                        local.merchant_inventory_liquidation_value =
                            saturating_add(
                                local.merchant_inventory_liquidation_value,
                                mul_div_sat(retail_value,
                                    std::clamp<int64_t>(
                                        _good_merchant_buy_factor_q16[good],
                                        0, Q16_ONE),
                                    Q16_ONE, local_sat),
                                local_sat);
                    }
                    _audit_task_ms_scratch[task] =
                        elapsed_ms(task_started);
                }
            };
            parallel_for_range("pk_economy_audit_market", audit_tasks,
                               audit_tasks, 1, audit_task_range);
            for (int32_t task = 0; task < audit_tasks; ++task) {
                const AuditTotals &local =
                    _audit_task_totals_scratch[task];
                _closing_totals.goods_stock += local.goods_stock;
                _closing_totals.merchant_inventory_retail_value =
                    saturating_add(
                        _closing_totals.merchant_inventory_retail_value,
                        local.merchant_inventory_retail_value,
                        _publish_valuation_sat);
                _closing_totals.merchant_inventory_liquidation_value =
                    saturating_add(
                        _closing_totals.merchant_inventory_liquidation_value,
                        local.merchant_inventory_liquidation_value,
                        _publish_valuation_sat);
                _publish_valuation_sat +=
                    _audit_task_saturation_scratch[task];
            }
            _audit_worker_cpu_ms += std::accumulate(
                _audit_task_ms_scratch.begin(),
                _audit_task_ms_scratch.end(), 0.0);
        } else {
            for (size_t index = start; index < end; ++index) {
                const int32_t good = static_cast<int32_t>(
                    index % static_cast<size_t>(_market.good_count));
                _closing_totals.goods_stock += _market.stock[index];
                const int64_t retail_value = mul_div_sat(
                    std::max<int64_t>(0, _market.stock[index]),
                    std::max<int64_t>(0, _market.price[index]),
                    GOODS_SCALE, _publish_valuation_sat);
                _closing_totals.merchant_inventory_retail_value =
                    saturating_add(
                        _closing_totals.merchant_inventory_retail_value,
                        retail_value, _publish_valuation_sat);
                _closing_totals.merchant_inventory_liquidation_value =
                    saturating_add(
                        _closing_totals.merchant_inventory_liquidation_value,
                        mul_div_sat(retail_value, std::clamp<int64_t>(
                            _good_merchant_buy_factor_q16[good], 0, Q16_ONE),
                            Q16_ONE, _publish_valuation_sat),
                        _publish_valuation_sat);
            }
        }
        _publish_cursor = end;
        work_done += static_cast<int64_t>(end - start);
        if (_publish_cursor >= total) {
            _publish_order_cursor = 0;
            _publish_line_cursor = _trade_orders.line_offsets.empty()
                ? 0 : _trade_orders.line_offsets[0];
            _publish_phase = PublishPhase::AUDIT_TRANSIT;
        }
    } else if (_publish_phase == PublishPhase::AUDIT_TRANSIT) {
        size_t processed = 0;
        while (_publish_order_cursor < _trade_orders.size() &&
               processed < audit_budget) {
            const int32_t order = _publish_order_cursor;
            if (_publish_line_cursor >= _trade_orders.line_offsets[order + 1]) {
                ++_publish_order_cursor;
                if (_publish_order_cursor < _trade_orders.size())
                    _publish_line_cursor = _trade_orders.line_offsets[_publish_order_cursor];
                continue;
            }
            const int32_t line = _publish_line_cursor++;
            if (_trade_orders.cargo_delivered[order] == 0) {
                _closing_totals.transit_goods = saturating_add(
                    _closing_totals.transit_goods,
                    _trade_orders.line_quantities[line], _publish_valuation_sat);
            }
            ++processed;
        }
        work_done += static_cast<int64_t>(processed);
        if (_publish_order_cursor >= _trade_orders.size()) {
            _closing_totals.goods_stock += _closing_totals.transit_goods;
            _publish_cursor = 0;
            _publish_phase = PublishPhase::AUDIT_ESCROW;
        }
    } else if (_publish_phase == PublishPhase::AUDIT_ESCROW) {
        const size_t start = _publish_cursor;
        const size_t end = std::min(
            _trade_orders.cash_escrow.size(), start + audit_budget);
        for (; _publish_cursor < end; ++_publish_cursor) {
            _closing_totals.escrow_cash = saturating_add(
                _closing_totals.escrow_cash,
                _trade_orders.cash_escrow[_publish_cursor], _publish_valuation_sat);
        }
        work_done += static_cast<int64_t>(end - start);
        if (_publish_cursor >= _trade_orders.cash_escrow.size()) {
            int64_t expedition_population = 0;
            int64_t expedition_funds = 0;
            sum_family_expedition_holdings(expedition_population,
                                           expedition_funds,
                                           _closing_totals.expedition_goods,
                                           _publish_valuation_sat);
            _closing_totals.expedition_funds = expedition_funds;
            _closing_totals.goods_stock = saturating_add(
                _closing_totals.goods_stock, _closing_totals.expedition_goods,
                _publish_valuation_sat);
            _closing_totals.escrow_cash = saturating_add(
                _closing_totals.escrow_cash, expedition_funds,
                _publish_valuation_sat);
            _closing_totals.escrow_cash = saturating_add(
                _closing_totals.escrow_cash, fiscal_escrow_total(),
                _publish_valuation_sat);
            _publish_cursor = 0;
            _publish_phase = PublishPhase::AUDIT_COUNTRY;
        }
    } else if (_publish_phase == PublishPhase::AUDIT_COUNTRY) {
        const size_t start = _publish_cursor;
        const size_t end = std::min(
            static_cast<size_t>(_market.good_count), start + audit_budget);
        if (_country_runtime != nullptr) {
            for (; _publish_cursor < end; ++_publish_cursor) {
                const int64_t country_good =
                    _country_runtime->total_good(
                        static_cast<int32_t>(_publish_cursor));
                _closing_totals.country_goods += country_good;
                _closing_totals.goods_stock += country_good;
            }
        } else {
            _publish_cursor = end;
        }
        work_done += static_cast<int64_t>(end - start);
        if (_publish_cursor >= static_cast<size_t>(_market.good_count))
            _publish_phase = PublishPhase::VERIFY;
    } else if (_publish_phase == PublishPhase::VERIFY) {
        refresh_country_research_goods_consumed();
        const int64_t population_expected = _opening_totals.population +
            _births - _deaths + _external_population_delta;
        const int64_t money_open = _opening_totals.cohort_funds +
            _opening_totals.country_cash + _opening_totals.escrow_cash;
        const int64_t money_close = _closing_totals.cohort_funds +
            _closing_totals.country_cash + _closing_totals.escrow_cash;
        const int64_t money_expected = money_open + _explicit_money_mint -
            _explicit_money_burn;
        const int64_t goods_expected = _opening_totals.goods_stock +
            _explicit_stock_delta + _production_output_stock +
            _production_output_discarded + _production_output_retained -
            _consumed_goods -
            _owner_output_consumed - _construction_goods_consumed -
            _production_inputs_consumed - _production_output_discarded -
            _cycle_flow_discarded - _bullion_stock_consumed -
            _country_research_goods_consumed;
        if (!_closing_audit_incremental_this_epoch &&
            _closing_audit_mode != 0) {
            const int64_t incremental_money =
                _incremental_closing_totals.cohort_funds +
                _incremental_closing_totals.country_cash +
                _incremental_closing_totals.escrow_cash;
            const int64_t full_money = _closing_totals.cohort_funds +
                _closing_totals.country_cash +
                _closing_totals.escrow_cash;
            const bool mismatch =
                _incremental_closing_totals.population !=
                    _closing_totals.population ||
                incremental_money != full_money ||
                _incremental_closing_totals.goods_stock !=
                    _closing_totals.goods_stock;
            if (mismatch) {
                ++_closing_audit_mismatches;
                diagnose_incremental_audit_mismatch(_closing_totals);
                _closing_audit_runtime_disabled = true;
                if (_closing_audit_mode == 2) {
                    error = "incremental_closing_audit_mismatch";
                    return false;
                }
            }
        }
        if (_closing_totals.population != population_expected)
            error = "population_conservation_failed";
        else if (money_close != money_expected)
            error = "money_conservation_failed";
        else if (_closing_totals.goods_stock != goods_expected)
            error = "goods_conservation_failed";
        if (!error.empty()) return false;
        _closing_audit_force_full = false;
        _settlement_watermark = _sample_day;
        _settlement_newest_day = _sample_day;
        _publish_have_populated = false;
        _publish_cursor = 0;
        _publish_phase = PublishPhase::WATERMARK;
        ++work_done;
    } else if (_publish_phase == PublishPhase::WATERMARK) {
        const size_t start = _publish_cursor;
        const size_t end = std::min(static_cast<size_t>(_cell_count), start + budget);
        for (; _publish_cursor < end; ++_publish_cursor) {
            if (_staging_cells[_publish_cursor].population <= 0) continue;
            const int64_t settlement_day =
                cell_in_market_workset(static_cast<int32_t>(_publish_cursor),
                                       _sample_day)
                ? _sample_day : _cell_last_settlement_day[_publish_cursor];
            if (!_publish_have_populated) {
                _settlement_watermark = settlement_day;
                _settlement_newest_day = settlement_day;
                _publish_have_populated = true;
            } else {
                _settlement_watermark = std::min(_settlement_watermark, settlement_day);
                _settlement_newest_day = std::max(_settlement_newest_day, settlement_day);
            }
        }
        work_done += static_cast<int64_t>(end - start);
        if (_publish_cursor >= static_cast<size_t>(_cell_count)) {
            _settlement_max_age_days = _publish_have_populated
                ? std::max<int64_t>(0, _sample_day - _settlement_watermark) : 0;
            _publish_cursor = 0;
            _publish_valuation_sat = 0;
            _publish_trade_alpha = std::min<int64_t>(Q16_ONE, saturating_mul(
                _trade_flow_ema_alpha_q16, std::max(1, _epoch_days),
                _publish_valuation_sat));
            _publish_phase = PublishPhase::TRADE_FLOW;
        }
    } else if (_publish_phase == PublishPhase::TRADE_FLOW) {
        const size_t start = _publish_cursor;
        const size_t end = std::min(_trade_flows.cells.size(), start + budget);
        for (; _publish_cursor < end; ++_publish_cursor) {
            const int64_t observed_import = _trade_flows.period_import[_publish_cursor] /
                std::max(1, _epoch_days);
            const int64_t observed_export = _trade_flows.period_export[_publish_cursor] /
                std::max(1, _epoch_days);
            _trade_flows.import_ema[_publish_cursor] = saturating_add(
                _trade_flows.import_ema[_publish_cursor], mul_div_sat(
                    observed_import - _trade_flows.import_ema[_publish_cursor],
                    _publish_trade_alpha, Q16_ONE, _publish_valuation_sat),
                _publish_valuation_sat);
            _trade_flows.export_ema[_publish_cursor] = saturating_add(
                _trade_flows.export_ema[_publish_cursor], mul_div_sat(
                    observed_export - _trade_flows.export_ema[_publish_cursor],
                    _publish_trade_alpha, Q16_ONE, _publish_valuation_sat),
                _publish_valuation_sat);
            _trade_flows.period_import[_publish_cursor] = 0;
            _trade_flows.period_export[_publish_cursor] = 0;
        }
        work_done += static_cast<int64_t>(end - start);
        if (_publish_cursor >= _trade_flows.cells.size()) {
            _saturation_count = saturating_add(
                _saturation_count, _publish_valuation_sat, _saturation_count);
            _trade_signal_max_age_days = 0;
            _trade_response_deadline_misses = 0;
            _trade_unresolved_no_attempt = 0;
            _trade_unresolved_no_spread = 0;
            _trade_unresolved_margin = 0;
            _trade_unresolved_route = 0;
            _trade_unresolved_stock = 0;
            _trade_unresolved_capacity = 0;
            _trade_unresolved_cash = 0;
            _trade_unresolved_order_cap = 0;
            _publish_cursor = 0;
            _publish_phase = PublishPhase::TRADE_DIAGNOSTICS;
        }
    } else if (_publish_phase == PublishPhase::TRADE_DIAGNOSTICS) {
        const size_t count = std::min({
            _trade_signal_first_seen_day.size(),
            _trade_signal_first_dispatch_day.size(),
            _trade_signal_deadline_reported.size(),
        });
        const size_t start = _publish_cursor;
        const size_t end = std::min(count, start + audit_budget);
        for (; _publish_cursor < end; ++_publish_cursor) {
            const int64_t first_seen = _trade_signal_first_seen_day[_publish_cursor];
            if (first_seen < 0) continue;
            const int64_t age = std::max<int64_t>(0, _sample_day - first_seen);
            _trade_signal_max_age_days = std::max(_trade_signal_max_age_days, age);
            if (_trade_signal_first_dispatch_day[_publish_cursor] >= 0 ||
                age <= _trade_response_days) continue;
            ++_trade_response_deadline_misses;
            switch (_trade_signal_last_rejection_reason[_publish_cursor]) {
                case TRADE_SIGNAL_DIAG_NO_SPREAD: ++_trade_unresolved_no_spread; break;
                case TRADE_SIGNAL_DIAG_MARGIN: ++_trade_unresolved_margin; break;
                case TRADE_SIGNAL_DIAG_ROUTE: ++_trade_unresolved_route; break;
                case TRADE_SIGNAL_DIAG_STOCK: ++_trade_unresolved_stock; break;
                case TRADE_SIGNAL_DIAG_CAPACITY: ++_trade_unresolved_capacity; break;
                case TRADE_SIGNAL_DIAG_CASH: ++_trade_unresolved_cash; break;
                case TRADE_SIGNAL_DIAG_ORDER_CAP: ++_trade_unresolved_order_cap; break;
                default: ++_trade_unresolved_no_attempt; break;
            }
            if (_trade_signal_deadline_reported[_publish_cursor] == 0) {
                _trade_signal_deadline_reported[_publish_cursor] = 1;
                ++_trade_response_deadline_misses_cumulative;
            }
        }
        work_done += static_cast<int64_t>(end - start);
        if (_publish_cursor >= count) {
            _trade_plan_init.clear();
            _publish_phase = PublishPhase::TRADE_INIT;
        }
    } else if (_publish_phase == PublishPhase::TRADE_INIT) {
        const TradePlanInitPhase init_executed =
            _trade_plan_init.phase == TradePlanInitPhase::IDLE
            ? TradePlanInitPhase::COMPONENT_PREPARE : _trade_plan_init.phase;
        _executed_substage = std::string("trade_init.") +
            trade_plan_init_phase_name(init_executed);
        const bool init_in_progress =
            _trade_plan_init.phase != TradePlanInitPhase::IDLE &&
            _trade_plan_init.phase != TradePlanInitPhase::DONE;
        const bool needs_plan = init_in_progress ||
            (_trade_runtime_mode != 0 && _trade_topology.ready &&
            (_trade_plan.phase == TradePlanStore::IDLE ||
             _trade_plan.country_topology_hash != _epoch_country_topology_hash ||
             _trade_plan.topology_generation != _trade_topology.topology_generation));
        if (!needs_plan) {
            _publish_phase = PublishPhase::COMMIT;
        } else {
            if (!begin_trade_plan_slice(work_done, error)) return false;
            if (_trade_plan_init.phase == TradePlanInitPhase::DONE)
                _publish_phase = PublishPhase::COMMIT;
        }
    } else if (_publish_phase == PublishPhase::COMMIT) {
        _committed_cells.swap(_staging_cells);
        commit_incremental_audit_shadow();
        update_settlements_for_changed_cells();
        for (const int32_t cell : _epoch_settlement_cells) {
            if (cell < 0 || cell >= _cell_count) continue;
            _cell_last_settlement_day[cell] = _sample_day;
            ++_cell_settlement_generation[cell];
            ++_cell_price_stock_gen[cell];
            ++_cell_owner_cash_gen[cell];
            ++_cell_population_gen[cell];
            ++_cell_resource_gen[cell];
            if (cell < static_cast<int32_t>(_market.cell_to_market.size()) &&
                cell < static_cast<int32_t>(_cell_effect_shortage_q16.size())) {
                const int32_t market = _market.cell_to_market[cell];
                int32_t shortage_q16 = 0;
                int32_t essentials_q16 = 0;
                if (market >= 0 && market < _market.market_count) {
                    for (int32_t good = 0; good < _market.good_count; ++good) {
                        const int64_t lane = _market.index(market, good);
                        if (lane < 0 || lane >= static_cast<int64_t>(
                                _market.last_shortage_q16.size())) continue;
                        const int32_t lane_shortage = _market.last_shortage_q16[
                            static_cast<size_t>(lane)];
                        shortage_q16 = std::max(shortage_q16, lane_shortage);
                        if (good < static_cast<int32_t>(_good_is_essential.size()) &&
                            _good_is_essential[static_cast<size_t>(good)] != 0)
                            essentials_q16 = std::max(essentials_q16, lane_shortage);
                    }
                }
                _cell_effect_shortage_q16[static_cast<size_t>(cell)] =
                    std::clamp<int32_t>(shortage_q16, 0,
                        static_cast<int32_t>(Q16_ONE));
                if (cell < static_cast<int32_t>(_cell_essentials_shortage_q16.size()))
                    _cell_essentials_shortage_q16[static_cast<size_t>(cell)] =
                        std::clamp<int32_t>(essentials_q16, 0,
                            static_cast<int32_t>(Q16_ONE));
            }
            if (cell < static_cast<int32_t>(_cell_resource_abundance_q16.size()) &&
                _cell_count > 0 && !_resource_snapshot.empty()) {
                int64_t total = 0;
                int32_t counted = 0;
                int64_t sat = 0;
                const int32_t resource_count = static_cast<int32_t>(
                    _resource_ids.size());
                for (int32_t resource = 0; resource < resource_count; ++resource) {
                    const size_t idx = static_cast<size_t>(resource) *
                        static_cast<size_t>(_cell_count) + static_cast<size_t>(cell);
                    if (idx >= _resource_snapshot.size() ||
                        _resource_snapshot[idx] <= 0) continue;
                    const int64_t remaining = idx < _resource_remaining.size()
                        ? std::max<int64_t>(0, _resource_remaining[idx])
                        : _resource_snapshot[idx];
                    total = saturating_add(total, mul_div_sat(remaining, Q16_ONE,
                        _resource_snapshot[idx], sat), sat);
                    ++counted;
                }
                _cell_resource_abundance_q16[static_cast<size_t>(cell)] =
                    counted > 0 ? static_cast<int32_t>(std::clamp<int64_t>(
                        total / counted, 0, Q16_ONE)) : Q16_ONE;
            }
            constexpr uint64_t AGGREGATE_EFFECT_METRICS =
                (1ULL << 7U) | (1ULL << 8U) | (1ULL << 9U) |
                (1ULL << 11U) | (1ULL << 14U);
            refresh_family_effect_metrics_for_cell(cell,
                family_effect_metric_revision(2), AGGREGATE_EFFECT_METRICS);
        }
        publish_social_pressure_facts();
        publish_technology_practice_facts();
        publish_country_development_facts();
        _rolling_processed_cells = static_cast<int32_t>(_epoch_settlement_cells.size());
        _rolling_deferred_cells = std::max(
            0, _rolling_due_cells - _rolling_processed_cells);
        _last_committed_day = _sample_day;
        _commit_day = _current_day;
        _resource_deltas_ready = std::any_of(
            _resource_touched_lanes.begin(), _resource_touched_lanes.end(),
            [&](size_t index) {
                return index < _resource_deltas.size() &&
                    _resource_deltas[index] != 0;
            });
        _epoch_commands.clear();
        _structural_commands.clear();
        _epoch_market_ids.clear();
        _epoch_settlement_cells.clear();
        _epoch_building_cells.clear();
        _epoch_plan_cells.clear();
        trace_commit_epoch(0, 0, 0);
        _epoch_active = false;
        _stage = _trade_plan.phase == TradePlanStore::IDLE
            ? Stage::AGGREGATE_PUBLISH : Stage::TRADE_PLANNING;
        _publish_phase = PublishPhase::DONE;
        ++work_done;
    }

    const double slice_ms = elapsed_ms(started);
    const size_t phase_index = static_cast<size_t>(executed_phase);
    _publish_phase_ms[phase_index] += slice_ms;
    _publish_phase_work[phase_index] += work_done - work_before;
    _publish_slice_phase_ms[phase_index] = slice_ms;
    _publish_slice_phase_work[phase_index] = work_done - work_before;
    _publish_ms += slice_ms;
    if (executed_phase >= PublishPhase::AUDIT_POPULATION &&
        executed_phase <= PublishPhase::VERIFY)
        _audit_ms += slice_ms;
    if (executed_phase == PublishPhase::WATERMARK)
        _watermark_ms += slice_ms;
    if (executed_phase == PublishPhase::COMMIT && !_epoch_active && !_fatal) {
        capture_completed_perf_snapshot();
        note_completed_epoch_cadence_ms();
    }
    return true;
}

} // namespace pk

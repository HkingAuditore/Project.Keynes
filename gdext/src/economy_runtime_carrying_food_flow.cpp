#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "parallel_dispatcher.h"
#include "runtime_switch_registry.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace pk {

void NativeEconomyRuntime::accumulate_trade_food_flow(
        int32_t cell, int32_t good, int64_t import_qty,
        int64_t export_qty, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count.get() || good < 0 ||
        good >= static_cast<int32_t>(_good_food_equivalent_q16.size())) return;
    const int64_t coefficient = _good_food_equivalent_q16[
        static_cast<size_t>(good)];
    if (coefficient <= 0) return;
    ++_food_trade_events;
    const size_t lane = static_cast<size_t>(cell);
    if (lane >= _cell_food_import_eq_period.size()) return;
    _cell_food_import_eq_period[lane] = saturating_add(
        _cell_food_import_eq_period[lane],
        mul_div_sat(std::max<int64_t>(0, import_qty), coefficient, Q16_ONE, sat), sat);
    _cell_food_export_eq_period[lane] = saturating_add(
        _cell_food_export_eq_period[lane],
        mul_div_sat(std::max<int64_t>(0, export_qty), coefficient, Q16_ONE, sat), sat);
}

void NativeEconomyRuntime::commit_food_flow_snapshot() {
    EconomyCostProbe probe("food_capacity.commit", _current_day.get());
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
    if (_cell_food_output_eq_period.size() != cells ||
        _cell_food_input_eq_period.size() != cells ||
        _cell_food_import_eq_period.size() != cells ||
        _cell_food_export_eq_period.size() != cells ||
        _cell_food_access_eq_period.size() != cells) return;
    if (_cell_food_flow_valid.size() != cells)
        _cell_food_flow_valid.resize(cells, 0);
    // An epoch contains only today's rolling market bucket. Zero scratch for
    // another cell means "not settled", not "no food". Keep that cell's last
    // complete production/consumption observation until it settles again.
    // Store daily equivalents so a later bucket with a different epoch length
    // cannot reinterpret an untouched cell's numerator using the new duration.
    // Old saves already carry their common duration; normalize them once here.
    const int32_t previous_days = std::max(1, _food_flow_previous_period_days.get());
    if (previous_days != 1) {
        for (size_t cell = 0; cell < cells; ++cell) {
            for (auto *column : {&_cell_food_output_eq_previous,
                     &_cell_food_input_eq_previous, &_cell_food_import_eq_previous,
                     &_cell_food_export_eq_previous, &_cell_food_access_eq_previous}) {
                column->write_scalar(cell, (*column)[cell] / previous_days,
                    market_mutation_sink());
            }
        }
    }
    const int32_t days = std::max(1, _epoch_days.get());
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || static_cast<size_t>(cell) >= cells) continue;
        _cell_food_output_eq_previous.write_scalar(cell,
            _cell_food_output_eq_period[cell] / days, market_mutation_sink());
        _cell_food_input_eq_previous.write_scalar(cell,
            _cell_food_input_eq_period[cell] / days, market_mutation_sink());
        _cell_food_access_eq_previous.write_scalar(cell,
            _cell_food_access_eq_period[cell] / days, market_mutation_sink());
        _cell_food_flow_valid.write_scalar(cell, 1, market_mutation_sink());
    }
    // Trade settles globally, including arrivals outside today's market bucket.
    // Keep its existing epoch observation cadence and account for each event
    // once, independently of the retained household/production observations.
    for (size_t cell = 0; cell < cells; ++cell) {
        _cell_food_import_eq_previous.write_scalar(cell,
            _cell_food_import_eq_period[cell] / days, market_mutation_sink());
        _cell_food_export_eq_previous.write_scalar(cell,
            _cell_food_export_eq_period[cell] / days, market_mutation_sink());
    }
    _food_flow_previous_period_days = 1;
    static const bool serial_cells = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FOOD_CAPACITY_SERIAL);
        return value && std::strcmp(value, "1") == 0;
    }();
    const int32_t tasks = !serial_cells && _worker_enabled && cells >= 1024 &&
            parallel_has_real_worker_threads()
        ? std::min<int32_t>(_worker_task_cap, _worker_tasks_hint > 0 ? _worker_tasks_hint : 8) : 1;
    thread_local std::vector<int64_t> cell_saturations;
    cell_saturations.resize(cells);
    int64_t *const sat_lanes = cell_saturations.data();
    const auto compute = [&](int32_t first, int32_t last) {
        for (int32_t cell = first; cell < last; ++cell) {
            int64_t k_geo = 0;
            int64_t sat = 0;
            _cell_carrying_k_eff[cell] = food_flow_capacity_for_cell(cell, k_geo, sat);
            _cell_carrying_k_geo[cell] = k_geo;
            sat_lanes[cell] = sat;
        }
    };
    if (tasks > 1)
        parallel_for_range("pk_economy_food_capacity", static_cast<int32_t>(cells), tasks, 128, compute);
    else compute(0, static_cast<int32_t>(cells));
    static const bool verify_cells = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (verify_cells) {
        for (size_t cell = 0; cell < cells; ++cell) {
            int64_t k_geo = 0, sat = 0;
            const int64_t k_eff = food_flow_capacity_for_cell(static_cast<int32_t>(cell), k_geo, sat);
            if (k_eff != _cell_carrying_k_eff[cell] || k_geo != _cell_carrying_k_geo[cell] ||
                    sat != sat_lanes[cell]) {
                std::fprintf(stderr, "[food-capacity-parallel-mismatch] day=%lld cell=%llu\n",
                    static_cast<long long>(_current_day.get()), static_cast<unsigned long long>(cell));
                std::abort();
            }
        }
    }
    for (int64_t sat : cell_saturations) _saturation_count += sat;
    EconomyCostProbe::record("food_capacity.cell_tasks", _current_day.get(), 0.0, tasks);
    static const bool scalar = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FOOD_STOCK_SCAN_SCALAR);
        return value && std::strcmp(value, "1") == 0;
    }();
    const int32_t good_limit = std::min<int32_t>(market_store().good_count.get(),
        static_cast<int32_t>(_good_food_equivalent_q16.size()));
    const size_t goods_scanned = scalar ? static_cast<size_t>(std::max(0, good_limit))
        : static_cast<size_t>(std::lower_bound(_food_equivalent_goods.begin(),
            _food_equivalent_goods.end(), good_limit) - _food_equivalent_goods.begin());
    const size_t markets_scanned = std::min(cells,
        static_cast<size_t>(std::max(0, market_store().market_count.get())));
    EconomyCostProbe::record("food_capacity.stock_scan_entries", _current_day.get(),
        0.0, markets_scanned * goods_scanned);
}

int64_t NativeEconomyRuntime::food_flow_capacity_for_cell(
        int32_t cell, int64_t &k_geo, int64_t &sat) const {
    k_geo = 0;
    if (cell < 0 || cell >= _cell_count.get() ||
        static_cast<size_t>(cell) >= _cell_food_flow_valid.size() ||
        _cell_food_flow_valid[static_cast<size_t>(cell)] == 0) return 0;
    const int64_t flow_days = std::max<int32_t>(1, _food_flow_previous_period_days.get());
    const int64_t per_person_food = std::max<int64_t>(
        1, _carrying_survival_food_per_person);
    const int64_t denominator = saturating_mul(flow_days, per_person_food, sat);
    if (denominator <= 0) return 0;
    const size_t lane = static_cast<size_t>(cell);
    if (lane >= _cell_food_output_eq_previous.size() ||
        lane >= _cell_food_input_eq_previous.size() ||
        lane >= _cell_food_import_eq_previous.size() ||
        lane >= _cell_food_export_eq_previous.size()) return 0;
    const int64_t local = std::max<int64_t>(0,
        _cell_food_output_eq_previous[lane] -
        _cell_food_input_eq_previous[lane]);
    const int64_t effective = std::max<int64_t>(0, local +
        _cell_food_import_eq_previous[lane] -
        _cell_food_export_eq_previous[lane]);
    // A warehouse reserve is useful only for a bounded horizon. Convert
    // household-available stock into equivalent flow for the current period,
    // excluding production/construction reserves from the stock contribution.
    int64_t stock_food_eq = 0;
    if (cell < market_store().market_count.get()) {
        const int32_t market = cell;
        const int32_t good_limit = std::min<int32_t>(
            market_store().good_count.get(),
            static_cast<int32_t>(_good_food_equivalent_q16.size()));
        static const bool scalar = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FOOD_STOCK_SCAN_SCALAR);
            return value && std::strcmp(value, "1") == 0;
        }();
        static const bool verify = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
            return value && std::strcmp(value, "1") == 0;
        }();
        auto stock_equivalent = [&](bool full_scan, int64_t &scan_sat) {
        int64_t total = 0;
        const int32_t count = full_scan ? good_limit
            : static_cast<int32_t>(_food_equivalent_goods.size());
        for (int32_t entry = 0; entry < count; ++entry) {
            const int32_t good = full_scan ? entry : _food_equivalent_goods[entry];
            if (good >= good_limit) break;
            const int32_t coefficient = _good_food_equivalent_q16[
                static_cast<size_t>(good)];
            if (coefficient <= 0) continue;
            const int64_t idx = market_store().index(market, good);
            if (idx < 0 || idx >= static_cast<int64_t>(market_store().stock.size())) continue;
            const int64_t raw_stock = market_store().stock[static_cast<size_t>(idx)];
            if (raw_stock <= 0) continue;
            int64_t reserve = 0;
            const int32_t signal = market_signal_index(market, good);
            if (signal >= 0) {
                if (signal < static_cast<int32_t>(_production_input_reserve.size()))
                    reserve = std::max(reserve, _production_input_reserve[
                        static_cast<size_t>(signal)]);
                if (signal < static_cast<int32_t>(_construction_material_reserve.size()))
                    reserve = std::max(reserve, _construction_material_reserve[
                        static_cast<size_t>(signal)]);
            }
            const int64_t available = std::max<int64_t>(0, raw_stock - reserve);
            if (available <= 0) continue;
            total = saturating_add(total,
                mul_div_sat(available, coefficient, Q16_ONE, scan_sat), scan_sat);
        }
        return total;
        };
        const int64_t initial_stock_sat = sat;
        stock_food_eq = stock_equivalent(scalar, sat);
        if (!scalar && verify) {
            int64_t reference_sat = initial_stock_sat;
            if (stock_equivalent(true, reference_sat) != stock_food_eq || reference_sat != sat) {
                std::fprintf(stderr, "[food-stock-scan-mismatch] day=%lld cell=%d\n",
                    static_cast<long long>(_current_day.get()), cell);
                std::abort();
            }
        }
    }
    const int64_t stock_period_eq = mul_div_sat(
        stock_food_eq, flow_days,
        std::max<int32_t>(1, _carrying_stock_buffer_days), sat);
    const int64_t effective_with_stock = saturating_add(
        effective, stock_period_eq, sat);
    k_geo = local / denominator;
    return effective_with_stock / denominator;
}

} // namespace pk

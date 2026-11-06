#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

void NativeEconomyRuntime::refresh_epoch_research_demand() {
    _epoch_research_good_id = -1;
    _epoch_research_demand_by_cell.assign(
        static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    _epoch_research_demand_by_market.assign(
        static_cast<size_t>(std::max(0, market_store().market_count.get())), 0);
    if (_country_runtime == nullptr || !country_reads().economy_available() ||
        market_store().market_count.get() <= 0 || market_store().good_count.get() <= 0 ||
        _epoch_country_count <= 0) return;

    const int32_t research_good =
        country_reads().technology_points_good_id();
    if (research_good < 0 || research_good >= market_store().good_count.get()) return;
    _epoch_research_good_id = research_good;

    const int32_t days = std::max(1, _epoch_days.get());
    const size_t country_count = static_cast<size_t>(_epoch_country_count);
    std::vector<int64_t> population_by_country(country_count, 0);
    std::vector<int64_t> price_population_by_country(country_count, 0);
    const int64_t fallback_price = std::max<int64_t>(
        1, research_good < static_cast<int32_t>(_good_default_price.size())
            ? _good_default_price[static_cast<size_t>(research_good)] : 1);
    const bool cell_market_shape = market_store().cell_to_market.size() ==
        static_cast<size_t>(_cell_count.get());
    const auto market_for_cell = [&](int32_t cell) {
        const int32_t market = cell_market_shape
            ? market_store().cell_to_market[static_cast<size_t>(cell)] : cell;
        return market >= 0 && market < market_store().market_count.get() ? market : -1;
    };
    const auto visit_populated_cell = [&](auto &&fn) {
        if (!_economy_live_cells.empty()) {
            for (const int32_t cell : _economy_live_cells) {
                if (cell >= 0 && cell < _cell_count.get()) fn(cell);
            }
        } else {
            for (int32_t cell = 0; cell < _cell_count.get(); ++cell) fn(cell);
        }
    };
    visit_populated_cell([&](int32_t cell) {
        if (cell >= static_cast<int32_t>(_epoch_cell_country.size()) ||
            cell >= static_cast<int32_t>(_committed_cells.size())) return;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) return;
        const int64_t population = std::max<int64_t>(
            0, _committed_cells[static_cast<size_t>(cell)].population);
        if (population <= 0) return;
        population_by_country[static_cast<size_t>(country)] = saturating_add(
            population_by_country[static_cast<size_t>(country)], population,
            _saturation_count);

        int64_t price = fallback_price;
        const int32_t market = market_for_cell(cell);
        if (market >= 0) {
            const int64_t index = market_store().index(market, research_good);
            if (index >= 0 && index < static_cast<int64_t>(market_store().price.size()))
                price = std::max<int64_t>(1, market_store().price[static_cast<size_t>(index)]);
        }
        price_population_by_country[static_cast<size_t>(country)] = saturating_add(
            price_population_by_country[static_cast<size_t>(country)],
            mul_div_sat(population, price, 1, _saturation_count),
            _saturation_count);
    });

    std::vector<int64_t> demand_by_country(country_count, 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        const size_t country_index = static_cast<size_t>(country);
        if (population_by_country[country_index] <= 0) continue;
        bool enabled = false;
        int64_t daily_budget = 0;
        int64_t remaining_points = 0;
        if (!research_procurement_policy_for(
                country, enabled, daily_budget, remaining_points) ||
            !enabled || daily_budget <= 0 || remaining_points <= 0) continue;
        const int64_t cash = std::max<int64_t>(
            0, country_reads().cash_for_slot(country));
        const int64_t epoch_budget = std::min<int64_t>(
            cash, saturating_mul(daily_budget, days, _saturation_count));
        if (epoch_budget <= 0) continue;
        const int64_t average_price = std::max<int64_t>(1,
            price_population_by_country[country_index] /
                population_by_country[country_index]);
        const int64_t affordable_points = mul_div_sat(
            epoch_budget, GOODS_SCALE, average_price, _saturation_count);
        demand_by_country[country_index] = std::min(
            std::max<int64_t>(0, remaining_points), affordable_points);
    }

    // Allocate each country's total once, in ascending cell order. The prefix
    // split gives an exact population-weighted partition, so a multi-cell
    // country cannot accidentally copy its national demand to every cell.
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        const size_t country_index = static_cast<size_t>(country);
        const int64_t total_demand = demand_by_country[country_index];
        const int64_t total_population = population_by_country[country_index];
        if (total_demand <= 0 || total_population <= 0) continue;
        int64_t population_prefix = 0;
        int64_t allocated = 0;
        visit_populated_cell([&](int32_t cell) {
            if (cell >= static_cast<int32_t>(_epoch_cell_country.size()) ||
                cell >= static_cast<int32_t>(_committed_cells.size()) ||
                _epoch_cell_country[static_cast<size_t>(cell)] != country)
                return;
            const int64_t population = std::max<int64_t>(
                0, _committed_cells[static_cast<size_t>(cell)].population);
            if (population <= 0) return;
            population_prefix = saturating_add(
                population_prefix, population, _saturation_count);
            const int64_t next_allocated = mul_div_sat(
                total_demand, population_prefix, total_population,
                _saturation_count);
            const int64_t share = std::max<int64_t>(
                0, next_allocated - allocated);
            _epoch_research_demand_by_cell[static_cast<size_t>(cell)] = share;
            allocated = next_allocated;
        });
    }
    visit_populated_cell([&](int32_t cell) {
        if (cell >= static_cast<int32_t>(_epoch_research_demand_by_cell.size()))
            return;
        const int32_t market = market_for_cell(cell);
        if (market < 0 || _epoch_research_demand_by_cell[static_cast<size_t>(cell)] <= 0)
            return;
        _epoch_research_demand_by_market[static_cast<size_t>(market)] = saturating_add(
            _epoch_research_demand_by_market[static_cast<size_t>(market)],
            _epoch_research_demand_by_cell[static_cast<size_t>(cell)],
            _saturation_count);
    });
}

void NativeEconomyRuntime::refresh_epoch_bullion_quota() {
    _epoch_bullion_quota_keys.clear();
    _epoch_bullion_quota_initial.clear();
    _epoch_bullion_quota_remaining.clear();
    _epoch_bullion_quota_initial_total = 0;
    _epoch_bullion_quota_remaining_total = 0;
    _epoch_bullion_quota_remainder_units = 0;
    // Retire bullion issuance quotas. Keep the old lanes empty for save/CSV
    // compatibility; monetary goods settle at face value without a cap.
    return;
#if 0
    if (_cell_count.get() <= 0 || market_store().good_count.get() <= 0 ||
        _epoch_settlement_cells.empty() || _bullion_monthly_issue_cap_q16.get() <= 0)
        return;

    bool has_monetary_good = false;
    for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
        if (good < static_cast<int32_t>(_good_monetary_issue_values.size()) &&
            _good_monetary_issue_values[good] > 0) {
            has_monetary_good = true;
            break;
        }
    }
    if (!has_monetary_good) return;

    std::vector<int64_t> cell_population(
        static_cast<size_t>(_cell_count.get()), 0);
    std::vector<int64_t> cell_weight(
        static_cast<size_t>(_cell_count.get()), 0);
    std::vector<int64_t> country_population(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count.get()) continue;
        int64_t population = 0;
        int64_t funds = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            population = saturating_add(population,
                std::max<int64_t>(0, population_store().population[slot]),
                _saturation_count);
            funds = saturating_add(funds,
                std::max<int64_t>(0, population_store().funds[slot]),
                _saturation_count);
        });
        cell_population[static_cast<size_t>(cell)] = population;
        const int32_t country = cell < static_cast<int32_t>(
                _epoch_cell_country.size())
            ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
        if (country >= 0 && country < _epoch_country_count)
            country_population[static_cast<size_t>(country)] = saturating_add(
                country_population[static_cast<size_t>(country)], population,
                _saturation_count);
        cell_weight[static_cast<size_t>(cell)] = funds;
    }
    // Country treasury cash is apportioned by population after fiscal reserve;
    // this keeps the world cap global while allowing a cash-poor but populated
    // cell to inherit a deterministic share of national monetary capacity.
    if (_country_runtime != nullptr) {
        for (const int32_t cell : _epoch_settlement_cells) {
            if (cell < 0 || cell >= _cell_count.get()) continue;
            const int32_t country = cell < static_cast<int32_t>(
                    _epoch_cell_country.size())
                ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
            if (country < 0 || country >= _epoch_country_count) continue;
            const int64_t national_cash = std::max<int64_t>(0,
                country_reads().cash_for_slot(country));
            const int64_t population = cell_population[static_cast<size_t>(cell)];
            const int64_t total_population = country_population[
                static_cast<size_t>(country)];
            if (national_cash <= 0 || population <= 0 || total_population <= 0)
                continue;
            cell_weight[static_cast<size_t>(cell)] = saturating_add(
                cell_weight[static_cast<size_t>(cell)],
                mul_div_sat(national_cash, population, total_population,
                            _saturation_count), _saturation_count);
        }
    }
    int64_t total_weight = 0;
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell >= 0 && cell < _cell_count.get())
            total_weight = saturating_add(total_weight,
                cell_weight[static_cast<size_t>(cell)], _saturation_count);
    }
    if (total_weight <= 0) return;
    // Only spendable money can justify new currency issuance. Fiscal/trade/
    // expedition escrow is locked and must not be counted as the monetary
    // base; using _opening_totals.country_cash here would also double-count
    // fiscal cash after the reservation pass has moved it into escrow.
    const int64_t spendable_country_cash = _country_runtime != nullptr
        ? std::max<int64_t>(0, country_reads().total_cash())
        : std::max<int64_t>(0, _opening_totals.country_cash);
    const int64_t opening_money = saturating_add(
        std::max<int64_t>(0, _opening_totals.cohort_funds),
        spendable_country_cash, _saturation_count);
    const int64_t monthly_cap = mul_div_sat(
        opening_money, std::clamp<int64_t>(_bullion_monthly_issue_cap_q16.get(),
            0, Q16_ONE), Q16_ONE, _saturation_count);
    const int64_t epoch_cap = mul_div_sat(
        monthly_cap, std::max<int64_t>(1, _epoch_days.get()), 30,
        _saturation_count);
    if (epoch_cap <= 0) return;

    struct QuotaRow {
        uint64_t key = 0;
        int64_t weight = 0;
        int64_t base = 0;
        int64_t remainder = 0;
    };
    std::vector<QuotaRow> rows;
    rows.reserve(_epoch_settlement_cells.size());
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count.get() ||
            cell_weight[static_cast<size_t>(cell)] <= 0) continue;
        // One cell-level pool is shared by every monetary good (gold, silver,
        // and future bullion goods). Keeping the pool at cell scope means a
        // cell with only one monetary producer never strands the other half of
        // an artificial per-good split, while competing goods still contend for
        // the same issuance budget during settlement.
        // The product can exceed int64 even though the apportioned quotient is
        // bounded by epoch_cap (weight <= total_weight).  Do the quotient and
        // remainder in 128-bit arithmetic so saturation cannot turn the
        // fractional remainder into billions of fake whole units.
        const uint64_t ua = static_cast<uint64_t>(epoch_cap);
        const uint64_t ub = static_cast<uint64_t>(
            cell_weight[static_cast<size_t>(cell)]);
        const uint64_t ud = static_cast<uint64_t>(total_weight);
        uint64_t quotient = 0;
        uint64_t remainder = 0;
        if (ua <= std::numeric_limits<uint64_t>::max() / ub) {
            const uint64_t product = ua * ub;
            quotient = product / ud;
            remainder = product % ud;
        } else {
#if defined(_MSC_VER) && defined(_M_X64)
            uint64_t product_hi = 0;
            const uint64_t product_lo = _umul128(ua, ub, &product_hi);
            if (product_hi >= ud) {
                // This cannot occur while ub <= ud and epoch_cap fits in
                // int64, but keep the path saturating if a future caller
                // violates that invariant.
                ++_saturation_count;
                quotient = static_cast<uint64_t>(
                    std::numeric_limits<int64_t>::max());
                remainder = 0;
            } else {
                quotient = _udiv128(product_hi, product_lo, ud, &remainder);
            }
#else
            const unsigned __int128 product =
                static_cast<unsigned __int128>(ua) * ub;
            quotient = static_cast<uint64_t>(product / ud);
            remainder = static_cast<uint64_t>(product % ud);
#endif
        }
        rows.push_back({static_cast<uint64_t>(static_cast<uint32_t>(cell)),
                        cell_weight[static_cast<size_t>(cell)],
                        static_cast<int64_t>(std::min<uint64_t>(
                            quotient, static_cast<uint64_t>(epoch_cap))),
                        static_cast<int64_t>(remainder)});
    }
    if (rows.empty()) return;

    // Largest-remainder apportionment keeps the sum exactly at epoch_cap (when
    // there are enough weighted cells) instead of losing the fractional tail
    // independently in every cell. Ties use the stable cell id, preserving
    // replay equality and making tiny but positive cells discoverable.
    int64_t base_total = 0;
    for (const QuotaRow &row : rows)
        base_total = saturating_add(base_total, row.base, _saturation_count);
    int64_t remainder_units = std::max<int64_t>(
        0, epoch_cap - std::min(epoch_cap, base_total));
    // Largest-remainder apportionment has fewer leftover units than rows.  A
    // violated bound indicates a numeric regression; clamp it so malformed
    // inputs can never turn this bounded step into an unbounded hot loop.
    const int64_t max_remainder_units = static_cast<int64_t>(rows.size()) - 1;
    if (remainder_units > std::max<int64_t>(0, max_remainder_units)) {
        ++_saturation_count;
        remainder_units = std::max<int64_t>(0, max_remainder_units);
    }
    _epoch_bullion_quota_remainder_units = remainder_units;
    std::vector<size_t> remainder_order(rows.size());
    for (size_t i = 0; i < rows.size(); ++i) remainder_order[i] = i;
    std::stable_sort(remainder_order.begin(), remainder_order.end(),
        [&](size_t lhs, size_t rhs) {
            if (rows[lhs].remainder != rows[rhs].remainder)
                return rows[lhs].remainder > rows[rhs].remainder;
            return rows[lhs].key < rows[rhs].key;
        });
    for (int64_t i = 0; i < remainder_units; ++i)
        rows[remainder_order[static_cast<size_t>(i) % rows.size()]].base =
            saturating_add(rows[remainder_order[static_cast<size_t>(i) % rows.size()]].base,
                           1, _saturation_count);

    std::sort(rows.begin(), rows.end(), [](const QuotaRow &a, const QuotaRow &b) {
        return a.key < b.key;
    });
    for (const QuotaRow &row : rows) {
        _epoch_bullion_quota_keys.push_back(row.key);
        _epoch_bullion_quota_initial.push_back(std::max<int64_t>(0, row.base));
        _epoch_bullion_quota_remaining.push_back(std::max<int64_t>(0, row.base));
        _epoch_bullion_quota_initial_total = saturating_add(
            _epoch_bullion_quota_initial_total, std::max<int64_t>(0, row.base),
            _saturation_count);
        _epoch_bullion_quota_remaining_total = saturating_add(
            _epoch_bullion_quota_remaining_total, std::max<int64_t>(0, row.base),
            _saturation_count);
    }
#endif
}

} // namespace pk

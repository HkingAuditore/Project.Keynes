#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "native_simulation_host.h"
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

NativeEconomyRuntime::AuditTotals
NativeEconomyRuntime::audit_totals_from_shadow(const AuditTotals &baseline) const {
    AuditTotals totals = baseline;
    for (const size_t slot : _audit_population_touched_lanes) {
        if (slot >= _audit_shadow_population.size() ||
            slot >= _audit_shadow_funds.size())
            continue;
        const bool active =
            slot < population_store().active.size() && population_store().active[slot] != 0;
        const int64_t population =
            active ? population_store().population[slot] : 0;
        const int64_t funds = active ? population_store().funds[slot] : 0;
        totals.population += population - _audit_shadow_population[slot];
        totals.cohort_funds += funds - _audit_shadow_funds[slot];
    }
    for (const size_t index : _audit_market_touched_lanes) {
        if (index >= _audit_shadow_market_stock.size() ||
            index >= market_store().stock.size())
            continue;
        totals.goods_stock +=
            market_store().stock[index] - _audit_shadow_market_stock[index];
    }
    totals.country_cash =
        _country_runtime == nullptr ? 0 : country_reads().total_cash();
    totals.merchant_cash = 0;
    for (const int32_t slot : _merchant_slots) {
        if (slot >= 0 &&
            slot < static_cast<int32_t>(population_store().active.size()) &&
            population_store().active[slot] != 0) {
            totals.merchant_cash += std::max<int64_t>(
                0, population_store().funds[slot]);
        }
    }
    const int64_t transit = trade_transit_goods();
    totals.goods_stock += transit - totals.transit_goods;
    totals.transit_goods = transit;
    int64_t expedition_population = 0;
    int64_t expedition_funds = 0;
    int64_t expedition_goods = 0;
    int64_t ignored_saturation = 0;
    sum_family_expedition_holdings(expedition_population, expedition_funds,
                                   expedition_goods, ignored_saturation);
    // `transit_population` of any snapshot is expedition + army lane (that is how
    // audit_totals() and the opening fast path build it), so recover the
    // expedition-only baseline before either block rewrites it. Using the raw
    // field here subtracted the lane once and never gave it back, which made the
    // incremental population short by the whole lane and tripped the
    // incremental_audit_mismatch cross-check on any epoch with a lane.
    const int64_t baseline_expedition_population =
        totals.transit_population - totals.army_lane_population;
    totals.population += expedition_population - baseline_expedition_population;
    totals.transit_population = expedition_population;
    totals.expedition_funds = expedition_funds;
    totals.goods_stock += expedition_goods - totals.expedition_goods;
    totals.expedition_goods = expedition_goods;
    // BEGIN army personnel lane: lane holdings are re-read live, exactly like the
    // expedition payload, so the incremental closing audit never has to track
    // them by touch.
    int64_t army_lane_population = 0;
    int64_t army_lane_funds = 0;
    sum_army_personnel_holdings(army_lane_population, army_lane_funds,
                                ignored_saturation);
    totals.population += army_lane_population - totals.army_lane_population;
    totals.transit_population = saturating_add(
        totals.transit_population, army_lane_population, ignored_saturation);
    totals.army_lane_population = army_lane_population;
    totals.army_lane_funds = army_lane_funds;
    // END army personnel lane
    const int64_t escrow = trade_escrow_cash();
    totals.escrow_cash = saturating_add(
        saturating_add(escrow, fiscal_escrow_total(), ignored_saturation),
        expedition_funds, ignored_saturation);
    // BEGIN army personnel lane: lane cash is escrow cash too.
    totals.escrow_cash = saturating_add(totals.escrow_cash, army_lane_funds,
                                        ignored_saturation);
    // END army personnel lane
    int64_t country_goods = 0;
    if (_country_runtime != nullptr) {
        for (int32_t good = 0; good < market_store().good_count.get(); ++good)
            country_goods += country_reads().total_good(good);
    }
    totals.goods_stock += country_goods - totals.country_goods;
    totals.country_goods = country_goods;
    return totals;
}

void NativeEconomyRuntime::refresh_country_research_goods_consumed() {
    if (_country_runtime == nullptr) {
        _country_research_goods_consumed = 0;
        return;
    }
    const int64_t current = country_reads().research_consumed_total();
    _country_research_goods_consumed = current >= _country_research_consumed_opening
        ? current - _country_research_consumed_opening : 0;
}

void NativeEconomyRuntime::resync_closing_country_goods_audit() {
    if (_country_runtime == nullptr) {
        _country_research_goods_consumed = 0;
        return;
    }
    int64_t country_goods = 0;
    int64_t research_consumed = 0;
    int64_t country_cash = 0;
    country_reads().sample_economy_goods_audit(
        country_goods, research_consumed, country_cash);
    _closing_totals.goods_stock +=
        country_goods - _closing_totals.country_goods;
    _closing_totals.country_goods = country_goods;
    _closing_totals.country_cash = country_cash;
    _country_research_goods_consumed =
        research_consumed >= _country_research_consumed_opening
            ? research_consumed - _country_research_consumed_opening : 0;
}

bool NativeEconomyRuntime::should_run(int64_t day_index) const {
    // PROBE is deliberately non-authoritative. It may be exercised by explicit
    // focused tests/benchmarks, but the production scheduler must not mutate the
    // committed market until the ACTIVE performance gate has passed.
    if (!_bootstrapped || _fatal || _save.active || _restore.active || _market_runtime_mode != 2)
        return false;
    // A running frozen cycle is intentionally isolated from live country
    // changes. A new cycle, however, must wait until every due country command
    // for this day has committed at country_daily priority 255.
    // When Country is worker-authoritative, sync should_run is not a live day
    // owner — waiting on it starves economy forever (runtime graph skips the
    // country slice). Peer asset traffic still flows via the simulation host.
    if (!_epoch_active && _country_runtime != nullptr &&
        country_reads().should_run(day_index)) {
        const bool country_on_worker =
            country_reads().sync_store_writes_forbidden() ||
            (_simulation_host != nullptr &&
             (_simulation_host->domain_is_worker_authoritative(
                  RuntimeDomainId::COUNTRY) ||
              _simulation_host->country_authority_owner_is_worker()));
        if (!country_on_worker) return false;
    }
    // A native Effect command is consumed by the next frozen ledger cycle.
    // Once the current day has already committed, keeping the economy hot only
    // because its ACK is pending creates a same-day continuation with no epoch
    // available to ingest the command. The next day naturally reopens the
    // cycle and preserves the normal ledger boundary.
    if (!_family_expedition_due_heap.empty() &&
        _family_expedition_due_heap.front().first <= day_index) return true;
    for (const CanalProject &project : _canal_projects) {
        if ((project.state == CANAL_PROJECT_BUILDING && project.ready_day <= day_index) ||
            project.state == CANAL_PROJECT_AWAITING_EFFECT) return true;
    }
    return _epoch_active || day_index > _last_committed_day.get() ||
           trade_planner_should_run();
}

NativeEconomyRuntime::AuditTotals NativeEconomyRuntime::audit_totals() const {
    AuditTotals totals;
    int64_t valuation_sat = 0;
    for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
        if (population_store().active[slot] == 0) continue;
        totals.population += population_store().population[slot];
        totals.cohort_funds += population_store().funds[slot];
        if (is_merchant_slot(static_cast<int32_t>(slot))) {
            totals.merchant_cash = saturating_add(
                totals.merchant_cash,
                std::max<int64_t>(0, population_store().funds[slot]),
                valuation_sat);
        }
    }
    totals.country_cash = _country_runtime == nullptr ? 0 : country_reads().total_cash();
    for (int32_t market = 0; market < market_store().market_count.get(); ++market) {
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            const int64_t index = market_store().index(market, good);
            totals.goods_stock += market_store().stock[index];
            // 零/负库存估值恒为零；库存总量仍逐项纳入守恒审计。
            if (market_store().stock[index] <= 0) continue;
            const int64_t retail_value = mul_div_sat(
                std::max<int64_t>(0, market_store().stock[index]),
                std::max<int64_t>(0, market_store().price[index]),
                GOODS_SCALE, valuation_sat);
            totals.merchant_inventory_retail_value = saturating_add(
                totals.merchant_inventory_retail_value, retail_value,
                valuation_sat);
            totals.merchant_inventory_liquidation_value = saturating_add(
                totals.merchant_inventory_liquidation_value,
                mul_div_sat(retail_value, std::clamp<int64_t>(
                    _good_merchant_buy_factor_q16[good], 0, Q16_ONE),
                    Q16_ONE, valuation_sat), valuation_sat);
        }
    }
    totals.transit_goods = trade_transit_goods();
    int64_t expedition_funds = 0;
    int64_t expedition_goods = 0;
    sum_family_expedition_holdings(totals.transit_population, expedition_funds,
                                   expedition_goods, valuation_sat);
    // BEGIN army personnel lane (contract §1.2): embarked people and their cash
    // have left the cohort table but are still owned by Economy, so they count
    // as transit population and escrow cash exactly like an expedition payload.
    int64_t army_lane_population = 0;
    int64_t army_lane_funds = 0;
    sum_army_personnel_holdings(army_lane_population, army_lane_funds,
                                valuation_sat);
    totals.transit_population = saturating_add(totals.transit_population,
                                               army_lane_population, valuation_sat);
    totals.army_lane_population = army_lane_population;
    totals.army_lane_funds = army_lane_funds;
    // END army personnel lane
    totals.expedition_funds = expedition_funds;
    totals.expedition_goods = expedition_goods;
    totals.population += totals.transit_population;
    totals.escrow_cash = saturating_add(saturating_add(
        trade_escrow_cash(), fiscal_escrow_total(), valuation_sat),
        expedition_funds, valuation_sat);
    // BEGIN army personnel lane: lane cash joins escrow cash but stays out of
    // expedition_funds, which the epoch compares against the family expedition
    // store only.
    totals.escrow_cash = saturating_add(totals.escrow_cash, army_lane_funds,
                                        valuation_sat);
    // END army personnel lane
    totals.goods_stock += totals.transit_goods;
    totals.goods_stock += expedition_goods;
    if (_country_runtime != nullptr) {
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            const int64_t country_good =
                country_reads().total_good(good);
            totals.country_goods += country_good;
            totals.goods_stock += country_good;
        }
    }
    return totals;
}

void NativeEconomyRuntime::capture_fatal_context(const std::string &reason) {
    _fatal_context = FatalContext{};
    _fatal_context.valid = true;
    _fatal_context.reason = reason;
    _fatal_context.stage = static_cast<int32_t>(_stage);
    _fatal_context.executed_stage = static_cast<int32_t>(_executed_stage);
    _fatal_context.executed_substage = _executed_substage;
    _fatal_context.day = _current_day.get();
    _fatal_context.epoch_id = _epoch_id.get();
    _fatal_context.command_cursor = _command_cursor;
    _fatal_context.structural_cursor = _structural_cursor;
    _fatal_context.d7_operation_gate_mask = _d7_operation_gate_mask;
    _fatal_context.country_sync_writes_forbidden =
        _country_runtime != nullptr &&
        country_reads().sync_store_writes_forbidden();
    _fatal_context.country_worker_authoritative =
        _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(
            RuntimeDomainId::COUNTRY);
    // The cursor still points at the command that failed, so the opcode and
    // subject handles are recoverable without a breadcrumb in every caller.
    if (_stage == Stage::LEDGER_APPLY && _command_cursor >= 0 &&
        _command_cursor < static_cast<int32_t>(_epoch_commands.size())) {
        const Command &command =
            _epoch_commands[static_cast<size_t>(_command_cursor)];
        _fatal_context.command_opcode = command.opcode;
        _fatal_context.target_handle = static_cast<int64_t>(command.target_handle);
        _fatal_context.subject_handle = command.i64_1;
        _fatal_context.amount = command.i64_0;
    } else if (_stage == Stage::STRUCTURAL_COMMIT && _structural_cursor >= 0 &&
               _structural_cursor <
                   static_cast<int32_t>(_structural_commands.size())) {
        const StructuralCommand &command =
            _structural_commands[static_cast<size_t>(_structural_cursor)];
        _fatal_context.command_opcode = command.opcode;
        _fatal_context.target_handle = command.source_slot;
        _fatal_context.subject_handle = command.cell;
        _fatal_context.amount = command.funds;
    }
}

} // namespace pk

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

void NativeEconomyRuntime::park_on_country_asset_pending(const char *substage) {
    std::string service_error;
    service_country_economy_asset_peer(64, service_error);
    _executed_substage = substage;
}

void NativeEconomyRuntime::fail(const std::string &reason) {
    capture_fatal_context(reason);
    diag_stage_money_probe("fatal", reason == "money_conservation_failed");
    if (reason == "money_conservation_failed") {
        // Leave a final stage marker even when the incremental trace is not
        // available for this audit mode. Reuse already verified closing totals
        // so the fatal path does not trigger another full scan.
        capture_money_audit_candidates();
        pk::log_info(
            "[economy-money-audit] day=%lld open=%lld close=%lld expected=%lld error=%lld mint=%lld burn=%lld producer_support=%lld bullion=%lld opening_escrow=%lld closing_escrow=%lld",
            static_cast<long long>(_current_day.get()),
            static_cast<long long>(_opening_totals.cohort_funds +
                _opening_totals.country_cash + _opening_totals.escrow_cash),
            static_cast<long long>(_closing_totals.cohort_funds +
                _closing_totals.country_cash + _closing_totals.escrow_cash),
            static_cast<long long>(_opening_totals.cohort_funds +
                _opening_totals.country_cash + _opening_totals.escrow_cash +
                _explicit_money_mint - _explicit_money_burn),
            static_cast<long long>(_closing_totals.cohort_funds +
                _closing_totals.country_cash + _closing_totals.escrow_cash -
                (_opening_totals.cohort_funds + _opening_totals.country_cash +
                 _opening_totals.escrow_cash + _explicit_money_mint -
                 _explicit_money_burn)),
            static_cast<long long>(_explicit_money_mint),
            static_cast<long long>(_explicit_money_burn),
            static_cast<long long>(_producer_support_money_issued),
            static_cast<long long>(_bullion_money_issued),
            static_cast<long long>(_opening_totals.escrow_cash),
            static_cast<long long>(_closing_totals.escrow_cash));
        for (const MoneyAuditAccountDiagnostic &account :
                _money_audit_candidate_accounts) {
            const char *profession = account.profession >= 0 &&
                account.profession < static_cast<int32_t>(_profession_ids.size())
                ? _profession_ids[account.profession].c_str() : "unknown";
            pk::log_info(
                "[economy-money-audit-candidate] slot=%d handle=%llu cell=%d signature=%d profession=%d:%s opening=%lld closing=%lld net_change=%lld",
                account.slot, static_cast<unsigned long long>(account.handle),
                account.cell, account.signature, account.profession, profession,
                static_cast<long long>(account.opening_funds),
                static_cast<long long>(account.closing_funds),
                static_cast<long long>(account.net_change));
        }
    }
    if (reason == "goods_conservation_failed") {
        capture_goods_audit_candidates();
        for (const GoodsAuditLaneDiagnostic &lane : _goods_audit_candidate_lanes) {
            const char *good_id = lane.good >= 0 &&
                lane.good < static_cast<int32_t>(_good_ids.size())
                ? _good_ids[lane.good].c_str() : "unknown";
            pk::log_info(
                "[economy-goods-audit-candidate] market=%d cell=%d good=%d:%s opening=%lld closing=%lld net_change=%lld",
                lane.market, lane.cell, lane.good, good_id,
                static_cast<long long>(lane.opening_stock),
                static_cast<long long>(lane.closing_stock),
                static_cast<long long>(lane.net_change));
        }
    }
    for (const MoneyStageDiagnostic &diagnostic : _money_stage_diagnostics) {
        pk::log_info(
            "[economy-money-stage] day=%lld epoch=%lld where=%s stage=%s executed=%s substage=%s diff=%lld delta=%lld money=%lld expected=%lld cohort=%lld country=%lld escrow=%lld mint=%lld burn=%lld",
            static_cast<long long>(diagnostic.day),
            static_cast<long long>(diagnostic.epoch_id),
            diagnostic.where.data(),
            stage_name(static_cast<Stage>(diagnostic.stage)),
            stage_name(static_cast<Stage>(diagnostic.executed_stage)),
            diagnostic.substage.data(),
            static_cast<long long>(diagnostic.diff),
            static_cast<long long>(diagnostic.delta),
            static_cast<long long>(diagnostic.money_now),
            static_cast<long long>(diagnostic.money_expected),
            static_cast<long long>(diagnostic.cohort_funds),
            static_cast<long long>(diagnostic.country_cash),
            static_cast<long long>(diagnostic.escrow_cash),
            static_cast<long long>(diagnostic.explicit_money_mint),
            static_cast<long long>(diagnostic.explicit_money_burn));
    }
    pk::log_info(
        "[economy-fatal] day=%lld stage=%s executed_stage=%s substage=%s reason=%s command_cursor=%d opcode=%d target=%lld subject=%lld amount=%lld d7_gate_mask=%u country_sync_writes_forbidden=%d country_worker_authoritative=%d",
        static_cast<long long>(_current_day.get()), stage_name(_stage),
        stage_name(_executed_stage), _executed_substage.c_str(), reason.c_str(),
        _fatal_context.command_cursor, _fatal_context.command_opcode,
        static_cast<long long>(_fatal_context.target_handle),
        static_cast<long long>(_fatal_context.subject_handle),
        static_cast<long long>(_fatal_context.amount),
        static_cast<unsigned int>(_fatal_context.d7_operation_gate_mask),
        _fatal_context.country_sync_writes_forbidden ? 1 : 0,
        _fatal_context.country_worker_authoritative ? 1 : 0);
    trace_abort_epoch();
    for (const int32_t cell : _staging_touched_cells) {
        if (cell >= 0 && cell < static_cast<int32_t>(_committed_cells.size()) &&
            cell < static_cast<int32_t>(_staging_cells.size())) {
            _staging_cells[cell] = _committed_cells[cell];
        }
    }
    _staging_touched_cells.clear();
    _fatal = true;
    _fatal_reason = reason;
    _epoch_active = false;
    _stage = Stage::FATAL;
}

void NativeEconomyRuntime::finalize_household_building_cell(
        int32_t cell, int64_t &saturation, int64_t &restarted,
        int64_t &failed) {
    if (cell < 0 || cell >= _cell_count.get() ||
        _building_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1)) return;
    for (int32_t g = _building_cell_offsets[cell];
         g < _building_cell_offsets[cell + 1]; ++g) {
        auto group = building_at(static_cast<size_t>(g));
        const int64_t livelihood = saturating_mul(saturating_mul(
            living_cost_for_signature(cell, group.owner_signature_id, -1,
                                      saturation),
            std::max<int64_t>(0, group.filled_owner), saturation),
            std::max(1, _epoch_days.get()), saturation);
        const int64_t credit = g < static_cast<int32_t>(
                _building_owner_livelihood_credit.size())
            ? std::min<int64_t>(livelihood,
                _building_owner_livelihood_credit[g]) : 0;
        group.last_in_kind_livelihood_value = std::max<int64_t>(0, credit);
        const int64_t realized_cost = saturating_add(saturating_add(
            saturating_add(group.last_input_cost, group.last_base_wages_due,
                saturation), group.last_maintenance_cost, saturation),
            livelihood - credit, saturation);
        const int64_t margin = realized_cost <= 0
            ? (group.last_revenue > 0 ? Q16_ONE : 0)
            : mul_div_sat(saturating_sub(
                group.last_revenue, realized_cost, saturation),
                Q16_ONE, std::max<int64_t>(MONEY_SCALE, realized_cost),
                saturation);
        group.realized_profit_margin_q16 = static_cast<int32_t>(
            std::clamp<int64_t>(margin, -Q16_ONE, Q16_ONE));
        // Suspended buildings are evaluated by the unified economic plan
        // above. There is no reduced-capacity trial settlement here: a viable
        // building is scheduled ACTIVE for the next frozen boundary, while a
        // non-viable building remains fully suspended.
        (void)restarted;
        (void)failed;
    }
}

int64_t NativeEconomyRuntime::production_reserve_shortfall_cell(
        int32_t cell, int64_t &saturation) const {
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    const int32_t market = market_store().cell_to_market[cell];
    int64_t shortfall = 0;
    for (int32_t signal = _market_signals.cell_offsets[cell];
         signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
        if (signal >= static_cast<int32_t>(_production_input_reserve.size())) continue;
        const int32_t good = _market_signals.good_ids[signal];
        shortfall = saturating_add(
            shortfall, std::max<int64_t>(0,
                _production_input_reserve[signal] -
                    market_store().stock[market_store().index(market, good)]),
            saturation);
    }
    return shortfall;
}

void NativeEconomyRuntime::review_recovery_building_group(int32_t g) {
    if (g < 0 || g >= static_cast<int32_t>(building_count())) return;
    // Read-only prefilter: most reviewed groups are live, non-liquidatable or
    // debt-free and only need a conditional diagnostic reset. Borrowing every
    // mutable column for them dominated this phase.
    {
        const auto view = building_view(static_cast<size_t>(g));
        if (view.count <= 0 || view.operating_state != 1 ||
            view.cell < 0 || view.cell >= _cell_count.get() ||
            view.type_id < 0 ||
            view.type_id >= static_cast<int32_t>(_building_types.size())) return;
        // Military v1: state-owned lots are never reviewed for liquidation.
        if (_building_types[static_cast<size_t>(view.type_id)].kind == 3) return;
    }
    const bool liquidation_eligible = g < static_cast<int32_t>(
            _building_recovery_liquidation_eligible.size()) &&
        _building_recovery_liquidation_eligible[g] != 0;
    if (!liquidation_eligible) {
        if (building_view(static_cast<size_t>(g)).recovery_failed_reviews != 0)
            building_at(static_cast<size_t>(g)).recovery_failed_reviews = 0;
        return;
    }
    // Recovery liquidation is debt recovery. An owner-financed building with
    // no merchant principal/premium remains addressable while suspended so
    // owner release and a later restart can inspect the same group.
    if (building_view(static_cast<size_t>(g)).merchant_debt_principal <= 0 &&
        building_view(static_cast<size_t>(g)).merchant_debt_premium <= 0) {
        if (building_view(static_cast<size_t>(g)).recovery_failed_reviews != 0)
            building_at(static_cast<size_t>(g)).recovery_failed_reviews = 0;
        return;
    }
    auto group = building_at(static_cast<size_t>(g));
    const BuildingType &type = _building_types[group.type_id];
    // The lifecycle decision is already expressed in monetary terms by the
    // restart-cost and expected-profit gate. Keep one diagnostic marker for
    // compatibility, but do not delay liquidation behind an arbitrary review
    // count once a restart is executable and still unprofitable.
    group.recovery_failed_reviews = 1;
    if (type.owner_profession_id == _merchant_profession_id) return;
    int64_t unit_period_output = 0;
    for (int32_t output_index = 0; output_index < type.output_count; ++output_index) {
        const GoodAmount &output = _building_outputs[type.output_begin + output_index];
        unit_period_output = saturating_add(
            unit_period_output, effective_building_output_quantity(
                group, output.good_id, output.quantity, Q16_ONE,
                std::max<int64_t>(1, _epoch_days.get()), _saturation_count),
            _saturation_count);
    }
    const int64_t liquidation_capacity_q16 = std::max<int64_t>(
        group.planned_utilization_q16,
        g < static_cast<int32_t>(_building_recovery_probe_capacity_q16.size())
            ? _building_recovery_probe_capacity_q16[g] : 0);
    unit_period_output = mul_div_sat(
        unit_period_output, std::max<int64_t>(1, liquidation_capacity_q16),
        Q16_ONE, _saturation_count);
    const int64_t supported_count = unit_period_output > 0
        ? std::min<int64_t>(group.count,
            saturating_add(std::max<int64_t>(0, group.last_sold),
                unit_period_output - 1, _saturation_count) / unit_period_output)
        : 0;
    const int64_t confirmed_excess = std::max<int64_t>(
        0, group.count - supported_count);
    if (confirmed_excess <= 0) {
        group.recovery_failed_reviews = 0;
        return;
    }
    const int64_t max_retire = std::max<int64_t>(1,
        saturating_add(saturating_mul(group.count,
            _recovery_liquidation_max_share_q16.get(), _saturation_count),
            Q16_ONE - 1, _saturation_count) / Q16_ONE);
    const int64_t retire_count = std::min(confirmed_excess, max_retire);
    const int64_t count_before = group.count;
    const int64_t principal_bad = retire_count == count_before
        ? group.merchant_debt_principal
        : mul_div_sat(group.merchant_debt_principal,
            retire_count, count_before, _saturation_count);
    const int64_t premium_bad = retire_count == count_before
        ? group.merchant_debt_premium
        : mul_div_sat(group.merchant_debt_premium,
            retire_count, count_before, _saturation_count);
    const int64_t bad_debt = saturating_add(
        principal_bad, premium_bad, _saturation_count);
    _merchant_credit_bad_debt = saturating_add(
        _merchant_credit_bad_debt, bad_debt, _saturation_count);
    _recovery_liquidated_buildings = saturating_add(
        _recovery_liquidated_buildings, retire_count, _saturation_count);
    group.merchant_debt_principal = std::max<int64_t>(
        0, group.merchant_debt_principal - principal_bad);
    group.merchant_debt_premium = std::max<int64_t>(
        0, group.merchant_debt_premium - premium_bad);
    _investment_employment_cells.push_back(group.cell);
    group.count -= retire_count;
    _building_handle_index_clean = false;
    if (group.count <= 0) {
        group.count = 0;
        group.merchant_debt_principal = 0;
        group.merchant_debt_premium = 0;
        group.merchant_debt_term_cycles_left = 0;
        group.merchant_debt_delinquent_cycles = 0;
        ++_recovery_fully_liquidated_groups;
    } else {
        _recovery_partially_liquidated_buildings = saturating_add(
            _recovery_partially_liquidated_buildings,
            retire_count, _saturation_count);
    }
}

Dictionary NativeEconomyRuntime::run_slice(const Dictionary &ctx) {
    return run_slice_internal(ctx, false);
}

Dictionary NativeEconomyRuntime::run_slice_compact(const Dictionary &ctx) {
    return run_slice_internal(ctx, true);
}

bool NativeEconomyRuntime::worker_run_compact_slice(int64_t day_index,
                                                     std::string &error,
                                                     bool *done,
                                                     bool *pending_input) {
    error.clear();
    if (done != nullptr) *done = false;
    if (pending_input != nullptr) *pending_input = false;
    Dictionary ctx;
    ctx["day_index"] = day_index;
    const Dictionary result = run_slice_compact(ctx);
    const bool fatal = static_cast<bool>(result.get("fatal", false));
    const bool slice_done = static_cast<bool>(result.get("done", false));
    const bool pending = static_cast<bool>(result.get("pending_input", false));
    if (done != nullptr) *done = slice_done;
    if (pending_input != nullptr) *pending_input = pending;
    if (pending) {
        // Soft input barrier: main thread has not yet captured same-day
        // environment/building context. Not a ledger fatal — Host parks day.
        error = String(result.get("yield_reason", "pending_input"))
                    .utf8()
                    .get_data();
        if (error.empty()) error = "pending_input";
        return true;
    }
    if (fatal) {
        error = String(result.get("fatal_reason", "economy_worker_fatal"))
                    .utf8()
                    .get_data();
        if (error.empty()) error = "economy_worker_fatal";
        return false;
    }
    return true;
}

void NativeEconomyRuntime::diag_stage_money_probe(const char *where, bool force) {
    static const char *env = pk::runtime_switch_value(pk::RuntimeSwitch::PK_DIAG_STAGE_MONEY);
    static const int64_t from_day = env ? std::atoll(env) : -1;
    if (_current_day.get() < 0) return;
    const bool force_full_trace = from_day >= 0 &&
        _current_day.get() >= from_day;
    const bool incremental_available = _audit_mutation_generation != 0 &&
        _closing_audit_mode != 0 && !_closing_audit_runtime_disabled;
    if (_money_stage_probe_epoch_id != _epoch_id.get()) {
        _money_stage_probe_epoch_id = _epoch_id.get();
        _money_stage_diagnostics.clear();
        _money_stage_probe_last_diff = 0;
        _money_stage_probe_last_stage = -1;
        _money_stage_probe_last_executed_stage = -1;
        _money_stage_probe_post_commit = false;
        _money_stage_probe_has_last = false;
        _money_stage_probe_last_where.clear();
        _money_stage_probe_last_substage.clear();
    }
    // The default trace is cheap in incremental-audit mode. In FULL mode,
    // retain stage samples only when explicitly requested or at the fatal
    // boundary; otherwise a full population/market scan per slice would be
    // an unacceptable always-on cost.
    if (!incremental_available && !force_full_trace && !force && !_fatal) return;

    const bool use_closing_totals = force && _closing_totals_valid;
    AuditTotals now;
    if (use_closing_totals) {
        now = _closing_totals;
    } else if (incremental_available) {
        now = incremental_audit_totals();
    } else {
        now = audit_totals();
    }
    int64_t money_now = now.cohort_funds + now.country_cash + now.escrow_cash;
    if (!use_closing_totals && !_money_stage_probe_post_commit &&
        std::strcmp(where, "fiscal_settlement") != 0) {
        // Before commit_fiscal folds lanes into escrow, withheld tax and paid
        // subsidy live only in the lane tallies.
        for (size_t lane = 0; lane < _fiscal_epoch_collected.size(); ++lane)
            money_now += _fiscal_epoch_collected[lane];
        for (size_t lane = 0; lane < _fiscal_epoch_paid.size(); ++lane)
            money_now -= _fiscal_epoch_paid[lane];
        for (size_t lane = 0; lane < _tariff_epoch_collected.size(); ++lane)
            money_now += _tariff_epoch_collected[lane];
        for (size_t lane = 0; lane < _tariff_epoch_paid.size(); ++lane)
            money_now -= _tariff_epoch_paid[lane];
    }
    if (std::strcmp(where, "fiscal_settlement") == 0)
        _money_stage_probe_post_commit = true;
    const int64_t money_open = _opening_totals.cohort_funds +
        _opening_totals.country_cash + _opening_totals.escrow_cash;
    const int64_t money_expected = money_open + _explicit_money_mint -
        _explicit_money_burn;
    const int64_t diff = money_now - money_expected;
    const int32_t stage = static_cast<int32_t>(_stage);
    const int32_t executed_stage = static_cast<int32_t>(_executed_stage);
    const bool point_changed = !_money_stage_probe_has_last ||
        diff != _money_stage_probe_last_diff ||
        stage != _money_stage_probe_last_stage ||
        executed_stage != _money_stage_probe_last_executed_stage ||
        _money_stage_probe_last_where != where ||
        _money_stage_probe_last_substage != _executed_substage;
    if (!point_changed) return;

    MoneyStageDiagnostic diagnostic;
    diagnostic.day = _current_day.get();
    diagnostic.epoch_id = _epoch_id.get();
    diagnostic.stage = stage;
    diagnostic.executed_stage = executed_stage;
    diagnostic.money_open = money_open;
    diagnostic.money_now = money_now;
    diagnostic.money_expected = money_expected;
    diagnostic.diff = diff;
    diagnostic.delta = _money_stage_probe_has_last
        ? diff - _money_stage_probe_last_diff : diff;
    diagnostic.cohort_funds = now.cohort_funds;
    diagnostic.country_cash = now.country_cash;
    diagnostic.escrow_cash = now.escrow_cash;
    diagnostic.explicit_money_mint = _explicit_money_mint;
    diagnostic.explicit_money_burn = _explicit_money_burn;
    std::snprintf(diagnostic.where.data(), diagnostic.where.size(), "%s", where);
    std::snprintf(diagnostic.substage.data(), diagnostic.substage.size(), "%s",
        _executed_substage.c_str());
    constexpr size_t MAX_MONEY_STAGE_DIAGNOSTICS = 128;
    constexpr size_t PRESERVED_INITIAL_DIAGNOSTICS = 32;
    if (_money_stage_diagnostics.capacity() < MAX_MONEY_STAGE_DIAGNOSTICS)
        _money_stage_diagnostics.reserve(MAX_MONEY_STAGE_DIAGNOSTICS);
    if (_money_stage_diagnostics.size() >= MAX_MONEY_STAGE_DIAGNOSTICS) {
        _money_stage_diagnostics.erase(
            _money_stage_diagnostics.begin() + PRESERVED_INITIAL_DIAGNOSTICS);
    }
    _money_stage_diagnostics.push_back(std::move(diagnostic));
    _money_stage_probe_last_diff = diff;
    _money_stage_probe_last_stage = stage;
    _money_stage_probe_last_executed_stage = executed_stage;
    _money_stage_probe_last_where = where;
    _money_stage_probe_last_substage = _executed_substage;
    _money_stage_probe_has_last = true;
}

} // namespace pk

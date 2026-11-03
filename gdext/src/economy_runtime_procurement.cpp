// National procurement budget + era advancement procurement.
//
// Contract: docs/cpp-dots-runtime/era-advancement-runtime.md §2.2-2.4.
// Everything in this file is transient: no PKEC field, no state-hash input.
// Setters run on any thread and only append to a mutex-guarded inbox; the
// Economy owner thread folds the inbox at the next epoch begin so a policy
// change never leaks into an already-frozen economy cycle.
#include "economy_runtime.h"
#include "country_runtime.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <limits>
#include <tuple>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

namespace {
uint64_t era_procurement_key(int32_t place, int32_t good) {
    return (static_cast<uint64_t>(static_cast<uint32_t>(place)) << 32U) |
        static_cast<uint32_t>(good);
}

int32_t clamp_bp(int32_t value) { return std::clamp<int32_t>(value, 0, 10000); }

enum ProcurementCashKind : int32_t {
    PROCUREMENT_CASH_RESEARCH = 0,
    PROCUREMENT_CASH_ERA = 1,
    PROCUREMENT_CASH_COLONIZATION = 2,
};
} // namespace

// ── Ingress (any thread) ─────────────────────────────────────────────────

Dictionary NativeEconomyRuntime::set_country_procurement_policy(
        int64_t country_handle, bool enabled, int32_t treasury_share_bp,
        int32_t research_share_bp, int64_t effective_day, int64_t sequence) {
    Dictionary out;
    if (_country_runtime == nullptr || !_country_runtime->valid_handle(country_handle)) {
        out["ok"] = false;
        out["code"] = "procurement_country_invalid";
        return out;
    }
    if (treasury_share_bp < 0 || treasury_share_bp > 10000 ||
        research_share_bp < 0 || research_share_bp > 10000) {
        out["ok"] = false;
        out["code"] = "procurement_share_invalid";
        return out;
    }
    PendingProcurementUpdate update;
    update.kind = 1;
    update.country_handle = static_cast<uint64_t>(country_handle);
    update.flag = enabled;
    update.treasury_share_bp = treasury_share_bp;
    update.research_share_bp = research_share_bp;
    update.effective_day = std::max<int64_t>(0, effective_day);
    update.sequence = sequence;
    {
        std::lock_guard<std::mutex> lock(_procurement_inbox->mutex);
        update.order = _procurement_inbox->next_order++;
        _procurement_inbox->requested_policy[update.country_handle] = update;
        _procurement_inbox->updates.push_back(std::move(update));
    }
    out["ok"] = true;
    out["code"] = "procurement_policy_queued";
    out["queued"] = true;
    out["effective_day"] = effective_day;
    out["sequence"] = sequence;
    return out;
}

Dictionary NativeEconomyRuntime::set_era_procurement_target(
        int64_t country_handle, bool active, const PackedInt32Array &good_indices,
        const PackedInt64Array &required_quantities, int64_t effective_day,
        int64_t sequence) {
    Dictionary out;
    if (_country_runtime == nullptr || !_country_runtime->valid_handle(country_handle)) {
        out["ok"] = false;
        out["code"] = "procurement_country_invalid";
        return out;
    }
    if (active && good_indices.size() != required_quantities.size()) {
        out["ok"] = false;
        out["code"] = "era_procurement_target_shape_invalid";
        return out;
    }
    const int32_t good_count = static_cast<int32_t>(_good_ids.size());
    PendingProcurementUpdate update;
    update.kind = 2;
    update.country_handle = static_cast<uint64_t>(country_handle);
    update.flag = active;
    if (active) {
        for (int64_t i = 0; i < good_indices.size(); ++i) {
            const int32_t good = good_indices[i];
            const int64_t quantity = required_quantities[i];
            if (good < 0 || good >= good_count || quantity < 0) {
                out["ok"] = false;
                out["code"] = "era_procurement_target_good_invalid";
                return out;
            }
            // Merge duplicate goods so the deterministic line order is unique.
            const auto found = std::find(update.goods.begin(), update.goods.end(), good);
            if (found != update.goods.end()) {
                int64_t sat = 0;
                int64_t &total = update.quantities[static_cast<size_t>(
                    found - update.goods.begin())];
                total = saturating_add(total, quantity, sat);
                continue;
            }
            update.goods.push_back(good);
            update.quantities.push_back(quantity);
        }
    }
    update.effective_day = std::max<int64_t>(0, effective_day);
    update.sequence = sequence;
    {
        std::lock_guard<std::mutex> lock(_procurement_inbox->mutex);
        update.order = _procurement_inbox->next_order++;
        _procurement_inbox->requested_era[update.country_handle] = update;
        _procurement_inbox->updates.push_back(std::move(update));
    }
    out["ok"] = true;
    out["code"] = active ? "era_procurement_target_queued"
                         : "era_procurement_target_clear_queued";
    out["queued"] = true;
    out["effective_day"] = effective_day;
    out["sequence"] = sequence;
    return out;
}

// ── Owner-thread state ───────────────────────────────────────────────────

void NativeEconomyRuntime::clear_procurement_runtime_state(bool clear_pending) {
    _country_procurement.clear();
    _country_trade_orders_by_slot.clear();
    reset_era_procurement_epoch();
    _epoch_era_demand_by_cell.clear();
    _epoch_era_demand_by_market.clear();
    if (clear_pending) {
        std::lock_guard<std::mutex> lock(_procurement_inbox->mutex);
        _procurement_inbox->updates.clear();
        _procurement_inbox->requested_policy.clear();
        _procurement_inbox->requested_era.clear();
    }
}

void NativeEconomyRuntime::reset_era_procurement_epoch() {
    _era_procurement_candidates.clear();
    _era_procurement_budgets.clear();
    _era_procurement_remaining.clear();
    _era_procurement_line_offsets.clear();
    _era_procurement_handles.clear();
    _era_procurement_cursor = 0;
    _era_procurement_initialized = false;
    _era_procurement_done = false;
    _era_procurement_continuation = EraProcurementContinuation{};
}

void NativeEconomyRuntime::apply_pending_procurement_updates(int64_t day_index) {
    std::vector<PendingProcurementUpdate> due;
    {
        std::lock_guard<std::mutex> lock(_procurement_inbox->mutex);
        if (_procurement_inbox->updates.empty()) return;
        std::vector<PendingProcurementUpdate> future;
        for (PendingProcurementUpdate &update : _procurement_inbox->updates) {
            if (update.effective_day <= day_index) due.push_back(std::move(update));
            else future.push_back(std::move(update));
        }
        _procurement_inbox->updates.swap(future);
    }
    std::stable_sort(due.begin(), due.end(),
        [](const PendingProcurementUpdate &a, const PendingProcurementUpdate &b) {
            return std::tie(a.effective_day, a.sequence, a.order) <
                std::tie(b.effective_day, b.sequence, b.order);
        });
    for (PendingProcurementUpdate &update : due) {
        if (_country_runtime == nullptr ||
            !_country_runtime->valid_handle(static_cast<int64_t>(update.country_handle)))
            continue;
        CountryProcurementState &state = _country_procurement[update.country_handle];
        state.country_handle = update.country_handle;
        if (update.kind == 1) {
            state.policy_enabled = update.flag;
            state.treasury_share_bp = clamp_bp(update.treasury_share_bp);
            state.research_share_bp = clamp_bp(update.research_share_bp);
        } else if (update.kind == 2) {
            if (!update.flag) {
                state.era_active = false;
                state.era_goods.clear();
                continue;
            }
            std::vector<EraProcurementLine> lines;
            lines.reserve(update.goods.size());
            for (size_t i = 0; i < update.goods.size(); ++i) {
                EraProcurementLine line;
                line.good = update.goods[i];
                line.required = update.quantities[i];
                for (const EraProcurementLine &old : state.era_goods)
                    if (old.good == line.good) line.purchased_total = old.purchased_total;
                lines.push_back(line);
            }
            state.era_active = true;
            state.era_goods.swap(lines);
        }
    }
}

NativeEconomyRuntime::CountryProcurementState *
NativeEconomyRuntime::procurement_state_for_slot(int32_t country) {
    if (country < 0 || country >= _epoch_country_count ||
        static_cast<size_t>(country) >= _epoch_country_handles.size()) return nullptr;
    const auto found = _country_procurement.find(
        _epoch_country_handles[static_cast<size_t>(country)]);
    return found == _country_procurement.end() ? nullptr : &found->second;
}

const NativeEconomyRuntime::CountryProcurementState *
NativeEconomyRuntime::procurement_state_for_slot(int32_t country) const {
    if (country < 0 || country >= _epoch_country_count ||
        static_cast<size_t>(country) >= _epoch_country_handles.size()) return nullptr;
    const auto found = _country_procurement.find(
        _epoch_country_handles[static_cast<size_t>(country)]);
    return found == _country_procurement.end() ? nullptr : &found->second;
}

bool NativeEconomyRuntime::research_procurement_policy_for(
        int32_t country, bool &enabled, int64_t &daily_budget,
        int64_t &remaining_points) const {
    if (_country_runtime == nullptr ||
        !_country_runtime->research_procurement_policy(
            country, enabled, daily_budget, remaining_points))
        return false;
    const CountryProcurementState *state = procurement_state_for_slot(country);
    if (state != nullptr && state->policy_enabled)
        daily_budget = std::max<int64_t>(0, state->research_daily);
    return true;
}

void NativeEconomyRuntime::freeze_epoch_procurement_budgets() {
    if (_country_procurement.empty() || _country_runtime == nullptr) return;
    const int64_t days = std::max(1, _epoch_days.get());
    // Roll per-epoch spend counters first so "last epoch" reads stay stable
    // for the whole following cycle.
    for (auto &entry : _country_procurement) {
        CountryProcurementState &state = entry.second;
        state.era_last_epoch_cash = state.era_cash_epoch;
        state.research_cash_last_epoch = state.research_cash_epoch;
        state.colonization_cash_last_epoch = state.colonization_cash_epoch;
        state.era_cash_epoch = 0;
        state.research_cash_epoch = 0;
        state.colonization_cash_epoch = 0;
        state.national_daily = 0;
        state.research_daily = 0;
        state.other_daily = 0;
        state.era_daily = 0;
        state.colonization_daily = 0;
    }
    std::vector<uint8_t> colonization_demand(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    for (int32_t i = 0; i < static_cast<int32_t>(family_expeditions_store().active.size()); ++i) {
        if (family_expeditions_store().active[i] == 0 ||
            family_expeditions_store().state[i] != EXPEDITION_PREPARING) continue;
        const uint64_t handle = family_expeditions_store().country_handle[i];
        const int32_t slot = static_cast<int32_t>(handle & 0xffffffffULL);
        if (slot >= 0 && slot < _epoch_country_count &&
            static_cast<size_t>(slot) < _epoch_country_handles.size() &&
            _epoch_country_handles[static_cast<size_t>(slot)] == handle)
            colonization_demand[static_cast<size_t>(slot)] = 1;
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        CountryProcurementState *state = procurement_state_for_slot(country);
        if (state == nullptr || !state->policy_enabled) continue;
        const int64_t cash = std::max<int64_t>(0, _country_runtime->cash_for_slot(country));
        state->national_daily = mul_div_sat(cash, state->treasury_share_bp, 10000,
                                            _saturation_count);
        bool research_enabled = false;
        int64_t ignored_daily = 0;
        int64_t research_remaining = 0;
        const bool research_demand = _country_runtime->research_procurement_policy(
                country, research_enabled, ignored_daily, research_remaining) &&
            research_enabled && research_remaining > 0;
        state->research_daily = research_demand
            ? mul_div_sat(state->national_daily, state->research_share_bp, 10000,
                          _saturation_count)
            : 0;
        state->other_daily = std::max<int64_t>(0, state->national_daily - state->research_daily);
        bool era_demand = false;
        if (state->era_active) {
            for (const EraProcurementLine &line : state->era_goods) {
                if (line.required > _country_runtime->good_for_slot(country, line.good)) {
                    era_demand = true;
                    break;
                }
            }
        }
        const bool colonization = colonization_demand[static_cast<size_t>(country)] != 0;
        if (era_demand && colonization) {
            state->era_daily = state->other_daily / 2;
            state->colonization_daily = state->other_daily - state->era_daily;
        } else if (era_demand) {
            state->era_daily = state->other_daily;
        } else if (colonization) {
            state->colonization_daily = state->other_daily;
        }
        (void)days;
    }
}

int64_t NativeEconomyRuntime::colonization_procurement_allowance(
        uint64_t country_handle, int64_t day) {
    const auto found = _country_procurement.find(country_handle);
    if (found == _country_procurement.end() || !found->second.policy_enabled)
        return -1;
    CountryProcurementState &state = found->second;
    const int64_t daily = std::max<int64_t>(0, state.colonization_daily);
    const int64_t cap = saturating_mul(daily, std::max(1, _epoch_days.get()),
                                       _saturation_count);
    if (day < 0) day = std::max<int64_t>(0, _current_day.get());
    if (state.colonization_allowance_day < 0) {
        state.colonization_allowance = daily;
    } else if (day > state.colonization_allowance_day) {
        state.colonization_allowance = saturating_add(state.colonization_allowance,
            saturating_mul(daily, day - state.colonization_allowance_day,
                           _saturation_count), _saturation_count);
    }
    state.colonization_allowance_day = std::max(state.colonization_allowance_day, day);
    state.colonization_allowance = std::min(state.colonization_allowance, cap);
    return state.colonization_allowance;
}

void NativeEconomyRuntime::consume_colonization_procurement_allowance(
        uint64_t country_handle, int64_t cash) {
    const auto found = _country_procurement.find(country_handle);
    if (found == _country_procurement.end() || cash <= 0) return;
    found->second.colonization_allowance =
        std::max<int64_t>(0, found->second.colonization_allowance - cash);
}

void NativeEconomyRuntime::note_procurement_cash(uint64_t country_handle,
                                                 int32_t kind, int64_t cash) {
    if (cash <= 0) return;
    const auto found = _country_procurement.find(country_handle);
    if (found == _country_procurement.end()) return;
    CountryProcurementState &state = found->second;
    int64_t *slot = kind == PROCUREMENT_CASH_RESEARCH ? &state.research_cash_epoch
        : kind == PROCUREMENT_CASH_ERA ? &state.era_cash_epoch
        : &state.colonization_cash_epoch;
    *slot = saturating_add(*slot, cash, _saturation_count);
    if (kind == PROCUREMENT_CASH_ERA)
        state.era_cash_spent_total = saturating_add(state.era_cash_spent_total, cash,
                                                    _saturation_count);
}

void NativeEconomyRuntime::note_trade_order_countries(int32_t source_cell,
                                                      int32_t destination_cell) {
    const auto bump = [&](int32_t cell) -> int32_t {
        if (cell < 0 || cell >= static_cast<int32_t>(_epoch_cell_country.size())) return -1;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count ||
            static_cast<size_t>(country) >= _epoch_country_handles.size()) return -1;
        const uint64_t handle = _epoch_country_handles[static_cast<size_t>(country)];
        if (_country_trade_orders_by_slot.size() <= static_cast<size_t>(country))
            _country_trade_orders_by_slot.resize(static_cast<size_t>(country) + 1, {0, 0});
        auto &entry = _country_trade_orders_by_slot[static_cast<size_t>(country)];
        if (entry.first != handle) entry = {handle, 0};
        if (entry.second < std::numeric_limits<int64_t>::max()) ++entry.second;
        return country;
    };
    const int32_t source_country = bump(source_cell);
    if (destination_cell < 0 || destination_cell >= static_cast<int32_t>(_epoch_cell_country.size()))
        return;
    const int32_t destination_country =
        _epoch_cell_country[static_cast<size_t>(destination_cell)];
    if (destination_country != source_country) bump(destination_cell);
}

// ── Era demand signals ───────────────────────────────────────────────────

void NativeEconomyRuntime::refresh_epoch_era_demand() {
    _epoch_era_demand_by_cell.clear();
    _epoch_era_demand_by_market.clear();
    if (_country_procurement.empty() || _country_runtime == nullptr ||
        market_store().market_count.get() <= 0) return;
    const bool cell_market_shape = market_store().cell_to_market.size() ==
        static_cast<size_t>(_cell_count.get());
    const int64_t days = std::max(1, _epoch_days.get());
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        const CountryProcurementState *state = procurement_state_for_slot(country);
        if (state == nullptr || !state->policy_enabled || !state->era_active ||
            state->era_daily <= 0) continue;
        int64_t budget = std::min(
            std::max<int64_t>(0, _country_runtime->cash_for_slot(country)),
            saturating_mul(state->era_daily, days, _saturation_count));
        for (const EraProcurementLine &line : state->era_goods) {
            if (budget <= 0) break;
            const int64_t remaining = std::max<int64_t>(0,
                line.required - _country_runtime->good_for_slot(country, line.good));
            if (remaining <= 0) continue;
            // Signal the cheapest in-territory market with a living merchant.
            int32_t best_cell = -1, best_market = -1;
            int64_t best_price = std::numeric_limits<int64_t>::max();
            for (const int32_t cell : _economy_live_cells) {
                if (cell < 0 || cell >= static_cast<int32_t>(_epoch_cell_country.size()) ||
                    _epoch_cell_country[static_cast<size_t>(cell)] != country) continue;
                const int32_t market = cell_market_shape
                    ? market_store().cell_to_market[static_cast<size_t>(cell)] : cell;
                if (market < 0 || market >= market_store().market_count.get() ||
                    !market_has_living_merchant(market)) continue;
                const int64_t price = std::max<int64_t>(1,
                    market_store().price[market_store().index(market, line.good)]);
                if (price < best_price) {
                    best_price = price; best_cell = cell; best_market = market;
                }
            }
            if (best_market < 0) continue;
            const int64_t affordable = std::min(remaining,
                mul_div_sat(budget, GOODS_SCALE, best_price, _saturation_count));
            if (affordable <= 0) continue;
            budget -= goods_cost(affordable, best_price, _saturation_count);
            _epoch_era_demand_by_cell.push_back(
                {era_procurement_key(best_cell, line.good), affordable});
            _epoch_era_demand_by_market.push_back(
                {era_procurement_key(best_market, line.good), affordable});
            ensure_market_signal_index(best_cell, line.good);
        }
    }
    auto merge = [&](auto &rows) {
        std::sort(rows.begin(), rows.end());
        size_t write = 0;
        for (size_t read = 0; read < rows.size(); ++read) {
            if (write > 0 && rows[write - 1].first == rows[read].first)
                rows[write - 1].second = saturating_add(
                    rows[write - 1].second, rows[read].second, _saturation_count);
            else rows[write++] = rows[read];
        }
        rows.resize(write);
    };
    merge(_epoch_era_demand_by_cell);
    merge(_epoch_era_demand_by_market);
}

// ── Era procurement pass (market -> treasury) ────────────────────────────

bool NativeEconomyRuntime::advance_era_procurement(EraProcurementContinuation &c,
                                                   std::string &error) {
    error.clear();
    if (!c.active) return true;
    if (c.phase == 1) {
        if (c.pending_request_id == 0 || _simulation_host == nullptr) {
            c.active = false;
            c.last_error = "era_procurement_peer_identity_missing";
            return true;
        }
        RuntimeEconomyAssetResult terminal;
        if (!_simulation_host->country_economy_asset_terminal_result(
                c.pending_request_id, terminal)) {
            return true; // still pending; caller parks the stage
        }
        if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
            terminal.operation != RuntimeEconomyAssetOperation::GOOD_FROM_MARKET) {
            c.last_error = terminal.reason[0] != '\0' ? terminal.reason.data()
                                                      : "era_procurement_peer_rejected";
            _simulation_host->acknowledge_country_economy_asset_consumed(c.pending_request_id);
            c.pending_request_id = 0;
            c.active = false;
            c.phase = 6;
            return true;
        }
        if (_simulation_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY)) {
            if (!_simulation_host->finish_worker_country_asset(
                    c.pending_request_id, terminal, error))
                return false;
        } else if (!_simulation_host->flush_country_economy_asset_commits(
                       error, c.pending_request_id) ||
                   !_simulation_host->publish_country_worker_snapshot(
                       RUNTIME_DIRTY_COUNTRY_STATE, error)) {
            return false;
        } else {
            _simulation_host->acknowledge_country_economy_asset_consumed(c.pending_request_id);
        }
        const int64_t committed_qty = terminal.committed_quantity > 0
            ? terminal.committed_quantity : c.quantity;
        const int64_t committed_cash = terminal.committed_cash > 0
            ? terminal.committed_cash : c.cash;
        if (committed_qty != c.quantity || committed_cash != c.cash) {
            error = "era_procurement_host_commit_quantity_drift";
            return false;
        }
        c.transaction_id = c.pending_request_id;
        c.pending_request_id = 0;
        c.host_peer = true;
        // The worker-side GOOD_FROM_MARKET service already removed the stock.
        c.market_applied = true;
        c.phase = 4;
    }
    if (c.phase == 4) {
        if (!c.market_applied) {
            const size_t lane = market_store().index(c.market, c.good);
            if (lane >= market_store().stock.size() ||
                market_store().stock[lane] < c.quantity) {
                error = "era_procurement_market_stock_drift";
                return false;
            }
            audit_touch_market_lane(lane);
            market_store().stock.write_scalar(lane,
                market_store().stock[lane] - c.quantity, market_mutation_sink());
            c.market_applied = true;
        }
        // Credit the local merchants with the frozen population weights.
        int64_t prefix = 0, distributed = 0;
        for (size_t index = 0; index < c.living_merchants.size(); ++index) {
            const int32_t slot = c.living_merchants[index];
            prefix = saturating_add(prefix, c.merchant_weights[index], _saturation_count);
            const int64_t next = mul_div_sat(c.cash, prefix, c.merchant_population,
                                             _saturation_count);
            const int64_t share = std::max<int64_t>(0, next - distributed);
            distributed = next;
            audit_touch_population_lane(slot);
            touch_accounting_slot(slot);
            population_store().funds.write_scalar(slot, saturating_add(
                population_store().funds[slot], share, _saturation_count),
                market_mutation_sink());
            population_store().epoch_income.write_scalar(slot, saturating_add(
                population_store().epoch_income[slot], share, _saturation_count),
                market_mutation_sink());
            trace_record_cashflow(c.market, population_store().handle_for_slot(slot),
                CASHFLOW_MERCHANT_BUSINESS, share, 0);
        }
        if (distributed != c.cash) {
            error = "era_procurement_merchant_distribution_drift";
            return false;
        }
        if (!c.host_peer) {
            const Dictionary applied = _country_runtime->acknowledge_economy_asset_peer_applied(
                c.transaction_id, c.session_epoch, c.country_generation,
                c.peer_generation, true, String());
            if (!static_cast<bool>(applied.get("ok", false)) ||
                String(applied.get("status_name", "")) != "completed") {
                error = "era_procurement_peer_apply_ack_failed";
                return false;
            }
        }
        c.phase = 5;
        c.active = false;
        return true;
    }
    error = "era_procurement_phase_invalid";
    return false;
}

bool NativeEconomyRuntime::run_government_era_procurement(std::string &error) {
    error.clear();
    if (_era_procurement_done) return true;
    if (_country_runtime == nullptr || !_country_runtime->economy_available() ||
        _country_procurement.empty()) {
        _era_procurement_done = true;
        return true;
    }
    constexpr size_t CANDIDATES_PER_SLICE = 32;
    if (!_era_procurement_initialized) {
        _era_procurement_initialized = true;
        _era_procurement_cursor = 0;
        _era_procurement_candidates.clear();
        const size_t countries = static_cast<size_t>(std::max(0, _epoch_country_count));
        _era_procurement_budgets.assign(countries, 0);
        _era_procurement_handles.assign(countries, 0);
        _era_procurement_line_offsets.assign(countries + 1, 0);
        _era_procurement_remaining.clear();
        const int64_t days = std::max(1, _epoch_days.get());
        bool any = false;
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const CountryProcurementState *state = procurement_state_for_slot(country);
            _era_procurement_line_offsets[static_cast<size_t>(country)] =
                static_cast<int32_t>(_era_procurement_remaining.size());
            if (state == nullptr || !state->policy_enabled || !state->era_active ||
                state->era_daily <= 0) continue;
            _era_procurement_handles[static_cast<size_t>(country)] = state->country_handle;
            _era_procurement_budgets[static_cast<size_t>(country)] = std::min(
                std::max<int64_t>(0, _country_runtime->cash_for_slot(country)),
                saturating_mul(state->era_daily, days, _saturation_count));
            for (const EraProcurementLine &line : state->era_goods) {
                const int64_t remaining = std::max<int64_t>(0,
                    line.required - _country_runtime->good_for_slot(country, line.good));
                _era_procurement_remaining.push_back(remaining);
                if (remaining > 0) any = true;
            }
        }
        _era_procurement_line_offsets[countries] =
            static_cast<int32_t>(_era_procurement_remaining.size());
        if (!any) {
            _era_procurement_done = true;
            return true;
        }
        const bool cell_market_shape = market_store().cell_to_market.size() ==
            static_cast<size_t>(_cell_count.get());
        for (const int32_t market : _epoch_market_ids) {
            if (market < 0 || market >= _cell_count.get() ||
                market >= static_cast<int32_t>(_epoch_cell_country.size()) ||
                !market_has_living_merchant(market)) continue;
            // One cell is one local market; the market id is its cell.
            if (cell_market_shape &&
                market_store().cell_to_market[static_cast<size_t>(market)] != market) continue;
            const int32_t country = _epoch_cell_country[static_cast<size_t>(market)];
            if (country < 0 || country >= _epoch_country_count ||
                _era_procurement_budgets[static_cast<size_t>(country)] <= 0) continue;
            const CountryProcurementState *state = procurement_state_for_slot(country);
            if (state == nullptr) continue;
            const int32_t base = _era_procurement_line_offsets[static_cast<size_t>(country)];
            for (int32_t line = 0; line < static_cast<int32_t>(state->era_goods.size()); ++line) {
                if (_era_procurement_remaining[static_cast<size_t>(base + line)] <= 0) continue;
                const int32_t good = state->era_goods[static_cast<size_t>(line)].good;
                const size_t index = market_store().index(market, good);
                if (index >= market_store().stock.size() || market_store().stock[index] <= 0)
                    continue;
                _era_procurement_candidates.push_back({country, line, good, market,
                    market_store().price[index]});
            }
        }
        std::stable_sort(_era_procurement_candidates.begin(), _era_procurement_candidates.end(),
            [](const EraProcurementCandidate &a, const EraProcurementCandidate &b) {
                return std::tie(a.country, a.line, a.price, a.market) <
                    std::tie(b.country, b.line, b.price, b.market);
            });
    }

    EraProcurementContinuation &c = _era_procurement_continuation;
    const auto settle = [&]() {
        const size_t country = static_cast<size_t>(c.country);
        if (c.phase == 5) {
            const int32_t base = _era_procurement_line_offsets[country];
            int64_t &remaining = _era_procurement_remaining[static_cast<size_t>(base + c.line)];
            remaining = std::max<int64_t>(0, remaining - c.quantity);
            _era_procurement_budgets[country] =
                std::max<int64_t>(0, _era_procurement_budgets[country] - c.cash);
            const uint64_t handle = _era_procurement_handles[country];
            auto found = _country_procurement.find(handle);
            if (found != _country_procurement.end()) {
                for (EraProcurementLine &line : found->second.era_goods)
                    if (line.good == c.good)
                        line.purchased_total = saturating_add(line.purchased_total,
                            c.quantity, _saturation_count);
            }
            note_procurement_cash(handle, PROCUREMENT_CASH_ERA, c.cash);
            note_non_tax_outflow(handle, NON_TAX_ERA_PROCUREMENT, c.cash);
            // Non-household demand event, same channel as expedition cargo.
            const int32_t signal = ensure_market_signal_index(c.market, c.good);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_nonhousehold_withdrawals.size())) {
                _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                    _epoch_nonhousehold_withdrawals[signal], c.quantity, _saturation_count);
                const int64_t daily = c.quantity / std::max(1, _epoch_days.get());
                _market_signals.business_demand_ema.write_scalar(signal, saturating_add(
                    _market_signals.business_demand_ema[signal], daily,
                    _saturation_count), market_mutation_sink());
                _market_signals.realized_withdrawal_ema.write_scalar(signal, saturating_add(
                    _market_signals.realized_withdrawal_ema[signal], daily,
                    _saturation_count), market_mutation_sink());
            }
            ++_era_procurement_orders;
        } else {
            ++_era_procurement_rejections;
        }
        ++_era_procurement_cursor;
        c = EraProcurementContinuation{};
    };

    if (c.active) {
        if (!advance_era_procurement(c, error)) return false;
        if (c.active) return true;
        settle();
        return true;
    }

    const size_t end = std::min(_era_procurement_candidates.size(),
                                _era_procurement_cursor + CANDIDATES_PER_SLICE);
    while (_era_procurement_cursor < end) {
        const EraProcurementCandidate candidate =
            _era_procurement_candidates[_era_procurement_cursor];
        const size_t country = static_cast<size_t>(candidate.country);
        const int32_t base = _era_procurement_line_offsets[country];
        const int64_t remaining = _era_procurement_remaining[static_cast<size_t>(base + candidate.line)];
        const int64_t budget = std::min(_era_procurement_budgets[country],
            std::max<int64_t>(0, _country_runtime->cash_for_slot(candidate.country)));
        const size_t index = market_store().index(candidate.market, candidate.good);
        const int64_t price = index < market_store().price.size()
            ? market_store().price[index] : 0;
        if (remaining <= 0 || budget <= 0 || price <= 0 ||
            index >= market_store().stock.size()) {
            ++_era_procurement_cursor;
            continue;
        }
        const int64_t quantity = std::min({market_store().stock[index], remaining,
            mul_div_sat(budget, GOODS_SCALE, price, _saturation_count)});
        const int64_t cash = quantity > 0 ? goods_cost(quantity, price, _saturation_count) : 0;
        if (quantity <= 0 || cash <= 0 || cash > budget) {
            ++_era_procurement_cursor;
            continue;
        }
        c = EraProcurementContinuation{};
        c.active = true;
        c.phase = 1;
        c.country = candidate.country;
        c.line = candidate.line;
        c.market = candidate.market;
        c.good = candidate.good;
        c.quantity = quantity;
        c.cash = cash;
        if (_merchant_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t edge = _merchant_offsets[candidate.market];
                 edge < _merchant_offsets[candidate.market + 1]; ++edge) {
                const int32_t slot = _merchant_slots[edge];
                if (is_merchant_slot(slot) && slot >= 0 &&
                    slot < static_cast<int32_t>(population_store().population.size()) &&
                    population_store().population[slot] > 0)
                    c.living_merchants.push_back(slot);
            }
        }
        for (const int32_t slot : c.living_merchants) {
            c.merchant_weights.push_back(population_store().population[slot]);
            c.merchant_population = saturating_add(c.merchant_population,
                population_store().population[slot], _saturation_count);
        }
        if (c.merchant_population <= 0) {
            c.phase = 6;
            c.active = false;
            settle();
            continue;
        }
        const uint64_t handle = _era_procurement_handles[country];
        const std::vector<int32_t> ids{candidate.good};
        const std::vector<int64_t> goods{quantity};
        std::string route_error;
        const CountryWorkerAssetRoute route = block_or_enqueue_country_worker_asset(
            static_cast<uint16_t>(NativeCountryRuntime::ECONOMY_ASSET_GOOD_FROM_MARKET),
            static_cast<int64_t>(handle), cash, quantity, ids, goods, route_error,
            &c.pending_request_id, candidate.market);
        if (route == CountryWorkerAssetRoute::ENQUEUED_PENDING) {
            // Do NOT mark this request as self-settled (deferred). Deferral is
            // for continuations that settle outside the epoch (family
            // expedition preparation at the idle boundary). Inside the epoch a
            // deferred request keeps country_authority_drain_idle_locked()
            // false, so the Country worker never finishes the day that would
            // commit it, the generic flush never sweeps it, and the stage
            // parks on era_asset_peer_pending until the fiscal-peer stall
            // timeout. The research purchase in the same stage polls the
            // terminal instead, and so does this one (see phase 1).
            c.host_peer = true;
            return true; // parked until the Country worker prepares/commits
        }
        if (route != CountryWorkerAssetRoute::NOT_APPLICABLE) {
            c.last_error = route_error;
            c.phase = 6;
            c.active = false;
            settle();
            continue;
        }
        const Dictionary begun = _country_runtime->begin_economy_good_from_market(
            static_cast<int64_t>(handle), candidate.good, quantity, _epoch_id.get(),
            static_cast<int32_t>(_stage), 0, cash);
        if (!static_cast<bool>(begun.get("ok", false))) {
            c.phase = 6;
            c.active = false;
            settle();
            continue;
        }
        c.transaction_id = static_cast<uint64_t>(static_cast<int64_t>(begun.get("transaction_id", 0)));
        c.session_epoch = static_cast<uint64_t>(static_cast<int64_t>(begun.get("session_epoch", 0)));
        c.country_generation = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("country_generation", 0)));
        c.peer_generation = _committed_generation;
        if (static_cast<int64_t>(begun.get("prepared_quantity", 0)) != quantity) {
            _country_runtime->acknowledge_economy_asset_peer_prepared(
                c.transaction_id, c.session_epoch, c.country_generation,
                c.peer_generation, false, String("era_procurement_quantity_drift"));
            c.phase = 6;
            c.active = false;
            settle();
            continue;
        }
        const Dictionary prepared = _country_runtime->acknowledge_economy_asset_peer_prepared(
            c.transaction_id, c.session_epoch, c.country_generation,
            c.peer_generation, true, String());
        if (!static_cast<bool>(prepared.get("ok", false))) {
            error = "era_procurement_peer_prepare_failed";
            return false;
        }
        const Dictionary committed = _country_runtime->commit_economy_asset_transaction(
            c.transaction_id);
        if (!static_cast<bool>(committed.get("ok", false)) ||
            static_cast<int64_t>(committed.get("committed_quantity", 0)) != quantity ||
            static_cast<int64_t>(committed.get("committed_cash", cash)) != cash) {
            error = "era_procurement_peer_commit_failed";
            return false;
        }
        c.host_peer = false;
        c.market_applied = false;
        c.phase = 4;
        if (!advance_era_procurement(c, error)) return false;
        settle();
    }
    if (_era_procurement_cursor >= _era_procurement_candidates.size())
        _era_procurement_done = true;
    return true;
}

// ── Query ────────────────────────────────────────────────────────────────

Dictionary NativeEconomyRuntime::country_procurement_snapshot(int64_t country_handle) const {
    Dictionary out;
    if (_country_runtime == nullptr || !_country_runtime->valid_handle(country_handle)) {
        out["ok"] = false;
        out["code"] = "procurement_country_invalid";
        return out;
    }
    const uint64_t handle = static_cast<uint64_t>(country_handle);
    const int32_t slot = static_cast<int32_t>(handle & 0xffffffffULL);
    const auto found = _country_procurement.find(handle);
    const CountryProcurementState *state =
        found == _country_procurement.end() ? nullptr : &found->second;
    bool policy_enabled = state != nullptr && state->policy_enabled;
    int32_t treasury_bp = state != nullptr ? state->treasury_share_bp : 0;
    int32_t research_bp = state != nullptr ? state->research_share_bp : 0;
    bool era_active = state != nullptr && state->era_active;
    std::vector<EraProcurementLine> lines = state != nullptr
        ? state->era_goods : std::vector<EraProcurementLine>{};
    bool policy_pending = false, era_pending = false;
    {
        // Requested-but-not-yet-applied configuration is shown immediately so
        // a UI slider does not snap back until the next economy epoch.
        std::lock_guard<std::mutex> lock(_procurement_inbox->mutex);
        for (const PendingProcurementUpdate &update : _procurement_inbox->updates) {
            if (update.country_handle != handle) continue;
            if (update.kind == 1) {
                policy_pending = true;
                policy_enabled = update.flag;
                treasury_bp = update.treasury_share_bp;
                research_bp = update.research_share_bp;
            } else if (update.kind == 2) {
                era_pending = true;
                era_active = update.flag;
                std::vector<EraProcurementLine> next;
                if (update.flag) {
                    for (size_t i = 0; i < update.goods.size(); ++i) {
                        EraProcurementLine line;
                        line.good = update.goods[i];
                        line.required = update.quantities[i];
                        for (const EraProcurementLine &old : lines)
                            if (old.good == line.good) line.purchased_total = old.purchased_total;
                        next.push_back(line);
                    }
                }
                lines.swap(next);
            }
        }
    }
    out["ok"] = true;
    out["policy_enabled"] = policy_enabled;
    out["policy_pending"] = policy_pending;
    out["treasury_share_bp"] = treasury_bp;
    out["research_share_bp"] = research_bp;
    // Frozen epoch values when available; otherwise a live preview from cash.
    int64_t national = 0, research = 0, other = 0, era_daily = 0, colonization = 0;
    if (state != nullptr && state->policy_enabled && !policy_pending) {
        national = state->national_daily;
        research = state->research_daily;
        other = state->other_daily;
        era_daily = state->era_daily;
        colonization = state->colonization_daily;
    } else if (policy_enabled) {
        int64_t sat = 0;
        const int64_t cash = std::max<int64_t>(0, _country_runtime->cash_for_slot(slot));
        national = mul_div_sat(cash, clamp_bp(treasury_bp), 10000, sat);
        research = mul_div_sat(national, clamp_bp(research_bp), 10000, sat);
        other = national - research;
        era_daily = era_active ? other : 0;
    }
    out["national_daily_budget"] = national;
    out["research_daily_budget"] = research;
    out["other_daily_budget"] = other;
    out["era_active"] = era_active;
    out["era_pending"] = era_pending;
    out["era_daily_budget"] = era_daily;
    out["colonization_daily_budget"] = colonization;
    Array goods;
    for (const EraProcurementLine &line : lines) {
        Dictionary row;
        const int64_t stock = _country_runtime->good_for_slot(slot, line.good);
        row["good_index"] = line.good;
        row["required"] = line.required;
        row["treasury_stock"] = stock;
        row["remaining"] = std::max<int64_t>(0, line.required - stock);
        row["purchased_total"] = line.purchased_total;
        goods.push_back(row);
    }
    out["era_goods"] = goods;
    out["era_cash_spent_total"] = state != nullptr ? state->era_cash_spent_total : 0;
    out["era_last_epoch_cash"] = state != nullptr ? state->era_last_epoch_cash : 0;
    out["era_current_epoch_cash"] = state != nullptr ? state->era_cash_epoch : 0;
    out["research_cash_spent_last_epoch"] =
        state != nullptr ? state->research_cash_last_epoch : 0;
    out["colonization_cash_spent_last_epoch"] =
        state != nullptr ? state->colonization_cash_last_epoch : 0;
    int64_t trade_orders = 0;
    if (slot >= 0 && static_cast<size_t>(slot) < _country_trade_orders_by_slot.size() &&
        _country_trade_orders_by_slot[static_cast<size_t>(slot)].first == handle)
        trade_orders = _country_trade_orders_by_slot[static_cast<size_t>(slot)].second;
    out["trade_orders_total"] = trade_orders;
    return out;
}

} // namespace pk

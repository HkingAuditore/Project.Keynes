#include "economy_cost_probe.h"
#include "economy_runtime_variant_helpers.h"
#include "runtime_economy_pod.h"
#include "runtime_switch_registry.h"
#include <cmath>
#include <chrono>
#include <cstring>
#include <numeric>
// National procurement budget + era advancement procurement.
//
// Contract: docs/cpp-dots-runtime/era-advancement-runtime.md §2.2-2.4.
// Everything in this file is transient: no PKEC field, no state-hash input.
// Setters run on any thread and only append to a mutex-guarded inbox; the
// Economy owner thread folds the inbox at the next epoch begin so a policy
// change never leaks into an already-frozen economy cycle.
#include "economy_runtime.h"
#include "country_api.h"
#include "economy_host_port.h"

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
        int32_t research_share_bp, int64_t effective_day, int64_t sequence,
        int32_t era_share_bp, int32_t colonization_share_bp) {
    Dictionary out;
    if (_country_runtime == nullptr || !country_reads().valid_handle(country_handle)) {
        out["ok"] = false;
        out["code"] = "procurement_country_invalid";
        return out;
    }
    if (treasury_share_bp < 0 || treasury_share_bp > 10000 ||
        research_share_bp < 0 || research_share_bp > 10000 ||
        era_share_bp < -1 || era_share_bp > 10000 ||
        colonization_share_bp < -1 || colonization_share_bp > 10000) {
        out["ok"] = false;
        out["code"] = "procurement_share_invalid";
        return out;
    }
    // -1 means "keep the legacy split", so only positive shares compete for
    // the 100% envelope. Anything above it is rejected instead of silently
    // normalized: an over-allocated policy must fail loudly at the boundary.
    int64_t allocated = static_cast<int64_t>(clamp_bp(research_share_bp)) +
        std::max<int32_t>(0, era_share_bp) +
        std::max<int32_t>(0, colonization_share_bp);
    if (allocated > 10000) {
        out["ok"] = false;
        out["code"] = "procurement_share_over_allocated";
        out["allocated_bp"] = allocated;
        return out;
    }
    PendingProcurementUpdate update;
    update.kind = 1;
    update.country_handle = static_cast<uint64_t>(country_handle);
    update.flag = enabled;
    update.treasury_share_bp = treasury_share_bp;
    update.research_share_bp = research_share_bp;
    // -1 is forwarded on purpose: apply_pending_procurement_updates keeps the
    // previously stored channel share in that case.
    update.era_share_bp = era_share_bp;
    update.colonization_share_bp = colonization_share_bp;
    update.effective_day = std::max<int64_t>(0, effective_day);
    update.sequence = sequence;
    {
        std::lock_guard<std::mutex> lock(_procurement_inbox->mutex);
        update.order = _procurement_inbox->next_order++;
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
    if (_country_runtime == nullptr || !country_reads().valid_handle(country_handle)) {
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
    _epoch_research_daily.clear();
    _country_trade_orders_by_slot.clear();
    reset_era_procurement_epoch();
    _epoch_era_demand_by_cell.clear();
    _epoch_era_demand_by_market.clear();
    if (clear_pending) {
        std::lock_guard<std::mutex> lock(_procurement_inbox->mutex);
        _procurement_inbox->updates.clear();
        _procurement_inbox->next_order = 1;
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
            !country_reads().valid_handle(static_cast<int64_t>(update.country_handle)))
            continue;
        EconomyProcurementState &state = _country_procurement[update.country_handle];
        state.country_handle = update.country_handle;
        if (update.kind == 1) {
            state.policy_enabled = update.flag;
            state.treasury_share_bp = clamp_bp(update.treasury_share_bp);
            state.research_share_bp = clamp_bp(update.research_share_bp);
            // -1 keeps the legacy split (or whatever was stored before), so a
            // treasury-page submit never clears the fiscal-page channels.
            if (update.era_share_bp >= 0) state.era_share_bp = clamp_bp(update.era_share_bp);
            if (update.colonization_share_bp >= 0)
                state.colonization_share_bp = clamp_bp(update.colonization_share_bp);
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

NativeEconomyRuntime::EconomyProcurementState *
NativeEconomyRuntime::procurement_state_for_slot(int32_t country) {
    if (country < 0 || country >= _epoch_country_count ||
        static_cast<size_t>(country) >= _epoch_country_handles.size()) return nullptr;
    const auto found = _country_procurement.find(
        _epoch_country_handles[static_cast<size_t>(country)]);
    return found == _country_procurement.end() ? nullptr : &found->second;
}

const NativeEconomyRuntime::EconomyProcurementState *
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
    daily_budget = 0;
    if (_country_runtime == nullptr ||
        !country_reads().research_procurement_policy(country, enabled, remaining_points))
        return false;
    if (country >= 0 && static_cast<size_t>(country) < _epoch_research_daily.size())
        daily_budget = _epoch_research_daily[static_cast<size_t>(country)];
    return true;
}

void NativeEconomyRuntime::freeze_epoch_procurement_budgets() {
    _epoch_research_daily.assign(static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    if (_country_runtime == nullptr) return;
    const int64_t days = std::max(1, _epoch_days.get());
    // Roll per-epoch spend counters first so "last epoch" reads stay stable
    // for the whole following cycle.
    for (auto &entry : _country_procurement) {
        EconomyProcurementState &state = entry.second;
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
    mark_country_ai_colonization_demand(colonization_demand);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        EconomyProcurementState *state = procurement_state_for_slot(country);
        if (state != nullptr && !state->policy_enabled) continue;
        const int64_t cash = std::max<int64_t>(0, country_reads().cash_for_slot(country));
        bool research_enabled = false;
        int64_t research_remaining = 0;
        const bool research_demand = country_reads().research_procurement_policy(
                country, research_enabled, research_remaining) &&
            research_enabled && research_remaining > 0;
        if (state == nullptr) {
            // No policy was ever sent (AI off, scripted countries): research
            // at the profile default shares; the other channels stay legacy.
            if (research_demand)
                _epoch_research_daily[static_cast<size_t>(country)] = mul_div_sat(
                    mul_div_sat(cash, _procurement_default_treasury_share_bp, 10000,
                                _saturation_count),
                    _procurement_default_research_share_bp, 10000, _saturation_count);
            continue;
        }
        state->national_daily = mul_div_sat(cash, state->treasury_share_bp, 10000,
                                            _saturation_count);
        state->research_daily = research_demand
            ? mul_div_sat(state->national_daily, state->research_share_bp, 10000,
                          _saturation_count)
            : 0;
        _epoch_research_daily[static_cast<size_t>(country)] = state->research_daily;
        state->other_daily = std::max<int64_t>(0, state->national_daily - state->research_daily);
        bool era_demand = false;
        if (state->era_active) {
            for (const EraProcurementLine &line : state->era_goods) {
                if (line.required > country_reads().good_for_slot(country, line.good)) {
                    era_demand = true;
                    break;
                }
            }
        }
        const bool colonization = colonization_demand[static_cast<size_t>(country)] != 0;
        // Share-based split of national_daily. All three shares (research, era,
        // colonization) are percentages of the same national budget, which is
        // what makes "the three shares sum to <= 100%" a real constraint.
        // A channel share of -1 means the player never touched it, so the
        // legacy allocation is kept: 50/50 when both channels demand cash, all
        // of it to the only demander. Any unallocated remainder stays in the
        // treasury.
        const bool era_share_set = state->era_share_bp >= 0;
        const bool colonization_share_set = state->colonization_share_bp >= 0;
        int64_t era_daily = 0;
        int64_t colonization_daily = 0;
        if (!era_share_set && !colonization_share_set) {
            if (era_demand && colonization) {
                era_daily = state->other_daily / 2;
                colonization_daily = state->other_daily - era_daily;
            } else if (era_demand) {
                era_daily = state->other_daily;
            } else if (colonization) {
                colonization_daily = state->other_daily;
            }
        } else {
            if (era_share_set && era_demand)
                era_daily = mul_div_sat(state->national_daily, clamp_bp(state->era_share_bp),
                                        10000, _saturation_count);
            if (colonization_share_set && colonization)
                colonization_daily = mul_div_sat(state->national_daily,
                    clamp_bp(state->colonization_share_bp), 10000, _saturation_count);
            // An unspecified channel keeps the legacy "whatever is left of the
            // other_daily pool" rule so an old treasury-page submit never
            // starves colonization.
            if (!era_share_set && era_demand)
                era_daily = std::max<int64_t>(0, state->other_daily - colonization_daily);
            if (!colonization_share_set && colonization)
                colonization_daily = std::max<int64_t>(0, state->other_daily - era_daily);
        }
        state->era_daily = era_daily;
        state->colonization_daily = colonization_daily;
        (void)days;
    }
}

void NativeEconomyRuntime::ensure_epoch_colonization_budget(
        uint64_t country_handle) {
    const auto found = _country_procurement.find(country_handle);
    if (found == _country_procurement.end()) return;
    EconomyProcurementState &state = found->second;
    // A party created after the epoch boundary never entered the demand scan,
    // so the freeze left `colonization_daily` at zero and every purchase would
    // be judged over budget for the whole epoch. Recover the same split the
    // freeze would have produced for a country that already had demand.
    if (!state.policy_enabled || state.colonization_daily > 0 ||
        state.national_daily <= 0) return;
    int64_t daily = 0;
    if (state.colonization_share_bp >= 0) {
        daily = mul_div_sat(state.national_daily,
            clamp_bp(state.colonization_share_bp), 10000, _saturation_count);
    } else {
        // Legacy split: the channel that never set a share takes whatever the
        // other pool (national minus research minus era) has left.
        daily = std::max<int64_t>(0, state.other_daily - state.era_daily);
    }
    if (daily <= 0) return;
    state.colonization_daily = daily;
    // The channel now exists for this epoch: hand out today's refill instead of
    // waiting for the next day boundary.
    state.colonization_allowance = std::max(state.colonization_allowance, daily);
}

int64_t NativeEconomyRuntime::colonization_procurement_allowance(
        uint64_t country_handle, int64_t day) {
    const auto found = _country_procurement.find(country_handle);
    if (found == _country_procurement.end() || !found->second.policy_enabled)
        return -1;
    EconomyProcurementState &state = found->second;
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
    EconomyProcurementState &state = found->second;
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

#include "economy_runtime_procurement_section_era.inc"

// ── Query ────────────────────────────────────────────────────────────────

Dictionary NativeEconomyRuntime::country_procurement_snapshot(int64_t country_handle) const {
    Dictionary out;
    if (_country_runtime == nullptr || !country_reads().valid_handle(country_handle)) {
        out["ok"] = false;
        out["code"] = "procurement_country_invalid";
        return out;
    }
    const uint64_t handle = static_cast<uint64_t>(country_handle);
    const int32_t slot = static_cast<int32_t>(handle & 0xffffffffULL);
    const auto found = _country_procurement.find(handle);
    const EconomyProcurementState *state =
        found == _country_procurement.end() ? nullptr : &found->second;
    bool policy_enabled = state != nullptr && state->policy_enabled;
    int32_t treasury_bp = state != nullptr ? state->treasury_share_bp : 0;
    int32_t research_bp = state != nullptr ? state->research_share_bp : 0;
    int32_t era_bp = state != nullptr ? state->era_share_bp : -1;
    int32_t colonization_bp = state != nullptr ? state->colonization_share_bp : -1;
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
                if (update.era_share_bp >= 0) era_bp = update.era_share_bp;
                if (update.colonization_share_bp >= 0)
                    colonization_bp = update.colonization_share_bp;
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
    // A country that never sent a policy researches at the profile defaults.
    const bool policy_default = state == nullptr && !policy_pending;
    if (policy_default) {
        treasury_bp = _procurement_default_treasury_share_bp;
        research_bp = _procurement_default_research_share_bp;
    }
    out["ok"] = true;
    out["policy_enabled"] = policy_enabled;
    out["policy_default"] = policy_default;
    out["policy_pending"] = policy_pending;
    out["treasury_share_bp"] = treasury_bp;
    out["research_share_bp"] = research_bp;
    out["era_share_bp"] = era_bp;
    out["colonization_share_bp"] = colonization_bp;
    // Frozen epoch values when available; otherwise a live preview from cash.
    int64_t national = 0, research = 0, other = 0, era_daily = 0, colonization = 0;
    if (state != nullptr && state->policy_enabled && !policy_pending) {
        national = state->national_daily;
        research = state->research_daily;
        other = state->other_daily;
        era_daily = state->era_daily;
        colonization = state->colonization_daily;
    } else if (policy_default) {
        if (slot >= 0 && static_cast<size_t>(slot) < _epoch_research_daily.size())
            research = _epoch_research_daily[static_cast<size_t>(slot)];
    } else if (policy_enabled) {
        int64_t sat = 0;
        const int64_t cash = std::max<int64_t>(0, country_reads().cash_for_slot(slot));
        national = mul_div_sat(cash, clamp_bp(treasury_bp), 10000, sat);
        research = mul_div_sat(national, clamp_bp(research_bp), 10000, sat);
        other = national - research;
        // Same split rule as the frozen path so the preview does not jump when
        // the epoch lands: all three shares are percentages of national_daily.
        const bool era_share_set = era_bp >= 0;
        const bool colonization_share_set = colonization_bp >= 0;
        if (!era_share_set && !colonization_share_set) {
            era_daily = era_active ? other : 0;
        } else {
            if (era_share_set && era_active)
                era_daily = mul_div_sat(national, clamp_bp(era_bp), 10000, sat);
            if (colonization_share_set)
                colonization = mul_div_sat(national, clamp_bp(colonization_bp), 10000, sat);
            if (!era_share_set)
                era_daily = std::max<int64_t>(0, other - colonization);
            if (!colonization_share_set)
                colonization = std::max<int64_t>(0, other - era_daily);
        }
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
        const int64_t stock = country_reads().good_for_slot(slot, line.good);
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

#include "economy_runtime_procurement_section_research_planning.inc"

#include "economy_runtime_procurement_section_research_execution.inc"

} // namespace pk

#include "economy_runtime_colonization_kit_includes.inc"

namespace pk {

namespace {
uint64_t procurement_key(int32_t place, int32_t good) {
    return (static_cast<uint64_t>(static_cast<uint32_t>(place)) << 32U) |
        static_cast<uint32_t>(good);
}
int64_t procurement_quantity(
        const std::vector<std::pair<uint64_t, int64_t>> &rows,
        int32_t place, int32_t good) {
    if (place < 0 || good < 0) return 0;
    const uint64_t key = procurement_key(place, good);
    const auto row = std::lower_bound(rows.begin(), rows.end(), key,
        [](const auto &entry, uint64_t value) { return entry.first < value; });
    return row != rows.end() && row->first == key ? row->second : 0;
}
}

int64_t NativeEconomyRuntime::epoch_colonization_demand(
        int32_t cell, int32_t good) const {
    return procurement_quantity(_epoch_colonization_demand_by_cell, cell, good);
}

int64_t NativeEconomyRuntime::epoch_colonization_demand_daily(
        int32_t cell, int32_t good) const {
    const int64_t quantity = epoch_colonization_demand(cell, good);
    if (quantity <= 0 || good >= static_cast<int32_t>(_good_target_inventory_days_q16.size()))
        return 0;
    const int64_t days = std::max<int64_t>(std::max(1, _epoch_days.get()),
        (static_cast<int64_t>(_good_target_inventory_days_q16[good]) + Q16_ONE - 1) / Q16_ONE);
    return quantity / days + (quantity % days != 0);
}

int64_t NativeEconomyRuntime::epoch_procurement_demand_daily(
        int32_t cell, int32_t good) const {
    int64_t sat = 0;
    int64_t era_daily = 0;
    const int64_t era = procurement_quantity(_epoch_era_demand_by_cell, cell, good);
    if (era > 0) {
        const int64_t days = std::max(1, _epoch_days.get());
        era_daily = era / days + (era % days != 0);
    }
    return saturating_add(saturating_add(saturating_add(epoch_research_demand_daily(cell, good),
        epoch_colonization_demand_daily(cell, good), sat), era_daily, sat), epoch_military_demand_daily(cell, good), sat);
}

int64_t NativeEconomyRuntime::epoch_procurement_demand_daily_for_market(
        int32_t market, int32_t good) const {
    int64_t sat = 0;
    const int64_t quantity = procurement_quantity(
        _epoch_colonization_demand_by_market, market, good);
    int64_t daily = 0;
    if (quantity > 0 && good >= 0 &&
        good < static_cast<int32_t>(_good_target_inventory_days_q16.size())) {
        const int64_t days = std::max<int64_t>(std::max(1, _epoch_days.get()),
            (static_cast<int64_t>(_good_target_inventory_days_q16[good]) + Q16_ONE - 1) / Q16_ONE);
        daily = quantity / days + (quantity % days != 0);
    }
    const int64_t era = procurement_quantity(_epoch_era_demand_by_market, market, good);
    if (era > 0) {
        const int64_t days = std::max(1, _epoch_days.get());
        daily = saturating_add(daily, era / days + (era % days != 0), sat);
    }
    return saturating_add(saturating_add(epoch_research_demand_daily_for_market(market, good), daily, sat), epoch_military_demand_daily_for_market(market, good), sat);
}

void NativeEconomyRuntime::refresh_epoch_colonization_demand() {
    _epoch_colonization_demand_by_cell.clear();
    _epoch_colonization_demand_by_market.clear();
    if (_country_runtime == nullptr || !country_reads().economy_available()) return;
    std::vector<int32_t> preparing;
    for (int32_t i = 0; i < static_cast<int32_t>(family_expeditions_store().active.size()); ++i)
        if (family_expeditions_store().active[i] != 0 &&
            family_expeditions_store().state[i] == EXPEDITION_PREPARING)
            preparing.push_back(i);
    if (preparing.empty()) return;
    std::sort(preparing.begin(), preparing.end(), [&](int32_t a, int32_t b) {
        return std::pair(family_expeditions_store().country_handle[a],
                         family_expeditions_store().stable_id[a]) <
               std::pair(family_expeditions_store().country_handle[b],
                         family_expeditions_store().stable_id[b]);
    });
    std::vector<int64_t> budgets(static_cast<size_t>(_epoch_country_count), 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        const int64_t cash = std::max<int64_t>(0, country_reads().cash_for_slot(country));
        bool enabled = false;
        int64_t daily = 0, remaining = 0;
        research_procurement_policy_for(country, enabled, daily, remaining);
        const int64_t research_budget = enabled && remaining > 0
            ? std::min(cash, saturating_mul(std::max<int64_t>(0, daily),
                std::max(1, _epoch_days.get()), _saturation_count)) : 0;
        budgets[country] = cash - research_budget;
        // National procurement policy: colonization reserve is capped by its
        // share of the national budget for this epoch.
        if (const EconomyProcurementState *policy = procurement_state_for_slot(country);
            policy != nullptr && policy->policy_enabled) {
            budgets[country] = std::min(budgets[country], saturating_mul(
                std::max<int64_t>(0, policy->colonization_daily),
                std::max(1, _epoch_days.get()), _saturation_count));
        }
    }
    const auto &pending_purchase = _family_expedition_procurement_continuation;
    if (pending_purchase.active && pending_purchase.phase == 1 &&
        pending_purchase.expedition >= 0 && pending_purchase.expedition <
            static_cast<int32_t>(family_expeditions_store().active.size()) &&
        family_expeditions_store().active[pending_purchase.expedition] != 0) {
        const int32_t country = static_cast<int32_t>(
            family_expeditions_store().country_handle[pending_purchase.expedition] & 0xffffffffU);
        if (country >= 0 && country < _epoch_country_count)
            budgets[country] = std::max<int64_t>(0, budgets[country] - pending_purchase.cash);
    }
    for (const int32_t expedition : preparing) {
        const int32_t source = family_expeditions_store().source_cell[expedition];
        const int32_t target = family_expeditions_store().target_cell[expedition];
        const int64_t country_handle = family_expeditions_store().country_handle[expedition];
        const int32_t country = static_cast<int32_t>(static_cast<uint64_t>(country_handle) & 0xffffffffU);
        if (source < 0 || source >= _cell_count.get() ||
            country < 0 || country >= _epoch_country_count || budgets[country] <= 0 ||
            !country_reads().valid_handle(country_handle) ||
            _epoch_cell_country[source] != country ||
            !colonization_target_owner_allowed(country_handle, target) ||
            family_population_in_cell(family_expeditions_store().family_handle[expedition], source) <=
                family_expeditions_store().population[expedition]) continue;
        const int32_t market = market_store().cell_to_market[source];
        if (market < 0 || market >= market_store().market_count.get()) continue;
        std::vector<int64_t> held;
        collect_family_expedition_reserved_stock(expedition, held);
        const auto &pending = _family_expedition_procurement_continuation;
        if (pending.active && pending.expedition == expedition && pending.good >= 0 &&
            pending.good < static_cast<int32_t>(held.size())) {
            held[pending.good] = saturating_add(held[pending.good], pending.quantity, _saturation_count);
        }
        ColonizationReserveContext reserve;
        reserve.reserved = &held;
        reserve.prefer_reserved_candidates = true;
        reserve.forecast_missing = true;
        ColonizationKitPlan kit;
        const int32_t speed = std::max(1, family_expeditions_store().speed[expedition]);
        const int32_t travel = std::max(1,
            (family_expeditions_store().route_cost[expedition] + speed - 1) / speed);
        if (!plan_colonization_kit(source, target,
                family_expeditions_store().population[expedition] +
                    family_expeditions_store().anonymous[expedition], travel,
                true, kit, false, &reserve) ||
            kit.kit_unbuildable != 0) continue;
        std::vector<int64_t> wanted(held.size(), 0);
        for (const auto &line : kit.cargo)
            wanted[line.good_id] = saturating_add(wanted[line.good_id], line.quantity, _saturation_count);
        for (const auto &line : kit.cargo) {
            const int32_t good = line.good_id;
            const int64_t gap = std::max<int64_t>(0, wanted[good] - held[good]);
            wanted[good] = 0; // a good shared by construction/buffer is funded once
            if (gap <= 0 || budgets[country] <= 0) continue;
            const int64_t price = std::max<int64_t>(1, market_store().price[
                market_store().index(market, good)]);
            const int64_t affordable = std::min(gap, mul_div_sat(
                budgets[country], GOODS_SCALE, price, _saturation_count));
            if (affordable <= 0) continue;
            budgets[country] -= goods_cost(affordable, price, _saturation_count);
            _epoch_colonization_demand_by_cell.push_back({procurement_key(source, good), affordable});
            _epoch_colonization_demand_by_market.push_back({procurement_key(market, good), affordable});
            ensure_market_signal_index(source, good);
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
    merge(_epoch_colonization_demand_by_cell);
    merge(_epoch_colonization_demand_by_market);
}

} // namespace pk

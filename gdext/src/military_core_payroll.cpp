// Military payroll: collect occupied holders once, then settle in the original
// country / garrison-cell / army-slot order against each country's cash.
#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>

namespace pk {

namespace {
using namespace mil;

struct PayrollRow {
    int32_t country = -1;
    int32_t holder = -1;
    uint8_t army = 0;
    int64_t amount = 0;
};

bool payroll_holder_less(const PayrollRow &a, const PayrollRow &b) {
    if (a.country != b.country) return a.country < b.country;
    if (a.army != b.army) return a.army < b.army;
    return a.holder < b.holder;
}
} // namespace

int64_t MilitaryCore::soldier_living_cost(int32_t country_slot) const {
    if (country_slot < 0) return 0;
    if ((size_t)country_slot >= _last_digest.country_soldier_living_cost.size()) return 0;
    return _last_digest.country_soldier_living_cost[(size_t)country_slot];
}

int64_t MilitaryCore::soldier_daily_wage(int32_t country_slot) const {
    if (country_slot < 0 || (size_t)country_slot >= _policies.size()) return 0;
    const MilitaryCountryPolicy &p = _policies[(size_t)country_slot];
    // AUTO and ABSOLUTE use the same per-head amount for both holder kinds.
    if (p.wage_mode == 1) return std::max<int64_t>(0, p.wage_absolute);
    return std::max<int64_t>(0, mul_div(soldier_living_cost(country_slot),
                                       stat_q16(_last_digest, country_slot, MSTAT_WAGE),
                                       MILITARY_Q16));
}

void MilitaryCore::run_wages_and_upkeep(const MilitaryWorldDigest &digest,
                                       std::vector<MilitaryIntent> &out) {
    // Scratch belongs to this calling thread, not to a country or a saved world.
    // Reinitialize every call: restoring/reconfiguring a smaller world cannot
    // reuse yesterday's amounts or holder identity.
    static thread_local std::vector<int64_t> wages;
    static thread_local std::vector<int64_t> demands;
    static thread_local std::vector<PayrollRow> rows;
    wages.assign(_policies.size(), 0);
    demands.assign(_policies.size(), 0);
    rows.clear();
    bool has_country = false;
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        if (_policy_handle[slot] == 0) continue;
        has_country = true;
        wages[slot] = soldier_daily_wage((int32_t)slot);
    }
    if (!has_country) return;

    for (size_t i = 0; i < _lots.active.size(); ++i) {
        ++_report.payroll_lots_visited;
        if (!_lots.active[i] || _lots.count[i] <= 0) continue;
        const int32_t country = _lots.country_slot[i];
        if (country < 0 || (size_t)country >= wages.size()) continue;
        const int64_t amount = wages[(size_t)country] * _lots.count[i];
        if (amount <= 0) continue;
        const int32_t holder = _lots.location[i];
        const bool army = _lots.location_kind[i] == (uint8_t)MILITARY_LOT_ARMY;
        if (army) {
            if (!army_alive(_armies, holder)) continue;
        } else {
            if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
            if (holder < 0 || holder >= _terrain.cell_count) continue;
        }
        // Multiply each lot before adding, and retain the original lot order
        // for the country's demand and for every holder's accumulated amount.
        demands[(size_t)country] += amount;
        rows.push_back({country, holder, (uint8_t)(army ? 1 : 0), amount});
    }
    std::stable_sort(rows.begin(), rows.end(), payroll_holder_less);
    size_t cursor = 0;
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        const uint64_t handle = _policy_handle[slot];
        if (handle == 0) continue;
        MilitaryCountryPolicy &p = _policies[slot];
        const int64_t cash = slot < digest.country_cash.size() ? digest.country_cash[slot] : 0;
        const MilitaryBudgetSplit split = budget_split((int32_t)slot, cash);
        p.wage_planned_today = 0;
        int64_t budget = std::max<int64_t>(0, cash);
        int64_t planned = 0;
        while (cursor < rows.size() && rows[cursor].country == (int32_t)slot) {
            const PayrollRow first = rows[cursor++];
            int64_t amount = first.amount;
            while (cursor < rows.size() && rows[cursor].country == first.country &&
                   rows[cursor].army == first.army && rows[cursor].holder == first.holder) {
                amount += rows[cursor++].amount;
            }
            ++_report.payroll_holders_visited;
            if (amount <= 0) continue;
            const int64_t pay = std::min(amount, budget);
            if (pay <= 0) continue;
            budget -= pay;
            planned += pay;
            MilitaryIntent in;
            in.country_a = handle;
            in.amount = pay;
            if (first.army) {
                const size_t a = (size_t)first.holder;
                _report.payroll_army += pay;
                in.kind = MILITARY_INTENT_ARMY_PAY;
                in.cell = _armies.cell[a];
                in.count = _armies.cached_headcount[a];
                in.source_id = army_handle(first.holder);
            } else {
                _report.payroll_garrison += pay;
                in.kind = MILITARY_INTENT_PAY_WAGES;
                in.cell = first.holder;
                in.source_id = (uint64_t)first.holder;
            }
            out.push_back(in);
        }
        const int64_t demanded = demands[slot];
        p.pay_ratio_30_q16 = demanded > 0
                                 ? (int32_t)clamp64(mul_div(planned, MILITARY_Q16, demanded), 0, MILITARY_Q16)
                                 : MILITARY_Q16;
        // The envelope is a planning target; cash remains the hard limit.
        // Garrison rows spend first, then army rows. Later procurement and
        // maintenance reserve wage_planned_today from this same cash snapshot.
        p.wage_demand = 0;
        p.wage_arrears = 0;
        p.wage_overspend = 0;
        if (split.enabled) {
            p.wage_demand = demanded;
            if (planned > split.wage_ceiling)
                p.wage_overspend = planned - split.wage_ceiling;
            if (demanded > planned) p.wage_arrears = demanded - planned;
        }
        p.wage_planned_today = planned;
        p.spend_payroll_30 = p.spend_payroll_30 - p.spend_payroll_30 / 30 + planned;
        // Physical maintenance owns repairs; the retired cash-upkeep fields
        // are still cleared on every wage pass, including empty countries.
        p.upkeep_demand = 0;
        p.upkeep_arrears = 0;
        p.upkeep_overspend = 0;
    }
}

} // namespace pk

// Military budget envelope (任务 6 / 需求 5.1, 5.5).
//
// One envelope per country, expressed as a share of the country's daily treasury
// cash (需求 5.1: 军事总预算份额 = 每日国库现金份额), then split into three
// channel ceilings. Two properties matter and are easy to get wrong:
//
//  1. `budget_share_bp <= 0` means NO envelope. Every foreign AI country and
//     every save loaded before the player re-pushes a policy lives in that
//     state, and they must keep settling against cash and demand exactly as
//     they did before this file existed. A ceiling of 0 is therefore NOT the
//     same thing as "no envelope": 0 pauses a channel, absence keeps the old
//     behaviour.
//
//  2. The three channel shares are percentages of the envelope itself, not of a
//     remainder left over by another channel. Combined with the native submit
//     check (`command_budget_channels_exceed_10000`) that makes "sum <= 100%" a
//     real constraint instead of a decorative one.

#include "military_core.h"

#include <algorithm>

namespace pk {
namespace {

// Basis-points share of `base`, splitting the division so a huge base cannot
// overflow int64 while multiplying.
int64_t share_of(int64_t base, int32_t bp) {
    if (base <= 0 || bp <= 0) return 0;
    const int64_t clamped = std::clamp<int32_t>(bp, 0, 10000);
    if (clamped >= 10000) return base;
    return (base / 10000) * clamped + ((base % 10000) * clamped) / 10000;
}

} // namespace

int64_t MilitaryCore::last_country_cash(int32_t country_slot) const {
    if (country_slot < 0) return 0;
    const size_t slot = static_cast<size_t>(country_slot);
    if (slot >= _last_digest.country_cash.size()) return 0;
    return std::max<int64_t>(0, _last_digest.country_cash[slot]);
}

MilitaryCore::MilitaryBudgetSplit MilitaryCore::budget_split(
        int32_t country_slot, int64_t cash) const {
    MilitaryBudgetSplit split;
    if (country_slot < 0 || static_cast<size_t>(country_slot) >= _policies.size())
        return split;
    const MilitaryCountryPolicy &p = _policies[static_cast<size_t>(country_slot)];
    if (p.budget_share_bp <= 0) return split;
    split.enabled = true;
    split.envelope_daily = share_of(std::max<int64_t>(0, cash), p.budget_share_bp);
    if (split.envelope_daily <= 0) return split;
    split.wage_ceiling = share_of(split.envelope_daily, p.budget_wage_bp);
    split.upkeep_ceiling = share_of(split.envelope_daily, p.budget_upkeep_bp);
    split.procurement_ceiling = share_of(split.envelope_daily,
                                         p.procurement_share_bp);
    return split;
}

} // namespace pk

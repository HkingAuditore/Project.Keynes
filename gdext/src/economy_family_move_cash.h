#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>

namespace pk {

// The fixed-point operation is supplied by NativeEconomyRuntime so live
// moves and the investment ledger share the same rounding and saturation.
template <typename MulDiv>
int64_t family_move_cash_share(int64_t cash, int64_t people, int64_t population,
        int64_t &sat, MulDiv mul_div) {
    if (people <= 0 || population <= 0) return 0;
    return people >= population ? cash : mul_div(cash, people, population, sat);
}

// Cash carried out of a cohort by one move, once the family/anonymous split of
// the movers is known. This is the single definition of the transfer rule:
//   * move_cohort_population()        -- the live write,
//   * investment_portfolio_funds_feasible() -- the pre-write replay, fed with
//                                            simulated population/funds, and
//   * investment_commit_portfolio()   -- the pre-write gate on live state
// all resolve the carried cash here. Splitting the rule used to be the reason a
// replay could approve a leg the write then could not fund
// (building_investment_capital_preflight_drift); see
// docs/architecture/feature-guides.md §自动建筑投资的资金预检.
//   family_plan_valid: the caller resolved a family/anonymous split
//                      (plan_family_membership_move produced rows) and
//                      `moved_claim`/`anonymous_moved` are meaningful.
//   family_claim:      total cash claim of the source cohort's family rows.
//   anonymous_people:  source cohort population that holds no family claim.
// A full drain always carries every fund unit in the cohort.
template <typename MulDiv>
int64_t cohort_move_cash(int64_t funds, int64_t population, int64_t moved_people,
        bool family_plan_valid, int64_t moved_claim, int64_t family_claim,
        int64_t anonymous_moved, int64_t anonymous_people,
        int64_t &sat, MulDiv mul_div) {
    if (moved_people <= 0 || population <= 0) return 0;
    const int64_t source_funds = std::max<int64_t>(0, funds);
    if (moved_people >= population) return source_funds;
    if (!family_plan_valid)
        return family_move_cash_share(source_funds, moved_people, population, sat, mul_div);
    const int64_t anonymous_funds = std::max<int64_t>(0, source_funds - family_claim);
    const int64_t anonymous_cash = family_move_cash_share(
        anonymous_funds, anonymous_moved, anonymous_people, sat, mul_div);
    const int64_t claim = std::max<int64_t>(0, moved_claim);
    const int64_t carried =
        anonymous_cash > std::numeric_limits<int64_t>::max() - claim
            ? std::numeric_limits<int64_t>::max() : claim + anonymous_cash;
    return std::clamp<int64_t>(carried, 0, source_funds);
}

} // namespace pk

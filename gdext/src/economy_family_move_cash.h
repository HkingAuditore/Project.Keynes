#pragma once

#include <cstdint>

namespace pk {

// The fixed-point operation is supplied by NativeEconomyRuntime so live
// moves and the investment ledger share the same rounding and saturation.
template <typename MulDiv>
int64_t family_move_cash_share(int64_t cash, int64_t people, int64_t population,
        int64_t &sat, MulDiv mul_div) {
    if (people <= 0 || population <= 0) return 0;
    return people >= population ? cash : mul_div(cash, people, population, sat);
}

} // namespace pk

#include "economy_runtime.h"

#include <algorithm>
#include <cstdint>
#include <limits>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

namespace pk {

uint64_t economy_magnitude_i64(int64_t value) {
    return value >= 0 ? static_cast<uint64_t>(value)
                      : static_cast<uint64_t>(-(value + 1)) + 1ULL;
}

int64_t economy_clamp_i64_from_unsigned(uint64_t magnitude, bool negative,
                                        int64_t &saturation_count) {
    constexpr uint64_t POS_MAX = static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
    constexpr uint64_t NEG_MAX = POS_MAX + 1ULL;
    if ((!negative && magnitude > POS_MAX) || (negative && magnitude > NEG_MAX)) {
        ++saturation_count;
        return negative ? std::numeric_limits<int64_t>::min()
                        : std::numeric_limits<int64_t>::max();
    }
    if (negative) {
        if (magnitude == NEG_MAX) return std::numeric_limits<int64_t>::min();
        return -static_cast<int64_t>(magnitude);
    }
    return static_cast<int64_t>(magnitude);
}

int64_t NativeEconomyRuntime::saturating_add(int64_t a, int64_t b, int64_t &sat) {
    if (b > 0 && a > std::numeric_limits<int64_t>::max() - b) {
        ++sat;
        return std::numeric_limits<int64_t>::max();
    }
    if (b < 0 && a < std::numeric_limits<int64_t>::min() - b) {
        ++sat;
        return std::numeric_limits<int64_t>::min();
    }
    return a + b;
}

int64_t NativeEconomyRuntime::saturating_sub(int64_t a, int64_t b, int64_t &sat) {
    if (b == std::numeric_limits<int64_t>::min()) {
        if (a >= 0) {
            ++sat;
            return std::numeric_limits<int64_t>::max();
        }
        return a - b;
    }
    return saturating_add(a, -b, sat);
}

int64_t NativeEconomyRuntime::saturating_mul(int64_t a, int64_t b, int64_t &sat) {
    if (a == 0 || b == 0) return 0;
    const bool negative = (a < 0) ^ (b < 0);
    const uint64_t ua = economy_magnitude_i64(a);
    const uint64_t ub = economy_magnitude_i64(b);
    if (ua > std::numeric_limits<uint64_t>::max() / ub) {
        ++sat;
        return negative ? std::numeric_limits<int64_t>::min()
                        : std::numeric_limits<int64_t>::max();
    }
    return economy_clamp_i64_from_unsigned(ua * ub, negative, sat);
}

int64_t NativeEconomyRuntime::mul_div_sat(int64_t a, int64_t b, int64_t divisor,
                                          int64_t &sat) {
    if (divisor == 0) {
        ++sat;
        return ((a < 0) ^ (b < 0)) ? std::numeric_limits<int64_t>::min()
                                    : std::numeric_limits<int64_t>::max();
    }
    const bool negative = (a < 0) ^ (b < 0) ^ (divisor < 0);
    const uint64_t ua = economy_magnitude_i64(a);
    const uint64_t ub = economy_magnitude_i64(b);
    const uint64_t ud = economy_magnitude_i64(divisor);
    if (ua == 0 || ub == 0) return 0;
    if (ua <= std::numeric_limits<uint64_t>::max() / ub) {
        const uint64_t quotient = (ua * ub) / ud;
        return economy_clamp_i64_from_unsigned(quotient, negative, sat);
    }
#if defined(_MSC_VER) && defined(_M_X64)
    uint64_t hi = 0;
    const uint64_t lo = _umul128(ua, ub, &hi);
    if (hi >= ud) {
        ++sat;
        return negative ? std::numeric_limits<int64_t>::min()
                        : std::numeric_limits<int64_t>::max();
    }
    uint64_t remainder = 0;
    const uint64_t quotient = _udiv128(hi, lo, ud, &remainder);
    return economy_clamp_i64_from_unsigned(quotient, negative, sat);
#else
    const unsigned __int128 product = static_cast<unsigned __int128>(ua) * ub;
    const unsigned __int128 quotient = product / ud;
    const unsigned __int128 limit = static_cast<unsigned __int128>(
        negative ? static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) + 1ULL
                 : static_cast<uint64_t>(std::numeric_limits<int64_t>::max()));
    if (quotient > limit) {
        ++sat;
        return negative ? std::numeric_limits<int64_t>::min()
                        : std::numeric_limits<int64_t>::max();
    }
    return economy_clamp_i64_from_unsigned(static_cast<uint64_t>(quotient), negative, sat);
#endif
}

int64_t NativeEconomyRuntime::inventory_adjusted_cost_pressure(
        int64_t cost, int64_t inventory, int64_t &sat) {
    return cost > 0 && inventory < 0
        ? mul_div_sat(cost, std::max<int64_t>(0, Q16_ONE + inventory), Q16_ONE, sat)
        : cost;
}

int64_t NativeEconomyRuntime::pow_q16(int64_t ratio_q16, int64_t exponent_q16,
                                      int64_t &sat) {
    if (ratio_q16 <= 0) return exponent_q16 <= 0 ? Q16_ONE : 0;
    uint64_t x_q32 = static_cast<uint64_t>(ratio_q16) << 16;
    int32_t integer_log = 0;
    while (x_q32 < (1ULL << 32)) {
        x_q32 <<= 1;
        --integer_log;
        if (integer_log < -31) return 0;
    }
    while (x_q32 >= (2ULL << 32)) {
        x_q32 >>= 1;
        ++integer_log;
        if (integer_log > 31) break;
    }
    uint32_t fractional_log = 0;
    for (int32_t bit = 15; bit >= 0; --bit) {
#if defined(_MSC_VER) && defined(_M_X64)
        uint64_t hi = 0;
        const uint64_t lo = _umul128(x_q32, x_q32, &hi);
        x_q32 = (hi << 32) | (lo >> 32);
#else
        x_q32 = static_cast<uint64_t>((static_cast<unsigned __int128>(x_q32) * x_q32) >> 32);
#endif
        if (x_q32 >= (2ULL << 32)) {
            x_q32 >>= 1;
            fractional_log |= 1U << bit;
        }
    }
    const int64_t log_q16 = static_cast<int64_t>(integer_log) * Q16_ONE + fractional_log;
    const int64_t exponent_value = mul_div_sat(log_q16, exponent_q16, Q16_ONE, sat);
    int64_t integer_exp = exponent_value / Q16_ONE;
    int64_t fractional_exp = exponent_value % Q16_ONE;
    if (fractional_exp < 0) {
        fractional_exp += Q16_ONE;
        --integer_exp;
    }
    static constexpr uint64_t EXP2_FRAC_Q32[16] = {
        6074001000ULL, 5107605667ULL, 4683695048ULL, 4485121744ULL,
        4389014833ULL, 4341736423ULL, 4318288544ULL, 4306612134ULL,
        4300785774ULL, 4297875550ULL, 4296421177ULL, 4295694175ULL,
        4295330720ULL, 4295149004ULL, 4295058149ULL, 4295012722ULL,
    };
    uint64_t out_q32 = 1ULL << 32;
    for (int32_t i = 0; i < 16; ++i) {
        if ((fractional_exp & (1LL << (15 - i))) == 0) continue;
#if defined(_MSC_VER) && defined(_M_X64)
        uint64_t hi = 0;
        const uint64_t lo = _umul128(out_q32, EXP2_FRAC_Q32[i], &hi);
        out_q32 = (hi << 32) | (lo >> 32);
#else
        out_q32 = static_cast<uint64_t>(
            (static_cast<unsigned __int128>(out_q32) * EXP2_FRAC_Q32[i]) >> 32);
#endif
    }
    if (integer_exp >= 0) {
        if (integer_exp >= 31 || out_q32 > (std::numeric_limits<uint64_t>::max() >> integer_exp)) {
            ++sat;
            return std::numeric_limits<int64_t>::max();
        }
        out_q32 <<= integer_exp;
    } else {
        if (integer_exp <= -63) return 0;
        out_q32 >>= -integer_exp;
    }
    return economy_clamp_i64_from_unsigned(out_q32 >> 16, false, sat);
}

void NativeEconomyRuntime::formula_fixed_per_capita(const FormulaBatchInput &in,
                                                     int64_t *out, int64_t &sat) {
    const int64_t base_qty = in.param_count > 0 ? std::max<int64_t>(0, in.params[0]) : 0;
    const int64_t epoch_qty = saturating_mul(base_qty, std::max(1, in.dt_days), sat);
    for (int32_t i = 0; i < in.count; ++i)
        out[i] = saturating_mul(in.population[i], epoch_qty, sat);
}

void NativeEconomyRuntime::formula_income_price_linear(const FormulaBatchInput &in,
                                                        int64_t *out, int64_t &sat) {
    const int64_t base_qty = in.param_count > 0 ? std::max<int64_t>(0, in.params[0]) : 0;
    const int64_t ref_income = in.param_count > 1 ? std::max<int64_t>(1, in.params[1]) : MONEY_SCALE;
    const int64_t income_weight = in.param_count > 2 ? in.params[2] : Q16_ONE;
    const int64_t ref_price = in.param_count > 3 ? std::max<int64_t>(1, in.params[3]) : MONEY_SCALE;
    const int64_t price_elasticity = in.param_count > 4 ? in.params[4] : Q16_ONE;
    const int64_t min_factor = in.param_count > 5 ? std::max<int64_t>(0, in.params[5]) : 0;
    const int64_t max_factor = in.param_count > 6 ? std::max<int64_t>(min_factor, in.params[6]) : Q16_ONE * 4;
    for (int32_t i = 0; i < in.count; ++i) {
        const int64_t pop = std::max<int64_t>(1, in.population[i]);
        const int64_t income_pc = in.income_ema[i] / pop;
        int64_t income_factor = saturating_add(
            Q16_ONE, mul_div_sat(income_pc - ref_income, income_weight, ref_income, sat), sat);
        int64_t price_factor = saturating_sub(
            Q16_ONE, mul_div_sat(static_cast<int64_t>(in.price) - ref_price,
                                price_elasticity, ref_price, sat), sat);
        income_factor = std::clamp(income_factor, min_factor, max_factor);
        price_factor = std::clamp(price_factor, min_factor, max_factor);
        int64_t qty = saturating_mul(in.population[i], base_qty, sat);
        qty = saturating_mul(qty, std::max(1, in.dt_days), sat);
        qty = mul_div_sat(qty, income_factor, Q16_ONE, sat);
        out[i] = mul_div_sat(qty, price_factor, Q16_ONE, sat);
    }
}

int32_t NativeEconomyRuntime::base_price_ceiling(
        int32_t reference, int32_t default_price, int64_t cost_anchor) {
    const int64_t base = std::max<int64_t>(1, default_price);
    const int64_t anchor = std::clamp<int64_t>(std::max(base, cost_anchor), 1, INT32_MAX);
    // Valid catalog i32 operands have an exact, non-overflowing i64 product.
    return static_cast<int32_t>(std::min<int64_t>(INT32_MAX,
        (std::max<int64_t>(1, reference) * anchor + base - 1) / base));
}

NativeEconomyRuntime::PriceCeilingState NativeEconomyRuntime::advance_price_ceiling(
        PriceCeilingState state, int32_t base, int32_t price, int64_t shortage,
        int32_t days, int32_t confirm_days, int32_t expand_bp, int32_t recover_bp) {
    state.limit = std::max(base, state.limit);
    // A local settlement represents at most five actual elapsed days. Replay
    // fixed daily integer steps so cadence never changes the confirmation clock.
    for (int32_t day = 0; day < std::clamp(days, 0, 5); ++day) {
        const bool confirmed = state.confirmation_days >= confirm_days;
        const bool release = int64_t(price) * 10 < int64_t(state.limit) * 7 ||
                             shortage * 10 <= Q16_ONE;
        if (confirmed) {
            if (release) state.confirmation_days = 0;
            else if (shortage >= Q16_ONE / 4) {
                const int64_t growth = (int64_t(state.limit) * expand_bp + 9999) / 10000;
                state.limit = static_cast<int32_t>(std::min<int64_t>(INT32_MAX,
                    int64_t(state.limit) + growth));
            }
        } else if (int64_t(price) * 5 >= int64_t(state.limit) * 4 &&
                   shortage >= Q16_ONE / 4) {
            ++state.confirmation_days;
        } else {
            state.confirmation_days = 0;
        }
        if (int64_t(price) * 10 < int64_t(state.limit) * 7 && shortage * 10 <= Q16_ONE) {
            const int64_t reduction = (int64_t(state.limit) * recover_bp + 9999) / 10000;
            state.limit = static_cast<int32_t>(std::max<int64_t>(base, state.limit - reduction));
        }
    }
    return state;
}

int64_t NativeEconomyRuntime::shape_price(int32_t ceiling, int64_t current_price,
        int64_t next_price, int64_t &sat, bool *headroom_damped,
        bool *catalog_bound, bool *minimum_tick) {
    if (minimum_tick) *minimum_tick = false;
    // Price V5 has no economic floor. Small positive prices are a UI
    // formatting concern; only the numeric minimum protects arithmetic.
    const int64_t catalog_min = PRICE_NUMERIC_GUARD_MIN;
    const int64_t catalog_max = std::min<int64_t>(
        PRICE_NUMERIC_GUARD_MAX, std::max<int64_t>(catalog_min, ceiling));
    // Only the final 20% of the current cap damps upward movement.
    // Contracting a cap never forces a markdown; falls keep their rate limit.
    const int64_t soft_start = catalog_max * 4 / 5;
    const int64_t catalog_span = catalog_max - soft_start;
    int64_t shaped = next_price;
    if (headroom_damped != nullptr) *headroom_damped = false;
    if (next_price > current_price && current_price >= soft_start && catalog_span > 0) {
        const int64_t headroom_q16 = mul_div_sat(
            std::max<int64_t>(0, catalog_max - current_price), Q16_ONE,
            catalog_span, sat);
        const int64_t damped = saturating_add(current_price, mul_div_sat(
            next_price - current_price, headroom_q16, Q16_ONE, sat), sat);
        if (headroom_damped != nullptr) *headroom_damped = damped != next_price;
        shaped = damped;
        if (shaped == current_price && current_price < catalog_max) {
            shaped = current_price + 1;
            if (minimum_tick) *minimum_tick = true;
        }
    }
    const int64_t bounded = std::clamp<int64_t>(shaped, catalog_min, std::max(catalog_max, current_price));
    if (catalog_bound != nullptr) *catalog_bound = bounded != shaped;
    return bounded;
}

} // namespace pk

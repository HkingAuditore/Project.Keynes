// Included after NativeEconomyRuntime inside namespace pk.
// Common invoice operands fit a signed 64-bit product. Keep this path inline;
// extreme quantities still use the established wide saturating arithmetic.
inline int64_t NativeEconomyRuntime::GoodsBill::total(int64_t &) const {
    return charged;
}

inline int64_t NativeEconomyRuntime::GoodsBill::add(
        int64_t quantity, int64_t price, int64_t &sat) {
    if (quantity <= 0 || price <= 0) return 0;
    int64_t units;
    int64_t fraction;
    constexpr int64_t small_max = std::numeric_limits<int32_t>::max();
    if (quantity <= small_max && price <= small_max) {
        const int64_t product = quantity * price;
        units = product / GOODS_SCALE;
        fraction = remainder + product % GOODS_SCALE;
    } else {
        units = mul_div_sat(quantity, price, GOODS_SCALE, sat);
        fraction = remainder + ((quantity % GOODS_SCALE) *
                                (price % GOODS_SCALE)) % GOODS_SCALE;
    }
    const int64_t correction = (fraction > GOODS_SCALE ||
        (remainder == 0 && fraction != 0)) ? 1 : 0;
    remainder = static_cast<int32_t>(fraction % GOODS_SCALE);
    constexpr int64_t limit = std::numeric_limits<int64_t>::max();
    if (units < limit && charged <= limit - units - correction) {
        const int64_t delta = units + correction;
        charged += delta;
        return delta;
    }
    const int64_t before = charged;
    charged = saturating_add(charged, saturating_add(units, correction, sat), sat);
    return charged - before;
}

inline int64_t NativeEconomyRuntime::goods_cost(
        int64_t quantity, int64_t price, int64_t &sat) {
    if (quantity <= 0 || price <= 0) return 0;
    constexpr int64_t small_max = std::numeric_limits<int32_t>::max();
    if (quantity <= small_max && price <= small_max)
        return (quantity * price + GOODS_SCALE - 1) / GOODS_SCALE;
    const int64_t whole = mul_div_sat(quantity, price, GOODS_SCALE, sat);
    const bool fractional = ((quantity % GOODS_SCALE) *
                            (price % GOODS_SCALE)) % GOODS_SCALE != 0;
    return saturating_add(whole, fractional ? 1 : 0, sat);
}

// Included inside namespace pk by the colonization implementation files.
using namespace godot;
using namespace variant_helpers;

namespace {

constexpr int32_t COLONIZATION_EXPANSION_BUDGET = 8192;
constexpr int32_t COLONIZATION_SPEED = 1;
constexpr size_t COLONIZATION_QUOTE_CACHE_LIMIT = 4096;
constexpr size_t COLONIZATION_RECEIPT_LIMIT = 2048;
constexpr int32_t COLONIZATION_EFFECT_SOURCE = 0x434f4c4f; // COLO

uint64_t mul_mod_u64(uint64_t a, uint64_t b, uint64_t modulus) {
    if (modulus == 0) return 0;
    a %= modulus;
    uint64_t result = 0;
    while (b != 0) {
        if ((b & 1U) != 0)
            result = result >= modulus - a ? result - (modulus - a) : result + a;
        b >>= 1U;
        if (b != 0)
            a = a >= modulus - a ? a - (modulus - a) : a + a;
    }
    return result;
}

bool due_heap_less(const std::pair<int64_t, int32_t> &a,
                   const std::pair<int64_t, int32_t> &b) {
    return a.first > b.first || (a.first == b.first && a.second > b.second);
}

bool route_heap_less(const std::pair<int64_t, int32_t> &a,
                     const std::pair<int64_t, int32_t> &b) {
    return a.first > b.first || (a.first == b.first && a.second > b.second);
}

} // namespace

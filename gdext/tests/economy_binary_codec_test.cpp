#include "economy_runtime_binary_codec.h"
#include <cassert>
#include <cstdio>
#include <limits>
#include <random>

template <typename T>
void check() {
    std::mt19937_64 random(74027);
    for (size_t count : {size_t(0), size_t(1), size_t(7), size_t(64), size_t(4097)}) {
        std::vector<T> values(count);
        for (T &value : values) value = static_cast<T>(random());
        if (count) values.front() = std::numeric_limits<T>::min();
        if (count > 1) values.back() = std::numeric_limits<T>::max();
        for (size_t prefix = 0; prefix < 16; ++prefix) {
            std::vector<uint8_t> actual(prefix, 0x9b), expected = actual;
            for (T value : values) {
                using U = std::make_unsigned_t<T>;
                const U bits = static_cast<U>(value);
                for (size_t byte = 0; byte < sizeof(T); ++byte)
                    expected.push_back(static_cast<uint8_t>((bits >> (byte * 8)) & U(255)));
            }
            pk::binary_codec::append_column_le(actual, values);
            assert(actual == expected);
        }
    }
    std::vector<uint8_t> empty;
    pk::binary_codec::append_column_le<T>(empty, nullptr, 0);
    assert(empty.empty());
}

int main() {
    check<uint8_t>(); check<uint16_t>(); check<int32_t>();
    check<uint32_t>(); check<int64_t>(); check<uint64_t>();
    std::puts("economy_binary_codec_test PASS (signed bounds, lengths, alignment, empty)");
}

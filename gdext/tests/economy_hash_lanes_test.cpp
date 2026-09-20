#include "economy_hash.h"
#include <cassert>
#include <random>

template <typename T> void check() {
    std::mt19937_64 random(1735228708);
    for (size_t n = 0; n < 257; ++n) {
        std::vector<T> values(n);
        for (int pattern = 0; pattern < 4; ++pattern) {
            for (auto &v : values) v = pattern == 0 ? 0 :
                pattern == 1 ? static_cast<T>(random()) :
                pattern == 2 ? static_cast<T>(random() % 13 == 0 ? random() : 0) :
                static_cast<T>(-1);
            const uint64_t seed = random();
            uint64_t bytes = seed, words = seed;
            for (T v : values) {
                uint64_t u = static_cast<uint64_t>(v);
                words = (words ^ u) * 1099511628211ULL;
                for (int b = 0; b < 8; ++b) {
                    bytes = (bytes ^ (u & 255)) * 1099511628211ULL;
                    u >>= 8;
                }
            }
            assert(pk::economy_hash_lanes<true>(seed, values) == bytes);
            assert(pk::economy_hash_lanes<false>(seed, values) == words);
        }
    }
}
int main() {
    check<int64_t>(); check<int32_t>(); check<uint16_t>(); check<uint8_t>();
    return 0;
}

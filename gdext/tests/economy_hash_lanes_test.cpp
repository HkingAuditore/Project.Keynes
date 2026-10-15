#include "economy_hash.h"
#include <cassert>
#include <random>
#include <cstdio>

uint64_t reference_bytes(uint64_t hash, const uint8_t *data, size_t size) {
    for (size_t i = 0; i < size; ++i) {
        hash ^= static_cast<uint64_t>(data[i]);
        hash *= 1099511628211ULL;
    }
    return hash;
}

void check_raw_bytes() {
    std::mt19937_64 random(1735228709);
    std::vector<size_t> lengths;
    for (size_t n = 0; n <= 513; ++n) lengths.push_back(n);
    for (size_t n : {4095u, 4096u, 4097u, 65537u, 1048576u}) lengths.push_back(n);
    for (size_t n : lengths) {
        std::vector<uint8_t> bytes(n + 16);
        for (int pattern = 0; pattern < 5; ++pattern) {
            for (auto &byte : bytes) byte = pattern == 0 ? 0 :
                pattern == 1 ? static_cast<uint8_t>(random()) :
                pattern == 2 ? static_cast<uint8_t>(random() % 67 == 0 ? random() : 0) :
                pattern == 3 ? 255 : 128;
            for (size_t offset = 0; offset < 16; ++offset) {
                const uint8_t *data = bytes.data() + offset;
                const uint64_t seed = random();
                const uint64_t expected = reference_bytes(seed, data, n);
                assert(pk::economy_hash_bytes(seed, data, n) == expected);
                const size_t split = n == 0 ? 0 : random() % n;
                assert(pk::economy_hash_bytes(
                    pk::economy_hash_bytes(seed, data, split), data + split, n - split) == expected);
            }
        }
    }
    assert(pk::economy_hash_bytes(17, nullptr, 0) == 17);
}

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
    check_raw_bytes();
    std::puts("economy_hash_lanes_test PASS (lanes + raw byte lengths/patterns/alignment/streaming)");
    return 0;
}

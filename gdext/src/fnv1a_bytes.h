#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace pk::hashing::fnv1a {

// 保持原 little-endian 八字节 FNV-1a ABI；连续零字节可合并为一次乘法。
inline uint64_t mix_u64_le(uint64_t hash, uint64_t value) noexcept {
    constexpr uint64_t prime = 1099511628211ULL;
    constexpr uint64_t prime2 = prime * prime;
    constexpr uint64_t prime4 = prime2 * prime2;
    constexpr uint64_t prime8 = prime4 * prime4;
    if (value == 0) return hash * prime8;
    for (int i = 0; i < 2; ++i) {
        hash = (hash ^ static_cast<uint8_t>(value)) * prime;
        value >>= 8;
    }
    if (value == 0) return hash * (prime4 * prime2);
    for (int i = 0; i < 2; ++i) {
        hash = (hash ^ static_cast<uint8_t>(value)) * prime;
        value >>= 8;
    }
    if (value == 0) return hash * prime4;
    for (int i = 0; i < 4; ++i) {
        hash = (hash ^ static_cast<uint8_t>(value)) * prime;
        value >>= 8;
    }
    return hash;
}

inline uint64_t scalar(uint64_t hash, const uint8_t *data, size_t size) noexcept {
    for (size_t i = 0; i < size; ++i)
        hash = (hash ^ data[i]) * 1099511628211ULL;
    return hash;
}

// 原始字节流与 lanes<T> 的八字节数值编码不同，不能互换。
inline uint64_t bytes(uint64_t hash, const uint8_t *data, size_t size) noexcept {
#if defined(_WIN32) || (defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
    constexpr uint64_t prime64 = []() constexpr {
        uint64_t power = 1;
        for (int i = 0; i < 64; ++i) power *= 1099511628211ULL;
        return power;
    }();
    // XOR touches only the low byte. For a fixed block, two incoming hashes
    // with the same low byte stay apart by their initial difference * prime^64.
    // Precompute the low-byte term for the common all-ones (-1) map sentinel.
    static constexpr auto ones = [] {
        std::array<uint64_t, 256> table{};
        for (size_t low = 0; low < table.size(); ++low) {
            uint64_t h = low;
            for (unsigned j = 0; j < 64; ++j) h = (h ^ 255u) * 1099511628211ULL;
            table[low] = h;
        }
        return table;
    }();
    size_t i = 0;
    for (; size - i >= 64; i += 64) {
        uint64_t words[8];
        std::memcpy(words, data + i, sizeof(words));
        if ((words[0] | words[1] | words[2] | words[3] |
             words[4] | words[5] | words[6] | words[7]) == 0) {
            hash *= prime64;
            continue;
        }
        if ((words[0] & words[1] & words[2] & words[3] &
             words[4] & words[5] & words[6] & words[7]) == UINT64_MAX) {
            hash = (hash & ~uint64_t{255}) * prime64 + ones[static_cast<uint8_t>(hash)];
            continue;
        }
        for (uint64_t word : words) hash = mix_u64_le(hash, word);
    }
    for (; size - i >= 8; i += 8) {
        uint64_t word;
        std::memcpy(&word, data + i, sizeof(word));
        hash = mix_u64_le(hash, word);
    }
    for (; i < size; ++i) hash = (hash ^ data[i]) * 1099511628211ULL;
    return hash;
#else
    return scalar(hash, data, size);
#endif
}

} // namespace pk::hashing::fnv1a

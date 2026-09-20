#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>
#include <type_traits>

namespace pk {

// 保持原 little-endian 八字节 FNV-1a ABI；连续零字节可合并为一次乘法。
inline uint64_t economy_hash_u64(uint64_t hash, uint64_t value) noexcept {
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


template <bool ByteHash, typename T>
uint64_t economy_hash_lanes(uint64_t hash, const std::vector<T> &values) noexcept {
    constexpr uint64_t prime = 1099511628211ULL;
    constexpr uint64_t power = []() constexpr {
        uint64_t result = 1;
        for (int i = 0; i < (ByteHash ? 64 : 8); ++i) result *= 1099511628211ULL;
        return result;
    }();
    size_t i = 0;
    for (; i + 8 <= values.size(); i += 8) {
        const auto combined = static_cast<uint64_t>(values[i]) |
            static_cast<uint64_t>(values[i+1]) | static_cast<uint64_t>(values[i+2]) |
            static_cast<uint64_t>(values[i+3]) | static_cast<uint64_t>(values[i+4]) |
            static_cast<uint64_t>(values[i+5]) | static_cast<uint64_t>(values[i+6]) |
            static_cast<uint64_t>(values[i+7]);
        if (combined == 0) { hash *= power; continue; }
        for (size_t j = 0; j < 8; ++j) {
            const uint64_t value = static_cast<uint64_t>(values[i+j]);
            if constexpr (ByteHash) hash = economy_hash_u64(hash, value);
            else hash = (hash ^ value) * prime;
        }
    }
    for (; i < values.size(); ++i) {
        const uint64_t value = static_cast<uint64_t>(values[i]);
        if constexpr (ByteHash) hash = economy_hash_u64(hash, value);
        else hash = (hash ^ value) * prime;
    }
    return hash;
}

} // namespace pk

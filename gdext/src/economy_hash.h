#pragma once

#include <cstdint>

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

} // namespace pk

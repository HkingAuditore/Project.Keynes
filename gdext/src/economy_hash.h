#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>
#include <type_traits>
#include <cstring>
#include <cstdlib>
#include <cstdio>

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

inline uint64_t economy_hash_bytes_scalar(uint64_t hash, const uint8_t *data,
                                          size_t size) noexcept {
    for (size_t i = 0; i < size; ++i)
        hash = (hash ^ data[i]) * 1099511628211ULL;
    return hash;
}

// 原始字节流与 lanes<T> 的八字节数值编码不同，不能互换。
inline uint64_t economy_hash_bytes(uint64_t hash, const uint8_t *data,
                                   size_t size) noexcept {
#if defined(_WIN32) || (defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
    constexpr uint64_t prime64 = []() constexpr {
        uint64_t power = 1;
        for (int i = 0; i < 64; ++i) power *= 1099511628211ULL;
        return power;
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
        for (uint64_t word : words) hash = economy_hash_u64(hash, word);
    }
    for (; size - i >= 8; i += 8) {
        uint64_t word;
        std::memcpy(&word, data + i, sizeof(word));
        hash = economy_hash_u64(hash, word);
    }
    for (; i < size; ++i) hash = (hash ^ data[i]) * 1099511628211ULL;
    return hash;
#else
    return economy_hash_bytes_scalar(hash, data, size);
#endif
}

inline uint64_t economy_save_hash_bytes(const uint8_t *data, size_t size) noexcept {
    constexpr uint64_t offset = 1469598103934665603ULL;
    static const bool scalar = []() {
        const char *value = std::getenv("PK_SAVE_BYTE_HASH_SCALAR");
        return value && value[0] == '1';
    }();
    static const bool verify = []() {
        const char *value = std::getenv("PK_SAVE_BYTE_HASH_VERIFY");
        return value && value[0] == '1';
    }();
    if (scalar) return economy_hash_bytes_scalar(offset, data, size);
    const uint64_t hash = economy_hash_bytes(offset, data, size);
    if (verify && hash != economy_hash_bytes_scalar(offset, data, size)) {
        std::fputs("[save-byte-hash] scalar mismatch\n", stderr);
        std::abort();
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

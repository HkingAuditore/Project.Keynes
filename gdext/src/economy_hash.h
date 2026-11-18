#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>
#include <type_traits>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include "runtime_switch_registry.h"
#include "fnv1a_bytes.h"
namespace pk {

inline uint64_t economy_hash_u64(uint64_t hash, uint64_t value) noexcept {
    return hashing::fnv1a::mix_u64_le(hash, value);
}

inline uint64_t economy_hash_bytes_scalar(uint64_t hash, const uint8_t *data, size_t size) noexcept {
    return hashing::fnv1a::scalar(hash, data, size);
}

inline uint64_t economy_hash_bytes(uint64_t hash, const uint8_t *data, size_t size) noexcept {
    return hashing::fnv1a::bytes(hash, data, size);
}

inline uint64_t economy_save_hash_bytes(const uint8_t *data, size_t size) noexcept {
    constexpr uint64_t offset = 1469598103934665603ULL;
    static const bool scalar = []() {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_SAVE_BYTE_HASH_SCALAR);
        return value && value[0] == '1';
    }();
    static const bool verify = []() {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_SAVE_BYTE_HASH_VERIFY);
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

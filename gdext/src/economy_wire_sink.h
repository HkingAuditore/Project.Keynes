#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace pk {

// 同一字段遍历服务存档、长度与哈希；不改变既有 wire 字节或长度前缀。
struct EconomyWireSizeSink { size_t size = 0; };
struct EconomyWireHashSink { uint64_t hash; };

constexpr uint64_t economy_wire_prime_power(size_t bytes) {
    uint64_t value = 1;
    for (size_t i = 0; i < bytes; ++i) value *= 1099511628211ull;
    return value;
}

template <typename T>
void economy_wire_append(std::vector<uint8_t> &out, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), bytes, bytes + sizeof(T));
}

template <typename T>
void economy_wire_append(EconomyWireSizeSink &out, const T &) {
    out.size += sizeof(T);
}

template <typename T>
void economy_wire_append(EconomyWireHashSink &out, const T &value) {
    if (value == 0) {
        out.hash *= economy_wire_prime_power(sizeof(T));
        return;
    }
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    for (size_t i = 0; i < sizeof(T); ++i) {
        out.hash ^= bytes[i];
        out.hash *= 1099511628211ull;
    }
}

} // namespace pk

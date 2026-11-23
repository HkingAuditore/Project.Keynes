#pragma once

#include "economy_hash.h"
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

struct RuntimeEconomyLedgerState;
struct RuntimeEconomyOwnedState;

namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

void append_u32(std::vector<uint8_t> &out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xffu));
}

void append_u16(std::vector<uint8_t> &out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xffu));
}

void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (8 * i)) & 0xffu));
}

void append_i64(std::vector<uint8_t> &out, int64_t value) {
    append_u64(out, static_cast<uint64_t>(value));
}

void append_i32(std::vector<uint8_t> &out, int32_t value) {
    append_u32(out, static_cast<uint32_t>(value));
}

bool read_u32(const uint8_t *&p, const uint8_t *end, uint32_t &value) {
    if (end - p < 4) return false;
    value = static_cast<uint32_t>(p[0]) |
        (static_cast<uint32_t>(p[1]) << 8) |
        (static_cast<uint32_t>(p[2]) << 16) |
        (static_cast<uint32_t>(p[3]) << 24);
    p += 4;
    return true;
}

bool read_u16(const uint8_t *&p, const uint8_t *end, uint16_t &value) {
    if (end - p < 2) return false;
    value = static_cast<uint16_t>(p[0]) |
        (static_cast<uint16_t>(p[1]) << 8);
    p += 2;
    return true;
}

bool read_u64(const uint8_t *&p, const uint8_t *end, uint64_t &value) {
    if (end - p < 8) return false;
    value = 0;
    for (int i = 0; i < 8; ++i)
        value |= static_cast<uint64_t>(p[i]) << (8 * i);
    p += 8;
    return true;
}

bool read_i64(const uint8_t *&p, const uint8_t *end, int64_t &value) {
    uint64_t raw = 0;
    if (!read_u64(p, end, raw)) return false;
    value = static_cast<int64_t>(raw);
    return true;
}

bool read_i32(const uint8_t *&p, const uint8_t *end, int32_t &value) {
    uint32_t raw = 0;
    if (!read_u32(p, end, raw)) return false;
    value = static_cast<int32_t>(raw);
    return true;
}

constexpr int64_t Q16_ONE = 65536;
uint64_t fnv1a(const uint8_t *data, size_t size) noexcept {
    return economy_save_hash_bytes(data, size);
}

} // namespace

namespace economy_pod_internal {
bool build_owned_state_from_ledger(const RuntimeEconomyLedgerState &ledger,
                                   RuntimeEconomyOwnedState &restored,
                                   std::string &error);
} // namespace economy_pod_internal

} // namespace pk

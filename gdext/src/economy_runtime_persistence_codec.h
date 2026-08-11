#pragma once

#include "economy_runtime.h"
#include "economy_runtime_binary_codec.h"

#include <cstring>
#include <limits>
#include <vector>

namespace pk::persistence_codec {

inline constexpr int32_t PRICE_NUMERIC_GUARD_MIN = 1;
inline constexpr int32_t PRICE_NUMERIC_GUARD_MAX =
    std::numeric_limits<int32_t>::max();
inline constexpr uint32_t SAVE_MAGIC = 0x43454b50U; // "PKEC" little endian
inline constexpr uint16_t SAVE_SECTION_HEADER = 0;
inline constexpr uint16_t SAVE_SECTION_PAGES = 1;
inline constexpr uint16_t SAVE_SECTION_MARKETS = 2;
inline constexpr uint16_t SAVE_SECTION_CELLS = 3;
inline constexpr uint16_t SAVE_SECTION_COMMANDS = 4;
inline constexpr uint16_t SAVE_SECTION_BUILDINGS = 5;
inline constexpr uint16_t SAVE_SECTION_CONSTRUCTION = 6;
inline constexpr uint16_t SAVE_SECTION_AUDIT = 7;
inline constexpr uint16_t SAVE_SECTION_SIGNALS = 8;
inline constexpr uint16_t SAVE_SECTION_LABOR_SIGNALS = 9;
inline constexpr uint16_t SAVE_SECTION_TRADE_ORDERS = 10;
inline constexpr uint16_t SAVE_SECTION_TRADE_FLOWS = 11;
inline constexpr uint16_t SAVE_SECTION_MODIFIERS = 12;
inline constexpr uint16_t SAVE_SECTION_FISCAL = 13;
inline constexpr uint16_t SAVE_SECTION_SETTLEMENT_NAMES = 14;
inline constexpr uint16_t SAVE_SECTION_FAMILY_RECORDS = 15;
inline constexpr uint16_t SAVE_SECTION_FAMILY_MEMBERSHIP = 16;
inline constexpr uint16_t SAVE_SECTION_FAMILY_OWNERSHIP = 17;
inline constexpr uint16_t SAVE_SECTION_PERSON_RECORDS = 18;
inline constexpr uint16_t SAVE_SECTION_PERSON_NEEDS = 19;
inline constexpr uint16_t SAVE_SECTION_FAMILY_TRAITS = 20;
inline constexpr uint16_t SAVE_SECTION_FAMILY_INFLUENCES = 21;
inline constexpr uint16_t SAVE_SECTION_FAMILY_TRAIT_COMMANDS = 22;
inline constexpr uint16_t SAVE_SECTION_FAMILY_EXPEDITIONS = 23;
inline constexpr uint16_t SAVE_SECTION_TARIFF_HISTORY = 24;
inline constexpr uint16_t SAVE_SECTION_COUNTRY_GOOD = 25;
inline constexpr uint16_t SAVE_SECTION_COUNTRY_PARTNER = 26;
inline constexpr uint16_t SAVE_SECTION_CANAL_QUOTES = 27;
inline constexpr uint16_t SAVE_SECTION_CANAL_PROJECTS = 28;
inline constexpr uint16_t SAVE_SECTION_END = 29;
inline constexpr uint16_t SAVE_SECTION_END_V33 = 27;
inline constexpr uint16_t SAVE_SECTION_END_V26 = 18;
inline constexpr uint16_t SAVE_SECTION_END_V24_TO_V25 = 15;
inline constexpr uint16_t SAVE_SECTION_END_V23 = 14;
inline constexpr uint16_t SAVE_SECTION_END_V20_TO_V22 = 13;
inline constexpr uint16_t SAVE_SECTION_END_V11_TO_V19 = 12;
inline constexpr uint16_t SAVE_SECTION_END_V10 = 10;

inline godot::PackedByteArray make_save_chunk(
        uint16_t section, uint32_t records,
        const std::vector<uint8_t> &payload) {
    using binary_codec::append_le;
    std::vector<uint8_t> bytes;
    bytes.reserve(16 + payload.size());
    append_le<uint32_t>(bytes, SAVE_MAGIC);
    append_le<uint16_t>(bytes,
        static_cast<uint16_t>(NativeEconomyRuntime::SCHEMA_VERSION));
    append_le<uint16_t>(bytes, section);
    append_le<uint32_t>(bytes, records);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(payload.size()));
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    godot::PackedByteArray out;
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty())
        std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

} // namespace pk::persistence_codec

#pragma once

#include "runtime_economy_state.h"
#include "economy_hash.h"
#include "economy_runtime_binary_codec.h"

namespace pk::persistence_codec {
constexpr uint32_t OWNED_STATE_MAGIC = 0x414F534Fu; // "OSOA"
constexpr uint32_t OWNED_STATE_VERSION = 3u;

inline void owned_put_u32(std::vector<uint8_t> &out, uint32_t value) {
    for (int i = 0; i < 4; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
}
inline void owned_put_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
}
inline void owned_put_i64(std::vector<uint8_t> &out, int64_t value) {
    owned_put_u64(out, static_cast<uint64_t>(value));
}
inline void owned_put_i32(std::vector<uint8_t> &out, int32_t value) {
    owned_put_u32(out, static_cast<uint32_t>(value));
}

inline uint64_t owned_fnv1a(const uint8_t *data, size_t size) {
    return economy_save_hash_bytes(data, size);
}

inline bool append_owned_block(std::vector<uint8_t> &out, uint32_t id,
                        const std::vector<uint8_t> &payload) {
    owned_put_u32(out, id);
    owned_put_u32(out, static_cast<uint32_t>(payload.size()));
    out.insert(out.end(), payload.begin(), payload.end());
    return true;
}

inline void encode_owned_state_soa(const RuntimeEconomyLedgerState &ledger,
                            std::vector<uint8_t> &out,
                            bool bulk = binary_codec::bulk_little_endian_enabled()) {
    out.clear();
    owned_put_u32(out, OWNED_STATE_MAGIC);
    owned_put_u32(out, OWNED_STATE_VERSION);
    owned_put_u64(out, ledger.ledger_hash);
    owned_put_u64(out, ledger.generation);
    owned_put_i64(out, ledger.committed_day);
    const size_t hash_at = out.size();
    owned_put_u64(out, 0u);
    std::vector<uint8_t> block;
    ledger.building.store.append_wire(block);
    append_owned_block(out, 1u, block);
    block.clear();
    ledger.trade_escrow.store.append_wire(block);
    append_owned_block(out, 2u, block);
    block.clear();
    ledger.family.store.append_wire(block);
    append_owned_block(out, 3u, block);
    block.clear();
    ledger.resource.store.append_wire(block);
    append_owned_block(out, 4u, block);
    block.clear();
    owned_put_u32(block, static_cast<uint32_t>(ledger.cohort_active.size()));
    for (size_t i = 0; i < ledger.cohort_active.size(); ++i) {
        block.push_back(ledger.cohort_active[i]);
        owned_put_u32(block, static_cast<uint32_t>(ledger.cohort_cell[i]));
        owned_put_u32(block, static_cast<uint32_t>(ledger.cohort_slot[i]));
        owned_put_u32(block, ledger.cohort_signature_id[i]);
        owned_put_u64(block, static_cast<uint64_t>(ledger.cohort_population[i]));
        owned_put_u64(block, static_cast<uint64_t>(ledger.cohort_funds[i]));
    }
    append_owned_block(out, 5u, block);
    block.clear();
    owned_put_u32(block, static_cast<uint32_t>(ledger.market_stock.size()));
    if (bulk) {
        const size_t offset = block.size();
        // OSOA 的 8/4/8 交错记录固定为 20 字节，不能引入结构体填充。
        block.resize(offset + ledger.market_stock.size() * 20u);
        uint8_t *records = block.data() + offset;
        for (size_t i = 0; i < ledger.market_stock.size(); ++i) {
            uint8_t *record = records + i * 20u;
            binary_codec::store_le(record, ledger.market_stock[i]);
            binary_codec::store_le(record + 8u, ledger.market_price[i]);
            binary_codec::store_le(record + 12u, ledger.market_demand_ema[i]);
        }
    } else for (size_t i = 0; i < ledger.market_stock.size(); ++i) {
        owned_put_u64(block, static_cast<uint64_t>(ledger.market_stock[i]));
        owned_put_u32(block, static_cast<uint32_t>(ledger.market_price[i]));
        owned_put_u64(block, static_cast<uint64_t>(ledger.market_demand_ema[i]));
    }
    append_owned_block(out, 6u, block);
    // Section 7: epoch-cursor / continuation watermark (typed wire already
    // exists on the ledger). Journal / market-signal blobs remain in their
    // ECP2 domain chunks; OSOA only mirrors the idle cursor here.
    if (ledger.epoch_cursor.captured) {
        block.clear();
        owned_put_i64(block, ledger.epoch_cursor.sample_day);
        owned_put_i64(block, ledger.epoch_cursor.current_day);
        owned_put_i64(block, ledger.epoch_cursor.last_committed_day);
        owned_put_i64(block, ledger.epoch_cursor.epoch_id);
        owned_put_i32(block, ledger.epoch_cursor.epoch_days);
        block.push_back(ledger.epoch_cursor.epoch_active);
        owned_put_i32(block, ledger.epoch_cursor.native_stage);
        owned_put_u32(block, ledger.epoch_cursor.graph_completed_mask);
        ledger.epoch_cursor.store.append_wire(block);
        append_owned_block(out, 7u, block);
    }
    const uint64_t hash = owned_fnv1a(out.data() + hash_at + 8u,
                                     out.size() - hash_at - 8u);
    for (int i = 0; i < 8; ++i)
        out[hash_at + static_cast<size_t>(i)] =
            static_cast<uint8_t>((hash >> (i * 8)) & 0xffu);
}

inline bool read_owned_u32(const uint8_t *data, size_t size, size_t &cursor,
                    uint32_t &value) {
    if (cursor > size || size - cursor < 4u) return false;
    value = static_cast<uint32_t>(data[cursor]) |
        (static_cast<uint32_t>(data[cursor + 1]) << 8u) |
        (static_cast<uint32_t>(data[cursor + 2]) << 16u) |
        (static_cast<uint32_t>(data[cursor + 3]) << 24u);
    cursor += 4u;
    return true;
}
inline bool read_owned_u64(const uint8_t *data, size_t size, size_t &cursor,
                    uint64_t &value) {
    if (cursor > size || size - cursor < 8u) return false;
    value = 0;
    for (int i = 0; i < 8; ++i)
        value |= static_cast<uint64_t>(data[cursor + static_cast<size_t>(i)]) <<
            (i * 8u);
    cursor += 8u;
    return true;
}
inline bool validate_owned_state_soa(const std::vector<uint8_t> &wire) {
    if (wire.size() < 40u) return false;
    size_t cursor = 0;
    uint32_t magic = 0, version = 0;
    uint64_t ledger_hash = 0, generation = 0, committed_day_bits = 0;
    uint64_t expected_hash = 0;
    if (!read_owned_u32(wire.data(), wire.size(), cursor, magic) ||
        !read_owned_u32(wire.data(), wire.size(), cursor, version) ||
        !read_owned_u64(wire.data(), wire.size(), cursor, ledger_hash) ||
        !read_owned_u64(wire.data(), wire.size(), cursor, generation) ||
        !read_owned_u64(wire.data(), wire.size(), cursor, committed_day_bits) ||
        cursor > wire.size() - 8u ||
        !read_owned_u64(wire.data(), wire.size(), cursor, expected_hash) ||
        magic != OWNED_STATE_MAGIC || version != OWNED_STATE_VERSION) {
        return false;
    }
    if (generation == 0u) return false;
    const int64_t committed_day =
        static_cast<int64_t>(committed_day_bits);
    if (committed_day < 0) return false;
    const size_t hash_at = 32u;
    const uint64_t actual_hash = owned_fnv1a(
        wire.data() + hash_at + 8u, wire.size() - hash_at - 8u);
    if (actual_hash != expected_hash) return false;
    uint32_t seen = 0;
    // Sections 1..6, 8, 9 and 10 are required. Section 7 is the optional epoch cursor.
    // Journal / market-signal payloads live in ECP2 domain blobs, not OSOA.
    // Reject unknown ids fail-closed.
    while (cursor < wire.size()) {
        uint32_t id = 0, payload_size = 0;
        if (!read_owned_u32(wire.data(), wire.size(), cursor, id) ||
            !read_owned_u32(wire.data(), wire.size(), cursor, payload_size) ||
            id < 1u || id > 12u || (seen & (1u << id)) != 0u ||
            payload_size > wire.size() - cursor) return false;
        seen |= 1u << id;
        // Sections 1..4 may legitimately be empty (e.g. no trade escrow /
        // family / resource lanes on a sparse fixture). Cohort/market carry
        // an explicit count prefix and must stay shape-consistent when present.
        if (id == 5u || id == 6u) {
            if (payload_size < 4u) return false;
            uint32_t count = 0;
            size_t count_cursor = cursor;
            if (!read_owned_u32(wire.data(), wire.size(), count_cursor, count))
                return false;
            if (id == 5u) {
                // active(u8)+cell(u32)+slot(u32)+sig(u32)+pop(u64)+funds(u64)
                constexpr size_t kCohortRow = 1u + 4u + 4u + 4u + 8u + 8u;
                if (static_cast<uint64_t>(count) * kCohortRow !=
                    payload_size - 4u) {
                    return false;
                }
            } else {
                // stock(u64)+price(u32)+ema(u64)
                constexpr size_t kMarketRow = 8u + 4u + 8u;
                if (static_cast<uint64_t>(count) * kMarketRow !=
                    payload_size - 4u) {
                    return false;
                }
            }
        }
        if (id == 7u) {
            // Fixed prefix: sample/current/committed/epoch_id (4*i64) +
            // epoch_days(i32) + active(u8) + native_stage(i32) +
            // graph_mask(u32). The idle store may append a trailing wire.
            constexpr size_t kEpochCursorPrefix =
                8u * 4u + 4u + 1u + 4u + 4u;
            if (payload_size < kEpochCursorPrefix) return false;
            size_t day_cursor = cursor;
            uint64_t sample_bits = 0, current_bits = 0, committed_bits = 0;
            uint64_t epoch_id_bits = 0;
            if (!read_owned_u64(wire.data(), wire.size(), day_cursor,
                                sample_bits) ||
                !read_owned_u64(wire.data(), wire.size(), day_cursor,
                                current_bits) ||
                !read_owned_u64(wire.data(), wire.size(), day_cursor,
                                committed_bits) ||
                !read_owned_u64(wire.data(), wire.size(), day_cursor,
                                epoch_id_bits)) {
                return false;
            }
            const int64_t sample_day = static_cast<int64_t>(sample_bits);
            const int64_t current_day = static_cast<int64_t>(current_bits);
            const int64_t committed = static_cast<int64_t>(committed_bits);
            if (committed < 0 || current_day < committed) return false;
            if (sample_day >= 0 && current_day >= 0 &&
                sample_day > current_day) {
                return false;
            }
            (void)epoch_id_bits;
        }
        cursor += payload_size;
    }
    (void)ledger_hash;
    // Require core sections 1..6 and publication state 8 and resource state 9; section 7 is optional.
    return cursor == wire.size() && (seen & 0x37Eu) == 0x37Eu;
}
inline void append_publication_block(std::vector<uint8_t> &wire,
                                     const std::vector<uint8_t> &payload, uint32_t id = 8u) {
    append_owned_block(wire, id, payload);
    const uint64_t hash = owned_fnv1a(wire.data() + 40u, wire.size() - 40u);
    binary_codec::store_le(wire.data() + 32u, hash);
}
inline std::vector<uint8_t> publication_block(const std::vector<uint8_t> &wire, uint32_t wanted = 8u) {
    size_t cursor = 40u;
    while (cursor < wire.size()) {
        uint32_t id = 0, size = 0;
        if (!read_owned_u32(wire.data(), wire.size(), cursor, id) ||
            !read_owned_u32(wire.data(), wire.size(), cursor, size) ||
            size > wire.size() - cursor) return {};
        if (id == wanted) return {wire.begin() + cursor, wire.begin() + cursor + size};
        cursor += size;
    }
    return {};
}
} // namespace pk::persistence_codec

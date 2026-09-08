#include "country_core.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace pk {

uint64_t country_peer_request_id(uint64_t session_epoch,
                                 uint64_t country_generation,
                                 int64_t day,
                                 uint32_t continuation_index,
                                 int32_t country_slot,
                                 int32_t technology,
                                 CountryPeerIntentCode opcode) noexcept {
    // SplitMix-style avalanche.  The identity is deterministic across
    // synchronous and worker adapters and is deliberately independent of
    // container addresses or allocation order.
    uint64_t value = 0x43504b3250454552ull; // "CP2PEER"
    const auto mix = [&value](uint64_t input) {
        value ^= input + 0x9e3779b97f4a7c15ull + (value << 6u) + (value >> 2u);
        value ^= value >> 30u;
        value *= 0xbf58476d1ce4e5b9ull;
        value ^= value >> 27u;
        value *= 0x94d049bb133111ebull;
        value ^= value >> 31u;
    };
    mix(session_epoch);
    mix(country_generation);
    mix(static_cast<uint64_t>(day));
    mix(static_cast<uint64_t>(continuation_index));
    mix(static_cast<uint64_t>(static_cast<uint32_t>(country_slot)));
    mix(static_cast<uint64_t>(static_cast<uint32_t>(technology)));
    mix(static_cast<uint64_t>(static_cast<uint16_t>(opcode)));
    return value == 0 ? 1 : value;
}

void country_peer_copy_reason(
        std::array<char, COUNTRY_PEER_REASON_CAPACITY> &destination,
        const char *source) noexcept {
    size_t index = 0;
    if (source != nullptr) {
        for (; index + 1u < destination.size() && source[index] != '\0'; ++index)
            destination[index] = source[index];
    }
    if (index < destination.size()) destination[index] = '\0';
    for (++index; index < destination.size(); ++index)
        destination[index] = '\0';
}

namespace {
constexpr uint32_t CPD2_MAGIC = 0x32445043u;
constexpr uint32_t PKCN_MAGIC = 0x4e434b50u;
constexpr uint32_t MAX_PROTOCOL_RECORDS = 1000000u;
constexpr uint32_t MAX_REASON_BYTES = 4096u;
constexpr uint32_t MAX_CANONICAL_BYTES = 64u * 1024u * 1024u;

void append_u8(std::vector<uint8_t> &out, uint8_t value) {
    out.push_back(value);
}

void append_u32(std::vector<uint8_t> &out, uint32_t value) {
    for (uint32_t i = 0; i < 4; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}

void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (uint32_t i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}

void append_i64(std::vector<uint8_t> &out, int64_t value) {
    append_u64(out, static_cast<uint64_t>(value));
}

void append_string(std::vector<uint8_t> &out, const std::string &value) {
    append_u32(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

bool read_u8(const uint8_t *bytes, size_t size, size_t &cursor, uint8_t &out) {
    if (cursor >= size) return false;
    out = bytes[cursor++];
    return true;
}

bool read_u32(const uint8_t *bytes, size_t size, size_t &cursor, uint32_t &out) {
    if (cursor > size || size - cursor < 4u) return false;
    out = static_cast<uint32_t>(bytes[cursor]) |
        (static_cast<uint32_t>(bytes[cursor + 1u]) << 8u) |
        (static_cast<uint32_t>(bytes[cursor + 2u]) << 16u) |
        (static_cast<uint32_t>(bytes[cursor + 3u]) << 24u);
    cursor += 4u;
    return true;
}

bool read_u64(const uint8_t *bytes, size_t size, size_t &cursor, uint64_t &out) {
    if (cursor > size || size - cursor < 8u) return false;
    out = 0;
    for (uint32_t i = 0; i < 8; ++i)
        out |= static_cast<uint64_t>(bytes[cursor + i]) << (i * 8u);
    cursor += 8u;
    return true;
}

bool read_i64(const uint8_t *bytes, size_t size, size_t &cursor, int64_t &out) {
    uint64_t bits = 0;
    if (!read_u64(bytes, size, cursor, bits)) return false;
    std::memcpy(&out, &bits, sizeof(out));
    return true;
}

bool read_string(const uint8_t *bytes, size_t size, size_t &cursor,
                 std::string &out) {
    uint32_t count = 0;
    if (!read_u32(bytes, size, cursor, count) || count > MAX_REASON_BYTES ||
        cursor > size || count > size - cursor)
        return false;
    out.assign(reinterpret_cast<const char *>(bytes + cursor), count);
    cursor += count;
    return true;
}

void append_receipt(std::vector<uint8_t> &out,
                    const CountryCommandReceipt &receipt) {
    append_u64(out, receipt.request_id);
    append_u32(out, receipt.producer_id);
    append_u64(out, receipt.sequence);
    append_i64(out, receipt.effective_day);
    append_u64(out, receipt.generation);
    append_u8(out, static_cast<uint8_t>(receipt.code));
    append_string(out, receipt.reason);
}

bool read_receipt(const uint8_t *bytes, size_t size, size_t &cursor,
                  CountryCommandReceipt &out) {
    uint8_t code = 0;
    if (!read_u64(bytes, size, cursor, out.request_id) ||
        !read_u32(bytes, size, cursor, out.producer_id) ||
        !read_u64(bytes, size, cursor, out.sequence) ||
        !read_i64(bytes, size, cursor, out.effective_day) ||
        !read_u64(bytes, size, cursor, out.generation) ||
        !read_u8(bytes, size, cursor, code) ||
        !read_string(bytes, size, cursor, out.reason))
        return false;
    if (code > static_cast<uint8_t>(
                   CountryCommandReceiptCode::REJECTED_AT_EXECUTION))
        return false;
    out.code = static_cast<CountryCommandReceiptCode>(code);
    return true;
}

bool read_pkcn_header(const std::vector<uint8_t> &bytes, uint32_t &schema,
                      uint64_t &catalog_hash, uint64_t &generation,
                      int64_t &committed_day, uint64_t &watermark) {
    size_t cursor = 0;
    uint32_t magic = 0;
    return read_u32(bytes.data(), bytes.size(), cursor, magic) &&
        magic == PKCN_MAGIC &&
        read_u32(bytes.data(), bytes.size(), cursor, schema) &&
        read_u64(bytes.data(), bytes.size(), cursor, catalog_hash) &&
        read_u64(bytes.data(), bytes.size(), cursor, generation) &&
        read_i64(bytes.data(), bytes.size(), cursor, committed_day) &&
        read_u64(bytes.data(), bytes.size(), cursor, watermark);
}
} // namespace

uint64_t country_checkpoint_checksum(const uint8_t *bytes, size_t size) noexcept {
    uint64_t hash = 1469598103934665603ull;
    if (bytes == nullptr) return hash;
    for (size_t i = 0; i < size; ++i) {
        hash ^= static_cast<uint64_t>(bytes[i]);
        hash *= 1099511628211ull;
    }
    return hash;
}

bool validate_country_core_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                      std::string &error) {
    error.clear();
    if (checkpoint.abi_version != COUNTRY_CHECKPOINT_ABI_VERSION) {
        error = "country_checkpoint_abi_incompatible";
        return false;
    }
    if (checkpoint.country_schema_version != COUNTRY_CHECKPOINT_SCHEMA_VERSION) {
        error = "country_checkpoint_schema_incompatible";
        return false;
    }
    if (checkpoint.session_epoch == 0 || checkpoint.catalog_hash == 0 ||
        checkpoint.generation == 0 || checkpoint.committed_day < -1 ||
        checkpoint.next_event_id == 0 || checkpoint.next_boundary_id == 0) {
        error = "country_checkpoint_header_invalid";
        return false;
    }
    if (checkpoint.canonical_pkcn.empty() ||
        checkpoint.canonical_pkcn.size() > MAX_CANONICAL_BYTES) {
        error = "country_checkpoint_payload_invalid";
        return false;
    }
    uint32_t schema = 0;
    uint64_t catalog = 0;
    uint64_t generation = 0;
    int64_t day = -1;
    uint64_t watermark = 0;
    if (!read_pkcn_header(checkpoint.canonical_pkcn, schema, catalog,
                          generation, day, watermark) ||
        schema != checkpoint.country_schema_version ||
        catalog != checkpoint.catalog_hash ||
        generation != checkpoint.generation ||
        day != checkpoint.committed_day ||
        watermark != checkpoint.command_watermark) {
        error = "country_checkpoint_pkcn_header_mismatch";
        return false;
    }
    if (checkpoint.pending_protocol.size() > MAX_PROTOCOL_RECORDS ||
        checkpoint.request_states.size() > MAX_PROTOCOL_RECORDS ||
        checkpoint.terminal_receipts.size() > MAX_PROTOCOL_RECORDS) {
        error = "country_checkpoint_protocol_count_invalid";
        return false;
    }
    std::unordered_set<uint64_t> pending_orders;
    std::unordered_set<uint64_t> pending_requests;
    for (const CountryPendingCommandProtocol &entry :
         checkpoint.pending_protocol) {
        if (entry.submit_order == 0 || entry.request_id == 0 ||
            entry.submit_order > checkpoint.command_watermark ||
            !pending_orders.insert(entry.submit_order).second ||
            !pending_requests.insert(entry.request_id).second) {
            error = "country_checkpoint_pending_protocol_invalid";
            return false;
        }
    }
    std::unordered_map<uint64_t, CountryCommandReceiptCode> state_codes;
    for (const CountryCommandReceipt &receipt : checkpoint.request_states) {
        if (receipt.request_id == 0 || receipt.effective_day < 0 ||
            receipt.reason.size() > MAX_REASON_BYTES ||
            !state_codes.emplace(receipt.request_id, receipt.code).second) {
            error = "country_checkpoint_request_state_invalid";
            return false;
        }
    }
    for (uint64_t request_id : pending_requests) {
        const auto found = state_codes.find(request_id);
        if (found == state_codes.end() ||
            found->second != CountryCommandReceiptCode::ACCEPTED) {
            error = "country_checkpoint_pending_receipt_missing";
            return false;
        }
    }
    for (const CountryCommandReceipt &receipt : checkpoint.terminal_receipts) {
        const auto found = state_codes.find(receipt.request_id);
        if (receipt.request_id == 0 || receipt.effective_day < 0 ||
            receipt.reason.size() > MAX_REASON_BYTES ||
            (receipt.code != CountryCommandReceiptCode::COMMITTED &&
             receipt.code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION) ||
            found == state_codes.end() || found->second != receipt.code) {
            error = "country_checkpoint_terminal_receipt_invalid";
            return false;
        }
    }
    return true;
}

bool encode_country_core_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                    std::vector<uint8_t> &out,
                                    std::string &error) {
    if (!validate_country_core_checkpoint(checkpoint, error)) return false;
    out.clear();
    out.reserve(128u + checkpoint.canonical_pkcn.size() +
        checkpoint.pending_protocol.size() * 28u);
    append_u32(out, CPD2_MAGIC);
    append_u32(out, checkpoint.abi_version);
    append_u32(out, checkpoint.country_schema_version);
    append_u32(out, 0u);
    append_u64(out, checkpoint.session_epoch);
    append_u64(out, checkpoint.catalog_hash);
    append_u64(out, checkpoint.generation);
    append_i64(out, checkpoint.committed_day);
    append_u64(out, checkpoint.business_state_hash);
    append_u64(out, checkpoint.command_watermark);
    append_u64(out, checkpoint.next_event_id);
    append_u64(out, checkpoint.next_boundary_id);
    append_u32(out, static_cast<uint32_t>(checkpoint.canonical_pkcn.size()));
    append_u64(out, country_checkpoint_checksum(checkpoint.canonical_pkcn.data(),
                                                checkpoint.canonical_pkcn.size()));
    out.insert(out.end(), checkpoint.canonical_pkcn.begin(),
               checkpoint.canonical_pkcn.end());
    append_u32(out, static_cast<uint32_t>(checkpoint.pending_protocol.size()));
    for (const CountryPendingCommandProtocol &entry : checkpoint.pending_protocol) {
        append_u64(out, entry.submit_order);
        append_u64(out, entry.request_id);
        append_u32(out, entry.producer_id);
        append_u64(out, entry.observed_generation);
    }
    append_u32(out, static_cast<uint32_t>(checkpoint.request_states.size()));
    for (const CountryCommandReceipt &receipt : checkpoint.request_states)
        append_receipt(out, receipt);
    append_u32(out, static_cast<uint32_t>(checkpoint.terminal_receipts.size()));
    for (const CountryCommandReceipt &receipt : checkpoint.terminal_receipts)
        append_receipt(out, receipt);
    append_u64(out, country_checkpoint_checksum(out.data(), out.size()));
    return true;
}

bool decode_country_core_checkpoint(const uint8_t *bytes, size_t size,
                                    CountryCoreCheckpoint &out,
                                    std::string &error) {
    error.clear();
    constexpr size_t MIN_BYTES = 104u;
    if (bytes == nullptr || size < MIN_BYTES ||
        size > static_cast<size_t>(MAX_CANONICAL_BYTES) + 256u * 1024u * 1024u) {
        error = "country_checkpoint_truncated";
        return false;
    }
    size_t checksum_cursor = size - sizeof(uint64_t);
    uint64_t encoded_checksum = 0;
    if (!read_u64(bytes, size, checksum_cursor, encoded_checksum) ||
        encoded_checksum != country_checkpoint_checksum(bytes, size - sizeof(uint64_t))) {
        error = "country_checkpoint_checksum_failed";
        return false;
    }
    CountryCoreCheckpoint parsed;
    size_t cursor = 0;
    uint32_t magic = 0;
    uint32_t flags = 0;
    uint32_t payload_size = 0;
    uint64_t payload_checksum = 0;
    if (!read_u32(bytes, size, cursor, magic) || magic != CPD2_MAGIC ||
        !read_u32(bytes, size, cursor, parsed.abi_version) ||
        !read_u32(bytes, size, cursor, parsed.country_schema_version) ||
        !read_u32(bytes, size, cursor, flags) || flags != 0 ||
        !read_u64(bytes, size, cursor, parsed.session_epoch) ||
        !read_u64(bytes, size, cursor, parsed.catalog_hash) ||
        !read_u64(bytes, size, cursor, parsed.generation) ||
        !read_i64(bytes, size, cursor, parsed.committed_day) ||
        !read_u64(bytes, size, cursor, parsed.business_state_hash) ||
        !read_u64(bytes, size, cursor, parsed.command_watermark) ||
        !read_u64(bytes, size, cursor, parsed.next_event_id) ||
        !read_u64(bytes, size, cursor, parsed.next_boundary_id) ||
        !read_u32(bytes, size, cursor, payload_size) ||
        !read_u64(bytes, size, cursor, payload_checksum)) {
        error = "country_checkpoint_header_invalid";
        return false;
    }
    if (payload_size == 0 || payload_size > MAX_CANONICAL_BYTES ||
        cursor > size - sizeof(uint64_t) ||
        payload_size > size - sizeof(uint64_t) - cursor) {
        error = "country_checkpoint_payload_invalid";
        return false;
    }
    parsed.canonical_pkcn.assign(bytes + cursor, bytes + cursor + payload_size);
    cursor += payload_size;
    if (country_checkpoint_checksum(parsed.canonical_pkcn.data(),
                                    parsed.canonical_pkcn.size()) != payload_checksum) {
        error = "country_checkpoint_payload_checksum_failed";
        return false;
    }
    uint32_t count = 0;
    if (!read_u32(bytes, size, cursor, count) || count > MAX_PROTOCOL_RECORDS) {
        error = "country_checkpoint_pending_protocol_invalid";
        return false;
    }
    parsed.pending_protocol.resize(count);
    for (CountryPendingCommandProtocol &entry : parsed.pending_protocol) {
        if (!read_u64(bytes, size, cursor, entry.submit_order) ||
            !read_u64(bytes, size, cursor, entry.request_id) ||
            !read_u32(bytes, size, cursor, entry.producer_id) ||
            !read_u64(bytes, size, cursor, entry.observed_generation)) {
            error = "country_checkpoint_pending_protocol_truncated";
            return false;
        }
    }
    if (!read_u32(bytes, size, cursor, count) || count > MAX_PROTOCOL_RECORDS) {
        error = "country_checkpoint_request_state_invalid";
        return false;
    }
    parsed.request_states.resize(count);
    for (CountryCommandReceipt &receipt : parsed.request_states) {
        if (!read_receipt(bytes, size - sizeof(uint64_t), cursor, receipt)) {
            error = "country_checkpoint_request_state_truncated";
            return false;
        }
    }
    if (!read_u32(bytes, size, cursor, count) || count > MAX_PROTOCOL_RECORDS) {
        error = "country_checkpoint_terminal_receipt_invalid";
        return false;
    }
    parsed.terminal_receipts.resize(count);
    for (CountryCommandReceipt &receipt : parsed.terminal_receipts) {
        if (!read_receipt(bytes, size - sizeof(uint64_t), cursor, receipt)) {
            error = "country_checkpoint_terminal_receipt_truncated";
            return false;
        }
    }
    if (cursor != size - sizeof(uint64_t)) {
        error = "country_checkpoint_tail_invalid";
        return false;
    }
    parsed.checkpoint_hash = encoded_checksum;
    if (!validate_country_core_checkpoint(parsed, error)) return false;
    out = std::move(parsed);
    return true;
}

const char *country_core_step_status_name(CountryCoreStepStatus status) {
    switch (status) {
    case CountryCoreStepStatus::PROGRESS: return "progress";
    case CountryCoreStepStatus::NEED_PEER_RESULTS: return "need_peer_results";
    case CountryCoreStepStatus::BOUNDARY_COMMITTED: return "boundary_committed";
    case CountryCoreStepStatus::DAY_QUIESCENT: return "day_quiescent";
    case CountryCoreStepStatus::REJECTED: return "rejected";
    case CountryCoreStepStatus::FAULTED: return "faulted";
    case CountryCoreStepStatus::OFF: return "off";
    }
    return "faulted";
}

} // namespace pk

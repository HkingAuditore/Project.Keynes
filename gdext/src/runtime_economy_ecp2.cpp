#include "runtime_economy_ecp2.h"

#include "economy_runtime.h"
#include "economy_runtime_binary_codec.h"
#include "runtime_economy_state.h"

#include <algorithm>
#include <cstring>

namespace pk {
namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

using persistence_codec::SAVE_MAGIC;
using persistence_codec::SAVE_SECTION_AUDIT;
using persistence_codec::SAVE_SECTION_BUILDINGS;
using persistence_codec::SAVE_SECTION_CANAL_PROJECTS;
using persistence_codec::SAVE_SECTION_CANAL_QUOTES;
using persistence_codec::SAVE_SECTION_CADENCE_STATE;
using persistence_codec::SAVE_SECTION_CELLS;
using persistence_codec::SAVE_SECTION_COMMANDS;
using persistence_codec::SAVE_SECTION_CONSTRUCTION;
using persistence_codec::SAVE_SECTION_COUNTRY_GOOD;
using persistence_codec::SAVE_SECTION_COUNTRY_PARTNER;
using persistence_codec::SAVE_SECTION_END;
using persistence_codec::SAVE_SECTION_FAMILY_EXPEDITIONS;
using persistence_codec::SAVE_SECTION_FAMILY_INFLUENCES;
using persistence_codec::SAVE_SECTION_FAMILY_MEMBERSHIP;
using persistence_codec::SAVE_SECTION_FAMILY_OWNERSHIP;
using persistence_codec::SAVE_SECTION_FAMILY_RECORDS;
using persistence_codec::SAVE_SECTION_FAMILY_TRAITS;
using persistence_codec::SAVE_SECTION_FAMILY_TRAIT_COMMANDS;
using persistence_codec::SAVE_SECTION_FISCAL;
using persistence_codec::SAVE_SECTION_FISCAL_PEER;
using persistence_codec::SAVE_SECTION_RESOURCE_STOCK;
using persistence_codec::SAVE_SECTION_HEADER;
using persistence_codec::SAVE_SECTION_LABOR_SIGNALS;
using persistence_codec::SAVE_SECTION_MARKETS;
using persistence_codec::SAVE_SECTION_MODIFIERS;
using persistence_codec::SAVE_SECTION_PAGES;
using persistence_codec::SAVE_SECTION_PERSON_NEEDS;
using persistence_codec::SAVE_SECTION_PERSON_RECORDS;
using persistence_codec::SAVE_SECTION_PRICE_CEILINGS;
using persistence_codec::SAVE_SECTION_SETTLEMENT_NAMES;
using persistence_codec::SAVE_SECTION_SIGNALS;
using persistence_codec::SAVE_SECTION_TARIFF_HISTORY;
using persistence_codec::SAVE_SECTION_TRADE_FLOWS;
using persistence_codec::SAVE_SECTION_TRADE_ORDERS;

void append_u32(std::vector<uint8_t> &out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 8u) & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 16u) & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 24u) & 0xffu));
}

void append_i32(std::vector<uint8_t> &out, int32_t value) {
    append_u32(out, static_cast<uint32_t>(value));
}

void append_i64(std::vector<uint8_t> &out, int64_t value) {
    append_u32(out, static_cast<uint32_t>(value));
    append_u32(out, static_cast<uint32_t>(static_cast<uint64_t>(value) >> 32u));
}

void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (8 * i)) & 0xffu));
}

void append_u8(std::vector<uint8_t> &out, uint8_t value) {
    out.push_back(value);
}

uint64_t fnv1a_bytes(const uint8_t *data, size_t size) noexcept {
    uint64_t hash = FNV_OFFSET;
    for (size_t i = 0; i < size; ++i) {
        hash ^= static_cast<uint64_t>(data[i]);
        hash *= FNV_PRIME;
    }
    return hash;
}

bool read_u32(const uint8_t *&p, const uint8_t *end, uint32_t &value) {
    if (end - p < 4) return false;
    value = static_cast<uint32_t>(p[0]) |
        (static_cast<uint32_t>(p[1]) << 8u) |
        (static_cast<uint32_t>(p[2]) << 16u) |
        (static_cast<uint32_t>(p[3]) << 24u);
    p += 4;
    return true;
}

bool read_i32(const uint8_t *&p, const uint8_t *end, int32_t &value) {
    uint32_t raw = 0;
    if (!read_u32(p, end, raw)) return false;
    value = static_cast<int32_t>(raw);
    return true;
}

bool read_i64(const uint8_t *&p, const uint8_t *end, int64_t &value) {
    uint32_t lo = 0;
    uint32_t hi = 0;
    if (!read_u32(p, end, lo) || !read_u32(p, end, hi)) return false;
    value = static_cast<int64_t>(
        static_cast<uint64_t>(lo) |
        (static_cast<uint64_t>(hi) << 32u));
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

bool read_u8(const uint8_t *&p, const uint8_t *end, uint8_t &value) {
    if (p >= end) return false;
    value = *p++;
    return true;
}

void append_envelope(std::vector<uint8_t> &out,
                     const RuntimeEconomyEcp2Envelope &envelope) {
    append_i32(out, envelope.schema_version);
    append_u32(out, envelope.abi_version);
    append_i32(out, envelope.cell_count);
    append_i32(out, envelope.market_count);
    append_i32(out, envelope.good_count);
    append_i64(out, envelope.catalog_hash);
    append_i64(out, envelope.building_catalog_hash);
    append_i64(out, envelope.settlement_catalog_hash);
    append_i64(out, envelope.family_catalog_hash);
    append_i64(out, envelope.person_catalog_hash);
    append_i32(out, envelope.market_cycle_days);
    append_i32(out, envelope.plan_cycle_days);
    append_i32(out, envelope.investment_cycle_days);
    append_i64(out, envelope.epoch_id);
    append_i64(out, envelope.last_committed_day);
    append_i64(out, envelope.current_day);
    append_i64(out, envelope.sample_day);
    append_i32(out, envelope.epoch_days);
    append_u64(out, envelope.committed_generation);
    append_i64(out, envelope.seed);
}

bool read_envelope(const uint8_t *&p, const uint8_t *end,
                   RuntimeEconomyEcp2Envelope &envelope) {
    if (!read_i32(p, end, envelope.schema_version) ||
        !read_u32(p, end, envelope.abi_version) ||
        !read_i32(p, end, envelope.cell_count) ||
        !read_i32(p, end, envelope.market_count) ||
        !read_i32(p, end, envelope.good_count) ||
        !read_i64(p, end, envelope.catalog_hash) ||
        !read_i64(p, end, envelope.building_catalog_hash) ||
        !read_i64(p, end, envelope.settlement_catalog_hash) ||
        !read_i64(p, end, envelope.family_catalog_hash) ||
        !read_i64(p, end, envelope.person_catalog_hash) ||
        !read_i32(p, end, envelope.market_cycle_days) ||
        !read_i32(p, end, envelope.plan_cycle_days) ||
        !read_i32(p, end, envelope.investment_cycle_days) ||
        !read_i64(p, end, envelope.epoch_id) ||
        !read_i64(p, end, envelope.last_committed_day) ||
        !read_i64(p, end, envelope.current_day) ||
        !read_i64(p, end, envelope.sample_day) ||
        !read_i32(p, end, envelope.epoch_days) ||
        !read_u64(p, end, envelope.committed_generation) ||
        !read_i64(p, end, envelope.seed)) {
        return false;
    }
    return p <= end;
}

void append_resume(std::vector<uint8_t> &out,
                   const RuntimeEconomyEcp2Resume &resume) {
    append_u8(out, resume.epoch_active);
    append_i32(out, resume.native_stage);
    append_u32(out, resume.graph_completed_mask);
    append_i64(out, resume.sample_day);
    append_i64(out, resume.current_day);
    append_i64(out, resume.epoch_id);
    append_i32(out, resume.epoch_days);
    append_u64(out, resume.publish_cursor);
    append_i32(out, resume.publish_order_cursor);
    append_i32(out, resume.publish_line_cursor);
    append_i32(out, resume.executed_stage);
    append_i32(out, resume.publish_phase);
    append_u32(out, resume.stage_index);
    append_u32(out, resume.cell_cursor);
    append_u32(out, resume.group_cursor);
    append_u32(out, resume.command_cursor);
    append_u32(out, resume.structural_cursor);
    append_u32(out, resume.building_cell_cursor);
    append_u32(out, resume.plan_evaluate_cursor);
    append_i32(out, resume.building_plan_phase);
    append_i32(out, resume.household_market_phase);
    append_i32(out, resume.household_post_cursor);
    append_i32(out, resume.building_commit_phase);
    append_i32(out, resume.building_commit_cursor);
    append_i32(out, resume.building_finalize_phase);
    append_i32(out, resume.family_commit_cursor);
    append_i32(out, resume.family_commit_phase);
    append_i32(out, resume.person_commit_cursor);
    append_i32(out, resume.person_commit_phase);
    append_u32(out, resume.slice_index);
    append_u8(out, resume.waiting_for_peer);
    append_u8(out, resume.evaluate_phase);
    append_u8(out, resume.trade_plan_phase);
    append_u32(out, resume.trade_plan_scan_cursor);
    append_u32(out, resume.trade_plan_route_cursor);
}

bool read_resume(const uint8_t *&p, const uint8_t *end,
                 RuntimeEconomyEcp2Resume &resume) {
    return read_u8(p, end, resume.epoch_active) &&
           read_i32(p, end, resume.native_stage) &&
           read_u32(p, end, resume.graph_completed_mask) &&
           read_i64(p, end, resume.sample_day) &&
           read_i64(p, end, resume.current_day) &&
           read_i64(p, end, resume.epoch_id) &&
           read_i32(p, end, resume.epoch_days) &&
           read_u64(p, end, resume.publish_cursor) &&
           read_i32(p, end, resume.publish_order_cursor) &&
           read_i32(p, end, resume.publish_line_cursor) &&
           read_i32(p, end, resume.executed_stage) &&
           read_i32(p, end, resume.publish_phase) &&
           read_u32(p, end, resume.stage_index) &&
           read_u32(p, end, resume.cell_cursor) &&
           read_u32(p, end, resume.group_cursor) &&
           read_u32(p, end, resume.command_cursor) &&
           read_u32(p, end, resume.structural_cursor) &&
           read_u32(p, end, resume.building_cell_cursor) &&
           read_u32(p, end, resume.plan_evaluate_cursor) &&
           read_i32(p, end, resume.building_plan_phase) &&
           read_i32(p, end, resume.household_market_phase) &&
           read_i32(p, end, resume.household_post_cursor) &&
           read_i32(p, end, resume.building_commit_phase) &&
           read_i32(p, end, resume.building_commit_cursor) &&
           read_i32(p, end, resume.building_finalize_phase) &&
           read_i32(p, end, resume.family_commit_cursor) &&
           read_i32(p, end, resume.family_commit_phase) &&
           read_i32(p, end, resume.person_commit_cursor) &&
           read_i32(p, end, resume.person_commit_phase) &&
           read_u32(p, end, resume.slice_index) &&
           read_u8(p, end, resume.waiting_for_peer) &&
           read_u8(p, end, resume.evaluate_phase) &&
           read_u8(p, end, resume.trade_plan_phase) &&
           read_u32(p, end, resume.trade_plan_scan_cursor) &&
           read_u32(p, end, resume.trade_plan_route_cursor) &&
           p <= end;
}

bool parse_pkec_chunk_section(const uint8_t *data, size_t size,
                              uint16_t &section_out) {
    if (size < 16u) return false;
    uint32_t magic = static_cast<uint32_t>(data[0]) |
        (static_cast<uint32_t>(data[1]) << 8u) |
        (static_cast<uint32_t>(data[2]) << 16u) |
        (static_cast<uint32_t>(data[3]) << 24u);
    if (magic != SAVE_MAGIC) return false;
    section_out = static_cast<uint16_t>(data[6]) |
        static_cast<uint16_t>(static_cast<uint16_t>(data[7]) << 8u);
    return true;
}

size_t pkec_chunk_size(const uint8_t *data, size_t remaining) {
    if (remaining < 16u) return 0;
    uint32_t magic = static_cast<uint32_t>(data[0]) |
        (static_cast<uint32_t>(data[1]) << 8u) |
        (static_cast<uint32_t>(data[2]) << 16u) |
        (static_cast<uint32_t>(data[3]) << 24u);
    if (magic != SAVE_MAGIC) return 0;
    uint32_t payload_size = static_cast<uint32_t>(data[12]) |
        (static_cast<uint32_t>(data[13]) << 8u) |
        (static_cast<uint32_t>(data[14]) << 16u) |
        (static_cast<uint32_t>(data[15]) << 24u);
    const size_t total = 16u + static_cast<size_t>(payload_size);
    return total <= remaining ? total : 0;
}

} // namespace

void ecp2_collect_pkec_chunks_for_section(
        const std::unordered_map<uint32_t, std::vector<uint8_t>> &domain_blobs,
        uint16_t section, std::vector<std::vector<uint8_t>> &out) {
    const uint32_t domain = ecp2_domain_for_pkec_section(section);
    const auto found = domain_blobs.find(domain);
    if (found == domain_blobs.end()) return;
    const std::vector<uint8_t> &blob = found->second;
    size_t cursor = 0;
    while (cursor < blob.size()) {
        const size_t chunk_size = pkec_chunk_size(blob.data() + cursor,
                                                  blob.size() - cursor);
        if (chunk_size == 0) break;
        uint16_t chunk_section = 0;
        if (!parse_pkec_chunk_section(blob.data() + cursor, chunk_size,
                                      chunk_section)) {
            break;
        }
        if (chunk_section == section) {
            out.emplace_back(blob.begin() + static_cast<std::ptrdiff_t>(cursor),
                             blob.begin() +
                                 static_cast<std::ptrdiff_t>(cursor + chunk_size));
        }
        cursor += chunk_size;
    }
}

uint32_t ecp2_domain_for_pkec_section(uint16_t section) noexcept {
    switch (section) {
    case SAVE_SECTION_HEADER:
        return ECP2_DOMAIN_ENVELOPE;
    case SAVE_SECTION_PAGES:
        return ECP2_DOMAIN_POPULATION;
    case SAVE_SECTION_MARKETS:
    case SAVE_SECTION_PRICE_CEILINGS:
        return ECP2_DOMAIN_MARKETS;
    case SAVE_SECTION_CELLS:
        return ECP2_DOMAIN_CELLS;
    case SAVE_SECTION_SETTLEMENT_NAMES:
        return ECP2_DOMAIN_SETTLEMENTS;
    case SAVE_SECTION_BUILDINGS:
    case SAVE_SECTION_CONSTRUCTION:
        return ECP2_DOMAIN_BUILDINGS;
    case SAVE_SECTION_TRADE_ORDERS:
        return ECP2_DOMAIN_TRADE_ORDERS;
    case SAVE_SECTION_FAMILY_RECORDS:
    case SAVE_SECTION_FAMILY_MEMBERSHIP:
    case SAVE_SECTION_FAMILY_OWNERSHIP:
    case SAVE_SECTION_PERSON_RECORDS:
    case SAVE_SECTION_PERSON_NEEDS:
    case SAVE_SECTION_FAMILY_TRAITS:
    case SAVE_SECTION_FAMILY_INFLUENCES:
    case SAVE_SECTION_FAMILY_TRAIT_COMMANDS:
    case SAVE_SECTION_FAMILY_EXPEDITIONS:
        return ECP2_DOMAIN_FAMILY;
    case SAVE_SECTION_TRADE_FLOWS:
    case SAVE_SECTION_TARIFF_HISTORY:
    case SAVE_SECTION_COUNTRY_GOOD:
    case SAVE_SECTION_COUNTRY_PARTNER:
        return ECP2_DOMAIN_TRADE_FLOWS;
    case SAVE_SECTION_FISCAL:
    case SAVE_SECTION_FISCAL_PEER:
        return ECP2_DOMAIN_FISCAL;
    case SAVE_SECTION_RESOURCE_STOCK:
        return ECP2_DOMAIN_RESOURCE;
    case SAVE_SECTION_COMMANDS:
        return ECP2_DOMAIN_COMMANDS;
    case SAVE_SECTION_AUDIT:
        return ECP2_DOMAIN_AUDIT;
    case SAVE_SECTION_SIGNALS:
    case SAVE_SECTION_LABOR_SIGNALS:
    case SAVE_SECTION_CADENCE_STATE:
        return ECP2_DOMAIN_SIGNALS;
    case SAVE_SECTION_MODIFIERS:
        return ECP2_DOMAIN_MODIFIERS;
    case SAVE_SECTION_CANAL_QUOTES:
    case SAVE_SECTION_CANAL_PROJECTS:
        return ECP2_DOMAIN_CANAL;
    default:
        return 0;
    }
}

bool ecp2_has_required_domains(uint32_t mask, uint32_t required) noexcept {
    return (mask & required) == required;
}

bool encode_ecp2(const RuntimeEconomyEcp2State &state,
                 std::vector<uint8_t> &out, std::string &error) {
    error.clear();
    out.clear();
    out.reserve(256);
    append_u32(out, RUNTIME_ECONOMY_ECP2_MARKER);
    append_u32(out, state.abi_version);
    append_u32(out, static_cast<uint32_t>(state.schema_version));
    append_u32(out, state.authority_domain_mask);
    const size_t hash_at = out.size();
    append_u64(out, 0u);

    std::vector<uint8_t> body;
    if ((state.authority_domain_mask & ECP2_DOMAIN_ENVELOPE) != 0) {
        // Typed envelope first, then any PKEC HEADER chunks captured under the
        // same domain bit so restore can rebuild SAVE_SECTION_HEADER.
        std::vector<uint8_t> envelope_bytes;
        append_envelope(envelope_bytes, state.envelope);
        const auto header_blob = state.domain_blobs.find(ECP2_DOMAIN_ENVELOPE);
        if (header_blob != state.domain_blobs.end()) {
            envelope_bytes.insert(envelope_bytes.end(),
                                  header_blob->second.begin(),
                                  header_blob->second.end());
        }
        append_u32(body, static_cast<uint32_t>(envelope_bytes.size()));
        body.insert(body.end(), envelope_bytes.begin(), envelope_bytes.end());
    }

    static constexpr uint32_t kDomainBits[] = {
        ECP2_DOMAIN_POPULATION, ECP2_DOMAIN_MARKETS, ECP2_DOMAIN_CELLS,
        ECP2_DOMAIN_SETTLEMENTS, ECP2_DOMAIN_BUILDINGS, ECP2_DOMAIN_TRADE_ORDERS,
        ECP2_DOMAIN_FAMILY, ECP2_DOMAIN_RESOURCE, ECP2_DOMAIN_TRADE_FLOWS,
        ECP2_DOMAIN_FISCAL, ECP2_DOMAIN_COMMANDS, ECP2_DOMAIN_AUDIT,
        ECP2_DOMAIN_SIGNALS, ECP2_DOMAIN_MODIFIERS, ECP2_DOMAIN_CANAL,
        ECP2_DOMAIN_EPOCH_RESUME, ECP2_DOMAIN_OWNED_STATE,
    };
    for (const uint32_t bit : kDomainBits) {
        if ((state.authority_domain_mask & bit) == 0) continue;
        const auto found = state.domain_blobs.find(bit);
        std::vector<uint8_t> payload;
        if (bit == ECP2_DOMAIN_EPOCH_RESUME) {
            append_resume(payload, state.resume);
        } else if (found != state.domain_blobs.end()) {
            payload = found->second;
        }
        append_u32(body, bit);
        append_u32(body, static_cast<uint32_t>(payload.size()));
        body.insert(body.end(), payload.begin(), payload.end());
    }

    out.insert(out.end(), body.begin(), body.end());
    const uint64_t hash = fnv1a_bytes(out.data() + hash_at + 8u,
                                      out.size() - hash_at - 8u);
    out[hash_at] = static_cast<uint8_t>(hash & 0xffu);
    out[hash_at + 1] = static_cast<uint8_t>((hash >> 8u) & 0xffu);
    out[hash_at + 2] = static_cast<uint8_t>((hash >> 16u) & 0xffu);
    out[hash_at + 3] = static_cast<uint8_t>((hash >> 24u) & 0xffu);
    out[hash_at + 4] = static_cast<uint8_t>((hash >> 32u) & 0xffu);
    out[hash_at + 5] = static_cast<uint8_t>((hash >> 40u) & 0xffu);
    out[hash_at + 6] = static_cast<uint8_t>((hash >> 48u) & 0xffu);
    out[hash_at + 7] = static_cast<uint8_t>((hash >> 56u) & 0xffu);
    return true;
}

bool decode_ecp2(const uint8_t *data, size_t size,
                 RuntimeEconomyEcp2State &out, std::string &error) {
    error.clear();
    out = RuntimeEconomyEcp2State{};
    if (data == nullptr || size < 24u) {
        error = "ecp2_truncated";
        return false;
    }
    const uint8_t *p = data;
    const uint8_t *end = data + size;
    uint32_t marker = 0;
    uint32_t abi = 0;
    uint32_t schema = 0;
    uint32_t mask = 0;
    uint64_t content_hash = 0;
    if (!read_u32(p, end, marker) || marker != RUNTIME_ECONOMY_ECP2_MARKER ||
        !read_u32(p, end, abi) || !read_u32(p, end, schema) ||
        !read_u32(p, end, mask) || !read_u64(p, end, content_hash)) {
        error = "ecp2_header_invalid";
        return false;
    }
    const uint64_t expected_hash = fnv1a_bytes(p, static_cast<size_t>(end - p));
    if (expected_hash != content_hash) {
        error = "ecp2_content_hash_mismatch";
        return false;
    }
    out.abi_version = abi;
    out.schema_version = static_cast<int32_t>(schema);
    out.authority_domain_mask = mask;
    out.content_hash = content_hash;

    if (abi != RUNTIME_ECONOMY_ECP2_ABI_VERSION) {
        error = "ecp2_abi_version_incompatible";
        return false;
    }
    if (schema != static_cast<uint32_t>(RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION)) {
        error = "ecp2_schema_version_incompatible";
        return false;
    }
    constexpr uint32_t known_domains = ECP2_DOMAIN_FULL_AUTHORITY |
        ECP2_DOMAIN_EPOCH_RESUME | ECP2_DOMAIN_OWNED_STATE;
    if ((mask & ~known_domains) != 0u ||
        (mask & ECP2_DOMAIN_ENVELOPE) == 0u) {
        error = "ecp2_domain_mask_invalid";
        return false;
    }

    if ((mask & ECP2_DOMAIN_ENVELOPE) != 0) {
        uint32_t envelope_size = 0;
        if (!read_u32(p, end, envelope_size) ||
            envelope_size > static_cast<uint32_t>(end - p)) {
            error = "ecp2_envelope_truncated";
            return false;
        }
        const uint8_t *ep = p;
        const uint8_t *eend = p + envelope_size;
        if (!read_envelope(ep, eend, out.envelope)) {
            error = "ecp2_envelope_invalid";
            return false;
        }
        // Bytes after the typed envelope are concatenated PKEC HEADER chunks.
        if (ep < eend) {
            out.domain_blobs[ECP2_DOMAIN_ENVELOPE].assign(ep, eend);
        }
        p += envelope_size;
    }

    uint32_t seen_domain_bits = ECP2_DOMAIN_ENVELOPE;
    while (p < end) {
        uint32_t domain_bit = 0;
        uint32_t payload_size = 0;
        if (!read_u32(p, end, domain_bit) || !read_u32(p, end, payload_size) ||
            payload_size > static_cast<uint32_t>(end - p)) {
            error = "ecp2_domain_truncated";
            return false;
        }
        const uint8_t *payload = p;
        p += payload_size;
        if (domain_bit == 0 || (domain_bit & (domain_bit - 1u)) != 0u ||
            (domain_bit & ~known_domains) != 0u ||
            (seen_domain_bits & domain_bit) != 0u) {
            error = "ecp2_domain_duplicate_or_invalid";
            return false;
        }
        seen_domain_bits |= domain_bit;
        if (domain_bit == ECP2_DOMAIN_EPOCH_RESUME) {
            const uint8_t *rp = payload;
            const uint8_t *rend = payload + payload_size;
            if (!read_resume(rp, rend, out.resume)) {
                error = "ecp2_resume_invalid";
                return false;
            }
            continue;
        }
        out.domain_blobs[domain_bit].assign(payload, payload + payload_size);
    }
    if (p != end) {
        error = "ecp2_trailing_bytes";
        return false;
    }
    return true;
}

bool runtime_economy_ecp2_self_test(std::string &error) {
    error.clear();
    RuntimeEconomyEcp2State state;
    state.authority_domain_mask = ECP2_DOMAIN_ENVELOPE;
    state.envelope.schema_version = RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION;
    state.envelope.cell_count = 4;
    state.envelope.market_count = 2;
    state.envelope.good_count = 3;
    state.envelope.catalog_hash = 17;
    state.envelope.last_committed_day = 9;
    state.envelope.current_day = 10;

    std::vector<uint8_t> wire;
    if (!encode_ecp2(state, wire, error)) return false;
    RuntimeEconomyEcp2State roundtrip;
    if (!decode_ecp2(wire.data(), wire.size(), roundtrip, error)) return false;
    if (roundtrip.envelope.cell_count != 4 ||
        roundtrip.envelope.catalog_hash != 17 ||
        roundtrip.envelope.last_committed_day != 9) {
        error = "ecp2_envelope_roundtrip_failed";
        return false;
    }

    state.authority_domain_mask =
        ECP2_DOMAIN_ENVELOPE | ECP2_DOMAIN_AUDIT;
    state.domain_blobs[ECP2_DOMAIN_AUDIT] = {0x43, 0x45, 0x4b, 0x50, 0x34,
                                             0x00, 0x07, 0x00, 0x01, 0x00,
                                             0x00, 0x00, 0x02, 0x00, 0x00,
                                             0x00, 0xaa, 0xbb};
    wire.clear();
    if (!encode_ecp2(state, wire, error)) return false;
    roundtrip = RuntimeEconomyEcp2State{};
    if (!decode_ecp2(wire.data(), wire.size(), roundtrip, error)) return false;
    const auto audit = roundtrip.domain_blobs.find(ECP2_DOMAIN_AUDIT);
    if (audit == roundtrip.domain_blobs.end() ||
        audit->second.size() != state.domain_blobs[ECP2_DOMAIN_AUDIT].size()) {
        error = "ecp2_opaque_domain_roundtrip_failed";
        return false;
    }

    // HEADER PKEC chunks must survive under the envelope domain payload.
    state.authority_domain_mask =
        ECP2_DOMAIN_ENVELOPE | ECP2_DOMAIN_EPOCH_RESUME;
    state.domain_blobs[ECP2_DOMAIN_ENVELOPE] = {
        0x50, 0x4b, 0x45, 0x43, 0x34, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x7e};
    state.resume.epoch_active = 1;
    state.resume.native_stage = 4;
    state.resume.cell_cursor = 12;
    state.resume.building_plan_phase = 1;
    state.resume.trade_plan_phase = 2;
    wire.clear();
    if (!encode_ecp2(state, wire, error)) return false;
    roundtrip = RuntimeEconomyEcp2State{};
    if (!decode_ecp2(wire.data(), wire.size(), roundtrip, error)) return false;
    const auto header = roundtrip.domain_blobs.find(ECP2_DOMAIN_ENVELOPE);
    if (header == roundtrip.domain_blobs.end() ||
        header->second != state.domain_blobs[ECP2_DOMAIN_ENVELOPE]) {
        error = "ecp2_header_chunk_roundtrip_failed";
        return false;
    }
    if (roundtrip.resume.epoch_active != 1 ||
        roundtrip.resume.native_stage != 4 ||
        roundtrip.resume.cell_cursor != 12 ||
        roundtrip.resume.building_plan_phase != 1 ||
        roundtrip.resume.trade_plan_phase != 2) {
        error = "ecp2_resume_roundtrip_failed";
        return false;
    }
    // A mid-epoch checkpoint is content-addressed. Corrupting a cursor or a
    // typed domain must fail before restore can mutate the live authority.
    if (wire.size() < 32u) {
        error = "ecp2_mid_epoch_wire_too_small";
        return false;
    }
    std::vector<uint8_t> tampered = wire;
    tampered.back() ^= 0x01u;
    RuntimeEconomyEcp2State ignored;
    std::string tamper_error;
    if (decode_ecp2(tampered.data(), tampered.size(), ignored, tamper_error) ||
        tamper_error != "ecp2_content_hash_mismatch") {
        error = "ecp2_mid_epoch_tamper_not_rejected";
        return false;
    }
    return true;
}

} // namespace pk

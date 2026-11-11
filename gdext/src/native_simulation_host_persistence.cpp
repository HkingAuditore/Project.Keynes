#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>
#if defined(_WIN32)
#include <windows.h>
#endif
#include "native_simulation_host_support.h"
#include "runtime_control_wakeup.h"
namespace pk {
namespace {
void d7_append_u32(std::vector<uint8_t> &out, uint32_t value) {
    for (uint32_t i = 0; i < 4u; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}
void d7_append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (uint32_t i = 0; i < 8u; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}
} // namespace
bool NativeSimulationHost::request_save(uint64_t request_id) {
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (request_id == 0 || current == RuntimeWorkerState::STOPPED ||
        current == RuntimeWorkerState::STOPPING ||
        current == RuntimeWorkerState::FAULTED ||
        _stop_requested.load(std::memory_order_acquire)) {
        return false;
    }
    uint64_t expected_request = 0;
    if (!_save_request_id.compare_exchange_strong(expected_request, request_id,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    _save_consumed_request_id.store(0, std::memory_order_release);
    _save_failed_request_id.store(0, std::memory_order_release);
    record_save_failure("");
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(), std::memory_order_release);
    // Publish the flag only after the ID.  The worker's acquire exchange then
    // cannot observe a request without its matching identifier.
    runtime_control_wakeup(_control_mutex, _control_cv, [this] {
        _save_requested.store(true, std::memory_order_release);
    });
    service_inline_save_request();
    return true;
}
std::shared_ptr<const RuntimeSaveBundle>
NativeSimulationHost::poll_save(uint64_t request_id) {
    service_inline_save_request();
    const auto bundle = std::atomic_load_explicit(&_save_bundle, std::memory_order_acquire);
    if (bundle == nullptr ||
        (request_id != 0 && bundle->request_id != request_id)) {
        return nullptr;
    }
    uint64_t expected = 0;
    if (!_save_consumed_request_id.compare_exchange_strong(
            expected, bundle->request_id, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        return nullptr;
    }
    return bundle;
}
bool NativeSimulationHost::restore_bundle(const uint8_t *bytes, size_t size,
                                          std::string &error,
                                          const uint8_t *external_ecp2, size_t external_ecp2_size,
                                          bool *recovered_truncated_ecp2) {
    if (recovered_truncated_ecp2) *recovered_truncated_ecp2 = false;
    if (try_fault_injection("restore.decode.before")) {
        error = "restore_decode_fault_injected_before";
        return false;
    }
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {
        error = "runtime_restore_requires_stopped_worker";
        return false;
    }
    // Fixed v2 scalar header (through section_mask) plus the trailing checksum.
    // The command tail is mandatory in v2 because producer cursors are part of
    // the deterministic restore contract.
    constexpr size_t SCALAR_HEADER_SIZE = 89u;
    constexpr size_t MIN_BUNDLE_SIZE = SCALAR_HEADER_SIZE + 4u + 4u +
        (256u * sizeof(uint64_t)) + sizeof(uint64_t) + sizeof(uint64_t);
    if (bytes == nullptr || size < SCALAR_HEADER_SIZE + sizeof(uint64_t)) {
        error = "runtime_bundle_truncated";
        return false;
    }
    if (std::memcmp(bytes, "PKSR", 4) != 0) {
        error = "runtime_bundle_magic_invalid";
        return false;
    }
    const auto read_u32 = [bytes, size](size_t offset, uint32_t &out) {
        if (offset > size || size - offset < 4u) return false;
        out = static_cast<uint32_t>(bytes[offset]) |
            (static_cast<uint32_t>(bytes[offset + 1u]) << 8u) |
            (static_cast<uint32_t>(bytes[offset + 2u]) << 16u) |
            (static_cast<uint32_t>(bytes[offset + 3u]) << 24u);
        return true;
    };
    const auto read_u16 = [bytes, size](size_t offset, uint16_t &out) {
        if (offset > size || size - offset < 2u) return false;
        out = static_cast<uint16_t>(bytes[offset]) |
            static_cast<uint16_t>(static_cast<uint16_t>(bytes[offset + 1u]) << 8u);
        return true;
    };
    const auto read_u64 = [bytes, size](size_t offset, uint64_t &out) {
        if (offset > size || size - offset < 8u) return false;
        out = 0;
        for (uint32_t i = 0; i < 8u; ++i)
            out |= static_cast<uint64_t>(bytes[offset + i]) << (i * 8u);
        return true;
    };
    uint32_t version = 0;
    if (!read_u32(4u, version) || version != RUNTIME_SAVE_BUNDLE_VERSION) {
        error = "runtime_bundle_version_incompatible";
        return false;
    }
    uint64_t encoded_checksum = 0;
    if (!read_u64(size - sizeof(uint64_t), encoded_checksum)) {
        error = "runtime_bundle_checksum_missing";
        return false;
    }
    const uint64_t checksum = economy_save_hash_bytes(bytes, size - sizeof(uint64_t));
    if (checksum != encoded_checksum) {
        error = "runtime_bundle_checksum_failed";
        return false;
    }
    RuntimeSaveBundle parsed;
    parsed.bytes.assign(bytes, bytes + size);
    parsed.checksum = encoded_checksum;
    parsed.bundle_version = version;
    uint64_t committed_day_bits = 0;
    if (!read_u64(8u, parsed.request_id) ||
        !read_u64(16u, committed_day_bits)) {
        error = "runtime_bundle_header_invalid";
        return false;
    }
    // Decode the signed fields through an integer temporary.  Reinterpreting
    // an int64_t object as uint64_t violates strict-aliasing and is not
    // required by the endian-stable wire format.
    std::memcpy(&parsed.committed_day, &committed_day_bits,
                sizeof(parsed.committed_day));
    uint64_t speed_bits = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t environment_generation = 0;
    uint64_t environment_day_bits = 0;
    uint64_t anomaly_bits = 0;
    uint64_t debt_bits = 0;
    uint32_t runtime_domain_abi_version = 0;
    uint32_t section_mask = 0;
    if (!read_u64(24u, speed_bits) || !read_u64(33u, generation) ||
        !read_u64(41u, state_hash) || !read_u64(49u, environment_generation) ||
        !read_u64(57u, environment_day_bits) || !read_u64(65u, anomaly_bits) ||
        !read_u64(73u, debt_bits) || !read_u32(81u, runtime_domain_abi_version) ||
        !read_u32(85u, section_mask)) {
        error = "runtime_bundle_header_invalid";
        return false;
    }
    std::memcpy(&parsed.speed_days_per_second, &speed_bits, sizeof(double));
    parsed.paused = bytes[32u] != 0;
    parsed.generation = generation;
    parsed.state_hash = state_hash;
    parsed.environment_generation = environment_generation;
    parsed.runtime_domain_abi_version = runtime_domain_abi_version;
    parsed.section_mask = section_mask;
    std::memcpy(&parsed.environment_day, &environment_day_bits, sizeof(int64_t));
    std::memcpy(&parsed.climate_anomaly, &anomaly_bits, sizeof(double));
    std::memcpy(&parsed.time_debt_days, &debt_bits, sizeof(double));
    if (parsed.committed_day < 0 || parsed.environment_day < 0 ||
        !std::isfinite(parsed.speed_days_per_second) ||
        parsed.speed_days_per_second < 0.0 ||
        !std::isfinite(parsed.climate_anomaly) ||
        !std::isfinite(parsed.time_debt_days) ||
        parsed.time_debt_days < 0.0 || parsed.time_debt_days > 100.0) {
        error = "runtime_bundle_value_invalid";
        return false;
    }
    if (parsed.runtime_domain_abi_version != RUNTIME_DOMAIN_ABI_VERSION) {
        error = "runtime_bundle_domain_abi_incompatible";
        return false;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE) == 0 ||
        (parsed.section_mask & ~(RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE |
                                 RUNTIME_SAVE_SECTION_DOMAIN_POD |
                                 RUNTIME_SAVE_SECTION_CLIMATE |
                                 RUNTIME_SAVE_SECTION_COUNTRY |
                                 RUNTIME_SAVE_SECTION_MODIFIER |
                                 RUNTIME_SAVE_SECTION_TRIGGER |
                                 RUNTIME_SAVE_SECTION_EVENTS |
                                 RUNTIME_SAVE_SECTION_EFFECT |
                                 RUNTIME_SAVE_SECTION_IDEOLOGY |
                                 RUNTIME_SAVE_SECTION_ECONOMY_ASSET |
                                 RUNTIME_SAVE_SECTION_ECONOMY_POD |
                                 RUNTIME_SAVE_SECTION_ECONOMY_ECP2 |
                                 RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT)) != 0) {
        error = "runtime_bundle_section_mask_invalid";
        return false;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EFFECT) == 0) {
        error = "runtime_bundle_effect_section_missing";
        return false;
    }
    if (size < MIN_BUNDLE_SIZE) {
        error = "runtime_bundle_tail_missing";
        return false;
    }
    constexpr uint32_t PRODUCER_CURSOR_MARKER = 0x31514350u; // "PCQ1"
    size_t cursor = SCALAR_HEADER_SIZE;
    const size_t payload_end = size - sizeof(uint64_t);
    uint32_t command_count = 0;
    if (!read_u32(cursor, command_count) ||
        command_count > RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "runtime_bundle_command_count_invalid";
        return false;
    }
    cursor += 4u;
    parsed.pending_commands.reserve(command_count);
    for (uint32_t i = 0; i < command_count; ++i) {
        RuntimeCommandPacket packet;
        RuntimeCommandEnvelope &envelope = packet.envelope;
        uint64_t requested_day_bits = 0;
        uint64_t effective_day_bits = 0;
        if (!read_u64(cursor, envelope.request_id) ||
            !read_u32(cursor + 8u, envelope.producer_id) ||
            !read_u64(cursor + 12u, envelope.sequence) ||
            !read_u64(cursor + 20u, envelope.observed_generation) ||
            !read_u64(cursor + 28u, requested_day_bits) ||
            !read_u64(cursor + 36u, effective_day_bits) ||
            !read_u16(cursor + 44u, envelope.domain) ||
            !read_u16(cursor + 46u, envelope.opcode) ||
            !read_u32(cursor + 48u, envelope.payload_size)) {
            error = "runtime_bundle_command_truncated";
            return false;
        }
        std::memcpy(&envelope.requested_day, &requested_day_bits,
                    sizeof(envelope.requested_day));
        std::memcpy(&envelope.effective_day, &effective_day_bits,
                    sizeof(envelope.effective_day));
        envelope.payload_offset = 0;
        cursor += 52u;
        if (envelope.request_id == 0 || envelope.requested_day < 0 ||
            envelope.effective_day < 0 || envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD ||
            envelope.domain > static_cast<uint16_t>(RuntimeDomainId::COMMIT) ||
            envelope.opcode == 0 ||
            cursor > payload_end || envelope.payload_size > payload_end - cursor) {
            error = "runtime_bundle_command_invalid";
            return false;
        }
        if (envelope.payload_size > 0) {
            std::memcpy(packet.payload.data(), bytes + cursor,
                        envelope.payload_size);
        }
        cursor += envelope.payload_size;
        parsed.pending_commands.push_back(std::move(packet));
    }
    uint32_t marker = 0;
    if (!read_u32(cursor, marker) || marker != PRODUCER_CURSOR_MARKER) {
        error = "runtime_bundle_producer_cursor_missing";
        return false;
    }
    cursor += 4u;
    for (uint64_t &sequence : parsed.producer_sequences) {
        if (!read_u64(cursor, sequence)) {
            error = "runtime_bundle_producer_cursor_truncated";
            return false;
        }
        cursor += 8u;
    }
    if (!read_u64(cursor, parsed.fallback_producer_sequence)) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    cursor += 8u;
    uint64_t forwarded_event_id = 0;
    if (!read_u64(cursor, parsed.economy_fact_event_sequence) ||
        !read_u64(cursor + 8u, forwarded_event_id) ||
        !read_u64(cursor + 16u, parsed.trigger_forward_sequence) ||
        forwarded_event_id > static_cast<uint64_t>(INT64_MAX)) {
        error = "runtime_bundle_event_transport_invalid"; return false;
    }
    parsed.trigger_forwarded_event_id = static_cast<int64_t>(forwarded_event_id);
    cursor += 24u;
    uint32_t command_bytes = 0;
    if (!read_u32(cursor, command_bytes) || cursor > payload_end || payload_end - cursor < 4u || command_bytes > payload_end - cursor - 4u) {
        error = "runtime_bundle_economy_commands_truncated"; return false;
    }
    cursor += 4u;
    parsed.economy_command_bytes.assign(bytes + cursor, bytes + cursor + command_bytes);
    cursor += command_bytes;
    RuntimeEconomyPodAuthority command_candidate;
    if (!command_candidate.restore_command_continuation(parsed.economy_command_bytes, error)) return false;
    uint32_t transport_bytes = 0;
    if (!read_u32(cursor, transport_bytes) || cursor > payload_end || payload_end - cursor < 4u || transport_bytes > payload_end - cursor - 4u) {
        error = "runtime_bundle_trigger_transport_truncated"; return false;
    }
    cursor += 4u;
    parsed.trigger_transport_bytes.assign(bytes + cursor, bytes + cursor + transport_bytes);
    cursor += transport_bytes;
    if (!restore_trigger_transport(parsed.trigger_transport_bytes, error, false)) return false;
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_DOMAIN_POD) != 0) {
        constexpr uint32_t DOMAIN_SECTION_MARKER = 0x32445044u; // "DPD2"
        uint32_t marker = 0;
        uint32_t section_size = 0;
        const bool section_header_available = cursor <= payload_end &&
            payload_end - cursor >= 8u;
        if (!section_header_available || !read_u32(cursor, marker) ||
            marker != DOMAIN_SECTION_MARKER ||
            !read_u32(cursor + 4u, section_size) ||
            section_size > 64u * 1024u * 1024u ||
            payload_end - cursor < 16u ||
            section_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_domain_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.domain_pod_bytes.assign(bytes + cursor, bytes + cursor + section_size);
        cursor += section_size;
        uint64_t section_checksum = 0;
        if (!read_u64(cursor, section_checksum)) {
            error = "runtime_bundle_domain_section_checksum_missing";
            return false;
        }
        uint64_t computed_section_checksum = 1469598103934665603ull;
        for (const uint8_t byte : parsed.domain_pod_bytes) {
            computed_section_checksum ^= static_cast<uint64_t>(byte);
            computed_section_checksum *= 1099511628211ull;
        }
        if (computed_section_checksum != section_checksum) {
            error = "runtime_bundle_domain_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_CLIMATE) != 0) {
        constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // CLM2
        uint32_t climate_marker = 0;
        uint32_t climate_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, climate_marker) ||
            !read_u32(cursor + 4u, climate_size) ||
            climate_marker != CLIMATE_SECTION_MARKER ||
            climate_size > 64u * 1024u * 1024u ||
            climate_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_climate_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.climate_bytes.assign(bytes + cursor, bytes + cursor + climate_size);
        cursor += climate_size;
        uint64_t climate_checksum = 0;
        if (!read_u64(cursor, climate_checksum)) {
            error = "runtime_bundle_climate_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.climate_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != climate_checksum) {
            error = "runtime_bundle_climate_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_COUNTRY) != 0) {
        constexpr uint32_t COUNTRY_SECTION_MARKER = 0x32445043u; // CPD2
        uint32_t country_marker = 0;
        uint32_t country_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, country_marker) ||
            !read_u32(cursor + 4u, country_size) ||
            country_marker != COUNTRY_SECTION_MARKER ||
            country_size > 64u * 1024u * 1024u ||
            country_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_country_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.country_bytes.assign(bytes + cursor, bytes + cursor + country_size);
        cursor += country_size;
        uint64_t country_checksum = 0;
        if (!read_u64(cursor, country_checksum)) {
            error = "runtime_bundle_country_section_checksum_missing";
            return false;
        }
        const uint64_t computed = country_checkpoint_checksum(
            parsed.country_bytes.data(), parsed.country_bytes.size());
        if (computed != country_checksum) {
            error = "runtime_bundle_country_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        CountryCoreCheckpoint checkpoint;
        if (!decode_country_core_checkpoint(parsed.country_bytes.data(),
                                            parsed.country_bytes.size(),
                                            checkpoint, error)) {
            error = "runtime_bundle_country_section_invalid:" + error;
            return false;
        }
        std::unordered_map<uint64_t, CountryCommandReceiptCode> country_states;
        country_states.reserve(checkpoint.request_states.size());
        for (const CountryCommandReceipt &receipt : checkpoint.request_states)
            country_states.emplace(receipt.request_id, receipt.code);
        std::unordered_set<uint64_t> country_terminals;
        country_terminals.reserve(checkpoint.terminal_receipts.size());
        for (const CountryCommandReceipt &receipt : checkpoint.terminal_receipts)
            country_terminals.insert(receipt.request_id);
        for (const RuntimeCommandPacket &packet : parsed.pending_commands) {
            if (packet.envelope.domain !=
                    static_cast<uint16_t>(RuntimeDomainId::COUNTRY)) {
                continue;
            }
            const auto state = country_states.find(packet.envelope.request_id);
            if (state == country_states.end() ||
                state->second != CountryCommandReceiptCode::ACCEPTED ||
                country_terminals.find(packet.envelope.request_id) !=
                    country_terminals.end()) {
                error = "runtime_bundle_country_pending_receipt_invalid";
                return false;
            }
        }
        parsed.country_pkcn_bytes = checkpoint.canonical_pkcn;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_ASSET) != 0) {
        constexpr uint32_t D7_SECTION_MARKER = 0x31543744u; // D7T1
        uint32_t d7_marker = 0;
        uint32_t d7_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, d7_marker) ||
            !read_u32(cursor + 4u, d7_size) ||
            d7_marker != D7_SECTION_MARKER ||
            d7_size > 64u * 1024u * 1024u ||
            d7_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_d7_transaction_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_asset_bytes.assign(bytes + cursor,
                                          bytes + cursor + d7_size);
        cursor += d7_size;
        uint64_t d7_checksum = 0;
        if (!read_u64(cursor, d7_checksum)) {
            error = "runtime_bundle_d7_transaction_checksum_missing";
            return false;
        }
        uint64_t computed_d7 = 1469598103934665603ull;
        for (const uint8_t byte : parsed.economy_asset_bytes) {
            computed_d7 ^= static_cast<uint64_t>(byte);
            computed_d7 *= 1099511628211ull;
        }
        if (computed_d7 != d7_checksum) {
            error = "runtime_bundle_d7_transaction_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_asset_bytes.size() < 8u ||
            std::memcmp(parsed.economy_asset_bytes.data(), "D7T1", 4u) != 0) {
            error = "runtime_bundle_d7_transaction_marker_invalid";
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_TRIGGER) != 0) {
        constexpr uint32_t TRIGGER_SECTION_MARKER = 0x31445054u; // TPD1
        uint32_t trigger_marker = 0;
        uint32_t trigger_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, trigger_marker) ||
            !read_u32(cursor + 4u, trigger_size) ||
            trigger_marker != TRIGGER_SECTION_MARKER ||
            trigger_size > 64u * 1024u * 1024u ||
            trigger_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_trigger_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.trigger_bytes.assign(bytes + cursor, bytes + cursor + trigger_size);
        cursor += trigger_size;
        uint64_t trigger_checksum = 0;
        if (!read_u64(cursor, trigger_checksum)) {
            error = "runtime_bundle_trigger_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.trigger_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != trigger_checksum) {
            error = "runtime_bundle_trigger_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_MODIFIER) != 0) {
        constexpr uint32_t MODIFIER_SECTION_MARKER = 0x3246444Du; // MDF2
        uint32_t modifier_marker = 0;
        uint32_t modifier_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, modifier_marker) ||
            !read_u32(cursor + 4u, modifier_size) ||
            modifier_marker != MODIFIER_SECTION_MARKER ||
            modifier_size > 64u * 1024u * 1024u ||
            modifier_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_modifier_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.modifier_bytes.assign(bytes + cursor, bytes + cursor + modifier_size);
        cursor += modifier_size;
        uint64_t modifier_checksum = 0;
        if (!read_u64(cursor, modifier_checksum)) {
            error = "runtime_bundle_modifier_section_checksum_missing";
            return false;
        }
        uint64_t computed_modifier = 1469598103934665603ull;
        for (const uint8_t byte : parsed.modifier_bytes) {
            computed_modifier ^= static_cast<uint64_t>(byte);
            computed_modifier *= 1099511628211ull;
        }
        if (computed_modifier != modifier_checksum) {
            error = "runtime_bundle_modifier_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.modifier_bytes.size() < 4u ||
            std::memcmp(parsed.modifier_bytes.data(), "MDF2", 4u) != 0) {
            error = "runtime_bundle_modifier_section_marker_invalid";
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EVENTS) != 0) {
        constexpr uint32_t EVENTS_SECTION_MARKER = 0x31545645u; // EVT1
        uint32_t events_marker = 0;
        uint32_t events_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, events_marker) ||
            !read_u32(cursor + 4u, events_size) ||
            events_marker != EVENTS_SECTION_MARKER ||
            events_size > 64u * 1024u * 1024u ||
            events_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_events_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.events_bytes.assign(bytes + cursor, bytes + cursor + events_size);
        cursor += events_size;
        uint64_t events_checksum = 0;
        if (!read_u64(cursor, events_checksum)) {
            error = "runtime_bundle_events_section_checksum_missing";
            return false;
        }
        uint64_t computed_events = 1469598103934665603ull;
        for (const uint8_t byte : parsed.events_bytes) {
            computed_events ^= static_cast<uint64_t>(byte);
            computed_events *= 1099511628211ull;
        }
        if (computed_events != events_checksum) {
            error = "runtime_bundle_events_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.events_bytes.size() < 4u ||
            std::memcmp(parsed.events_bytes.data(), "EVT1", 4u) != 0) {
            error = "runtime_bundle_events_section_marker_invalid";
            return false;
        }
        RuntimeEventsAuthority candidate;
        std::string events_restore_error;
        if (!candidate.restore(parsed.events_bytes.data(),
                               parsed.events_bytes.size(), events_restore_error)) {
            error = events_restore_error.empty()
                ? "runtime_bundle_events_restore_invalid" : events_restore_error;
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT) != 0) {
        constexpr uint32_t GMP1_MARKER = 0x31504d47u; // GMP1
        uint32_t marker = 0;
        uint32_t section_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, marker) ||
            !read_u32(cursor + 4u, section_size) || marker != GMP1_MARKER ||
            section_size != 32u || section_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_gameplay_effect_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.gameplay_effect_bytes.assign(bytes + cursor,
                                            bytes + cursor + section_size);
        cursor += section_size;
        uint64_t stored_checksum = 0;
        if (!read_u64(cursor, stored_checksum)) {
            error = "runtime_bundle_gameplay_effect_checksum_missing";
            return false;
        }
        uint64_t computed_checksum = 1469598103934665603ull;
        for (const uint8_t byte : parsed.gameplay_effect_bytes) {
            computed_checksum ^= static_cast<uint64_t>(byte);
            computed_checksum *= 1099511628211ull;
        }
        if (computed_checksum != stored_checksum) {
            error = "runtime_bundle_gameplay_effect_checksum_failed";
            return false;
        }
        cursor += 8u;
        size_t gmp_cursor = 0;
        uint32_t inner_marker = 0;
        uint32_t abi = 0;
        uint64_t generation = 0;
        uint32_t pending = 0;
        uint32_t terminal = 0;
        uint64_t state_hash = 0;
        if (!d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, inner_marker) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, abi) ||
            !d7_read_u64(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, generation) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, pending) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, terminal) ||
            !d7_read_u64(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, state_hash) || gmp_cursor != section_size ||
            inner_marker != GMP1_MARKER || abi != 1u) {
            error = "runtime_bundle_gameplay_effect_payload_invalid";
            return false;
        }
        uint32_t actual_pending = 0;
        for (const RuntimeCommandPacket &packet : parsed.pending_commands) {
            if (packet.envelope.domain == static_cast<uint16_t>(
                    RuntimeDomainId::GAMEPLAY_EFFECT))
                ++actual_pending;
        }
        if (pending != actual_pending) {
            error = "runtime_bundle_gameplay_effect_pending_mismatch";
            return false;
        }
        (void)generation;
        (void)terminal;
        (void)state_hash;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EFFECT) != 0) {
        constexpr uint32_t EFFECT_SECTION_MARKER = 0x31504645u; // EFP1
        uint32_t effect_marker = 0;
        uint32_t effect_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, effect_marker) ||
            !read_u32(cursor + 4u, effect_size) ||
            effect_marker != EFFECT_SECTION_MARKER ||
            effect_size > 64u * 1024u * 1024u ||
            effect_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_effect_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.effect_bytes.assign(bytes + cursor, bytes + cursor + effect_size);
        cursor += effect_size;
        uint64_t effect_checksum = 0;
        if (!read_u64(cursor, effect_checksum)) {
            error = "runtime_bundle_effect_section_checksum_missing";
            return false;
        }
        uint64_t computed_effect = 1469598103934665603ull;
        for (const uint8_t byte : parsed.effect_bytes) {
            computed_effect ^= static_cast<uint64_t>(byte);
            computed_effect *= 1099511628211ull;
        }
        if (computed_effect != effect_checksum) {
            error = "runtime_bundle_effect_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.effect_bytes.size() < 4u ||
            std::memcmp(parsed.effect_bytes.data(), "EFP1", 4u) != 0) {
            error = "runtime_bundle_effect_section_marker_invalid";
            return false;
        }
        if (!_effect_pod_configured) {
            error = "runtime_bundle_effect_catalog_missing";
            return false;
        }
        RuntimeEffectPodAuthority candidate;
        std::string effect_restore_error;
        if (!candidate.configure(_effect_pod_catalog, effect_restore_error) ||
            !candidate.restore(parsed.effect_bytes.data(),
                               parsed.effect_bytes.size(), effect_restore_error)) {
            error = effect_restore_error.empty()
                ? "runtime_bundle_effect_restore_invalid" : effect_restore_error;
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_IDEOLOGY) != 0) {
        constexpr uint32_t IDEOLOGY_SECTION_MARKER = 0x32504449u; // IDP2
        uint32_t ideology_marker = 0;
        uint32_t ideology_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, ideology_marker) ||
            !read_u32(cursor + 4u, ideology_size) ||
            ideology_marker != IDEOLOGY_SECTION_MARKER ||
            ideology_size > 64u * 1024u * 1024u ||
            ideology_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_ideology_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.ideology_bytes.assign(bytes + cursor, bytes + cursor + ideology_size);
        cursor += ideology_size;
        uint64_t ideology_checksum = 0;
        if (!read_u64(cursor, ideology_checksum)) {
            error = "runtime_bundle_ideology_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.ideology_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != ideology_checksum) {
            error = "runtime_bundle_ideology_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.ideology_bytes.size() < 4u ||
            std::memcmp(parsed.ideology_bytes.data(), "IDP2", 4u) != 0) {
            error = "runtime_bundle_ideology_section_marker_invalid";
            return false;
        }
        // The ideology POD catalog is derived from the Country POD snapshot,
        // so it can only be configured after PKCN restores — and PKSR restores
        // before PKCN. When the catalog is not configured yet, the checksum and
        // marker above still reject corrupt bytes; the catalog-dependent dry
        // run is deferred to worker start, which restores IDP2 against the
        // then-configured catalog and faults before any day runs if it fails.
        if (_ideology_pod_configured) {
            RuntimeIdeologyPodAuthority candidate;
            std::string ideology_restore_error;
            if (!candidate.configure(_ideology_pod_catalog,
                                     ideology_restore_error) ||
                !candidate.restore(parsed.ideology_bytes.data(),
                                   parsed.ideology_bytes.size(),
                                   ideology_restore_error)) {
                error = ideology_restore_error.empty()
                    ? "runtime_bundle_ideology_restore_invalid"
                    : ideology_restore_error;
                return false;
            }
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_POD) != 0) {
        constexpr uint32_t ECONOMY_POD_SECTION_MARKER = 0x31504345u; // ECP1
        uint32_t economy_marker = 0;
        uint32_t economy_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, economy_marker) ||
            !read_u32(cursor + 4u, economy_size) ||
            economy_marker != ECONOMY_POD_SECTION_MARKER ||
            economy_size > 64u * 1024u * 1024u ||
            economy_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_economy_pod_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_pod_bytes.assign(bytes + cursor,
                                        bytes + cursor + economy_size);
        cursor += economy_size;
        uint64_t economy_checksum = 0;
        if (!read_u64(cursor, economy_checksum)) {
            error = "runtime_bundle_economy_pod_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.economy_pod_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != economy_checksum) {
            error = "runtime_bundle_economy_pod_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_pod_bytes.size() < 4u ||
            std::memcmp(parsed.economy_pod_bytes.data(), "ECP1", 4u) != 0) {
            error = "runtime_bundle_economy_pod_section_marker_invalid";
            return false;
        }
        RuntimeEconomyPodAuthority candidate;
        std::string economy_restore_error;
        if (!candidate.restore_ecp1(parsed.economy_pod_bytes.data(),
                                    parsed.economy_pod_bytes.size(),
                                    economy_restore_error)) {
            error = economy_restore_error.empty()
                ? "runtime_bundle_economy_pod_restore_invalid"
                : economy_restore_error;
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_ECP2) != 0) {
        constexpr uint32_t ECONOMY_ECP2_SECTION_MARKER = 0x32504345u; // ECP2
        uint32_t economy_marker = 0;
        uint32_t economy_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, economy_marker) ||
            !read_u32(cursor + 4u, economy_size) ||
            economy_marker != ECONOMY_ECP2_SECTION_MARKER ||
            economy_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_economy_ecp2_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_ecp2_bytes.assign(bytes + cursor,
                                         bytes + cursor + economy_size);
        cursor += economy_size;
        uint64_t economy_checksum = 0;
        if (!read_u64(cursor, economy_checksum)) {
            error = "runtime_bundle_economy_ecp2_section_checksum_missing";
            return false;
        }
        const uint64_t computed = economy_save_hash_bytes(
            parsed.economy_ecp2_bytes.data(), parsed.economy_ecp2_bytes.size());
        if (computed != economy_checksum) {
            error = "runtime_bundle_economy_ecp2_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_ecp2_bytes.size() < 4u ||
            std::memcmp(parsed.economy_ecp2_bytes.data(), "ECP2", 4u) != 0) {
            error = "runtime_bundle_economy_ecp2_section_marker_invalid";
            return false;
        }
        RuntimeEconomyEcp2State candidate_ecp2;
        std::string economy_ecp2_restore_error;
        if (!decode_ecp2(parsed.economy_ecp2_bytes.data(),
                         parsed.economy_ecp2_bytes.size(), candidate_ecp2,
                         economy_ecp2_restore_error)) {
            // Old writers silently capped this section at 64 MiB, but PKSV
            // retained the complete frozen checkpoint as its separate ecp2
            // section. Recover only that exact prefix, after the original
            // bundle/section checksums and the complete ECP2 hash validate.
            constexpr size_t legacy_limit = 64u * 1024u * 1024u;
            if (economy_ecp2_restore_error != "ecp2_content_hash_mismatch" ||
                parsed.economy_ecp2_bytes.size() != legacy_limit ||
                external_ecp2 == nullptr || external_ecp2_size <= legacy_limit ||
                external_ecp2_size > std::numeric_limits<uint32_t>::max() ||
                std::memcmp(parsed.economy_ecp2_bytes.data(), external_ecp2,
                            legacy_limit) != 0) {
                error = economy_ecp2_restore_error.empty()
                    ? "runtime_bundle_economy_ecp2_restore_invalid"
                    : economy_ecp2_restore_error;
                return false;
            }
            if (!decode_ecp2(external_ecp2, external_ecp2_size, candidate_ecp2,
                             economy_ecp2_restore_error)) {
                error = economy_ecp2_restore_error;
                return false;
            }
            parsed.economy_ecp2_bytes.assign(external_ecp2, external_ecp2 + external_ecp2_size);
            if (recovered_truncated_ecp2) *recovered_truncated_ecp2 = true;
        }
        if (!ecp2_has_required_domains(candidate_ecp2.authority_domain_mask,
                                       ECP2_DOMAIN_CORE_AUTHORITY)) {
            error = "runtime_bundle_economy_ecp2_core_domains_missing";
            return false;
        }
    }
    if (cursor != payload_end) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    _pending_restore_bundle = std::move(parsed);
    if (try_fault_injection("restore.validate.before")) {
        error = "restore_validate_fault_injected_before";
        _pending_restore_bundle = RuntimeSaveBundle{};
        _has_pending_restore = false;
        return false;
    }
    _has_pending_restore = true;
    // The main thread numbers the next environment input from the reported
    // environment generation, and it captures the first post-load input
    // before the worker starts. Publishing the saved generation only at worker
    // start let that first input restart at 1, below the restored Climate
    // authority's last input, which faulted with
    // climate_input_generation_not_monotonic on the first day after a load.
    if (_pending_restore_bundle.environment_generation >
            _environment_generation.load(std::memory_order_acquire)) {
        _environment_generation.store(_pending_restore_bundle.environment_generation,
                                      std::memory_order_release);
    }
    // GPU/Object state is intentionally outside the runtime bundle. The next
    // committed visual batch must therefore be a reconstructible full refresh
    // after any successful restore, even when the visual ring had no drop.
    _visual_full_refresh.store(true, std::memory_order_release);
    if (try_fault_injection("restore.swap.before")) {
        error = "restore_swap_fault_injected_before";
        _pending_restore_bundle = RuntimeSaveBundle{};
        _has_pending_restore = false;
        return false;
    }
    return true;
}

void NativeSimulationHost::build_save_bundle(
        uint64_t request_id,
        const std::vector<RuntimeCommandPacket> &pending_commands) {
    EconomyCostProbe save_probe("save.bundle", _committed_day.load(std::memory_order_acquire));
    if (try_fault_injection("save.barrier.before")) {
        return;
    }
    // The wire format accepts one protocol-capacity command tail. A live
    // backlog may also contain commands drained from earlier ingress batches;
    // reject the save without changing that backlog instead of truncating it.
    if (pending_commands.size() > RUNTIME_COMMAND_QUEUE_CAPACITY) {
        record_save_failure("save_pending_command_capacity_exceeded");
        return;
    }
    // Check this before cross-domain checkpoint identities: bootstrap Country
    // legitimately has no committed day either. Report the actionable cause.
    if (_economy_ecp2_dual_write.load(std::memory_order_acquire) &&
        _economy_production_runtime != nullptr &&
        _economy_production_runtime->last_committed_day() < 0) {
        record_save_failure("save_requires_first_settlement");
        return;
    }
    auto bundle = std::make_shared<RuntimeSaveBundle>();
    bundle->request_id = request_id;
    bundle->bundle_version = RUNTIME_SAVE_BUNDLE_VERSION;
    bundle->runtime_domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    bundle->section_mask = RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE |
        RUNTIME_SAVE_SECTION_DOMAIN_POD;
    bundle->committed_day = _committed_day.load(std::memory_order_acquire);
    bundle->paused = _paused.load(std::memory_order_acquire);
    bundle->speed_days_per_second = _speed_days_per_second.load(std::memory_order_acquire);
    bundle->generation = _generation.load(std::memory_order_acquire);
    bundle->state_hash = _state_hash.load(std::memory_order_acquire);
    bundle->environment_generation = _environment_generation.load(
        std::memory_order_acquire);
    bundle->environment_day = _environment_day.load(std::memory_order_acquire);
    bundle->time_debt_days = _time_debt_days.load(std::memory_order_acquire);
    bundle->pending_commands = pending_commands;
    for (size_t i = 0; i < _producer_sequences.size(); ++i) {
        bundle->producer_sequences[i] = _producer_sequences[i].load(
            std::memory_order_acquire);
    }
    bundle->economy_fact_event_sequence = _economy_fact_event_sequence;
    bundle->trigger_forwarded_event_id = _trigger_forwarded_event_id;
    bundle->trigger_forward_sequence = _trigger_forward_sequence;
    bundle->economy_command_bytes = _economy_pod_authority.encode_command_continuation(); bundle->trigger_transport_bytes = encode_trigger_transport();
    bundle->fallback_producer_sequence = _fallback_producer_sequence.load(
        std::memory_order_acquire);
    if (const auto environment = environment_snapshot()) {
        bundle->climate_anomaly = environment->climate_anomaly;
    }
    _pod_pipeline.serialize(bundle->domain_pod_bytes);
    const bool include_climate = _climate_authority.store().cell_count != 0;
    if (include_climate) {
        EconomyCostProbe climate_probe("save.climate", bundle->committed_day);
        std::string climate_save_error;
        if (!_climate_authority.serialize(bundle->climate_bytes, climate_save_error)) {
            set_fault(climate_save_error.empty() ? "climate_save_encode_failed" :
                      climate_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_CLIMATE;
    }
    const auto country_checkpoint = std::atomic_load_explicit(
        &_country_checkpoint, std::memory_order_acquire);
    // Under worker Country authority the checkpoint must describe the same
    // committed day as this bundle. A mismatch restores a Country POD that can
    // never plan the next host day (country_day_not_contiguous forever), so
    // reject the save explicitly instead of writing an inconsistent bundle.
    if (country_checkpoint != nullptr &&
        domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
        country_checkpoint->committed_day != bundle->committed_day) {
        const std::string reason = "save_country_checkpoint_day_mismatch:c=" +
            std::to_string(country_checkpoint->committed_day) + ",b=" +
            std::to_string(bundle->committed_day);
        record_save_failure(reason.c_str());
        return;
    }
    if (country_checkpoint != nullptr) {
        // The synchronous checkpoint carries the canonical PKCN business
        // payload. Host protocol state is merged here at the same save
        // boundary, so pending worker packets and terminal receipts cannot
        // drift from the PKCN generation/day/hash they accompany.
        CountryCoreCheckpoint checkpoint = *country_checkpoint;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            std::map<uint64_t, CountryCommandReceipt> states;
            for (const CountryCommandReceipt &receipt : checkpoint.request_states)
                states.emplace(receipt.request_id, receipt);
            std::map<uint64_t, CountryCommandReceipt> terminals;
            for (const CountryCommandReceipt &receipt : checkpoint.terminal_receipts)
                terminals.emplace(receipt.request_id, receipt);

            for (const auto &entry : _country_command_states) {
                const CountryCommandReceipt &receipt = entry.second;
                const auto existing = states.find(receipt.request_id);
                if (existing == states.end()) {
                    states.emplace(receipt.request_id, receipt);
                } else if (existing->second.code != receipt.code ||
                           existing->second.effective_day != receipt.effective_day) {
                    const auto &previous = existing->second;
                    if (previous.code == CountryCommandReceiptCode::ACCEPTED &&
                        receipt.code == CountryCommandReceiptCode::REJECTED_AT_EXECUTION &&
                        receipt.producer_id == COUNTRY_AI_PRODUCER_ID &&
                        previous.producer_id == receipt.producer_id &&
                        previous.sequence == receipt.sequence &&
                        previous.effective_day == receipt.effective_day &&
                        receipt.reason == "country_ai_superseded_by_worker") {
                        // 只读副本保留旧接收记录；Host 的 AI 收尾终态优先。
                        existing->second = receipt;
                        continue;
                    }
                    set_fault("country_save_request_state_conflict");
                    return;
                }
            }
            for (const RuntimeCommandPacket &packet : pending_commands) {
                if (packet.envelope.domain !=
                        static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
                    packet.envelope.request_id == 0) {
                    continue;
                }
                const auto existing = states.find(packet.envelope.request_id);
                if (existing == states.end()) {
                    CountryCommandReceipt accepted;
                    accepted.request_id = packet.envelope.request_id;
                    accepted.producer_id = packet.envelope.producer_id;
                    accepted.sequence = packet.envelope.sequence;
                    accepted.effective_day = packet.envelope.effective_day;
                    accepted.generation = checkpoint.generation;
                    accepted.code = CountryCommandReceiptCode::ACCEPTED;
                    states.emplace(accepted.request_id, std::move(accepted));
                } else if (existing->second.code != CountryCommandReceiptCode::ACCEPTED) {
                    set_fault("country_save_pending_receipt_not_accepted");
                    return;
                }
            }
            for (const auto &entry : _country_command_terminals) {
                const CountryCommandReceipt &receipt = entry.second;
                const auto existing = states.find(receipt.request_id);
                if (existing == states.end() || existing->second.code != receipt.code) {
                    set_fault("country_save_terminal_receipt_state_mismatch");
                    return;
                }
                terminals.emplace(receipt.request_id, receipt);
            }
            checkpoint.request_states.clear();
            checkpoint.request_states.reserve(states.size());
            for (const auto &entry : states)
                checkpoint.request_states.push_back(entry.second);
            checkpoint.terminal_receipts.clear();
            checkpoint.terminal_receipts.reserve(terminals.size());
            for (const auto &entry : terminals)
                checkpoint.terminal_receipts.push_back(entry.second);
        }
        std::string country_save_error;
        if (!encode_country_core_checkpoint(checkpoint,
                                            bundle->country_bytes,
                                            country_save_error)) {
            set_fault(country_save_error.empty() ? "country_save_encode_failed" :
                      country_save_error.c_str());
            return;
        }
        bundle->country_pkcn_bytes = checkpoint.canonical_pkcn;
        bundle->section_mask |= RUNTIME_SAVE_SECTION_COUNTRY;
    }
    std::string d7_save_error;
    if (!serialize_country_economy_asset_journal(
            bundle->economy_asset_bytes, d7_save_error)) {
        set_fault(d7_save_error.empty() ? "d7_transaction_journal_encode_failed" :
                  d7_save_error.c_str());
        return;
    }
    if (!bundle->economy_asset_bytes.empty())
        bundle->section_mask |= RUNTIME_SAVE_SECTION_ECONOMY_ASSET;
    RuntimeTriggerPodSaveSection trigger_save;
    std::string trigger_save_error;
    if (_domain_authority_runner.encode_trigger_save(trigger_save,
                                                     trigger_save_error)) {
        bundle->trigger_bytes = std::move(trigger_save.payload);
        bundle->section_mask |= RUNTIME_SAVE_SECTION_TRIGGER;
    }
    if (_modifier_pod_configured) {
        std::vector<RuntimeModifierPodCommand> modifier_pending;
        modifier_pending.reserve(pending_commands.size());
        for (const RuntimeCommandPacket &packet : pending_commands) {
            RuntimeModifierPodCommand command;
            if (decode_modifier_packet(packet, command))
                modifier_pending.push_back(command);
        }
        _modifier_pod_authority.set_pending_command_identities(modifier_pending);
        _modifier_pod_authority.serialize(bundle->modifier_bytes);
        if (bundle->modifier_bytes.empty()) {
            set_fault("modifier_save_encode_failed");
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_MODIFIER;
    }
    {
        std::string events_save_error;
        if (!_events_authority.serialize(bundle->events_bytes, events_save_error)) {
            set_fault(events_save_error.empty() ? "events_save_encode_failed" :
                      events_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_EVENTS;
    }
    {
        constexpr uint32_t GMP1_MARKER = 0x31504d47u; // GMP1
        constexpr uint32_t GMP1_ABI = 1u;
        uint32_t pending_gameplay = 0;
        for (const RuntimeCommandPacket &packet : pending_commands) {
            if (packet.envelope.domain == static_cast<uint16_t>(
                    RuntimeDomainId::GAMEPLAY_EFFECT))
                ++pending_gameplay;
        }
        std::vector<uint8_t> &gmp = bundle->gameplay_effect_bytes;
        gmp.clear();
        d7_append_u32(gmp, GMP1_MARKER);
        d7_append_u32(gmp, GMP1_ABI);
        d7_append_u64(gmp, _gameplay_effect_generation.load(
            std::memory_order_acquire));
        d7_append_u32(gmp, pending_gameplay);
        d7_append_u32(gmp, _gameplay_effect_terminal.load(
            std::memory_order_acquire));
        d7_append_u64(gmp, _gameplay_effect_state_hash.load(
            std::memory_order_acquire));
        bundle->section_mask |= RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT;
    }
    if (_effect_pod_configured) {
        std::string effect_save_error;
        if (!encode_effect_pod_save(bundle->effect_bytes, effect_save_error)) {
            set_fault(effect_save_error.empty() ? "effect_save_encode_failed" :
                      effect_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_EFFECT;
    }
    if (_ideology_pod_configured) {
        std::string ideology_save_error;
        if (!encode_ideology_pod_save(bundle->ideology_bytes,
                                      ideology_save_error)) {
            set_fault(ideology_save_error.empty()
                ? "ideology_save_encode_failed"
                : ideology_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_IDEOLOGY;
    }
    {
        std::string economy_pod_save_error;
        if (_economy_pod_authority.encode_ecp1(bundle->economy_pod_bytes,
                                               economy_pod_save_error)) {
            if (!bundle->economy_pod_bytes.empty())
                bundle->section_mask |= RUNTIME_SAVE_SECTION_ECONOMY_POD;
        }
        // ECP1 is optional when the POD has never committed; encode failure
        // with empty bytes is not a host fault.
        if (!economy_pod_save_error.empty() &&
            economy_pod_save_error != "economy_pod_ecp1_save_blocked") {
            set_fault(economy_pod_save_error.c_str());
            return;
        }
    }
    if (_economy_ecp2_dual_write.load(std::memory_order_acquire) &&
        _economy_production_runtime != nullptr) {
        EconomyCostProbe economy_probe("save.ecp2", bundle->committed_day);
        uint32_t capture_flags = 0;
        if (_economy_ecp2_mid_epoch_save.load(std::memory_order_acquire))
            capture_flags |= ECP2_CAPTURE_ALLOW_MID_EPOCH |
                             ECP2_CAPTURE_INCLUDE_RESUME;
        RuntimeEconomyEcp2State ecp2_state;
        std::string ecp2_capture_error;
        // ECP2 records the Country identity it is bound to, and restore
        // requires it to match the Country restored from this same bundle.
        // Under worker Country authority that is the committed checkpoint
        // above, not the main-thread runtime the economy points at (which
        // stays at its bootstrap state and would never match on load).
        const bool stamp_worker_country =
            country_checkpoint != nullptr &&
            domain_is_worker_authoritative(RuntimeDomainId::COUNTRY);
        EconomyAuthorityTransfer::CountryIdentity country_identity;
        if (stamp_worker_country) {
            country_identity = {country_checkpoint->generation,
                                country_checkpoint->business_state_hash};
        }
        if (!EconomyAuthorityTransfer::capture(*_economy_production_runtime,
                ecp2_state, ecp2_capture_error, capture_flags,
                stamp_worker_country ? &country_identity : nullptr)) {
            // A rejected capture must not publish a bundle missing its Economy section.
            record_save_failure(ecp2_capture_error.empty() ? "economy_ecp2_capture_failed" :
                ecp2_capture_error.c_str());
            return;
        }
        std::string ecp2_encode_error;
        if (!encode_ecp2(ecp2_state, bundle->economy_ecp2_bytes, ecp2_encode_error) ||
                bundle->economy_ecp2_bytes.empty()) {
            set_fault(ecp2_encode_error.empty() ? "economy_ecp2_encode_failed" :
                ecp2_encode_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_ECONOMY_ECP2;
    }

    // PKSR v2 is an endian-stable runtime envelope. The fixed scalar header
    // carries an explicit ABI/section mask, followed by a bounded pending
    // command tail and producer cursors. The checksum remains the final eight
    // bytes and the complete tail is mandatory for v2 restores.
    const auto wire_started = std::chrono::steady_clock::now();
    size_t wire_reserve = 4 + 4 + 8 * 10 + 1 + 4 + 4 +
        bundle->pending_commands.size() * (8 + 4 + 8 + 8 + 8 + 8 + 2 + 2 + 4 +
                                           RUNTIME_MAX_COMMAND_PAYLOAD) +
        bundle->producer_sequences.size() * 8 + 8 + 24 + 8;
    // 所有 section 已冻结；一次预留，避免拼接大 section 时反复搬移前缀。
    for (const auto *section : {&bundle->domain_pod_bytes, &bundle->climate_bytes,
            &bundle->country_bytes, &bundle->economy_asset_bytes,
            &bundle->trigger_bytes, &bundle->modifier_bytes, &bundle->events_bytes,
            &bundle->gameplay_effect_bytes, &bundle->effect_bytes,
            &bundle->ideology_bytes, &bundle->economy_pod_bytes,
            &bundle->economy_ecp2_bytes}) {
        const size_t limit = section == &bundle->economy_ecp2_bytes
            ? std::numeric_limits<uint32_t>::max() : 64u * 1024u * 1024u;
        if (section->size() > limit) {
            record_save_failure("save_runtime_section_too_large");
            return;
        }
        wire_reserve += 16u + section->size();
    }
    bundle->bytes.reserve(wire_reserve);
    const auto append_bytes = [&bundle](const void *data, size_t size) {
        const size_t offset = bundle->bytes.size();
        bundle->bytes.resize(offset + size);
        std::memcpy(bundle->bytes.data() + offset, data, size);
    };
    const auto append_u32_le = [&append_bytes](uint32_t value) {
        const std::array<uint8_t, 4> bytes{
            static_cast<uint8_t>(value & 0xffu),
            static_cast<uint8_t>((value >> 8u) & 0xffu),
            static_cast<uint8_t>((value >> 16u) & 0xffu),
            static_cast<uint8_t>((value >> 24u) & 0xffu),
        };
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_u16_le = [&append_bytes](uint16_t value) {
        const std::array<uint8_t, 2> bytes{
            static_cast<uint8_t>(value & 0xffu),
            static_cast<uint8_t>((value >> 8u) & 0xffu),
        };
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_u64_le = [&append_bytes](uint64_t value) {
        std::array<uint8_t, 8> bytes{};
        for (uint32_t i = 0; i < bytes.size(); ++i)
            bytes[i] = static_cast<uint8_t>((value >> (i * 8u)) & 0xffu);
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_i64_le = [&append_u64_le](int64_t value) {
        append_u64_le(static_cast<uint64_t>(value));
    };
    const auto append_f64_le = [&append_u64_le](double value) {
        uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        append_u64_le(bits);
    };
    const char magic[4] = {'P', 'K', 'S', 'R'};
    const uint32_t version = RUNTIME_SAVE_BUNDLE_VERSION;
    const uint8_t paused = bundle->paused ? 1u : 0u;
    append_bytes(magic, sizeof(magic));
    append_u32_le(version);
    append_u64_le(bundle->request_id);
    append_i64_le(bundle->committed_day);
    append_f64_le(bundle->speed_days_per_second);
    append_bytes(&paused, sizeof(paused));
    append_u64_le(bundle->generation);
    append_u64_le(bundle->state_hash);
    append_u64_le(bundle->environment_generation);
    append_i64_le(bundle->environment_day);
    append_f64_le(bundle->climate_anomaly);
    append_f64_le(bundle->time_debt_days);
    append_u32_le(RUNTIME_DOMAIN_ABI_VERSION);
    append_u32_le(bundle->section_mask);

    const uint32_t pending_count = static_cast<uint32_t>(bundle->pending_commands.size());
    append_u32_le(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        const RuntimeCommandPacket &command = bundle->pending_commands[i];
        const RuntimeCommandEnvelope &envelope = command.envelope;
        append_u64_le(envelope.request_id);
        append_u32_le(envelope.producer_id);
        append_u64_le(envelope.sequence);
        append_u64_le(envelope.observed_generation);
        append_i64_le(envelope.requested_day);
        append_i64_le(envelope.effective_day);
        append_u16_le(envelope.domain);
        append_u16_le(envelope.opcode);
        append_u32_le(envelope.payload_size);
        if (envelope.payload_size > 0) {
            append_bytes(command.payload.data(), envelope.payload_size);
        }
    }
    // A marker separates optional command records from producer cursors. This
    // lets a future PKSR decoder reject a truncated tail instead of treating
    // arbitrary bytes as sequence state.
    constexpr uint32_t PRODUCER_CURSOR_MARKER = 0x31514350u; // "PCQ1"
    append_u32_le(PRODUCER_CURSOR_MARKER);
    for (uint64_t sequence : bundle->producer_sequences)
        append_u64_le(sequence);
    append_u64_le(bundle->fallback_producer_sequence);
    append_u64_le(bundle->economy_fact_event_sequence);
    append_i64_le(bundle->trigger_forwarded_event_id);
    append_u64_le(bundle->trigger_forward_sequence);
    append_u32_le(static_cast<uint32_t>(bundle->economy_command_bytes.size()));
    append_bytes(bundle->economy_command_bytes.data(), bundle->economy_command_bytes.size());
    append_u32_le(static_cast<uint32_t>(bundle->trigger_transport_bytes.size()));
    append_bytes(bundle->trigger_transport_bytes.data(), bundle->trigger_transport_bytes.size());
    constexpr uint32_t DOMAIN_SECTION_MARKER = 0x32445044u; // "DPD2"
    append_u32_le(DOMAIN_SECTION_MARKER);
    append_u32_le(static_cast<uint32_t>(bundle->domain_pod_bytes.size()));
    const uint32_t domain_section_size = static_cast<uint32_t>(bundle->domain_pod_bytes.size());
    if (domain_section_size > 0) {
        append_bytes(bundle->domain_pod_bytes.data(), domain_section_size);
    }
    const uint64_t domain_checksum = economy_save_hash_bytes(
        bundle->domain_pod_bytes.data(), domain_section_size);
    append_u64_le(domain_checksum);

    if (include_climate) {
        constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // "CLM2"
        append_u32_le(CLIMATE_SECTION_MARKER);
        const uint32_t climate_section_size = static_cast<uint32_t>(bundle->climate_bytes.size());
        append_u32_le(climate_section_size);
        if (climate_section_size > 0)
            append_bytes(bundle->climate_bytes.data(), climate_section_size);
        uint64_t climate_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < climate_section_size; ++i) {
            climate_checksum ^= static_cast<uint64_t>(bundle->climate_bytes[i]);
            climate_checksum *= 1099511628211ull;
        }
        append_u64_le(climate_checksum);
    }

    if (country_checkpoint != nullptr) {
        constexpr uint32_t COUNTRY_SECTION_MARKER = 0x32445043u; // CPD2
        append_u32_le(COUNTRY_SECTION_MARKER);
        const uint32_t country_section_size = static_cast<uint32_t>(
            bundle->country_bytes.size());
        append_u32_le(country_section_size);
        if (country_section_size > 0)
            append_bytes(bundle->country_bytes.data(), country_section_size);
        append_u64_le(country_checkpoint_checksum(bundle->country_bytes.data(),
                                                   country_section_size));
    }

    if (!bundle->economy_asset_bytes.empty()) {
        constexpr uint32_t D7_SECTION_MARKER = 0x31543744u; // D7T1
        append_u32_le(D7_SECTION_MARKER);
        const uint32_t d7_section_size = static_cast<uint32_t>(bundle->economy_asset_bytes.size());
        append_u32_le(d7_section_size);
        append_bytes(bundle->economy_asset_bytes.data(), d7_section_size);
        const uint64_t d7_checksum = economy_save_hash_bytes(
            bundle->economy_asset_bytes.data(), d7_section_size);
        append_u64_le(d7_checksum);
    }

    if (!bundle->trigger_bytes.empty()) {
        constexpr uint32_t TRIGGER_SECTION_MARKER = 0x31445054u; // TPD1
        append_u32_le(TRIGGER_SECTION_MARKER);
        const uint32_t trigger_section_size = static_cast<uint32_t>(bundle->trigger_bytes.size());
        append_u32_le(trigger_section_size);
        append_bytes(bundle->trigger_bytes.data(), trigger_section_size);
        uint64_t trigger_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < trigger_section_size; ++i) {
            trigger_checksum ^= static_cast<uint64_t>(bundle->trigger_bytes[i]);
            trigger_checksum *= 1099511628211ull;
        }
        append_u64_le(trigger_checksum);
    }

    if (!bundle->modifier_bytes.empty()) {
        constexpr uint32_t MODIFIER_SECTION_MARKER = 0x3246444Du; // MDF2
        append_u32_le(MODIFIER_SECTION_MARKER);
        const uint32_t modifier_section_size = static_cast<uint32_t>(
            bundle->modifier_bytes.size());
        append_u32_le(modifier_section_size);
        append_bytes(bundle->modifier_bytes.data(), modifier_section_size);
        uint64_t modifier_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < modifier_section_size; ++i) {
            modifier_checksum ^= static_cast<uint64_t>(bundle->modifier_bytes[i]);
            modifier_checksum *= 1099511628211ull;
        }
        append_u64_le(modifier_checksum);
    }

    if (!bundle->events_bytes.empty()) {
        constexpr uint32_t EVENTS_SECTION_MARKER = 0x31545645u; // EVT1
        append_u32_le(EVENTS_SECTION_MARKER);
        const uint32_t events_section_size = static_cast<uint32_t>(
            bundle->events_bytes.size());
        append_u32_le(events_section_size);
        append_bytes(bundle->events_bytes.data(), events_section_size);
        uint64_t events_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < events_section_size; ++i) {
            events_checksum ^= static_cast<uint64_t>(bundle->events_bytes[i]);
            events_checksum *= 1099511628211ull;
        }
        append_u64_le(events_checksum);
    }

    if (!bundle->gameplay_effect_bytes.empty()) {
        constexpr uint32_t GAMEPLAY_EFFECT_SECTION_MARKER = 0x31504d47u; // GMP1
        append_u32_le(GAMEPLAY_EFFECT_SECTION_MARKER);
        const uint32_t gameplay_effect_section_size = static_cast<uint32_t>(
            bundle->gameplay_effect_bytes.size());
        append_u32_le(gameplay_effect_section_size);
        append_bytes(bundle->gameplay_effect_bytes.data(),
                     gameplay_effect_section_size);
        uint64_t gameplay_effect_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < gameplay_effect_section_size; ++i) {
            gameplay_effect_checksum ^= static_cast<uint64_t>(
                bundle->gameplay_effect_bytes[i]);
            gameplay_effect_checksum *= 1099511628211ull;
        }
        append_u64_le(gameplay_effect_checksum);
    }

    if (!bundle->effect_bytes.empty()) {
        constexpr uint32_t EFFECT_SECTION_MARKER = 0x31504645u; // EFP1
        append_u32_le(EFFECT_SECTION_MARKER);
        const uint32_t effect_section_size = static_cast<uint32_t>(
            bundle->effect_bytes.size());
        append_u32_le(effect_section_size);
        append_bytes(bundle->effect_bytes.data(), effect_section_size);
        uint64_t effect_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < effect_section_size; ++i) {
            effect_checksum ^= static_cast<uint64_t>(bundle->effect_bytes[i]);
            effect_checksum *= 1099511628211ull;
        }
        append_u64_le(effect_checksum);
    }

    if (!bundle->ideology_bytes.empty()) {
        constexpr uint32_t IDEOLOGY_SECTION_MARKER = 0x32504449u; // IDP2
        append_u32_le(IDEOLOGY_SECTION_MARKER);
        const uint32_t ideology_section_size = static_cast<uint32_t>(
            bundle->ideology_bytes.size());
        append_u32_le(ideology_section_size);
        append_bytes(bundle->ideology_bytes.data(), ideology_section_size);
        uint64_t ideology_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < ideology_section_size; ++i) {
            ideology_checksum ^= static_cast<uint64_t>(bundle->ideology_bytes[i]);
            ideology_checksum *= 1099511628211ull;
        }
        append_u64_le(ideology_checksum);
    }

    if (!bundle->economy_pod_bytes.empty()) {
        constexpr uint32_t ECONOMY_POD_SECTION_MARKER = 0x31504345u; // ECP1
        append_u32_le(ECONOMY_POD_SECTION_MARKER);
        const uint32_t economy_section_size = static_cast<uint32_t>(
            bundle->economy_pod_bytes.size());
        append_u32_le(economy_section_size);
        append_bytes(bundle->economy_pod_bytes.data(), economy_section_size);
        const uint64_t economy_checksum = economy_save_hash_bytes(
            bundle->economy_pod_bytes.data(), economy_section_size);
        append_u64_le(economy_checksum);
    }

    if (!bundle->economy_ecp2_bytes.empty()) {
        constexpr uint32_t ECONOMY_ECP2_SECTION_MARKER = 0x32504345u; // ECP2
        append_u32_le(ECONOMY_ECP2_SECTION_MARKER);
        const uint32_t ecp2_section_size = static_cast<uint32_t>(
            bundle->economy_ecp2_bytes.size());
        append_u32_le(ecp2_section_size);
        append_bytes(bundle->economy_ecp2_bytes.data(), ecp2_section_size);
        const uint64_t ecp2_checksum = economy_save_hash_bytes(
            bundle->economy_ecp2_bytes.data(), ecp2_section_size);
        append_u64_le(ecp2_checksum);
    }

    const uint64_t checksum = economy_save_hash_bytes(
        bundle->bytes.data(), bundle->bytes.size());
    bundle->checksum = checksum;
    append_u64_le(bundle->checksum);
    EconomyCostProbe::record("save.wire", bundle->committed_day,
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - wire_started).count(), bundle->bytes.size());

    _save_consumed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(std::move(bundle)),
        std::memory_order_release);
    try_fault_injection("save.barrier.after");
}

} // namespace pk

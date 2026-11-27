#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "native_simulation_host_military.h"
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
#include "runtime_world_environment.h"
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
                                 RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT |
                                 RUNTIME_SAVE_SECTION_EFFECT_TRANSPORT |
                                 RUNTIME_SAVE_SECTION_MILITARY_TERRAIN |
                                 RUNTIME_SAVE_SECTION_SEASON_HISTORY |
                                 RUNTIME_SAVE_SECTION_PLAYER_CONFIRMATION |
                                 RUNTIME_SAVE_SECTION_VISION |
                                 RUNTIME_SAVE_SECTION_BIO |
                                 RUNTIME_SAVE_SECTION_CLIMATE_CALENDAR)) != 0) {
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
    if (!read_u32(cursor, command_count) || cursor + 4u > payload_end ||
        command_count > (payload_end - cursor - 4u) / 52u) {
        error = "runtime_bundle_command_count_invalid";
        return false;
    }
    cursor += 4u;
    parsed.pending_commands.reserve(command_count);
    uint32_t regular_commands = 0;
#include "native_simulation_host_persistence_section_pending_commands.inc"
#include "native_simulation_host_persistence_section_runtime_authorities.inc"
#include "native_simulation_host_persistence_section_gameplay_and_economy.inc"
    // The optional Effect inbox follows the final authority section. Its
    // payload is already covered by the whole bundle checksum.
    for (auto [section, bytes_out] : {
            std::make_pair(RUNTIME_SAVE_SECTION_MILITARY_TERRAIN, &parsed.military_terrain_bytes),
            std::make_pair(RUNTIME_SAVE_SECTION_SEASON_HISTORY, &parsed.season_history_bytes),
            std::make_pair(RUNTIME_SAVE_SECTION_PLAYER_CONFIRMATION, &parsed.player_confirmation_bytes),
            std::make_pair(RUNTIME_SAVE_SECTION_VISION, &parsed.vision_bytes),
            std::make_pair(RUNTIME_SAVE_SECTION_BIO, &parsed.bio_bytes),
            std::make_pair(RUNTIME_SAVE_SECTION_CLIMATE_CALENDAR, &parsed.climate_calendar_bytes)}) {
        if ((parsed.section_mask & section) == 0u) continue;
        uint32_t length = 0;
        if (payload_end - cursor < 4u || !read_u32(cursor, length) ||
                length > payload_end - cursor - 4u) {
            error = "runtime_bundle_producer_cursor_invalid";
            return false;
        }
        cursor += 4u;
        bytes_out->assign(bytes + cursor, bytes + cursor + length);
        cursor += length;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EFFECT_TRANSPORT) != 0u) {
        parsed.effect_transport_bytes.assign(bytes + cursor, bytes + payload_end);
        cursor = payload_end;
    }
    if (cursor != payload_end) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_PLAYER_CONFIRMATION) != 0u &&
            (parsed.player_confirmation_bytes.empty() ||
             !decode_player_confirmation(parsed.player_confirmation_bytes, parsed.committed_day, nullptr))) {
        error = "runtime_bundle_player_confirmation_invalid";
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
    if (try_fault_injection("restore.swap.before")) {
        error = "restore_swap_fault_injected_before";
        _pending_restore_bundle = RuntimeSaveBundle{};
        _has_pending_restore = false;
        return false;
    }
    return true;
}

#include "native_simulation_host_persistence_section_write_bundle.inc"

} // namespace pk

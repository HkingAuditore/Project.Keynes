#pragma once

#include "economy_runtime_persistence_codec.h"

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace pk {

class NativeEconomyRuntime;

constexpr uint32_t RUNTIME_ECONOMY_ECP2_MARKER = 0x32504345u; // "ECP2"
constexpr uint32_t RUNTIME_ECONOMY_ECP2_ABI_VERSION = 2u;
constexpr int32_t RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION = 53;

enum EconomyEcp2Domain : uint32_t {
    ECP2_DOMAIN_ENVELOPE = 1u << 0,
    ECP2_DOMAIN_POPULATION = 1u << 1,
    ECP2_DOMAIN_MARKETS = 1u << 2,
    ECP2_DOMAIN_CELLS = 1u << 3,
    ECP2_DOMAIN_SETTLEMENTS = 1u << 4,
    ECP2_DOMAIN_BUILDINGS = 1u << 5,
    ECP2_DOMAIN_TRADE_ORDERS = 1u << 6,
    ECP2_DOMAIN_FAMILY = 1u << 7,
    ECP2_DOMAIN_RESOURCE = 1u << 8,
    ECP2_DOMAIN_TRADE_FLOWS = 1u << 9,
    ECP2_DOMAIN_FISCAL = 1u << 10,
    ECP2_DOMAIN_COMMANDS = 1u << 11,
    ECP2_DOMAIN_AUDIT = 1u << 12,
    ECP2_DOMAIN_SIGNALS = 1u << 13,
    ECP2_DOMAIN_MODIFIERS = 1u << 14,
    ECP2_DOMAIN_CANAL = 1u << 15,
    ECP2_DOMAIN_EPOCH_RESUME = 1u << 16,
    ECP2_DOMAIN_OWNED_STATE = 1u << 17,
};

constexpr uint32_t ECP2_DOMAIN_CORE_AUTHORITY =
    ECP2_DOMAIN_ENVELOPE | ECP2_DOMAIN_POPULATION | ECP2_DOMAIN_MARKETS |
    ECP2_DOMAIN_CELLS | ECP2_DOMAIN_SETTLEMENTS | ECP2_DOMAIN_BUILDINGS |
    ECP2_DOMAIN_TRADE_ORDERS | ECP2_DOMAIN_FAMILY | ECP2_DOMAIN_RESOURCE |
    ECP2_DOMAIN_TRADE_FLOWS | ECP2_DOMAIN_FISCAL | ECP2_DOMAIN_OWNED_STATE;

constexpr uint32_t ECP2_DOMAIN_FULL_AUTHORITY =
    ECP2_DOMAIN_CORE_AUTHORITY | ECP2_DOMAIN_COMMANDS | ECP2_DOMAIN_AUDIT |
    ECP2_DOMAIN_SIGNALS | ECP2_DOMAIN_MODIFIERS | ECP2_DOMAIN_CANAL |
    ECP2_DOMAIN_OWNED_STATE;

constexpr uint32_t ECP2_CAPTURE_ALLOW_MID_EPOCH = 1u;
constexpr uint32_t ECP2_CAPTURE_INCLUDE_RESUME = 2u;
// In-memory rollback snapshot taken by apply_ecp2_authority. Never persisted,
// so it skips the "Country must be idle" gate that protects real saves.
constexpr uint32_t ECP2_CAPTURE_ROLLBACK_BACKUP = 4u;

struct RuntimeEconomyEcp2Envelope {
    int32_t schema_version = RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION;
    uint32_t abi_version = RUNTIME_ECONOMY_ECP2_ABI_VERSION;
    int32_t cell_count = 0;
    int32_t market_count = 0;
    int32_t good_count = 0;
    int64_t catalog_hash = 0;
    int64_t building_catalog_hash = 0;
    int64_t settlement_catalog_hash = 0;
    int64_t family_catalog_hash = 0;
    int64_t person_catalog_hash = 0;
    int32_t market_cycle_days = 0;
    int32_t plan_cycle_days = 0;
    int32_t investment_cycle_days = 0;
    int64_t epoch_id = 0;
    int64_t last_committed_day = -1;
    int64_t current_day = -1;
    int64_t sample_day = -1;
    int32_t epoch_days = 0;
    uint64_t committed_generation = 0;
    int64_t seed = 0;
};

struct RuntimeEconomyEcp2Resume {
    uint8_t epoch_active = 0;
    int32_t native_stage = 0;
    uint32_t graph_completed_mask = 0;
    int64_t sample_day = -1;
    int64_t current_day = -1;
    int64_t epoch_id = 0;
    int32_t epoch_days = 0;
    uint64_t publish_cursor = 0;
    int32_t publish_order_cursor = 0;
    int32_t publish_line_cursor = 0;
    int32_t executed_stage = 0;
    int32_t publish_phase = 0;
    // Compact-slice / StageOps cursors (M1).
    uint32_t stage_index = 0;
    uint32_t cell_cursor = 0;
    uint32_t group_cursor = 0;
    uint32_t command_cursor = 0;
    uint32_t structural_cursor = 0;
    uint32_t building_cell_cursor = 0;
    uint32_t plan_evaluate_cursor = 0;
    int32_t building_plan_phase = 0;
    int32_t household_market_phase = 0;
    int32_t household_post_cursor = 0;
    int32_t building_commit_phase = 0;
    int32_t building_commit_cursor = 0;
    int32_t building_finalize_phase = 0;
    int32_t family_commit_cursor = 0;
    int32_t family_commit_phase = 0;
    int32_t person_commit_cursor = 0;
    int32_t person_commit_phase = 0;
    uint32_t slice_index = 0;
    uint8_t waiting_for_peer = 0;
    uint8_t evaluate_phase = 0;
    uint8_t trade_plan_phase = 0;
    uint32_t trade_plan_scan_cursor = 0;
    uint32_t trade_plan_route_cursor = 0;
};

struct RuntimeEconomyEcp2State {
    int32_t schema_version = RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION;
    uint32_t abi_version = RUNTIME_ECONOMY_ECP2_ABI_VERSION;
    uint32_t authority_domain_mask = 0;
    uint64_t content_hash = 0;
    RuntimeEconomyEcp2Envelope envelope{};
    std::unordered_map<uint32_t, std::vector<uint8_t>> domain_blobs;
    RuntimeEconomyEcp2Resume resume{};
};

uint32_t ecp2_domain_for_pkec_section(uint16_t section) noexcept;
bool ecp2_has_required_domains(uint32_t mask, uint32_t required) noexcept;
void ecp2_collect_pkec_chunks_for_section(
    const std::unordered_map<uint32_t, std::vector<uint8_t>> &domain_blobs,
    uint16_t section, std::vector<std::vector<uint8_t>> &out);

bool encode_ecp2(const RuntimeEconomyEcp2State &state,
                 std::vector<uint8_t> &out, std::string &error);
bool decode_ecp2(const uint8_t *data, size_t size,
                 RuntimeEconomyEcp2State &out, std::string &error);

bool runtime_economy_ecp2_self_test(std::string &error);

} // namespace pk

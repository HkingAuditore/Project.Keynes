#pragma once

// Public peer surface; each free function forwards to one runtime member.
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include "country_read_view.h"
#include "country_fiscal_return_intent.h"
#include "country_procurement_intent.h"

namespace godot { class Dictionary; }

namespace pk {
class NativeCountryRuntime;

// EffectRuntime's country adapter uses this POD ABI.  `payload` is
// precompiled by the Effect catalog: [cell|aux], [domain|position], four
// packed int16 research weights, and tax kind/item/rate respectively.
struct CountryEffectCommand {
    int32_t opcode = 0;
    int64_t effective_day = 0;
    int64_t sequence = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int64_t value = 0;
    std::array<int64_t, 4> payload{};
    uint64_t idempotency_key = 0;
    const char *stable_id = nullptr;
    const char *display_name = nullptr;
};
struct CountryApi {
    // v15: inactive records plus persistent political regime state.
    static constexpr int32_t SCHEMA_VERSION = 15;
    static constexpr uint32_t CAP_TREASURY_CONSTRUCTION = 1u << 0u;
    static constexpr int64_t MONEY_SCALE = 10000;
    static constexpr int64_t GOODS_SCALE = 1000;
    static constexpr int32_t NEUTRAL_SLOT = -1;
    // Percent mode: signed basis points. Positive taxes are capped at 100%,
    // while subsidies may reach 1000%. Absolute mode: signed currency per
    // countable unit. INT32_MIN is reserved for inheritance on both lanes.
    static constexpr int32_t TAX_RATE_MIN_BP = -100000;
    static constexpr int32_t TAX_RATE_MAX_BP = 10000;
    static constexpr int32_t TAX_ABSOLUTE_MIN = -1000000000;
    static constexpr int32_t TAX_ABSOLUTE_MAX = 1000000000;
    static constexpr int32_t TAX_RATE_INHERIT =
        std::numeric_limits<int32_t>::min();
    static constexpr int32_t TAX_MODE_INHERIT =
        std::numeric_limits<int32_t>::min();

    enum TaxKind : int32_t {
        TAX_INCOME = 0,
        TAX_TRANSACTION = 1,
        TAX_CONSUMPTION = TAX_TRANSACTION, // Compatibility alias.
        TAX_BUSINESS = 2,
        TAX_IMPORT = 3,
        TAX_EXPORT = 4,
        TAX_KIND_COUNT = 5,
    };

    enum TaxAssessmentMode : int32_t {
        TAX_MODE_PERCENT_BP = 0,
        TAX_MODE_ABSOLUTE = 1,
    };

    enum CommandOpcode : int32_t {
        COMMAND_CREATE_COUNTRY = 1,
        COMMAND_RENAME_COUNTRY = 2,
        COMMAND_TRANSFER_TERRITORY = 3,
        COMMAND_GRANT_TECHNOLOGY = 4,
        COMMAND_SET_RESEARCH_WEIGHTS = 5,
        COMMAND_ENQUEUE_RESEARCH = 6,
        COMMAND_REMOVE_RESEARCH = 7,
        COMMAND_MOVE_RESEARCH = 8,
        COMMAND_SET_RESEARCH_BUDGET = 9,
        COMMAND_REVEAL_ALL_TECHNOLOGIES = 10,
        COMMAND_SET_TAX_DEFAULT = 11,
        COMMAND_SET_TAX_OVERRIDE = 12,
        COMMAND_CLEAR_TAX_OVERRIDE = 13,
        // Internal/domain command: static map/event evidence becomes
        // country-owned research knowledge at the country command boundary.
        COMMAND_DISCOVER_COUNTRY_SIGNAL = 14,
        COMMAND_SET_CELL_TAX_DEFAULT = 15,
        COMMAND_CLEAR_CELL_TAX_DEFAULT = 16,
        COMMAND_SET_CELL_TAX_OVERRIDE = 17,
        COMMAND_CLEAR_CELL_TAX_OVERRIDE = 18,
        COMMAND_CLEAR_CELL_TAX_POLICY = 19,
        // Effect-only territorial acquisition used by family expeditions.
        // Unlike TRANSFER_TERRITORY this is compare-and-set: the command is
        // rejected unless the committed/staged owner is still neutral.
        COMMAND_CLAIM_UNOWNED_TERRITORY = 20,
        // Era advancement: aux = good dense id, value = GOODS_SCALE quantity.
        // Validated against the staged treasury (earlier commands in the same
        // batch included); insufficient stock rejects the whole batch. The
        // consumed quantity feeds a transient per-country sink counter that
        // Economy treats like research consumption in the goods audit.
        COMMAND_CONSUME_TREASURY_GOODS = 21,
        // 22/25/26 are reserved (cell controller lives in Military) and are
        // rejected at admission as country_command_opcode_unsupported.
        COMMAND_RESERVED_22 = 22,
        // Military v1 peace/annex commands. Receiver/annexer handle is packed
        // as cell = receiver slot, aux = receiver generation, i.e.
        // ((uint64)aux << 32) | (uint32)cell. Transfers move
        // min(available balance, value) and conserve totals exactly.
        COMMAND_TRANSFER_CASH_BETWEEN_COUNTRIES = 23,   // value = MONEY_SCALE
        COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES = 24,  // domain = good, value = GOODS_SCALE
        COMMAND_RESERVED_25 = 25,
        COMMAND_RESERVED_26 = 26,
        // target_handle = victim. Atomic within the batch: all territory,
        // cash and goods move to the annexer; the victim becomes inactive
        // with generation + 1, so later commands holding the old handle are
        // rejected as country_handle_invalid.
        COMMAND_ANNEX_COUNTRY = 27,
        COMMAND_SET_POLITICAL_REGIME = 28,
        COMMAND_OPCODE_MAX = COMMAND_SET_POLITICAL_REGIME,
    };

    enum AssetOperation : int32_t {
        ECONOMY_ASSET_RESEARCH_PURCHASE = 1,
        ECONOMY_ASSET_FISCAL_RESERVE = 2,
        ECONOMY_ASSET_FISCAL_RETURN = 3,
        ECONOMY_ASSET_FISCAL_COLLECT = 4,
        ECONOMY_ASSET_CASH_TO_COHORT = 5,
        ECONOMY_ASSET_CASH_FROM_COHORT = 6,
        ECONOMY_ASSET_GOOD_TO_MARKET = 7,
        ECONOMY_ASSET_GOOD_FROM_MARKET = 8,
        ECONOMY_ASSET_TREASURY_SPEND = 9,
    };
    enum AssetTransactionStatus : int32_t {
        ECONOMY_ASSET_CREATED = 1,
        ECONOMY_ASSET_COUNTRY_PREPARED = 2,
        ECONOMY_ASSET_PEER_PREPARED = 3,
        ECONOMY_ASSET_COMMIT_DECIDED = 4,
        ECONOMY_ASSET_COUNTRY_APPLIED = 5,
        ECONOMY_ASSET_PEER_APPLIED = 6,
        ECONOMY_ASSET_COMPLETED = 7,
        ECONOMY_ASSET_REJECTED = 8,
        // Explicit asynchronous bridge states.  The legacy values above are
        // retained for compatibility with the synchronous accounting report.
        ECONOMY_ASSET_AWAITING_PEER_PREPARED = 9,
        ECONOMY_ASSET_AWAITING_PEER_APPLIED = 10,
        ECONOMY_ASSET_FAULTED = 11,
    };

    // Minimal cross-section authority for an era reward. The complete frozen
    // alternatives remain in PKEF; PKCN stores only this reference/state so a
    // restore can reject orphaned or contradictory offers.
    struct EraRewardReference {
        int64_t plan_id = 0;
        int64_t offer_generation = 0;
        int32_t milestone_technology = -1;
        int32_t status = 0;
    };
};
using CountryEconomySnapshot = CountryReadView::Snapshot;

namespace country_api {
// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
bool copy_economy_snapshot(const NativeCountryRuntime &country, CountryEconomySnapshot &out);
int64_t cash_for_slot(const NativeCountryRuntime &country, int32_t country_slot);
bool has_technology(const NativeCountryRuntime &country, int32_t country_slot, int32_t technology_id);
uint32_t political_regime_capabilities(const NativeCountryRuntime &country, int32_t country_slot);
int32_t political_regime_id(const NativeCountryRuntime &country, int32_t country_slot);
int32_t country_slot_for_cell(const NativeCountryRuntime &country, int32_t cell);
bool valid_handle(const NativeCountryRuntime &country, int64_t handle);
int64_t last_committed_day(const NativeCountryRuntime &country);
bool sync_store_writes_forbidden(const NativeCountryRuntime &country);

// ---- Economy (economy_runtime.cpp, economy_runtime_annual.cpp, economy_runtime_building_employment.cpp, economy_runtime_building_investment.cpp, economy_runtime_building_production.cpp, economy_runtime_colonization_kit.cpp, economy_runtime_diagnostics.cpp, economy_runtime_fiscal.cpp, economy_runtime_internal_external_types.inc, economy_runtime_market.cpp, economy_runtime_military_view.cpp, economy_runtime_persistence_read.cpp, economy_runtime_persistence_write.cpp, economy_runtime_procurement.cpp, economy_runtime_queries_market_building.cpp, economy_runtime_trade.cpp, runtime_economy_army_personnel.cpp)
CountryReadView read_view(const NativeCountryRuntime &country);
CountryFiscalReturnPort fiscal_return_port(NativeCountryRuntime &country);
CountryProcurementPort procurement_port(NativeCountryRuntime &country);
bool economy_available(const NativeCountryRuntime &country);
int64_t country_handle_for_cell(const NativeCountryRuntime &country, int32_t cell);

// ---- Effect (effect_runtime.cpp)
bool submit_effect_commands_pod(NativeCountryRuntime &country, const CountryEffectCommand *commands, size_t count, std::vector<int64_t> &request_ids, std::string &error);
void drain_effect_host_command_receipts(NativeCountryRuntime &country);
bool effect_command_result_pod(const NativeCountryRuntime &country, int64_t request_id, bool &complete, bool &ok, std::string &reason);
godot::Dictionary country_snapshot(const NativeCountryRuntime &country, int64_t handle);
godot::Dictionary treasury_snapshot(const NativeCountryRuntime &country, int64_t handle);
godot::Dictionary research_snapshot(const NativeCountryRuntime &country, int64_t handle);
godot::Dictionary research_signal_snapshot(const NativeCountryRuntime &country, int64_t handle);
void set_era_reward_reference_pod(NativeCountryRuntime &country, int64_t plan_id, int64_t offer_generation, int32_t milestone_technology, int32_t status);
CountryApi::EraRewardReference era_reward_reference_pod(const NativeCountryRuntime &country);
int64_t world_seed(const NativeCountryRuntime &country);

// ---- Ideology (ideology_runtime.cpp)
bool has_research_signal(const NativeCountryRuntime &country, int32_t country_slot, int32_t signal_id);

// ---- Modifier (modifier_runtime.cpp)
} // namespace country_api
} // namespace pk

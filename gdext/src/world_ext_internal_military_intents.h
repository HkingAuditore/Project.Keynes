#pragma once

#include "economy_api.h"
#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

namespace {

using godot::Dictionary;
using godot::String;

// Country opcodes the military bridge is allowed to submit. 23/24/27 are the
// treaty opcodes the Country owner adds; 22/25/26 stay reserved for Country.
constexpr int32_t MCOUNTRY_TRANSFER_TERRITORY = 3;
constexpr int32_t MCOUNTRY_CONSUME_TREASURY_GOODS = 21;
constexpr int32_t MCOUNTRY_TRANSFER_CASH = 23;
constexpr int32_t MCOUNTRY_TRANSFER_GOODS = 24;
constexpr int32_t MCOUNTRY_ANNEX = 27;

// Economy opcodes from the public contract.
constexpr int32_t MECONOMY_TRANSFER_TO_COHORT = EconomyApi::COMMAND_TRANSFER_TO_COHORT;
constexpr int32_t MECONOMY_REMOVE_STOCK = EconomyApi::COMMAND_REMOVE_STOCK;
constexpr int32_t MECONOMY_ADD_POPULATION = EconomyApi::COMMAND_ADD_POPULATION;
constexpr int32_t MECONOMY_CHANGE_SIGNATURE = EconomyApi::COMMAND_CHANGE_SIGNATURE;
constexpr int32_t MECONOMY_CONVERT_COHORT = EconomyApi::COMMAND_MILITARY_CONVERT_COHORT;   // B: (cell, src sig, dst sig, heads)
constexpr int32_t MECONOMY_MARKET_GOOD_TO_COUNTRY = EconomyApi::COMMAND_MARKET_GOOD_TO_COUNTRY;
// Army personnel lane (army-personnel contract §1.2). Same POD lane as 24:
// payload0 = heads, payload1 = destination lane for MERGE_LANES, target_cohort
// = army handle, target_cell = the cell, target_country = soldier signature.
constexpr int32_t MECONOMY_ARMY_EMBARK = EconomyApi::COMMAND_ARMY_EMBARK;
constexpr int32_t MECONOMY_ARMY_DISEMBARK = EconomyApi::COMMAND_ARMY_DISEMBARK;
constexpr int32_t MECONOMY_ARMY_MERGE_LANES = EconomyApi::COMMAND_ARMY_MERGE_LANES;
// Split / partial transfer (army-personnel contract-2 §1.1). Lane -> lane like
// 32, so no cohort is named and no structural command is needed: payload0 =
// heads actually moved, payload1 = destination army handle, target_cohort =
// source army handle. payload0 <= 0 means "the whole lane" on the Economy side;
// Military emits 32 for that case instead (contract §1.2).
constexpr int32_t MECONOMY_ARMY_SPLIT_LANES = EconomyApi::COMMAND_ARMY_SPLIT_LANES;
// Army pay (army-pay contract §3, Economy opcode 34): payload0 = MONEY_SCALE
// amount, payload1 = country handle, target_cohort = army handle. Treasury cash
// only — no cohort and no structural command — so it rides the same POD lane as
// 24/30-33 and is deduplicated by `sequence` there.
constexpr int32_t MECONOMY_ARMY_LANE_PAY = EconomyApi::COMMAND_ARMY_LANE_PAY;

bool is_army_lane_opcode(int32_t opcode) {
    return opcode == MECONOMY_ARMY_EMBARK || opcode == MECONOMY_ARMY_DISEMBARK ||
           opcode == MECONOMY_ARMY_MERGE_LANES || opcode == MECONOMY_ARMY_SPLIT_LANES ||
           opcode == MECONOMY_ARMY_LANE_PAY;
}

// Numeric range of the core's stable purchase request ids (physical-maintenance
// design D6). Economy keys POD admission and receipt rows on `sequence` alone,
// so purchase identities live above the bridge counter's range and can never
// alias an unrelated command.
constexpr int64_t kMilitaryPurchaseSequenceBase = 1ll << 40;

// Both lane feature methods exist in this build; retain their runtime answers.
bool army_lane_split_supported(const NativeEconomyRuntime *runtime) {
    if (runtime == nullptr) return false;
    return economy_api::military_army_lane_split_supported(*runtime);
}

bool army_lane_pay_supported(const NativeEconomyRuntime *runtime) {
    if (runtime == nullptr) return false;
    return economy_api::military_army_lane_pay_supported(*runtime);
}

Dictionary military_fail(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = String(reason);
    return out;
}

} // namespace

// Army personnel lane helpers, defined in world_ext_economy_military.cpp.
// Null Economy answers false / -1; this build has all lane bindings.
bool economy_army_lane_supported(const void *economy);
int64_t economy_army_lane_population(void *economy, uint64_t army_handle);
int64_t economy_army_lane_funds(void *economy, uint64_t army_handle);
bool economy_set_army_ration(void *economy, uint64_t army_handle, int32_t q16);

} // namespace pk

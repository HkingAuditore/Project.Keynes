#pragma once

// Military <-> Country/Economy bridge contract (v1).
//
// This header is the ONLY shared surface between the pure military core
// (military_core*.cpp, no Godot types) and the Godot-facing bridge
// (world_ext_military.cpp) that talks to NativeCountryRuntime /
// NativeEconomyRuntime. Keep it POD, integer-only and allocation-free in the
// hot path: vectors are sized once per day by the bridge and reused.
//
// Units: people are plain int64 heads; money uses MONEY_SCALE (10000);
// goods use GOODS_SCALE (1000); fractions use q16 (65536 == 1.0) unless a
// field says _bp (10000 == 100%).

#include <cstdint>
#include <vector>

namespace pk {

constexpr int64_t MILITARY_MONEY_SCALE = 10000;
constexpr int64_t MILITARY_GOODS_SCALE = 1000;
constexpr int32_t MILITARY_Q16 = 65536;

// --- Frozen inputs (bridge -> core), captured once per military day -------

// Static/slow topology. Rebuilt only when the map changes or the season
// refreshes cover (snow/flood/glacier).
struct MilitaryTerrainInput {
    int32_t cell_count = 0;
    int32_t width = 0;            // columns, east-west wraps
    int32_t height = 0;
    std::vector<int32_t> neighbors;   // cell_count * 6, -1 = none
    std::vector<uint8_t> landform;    // LandformType.LF
    std::vector<uint8_t> vegetation;  // VegetationType.VEG
    std::vector<uint8_t> cover;       // CoverType.CV
    std::vector<uint8_t> is_water;
    std::vector<uint8_t> has_river;
    std::vector<uint8_t> settlement_tier; // 0 none,1 village,2 town,3 city,4 capital
};

// Per-day committed Country/Economy view. Dense per cell where noted;
// sparse per-country arrays are indexed by country slot.
struct MilitaryWorldDigest {
    int64_t day = -1;
    int32_t country_capacity = 0;
    std::vector<int32_t> cell_owner_slot;      // -1 neutral
    std::vector<uint64_t> country_handle;      // by slot, 0 = inactive
    std::vector<int64_t> country_cash;         // MONEY_SCALE
    std::vector<int32_t> country_era;          // era index 0..10
    std::vector<int64_t> country_annual_revenue; // MONEY_SCALE, rolling
    std::vector<int32_t> country_capital_cell;
    // Per cell (dense, cell_count). 0 when unknown.
    std::vector<int64_t> cell_population;
    std::vector<int64_t> cell_unemployed;      // levy / volunteer pool
    std::vector<int64_t> cell_soldiers;        // committed soldier cohort heads
    std::vector<uint8_t> cell_has_merchant;
    // Supply market view, sparse: rows of (cell, good, sellable, price).
    // `sellable` already excludes the 12.5% merchant floor.
    std::vector<int32_t> market_cell;
    std::vector<int32_t> market_good;
    std::vector<int64_t> market_sellable;      // GOODS_SCALE
    std::vector<int64_t> market_price;         // MONEY_SCALE per 1.0 good
    // Average non-food soldier living cost per head/day, by country slot.
    std::vector<int64_t> country_soldier_living_cost; // MONEY_SCALE
    // Technology gate: bitset rows per country over military unlock ids
    // compiled in MilitaryCatalog (unit + state building unlocks).
    int32_t unlock_words = 0;
    std::vector<uint64_t> country_unlock_bits; // country_capacity * unlock_words
    // Military Modifier stats, by country slot, q16 (see MilitaryStatId).
    int32_t stat_count = 0;
    std::vector<int32_t> country_stat_q16;     // country_capacity * stat_count
    // State (kind 3) building groups, sparse, sorted by (cell, type). This is a
    // read of the economy ledger, not a second tally: the core rebuilds
    // `MilitaryCellState::barracks_count` / `fort_tier` / `college_tier` from
    // these rows every day and never increments them locally (requirement
    // 6.1-6.3). `units` counts building instances, the same unit the demolish
    // lane decrements; a row whose count already reached zero is dropped by the
    // producer so a demolished-but-unpruned group never reads as standing.
    //
    // `state_lanes_present` separates "the ledger answered and it is empty"
    // from "the producer has no such lane" (a bridge compiled before this
    // contract). Only the former may zero the military cache; the latter must
    // leave the restored cache alone.
    int32_t state_lane_rows = 0;
    bool state_lanes_present = false;
    std::vector<int32_t> state_cell;
    std::vector<int32_t> state_type_id;
    std::vector<int32_t> state_state_role;   // economy STATE_ROLE_* (1..3)
    std::vector<int64_t> state_units;
};

// --- Outputs (core -> bridge), emitted for effective day D+1 --------------

enum MilitaryIntentKind : uint16_t {
    MILITARY_INTENT_NONE = 0,
    // Economy
    MILITARY_INTENT_ENLIST = 1,          // cell, count: unemployed -> soldier
    MILITARY_INTENT_LEVY = 2,            // cell, count: forced (any worker)
    MILITARY_INTENT_DISCHARGE = 3,       // cell, count: soldier -> unemployed
    MILITARY_INTENT_CASUALTY = 4,        // cell, count: soldier cohort deaths
    MILITARY_INTENT_PAY_WAGES = 5,       // country, cell, amount: treasury -> soldier cohort cash
    MILITARY_INTENT_PROCURE_GOOD = 6,    // country, cell(market), good, qty: market -> treasury (paid)
    MILITARY_INTENT_CONSUME_TREASURY_GOOD = 7, // country, good, qty: treasury good consumed
    MILITARY_INTENT_REQUISITION = 8,     // cell, good, qty: market stock seized (no pay)
    MILITARY_INTENT_SPEND_CASH = 9,      // country, amount: upkeep/build cash spend
    // Army personnel lane (army-personnel contract §2.1; Economy opcodes
    // 30/31/32/33 in the same POD lane as 24). The army handle rides in
    // `source_id` so the receipt can name the formation, and it is the lane key
    // on the Economy side (contract §1.2: target_cohort = army handle). The
    // soldier signature is resolved by the ECONOMY runtime for the named cell;
    // Military never passes a cohort slot id.
    MILITARY_INTENT_ARMY_EMBARK = 10,      // army, cell, count: cell soldier cohort -> lane
    MILITARY_INTENT_ARMY_DISEMBARK = 11,   // army, cell, count: lane -> cell soldier cohort
    MILITARY_INTENT_ARMY_MERGE_LANES = 12, // country_a = src army, country_b = dst army
    // Split / partial transfer (contract §1.2, Economy opcode 33): `count` heads
    // leave the source formation's lane and join the destination formation's
    // lane. `count` is the head count of the lots that actually moved (never the
    // template), so the two lanes keep summing to the formations' lots.
    // country_a = src army handle (target_cohort), country_b = dst army handle.
    MILITARY_INTENT_ARMY_SPLIT_LANES = 13,
    // Army pay (army-pay contract §2.1, Economy opcode 34): the wages of the
    // people who actually march with the formation are paid into its lane
    // instead of the garrison cell they left behind. `source_id` = army handle
    // (the lane key on the Economy side), `count` = heads on the formation's
    // lots, `amount` = heads x the daily per-head wage (the SAME value the
    // garrison path uses), `country_a` = the paying country. Appended after 13
    // so no existing kind is renumbered.
    MILITARY_INTENT_ARMY_PAY = 14,
    // State building request (military-state-buildings-economy-integration 4.x).
    // `state.build` is not a settlement: the bridge turns this request into a
    // `queue_treasury_sponsored_build` call, and only a successful economy
    // acceptance is echoed back as `MCMD_STATE_BUILD` for the core's own
    // completion-day bookkeeping. Emitted by the AI (which has no command
    // ingress of its own) and by any caller that only has the intent lane.
    // cell, count = state building index, country_a = payer.
    MILITARY_INTENT_STATE_BUILD = 15,
    // State building removal (military-state-buildings-economy-integration 6.5).
    // The mirror of 15: the bridge turns this request into a
    // `queue_treasury_sponsored_demolish` call and only an accepted removal is
    // echoed back as `MCMD_STATE_DEMOLISH` for the core's bookkeeping, so the
    // economy ledger is always the first to change and the core can never
    // report a demolition the ledger did not record.
    // cell, count = state building index, country_a = owner. One unit per row.
    MILITARY_INTENT_STATE_DEMOLISH = 16,
    // Replacement snapshot of funded, unfilled procurement. cell=-1 clears
    // the previous snapshot; other rows name a real good (never a category).
    // count=goods, amount=normalization days. No custody or cash movement.
    MILITARY_INTENT_PROCUREMENT_DEMAND = 17,
    // Country
    MILITARY_INTENT_TRANSFER_TERRITORY = 20, // cell, to_country (treaty cession)
    MILITARY_INTENT_TRANSFER_CASH = 21,      // from, to, amount (reparations)
    MILITARY_INTENT_TRANSFER_GOODS = 22,     // from, to, good, qty
    MILITARY_INTENT_ANNEX_COUNTRY = 23,      // victim, annexer
};

struct MilitaryIntent {
    uint16_t kind = MILITARY_INTENT_NONE;
    uint16_t reserved = 0;
    int32_t cell = -1;
    int32_t good = -1;
    int32_t pad = 0;
    uint64_t country_a = 0;   // payer / owner / victim / from
    uint64_t country_b = 0;   // receiver / annexer / to
    int64_t count = 0;        // heads or GOODS_SCALE quantity
    int64_t amount = 0;       // MONEY_SCALE
    uint64_t source_id = 0;   // army/war/shipment id for receipts
};

// Gameplay facts published to GameplayEventBus (types 40..47).
enum MilitaryEventType : uint16_t {
    MILITARY_EVENT_WAR_DECLARED = 40,
    MILITARY_EVENT_WAR_ENDED = 41,
    MILITARY_EVENT_BATTLE_RESOLVED = 42,
    MILITARY_EVENT_CELL_CONTROL_CHANGED = 43,
    MILITARY_EVENT_ARMY_DESTROYED = 44,
    MILITARY_EVENT_COUNTRY_ANNEXED = 45,
    MILITARY_EVENT_CONVOY_INTERCEPTED = 46,
    MILITARY_EVENT_LEVY_APPLIED = 47,
};

struct MilitaryEvent {
    uint64_t id = 0;
    int64_t day = 0;
    uint16_t type = 0;
    uint16_t payload_schema = 0;  // 20..25
    int32_t cell = -1;
    uint64_t i0 = 0, i1 = 0, i2 = 0, i3 = 0;
    int64_t value = 0;
};

// Receipt for an intent after the bridge applied it (fed back next day so
// the core can reconcile lots against committed cohorts).
struct MilitaryIntentReceipt {
    uint16_t kind = 0;
    uint8_t ok = 0;
    uint8_t pad = 0;
    int32_t cell = -1;
    uint64_t source_id = 0;
    int64_t committed_count = 0;
    int64_t committed_amount = 0;
};

} // namespace pk

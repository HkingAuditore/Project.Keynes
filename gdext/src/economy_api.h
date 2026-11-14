#pragma once

// Public Economy surface for peer modules (Country, Effect, Ideology, Modifier,
// Trigger, presentation caches). Peers include this header instead of
// economy_runtime.h; see docs/architecture/module-boundaries.md ("Module API
// headers"). Rules:
//   * Only PODs, enums, constants and free-function declarations live here.
//   * Never include economy_runtime*.h or any Economy-internal header.
//   * NativeEconomyRuntime derives from EconomyApi, so the historical names
//     NativeEconomyRuntime::COMMAND_* / FAMILY_METRIC_* / EffectCommand keep
//     working inside Economy; peers spell them EconomyApi::*.
//   * Calls into the runtime go through the economy_api:: free functions
//     (economy_api.cpp); each forwards to exactly one member, unchanged.

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "metric_mask.h"
#include "effect_selector_cap.h"

namespace godot { class Dictionary; class Array; }

namespace pk {

class NativeEconomyRuntime;

// P3-B: everything a reader depends on is published as ONE immutable snapshot.
// Reading the counters one by one let a card see metric A's new revision next to
// metric B's old one; reading one snapshot cannot.
//
// Namespace scope, not nested: the class both stores it and reads it from another
// translation unit, and a nested private type cannot be named there.
//
// The array length MUST be the real metric count. `FAMILY_METRIC_COUNT` lives inside
// `NativeEconomyRuntime`, which is declared AFTER this struct, so the length used to be
// the literal `68` -- and when R-4 appended metrics 68 and 69 nobody widened it. The
// result was a 2-element heap overwrite on every publish that touched a new metric:
// `economy_runtime_family_buff.cpp` does `++next->metric_revision[slot]` for
// `slot == 68/69`, and Windows logged ~65 `0xc0000374` (heap corruption) crashes from
// 14:27 on. A card reading metric 68 (`land_tax_reform` L3, `light_levy`) triggered it
// every time, which is why the worker tests "stopped at day 1" -- the process died, it
// did not get slow.
//
// `PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY` is the namespace-scope mirror of
// `FAMILY_METRIC_COUNT`; the `static_assert` below the enum keeps the two in lockstep.
constexpr int32_t PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY = 108;

struct EffectInputSnapshot {
    uint64_t generation = 0;
    uint64_t territory_revision = 0;
    uint64_t tag_revision = 0;
    uint64_t family_revision = 0;
    std::array<uint64_t, PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY> metric_revision{};
};

struct EconomyMilitaryCellView {
    std::vector<int64_t> population;
    std::vector<int64_t> unemployed;    // unemployed-profession heads
    std::vector<int64_t> soldiers;      // soldier-profession heads
    std::vector<uint8_t> has_merchant;  // a live merchant serves the cell
};

struct EconomyApi {
    enum EventKind : int32_t {
        EVENT_COMMAND_SETTLED = 1,
        EVENT_MARKET_SETTLED = 2,
        EVENT_STRUCTURAL_CHANGE = 3,
        EVENT_CONSTRUCTION_STARTED = 4,
        EVENT_CONSTRUCTION_COMPLETED = 5,
        EVENT_BUILDING_DEMOLISHED = 6,
        EVENT_EMPLOYMENT_SETTLED = 7,
        EVENT_WAGE_SETTLED = 8,
        EVENT_BUILDING_PRODUCTION_SETTLED = 9,
        EVENT_EPOCH_COMMITTED = 10,
        EVENT_RESTORE_BOUNDARY = 11,
        EVENT_TRADE_DISPATCHED = 12,
        EVENT_TRADE_ARRIVED = 13,
        EVENT_POPULATION_SOURCE = 14,
        EVENT_TARIFF_SUBSIDY_INTENT = 15,
        // 市场级人口变化（births/deaths 汇总）。逐格出生分摊在 market 结算内部，
        // 这里只发市场级 delta，够表现层做音效/特效，且不进热路径。
        EVENT_POPULATION_CHANGED = 16,
    };

    enum CommandOpcode : int32_t {
        COMMAND_TRANSFER_TO_COHORT = 1,
        COMMAND_MINT_TO_COHORT = 2,
        COMMAND_BURN_FROM_COHORT = 3,
        COMMAND_ADD_STOCK = 4,
        COMMAND_REMOVE_STOCK = 5,
        COMMAND_ADD_POPULATION = 6,
        COMMAND_MOVE_POPULATION = 7,
        COMMAND_CHANGE_SIGNATURE = 8,
        // B: state-directed cohort conversion inside one cell. The caller names
        // (cell, source signature, destination signature) so no cohort slot id
        // ever crosses an execution boundary; Economy resolves the cohort in
        // whichever store owns the day and moves the people there.
        COMMAND_MILITARY_CONVERT_COHORT = 24,
        COMMAND_TRANSFER_FROM_COHORT = 9,
        COMMAND_BUILD = 10,
        COMMAND_DEMOLISH = 11,
        COMMAND_COUNTRY_GOOD_TO_MARKET = 12,
        COMMAND_MARKET_GOOD_TO_COUNTRY = 13,
        COMMAND_FAMILY_FREE_BUILDING = 14,
        COMMAND_FAMILY_POPULATION_REWARD = 15,
        COMMAND_TREASURY_SPONSORED_BUILD = 16,
        COMMAND_START_FAMILY_EXPEDITION = 17,
        COMMAND_CANCEL_FAMILY_EXPEDITION = 18,
        COMMAND_SETTLE_FAMILY_EXPEDITION = 19,
        // Domain-only command. It is intentionally not accepted by the generic
        // submit_commands() API; EconomyFacade can enqueue it only after a
        // server-owned quote token has been validated.
        COMMAND_BUILD_CANAL = 20,
        COMMAND_FAMILY_ABSORB_ANONYMOUS = 21,
        COMMAND_FAMILY_PURCHASE_DISCOUNT = 22,
        COMMAND_FAMILY_SET_SPLIT_POLICY = 23,
        // BEGIN army personnel lane (contract §1.2). Same wire shape as opcode
        // 24: the army is named by its Military handle (never a slot id), the
        // cohort by (target_cell, signature) and the head count by payload0.
        //   target_cohort = army handle, target_cell = cell,
        //   target_country = signature, payload0 = heads,
        //   payload1 = destination army handle (merge / split).
        COMMAND_ARMY_EMBARK = 30,
        COMMAND_ARMY_DISEMBARK = 31,
        COMMAND_ARMY_MERGE_LANES = 32,
        // 33: heads (payload0) move from the src lane (target_cohort) into the
        // dst lane (payload1), money proportional, destination created on
        // demand. payload0 <= 0 means "move the whole lane" (opcode 32's
        // semantics, without releasing a destination). Lane -> lane only: the
        // cohorts are not touched, so no structural command is needed.
        COMMAND_ARMY_SPLIT_LANES = 33,
        // 34: army pay (army-pay contract §1). payload0 = MONEY_SCALE amount,
        // payload1 = country handle, target_cohort = army handle. The treasury
        // cash is collected through the existing conserved non-tax expenditure
        // path (military_collect_cash) and credited to the lane: exactly what
        // the treasury lost. No cohort is touched and nothing is minted, so no
        // structural command is needed; deduplicated by `sequence` like 24/30-33.
        COMMAND_ARMY_LANE_PAY = 34,
        // Standing military demand snapshot, retained in the saved command
        // queue until a newer reset replaces it. cell=-1 is the reset marker;
        // payload0=missing goods, payload1=normalization days.
        COMMAND_MILITARY_PROCUREMENT_DEMAND = 36,
        COMMAND_MILITARY_PURCHASE = 37,
        COMMAND_MILITARY_PURCHASE_RECEIPT = 38,
        COMMAND_MILITARY_PURCHASE_ACK = 39,
        // END army personnel lane
        // 35: treasury-sponsored DEMOLISH of a state lot. Payload matches
        // opcode 16: i32_0=cell, i32_1=type_id, i64_0=count,
        // i64_1=OWNERSHIP_TREASURY_SPONSORED_PRIVATE, target_handle=country.
        COMMAND_TREASURY_SPONSORED_DEMOLISH = 35,
    };

    enum FamilyEffectMetricId : int32_t {
        FAMILY_METRIC_MAGNITUDE_Q16 = 0,
        FAMILY_METRIC_FAMILY_POPULATION = 1,
        FAMILY_METRIC_FAMILY_CASH_CLAIM = 2,
        FAMILY_METRIC_BRANCH_PRESTIGE_Q16 = 3,
        FAMILY_METRIC_BRANCH_POPULATION = 4,
        FAMILY_METRIC_CELL_TEMPERATURE_Q16 = 5,
        FAMILY_METRIC_CELL_PRECIPITATION_Q16 = 6,
        FAMILY_METRIC_CELL_RESOURCE_SHORTAGE_Q16 = 7,
        FAMILY_METRIC_CELL_TRADE_EVENTS = 8,
        FAMILY_METRIC_CELL_POPULATION = 9,
        FAMILY_METRIC_CELL_LANDFORM = 10,
        FAMILY_METRIC_CELL_ESSENTIALS_SHORTAGE_Q16 = 11,
        FAMILY_METRIC_BRANCH_IS_LOCAL_PRESTIGE_MAX = 12,
        FAMILY_METRIC_CELL_RAIN_EVENT = 13,
        FAMILY_METRIC_CELL_RESOURCE_ABUNDANCE_Q16 = 14,
        FAMILY_METRIC_HAS_OWNED_MANUFACTURING = 15,
        FAMILY_METRIC_DISTINCT_SECTOR_COUNT = 16,
        FAMILY_METRIC_DOMINANT_SECTOR_ID = 17,
        FAMILY_METRIC_DOMINANT_SECTOR_SHARE_Q16 = 18,
        FAMILY_METRIC_COMPLETE_CHAIN_COUNT = 19,
        FAMILY_METRIC_MAX_LOCAL_CHAIN_SHARE_Q16 = 20,
        FAMILY_METRIC_MAX_CHAIN_UPGRADE_FAMILY_ID = 21,
        FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16 = 22,
        FAMILY_METRIC_CELL_RESOURCE_CLASS_COUNT = 23,
        FAMILY_METRIC_CELL_MANUFACTURING_BUILDING_COUNT = 24,
        FAMILY_METRIC_CELL_DISTINCT_SECTOR_COUNT = 25,
        FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID = 26,
        FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16 = 27,
        FAMILY_METRIC_CELL_COMPLETE_CHAIN_COUNT = 28,
        FAMILY_METRIC_CELL_HAS_EXTRACTIVE_RESOURCE = 29,
        FAMILY_METRIC_CELL_LEGAL_BUILDING_TYPE_COUNT = 30,
        FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT = 31,
        FAMILY_METRIC_FAMILY_BRANCH_COUNT = 32,
        FAMILY_METRIC_FAMILY_REMOTE_BRANCH_COUNT = 33,
        FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16 = 34,
        FAMILY_METRIC_CELL_KNOWLEDGE_BUILDING_CLASS_COUNT = 35,
        FAMILY_METRIC_CELL_CAN_PRODUCE_CORN = 36,
        // Output-share metrics. The pre-existing *_SECTOR_SHARE_Q16 rows above
        // count buildings, so they do not move when an output coefficient
        // changes -- gating "mine 60% -> boost industry" on them would never
        // close the loop. These are aggregated from group.last_output, which is
        // already net of output_factor_q16, so raising a sector coefficient
        // moves the share and the condition can feed back into itself.
        FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_AGRICULTURE_Q16 = 37,
        FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_EXTRACTIVE_Q16 = 38,
        FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_MANUFACTURING_Q16 = 39,
        FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_ENERGY_Q16 = 40,
        FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_KNOWLEDGE_Q16 = 41,
        FAMILY_METRIC_CELL_DOMINANT_SECTOR_OUTPUT_SHARE_Q16 = 42,
        // Resource side. Resources (building_resource_ids: iron, corn, ...) and
        // goods (building_outputs[].good_id) are two separate id spaces, so
        // both readings get a metric: "this cell is rich in iron" is a stock
        // question, "this cell mostly produces X" is an output question.
        FAMILY_METRIC_CELL_DOMINANT_RESOURCE_ID = 43,
        FAMILY_METRIC_CELL_DOMINANT_RESOURCE_STOCK_SHARE_Q16 = 44,
        FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID = 45,
        FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16 = 46,
        // Country scalars, read from CountryClassOpinionSnapshot rather than
        // live Economy stores: that snapshot is already frozen once per publish
        // pass and is the same source ideology point accrual reads, so a
        // condition can never observe a half-updated country.
        // research_speed / build_speed are deliberately absent -- the project
        // models neither, and inventing a metric that always reads 0 would make
        // a card silently inert.
        FAMILY_METRIC_COUNTRY_POPULATION_Q16 = 47,
        FAMILY_METRIC_COUNTRY_BUILDINGS_INSTALLED = 48,
        FAMILY_METRIC_COUNTRY_TRADE_BASE_VALUE_Q16 = 49,
        // Terrain is a *different id space* from landform (metric 10): landform
        // is the LF axis (plain / hills / delta / ...), terrain is the
        // TerrainType axis (grassland / floodplain / ...). The tag dictionary
        // mixes the two under one「地貌」heading, so「河谷」— a floodplain —
        // could not be expressed at all until this row existed. Count_q16, like
        // landform, because it is a category id compared for equality.
        FAMILY_METRIC_CELL_TERRAIN = 50,
        // ── X3: who works this cell ─────────────────────────────────────────
        // The cell's profession mix. `DOMINANT_*` answers "this is a hunters'
        // camp / a weavers' town"; the share is what makes that readable as a
        // threshold ("单一职业 ≥ 80%"), the id is for equality gating once
        // content knows the profession ids. `COUNT` is the diversity reading.
        //
        // Deliberately NOT one metric per profession: the id list is data-driven
        // (data/economy/professions/*.tres), and an enum that has to be edited
        // every time content adds a profession would rot.
        FAMILY_METRIC_CELL_DOMINANT_PROFESSION_ID = 51,
        FAMILY_METRIC_CELL_DOMINANT_PROFESSION_SHARE_Q16 = 52,
        FAMILY_METRIC_CELL_PROFESSION_COUNT = 53,
        // ── X2: the neighbourhood ───────────────────────────────────────────
        // Sum of the six neighbours' populations. The cheap half of X2: it needs
        // only the neighbour graph and the committed population column, so it
        // stays O(6) per sample instead of walking every neighbour's buildings.
        // "城郊" content reads this instead of inventing a radius.
        FAMILY_METRIC_CELL_NEIGHBOR_POPULATION_Q16 = 54,
        // ── X11: what the state takes ───────────────────────────────────────
        // Mean income-tax rate across professions, in basis points (10000 =
        // 100%). Frozen once per epoch with the rest of the tax shape, so a
        // condition cannot observe a half-applied tax change.
        FAMILY_METRIC_COUNTRY_INCOME_TAX_BURDEN_BP = 55,
        // ── X7: how much of the country looks a certain way ─────────────────
        // Counts of the country's OWN cells matching a tag from the compiled-in
        // list in economy_runtime_family_buff.cpp. This is the reading behind
        // "每有 1 个矿业支柱地块，再 +1%" style cards.
        //
        // Deliberately not a generic "count of tag N" metric: metrics take no
        // parameters, and one id per tag would mean an enum entry for all 270
        // tags. The list below is the subset content actually counts; adding a
        // tag means appending one slot AND one metric id together, which the
        // static table makes a single reviewable edit.
        FAMILY_METRIC_COUNTRY_AGRICULTURE_CELL_COUNT = 56,
        FAMILY_METRIC_COUNTRY_EXTRACTIVE_CELL_COUNT = 57,
        FAMILY_METRIC_COUNTRY_MANUFACTURING_CELL_COUNT = 58,
        FAMILY_METRIC_COUNTRY_CHAINED_CELL_COUNT = 59,
        FAMILY_METRIC_COUNTRY_SPECIALIZED_CELL_COUNT = 60,
        FAMILY_METRIC_COUNTRY_MARKET_CELL_COUNT = 61,
        // Settlement count is the one tag that needs no production at all (it is
        // a population threshold), so it is also the honest control for "did the
        // count run" in a fixture whose buildings never produce.
        FAMILY_METRIC_COUNTRY_SETTLEMENT_CELL_COUNT = 62,
        // Per-good counts. These are NOT a new mechanism: `cell.produces.<good>`
        // already marks exactly the cells whose dominant output is that good, so
        // one more slot in kCountryTagCountSlots is one more metric. Four goods
        // content actually counts today; adding another is a two-line change.
        FAMILY_METRIC_COUNTRY_SILVER_CELL_COUNT = 63,
        FAMILY_METRIC_COUNTRY_SALT_CELL_COUNT = 64,
        FAMILY_METRIC_COUNTRY_IRON_ORE_CELL_COUNT = 65,
        FAMILY_METRIC_COUNTRY_COAL_CELL_COUNT = 66,
        // Distinct goods for which this country owns at least one *specialized*
        // cell (top-output-good share >= 60%, the same threshold as the
        // `cell.specialized` tag). "特许航路" counts this, and it cannot be
        // derived from tag counts: two cells producing the same good must
        // collapse into one.
        FAMILY_METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT = 67,
        // Net tax burden of this cell's cohorts over the current epoch, Q16 ratio of
        // (tax paid - subsidy received) to gross cash + in-kind income. Clamped to
        // [0, Q16_ONE]; a cell with no income reports Q16_ONE (fully burdened) only
        // when it also paid tax, otherwise Q16_ONE is the "no signal" value the
        // generator's ramp expects for an empty cell. Uses the same
        // ACCOUNTING_EPOCH_BIT parity as `touch_accounting_slot`, so a cohort that has
        // not booked this epoch counts as 0 instead of leaking last epoch's numbers.
        FAMILY_METRIC_CELL_NET_TAX_BURDEN_Q16 = 68,
        // Country treasury cash as a percentage of one year of national population
        // income (1 point = 1%), clamped to [0, 1000]. Frozen per country per epoch.
        // v0 denominator is a 365-day extrapolation of the live `income_ema`; the true
        // rolling-year accumulator would add save state and is deferred (09 §8).
        FAMILY_METRIC_COUNTRY_TREASURY_RESERVE_RATIO_PCT = 69,
        // ── 19 §3.2 reservation: ids 70..86 ─────────────────────────────────
        // Pre-allocated in one commit so parallel lanes only FILL a slot and never
        // change the total (which would conflict on every merge). Until a lane
        // implements its slot the sampler leaves it at 0 and the GDScript key is a
        // `reserved.*` placeholder, so the generator cannot bind a card to it.
        // Owner docs: 70-74 X13 (16), 75-76 X12, 77-78 X14, 79-83 X10, 84-86 X9-a (17).
        FAMILY_METRIC_CELL_TEMPERATURE_ANNUAL_Q16 = 70,
        FAMILY_METRIC_CELL_DRY_STREAK_DAYS = 71,
        FAMILY_METRIC_CELL_HAZARD_TODAY_MASK = 72,
        FAMILY_METRIC_CELL_DAYS_SINCE_HAZARD = 73,
        FAMILY_METRIC_CELL_TEMPERATURE_ANOMALY_Q16 = 74,
        // X12: raw integer bitmask (river=1, coastal=2, canal=4, border=8).
        FAMILY_METRIC_CELL_GEO_FLAGS = 75,
        // X12: connected river/canal component size, encoded as count_q16.
        FAMILY_METRIC_CELL_WATERWAY_COMPONENT_SIZE = 76,
        // X14: committed class opinion. The catalog currently has four
        // political classes, which do not fit 77..78, so 77 is the most-used
        // class ("general") and 78 is the population-weighted country value.
        FAMILY_METRIC_COUNTRY_CLASS_SATISFACTION_Q16 = 77,
        FAMILY_METRIC_COUNTRY_WEIGHTED_SATISFACTION_Q16 = 78,
        FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT = 79,
        FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_0 = 80,
        FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_1 = 81,
        FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_2 = 82,
        FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_3 = 83,
        // X9-a: per-cell family aggregates. The branch table already holds the
        // authoritative rows; these are derived and never persisted.
        FAMILY_METRIC_CELL_FAMILY_BRANCH_COUNT = 84,
        FAMILY_METRIC_CELL_MAX_BRANCH_PRESTIGE_Q16 = 85,
        FAMILY_METRIC_CELL_FAMILY_ASSET_SHARE_Q16 = 86,
        // X8: distinct dominant output goods among the six neighbours. Derived
        // at the commit tail; no Economy column or save-schema field owns it.
        FAMILY_METRIC_CELL_NEIGHBOR_DISTINCT_GOODS = 87,
        // X13 residual used by mandate_of_heaven: share of this country's owned
        // cells whose days_since_hazard is at least 365, as a Q16 ratio.
        FAMILY_METRIC_COUNTRY_HAZARD_FREE_CELL_SHARE_Q16 = 88,
        // X14 extension: the committed `farmer` political-class satisfaction.
        // Unlike metric 77 (general) this row is what petition_box's point-gain
        // gate reads. Appended so existing ids remain stable.
        FAMILY_METRIC_COUNTRY_FARMER_SATISFACTION_Q16 = 89,
        // X9-b: country-level family aggregates rebuilt at FAMILY_COMMIT from
        // the live family/branch tables. Counts and ages are encoded with
        // count_q16 so the generator can use ordinary count ramps.
        FAMILY_METRIC_COUNTRY_FAMILY_REMOTE_BRANCH_COUNT = 90,
        FAMILY_METRIC_COUNTRY_FAMILIES_WITH_AT_LEAST_3_BRANCHES = 91,
        FAMILY_METRIC_COUNTRY_MAX_FAMILY_AGE_DAYS = 92,
        FAMILY_METRIC_COUNTRY_AVG_FAMILY_AGE_DAYS = 93,
        // X2 extension: number of the six neighbors that are agriculture
        // pillars (agriculture output share >= 50%, the same definition as the
        // `cell.sector.agriculture` tag). Terrace farming's L3 clause gates on
        // this without requiring a terrain-specific tag count.
        FAMILY_METRIC_CELL_NEIGHBOR_AGRICULTURE_COUNT = 94,
        // Still reserved by the original X3-b allocation.
        FAMILY_METRIC_RESERVED_95 = 95,
        // X3-b: population shares for the profession groups that the
        // cooperative/mechanized-farming/trade-union cards name. The share
        // denominator is the cell population assigned to known professions,
        // consistent with metrics 51..53. Employment is a separate X3 reading.
        FAMILY_METRIC_CELL_PROFESSION_SHARE_FARMER_Q16 = 96,
        FAMILY_METRIC_CELL_PROFESSION_SHARE_INDUSTRIAL_Q16 = 97,
        FAMILY_METRIC_CELL_PROFESSION_SHARE_COOPERATIVE_Q16 = 98,
        // X14 extension: the committed `worker` political-class satisfaction.
        // This is the class trade_unions gates on; metric 77 remains `general`.
        FAMILY_METRIC_COUNTRY_WORKER_CLASS_SATISFACTION_Q16 = 99,
        FAMILY_METRIC_RESERVED_100 = 100,
        FAMILY_METRIC_RESERVED_101 = 101,
        // X7-b: IDs 102-107 are reserved by the fixed cross-lane allocation.
        // Five metrics use five ids; 107 stays an explicit empty slot so this
        // lane keeps the 102-107 range without inventing a sixth mechanic.
        FAMILY_METRIC_COUNTRY_ENERGY_CELL_COUNT = 102,
        FAMILY_METRIC_COUNTRY_ABUNDANT_MOUNTAIN_FOREST_CELL_COUNT = 103,
        FAMILY_METRIC_COUNTRY_LANDFORM_SIGNAL_COUNT = 104,
        FAMILY_METRIC_COUNTRY_WEATHER_SIGNAL_COUNT = 105,
        FAMILY_METRIC_COUNTRY_BIO_SIGNAL_COUNT = 106,
        FAMILY_METRIC_RESERVED_107 = 107,
        // The selection set is a MetricMask (256 ids), so this count may grow
        // past 64 -- it just must not exceed MetricMask::CAPACITY, which the
        // static_assert below pins at compile time. Ids are the array index, so
        // new rows MUST be appended; reordering silently changes what every
        // existing card measures.
        FAMILY_METRIC_COUNT = 108,
    };

    static bool is_registered_economy_effect_opcode(int32_t opcode) {
        return (opcode >= COMMAND_TRANSFER_TO_COHORT &&
                opcode <= COMMAND_FAMILY_POPULATION_REWARD) ||
            (opcode >= COMMAND_START_FAMILY_EXPEDITION &&
             opcode <= COMMAND_SETTLE_FAMILY_EXPEDITION) ||
            opcode == COMMAND_FAMILY_ABSORB_ANONYMOUS ||
            opcode == COMMAND_FAMILY_PURCHASE_DISCOUNT ||
            opcode == COMMAND_FAMILY_SET_SPLIT_POLICY;
    }

    // EffectRuntime's Economy adapter uses this fixed POD ABI. Payload layout
    // is compiled at the catalog boundary: payload_i0's low/high words become
    // i32_0/i32_1, value_q16 becomes i64_0 and payload_i1 becomes i64_1.
    struct EffectCommand {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int32_t i32_0 = 0;
        int32_t i32_1 = 0;
        int64_t i64_0 = 0;
        int64_t i64_1 = 0;
        uint64_t idempotency_key = 0;
    };
    enum EffectCommandPreflightResult : int32_t {
        EFFECT_PREFLIGHT_ACCEPT = 0,
        EFFECT_PREFLIGHT_RETRY = 1,
        EFFECT_PREFLIGHT_REJECT = 2,
    };

    struct CountryClassOpinionSnapshot {
        uint64_t revision = 0;
        uint64_t class_hash = 0;
        // Hash of the country-level values derived for metrics 77/78. Revision
        // advances on every publish, but the copied metric content must reuse
        // when these values are unchanged.
        uint64_t class_metric_content_hash = 0;
        int64_t epoch_day = -1;
        int64_t commit_day = -1;
        // Development period this snapshot describes, and the period length in
        // days. `period_index = commit_day / period_days` is DERIVED, so both
        // authorities compute the same key for the same simulated day no matter
        // how often each of them publishes; ideology uses it as its accrual
        // idempotency key (A1).
        int64_t period_index = -1;
        int32_t country_count = 0;
        int32_t class_count = 0;
        std::vector<uint64_t> country_handles;
        std::vector<uint32_t> country_generations;
        std::vector<int64_t> population;
        std::vector<int64_t> funds;
        std::vector<int64_t> owner_employed;
        std::vector<int64_t> satisfaction_weighted;
        std::vector<int32_t> satisfaction_q16;
        // Per-country development lanes consumed by ideology point accrual.
        // They are collected in the same publish pass and frozen with the
        // class rows, so ideology never samples live Economy stores.
        std::vector<int64_t> country_population;
        std::vector<int64_t> country_buildings_installed;
        std::vector<int64_t> country_trade_base_value;
        int64_t period_days = 1;
    };

    // AI expedition commands carry this tag in `sequence` so execution-time
    // rejection receipts (kind 7) can be attributed back to the AI.
    static constexpr int64_t COUNTRY_AI_COLONIZATION_SEQUENCE_TAG = int64_t{1} << 62;
    struct CountryAiColonizationStat {
        uint64_t country_handle = 0;
        uint32_t failures = 0;
        uint32_t started = 0;
    };
};

// Free-function entry points for peers. Grouped by consumer; add new ones next
// to their consumer and keep each a one-line forward in economy_api.cpp.
namespace economy_api {

// Modifier: family/ideology entity-handle validation.
bool valid_family_effect_entity_handle(const NativeEconomyRuntime &economy,
                                       uint64_t handle);
bool valid_family_effect_target_handle(const NativeEconomyRuntime &economy,
                                       uint64_t handle);

// Effect: effect-command preflight/enqueue/result.
int32_t preflight_effect_commands_pod(const NativeEconomyRuntime &economy,
                                      const EconomyApi::EffectCommand *commands,
                                      size_t count, std::string &error);
bool submit_effect_commands_pod(NativeEconomyRuntime &economy,
                                const EconomyApi::EffectCommand *commands,
                                size_t count, std::vector<int64_t> &request_ids,
                                std::string &error);
bool effect_command_result_pod(const NativeEconomyRuntime &economy,
                               int64_t request_id, bool &complete, bool &ok,
                               std::string &reason);

// Ideology: committed opinion snapshots, effect-target selection, metric
// sampling and effect-input publication.
const EconomyApi::CountryClassOpinionSnapshot &country_class_opinion_snapshot(
    const NativeEconomyRuntime &economy);
int32_t cell_country_slot(const NativeEconomyRuntime &economy, int32_t cell);
int32_t family_target_min_branches_for_test(
    const NativeEconomyRuntime &economy, int32_t authored_min);
void collect_family_effect_target_handles(
    const NativeEconomyRuntime &economy, int32_t country_slot,
    int32_t min_branches, int32_t cap, std::vector<uint64_t> &out_handles);
int32_t country_anchor_cell(const NativeEconomyRuntime &economy,
                            int32_t country_slot);
int32_t target_tag_count(const NativeEconomyRuntime &economy);
void collect_own_tagged_cells(const NativeEconomyRuntime &economy,
                              int32_t country_slot, int32_t tag,
                              std::vector<int32_t> &out_cells);
int32_t cell_count(const NativeEconomyRuntime &economy);
int32_t building_neighbor(const NativeEconomyRuntime &economy, int32_t cell,
                          int32_t direction);
void collect_effect_target_cells(
    const NativeEconomyRuntime &economy, int32_t source_cell,
    int32_t selector_kind, int32_t param0, int32_t param1,
    std::vector<int32_t> &out_cells, uint64_t selection_salt = 0,
    EffectSelectorStats *stats = nullptr);
void dilate_cell_set(const NativeEconomyRuntime &economy,
                     const std::vector<int32_t> &sources, int32_t depth,
                     std::vector<int32_t> &out_cells);
void sample_effect_metrics(const NativeEconomyRuntime &economy, int32_t cell,
                           int32_t metric_count, int64_t *out_metrics,
                           const MetricMask &metric_mask = MetricMask::all());
void set_effect_input_consumers(
    NativeEconomyRuntime &economy, const MetricMask &cell_metrics,
    bool tags_needed, bool families_needed,
    const std::array<std::vector<int64_t>, EconomyApi::FAMILY_METRIC_COUNT>
        &metric_thresholds,
    const std::vector<int32_t> &tag_ids = {});
std::shared_ptr<const EffectInputSnapshot> effect_input_snapshot(
    const NativeEconomyRuntime &economy);
uint64_t effect_input_revision(const NativeEconomyRuntime &economy);

// Country: committed-day watermark and era-milestone notification.
uint64_t committed_generation(const NativeEconomyRuntime &economy);
void notify_era_milestone_activated(NativeEconomyRuntime &economy,
                                    uint64_t country_handle);

// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
void military_read_cell_view(const NativeEconomyRuntime &economy, EconomyMilitaryCellView &out, int32_t good_count = 0);
void military_read_market(const NativeEconomyRuntime &economy, int32_t good, std::vector<int32_t> &out_cells, std::vector<int64_t> &out_sellable, std::vector<int64_t> &out_price);
int32_t military_soldier_profession(NativeEconomyRuntime &economy);
int32_t military_unemployed_profession(const NativeEconomyRuntime &economy);
int32_t military_merchant_profession(const NativeEconomyRuntime &economy);
int64_t military_soldier_living_cost(const NativeEconomyRuntime &economy, int32_t country_slot);
uint64_t military_cohort_handle_any_ethnicity(const NativeEconomyRuntime &economy, int32_t cell, int32_t profession_id);
uint64_t military_cohort_handle_from_professions(const NativeEconomyRuntime &economy, int32_t cell, const int32_t *professions, int32_t count);
int64_t military_soldier_heads(const NativeEconomyRuntime &economy, int32_t cell);
int32_t military_cohort_signature(const NativeEconomyRuntime &economy, uint64_t handle);
int32_t military_cohort_ethnicity(const NativeEconomyRuntime &economy, uint64_t handle);
int32_t military_signature_for_cell_ethnicity(const NativeEconomyRuntime &economy, int32_t cell, int32_t profession);
int32_t military_signature_for(const NativeEconomyRuntime &economy, int32_t profession_id, int32_t ethnicity_id);
int64_t military_collect_cash(NativeEconomyRuntime &economy, int64_t country_handle, int64_t amount);
bool military_command_window_open(const NativeEconomyRuntime &economy);
int32_t set_military_ration_satisfaction(NativeEconomyRuntime &economy, const std::vector<int32_t> &cells, const std::vector<int32_t> &q16);
void set_military_army_ration(NativeEconomyRuntime &economy, uint64_t army_handle, int32_t ration_q16);
int64_t military_army_population(const NativeEconomyRuntime &economy, uint64_t army_handle);
int64_t military_army_funds(const NativeEconomyRuntime &economy, uint64_t army_handle);
bool military_army_lane_split_supported(const NativeEconomyRuntime &economy);
bool military_army_lane_pay_supported(const NativeEconomyRuntime &economy);
int32_t profession_count(const NativeEconomyRuntime &economy);
int64_t last_committed_day(const NativeEconomyRuntime &economy);
bool epoch_active(const NativeEconomyRuntime &economy);
godot::Dictionary detail_report(const NativeEconomyRuntime &economy);
bool capture_trade_topology(NativeEconomyRuntime &economy, const int32_t *neighbors,
    const uint8_t *terrain, const uint8_t *canal_mask, const float *canal_water,
    const uint8_t *passable, const int32_t *move_cost, int32_t count,
    uint64_t generation, std::string &error, const uint8_t *landform, const uint8_t *river);
bool capture_trade_visibility(NativeEconomyRuntime &economy, const uint8_t *visible,
    int32_t count, bool solved, bool from_map, std::string &error);
godot::Dictionary poll_events(const NativeEconomyRuntime &economy, const godot::Dictionary &opts);
godot::Dictionary trace_report(const NativeEconomyRuntime &economy);
bool set_cell_tag_override_for_test(NativeEconomyRuntime &economy, const std::string &tag_key, int32_t cell, bool on);
void clear_cell_tag_overrides_for_test(NativeEconomyRuntime &economy);

// ---- State building and procurement bindings (world_ext_economy.cpp, world_ext_military.cpp)
bool military_purchase_receipt(const NativeEconomyRuntime &economy, int64_t sequence, int64_t &quantity, int64_t &cash);
bool military_read_state_buildings(const NativeEconomyRuntime &economy, std::vector<int32_t> &out_cells, std::vector<int32_t> &out_type_ids, std::vector<int32_t> &out_state_roles, std::vector<int64_t> &out_units);
godot::Dictionary queue_treasury_sponsored_build(NativeEconomyRuntime &economy, int64_t country_handle, int32_t cell_idx, int32_t type_id, int64_t effective_day, int64_t sequence, bool queue_for_worker);
godot::Dictionary queue_treasury_sponsored_demolish(NativeEconomyRuntime &economy, int64_t country_handle, int32_t cell_idx, int32_t type_id, int64_t count, int64_t effective_day, int64_t sequence, bool queue_for_worker);
godot::Dictionary set_country_procurement_policy(NativeEconomyRuntime &economy, int64_t country_handle, bool enabled, int32_t treasury_share_bp, int32_t research_share_bp, int64_t effective_day, int64_t sequence, int32_t era_share_bp, int32_t colonization_share_bp);
bool trade_topology_ready_for_test(const NativeEconomyRuntime &economy);
bool trade_passable_for_test(const NativeEconomyRuntime &economy, int32_t cell);
bool epoch_active_for_test(const NativeEconomyRuntime &economy);

} // namespace economy_api

} // namespace pk

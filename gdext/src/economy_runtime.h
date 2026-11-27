#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <limits>
#include <memory>
#include <map>
#include <mutex>
#include <numeric>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "runtime_chunk_hash.h"
#include "runtime_economy_stratum_mobilization.h"
#include "runtime_published_view.h"
#include "runtime_switch_registry.h"
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include "economy_api.h"
#include "economy_graph_kernels.h"
#include "runtime_economy_state.h"
#include "economy_tracked_journal.h"
#include "economy_keyed_variable_records.h"
#include "economy_owned_record_value.h"
#include "runtime_economy_population_store.h"
// BEGIN army personnel lane (contract §1) — Economy side of the army personnel lane.
#include "runtime_economy_army_personnel.h"
// END army personnel lane
#include "runtime_pod_protocol.h"
#include "country_api.h"
#include "natural_resource_kernel.h"
#include "trade_visual_cache.h"
#include "annual_development_ledger.h"
#include "metric_mask.h"
#include "effect_selector_cap.h"
#include "target_tag.h"

namespace pk {

// Track B spread mode per-live-cell derived work cache entry.
struct TrackBDerivedCellWork {
    std::vector<int32_t> goods;
    std::vector<int64_t> quantities;
    // Leontief shadow value of the downstream output attributable to each
    // derived input edge. Parallel to goods/quantities; used only to lift the
    // price-adjustment anchor when no producer has published a cost anchor.
    std::vector<int64_t> anchors;
    int64_t edges = 0;
    uint64_t startup_calls = 0;
    uint64_t enqueued_goods = 0;
    bool seeded = false;
    void reset() {
        goods.clear();
        quantities.clear();
        anchors.clear();
        edges = 0;
        startup_calls = 0;
        enqueued_goods = 0;
        seeded = false;
    }
};

struct RuntimeEconomyEcp2State;
struct RuntimeGdpCell;

class EffectRuntime;
class EffectInstanceForwarder;

class NativeCountryRuntime;
class EconomyHostPort;
class EconomyCsvRecorder;
class ModifierRuntime;
class TriggerRuntime;
class NativeEconomyBuildingPlanExecutor;
class NativeEconomyGraphStageOps;
struct RuntimeEconomyPodCommand;

// Default D7 peer gate: fiscal-only (M1). open_all_d7_operation_gates() expands
// to all nine RuntimeEconomyAssetOperation bits for M2–M5 peer completion.
constexpr uint32_t RUNTIME_ECONOMY_D7_FISCAL_GATE_MASK =
    (1u << static_cast<uint32_t>(RuntimeEconomyAssetOperation::FISCAL_RESERVE)) |
    (1u << static_cast<uint32_t>(RuntimeEconomyAssetOperation::FISCAL_RETURN)) |
    (1u << static_cast<uint32_t>(RuntimeEconomyAssetOperation::FISCAL_COLLECT));
constexpr uint32_t RUNTIME_ECONOMY_D7_ALL_GATE_MASK =
    ((1u << (static_cast<uint32_t>(RuntimeEconomyAssetOperation::TREASURY_SPEND) +
             1u)) -
     2u);

// NativeEconomyRuntime is the sole mutable authority for population cohorts
// and markets. Godot containers are accepted/emitted only at coarse API
// boundaries; every graph stage operates on POD/std::vector storage.

// R-3: the per-epoch tag tables, published once and then READ ONLY.
//
// Both tables used to be plain `std::vector` members that the owning thread cleared
// and refilled at `capture_country_epoch`, while any thread could read them through
// `ensure_epoch_tag_bits()` / `ensure_country_tag_counts()`. Clearing a vector that
// another thread is iterating is a data race on the vector's buffer, not a stale
// read -- exactly the defect this type removes.
//
// Published like `_effect_input_snapshot`: build a new immutable copy, `atomic_store`
// it, and let every reader `atomic_load` ONCE into a local shared_ptr. The loaded
// pointer keeps the tables alive for the whole read even if a later epoch swaps a new
// one in, so no reader can observe a half-built table.
//
// Namespace scope, not nested: the class stores it, and other translation units
// read it, so a nested private type could not be named where it is consumed.
struct TagSnapshot {
    // `words` is cells/64: the bitset is [tag * tag_words + word].
    int32_t tag_words = 0;
    int32_t tag_count = 0;
    std::vector<uint64_t> tag_bits;
    // [country * kCountryTagCountSlotCount + slot]; slot order must match
    // kCountryTagCountSlots in economy_runtime_family_buff.cpp.
    int32_t country_count = 0;
    std::vector<int32_t> country_tag_counts;
    // X7b (metric 67): distinct specialized goods per country. Moved here from a
    // pair of `mutable` members that were built lazily from a const getter (R-3):
    // the same race, and worse, because it also sampled per-cell metrics while the
    // epoch columns could be moving.
    std::vector<int32_t> country_specialized_good_count;
    // Monotone, so a report can tell which epoch a reader saw.
    uint64_t generation = 0;
};

class NativeEconomyRuntime : public EconomyApi {
public:
    // A+Y N3/N4: live tables now live in runtime_economy_live_tables.h so
    // RuntimeEconomyOwnedState can own them; the historical nested names stay
    // as aliases.
    using FamilyStore = EconomyFamilyStore;
    using TradeOrderStore = EconomyTradeOrderStore;
    // A+Y N5: the notable-family side tables moved to
    // runtime_economy_family_side_tables.h for the same reason.
    using NotablePersonStore = EconomyNotablePersonStore;
    using PersonNeedState = EconomyPersonNeedState;
    using FamilyMembershipEdge = EconomyFamilyMembershipEdge;
    std::shared_ptr<const TagSnapshot> published_tag_snapshot() const { return tag_snapshot(); }
    using FamilyBuildingOwnership = EconomyFamilyBuildingOwnership;
    using FamilyTraitRoll = EconomyFamilyTraitRoll;
    using FamilyCellInfluenceStore = EconomyFamilyCellInfluenceStore;
    using FamilyExpeditionPayload = EconomyFamilyExpeditionPayload;
    using FamilyExpeditionCargoLine = EconomyFamilyExpeditionCargoLine;
    using FamilyExpeditionKitBuilding = EconomyFamilyExpeditionKitBuilding;
    using FamilyExpeditionStore = EconomyFamilyExpeditionStore;
    friend class NativeEconomyBuildingPlanExecutor;
    friend class NativeEconomyGraphStageOps;
    friend class EconomyAuthorityTransfer;
    friend class EconomyInvariantProbe;
    // Builds a synthetic per-cell snapshot (neighbour grid + terrain columns)
    // so the shared effect target selector can be exercised without a live
    // map_data, matching the economy_authority_fault_gate_self_test pattern.
    friend struct EconomyTargetSelectorTests;
    friend bool economy_dispatch_mutate_stage(EconomySoAView &view,
                                              RuntimeEconomyGraphStage stage,
                                              EconomyStageCursor &cursor,
                                              const RuntimeEconomyEpochInput &input,
                                              EconomyStageResult &result,
                                              std::string &error);
    // 28: persistent per-cell/per-ethnicity Q32 birth residuals.
    // 30: authoritative composite satisfaction dimensions, income baseline EMA,
    //     per-cohort fiscal burden accumulators, family branch satisfaction, and
    //     per-cell published social-pressure level.
    // 35: RECOVERY_PROBE is no longer a runtime state. The building catalog
    // and grouped construction contract changed with this version; older
    // economy saves are intentionally incompatible and are rejected.
    // 36: legacy cell carrying-capacity mix and support EMA (read and discarded
    //     when migrating to v45 real food-flow capacity).
    // 37: family-expedition cargo escrow and frozen colonization starter kits.
    // v36 in-flight expeditions restore with cargo_count = 0.
    // 38: locked market cadence N (1-5) and shared slow plan/investment S (5-30).
    // 39: plan P (5-15) and investment I (10-30) lock separately, with I > P.
    // v38 restores P from saved S (clamped to 15) and synthesizes I > P.
    // v37 restores as N=5 and P from saved plan days.
    // 41: family-effect bindings are catalog-owned native programs. Older
    // economy saves are intentionally incompatible.
    // 42: family expeditions may occupy a target in EXPEDITION_PREPARING
    // with empty payload/cargo until the colonization kit is complete.
    // v41 remains readable and must not contain PREPARING records.
    // 43: sector maintenance horizons and maintenance cost factor.
    // 44: resolved startup-demand mode. v43 restores with startup demand OFF.
    // 45: previous-period food-flow carrying-capacity snapshot.
    // 51: EXPEDITION_PREPARING parties escrow the cargo they have already
    // drawn from the source market, so payload/kit stay empty but cargo may
    // not. 52: fiscal records persist the Economy-owned per-Country escrow
    // used by the D7 fiscal peer. Older economy saves are rejected by the
    // same-version reader.
    // 53: optional D7 peer journal extension (session/domains/hashes) after
    // cadence; base fiscal-peer wire shape stays schema-52 compatible.
    // 54: PREPARING expeditions persist the fixed bridge/material demand used
    // by their stocking progress denominator.
    // 55: population-milestone family founding. The family policy header
    // carries the founder minimum and milestone-list hash, and section 35
    // stores milestone counts, open founding offers, queued choices, and
    // preselected founding effects.
    // 56: player-reviewed branch splits and persistent split lineage.
    // 57: X13a climate derived columns and persistent dry/hazard counters.
    // 58: the fiscal section also stores the non-tax research procurement cash
    //     outflow per country, so 国库支出 survives save/restore instead of
    //     reading zero for the batch it was paid in.
    // 59: the fiscal section also stores the non-tax construction cash outflow
    //     per country so treasury-sponsored state building charges survive.
    // 60: state buildings (building_kind = "state") are part of the building
    //     ledger; a v59 stream restores them as empty lanes and the military
    //     side folds its cumulative barracks/fort/college cache into the
    //     ledger on the first step (see military_core_save.cpp).
    // 61: military purchase receipts and the state building cash boundary.
    // 62: pending family colonization population rewards in family records.
    // 63: sparse (cell, profession) stratum mobilization rows (section 37).
    //     A v62 stream has no section and restores an empty table, which is the
    //     correct pre-feature state (no organization had accumulated yet).
    // 64: market signals also preserve current/previous producer sales. These
    // observations drive the next input purchase and owner opportunity quotes.
    // 65: colonization parties carry unaffiliated colonists (anonymous lanes)
    // next to the family headcount, so the party size is family + anonymous.
    static constexpr int32_t SCHEMA_VERSION = 65;
    // Dense order of the compiled `building_economic_sectors` column. It mirrors
    // `BUILDING_SECTOR_IDS` in economy_catalog.gd: agriculture, extractive,
    // manufacturing, energy, knowledge, then the appended `military` sector. The
    // order is a data contract, so append only, never reorder.
    static constexpr int32_t CIVIL_SECTOR_COUNT = 5;
    static constexpr int32_t MILITARY_SECTOR_ID = CIVIL_SECTOR_COUNT;
    static constexpr int32_t BUILDING_SECTOR_COUNT = CIVIL_SECTOR_COUNT + 1;
    static constexpr uint32_t BUILDING_KIT_ROLE_TRADE = 1u;
    static constexpr uint32_t BUILDING_KIT_ROLE_CONSTRUCTION = 2u;
    static constexpr uint32_t BUILDING_KIT_ROLE_CLOTHING_INPUT = 4u;
    static constexpr uint32_t BUILDING_KIT_ROLE_CLOTHING = 8u;
    static constexpr uint32_t BUILDING_KIT_ROLE_SURVIVAL_FOOD = 16u;
    static constexpr uint8_t EXPEDITION_CARGO_CONSTRUCTION = 0;
    static constexpr uint8_t EXPEDITION_CARGO_BUFFER = 1;
    static constexpr int32_t COLONIZATION_KIT_MIN_OWNER_SLOTS = 3;
    // A party is either a family branch (population = family people) or a plain
    // settler caravan (family_handle 0, population = 0, anonymous = people).
    // Both fly the same payload/kit/arrival path.
    static constexpr int32_t COLONIZATION_KIT_FOOD_COVERAGE_Q16 = 72090;
    static constexpr int32_t COLONIZATION_KIT_BRIDGE_EXTRA_DAYS = 15;
    // Bump when preparing-kit buffer demand changes so in-flight PREPARING
    // parties replan even if source stock of the previous missing goods is
    // unchanged. Revision 2: clothing uses need.base_qty_per_person, not 1.0
    // goods per person-day. Revision 3: every candidate in an underfilled
    // substitute group participates in the PREPARING stock watch. Revision 4:
    // staple, protein, and produce candidates share one aggregate food pool.
    // Revision 5: preparing parties escrow spare stock day by day, so the
    // watch identity covers the reserve as well as the remaining shortfall.
    // Revision 6: unavailable soft tool inputs do not block departure.
    static constexpr uint64_t COLONIZATION_PREPARING_STOCK_HASH_REVISION = 6;
    static constexpr int32_t ROLLING_PHASE_COUNT = 5;
    static constexpr int32_t MARKET_CYCLE_MIN_DAYS = 1;
    static constexpr int32_t MARKET_CYCLE_MAX_DAYS = 5;
    static constexpr int32_t SLOW_CYCLE_MIN_DAYS = 5;
    static constexpr int32_t SLOW_CYCLE_MAX_DAYS = 30;
    static constexpr int32_t PLAN_CYCLE_MIN_DAYS = 5;
    static constexpr int32_t PLAN_CYCLE_MAX_DAYS = 15;
    static constexpr int32_t INVEST_CYCLE_MIN_DAYS = 10;
    static constexpr int32_t INVEST_CYCLE_MAX_DAYS = 30;
    static constexpr int32_t CARRYING_FAMILY_COUNT = 21;
    static constexpr int32_t CARRYING_NEED_FAMILY_COUNT = 17;
    static constexpr int32_t CARRYING_SUPPORT_RESOURCE_COUNT = 7;
    static constexpr int32_t CARRYING_LANDFORM_COUNT = 16;
    static constexpr int32_t CARRYING_VEGETATION_COUNT = 28;
    // 不能叫 PAGE_SIZE：那是 POSIX 保留的宏名，emscripten 的 musl
    // <bits/limits.h> 无条件 `#define PAGE_SIZE 65536`，会把这行成员声明展开成
    // `static constexpr int32_t 65536 = 64;`。
    static constexpr int32_t COHORT_PAGE_SIZE = 64;
    static constexpr int64_t MONEY_SCALE = 10000;
    static constexpr int64_t GOODS_SCALE = 1000;
    static constexpr int64_t Q16_ONE = 65536;
    // Seven presentation bands over the cohort composite satisfaction.
    static constexpr int64_t LIVING_STANDARD_THRESHOLDS_Q16[6] = {
        Q16_ONE * 12 / 100, Q16_ONE * 22 / 100, Q16_ONE * 33 / 100,
        Q16_ONE * 45 / 100, Q16_ONE * 58 / 100, Q16_ONE * 72 / 100,
    };
    static constexpr uint8_t BUILDING_VISUAL_UNKNOWN = 255;
    static constexpr int64_t PRODUCER_SUPPORT_PRICE_NUMERATOR = 1;
    static constexpr int64_t PRODUCER_SUPPORT_PRICE_DENOMINATOR = 5;
    static constexpr int32_t PRICE_NUMERIC_GUARD_MIN = 1;
    static constexpr int32_t PRICE_NUMERIC_GUARD_MAX =
        std::numeric_limits<int32_t>::max();
    static constexpr int64_t MERCHANT_INVENTORY_HIGH_WATER_Q16 =
        Q16_ONE + Q16_ONE / 5;
    static constexpr int64_t Q32_ONE = 4294967296LL;
    static constexpr int32_t MAX_RULES_PER_PLAN = 32;
    static constexpr int32_t MAX_NEEDS_PER_PLAN = 20;
    static constexpr int32_t MAX_VARIANTS_PER_NEED = 8;
    static constexpr int32_t MAX_COMPONENTS_PER_VARIANT = 4;
    static constexpr int32_t ENV_CURVE_SAMPLES = 17;
    static constexpr int32_t PUBLISH_ENTRIES_PER_SLICE = 4096;
    static constexpr int32_t PUBLISH_AUDIT_ENTRIES_PER_SLICE = 131072;
    // Commit mutates the authoritative cell table and therefore cannot be
    // worker-parallelized. Keep its deterministic range small enough that a
    // single publish slice remains below the 2 ms non-preemptible target.
    static constexpr int32_t PUBLISH_COMMIT_ENTRIES_PER_SLICE = 256;
    static constexpr int32_t BUILDING_REVIEW_GROUPS_PER_SLICE = 4096;
    static constexpr int32_t AUTO_BUILDING_CELLS_PER_SLICE = 256;
    static constexpr int32_t AUTO_INVESTMENT_CELLS_PER_SLICE = 96;
    static constexpr int32_t AUTO_BUILDING_FINALIZE_CELLS_PER_SLICE = 128;
    // Cooperative planner budget. Route searches retain their heap/cursors
    // across native slices, so this is a deterministic work cap rather than a
    // wall-clock deadline.
    static constexpr int32_t TRADE_ROUTE_EXPANSIONS_PER_SLICE = 256;

    // Composite satisfaction dimensions. The first SAT_TIER_COUNT entries are
    // need tiers fed by the household market clearing; the rest are derived from
    // cohort ledgers and frozen epoch context. Extending the model means
    // appending an enumerator before SAT_DIM_COUNT and widening the authored
    // weight columns; no storage layout outside this stride changes.
    enum SatisfactionDimension : int32_t {
        SAT_DIM_SUBSISTENCE = 0,
        SAT_DIM_BASIC = 1,
        SAT_DIM_COMFORT = 2,
        SAT_DIM_LUXURY = 3,
        SAT_DIM_INCOME = 4,
        SAT_DIM_SAVINGS = 5,
        SAT_DIM_TAX = 6,
        SAT_DIM_DEVELOPMENT = 7,
        SAT_DIM_COUNT = 8,
    };
    static constexpr int32_t SAT_TIER_COUNT = 4;
    static constexpr int32_t SAT_DEVELOPMENT_INPUT_COUNT = 3;
    static constexpr int32_t SAT_PRESSURE_LEVEL_COUNT = 5;

    static constexpr uint16_t FAMILY_FLAG_SPLIT_RETAIN_ONLY = 1u;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_BONUS_WEIGHT = 2u;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_REPLACE = 4u;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_GIFT_BUILDING = 8u;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_GIFT_POPULATION = 16u;
    // Only the formal starter bootstrap may create a household below the
    // ordinary notable-family minimum. Child branches are ordinary families.
    static constexpr uint16_t FAMILY_FLAG_STARTER = 32u;
    // Lifecycle floor for an existing non-starter family. New families use
    // the profile-driven _family_min_founder_people instead.
    static constexpr int64_t FAMILY_MIN_ACTIVE_PEOPLE = 20;
    // Branch demography (docs/cpp-dots-runtime/family-demography-ledger-design.md).
    // Shares are of the cell population with the family's origin ethnicity.
    static constexpr int32_t FAMILY_TARGET_SHARE_MIN_Q16 = 13107;   // 20%
    static constexpr int32_t FAMILY_TARGET_SHARE_MAX_Q16 = 45875;   // 70%
    static constexpr int32_t FAMILY_TARGET_SHARE_TOTAL_Q16 = 45875; // 70%
    static constexpr int32_t FAMILY_TARGET_SHARE_EPSILON_Q16 = 655; // 1%
    static constexpr int32_t FAMILY_HEALTH_BUILDING_WEIGHT_Q16 = 98304; // 1.5
    static constexpr int32_t FAMILY_HEALTH_WEALTH_WEIGHT_Q16 = 65536;   // 1.0
    static constexpr int32_t FAMILY_HEALTH_EMPLOYMENT_WEIGHT_Q16 = 32768; // 0.5
    static constexpr int32_t FAMILY_HEALTH_BUILDING_REF_Q16 = 16384;    // 25%
    // Per-capita claim below this fraction of the local per-capita funds is
    // cash distress; it reaches 1 at zero claim.
    static constexpr int32_t FAMILY_CASH_DISTRESS_RATIO_Q16 = 16384;    // 25%
    static constexpr int32_t FAMILY_CASH_DISTRESS_WEIGHT_Q16 = 32768;   // 0.5
    static constexpr int32_t FAMILY_BIRTH_SLOPE_Q16 = 65536;            // k_b
    static constexpr int32_t FAMILY_DEATH_SLOPE_Q16 = 32768;            // k_d
    static constexpr int32_t FAMILY_BIRTH_DISTRESS_SLOPE_Q16 = 32768;   // mu
    static constexpr int32_t FAMILY_DEATH_DISTRESS_SLOPE_Q16 = 65536;   // lambda
    static constexpr int32_t FAMILY_WEIGHT_MIN_Q16 = 16384;             // 0.25
    static constexpr int32_t FAMILY_WEIGHT_MAX_Q16 = 196608;            // 3.0
    static constexpr int32_t FAMILY_RECRUIT_RATE_Q16 = 1311;            // 2% of gap per review
    // A SET absorb bonus of 1.0 raises the target share by this much.
    static constexpr int32_t FAMILY_ABSORB_TARGET_BONUS_Q16 = 3277;     // 5%
    // Career-move tilt toward the preferred family's members.
    static constexpr int32_t FAMILY_PREFERRED_MOVE_WEIGHT_Q16 = 131072; // 2.0
    // An unstaffed holding releases at most ceil(owned / divisor) units per review.
    static constexpr int64_t FAMILY_RELEASE_STEP_DIVISOR = 4;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_MODE_MASK =
        FAMILY_FLAG_SPLIT_RETAIN_ONLY | FAMILY_FLAG_SPLIT_BONUS_WEIGHT |
        FAMILY_FLAG_SPLIT_REPLACE;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_POLICY_MASK =
        FAMILY_FLAG_SPLIT_MODE_MASK | FAMILY_FLAG_SPLIT_GIFT_BUILDING |
        FAMILY_FLAG_SPLIT_GIFT_POPULATION;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_WEIGHT_SHIFT = 8u;

    enum FamilyBehaviorScoreTerm : int32_t {
        FAMILY_SCORE_CANDIDATE_WEIGHT = 0,
        FAMILY_SCORE_TAX_SENSITIVITY = 1,
        FAMILY_SCORE_LOCAL_RESOURCE_ABUNDANCE = 2,
        FAMILY_SCORE_UPGRADE_TIER = 3,
        FAMILY_SCORE_LOCAL_POPULARITY = 4,
        FAMILY_SCORE_CAREER_MOBILITY = 5,
    };

    static_assert(FAMILY_METRIC_COUNT <= MetricMask::CAPACITY,
        "FAMILY_METRIC_COUNT exceeds MetricMask::CAPACITY; widen the mask "
        "before appending metric ids");
    // `EffectInputSnapshot::metric_revision` is indexed by metric id and is written as
    // `++next->metric_revision[slot]`, so its length must BE the metric count. A short
    // array is a heap overwrite, not a truncation, and it took ~65 `0xc0000374` crashes
    // to notice. Pinning the two constants together here makes appending a metric
    // without widening the array a compile error.
    static_assert(FAMILY_METRIC_COUNT == PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY,
        "FAMILY_METRIC_COUNT and PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY must match: "
        "EffectInputSnapshot::metric_revision is indexed by metric id");

    enum FamilyBehaviorDirtyReason : uint32_t {
        FAMILY_BEHAVIOR_DIRTY_INITIAL = 1u << 0u,
        FAMILY_BEHAVIOR_DIRTY_TRAITS = 1u << 1u,
        FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS = 1u << 2u,
        FAMILY_BEHAVIOR_DIRTY_INFLUENCES = 1u << 3u,
        FAMILY_BEHAVIOR_DIRTY_CONDITION_METRICS = 1u << 4u,
        FAMILY_BEHAVIOR_DIRTY_HOME_CELL = 1u << 5u,
    };
    // Internal compact selector. Authored selectors stay exact dense IDs;
    // this row matches every profession in one precompiled class.
    static constexpr int32_t FAMILY_BEHAVIOR_SELECTOR_PROFESSION_CLASS = 100;

    static bool is_family_ledger_command(int32_t opcode) {
        return opcode == COMMAND_FAMILY_FREE_BUILDING ||
            opcode == COMMAND_FAMILY_POPULATION_REWARD ||
            opcode == COMMAND_FAMILY_ABSORB_ANONYMOUS ||
            opcode == COMMAND_FAMILY_PURCHASE_DISCOUNT;
    }


    enum ConstructionOwnershipPolicy : int32_t {
        OWNERSHIP_TREASURY_SPONSORED_PRIVATE = 1,
        OWNERSHIP_TREASURY_MILITARY_ORDER = 2,
    };

    NativeEconomyRuntime();
    ~NativeEconomyRuntime();
    void attach_country_runtime(NativeCountryRuntime *runtime) { _country_runtime = runtime; }
    void attach_simulation_host(EconomyHostPort *host) { _simulation_host = host; }
    AnnualEconomyFacts capture_annual_facts(uint64_t country_handle, bool flows) const;
    std::vector<RuntimeGdpCell> capture_settlement_output(uint64_t country_handle) const;
    void publish_annual_development_facts();
    bool annual_observes_cell(int32_t cell) const;
    void record_annual_event(int32_t cell, AnnualMetric metric, int64_t value);
    void record_annual_production(int32_t cell);
#include "economy_runtime_internal_configuration_api.h"
    // Pure, transaction-scoped validation used by EffectRuntime before it
    // flattens accepted transactions into one native enqueue batch. This does
    // not reserve request IDs or mutate Economy state.
    int32_t preflight_effect_commands_pod(const EffectCommand *commands,
                                          size_t count,
                                          std::string &error) const;
    bool submit_effect_commands_pod(const EffectCommand *commands, size_t count,
                                    std::vector<int64_t> &request_ids,
                                    std::string &error);
    // Apply due effect-tagged pending commands while no epoch is open so
    // Effect ACK cannot pin WorldClock waiting for the next begin_epoch.
    void drain_due_effect_pending_commands();
    bool effect_command_result_pod(int64_t request_id, bool &complete,
                                   bool &ok, std::string &reason) const;
    bool has_pending_effect_commands() const;
#include "economy_runtime_internal_day_api.h"
#include "economy_runtime_internal_world_inputs_api.h"
#include "economy_runtime_internal_settlement_api.h"
    const CountryClassOpinionSnapshot &country_class_opinion_snapshot() const {
        return _class_opinion_buffers[
            static_cast<size_t>(_class_opinion_committed_buffer)];
    }
    // Family reads the completed buffer; publication writes the other buffer.
    auto copy_lineage_opinion_view() const {
        const auto &source = country_class_opinion_snapshot();
        using Rows = std::decay_t<decltype(source)>;
        return RuntimePublishedView<Rows>{source.revision, source.commit_day,
            true, std::make_shared<const Rows>(source)};
    }
    // Test-only publication view. The X14 override already drives the derived
    // country metrics, but the Ideology worker consumes the raw row snapshot.
    // Returning a copy keeps the committed buffer immutable while exposing the
    // overridden rows and the country totals derived from them.
    bool class_opinion_source_override_enabled_for_test() const;
    CountryClassOpinionSnapshot country_class_opinion_source_snapshot() const;
    godot::Dictionary country_class_opinion_snapshot_debug() const;

    // Country AI boundary (see docs/cpp-dots-runtime/country-ai-runtime.md).
    // All three are thread-safe: the digest is an immutable snapshot swapped
    // at Economy commit, preferences are frozen inputs read by FAMILY_COMMIT,
    // and colonization intents are converted into ordinary expedition
    // commands at the next epoch open.
    std::shared_ptr<const CountryAiEconomyDigest> country_ai_digest() const;
    void restore_country_ai_digest(std::shared_ptr<const CountryAiEconomyDigest> digest);
    void set_country_ai_family_preferences(std::vector<struct CountryAiFamilyPreferenceRow> rows);
    void queue_country_ai_colonization(std::vector<struct CountryAiColonizationIntent> intents);
    // AI research shares become ordinary procurement policies (whole treasury
    // as the national envelope, legacy era/colonization split).
    void queue_research_procurement_policy(uint64_t country_handle,
                                           int32_t research_share_bp,
                                           int64_t effective_day, int64_t sequence);
    void export_country_ai_pending(
        std::vector<CountryAiColonizationIntent> &intents,
        std::vector<CountryAiColonizationStat> &stats,
        int64_t &receipt_cursor) const;
    void import_country_ai_pending(
        std::vector<CountryAiColonizationIntent> intents,
        std::vector<CountryAiColonizationStat> stats,
        int64_t receipt_cursor);

#include "economy_runtime_internal_read_views.h"
    TradeVisualCache trade_visual_cache;

#include "economy_runtime_internal_planning_types.h"
#include "economy_runtime_internal_market_types.h"
#include "economy_runtime_internal_settlement_types.h"
#include "economy_runtime_internal_state_members.h"
#include "economy_runtime_internal_operations.h"
public:
    // Declared here (not with the other family-effect helpers, which are
    // private) because NativeIdeologyRuntime resolves cell-scoped ideology
    // effects through the same selector.
    //
    // Generalised target-cell resolver shared by family and ideology effects.
    // `param0` is always the cell cap (0 = EffectRuntime::SELECTOR_DEFAULT_CELLS,
    // hard-clamped to SELECTOR_MAX_CELLS). `param1` is the kind-specific
    // argument: predicate id for SELECTOR_PREDICATE_ANY_CELL, hop count for
    // SELECTOR_DISTANCE_N, 1-based tag id for SELECTOR_OWN_TERRITORY and
    // SELECTOR_TAG_ANY_CELL, unused for the component kinds (they follow the
    // anchor's terrain / dominant resource). Output is always sorted,
    // deduplicated and capped, so two identical calls produce the same vector --
    // which is what makes "one instance per cell" replayable.
    // P3 step 3: the per-cell coefficient table published by the Ideology side.
    // Copied, because the table is an immutable snapshot by contract -- the
    // publisher builds a new one instead of mutating this.
    // Public seam over city_good_output_factor_q16(), which lives in a private
    // section. Diagnostics and tests need to read the composed factor; the
    // production hot path keeps using the private one directly.
    int32_t city_output_factor_for_test(int32_t cell, int32_t good_id) const;
#include "economy_runtime_internal_service_and_targets_api.h"
#include "economy_runtime_internal_profession_diagnostics.h"
    // ── Effect input revision (P1-A) ────────────────────────────────────────
    // Read by NativeIdeologyRuntime to decide whether anything has to be
    // re-evaluated at all. Acquire/release because the economy may publish from
    // its own thread while the ideology facade reads on the main thread.
    uint64_t effect_input_revision() const {
        return _effect_input_revision.load(std::memory_order_acquire);
    }
    // Per-metric revision (review §3). A card mixes only the metrics it reads,
    // so one metric moving no longer re-signs every economy-input card.
    uint64_t effect_metric_revision(int32_t metric) const {
        if (metric < 0 || metric >= static_cast<int32_t>(FAMILY_METRIC_COUNT))
            return 0;
        const auto snapshot = effect_input_snapshot();
        return snapshot == nullptr
            ? 0
            : snapshot->metric_revision[static_cast<size_t>(metric)];
    }
    std::shared_ptr<const EffectInputSnapshot> effect_input_snapshot() const {
        return std::atomic_load_explicit(&_effect_input_snapshot,
            std::memory_order_acquire);
    }
    // The other two thirds of the split: ownership and tag bits move on their
    // own schedules, so a card that only reads one of them does not re-sign when
    // the others move (review §3).
    uint64_t effect_territory_revision() const {
        const auto snapshot = effect_input_snapshot();
        return snapshot == nullptr ? 0 : snapshot->territory_revision;
    }
    uint64_t effect_tag_revision() const {
        const auto snapshot = effect_input_snapshot();
        return snapshot == nullptr ? 0 : snapshot->tag_revision;
    }
    uint64_t effect_family_revision() const {
        const auto snapshot = effect_input_snapshot();
        return snapshot == nullptr ? 0 : snapshot->family_revision;
    }
    // Called from configure_ideologies() with the catalog's declared consumer
    // set. Clears the published digest so the next COMMIT definitely advances
    // the revision instead of matching the empty-catalog digest.
    // `has_value == false` clears the override.
    void set_effect_metric_override(int32_t metric, int64_t value, bool has_value);
    // Test-only: force one (tag, cell) pair true or false while effect metrics
    // are sampled. The snapshot builder applies these bits after predicate
    // evaluation, so the tag bitset and its digest see the same input.
    bool set_cell_tag_override_for_test(const std::string &tag_key,
                                        int32_t cell, bool on);
    void clear_cell_tag_overrides_for_test();
    // Test-only: freezes the committed class-opinion source rows for X14's
    // unchanged-day proof. Subsequent publishes still advance their revision.
    void set_class_opinion_source_override_for_test(
        const std::vector<int64_t> &population,
        const std::vector<int32_t> &satisfaction_q16,
        const std::vector<int64_t> &satisfaction_weighted);
    void clear_class_opinion_source_override_for_test();
    void set_effect_input_consumers(
        const MetricMask &cell_metrics, bool tags_needed, bool families_needed,
        const std::array<std::vector<int64_t>, FAMILY_METRIC_COUNT>
            &metric_thresholds,
        const std::vector<int32_t> &tag_ids = {});
    // Called once per committed economy day. Recomputes the digest and advances
    // `effect_input_revision()` only when it differs from the last published
    // one. A no-op when no managed card reads economy input.
    void refresh_effect_input_digest();
    void refresh_neighbor_distinct_goods_metrics();

#include "economy_runtime_internal_military_api.h"
private:
#include "economy_runtime_internal_military_and_lineage.h"
#include "economy_runtime_internal_audit_and_formulas.h"
    // ECP2 mid-epoch export bypasses the committed-boundary gate in begin_save.
    mutable bool _ecp2_allow_mid_epoch_export = false;
    // While the worker-start path installs a save, Economy is applied BEFORE Country
    // (`native_simulation_host.cpp`), so the archive's country generation/hash cannot
    // match the still-bootstrapping live runtime. Set only inside that window; every
    // other apply compares them strictly (see `economy_runtime_persistence_read.cpp`).
    bool _accept_stale_country_identity = false;
    // The country identity the ARCHIVE asked for, recorded when the comparison was
    // deferred. The Host verifies these against the real Country runtime once the PKCN
    // checkpoint is installed (`verify_deferred_country_identity`), so deferring the
    // check moves it rather than dropping it -- otherwise an archive whose Country
    // bytes and Economy bytes come from different saves would load silently.
    uint64_t _deferred_country_generation = 0;
    uint64_t _deferred_country_state_hash = 0;
    bool _deferred_country_identity_recorded = false;

#include "economy_runtime_internal_continuation_api.h"
};

#include "economy_runtime_internal_arithmetic.h"

} // namespace pk


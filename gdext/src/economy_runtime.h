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
#include "runtime_published_view.h"
#include "runtime_switch_registry.h"
#include <godot_cpp/variant/dictionary.hpp>
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
#include "country_read_view.h"
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
    int64_t edges = 0;
    uint64_t startup_calls = 0;
    uint64_t enqueued_goods = 0;
    bool seeded = false;
    void reset() {
        goods.clear();
        quantities.clear();
        edges = 0;
        startup_calls = 0;
        enqueued_goods = 0;
        seeded = false;
    }
};

struct RuntimeEconomyEcp2State;

class EffectRuntime;
class EffectInstanceForwarder;

class NativeCountryRuntime;
class NativeSimulationHost;
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
    static constexpr int32_t SCHEMA_VERSION = 59;
    static constexpr uint32_t BUILDING_KIT_ROLE_TRADE = 1u;
    static constexpr uint32_t BUILDING_KIT_ROLE_CONSTRUCTION = 2u;
    static constexpr uint32_t BUILDING_KIT_ROLE_CLOTHING_INPUT = 4u;
    static constexpr uint32_t BUILDING_KIT_ROLE_CLOTHING = 8u;
    static constexpr uint32_t BUILDING_KIT_ROLE_SURVIVAL_FOOD = 16u;
    static constexpr uint8_t EXPEDITION_CARGO_CONSTRUCTION = 0;
    static constexpr uint8_t EXPEDITION_CARGO_BUFFER = 1;
    static constexpr int32_t COLONIZATION_KIT_MIN_OWNER_SLOTS = 3;
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
    };

    NativeEconomyRuntime();
    ~NativeEconomyRuntime();
    void attach_country_runtime(NativeCountryRuntime *runtime) { _country_runtime = runtime; }
    void attach_simulation_host(NativeSimulationHost *host) { _simulation_host = host; }
    AnnualEconomyFacts capture_annual_facts(uint64_t country_handle, bool flows) const;
    void publish_annual_development_facts();
    bool annual_observes_cell(int32_t cell) const;
    void record_annual_event(int32_t cell, AnnualMetric metric, int64_t value);
    void record_annual_production(int32_t cell);
    uint64_t asset_peer_request_high_watermark() const noexcept;
    void attach_csv_recorder(EconomyCsvRecorder *recorder) { _csv_recorder = recorder; }
    void set_sync_writes_forbidden(bool forbidden) {
        _sync_writes_forbidden = forbidden;
    }
    bool sync_writes_forbidden() const { return _sync_writes_forbidden; }
    void set_d7_operation_gate_mask(uint32_t mask) {
        _d7_operation_gate_mask = mask;
    }
    uint32_t d7_operation_gate_mask() const { return _d7_operation_gate_mask; }
    // Opens all nine Country/Economy asset ops for peer completion. Non-fiscal
    // COUNTRY_PREPARED requests journal COMPLETED with prepared amounts; M2–M5
    // cohort/market ops also apply local SoA via apply_peer_asset_side_effects
    // (Country has already transferred treasury value on its commit path).
    void open_all_d7_operation_gates() {
        _d7_operation_gate_mask = RUNTIME_ECONOMY_D7_ALL_GATE_MASK;
    }
    // Country unique-writer still needs treasury technology-point purchase even
    // when Economy remains sync (fiscal-only default mask). Research is the
    // minimum non-fiscal op required for government procurement to resume.
    void open_research_purchase_d7_gate() {
        _d7_operation_gate_mask |=
            (1u << static_cast<uint32_t>(
                RuntimeEconomyAssetOperation::RESEARCH_PURCHASE));
    }
    // Country ACTIVE + Economy sync still needs the two legs used by local
    // expedition procurement: market -> Country treasury, then treasury ->
    // expedition cargo.  They are peer-routed through the Country worker;
    // leaving either gate closed parks PREPARING at 0% without a fatal.
    void open_country_market_purchase_d7_gates() {
        _d7_operation_gate_mask |=
            (1u << static_cast<uint32_t>(
                RuntimeEconomyAssetOperation::GOOD_FROM_MARKET)) |
            (1u << static_cast<uint32_t>(
                RuntimeEconomyAssetOperation::TREASURY_SPEND));
    }
    bool bind_soa_view(EconomySoAView &view, std::string &error);
    // Phase-5 A+Y: formula hot path mutates OwnedState population/market in
    // place. While bound, population_store()/market_store() alias OwnedState.
    bool bind_formula_owned_state(RuntimeEconomyOwnedState &owned,
                                  std::string &error);
    void unbind_formula_owned_state() noexcept;
    bool formula_owned_bound() const noexcept {
        return _formula_owned != nullptr;
    }
    RuntimeEconomyBuildingStore &buildings_store() noexcept {
        return _formula_owned != nullptr ? _formula_owned->buildings
                                         : _buildings_soa_local;
    }
    const RuntimeEconomyBuildingStore &buildings_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->buildings
                                         : _buildings_soa_local;
    }
    // Same lane as buildings_store(), reachable from const members. Only the
    // role/pending projections are refreshed through it; group columns stay
    // read-only for const callers.
    RuntimeEconomyBuildingStore &mutable_buildings_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->buildings
                                         : _buildings_soa_local;
    }
    const char *formula_backing_tag() const noexcept {
        return _formula_owned != nullptr ? "owned_state" : "ner_local";
    }
    std::unique_ptr<EconomyGraphStageOps> make_graph_stage_ops(bool mutate);
    // POD command path: maps RuntimeEconomyPodCommand → apply_command.
    // Sync submit_commands remains the facade; do not double-submit the same
    // request through both POD commit and sync enqueue.
    bool apply_pod_command(const RuntimeEconomyPodCommand &pod,
                           std::string &error);
    bool enqueue_or_apply_pod_command(const RuntimeEconomyPodCommand &pod,
                                      std::string &error);
    // Phase-2.6.3: copy OwnedState columns into production NER after a
    // POD-first command, coordinate country peers, and recapture mirrors.
    bool pull_owned_command_result(RuntimeEconomyOwnedState &owned,
                                   const RuntimeEconomyPodCommand &command,
                                   int64_t settled, std::string &error);
    // Legacy narrow pull for mint/burn/stock tests.
    bool pull_owned_core_columns(const RuntimeEconomyOwnedState &owned,
                                 int32_t opcode, int64_t settled,
                                 std::string &error);
    void fill_economy_audit_snapshot(int64_t &pop_err, int64_t &money_err,
                                     int64_t &goods_err,
                                     uint32_t &dirty_family_mask,
                                     int64_t &changed_cells,
                                     int64_t &changed_cohorts) const;
    void fill_economy_business_summary(int64_t &summary_population,
                                       int64_t &summary_funds,
                                       int32_t &summary_markets,
                                       int32_t &summary_buildings,
                                       int32_t &summary_cohorts,
                                       int32_t &summary_families) const;
    // Copies only committed ledger columns. This is a cold publish-boundary
    // handoff for POD parity; it is never used while an epoch is mutable.
    // `compute_ledger_hash=false` leaves ledger_hash 0; every reader of such a
    // ledger must hash on demand.
    void capture_committed_ledger_state(RuntimeEconomyLedgerState &out,
                                       uint64_t completed_stage_hash = 0,
                                       bool compute_ledger_hash = true) const;
    // Phase-4 layout unification: AoS→OwnedState SoA mirrors (capture path).
    void flush_formula_owned_domain_mirrors();
    // A+Y N2: refreshes the role/pending projections on the sole live group
    // lane, then copies it out when `out` is a different store.
    void sync_owned_building_store(RuntimeEconomyBuildingStore &out) const;
    void sync_owned_trade_escrow_store(RuntimeEconomyTradeEscrowStore &out) const;
    void sync_owned_family_store(RuntimeEconomyFamilyStore &out) const;
    void sync_owned_resource_store(RuntimeEconomyResourceStore &out) const;
    void fill_ledger_building_from_store(
        RuntimeEconomyBuildingCommittedBlock &block,
        const RuntimeEconomyBuildingStore &store) const;
    void fill_ledger_trade_escrow_from_store(
        RuntimeEconomyTradeEscrowCommittedBlock &block,
        const RuntimeEconomyTradeEscrowStore &store) const;
    void fill_ledger_family_from_store(
        RuntimeEconomyFamilyCommittedBlock &block,
        const RuntimeEconomyFamilyStore &store) const;
    void fill_ledger_resource_from_store(
        RuntimeEconomyResourceCommittedBlock &block,
        const RuntimeEconomyResourceStore &store) const;
    // Idle-day cursor identity. Capture and the Owned mirror flush share it so
    // a day-end export from OwnedState carries the same cursor block.
    void fill_ledger_epoch_cursor(
        RuntimeEconomyEpochCursorCommittedBlock &block) const;
    // Optional alias: publish/resource hot loops read stock lanes through
    // OwnedState when bound (see resource_stock_lanes()).
    void bind_resource_store(RuntimeEconomyResourceStore *store) noexcept {
        _resource_store_alias = store;
    }
    RuntimeEconomyResourceStore *bound_resource_store() const noexcept {
        return _resource_store_alias;
    }
    EconomyTrackedColumn<int64_t> &resource_stock_lanes() noexcept;
    const EconomyTrackedColumn<int64_t> &resource_stock_lanes() const noexcept;
    // A+Y N9: epoch harvest scratch follows the same alias rule as the stock
    // lanes — the bound store owns it, the NER locals are the unbound fallback.
    std::vector<int64_t> &resource_remaining_lanes() noexcept;
    const std::vector<int64_t> &resource_remaining_lanes() const noexcept;
    std::vector<int64_t> &resource_harvest_remaining_lanes() noexcept;
    const std::vector<int64_t> &resource_harvest_remaining_lanes() const noexcept;
    std::vector<int64_t> &resource_delta_lanes() noexcept;
    const std::vector<int64_t> &resource_delta_lanes() const noexcept;
    std::vector<uint32_t> &resource_lane_generation_lanes() noexcept;
    const std::vector<uint32_t> &resource_lane_generation_lanes() const noexcept;
    // Named-kernel household boundary: one post-building finalize chunk when
    // phase==1; otherwise ok hash boundary (settle stays on compact slice).
    bool kernel_run_household_market_boundary(
        EconomyStageCursor &cursor, const RuntimeEconomyEpochInput &input,
        EconomyStageResult &result, std::string &error);
    void attach_modifier_runtime(ModifierRuntime *runtime) { _modifier_runtime = runtime; }
    void attach_effect_runtime(EffectRuntime *runtime) { _effect_runtime = runtime; }
    // M2b: the family path writes Effect instances one row at a time, so it has
    // to route through the same forwarder the declarative batch path uses.
    // Null keeps the pre-M2b behaviour of writing EffectRuntime directly.
    void attach_effect_forwarder(EffectInstanceForwarder *forwarder) {
        _effect_forwarder = forwarder;
    }
    void attach_trigger_runtime(TriggerRuntime *runtime) { _trigger_runtime = runtime; }
    bool valid_family_effect_entity_handle(uint64_t handle) const;
    // X9-b ideology family targeting. FAMILY_COMMIT owns both the family and
    // branch tables, so resolution stays on this side of the domain boundary.
    bool valid_family_effect_target_handle(uint64_t handle) const;
    void collect_family_effect_target_handles(int32_t country_slot,
        int32_t min_branches, int32_t cap,
        std::vector<uint64_t> &out_handles) const;
    // Worker fixtures use this to exercise the authored >=3 branch clause with
    // the one founder branch a headless world can create. It may only relax the
    // authored floor; 0 disables the override.
    void set_family_target_min_branches_override_for_test(int32_t min_branches);
    int32_t family_target_min_branches_for_test(int32_t authored_min) const {
        return _family_target_min_branches_override_for_test > 0
            ? std::min(authored_min,
                _family_target_min_branches_override_for_test)
            : authored_min;
    }
    void notify_era_milestone_activated(uint64_t country_handle);
    bool country_restore_allowed() const {
        return !_bootstrapped && !_save.active && !_restore.active;
    }
    bool country_save_allowed() const {
        return !_epoch_active && !_save.active && !_restore.active && !_fatal;
    }

    godot::Dictionary configure(const godot::Dictionary &catalog,
                                const godot::Dictionary &profile,
                                int32_t cell_count,
                                int64_t seed);
    godot::Dictionary bootstrap(const godot::Dictionary &population_packet,
                                const godot::Dictionary &market_packet);
    godot::Dictionary submit_commands(const godot::Dictionary &batch);
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
    godot::Dictionary run_slice(const godot::Dictionary &ctx);
    godot::Dictionary run_slice_compact(const godot::Dictionary &ctx);
    // Worker ACTIVE production: one compact ECONOMY_GRAPH slice on the existing
    // formula owner (no second formula set). Returns false on fatal/ledger error.
    // When non-null, *done is set from the slice result (epoch idle for the day).
    // pending_input=true means same-day env/building context is not yet captured
    // on the main thread; returns true (not fatal) with *done=false so Host can
    // park the ECONOMY stage without soft-completing.
    bool worker_run_compact_slice(int64_t day_index, std::string &error,
                                  bool *done = nullptr,
                                  bool *pending_input = nullptr);
    // Published by the worker into the perf snapshot. Epoch counters reset in
    // clear_epoch_metrics; masks are the frozen epoch tax masks.
    struct TaxSchedDiag {
        double epoch_fiscal_ms = 0.0;
        double fiscal_settlement_ms = 0.0;
        double income_subsidy_ms = 0.0;
        uint8_t negative_tax_mask = 0;
        uint8_t active_tax_mask = 0;
    };
    void copy_tax_sched_diag(TaxSchedDiag &out, char *stage, size_t stage_cap,
                             char *substage, size_t substage_cap) const;
    // Phase-2.4.4.1: StageOps epoch-open prelude (peer/fiscal/trade/start_epoch).
    // Mirrors compact idle-open semantics without entering graph stages.
    bool run_epoch_open_prelude_drain(int64_t day_index, int64_t &work_done,
                                      std::string &error,
                                      bool *pending_input = nullptr,
                                      bool *idle_done = nullptr);
    // Phase-2.4.5: sync StageOps mutate day (prelude + all graph stage drains).
    bool run_stage_ops_day(int64_t day_index, std::string &error);
    bool stage_ops_epoch_open_ready() const noexcept { return _epoch_active; }
    uint32_t next_stage_ops_stage_index() const noexcept;
    bool capture_worker_day_input(const RuntimeEconomyDayInput &input,
                                  std::string &error);
    bool capture_environment(int64_t day_index, const float *temperature,
                             const float *temperature_30d, const float *moisture,
                             const float *plant_available_water,
                             const float *precipitation,
                             const float *snow_cover,
                             const float *weather_intensity,
                             const float *temperature_365d,
                             const uint8_t *weather_type,
                             const uint8_t *cover, int32_t count,
                             std::string &error);
    bool needs_environment_capture(int64_t day_index) const {
        return !_epoch_active && day_index > _last_committed_day &&
               _environment_day != day_index;
    }
    bool epoch_active() const { return _epoch_active; }
    // Committed-day identity used by the day-end Owned mirror publish. This is
    // the same day `capture_committed_ledger_state` stamps on the ledger.
    int64_t current_day() const { return _current_day; }
    int64_t last_committed_day() const { return _last_committed_day; }
    bool should_run(int64_t day_index) const;
    bool deadline_critical(int64_t day_index) const;
    // Mutable peer-domain watermark.  `_epoch_id` identifies an Economy
    // epoch; this value identifies the latest committed aggregate state.
    uint64_t committed_generation() const { return _committed_generation; }
    void drain_bio_introduces(godot::PackedInt32Array &cells,
                              godot::PackedInt32Array &bits);
    godot::PackedInt32Array economy_live_cells_query();
    godot::Dictionary report() const;
    godot::Dictionary committed_audit_report() const;
    // Test-only previous-cycle wall time. Negative values clear the override.
    // Injected milliseconds participate in N/P/I selection only; they never enter
    // the authoritative state hash or PKEC. The third argument is optional; a
    // negative value reuses the plan-cycle milliseconds for investment knives.
    godot::Dictionary inject_cadence_timing(double market_cycle_ms,
                                            double plan_cycle_ms,
                                            double investment_cycle_ms = -1.0);
    godot::Dictionary population_cell_summary(int32_t cell_idx) const;
    godot::Dictionary named_settlement_snapshot() const;
    godot::Dictionary settlement_delta(int64_t since_revision) const;
    godot::Dictionary population_cell_snapshot(int32_t cell_idx) const;
    godot::Dictionary population_cell_snapshot(
        int32_t cell_idx, bool include_details) const;
    godot::Dictionary population_cell_snapshot(int32_t cell_idx,
                                                float temperature,
                                                float moisture,
                                                float snow_cover,
                                                float weather_intensity,
                                                bool environment_ready) const;
    godot::Dictionary market_cell_snapshot(int32_t cell_idx) const;
    // Read-only bounded order page. `good_index` >= 0 keeps only orders that
    // carry that good line and emits only its lines; -1 keeps every line.
    // Rows are stably ordered by (arrival_day, order id) before paging.
    godot::Dictionary trade_orders_for_cell(int32_t cell_idx, int32_t offset,
                                             int32_t limit,
                                             int32_t good_index = -1) const;
    godot::Dictionary country_trade_snapshot(int64_t country_handle,
                                              const godot::String &view,
                                              int32_t offset, int32_t limit) const;
    godot::Dictionary building_cell_snapshot(int32_t cell_idx) const;
    // Read-only country economy rollup over the frozen epoch territory. Views:
    // summary / professions / buildings / goods / investment / settlements.
    // scope_cell < 0 aggregates the whole territory; filter_id narrows the
    // buildings view to one economic sector. Never simulation input.
    godot::Dictionary country_economy_overview(int64_t country_handle,
                                               const godot::String &view,
                                               int32_t scope_cell,
                                               int32_t filter_id,
                                               int32_t offset,
                                               int32_t limit) const;
    // Bounded committed projection for automatic, near-map situation icons.
    // No economy state is copied into MapData or the save schema.
    godot::Dictionary cell_situation_snapshot(
        const godot::PackedInt32Array &requested_cells) const;
    // Sparse, committed visual projection. This lane is deliberately excluded
    // from PKEC and state_hash; it is rebuilt from authoritative groups.
    godot::Dictionary building_visual_snapshot(
        const godot::PackedInt32Array &requested_cells) const;
    godot::Dictionary consume_building_visual_dirty_cells();
    godot::Dictionary treasury_construction_quotes(
        int64_t country_handle, int32_t cell_idx,
        const godot::PackedInt32Array &type_ids) const;
    godot::Dictionary construction_command_receipts(int64_t after_receipt_id,
                                                     int32_t limit) const;
    godot::Dictionary canal_route_quote(
        int64_t country_handle, int32_t start_cell, int32_t end_cell,
        const godot::PackedInt32Array &waypoints);
    godot::Dictionary canal_route_quote_detail(
        int64_t country_handle, int64_t quote_token) const;
    godot::Dictionary queue_canal_construction(
        int64_t country_handle, int64_t quote_token,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary canal_construction_receipts(
        int64_t country_handle, int64_t after_receipt_id,
        int32_t limit) const;
    godot::Dictionary family_cell_snapshot(int32_t cell_idx, int32_t offset,
                                            int32_t limit) const;
    godot::Dictionary family_snapshot(int64_t family_handle) const;
    godot::Dictionary family_branches(int64_t family_handle, int32_t offset,
                                      int32_t limit) const;
    godot::Dictionary family_traits(int64_t family_handle) const;
    godot::Dictionary family_branch_effects(int64_t family_handle,
                                            int32_t cell) const;
    godot::Dictionary submit_family_trait_commands(
        const godot::Dictionary &packed_batch);
    godot::Dictionary family_founding_offers(int32_t offset,
                                             int32_t limit) const;
    godot::Dictionary submit_family_founding_choice(
        int64_t offer_id, int64_t generation, int32_t choice_index,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary family_industries(int64_t family_handle, int32_t offset,
                                        int32_t limit) const;
    godot::Dictionary family_notable_people(int64_t family_handle,
                                            int32_t offset,
                                            int32_t limit) const;
    godot::Dictionary family_colonization_quotes(
        int64_t country_handle, int32_t target_cell, int64_t family_filter,
        int32_t source_filter, int32_t offset, int32_t limit,
        const uint8_t *visible, int32_t visible_count,
        uint64_t vision_revision);
    godot::Dictionary family_colonization_quote_detail(
        int64_t quote_token, int64_t population = -1) const;
    void fill_colonization_query_flags(godot::Dictionary &out) const;
    godot::Dictionary submit_family_colonization_start(
        int64_t country_handle, int64_t family_handle, int32_t source_cell,
        int32_t target_cell, int64_t population, int64_t quote_token,
        int64_t effective_day, int64_t sequence, const uint8_t *visible,
        int32_t visible_count, uint64_t vision_revision,
        bool queue_for_worker = false);
    godot::Dictionary submit_family_colonization_cancel(
        int64_t country_handle, int64_t expedition_handle,
        int64_t effective_day, int64_t sequence,
        bool queue_for_worker = false);
    // National procurement budget + era procurement target (era advancement,
    // docs/cpp-dots-runtime/era-advancement-runtime.md §2.2-2.4). Both are
    // transient (not PKEC, not state hash). Setters may be called from the
    // main thread at any time: they only append to a mutex-guarded pending
    // table that the Economy owner thread applies at the next epoch begin.
    godot::Dictionary set_country_procurement_policy(
        int64_t country_handle, bool enabled, int32_t treasury_share_bp,
        int32_t research_share_bp, int64_t effective_day, int64_t sequence);
    godot::Dictionary set_era_procurement_target(
        int64_t country_handle, bool active,
        const godot::PackedInt32Array &good_indices,
        const godot::PackedInt64Array &required_quantities,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary country_procurement_snapshot(int64_t country_handle) const;
    godot::Dictionary family_expeditions(int64_t country_handle,
                                         int32_t offset,
                                         int32_t limit) const;
    godot::Dictionary family_expedition_snapshot(
        int64_t country_handle, int64_t expedition_handle) const;
    godot::Dictionary family_colonization_receipts(
        int64_t country_handle, int64_t after_receipt_id,
        int32_t limit) const;
    godot::Dictionary notable_person_snapshot(int64_t person_handle) const;
    godot::Dictionary notable_person_needs(int64_t person_handle,
                                           int32_t offset,
                                           int32_t limit) const;
    godot::Dictionary building_notable_people(int64_t building_handle,
                                              int32_t offset,
                                              int32_t limit) const;
    // Cold-path satisfaction tracing. Both are pure reads of published state
    // and are only safe to call between native slices.
    godot::Dictionary explain_cohort_satisfaction(int64_t cohort_handle) const;
    godot::Dictionary cell_satisfaction_attractiveness(int32_t cell_idx) const;
    godot::Dictionary fiscal_snapshot(int64_t country_handle) const;
    godot::Dictionary fixed_math_probe(const godot::Dictionary &vectors) const;
    godot::Dictionary production_climate_math_probe(
        const godot::Dictionary &vectors) const;
    int64_t state_hash() const;
    int64_t state_hash_legacy() const;
    godot::Dictionary reset(const godot::String &reason);

    godot::Dictionary begin_save(int32_t chunk_bytes);
    godot::Dictionary begin_forensics_save(int32_t chunk_bytes);
    godot::PackedByteArray read_save_chunk(int32_t max_bytes);
    godot::Dictionary end_save();
    godot::Dictionary begin_restore();
    godot::Dictionary feed_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_restore();

    // ECP2 full-authority capture/apply (PKEC section remapping + resource wire).
    bool capture_ecp2_authority(RuntimeEconomyEcp2State &out, std::string &error,
                                  uint32_t flags = 0) const;
    bool apply_ecp2_authority(const RuntimeEconomyEcp2State &in,
                              std::string &error);
    const std::string &restore_rejected_reason() const noexcept {
        return _restore_rejected_reason;
    }
    // Explicit one-shot PKEC migrate helper: arms restore and clears into a
    // candidate scratch. Production coordinator/facade must not call this.
    godot::Dictionary begin_restore_pkec_migrate();

    // Committed, read-only economy event stream. Events produced by an active
    // frozen epoch remain private until aggregate_publish succeeds.
    godot::Dictionary event_schema() const;
    godot::Dictionary set_trace_filter(const godot::Dictionary &filter);
    godot::Dictionary set_inspector_trace_cell(int32_t cell_idx);
    godot::Dictionary poll_events(const godot::Dictionary &opts) const;
    godot::Dictionary ack_events(const godot::StringName &consumer_id,
                                 int64_t up_to_event_id);
    godot::Dictionary trace_report() const;
    godot::Dictionary begin_event_archive(int32_t chunk_bytes);
    godot::PackedByteArray read_event_archive_chunk(int32_t max_bytes);
    godot::Dictionary end_event_archive();

    // Building context is captured once at the frozen sample boundary. Natural
    // resources are resource-major and use GOODS_SCALE units in native state.
    bool capture_building_context(int64_t day_index, const float *elevation,
                                  const uint8_t *terrain, const uint8_t *landform,
                                  const uint8_t *vegetation, const uint8_t *is_water,
                                  const uint8_t *has_river, const int32_t *neighbor_indices,
                                  const std::vector<const float *> &resources,
                                  const std::vector<const float *> &resource_changes,
                                  int32_t count, std::string &error);
    bool needs_building_context_capture(int64_t day_index) const {
        return !_epoch_active && day_index > _last_committed_day &&
               _building_context_day != day_index;
    }
    const std::vector<std::string> &building_resource_reserve_slots() const {
        return _resource_reserve_slots;
    }
    const std::vector<std::string> &building_resource_extra_slots() const {
        return _resource_extra_slots;
    }
    int32_t cell_count() const { return _cell_count; }
    bool drain_building_resource_deltas(std::vector<size_t> &out_lanes,
                                        std::vector<int64_t> &out_deltas);
    // Natural regeneration coefficients for the worker-owned reserve lanes,
    // aligned with _resource_ids. Pointers inside `constants` stay unset.
    struct WorkerNaturalResource {
        NatResRuntime constants;
        int32_t habitat_mode = 0;
        int32_t temperature_signal = 0;
        int32_t moisture_signal = 0;
    };
    void configure_worker_natural_resources(
        std::vector<WorkerNaturalResource> resources);
    bool worker_natural_resources_configured() const {
        return !_worker_natural_resources.empty() &&
            _worker_natural_resources.size() == _resource_ids.size();
    }
    bool worker_resource_seeded() const { return _worker_resource_seeded; }
    void take_worker_resource_mirror_cells(std::vector<int32_t> &out);
    const std::vector<float> &worker_resource_reserve_lanes() const {
        return _worker_resource_reserve;
    }
    const std::vector<float> &worker_resource_extra_lanes() const {
        return _worker_resource_extra;
    }
    struct CommittedGameplayFact {
        int32_t kind = 0;
        int32_t cell = -1;
        uint64_t entity_handle = 0;
        int32_t entity_id = -1;
        int64_t value = 0;
        std::array<int32_t, 4> payload{};
        int32_t flags = 0;
    };
    enum GameplayFactKind : int32_t {
        GAMEPLAY_FACT_CONSTRUCTION_COMPLETED = 1,
        GAMEPLAY_FACT_TRADE_ARRIVED = 2,
        GAMEPLAY_FACT_SOCIAL_PRESSURE = 3,
        GAMEPLAY_FACT_TARIFF_SUBSIDY_INTENT = 4,
        GAMEPLAY_FACT_TECHNOLOGY_PRACTICE = 5,
        GAMEPLAY_FACT_TECHNOLOGY_CONTACT = 6,
        GAMEPLAY_FACT_INFRASTRUCTURE_COMPLETED = 7,
        GAMEPLAY_FACT_REPEATED_CROP_FAILURE = 8,
        GAMEPLAY_FACT_COUNTRY_DEVELOPMENT_METRIC = 9,
    };
    enum TechnologyPracticeRule : int32_t {
        PRACTICE_MAIZE_SELECTION = 0,
        PRACTICE_DRYLAND_DAYS = 1,
        PRACTICE_DRYLAND_DROUGHTS = 2,
        PRACTICE_HYDRAULIC_ENGINEERING = 3,
        PRACTICE_METALWORKING = 4,
        PRACTICE_PRINTING = 5,
        PRACTICE_STEAM_POWER = 6,
        PRACTICE_ELECTRIFICATION = 7,
        PRACTICE_INDUSTRIAL_ORGANIZATION = 8,
        PRACTICE_AUTOMATION = 9,
        PRACTICE_CLIMATE_MODELING = 10,
        PRACTICE_SEED_SAVING = 11,
        PRACTICE_RAINFED_ADAPTATION = 12,
        PRACTICE_PADDY_CONTROL = 13,
        PRACTICE_TERRACE_MAINTENANCE = 14,
        PRACTICE_MINE_SUPPORT = 15,
        PRACTICE_MINE_DRAINAGE = 16,
        PRACTICE_KILN_TEMPERATURE = 17,
        PRACTICE_PRINT_CALIBRATION = 18,
        PRACTICE_STEAM_SEALING = 19,
        PRACTICE_MOTOR_WINDING = 20,
        PRACTICE_ASSEMBLY_LINE = 21,
        PRACTICE_DIGITAL_CONTROL = 22,
        PRACTICE_MARITIME_OPERATIONS = 23,
        PRACTICE_WATERSHED_MANAGEMENT = 24,
        PRACTICE_FOREST_MANAGEMENT = 25,
        PRACTICE_CHEMICAL_PROCESS_CONTROL = 26,
        PRACTICE_ENERGY_CONTROL = 27,
        PRACTICE_HIDE_WORKING = 28,
        PRACTICE_RULE_COUNT = 29,
    };
    bool drain_committed_gameplay_facts(
        std::vector<CommittedGameplayFact> &out);
    // Gameplay journal row for a committed fact (phase 9, source 1). False for
    // kinds that are not published.
    static bool gameplay_fact_event(int32_t kind, int32_t &event_type,
                                    int32_t &payload_schema);
    bool compile_development_catalog(const godot::Dictionary &catalog,
                                     std::string &error);
    int32_t building_resource_access_cells(int32_t cell, int32_t resource_id,
                                           int32_t *out_cells, int32_t capacity) const;
    static constexpr uint8_t WATER_CLASS_NONE = 0;
    static constexpr uint8_t WATER_CLASS_LAKE = 1;
    static constexpr uint8_t WATER_CLASS_SHALLOW = 2;
    static constexpr uint8_t WATER_CLASS_FAR = 3;
    static constexpr uint8_t WATER_CLASS_DEEP = 4;
    static constexpr uint8_t WATER_CAP_RIVER = 1u;
    static constexpr uint8_t WATER_CAP_SHALLOW_SEA = 2u;
    static constexpr uint8_t WATER_CAP_FAR_SEA = 4u;
    static constexpr uint8_t WATER_CAP_DEEP_SEA = 8u;
    static constexpr int32_t WATER_LAYER_COUNT = 8;
    static constexpr int32_t WATER_PORTAL_GRAPH_COUNT = 4;
    static constexpr int32_t WATER_TRANSFER_PENALTY = 2;
    static constexpr int32_t WATER_ENTER_COST = 1;

    static int32_t water_maritime_level(uint8_t cap) {
        if ((cap & WATER_CAP_DEEP_SEA) != 0) return 3;
        if ((cap & WATER_CAP_FAR_SEA) != 0) return 2;
        if ((cap & WATER_CAP_SHALLOW_SEA) != 0) return 1;
        return 0;
    }
    static int32_t water_layer_index(uint8_t cap) {
        return ((cap & WATER_CAP_RIVER) != 0 ? 4 : 0) + water_maritime_level(cap);
    }
    static int32_t water_portal_graph_index(uint8_t cap) {
        const int32_t level = water_maritime_level(cap);
        if (level >= 1) return level;
        if ((cap & WATER_CAP_RIVER) != 0) return 0;
        return -1;
    }
    static uint8_t water_capability_from_layer(int32_t layer) {
        layer = std::clamp(layer, 0, WATER_LAYER_COUNT - 1);
        uint8_t cap = 0;
        if (layer >= 4) cap |= WATER_CAP_RIVER;
        const int32_t maritime = layer % 4;
        if (maritime >= 1) cap |= WATER_CAP_SHALLOW_SEA;
        if (maritime >= 2) cap |= WATER_CAP_FAR_SEA;
        if (maritime >= 3) cap |= WATER_CAP_DEEP_SEA;
        return cap;
    }

    bool capture_trade_topology(const int32_t *neighbor_indices,
                                const uint8_t *terrain,
                                const uint8_t *canal_edge_mask,
                                const float *canal_water,
                                const uint8_t *trade_passable_lut,
                                const int32_t *trade_move_cost_lut,
                                int32_t count, uint64_t generation,
                                std::string &error,
                                const uint8_t *landform = nullptr,
                                const uint8_t *has_river = nullptr);
    bool capture_trade_visibility(const uint8_t *visible, int32_t count,
                                  bool fog_solved, bool from_map,
                                  std::string &error);
    bool trade_visibility_manual() const { return _trade_visibility_manual; }
    bool refresh_canal_topology(const uint8_t *canal_edge_mask,
                                const float *canal_water,
                                int32_t count, std::string &error);
    int32_t trade_edge_cost(int32_t from_cell, int32_t to_cell) const;
    int32_t trade_land_step_cost(int32_t from_cell, int32_t to_cell,
                                 uint8_t cap) const;
    int32_t trade_component_for(int32_t cell, uint8_t cap) const;
    uint8_t water_capability_for_country(int32_t country_slot, bool frozen) const;
    uint8_t water_capability_for_handle(uint64_t country_handle, bool frozen) const;
    bool water_class_navigable(uint8_t water_class, uint8_t cap) const;
    bool cells_are_hex_neighbors(int32_t a, int32_t b) const;
    uint64_t canal_topology_hash() const {
        return _trade_topology.ready ? _trade_topology.topology_hash : 0;
    }
    uint64_t geo_flags_rebuilds() const {
        return _geo_flags_rebuilds.load(std::memory_order_relaxed);
    }
    uint64_t family_cell_metric_rebuilds() const {
        return _family_cell_metric_rebuilds.load(std::memory_order_relaxed);
    }
    uint64_t family_country_metric_rebuilds() const {
        return _family_country_metric_rebuilds.load(std::memory_order_relaxed);
    }
    uint64_t class_metric_rebuilds() const {
        return _class_metric_rebuilds.load(std::memory_order_relaxed);
    }
    int64_t class_metric_source_revision() const {
        return static_cast<int64_t>(_class_metric_source_revision);
    }
    int64_t class_metric_source_epoch_day() const {
        return _class_metric_source_epoch_day;
    }
    uint64_t class_metric_source_content_hash() const {
        return _class_metric_source_content_hash;
    }
    // Test-only: runs the same refresh as the epoch boundary without advancing
    // the simulation. Used to synchronize a fixture with the already-committed
    // snapshot before measuring.
    void refresh_class_opinion_metrics_for_test() {
        refresh_class_opinion_metrics();
    }
    const std::vector<int64_t> &class_metric_satisfaction_q16() const {
        return _epoch_country_class_satisfaction_q16;
    }
    const std::vector<int64_t> &class_metric_weighted_satisfaction_q16() const {
        return _epoch_country_weighted_satisfaction_q16;
    }
    const std::vector<int64_t> &class_metric_farmer_satisfaction_q16() const {
        return _epoch_country_farmer_satisfaction_q16;
    }
    const std::vector<int64_t> &class_metric_worker_satisfaction_q16() const {
        return _epoch_country_worker_satisfaction_q16;
    }
    uint64_t technology_metric_rebuilds() const {
        return _technology_metric_rebuilds.load(std::memory_order_relaxed);
    }
    uint64_t technology_metric_source_hash() const {
        return _technology_metric_source_hash;
    }
    uint64_t neighbor_distinct_goods_source_hash() const {
        return _neighbor_distinct_goods_source_hash;
    }
    // Test-only: replace the captured country technology bitset with an exact
    // shape, then run the production hash-gated refresh.
    void set_epoch_country_technologies_for_test(
        const std::vector<uint64_t> &bits);
    void clear_epoch_country_technologies_for_test();
    int32_t epoch_country_count_for_test() const {
        return _epoch_country_count;
    }
    // Size of the ECONOMY-side territory plane. `country_cell_count` returns 0
    // whenever this does not equal the cell count
    // (economy_runtime_family_buff.cpp:970), which makes every territory selector
    // produce zero targets -- indistinguishable from "the card matched nothing".
    // M4 diagnosis for the own-territory selector: how many times its branch ran,
    // what `owned` it saw, and how many cells it emitted. Without these, an empty
    // result is indistinguishable from "the branch never ran".
    mutable int64_t _own_territory_branch = 0;
    // Last-seen inputs of the own-territory branch. `emitted` was 0 while
    // `owned` was 1600, which can only be one of: source_cell out of range,
    // country != the slot that owns everything, or every country_cell_at returning
    // -1. These three record which.
    mutable int64_t _own_last_source_cell = -999;
    mutable int64_t _own_last_country = -999;
    mutable int64_t _own_last_cap = -999;
    mutable int64_t _own_first_cell_ok = -999;
    mutable int64_t _own_last_tag = -999;
    // Cells pushed inside the collect loop, BEFORE sort/unique/cap. If this is
    // non-zero while `emitted` is 0, the loss is in sort/unique/cap; if it is 0,
    // the loop itself never pushed.
    mutable int64_t _own_pushed_raw = 0;
    mutable int64_t _own_cell_neg = 0;
    mutable int64_t _own_tag_rejected = 0;
    int64_t own_last_source_cell_debug() const { return _own_last_source_cell; }
    int64_t own_last_country_debug() const { return _own_last_country; }
    int64_t own_last_cap_debug() const { return _own_last_cap; }
    int64_t own_first_cell_ok_debug() const { return _own_first_cell_ok; }
    int64_t own_last_tag_debug() const { return _own_last_tag; }
    int64_t own_pushed_raw_debug() const { return _own_pushed_raw; }
    int64_t own_cell_neg_debug() const { return _own_cell_neg; }
    int64_t own_tag_rejected_debug() const { return _own_tag_rejected; }
    mutable int64_t _own_territory_owned = 0;
    mutable int64_t _own_territory_emitted = 0;
    int64_t own_territory_branch_count() const { return _own_territory_branch; }
    int64_t own_territory_owned_total() const { return _own_territory_owned; }
    int64_t own_territory_emitted_total() const { return _own_territory_emitted; }

    // Readiness of the building-context columns the RADIAL selectors depend on.
    //
    // `collect_effect_target_cells` returns "no cells" for kinds 6..11 unless all four
    // columns are sized to the grid (`economy_runtime_family_buff.cpp:2554-2562`). That
    // guard is invisible from outside, so a fixture whose ring comes back empty cannot
    // tell "no neighbours" from "the snapshot was never captured".
    godot::Dictionary building_context_ready_for_test() const;

    size_t epoch_cell_country_size_for_test() const {
        return _epoch_cell_country.size();
    }
    // Colonization gate probes (plan 22 M3-8). `family_colonization_quotes`
    // rejects a cell with `passable == 0` unless an epoch is active
    // (`economy_runtime_colonization.cpp:496`), and NEITHER input was observable --
    // which is why a diagnostic that checked the other gates reported "all clear"
    // while the call kept failing.
    //
    // Both are const and side-effect free; they exist so a probe can say WHICH of
    // the two conditions is unmet instead of inferring it.
    bool trade_passable_for_test(int32_t cell) const {
        if (cell < 0 ||
            static_cast<size_t>(cell) >= _trade_topology.passable.size())
            return false;
        return _trade_topology.passable[static_cast<size_t>(cell)] != 0;
    }
    bool epoch_active_for_test() const { return _epoch_active; }
    bool trade_topology_ready_for_test() const {
        return _trade_topology.ready &&
            _trade_topology.passable.size() ==
                static_cast<size_t>(_cell_count.get());
    }
    int32_t epoch_country_technology_words_for_test() const {
        return _epoch_country_technology_words;
    }
    int64_t epoch_country_technology_word_for_test(
            int32_t country, int32_t word) const {
        if (country < 0 || word < 0) return 0;
        const size_t index =
            static_cast<size_t>(country) *
                static_cast<size_t>(_epoch_country_technology_words) +
            static_cast<size_t>(word);
        return index < _epoch_country_technologies.size()
            ? static_cast<int64_t>(_epoch_country_technologies[index]) : 0;
    }
    void refresh_technology_metrics_for_test() {
        refresh_technology_metrics();
    }
    // Bounded, read-only payload used by the Effect gameplay adapter. The
    // route remains Economy-owned until the Effect transaction is ACKED.
    bool canal_project_commit_payload(uint64_t project_handle,
                                      uint32_t project_generation,
                                      std::vector<int32_t> &route_cells,
                                      std::vector<int32_t> &route_edge_dirs,
                                      uint64_t &topology_hash,
                                      std::string &error) const;
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
    std::shared_ptr<const struct CountryAiEconomyDigest> country_ai_digest() const;
    void set_country_ai_family_preferences(std::vector<struct CountryAiFamilyPreferenceRow> rows);
    void queue_country_ai_colonization(std::vector<struct CountryAiColonizationIntent> intents);
    void export_country_ai_pending(
        std::vector<CountryAiColonizationIntent> &intents,
        std::vector<CountryAiColonizationStat> &stats,
        int64_t &receipt_cursor) const;
    void import_country_ai_pending(
        std::vector<CountryAiColonizationIntent> intents,
        std::vector<CountryAiColonizationStat> stats,
        int64_t receipt_cursor);

    // EconomyCommitView. While the worker owns economy execution the main
    // thread must not read live economy state outside the authority boundary.
    // It registers demand for a query key; the worker evaluates the demanded
    // keys at its committed day boundary and publishes an immutable view.
    // Views are UI/diagnostic reads only: never simulation input, PKEC or hash.
    enum class ReadQuery : uint16_t {
        NONE = 0,
        POPULATION_CELL_SNAPSHOT,
        POPULATION_CELL_SUMMARY,
        NAMED_SETTLEMENT_SNAPSHOT,
        SETTLEMENT_DELTA,
        MARKET_CELL_SNAPSHOT,
        EXPLAIN_COHORT_SATISFACTION,
        CELL_SATISFACTION_ATTRACTIVENESS,
        FISCAL_SNAPSHOT,
        COUNTRY_TRADE_SNAPSHOT,
        TRADE_ORDERS_FOR_CELL,
        BUILDING_CELL_SNAPSHOT,
        TREASURY_CONSTRUCTION_QUOTES,
        CONSTRUCTION_COMMAND_RECEIPTS,
        CANAL_ROUTE_QUOTE,
        CANAL_ROUTE_QUOTE_DETAIL,
        CANAL_CONSTRUCTION_RECEIPTS,
        FAMILY_CELL_SNAPSHOT,
        FAMILY_SNAPSHOT,
        FAMILY_TRAITS,
        FAMILY_BRANCHES,
        FAMILY_COLONIZATION_QUOTES,
        FAMILY_COLONIZATION_QUOTE_DETAIL,
        FAMILY_EXPEDITIONS,
        FAMILY_EXPEDITION_SNAPSHOT,
        FAMILY_COLONIZATION_RECEIPTS,
        FAMILY_BRANCH_EFFECTS,
        FAMILY_FOUNDING_OFFERS,
        FAMILY_INDUSTRIES,
        FAMILY_NOTABLE_PEOPLE,
        NOTABLE_PERSON_SNAPSHOT,
        NOTABLE_PERSON_NEEDS,
        BUILDING_NOTABLE_PEOPLE,
        COUNTRY_CLASS_OPINION_SNAPSHOT,
        COUNTRY_ECONOMY_OVERVIEW,
        SITUATION_VISUAL_SNAPSHOT,
        COUNTRY_PROCUREMENT_SNAPSHOT,
    };
    struct ReadKey {
        ReadQuery query = ReadQuery::NONE;
        std::array<int64_t, 8> args{};
        godot::String text;
        godot::PackedInt32Array ints;
        // Payload only (colonization visibility); its identity is the vision
        // revision carried in args.
        godot::PackedByteArray bytes;
        uint64_t hash = 0;
        void seal();
        bool same(const ReadKey &other) const;
    };
    struct ReadViewEntry {
        ReadKey key;
        godot::Dictionary value;
        // Entries survive across serves until the refresh interval, so each
        // carries the committed day it was evaluated at.
        int64_t committed_day = -1;
        uint64_t generation = 0;
    };
    struct ReadView {
        uint64_t serial = 0;
        uint64_t generation = 0;
        int64_t committed_day = -1;
        std::vector<ReadViewEntry> entries; // sorted by key.hash
        const ReadViewEntry *find(const ReadKey &key) const;
    };
    struct BuildingVisualView {
        uint64_t generation = 0;
        int32_t cell_count = 0;
        std::vector<int32_t> cell_offsets;
        std::vector<int32_t> type_indices;
        std::vector<int64_t> counts;
        // Per cell; BUILDING_VISUAL_UNKNOWN where no cohort has been sampled.
        std::vector<uint8_t> settlement_tiers;
        std::vector<uint8_t> living_levels;
        std::vector<uint8_t> rich_buckets;
        std::vector<uint8_t> poor_buckets;
    };
    godot::Dictionary evaluate_read_query(const ReadKey &key);
    void read_view_subscribe(const ReadKey &key);
    std::shared_ptr<const ReadView> read_view() const {
        return std::atomic_load_explicit(&_read_view, std::memory_order_acquire);
    }
    // Caller must hold the economy authority boundary with no epoch open.
    void serve_read_view();
    void publish_building_visual_view();
    std::shared_ptr<const BuildingVisualView> building_visual_view() const {
        return std::atomic_load_explicit(&_building_visual_view,
                                         std::memory_order_acquire);
    }
    static godot::Dictionary building_visual_rows(
        const BuildingVisualView &view,
        const godot::PackedInt32Array &requested_cells);
    godot::PackedInt32Array drain_building_visual_outbox();
    void read_view_reset();
    godot::Dictionary read_view_status() const;
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
    // ─── Military voucher: state service professions / state buildings ───────
    // Publishes the per-cell military ration satisfaction Military owns. Needs
    // listed in a profession's `state_supplied_need_ids` never enter market
    // purchase; their satisfaction is set from these Q16 values. Cells absent
    // from `cells` fall back to the previous value (initially 1.0), so a world
    // without soldiers is unchanged. Returns the number of cells written.
    int32_t set_military_ration_satisfaction(
        const std::vector<int32_t> &cells, const std::vector<int32_t> &q16);
    // Convenience read used by the ration path and by diagnostics.
    int32_t military_ration_satisfaction_q16(int32_t cell) const {
        return cell >= 0 &&
            static_cast<size_t>(cell) < _military_ration_sat_q16.size()
            ? _military_ration_sat_q16[static_cast<size_t>(cell)] : Q16_ONE;
    }
    // BEGIN army personnel lane public API (contract §1.4).
    // Military publishes the army's in-kind ration fill ratio once per day; the
    // cell overload also moves the lane to the army's current cell, which is
    // what guest consumption and the household-market kernel read. The two
    // argument form keeps the previous cell (embark cell) so a caller that only
    // has a ration cannot accidentally teleport the lane.
    void set_military_army_ration(uint64_t army_handle, int32_t ration_q16);
    void set_military_army_ration(uint64_t army_handle, int32_t ration_q16,
                                  int32_t cell);
    // Reconciliation read-out for the bridge: 0 when the army has no lane.
    int64_t military_army_population(uint64_t army_handle) const;
    int64_t military_army_funds(uint64_t army_handle) const;
    int32_t military_army_cell(uint64_t army_handle) const;
    int32_t military_army_satisfaction_q16(uint64_t army_handle) const;
    int64_t military_army_lane_population() const;
    // Feature detection for the Military bridge (army-personnel contract 2
    // §1.1/§1.2): true when this build implements opcode 33
    // (COMMAND_ARMY_SPLIT_LANES). The bridge probes it the same way it probes
    // military_army_population() so an army.split / army.transfer translation can
    // choose "the heads move" over the old "the lane stays put" behaviour.
    bool military_army_lane_split_supported() const;
    // Feature detection for opcode 34 (COMMAND_ARMY_LANE_PAY, army-pay contract
    // §3.3): true when this build pays an army lane from the treasury. The
    // Military bridge probes it before emitting ARMY_PAY so an Economy that
    // predates 34 degrades to a no-op plus a failed receipt instead of an
    // admission rejection that could take the whole POD batch down.
    bool military_army_lane_pay_supported() const;
    // END army personnel lane public API
    bool profession_is_state_service_only(int32_t profession_id) const {
        return profession_id >= 0 &&
            static_cast<size_t>(profession_id) <
                _profession_state_service_only.size() &&
            _profession_state_service_only[static_cast<size_t>(profession_id)] != 0;
    }
    bool profession_need_is_state_supplied(int32_t profession_id,
                                           int32_t stable_need) const {
        if (_state_supplied_need_columns == 0 || profession_id < 0 ||
            stable_need < 0) return false;
        const size_t index = static_cast<size_t>(profession_id) *
            _need_ids.size() + static_cast<size_t>(stable_need);
        return index < _profession_state_supplied_need_mask.size() &&
            _profession_state_supplied_need_mask[index] != 0;
    }
    // True for state-owned building types (kind 3). Excluded from investment
    // review, recovery/liquidation, loss closure, family ownership and merchant
    // lending; construction and demolition go through the state commands.
    bool building_type_is_state(int32_t type_id) const {
        return type_id >= 0 &&
            static_cast<size_t>(type_id) < _building_types.size() &&
            _building_types[static_cast<size_t>(type_id)].kind == 3;
    }
    int32_t state_owner_signature() const { return _state_owner_signature; }
    // How many of `cell`'s hex neighbours satisfy the tag (-1 = count every
    // neighbour). Reuses the selector BFS so there is exactly one definition of
    // "adjacent" in the codebase; a second adjacency walk would drift from it.
    int32_t neighbor_count_with_tag(int32_t cell, int32_t tag) const;
    // One hex neighbour from the epoch snapshot, or -1 when the snapshot or
    // direction is absent. X1-b's source-count walk needs bounded R1/R2
    // neighbour reads and a BFS for radius 3/4.
    int32_t building_neighbor(int32_t cell, int32_t direction) const;
    void collect_effect_target_cells(
        int32_t source_cell, int32_t selector_kind, int32_t param0, int32_t param1,
        std::vector<int32_t> &out_cells, uint64_t selection_salt = 0,
        EffectSelectorStats *stats = nullptr) const;

    // Expand a SOURCE SET by `depth` neighbour hops, in ONE pass.
    //
    // WHY THIS EXISTS
    //
    // The kind 14/15 fan-out used to call `collect_effect_target_cells` once PER SOURCE.
    // That function allocates and zeroes a `cells`-sized `seen` buffer on every call
    // (`economy_runtime_family_buff.cpp:2663`), so a 6400-cell country with 6400 sources
    // paid 6400 allocations of 6.4 KB -- about 41 MB of allocate-and-zero per resolve,
    // on top of the walks themselves.
    //
    // With the source cap removed (2026-10-28) that pattern went from 32 sources to
    // every tagged cell, which is what pushed one resolve past the 1 ms slice gate.
    // Sharding would have spread that cost over several steps while leaving the total
    // work O(sources x cells); this removes the per-source cost instead, so the step
    // stays bounded without needing more steps at all.
    //
    // Semantics are identical to the per-source loop: the result is the UNION of the
    // rings, deduplicated. The anchor cell is NOT included (kinds 6/7 contract).
    void dilate_cell_set(const std::vector<int32_t> &sources, int32_t depth,
                         std::vector<int32_t> &out_cells) const;
    // Resource id with the largest stock at `cell`, or -1 when the cell holds
    // no resource. Ties resolve to the lowest id so the answer is stable.
    int32_t dominant_resource_at(int32_t cell) const;
    // Stock share of dominant_resource_at(cell) in Q16, or 0 when the cell holds
    // no resource.
    int32_t dominant_resource_stock_share_q16(int32_t cell) const;
    // Good id with the largest *output* at `cell`, or -1 when the cell produces
    // nothing. Unlike dominant_resource_at() this is a flow reading: it weights
    // each building group's last_output (already net of output_factor_q16) by
    // the group's authored output mix.
    int32_t dominant_output_good_at(int32_t cell, int32_t &out_share_q16) const;
    // Country slot owning `cell` in the current epoch, or -1 when the epoch
    // index has not been rebuilt (call after an epoch has run).
    int32_t cell_country_slot(int32_t cell) const;
    // Lowest cell index owned by `country_slot`, or -1. TODO: replace with a
    // real capital / city-cell anchor once the game models one -- until then a
    // cell-targeted ideology effect is anchored on the country's first cell.
    int32_t country_anchor_cell(int32_t country_slot) const;
    // How many cells `country_slot` owns in the current epoch. Returns 0 when
    // the epoch index has not been rebuilt or the slot owns nothing.
    int32_t country_cell_count(int32_t country_slot) const;
    // `index`-th cell owned by `country_slot`, ascending by cell id, or -1.
    // Ascending order is what makes SELECTOR_OWN_TERRITORY replayable: a cap
    // always keeps the lowest cell ids.
    int32_t country_cell_at(int32_t country_slot, int32_t index) const;
    // Every cell owned by `country_slot` that carries `tag` (0-based, unlike the
    // selector's 1-based ids), ascending. No cap: X1-b must count every source,
    // while SELECTOR_OWN_TERRITORY intentionally stops at its instance budget.
    // The tag snapshot is loaded once for the whole sweep.
    void collect_own_tagged_cells(int32_t country_slot, int32_t tag,
        std::vector<int32_t> &out_cells) const;
    // Catalog-declared tag table (see target_tag.h). Called once where the
    // effect runtime is attached, so the selector never has to reach through a
    // possibly-null pointer from a const query path. Assigning here also
    // invalidates the per-epoch tag bitset, so ordering against
    // capture_country_epoch() does not matter.
    void set_target_tags(const TargetTagTable &tags);
    int32_t target_tag_count() const { return _target_tags.count(); }
    // True when `cell` satisfies `tag` in the current epoch. O(1) after the
    // first call of an epoch builds the bitset; out-of-range inputs are false.
    bool cell_has_target_tag(int32_t cell, int32_t tag) const;
    // Per-cell metric sampling for programs that have NO family behind them
    // (ideology cards today, technology effects later).
    //
    // fill_family_behavior_metrics() is family-relative, so it cannot be opened
    // to other domains as-is: it is private and every existing caller passes a
    // real family/branch. This door pins both to -1, which makes every
    // family-relative metric (ids 1..4, 15..21, 32..34) read 0 -- the correct
    // answer for "this cell has no family behind the card", not a bug.
    //
    // `out_metrics` is fully zeroed first, then only the ids selected by
    // `metric_mask` are computed, so a caller can pass the program's declared
    // mask straight from FamilyEffectMetadataPod and publish exactly the ids it
    // asked for. Metrics outside the mask stay 0.
    void sample_effect_metrics(int32_t cell, int32_t metric_count,
                               int64_t *out_metrics,
                               const MetricMask &metric_mask =
                                   MetricMask::all()) const;

    // ── R-4 X16 diagnostics ─────────────────────────────────────────────────
    // The profession id table, in `profession_id` order, so a probe can index the
    // frozen per-profession arrays by name.
    const std::vector<std::string> &profession_ids() const noexcept {
        return _profession_ids;
    }
    // The value `update_cohort_satisfaction` will use for (country_slot, profession).
    // Returns the DESIGN DEFAULTS (1.0 / 0) when the index is out of range, matching
    // what the reader does -- a probe that reported -1 instead would be measuring the
    // probe, not the runtime.
    //
    // Takes a COUNTRY SLOT, not a handle: the epoch arrays are slot-indexed, and
    // converting a handle here would need a lookup that does not exist on this class.
    // Callers get the slot from `get_country_cell_summary(...).country_slot`.
    void epoch_profession_values(int32_t country_slot, int32_t profession_id,
                                 int32_t &tax_tolerance_q16,
                                 int32_t &satisfaction_bp) const noexcept {
        tax_tolerance_q16 = Q16_ONE;
        satisfaction_bp = 0;
        if (country_slot < 0 || profession_id < 0) return;
        const size_t professions = std::max<size_t>(1, _profession_ids.size());
        const size_t index = static_cast<size_t>(country_slot) * professions +
            static_cast<size_t>(profession_id);
        if (index < _epoch_country_profession_tax_tolerance_q16.size())
            tax_tolerance_q16 = _epoch_country_profession_tax_tolerance_q16[index];
        if (index < _epoch_country_profession_satisfaction_bp.size())
            satisfaction_bp = _epoch_country_profession_satisfaction_bp[index];
    }

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

    // ---- NativeEconomyRuntime military read view
    // Narrow, allocation-free reads the Military bridge uses to build
    // MilitaryWorldDigest (world_ext_military.cpp). Owned by the military
    // bridge owner; the implementation lives in
    // economy_runtime_military_view.cpp. Nothing here mutates economy state.
    //
    // Per-cell committed view, filled from the bound population SoA without
    // building any Godot value. Every lane is resized to `cell_count()`.
    struct MilitaryCellView {
        std::vector<int64_t> population;
        std::vector<int64_t> unemployed;    // unemployed-profession heads
        std::vector<int64_t> soldiers;      // soldier-profession heads
        std::vector<uint8_t> has_merchant;  // a live merchant serves the cell
    };
    void military_read_cell_view(MilitaryCellView &out, int32_t good_count = 0) const;
    // Market sellable stock and retail price for one good across every live
    // market, sparse. `sellable` (GOODS_SCALE) already excludes the merchant
    // operating floor; `price` is MONEY_SCALE per 1.0 good.
    void military_read_market(int32_t good, std::vector<int32_t> &out_cells,
                              std::vector<int64_t> &out_sellable,
                              std::vector<int64_t> &out_price) const;
    // Dense soldier / unemployed profession ids (resolved from the profession
    // catalog; -1 when the catalog predates the military content).
    int32_t military_soldier_profession();
    int32_t military_unemployed_profession() const { return _unemployed_profession_id; }
    int32_t military_merchant_profession() const { return _merchant_profession_id; }
    // Per-head daily living cost of the soldier plan in MONEY_SCALE, excluding
    // the two ration needs Military supplies in kind (design §9.6).
    int64_t military_soldier_living_cost(int32_t country_slot) const;
    // Cohort handle for (cell, signature) / (cell, profession, any ethnicity);
    // 0 when no live cohort matches. Used to route CHANGE_SIGNATURE and
    // ADD_POPULATION intents.
    uint64_t military_cohort_handle(int32_t cell, int32_t signature) const;
    uint64_t military_cohort_handle_any_ethnicity(int32_t cell,
                                                  int32_t profession_id) const;
    // Dense profession rows of the province catalog. The levy path enumerates
    // them to decide which cohorts may be drafted (design §5.4).
    int32_t profession_count() const {
        return static_cast<int32_t>(_profession_ids.size());
    }
    // First live cohort in `cell` whose profession is one of `professions`
    // (ascending profession order, then lowest ethnicity). 0 when none.
    uint64_t military_cohort_handle_from_professions(int32_t cell,
                                                     const int32_t *professions,
                                                     int32_t count) const;
    // Total population still alive in the cell's soldier cohorts (0 = none).
    int64_t military_soldier_heads(int32_t cell) const;
    // Ethnicity of the signature a cohort handle names (-1 when stale). A
    // cohort transition must keep it so (profession, ethnicity) stays paired.
    // Signature id a cohort handle names (-1 when stale); the B opcode names
    // cohorts by signature so no slot id crosses an execution boundary.
    int32_t military_cohort_signature(uint64_t handle) const;
    int32_t military_cohort_ethnicity(uint64_t handle) const;
    // Destination signature for a cohort transition, resolved by THIS runtime's
    // own signature table: the ethnicity of the cell's cohort of `profession`,
    // else the ethnicity of any live cohort in the cell, else ethnicity 0.
    // Callers must never invent the id from a profession index.
    int32_t military_signature_for_cell_ethnicity(int32_t cell, int32_t profession) const;    // Diagnostics: how many (profession, ethnicity) signatures this catalog interns.
    int32_t military_signature_count() const { return static_cast<int32_t>(_signatures.size()); }
    // Signature id for (profession, ethnicity); -1 when the pair has no plan.
    int32_t military_signature_for(int32_t profession_id, int32_t ethnicity_id) const {
        return signature_for_profession_ethnicity(profession_id, ethnicity_id);
    }
    // Conserved Military -> treasury cash spend: reserve then collect through
    // the country fiscal escrow so the amount lands in the non-tax expenditure
    // slots. Returns the amount actually collected.
    int64_t military_collect_cash(int64_t country_handle, int64_t amount);
    // True while Economy can queue near-cash commands (no open epoch, not
    // saving/restoring, not faulted).
    bool military_command_window_open() const;
    // Queued economy commands with `effective_day <= day`. Lets the bridge tell
    // "not executed yet" apart from "rejected at execution".
    int32_t military_queued_commands_through(int64_t day) const;
private:
    // ---- NativeEconomyRuntime military read view (state)
    // Resolved lazily from the profession catalog (contract §3): a catalog
    // that predates the military content simply reports zero soldiers.
    int32_t _soldier_profession_id = -1;
    // Signature -> profession lane, rebuilt on every military_read_cell_view
    // call. Transient: never saved, never hashed.
    mutable std::vector<int32_t> _military_signature_profession;
    mutable bool _military_cell_view_published = false;
    void fire_family_event_once_effect(int32_t family_index,
                                       const std::string &program_key);
    void apply_pending_family_split_gifts();
    void ensure_family_policy_factors();
    bool sync_owned_columns_to_production(const RuntimeEconomyOwnedState &owned,
                                          std::string &error);
    void sync_production_core_columns_to_owned(
        RuntimeEconomyOwnedState &owned) const;
    void capture_owned_mirror_stores(RuntimeEconomyOwnedState &owned) const;
    void reset_family_policy_factors(int32_t family_index);
    int32_t family_colonization_population_reward_amount(
        uint64_t family_handle) const;
    void apply_family_colonization_population_reward(int32_t destination,
                                                     uint64_t family_handle,
                                                     int64_t amount);
    int32_t family_consumption_factor_q16(int32_t cohort_slot,
                                          int32_t need_id) const;
    int32_t family_good_consumption_factor_q16(int32_t cohort_slot,
                                               int32_t good_id) const;
    int32_t family_variant_preference_factor_q16(int32_t cohort_slot,
                                                 int32_t variant_id,
                                                 int64_t &sat, int32_t *good_factors = nullptr) const;
    uint64_t preferred_family_for_cohort(int32_t cohort_slot,
                                         int32_t axis,
                                         int32_t selector_kind,
                                         int32_t selector_id) const;
    int64_t building_reset_capital_value(BuildingGroupConstRef group) const;
    bool family_free_building_resources_legal(int32_t cell, int32_t type_id,
                                              int64_t count) const;
    void dissolve_family(uint64_t family_handle);
    // Applies _family_move_plan after the cohort lanes have moved.
    void move_family_membership(int32_t source_slot, int32_t destination_slot,
                                int64_t moved_funds);
    // Splits a move of `moved_population` from a cohort across anonymous
    // people and family edges; returns the anonymous share and fills
    // _family_move_plan with (edge index, people, claim).
    int64_t plan_family_membership_move(int32_t source_slot,
                                        int32_t destination_cell,
                                        int64_t moved_population,
                                        uint64_t preferred_family_handle,
                                        bool preferred_family_strict);
    struct FamilyMovePlanRow {
        int32_t edge = -1;
        int64_t people = 0;
        int64_t claim = 0;
    };
    std::vector<FamilyMovePlanRow> _family_move_plan;
    std::vector<int32_t> _family_destination_edge_scratch;
    // Sponsor of the build command being committed; 0 picks the cohort's
    // largest-claim family as before.
    uint64_t _construction_sponsor_override = 0;
    bool _construction_sponsor_override_set = false;
    uint64_t sponsor_family_for_cohort(uint64_t cohort_handle,
                                       int32_t cell) const;
    int32_t building_index_for_handle(uint64_t building_handle) const;
    void rebuild_building_handle_index() const;
    const std::unordered_map<uint64_t, int32_t> &building_handle_index() const;
    int64_t family_population(uint64_t family_handle) const;
    int64_t family_cash_claim(uint64_t family_handle) const;
    int64_t family_owned_buildings(uint64_t family_handle) const;
    bool compile_person_catalog(const godot::Dictionary &catalog,
                                std::string &error);
    bool run_person_commit_slice(int64_t &work_done, std::string &error);
    void rebuild_person_indices();
    void compact_person_needs();
    void normalize_person_needs();
    void bind_notable_person_jobs();
    void reconcile_person_claims();
    void update_person_equity_shares();
    void review_person_promotions();
    void promote_person_for_family(int32_t family_index);
    void register_person_effect(int32_t person_index);
    void retire_person(int32_t person_index);
    void record_person_demography(int32_t cohort_slot,
                                  int64_t population_before,
                                  int64_t deaths);
    void move_notable_people(uint64_t source_cohort_handle,
                             uint64_t destination_cohort_handle,
                             uint64_t family_handle,
                             int64_t family_people_before,
                             int64_t moved_family_people);
    int32_t family_membership_index(uint64_t family_handle,
                                    uint64_t cohort_handle) const;
    int64_t desired_need_units_for_actor(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t actor_population, int64_t actor_funds,
        int64_t &saturation_count) const;
    bool slot_has_merchant_profession(int32_t slot) const;
    bool is_merchant_slot(int32_t slot) const;
    int64_t living_merchant_population(int32_t cell) const;
    bool market_has_living_merchant(int32_t market) const;
    void collect_living_merchant_slots(int32_t market,
                                       std::vector<int32_t> &out) const;
    bool ensure_market_has_living_merchant(int32_t market, int64_t &repair_count,
                                           std::string &error);
    void touch_accounting_slot(int32_t slot);
    void record_cohort_fiscal(int32_t slot, int64_t signed_amount);
    void rebuild_incremental_audit_shadow();
    void begin_incremental_audit_epoch();
    // Continuous audit (touched-lane shadow carried across epochs) is on unless
    // PK_ECONOMY_AUDIT_SHADOW_REUSE=0. The 25-day full audit still runs.
    static bool audit_shadow_reuse_enabled();
    void audit_touch_population_lane(int32_t slot);
    void audit_touch_market_lane(size_t index);
    void sum_family_expedition_holdings(int64_t &population, int64_t &funds,
                                        int64_t &goods, int64_t &saturation) const;
    int64_t family_expedition_payload_people(int32_t expedition) const;
    void note_family_expedition_audit_invalidation();
    AuditTotals incremental_audit_totals() const;
    AuditTotals audit_totals_from_shadow(const AuditTotals &baseline) const;
    void commit_incremental_audit_shadow();
    void diagnose_incremental_audit_mismatch(const AuditTotals &full);
    void capture_goods_audit_candidates();
    void capture_money_audit_candidates();
    AuditTotals audit_totals() const;
    int64_t memory_bytes() const;
    int32_t choose_epoch_days(int64_t cohort_count);
    void write_cadence_report(godot::Dictionary &out) const;
    void write_hash_work_report(godot::Dictionary &out) const;
    EconomyWorkerChanges *market_mutation_sink() const {
        if (_production_result_sink) return &_production_result_sink->market_changes;
        if (_market_result_sink) return &_market_result_sink->market_changes;
        return nullptr;
    }
    ChangeRegistry &worker_change_registry(EconomyFieldId field) {
        switch (field.domain) {
            case 1: return population_store().changes;
            case 2: return market_store().changes;
            case 3:
                return _formula_owned && field.column == 1
                    ? _formula_owned->resources.changes : _resource_changes_local;
            case 4: return buildings_store().changes;
            case 5: return families_store().changes;
            case 6: return persons_store().changes;
            case 7: return family_influences().changes;
            case 8: return family_expeditions_store().changes;
            case 9: return trade_orders_store().changes;
            case 10: return _building_role_changes;
            case 14:
                switch (field.column) {
                    case 1: return _pending_commands.registry();
                    case 2: return _epoch_commands.registry();
                    case 3: return _structural_commands.registry();
                    case 4: return _family_trait_commands.registry();
                    case 5: return _family_founding_choices.registry();
                    default: throw std::logic_error("economy_worker_command_column_unregistered");
                }
            case 17:
                switch (field.column) {
                    case 1: return _settlements.tier.registry();
                    case 2: return _settlements.name_active.registry();
                    case 3: return _settlements.name_forced.registry();
                    case 4: return _settlements.prosperity_generation.registry();
                    case 5: return _settlements.name_roll_generation.registry();
                    case 6: return _settlements.prefix.registry();
                    case 7: return _settlements.root.registry();
                    case 8: return _settlements.suffix.registry();
                    case 9: return _settlements.disambiguator.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 18:
                switch (field.column) {
                    case 1: return _market_signals.cell_offsets.registry();
                    case 2: return _market_signals.good_ids.registry();
                    case 3: return _market_signals.business_demand_ema.registry();
                    case 4: return _market_signals.offered_supply_ema.registry();
                    case 5: return _market_signals.realized_withdrawal_ema.registry();
                    case 6: return _market_signals.cost_anchor_price.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 19:
                switch (field.column) {
                    case 1: return _labor_signals.cell_offsets.registry();
                    case 2: return _labor_signals.profession_ids.registry();
                    case 3: return _labor_signals.base_living_cost.registry();
                    case 4: return _labor_signals.role_living_cost.registry();
                    case 5: return _labor_signals.contract_wage_ema.registry();
                    case 6: return _labor_signals.paid_wage_ema.registry();
                    case 7: return _labor_signals.job_days.registry();
                    case 8: return _labor_signals.pay_ratio_q16.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 20:
                switch (field.column) {
                    case 1: return _trade_flows.cells.registry();
                    case 2: return _trade_flows.goods.registry();
                    case 3: return _trade_flows.import_ema.registry();
                    case 4: return _trade_flows.export_ema.registry();
                    case 5: return _trade_flows.period_import.registry();
                    case 6: return _trade_flows.period_export.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 21:
                switch (field.column) {
                    case 1: return _country_good_trade.countries.registry();
                    case 2: return _country_good_trade.goods.registry();
                    case 3: return _country_good_trade.import_quantity.registry();
                    case 4: return _country_good_trade.export_quantity.registry();
                    case 5: return _country_good_trade.import_base.registry();
                    case 6: return _country_good_trade.export_base.registry();
                    case 7: return _country_good_trade.import_tariff.registry();
                    case 8: return _country_good_trade.export_tariff.registry();
                    case 9: return _country_good_trade.batch_epoch.registry();
                    case 10: return _country_good_trade.batch_import_quantity.registry();
                    case 11: return _country_good_trade.batch_export_quantity.registry();
                    case 12: return _country_good_trade.batch_import_base.registry();
                    case 13: return _country_good_trade.batch_export_base.registry();
                    case 14: return _country_good_trade.batch_import_tariff.registry();
                    case 15: return _country_good_trade.batch_export_tariff.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 22:
                switch (field.column) {
                    case 1: return _country_partner_trade.countries.registry();
                    case 2: return _country_partner_trade.partners.registry();
                    case 3: return _country_partner_trade.import_quantity.registry();
                    case 4: return _country_partner_trade.export_quantity.registry();
                    case 5: return _country_partner_trade.import_base.registry();
                    case 6: return _country_partner_trade.export_base.registry();
                    case 7: return _country_partner_trade.order_count.registry();
                    case 8: return _country_partner_trade.batch_epoch.registry();
                    case 9: return _country_partner_trade.batch_import_quantity.registry();
                    case 10: return _country_partner_trade.batch_export_quantity.registry();
                    case 11: return _country_partner_trade.batch_import_base.registry();
                    case 12: return _country_partner_trade.batch_export_base.registry();
                    case 13: return _country_partner_trade.batch_order_count.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 23:
                switch (field.column) {
                    case 1: return _tariff_history.countries.registry();
                    case 2: return _tariff_history.kinds.registry();
                    case 3: return _tariff_history.bases.registry();
                    case 4: return _tariff_history.assessed.registry();
                    case 5: return _tariff_history.collected.registry();
                    case 6: return _tariff_history.requests.registry();
                    case 7: return _tariff_history.reserved.registry();
                    case 8: return _tariff_history.paid.registry();
                    case 9: return _tariff_history.cumulative_bases.registry();
                    case 10: return _tariff_history.cumulative_collected.registry();
                    case 11: return _tariff_history.cumulative_requests.registry();
                    case 12: return _tariff_history.cumulative_paid.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 25: return market_store().price_ceilings.registry();
            case 27: return _canal_projects.registry();
            case 26:
                switch (field.column) {
                    case 1: return _settlement_full_name_ids.registry();
                    case 2: return _settlement_prefix_ids.registry();
                    case 3: return _settlement_root_ids.registry();
                    case 4: return _settlement_suffix_ids.registry();
                    case 5: return _settlement_name_pack_id.registry();
                    case 6: return _ethnicity_ids.registry();
                    case 7: return _good_ids.registry();
                    case 8: return _plan_ids.registry();
                    case 9: return _profession_ids.registry();
                    default: throw std::logic_error("economy_name_catalog_column_unregistered");
                }
            case 24:
                switch (field.column) {
                    case 1: return _family_founding_offers.registry();
                    case 2: return _family_modifier_bindings.registry();
                    case 3: return _family_trigger_bindings.registry();
                    case 4: return _family_effect_bindings.registry();
                    case 5: return _family_founding_effects.registry();
                    case 6: return _family_split_parents.registry();
                    default: throw std::logic_error("economy_worker_variable_column_unregistered");
                }
            case 16:
                switch (field.column) {
                    case 1: return _birth_residual_q32.registry();
                    case 2: return _cell_building_structure_gen.registry();
                    case 3: return _cell_food_access_eq_previous.registry();
                    case 4: return _cell_food_export_eq_previous.registry();
                    case 5: return _cell_food_flow_valid.registry();
                    case 6: return _cell_food_import_eq_previous.registry();
                    case 7: return _cell_food_input_eq_previous.registry();
                    case 8: return _cell_food_output_eq_previous.registry();
                    case 9: return _cell_last_settlement_day.registry();
                    case 10: return _cell_owner_cash_gen.registry();
                    case 11: return _cell_population_gen.registry();
                    case 12: return _cell_price_stock_gen.registry();
                    case 13: return _cell_settlement_generation.registry();
                    case 14: return _cell_social_pressure_level.registry();
                    case 15: return _cell_support_ema_q16.registry();
                    case 16: return _cell_technology_gen.registry();
                    case 17: return _cell_trade_gen.registry();
                    case 18: return _epoch_country_handles.registry();
                    case 19: return _fiscal_cumulative_bases.registry();
                    case 20: return _fiscal_cumulative_collected.registry();
                    case 21: return _fiscal_cumulative_paid.registry();
                    case 22: return _fiscal_cumulative_requests.registry();
                    case 23: return _fiscal_escrow_by_country.registry();
                    case 24: return _fiscal_last_events.registry();
                    case 25: return _fiscal_previous_country_handles.registry();
                    case 26: return _fiscal_previous_requests.registry();
                    case 27: return _family_milestones_reached.registry();
                    case 28: return _cell_effect_shortage_q16.registry();
                    case 29: return _cell_essentials_shortage_q16.registry();
                    case 30: return _cell_force_wake.registry();
                    case 31: return _cell_next_review_day.registry();
                    case 32: return _cell_shortage_since_day.registry();
                    case 33: return _cell_tier.registry();
                    case 34: return _cell_tier_change_day.registry();
                    case 35: return _cell_tier_seen_gen.registry();
                    case 36: return _cell_tier_seen_population.registry();
                    case 37: return _environment_moisture_q16.registry();
                    case 38: return _environment_plant_available_water_q16.registry();
                    case 39: return _environment_precipitation_q16.registry();
                    case 40: return _environment_snow_q16.registry();
                    case 41: return _environment_temperature_30d_q16.registry();
                    case 42: return _environment_temperature_q16.registry();
                    case 43: return _environment_weather_q16.registry();
                    case 44: return _fiscal_last_assessed.registry();
                    case 45: return _fiscal_last_bases.registry();
                    case 46: return _fiscal_last_collected.registry();
                    case 47: return _fiscal_last_paid.registry();
                    case 48: return _fiscal_last_requests.registry();
                    case 49: return _fiscal_last_reserved.registry();
                    case 50: return _fiscal_last_unmet.registry();
                    case 51: return _maintenance_horizon_days_by_sector.registry();
                    case 52: return _cell_temperature_annual_q16.registry();
                    case 53: return _cell_temperature_anomaly_q16.registry();
                    case 54: return _cell_hazard_today_mask.registry();
                    case 55: return _cell_dry_streak_days.registry();
                    case 56: return _cell_days_since_hazard.registry();
                    case 57: return _cell_previous_hazard_mask.registry();
                    case 58: return _cell_weather_type.registry();
                    case 59: return _cell_cover.registry();
                    case 60: return _fiscal_last_non_tax_outflow.registry();
                    default: throw std::logic_error("economy_worker_native_column_unregistered");
                }
            case 15: return _metadata_changes;
            case 13: return _asset_peer_journal.registry();
            case 12:
                switch (field.column) {
                    case 1: return family_memberships().registry();
                    case 2: return family_ownerships().registry();
                    case 3: return family_trait_rolls().registry();
                    case 4: return person_needs().registry();
                    case 5: return family_expedition_payloads().registry();
                    case 6: return family_expedition_cargo().registry();
                    case 7: return family_expedition_kit_buildings().registry();
                    default: throw std::logic_error("economy_worker_record_column_unregistered");
                }
            case 11:
                switch (field.column) {
                    case 1: return family_expedition_route_cells().registry();
                    case 2: return family_expedition_route_costs().registry();
                    case 3: return family_expedition_person_handles().registry();
                    case 4: return family_expedition_missing_good_ids().registry();
                    case 5: return family_expedition_missing_good_quantities().registry();
                    default: throw std::logic_error("economy_worker_change_side_column_unregistered");
                }

            default: throw std::logic_error("economy_worker_change_domain_unregistered");
        }
    }
    void merge_economy_worker_changes(const EconomyWorkerChanges &changes) {
        // The coordinator visits each private record once in task order.
        // Adding domains must not multiply scans over the same touched list.
        for (const auto &before : changes.preimages)
            worker_change_registry(before.field).capture_before(before.field, before.lane, before.bits);
        for (const auto &range : changes.ranges)
            worker_change_registry(range.field).touch(range.field, range.first, range.count);
    }
    void write_fiscal_continuation_report(godot::Dictionary &out) const;
    godot::Dictionary fatal_context_report() const;
    int32_t locked_market_cycle_days() const;
    int32_t locked_slow_cycle_days() const;
    int32_t locked_plan_cycle_days() const;
    int32_t locked_investment_cycle_days() const;
    int32_t cycle_phase(int64_t day, int64_t start, int32_t cycle) const;
    bool market_in_workset(int32_t market, int64_t day) const;
    bool cell_in_market_workset(int32_t cell, int64_t day) const;
    bool cell_due_slow_review(int32_t cell, int64_t day) const;
    bool cell_due_plan_review(int32_t cell, int64_t day) const;
    bool cell_due_investment_review(int32_t cell, int64_t day) const;
    int32_t workset_elapsed_days(int64_t day_index) const;
    void capture_cell_elapsed_days(int64_t day_index);
    int32_t cell_elapsed_days(int32_t cell) const;
    enum TierReason : int32_t {
        TIER_REASON_PLAYER_TERRITORY = 0,
        TIER_REASON_VISIBLE,
        TIER_REASON_FORCED_WAKE,
        TIER_REASON_EFFECT_SHORTAGE,
        TIER_REASON_ESSENTIALS_SHORTAGE,
        TIER_REASON_CONSTRUCTION,
        TIER_REASON_RECENT_CHANGE,
        TIER_REASON_QUIET_SHORT,
        TIER_REASON_QUIET_WITH_BUILDINGS,
        TIER_REASON_DORMANT,
        TIER_REASON_OUT_OF_RANGE,
        TIER_REASON_COUNT,
    };
    uint8_t classify_cell_activity_tier(int32_t cell, int64_t day_index,
                                        int32_t *reason_out = nullptr) const;
    void refresh_cell_activity_tiers(int64_t day_index);
    void request_cell_wake(int32_t cell);
    int32_t tier_review_period_days(uint8_t tier) const;
    void rebuild_economy_live_cells();
    void capture_epoch_country_population();
    void refresh_cadence_estimates();
    void maybe_lock_cadence_cycles(int64_t day_index);
    void lock_market_cycle(int64_t day_index);
    void lock_slow_cycle(int64_t day_index);
    void lock_plan_cycle(int64_t day_index);
    void lock_investment_cycle(int64_t day_index);
    void apply_locked_slow_days();
    void note_completed_epoch_cadence_ms();
    void synthesize_cadence_locks_from_legacy_save();
    int32_t choose_locked_market_cycle_days(int32_t current_n) const;
    int32_t choose_locked_slow_cycle_days(int32_t current_s, int32_t n) const;
    int32_t choose_locked_investment_cycle_days(int32_t current_i, int32_t n,
                                                int32_t plan_days) const;
    int32_t choose_locked_cycle_days(int32_t current, int32_t n, int32_t knives,
                                     double ema, double injected_ms,
                                     int32_t lo, int32_t hi) const;
    int32_t longer_investment_cycle_days(int32_t plan_days, int32_t n,
                                         int32_t candidate) const;
    int32_t snap_slow_days_to_market_multiple(int32_t s, int32_t n) const;
    int32_t snap_cycle_days(int32_t value, int32_t n, int32_t lo,
                            int32_t hi) const;
    int32_t apply_cadence_hysteresis(int32_t current, int32_t raw) const;
    int32_t knives_per_day(double ms_per_knife) const;
    double quantized_ms_per_knife(double cycle_ms, int32_t knives) const;
    int32_t building_slice_end(int32_t active_begin) const;
    int32_t building_slice_end(int32_t active_begin, int32_t cell_cap,
                               int32_t group_cap) const;
    int32_t building_plan_slice_end(int32_t active_begin) const;
    int32_t plan_evaluate_slice_end(int32_t active_begin) const;
    int32_t slice_end_over(const std::vector<int32_t> &cells,
                           int32_t active_begin, int32_t cell_cap,
                           int32_t group_cap) const;
    int32_t household_post_slice_end(int32_t active_begin) const;
    int32_t estimate_building_ranges() const;
    int32_t stage_progress_q16() const;
    const char *stage_name() const;
    const char *stage_name(Stage stage) const;
    const char *publish_phase_name(PublishPhase phase) const;
    const char *trade_plan_init_phase_name(TradePlanInitPhase phase) const;

    static int64_t saturating_add(int64_t a, int64_t b, int64_t &saturation_count);
    static int64_t saturating_sub(int64_t a, int64_t b, int64_t &saturation_count);
    static int64_t saturating_mul(int64_t a, int64_t b, int64_t &saturation_count);
    // Ephemeral bill: sum exact q*p/GOODS_SCALE, then round once. No save state.
    friend struct EconomyPricingTests;
    struct GoodsBill {
        int64_t charged = 0;
        int32_t remainder = 0;
        int64_t add(int64_t quantity, int64_t price, int64_t &sat);
        int64_t total(int64_t &sat) const;
    };
    static int64_t inventory_adjusted_cost_pressure(int64_t cost, int64_t inventory, int64_t &sat);
    static int64_t goods_cost(int64_t quantity, int64_t price, int64_t &sat);
    static int64_t mul_div_sat(int64_t a, int64_t b, int64_t divisor,
                               int64_t &saturation_count);
    static int64_t pow_q16(int64_t ratio_q16, int64_t exponent_q16,
                           int64_t &saturation_count);
    int32_t sample_environment_curve(int32_t curve_id, int32_t cell) const;
    int32_t sample_environment_curve(int32_t curve_id,
                                     const EnvironmentSample &sample) const;
    EnvironmentSample environment_sample_for_cell(int32_t cell) const;
    static EnvironmentSample environment_sample_from_float(float temperature,
                                                            float moisture,
                                                            float snow_cover,
                                                            float weather_intensity,
                                                            bool ready);
    int64_t variant_unit_price(int32_t market, int32_t variant_id,
                               int64_t &saturation_count) const;
    void build_demand_basis(int32_t market, const EnvironmentSample &sample,
                            std::vector<int64_t> &variant_scores,
                            std::vector<int64_t> &variant_prices,
                            std::vector<int64_t> &need_score_sums,
                            std::vector<int64_t> &need_composites,
                            std::vector<int64_t> &need_environment,
                            int64_t &saturation_count) const;
    void build_demand_basis_cached(int32_t cell, int32_t market,
                                   const EnvironmentSample &sample,
                                   std::vector<int64_t> &variant_scores,
                                   std::vector<int64_t> &variant_prices,
                                   std::vector<int64_t> &need_score_sums,
                                   std::vector<int64_t> &need_composites,
                                   std::vector<int64_t> &need_environment,
                                   int64_t &saturation_count);
    void prepare_due_demand_basis_cache();
    int64_t desired_need_units(int32_t slot, int32_t need_index, int32_t dt_days,
                               int64_t environment_factor_q16,
                               int64_t composite_factor_q16,
                               int64_t &saturation_count) const;
    int64_t desired_need_units_for_funds(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t funds, int64_t &saturation_count) const;
    void compute_cohort_demand_preview(
        int32_t slot, int32_t market, const EnvironmentSample &sample,
        const std::vector<int32_t> *price_override, int64_t funds_override,
        std::vector<int64_t> &good_per_capita_daily,
        int64_t &saturation_count) const;
    int64_t survival_required_units(int32_t slot, int32_t stable_need_id,
                                    int32_t dt_days,
                                    const EnvironmentSample &sample,
                                    int64_t &saturation_count) const;
    godot::Dictionary population_cell_snapshot_impl(
        int32_t cell_idx, const EnvironmentSample &sample,
        bool include_details) const;
    void append_population_employment_fields(
        godot::Dictionary &out, int32_t cell_idx) const;
    void group_job_totals(BuildingGroupConstRef group, int64_t &job_capacity,
                          int64_t &jobs_filled, int64_t &sat) const;
    bool compile_settlement_catalog(const godot::Dictionary &catalog,
                                    std::string &error);
    int64_t population_total_for_cell(int32_t cell) const;
    uint8_t prosperity_tier_for_population(int64_t population,
                                           uint8_t current) const;
    std::string settlement_name_for_cell(int32_t cell) const;
    void assign_settlement_name(int32_t cell);
    void release_settlement_name(int32_t cell);
    void initialize_settlements_from_population();
    void update_settlements_for_changed_cells();
    void append_settlement_fields(godot::Dictionary &out, int32_t cell) const;
    godot::Dictionary settlement_rows(const std::vector<SettlementChange> &changes,
                                      bool full_snapshot) const;
    static void formula_fixed_per_capita(const FormulaBatchInput &in, int64_t *out,
                                         int64_t &saturation_count);
    static void formula_income_price_linear(const FormulaBatchInput &in, int64_t *out,
                                            int64_t &saturation_count);

    bool decode_restore_chunk(const std::vector<uint8_t> &bytes, std::string &error);
    bool begin_restore_internal(std::string &error);
    bool end_restore_internal(std::string &error);
    // Clears live SoA into an empty candidate rebuild surface. Must only run
    // after apply_ecp2_authority has captured a rollback backup (or from the
    // explicit PKEC migrate helper).
    void prepare_restore_candidate_scratch();
    bool apply_ecp2_authority_internal(const RuntimeEconomyEcp2State &in,
                                       std::string &error);
    void set_restore_rejected_reason(const std::string &reason);
    bool validate_ecp2_candidate(const RuntimeEconomyEcp2State &in,
                                 std::string &error) const;
    bool validate_restored_committed_snapshot(std::string &error) const;

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

  public:
    // Verify the country identity the archive asked for against the LIVE Country
    // runtime. Called by the Host once the PKCN checkpoint has been installed.
    //
    // This is the other half of `_accept_stale_country_identity`: the apply step
    // defers the comparison because Country is not installed yet, and this performs it
    // at the first moment the answer means something. Without it, pairing A's Country
    // bytes with B's Economy bytes would load silently -- the exact corruption the
    // original check existed to catch.
    //
    // Returns true when there is nothing to verify (no deferred identity), so a caller
    // can call it unconditionally on any start path.
    bool verify_deferred_country_identity(std::string &error) const;

  private:
    mutable bool _forensics_allow_fatal_export = false;
    // Set only for the begin_save call inside an ECP2 rollback-backup capture.
    mutable bool _ecp2_rollback_backup_export = false;
    // Country identity written into the save header while the Host builds a
    // bundle under worker Country authority (see EconomyAuthorityTransfer::capture).
    bool _save_country_identity_override = false;
    uint64_t _save_country_generation = 0;
    uint64_t _save_country_state_hash = 0;
    // Stable reject code for the last failed restore/ECP2 apply (diagnostics).
    std::string _restore_rejected_reason;
    // Why the last `apply_ecp2_authority` ran WITHOUT a rollback backup.
    //
    // The backup is best-effort: a live state that cannot be captured (which is normal
    // during a load, where the economy bundle is applied before the POD mirror is
    // installed) must not make the restore impossible. Kept for diagnostics so "we
    // applied without a rollback point" is visible instead of silent.
    std::string _last_restore_backup_skipped_reason;

    bool trace_detail_for_cell(int32_t cell) const;
    void trace_record_cashflow(int32_t cell, uint64_t cohort_handle, int32_t source,
                               int64_t income, int64_t expense);
    void trace_reconcile_inspector_cashflows();
    void trace_begin_epoch();
    void trace_append(int32_t kind, int32_t stage, int32_t cell,
                      int32_t subject_kind, int64_t subject_id,
                      int32_t subject_i0, int32_t subject_i1,
                      int64_t value0, int64_t value1, int64_t value2,
                      int64_t value3, const std::vector<EventLeg> *legs = nullptr,
                      int32_t flags = 0);
    void trace_commit_epoch(int64_t population_error, int64_t money_error,
                            int64_t goods_error);
    void trace_abort_epoch();
    void trace_evict_to_budget();
    int64_t trace_memory_bytes() const;
    static uint64_t trace_hash_mix(uint64_t hash, uint64_t value);
    static thread_local ProductionResult *_production_result_sink;
    static thread_local MarketResult *_market_result_sink;
    // Non-null only while a market worker task is running; stage_cell_summary
    // appends here instead of the shared list. Null on every scalar path.
    static thread_local std::vector<int32_t> *_staging_touched_sink;

    bool apply_treasury_sponsored_build_command(const Command &cmd,
                                                 std::string &error);
    bool apply_canal_build_command(const Command &cmd, std::string &error);
    bool process_due_canal_projects(int64_t day, std::string &error);
    bool plan_canal_route(uint64_t country_handle, int32_t start_cell,
                          int32_t end_cell,
                          const godot::PackedInt32Array &waypoints,
                          CanalQuote &quote, std::string &error) const;
    bool validate_canal_quote_snapshot(const CanalQuote &quote,
                                       std::string &error) const;
    godot::Dictionary canal_quote_dictionary(const CanalQuote &quote) const;
    void stage_canal_receipt(const Command &cmd, bool ok,
                             const char *code, uint64_t project_handle = 0,
                             int64_t cash_paid = 0,
                             int64_t treasury_goods_used = 0,
                             int64_t market_goods_used = 0);
    int32_t treasury_build_owner_signature(int32_t cell,
                                           int32_t type_id) const;
    void stage_construction_receipt(const Command &cmd, bool ok,
                                    const char *code, int64_t cash_paid = 0,
                                    int64_t treasury_goods_used = 0,
                                    int64_t market_goods_used = 0);
};

// Common invoice operands fit a signed 64-bit product. Keep this path inline;
// extreme quantities still use the established wide saturating arithmetic.
inline int64_t NativeEconomyRuntime::GoodsBill::total(int64_t &) const {
    return charged;
}

inline int64_t NativeEconomyRuntime::GoodsBill::add(
        int64_t quantity, int64_t price, int64_t &sat) {
    if (quantity <= 0 || price <= 0) return 0;
    int64_t units;
    int64_t fraction;
    constexpr int64_t small_max = std::numeric_limits<int32_t>::max();
    if (quantity <= small_max && price <= small_max) {
        const int64_t product = quantity * price;
        units = product / GOODS_SCALE;
        fraction = remainder + product % GOODS_SCALE;
    } else {
        units = mul_div_sat(quantity, price, GOODS_SCALE, sat);
        fraction = remainder + ((quantity % GOODS_SCALE) *
                                (price % GOODS_SCALE)) % GOODS_SCALE;
    }
    const int64_t correction = (fraction > GOODS_SCALE ||
        (remainder == 0 && fraction != 0)) ? 1 : 0;
    remainder = static_cast<int32_t>(fraction % GOODS_SCALE);
    constexpr int64_t limit = std::numeric_limits<int64_t>::max();
    if (units < limit && charged <= limit - units - correction) {
        const int64_t delta = units + correction;
        charged += delta;
        return delta;
    }
    const int64_t before = charged;
    charged = saturating_add(charged, saturating_add(units, correction, sat), sat);
    return charged - before;
}

inline int64_t NativeEconomyRuntime::goods_cost(
        int64_t quantity, int64_t price, int64_t &sat) {
    if (quantity <= 0 || price <= 0) return 0;
    constexpr int64_t small_max = std::numeric_limits<int32_t>::max();
    if (quantity <= small_max && price <= small_max)
        return (quantity * price + GOODS_SCALE - 1) / GOODS_SCALE;
    const int64_t whole = mul_div_sat(quantity, price, GOODS_SCALE, sat);
    const bool fractional = ((quantity % GOODS_SCALE) *
                            (price % GOODS_SCALE)) % GOODS_SCALE != 0;
    return saturating_add(whole, fractional ? 1 : 0, sat);
}

// Synthetic-grid self check for NativeEconomyRuntime::collect_effect_target_cells().
// Lives outside the runtime so the production class keeps a single friend line
// instead of an in-class test surface. Defined in
// economy_runtime_effect_selector_tests.cpp.
struct EconomyTargetSelectorTests {
    // Returns true when every selector assertion holds. On failure `error`
    // names the exact assertion that broke.
    static bool run(std::string &error);
};

} // namespace pk


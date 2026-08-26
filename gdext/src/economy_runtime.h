#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <limits>
#include <numeric>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace pk {

class EffectRuntime;

class NativeCountryRuntime;
class EconomyCsvRecorder;
class ModifierRuntime;
class TriggerRuntime;

// NativeEconomyRuntime is the sole mutable authority for population cohorts
// and markets. Godot containers are accepted/emitted only at coarse API
// boundaries; every graph stage operates on POD/std::vector storage.
class NativeEconomyRuntime {
public:
    // 28: persistent per-cell/per-ethnicity Q32 birth residuals.
    // 30: authoritative composite satisfaction dimensions, income baseline EMA,
    //     per-cohort fiscal burden accumulators, family branch satisfaction, and
    //     per-cell published social-pressure level.
    // 35: RECOVERY_PROBE is no longer a runtime state. The building catalog
    // and grouped construction contract changed with this version; older
    // economy saves are intentionally incompatible and are rejected.
    // 36: cell carrying-capacity mix (K_geo × surplus × sat) and support EMA.
    // v35 saves restore with support_ema = 1. Pre-v35 economy saves stay rejected.
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
    static constexpr int32_t SCHEMA_VERSION = 44;
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
    static constexpr uint64_t COLONIZATION_PREPARING_STOCK_HASH_REVISION = 4;
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

    enum CommandOpcode : int32_t {
        COMMAND_TRANSFER_TO_COHORT = 1,
        COMMAND_MINT_TO_COHORT = 2,
        COMMAND_BURN_FROM_COHORT = 3,
        COMMAND_ADD_STOCK = 4,
        COMMAND_REMOVE_STOCK = 5,
        COMMAND_ADD_POPULATION = 6,
        COMMAND_MOVE_POPULATION = 7,
        COMMAND_CHANGE_SIGNATURE = 8,
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
    };

    static constexpr uint16_t FAMILY_FLAG_SPLIT_RETAIN_ONLY = 1u;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_BONUS_WEIGHT = 2u;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_REPLACE = 4u;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_GIFT_BUILDING = 8u;
    static constexpr uint16_t FAMILY_FLAG_SPLIT_GIFT_POPULATION = 16u;
    // Only the formal starter bootstrap may create a household below the
    // ordinary notable-family minimum. Child branches are ordinary families.
    static constexpr uint16_t FAMILY_FLAG_STARTER = 32u;
    static constexpr int64_t FAMILY_MIN_ACTIVE_PEOPLE = 20;
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
        FAMILY_METRIC_COUNT = 37,
    };

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

    static bool is_registered_economy_effect_opcode(int32_t opcode) {
        return (opcode >= COMMAND_TRANSFER_TO_COHORT &&
                opcode <= COMMAND_FAMILY_POPULATION_REWARD) ||
            (opcode >= COMMAND_START_FAMILY_EXPEDITION &&
             opcode <= COMMAND_SETTLE_FAMILY_EXPEDITION) ||
            opcode == COMMAND_FAMILY_ABSORB_ANONYMOUS ||
            opcode == COMMAND_FAMILY_PURCHASE_DISCOUNT ||
            opcode == COMMAND_FAMILY_SET_SPLIT_POLICY;
    }

    enum ConstructionOwnershipPolicy : int32_t {
        OWNERSHIP_TREASURY_SPONSORED_PRIVATE = 1,
    };

    NativeEconomyRuntime();
    ~NativeEconomyRuntime();
    void attach_country_runtime(NativeCountryRuntime *runtime) { _country_runtime = runtime; }
    void attach_modifier_runtime(ModifierRuntime *runtime) { _modifier_runtime = runtime; }
    void attach_effect_runtime(EffectRuntime *runtime) { _effect_runtime = runtime; }
    void attach_trigger_runtime(TriggerRuntime *runtime) { _trigger_runtime = runtime; }
    bool valid_family_effect_entity_handle(uint64_t handle) const;
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
    // Pure, transaction-scoped validation used by EffectRuntime before it
    // flattens accepted transactions into one native enqueue batch. This does
    // not reserve request IDs or mutate Economy state.
    int32_t preflight_effect_commands_pod(const EffectCommand *commands,
                                          size_t count,
                                          std::string &error) const;
    bool submit_effect_commands_pod(const EffectCommand *commands, size_t count,
                                    std::vector<int64_t> &request_ids,
                                    std::string &error);
    bool effect_command_result_pod(int64_t request_id, bool &complete,
                                   bool &ok, std::string &reason) const;
    bool has_pending_effect_commands() const;
    godot::Dictionary run_slice(const godot::Dictionary &ctx);
    godot::Dictionary run_slice_compact(const godot::Dictionary &ctx);
    bool capture_environment(int64_t day_index, const float *temperature,
                             const float *temperature_30d, const float *moisture,
                             const float *plant_available_water,
                             const float *precipitation,
                             const float *snow_cover,
                             const float *weather_intensity, int32_t count,
                             std::string &error);
    bool needs_environment_capture(int64_t day_index) const {
        return !_epoch_active && day_index > _last_committed_day &&
               _environment_day != day_index;
    }
    bool should_run(int64_t day_index) const;
    void drain_bio_introduces(godot::PackedInt32Array &cells,
                              godot::PackedInt32Array &bits);
    godot::PackedInt32Array economy_live_cells_query();
    godot::Dictionary report() const;
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
    godot::Dictionary trade_orders_for_cell(int32_t cell_idx, int32_t offset,
                                             int32_t limit) const;
    godot::Dictionary country_trade_snapshot(int64_t country_handle,
                                              const godot::String &view,
                                              int32_t offset, int32_t limit) const;
    godot::Dictionary building_cell_snapshot(int32_t cell_idx) const;
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
        int32_t visible_count, uint64_t vision_revision);
    godot::Dictionary submit_family_colonization_cancel(
        int64_t country_handle, int64_t expedition_handle,
        int64_t effective_day, int64_t sequence);
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
    godot::Dictionary reset(const godot::String &reason);

    godot::Dictionary begin_save(int32_t chunk_bytes);
    godot::PackedByteArray read_save_chunk(int32_t max_bytes);
    godot::Dictionary end_save();
    godot::Dictionary begin_restore();
    godot::Dictionary feed_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_restore();

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
        PRACTICE_RULE_COUNT = 28,
    };
    bool drain_committed_gameplay_facts(
        std::vector<CommittedGameplayFact> &out);
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
    // Bounded, read-only payload used by the Effect gameplay adapter. The
    // route remains Economy-owned until the Effect transaction is ACKED.
    bool canal_project_commit_payload(uint64_t project_handle,
                                      uint32_t project_generation,
                                      std::vector<int32_t> &route_cells,
                                      std::vector<int32_t> &route_edge_dirs,
                                      uint64_t &topology_hash,
                                      std::string &error) const;
    struct CountryClassOpinionSnapshot {
        uint64_t revision = 0;
        uint64_t class_hash = 0;
        int64_t epoch_day = -1;
        int64_t commit_day = -1;
        int32_t country_count = 0;
        int32_t class_count = 0;
        std::vector<uint64_t> country_handles;
        std::vector<uint32_t> country_generations;
        std::vector<int64_t> population;
        std::vector<int64_t> funds;
        std::vector<int64_t> owner_employed;
        std::vector<int64_t> satisfaction_weighted;
        std::vector<int32_t> satisfaction_q16;
    };
    const CountryClassOpinionSnapshot &country_class_opinion_snapshot() const {
        return _class_opinion_buffers[
            static_cast<size_t>(_class_opinion_committed_buffer)];
    }
    godot::Dictionary country_class_opinion_snapshot_debug() const;

private:
    friend class EconomyCsvRecorder;
    enum StructuralOpcode : int32_t {
        STRUCTURAL_BIRTH = -1,
        STRUCTURAL_REMOVE_EMPTY = 0,
    };
    enum class Stage : int32_t {
        IDLE = 0,
        EPOCH_BEGIN = 1,
        LEDGER_APPLY = 2,
        HOUSEHOLD_MARKET = 3,
        STRUCTURAL_COMMIT = 4,
        WAIT_COMMIT = 5,
        BUILDING_EMPLOYMENT = 6,
        BUILDING_PRODUCTION = 7,
        BUILDING_COMMIT = 8,
        AGGREGATE_PUBLISH = 9,
        FATAL = 10,
        TRADE_SETTLE = 11,
        TRADE_DISPATCH = 12,
        TRADE_PLANNING = 13,
        BUILDING_PLAN = 14,
        GOVERNMENT_RESEARCH_PROCUREMENT = 15,
        FAMILY_COMMIT = 16,
        PERSON_COMMIT = 17,
    };

    enum class PublishPhase : uint8_t {
        PREPARE = 0,
        AUDIT_POPULATION = 1,
        AUDIT_MARKET = 2,
        AUDIT_TRANSIT = 3,
        AUDIT_ESCROW = 4,
        AUDIT_COUNTRY = 5,
        VERIFY = 6,
        WATERMARK = 7,
        TRADE_FLOW = 8,
        TRADE_DIAGNOSTICS = 9,
        TRADE_INIT = 10,
        COMMIT = 11,
        DONE = 12,
        COUNT = 13,
    };

    static constexpr size_t BUILDING_COMMIT_PHASE_COUNT = 7;

    enum class TradePlanInitPhase : uint8_t {
        IDLE = 0,
        COMPONENT_PREPARE = 1,
        COMPONENT_CLEAR = 2,
        COMPONENT_BUILD = 3,
        PREPARE = 4,
        INFLIGHT_BUILD = 5,
        INFLIGHT_SORT = 6,
        PRUNE = 7,
        INBOUND_BUILD = 8,
        ROTATE = 9,
        WORKSPACE_CLEAR = 10,
        FINALIZE = 11,
        DONE = 12,
    };

    struct FormulaBatchInput {
        const int64_t *population = nullptr;
        const int64_t *funds = nullptr;
        const int64_t *income_ema = nullptr;
        int32_t count = 0;
        int32_t price = 0;
        int32_t dt_days = 1;
        const int64_t *params = nullptr;
        int32_t param_count = 0;
    };
    using FormulaBatchFn = void (*)(const FormulaBatchInput &, int64_t *, int64_t &);

    struct FormulaDefinition {
        std::string stable_id;
        int32_t version = 1;
        int32_t min_params = 0;
        int32_t max_params = 0;
        FormulaBatchFn batch = nullptr;
    };

    struct Rule {
        int32_t good_id = -1;
        int32_t formula_id = -1;
        int32_t formula_version = 0;
        int32_t priority = 0;
        int32_t param_begin = 0;
        int32_t param_count = 0;
    };

    struct Plan {
        int32_t need_begin = 0;
        int32_t need_count = 0;
    };

    struct Need {
        int32_t stable_id = -1;
        int32_t priority = 0;
        int32_t variant_begin = 0;
        int32_t variant_count = 0;
        int64_t base_qty_per_person = 0;
        int32_t wealth_elasticity_q16 = 0;
        int32_t wealth_min_q16 = 0;
        int32_t wealth_max_q16 = Q16_ONE;
        int32_t price_quantity_elasticity_q16 = Q16_ONE;
        int32_t price_quantity_floor_q16 = 0;
        int32_t quantity_env_curve = -1;
        int32_t living_cost_weight_q16 = 0;
        // Composite satisfaction classification, resolved from the need catalog
        // rather than from need id strings.
        int32_t satisfaction_tier = SAT_DIM_BASIC;
        int32_t satisfaction_weight_q16 = Q16_ONE;
        std::array<int32_t, 9> wealth_lut_q16{};
    };

    struct VariantChoice {
        int32_t component_begin = 0;
        int32_t component_count = 0;
        int32_t preference_q16 = Q16_ONE;
        int32_t price_elasticity_q16 = Q16_ONE;
        int32_t preference_env_curve = -1;
        int64_t reference_unit_price = MONEY_SCALE;
        int32_t wealth_elasticity_q16 = 0;
        int32_t savings_threshold_months_q16 = 0;
        std::array<int32_t, 9> wealth_lut_q16{};
    };

    struct NeedComponent {
        int32_t good_id = -1;
        int64_t qty_per_need = GOODS_SCALE;
    };

    struct EnvironmentCurve {
        int32_t signal_id = 0;
        int32_t values_q16[ENV_CURVE_SAMPLES]{};
    };

    struct EnvironmentSample {
        int32_t temperature_q16 = Q16_ONE / 2;
        int32_t temperature_30d_q16 = Q16_ONE / 2;
        int32_t moisture_q16 = Q16_ONE / 2;
        int32_t plant_available_water_q16 = Q16_ONE / 2;
        int32_t snow_q16 = 0;
        int32_t weather_q16 = 0;
        bool ready = false;
    };

    struct ProductionClimateProfile {
        int32_t temperature_opt_q16 = Q16_ONE / 2;
        int32_t temperature_tolerance_q16 = Q16_ONE;
        int32_t water_opt_q16 = Q16_ONE / 2;
        int32_t water_tolerance_q16 = Q16_ONE;
        int32_t exposure_q16 = 0;
        int32_t floor_q16 = Q16_ONE;
    };

    struct Signature {
        int32_t profession_id = -1;
        int32_t ethnicity_id = -1;
        int32_t plan_id = -1;
        int64_t birth_rate_q32 = 0;
        int64_t death_rate_q32 = 0;
        int64_t satisfaction_birth_weight_q16 = Q16_ONE;
        // Class-specific composite weights, indexed by SatisfactionDimension.
        std::array<int32_t, SAT_DIM_COUNT> satisfaction_weights_q16{};
    };

    struct BuildingType {
		int32_t kind = 1; // 0=collector, 1=industrial.
        int32_t economic_sector = 2; // agriculture, extractive, manufacturing, energy, knowledge.
        int32_t production_climate_profile_id = -1;
        int32_t upgrade_family_id = -1;
        int32_t upgrade_tier = 0;
        int32_t owner_profession_id = -1;
        int64_t owner_slots_per_building = 0;
        int64_t wage_per_employee_per_day = 0;
        int32_t employee_begin = 0;
        int32_t employee_count = 0;
        int32_t construction_begin = 0;
        int32_t construction_count = 0;
        int32_t maintenance_begin = 0;
        int32_t maintenance_count = 0;
        int32_t maintenance_horizon_days = 0;
        int32_t input_begin = 0;
        int32_t input_count = 0;
        int32_t output_begin = 0;
        int32_t output_count = 0;
        int32_t resource_begin = 0;
        int32_t resource_count = 0;
        int32_t generation_begin = 0;
        int32_t generation_count = 0;
        int32_t generation_floor_q16 = 0;
        int32_t condition_begin = 0;
        int32_t condition_count = 0;
        int32_t construction_days = 0;
        int32_t behavior_id = 0; // 0=none, 1=consume, 2=cultivate+consume.
        int32_t behavior_version = 1;
        int32_t target_operating_margin_q16 = 0;
        int32_t supply_price_elasticity_q16 = Q16_ONE;
        int32_t output_cost_share_begin = 0;
        int32_t output_cost_share_count = 0;
        int32_t market_signal_begin = 0;
        int32_t market_signal_count = 0;
        int32_t labor_signal_begin = 0;
        int32_t labor_signal_count = 0;
        uint32_t kit_role_mask = 0;
    };

    struct JobRole {
        int32_t profession_id = -1;
        int64_t slots_per_building = 0;
        int32_t wage_policy = 0; // 0=none, 1=fixed, 2=adaptive.
        int64_t reference_wage_per_day = 0;
    };

    struct GoodAmount {
        int32_t good_id = -1;
        int64_t quantity = 0;
    };

    struct ConstructionCandidate {
        int32_t good_id = -1;
        int32_t efficiency_q16 = Q16_ONE;
    };

    struct ConstructionMaterialPlan {
        std::vector<int32_t> good_ids;
        std::vector<int64_t> quantities;
        int64_t total_cost = 0;
        int32_t failed_group = -1;
        bool feasible = false;
    };

    struct ProductionInput {
        int32_t preferred_good_id = -1;
        int64_t quantity = 0;
        int32_t candidate_begin = 0;
        int32_t candidate_count = 0;
        int32_t required_q16 = Q16_ONE;
    };

    struct InputCandidate {
        int32_t good_id = -1;
        int32_t efficiency_q16 = Q16_ONE;
    };

    struct ResourceAmount {
        int32_t resource_id = -1;
        int64_t quantity = 0;
        int32_t mode = 0; // 0=extract per day, 1=capacity per building.
        int32_t access_mode = 0; // 0=local, 1=local plus six hex neighbors.
    };

    struct CarryingSupportYield {
        int32_t building_type_id = -1;
        int32_t resource_id = -1;
        int32_t secondary_resource_id = -1;
        int32_t mode = 1;
        int64_t food_output_per_day = 0;
        int64_t resource_qty = 1;
        int64_t secondary_qty = 0;
    };

    struct ConditionToken {
        int32_t opcode = 0; // 1=predicate, 2=and, 3=or, 4=not.
        int32_t signal = 0;
        int32_t compare = 0;
        int32_t reference = -1;
        int64_t value = 0;
    };

    struct BuildingGroup {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t count = 0;
        int64_t filled_owner = 0;
        int32_t employee_fill_begin = -1;
        int32_t last_input_selection_begin = -1;
        int64_t last_capacity_q16 = 0;
        int64_t last_temperature_fit_q16 = Q16_ONE;
        int64_t last_water_fit_q16 = Q16_ONE;
        int64_t last_climate_capacity_q16 = Q16_ONE;
        int64_t last_climate_lost_output = 0;
        int64_t last_input = 0;
        int64_t last_output = 0;
        int64_t last_sold = 0;
        int64_t last_discarded = 0;
        int64_t last_resource = 0;
        int64_t last_resource_generated = 0;
        int64_t last_revenue = 0;
        int64_t last_input_cost = 0;
        int64_t last_wages_paid = 0;
        int64_t last_wages_due = 0;
        int64_t last_expected_revenue = 0;
        int64_t last_operating_cost = 0;
        int64_t last_maintenance_cost = 0;
        int32_t last_margin_gap_q16 = 0;
        int32_t planned_utilization_q16 = Q16_ONE;
        int64_t sample_unit_input_cost = 0;
        int64_t sample_unit_maintenance_cost = 0;
        int64_t last_base_wages_paid = 0;
        int64_t last_base_wages_due = 0;
        int64_t last_bonus_paid = 0;
        int64_t last_bonus_due = 0;
        int64_t purchase_intent_capacity_q16 = 0;
        int32_t realized_profit_margin_q16 = 0;
        uint16_t severe_loss_cycles = 0;
        uint16_t recovery_cycles = 0;
        uint16_t recovery_failed_reviews = 0;
        uint16_t merchant_debt_term_cycles_left = 0;
        uint16_t merchant_debt_delinquent_cycles = 0;
        uint8_t operating_state = 0; // 0=ACTIVE, 1=SUSPENDED_LOSS.
        uint8_t wage_suspended = 0;
        int64_t merchant_debt_principal = 0;
        int64_t merchant_debt_premium = 0;
        int64_t last_in_kind_livelihood_value = 0;
        uint8_t pending_operating_state = 255; // 255=NONE; applied at next due-cell epoch.
        uint16_t recovery_cooldown_cycles = 0;
        uint64_t modifier_handle = 0;
        int32_t output_factor_q16 = Q16_ONE;
    };

    struct PendingConstruction {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t count = 0;
        int64_t ready_day = 0;
        int64_t sequence = 0;
        int64_t merchant_debt_principal = 0;
        int64_t merchant_debt_premium = 0;
        uint16_t merchant_debt_term_cycles_left = 0;
        uint64_t sponsor_family_handle = 0;
    };

    struct FamilyStore {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<int64_t> stable_id;
        std::vector<int32_t> surname_id;
        std::vector<uint32_t> surname_disambiguator;
        std::vector<int64_t> founded_day;
        std::vector<int32_t> home_cell;
        std::vector<int32_t> origin_cell;
        std::vector<int32_t> origin_ethnicity;
        std::vector<int32_t> culture_group_id;
        std::vector<uint32_t> split_sequence;
        std::vector<uint16_t> decline_reviews;
        std::vector<uint16_t> flags;
        std::vector<int32_t> free_indices;
        int64_t active_count = 0;

        void clear();
        int32_t allocate();
        void release(int32_t index);
        uint64_t handle_for_index(int32_t index) const;
        bool valid_handle(uint64_t handle, int32_t &index_out) const;
    };

    struct NotablePersonStore {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<int64_t> stable_id;
        std::vector<uint64_t> family_handle;
        std::vector<uint64_t> cohort_handle;
        std::vector<int32_t> given_name_id;
        std::vector<uint32_t> name_disambiguator;
        std::vector<int64_t> notable_since_day;
        std::vector<uint16_t> flags;
        std::vector<int64_t> cash_claim;
        std::vector<int64_t> family_equity_share_q32;
        std::vector<int64_t> epoch_job_income;
        std::vector<int64_t> epoch_business_result;
        std::vector<int64_t> epoch_consumption_expense;
        std::vector<int64_t> epoch_tax;
        std::vector<int64_t> income_ema;
        std::vector<uint16_t> needs_satisfaction;
        std::vector<uint16_t> worst_need_id;
        std::vector<uint64_t> building_handle;
        std::vector<uint8_t> job_kind; // 0=none, 1=owner, 2=employee.
        std::vector<int32_t> employee_role_index;
        std::vector<int64_t> job_since_day;
        std::vector<int32_t> free_indices;
        int64_t active_count = 0;

        void clear();
        int32_t allocate();
        void release(int32_t index);
        uint64_t handle_for_index(int32_t index) const;
        bool valid_handle(uint64_t handle, int32_t &index_out) const;
    };

    struct PersonNeedState {
        uint64_t person_handle = 0;
        int32_t stable_need_id = -1;
        int64_t desired_period_units = 0;
        uint16_t satisfaction_q16 = 0;
        int64_t attributed_spend = 0;
    };

    struct PersonMarketAttribution {
        uint64_t person_handle = 0;
        int64_t consumption_expense = 0;
        int64_t consumption_tax = 0;
        uint16_t satisfaction_q16 = 0;
        uint16_t worst_need_id = std::numeric_limits<uint16_t>::max();
    };

    struct PersonDemographyEvent {
        uint64_t cohort_handle = 0;
        int64_t population_before = 0;
        int64_t deaths = 0;
    };

    struct FamilyMembershipEdge {
        uint64_t family_handle = 0;
        uint64_t cohort_handle = 0;
        int64_t people = 0;
        int64_t cash_claim = 0;
        int64_t population_basis = 0;
        int64_t funds_basis = 0;
        int64_t owner_employed = 0;
        int64_t employee_employed = 0;
    };

    struct FamilyBuildingOwnership {
        uint64_t family_handle = 0;
        uint64_t building_handle = 0;
        int64_t owned_count = 0;
        int64_t filled_owner = 0;
    };

    struct FamilyTraitRoll {
        uint64_t family_handle = 0;
        int32_t trait_id = -1;
        int32_t strength_q16 = Q16_ONE;
        uint8_t core = 0;
    };

    // Compiled family-local behavior factors. This transient CSR is rebuilt
    // only at FAMILY_COMMIT/restore boundaries; consumption, investment and
    // career hot loops never scan the global trait roll table.
    struct FamilyBehaviorFactorRow {
        int32_t cell = -1;
        int32_t score_term = 0;
        int32_t axis = 0;
        int32_t selector_kind = 0;
        int32_t selector_id = 0;
        int32_t factor_q16 = Q16_ONE;
    };

    struct FamilyIndustryStats {
        int32_t family_index = -1;
        int32_t cell = -1;
        uint8_t has_owned_manufacturing = 0;
        int32_t distinct_sector_count = 0;
        int32_t dominant_sector_id = -1;
        int32_t dominant_sector_share_q16 = 0;
        int32_t complete_chain_count = 0;
        int32_t max_local_chain_share_q16 = 0;
        int32_t max_chain_upgrade_family_id = -1;
    };

    struct FamilyOwnedOutputRow {
        int32_t family_index = -1;
        int32_t cell = -1;
        int32_t kind = 0; // 0=all sectors, 1=economic sector, 2=upgrade family.
        int32_t dense_id = 0;
        int32_t factor_q16 = Q16_ONE;
    };

    struct FamilyCellInfluenceStore {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<uint64_t> family_handle;
        std::vector<int32_t> cell;
        std::vector<int64_t> stable_id;
        std::vector<int64_t> population;
        std::vector<int64_t> cash;
        std::vector<int64_t> building_asset;
        std::vector<int32_t> population_share_q16;
        std::vector<int32_t> cash_share_q16;
        std::vector<int32_t> building_share_q16;
        std::vector<int32_t> score_q16;
        // Population-weighted composite satisfaction of the member cohorts in
        // this cell. Feeds branch-survival review; the prestige formula is
        // deliberately unchanged.
        std::vector<int32_t> satisfaction_q16;
        std::vector<uint8_t> prestige_level;
        std::vector<uint8_t> pending_target_level;
        std::vector<uint8_t> review_streak;
        std::vector<int64_t> last_review_day;
        std::vector<uint32_t> free_indices;

        void clear();
        int32_t allocate();
        void release(int32_t index);
        uint64_t handle_for_index(int32_t index) const;
        bool valid_handle(uint64_t handle, int32_t &index_out) const;
    };

    struct FamilyTraitCommand {
        int32_t operation = 0; // 1=grant, 2=remove, 3=set-strength.
        uint64_t family_handle = 0;
        int32_t trait_id = -1;
        int32_t strength_q16 = Q16_ONE;
        int64_t effective_day = 0;
        int32_t priority = 0;
        int64_t sequence = 0;
        uint64_t submit_order = 0;
    };

    struct FamilyModifierBinding {
        uint64_t branch_handle = 0;
        std::string definition_key;
        int32_t magnitude_q16 = 0;
    };

    struct FamilyTriggerBinding {
        uint64_t branch_handle = 0;
        std::string definition_key;
        int32_t reward_target = 0;
    };

    struct FamilyEffectBinding {
        uint64_t branch_handle = 0;
        std::string definition_key;
        int32_t strength_q16 = 0;
        int64_t instance_id = 0;
        uint32_t generation = 0;
        int32_t target_domain = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        uint64_t metric_mask = 0;
    };

    enum FamilyExpeditionState : uint8_t {
        EXPEDITION_OUTBOUND = 1,
        EXPEDITION_SETTLING = 2,
        EXPEDITION_RETURNING = 3,
        EXPEDITION_PREPARING = 4,
    };

    struct FamilyExpeditionPayload {
        uint64_t source_cohort_handle = 0;
        int32_t signature = -1;
        int64_t people = 0;
        int64_t funds = 0;
        int64_t epoch_income = 0;
        int64_t epoch_expense = 0;
        int64_t epoch_in_kind_income = 0;
        int64_t income_ema = 0;
        int64_t epoch_tax_paid = 0;
        int64_t epoch_subsidy_received = 0;
        int64_t income_baseline_ema = 0;
        int64_t demography_residual = 0;
        int64_t cash_claim = 0;
        int64_t owner_employed = 0;
        int64_t employee_employed = 0;
        uint32_t person_begin = 0;
        uint32_t person_count = 0;
        uint16_t needs_satisfaction = 0;
        uint16_t worst_need_id = std::numeric_limits<uint16_t>::max();
        uint16_t composite_satisfaction = 0;
        std::array<uint16_t, SAT_DIM_COUNT> satisfaction_dims{};
        uint8_t worst_dimension_id = 0;
        // Transient lane reservation rebuilt from authoritative payload data.
        int32_t reserved_slot = -1;
    };

    struct FamilyExpeditionCargoLine {
        int32_t good_id = -1;
        int64_t quantity = 0;
        uint8_t flags = 0;
    };

    struct FamilyExpeditionKitBuilding {
        int32_t type_id = -1;
        int64_t count = 0;
    };

    struct ColonizationKitPlan {
        std::vector<FamilyExpeditionKitBuilding> buildings;
        std::vector<FamilyExpeditionCargoLine> cargo;
        std::vector<int32_t> missing_good_ids;
        int64_t supported_population = 0;
        int64_t food_coverage_q16 = 0;
        uint8_t kit_partial = 0;
        uint8_t place_buildings = 0;
        uint64_t kit_hash = 0;
        uint64_t dest_identity = 0;
        uint64_t source_stock_identity = 0;
    };

    struct FamilyExpeditionStore {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<int64_t> stable_id;
        std::vector<uint64_t> country_handle;
        std::vector<uint64_t> family_handle;
        std::vector<int32_t> source_cell;
        std::vector<int32_t> target_cell;
        std::vector<int64_t> departure_day;
        std::vector<int64_t> due_day;
        std::vector<int32_t> route_cost;
        std::vector<int32_t> speed;
        std::vector<uint8_t> state;
        std::vector<int64_t> population;
        std::vector<uint32_t> route_begin;
        std::vector<uint32_t> route_count;
        std::vector<uint32_t> payload_begin;
        std::vector<uint32_t> payload_count;
        std::vector<uint32_t> cargo_begin;
        std::vector<uint32_t> cargo_count;
        std::vector<uint32_t> kit_building_begin;
        std::vector<uint32_t> kit_building_count;
        std::vector<uint64_t> kit_missing_stock_identity;
        std::vector<uint32_t> missing_good_begin;
        std::vector<uint32_t> missing_good_count;
        std::vector<int64_t> effect_transaction_id;
        std::vector<uint64_t> idempotency_key;
        std::vector<int32_t> free_indices;
        int64_t active_count = 0;

        void clear();
        int32_t allocate();
        void release(int32_t index);
        uint64_t handle_for_index(int32_t index) const;
        bool valid_handle(uint64_t handle, int32_t &index_out) const;
    };

    struct ColonizationQuoteCacheEntry {
        uint64_t token = 0;
        uint64_t country_handle = 0;
        uint64_t family_handle = 0;
        int32_t source_cell = -1;
        int32_t target_cell = -1;
        int64_t maximum_population = 0;
        int32_t route_cost = 0;
        int32_t travel_days = 0;
        uint64_t topology_generation = 0;
        uint64_t country_generation = 0;
        uint64_t vision_hash = 0;
        uint64_t route_hash = 0;
        uint64_t dest_kit_identity = 0;
        uint64_t source_stock_identity = 0;
        uint32_t route_begin = 0;
        uint32_t route_count = 0;
    };

    struct ColonizationReceipt {
        int64_t receipt_id = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        int64_t settled_day = 0;
        uint64_t country_handle = 0;
        uint64_t expedition_handle = 0;
        int32_t target_cell = -1;
        uint8_t kind = 0;
        std::string code;
    };

    struct BuildingRoleSpan {
        int32_t employee_begin = -1;
        int32_t input_begin = -1;
    };

    struct InvestmentExistingType {
        int32_t first_group = -1;
        int32_t last_group = -1;
        int32_t representative_group = -1;
        int64_t installed_count = 0;
        int64_t active_count = 0;
        int64_t suspended_count = 0;
        // Building-equivalent unused capacity in Q16. This is transient review
        // state: offered supply already accounts for the utilized share, so only
        // the unused share is reserved against the remaining demand gap.
        int64_t idle_capacity_q16 = 0;
        int64_t filled_owner = 0;
        int64_t owner_required = 0;
        int64_t last_sold = 0;
        int64_t last_discarded = 0;
    };

    enum InvestmentRejection : int32_t {
        INVESTMENT_REJECTION_NONE = 0,
        INVESTMENT_REJECTION_PENDING_CONSTRUCTION = 1,
        INVESTMENT_REJECTION_SUSPENDED_CAPACITY = 2,
        INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY = 3,
        INVESTMENT_REJECTION_INSTALLED_CAPACITY_SUFFICIENT = 4,
        INVESTMENT_REJECTION_OWNER_LIVELIHOOD = 5,
        INVESTMENT_REJECTION_SELL_THROUGH = 6,
        INVESTMENT_REJECTION_DISCARD = 7,
        INVESTMENT_REJECTION_INPUT_CHAIN = 8,
        INVESTMENT_REJECTION_TARGET_MARGIN = 9,
        INVESTMENT_REJECTION_PAYBACK = 10,
        INVESTMENT_REJECTION_SPONSOR_CAPITAL = 11,
        INVESTMENT_REJECTION_MATERIALS = 12,
        INVESTMENT_REJECTION_RESOURCE = 13,
        INVESTMENT_REJECTION_PROBABILITY = 14,
        INVESTMENT_REJECTION_MARKET_SIGNAL = 15,
        INVESTMENT_REJECTION_GROWTH_LIMIT = 16,
        INVESTMENT_REJECTION_UNSUPPORTED_KIND = 17,
        INVESTMENT_REJECTION_NO_COST_ADVANTAGE = 18,
    };

    struct InvestmentDiagnostic {
        int32_t type_id = -1;
        int32_t rejection_reason = INVESTMENT_REJECTION_NONE;
        int64_t shortage_q16 = 0;
        int64_t utilization_q16 = 0;
        int32_t driver_good_id = -1;
        int64_t driver_pressure_q16 = 0;
        int64_t driver_utilization_q16 = 0;
        int64_t driver_sellable = 0;
        int64_t driver_merchant_sold = 0;
        int64_t driver_sell_through_q16 = 0;
        int64_t driver_discard_q16 = 0;
        int64_t stealable = 0;
        int64_t challenger_unit_cost = 0;
        int64_t incumbent_unit_cost = 0;
        int64_t score_q16 = 0;
        int64_t payback_days = 0;
        int64_t required_capital = 0;
        int64_t projected_profit_per_day = 0;
        int64_t return_on_capital_q16 = 0;
        int64_t cost_advantage_q16 = 0;
        int32_t failed_material_group = -1;
        std::vector<int32_t> selected_material_good_ids;
        std::vector<int64_t> selected_material_quantities;
    };

    struct OutputInvestmentSignal {
        int32_t good_id = -1;
        int64_t pressure_q16 = 0;
        int64_t utilization_q16 = 0;
        int64_t deficit = 0;
        int64_t sellable = 0;
        int64_t merchant_sold = 0;
        int64_t discarded = 0;
        int64_t sell_through_q16 = 0;
        int64_t discard_q16 = 0;
        int64_t driver_strength_q16 = 0;
        int64_t nameplate_output = 0;
        int64_t demand = 0;
        int64_t startup_demand = 0;
        int64_t remote_startup_demand = 0;
        bool startup_incremental = false;
    };

    struct InvestmentIncumbentLane {
        int32_t good_id = -1;
        int32_t type_id = -1;
        int64_t unit_cost = 0;
        int64_t daily_offered = 0;
    };

    struct StartupRemoteLane {
        int32_t country = -1;
        int32_t component = -1;
        int32_t good_id = -1;
        int64_t remaining_daily = 0;
    };

    struct StartupRemoteGroup {
        int32_t country = -1;
        int32_t component = -1;
        int32_t lane_begin = 0;
        int32_t lane_end = 0;
    };

    struct StartupInboundLane {
        uint64_t cell_good_key = 0;
        int64_t quantity = 0;
    };

    struct StartupRemoteAccumulator {
        int32_t country = -1;
        int32_t component = -1;
        int32_t good_id = -1;
        int64_t demand = 0;
        int64_t available = 0;
    };

    struct PopulationStore {
        std::vector<int32_t> cell_first_page;
        std::vector<int32_t> page_next;
        std::vector<int32_t> page_cell;
        std::vector<int32_t> free_pages;

        std::vector<uint8_t> active;
        std::vector<uint8_t> reserved;
        std::vector<uint64_t> reservation_owner;
        std::vector<uint32_t> signature_id;
        std::vector<uint32_t> generation;
        std::vector<int64_t> population;
        std::vector<int64_t> funds;
        std::vector<int64_t> epoch_income;
        std::vector<int64_t> epoch_expense;
        // Derived diagnostic: retail value of goods consumed from producer-retained output.
        // It is reset with the epoch and intentionally excluded from save/hash authority.
        std::vector<int64_t> epoch_in_kind_income;
        std::vector<int64_t> income_ema;
        // Gross fiscal flows realized this epoch. They are pure attribution of
        // transfers that already happened, so they never participate in money
        // conservation; they exist so the tax-burden dimension can be computed
        // without re-deriving rates.
        std::vector<int64_t> epoch_tax_paid;
        std::vector<int64_t> epoch_subsidy_received;
        // Slow per-capita income EMA. `income_ema` tracks the current level;
        // this baseline trails it so their ratio is a growth signal.
        std::vector<int64_t> income_baseline_ema;
        // Subsistence satisfaction. Retains its historical name because it is
        // still the sole input to starvation mortality.
        std::vector<uint16_t> needs_satisfaction;
        std::vector<uint16_t> worst_need_id;
        // Composite satisfaction plus its SAT_DIM_COUNT-strided breakdown and
        // the dimension responsible for the largest weighted shortfall.
        std::vector<uint16_t> composite_satisfaction;
        std::vector<uint16_t> satisfaction_dims;
        std::vector<uint8_t> worst_dimension_id;
        std::vector<uint16_t> flags;
        std::vector<int64_t> demography_residual;
        std::vector<int64_t> owner_employed;
        std::vector<int64_t> employee_employed;

        int64_t active_count = 0;
        int64_t high_water_slots = 0;

        void clear(int32_t cells);
        void reset_satisfaction_slot(int32_t slot);
        int32_t allocate_page(int32_t cell);
        mutable int64_t scan_steps = 0;  // Diagnostics only.
        int32_t find_signature(int32_t cell, uint32_t signature) const;
        int32_t allocate_slot(int32_t cell, uint32_t signature);
        int32_t reserve_slot(int32_t cell, uint32_t signature,
                             uint64_t owner);
        int32_t claim_reserved_slot(int32_t slot, int32_t cell,
                                    uint32_t signature, uint64_t owner);
        void release_reserved_slot(int32_t slot, uint64_t owner);
        bool valid_handle(uint64_t handle, int32_t &slot_out) const;
        uint64_t handle_for_slot(int32_t slot) const;
        void release_slot(int32_t slot);
        void reclaim_empty_pages(int32_t cell);
        template <typename F> void for_each_in_cell(int32_t cell, F &&fn) const {
            if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return;
            for (int32_t p = cell_first_page[cell]; p >= 0; p = page_next[p]) {
                const int32_t base = p * COHORT_PAGE_SIZE;
                for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
                    const int32_t slot = base + lane;
                    if (active[slot] != 0) fn(slot);
                }
            }
        }
    };

    struct SettlementChange {
        int32_t cell = -1;
        uint8_t tier = 0;
        uint8_t name_active = 0;
    };

    struct SettlementRevision {
        int64_t revision = 0;
        std::vector<SettlementChange> changes;
    };

    struct SettlementStore {
        std::vector<uint8_t> tier;
        std::vector<uint8_t> name_active;
        std::vector<uint8_t> name_forced;
        std::vector<uint32_t> prosperity_generation;
        std::vector<uint32_t> name_roll_generation;
        std::vector<int32_t> prefix;
        std::vector<int32_t> root;
        std::vector<int32_t> suffix;
        std::vector<uint32_t> disambiguator;
        std::unordered_map<std::string, int32_t> active_names;
        std::deque<SettlementRevision> revisions;
        int64_t revision = 0;

        void clear(int32_t cells) {
            tier.assign(cells, 0);
            name_active.assign(cells, 0);
            name_forced.assign(cells, 0);
            prosperity_generation.assign(cells, 0);
            name_roll_generation.assign(cells, 0);
            prefix.assign(cells, -1);
            root.assign(cells, -1);
            suffix.assign(cells, -1);
            disambiguator.assign(cells, 0);
            active_names.clear();
            revisions.clear();
            revision = 0;
        }
    };

    struct MarketStore {
        int32_t market_count = 0;
        int32_t good_count = 0;
        std::vector<int64_t> stock;
        std::vector<int32_t> price;
        std::vector<int64_t> demand_ema;
        std::vector<uint16_t> last_shortage_q16;
        std::vector<int32_t> cell_to_market;

        void clear();
        int64_t index(int32_t market, int32_t good) const {
            return static_cast<int64_t>(market) * good_count + good;
        }
    };

    struct MarketSignalStore {
        std::vector<int32_t> cell_offsets;
        std::vector<int32_t> good_ids;
        // Optional O(1) (cell, good) -> sparse signal index. Rebuilt from the
        // authoritative ascending CSR and excluded from save/hash state.
        std::vector<int32_t> dense_index;
        std::vector<int64_t> business_demand_ema;
        std::vector<int64_t> offered_supply_ema;
        std::vector<int64_t> realized_withdrawal_ema;
        std::vector<int32_t> cost_anchor_price;

        void clear(int32_t cells) {
            cell_offsets.assign(static_cast<size_t>(std::max(0, cells)) + 1, 0);
            good_ids.clear();
            dense_index.clear();
            business_demand_ema.clear();
            offered_supply_ema.clear();
            realized_withdrawal_ema.clear();
            cost_anchor_price.clear();
        }
    };

    struct WaterPortalGraph {
        std::vector<int32_t> cell_portal;
        std::vector<int32_t> portal_cells;
        std::vector<int32_t> offsets;
        std::vector<int32_t> targets;
        std::vector<int32_t> costs;
        std::vector<int32_t> reverse_offsets;
        std::vector<int32_t> reverse_targets;
        std::vector<int32_t> reverse_costs;

        void clear() {
            cell_portal.clear();
            portal_cells.clear();
            offsets.clear();
            targets.clear();
            costs.clear();
            reverse_offsets.clear();
            reverse_targets.clear();
            reverse_costs.clear();
        }
    };

    struct TradeTopologyStore {
        std::vector<int32_t> neighbors;
        std::vector<uint8_t> passable;
        std::vector<int32_t> enter_cost;
        std::vector<int32_t> edge_cost;
        std::vector<uint8_t> canal_edge_mask;
        std::vector<float> canal_water;
        std::vector<int32_t> component;
        std::vector<uint8_t> water_class;
        std::vector<uint8_t> has_river;
        WaterPortalGraph water_portals[WATER_PORTAL_GRAPH_COUNT];
        std::vector<int32_t> component_layers;
        uint64_t topology_generation = 0;
        uint64_t topology_hash = 0;
        // Hash of the frozen cell->country ownership map used to build
        // components. Country cash/treasury generations must not invalidate
        // routing when borders did not change.
        uint64_t component_country_hash = 0;
        bool ready = false;

        void clear() {
            neighbors.clear();
            passable.clear();
            enter_cost.clear();
            edge_cost.clear();
            canal_edge_mask.clear();
            canal_water.clear();
            component.clear();
            water_class.clear();
            has_river.clear();
            for (WaterPortalGraph &graph : water_portals) graph.clear();
            component_layers.clear();
            topology_generation = 0;
            topology_hash = 0;
            component_country_hash = 0;
            ready = false;
        }
    };

    struct TradeSignal {
        int32_t cell = -1;
        int32_t good = -1;
        int32_t country = -1;
        int32_t price = 0;
        int64_t quantity = 0;
        int32_t age_days = 0;
        int32_t response_priority = 0;
    };

    struct TradeCandidate {
        int32_t source = -1;
        int32_t destination = -1;
        int32_t good = -1;
        int32_t country = -1;
        // `country` is retained as the source-country compatibility field.
        int32_t source_country = -1;
        int32_t destination_country = -1;
        uint64_t source_country_handle = 0;
        uint64_t destination_country_handle = 0;
        int32_t route_cost = 0;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        int64_t quantity = 0;
        int64_t expected_profit = 0;
        int64_t base_value = 0;
        int64_t retail_value = 0;
        int64_t import_transfer = 0;
        int64_t export_transfer = 0;
        int64_t capacity_work = 0;
        int64_t density_q16 = 0;
        int32_t signal_age_days = 0;
        int32_t response_priority = 0;
        uint32_t source_price_stock_generation = 0;
        uint32_t destination_price_stock_generation = 0;
        int64_t planned_day = -1;
        uint64_t topology_generation = 0;
        uint64_t country_topology_hash = 0;
        uint8_t flags = 0;
    };

    enum TradeLineFlags : uint8_t {
        TRADE_LINE_FOREIGN = 1U << 0,
        TRADE_LINE_RELIEF = 1U << 1,
        TRADE_LINE_IMPORT_SUBSIDY = 1U << 2,
        TRADE_LINE_EXPORT_SUBSIDY = 1U << 3,
        TRADE_LINE_IMPORT_TAX = 1U << 4,
        TRADE_LINE_EXPORT_TAX = 1U << 5,
    };

    struct TradeQuote {
        int64_t base = 0;
        int64_t retail = 0;
        int64_t import_transfer = 0;
        int64_t export_transfer = 0;
        int64_t importer_outlay = 0;
        int64_t exporter_receipt = 0;
        int64_t importer_profit = 0;
        int64_t combined_profit = 0;
        int64_t margin_q16 = 0;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        bool foreign = false;
        bool relief = false;
    };

    struct TradePlanStore {
        enum Phase : int32_t { IDLE = 0, SCAN = 1, ROUTE = 2 };
        int32_t phase = IDLE;
        int64_t scan_cursor = 0;
        int32_t route_cursor = 0;
        int64_t scan_total = 0;
        std::vector<int32_t> scan_cells;
        std::vector<int32_t> scan_goods;
        std::vector<int64_t> scan_inbound;
        uint64_t country_topology_hash = 0;
        uint64_t topology_generation = 0;
        std::vector<TradeSignal> sources;
        std::vector<TradeSignal> destinations;
        std::vector<TradeCandidate> working_candidates;
        std::vector<TradeCandidate> ready_candidates;
        // Rebuildable one-batch retry queue for nominally viable routes that
        // emitted a tariff subsidy intent. It is deliberately not persisted or
        // hashed; dispatch revalidates every endpoint, price and resource bound.
        std::vector<TradeCandidate> deferred_subsidy_candidates;
        std::vector<int64_t> distance;
        std::vector<uint32_t> distance_stamp;
        std::vector<int32_t> target_signal;
        std::vector<uint32_t> target_stamp;
        std::vector<std::pair<int64_t, int32_t>> heap;
        uint32_t search_stamp = 0;
        std::vector<uint64_t> route_cache_keys;
        std::vector<int32_t> route_cache_costs;
        uint64_t route_cache_country_topology_hash = 0;
        uint64_t route_cache_topology_generation = 0;
        bool route_search_active = false;
        int32_t route_search_source = -1;
        int32_t route_search_accepted = 0;
        int32_t route_search_pending_targets = 0;
        int32_t route_search_expansions = 0;
        int64_t completed_scans = 0;

        void clear_transient() {
            phase = IDLE;
            scan_cursor = 0;
            route_cursor = 0;
            scan_total = 0;
            scan_cells.clear();
            scan_goods.clear();
            scan_inbound.clear();
            sources.clear();
            destinations.clear();
            working_candidates.clear();
            ready_candidates.clear();
            deferred_subsidy_candidates.clear();
            distance.clear();
            distance_stamp.clear();
            target_signal.clear();
            target_stamp.clear();
            heap.clear();
            route_cache_keys.clear();
            route_cache_costs.clear();
            route_cache_country_topology_hash = 0;
            route_cache_topology_generation = 0;
            route_search_active = false;
            route_search_source = -1;
            route_search_accepted = 0;
            route_search_pending_targets = 0;
            route_search_expansions = 0;
            search_stamp = 0;
            completed_scans = 0;
            country_topology_hash = 0;
            topology_generation = 0;
        }
    };

    struct TradeOrderStore {
        enum State : uint8_t { IN_TRANSIT = 0, WAITING_RECEIVER = 1 };
        std::vector<int64_t> ids;
        std::vector<int32_t> sources;
        std::vector<int32_t> destinations;
        std::vector<int32_t> countries;
        std::vector<uint64_t> source_country_handles;
        std::vector<uint64_t> destination_country_handles;
        std::vector<int32_t> source_country_slots;
        std::vector<int32_t> destination_country_slots;
        std::vector<int64_t> departure_days;
        std::vector<int64_t> arrival_days;
        std::vector<int64_t> cash_escrow;
        std::vector<int64_t> capacity_work;
        std::vector<uint8_t> states;
        std::vector<uint8_t> cargo_delivered;
        std::vector<int32_t> line_offsets;
        std::vector<int32_t> line_goods;
        std::vector<int64_t> line_quantities;
        std::vector<int32_t> line_unit_prices;
        std::vector<int32_t> line_destination_prices;
        std::vector<int64_t> line_base_values;
        std::vector<int64_t> line_retail_values;
        std::vector<int64_t> line_import_transfers;
        std::vector<int64_t> line_export_transfers;
        std::vector<uint8_t> line_flags;
        std::vector<int32_t> seller_offsets;
        std::vector<uint64_t> seller_handles;
        std::vector<int64_t> seller_weights;
        // Derived CSR time buckets. Arrival days remain the persisted authority;
        // these vectors are rebuilt after dispatch, compaction, and restore.
        std::vector<int64_t> arrival_bucket_days;
        std::vector<int32_t> arrival_bucket_offsets;
        std::vector<int32_t> arrival_bucket_orders;
        bool arrival_buckets_dirty = true;
        int64_t next_id = 1;

        void clear() {
            ids.clear(); sources.clear(); destinations.clear(); countries.clear();
            source_country_handles.clear(); destination_country_handles.clear();
            source_country_slots.clear(); destination_country_slots.clear();
            departure_days.clear(); arrival_days.clear(); cash_escrow.clear();
            capacity_work.clear(); states.clear(); cargo_delivered.clear();
            line_offsets.assign(1, 0); line_goods.clear(); line_quantities.clear();
            line_unit_prices.clear(); line_destination_prices.clear();
            line_base_values.clear(); line_retail_values.clear();
            line_import_transfers.clear(); line_export_transfers.clear();
            line_flags.clear(); seller_offsets.assign(1, 0);
            seller_handles.clear(); seller_weights.clear();
            arrival_bucket_days.clear(); arrival_bucket_offsets.assign(1, 0);
            arrival_bucket_orders.clear(); arrival_buckets_dirty = true;
            next_id = 1;
        }
        int32_t size() const { return static_cast<int32_t>(ids.size()); }
    };

    struct TradeFlowSignalStore {
        std::vector<int32_t> cells;
        std::vector<int32_t> goods;
        std::vector<int64_t> import_ema;
        std::vector<int64_t> export_ema;
        std::vector<int64_t> period_import;
        std::vector<int64_t> period_export;

        void clear() {
            cells.clear(); goods.clear(); import_ema.clear(); export_ema.clear();
            period_import.clear(); period_export.clear();
        }
    };

    struct CountryGoodTradeAggregateStore {
        std::vector<int32_t> countries;
        std::vector<int32_t> goods;
        // Cumulative authority.
        std::vector<int64_t> import_quantity;
        std::vector<int64_t> export_quantity;
        std::vector<int64_t> import_base;
        std::vector<int64_t> export_base;
        std::vector<int64_t> import_tariff;
        std::vector<int64_t> export_tariff;
        // Latest touched epoch. Query treats rows from an older epoch as a
        // lazy-zero previous batch while retaining the cumulative columns.
        std::vector<int64_t> batch_epoch;
        std::vector<int64_t> batch_import_quantity;
        std::vector<int64_t> batch_export_quantity;
        std::vector<int64_t> batch_import_base;
        std::vector<int64_t> batch_export_base;
        std::vector<int64_t> batch_import_tariff;
        std::vector<int64_t> batch_export_tariff;
        void clear() {
            countries.clear(); goods.clear(); import_quantity.clear();
            export_quantity.clear(); import_base.clear(); export_base.clear();
            import_tariff.clear(); export_tariff.clear();
            batch_epoch.clear(); batch_import_quantity.clear();
            batch_export_quantity.clear(); batch_import_base.clear();
            batch_export_base.clear(); batch_import_tariff.clear();
            batch_export_tariff.clear();
        }
    };

    struct CountryPartnerTradeAggregateStore {
        std::vector<int32_t> countries;
        std::vector<int32_t> partners;
        // Cumulative authority.
        std::vector<int64_t> import_quantity;
        std::vector<int64_t> export_quantity;
        std::vector<int64_t> import_base;
        std::vector<int64_t> export_base;
        std::vector<int64_t> order_count;
        std::vector<int64_t> batch_epoch;
        std::vector<int64_t> batch_import_quantity;
        std::vector<int64_t> batch_export_quantity;
        std::vector<int64_t> batch_import_base;
        std::vector<int64_t> batch_export_base;
        std::vector<int64_t> batch_order_count;
        void clear() {
            countries.clear(); partners.clear(); import_quantity.clear();
            export_quantity.clear(); import_base.clear(); export_base.clear();
            order_count.clear();
            batch_epoch.clear(); batch_import_quantity.clear();
            batch_export_quantity.clear(); batch_import_base.clear();
            batch_export_base.clear(); batch_order_count.clear();
        }
    };

    struct TariffHistoryStore {
        std::vector<int32_t> countries;
        std::vector<int32_t> kinds;
        std::vector<int64_t> bases;
        std::vector<int64_t> assessed;
        std::vector<int64_t> collected;
        std::vector<int64_t> requests;
        std::vector<int64_t> reserved;
        std::vector<int64_t> paid;
        std::vector<int64_t> cumulative_bases;
        std::vector<int64_t> cumulative_collected;
        std::vector<int64_t> cumulative_requests;
        std::vector<int64_t> cumulative_paid;
        void clear() {
            countries.clear(); kinds.clear(); bases.clear(); assessed.clear();
            collected.clear(); requests.clear(); reserved.clear(); paid.clear();
            cumulative_bases.clear(); cumulative_collected.clear();
            cumulative_requests.clear(); cumulative_paid.clear();
        }
    };

    struct LaborMarketStore {
        std::vector<int32_t> cell_offsets;
        std::vector<int32_t> profession_ids;
        std::vector<int64_t> base_living_cost;
        std::vector<int64_t> role_living_cost;
        std::vector<int64_t> contract_wage_ema;
        std::vector<int64_t> paid_wage_ema;
        std::vector<int64_t> job_days;
        std::vector<int32_t> pay_ratio_q16;

        void clear(int32_t cells) {
            cell_offsets.assign(static_cast<size_t>(std::max(0, cells)) + 1, 0);
            profession_ids.clear();
            base_living_cost.clear();
            role_living_cost.clear();
            contract_wage_ema.clear();
            paid_wage_ema.clear();
            job_days.clear();
            pay_ratio_q16.clear();
        }
    };

    struct PricePressure {
        int64_t household_demand = 0;
        int64_t business_demand = 0;
        int64_t supply = 0;
        int64_t excess_q16 = 0;
        int64_t inventory_target = 0;
        int64_t inventory_q16 = 0;
        int64_t shortage_q16 = 0;
        int64_t cost_q16 = 0;
        int64_t idle_q16 = 0;
        int64_t total_q16 = 0;
        int64_t change_q16 = 0;
        int64_t adjustment_anchor_price = 1;
        int64_t inactive_reversion_alpha_q16 = 0;
    };

    struct Command {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t target_handle = 0;
        int32_t i32_0 = 0;
        int32_t i32_1 = 0;
        int64_t i64_0 = 0;
        int64_t i64_1 = 0;
        uint64_t submit_order = 0;
        int64_t effect_request_id = 0;
        uint64_t effect_idempotency_key = 0;
    };

    struct EffectCommandResult {
        uint8_t complete = 0;
        uint8_t ok = 0;
        std::string reason;
    };

    struct StructuralCommand {
        int32_t opcode = 0;
        int32_t source_slot = -1;
        int32_t cell = -1;
        int32_t signature = -1;
        int64_t population = 0;
        int64_t funds = 0;
        int64_t sequence = 0;
    };

    struct CellSummary {
        int64_t population = 0;
        int64_t funds = 0;
        int64_t epoch_income = 0;
        int64_t epoch_expense = 0;
        int32_t cohort_count = 0;
        int32_t satisfaction_q16 = 0;
    };

    struct AuditTotals {
        int64_t population = 0;
        int64_t cohort_funds = 0;
        int64_t country_cash = 0;
        int64_t goods_stock = 0;
        int64_t country_goods = 0;
        int64_t transit_goods = 0;
        int64_t transit_population = 0;
        int64_t escrow_cash = 0;
        int64_t expedition_funds = 0;
        int64_t expedition_goods = 0;
        int64_t merchant_cash = 0;
        int64_t merchant_inventory_retail_value = 0;
        int64_t merchant_inventory_liquidation_value = 0;
    };

    struct TradePlanInitState {
        TradePlanInitPhase phase = TradePlanInitPhase::IDLE;
        size_t cursor = 0;
        int32_t order_cursor = 0;
        int32_t line_cursor = 0;
        size_t active_before_prune = 0;
        size_t rotation = 0;
        int32_t component_seed = 0;
        int32_t next_component = 0;
        size_t component_queue_cursor = 0;
        std::vector<int32_t> component_queue;
        std::vector<uint64_t> inflight_keys;
        std::vector<uint64_t> retained_active_keys;
        std::vector<int64_t> rotated_inbound;

        void clear() {
            phase = TradePlanInitPhase::IDLE;
            cursor = 0;
            order_cursor = 0;
            line_cursor = 0;
            active_before_prune = 0;
            rotation = 0;
            component_seed = 0;
            next_component = 0;
            component_queue_cursor = 0;
            component_queue.clear();
            inflight_keys.clear();
            retained_active_keys.clear();
            rotated_inbound.clear();
        }
    };

    struct Order {
        int32_t local_cohort = -1;
        int32_t slot = -1;
        int32_t good = -1;
        int32_t priority = 0;
        int64_t desired_qty = 0;
        int64_t funded_qty = 0;
        int64_t filled_qty = 0;
    };

    struct BundleOrder {
        int32_t local_cohort = -1;
        int32_t slot = -1;
        int32_t need_index = -1;
        int32_t variant_index = -1;
        int32_t priority = 0;
        int64_t desired_units = 0;
        int64_t funded_units = 0;
        int64_t filled_units = 0;
        int64_t unit_price = 0;
        int64_t base_unit_price = 0;
        int64_t quoted_subsidy_per_unit = 0;
    };

    struct OwnerRetainedOutput {
        int32_t owner_slot = -1;
        int32_t good_id = -1;
        int32_t building_group = -1;
        int64_t quantity = 0;
    };

    struct BuildingInKindCredit {
        int32_t building_group = -1;
        int64_t frozen_value = 0;
    };

    struct EventLeg;
    struct CashflowEntry;

    struct CohortWelfareEntry {
        uint64_t cohort_handle = 0;
        // Mirrors of the authoritative columns, copied here so the Inspector can
        // read per-need detail and the composite from one trace payload.
        int32_t overall_satisfaction_q16 = 0;
        int32_t living_standard_level = 0;
        int32_t worst_dimension_id = -1;
        std::array<int32_t, SAT_DIM_COUNT> satisfaction_dims_q16{};
        std::vector<int32_t> need_ids;
        std::vector<int32_t> need_satisfaction_q16;
        std::vector<int32_t> need_weight_q16;
        std::vector<int32_t> need_tiers;
        std::vector<int64_t> previous_demand_per_capita_daily;
        std::vector<int64_t> wealth_demand_delta_per_capita_daily;
        std::vector<int64_t> price_demand_delta_per_capita_daily;
    };

    struct MarketResult {
        bool ok = true;
        std::string error;
        int64_t processed_cohorts = 0;
        int64_t processed_rules = 0;
        int64_t processed_needs = 0;
        int64_t processed_variants = 0;
        int64_t processed_components = 0;
        int64_t saturation_count = 0;
        int64_t consumed_goods = 0;
        int64_t cycle_flow_consumed = 0;
        int64_t cycle_flow_discarded = 0;
        int64_t retained_output_consumed = 0;
        int64_t retained_output_discarded = 0;
        std::vector<int64_t> retained_consumed_by_good;
        std::vector<BuildingInKindCredit> building_in_kind_credits;
        int64_t owner_working_capital_reserved = 0;
        int64_t births = 0;
        int64_t deaths = 0;
        std::vector<int32_t> population_changed_cells;
        std::vector<PersonNeedState> person_needs;
        std::vector<PersonMarketAttribution> person_attributions;
        std::vector<PersonDemographyEvent> person_demography;
        int64_t closing_population = 0;
        int64_t closing_cohort_funds = 0;
        int64_t closing_goods_stock = 0;
        double formula_ms = 0.0;
        double clear_ms = 0.0;
        double fallback_ms = 0.0;
        double merchant_settle_ms = 0.0;
        double price_ms = 0.0;
        int64_t merchant_count = 0;
        int64_t merchant_repairs = 0;
        int64_t price_cap_hits = 0;
        int64_t price_cost_anchor_hits = 0;
        int64_t price_inactive_reversions = 0;
        int64_t revenue = 0;
        int64_t changed_prices = 0;
        uint64_t mutation_hash = 1469598103934665603ULL;
        std::vector<EventLeg> trace_legs;
        std::vector<CashflowEntry> cashflows;
        std::vector<CohortWelfareEntry> welfare_entries;
        std::vector<StructuralCommand> structural_commands;
        std::vector<int32_t> trade_active_goods;
        // Worker-local audit lanes. Worker mutation sites cannot append to the
        // shared audit vectors; the owning thread registers these during merge.
        std::vector<size_t> audit_population_lanes;
        std::vector<size_t> audit_market_lanes;
        int64_t allocation_growth_count = 0;
        int64_t allocation_growth_bytes = 0;
        int64_t approximation_decisions = 0;
        int64_t approximation_exact_probes = 0;
        int64_t approximation_certificate_failures = 0;
        int64_t approximation_exact_fallbacks = 0;
        int64_t approximation_frontier_candidates = 0;
        int64_t approximation_frontier_pruned = 0;
        int64_t approximation_max_certified_regret_q16 = 0;
        int64_t approximation_probe_violations = 0;
        int64_t approximation_probe_max_spend_error_q16 = 0;
        int64_t approximation_probe_max_demand_error_q16 = 0;
        std::vector<uint8_t> approximation_variant_active;

        void reset();
        int64_t capacity_bytes() const;
    };

    enum TraceMode : int32_t {
        TRACE_OFF = 0,
        TRACE_SUMMARY = 1,
        TRACE_SELECTIVE = 2,
        TRACE_FULL_DEBUG = 3,
    };

    enum CashflowSource : int32_t {
        CASHFLOW_WAGES = 1,
        CASHFLOW_OWNER_OPERATIONS = 2,
        CASHFLOW_MERCHANT_HOUSEHOLD = 3,
        CASHFLOW_MERCHANT_BUSINESS = 4,
        CASHFLOW_TRANSFER = 5,
        CASHFLOW_HOUSEHOLD_CONSUMPTION = 6,
        CASHFLOW_PRODUCTION_INPUT = 7,
        CASHFLOW_OWNER_WAGES = 8,
        CASHFLOW_CONSTRUCTION = 9,
        CASHFLOW_MERCHANT_PROCUREMENT = 10,
        CASHFLOW_OTHER = 11,
        CASHFLOW_PRODUCER_SUPPORT = 12,
        CASHFLOW_INCOME_TAX = 13,
        CASHFLOW_CONSUMPTION_TAX = 14,
        CASHFLOW_BUSINESS_TAX = 15,
        CASHFLOW_INCOME_SUBSIDY = 16,
        CASHFLOW_CONSUMPTION_SUBSIDY = 17,
        CASHFLOW_BUSINESS_SUBSIDY = 18,
        CASHFLOW_FISCAL_ESCROW = 19,
        CASHFLOW_IMPORT_TAX = 20,
        CASHFLOW_EXPORT_TAX = 21,
        CASHFLOW_IMPORT_SUBSIDY = 22,
        CASHFLOW_EXPORT_SUBSIDY = 23,
    };

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
    };

    enum EventFlags : int32_t {
        EVENT_FLAG_DETAIL_PRESENT = 1 << 0,
        EVENT_FLAG_DETAIL_TRUNCATED = 1 << 1,
        EVENT_FLAG_TRADE_FOREIGN = 1 << 8,
        EVENT_FLAG_TRADE_RELIEF = 1 << 9,
        EVENT_FLAG_TRADE_IMPORT_SUBSIDY = 1 << 10,
        EVENT_FLAG_TRADE_EXPORT_SUBSIDY = 1 << 11,
        EVENT_FLAG_TRADE_IMPORT_TAX = 1 << 12,
        EVENT_FLAG_TRADE_EXPORT_TAX = 1 << 13,
    };

    enum EventField : int32_t {
        FIELD_COHORT_POPULATION = 1,
        FIELD_COHORT_FUNDS = 2,
        FIELD_COHORT_EPOCH_INCOME = 3,
        FIELD_COHORT_EPOCH_EXPENSE = 4,
        FIELD_COHORT_INCOME_EMA = 5,
        FIELD_COHORT_SATISFACTION = 6,
        FIELD_COHORT_WORST_NEED = 7,
        FIELD_COHORT_OWNER_EMPLOYED = 8,
        FIELD_COHORT_EMPLOYEE_EMPLOYED = 9,
        FIELD_COHORT_SIGNATURE = 10,
        FIELD_TREASURY_CASH = 11,
        FIELD_MARKET_STOCK = 12,
        FIELD_MARKET_PRICE = 13,
        FIELD_MARKET_DEMAND_EMA = 14,
        FIELD_MARKET_SHORTAGE = 15,
        FIELD_BUILDING_COUNT = 16,
        FIELD_BUILDING_OWNER_FILLED = 17,
        FIELD_BUILDING_EMPLOYEE_FILLED = 18,
        FIELD_BUILDING_CAPACITY = 19,
        FIELD_BUILDING_INPUT = 20,
        FIELD_BUILDING_OUTPUT = 21,
        FIELD_BUILDING_SOLD = 22,
        FIELD_BUILDING_DISCARDED = 23,
        FIELD_BUILDING_RESOURCE = 24,
        FIELD_BUILDING_RESOURCE_GENERATED = 25,
        FIELD_BUILDING_REVENUE = 26,
        FIELD_BUILDING_INPUT_COST = 27,
        FIELD_BUILDING_WAGES_PAID = 28,
        FIELD_RESOURCE_DELTA = 29,
        FIELD_COHORT_DEMOGRAPHY_RESIDUAL = 30,
        FIELD_BUILDING_WAGES_DUE = 31,
        FIELD_BUILDING_EXPECTED_REVENUE = 32,
        FIELD_BUILDING_OPERATING_COST = 33,
        FIELD_BUILDING_MARGIN_GAP = 34,
        FIELD_BUILDING_PLANNED_UTILIZATION = 35,
        FIELD_BUILDING_BASE_WAGES_PAID = 36,
        FIELD_BUILDING_BASE_WAGES_DUE = 37,
        FIELD_BUILDING_BONUS_PAID = 38,
        FIELD_BUILDING_BONUS_DUE = 39,
        FIELD_BUILDING_WAGE_SUSPENDED = 40,
        FIELD_TRADE_QUANTITY = 41,
        FIELD_TRADE_BASE_VALUE = 42,
        FIELD_TRADE_RETAIL_VALUE = 43,
        FIELD_TRADE_IMPORT_TRANSFER = 44,
        FIELD_TRADE_EXPORT_TRANSFER = 45,
    };

    enum EventSubjectKind : int32_t {
        SUBJECT_NONE = 0,
        SUBJECT_COHORT = 1,
        SUBJECT_MARKET = 2,
        SUBJECT_BUILDING_GROUP = 3,
        SUBJECT_COMMAND = 4,
        SUBJECT_TREASURY = 5,
        SUBJECT_RESOURCE = 6,
        SUBJECT_TRADE_ORDER = 7,
        SUBJECT_FAMILY_BRANCH = 8,
    };

    struct EventLeg {
        int32_t field = 0;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t key_id = -1;
        int64_t before = 0;
        int64_t after = 0;
    };

    struct EventRecord {
        int64_t event_id = 0;
        int32_t stage = 0;
        int32_t kind = 0;
        int32_t flags = 0;
        int32_t cell = -1;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t subject_i0 = -1;
        int32_t subject_i1 = -1;
        uint32_t leg_begin = 0;
        uint32_t leg_count = 0;
        int64_t value0 = 0;
        int64_t value1 = 0;
        int64_t value2 = 0;
        int64_t value3 = 0;
    };

    struct CashflowEntry {
        uint64_t cohort_handle = 0;
        int32_t source = CASHFLOW_OTHER;
        int64_t income = 0;
        int64_t expense = 0;
    };

    struct ConstructionCommandReceipt {
        int64_t receipt_id = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        int64_t settled_day = 0;
        uint64_t country_handle = 0;
        int32_t cell = -1;
        int32_t type_id = -1;
        bool ok = false;
        std::string code;
        int64_t cash_paid = 0;
        int64_t treasury_goods_used = 0;
        int64_t market_goods_used = 0;
    };

    enum CanalSourceKind : uint8_t {
        CANAL_SOURCE_NONE = 0,
        CANAL_SOURCE_SALINE = 1,
        CANAL_SOURCE_FRESHWATER = 2,
    };

    enum CanalProjectState : uint8_t {
        CANAL_PROJECT_BUILDING = 1,
        CANAL_PROJECT_AWAITING_EFFECT = 2,
        CANAL_PROJECT_COMPLETED = 3,
        CANAL_PROJECT_FAILED = 4,
    };

    struct CanalQuote {
        uint64_t token = 0;
        uint64_t country_handle = 0;
        int64_t snapshot_day = -1;
        uint64_t topology_hash = 0;
        uint64_t country_generation = 0;
        uint64_t price_hash = 0;
        uint8_t source_kind = CANAL_SOURCE_NONE;
        int32_t new_edge_count = 0;
        int32_t reused_edge_count = 0;
        int32_t construction_days = 0;
        int64_t cash_required = 0;
        std::array<int32_t, 2> material_good_ids{{-1, -1}};
        std::array<int64_t, 2> material_quantities{{0, 0}};
        std::vector<int32_t> route_cells;
        std::vector<int32_t> route_edge_dirs;
    };

    struct CanalProject {
        uint64_t handle = 0;
        uint32_t generation = 1;
        uint64_t country_handle = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        int64_t ready_day = 0;
        int64_t effect_transaction_id = 0;
        uint64_t topology_hash = 0;
        int64_t cash_paid = 0;
        int64_t treasury_goods_used = 0;
        int64_t market_goods_used = 0;
        uint8_t source_kind = CANAL_SOURCE_NONE;
        uint8_t state = CANAL_PROJECT_BUILDING;
        std::vector<int32_t> route_cells;
        std::vector<int32_t> route_edge_dirs;
    };

    struct CanalConstructionReceipt {
        int64_t receipt_id = 0;
        int64_t effective_day = 0;
        int64_t settled_day = 0;
        int64_t sequence = 0;
        uint64_t country_handle = 0;
        uint64_t project_handle = 0;
        bool ok = false;
        std::string code;
        int64_t cash_paid = 0;
        int64_t treasury_goods_used = 0;
        int64_t market_goods_used = 0;
    };

    enum TradeSignalDiagnosticReason : int32_t {
        TRADE_SIGNAL_DIAG_NONE = 0,
        TRADE_SIGNAL_DIAG_NO_SPREAD = 1,
        TRADE_SIGNAL_DIAG_MARGIN = 2,
        TRADE_SIGNAL_DIAG_ROUTE = 3,
        TRADE_SIGNAL_DIAG_STOCK = 4,
        TRADE_SIGNAL_DIAG_CAPACITY = 5,
        TRADE_SIGNAL_DIAG_CASH = 6,
        TRADE_SIGNAL_DIAG_ORDER_CAP = 7,
        TRADE_SIGNAL_DIAG_DISPATCHED = 8,
        TRADE_SIGNAL_DIAG_ARBITRATED_OUT = 9,
    };

    struct ProductionTraceDraft {
        int32_t kind = 0;
        int32_t stage = 0;
        int32_t cell = -1;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t subject_i0 = -1;
        int32_t subject_i1 = -1;
        int64_t value0 = 0;
        int64_t value1 = 0;
        int64_t value2 = 0;
        int64_t value3 = 0;
        int32_t flags = 0;
        std::vector<EventLeg> legs;
    };

    struct ProductionCashflowDraft {
        int32_t cell = -1;
        CashflowEntry entry;
    };

    struct ProductionResult {
        bool ok = true;
        std::string error;
        int64_t saturation_count = 0;
        int64_t processed_building_groups = 0;
        int64_t climate_profiled_building_groups = 0;
        int64_t climate_limited_building_groups = 0;
        int64_t climate_capacity_sum_q16 = 0;
        int64_t merchant_procurement_budget = 0;
        int64_t merchant_procurement_opportunity = 0;
        int64_t merchant_procurement_allocated = 0;
        int64_t merchant_procurement_unspent_allocated = 0;
        int64_t merchant_procurement_reserved = 0;
        int64_t merchant_procurement_spent = 0;
        int64_t merchant_procurement_retail_value = 0;
        int64_t merchant_procurement_factor_weighted_cash_q16 = 0;
        int64_t merchant_survival_procurement_required = 0;
        int64_t merchant_survival_procurement_allocated = 0;
        int64_t merchant_input_procurement_required = 0;
        int64_t merchant_input_procurement_allocated = 0;
        int64_t owner_working_capital_allocated = 0;
        int64_t working_capital_scale_error_bound_q16 = 0;
        int64_t building_resource_capacity_checks = 0;
        int64_t building_resource_limited_groups = 0;
        int64_t building_resource_capacity_limited_groups = 0;
        int64_t building_resource_generated = 0;
        int64_t building_resource_consumed = 0;
        int64_t production_inputs_consumed = 0;
        int64_t maintenance_goods_consumed = 0;
        int64_t maintenance_unmet = 0;
        int64_t maintenance_unpaid_value = 0;
        int64_t production_output_stock = 0;
        int64_t production_output_discarded = 0;
        int64_t production_output_supported = 0;
        int64_t producer_revenue = 0;
        int64_t producer_support_money_issued = 0;
        int64_t explicit_money_mint = 0;
        int64_t bullion_money_issued = 0;
        int64_t bullion_stock_consumed = 0;
        int64_t gold_accepted = 0;
        int64_t silver_accepted = 0;
        int64_t gold_money_issued = 0;
        int64_t silver_money_issued = 0;
        int64_t cycle_flow_produced = 0;
        int64_t cycle_flow_consumed = 0;
        int64_t cycle_flow_discarded = 0;
        int64_t building_wages_paid = 0;
        int64_t building_wages_unpaid = 0;
        int64_t building_base_wages_paid = 0;
        int64_t building_base_wages_due = 0;
        int64_t building_bonus_paid = 0;
        int64_t building_bonus_due = 0;
        int64_t wage_suspended_building_groups = 0;
        int64_t desired_business_demand = 0;
        int64_t funded_business_demand = 0;
        int64_t unfunded_business_demand = 0;
        int64_t market_signal_updates = 0;
        int64_t merchant_credit_committed = 0;
        int64_t merchant_credit_drawn = 0;
        int64_t merchant_credit_repaid = 0;
        int64_t merchant_credit_premium_repaid = 0;
        double market_signal_ms = 0.0;
        std::vector<size_t> resource_touched_lanes;
        std::vector<OwnerRetainedOutput> retained_outputs;
        std::vector<ProductionTraceDraft> trace_drafts;
        std::vector<ProductionCashflowDraft> cashflow_drafts;
        // Worker-local audit lanes, registered on the joining thread.
        std::vector<size_t> audit_population_lanes;
        std::vector<size_t> audit_market_lanes;
        // Worker-local occupancy introductions. The shared
        // `_bio_introduce_keys` set must not be mutated from production
        // workers; merge_building_production_result commits these in cell order.
        std::vector<int32_t> bio_introduce_cells;
        std::vector<int32_t> bio_introduce_bits;
        int64_t allocation_growth_count = 0;
        int64_t allocation_growth_bytes = 0;

        void reset();
        int64_t capacity_bytes() const;
    };

    struct BuildingPlanResult {
        bool ok = true;
        std::string error;
        int64_t saturation_count = 0;
        int64_t merchant_credit_budget = 0;
        int64_t merchant_credit_committed = 0;
        int64_t recovery_candidates = 0;
        int64_t recovery_approved = 0;
        int64_t loss_suspended_building_groups = 0;
        int64_t unprofitable_building_groups = 0;
        int64_t utilization_sum_q16 = 0;
        double worker_ms = 0.0;

        void reset() {
            *this = {};
        }
    };

    struct CompletedEpochPerf {
        bool valid = false;
        int64_t epoch_id = -1;
        int64_t sample_day = -1;
        int64_t continuation_slices = 0;
        int32_t market_worker_tasks_max = 1;
        int64_t market_worker_task_sum = 0;
        int64_t market_worker_dispatches = 0;
        int64_t market_worker_parallel_dispatches = 0;
        int32_t production_worker_tasks_max = 1;
        int64_t production_worker_task_sum = 0;
        int64_t production_worker_dispatches = 0;
        int64_t production_worker_parallel_dispatches = 0;
        int64_t production_worker_weight_total = 0;
        int64_t production_worker_task_weight_min = 0;
        int64_t production_worker_task_weight_max = 0;
        int64_t production_worker_imbalance_q16_max = 0;
        double production_worker_cpu_ms = 0.0;
        int32_t audit_worker_tasks_max = 1;
        int64_t audit_worker_dispatches = 0;
        double audit_worker_cpu_ms = 0.0;
        int32_t building_plan_worker_tasks_max = 1;
        int64_t building_plan_worker_parallel_dispatches = 0;
        double building_plan_worker_cpu_ms = 0.0;
        int64_t opening_audit_fast_paths = 0;
        int64_t opening_audit_full_verifications = 0;
        int64_t closing_audit_fast_paths = 0;
        int64_t closing_audit_full_verifications = 0;
        int64_t closing_audit_mismatches = 0;
        std::string closing_audit_mismatch_ledger = "none";
        int64_t closing_audit_mismatch_lane = -1;
        int64_t closing_audit_population_touched_lanes = 0;
        int64_t closing_audit_market_touched_lanes = 0;
        int64_t closing_audit_population_full_scan_entries = 0;
        int64_t closing_audit_market_full_scan_entries = 0;
        int64_t investment_scheduled_review_cells = 0;
        int64_t investment_review_cells = 0;
        int64_t investment_type_evaluations = 0;
        int64_t investment_market_signal_rejections = 0;
        int64_t investment_ethnicity_evaluations = 0;
        int64_t investment_sparse_considered_types = 0;
        int64_t investment_sparse_selected_types = 0;
        int64_t investment_sparse_skipped_types = 0;
        int64_t investment_sparse_mismatches = 0;
        int64_t investment_sparse_dense_fallbacks = 0;
        int64_t startup_demand_seed_count = 0;
        int64_t startup_demand_touched_lanes = 0;
        int64_t startup_demand_catalog_edges = 0;
        int64_t startup_demand_cycle_skips = 0;
        int64_t startup_demand_remote_lanes = 0;
        int64_t startup_demand_matched_review_cells = 0;
        int64_t startup_demand_buildings_started = 0;
        int64_t startup_demand_scratch_bytes = 0;
        int64_t investment_displacement_type_evaluations = 0;
        int64_t building_investment_displacement_starts = 0;
        int64_t approximation_decisions = 0;
        int64_t approximation_exact_probes = 0;
        int64_t approximation_certificate_failures = 0;
        int64_t approximation_exact_fallbacks = 0;
        int64_t approximation_frontier_candidates = 0;
        int64_t approximation_frontier_pruned = 0;
        int64_t approximation_max_observed_regret_q16 = 0;
        int64_t approximation_probe_violations = 0;
        int64_t approximation_probe_max_spend_error_q16 = 0;
        int64_t approximation_probe_max_demand_error_q16 = 0;
        int32_t approximation_cooldown_epochs_left = 0;
        int32_t high_speed_batch_multiplier = 1;
        int64_t high_speed_market_dispatches_saved = 0;
        int64_t high_speed_production_dispatches_saved = 0;
        int64_t budgeted_building_commit_phase_fusions = 0;
        int64_t budgeted_publish_phase_fusions = 0;
        double building_plan_ms = 0.0;
        double building_plan_evaluate_ms = 0.0;
        double building_plan_reserve_ms = 0.0;
        double building_employment_ms = 0.0;
        double building_production_ms = 0.0;
        double building_production_worker_ms = 0.0;
        double building_production_merge_ms = 0.0;
        double household_market_worker_ms = 0.0;
        double household_market_prepare_ms = 0.0;
        double household_market_merge_ms = 0.0;
        double household_market_merge_aggregate_ms = 0.0;
        double household_market_merge_trade_ms = 0.0;
        int64_t prepare_reuse_count = 0;
        int64_t workset_cells_planned = 0;
        int64_t workset_cells_executed = 0;
        int64_t duplicate_range_count = 0;
        double building_investment_ms = 0.0;
        double investment_evaluate_ms = 0.0;
        double investment_allocate_ms = 0.0;
        double investment_prepare_lanes_ms = 0.0;
        double investment_prepare_pending_ms = 0.0;
        double investment_prepare_groups_ms = 0.0;
        double startup_demand_prepare_ms = 0.0;
        double finalize_construction_ms = 0.0;
        double finalize_reconcile_ms = 0.0;
        double building_factor_refresh_ms = 0.0;
        double building_role_storage_ms = 0.0;
        int64_t building_factor_cache_hits = 0;
        int64_t building_factor_cache_misses = 0;
        int64_t building_factor_miss_modver = 0;
        int64_t building_factor_miss_country = 0;
        int64_t building_factor_miss_sector = 0;
        int64_t building_factor_miss_research = 0;
        int64_t building_factor_miss_identity = 0;
        double aggregate_publish_ms = 0.0;
        double aggregate_audit_ms = 0.0;
        int64_t market_result_allocation_growth_count = 0;
        int64_t market_result_allocation_growth_bytes = 0;
        int64_t production_result_allocation_growth_count = 0;
        int64_t production_result_allocation_growth_bytes = 0;
        int64_t building_structure_count_only_updates = 0;
        int64_t building_structure_new_groups = 0;
        int64_t building_structure_removed_groups = 0;
        int64_t building_structure_topology_rebuilds = 0;
        int64_t building_structure_role_span_reuses = 0;
        int64_t building_structure_role_span_appends = 0;
        double building_structure_group_merge_ms = 0.0;
        double building_structure_market_cache_ms = 0.0;
        double building_structure_labor_cache_ms = 0.0;
    };

    struct EventBatch {
        int64_t epoch_id = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int32_t period_days = 1;
        int64_t first_event_id = 0;
        int64_t last_event_id = 0;
        uint64_t stream_hash = 1469598103934665603ULL;
        std::vector<EventRecord> events;
        std::vector<EventLeg> legs;
        int32_t cashflow_cell = -1;
        bool cashflow_complete = false;
        std::vector<CashflowEntry> cashflows;
        std::vector<CohortWelfareEntry> welfare_entries;
        int64_t bytes() const {
            int64_t welfare_bytes = 0;
            for (const CohortWelfareEntry &entry : welfare_entries) {
                welfare_bytes += static_cast<int64_t>(
                    entry.need_ids.capacity() * sizeof(int32_t) +
                    entry.need_satisfaction_q16.capacity() * sizeof(int32_t) +
                    entry.need_weight_q16.capacity() * sizeof(int32_t) +
                    entry.need_tiers.capacity() * sizeof(int32_t) +
                    entry.previous_demand_per_capita_daily.capacity() * sizeof(int64_t) +
                    entry.wealth_demand_delta_per_capita_daily.capacity() * sizeof(int64_t) +
                    entry.price_demand_delta_per_capita_daily.capacity() * sizeof(int64_t));
            }
            return static_cast<int64_t>(events.capacity() * sizeof(EventRecord) +
                                        legs.capacity() * sizeof(EventLeg) +
                                        cashflows.capacity() * sizeof(CashflowEntry) +
                                        welfare_entries.capacity() * sizeof(CohortWelfareEntry)) +
                   welfare_bytes;
        }
    };

    struct AuditFrame {
        int64_t epoch_id = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int64_t event_count = 0;
        int64_t leg_count = 0;
        int64_t population_error = 0;
        int64_t money_error = 0;
        int64_t goods_error = 0;
        uint64_t stream_hash = 1469598103934665603ULL;
    };

    struct SaveState {
        bool active = false;
        int32_t chunk_bytes = 4 * 1024 * 1024;
        int32_t section = 0;
        int32_t page_cursor = 0;
        int32_t market_cursor = 0;
        int32_t cell_cursor = 0;
        int32_t command_cursor = 0;
        int32_t building_cursor = 0;
        int32_t construction_cursor = 0;
        int32_t audit_cursor = 0;
        int32_t signal_cursor = 0;
        int32_t labor_signal_cursor = 0;
        int32_t trade_order_cursor = 0;
        int32_t trade_flow_cursor = 0;
        int32_t fiscal_cursor = 0;
        int32_t settlement_cursor = 0;
        int32_t family_cursor = 0;
        int32_t family_membership_cursor = 0;
        int32_t family_ownership_cursor = 0;
        int32_t person_cursor = 0;
        int32_t person_need_cursor = 0;
        int32_t family_trait_cursor = 0;
        int32_t family_influence_cursor = 0;
        int32_t family_trait_command_cursor = 0;
        int32_t family_expedition_cursor = 0;
        int32_t tariff_history_cursor = 0;
        int32_t country_good_cursor = 0;
        int32_t country_partner_cursor = 0;
        int32_t canal_quote_cursor = 0;
        int32_t canal_project_cursor = 0;
        std::vector<uint8_t> modifier_bytes;
        size_t modifier_cursor = 0;
        bool end_emitted = false;
    };

    struct RestoreState {
        bool active = false;
        bool header_seen = false;
        bool end_seen = false;
        bool failed = false;
        std::string error;
        int32_t expected_pages = 0;
        int32_t expected_commands = 0;
        int32_t expected_buildings = 0;
        int32_t expected_construction = 0;
        int32_t restored_pages = 0;
        int32_t restored_markets = 0;
        int32_t restored_cells = 0;
        int32_t restored_commands = 0;
        int32_t schema_version = 0;
        int32_t restored_buildings = 0;
        int32_t restored_construction = 0;
        int32_t expected_audits = 0;
        int32_t restored_audits = 0;
        int32_t expected_signals = 0;
        int32_t restored_signals = 0;
        int32_t expected_labor_signals = 0;
        int32_t restored_labor_signals = 0;
        int32_t expected_trade_orders = 0;
        int32_t restored_trade_orders = 0;
        int32_t expected_trade_flows = 0;
        int32_t restored_trade_flows = 0;
        int32_t expected_tariff_history = 0;
        int32_t restored_tariff_history = 0;
        int32_t expected_country_good = 0;
        int32_t restored_country_good = 0;
        int32_t expected_country_partner = 0;
        int32_t restored_country_partner = 0;
        int32_t expected_canal_quotes = 0;
        int32_t restored_canal_quotes = 0;
        int32_t expected_canal_projects = 0;
        int32_t restored_canal_projects = 0;
        int32_t expected_persons = 0;
        int32_t expected_person_needs = 0;
        int32_t restored_fiscal = 0;
        int32_t last_signal_cell = -1;
        int32_t last_signal_good = -1;
        int32_t last_labor_cell = -1;
        int32_t last_labor_profession = -1;
        std::vector<uint8_t> modifier_bytes;
        bool modifier_seen = false;
        bool fiscal_seen = false;
        bool settlement_names_seen = false;
        int32_t restored_families = 0;
        int32_t restored_family_memberships = 0;
        int32_t restored_family_ownerships = 0;
        bool family_records_seen = false;
        bool family_membership_seen = false;
        bool family_ownership_seen = false;
        int32_t restored_persons = 0;
        int32_t restored_person_needs = 0;
        bool person_records_seen = false;
        bool person_needs_seen = false;
        int32_t restored_family_traits = 0;
        int32_t restored_family_influences = 0;
        int32_t restored_family_trait_commands = 0;
        int32_t expected_family_traits = 0;
        int32_t expected_family_influences = 0;
        int32_t expected_family_trait_commands = 0;
        bool family_traits_seen = false;
        bool family_influences_seen = false;
        bool family_trait_commands_seen = false;
        int32_t expected_family_expedition_slots = 0;
        int32_t expected_family_expeditions = 0;
        int32_t restored_family_expedition_slots = 0;
        int32_t restored_family_expeditions = 0;
        bool family_expeditions_seen = false;
        bool tariff_history_seen = false;
        bool country_good_seen = false;
        bool country_partner_seen = false;
        bool canal_quotes_seen = false;
        bool canal_projects_seen = false;
    };

    struct EventArchiveState {
        bool active = false;
        bool header_emitted = false;
        bool end_emitted = false;
        int32_t chunk_bytes = 4 * 1024 * 1024;
        size_t batch_limit = 0;
        size_t batch_cursor = 0;
        size_t event_cursor = 0;
    };

    bool _configured = false;
    bool _bootstrapped = false;
    bool _epoch_active = false;
    bool _fatal = false;
    std::string _fatal_reason;
    Stage _stage = Stage::IDLE;
    Stage _executed_stage = Stage::IDLE;
    std::string _executed_substage;
    PublishPhase _publish_phase = PublishPhase::PREPARE;
    size_t _publish_cursor = 0;
    int32_t _publish_order_cursor = 0;
    int32_t _publish_line_cursor = 0;
    int64_t _publish_valuation_sat = 0;
    int64_t _publish_trade_alpha = 0;
    bool _publish_have_populated = false;
    TradePlanInitState _trade_plan_init;

    int32_t _cell_count = 0;
    int32_t _cells_per_slice = 256;
    bool _auto_slice_by_scale = true;
    int32_t _building_cells_per_slice = AUTO_BUILDING_CELLS_PER_SLICE;
    int32_t _building_groups_per_slice = 512;
    int32_t _building_plan_cells_per_slice_override = 0;
    int32_t _household_post_building_cells_per_slice_override = 0;
    int32_t _investment_cells_per_slice =
        AUTO_INVESTMENT_CELLS_PER_SLICE;
    int32_t _building_finalize_cells_per_slice =
        AUTO_BUILDING_FINALIZE_CELLS_PER_SLICE;
    int32_t _building_output_efficiency_q16 = Q16_ONE;
    bool _auto_building_slice_by_scale = true;
    int32_t _commands_per_slice = 16384;
    int32_t _epoch_days = 1;
    int32_t _configured_epoch_days = MARKET_CYCLE_MAX_DAYS;
    int32_t _min_epoch_days = MARKET_CYCLE_MIN_DAYS;
    int32_t _max_epoch_days = MARKET_CYCLE_MAX_DAYS;
    int32_t _locked_market_cycle_days = MARKET_CYCLE_MIN_DAYS;
    int64_t _market_cycle_start_day = 0;
    int32_t _locked_slow_cycle_days = PLAN_CYCLE_MIN_DAYS;
    int64_t _slow_cycle_start_day = 0;
    int32_t _locked_investment_cycle_days = INVEST_CYCLE_MIN_DAYS;
    int64_t _investment_cycle_start_day = 0;
    int32_t _slow_cycle_min_days = PLAN_CYCLE_MIN_DAYS;
    int32_t _slow_cycle_max_days = PLAN_CYCLE_MAX_DAYS;
    int32_t _invest_cycle_min_days = INVEST_CYCLE_MIN_DAYS;
    int32_t _invest_cycle_max_days = INVEST_CYCLE_MAX_DAYS;
    bool _cadence_initialized = false;
    double _cadence_target_ms = 8.0;
    double _injected_cycle_market_ms = -1.0;
    double _injected_cycle_slow_ms = -1.0;
    double _injected_cycle_investment_ms = -1.0;
    int32_t _forced_market_cycle_days = 0;
    int32_t _forced_slow_cycle_days = 0;
    int32_t _forced_investment_cycle_days = 0;
    double _market_ms_per_knife_ema = 0.0;
    double _slow_ms_per_knife_ema = 0.0;
    double _investment_ms_per_knife_ema = 0.0;
    double _cycle_market_ms_accum = 0.0;
    double _cycle_slow_ms_accum = 0.0;
    double _cycle_investment_ms_accum = 0.0;
    int32_t _estimated_populated_market_knives = 1;
    int32_t _estimated_slow_knives = 1;
    int32_t _estimated_investment_knives = 1;
    int32_t _cadence_machine_knives_per_day = 64;
    int32_t _cadence_slow_knives_per_day = 64;
    int32_t _cadence_investment_knives_per_day = 64;
    int32_t _cadence_change_reason = 1;
    int32_t _estimated_market_slices_per_epoch = 1;
    int32_t _estimated_building_slices_per_epoch = 0;
    int32_t _estimated_total_slices_per_epoch = 1;
    bool _workload_deadline_feasible = true;
    bool _workload_cycle_clamped = false;
    int64_t _configured_target_cohorts_per_slice = 0;
    int64_t _target_cohorts_per_slice = 30000;
    int32_t _commit_lag_budget_days = 0;
    int32_t _max_rules_per_plan = MAX_RULES_PER_PLAN;
    int64_t _wealth_reference_per_capita = MONEY_SCALE * 10;
    int32_t _living_cost_base_plan_id = -1;
    std::string _living_cost_base_plan_stable_id = "survival_household";
    std::vector<int32_t> _survival_food_need_stable_ids;
    std::vector<uint8_t> _survival_food_need_mask;
    std::vector<int32_t> _survival_required_need_indices;
    std::vector<uint8_t> _survival_food_good_mask;
    std::vector<uint8_t> _survival_clothing_good_mask;
    int32_t _survival_clothing_need_stable_id = -1;
    int32_t _starvation_satisfaction_threshold_q16 = Q16_ONE / 2;
    int32_t _survival_production_target_q16 = Q16_ONE;
    int64_t _starvation_death_rate_q32 = Q32_ONE / 200;
    // Composite satisfaction tuning. Weights are authored per profession; these
    // are the profile-wide fallbacks and the shared normalization references.
    std::array<int32_t, SAT_DIM_COUNT> _satisfaction_default_weights_q16 = {
        65536, 45875, 26214, 13107, 19661, 19661, 16384, 13107};
    int32_t _satisfaction_subsistence_gate_slack_q16 = 6554;
    int32_t _satisfaction_income_growth_floor_q16 = 58982;
    int32_t _satisfaction_income_growth_ceiling_q16 = 78643;
    int32_t _satisfaction_income_baseline_alpha_q16 = 1024;
    int64_t _satisfaction_savings_target_months_q16 = 393216;
    int32_t _satisfaction_tax_tolerance_q16 = 22938;
    std::array<int32_t, SAT_DEVELOPMENT_INPUT_COUNT>
        _satisfaction_development_weights_q16 = {26214, 26214, 13107};
    int32_t _satisfaction_development_variety_target = 12;
    int32_t _satisfaction_birth_reference_q16 = 45875;
    int64_t _carrying_k_habitat_ref = 40;
    int64_t _carrying_k_floor = 8;
    int32_t _carrying_river_bonus_q16 = 72090;
    int32_t _carrying_water_habitability_q16 = 49152;
    int32_t _carrying_surplus_elasticity_q16 = Q16_ONE / 2;
    int32_t _carrying_sat_elasticity_q16 = 22938;
    int32_t _carrying_soft_start_q16 = 45875;
    int32_t _carrying_surplus_floor_q16 = 16384;
    int32_t _carrying_surplus_cap_q16 = 98304;
    int32_t _carrying_sat_floor_q16 = 8192;
    int32_t _carrying_sat_cap_q16 = Q16_ONE;
    int32_t _carrying_residual_floor_q16 = Q16_ONE / 2;
    int32_t _carrying_residual_cap_q16 = Q16_ONE * 2;
    int32_t _carrying_support_ema_alpha_q16 = 1024;
    int32_t _carrying_temp_opt_lo_q16 = 19661;
    int32_t _carrying_temp_opt_hi_q16 = 45875;
    int32_t _carrying_paw_opt_lo_q16 = 16384;
    int32_t _carrying_paw_opt_hi_q16 = 58982;
    std::vector<int32_t> _carrying_family_weight;
    std::vector<std::string> _carrying_profile_class_ids;
    std::vector<int32_t> _carrying_profile_class_weight_q16;
    std::vector<int32_t> _carrying_class_weight_q16;
    std::vector<int32_t> _carrying_landform_habitability_q16;
    std::vector<int32_t> _carrying_vegetation_habitability_q16;
    std::array<int32_t, SAT_PRESSURE_LEVEL_COUNT - 1>
        _satisfaction_pressure_thresholds_q16 = {13107, 26214, 39322, 52429};
    int32_t _wage_ema_alpha_q16 = 8192;
    int32_t _wage_max_rise_q16_per_day = 1311;
    int32_t _wage_max_fall_q16_per_day = 1311;
    // Damping: contract wage floor may not exceed the building's per-employee
    // affordable revenue times this ratio (Q16). Prevents living-cost floor from
    // pushing wages far beyond what the employer can pay. 0 disables the cap.
    int32_t _wage_income_cap_ratio_q16 = 78643; // ~1.2x
    int32_t _employee_profit_share_q16 = 16384;
    int32_t _building_severe_loss_threshold_q16 = -16384;
    int32_t _building_severe_loss_cycles = 3;
    int32_t _building_restart_margin_q16 = 6554;
    int32_t _building_restart_cycles = 2;
    int32_t _merchant_procurement_cash_reserve_q16 = 8192;
    int32_t _merchant_market_making_days_q16 = Q16_ONE * 60;
    int32_t _merchant_credit_runtime_mode = 2; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int32_t _merchant_credit_exposure_q16 = 16384;
    int32_t _merchant_credit_premium_q16 = 3277;
    int32_t _merchant_credit_term_cycles = 6;
    int32_t _recovery_success_cycles = 2;
    // 73 five-day reviews are approximately one year. The old recovery name
    // is retained only for save/profile compatibility.
    int32_t _recovery_liquidation_failed_reviews = 73;
    int32_t _maintenance_horizon_days_by_sector[5] = {5475, 2920, 3650, 2190, 7300};
    int32_t _building_maintenance_cost_factor_q16 = Q16_ONE;
    int32_t _merchant_profession_id = -1;
    std::string _merchant_profession_stable_id = "merchant";
    // Reserved profession representing unemployed population. Resolved from the
    // catalog like the merchant profession; used by the employment pass to keep
    // laid-off / idle population in dedicated unemployed signatures instead of
    // deriving unemployment as population - owner - employee. Never a building role.
    int32_t _unemployed_profession_id = -1;
    std::string _unemployed_profession_stable_id = "unemployed";
    int32_t _market_runtime_mode = 1; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int32_t _trade_runtime_mode = 2; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int32_t _startup_demand_runtime_mode = 1; // 0=OFF, 1=ACTIVE.
    int64_t _trade_capacity_per_merchant_q16 = 64 * Q16_ONE;
    int32_t _trade_speed_cost_per_day = 4;
    int32_t _trade_min_margin_q16 = 3277;
    int32_t _trade_target_count = 4;
    int32_t _trade_signal_pairs_per_slice = 4096;
    int32_t _trade_route_searches_per_slice = 32;
    int32_t _trade_max_route_expansions = 8192;
    int32_t _trade_route_cache_entries = 16384;
    int32_t _trade_max_signals = 32768;
    int32_t _trade_max_candidates = 8192;
    int32_t _trade_max_orders = 4096;
    int32_t _trade_flow_ema_alpha_q16 = 8192;
    int32_t _trade_max_stock_share_q16 = 16384;
    int32_t _trade_export_floor_days = 5;
    int32_t _trade_export_inventory_fraction_q16 = Q16_ONE / 2;
    int32_t _trade_import_fill_fraction_q16 = Q16_ONE / 2;
    int32_t _trade_response_days = 15;
    int32_t _investment_review_days = 30;
    // Locked slow-cycle length S. Plan evaluation and investment review share
    // this value. Profile 10/30 are range hints and v37 restore compatibility,
    // not a fixed production cadence.
    int32_t _building_plan_days = 10;
    int32_t _investment_min_shortage_q16 = Q16_ONE / 8;
    int32_t _investment_min_utilization_q16 = 42598;
    int32_t _investment_max_payback_days = 365;
    int32_t _investment_operating_cycles = 2;
    int32_t _investment_gap_fill_share_q16 = Q16_ONE / 4;
    int32_t _investment_portfolio_max_types = 4;
    int32_t _investment_max_type_owner_share_q16 = Q16_ONE / 2;
    int32_t _investment_max_growth_share_q16 = 16384;
    int32_t _investment_new_type_seed_buildings = 1;
    int32_t _investment_displacement_min_advantage_q16 = Q16_ONE / 16;
    int32_t _investment_merchant_transition_min_improvement_q16 = Q16_ONE / 2;
    int32_t _investment_sparse_mode = 2;
    int32_t _recovery_liquidation_max_share_q16 = Q16_ONE / 4;
    int32_t _resource_min_reserve_q16 = 22938;
    int32_t _resource_safe_harvest_q16 = Q16_ONE / 2;
    int32_t _resource_min_horizon_days = 3650;
    int32_t _bullion_monthly_issue_cap_q16 = 655;
    int32_t _producer_support_monthly_cap_q16 = 3277;
    bool _worker_enabled = true;
    int32_t _worker_market_threshold = 256;
    int32_t _worker_tasks_hint = 0;
    int32_t _worker_task_cap = 6;
    bool _high_speed_batching_enabled = true;
    int32_t _full_audit_verify_interval_days = 25;
    // Closing audit mode: 0=FULL, 1=PROBE, 2=INCREMENTAL.
    int32_t _closing_audit_mode = 2;
    bool _closing_audit_runtime_disabled = false;
    bool _closing_audit_force_full = true;
    bool _closing_audit_incremental_this_epoch = false;
    // Accuracy policy: 0=EXACT, 1=BALANCED, 2=FAST, 3=CUSTOM.
    // Runtime mode: 0=OFF, 1=PROBE (exact authority), 2=ACTIVE.
    int32_t _accuracy_preset = 1;
    int32_t _approximation_runtime_mode = 2;
    int32_t _accuracy_max_regret_q16 = 1966;
    int32_t _accuracy_household_tail_share_q16 = 655;
    int32_t _accuracy_candidate_top_k = 2;
    int32_t _accuracy_choice_temperature_q16 = 983;
    int32_t _accuracy_exact_probe_rate_q16 = 655;
    int32_t _accuracy_fallback_cooldown_epochs = 10;
    int64_t _seed = 0;
    int64_t _catalog_hash = 0;
    int64_t _catalog_compat_hash_v6 = 0;
    int64_t _epoch_id = 0;
    int64_t _sample_day = -1;
    int64_t _current_day = -1;
    int64_t _commit_day = -1;
    int64_t _last_committed_day = -1;
    int64_t _explicit_money_mint = 0;
    int64_t _explicit_money_burn = 0;
    int64_t _external_population_delta = 0;
    int64_t _explicit_stock_delta = 0;
    int64_t _country_research_consumed_opening = 0;
    int64_t _country_research_goods_consumed = 0;
    int64_t _consumed_goods = 0;
    int64_t _births = 0;
    int64_t _deaths = 0;
    int64_t _saturation_count = 0;
    uint64_t _next_submit_order = 1;

    int32_t _cell_cursor = 0;
    int32_t _command_cursor = 0;
    int32_t _structural_cursor = 0;
    int32_t _building_cell_cursor = 0;
    // Cursor over _epoch_plan_cells for the BUILDING_PLAN evaluate phase.
    // Reserve still walks the full _epoch_building_cells via
    // _building_cell_cursor so production always sees a coherent (possibly
    // stale up to _building_plan_days) per-group plan snapshot.
    int32_t _plan_evaluate_cursor = 0;
    int32_t _building_plan_phase = 0;
    int32_t _household_market_phase = 0;
    int32_t _household_post_cursor = 0;
    int32_t _building_commit_phase = 0;
    int32_t _building_commit_cursor = 0;
    int32_t _building_finalize_phase = 0;
    int32_t _family_commit_cursor = 0;
    int32_t _family_commit_phase = 0;
    int32_t _person_commit_cursor = 0;
    int32_t _person_commit_phase = 0;
    int32_t _processed_cells = 0;
    int64_t _processed_cohorts = 0;
    int64_t _processed_rules = 0;
    int64_t _processed_needs = 0;
    int64_t _processed_variants = 0;
    int64_t _processed_components = 0;
    int64_t _processed_commands = 0;
    int64_t _rejected_commands = 0;
    int64_t _merchant_repairs = 0;
    int64_t _price_cap_hits = 0;
    int64_t _price_cost_anchor_hits = 0;
    int64_t _price_inactive_reversions = 0;
    int64_t _continuation_slices = 0;
    int64_t _processed_building_groups = 0;
    int64_t _climate_profiled_building_groups = 0;
    int64_t _climate_limited_building_groups = 0;
    int64_t _climate_capacity_sum_q16 = 0;
    int64_t _filled_owner_jobs = 0;
    int64_t _filled_employee_jobs = 0;
    int64_t _unemployed_population = 0;
    int64_t _families_formed = 0;
    int64_t _families_dissolved = 0;
    int64_t _family_membership_edges_processed = 0;
    int64_t _family_ownership_edges_processed = 0;
    int64_t _family_owner_jobs_filled = 0;
    int64_t _family_owner_jobs_vacant = 0;
    int64_t _persons_promoted = 0;
    int64_t _persons_died = 0;
    int64_t _persons_migrated = 0;
    int64_t _person_jobs_bound = 0;
    int64_t _person_need_edges_processed = 0;
    int64_t _construction_goods_consumed = 0;
    int64_t _building_structure_count_only_updates = 0;
    int64_t _building_structure_new_groups = 0;
    int64_t _building_structure_removed_groups = 0;
    int64_t _building_structure_topology_rebuilds = 0;
    int64_t _building_structure_role_span_reuses = 0;
    int64_t _building_structure_role_span_appends = 0;
    int64_t _building_investment_candidates = 0;
    int64_t _building_owner_mobility = 0;
    int64_t _building_owner_job_reallocations = 0;
    int64_t _building_owner_job_profession_changes = 0;
    int64_t _building_owner_job_probability_skips = 0;
    int64_t _building_employee_to_owner_reallocations = 0;
    int64_t _building_investments_started = 0;
    int64_t _building_investment_blocked_funds = 0;
    int64_t _building_investment_blocked_materials = 0;
    int64_t _building_investment_blocked_sponsor_capital = 0;
    int64_t _building_investment_blocked_resources = 0;
    int64_t _building_investment_probability_skips = 0;
    int64_t _building_investment_capital_transferred = 0;
    int64_t _building_investment_buildings_started = 0;
    int64_t _building_investment_portfolios_started = 0;
    int64_t _building_investment_types_started = 0;
    int64_t _building_investment_owner_population_moved = 0;
    int64_t _building_investment_max_type_owner_share_q16 = 0;
    int64_t _building_investment_demand_limited = 0;
    int64_t _building_investment_material_limited = 0;
    int64_t _building_investment_capital_limited = 0;
    int64_t _building_investment_owner_population_limited = 0;
    int64_t _building_investment_jobs_started = 0;
    int64_t _building_investment_employment_gap = 0;
    int64_t _building_investment_employment_catchup_cells = 0;
    int64_t _building_investment_displacement_starts = 0;
    int64_t _desired_business_demand = 0;
    int64_t _funded_business_demand = 0;
    int64_t _unfunded_business_demand = 0;
    int64_t _owner_working_capital_allocated = 0;
    int64_t _merchant_credit_budget = 0;
    int64_t _merchant_credit_committed = 0;
    int64_t _merchant_credit_drawn = 0;
    int64_t _merchant_credit_repaid = 0;
    int64_t _merchant_credit_premium_repaid = 0;
    int64_t _merchant_credit_outstanding = 0;
    int64_t _merchant_credit_bad_debt = 0;
    int64_t _recovery_candidates = 0;
    int64_t _recovery_approved = 0;
    int64_t _recovery_restarted = 0;
    int64_t _recovery_failed = 0;
    int64_t _recovery_liquidated_buildings = 0;
    int64_t _recovery_partially_liquidated_buildings = 0;
    int64_t _recovery_fully_liquidated_groups = 0;
    int64_t _working_capital_scale_error_bound_q16 = 0;
    int64_t _production_inputs_consumed = 0;
    int64_t _production_output_stock = 0;
    int64_t _production_output_discarded = 0;
    int64_t _production_output_retained = 0;
    int64_t _production_output_supported = 0;
    int64_t _owner_output_consumed = 0;
    int64_t _producer_revenue = 0;
	int64_t _producer_support_money_issued = 0;
	int64_t _bullion_money_issued = 0;
	// Bullion (gold/silver) physically absorbed by the mint each epoch. The
	// monetary system consumes the sold batch: the coined goods leave market
	// stock instead of accumulating as ghost inventory. Tracked as an explicit
	// goods-conservation sink so closing stock stays balanced.
	int64_t _bullion_stock_consumed = 0;
	int64_t _gold_accepted = 0;
	int64_t _silver_accepted = 0;
	int64_t _gold_money_issued = 0;
	int64_t _silver_money_issued = 0;
	int64_t _cycle_flow_produced = 0;
	int64_t _cycle_flow_consumed = 0;
	int64_t _cycle_flow_discarded = 0;
    int64_t _building_wages_paid = 0;
    int64_t _building_wages_unpaid = 0;
    int64_t _building_base_wages_paid = 0;
    int64_t _building_base_wages_due = 0;
    int64_t _building_bonus_paid = 0;
    int64_t _building_bonus_due = 0;
    int64_t _wage_suspended_building_groups = 0;
    int64_t _loss_suspended_building_groups = 0;
    int64_t _merchant_procurement_budget = 0;
    int64_t _merchant_procurement_opportunity = 0;
    int64_t _merchant_procurement_allocated = 0;
    int64_t _merchant_procurement_unspent_allocated = 0;
    int64_t _merchant_procurement_reserved = 0;
    int64_t _owner_working_capital_reserved = 0;
    int64_t _merchant_procurement_spent = 0;
    int64_t _merchant_procurement_retail_value = 0;
    int64_t _merchant_procurement_factor_weighted_cash_q16 = 0;
    int64_t _merchant_survival_procurement_required = 0;
    int64_t _merchant_survival_procurement_allocated = 0;
    int64_t _merchant_input_procurement_required = 0;
    int64_t _merchant_input_procurement_allocated = 0;
    int64_t _merchant_trade_purchase_cash = 0;
    int64_t _merchant_trade_sale_cash = 0;
    int64_t _government_research_procured_points = 0;
    int64_t _government_research_procurement_cash = 0;
    int64_t _government_research_procurement_orders = 0;
    std::vector<int64_t> _merchant_procurement_paid_by_cell;
    std::vector<int64_t> _merchant_procurement_retail_by_cell;
    std::vector<int64_t> _merchant_procurement_factor_weighted_cash_by_cell;
    std::vector<int64_t> _merchant_trade_purchase_by_cell;
    std::vector<int64_t> _merchant_trade_sale_by_cell;
    std::vector<int64_t> _merchant_credit_drawn_by_cell;
    int64_t _production_input_reserved = 0;
    int64_t _production_input_reserve_shortfall = 0;
    int64_t _construction_material_reserved = 0;
    int64_t _maintenance_goods_consumed = 0;
    int64_t _maintenance_unmet = 0;
    int64_t _maintenance_unpaid_value = 0;
    int64_t _labor_signal_updates = 0;
    int64_t _building_resource_generated = 0;
    int64_t _building_resource_consumed = 0;
    int64_t _building_resource_limited_groups = 0;
    int64_t _unprofitable_building_groups = 0;
    int64_t _zero_utilization_building_groups = 0;
    int64_t _utilization_sum_q16 = 0;
    int64_t _market_signal_updates = 0;
    int64_t _trade_route_expansions = 0;
    int64_t _trade_route_cache_hits = 0;
    int64_t _trade_route_cache_misses = 0;
    int64_t _trade_candidates_generated = 0;
    int64_t _trade_candidates_accepted = 0;
    int64_t _trade_rejected_profit = 0;
    int64_t _trade_rejected_no_spread = 0;
    int64_t _trade_rejected_margin = 0;
    int64_t _trade_quantity_profit_clips = 0;
    int64_t _trade_relief_candidates = 0;
    int64_t _trade_rejected_capacity = 0;
    int64_t _trade_rejected_stock = 0;
    int64_t _trade_rejected_cash = 0;
    int64_t _trade_rejected_route = 0;
    int64_t _trade_rejected_vision = 0;
    int64_t _trade_rejected_order_cap = 0;
    int64_t _trade_orders_dispatched = 0;
    int64_t _trade_orders_arrived = 0;
    int64_t _trade_unclaimed_orders = 0;
    int64_t _trade_capacity_available = 0;
    int64_t _trade_capacity_used = 0;
    int64_t _trade_settlement_lag_days = 0;
    int64_t _trade_plan_reset_count = 0;
    int64_t _trade_signal_max_age_days = 0;
    int64_t _trade_first_dispatch_delay_max_days = 0;
    int64_t _trade_response_deadline_misses = 0;
    int64_t _trade_response_deadline_misses_cumulative = 0;
    int64_t _trade_unresolved_no_attempt = 0;
    int64_t _trade_unresolved_no_spread = 0;
    int64_t _trade_unresolved_margin = 0;
    int64_t _trade_unresolved_route = 0;
    int64_t _trade_unresolved_stock = 0;
    int64_t _trade_unresolved_capacity = 0;
    int64_t _trade_unresolved_cash = 0;
    int64_t _trade_unresolved_order_cap = 0;
    int64_t _trade_active_keys_pruned = 0;
    int64_t _trade_deficit_episodes_started = 0;
    int64_t _trade_deficit_episodes_resolved = 0;
    int64_t _trade_candidates_stale_generation = 0;
    int64_t _trade_candidates_arbitrated_out = 0;
    int64_t _trade_true_source_stock_failures = 0;
    int64_t _trade_topology_content_change_count = 0;
    std::string _trade_last_plan_reset_reason = "none";
    int64_t _building_resource_capacity_checks = 0;
    int64_t _building_resource_capacity_limited_groups = 0;
    std::string _last_building_rejection_reason;
    int32_t _worker_tasks = 1;
    int32_t _production_worker_tasks = 1;
    int32_t _market_worker_tasks_max = 1;
    int64_t _market_worker_task_sum = 0;
    int64_t _market_worker_dispatches = 0;
    int64_t _market_worker_parallel_dispatches = 0;
    int32_t _production_worker_tasks_max = 1;
    int64_t _production_worker_task_sum = 0;
    int64_t _production_worker_dispatches = 0;
    int64_t _production_worker_parallel_dispatches = 0;
    int64_t _production_worker_weight_total = 0;
    int64_t _production_worker_task_weight_min = 0;
    int64_t _production_worker_task_weight_max = 0;
    int64_t _production_worker_imbalance_q16_max = 0;
    double _production_worker_cpu_ms = 0.0;
    int32_t _audit_worker_tasks_max = 1;
    int64_t _audit_worker_dispatches = 0;
    double _audit_worker_cpu_ms = 0.0;
    int32_t _building_plan_worker_tasks_max = 1;
    int64_t _building_plan_worker_parallel_dispatches = 0;
    double _building_plan_worker_cpu_ms = 0.0;
    int64_t _opening_audit_fast_paths = 0;
    int64_t _opening_audit_full_verifications = 0;
    int64_t _closing_audit_fast_paths = 0;
    int64_t _closing_audit_full_verifications = 0;
    int64_t _closing_audit_mismatches = 0;
    int64_t _closing_audit_population_full_scan_entries = 0;
    int64_t _closing_audit_market_full_scan_entries = 0;
    AuditTotals _incremental_closing_totals;
    bool _opening_audit_force_full = false;
    std::vector<int64_t> _audit_shadow_population;
    std::vector<int64_t> _audit_shadow_funds;
    std::vector<int64_t> _audit_shadow_market_stock;
    std::vector<uint32_t> _audit_population_lane_stamp;
    std::vector<uint32_t> _audit_market_lane_stamp;
    std::vector<size_t> _audit_population_touched_lanes;
    std::vector<size_t> _audit_market_touched_lanes;
    uint32_t _audit_mutation_generation = 0;
    std::string _closing_audit_mismatch_ledger = "none";
    int64_t _closing_audit_mismatch_lane = -1;
    int64_t _investment_scheduled_review_cells = 0;
    int64_t _investment_review_cells = 0;
    int64_t _investment_type_evaluations = 0;
    int64_t _investment_market_signal_rejections = 0;
    int64_t _investment_ethnicity_evaluations = 0;
    int64_t _investment_sparse_considered_types = 0;
    int64_t _investment_sparse_selected_types = 0;
    int64_t _investment_sparse_skipped_types = 0;
    int64_t _investment_sparse_mismatches = 0;
    int64_t _investment_sparse_dense_fallbacks = 0;
    // Types skipped by the capital-feasibility gate: no local sponsor cohort
    // (transferable <= raw funds) and no merchant credit can cover even the
    // construction cost, so every sponsor search for that (cell, type) is
    // guaranteed to fail. Exact no-false-negative early-out.
    int64_t _investment_gate_capital_type_skips = 0;
    int64_t _investment_displacement_type_evaluations = 0;
    int64_t _startup_demand_seed_count = 0;
    int64_t _startup_demand_touched_lanes = 0;
    int64_t _startup_demand_catalog_edges = 0;
    int64_t _startup_demand_cycle_skips = 0;
    int64_t _startup_demand_remote_lanes = 0;
    int64_t _startup_demand_matched_review_cells = 0;
    int64_t _startup_demand_buildings_started = 0;
    int64_t _startup_demand_scratch_bytes = 0;
    int64_t _approximation_decisions = 0;
    int64_t _approximation_exact_probes = 0;
    int64_t _approximation_certificate_failures = 0;
    int64_t _approximation_exact_fallbacks = 0;
    int64_t _approximation_frontier_candidates = 0;
    int64_t _approximation_frontier_pruned = 0;
    int64_t _approximation_max_observed_regret_q16 = 0;
    int64_t _approximation_probe_violations = 0;
    int64_t _approximation_probe_max_spend_error_q16 = 0;
    int64_t _approximation_probe_max_demand_error_q16 = 0;
    int32_t _approximation_cooldown_epochs_left = 0;
    int32_t _approximation_low_prune_epochs = 0;
    int32_t _active_batch_multiplier = 1;
    int64_t _high_speed_market_dispatches_saved = 0;
    int64_t _high_speed_production_dispatches_saved = 0;
    int64_t _budgeted_building_commit_phase_fusions = 0;
    int64_t _budgeted_publish_phase_fusions = 0;
    bool _investment_sparse_runtime_disabled = false;
    double _production_merge_ms = 0.0;
    double _production_worker_ms = 0.0;
    double _market_worker_ms = 0.0;
    double _household_market_prepare_ms = 0.0;
    double _market_merge_ms = 0.0;
    double _market_merge_aggregate_ms = 0.0;
    double _market_merge_trade_ms = 0.0;
    int64_t _market_result_allocation_growth_count = 0;
    int64_t _market_result_allocation_growth_bytes = 0;
    int64_t _production_result_allocation_growth_count = 0;
    int64_t _production_result_allocation_growth_bytes = 0;
    int32_t _rolling_phase = 0;
    int32_t _rolling_due_cells = 0;
    int32_t _rolling_processed_cells = 0;
    int32_t _rolling_deferred_cells = 0;
    int64_t _settlement_watermark = -1;
    int64_t _settlement_newest_day = -1;
    int64_t _settlement_max_age_days = 0;
    int64_t _rolling_deadline_violations = 0;
    // Transient epoch workset diagnostics. These counters do not participate
    // in economy state/event hashes and are reset at every epoch boundary.
    int64_t _prepare_reuse_count = 0;
    int64_t _workset_cells_planned = 0;
    int64_t _workset_cells_executed = 0;
    int64_t _duplicate_range_count = 0;
    int32_t _workset_last_cursor = 0;

    int32_t _trace_mode = TRACE_SELECTIVE;
    int64_t _trace_memory_budget = 32LL * 1024 * 1024;
    int32_t _trace_retention_epochs = 8;
    int64_t _trace_detail_epoch_budget = 8LL * 1024 * 1024;
    int32_t _trace_poll_max_events = 4096;
    std::vector<uint8_t> _trace_cell_mask;
    std::vector<uint8_t> _pending_trace_cell_mask;
    bool _trace_filter_pending = false;
    int32_t _inspector_trace_cell = -1;
    int32_t _pending_inspector_trace_cell = -1;
    bool _inspector_trace_pending = false;
    EventBatch _staging_events;
    std::deque<EventBatch> _committed_event_batches;
    std::vector<ConstructionCommandReceipt> _staging_construction_receipts;
    std::deque<ConstructionCommandReceipt> _committed_construction_receipts;
    int64_t _next_construction_receipt_id = 1;
    std::vector<CommittedGameplayFact> _staging_gameplay_facts;
    std::vector<CommittedGameplayFact> _committed_gameplay_facts;
    std::deque<AuditFrame> _audit_history;
    std::unordered_map<std::string, int64_t> _event_consumer_ack;
    int64_t _next_event_id = 1;
    int64_t _event_evicted_count = 0;
    int64_t _first_evicted_event_id = 0;
    int64_t _trace_detail_truncated = 0;
    int64_t _trace_uncommitted_discarded = 0;
    uint64_t _event_stream_hash = 1469598103934665603ULL;
    double _event_summary_ms = 0.0;
    double _event_detail_ms = 0.0;
    double _event_publish_ms = 0.0;
    EventArchiveState _event_archive;

    double _formula_ms = 0.0;
    double _clear_ms = 0.0;
    double _ledger_ms = 0.0;
    double _fallback_ms = 0.0;
    double _merchant_settle_ms = 0.0;
    double _price_ms = 0.0;
    double _structure_ms = 0.0;
    double _publish_ms = 0.0;
    double _employment_ms = 0.0;
    double _production_ms = 0.0;
    double _building_plan_ms = 0.0;
    double _building_plan_evaluate_ms = 0.0;
    double _building_plan_reserve_ms = 0.0;
    double _building_structure_group_merge_ms = 0.0;
    double _building_structure_market_cache_ms = 0.0;
    double _building_structure_labor_cache_ms = 0.0;
    double _investment_ms = 0.0;
    double _market_signal_ms = 0.0;
    double _market_signal_insert_ms = 0.0;
    double _market_signal_flush_ms = 0.0;
    int64_t _market_signal_insert_count = 0;
    double _wage_plan_ms = 0.0;
    double _labor_signal_ms = 0.0;
    double _trade_plan_ms = 0.0;
    double _trade_plan_scan_body_ms = 0.0;
    double _trade_plan_scan_finalize_ms = 0.0;
    double _trade_plan_route_prepare_ms = 0.0;
    double _trade_plan_route_expand_ms = 0.0;
    double _trade_plan_route_finalize_ms = 0.0;
    int64_t _trade_plan_scan_pairs_slice = 0;
    int64_t _trade_plan_route_sources_prepared_slice = 0;
    int64_t _trade_plan_route_expansions_slice = 0;
    int64_t _trade_plan_candidates_finalized_slice = 0;
    double _trade_settle_ms = 0.0;
    double _trade_dispatch_ms = 0.0;
    double _epoch_begin_ms = 0.0;
    double _epoch_preflight_ms = 0.0;
    double _prepare_ms = 0.0;
    // Transient epoch-begin substage timings (diagnostics only; never saved or
    // hashed). Sum of parts <= _epoch_begin_ms.
    double _epoch_begin_reset_ms = 0.0;
    double _epoch_begin_country_ms = 0.0;
    double _epoch_begin_city_factor_ms = 0.0;
    double _epoch_begin_building_factor_ms = 0.0;
    // Lookup-scan accounting (diagnostics only; never saved or hashed). Counts
    // elements visited by the remaining linear-scan lookups so the cost of
    // finding data can be separated from the cost of computing it. Attribution
    // uses _executed_stage, which the slice dispatcher sets before doing work.
    static constexpr size_t SCAN_STAGE_SLOTS = 18;
    mutable int64_t _scan_steps_by_stage[SCAN_STAGE_SLOTS] = {};
    mutable int64_t _scan_steps_find_building_group = 0;
    mutable int64_t _scan_steps_find_signature = 0;
    mutable int64_t _scan_steps_membership_fallback = 0;
    mutable int64_t _scan_steps_person_linear = 0;
    mutable int64_t _scan_steps_family_linear = 0;
    mutable int64_t _scan_calls_find_building_group = 0;
    mutable int64_t _scan_calls_find_signature = 0;
    mutable int64_t _scan_calls_membership_fallback = 0;
    void note_scan_steps(int64_t steps) const {
        const size_t slot = static_cast<size_t>(_executed_stage);
        if (slot < SCAN_STAGE_SLOTS) _scan_steps_by_stage[slot] += steps;
    }
    // Person-commit substage timings (diagnostics only; never saved or hashed).
    double _person_commit_retire_ms = 0.0;
    double _person_commit_index_ms = 0.0;
    double _person_commit_bind_jobs_ms = 0.0;
    double _person_commit_claims_ms = 0.0;
    double _person_commit_equity_ms = 0.0;
    double _person_commit_promote_ms = 0.0;
    double _family_commit_normalize_ms = 0.0;
    double _family_commit_attribution_ms = 0.0;
    double _family_commit_form_ms = 0.0;
    double _family_commit_index_ms = 0.0;
    double _family_commit_lifecycle_ms = 0.0;
    double _family_commit_influence_ms = 0.0;
    double _family_behavior_cache_ms = 0.0;
    int64_t _family_behavior_cache_rebuilds = 0;
    int64_t _family_behavior_cache_skips = 0;
    int64_t _family_behavior_metric_contexts_built = 0;
    int64_t _family_behavior_condition_edges_evaluated = 0;
    int64_t _family_behavior_class_rows = 0;
    uint32_t _family_behavior_cache_dirty_reasons =
        FAMILY_BEHAVIOR_DIRTY_INITIAL;
    uint32_t _family_behavior_cache_last_reasons = 0;
    bool _family_behavior_cache_dirty = true;
    double _person_retire_call_ms = 0.0;
    int64_t _person_retire_calls = 0;
    double _rebuild_person_needs_ms = 0.0;
    double _rebuild_person_count_ms = 0.0;
    double _rebuild_person_fill_ms = 0.0;
    double _rebuild_person_sort_ms = 0.0;
    double _rebuild_person_needoffsets_ms = 0.0;
    double _rebuild_family_membership_ms = 0.0;
    double _rebuild_family_ownership_ms = 0.0;
    double _rebuild_family_csr_ms = 0.0;
    double _rebuild_family_cellindex_ms = 0.0;
    double _investment_evaluate_ms = 0.0;
    double _investment_allocate_ms = 0.0;
    double _investment_prepare_lanes_ms = 0.0;
    double _investment_prepare_pending_ms = 0.0;
    double _investment_prepare_groups_ms = 0.0;
    double _startup_demand_prepare_ms = 0.0;
    double _finalize_construction_ms = 0.0;
    double _finalize_reconcile_ms = 0.0;
    double _building_factor_refresh_ms = 0.0;
    double _building_role_storage_ms = 0.0;
    int64_t _building_factor_cache_hits_epoch = 0;
    int64_t _building_factor_cache_misses_epoch = 0;
    int64_t _building_factor_miss_modver_epoch = 0;
    int64_t _building_factor_miss_country_epoch = 0;
    int64_t _building_factor_miss_sector_epoch = 0;
    int64_t _building_factor_miss_research_epoch = 0;
    int64_t _building_factor_miss_identity_epoch = 0;
    double _epoch_begin_workset_ms = 0.0;
    double _epoch_begin_resource_lane_ms = 0.0;
    double _epoch_begin_fiscal_ms = 0.0;
    double _epoch_begin_construction_csr_ms = 0.0;
    double _epoch_begin_recovery_apply_ms = 0.0;
    double _epoch_begin_vector_init_ms = 0.0;
    double _epoch_begin_audit_lane_ms = 0.0;
    double _epoch_begin_commands_ms = 0.0;
    double _audit_ms = 0.0;
    double _watermark_ms = 0.0;
    std::array<double, static_cast<size_t>(PublishPhase::COUNT)> _publish_phase_ms{};
    std::array<int64_t, static_cast<size_t>(PublishPhase::COUNT)> _publish_phase_work{};
    std::array<double, static_cast<size_t>(PublishPhase::COUNT)> _publish_slice_phase_ms{};
    std::array<int64_t, static_cast<size_t>(PublishPhase::COUNT)> _publish_slice_phase_work{};
    std::array<double, BUILDING_COMMIT_PHASE_COUNT> _building_commit_slice_phase_ms{};
    std::array<int64_t, BUILDING_COMMIT_PHASE_COUNT> _building_commit_slice_phase_work{};
    enum HouseholdSlicePhase : size_t {
        HOUSEHOLD_PREPARE = 0,
        HOUSEHOLD_WORKER,
        HOUSEHOLD_MERGE_AGGREGATE,
        HOUSEHOLD_MERGE_TRADE,
        HOUSEHOLD_TRACE,
        HOUSEHOLD_OTHER,
        HOUSEHOLD_POST_BUILDINGS,
        HOUSEHOLD_RESERVE_SHORTFALL,
        HOUSEHOLD_INCOME_SUBSIDY,
        HOUSEHOLD_STRUCTURAL_SORT,
        HOUSEHOLD_SLICE_PHASE_COUNT,
    };
    std::array<double, HOUSEHOLD_SLICE_PHASE_COUNT> _household_slice_phase_ms{};
    std::array<int64_t, HOUSEHOLD_SLICE_PHASE_COUNT> _household_slice_phase_work{};

    AuditTotals _opening_totals;
    AuditTotals _closing_totals;
    AuditTotals _publish_accum;
    PopulationStore _population;
    FamilyStore _families;
    FamilyExpeditionStore _family_expeditions;
    std::vector<int32_t> _family_expedition_route_cells;
    std::vector<int32_t> _family_expedition_route_costs;
    std::vector<FamilyExpeditionPayload> _family_expedition_payloads;
    std::vector<uint64_t> _family_expedition_person_handles;
    std::vector<FamilyExpeditionCargoLine> _family_expedition_cargo;
    std::vector<FamilyExpeditionKitBuilding> _family_expedition_kit_buildings;
    std::vector<int32_t> _family_expedition_missing_good_ids;
    std::vector<int64_t> _family_expedition_missing_good_quantities;
    std::unordered_map<uint64_t, int32_t> _family_expedition_target_index;
    std::vector<std::pair<int64_t, int32_t>> _family_expedition_due_heap;
    std::vector<ColonizationReceipt> _colonization_receipts;
    int64_t _next_colonization_receipt_id = 1;
    int64_t _next_family_expedition_stable_id = 1;
    std::vector<ColonizationQuoteCacheEntry> _colonization_quote_cache;
    std::unordered_map<uint64_t, int32_t> _colonization_quote_index;
    std::vector<int32_t> _colonization_quote_route_cells;
    std::vector<int32_t> _colonization_quote_route_costs;
    std::vector<int64_t> _colonization_distance;
    std::vector<uint32_t> _colonization_distance_stamp;
    std::vector<int32_t> _colonization_parent;
    std::vector<uint32_t> _colonization_parent_stamp;
    std::vector<std::pair<int64_t, int32_t>> _colonization_route_heap;
    uint32_t _colonization_search_stamp = 0;
    std::vector<int32_t> _transport_succ_cells;
    std::vector<int32_t> _transport_succ_costs;
    double _colonization_route_query_ms = 0.0;
    double _colonization_payload_split_ms = 0.0;
    double _colonization_cross_domain_ms = 0.0;
    std::vector<CanalQuote> _canal_quotes;
    std::unordered_map<uint64_t, int32_t> _canal_quote_index;
    std::vector<CanalProject> _canal_projects;
    std::unordered_map<uint64_t, int32_t> _canal_project_index;
    std::vector<CanalConstructionReceipt> _canal_receipts;
    uint64_t _next_canal_quote_token = 1;
    uint64_t _next_canal_project_id = 1;
    int64_t _next_canal_receipt_id = 1;
    FamilyCellInfluenceStore _family_influences;
    NotablePersonStore _persons;
    std::vector<FamilyMembershipEdge> _family_memberships;
    std::vector<FamilyBuildingOwnership> _family_ownerships;
    std::vector<FamilyTraitRoll> _family_traits;
    std::vector<int32_t> _family_behavior_factor_offsets;
    std::vector<FamilyBehaviorFactorRow> _family_behavior_factor_rows;
    std::vector<int32_t> _family_purchase_factor_q16;
    std::vector<int32_t> _family_investment_factor_q16;
    std::vector<int32_t> _family_birth_factor_q16;
    std::vector<int32_t> _family_absorb_bonus_q16;
    std::vector<int32_t> _family_colonization_population_reward;
    std::vector<FamilyTraitCommand> _family_trait_commands;
    std::vector<FamilyModifierBinding> _family_modifier_bindings;
    std::vector<FamilyEffectBinding> _family_effect_bindings;
    std::unordered_map<int64_t, size_t> _family_effect_binding_by_instance;
    std::unordered_map<uint64_t, std::vector<int64_t>>
        _family_effect_instances_by_branch;
    std::unordered_map<int32_t, std::vector<int64_t>>
        _family_effect_instances_by_cell;
    std::vector<FamilyTriggerBinding> _family_trigger_bindings;
    std::vector<PersonNeedState> _person_needs;
    // Set when a retirement leaves need rows behind. Compaction is deferred to
    // one pass so retiring N people costs O(rows) instead of O(N * rows).
    bool _person_needs_orphaned = false;
    // Cleared whenever the row set is replaced. While set, the rows are already
    // pruned, sorted and deduped, so a second rebuild in the same commit can
    // skip straight to the CSR construction.
    bool _person_needs_normalized = false;
    std::vector<PersonNeedState> _person_need_scratch;
    std::vector<int32_t> _person_need_owner_scratch;
    std::vector<int32_t> _person_need_cursor_scratch;
    // Influence shares move slowly and are only consumed by the per-branch
    // prestige review, which is itself on a 30-day phased cadence. Refresh runs
    // on this epoch stride, and always on a commit that changed the edge set so
    // branch creation and release are never deferred.
    static constexpr int64_t FAMILY_INFLUENCE_REFRESH_EPOCHS = 4;
    // Derived, transient CSR. Authoritative edges above remain sparse and are
    // rebuilt only at FAMILY_COMMIT or after structural restore.
    std::vector<int32_t> _family_member_offsets;
    std::vector<int32_t> _family_member_edge_indices;
    std::vector<int32_t> _family_owned_offsets;
    std::vector<int32_t> _family_owned_edge_indices;
    std::vector<int32_t> _family_cohort_offsets;
    std::vector<int32_t> _family_cohort_edge_indices;
    std::vector<int32_t> _family_building_offsets;
    std::vector<int32_t> _family_building_edge_indices;
    std::vector<int32_t> _family_cell_offsets;
    std::vector<int32_t> _family_cell_indices;
    std::vector<FamilyIndustryStats> _family_industry_stats;
    std::vector<FamilyOwnedOutputRow> _family_owned_output_rows;
    bool _family_indices_dirty = true;
    // Derived notable-person CSR; rebuilt at PERSON_COMMIT and restore.
    std::vector<int32_t> _person_family_offsets;
    std::vector<int32_t> _person_family_indices;
    std::vector<int32_t> _person_cohort_offsets;
    std::vector<int32_t> _person_cohort_indices;
    std::vector<int32_t> _person_cell_offsets;
    std::vector<int32_t> _person_cell_indices;
    std::vector<int32_t> _person_building_offsets;
    std::vector<int32_t> _person_building_indices;
    std::vector<int32_t> _person_need_offsets;
    bool _person_indices_dirty = true;
    // Frozen claim and epoch attribution scratch. Excluded from PKEC/hash.
    std::vector<int64_t> _person_opening_cash_claim;
    std::vector<PersonNeedState> _person_epoch_needs;
    std::vector<uint64_t> _person_previous_building_handle;
    std::vector<uint8_t> _person_previous_job_kind;
    std::vector<int32_t> _person_previous_employee_role_index;
    SettlementStore _settlements;
    MarketStore _market;
    MarketSignalStore _market_signals;
    MarketSignalStore _market_signals_rebuild_scratch;
    std::vector<int64_t> _epoch_business_demand_ema;
    std::vector<int64_t> _epoch_desired_business_demand;
    std::vector<int64_t> _epoch_funded_business_demand;
    std::vector<int64_t> _epoch_offered_supply_ema;
    // Current-cycle producer absorption diagnostics, aligned to the sparse
    // (cell, good) market-signal lanes. These are transient and excluded from
    // PKEC and the authoritative state hash.
    std::vector<int64_t> _epoch_producer_sellable_current;
    std::vector<int64_t> _epoch_producer_merchant_sold_current;
    std::vector<int64_t> _epoch_producer_discarded_current;
    std::vector<int64_t> _epoch_nonhousehold_withdrawals;
    std::vector<int32_t> _epoch_cost_anchor_price;
    std::vector<int64_t> _production_input_reserve;
    std::vector<int64_t> _construction_material_reserve;
    // Country research demand is derived once from the frozen country policy,
    // prices, and population at epoch begin. It is deliberately transient:
    // country treasury/goods remain Country authority and this cache is not
    // part of PKEC or the economy state hash.
    int32_t _epoch_research_good_id = -1;
    std::vector<int64_t> _epoch_research_demand_by_cell;
    std::vector<int64_t> _epoch_research_demand_by_market;
    // Building retention and household clearing share the same frozen basis.
    // These non-authoritative arrays avoid repeating elasticity/pow work.
    std::vector<int64_t> _demand_basis_cache_day;
    std::vector<int64_t> _demand_basis_variant_scores;
    std::vector<int64_t> _demand_basis_variant_prices;
    std::vector<int64_t> _demand_basis_need_score_sums;
    std::vector<int64_t> _demand_basis_need_composites;
    std::vector<int64_t> _demand_basis_need_environment;
    // Persistent per-cell rolling settlement state. Phase is derived from the
    // Stable cell id; last day and generation are PKEC v16 authority.
    std::vector<int64_t> _cell_last_settlement_day;
    // Q32 fractional births accumulated per cell and ethnicity.
    std::vector<int64_t> _birth_residual_q32;
    std::vector<uint32_t> _cell_settlement_generation;
    std::vector<uint32_t> _cell_price_stock_gen;
    std::vector<uint32_t> _cell_owner_cash_gen;
    std::vector<uint32_t> _cell_population_gen;
    std::vector<uint32_t> _cell_building_structure_gen;
    std::vector<uint32_t> _cell_technology_gen;
    std::vector<uint32_t> _cell_resource_gen;
    std::vector<uint32_t> _cell_trade_gen;
    std::vector<int32_t> _cell_effect_shortage_q16;
    std::vector<int32_t> _cell_essentials_shortage_q16;
    std::vector<int32_t> _cell_resource_abundance_q16;
    std::vector<int32_t> _cell_previous_precipitation_q16;
    std::vector<int32_t> _cell_rain_event_q16;
    std::vector<uint8_t> _good_is_essential;
    int32_t _max_building_upgrade_tier = 0;
    // Transaction worksets are deterministic, sorted and never persisted.
    std::vector<int32_t> _epoch_market_ids;
    std::vector<int64_t> _epoch_market_work_weights;
    // Scratch union of populated / building / pending-construction cells.
    // Rebuilt each epoch_begin; never saved or hashed.
    std::vector<int32_t> _economy_live_cells;
    std::vector<int32_t> _epoch_settlement_cells;
    std::vector<int32_t> _epoch_building_cells;
    // Subset of today's market workset whose plan evaluation is due on the
    // locked slow cycle S. Cells that are S-due but not in today's market
    // bucket wait until their next market day. Production still consumes the
    // last computed plan.
    std::vector<int32_t> _epoch_plan_cells;
    std::vector<int64_t> _household_post_saturation_scratch;
    std::vector<int64_t> _household_post_restarted_scratch;
    std::vector<int64_t> _household_post_failed_scratch;
    std::vector<int64_t> _household_reserve_shortfall_scratch;
    // Diagnostic-only per-cell contributions for the current rolling epoch.
    // Employment can be recomputed after structural changes; replacing the
    // cached contribution avoids subtracting a cell that was never counted in
    // this epoch and keeps the published totals non-negative.
    std::vector<int64_t> _employment_metrics_epoch_by_cell;
    std::vector<int64_t> _employment_owner_jobs_by_cell;
    std::vector<int64_t> _employment_employee_jobs_by_cell;
    std::vector<int64_t> _employment_unemployed_by_cell;
    // Epoch-transient lanes. They are rebuilt from the frozen sample and are
    // intentionally excluded from save data and the authoritative state hash.
    std::vector<int64_t> _building_survival_utilization_floor_q16;
    std::vector<int64_t> _building_planned_capacity_before_climate_q16;
    std::vector<int64_t> _building_funded_capacity_q16;
    std::vector<int64_t> _building_working_capital_allocated;
    std::vector<int64_t> _building_owner_livelihood_credit;
    std::vector<int64_t> _building_merchant_credit_limit;
    // Suspended producers keep no production, labor, or input demand. Permanent
    // liquidation is reviewed only when a full restart is physically and
    // financially executable but still economically unviable.
    std::vector<int64_t> _building_recovery_probe_capacity_q16;
    std::vector<uint8_t> _building_recovery_liquidation_eligible;
    // Per-group cache for refresh_building_modifier_factors, keyed on every
    // input of group.output_factor_q16 / modifier_handle: every frozen
    // country factor value, country handle, ECONOMY store snapshot_version,
    // and the (type, owner) identity. During a frozen epoch `_buildings` is
    // append-only; topology rebuilds permute the compact lane only at
    // BUILDING_COMMIT / idle boundaries and remap this cache with them.
    // Cache hits skip both ensure_building_identity and the ECONOMY
    // effective_value query. Transient; never saved or hashed.
    struct BuildingFactorCacheEntry {
        int64_t country_factor_q16 = std::numeric_limits<int64_t>::min();
        int64_t sector_factor_q16 = 0;
        int64_t research_factor_q16 = 0;
        int64_t family_factor_q16 = 0;
        int64_t building_type_factor_q16 = 0;
        int64_t terrain_sector_factor_q16 = 0;
        int64_t landform_sector_factor_q16 = 0;
        uint64_t country_handle = 0;
        uint64_t mod_version = 0;
        uint64_t exact_building_mod_version = 0;
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int32_t family_owned_factor_q16 = Q16_ONE;
        int32_t cell_sector_factor_q16 = Q16_ONE;
    };
    std::vector<BuildingFactorCacheEntry> _building_factor_cache;
    std::vector<BuildingFactorCacheEntry> _building_factor_cache_rebuild_scratch;
    // Persons whose cohort changed since the last CSR rebuild, keyed by the
    // cohort they landed in. Lets move_notable_people read the cohort CSR
    // instead of the whole person table without losing candidates the stale
    // CSR no longer lists.
    std::unordered_map<uint64_t, std::vector<int32_t>> _person_cohort_migrations;
    // Same idea for the person-family CSR, which promotion reads before the
    // next PERSON_COMMIT rebuild.
    std::unordered_map<uint64_t, std::vector<int32_t>> _person_family_migrations;
    // Live notable-person stable ids, so identity assignment can test for a
    // collision without walking the person table once per hash probe.
    std::unordered_set<int64_t> _person_stable_ids;
    std::unordered_set<int64_t> _family_stable_ids;
    // Live family indices grouped by surname, compacted lazily on read.
    std::vector<std::vector<int32_t>> _family_surname_members;
    std::vector<uint32_t> _person_candidate_stamp;
    uint32_t _person_candidate_generation = 0;
    int64_t _building_factor_cache_hits = 0;
    int64_t _building_factor_cache_misses = 0;
    std::vector<int64_t> _building_investment_score_q16;
    std::vector<int64_t> _building_investment_payback_days;
    std::vector<int32_t> _building_investment_rejection;
    // Bounded cold-path diagnostics for the one inspector-selected cell. These
    // are transient, excluded from save/hash, and include absent building types.
    int32_t _investment_diagnostic_cell = -1;
    int64_t _investment_diagnostic_day = -1;
    std::vector<InvestmentDiagnostic> _investment_diagnostics;
    std::unordered_map<uint64_t, int64_t> _investment_pending_by_cell_type;
    std::unordered_map<uint64_t, InvestmentExistingType>
        _investment_existing_by_cell_type;
    // Peak daily extraction already committed by installed and pending groups,
    // indexed as resource * cell_count + cell for the investment review only.
    std::vector<int64_t> _investment_resource_committed_by_cell;
    std::vector<int64_t> _investment_merchant_cash_by_cell;
    std::vector<int64_t> _investment_outstanding_credit_by_cell;
    std::vector<uint32_t> _investment_resource_commitment_stamp;
    std::vector<uint32_t> _investment_cell_finance_stamp;
    uint32_t _investment_scratch_generation = 0;
    std::vector<OutputInvestmentSignal> _investment_output_signals_scratch;
    std::vector<InvestmentIncumbentLane> _investment_incumbent_lanes_scratch;
    std::vector<int32_t> _investment_employment_cells;
    std::vector<int32_t> _investment_review_cell_indices;
    // Catalog-derived output-good -> building-type CSR plus the current review
    // cell's sparse active-good set. These lanes are rebuildable scheduling
    // data and are excluded from PKEC and the authoritative state hash.
    std::vector<int32_t> _investment_good_type_offsets;
    std::vector<int32_t> _investment_good_type_indices;
    std::vector<uint64_t> _investment_active_good_words;
    std::vector<int32_t> _investment_active_goods_scratch;
    std::vector<uint32_t> _investment_type_stamp;
    std::vector<uint32_t> _investment_good_stamp;
    uint32_t _investment_review_stamp_generation = 0;
    std::vector<int32_t> _investment_review_types_scratch;
    std::vector<int32_t> _investment_good_queue_scratch;
    // v44 transient startup-demand graph. The dense value/stamp pair is the
    // fixed 12-byte (cell, good) budget; only stamped/touched lanes are read.
    // Remote/inbound lanes are sparse, rebuilt once per investment batch, and
    // excluded from PKEC and the authoritative state hash.
    std::vector<int64_t> _startup_demand_values;
    std::vector<uint32_t> _startup_demand_stamps;
    uint32_t _startup_demand_generation = 0;
    std::vector<uint64_t> _startup_demand_touched_keys;
    std::vector<int32_t> _startup_monetary_good_indices;
    std::vector<StartupRemoteLane> _startup_remote_lanes;
    std::vector<StartupRemoteGroup> _startup_remote_groups;
    std::vector<StartupInboundLane> _startup_inbound_lanes;
    std::vector<StartupRemoteAccumulator> _startup_remote_accumulator_scratch;
    // Epoch-transient worker outputs. Keeping the nested vector capacities
    // avoids rebuilding thousands of small buffers every household slice.
    std::vector<MarketResult> _market_results_scratch;
    std::vector<ProductionResult> _production_results_scratch;
    // Production uses stable contiguous weighted ranges. These transient
    // buffers are diagnostics/scheduling scratch only and never enter PKEC or
    // the authoritative state hash.
    std::vector<int64_t> _production_cell_weights_scratch;
    std::vector<int32_t> _production_task_offsets_scratch;
    std::vector<int64_t> _production_task_weights_scratch;
    std::vector<double> _production_task_ms_scratch;
    std::vector<AuditTotals> _audit_task_totals_scratch;
    std::vector<int64_t> _audit_task_saturation_scratch;
    std::vector<double> _audit_task_ms_scratch;
    std::vector<BuildingPlanResult> _building_plan_results_scratch;
    CompletedEpochPerf _last_completed_perf;
    std::vector<uint64_t> _trade_active_keys;
    std::vector<uint8_t> _trade_active_key_present;
    std::unordered_map<uint64_t, uint8_t> _trade_active_key_idle_cycles;
    // Diagnostic-only sparse clocks keyed independently from authoritative EMA state.
    std::vector<uint64_t> _trade_signal_clock_keys;
    std::vector<uint64_t> _trade_signal_bulk_keys_scratch;
    std::vector<int64_t> _trade_signal_first_seen_day;
    std::vector<int64_t> _trade_signal_first_dispatch_day;
    std::vector<int64_t> _trade_signal_last_attempt_day;
    std::vector<int32_t> _trade_signal_last_rejection_reason;
    std::vector<uint8_t> _trade_signal_deadline_reported;
    // Investment-only append lanes. Entries are immediately visible through
    // dense_index, then stably merged into the authoritative CSR before publish.
    std::vector<int32_t> _market_signal_overflow_cells;
    std::vector<OwnerRetainedOutput> _owner_retained_outputs;
    TradeTopologyStore _trade_topology;
    TradePlanStore _trade_plan;
    TradeOrderStore _trade_orders;
    TradeFlowSignalStore _trade_flows;
    CountryGoodTradeAggregateStore _country_good_trade;
    CountryPartnerTradeAggregateStore _country_partner_trade;
    TariffHistoryStore _tariff_history;
    // Rebuildable sparse lookup/display indices.  The authoritative aggregate
    // columns above remain the only persisted/hashed state; these maps remove
    // the former O(total aggregates) rebuild from every dispatch, while the
    // per-country sorted row lists make paged UI queries O(limit).
    std::unordered_map<uint64_t, int32_t> _country_good_trade_index;
    std::unordered_map<uint64_t, int32_t> _country_partner_trade_index;
    std::unordered_map<uint64_t, int32_t> _tariff_history_index;
    std::vector<std::vector<int32_t>> _country_good_display_rows;
    std::vector<std::vector<int32_t>> _country_partner_display_rows;
    std::vector<uint8_t> _country_good_display_dirty;
    std::vector<uint8_t> _country_partner_display_dirty;
    uint64_t _country_trade_revision = 0;
    LaborMarketStore _labor_signals;
    LaborMarketStore _labor_signals_rebuild_scratch;
    std::vector<FormulaDefinition> _formulas;
    std::unordered_map<std::string, int32_t> _formula_by_id;
    std::vector<Signature> _signatures;
    // Dense (profession_id * n_ethnicity + ethnicity_id) -> signature_id lookup,
    // -1 when absent. Built once alongside _signatures. Lets the employment pass
    // resolve "the signature for this profession worker of this ethnicity" and
    // "the unemployed signature for this ethnicity" in O(1) without scanning.
    std::vector<int32_t> _signature_by_profession_ethnicity;
    std::vector<Plan> _plans;
    std::vector<Need> _needs;
    std::vector<VariantChoice> _variants;
    std::vector<NeedComponent> _components;
    std::vector<EnvironmentCurve> _environment_curves;
    std::vector<std::string> _need_ids;
    std::vector<int32_t> _ethnicity_need_factor_q16;
    std::vector<Rule> _rules;
    std::vector<int64_t> _rule_params;
    std::vector<std::string> _profession_ids;
    std::vector<int32_t> _profession_class_index;
    std::vector<std::string> _carrying_class_ids;
    std::vector<int32_t> _profession_political_class_index;
    std::vector<std::string> _political_class_ids;
    uint64_t _political_class_hash = 0;
    std::array<CountryClassOpinionSnapshot, 2> _class_opinion_buffers;
    int32_t _class_opinion_committed_buffer = 0;
    uint64_t _class_opinion_revision = 0;
    uint64_t _class_opinion_cells_scanned = 0;
    uint64_t _class_opinion_slots_scanned = 0;
    uint64_t _class_opinion_zero_population_rows = 0;
    uint64_t _last_class_opinion_cells_scanned = 0;
    uint64_t _last_class_opinion_slots_scanned = 0;
    uint64_t _last_class_opinion_zero_population_rows = 0;
    double _class_opinion_ms = 0.0;
    std::vector<std::string> _carrying_family_ids;
    std::vector<int32_t> _carrying_family_need_stable;
    std::vector<int32_t> _carrying_family_good_offsets;
    std::vector<int32_t> _carrying_family_goods;
    std::vector<int32_t> _need_carrying_family;
    std::vector<int32_t> _carrying_support_resource_ids;
    std::vector<int32_t> _carrying_food_yield_offsets;
    std::vector<CarryingSupportYield> _carrying_food_yields;
    int64_t _carrying_survival_food_per_person = 1;
    std::vector<CarryingSupportYield> _epoch_country_support_yield;
    std::vector<int32_t> _profession_technology_offsets;
    std::vector<int32_t> _profession_required_technologies;
    std::vector<std::string> _ethnicity_ids;
    std::vector<int32_t> _ethnicity_culture_group_ids;
    std::vector<std::string> _good_ids;
    std::vector<int32_t> _good_occupancy_bit_offsets;
    std::vector<int32_t> _good_occupancy_bits;
    std::vector<int32_t> _bio_introduce_cells;
    std::vector<int32_t> _bio_introduce_bits;
    // Main-thread only. Production workers land introductions in
    // ProductionResult; merge_building_production_result commits them here.
    std::unordered_set<uint64_t> _bio_introduce_keys;
    std::vector<std::string> _plan_ids;
    std::vector<int32_t> _good_default_price;
    std::vector<int64_t> _good_default_stock;
    std::vector<int32_t> _good_min_price;
    std::vector<int32_t> _good_max_price;
    std::vector<int32_t> _good_price_adjust_q16;
    std::vector<int32_t> _good_demand_price_elasticity_q16;
    std::vector<int32_t> _good_household_wealth_elasticity_q16;
    std::vector<int32_t> _good_household_savings_threshold_months_q16;
    std::vector<int32_t> _good_demand_ema_alpha_q16;
    std::vector<int32_t> _good_target_inventory_days_q16;
    std::vector<int32_t> _good_inventory_weight_q16;
    std::vector<int32_t> _good_shortage_weight_q16;
    std::vector<int32_t> _good_excess_demand_weight_q16;
    std::vector<int32_t> _good_cost_anchor_weight_q16;
    std::vector<int32_t> _good_inactive_reversion_weight_q16;
    std::vector<int32_t> _good_business_demand_ema_alpha_q16;
    std::vector<int32_t> _good_supply_ema_alpha_q16;
    std::vector<int32_t> _good_cost_ema_alpha_q16;
    std::vector<int32_t> _good_max_price_rise_q16;
    std::vector<int32_t> _good_max_price_fall_q16;
    std::vector<int32_t> _good_merchant_buy_factor_q16;
	std::vector<uint8_t> _good_trade_enabled;
	std::vector<int32_t> _good_transport_load_per_unit_q16;
	std::vector<std::string> _good_category_ids;
	std::vector<int32_t> _good_storage_modes;
	std::vector<int64_t> _good_monetary_issue_values;
	std::vector<int32_t> _cycle_flow_good_ids;
	std::vector<int32_t> _good_technology_tag_offsets;
	std::vector<std::string> _good_technology_tags;
    std::vector<int32_t> _good_technology_offsets;
    std::vector<int32_t> _good_required_technologies;
    std::vector<int32_t> _merchant_primary_slot;
    std::vector<int32_t> _merchant_offsets;
    std::vector<int32_t> _merchant_slots;
    std::vector<int32_t> _environment_temperature_q16;
    std::vector<int32_t> _environment_temperature_30d_q16;
    std::vector<int32_t> _environment_moisture_q16;
    std::vector<int32_t> _environment_plant_available_water_q16;
    std::vector<int32_t> _environment_precipitation_q16;
    std::vector<int32_t> _environment_snow_q16;
    std::vector<int32_t> _environment_weather_q16;
    std::vector<int32_t> _building_elevation_q16;
    std::vector<uint8_t> _building_terrain;
    std::vector<uint8_t> _building_landform;
    std::vector<uint8_t> _building_vegetation;
    std::vector<uint8_t> _building_is_water;
    std::vector<uint8_t> _building_has_river;
    std::vector<int32_t> _building_neighbors;
    std::vector<int64_t> _resource_snapshot;
    std::vector<int64_t> _resource_remaining;
    // Per-epoch extract allowance for renewable resources. This is derived from
    // the frozen reserve, never serialized, and is shared by all local extractors.
    std::vector<int64_t> _resource_harvest_remaining;
    std::vector<int64_t> _resource_gen_base;
    std::vector<int64_t> _resource_gen_temp;
    std::vector<int64_t> _resource_gen_moisture;
    std::vector<int64_t> _resource_gen_self;
    std::vector<int64_t> _resource_decay_base;
    std::vector<int64_t> _resource_decay_temp;
    std::vector<int64_t> _resource_decay_moisture;
    std::vector<int32_t> _resource_decay_self_q16;
    std::vector<int64_t> _resource_ecology_capacity;
    std::vector<int32_t> _resource_ecology_growth_q16;
    std::vector<int32_t> _resource_temp_lo_q16;
    std::vector<int32_t> _resource_temp_hi_q16;
    std::vector<int64_t> _resource_deltas;
    std::vector<uint32_t> _resource_lane_generation;
    std::vector<size_t> _resource_touched_lanes;
    std::vector<size_t> _last_published_resource_touched_lanes;
    uint32_t _resource_current_generation = 0;
    // Debug/recording visibility for the most recently published building
    // resource changes. It is derived epoch output, not save/hash authority.
    std::vector<int64_t> _last_published_resource_deltas;
    std::vector<std::string> _resource_ids;
    std::vector<std::string> _modifier_sector_ids;
    std::vector<std::string> _modifier_terrain_ids;
    std::vector<std::string> _modifier_landform_ids;
    std::vector<std::string> _resource_reserve_slots;
    std::vector<std::string> _resource_extra_slots;
    int64_t _building_context_day = -1;
    bool _resource_deltas_ready = false;
    int64_t _environment_day = -1;
    int64_t _environment_hash = 0;
    std::vector<int32_t> _market_cell_offsets;
    std::vector<int32_t> _market_cells;
    std::vector<Command> _pending_commands;
    std::vector<Command> _epoch_commands;
    std::unordered_map<int64_t, EffectCommandResult> _effect_command_results;
    std::unordered_map<uint64_t, int64_t> _effect_idempotency_requests;
    int64_t _next_effect_request_id = 1;
    std::vector<StructuralCommand> _structural_commands;
    std::vector<CellSummary> _committed_cells;
    std::vector<CellSummary> _staging_cells;
    std::vector<int32_t> _staging_touched_cells;
    // Per-task landing buffers for the market worker fan-out. Cells are
    // partitioned one-per-market, so summary/generation writes never alias
    // across tasks, but the touched list is a shared vector and must not be
    // grown concurrently. Merged back into _staging_touched_cells after join.
    std::vector<std::vector<int32_t>> _staging_touched_task_scratch;
    std::vector<uint32_t> _staging_cell_generation;
    uint32_t _staging_current_generation = 0;
    std::vector<int32_t> _structural_touched_cells;
    std::vector<int32_t> _population_changed_cells;
    // Number of _structural_touched_cells entries already covered by this
    // epoch's structural_commit employment reconcile. building_commit.finalize
    // re-reconciles only the tail appended after that point (investment
    // profession transitions), instead of double-reconciling the full set.
    int64_t _structural_reconciled_upto = 0;
    std::vector<int64_t> _prosperity_thresholds;
    std::vector<std::string> _prosperity_ids;
    std::vector<std::string> _prosperity_names;
    std::vector<std::string> _settlement_prefix_ids;
    std::vector<std::string> _settlement_prefix_text;
    std::vector<int32_t> _settlement_prefix_weights;
    std::vector<std::string> _settlement_prefix_alias_ids;
    std::vector<std::string> _settlement_prefix_alias_targets;
    std::vector<std::string> _settlement_root_ids;
    std::vector<std::string> _settlement_root_text;
    std::vector<int32_t> _settlement_root_weights;
    std::vector<std::string> _settlement_root_alias_ids;
    std::vector<std::string> _settlement_root_alias_targets;
    std::vector<std::string> _settlement_suffix_ids;
    std::vector<std::string> _settlement_suffix_text;
    std::vector<int32_t> _settlement_suffix_weights;
    std::vector<std::string> _settlement_suffix_alias_ids;
    std::vector<std::string> _settlement_suffix_alias_targets;
    std::string _settlement_name_pack_id = "default_zh";
    std::vector<std::string> _settlement_full_name_ids;
    std::vector<std::string> _settlement_full_name_text;
    std::vector<int32_t> _settlement_full_name_weights;
    std::vector<std::string> _settlement_full_name_alias_ids;
    std::vector<std::string> _settlement_full_name_alias_targets;
    int32_t _settlement_full_name_share_q16 = 32768;
    int32_t _settlement_named_tier = 2;
    int32_t _settlement_downgrade_bp = 9000;
    int64_t _prosperity_profile_hash = 0;
    int64_t _settlement_catalog_hash = 0;
    int64_t _prosperity_changed_cells = 0;
    int64_t _prosperity_promotions = 0;
    int64_t _prosperity_demotions = 0;
    int64_t _settlement_names_assigned = 0;
    int64_t _settlement_names_released = 0;
    int64_t _settlement_name_collision_probes = 0;
    double _prosperity_update_ms = 0.0;
    int64_t _structural_funds_to_treasury = 0;

    std::vector<std::string> _building_type_ids;
	std::vector<int32_t> _building_kinds;
    std::vector<int32_t> _building_economic_sectors;
	std::vector<std::string> _building_upgrade_family_ids;
	std::vector<int32_t> _building_upgrade_family_indices;
	std::vector<int32_t> _building_upgrade_tiers;
	std::vector<int32_t> _building_technology_tag_offsets;
	std::vector<std::string> _building_technology_tags;
	std::vector<int32_t> _building_required_technology_tag_offsets;
	std::vector<std::string> _building_required_technology_tags;
    std::vector<uint32_t> _building_technology_practice_masks;
    std::array<int32_t, 27> _breakthrough_signal_ids{};
    int32_t _bio_maize_signal_id = -1;
    std::array<int32_t, 8> _metal_resource_signal_ids{
        -1, -1, -1, -1, -1, -1, -1, -1};
    std::vector<int32_t> _building_technology_offsets;
    std::vector<int32_t> _building_required_technologies;
    std::vector<int32_t> _building_all_technology_offsets;
    std::vector<int32_t> _building_all_required_technologies;
    // Material/resource dependency gates compiled from Good/Resource technology
    // tags. Operating availability requires every input/output/resource group
    // to have at least one completed technology tag. Construction-good groups
    // (kind 1) gate new builds via good_market_available / material planning,
    // not already-standing lots.
    std::vector<int32_t> _building_dependency_branch_offsets;
    std::vector<int32_t> _building_dependency_branch_technologies;
    std::vector<int32_t> _building_dependency_branch_technology_offsets;
    std::vector<int32_t> _building_dependency_branch_group_offsets;
    std::vector<uint8_t> _building_dependency_kinds;
    std::vector<int32_t> _building_dependency_ids;
    std::vector<int32_t> _building_dependency_tag_offsets;
    std::vector<int32_t> _building_dependency_tags;
    std::vector<std::string> _technology_ids;
    int32_t _water_tech_river = -1;
    int32_t _water_tech_shallow = -1;
    int32_t _water_tech_far = -1;
    int32_t _water_tech_deep = -1;
    std::vector<int32_t> _development_metric_signal_indices;
    std::vector<int32_t> _development_metric_era_indices;
    std::vector<int32_t> _development_metric_types;
    std::vector<int32_t> _development_metric_subject_kinds;
    std::vector<int32_t> _development_metric_subject_offsets;
    std::vector<int32_t> _development_metric_subject_indices;
    std::vector<int64_t> _development_metric_qualifier_thresholds;
    std::vector<int32_t> _development_metric_duration_days;
    int32_t _technology_words = 0;
    NativeCountryRuntime *_country_runtime = nullptr;
    ModifierRuntime *_modifier_runtime = nullptr;
    EffectRuntime *_effect_runtime = nullptr;
    TriggerRuntime *_trigger_runtime = nullptr;
    std::vector<int32_t> _epoch_cell_country;
    std::vector<uint8_t> _epoch_cell_visible;
    int32_t _epoch_player_country_slot = -1;
    bool _epoch_trade_vision_gated = false;
    bool _trade_visibility_manual = false;
    std::vector<uint64_t> _epoch_country_technologies;
    std::vector<uint64_t> _epoch_country_handles;
    // Catalog-resolved tax stat ids and the per-epoch effective integer rates.
    // Only configure/capture touches ModifierRuntime; workers read these dense arrays.
    std::vector<int32_t> _income_tax_stat_ids;
    std::vector<int32_t> _consumption_tax_stat_ids;
    std::vector<int32_t> _business_tax_stat_ids;
    std::vector<int32_t> _import_tax_stat_ids;
    std::vector<int32_t> _export_tax_stat_ids;
    std::vector<int32_t> _country_family_output_stat_ids;
    std::vector<int32_t> _country_good_output_stat_ids;
    std::vector<int32_t> _country_good_input_stat_ids;
    std::vector<int32_t> _country_good_consumption_stat_ids;
    std::vector<int32_t> _country_resource_use_stat_ids;
    std::vector<int32_t> _country_resource_generation_stat_ids;
    std::vector<int32_t> _country_terrain_sector_output_stat_ids;
    std::vector<int32_t> _country_landform_sector_output_stat_ids;
    std::vector<int32_t> _country_building_output_stat_ids;
    int32_t _country_production_input_stat_id = -1;
    int32_t _country_household_consumption_stat_id = -1;
    int32_t _country_resource_use_stat_id = -1;
    std::array<int32_t, 4> _country_climate_loss_stat_ids{-1, -1, -1, -1};
    int32_t _city_birth_stat_id = -1;
    int32_t _city_consumption_stat_id = -1;
    std::vector<int32_t> _city_need_consumption_stat_ids;
    std::vector<int32_t> _city_good_consumption_stat_ids;
    std::vector<int32_t> _city_good_output_stat_ids;
    std::vector<int32_t> _city_building_output_stat_ids;
    std::vector<int8_t> _epoch_income_tax_rates;
    std::vector<int8_t> _epoch_consumption_tax_rates;
    std::vector<int8_t> _epoch_business_tax_rates;
    std::vector<int8_t> _epoch_import_tax_rates;
    std::vector<int8_t> _epoch_export_tax_rates;
    static constexpr size_t CELL_TAX_KIND_COUNT = 5;
    struct CompiledCellTaxOverride {
        int32_t item = -1;
        int8_t rate = 0;
    };
    struct CompiledCellTaxPolicy {
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            default_row_ids{-1, -1, -1, -1, -1};
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            override_begin{};
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            override_end{};
        uint8_t active_mask = 0;
    };
    struct CompiledCellTaxDefaultRow {
        int32_t kind = -1;
        int32_t country = -1;
        int8_t base_rate = 0;
        int32_t offset = 0;
        int32_t count = 0;
    };
    std::vector<uint32_t> _epoch_cell_compiled_tax_policy;
    std::vector<uint8_t> _epoch_cell_active_tax_mask;
    std::vector<CompiledCellTaxPolicy> _epoch_compiled_cell_tax_policies;
    std::vector<CompiledCellTaxOverride> _epoch_compiled_cell_tax_overrides;
    std::vector<CompiledCellTaxDefaultRow> _epoch_compiled_cell_tax_default_rows;
    std::vector<int8_t> _epoch_compiled_cell_tax_default_rates;
    int64_t _epoch_cell_tax_cache_bytes = 0;
    double _epoch_cell_tax_compile_ms = 0.0;
    bool _epoch_has_cell_tax_policies = false;
    uint64_t _epoch_tax_policy_version = 0;
    uint8_t _epoch_active_tax_mask = 0;
    static constexpr int32_t ACTIVE_TAX_KIND_COUNT = 3;
    std::vector<int64_t> _fiscal_previous_requests;
    std::vector<uint64_t> _fiscal_previous_country_handles;
    // Epoch-transient reservation weights. Income lanes are seeded from the
    // frozen minimum-living subsidy floor for current cohorts plus a bounded
    // prospective floor for available owner/employee professions, so a newly
    // enabled negative income rate can attract a transition without waiting
    // for one historical batch. Business lanes get the matching prospective
    // floor on investment-review cells only, bounded by one building of the
    // single most valuable subsidised type.
    std::vector<int64_t> _fiscal_reservation_requests;
    int64_t _fiscal_business_prospective_lanes = 0;
    int64_t _fiscal_business_prospective_request = 0;
    std::vector<int64_t> _fiscal_current_requests;
    std::vector<int64_t> _fiscal_budgets;
    std::vector<int64_t> _fiscal_remaining;
    std::vector<int64_t> _fiscal_epoch_bases;
    std::vector<int64_t> _fiscal_epoch_assessed;
    std::vector<int64_t> _fiscal_epoch_collected;
    std::vector<int64_t> _fiscal_epoch_paid;
    std::vector<int64_t> _fiscal_escrow_by_country;
    std::vector<int64_t> _fiscal_last_bases;
    std::vector<int64_t> _fiscal_last_assessed;
    std::vector<int64_t> _fiscal_last_collected;
    std::vector<int64_t> _fiscal_last_requests;
    std::vector<int64_t> _fiscal_last_reserved;
    std::vector<int64_t> _fiscal_last_paid;
    std::vector<int64_t> _fiscal_last_unmet;
    std::vector<int64_t> _fiscal_last_events;
    std::vector<int64_t> _fiscal_cumulative_bases;
    std::vector<int64_t> _fiscal_cumulative_collected;
    std::vector<int64_t> _fiscal_cumulative_requests;
    std::vector<int64_t> _fiscal_cumulative_paid;
    // Tariffs stay on a sparse cell x {import, export} lane separate from the
    // domestic cell x 3 fiscal arrays. The dense generation-stamped lookup is
    // transient metadata; monetary columns exist only for endpoint lanes
    // touched in the current epoch.
    std::vector<int32_t> _tariff_epoch_cells;
    std::vector<uint8_t> _tariff_epoch_kinds;
    std::vector<int64_t> _tariff_epoch_bases;
    std::vector<int64_t> _tariff_epoch_assessed;
    std::vector<int64_t> _tariff_epoch_collected;
    std::vector<int64_t> _tariff_epoch_requests;
    std::vector<int64_t> _tariff_epoch_reserved;
    std::vector<int64_t> _tariff_epoch_paid;
    std::vector<int64_t> _tariff_epoch_events;
    std::vector<int32_t> _tariff_lane_index;
    std::vector<uint32_t> _tariff_lane_stamp;
    uint32_t _tariff_lane_generation = 0;
    // Tariff subsidies share the country escrow with domestic subsidies. The
    // country vectors are the authoritative reservation budget consumed by
    // dispatch; cell lanes remain the sparse reporting surface.
    std::vector<int64_t> _tariff_country_requests;
    std::vector<int64_t> _tariff_country_budgets;
    std::vector<int64_t> _tariff_country_remaining;
    // Per-slot derived epoch scratch; intentionally excluded from save/hash.
    std::vector<int64_t> _income_taxable_base_by_slot;
    std::vector<int64_t> _income_subsidy_floor_by_slot;
    std::vector<int32_t> _epoch_country_output_factor_q16;
    std::vector<int32_t> _epoch_country_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_research_output_factor_q16;
    std::vector<int32_t> _epoch_country_family_output_factor_q16;
    std::vector<int32_t> _epoch_country_good_output_factor_q16;
    std::vector<int32_t> _epoch_country_good_input_factor_q16;
    std::vector<int32_t> _epoch_country_good_consumption_factor_q16;
    std::vector<int32_t> _epoch_country_resource_use_factor_q16;
    std::vector<int32_t> _epoch_country_resource_generation_factor_q16;
    std::vector<int32_t> _epoch_country_terrain_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_landform_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_building_output_factor_q16;
    std::vector<int32_t> _epoch_country_production_input_factor_q16;
    std::vector<int32_t> _epoch_country_household_consumption_factor_q16;
    std::vector<int32_t> _epoch_country_resource_global_use_factor_q16;
    std::vector<int32_t> _epoch_country_climate_loss_factor_q16;
    std::vector<int32_t> _epoch_country_trade_capacity_factor_q16;
    std::vector<int32_t> _epoch_country_trade_speed_factor_q16;
    std::vector<uint8_t> _epoch_country_water_capability;
    std::vector<int32_t> _epoch_country_construction_cost_factor_q16;
    std::vector<int32_t> _epoch_country_construction_time_factor_q16;
    std::vector<int32_t> _epoch_cell_birth_factor_q16;
    std::vector<int32_t> _epoch_cell_need_consumption_factor_q16;
    std::vector<int32_t> _epoch_cell_good_consumption_factor_q16;
    std::vector<int32_t> _epoch_cell_rain_event_threshold_q16;
    std::vector<int32_t> _epoch_cell_cold_capacity_factor_q16;
    std::vector<int32_t> _epoch_cell_sector_output_factor_q16;
    std::vector<int32_t> _family_policy_stamped_cells;
    // The city factor tables are pure functions of the city stat buckets in the
    // ECONOMY modifier store, so they survive across epochs and are rebuilt only
    // when those buckets (or the catalog shape behind the tables) change. The
    // cached shared row is what every cell without a group bucket holds, so a
    // rebuild only has to repaint the cells listed in _city_factor_dirty_cells.
    uint64_t _epoch_city_factor_stat_version = 0;
    bool _epoch_city_factor_valid = false;
    int32_t _city_factor_shared_birth_q16 = Q16_ONE;
    std::vector<int32_t> _city_factor_shared_needs_q16;
    std::vector<int32_t> _city_factor_shared_goods_q16;
    std::vector<int32_t> _city_factor_dirty_cells;
    std::vector<uint64_t> _city_factor_group_cells_scratch;
    std::vector<int32_t> _city_factor_stat_ids_scratch;
    // Exact city-good production factors use one shared global row plus sparse
    // per-cell overrides. The CSR scales with authored effects, not
    // `cell_count * good_count`, and is rebuilt only when one of those stats
    // changes. Transient; never saved or hashed.
    uint64_t _epoch_city_output_factor_stat_version = 0;
    bool _epoch_city_output_factor_valid = false;
    std::vector<int32_t> _city_output_shared_goods_q16;
    std::vector<int32_t> _city_output_cell_offsets;
    std::vector<int32_t> _city_output_good_indices;
    std::vector<int32_t> _city_output_factors_q16;
    std::vector<uint64_t> _city_output_scope_cells_scratch;
    std::vector<int32_t> _city_output_scope_stat_ids_scratch;
    // Epoch-transient country/type availability cache. Technology authority is
    // frozen once per daily transaction, so every cell in a country shares the
    // same result and hot loops can consume the ascending CSR directly.
    std::vector<uint8_t> _epoch_country_building_available;
    std::vector<uint8_t> _epoch_country_good_available;
    std::vector<uint8_t> _epoch_country_market_available;
    std::vector<uint8_t> _epoch_country_profession_available;
    std::vector<uint8_t> _epoch_country_variant_available;
    std::vector<int32_t> _epoch_country_building_type_offsets;
    std::vector<int32_t> _epoch_country_building_type_indices;
    // Social-development inputs frozen with the country epoch. Technology
    // progress is one popcount per country; the per-cell value additionally
    // folds in settlement tier and local built-industry variety so the hot loop
    // only reads a single Q16 per cell.
    std::vector<int32_t> _epoch_country_technology_progress_q16;
    std::vector<int32_t> _epoch_cell_development_q16;
    // Population-weighted survival-plan cost per person per day, refreshed by
    // compute_cell_living_costs_from_basis. Derived diagnostics only: it is the
    // savings dimension's denominator and never moves money.
    std::vector<int64_t> _cell_living_cost_per_capita;
    // Last published social-pressure level per cell. Persisted so a reload does
    // not replay a level-crossing event that already fired.
    std::vector<uint8_t> _cell_social_pressure_level;
    // Slow EMA of the surplus×sat mix factor. Fertility reads this so a single
    // harvest spike does not jump K_eff. Persisted in PKEC v36.
    std::vector<int32_t> _cell_support_ema_q16;
    // Derived carrying diagnostics. Not hashed except support EMA; Inspector only.
    std::vector<int64_t> _cell_carrying_k_geo;
    std::vector<int64_t> _cell_carrying_k_eff;
    std::vector<int32_t> _cell_carrying_surplus_q16;
    std::vector<int32_t> _cell_carrying_sat_q16;
    std::vector<int32_t> _cell_carrying_family_surplus_q16;
    std::vector<uint8_t> _cell_carrying_family_bindable;
    int32_t _epoch_country_count = 0;
    int32_t _epoch_country_technology_words = 0;
    uint64_t _epoch_country_generation = 0;
    uint64_t _epoch_country_hash = 0;
    uint64_t _epoch_country_topology_hash = 0;
    // Merchant capacity is frozen with the country snapshot so dispatch does
    // not rescan every map cell on each trade slice.
    std::vector<int64_t> _epoch_country_merchant_population;
    std::vector<BuildingType> _building_types;
    std::vector<std::string> _production_climate_profile_ids;
    std::vector<ProductionClimateProfile> _production_climate_profiles;
    // Catalog-baked, sorted unique signal edges per building type. Topology
    // rebuilds consume these spans instead of walking nested recipe columns.
    std::vector<int32_t> _building_type_market_signal_goods;
    std::vector<int32_t> _building_type_labor_signal_professions;
    std::vector<JobRole> _building_employee_roles;
    std::vector<GoodAmount> _building_construction_goods;
    // Candidate CSR is parallel to _building_construction_goods. The legacy
    // preferred good remains the first-class group identity; each slice is an
    // OR list of regional substitutes for that required group.
    std::vector<int32_t> _building_construction_candidate_offsets;
    std::vector<ConstructionCandidate> _building_construction_candidates;
    std::vector<int32_t> _building_maintenance_author_offsets;
    std::vector<GoodAmount> _building_maintenance_author_goods;
    std::vector<GoodAmount> _building_maintenance_goods;
    std::vector<ProductionInput> _building_inputs;
    std::vector<InputCandidate> _building_input_candidates;
    std::vector<GoodAmount> _building_outputs;
    std::vector<int32_t> _building_output_cost_shares_q16;
    std::vector<ResourceAmount> _building_resources;
    std::vector<ResourceAmount> _building_resource_generation;
    std::vector<ConditionToken> _building_conditions;
    std::vector<BuildingGroup> _buildings;
    // Kit settlement may append groups during LEDGER_APPLY. Reordering and
    // market-signal rebuild wait for BUILDING_COMMIT so frozen epoch group
    // indices and production reserves stay aligned. Idle-boundary landings
    // rebuild immediately and leave this false.
    bool _pending_building_topology_rebuild = false;
    // Handle -> compact group index acceleration for `_buildings`. Rebuilt
    // lazily whenever the group lane changes size and verified on every hit,
    // so a stale entry degrades into a rebuild instead of a wrong index.
    mutable std::unordered_map<uint64_t, int32_t> _building_handle_index;
    mutable size_t _building_handle_index_stamp = static_cast<size_t>(-1);
    mutable bool _building_handle_index_clean = false;
    // Transient topology scratch and reusable role/input spans. Structural
    // commits swap the compact group lane but keep authoritative role arrays
    // in place; these caches are reconstructed after configure/restore.
    std::vector<BuildingGroup> _building_groups_rebuild_scratch;
    std::vector<int32_t> _building_existing_indices_scratch;
    std::vector<int32_t> _building_new_indices_scratch;
    std::vector<int64_t> _building_investment_score_rebuild_scratch;
    std::vector<int64_t> _building_investment_payback_rebuild_scratch;
    std::vector<int32_t> _building_investment_rejection_rebuild_scratch;
    std::vector<std::vector<BuildingRoleSpan>> _building_free_role_spans_by_type;
    std::vector<uint32_t> _building_market_signal_stamp;
    std::vector<uint32_t> _building_labor_signal_stamp;
    uint32_t _building_market_signal_stamp_generation = 0;
    uint32_t _building_labor_signal_stamp_generation = 0;
    std::vector<int32_t> _building_cell_offsets;
    std::vector<int32_t> _building_active_cells;
    // Transient CSR baked from stable building order. Recovery reviews touch
    // only the current cell-modulo-review bucket instead of scanning all groups.
    std::vector<int32_t> _building_review_phase_offsets;
    std::vector<int32_t> _building_review_group_indices;
    std::vector<int32_t> _building_special_reset_group_indices;
    std::vector<int64_t> _building_employee_filled;
    // Inspector-only last purchased good per (building group, input slot).
    // This diagnostic lane is intentionally excluded from save and state hash.
    std::vector<int32_t> _building_last_input_selected_goods;
    std::vector<int64_t> _building_role_contract_wage;
    std::vector<int64_t> _building_role_base_living_cost;
    std::vector<int64_t> _building_role_living_cost;
    std::vector<int64_t> _building_role_local_average_wage;
    std::vector<int64_t> _building_role_base_wage_due;
    std::vector<int64_t> _building_role_base_wage_paid;
    std::vector<int64_t> _building_role_bonus_due;
    std::vector<int64_t> _building_role_bonus_paid;
    std::vector<PendingConstruction> _pending_construction;
    // Epoch-transient stable CSR over pending construction. This removes the
    // previous all-pending scan from every active building cell.
    std::vector<int32_t> _pending_construction_cell_offsets;
    std::vector<int32_t> _pending_construction_cell_indices;
    int64_t _building_catalog_hash = 0;
    int64_t _building_catalog_compat_hash_v6 = 0;
    int64_t _building_catalog_compat_hash_v7 = 0;
    int64_t _building_catalog_compat_hash_v13 = 0;
    int64_t _catalog_compat_hash_v7 = 0;
    int64_t _catalog_compat_hash_v8 = 0;
    int64_t _catalog_compat_hash_v10 = 0;
    int64_t _catalog_compat_hash_v13 = 0;
    int64_t _catalog_compat_hash_v39 = 0;
    int64_t _family_catalog_hash = 0;
    int64_t _family_catalog_compat_hash_v39 = 0;
    int32_t _family_trait_catalog_version = 0;
    int64_t _family_trait_catalog_hash = 0;
    int32_t _family_core_trait_min = 0;
    int32_t _family_core_trait_max = 0;
    std::vector<std::string> _family_trait_ids;
    std::vector<std::string> _family_trait_display_names;
    std::vector<int32_t> _family_trait_weights;
    std::vector<uint8_t> _family_trait_core_eligible;
    std::vector<int32_t> _family_trait_strength_min_q16;
    std::vector<int32_t> _family_trait_strength_max_q16;
    std::vector<int32_t> _family_trait_strength_step_q16;
    std::vector<int32_t> _family_trait_prerequisite_offsets;
    std::vector<int32_t> _family_trait_prerequisites;
    std::vector<int32_t> _family_trait_exclusion_offsets;
    std::vector<int32_t> _family_trait_exclusions;
    std::vector<int32_t> _family_trait_technology_prerequisite_offsets;
    std::vector<int32_t> _family_trait_technology_prerequisites;
    std::vector<uint8_t> _family_trait_technology_match_any;
    std::vector<int32_t> _family_trait_behavior_offsets;
    std::vector<int32_t> _family_trait_behavior_axes;
    std::vector<int32_t> _family_trait_behavior_selector_kinds;
    std::vector<int32_t> _family_trait_behavior_selector_ids;
    std::vector<int32_t> _family_trait_behavior_factors_q16;
    std::vector<int32_t> _family_trait_behavior_score_terms;
    std::vector<int32_t> _family_trait_behavior_condition_offsets;
    std::vector<int32_t> _family_trait_behavior_condition_ops;
    std::vector<int32_t> _family_trait_behavior_condition_arg0;
    std::vector<int64_t> _family_trait_behavior_condition_values;
    std::vector<int32_t> _family_trait_modifier_offsets;
    std::vector<std::string> _family_trait_modifier_definition_keys;
    std::vector<int32_t> _family_trait_modifier_targets;
    std::vector<int32_t> _family_trait_modifier_tier_magnitudes_q16;
    std::vector<int32_t> _family_trait_trigger_offsets;
    std::vector<std::string> _family_trait_trigger_definition_keys_by_tier;
    std::vector<int32_t> _family_trait_trigger_reward_targets;
    std::vector<int32_t> _family_trait_effect_offsets;
    std::vector<std::string> _family_trait_effect_keys;
    std::vector<int32_t> _family_trait_origin_landform_offsets;
    std::vector<uint8_t> _family_trait_origin_landforms;
    std::vector<uint8_t> _family_trait_origin_adjacent_water;
    std::vector<int32_t> _family_trait_origin_population_max;
    std::vector<int32_t> _family_trait_origin_temperature_max_q16;
    std::vector<int32_t> _family_trait_required_resource_offsets;
    std::vector<int32_t> _family_trait_required_resource_ids;
    std::vector<uint8_t> _family_trait_require_tax_or_subsidy;
    int32_t _family_effect_catalog_version = 0;
    int64_t _family_effect_catalog_hash = 0;
    std::vector<std::string> _family_effect_keys;
    std::vector<int32_t> _family_effect_source_kinds;
    std::vector<int32_t> _family_effect_weights;
    std::vector<uint8_t> _family_effect_random_pool_eligible;
    std::vector<int32_t> _family_effect_prerequisite_offsets;
    std::vector<int32_t> _family_effect_prerequisites;
    std::vector<uint8_t> _family_effect_technology_match_any;
    std::vector<int32_t> _family_effect_exclusion_offsets;
    std::vector<int32_t> _family_effect_exclusions;
    std::vector<int32_t> _family_effect_magnitude_by_prestige_q16;
    std::vector<std::string> _family_effect_trigger_definition_keys_by_tier;
    std::vector<int32_t> _family_effect_trigger_reward_targets;
    int32_t _family_corn_good_id = -1;
    int32_t _family_knowledge_class_index = -1;
    struct PendingFamilySplitGift {
        uint64_t family_handle = 0;
        int32_t cell = -1;
        uint16_t flags = 0;
        int32_t building_type_id = -1;
        int64_t population = 0;
    };
    std::vector<PendingFamilySplitGift> _pending_family_split_gifts;
    std::string _family_surname_pack_id = "default_zh";
    std::vector<std::string> _family_surname_ids;
    std::vector<std::string> _family_surname_text;
    std::vector<int32_t> _family_surname_weights;
    std::vector<int32_t> _family_surname_culture_group_ids;
    std::vector<std::string> _family_culture_group_ids;
    std::vector<std::string> _family_culture_group_display_names;
    std::vector<std::string> _family_culture_group_naming_formats;
    std::vector<std::string> _family_culture_group_separators;
    std::vector<std::string> _family_culture_group_suffixes;
    int64_t _person_catalog_hash = 0;
    std::string _person_given_name_pack_id = "default_zh";
    std::vector<std::string> _person_given_name_ids;
    std::vector<std::string> _person_given_name_text;
    std::vector<int32_t> _person_given_name_weights;

    // Notable-family policy. The anonymous majority remains implicit.
    int32_t _family_runtime_mode = 2; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int32_t _family_min_settlement_tier = 2;
    int32_t _family_review_days = 30;
    int64_t _family_min_population_per_active = 150;
    int64_t _family_split_population_threshold = 100;
    int32_t _family_max_per_cell = 8;
    int32_t _family_cells_per_slice = 128;
    int32_t _family_decline_reviews = 3;
    // Notable households include dependents of the owned owner posts, not just
    // the two shopkeepers. Anonymous majority stays implicit.
    int32_t _family_household_people_per_owner_slot = 256;
    int32_t _family_household_max_people = 1024;
    int32_t _person_runtime_mode = 2; // 0=OFF, 1=PROBE, 2=ACTIVE.
    int32_t _person_max_per_family = 4;
    int32_t _person_max_per_cell = 128;
    int32_t _person_max_total = 65536;
    int32_t _person_records_per_slice = 4096;

    SaveState _save;
    RestoreState _restore;

    void register_builtin_formulas();
    bool compile_catalog(const godot::Dictionary &catalog, std::string &error);
    bool configure_profile(const godot::Dictionary &profile, std::string &error);
    godot::Dictionary run_slice_internal(const godot::Dictionary &ctx, bool compact);
    godot::Dictionary compact_report() const;
    godot::Dictionary household_slice_breakdown_ms() const;
    godot::Dictionary household_slice_breakdown_work() const;
    bool start_epoch(int64_t day_index, std::string &error);
    bool trade_planner_should_run() const;
    bool run_trade_planner_slice(int64_t &work_done, std::string &error);
    bool begin_trade_plan_slice(int64_t &work_done, std::string &error);
    bool trade_vision_allows_pair(int32_t source, int32_t destination) const;
    bool route_trade_source(int32_t source_index, int32_t expansion_budget,
                            int32_t &expansions_done, bool &source_done,
                            std::string &error);
    int32_t cached_trade_route_cost(int32_t source, int32_t destination,
                                    int32_t country, int32_t &expansions);
    void collect_transport_successors(int32_t cell, uint8_t cap, bool reverse);
    void build_water_transport_graphs();
    void build_water_portal_graph(int32_t graph_index);
    void build_water_component_layers();
    bool reconstruct_water_corridor(int32_t from_portal, int32_t to_portal,
                                    uint8_t cap,
                                    std::vector<int32_t> &water_cells) const;
    void fill_trade_water_columns(const uint8_t *terrain, const uint8_t *landform,
                                  const uint8_t *has_river, int32_t count,
                                  std::vector<uint8_t> &water_class,
                                  std::vector<uint8_t> &river) const;
    bool append_colonization_route_step(int32_t from_cell, int32_t to_cell,
                                        uint8_t cap, int64_t reverse_from,
                                        int64_t reverse_to,
                                        std::vector<int32_t> &route,
                                        std::vector<int32_t> &cumulative,
                                        int64_t &running) const;
    static uint64_t trade_route_cache_key(int32_t source, int32_t destination,
                                          int32_t layer);
    int32_t estimate_trade_price(int32_t market, int32_t good,
                                 int64_t stock_after, int64_t &sat) const;
    int64_t trade_relief_pressure_q16(int32_t market, int32_t good,
                                      int64_t &sat) const;
    int64_t trade_local_stock_target(int32_t market, int32_t good,
                                     int64_t &sat) const;
    int64_t trade_export_floor(int32_t market, int32_t good,
                               int64_t &sat) const;
    int64_t profitable_trade_quantity(int32_t source, int32_t destination,
                                      int32_t good, int64_t max_quantity,
                                      bool relief_route, int32_t &source_price,
                                      int32_t &destination_price,
                                      int64_t &profit, int64_t &margin_q16,
                                      int64_t &sat) const;
    TradeQuote make_trade_quote(int32_t source, int32_t destination,
                                int32_t good, int64_t quantity,
                                int32_t source_price,
                                int32_t destination_price,
                                bool relief_route,
                                int64_t &saturation_count) const;
    int64_t merchant_inventory_target(int32_t market, int32_t good,
                                      int32_t signal_index,
                                      int64_t realized_withdrawal,
                                      int64_t export_ema,
                                      int64_t cold_start_daily_supply,
                                      int64_t &sat) const;
    int64_t merchant_procurement_quota(int32_t market, int32_t good,
                                       int32_t signal_index,
                                       int64_t sellable,
                                       int64_t target,
                                       int64_t stock,
                                       int64_t realized_withdrawal,
                                       int64_t export_ema,
                                       int64_t &sat) const;
    int32_t effective_merchant_buy_factor_q16(
        int32_t market, int32_t good, int64_t target, int64_t stock,
        int64_t &sat) const;
    bool settle_due_trade_orders(std::string &error);
    bool dispatch_trade_candidates(std::string &error);
    void update_trade_flow_ema();
    int32_t trade_flow_index(int32_t cell, int32_t good, bool create);
    int32_t trade_signal_clock_index(int32_t cell, int32_t good) const;
    int32_t ensure_trade_signal_clock_index(int32_t cell, int32_t good);
    void ensure_trade_signal_clock_keys_bulk(
        const std::vector<uint64_t> &sorted_unique_keys);
    void record_trade_signal_attempt(int32_t cell, int32_t good, int32_t reason);
    void refresh_trade_response_diagnostics();
    int64_t credit_trade_sellers(int32_t order_index, int64_t amount,
                                 int32_t cashflow_source = CASHFLOW_MERCHANT_BUSINESS);
    int64_t debit_trade_sellers(int32_t order_index, int64_t amount,
                                int32_t cashflow_source);
    void rebuild_trade_arrival_buckets();
    void compact_trade_orders(const std::vector<uint8_t> &remove);
    void rebuild_country_trade_indices();
    void sort_dirty_country_trade_display_indices();
    int64_t trade_transit_goods() const;
    int64_t trade_escrow_cash() const;
    bool apply_command(const Command &cmd, std::string &error);
    bool validate_command_pod(const Command &cmd, std::string &error) const;
    bool family_ledger_command_preflight(const Command &cmd) const;
    bool family_split_policy_command_preflight(const Command &cmd) const;
    bool apply_family_free_building_reward(const Command &cmd,
                                           std::string &error);
    bool apply_family_population_reward(const Command &cmd,
                                        std::string &error);
    bool apply_family_absorb_anonymous(const Command &cmd,
                                       std::string &error);
    bool apply_family_purchase_discount(const Command &cmd,
                                        std::string &error);
    bool apply_family_set_split_policy(const Command &cmd,
                                       std::string &error);
    bool process_market_cell(int32_t market, MarketResult &result, std::string &error);
    bool commit_structural(const StructuralCommand &cmd, std::string &error);
    // Core cohort migration primitive extracted from commit_structural. Moves up
    // to `requested_pop` people from `source` into the (dest_cell, dest_signature)
    // cohort, carrying a proportional share of funds/income/expense/ema/residual,
    // population-weighting needs_satisfaction, and transferring any rounding
    // residue of a fully-drained source to the treasury (never burned). Pushes
    // both cells onto _structural_touched_cells and appends a structural trace.
    // Callers are responsible for command-level guards (profession_available,
    // same-cell/same-signature no-op) before invoking it. Returns false only on a
    // hard failure (allocation / treasury transfer); an empty move is a no-op true.
    //
    // `source_drained_out` (optional): set to true when the move emptied `source`
    // and released its slot, false otherwise. The employment pass (in-line layoff
    // / hiring) iterates a *snapshot* of a cell's slots -- it must never migrate
    // from inside for_each_in_cell -- and uses this flag to skip a snapshot slot
    // that a prior migration in the same loop already released, preventing
    // stale-slot reuse. When null it is ignored (commit_structural path).
    bool move_cohort_population(int32_t source, int32_t dest_cell,
                                int32_t dest_signature, int64_t requested_pop,
                                std::string &error,
                                bool *source_drained_out = nullptr,
                                uint64_t preferred_family_handle = 0);
    bool apply_start_family_expedition(const Command &cmd,
                                       std::string &error);
    bool apply_cancel_family_expedition(const Command &cmd,
                                        std::string &error);
    bool apply_settle_family_expedition(const Command &cmd,
                                        std::string &error);
    bool extract_family_expedition_payload(int32_t expedition,
                                           int64_t requested,
                                           std::string &error);
    void unwind_family_expedition_payload_extract(int32_t expedition);
    bool extract_family_expedition_cargo(int32_t expedition,
                                         const ColonizationKitPlan &kit,
                                         std::string &error);
    bool restore_family_expedition_cargo(int32_t expedition,
                                         int32_t destination_cell,
                                         bool consume_construction,
                                         std::string &error);
    bool restore_family_expedition_payload(int32_t expedition,
                                            int32_t destination_cell,
                                            std::string &error);
    bool settle_family_expedition_kit(int32_t expedition,
                                      int32_t destination_cell,
                                      std::string &error);
    bool finalize_immediate_family_expedition_settlement(
        int32_t destination_cell, std::string &error);
    void release_family_expedition_reservations(int32_t expedition);
    bool process_due_family_expeditions(int64_t day, std::string &error);
    int64_t family_expedition_displayed_population(int32_t expedition) const;
    int64_t market_stock(int32_t cell, int32_t good_id) const;
    bool colonization_good_is_tools(int32_t good_id) const;
    uint64_t hash_preparing_missing_stock(int32_t source_cell,
                                          const int32_t *good_ids,
                                          uint32_t count) const;
    void store_preparing_missing_goods(int32_t expedition,
                                       const ColonizationKitPlan &kit);
    void refresh_preparing_family_expedition_missing(int32_t expedition);
    void abort_preparing_family_expedition(int32_t expedition, int64_t day,
                                           uint8_t kind, const char *code);
    bool launch_preparing_family_expedition(int32_t expedition, int64_t day,
                                            const ColonizationKitPlan &kit,
                                            std::string &error);
    bool advance_preparing_family_expedition(int32_t expedition, int64_t day,
                                             std::string &error);
    bool family_expedition_settle_inflight(uint64_t expedition_handle) const;
    void recover_lost_family_settlement_commands();
    bool stage_allows_in_epoch_family_settlement() const;
    void queue_family_settlement_command(const Command &command);
    void rebuild_family_expedition_indices();
    void push_family_expedition_due(int32_t expedition);
    void append_colonization_receipt(int32_t expedition, int64_t sequence,
                                     int64_t effective_day, int64_t settled_day,
                                     uint8_t kind, const char *code);
    void append_colonization_command_receipt(uint64_t country_handle,
                                             uint64_t expedition_handle,
                                             int32_t target_cell,
                                             int64_t sequence,
                                             int64_t effective_day,
                                             int64_t settled_day,
                                             uint8_t kind, const char *code);
    bool pending_family_expedition_target_taken(uint64_t country_handle,
                                                int32_t target_cell) const;
    bool pending_family_expedition_cancel_taken(uint64_t expedition_handle) const;
    bool has_pending_family_expedition_player_command() const;
    bool apply_family_expedition_player_command(const Command &cmd,
                                                std::string &error);
    int64_t family_population_in_cell(uint64_t family_handle,
                                      int32_t cell) const;
    bool colonization_target_owner_allowed(uint64_t country_handle,
                                           int32_t cell) const;
    bool colonization_destination_family_allowed(uint64_t family_handle,
                                                 int32_t cell) const;
    bool plan_family_colonization_route(uint64_t country_handle,
                                        int32_t source_cell,
                                        int32_t target_cell,
                                        const uint8_t *visible,
                                        int32_t visible_count,
                                        std::vector<int32_t> &route,
                                        std::vector<int32_t> &cumulative,
                                        int32_t &cost,
                                        std::string &error);
    uint64_t colonization_visibility_hash(const uint8_t *visible,
                                          int32_t count) const;
    uint64_t family_expedition_target_key(uint64_t country_handle,
                                          int32_t target_cell) const;
    bool cell_has_submitted_or_pending_buildings(int32_t cell) const;
    bool colonization_kit_type_eligible(int32_t source_cell, int32_t target_cell,
                                        int32_t type_id, bool frozen) const;
    int64_t colonization_kit_output_per_building(int32_t target_cell,
                                                 int32_t type_id,
                                                 int32_t good_id) const;
    int64_t colonization_kit_input_per_building(int32_t type_id,
                                                int32_t good_id) const;
    int64_t colonization_kit_daily_food_required(int32_t target_cell,
                                                 int64_t population) const;
    uint64_t hash_colonization_kit_plan(const ColonizationKitPlan &kit) const;
    void fill_colonization_kit_buffer(int32_t source_cell, int32_t target_cell,
                                      int64_t population, int32_t travel_days,
                                      ColonizationKitPlan &kit) const;
    void add_colonization_kit_cargo(ColonizationKitPlan &kit, int32_t good_id,
                                    int64_t quantity, uint8_t flags,
                                    int64_t &sat) const;
    void sort_colonization_kit_cargo(ColonizationKitPlan &kit) const;
    bool plan_colonization_kit(int32_t source_cell, int32_t target_cell,
                               int64_t population, int32_t travel_days,
                               bool frozen, ColonizationKitPlan &kit,
                               bool ignore_existing = false) const;
    bool adjust_market_stock(int32_t cell, int32_t good_id, int64_t delta,
                             std::string &error);
    bool publish_epoch_slice(int64_t &work_done, std::string &error);
    void reset_publish_state();
    bool compile_building_catalog(const godot::Dictionary &catalog, std::string &error);
    bool compile_carrying_catalog(const godot::Dictionary &catalog, std::string &error);
    void refresh_epoch_carrying_yields();
    int64_t carrying_mix_q16(int64_t value_q16, int32_t elasticity_q16,
                             int64_t &sat) const;
    int64_t carrying_climate_habitability_q16(int32_t cell, int64_t &sat) const;
    int64_t carrying_resource_stock(int32_t resource_id, int32_t cell) const;
    int64_t cell_k_geo_persons(int32_t cell, int64_t &sat) const;
    int64_t cell_family_surplus_q16(int32_t market, int32_t cell, int32_t family,
                                    int64_t food_filled, int64_t food_desired,
                                    const int64_t *good_demand,
                                    const int64_t *good_sales,
                                    int64_t &sat) const;
    void append_carrying_capacity_fields(godot::Dictionary &out,
                                         int32_t cell_idx) const;
    bool evaluate_building_conditions(int32_t type_id, int32_t cell) const;
    bool cell_has_technology(int32_t cell, int32_t technology_id, bool frozen) const;
    bool cell_has_requirements(int32_t cell, int32_t begin, int32_t end,
                               const std::vector<int32_t> &requirements,
                               bool frozen) const;
    bool cell_has_all_requirements(int32_t cell, int32_t begin, int32_t end,
                                   const std::vector<int32_t> &requirements,
                                   bool frozen) const;
    bool good_production_available(int32_t cell, int32_t good_id,
                                   bool frozen = true) const;
    bool good_market_available(int32_t cell, int32_t good_id,
                               bool frozen = true) const;
    // Compatibility name for callers that are explicitly asking for the
    // technology gate (UI/building unlock queries).
    bool good_available(int32_t cell, int32_t good_id, bool frozen = true) const;
    bool profession_available(int32_t cell, int32_t profession_id,
                              bool frozen = true) const;
    bool building_available(int32_t cell, int32_t type_id,
                            bool frozen = true) const;
    bool building_dependency_requirements_met(int32_t cell, int32_t type_id,
                                              bool frozen) const;
    bool building_dependency_group_required_for_operation(int32_t group) const;
    bool building_constructible(int32_t cell, int32_t type_id,
                                bool frozen = true) const;
    int64_t allocated_output_operating_cost(
        const BuildingType &type, int32_t output_index,
        int64_t operating_cost, int64_t &sat) const;
    // O(1) signature lookup helpers backed by _signature_by_profession_ethnicity.
    // Return -1 when no such signature exists (e.g. unemployed profession absent).
    inline int32_t signature_for_profession_ethnicity(int32_t profession_id,
                                                       int32_t ethnicity_id) const {
        if (profession_id < 0 || ethnicity_id < 0) return -1;
        const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());
        if (ethnicity_id >= n_eth) return -1;
        const size_t idx = static_cast<size_t>(profession_id) * static_cast<size_t>(n_eth) +
                           static_cast<size_t>(ethnicity_id);
        if (idx >= _signature_by_profession_ethnicity.size()) return -1;
        return _signature_by_profession_ethnicity[idx];
    }
    inline int32_t unemployed_signature_for_ethnicity(int32_t ethnicity_id) const {
        return signature_for_profession_ethnicity(_unemployed_profession_id, ethnicity_id);
    }
    void configure_satisfaction_profile(const godot::Dictionary &profile);
    bool capture_country_epoch(std::string &error);
    void refresh_epoch_development();
    // Writes the authoritative composite/dimension columns for one cohort and
    // returns the composite. `tier_*_q16` point at the SAT_TIER_COUNT-wide slice
    // the household need reduction just produced for this cohort.
    int64_t update_cohort_satisfaction(int32_t slot, int32_t cell,
                                       int64_t subsistence_q16,
                                       const Signature &signature,
                                       const int64_t *tier_weighted_q16,
                                       const int64_t *tier_weight_q16,
                                       int64_t &sat);
    int64_t normalize_band_q16(int64_t value, int64_t floor, int64_t ceiling,
                               int64_t &sat) const;
    int32_t living_standard_level_for(int64_t composite_q16) const;
    // Social-pressure level 0..4, ascending with satisfaction: 0 is the most
    // distressed band and 4 is contentment.
    int32_t social_pressure_level_for(int64_t composite_q16) const;
    void publish_social_pressure_facts();
    void publish_technology_practice_facts();
    void publish_country_development_facts();
    bool prepare_fiscal_budgets(int64_t day_index, std::string &error);
    int64_t prospective_business_subsidy_request(int32_t cell, int32_t country);
    void settle_income_subsidies_for_cell(int32_t cell,
                                          int64_t &saturation_count);
    bool commit_fiscal(std::string &error);
    int8_t frozen_tax_rate(int32_t cell, int32_t kind, int32_t item) const;
    int64_t apply_fiscal_tax(int32_t cell, int32_t kind, int64_t base,
                             int8_t rate, int64_t &saturation_count);
    int64_t expected_fiscal_transfer(int32_t cell, int32_t kind, int64_t base,
                                     int8_t rate,
                                     int64_t &saturation_count) const;
    int32_t tariff_epoch_lane_index(int32_t cell, int32_t tariff_kind,
                                    bool create);
    int64_t expected_after_tax_income(int32_t cell, int32_t profession,
                                      int64_t gross_income,
                                      int64_t &saturation_count) const;
    int64_t fiscal_escrow_total() const;
    bool apply_build_command(const Command &cmd, int32_t owner_slot,
                             std::string &error, bool allow_obsolete_tier = false);
    bool plan_construction_materials(int32_t cell, int32_t type_id,
                                     int64_t count, int32_t cost_factor_q16,
                                     ConstructionMaterialPlan &plan,
                                     const std::vector<int64_t> *additional_stock = nullptr,
                                     std::vector<int64_t> *stock_inout = nullptr,
                                     bool split_candidates = false) const;
    bool apply_demolish_command(const Command &cmd, int32_t owner_slot, std::string &error);
    bool run_building_employment_cell(int32_t cell,
                                      bool allow_owner_job_reallocation,
                                      std::string &error);
    void replace_employment_metrics_for_cell(int32_t cell, int64_t owner_jobs,
                                             int64_t employee_jobs,
                                             int64_t unemployed_population);
    bool reconcile_building_employment_after_population_change(
        const std::vector<int32_t> &affected_cells, std::string &error);
    bool reconcile_building_employment_cells_range(
        const std::vector<int32_t> &stable_cells, int32_t begin, int32_t end,
        std::string &error);
    bool run_building_production_cell(int32_t cell, ProductionResult &result,
                                      std::string &error);
    void merge_building_production_result(ProductionResult &result);
    bool run_endogenous_building_investment(int32_t ordinal_begin,
                                            int32_t ordinal_end,
                                            bool initialize,
                                            bool &population_changed,
                                            std::string &error);
    void prepare_investment_review_cells();
    void begin_investment_scratch_generation();
    void ensure_investment_cell_finance_lane(int32_t cell);
    void ensure_investment_resource_commitment_lane(size_t index);
    int64_t investment_merchant_cash(int32_t cell) const;
    int64_t investment_outstanding_credit(int32_t cell) const;
    int64_t investment_resource_committed(size_t index) const;
    void prepare_startup_demand();
    void propagate_startup_demand_for_cell(int32_t cell);
    void begin_startup_demand_generation();
    void record_startup_demand(int32_t cell, int32_t good_id,
                               int64_t daily_quantity);
    int64_t startup_demand_for(int32_t cell, int32_t good_id) const;
    int64_t remote_startup_demand_for(int32_t cell, int32_t good_id) const;
    void consume_remote_startup_demand(int32_t cell, int32_t good_id,
                                       int64_t daily_capacity);
    int32_t select_startup_producer(int32_t cell, int32_t good_id) const;
    int32_t select_startup_input_candidate(int32_t cell,
                                           const ProductionInput &input,
                                           int64_t &physical_daily) const;
    int32_t select_startup_construction_candidate(int32_t cell,
                                                  int32_t group,
                                                  int64_t &physical_quantity) const;
    int32_t find_entrepreneur_source(int32_t cell, int32_t target_signature,
                                     int64_t required_capital,
                                     int64_t target_income_per_day,
                                     int64_t target_living_cost_per_day,
                                     int64_t owner_slots_per_building,
                                     int32_t building_type_id,
                                     bool &had_eligible_sponsor,
                                     int64_t &willing_population,
                                     int64_t &transferable_capital,
                                     int64_t &income_improvement_q16,
                                     uint64_t &sponsor_family_handle) const;
    int64_t projected_owner_income_per_day(const BuildingGroup &group,
                                           int64_t &sat) const;
    int64_t projected_employee_tax_retention_q16(
        const BuildingGroup &group, int64_t &sat) const;
    int64_t effective_building_output_quantity(
        const BuildingGroup &group, int32_t good_id, int64_t base_quantity,
        int64_t utilization_q16, int64_t building_days,
        int64_t &sat) const;
    int64_t effective_building_output_quantity_for_target(
        int32_t cell, int32_t type_id, int32_t owner_signature_id,
        int32_t good_id, int64_t base_quantity, int64_t utilization_q16,
        int64_t building_days, int64_t &sat);
    int64_t effective_production_input_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_resource_use_quantity(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_managed_resource_generation(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_household_good_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const;
    void refresh_building_modifier_factors();
    void refresh_city_modifier_factors();
    void refresh_city_output_modifier_factors();
    int32_t city_good_output_factor_q16(int32_t cell, int32_t good_id) const;
    int64_t planned_owner_demand(const BuildingGroup &group,
                                 int64_t &sat) const;
    int64_t building_debt_due(const BuildingGroup &group, int64_t &sat) const;
    int64_t repay_building_debt(int32_t cell, int32_t owner_slot,
                                BuildingGroup &group, int64_t payment_cap,
                                int64_t &premium_paid);
    int64_t available_resource_amount(const ResourceAmount &item, int32_t cell) const;
    void ensure_resource_lane(size_t index);
    void consume_resource_amount(const ResourceAmount &item, int32_t cell, int64_t quantity);
    void queue_bio_introduce_from_good(int32_t cell, int32_t good_id);
    void commit_bio_introduce(int32_t cell, int32_t bit);
    bool resource_is_renewable(int32_t resource_id) const;
    int64_t renewable_safe_harvest(int32_t resource_id, int32_t cell) const;
    bool commit_ready_construction(std::vector<int32_t> &changed_cells,
                                   bool prune_empty_groups = true);
    void initialize_building_role_span(BuildingGroup &group);
    void release_building_role_span(const BuildingGroup &group);
    void rebuild_building_role_storage();
    void rebuild_building_cell_offsets();
    void rebuild_building_review_buckets();
    void review_recovery_building_group(int32_t group_index);
    void finalize_household_building_cell(int32_t cell, int64_t &saturation,
                                          int64_t &restarted,
                                          int64_t &failed);
    int64_t production_reserve_shortfall_cell(int32_t cell,
                                              int64_t &saturation) const;
    void add_trade_active_key(int32_t market, int32_t good);
    void rebuild_market_signals();
    void rebuild_market_signal_lookup();
    bool flush_market_signal_overflow(std::string &error);
    int32_t ensure_market_signal_index(int32_t cell, int32_t good);
    void rebuild_production_input_reserves(int32_t active_begin = 0,
                                           int32_t active_end = -1,
                                           bool initialize = true);
    void resolve_building_maintenance_csr();
    bool is_storable_nonmonetary_good(int32_t good) const;
    int32_t resolved_maintenance_horizon_days(const BuildingType &type) const;
    int64_t merchant_protected_reserve(int32_t signal) const;
    int64_t daily_maintenance_cost_for_type(
        int32_t cell, const BuildingType &type, int64_t &sat) const;
    int64_t maintenance_settlement_price(
        int32_t cell, int32_t good, int64_t &sat) const;
    void rebuild_labor_signals();
    int32_t labor_signal_index(int32_t cell, int32_t profession) const;
    int64_t living_cost_for_signature(int32_t cell, int32_t signature_id,
                                      int32_t plan_override, int64_t &sat) const;
    void compute_cell_living_costs_from_basis(
        int32_t cell, const std::vector<int64_t> &variant_scores,
        const std::vector<int64_t> &variant_prices,
        const std::vector<int64_t> &need_score_sums,
        const std::vector<int64_t> &need_environment, int64_t &sat);
    bool prepare_cell_wages(int32_t cell, std::string &error);
    void update_cell_labor_signals(int32_t cell);
    int64_t production_climate_capacity_q16(
        const BuildingType &type, int32_t cell,
        int64_t *temperature_fit_q16, int64_t *water_fit_q16,
        int64_t &saturation_count) const;
    void prepare_group_climate_capacity(BuildingGroup &group,
                                        const BuildingType &type);
    bool prepare_building_economic_plan(int32_t active_begin, int32_t active_end,
                                        const std::vector<int32_t> *cells_override,
                                        BuildingPlanResult &result,
                                        std::string &error);
    int32_t market_signal_index(int32_t cell, int32_t good) const;
    int64_t epoch_research_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_research_demand_daily_for_market(int32_t market,
                                                   int32_t good) const;
    void refresh_epoch_research_demand();
    PricePressure price_pressure(int32_t market, int32_t good, int64_t household_demand,
                                 int64_t stock, int64_t shortage_q16,
                                 int32_t signal_index, int64_t &saturation_count) const;
    int64_t next_price_v4(int32_t good, int64_t current_price,
                          const PricePressure &pressure, int32_t days,
                          int64_t &saturation_count, bool &rate_clamped) const;
    int32_t find_building_group(int32_t cell, int32_t type_id,
                                int32_t owner_signature_id) const;
    int32_t find_cohort_slot(int32_t cell, int32_t signature_id) const;
    int64_t credit_local_merchants(int32_t cell, int64_t amount,
                                   int32_t cashflow_source = CASHFLOW_MERCHANT_BUSINESS,
                                   int64_t *saturation_override = nullptr);
    int64_t debit_local_merchants(int32_t cell, int64_t amount,
                                  int32_t cashflow_source = CASHFLOW_MERCHANT_PROCUREMENT,
                                  int64_t *saturation_override = nullptr);
    int64_t pay_building_wage_amount(int32_t cell, int32_t owner_slot,
                                     int32_t profession_id, int64_t filled_jobs,
                                     int64_t due, int64_t payment_cap,
                                     int64_t *saturation_override = nullptr);
    void fail(const std::string &reason);
    void clear_epoch_metrics();
    void capture_completed_perf_snapshot();
    void rebuild_committed_summaries();
    CellSummary build_cell_summary(int32_t cell) const;
    void stage_cell_summary(int32_t cell, const CellSummary &summary);
    void finalize_market_result(int32_t market, MarketResult &result);
    void refresh_investment_active_goods_for_cell(int32_t cell,
                                                  int64_t &saturation_count);
    bool rebuild_market_cell_ranges(std::string &error);
    bool ensure_merchant_invariant(int32_t cell, int64_t &repair_count,
                                   std::string &error);
    bool rebuild_merchant_ranges(std::string &error);
    bool repair_cell_merchant_and_rebuild(int32_t cell, std::string &error);
    bool run_government_research_procurement(std::string &error);
    void refresh_country_research_goods_consumed();
    bool compile_family_catalog(const godot::Dictionary &catalog,
                                std::string &error);
    bool compile_family_trait_catalog(const godot::Dictionary &catalog,
                                      std::string &error);
    bool compile_family_effect_catalog(const godot::Dictionary &catalog,
                                       std::string &error);
    bool run_family_commit_slice(int64_t &work_done, std::string &error);
    void rebuild_family_indices(bool rebuild_derived = true);
    void rebuild_family_industry_metrics();
    void rebuild_family_owned_output_csr();
    bool rebuild_family_behavior_cache();
    void mark_family_behavior_cache_dirty(uint32_t reason);
    void rebuild_family_policy_scalars();
    void grant_random_pool_family_effect(int32_t family_index,
                                         bool submit_changes);
    void grant_ancestral_precept_for_country(uint64_t country_handle);
    int32_t family_effect_id_for_key(const std::string &program_key) const;
    int32_t family_effect_prestige_magnitude_q16(int32_t effect_id,
                                                 int32_t prestige_level) const;
    int32_t family_owned_output_factor_q16(int32_t family_index, int32_t cell,
                                           int32_t sector,
                                           int32_t upgrade_family) const;
    int32_t family_group_owned_output_factor_q16(int32_t group_index) const;
    const FamilyIndustryStats *family_industry_stats_for(
        int32_t family_index, int32_t cell) const;
    void apply_family_split_policy_flags(int32_t family_index, uint16_t policy,
                                         uint8_t weight_q8);
    void split_family_branches();
    void normalize_family_memberships(bool rebuild_derived = true);
    void absorb_family_households();
    int64_t family_household_target_people(int64_t owner_slots) const;
    int64_t family_household_people_for_slot(int32_t slot,
                                             int64_t owner_slots) const;
    int64_t family_owned_owner_slots_in_cell(int32_t family_index,
                                             int32_t cell) const;
    void add_family_household_people(uint64_t family_handle, int32_t slot,
                                     int64_t take);
    int64_t family_people_on_slot(int32_t slot) const;
    void update_family_employment_attribution();
    void clamp_family_owner_employment_for_cell(int32_t cell);
    int32_t create_family_for_building(int32_t cell, int32_t building_index,
                                       int64_t founders,
                                       int64_t filled_owner,
                                       bool allow_small_starter = false);
    bool repair_forced_capital_founder(int32_t cell);
    bool form_family_for_cell(int32_t cell);
    void review_family_lifecycle();
    void assign_core_family_traits(int32_t family_index);
    void apply_due_family_trait_commands();
    void rebuild_family_influences(bool rebuild_derived = true);
    void reconcile_family_branch_effects(uint64_t branch_handle,
                                         bool submit_changes);
    void clear_family_branch_effects(uint64_t branch_handle);
    void rebuild_family_effect_binding_index();
    void add_family_effect_binding(FamilyEffectBinding binding);
    void remove_family_effect_binding(size_t index);
    int64_t family_effect_metric_revision(int32_t phase) const;
    bool publish_family_effect_metrics(FamilyEffectBinding &binding,
                                       int64_t revision,
                                       uint64_t requested_mask);
    void refresh_family_effect_metrics_for_branch(uint64_t branch_handle,
                                                  int64_t revision,
                                                  uint64_t requested_mask);
    void refresh_family_effect_metrics_for_cell(int32_t cell,
                                                int64_t revision,
                                                uint64_t requested_mask);
    int32_t family_trait_behavior_factor_q16(uint64_t family_handle,
                                             int32_t axis,
                                             int32_t selector_kind,
                                             int32_t selector_id,
                                             int32_t cell = -1) const;
    int32_t family_behavior_score_term_q16(uint64_t family_handle,
                                           int32_t cell,
                                           int32_t score_term) const;
    int32_t family_purchase_pay_factor_q16(int32_t cohort_slot) const;
    int32_t family_free_building_type_id(const Command &cmd) const;
    void fill_family_behavior_metrics(int32_t family_index, int32_t branch,
                                      int32_t cell, int64_t *metrics,
                                      int32_t metric_count) const;
    bool evaluate_family_behavior_conditions(int32_t edge,
                                             const int64_t *metrics,
                                             int32_t metric_count) const;
    int32_t building_local_resource_abundance_q16(int32_t cell,
                                                  int32_t type_id) const;
    int32_t cell_profession_share_q16(int32_t cell,
                                      int32_t profession_id) const;
    bool family_trait_technology_unlocked(int32_t trait_id, int32_t cell) const;
    bool family_effect_technology_unlocked(int32_t effect_id, int32_t cell) const;
    bool family_trait_origin_gates_allow(int32_t trait_id, int32_t origin_cell) const;
    bool family_trait_context_allows(int32_t trait_id, int32_t family_index) const;
    void collect_family_effect_target_cells(
        int32_t source_cell, int32_t selector_kind,
        std::vector<int32_t> &out_cells) const;
    void fire_family_event_once_effect(int32_t family_index,
                                       const std::string &program_key);
    void apply_pending_family_split_gifts();
    void ensure_family_policy_factors();
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
                                                 int64_t &sat) const;
    uint64_t preferred_family_for_cohort(int32_t cohort_slot,
                                         int32_t axis,
                                         int32_t selector_kind,
                                         int32_t selector_id) const;
    int64_t building_reset_capital_value(const BuildingGroup &group) const;
    bool family_free_building_resources_legal(int32_t cell, int32_t type_id,
                                              int64_t count) const;
    void dissolve_family(uint64_t family_handle);
    void move_family_membership(uint64_t source_handle,
                                uint64_t destination_handle,
                                int64_t source_population_before,
                                int64_t moved_population,
                                int64_t source_funds_before,
                                int64_t moved_funds,
                                uint64_t preferred_family_handle = 0);
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
    void audit_touch_population_lane(int32_t slot);
    void audit_touch_market_lane(size_t index);
    void sum_family_expedition_holdings(int64_t &population, int64_t &funds,
                                        int64_t &goods, int64_t &saturation) const;
    int64_t family_expedition_payload_people(int32_t expedition) const;
    void note_family_expedition_audit_invalidation();
    AuditTotals incremental_audit_totals() const;
    void commit_incremental_audit_shadow();
    void diagnose_incremental_audit_mismatch(const AuditTotals &full);
    AuditTotals audit_totals() const;
    int64_t memory_bytes() const;
    int32_t choose_epoch_days(int64_t cohort_count);
    void write_cadence_report(godot::Dictionary &out) const;
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
    void rebuild_economy_live_cells();
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

} // namespace pk

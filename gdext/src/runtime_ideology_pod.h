#pragma once

#include "runtime_ideology_draw_kernel.h"
#include "runtime_pod_protocol.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

// 5: the offer row grew to IDEOLOGY_OFFER_CHOICE_CAPACITY and gained
// choice_count, the country row gained banned_bits, and the opinion
// snapshot gained the two draw-side per-country values.
constexpr uint32_t RUNTIME_IDEOLOGY_POD_ABI_VERSION = 5u;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_MAX_COUNTRIES = 1u << 20;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_MAX_IDEAS = 65536u;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_MAX_COMMANDS = 1u << 20;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_MAX_TRANSITIONS = 1u << 20;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_HISTORY = 32u;
constexpr uint64_t RUNTIME_IDEOLOGY_MODIFIER_SOURCE_TYPE = 0x4944454full; // IDEO

// Geometric draw cost shared by the main and worker runtimes:
// cost(0) = base, cost(n + 1) = round(cost(n) * growth_percent / 100), capped.
inline int64_t runtime_ideology_offer_cost_q16(
        int64_t base_q16, int64_t growth_percent, int64_t max_q16, uint64_t draw_sequence) {
    int64_t cost = base_q16 < 0 ? 0 : base_q16;
    const int64_t cap = max_q16 < cost ? cost : max_q16;
    if (growth_percent <= 100) return cost;
    for (uint64_t step = 0; step < draw_sequence && cost < cap; ++step) {
        if (cost > INT64_MAX / growth_percent) return cap;
        const int64_t next = (cost * growth_percent + 50) / 100;
        if (next == cost) break;  // tiny costs can stall under rounding
        cost = next;
    }
    return cost < cap ? cost : cap;
}

enum class RuntimeIdeologyPodOpcode : uint16_t {
    DISCOVER = 1,
    GRANT_POINTS = 2,
    OPEN_OFFER = 3,
    CHOOSE_OFFER = 4,
    EQUIP = 5,
    UNEQUIP = 6,
    PROMOTE = 7,
    ADD_UNDERSTANDING = 8,
    SET_GATE = 9,
    REROLL_OFFER = 10,
    BAN_CARD = 11,
};

enum class RuntimeIdeologyPodLocation : uint8_t {
    INACTIVE = 0,
    IDEOLOGY = 1,
    NATIONAL_SPIRIT = 2,
};

enum class RuntimeIdeologyPodPhase : uint8_t {
    PENDING_TRANSITIONS = 0,
    COMMANDS = 1,
    ACTIVE_PROGRESS = 2,
};

enum class RuntimeIdeologyPodReceiptStatus : uint8_t {
    PENDING = 1,
    SETTLED = 2,
    REJECTED = 3,
};

struct RuntimeIdeologyPodLevel {
    int64_t threshold_q16 = 0;
    int64_t daily_understanding_q16 = 0;
    uint32_t modifier_begin = 0;
    uint32_t modifier_count = 0;
};

// Reversible UniqueSource Modifier template row. The worker resolves the
// definition key hash against the Modifier POD catalog at stage time.
struct RuntimeIdeologyPodModifierTemplate {
    uint64_t definition_key_hash = 0;
    int32_t domain = 0;
    int32_t magnitude_q16 = 65536;
};

struct RuntimeIdeologyPodCapacityUnlock {
    int32_t technology_id = -1;
    int32_t ideology_delta = 0;
    int32_t spirit_delta = 0;
};

struct RuntimeIdeologyPodDefinition {
    uint8_t acquisition = 3;
    uint8_t reserved[3]{};
    int32_t rarity_weight = 1;
    int32_t ideology_cost = 1;
    int32_t spirit_cost = 1;
    int32_t min_spirit_level = 0;
    uint32_t level_begin = 0;
    uint32_t level_count = 0;
    uint32_t technology_begin = 0;
    uint32_t technology_count = 0;
    uint32_t signal_begin = 0;
    uint32_t signal_count = 0;
    uint32_t gate_begin = 0;
    uint32_t gate_count = 0;
    uint32_t stance_begin = 0;
    uint32_t stance_count = 0;
    std::array<int32_t, 3> support_threshold_q16{};
    int32_t exclusion_group_id = -1;
    // Era the idea belongs to; drives the draw-weight decay curve. Appended last
    // so the field order of every earlier member stays put.
    int32_t era_index = 0;
};

struct RuntimeIdeologyPodClassStance {
    int32_t class_index = -1;
    std::array<int32_t, 3> stance_q16{};
    std::array<int32_t, 3> critical_min_q16{{-65537, -65537, -65537}};
};

struct RuntimeIdeologyPodSynergyRequirement {
    int32_t ideology_id = -1;
    int32_t minimum_level = 0;
    uint8_t location_mask = 0;
    uint8_t reserved[3]{};
};

struct RuntimeIdeologyPodSynergy {
    uint32_t requirement_begin = 0;
    uint32_t requirement_count = 0;
    // Active when at least min_count requirement rows hold. Named synergies
    // use requirement_count; school resonances use 2 or 4 of the school.
    uint32_t min_count = 0;
    uint32_t modifier_begin = 0;
    uint32_t modifier_count = 0;
};

struct RuntimeIdeologyPodCatalog {
    uint32_t abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    uint64_t catalog_hash = 0;
    uint64_t country_catalog_hash = 0;
    uint64_t class_hash = 0;
    uint32_t class_count = 0;
    uint32_t technology_count = 0;
    uint32_t research_signal_count = 0;
    uint32_t gate_count = 0;
    int32_t ideology_capacity = 6;
    int32_t spirit_capacity = 3;
    int32_t ideology_capacity_max = 6;
    int32_t spirit_capacity_max = 3;
    // Rows the offer holds before the per-country bonus. The main runtime reads
    // the same number from `offer_choice_count`; the worker gets it here because
    // it has no profile.
    int32_t draw_count = 3;
    int64_t offer_cost_q16 = 65536;
    int64_t offer_cost_growth_percent = 100;
    int64_t offer_cost_max_q16 = 65536;
    int32_t reroll_cost_percent = 50;
    int64_t starting_points_q16 = 0;
    // Increment-only ideology point accrual (Q16 per unit).
    int64_t point_population_weight_q16 = 0;
    int64_t point_building_weight_q16 = 0;
    int64_t point_trade_weight_q16 = 0;
    int64_t point_gain_cap_q16 = 0;
    // Modifier POD stat id of country.ideology.point_gain_factor (-1 = 1.0).
    int32_t point_gain_stat_id = -1;
    // Same, for the two other ideology-facing multipliers. Their *values* are
    // frozen per country into RuntimeIdeologyOpinionSnapshot below, because the
    // worker cannot read ModifierRuntime; the id here only tells the host which
    // index to freeze.
    int32_t understanding_gain_stat_id = -1;
    int32_t reroll_cost_stat_id = -1;
    // Same, for the two DRAW-side per-country values. Only the host uses these
    // ids (to pick which bucket to freeze); the worker reads the frozen arrays
    // in the opinion snapshot.
    int32_t era_decay_floor_stat_id = -1;
    int32_t offer_choice_bonus_stat_id = -1;
    // Frozen catalog knobs for 精进 (owned cards returning to the pool). They
    // travel in the catalog rather than the opinion snapshot because they are
    // the same for every country, unlike the two stats above.
    int32_t refine_weight_bp = 0;
    int64_t refine_understanding_q16 = 4 * 65536;
    int32_t owner_influence_weight = 2;
    int64_t funds_per_influence = 1000000;
    uint32_t max_commands_per_slice = 4096;
    uint32_t max_transition_commands = 256;
    uint32_t max_transition_polls_per_slice = 4096;
    uint32_t max_active_visits_per_slice = 1024;
    std::vector<RuntimeIdeologyPodDefinition> definitions;
    std::vector<RuntimeIdeologyPodLevel> levels;
    std::vector<int32_t> technology_requirements;
    std::vector<int32_t> signal_requirements;
    std::vector<int32_t> gate_requirements;
    // Draw-weight decay by (unlocked_era - idea.era_index); empty means no decay.
    std::vector<int32_t> era_decay_bp;
    // Dense technology index of each era's milestone; -1 marks an era with none.
    // The worker derives the country's unlocked era from these bits, exactly like
    // the main runtime, so no extra command has to cross the domain boundary.
    std::vector<int32_t> era_milestone_technologies;
    std::vector<RuntimeIdeologyPodClassStance> class_stances;
    std::vector<RuntimeIdeologyPodSynergyRequirement> synergy_requirements;
    std::vector<RuntimeIdeologyPodSynergy> synergies;
    std::vector<uint32_t> ideology_synergy_offsets;
    std::vector<int32_t> ideology_synergy_ids;
    std::vector<RuntimeIdeologyPodModifierTemplate> level_modifiers;
    std::vector<RuntimeIdeologyPodModifierTemplate> synergy_modifiers;
    std::vector<RuntimeIdeologyPodCapacityUnlock> capacity_unlocks;
};

struct RuntimeIdeologyOpinionSnapshot {
    uint64_t revision = 0;
    uint64_t class_hash = 0;
    int64_t committed_day = -1;
    uint32_t country_count = 0;
    uint32_t class_count = 0;
    std::vector<uint64_t> country_handles;
    std::vector<uint32_t> country_generations;
    std::vector<int64_t> population;
    std::vector<int64_t> funds;
    std::vector<int64_t> owner_employed;
    std::vector<int64_t> satisfaction_weighted;
    std::vector<int32_t> satisfaction_q16;
    // Per-country development lanes (optional; empty disables accrual).
    std::vector<int64_t> country_population;
    std::vector<int64_t> country_buildings_installed;
    std::vector<int64_t> country_trade_base_value;
    int64_t period_days = 1;
    // Frozen country.ideology.point_gain_factor (Q16); empty means 1.0.
    std::vector<int32_t> point_gain_factor_q16;
    // Frozen country.ideology.understanding_gain_factor / reroll_cost_factor.
    // Empty means 1.0 for every country, which is why adding them is a no-op
    // for every existing caller: the worker only looks when the array has the
    // right length.
    std::vector<int32_t> understanding_gain_q16;
    std::vector<int32_t> reroll_cost_q16;
    // Draw-side per-country values. The worker cannot read ModifierRuntime, so
    // the host freezes them here every period, exactly like the two factors
    // above. Empty means 0 -- the identity element for both: no decay floor and
    // no extra offer rows.
    std::vector<int32_t> era_decay_floor_bp;
    std::vector<int32_t> offer_choice_bonus;
};

struct RuntimeIdeologyPodCommand {
    uint64_t request_id = 0;
    int32_t source_priority = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t submit_order = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    RuntimeIdeologyPodOpcode opcode = RuntimeIdeologyPodOpcode::DISCOVER;
    uint16_t reserved = 0;
    uint64_t country_handle = 0;
    int32_t ideology_id = -1;
    int64_t value_q16 = 0;
    uint32_t offer_generation = 0;
    int32_t choice_index = -1;
    int32_t gate_id = -1;
};

struct RuntimeIdeologyPodIdeaState {
    int64_t understanding_q16 = 0;
    int32_t level = -1;
    uint64_t entered_levels = 0;
    uint32_t generation = 1;
    RuntimeIdeologyPodLocation location = RuntimeIdeologyPodLocation::INACTIVE;
    uint8_t reserved[3]{};
};

struct RuntimeIdeologyPodOffer {
    uint32_t generation = 0;
    std::array<int32_t, IDEOLOGY_OFFER_CHOICE_CAPACITY> ideology_ids;
    uint8_t choice_count = 0;
    uint8_t active = 0;
    uint8_t reserved[2]{};

    RuntimeIdeologyPodOffer() { ideology_ids.fill(-1); }
    void clear() { ideology_ids.fill(-1); choice_count = 0; active = 0; }
};

struct RuntimeIdeologyPodPointLedger {
    int64_t population_q16 = 0;
    int64_t building_q16 = 0;
    int64_t trade_q16 = 0;
    int32_t opinion_factor_q16 = 65536;
    int32_t gain_factor_q16 = 65536;
    int64_t gain_q16 = 0;
    int64_t day = -1;
};

struct RuntimeIdeologyPodCountryState {
    uint64_t handle = 0;
    uint32_t generation = 0;
    int64_t ideology_points_q16 = 0;
    uint64_t points_revision = 0;
    uint8_t baseline_ready = 0;
    uint8_t history_count = 0;
    uint8_t history_head = 0;
    uint8_t reserved_points = 0;
    int64_t baseline_population = 0;
    int64_t baseline_buildings = 0;
    int64_t lifetime_points_q16 = 0;
    RuntimeIdeologyPodPointLedger ledger;
    std::array<int64_t, RUNTIME_IDEOLOGY_POD_HISTORY> history_q16{};
    uint64_t rng_state = 0;
    uint64_t draw_sequence = 0;
    int32_t ideology_slots_used = 0;
    int32_t spirit_slots_used = 0;
    // Pushed by the content layer through SET_ERA before that day's draw. Kept on
    // the row (not derived at draw time) so the main runtime and the worker read
    // the same number and the value survives save/restore.
    int32_t unlocked_era = 0;
    uint64_t opinion_revision = 0;
    RuntimeIdeologyPodOffer offer;
    std::vector<uint64_t> known_bits;
    // 封存: a second bitmap, never a reuse of known_bits (see CountryState).
    std::vector<uint64_t> banned_bits;
    std::vector<uint64_t> gate_bits;
    std::vector<uint64_t> synergy_bits;
    std::vector<RuntimeIdeologyPodIdeaState> ideas;
    std::vector<uint32_t> active_idea_ids;
};

struct RuntimeIdeologyPodTransition {
    uint64_t intent_id = 0;
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    int64_t effective_day = 0;
    uint32_t country_slot = 0;
    uint32_t country_generation = 0;
    int32_t ideology_id = -1;
    int32_t desired_level = -1;
    uint64_t desired_entered_levels = 0;
    RuntimeIdeologyPodLocation desired_location = RuntimeIdeologyPodLocation::INACTIVE;
    uint8_t intent_emitted = 0;
    uint8_t reserved[2]{};
    std::vector<uint64_t> desired_synergy_bits;
};

struct RuntimeIdeologyPodReceipt {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    RuntimeIdeologyPodReceiptStatus status = RuntimeIdeologyPodReceiptStatus::PENDING;
    RuntimeIdeologyPodOpcode opcode = RuntimeIdeologyPodOpcode::DISCOVER;
    uint64_t country_handle = 0;
    int32_t ideology_id = -1;
    int64_t settled_day = -1;
    uint32_t reason_code = 0;
};

struct RuntimeIdeologyPodProducerWatermark {
    uint32_t producer_id = 0;
    uint32_t reserved = 0;
    uint64_t sequence = 0;
};

struct RuntimeIdeologyPodSnapshot {
    uint32_t abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    uint64_t catalog_hash = 0;
    uint64_t input_generation = 0;
    uint64_t opinion_revision = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    int64_t committed_day = -1;
    int64_t round_day = -1;
    RuntimeIdeologyPodPhase phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
    uint32_t pending_cursor = 0;
    uint32_t command_cursor = 0;
    uint32_t active_country_cursor = 0;
    uint32_t active_idea_cursor = 0;
    uint64_t next_submit_order = 1;
    std::vector<RuntimeIdeologyPodCountryState> countries;
    std::vector<RuntimeIdeologyPodProducerWatermark> producer_high_watermarks;
    std::vector<RuntimeIdeologyPodCommand> commands;
    std::vector<RuntimeIdeologyPodTransition> pending_transitions;
    std::vector<RuntimeIdeologyPodReceipt> receipts;
};

// One Modifier row of an Ideology transition batch. All rows of a transition
// share transition_id; the worker settles the transition only after every row
// is ACKed by the Modifier POD.
struct RuntimeIdeologyPodModifierRow {
    uint64_t transition_id = 0;
    uint64_t country_handle = 0;
    uint32_t country_generation = 0;
    uint16_t opcode = 1; // Modifier APPLY=1, REMOVE=2
    uint16_t domain = 0;
    uint64_t definition_key_hash = 0;
    uint64_t source_id = 0;
    int32_t magnitude_q16 = 65536;
    uint32_t ordinal = 0;
    int64_t effective_day = 0;
};

struct RuntimeIdeologyPodPlan {
    RuntimeIdeologyPodSnapshot next_snapshot;
    std::vector<RuntimeDomainIntent> intents;
    std::vector<RuntimeIdeologyPodModifierRow> modifier_rows;
    uint64_t base_generation = 0;
    uint64_t input_generation = 0;
    uint64_t plan_hash = 0;
    uint32_t transition_visits = 0;
    uint32_t commands_consumed = 0;
    uint32_t active_visits = 0;
    uint8_t completed_day = 0;
    uint8_t preflight_ok = 0;
    uint8_t committed = 0;
    char error[64]{};
};

struct RuntimeIdeologyPodSaveSection {
    uint32_t abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    uint64_t catalog_hash = 0;
    uint64_t state_hash = 0;
    std::vector<uint8_t> payload;
};

class RuntimeIdeologyPodAuthority {
public:
    RuntimeIdeologyPodAuthority();
    void reset();
    bool configure(const RuntimeIdeologyPodCatalog &catalog, std::string &error);
    bool bootstrap(const RuntimeCountryPodSnapshot &country,
                   const RuntimeIdeologyOpinionSnapshot &opinion,
                   std::string &error);
    bool queue_command(RuntimeIdeologyPodCommand command, std::string &error);
    bool plan_day(int64_t day, const RuntimeCountryPodSnapshot &country,
                  const RuntimeIdeologyOpinionSnapshot &opinion,
                  const std::vector<RuntimeDomainAck> &acks,
                  RuntimeIdeologyPodPlan &plan, std::string &error);
    bool commit_day(RuntimeIdeologyPodPlan &plan, std::string &error);
    void discard_plan() noexcept { _plan_ready = false; }
    const RuntimeIdeologyPodSnapshot &snapshot() const noexcept { return _current; }
    const RuntimeIdeologyPodCatalog &catalog() const noexcept { return _catalog; }
    bool configured() const noexcept { return _configured; }
    uint64_t catalog_hash() const noexcept { return _catalog.catalog_hash; }
    void serialize(std::vector<uint8_t> &out) const;
    bool restore(const uint8_t *data, size_t size, std::string &error);
    // Worker in-flight Modifier batches are not persisted; after a restore the
    // pending transitions re-emit (APPLY upserts / REMOVE-missing are idempotent).
    void rearm_pending_transitions();
    static bool self_test(std::string &error);
    // Derived per-country rules shared with the main-thread facade.
    int32_t ideology_capacity_for(const RuntimeCountryPodSnapshot &country,
                                  uint32_t slot) const;
    int32_t spirit_capacity_for(const RuntimeCountryPodSnapshot &country,
                                uint32_t slot) const;
    int64_t offer_cost_for(uint64_t draw_sequence) const;
    // `factor_q16` is the country's frozen reroll multiplier. Passed in rather
    // than looked up because the opinion snapshot is a per-stage argument, not
    // authority state — the worker never owns modifier values.
    int64_t reroll_cost_for(uint64_t draw_sequence, int32_t factor_q16) const;

private:
    static bool command_less(const RuntimeIdeologyPodCommand &a,
                             const RuntimeIdeologyPodCommand &b) noexcept;
    static uint64_t compute_catalog_hash(const RuntimeIdeologyPodCatalog &catalog);
    static uint64_t compute_state_hash(const RuntimeIdeologyPodSnapshot &state);
    bool validate_catalog(const RuntimeIdeologyPodCatalog &catalog,
                          std::string &error) const;
    bool validate_inputs(const RuntimeCountryPodSnapshot &country,
                         const RuntimeIdeologyOpinionSnapshot &opinion,
                         std::string &error) const;
    bool validate_command(const RuntimeIdeologyPodCommand &command,
                          std::string &error) const;
    bool apply_command(RuntimeIdeologyPodSnapshot &state,
                       const RuntimeCountryPodSnapshot &country,
                       const RuntimeIdeologyOpinionSnapshot &opinion,
                       const RuntimeIdeologyPodCommand &command,
                       RuntimeIdeologyPodPlan &plan, std::string &error) const;
    bool begin_transition(RuntimeIdeologyPodSnapshot &state, uint32_t country_slot,
                          int32_t ideology_id, int32_t desired_level,
                          RuntimeIdeologyPodLocation desired_location,
                          uint64_t entered_levels,
                          const RuntimeIdeologyPodCommand *command,
                          int64_t day, RuntimeIdeologyPodPlan &plan,
                          std::string &error) const;
    void emit_transition(const RuntimeIdeologyPodSnapshot &state,
                         RuntimeIdeologyPodTransition &transition,
                         RuntimeIdeologyPodPlan &plan) const;
    void accrue_points(RuntimeIdeologyPodSnapshot &state,
                       const RuntimeIdeologyOpinionSnapshot &opinion,
                       int64_t day) const;
    // `opinion` is needed for the two per-country draw knobs (decay floor and
    // offer-row bonus). Passing the whole snapshot rather than the two arrays
    // keeps the call sites identical to the main-thread `draw_offer`, which is
    // the property that keeps the two authorities in step.
    bool draw_offer(RuntimeIdeologyPodSnapshot &state,
                    const RuntimeCountryPodSnapshot &country, uint32_t slot,
                    const RuntimeIdeologyOpinionSnapshot &opinion,
                    std::string &error) const;
    // Deepest era whose milestone technology this country holds. Derived from the
    // same catalog rows the main runtime uses so both agree without a round trip.
    int32_t unlocked_era_for(const RuntimeCountryPodSnapshot &country,
                             uint32_t slot) const;
    bool apply_ack(RuntimeIdeologyPodSnapshot &state,
                   const RuntimeDomainAck &ack, int64_t day,
                   RuntimeIdeologyPodPlan &plan,
                   std::string &error) const;
    void settle_synergies(RuntimeIdeologyPodCountryState &country,
                          uint32_t country_slot, int32_t ideology_id,
                          int64_t day, RuntimeIdeologyPodPlan &plan) const;
    bool support_allows(const RuntimeIdeologyPodSnapshot &state,
                        const RuntimeIdeologyOpinionSnapshot &opinion,
                        uint32_t country_slot, int32_t ideology_id,
                        uint32_t direction) const;
    bool requirements_met(const RuntimeIdeologyPodSnapshot &state,
                          const RuntimeCountryPodSnapshot &country,
                          uint32_t country_slot, int32_t ideology_id) const;
    int32_t unlocked_level(const RuntimeIdeologyPodIdeaState &idea,
                           int32_t ideology_id) const;
    void compute_synergies(const RuntimeIdeologyPodCountryState &country,
                           int32_t override_ideology,
                           int32_t override_level,
                           RuntimeIdeologyPodLocation override_location,
                           std::vector<uint64_t> &out) const;
    uint64_t transition_identity(const RuntimeIdeologyPodTransition &transition,
                                 RuntimeIdeologyPodOpcode opcode) const;

    RuntimeIdeologyPodCatalog _catalog;
    RuntimeIdeologyPodSnapshot _current;
    RuntimeIdeologyPodSnapshot _planned;
    bool _configured = false;
    bool _plan_ready = false;
};

// G8: immutable Ideology POD snapshot ring (mirrors RuntimeEffectSnapshotRing).
class RuntimeIdeologySnapshotRing {
public:
    RuntimeIdeologySnapshotRing();
    bool try_begin_write(uint32_t &index);
    RuntimeIdeologyPodSnapshot &write_buffer(uint32_t index) {
        return _slots[index].snapshot;
    }
    const RuntimeIdeologyPodSnapshot &read_buffer(uint32_t index) const {
        return _slots[index].snapshot;
    }
    void publish(uint32_t index);
    bool try_acquire_latest(uint64_t after_generation, uint32_t &index);
    void release(uint32_t index);
    void reset();
    uint64_t publish_drop_count() const {
        return _publish_drop_count.load(std::memory_order_relaxed);
    }
    static bool self_test();

private:
    enum : uint8_t { FREE = 0, WRITING = 1, READY = 2, READING = 3 };
    struct Slot {
        std::atomic<uint8_t> state{FREE};
        RuntimeIdeologyPodSnapshot snapshot{};
    };
    std::array<Slot, RUNTIME_SNAPSHOT_RING_SIZE> _slots{};
    std::atomic<uint64_t> _published_generation{0};
    std::atomic<uint64_t> _publish_drop_count{0};
};

} // namespace pk

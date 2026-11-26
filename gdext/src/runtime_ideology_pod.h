#pragma once

#include "runtime_ideology_pod_catalog.h"

namespace pk {

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
    uint8_t slot_index = 0;
    uint8_t reserved[2]{};
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

// Shared RNG seed constant. Both sides must derive `rng_state` from the SAME
// inputs, never from `catalog_hash`: the main thread and the worker compute that
// with different functions, so seeding from it made `rng_state` -- and therefore
// the whole `draw` section -- permanently unequal.
//
// The world seed is part of the input on purpose. Hashing only the country handle
// gave every session of the same map the same card order for a given country: two
// different games drew identical sequences, which is a content bug rather than a
// parity one. `world_seed` is the same number on both sides, so parity still
// holds.
constexpr uint64_t RUNTIME_IDEOLOGY_RNG_SEED_MIX = 0x9e3779b97f4a7c15ull;

inline uint64_t runtime_ideology_country_rng_seed(uint64_t handle,
                                                  uint64_t world_seed) {
    // splitmix-style avalanche so nearby (handle, seed) pairs do not produce
    // correlated streams.
    uint64_t value = handle ^ world_seed * 0x9e3779b97f4a7c15ull;
    value ^= value >> 30;
    value *= 0xbf58476d1ce4e5b9ull;
    value ^= value >> 27;
    value *= 0x94d049bb133111ebull;
    value ^= value >> 31;
    return value ^ RUNTIME_IDEOLOGY_RNG_SEED_MIX;
}

// Trade is a FLOW: `trade_per_day` points are earned on every day that passes,
// not once per settlement. Paying the full daily amount on every call made the
// total a function of how many times the caller happened to run, which is how
// two authorities with identical inputs produced 46859 vs 67969 points (R8-2).
//
// The correct account is "pay for the days that elapsed, once":
//     trade = trade_per_day * (day - trade_paid_day)
//
//   - the first observation only seeds the marker (`paid` stays INT64_MIN), so a
//     jump from INT64_MIN never pays for all of history;
//   - a settlement that happens twice on the same day pays once;
//   - a settlement that happens once every `period` days pays those `period`
//     days (it is the same elapsed span, not a special case);
//   - settling once or thirty times over the same 30 days pays the same total.
//
// NO period clamp. An earlier draft clamped the span to `period_days`, which
// reintroduced exactly the settlement-count dependence this function exists to
// remove: over 30 days with period 5, settling once paid 5000 and settling daily
// paid 29000, because the single settlement could only claim one period of
// elapsed time. The invariant "the total depends only on elapsed days" requires
// the full span. `period_days` stays a parameter so callers still state the
// cadence they are accounting for, but it does not cap the flow.
//
// Returns the amount owed and advances `paid`. Both authorities call THIS
// function, so the two can never drift into different accounting.
inline int64_t ideology_trade_flow_q16(int64_t trade_per_day, int64_t day,
                                       int64_t period_days, int64_t &paid) {
    (void)period_days;
    if (paid == INT64_MIN) {          // first observation: baseline only
        paid = day;
        return 0;
    }
    const int64_t span = day - paid;
    if (span <= 0) return 0;          // same day, or a day already paid
    paid = day;
    return trade_per_day * span;
}

// X6-a: the one per-term point multiplier both authorities use.
//
// Modifier values are frozen into the opinion snapshot in Q16 and clamped to
// [0.5, 3.0] before they get here. A missing/empty column is the identity
// multiplier (1.0), so old callers and fixtures retain their exact arithmetic.
inline int64_t ideology_point_term_q16(
        int64_t raw_q16, const std::vector<int32_t> &factors_q16,
        size_t slot) {
    constexpr int64_t kQ16One = 65536;
    if (raw_q16 == 0) return 0;
    int64_t factor_q16 = kQ16One;
    if (slot < factors_q16.size())
        factor_q16 = std::clamp<int64_t>(factors_q16[slot], kQ16One / 2,
                                         3 * kQ16One);
    if (factor_q16 == kQ16One) return raw_q16;
    if (raw_q16 > 0 && raw_q16 > INT64_MAX / factor_q16) return INT64_MAX;
    if (raw_q16 < 0 && raw_q16 < INT64_MIN / factor_q16) return INT64_MIN;
    return raw_q16 * factor_q16 / kQ16One;
}

// The single opinion-factor kernel. The floor is a country scalar frozen from
// Modifier; satisfaction is the population/influence-weighted committed value.
// Both authorities call this so a floor card cannot change only one side.
inline int32_t ideology_opinion_factor_q16(
        int64_t satisfaction_q16, const std::vector<int32_t> &floors_q16,
        size_t slot) {
    constexpr int32_t kQ16One = 65536;
    constexpr int32_t kFloorMin = 19661; // 0.3
    constexpr int32_t kFloorMax = 32768; // 0.5
    int32_t floor_q16 = kFloorMax;
    if (slot < floors_q16.size())
        floor_q16 = std::clamp(floors_q16[slot], kFloorMin, kFloorMax);
    const int64_t satisfaction = std::clamp<int64_t>(
        satisfaction_q16, 0, kQ16One);
    return static_cast<int32_t>(static_cast<int64_t>(floor_q16) +
                                satisfaction);
}

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
    // Last day this row paid its trade flow. Trade is a FLOW, not a high-water
    // delta, so a settlement must pay for the days that actually elapsed rather
    // than for the number of times it happened to run. `accrue_points` reads
    // this, clamps the elapsed span to the opinion period, and advances the
    // marker; see `ideology_trade_flow_q16` below.
    int64_t trade_paid_day = INT64_MIN;
    RuntimeIdeologyPodPointLedger ledger;
    std::array<int64_t, RUNTIME_IDEOLOGY_POD_HISTORY> history_q16{};
    uint64_t rng_state = 0;
    uint64_t draw_sequence = 0;
    uint16_t free_draws = 0;
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
    uint8_t desired_slot_index = 0;
    uint8_t intent_emitted = 0;
    uint8_t reserved = 0;
    // Entered levels the retained idea already had when this transition began.
    // The ACK path grants only the newly entered tiers; without this snapshot a
    // level-up from L2 to L3 could replay the L2 one-shot.
    uint64_t previous_entered_levels = 0;
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
    // Why a command was rejected, verbatim from `apply_command`'s `error`.
    //
    // `reason_code` is a 1-bit "something went wrong" flag, and the main-thread
    // receipt collapsed it into the constant string `ideology_worker_rejected`. That
    // made every worker-side rejection indistinguishable -- an unequip refused for
    // `ideology_not_equipped` read exactly like one refused for a support threshold,
    // and the only way to tell was to re-run under a debugger.
    //
    // Deliberately NOT serialized: this is an in-process diagnostic, so adding it
    // changes no save layout and needs no ABI bump. A restored session simply has no
    // rejection text, which is correct -- the rejection already happened and was
    // already acted on.
    std::string reason_text;
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

// Business-only hash for parity (review round 3): the same fields on both sides,
// excluding transport (generation, cursors, watermarks, phases, opinion_revision)
// and derived fields (slots used, active ids). `compute_state_hash` above includes
// the transport fields, so main-thread and worker snapshots can never agree on it.
// Per-section business hashes. The total is the mix of these seven, so any section
// that differs shows up in the total; keeping them apart is what lets a parity
// failure name the first diverging area instead of just "mismatch".
struct IdeologyBusinessSections {
    uint64_t points = 0;
    uint64_t baseline = 0;
    uint64_t history = 0;
    uint64_t draw = 0;
    uint64_t bits = 0;
    uint64_t offer = 0;
    uint64_t ideas = 0;
    // `points` is a mix of three independent quantities and a single hash says
    // only "one of them moved". Keeping the sub-hashes lets a parity failure
    // name the actual field instead of sending the next reader back into the
    // accrual call chain. They do not participate in the total hash.
    uint64_t points_balance = 0;
    uint64_t points_lifetime = 0;
    uint64_t points_revision = 0;
    // Ring cursor of the point-history buffer. Diagnostic only: it counts how
    // many accruals wrote, so it depends on each side's Economy publish cadence
    // and can never constrain business equality.
    uint64_t history_cursor = 0;
};
void ideology_business_sections(const RuntimeIdeologyPodSnapshot &state,
                                IdeologyBusinessSections &out);
uint64_t ideology_business_hash(const RuntimeIdeologyPodSnapshot &state);


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
    // 1 when this plan completed a day that the IMPORTED state already settles, i.e.
    // it republished the import unchanged instead of advancing it. `commit_day` keeps
    // the calendar floor armed for those, because a superseded day must not unarm the
    // rule that made it possible.
    uint8_t superseded_day = 0;
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
    // Per-cell tag bitmap published by the economy (`TagSnapshot`, tag-major:
    // [tag * words + word]). Kept OUT of `RuntimeCountryPodSnapshot` on purpose:
    // that struct has a save codec (`runtime_country_pod.cpp`), and the tags are
    // rebuilt from the economy on every epoch anyway.
    //
    // Stage B of docs/plans/ideology-worker-pod-conditions-plan.md. Nothing reads
    // these yet; the per-cell expansion arrives in stage D.
    void set_cell_tags(int32_t words, const std::vector<uint64_t> &bits);
    int32_t cell_tag_words() const { return _cell_tag_words; }
    const std::vector<uint64_t> &cell_tags() const { return _cell_tags; }
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
    // ── worker-side IMPORT: "your authoritative state is now this" ───────────
    //
    // `NativeIdeologyRuntime::capture` / `restore` are MAIN-THREAD facade calls. The
    // POD has its own state machine and never learns it was restored from, so its next
    // publish replaces the restored rows with its own state (measured: `idea_rows
    // [82,1,0,0] -> []`, the mirrored §9.3 dates `7/8 -> 2/3`, then the pump clears the
    // front). The two members below are the channel that fixes it, and they are the
    // POD's own save format rather than a new transport: the host already exposes
    // `restore_ideology_pod_save`, which configures a candidate from the LIVE catalog
    // and calls `restore` on it, so a snapshot produced here can be installed by the
    // worker without teaching the POD a second state format.
    //
    // `canonicalize_import` must run first: `active_idea_ids` is derived, it takes part
    // in `compute_state_hash`, and `restore` recomputes that hash -- a snapshot that
    // skipped this step is refused as `ideology_pod_save_state_hash_failed`.
    static void canonicalize_import(RuntimeIdeologyPodSnapshot &state);
    static void serialize_snapshot(const RuntimeIdeologyPodSnapshot &state,
                                   std::vector<uint8_t> &out);
    // True while the committed state came from a restore whose day is at or after the
    // worker's own calendar. Such a day is already settled, so `plan_day` republishes
    // the imported state instead of failing `ideology_day_not_monotonic`.
    bool import_supersedes_calendar() const noexcept {
        return _import_supersedes_calendar;
    }
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
    // Public so the main-thread runtime can hash its exported snapshot with the
    // SAME function the worker uses -- that shared implementation is the whole
    // basis of ideology parity.
    static uint64_t compute_state_hash(const RuntimeIdeologyPodSnapshot &state);

private:
    static bool command_less(const RuntimeIdeologyPodCommand &a,
                             const RuntimeIdeologyPodCommand &b) noexcept;
    static uint64_t compute_catalog_hash(const RuntimeIdeologyPodCatalog &catalog);
    bool validate_catalog(const RuntimeIdeologyPodCatalog &catalog,
                          std::string &error) const;
    void append_country_rows(RuntimeIdeologyPodSnapshot &, const std::vector<uint8_t> &active,
                             const std::vector<uint32_t> &generations, uint64_t opinion_revision) const;
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
                          uint8_t desired_slot_index, uint64_t entered_levels,
                          const RuntimeIdeologyPodCommand *command,
                          int64_t day, RuntimeIdeologyPodPlan &plan,
                          std::string &error) const;
    uint8_t next_free_slot(const RuntimeIdeologyPodCountryState &country,
                           RuntimeIdeologyPodLocation location,
                           int32_t exclude_ideology_id) const;
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
    // Stage B inputs (see the public setter). Transient: rebuilt from the economy
    // every epoch, never serialised.
    int32_t _cell_tag_words = 0;
    std::vector<uint64_t> _cell_tags;
    bool _configured = false;
    bool _plan_ready = false;
    // Armed by `restore` (a save install, whether this POD's own bytes or the runtime
    // save bundle's). It is what turns "the worker's calendar is behind the restored
    // day" from a hard fault into a no-op day; see `plan_day`.
    bool _import_supersedes_calendar = false;
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

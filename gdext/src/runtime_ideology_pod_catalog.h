#pragma once

#include "runtime_ideology_draw_kernel.h"
#include "runtime_ideology_incidence.h"
#include "runtime_pod_protocol.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <climits>
#include <string>
#include <vector>

namespace pk {

// 5: the offer row grew to IDEOLOGY_OFFER_CHOICE_CAPACITY and gained
// choice_count, the country row gained banned_bits, and the opinion
// snapshot gained the two draw-side per-country values.
// 6: the country row gained `trade_paid_day` and then the point-accrual
// period/baseline-day markers, which were written WITHOUT bumping this constant
// (R8-1). An ABI-5 reader would consume the v6 country row with the old field
// layout, so version 6 makes an old payload fail by VERSION instead of
// misreading it. Mirrors PKID 7 -> 8; the two move together because they
// serialize the same `CountryState` shape.
// 7: X6-a adds three frozen per-term point-factor columns to the opinion
// snapshot. They are not serialized by IDP2 itself, but the ABI moves so an
// ABI-6 payload is rejected by version rather than read against the new
// catalog/opinion contract.
// 8: IdeaState.reserved[0] now carries the deterministic slot_index and the
// catalog definition carries the X6-c copy flags. An ABI-7 reader cannot safely
// restore or replay the new slot/copy semantics.
// 9: X6-b adds the per-country `free_draws` row field. Keeping the old version
// would decode every later field one uint16 out of place.
// 10: social_media freezes `country.ideology.opinion_factor_floor` into the
// opinion snapshot. The value is per-country, so a different catalog/floor must
// reject old saves rather than silently reuse 0.5.
// 11: mandate_of_heaven freezes one global strength multiplier per school into
// the opinion snapshot. The card's school index also joins the catalog contract
// so the host and worker agree on which lane an equipped card consumes.
// 12: the opinion snapshot carries Economy's class-incidence table (channel
// count, per-country measured flags, country x class x channel Q16 shares). The
// support gate now derives each class's stance from that table instead of the
// authored stance rows, so an ABI-11 payload describes a different support model
// and must be rejected by version.
constexpr uint32_t RUNTIME_IDEOLOGY_POD_ABI_VERSION = 12u;
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
    GRANT_FREE_DRAW = 12,
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
    // X6-b card-tier grants delivered only after the transition's Modifier
    // batch ACKs. The worker owns the free-draw row, so it must carry this
    // one-shot metadata rather than routing it through the Modifier bridge.
    uint16_t on_enter_free_draws = 0;
};

// Reversible UniqueSource Modifier template row. The worker resolves the
// definition key hash against the Modifier POD catalog at stage time.
struct RuntimeIdeologyPodModifierTemplate {
    // 材料损益 selector：kind 决定用哪种指标挑目标，param0/1 是其参数。
    int32_t selector_kind = 0;
    int64_t selector_param0 = 0;
    int64_t selector_param1 = 0;
    uint64_t definition_key_hash = 0;
    int32_t domain = 0;
    int32_t magnitude_q16 = 65536;
    // Appended for the conditional / cell-scoped expansion
    // (docs/plans/ideology-worker-pod-conditions-plan.md, 阶段 A). Nothing reads
    // these yet: they stay at their defaults until the compiler emits them and the
    // plan path consumes them, so adding them now cannot change behaviour.
    //
    // `selector_kind` mirrors `EffectRuntime::SELECTOR_*`; `tag_*` and `condition_*`
    // are CSR windows into the catalog's own requirement tables.
    uint32_t tag_begin = 0;
    uint32_t tag_count = 0;
    uint32_t condition_begin = 0;
    uint32_t condition_count = 0;
};

struct RuntimeIdeologyPodCapacityUnlock {
    int32_t technology_id = -1;
    int32_t ideology_delta = 0;
    int32_t spirit_delta = 0;
};

struct RuntimeIdeologyPodDefinition {
    uint8_t acquisition = 3;
    uint8_t copy_left_programs = 0;
    uint8_t copyable = 1;
    uint8_t school_index = 0;
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
    // Primary + secondary build route bits. Derived catalog metadata for the
    // worker's per-country route_count scalars.
    uint32_t route_mask = 0;
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
    // Material support model (shared with the main runtime). Empty channel table
    // means the catalog predates the model, which the support gate rejects.
    ideology_incidence::IdeologyIncidenceTable incidence;
    // World seed the offer RNG is mixed with. Must be identical on both sides; it
    // is carried in the catalog for that reason. Without it the card order only
    // depended on the country handle, so every session of the same map drew the
    // same sequence.
    uint64_t world_seed = 0;
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
    // X6-a per-term point factors. Their values are frozen per country into
    // RuntimeIdeologyOpinionSnapshot; these ids only tell the host which
    // Modifier POD buckets to copy.
    int32_t point_population_factor_stat_id = -1;
    int32_t point_building_factor_stat_id = -1;
    int32_t point_trade_factor_stat_id = -1;
    // social_media: per-country opinion-factor floor. Frozen into the opinion
    // snapshot for the same reason as the point factors above.
    int32_t opinion_factor_floor_stat_id = -1;
    // One stat id per school, in the same order as `school_keys`. The host
    // freezes each lane into `school_strength_factor_q16`.
    std::vector<int32_t> school_strength_factor_stat_ids;
    std::vector<std::string> school_keys;
    // Route ids in catalog order, identical to NativeIdeologyRuntime.
    std::vector<std::string> route_keys;
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
    // 材料损益：每国的阶级立场负载（与经济侧 CountryClassOpinionSnapshot 对齐）。
    int32_t incidence_channel_count = 0;
    std::vector<uint8_t> incidence_measured;
    std::vector<int32_t> class_incidence_q16;
    uint64_t revision = 0;
    uint64_t class_hash = 0;
    int64_t committed_day = -1;
    // Development period this opinion covers, expressed as a monotone index.
    // Accrual is idempotent per PERIOD, not per revision (A1): the revision is
    // bumped on every Economy publish, so two authorities that publish at
    // different rates settled the same day different numbers of times. The
    // period index is the same number on both sides for the same day.
    int64_t period_index = -1;
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
    // Frozen X6-a per-term multipliers (Q16); empty means 1.0 for each term.
    std::vector<int32_t> point_population_factor_q16;
    std::vector<int32_t> point_building_factor_q16;
    std::vector<int32_t> point_trade_factor_q16;
    // Frozen country.ideology.opinion_factor_floor (Q16). Empty means 0.5, the
    // pre-social_media identity for every existing caller.
    std::vector<int32_t> opinion_factor_floor_q16;
    // Country-major, school-minor frozen strength multipliers. Empty means the
    // catalog has no school-strength stats and every card reads 1.0.
    std::vector<int32_t> school_strength_factor_q16;
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

} // namespace pk

#include "country_ai_core.h"

#include "country_core_apply.h"

#include <algorithm>
#include <cstring>
#include <iterator>
#include <limits>
#include <tuple>

#if defined(_MSC_VER)
#include <intrin.h>
#endif

namespace pk {

namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;
constexpr int32_t RESERVE_DAYS_CAP = 3650;
constexpr int32_t TAX_PRESSURE_LIMIT = 8;
constexpr int64_t CASH_EMA_LIMIT = 10000000000000ll;

uint64_t fnv_u64(uint64_t hash, uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        hash ^= (value >> (i * 8)) & 0xffu;
        hash *= FNV_PRIME;
    }
    return hash;
}

int ctz64(uint64_t value) {
#if defined(_MSC_VER)
    unsigned long index = 0;
    _BitScanForward64(&index, value);
    return static_cast<int>(index);
#else
    return __builtin_ctzll(value);
#endif
}

int64_t clamp64(int64_t value, int64_t lo, int64_t hi) {
    return value < lo ? lo : (value > hi ? hi : value);
}

int32_t clamp_q16(int64_t value) {
    return static_cast<int32_t>(clamp64(value, 0, COUNTRY_AI_Q16));
}

void set_reason(CountryAiDecision &decision, const char *reason) {
    std::strncpy(decision.reason.data(), reason, decision.reason.size() - 1);
    decision.reason[decision.reason.size() - 1] = '\0';
}

#include "country_ai_core_research.inc"
struct ThinkContext {
    const CountryAiCatalog &catalog;
    const CountryAiPlanInput &input;
    CountryAiMemory &mem;
    const CountryAiPersonality &personality;
    CountryAiObservation obs;
    MilestoneStatus milestones;
    uint64_t &decision_id;
    CountryAiPlanOutput &out;
    uint32_t emitted = 0;
};

CountryAiDecision &push_decision(ThinkContext &ctx, uint8_t module, uint8_t outcome,
                                 int32_t subject, const char *reason) {
    CountryAiDecision decision;
    decision.id = ++ctx.decision_id;
    decision.day = ctx.input.day;
    decision.slot = ctx.obs.slot;
    decision.handle = ctx.obs.handle;
    decision.module = module;
    decision.outcome = outcome;
    decision.agenda = ctx.mem.agenda;
    decision.subject = subject;
    set_reason(decision, reason);
    ctx.out.decisions.push_back(decision);
    return ctx.out.decisions.back();
}

CountryAiCommand &push_command(ThinkContext &ctx, uint16_t opcode, uint8_t module) {
    CountryAiCommand command;
    command.opcode = opcode;
    command.module = module;
    command.slot = ctx.obs.slot;
    command.target_handle = ctx.obs.handle;
    ctx.out.commands.push_back(command);
    ++ctx.emitted;
    return ctx.out.commands.back();
}

int32_t noise_bp(const CountryAiCatalog &catalog, uint64_t slot_handle, int64_t day,
                 uint64_t salt) {
    if (catalog.decision_noise_bp <= 0) return 0;
    const uint64_t span = static_cast<uint64_t>(catalog.decision_noise_bp) * 2u + 1u;
    const uint64_t roll = country_ai_mix(catalog.seed, slot_handle,
                                         static_cast<uint64_t>(day), salt) % span;
    return static_cast<int32_t>(roll) - catalog.decision_noise_bp;
}

void think_strategy(ThinkContext &ctx) {
    const CountryAiCatalog &catalog = ctx.catalog;
    std::array<int64_t, COUNTRY_AI_INPUT_COUNT> inputs{};
    inputs[COUNTRY_AI_INPUT_RESERVE_DAYS] = ctx.obs.reserve_days;
    inputs[COUNTRY_AI_INPUT_SATISFACTION_Q16] = ctx.obs.satisfaction_q16;
    inputs[COUNTRY_AI_INPUT_FRONTIER_CELLS] = ctx.obs.frontier;
    inputs[COUNTRY_AI_INPUT_MILESTONE_GAP] = ctx.milestones.goal >= 0 ? ctx.milestones.gap : 1000;
    inputs[COUNTRY_AI_INPUT_TERRITORY_CELLS] = ctx.obs.territory;
    inputs[COUNTRY_AI_INPUT_ESSENTIALS_Q16] = ctx.obs.essentials_q16;
    inputs[COUNTRY_AI_INPUT_EXPEDITIONS] = ctx.obs.economy != nullptr
        ? ctx.obs.economy->expeditions_active : 0;
    inputs[COUNTRY_AI_INPUT_CASH_TREND_BP] = ctx.obs.cash_trend_bp;
    std::array<int32_t, COUNTRY_AI_AGENDA_COUNT> scores{};
    for (uint32_t a = 0; a < COUNTRY_AI_AGENDA_COUNT; ++a) {
        const CountryAiAgendaDef &agenda = catalog.agendas[a];
        std::array<int32_t, COUNTRY_AI_MAX_CONSIDERATIONS> parts{};
        for (uint32_t i = 0; i < agenda.consideration_count; ++i) {
            const CountryAiCurve &curve = agenda.considerations[i];
            parts[i] = country_ai_eval_curve(curve, inputs[curve.input % COUNTRY_AI_INPUT_COUNT]);
        }
        int64_t score = country_ai_combine_scores(parts.data(), agenda.consideration_count);
        score = score * ctx.personality.agenda_bias_bp[a] / 10000;
        if (a == ctx.mem.agenda && ctx.mem.agenda_since_day >= 0)
            score = score * (10000 + catalog.agenda_inertia_bp) / 10000;
        score = score * (10000 + noise_bp(catalog, ctx.obs.handle, ctx.input.day, 0x5354u + a)) / 10000;
        scores[a] = static_cast<int32_t>(clamp64(score, 0, std::numeric_limits<int32_t>::max()));
    }
    uint32_t best = 0;
    for (uint32_t a = 1; a < COUNTRY_AI_AGENDA_COUNT; ++a)
        if (scores[a] > scores[best]) best = a;
    std::array<uint32_t, COUNTRY_AI_AGENDA_COUNT> order{{0, 1, 2, 3, 4}};
    std::stable_sort(order.begin(), order.end(), [&](uint32_t l, uint32_t r) {
        return scores[l] > scores[r];
    });
    const bool locked = ctx.mem.agenda_since_day >= 0 &&
        ctx.input.day - ctx.mem.agenda_since_day < catalog.agenda_min_days;
    const bool change = best != ctx.mem.agenda && !locked;
    const uint8_t previous = ctx.mem.agenda;
    if (change || ctx.mem.agenda_since_day < 0) {
        ctx.mem.agenda = static_cast<uint8_t>(best);
        ctx.mem.agenda_since_day = ctx.input.day;
    }
    CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_STRATEGY,
        COUNTRY_AI_OUTCOME_EMITTED, ctx.mem.agenda,
        change ? "agenda_switch" : (locked && best != previous ? "agenda_locked" : "agenda_keep"));
    decision.agenda = ctx.mem.agenda;
    decision.value = previous;
    decision.score_q16 = scores[ctx.mem.agenda];
    for (uint32_t i = 0; i < 3; ++i) {
        decision.alt_subject[i] = static_cast<int32_t>(order[i + 1]);
        decision.alt_score_q16[i] = scores[order[i + 1]];
    }
    ctx.mem.last_strategy_day = ctx.input.day;
}

#include "country_ai_core_research_decision.inc"
void think_tax(ThinkContext &ctx) {
    const CountryAiCatalog &catalog = ctx.catalog;
    const RuntimeCountryPodSnapshot &state = *ctx.input.state;
    const CountryAiAgendaDef &agenda = catalog.agendas[ctx.mem.agenda];
    const CountryAiPersonality &p = ctx.personality;
    const size_t base = static_cast<size_t>(ctx.obs.slot) * COUNTRY_AI_TAX_KIND_COUNT;
    const bool first = ctx.mem.last_tax_day < 0;
    ctx.mem.last_tax_day = ctx.input.day;
    const auto managed = [&](uint32_t kind) {
        return (catalog.tax_kind_mask & (1u << kind)) != 0 &&
               base + kind < state.country_tax_defaults.size() &&
               state.country_tax_default_modes[base + kind] == 0;
    };
    const auto emit = [&](uint32_t kind, int32_t rate, const char *reason, int32_t score) {
        CountryAiCommand &command = push_command(ctx, 11, COUNTRY_AI_MODULE_TAX);
        command.tax_kind = static_cast<int32_t>(kind);
        command.tax_rate_bp = rate;
        command.tax_mode = 0;
        CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_TAX,
            COUNTRY_AI_OUTCOME_EMITTED, static_cast<int32_t>(kind), reason);
        decision.value = rate;
        decision.amount = state.country_tax_defaults[base + kind];
        decision.score_q16 = score;
    };
    if (first) {
        for (uint32_t kind = 0; kind < COUNTRY_AI_TAX_KIND_COUNT; ++kind) {
            if (!managed(kind)) continue;
            const int32_t target = std::clamp(p.tax_initial_bp[kind], p.tax_min_bp[kind],
                                              std::max(p.tax_min_bp[kind], p.tax_max_bp[kind]));
            if (state.country_tax_defaults[base + kind] != target)
                emit(kind, target, "tax_initial", 0);
        }
        return;
    }
    if (ctx.obs.economy == nullptr) {
        push_decision(ctx, COUNTRY_AI_MODULE_TAX, COUNTRY_AI_OUTCOME_SKIPPED, -1,
                      "economy_digest_missing");
        return;
    }
    const int32_t sat = ctx.obs.satisfaction_q16;
    const int32_t floor = clamp_q16(static_cast<int64_t>(catalog.satisfaction_floor_q16) +
                                    agenda.satisfaction_floor_shift_q16);
    const int32_t band = catalog.tax_deadband_q16;
    const int64_t target_reserve = static_cast<int64_t>(catalog.reserve_target_days) *
        (10000 + agenda.tax_bias_bp) / 10000;
    int32_t &pressure = ctx.mem.tax_pressure;
    const char *reason = "tax_hold";
    if (sat < floor - band) {
        pressure = std::max(-TAX_PRESSURE_LIMIT, std::min(-1, pressure - 1));
        reason = "tax_cut_satisfaction";
    } else if (ctx.obs.reserve_days < target_reserve && ctx.mem.cash_delta_ema < 0) {
        pressure = std::min(TAX_PRESSURE_LIMIT, std::max(1, pressure + 1));
        reason = "tax_raise_deficit";
    } else if (ctx.obs.reserve_days >= std::min<int64_t>(RESERVE_DAYS_CAP, target_reserve * 2) &&
               ctx.mem.cash_delta_ema >= 0 && sat < floor + band * 2) {
        pressure = std::max(-TAX_PRESSURE_LIMIT, std::min(-1, pressure - 1));
        reason = "tax_cut_surplus";
    } else {
        pressure += pressure > 0 ? -1 : (pressure < 0 ? 1 : 0);
        push_decision(ctx, COUNTRY_AI_MODULE_TAX, COUNTRY_AI_OUTCOME_SKIPPED, -1, reason)
            .score_q16 = sat;
        return;
    }
    const int32_t step = std::clamp(catalog.tax_step_bp * std::abs(pressure),
                                    catalog.tax_step_bp, catalog.tax_max_step_bp);
    int32_t pick = -1;
    int32_t pick_room = 0;
    for (uint32_t kind = 0; kind < COUNTRY_AI_TAX_KIND_COUNT; ++kind) {
        if (!managed(kind)) continue;
        const int32_t rate = state.country_tax_defaults[base + kind];
        const int32_t room = pressure < 0 ? rate - p.tax_min_bp[kind] : p.tax_max_bp[kind] - rate;
        if (room > pick_room) { pick = static_cast<int32_t>(kind); pick_room = room; }
    }
    if (pick < 0 || (pressure > 0 && sat < floor)) {
        push_decision(ctx, COUNTRY_AI_MODULE_TAX, COUNTRY_AI_OUTCOME_SKIPPED, -1,
                      pick < 0 ? "tax_no_headroom" : "tax_raise_blocked").score_q16 = sat;
        return;
    }
    const uint32_t kind = static_cast<uint32_t>(pick);
    const int32_t rate = state.country_tax_defaults[base + kind];
    const int32_t next = pressure < 0 ? std::max(p.tax_min_bp[kind], rate - step)
                                      : std::min(p.tax_max_bp[kind], rate + step);
    if (next != rate) emit(kind, next, reason, sat);
}

// Food subsidy as a player would set it: a negative business-tax override on
// every survival-food building type, switched on while too many people are
// hungry and off once hunger recedes. The switch state is read back from the
// committed Country tax policy, so it needs no memory. Returns the rate in force.
int32_t think_subsidy(ThinkContext &ctx) {
    constexpr int32_t BUSINESS = 2;
    const CountryAiCatalog &catalog = ctx.catalog;
    const RuntimeCountryPodSnapshot &state = *ctx.input.state;
    const CountryAiEconomyRow *row = ctx.obs.economy;
    const CountryAiEconomyDigest *digest = ctx.input.economy;
    const int32_t rate = catalog.subsidy_food_rate_bp;
    const size_t types = state.building_type_count;
    const size_t base = static_cast<size_t>(ctx.obs.slot) * types;
    if (rate == 0 || row == nullptr || digest == nullptr ||
        (catalog.tax_kind_mask & (1u << BUSINESS)) == 0 ||
        digest->food_building_types.size() != types ||
        state.country_business_tax_overrides.size() < base + types)
        return 0;
    size_t food = 0;
    size_t active = 0;
    for (size_t t = 0; t < types; ++t) {
        if (digest->food_building_types[t] == 0) continue;
        ++food;
        if (state.country_business_tax_overrides[base + t] == rate) ++active;
    }
    if (food == 0) return 0;
    const bool on = active > 0;
    bool want = on;
    if (!on && row->hungry_share_q16 >= catalog.subsidy_on_hungry_share_q16) want = true;
    else if (on && row->hungry_share_q16 <= catalog.subsidy_off_hungry_share_q16) want = false;
    if (want == on && (!want || active == food)) return want ? rate : 0;
    uint32_t changed = 0;
    for (size_t t = 0; t < types; ++t) {
        if (digest->food_building_types[t] == 0) continue;
        const bool at_rate = state.country_business_tax_overrides[base + t] == rate;
        if (want == at_rate) continue;
        CountryAiCommand &command = push_command(ctx, want ? 12 : 13, COUNTRY_AI_MODULE_TAX);
        command.tax_kind = BUSINESS;
        command.tax_item = static_cast<int32_t>(t);
        command.tax_rate_bp = want ? rate : 0;
        command.tax_mode = 0;
        ++changed;
    }
    CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_TAX,
        COUNTRY_AI_OUTCOME_EMITTED, BUSINESS, want ? "food_subsidy_on" : "food_subsidy_off");
    decision.value = want ? rate : 0;
    decision.amount = changed;
    decision.score_q16 = row->hungry_share_q16;
    return want ? rate : 0;
}

#include "country_ai_core_colonization.inc"
bool slot_thinks(const CountryAiCatalog &catalog, const CountryAiMemory &mem,
                 int32_t slot, int64_t day) {
    if (mem.controlled == 0 || mem.handle == 0) return false;
    if (mem.initialized == 0) return true;
    const int64_t period = std::max(1, catalog.think_days);
    return ((day + slot) % period) == 0;
}

} // namespace

const CountryAiEconomyRow *CountryAiEconomyDigest::find(uint64_t handle) const {
    const auto it = std::lower_bound(rows.begin(), rows.end(), handle,
        [](const CountryAiEconomyRow &row, uint64_t h) { return row.country_handle < h; });
    return it != rows.end() && it->country_handle == handle ? &*it : nullptr;
}

bool CountryAiTechIndex::build(const RuntimeCountryPodCatalog &catalog) {
    technology_count = catalog.technology_count;
    words = catalog.technology_words;
    catalog_hash = catalog.catalog_hash;
    milestones.clear();
    is_milestone.assign(technology_count, 0);
    closure.assign(static_cast<size_t>(technology_count) * words, 0);
    if (catalog.prerequisite_offsets.size() != technology_count + 1u ||
        catalog.technology_costs.size() != technology_count ||
        catalog.technology_domains.size() != technology_count) {
        technology_count = 0;
        return false;
    }
    const bool has_milestones = catalog.milestone_offsets.size() == technology_count + 1u &&
        catalog.milestone_required_counts.size() == technology_count;
    if (has_milestones) {
        for (uint32_t t = 0; t < technology_count; ++t) {
            if (catalog.milestone_offsets[t + 1] > catalog.milestone_offsets[t]) {
                milestones.push_back(static_cast<int32_t>(t));
                is_milestone[t] = 1;
            }
        }
    }
    // Iterative DFS with a three-colour mark; the catalog is a DAG but a cycle
    // is tolerated (closure just stops at the back edge).
    std::vector<uint8_t> colour(technology_count, 0);
    std::vector<std::pair<int32_t, int32_t>> stack;
    for (uint32_t root = 0; root < technology_count; ++root) {
        if (colour[root] != 0) continue;
        stack.push_back({static_cast<int32_t>(root), catalog.prerequisite_offsets[root]});
        colour[root] = 1;
        while (!stack.empty()) {
            auto &[tech, edge] = stack.back();
            const int32_t end = catalog.prerequisite_offsets[static_cast<size_t>(tech) + 1u];
            if (edge < end) {
                const int32_t prereq = catalog.prerequisites[static_cast<size_t>(edge++)];
                if (prereq >= 0 && prereq < static_cast<int32_t>(technology_count) &&
                    colour[static_cast<size_t>(prereq)] == 0) {
                    colour[static_cast<size_t>(prereq)] = 1;
                    stack.push_back({prereq, catalog.prerequisite_offsets[static_cast<size_t>(prereq)]});
                }
                continue;
            }
            const size_t base = static_cast<size_t>(tech) * words;
            closure[base + static_cast<size_t>(tech / 64)] |= uint64_t{1} << (tech % 64);
            for (int32_t e = catalog.prerequisite_offsets[static_cast<size_t>(tech)]; e < end; ++e) {
                const int32_t prereq = catalog.prerequisites[static_cast<size_t>(e)];
                if (prereq < 0 || prereq >= static_cast<int32_t>(technology_count) ||
                    colour[static_cast<size_t>(prereq)] != 2) continue;
                const size_t pbase = static_cast<size_t>(prereq) * words;
                for (uint32_t w = 0; w < words; ++w) closure[base + w] |= closure[pbase + w];
            }
            colour[static_cast<size_t>(tech)] = 2;
            stack.pop_back();
        }
    }
    return true;
}

uint64_t country_ai_splitmix64(uint64_t &state) {
    uint64_t z = (state += 0x9e3779b97f4a7c15ull);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

uint64_t country_ai_mix(uint64_t seed, uint64_t a, uint64_t b, uint64_t c) {
    uint64_t state = seed ^ 0x4149434f554e5452ull;
    state ^= country_ai_splitmix64(state) ^ a;
    state ^= country_ai_splitmix64(state) ^ b;
    state ^= country_ai_splitmix64(state) ^ c;
    return country_ai_splitmix64(state);
}

int32_t country_ai_eval_curve(const CountryAiCurve &curve, int64_t x) {
    int64_t t = 0;
    if (curve.x1 == curve.x0) {
        t = x >= curve.x1 ? COUNTRY_AI_Q16 : 0;
    } else {
        const int64_t lo = std::min(curve.x0, curve.x1);
        const int64_t hi = std::max(curve.x0, curve.x1);
        const int64_t cx = clamp64(x, lo, hi);
        const int64_t span = curve.x1 - curve.x0;
        // |cx - x0| <= |span| so the quotient is in [0, Q16]; scale first by
        // dividing the span when it is large to avoid overflow.
        if (std::abs(span) > (int64_t{1} << 40))
            t = (cx - curve.x0) / (span / COUNTRY_AI_Q16 == 0 ? 1 : span / COUNTRY_AI_Q16);
        else
            t = (cx - curve.x0) * COUNTRY_AI_Q16 / span;
        t = clamp64(t, 0, COUNTRY_AI_Q16);
    }
    int64_t s = t;
    switch (curve.kind) {
    case COUNTRY_AI_CURVE_QUADRATIC: s = t * t / COUNTRY_AI_Q16; break;
    case COUNTRY_AI_CURVE_INV_QUADRATIC: {
        const int64_t u = COUNTRY_AI_Q16 - t;
        s = COUNTRY_AI_Q16 - u * u / COUNTRY_AI_Q16;
        break;
    }
    case COUNTRY_AI_CURVE_SMOOTHSTEP:
        s = t * t / COUNTRY_AI_Q16 * (3 * COUNTRY_AI_Q16 - 2 * t) / COUNTRY_AI_Q16;
        break;
    case COUNTRY_AI_CURVE_STEP: s = t >= COUNTRY_AI_Q16 / 2 ? COUNTRY_AI_Q16 : 0; break;
    default: break;
    }
    const int64_t y = static_cast<int64_t>(curve.y0_q16) +
        (static_cast<int64_t>(curve.y1_q16) - curve.y0_q16) * s / COUNTRY_AI_Q16;
    return clamp_q16(y);
}

int32_t country_ai_combine_scores(const int32_t *scores, uint32_t count) {
    if (count == 0) return COUNTRY_AI_Q16;
    // Infinite Axis Utility compensation: multiplying many factors in [0,1]
    // drags scores down with the factor count, so each factor is lifted by a
    // share of its own shortfall before multiplying.
    const int64_t modification = COUNTRY_AI_Q16 - COUNTRY_AI_Q16 / static_cast<int64_t>(count);
    int64_t product = COUNTRY_AI_Q16;
    for (uint32_t i = 0; i < count; ++i) {
        const int64_t s = clamp_q16(scores[i]);
        const int64_t makeup = (COUNTRY_AI_Q16 - s) * modification / COUNTRY_AI_Q16;
        const int64_t lifted = s + makeup * s / COUNTRY_AI_Q16;
        product = product * clamp_q16(lifted) / COUNTRY_AI_Q16;
    }
    return clamp_q16(product);
}

bool country_ai_normalize_weights(const std::array<int64_t, COUNTRY_AI_DOMAIN_COUNT> &demand,
                                  std::array<int32_t, COUNTRY_AI_DOMAIN_COUNT> &out) {
    std::array<int64_t, COUNTRY_AI_DOMAIN_COUNT> value{};
    int64_t total = 0;
    for (uint32_t d = 0; d < COUNTRY_AI_DOMAIN_COUNT; ++d) {
        value[d] = clamp64(demand[d], 0, int64_t{1} << 52);
        total += value[d];
    }
    if (total <= 0) return false;
    // Keep value * 10000 inside int64 regardless of catalog cost scale.
    while (total > (int64_t{1} << 48)) {
        total = 0;
        for (int64_t &v : value) { v >>= 4; total += v; }
        if (total <= 0) return false;
    }
    // Largest remainder keeps the sum at exactly 10000.
    std::array<int64_t, COUNTRY_AI_DOMAIN_COUNT> remainder{};
    int32_t assigned = 0;
    for (uint32_t d = 0; d < COUNTRY_AI_DOMAIN_COUNT; ++d) {
        out[d] = static_cast<int32_t>(value[d] * 10000 / total);
        remainder[d] = (value[d] * 10000) % total;
        assigned += out[d];
    }
    while (assigned < 10000) {
        uint32_t best = 0;
        for (uint32_t d = 1; d < COUNTRY_AI_DOMAIN_COUNT; ++d)
            if (remainder[d] > remainder[best]) best = d;
        ++out[best];
        remainder[best] = -1;
        ++assigned;
    }
    return true;
}

#include "country_ai_core_catalog.inc"
uint8_t country_ai_pick_personality(const CountryAiCatalog &catalog, uint64_t seed,
                                    int32_t slot, uint64_t handle) {
    if (catalog.personalities.empty()) return 0;
    int64_t total = 0;
    for (const CountryAiPersonality &p : catalog.personalities) total += std::max(0, p.weight);
    if (total <= 0) return 0;
    int64_t roll = static_cast<int64_t>(country_ai_mix(seed, static_cast<uint64_t>(slot),
        handle, 0x50455253u) % static_cast<uint64_t>(total));
    for (size_t i = 0; i < catalog.personalities.size(); ++i) {
        const int64_t w = std::max(0, catalog.personalities[i].weight);
        if (roll < w) return static_cast<uint8_t>(i);
        roll -= w;
    }
    return 0;
}

void country_ai_sync_memory(const CountryAiCatalog &catalog,
                            const RuntimeCountryPodSnapshot &state,
                            const std::vector<uint64_t> &excluded_sorted,
                            std::vector<CountryAiMemory> &memory) {
    memory.resize(state.country_count);
    for (uint32_t slot = 0; slot < state.country_count; ++slot) {
        const bool active = slot < state.country_active.size() && state.country_active[slot] != 0;
        const uint64_t handle = active
            ? ((static_cast<uint64_t>(state.country_generation[slot]) << 32u) | slot) : 0;
        CountryAiMemory &mem = memory[slot];
        if (mem.handle != handle) {
            mem = CountryAiMemory{};
            mem.handle = handle;
            if (handle != 0)
                mem.personality = country_ai_pick_personality(catalog, catalog.seed,
                                                              static_cast<int32_t>(slot), handle);
        }
        mem.controlled = handle != 0 &&
            !std::binary_search(excluded_sorted.begin(), excluded_sorted.end(), handle) ? 1 : 0;
    }
}

bool country_ai_due(const CountryAiCatalog &catalog,
                    const std::vector<CountryAiMemory> &memory, int64_t day) {
    for (size_t slot = 0; slot < memory.size(); ++slot)
        if (slot_thinks(catalog, memory[slot], static_cast<int32_t>(slot), day)) return true;
    return false;
}

void country_ai_plan(const CountryAiCatalog &catalog, const CountryAiPlanInput &input,
                     std::vector<CountryAiMemory> &memory, uint64_t &decision_id,
                     CountryAiPlanOutput &out) {
    if (input.state == nullptr || input.catalog == nullptr || input.tech == nullptr) return;
    const RuntimeCountryPodSnapshot &state = *input.state;
    const RuntimeCountryPodCatalog &pod = *input.catalog;
    if (pod.technology_words != state.technology_words ||
        input.tech->technology_count != pod.technology_count)
        return;
    std::vector<int32_t> scratch;
    const int64_t day = input.day;
    const uint32_t slots = std::min<uint32_t>(state.country_count,
                                              static_cast<uint32_t>(memory.size()));
    for (uint32_t slot = 0; slot < slots; ++slot) {
        CountryAiMemory &mem = memory[slot];
        if (!slot_thinks(catalog, mem, static_cast<int32_t>(slot), day)) continue;
        if (slot >= state.country_active.size() || state.country_active[slot] == 0) continue;
        const CountryAiPersonality &personality =
            catalog.personalities[std::min<size_t>(mem.personality, catalog.personalities.size() - 1)];
        ThinkContext ctx{catalog, input, mem, personality, {}, {}, decision_id, out};
        CountryAiObservation &obs = ctx.obs;
        obs.slot = static_cast<int32_t>(slot);
        obs.handle = mem.handle;
        obs.cash = state.country_cash[slot];
        obs.territory = state.territory_count[slot];
        // Cash trend: exponential moving average of per-day treasury change.
        if (mem.last_cash_day >= 0 && day > mem.last_cash_day) {
            const int64_t delta = clamp64((obs.cash - mem.last_cash) / (day - mem.last_cash_day),
                                          -CASH_EMA_LIMIT, CASH_EMA_LIMIT);
            mem.cash_delta_ema = mem.initialized ? mem.cash_delta_ema + (delta - mem.cash_delta_ema) / 4
                                                 : delta;
        }
        mem.last_cash = obs.cash;
        mem.last_cash_day = day;
        const int64_t burn = std::max<int64_t>(0, -mem.cash_delta_ema);
        obs.reserve_days = burn == 0 ? RESERVE_DAYS_CAP
            : static_cast<int32_t>(clamp64(std::max<int64_t>(0, obs.cash) / burn, 0, RESERVE_DAYS_CAP));
        obs.cash_trend_bp = obs.cash > 0
            ? static_cast<int32_t>(clamp64(mem.cash_delta_ema * 30 / std::max<int64_t>(1, obs.cash / 10000),
                                           -10000, 10000))
            : (mem.cash_delta_ema < 0 ? -10000 : 0);
        obs.frontier = count_frontier(state, obs.slot, input.neighbors, scratch);
        obs.economy = input.economy != nullptr ? input.economy->find(mem.handle) : nullptr;
        if (obs.economy != nullptr && obs.economy->population > 0) {
            obs.satisfaction_q16 = obs.economy->satisfaction_q16;
            obs.essentials_q16 = obs.economy->essentials_q16;
            mem.satisfaction_ema_q16 = mem.satisfaction_ema_q16 == 0 ? obs.satisfaction_q16
                : mem.satisfaction_ema_q16 + (obs.satisfaction_q16 - mem.satisfaction_ema_q16) / 4;
        } else {
            obs.economy = nullptr;
            obs.satisfaction_q16 = mem.satisfaction_ema_q16 != 0 ? mem.satisfaction_ema_q16
                                                                 : COUNTRY_AI_Q16 / 2;
            obs.essentials_q16 = COUNTRY_AI_Q16 / 2;
        }
        TechView view(state, pod, obs.slot);
        ctx.milestones = milestone_status(view, *input.tech);
        mem.goal_milestone = ctx.milestones.goal;
        mem.milestone_gap = ctx.milestones.gap;
        mem.completed_milestones = ctx.milestones.completed;
        const bool first = mem.initialized == 0;
        if (first || day - mem.last_strategy_day >= catalog.strategy_days) think_strategy(ctx);
        if (first || day - mem.last_research_day >= catalog.research_days) think_research(ctx, view);
        if (first || day - mem.last_tax_day >= catalog.tax_days) think_tax(ctx);
        if (!first && day - mem.last_colonize_day >= catalog.colonize_days) think_colonize(ctx);
        const int32_t food_subsidy_bp = first ? 0 : think_subsidy(ctx);
        if (obs.queued_techs == 0) {
            for (int32_t tech = 0; tech < static_cast<int32_t>(pod.technology_count); ++tech)
                obs.queued_techs += view.is_queued(tech) ? 1 : 0;
        }
        mem.initialized = 1;
        mem.last_think_day = day;
        mem.commands_emitted += ctx.emitted;
        ++out.countries_thought;
        CountryAiRecordRow row;
        row.day = day;
        row.slot = obs.slot;
        row.handle = obs.handle;
        row.agenda = mem.agenda;
        row.personality = mem.personality;
        row.cash = obs.cash;
        row.cash_delta_ema = mem.cash_delta_ema;
        row.reserve_days = obs.reserve_days;
        row.satisfaction_q16 = obs.satisfaction_q16;
        row.essentials_q16 = obs.essentials_q16;
        row.population = obs.economy != nullptr ? obs.economy->population : 0;
        row.territory = obs.territory;
        row.frontier = obs.frontier;
        row.completed_milestones = mem.completed_milestones;
        row.goal_milestone = mem.goal_milestone;
        row.milestone_gap = mem.milestone_gap;
        row.queued_techs = obs.queued_techs;
        row.research_share_bp = mem.research_share_bp;
        row.tax_paid = obs.economy != nullptr ? obs.economy->tax_paid : 0;
        row.household_income = obs.economy != nullptr ? obs.economy->income : 0;
        if (obs.economy != nullptr) {
            row.carrying_k_eff = obs.economy->carrying_k_eff;
            row.carrying_k_geo = obs.economy->carrying_k_geo;
            row.carrying_load_q16 = obs.economy->carrying_load_q16;
            row.hungry_share_q16 = obs.economy->hungry_share_q16;
        }
        row.food_subsidy_bp = food_subsidy_bp;
        for (uint32_t k = 0; k < 3; ++k)
            row.tax_bp[k] = state.country_tax_defaults[static_cast<size_t>(slot) *
                                                       COUNTRY_AI_TAX_KIND_COUNT + k];
        row.expeditions = obs.economy != nullptr ? obs.economy->expeditions_active : 0;
        row.families = obs.economy != nullptr ? obs.economy->family_count : 0;
        row.colonize_started = obs.economy != nullptr ? obs.economy->ai_colonization_started : 0;
        row.colonize_failures = obs.economy != nullptr ? obs.economy->ai_colonization_failures : 0;
        row.commands_emitted = mem.commands_emitted;
        row.commands_rejected = mem.commands_rejected;
        out.records.push_back(row);
    }
}

uint64_t country_ai_hash_memory(const std::vector<CountryAiMemory> &memory) {
    uint64_t h = FNV_OFFSET;
    for (const CountryAiMemory &m : memory) {
        const uint64_t fields[] = {
            m.handle, m.controlled, m.personality, m.agenda, m.initialized,
            static_cast<uint64_t>(m.agenda_since_day), static_cast<uint64_t>(m.last_think_day),
            static_cast<uint64_t>(m.last_strategy_day), static_cast<uint64_t>(m.last_research_day),
            static_cast<uint64_t>(m.last_tax_day), static_cast<uint64_t>(m.last_colonize_day),
            static_cast<uint64_t>(m.colonize_cooldown_until), static_cast<uint64_t>(m.last_cash),
            static_cast<uint64_t>(m.last_cash_day), static_cast<uint64_t>(m.cash_delta_ema),
            static_cast<uint64_t>(static_cast<int64_t>(m.satisfaction_ema_q16)),
            static_cast<uint64_t>(static_cast<int64_t>(m.goal_milestone)),
            static_cast<uint64_t>(static_cast<int64_t>(m.milestone_gap)),
            static_cast<uint64_t>(static_cast<int64_t>(m.completed_milestones)),
            static_cast<uint64_t>(static_cast<int64_t>(m.tax_pressure)),
            m.colonize_failures_seen, m.colonize_started_seen, m.commands_emitted,
            m.commands_rejected, m.colonize_intents,
            static_cast<uint64_t>(static_cast<int64_t>(m.colonize_last_target)),
            m.colonize_bad_cursor,
            static_cast<uint64_t>(static_cast<int64_t>(m.research_share_bp))};
        for (const uint64_t f : fields) h = fnv_u64(h, f);
        for (const int32_t cell : m.colonize_bad_targets)
            h = fnv_u64(h, static_cast<uint64_t>(static_cast<int64_t>(cell)));
    }
    return h & 0x7fffffffffffffffull;
}

const char *country_ai_agenda_name(uint8_t agenda) {
    switch (agenda) {
    case COUNTRY_AI_AGENDA_DEVELOP: return "develop";
    case COUNTRY_AI_AGENDA_EXPAND: return "expand";
    case COUNTRY_AI_AGENDA_ACCUMULATE: return "accumulate";
    case COUNTRY_AI_AGENDA_ERA_PUSH: return "era_push";
    case COUNTRY_AI_AGENDA_STABILIZE: return "stabilize";
    default: return "unknown";
    }
}

const char *country_ai_module_name(uint8_t module) {
    switch (module) {
    case COUNTRY_AI_MODULE_STRATEGY: return "strategy";
    case COUNTRY_AI_MODULE_RESEARCH: return "research";
    case COUNTRY_AI_MODULE_TAX: return "tax";
    case COUNTRY_AI_MODULE_COLONIZE: return "colonize";
    case COUNTRY_AI_MODULE_FAMILY: return "family";
    default: return "unknown";
    }
}

const char *country_ai_outcome_name(uint8_t outcome) {
    switch (outcome) {
    case COUNTRY_AI_OUTCOME_EMITTED: return "emitted";
    case COUNTRY_AI_OUTCOME_REJECTED: return "rejected";
    case COUNTRY_AI_OUTCOME_SKIPPED: return "skipped";
    case COUNTRY_AI_OUTCOME_PROBE: return "probe";
    default: return "unknown";
    }
}

} // namespace pk

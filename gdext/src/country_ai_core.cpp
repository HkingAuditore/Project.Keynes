#include "country_ai_core.h"

#include "country_core_apply.h"

#include <algorithm>
#include <cstring>
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

struct TechView {
    const RuntimeCountryPodSnapshot &state;
    const RuntimeCountryPodCatalog &catalog;
    int32_t slot;
    size_t base;
    std::vector<uint64_t> queued;

    TechView(const RuntimeCountryPodSnapshot &s, const RuntimeCountryPodCatalog &c,
             int32_t country_slot)
        : state(s), catalog(c), slot(country_slot),
          base(static_cast<size_t>(country_slot) * c.technology_words),
          queued(c.technology_words, 0) {
        const size_t country_base = static_cast<size_t>(slot) * COUNTRY_AI_DOMAIN_COUNT;
        for (uint32_t domain = 0; domain < COUNTRY_AI_DOMAIN_COUNT; ++domain) {
            const size_t length_index = country_base + domain;
            if (length_index >= state.research_queue_lengths.size()) continue;
            const size_t queue_base = length_index * COUNTRY_AI_QUEUE_SLOTS;
            for (uint32_t i = 0; i < state.research_queue_lengths[length_index]; ++i) {
                const int32_t tech = state.research_queues[queue_base + i];
                if (tech >= 0 && tech < static_cast<int32_t>(c.technology_count))
                    queued[static_cast<size_t>(tech / 64)] |= uint64_t{1} << (tech % 64);
            }
        }
    }
    static bool test(const std::vector<uint64_t> &bits, size_t base, int32_t tech) {
        const size_t word = base + static_cast<size_t>(tech / 64);
        return word < bits.size() && ((bits[word] >> (tech % 64)) & 1u) != 0;
    }
    bool done(int32_t tech) const { return test(state.country_technologies, base, tech); }
    bool discovered(int32_t tech) const { return test(state.country_discovered, base, tech); }
    bool pending(int32_t tech) const {
        return test(state.country_pending_technologies, base, tech);
    }
    bool is_queued(int32_t tech) const { return test(queued, 0, tech); }
    void mark_queued(int32_t tech) {
        queued[static_cast<size_t>(tech / 64)] |= uint64_t{1} << (tech % 64);
    }
    bool available(int32_t tech) const {
        return discovered(tech) && !done(tech) && !pending(tech) && !is_queued(tech) &&
               country_core_technology_prerequisites_met(state, catalog, slot, tech) &&
               country_core_research_condition_met(state, catalog, slot, tech);
    }
    int64_t remaining_closure_cost(const CountryAiTechIndex &index, int32_t tech) const {
        int64_t total = 0;
        const size_t closure_base = static_cast<size_t>(tech) * index.words;
        for (uint32_t w = 0; w < index.words; ++w) {
            uint64_t bits = index.closure[closure_base + w] &
                            ~state.country_technologies[base + w];
            while (bits != 0) {
                const int bit = ctz64(bits);
                bits &= bits - 1;
                const int32_t id = static_cast<int32_t>(w * 64u + static_cast<uint32_t>(bit));
                if (id < static_cast<int32_t>(catalog.technology_count))
                    total += std::max<int64_t>(0, catalog.technology_costs[static_cast<size_t>(id)]);
            }
        }
        return total;
    }
};

struct MilestoneStatus {
    int32_t goal = -1;
    int32_t gap = 0;
    int32_t completed = 0;
};

MilestoneStatus milestone_status(const TechView &view, const CountryAiTechIndex &index) {
    MilestoneStatus status;
    const RuntimeCountryPodCatalog &catalog = view.catalog;
    for (const int32_t milestone : index.milestones) {
        if (view.done(milestone)) { ++status.completed; continue; }
        if (view.pending(milestone)) continue;
        const int32_t entry = static_cast<size_t>(milestone) < catalog.entry_milestone_indices.size()
            ? catalog.entry_milestone_indices[static_cast<size_t>(milestone)] : -1;
        if (entry >= 0 && !view.done(entry)) continue;
        int32_t have = 0;
        const int32_t begin = catalog.milestone_offsets[static_cast<size_t>(milestone)];
        const int32_t end = catalog.milestone_offsets[static_cast<size_t>(milestone + 1)];
        for (int32_t edge = begin; edge < end; ++edge)
            if (view.done(catalog.milestone_candidates[static_cast<size_t>(edge)])) ++have;
        const int32_t required = catalog.milestone_required_counts[static_cast<size_t>(milestone)];
        const int32_t gap = std::max(0, required - have);
        if (status.goal < 0 || gap < status.gap) {
            status.goal = milestone;
            status.gap = gap;
        }
    }
    return status;
}

int32_t count_frontier(const RuntimeCountryPodSnapshot &state, int32_t slot,
                       const std::vector<int32_t> *neighbors, std::vector<int32_t> &scratch) {
    scratch.clear();
    if (neighbors == nullptr || state.territory_offsets.size() != state.country_count + 1u)
        return 0;
    const int32_t begin = state.territory_offsets[static_cast<size_t>(slot)];
    const int32_t end = state.territory_offsets[static_cast<size_t>(slot) + 1u];
    const int32_t cell_count = static_cast<int32_t>(state.cell_country_slot.size());
    for (int32_t i = begin; i < end; ++i) {
        const int32_t cell = state.territory_cells[static_cast<size_t>(i)];
        for (int32_t k = 0; k < 6; ++k) {
            const size_t ni = static_cast<size_t>(cell) * 6u + static_cast<size_t>(k);
            if (ni >= neighbors->size()) break;
            const int32_t n = (*neighbors)[ni];
            if (n < 0 || n >= cell_count) continue;
            if (state.cell_country_slot[static_cast<size_t>(n)] >= 0) continue;
            if (static_cast<size_t>(n) < state.is_water.size() &&
                state.is_water[static_cast<size_t>(n)] != 0) continue;
            scratch.push_back(n);
        }
    }
    std::sort(scratch.begin(), scratch.end());
    scratch.erase(std::unique(scratch.begin(), scratch.end()), scratch.end());
    return static_cast<int32_t>(scratch.size());
}

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

void think_research(ThinkContext &ctx, TechView &view) {
    const CountryAiCatalog &catalog = ctx.catalog;
    const RuntimeCountryPodCatalog &pod = *ctx.input.catalog;
    const RuntimeCountryPodSnapshot &state = *ctx.input.state;
    const CountryAiTechIndex &index = *ctx.input.tech;
    const CountryAiAgendaDef &agenda = catalog.agendas[ctx.mem.agenda];
    ctx.mem.last_research_day = ctx.input.day;
    if (!pod.research_conditions_complete) {
        push_decision(ctx, COUNTRY_AI_MODULE_RESEARCH, COUNTRY_AI_OUTCOME_SKIPPED, -1,
                      "research_conditions_missing");
        return;
    }
    const auto affinity = [&](int32_t tech) {
        const int32_t domain = pod.technology_domains[static_cast<size_t>(tech)];
        const int32_t bp = domain >= 0 && domain < static_cast<int32_t>(COUNTRY_AI_DOMAIN_COUNT)
            ? ctx.personality.domain_affinity_bp[static_cast<size_t>(domain)] : 10000;
        return std::max(1, bp);
    };
    struct Want { int32_t tech; int32_t priority; int64_t effective; };
    std::vector<Want> wants;
    const auto want = [&](int32_t tech, int32_t priority, int64_t effective) {
        for (Want &w : wants) {
            if (w.tech != tech) continue;
            if (std::tie(priority, effective) < std::tie(w.priority, w.effective)) {
                w.priority = priority;
                w.effective = effective;
            }
            return;
        }
        wants.push_back({tech, priority, effective});
    };
    const int32_t goal = ctx.milestones.goal;
    std::array<int32_t, 3> top{{-1, -1, -1}};
    std::array<int32_t, 3> top_score{{0, 0, 0}};
    if (goal >= 0) {
        if (view.available(goal)) want(goal, 0, 0);
        struct Candidate { int32_t tech; int64_t effective; };
        std::vector<Candidate> candidates;
        const int32_t begin = pod.milestone_offsets[static_cast<size_t>(goal)];
        const int32_t end = pod.milestone_offsets[static_cast<size_t>(goal + 1)];
        for (int32_t edge = begin; edge < end; ++edge) {
            const int32_t tech = pod.milestone_candidates[static_cast<size_t>(edge)];
            if (tech < 0 || tech >= static_cast<int32_t>(pod.technology_count) || view.done(tech))
                continue;
            const int64_t remaining = view.remaining_closure_cost(index, tech);
            candidates.push_back({tech, remaining * 10000 / affinity(tech)});
        }
        std::sort(candidates.begin(), candidates.end(), [](const Candidate &l, const Candidate &r) {
            return std::tie(l.effective, l.tech) < std::tie(r.effective, r.tech);
        });
        const size_t take = std::min(candidates.size(), static_cast<size_t>(
            std::max(0, ctx.milestones.gap + (agenda.era_focus ? 1 : 0))));
        for (size_t i = 0; i < std::min<size_t>(3, candidates.size()); ++i) {
            top[i] = candidates[i].tech;
            top_score[i] = static_cast<int32_t>(clamp64(candidates[i].effective, 0,
                std::numeric_limits<int32_t>::max()));
        }
        std::vector<uint64_t> visited(index.words, 0);
        std::vector<int32_t> stack;
        int32_t visits = 0;
        for (size_t c = 0; c < take; ++c) {
            stack.clear();
            stack.push_back(candidates[c].tech);
            while (!stack.empty() && visits < catalog.research_frontier_visit_limit) {
                const int32_t node = stack.back();
                stack.pop_back();
                if (TechView::test(visited, 0, node)) continue;
                visited[static_cast<size_t>(node / 64)] |= uint64_t{1} << (node % 64);
                ++visits;
                if (view.done(node) || view.pending(node) || view.is_queued(node)) continue;
                if (view.available(node)) {
                    want(node, agenda.era_focus ? 1 : 2, candidates[c].effective);
                    continue;
                }
                const int32_t entry = static_cast<size_t>(node) < pod.entry_milestone_indices.size()
                    ? pod.entry_milestone_indices[static_cast<size_t>(node)] : -1;
                if (entry >= 0 && !view.done(entry)) stack.push_back(entry);
                const int32_t pb = pod.prerequisite_offsets[static_cast<size_t>(node)];
                const int32_t pe = pod.prerequisite_offsets[static_cast<size_t>(node + 1)];
                for (int32_t e = pe - 1; e >= pb; --e) {
                    const int32_t prereq = pod.prerequisites[static_cast<size_t>(e)];
                    if (prereq >= 0 && prereq < static_cast<int32_t>(pod.technology_count) &&
                        !view.done(prereq))
                        stack.push_back(prereq);
                }
            }
        }
    }
    if (wants.empty()) {
        for (int32_t tech = 0; tech < static_cast<int32_t>(pod.technology_count); ++tech) {
            if (index.is_milestone[static_cast<size_t>(tech)] != 0 && tech != goal) continue;
            if (!view.available(tech)) continue;
            want(tech, 3, std::max<int64_t>(0, pod.technology_costs[static_cast<size_t>(tech)]) *
                              10000 / affinity(tech));
        }
    }
    std::sort(wants.begin(), wants.end(), [](const Want &l, const Want &r) {
        return std::tie(l.priority, l.effective, l.tech) < std::tie(r.priority, r.effective, r.tech);
    });
    const size_t country_base = static_cast<size_t>(ctx.obs.slot) * COUNTRY_AI_DOMAIN_COUNT;
    std::array<int32_t, COUNTRY_AI_DOMAIN_COUNT> lengths{};
    for (uint32_t d = 0; d < COUNTRY_AI_DOMAIN_COUNT; ++d)
        lengths[d] = state.research_queue_lengths[country_base + d];
    int32_t enqueued = 0;
    for (const Want &w : wants) {
        if (enqueued >= catalog.research_max_enqueue_per_eval) break;
        const int32_t domain = pod.technology_domains[static_cast<size_t>(w.tech)];
        if (domain < 0 || domain >= static_cast<int32_t>(COUNTRY_AI_DOMAIN_COUNT)) continue;
        if (lengths[static_cast<size_t>(domain)] >= static_cast<int32_t>(COUNTRY_AI_QUEUE_SLOTS))
            continue;
        CountryAiCommand &command = push_command(ctx, 6, COUNTRY_AI_MODULE_RESEARCH);
        command.aux = w.tech;
        command.domain = domain;
        command.position = w.priority == 0 ? 0 : -1;
        ++lengths[static_cast<size_t>(domain)];
        view.mark_queued(w.tech);
        ++enqueued;
        CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_RESEARCH,
            COUNTRY_AI_OUTCOME_EMITTED, w.tech,
            w.priority == 0 ? "enqueue_milestone" :
            (w.priority <= 2 ? "enqueue_goal_path" : "enqueue_fallback"));
        decision.value = goal;
        decision.amount = w.effective;
        decision.alt_subject = top;
        decision.alt_score_q16 = top_score;
    }
    // Weights follow the queued cost per domain so no domain starves while
    // another domain idles.
    std::array<int64_t, COUNTRY_AI_DOMAIN_COUNT> demand{};
    int32_t queued_total = 0;
    for (int32_t tech = 0; tech < static_cast<int32_t>(pod.technology_count); ++tech) {
        if (!view.is_queued(tech)) continue;
        const int32_t domain = pod.technology_domains[static_cast<size_t>(tech)];
        if (domain < 0 || domain >= static_cast<int32_t>(COUNTRY_AI_DOMAIN_COUNT)) continue;
        demand[static_cast<size_t>(domain)] += std::max<int64_t>(1,
            pod.technology_costs[static_cast<size_t>(tech)]);
        ++queued_total;
    }
    ctx.obs.queued_techs = queued_total;
    std::array<int32_t, COUNTRY_AI_DOMAIN_COUNT> weights{};
    if (country_ai_normalize_weights(demand, weights)) {
        int32_t diff = 0;
        for (uint32_t d = 0; d < COUNTRY_AI_DOMAIN_COUNT; ++d)
            diff += std::abs(weights[d] - state.research_weights_bp[country_base + d]);
        if (diff >= catalog.research_weight_threshold_bp) {
            CountryAiCommand &command = push_command(ctx, 5, COUNTRY_AI_MODULE_RESEARCH);
            command.weights_bp = weights;
            CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_RESEARCH,
                COUNTRY_AI_OUTCOME_EMITTED, -1, "set_weights");
            decision.value = diff;
            for (uint32_t i = 0; i < 3; ++i) {
                decision.alt_subject[i] = static_cast<int32_t>(i);
                decision.alt_score_q16[i] = weights[i];
            }
            decision.amount = weights[3];
        }
    }
    // Daily budget: a fixed share of discretionary cash spread over a horizon.
    const int64_t cash = ctx.obs.cash;
    const int64_t burn = std::max<int64_t>(0, -ctx.mem.cash_delta_ema);
    const int64_t floor = catalog.reserve_floor_cash +
        clamp64(burn, 0, CASH_EMA_LIMIT) * catalog.reserve_target_days / 4;
    const int64_t discretionary = std::max<int64_t>(0, cash - floor);
    int64_t share = agenda.research_share_bp;
    share = share * (5000 + ctx.personality.risk_bp) / 10000;
    int64_t target = queued_total == 0 ? 0 :
        clamp64(discretionary, 0, CASH_EMA_LIMIT * 100) / 10000 * share /
            std::max(1, catalog.research_budget_horizon_days);
    if (queued_total > 0) target = std::max(target, catalog.research_min_daily_budget);
    if (catalog.research_max_daily_budget > 0)
        target = std::min(target, catalog.research_max_daily_budget);
    const int64_t current = state.research_daily_budgets[static_cast<size_t>(ctx.obs.slot)];
    const uint8_t auto_purchase = state.research_auto_purchase[static_cast<size_t>(ctx.obs.slot)];
    const int32_t want_auto = target > 0 ? 1 : static_cast<int32_t>(auto_purchase);
    const int64_t delta = std::abs(target - current);
    const bool budget_change = (target != current) &&
        (current == 0 || target == 0 ||
         delta * 10000 >= static_cast<int64_t>(catalog.research_budget_change_bp) *
                              std::max<int64_t>(1, current) ||
         want_auto != auto_purchase);
    if (budget_change || (want_auto != auto_purchase)) {
        CountryAiCommand &command = push_command(ctx, 9, COUNTRY_AI_MODULE_RESEARCH);
        command.value = target;
        command.aux = want_auto;
        CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_RESEARCH,
            COUNTRY_AI_OUTCOME_EMITTED, -1, "set_budget");
        decision.amount = target;
        decision.value = want_auto;
    }
}

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

void bfs_rings(const RuntimeCountryPodSnapshot &state, int32_t slot,
               const std::vector<int32_t> &neighbors, int32_t radius,
               std::vector<int32_t> &dist, std::vector<int32_t> &cells) {
    const int32_t cell_count = static_cast<int32_t>(state.cell_country_slot.size());
    dist.assign(static_cast<size_t>(cell_count), -1);
    cells.clear();
    const int32_t begin = state.territory_offsets[static_cast<size_t>(slot)];
    const int32_t end = state.territory_offsets[static_cast<size_t>(slot) + 1u];
    for (int32_t i = begin; i < end; ++i) {
        const int32_t cell = state.territory_cells[static_cast<size_t>(i)];
        if (cell < 0 || cell >= cell_count || dist[static_cast<size_t>(cell)] >= 0) continue;
        dist[static_cast<size_t>(cell)] = 0;
        cells.push_back(cell);
    }
    size_t head = 0;
    while (head < cells.size()) {
        const int32_t cell = cells[head++];
        const int32_t d = dist[static_cast<size_t>(cell)];
        if (d >= radius) continue;
        for (int32_t k = 0; k < 6; ++k) {
            const size_t ni = static_cast<size_t>(cell) * 6u + static_cast<size_t>(k);
            if (ni >= neighbors.size()) break;
            const int32_t n = neighbors[ni];
            if (n < 0 || n >= cell_count || dist[static_cast<size_t>(n)] >= 0) continue;
            dist[static_cast<size_t>(n)] = d + 1;
            cells.push_back(n);
        }
    }
}

void think_colonize(ThinkContext &ctx) {
    const CountryAiCatalog &catalog = ctx.catalog;
    const RuntimeCountryPodSnapshot &state = *ctx.input.state;
    const CountryAiAgendaDef &agenda = catalog.agendas[ctx.mem.agenda];
    ctx.mem.last_colonize_day = ctx.input.day;
    const CountryAiEconomyRow *row = ctx.obs.economy;
    if (row == nullptr || ctx.input.neighbors == nullptr) {
        push_decision(ctx, COUNTRY_AI_MODULE_COLONIZE, COUNTRY_AI_OUTCOME_SKIPPED, -1,
                      row == nullptr ? "economy_digest_missing" : "topology_missing");
        return;
    }
    if (row->ai_colonization_failures > ctx.mem.colonize_failures_seen) {
        ctx.mem.colonize_cooldown_until = ctx.input.day + catalog.colonize_failure_cooldown_days;
    }
    ctx.mem.colonize_failures_seen = row->ai_colonization_failures;
    ctx.mem.colonize_started_seen = row->ai_colonization_started;
    const int32_t cap = catalog.colonize_max_in_flight + agenda.expansion_slots;
    const char *skip = nullptr;
    if (cap <= 0) skip = "colonize_disabled";
    else if (ctx.input.day < ctx.mem.colonize_cooldown_until) skip = "colonize_cooldown";
    else if (row->expeditions_active >= cap) skip = "colonize_in_flight_cap";
    else if (ctx.obs.reserve_days < catalog.colonize_min_reserve_days) skip = "colonize_reserve_low";
    else if (ctx.obs.frontier <= 0) skip = "colonize_no_frontier";
    else if (row->family_count <= 0) skip = "colonize_no_family";
    if (skip != nullptr) {
        push_decision(ctx, COUNTRY_AI_MODULE_COLONIZE, COUNTRY_AI_OUTCOME_SKIPPED, -1, skip);
        return;
    }
    const std::vector<int32_t> &neighbors = *ctx.input.neighbors;
    std::vector<int32_t> dist;
    std::vector<int32_t> cells;
    const int32_t radius = std::max(catalog.colonize_vision_radius, catalog.colonize_target_ring);
    bfs_rings(state, ctx.obs.slot, neighbors, radius, dist, cells);
    struct Target { int32_t cell; int64_t score; };
    std::vector<Target> targets;
    for (const int32_t cell : cells) {
        const int32_t d = dist[static_cast<size_t>(cell)];
        if (d <= 0 || d > catalog.colonize_target_ring) continue;
        if (state.cell_country_slot[static_cast<size_t>(cell)] >= 0) continue;
        if (static_cast<size_t>(cell) < state.is_water.size() &&
            state.is_water[static_cast<size_t>(cell)] != 0) continue;
        int32_t own_adjacent = 0;
        int32_t land_adjacent = 0;
        for (int32_t k = 0; k < 6; ++k) {
            const int32_t n = neighbors[static_cast<size_t>(cell) * 6u + static_cast<size_t>(k)];
            if (n < 0) continue;
            if (state.cell_country_slot[static_cast<size_t>(n)] == ctx.obs.slot) ++own_adjacent;
            if (static_cast<size_t>(n) >= state.is_water.size() ||
                state.is_water[static_cast<size_t>(n)] == 0) ++land_adjacent;
        }
        int64_t score = static_cast<int64_t>(own_adjacent) * COUNTRY_AI_Q16 / 6 +
                        static_cast<int64_t>(land_adjacent) * COUNTRY_AI_Q16 / 12;
        if (ctx.input.cell_value_q16 != nullptr &&
            static_cast<size_t>(cell) < ctx.input.cell_value_q16->size())
            score += (*ctx.input.cell_value_q16)[static_cast<size_t>(cell)];
        score = score * 2 / (1 + d);
        score += static_cast<int64_t>(country_ai_mix(catalog.seed, ctx.obs.handle,
            static_cast<uint64_t>(ctx.input.day), static_cast<uint64_t>(cell)) % 2048u);
        targets.push_back({cell, score});
    }
    if (targets.empty()) {
        push_decision(ctx, COUNTRY_AI_MODULE_COLONIZE, COUNTRY_AI_OUTCOME_SKIPPED, -1,
                      "colonize_no_target");
        return;
    }
    std::sort(targets.begin(), targets.end(), [](const Target &l, const Target &r) {
        return l.score != r.score ? l.score > r.score : l.cell < r.cell;
    });
    CountryAiColonizationIntent intent;
    intent.day = ctx.input.day;
    intent.country_handle = ctx.obs.handle;
    intent.target_cell = targets.front().cell;
    intent.population_share_bp = catalog.colonize_population_share_bp;
    intent.min_population = catalog.colonize_min_population;
    intent.sequence = (static_cast<uint64_t>(ctx.input.day) << 12) |
                      static_cast<uint64_t>(ctx.obs.slot & 0xfff);
    for (const int32_t cell : cells)
        if (dist[static_cast<size_t>(cell)] <= catalog.colonize_vision_radius)
            intent.visible_cells.push_back(cell);
    std::sort(intent.visible_cells.begin(), intent.visible_cells.end());
    ctx.out.colonization.push_back(std::move(intent));
    ++ctx.mem.colonize_intents;
    CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_COLONIZE,
        COUNTRY_AI_OUTCOME_EMITTED, targets.front().cell, "colonize_intent");
    decision.score_q16 = static_cast<int32_t>(clamp64(targets.front().score, 0,
        std::numeric_limits<int32_t>::max()));
    for (size_t i = 0; i < 3; ++i) {
        if (i + 1 >= targets.size()) break;
        decision.alt_subject[i] = targets[i + 1].cell;
        decision.alt_score_q16[i] = static_cast<int32_t>(clamp64(targets[i + 1].score, 0,
            std::numeric_limits<int32_t>::max()));
    }
}

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

uint64_t country_ai_catalog_hash(const CountryAiCatalog &c) {
    uint64_t h = FNV_OFFSET;
    const auto mix = [&h](int64_t v) { h = fnv_u64(h, static_cast<uint64_t>(v)); };
    mix(c.schema); mix(static_cast<int64_t>(c.seed));
    mix(c.think_days); mix(c.strategy_days); mix(c.research_days); mix(c.tax_days);
    mix(c.colonize_days); mix(c.agenda_min_days); mix(c.agenda_inertia_bp);
    mix(c.decision_noise_bp); mix(c.research_budget_horizon_days);
    mix(c.research_min_daily_budget); mix(c.research_max_daily_budget);
    mix(c.research_weight_threshold_bp); mix(c.research_max_enqueue_per_eval);
    mix(c.research_budget_change_bp); mix(c.research_frontier_visit_limit);
    mix(c.tax_kind_mask); mix(c.tax_step_bp); mix(c.tax_max_step_bp);
    mix(c.tax_deadband_q16); mix(c.satisfaction_floor_q16); mix(c.reserve_target_days);
    mix(c.reserve_floor_cash); mix(c.colonize_max_in_flight);
    mix(c.colonize_population_share_bp); mix(c.colonize_min_population);
    mix(c.colonize_vision_radius); mix(c.colonize_target_ring);
    mix(c.colonize_failure_cooldown_days); mix(c.colonize_min_reserve_days);
    for (const CountryAiAgendaDef &a : c.agendas) {
        mix(a.consideration_count);
        for (uint32_t i = 0; i < a.consideration_count; ++i) {
            const CountryAiCurve &curve = a.considerations[i];
            mix(curve.input); mix(curve.kind); mix(curve.x0); mix(curve.x1);
            mix(curve.y0_q16); mix(curve.y1_q16);
        }
        mix(a.research_share_bp); mix(a.expansion_slots); mix(a.tax_bias_bp);
        mix(a.satisfaction_floor_shift_q16); mix(a.era_focus);
    }
    mix(static_cast<int64_t>(c.personalities.size()));
    for (const CountryAiPersonality &p : c.personalities) {
        mix(static_cast<int64_t>(p.id_hash)); mix(p.weight); mix(p.risk_bp);
        for (int32_t v : p.agenda_bias_bp) mix(v);
        for (int32_t v : p.domain_affinity_bp) mix(v);
        for (int32_t v : p.tax_min_bp) mix(v);
        for (int32_t v : p.tax_max_bp) mix(v);
        for (int32_t v : p.tax_initial_bp) mix(v);
        for (int32_t v : p.family_pref) mix(v);
    }
    return h & 0x7fffffffffffffffull;
}

bool country_ai_validate_catalog(const CountryAiCatalog &c, std::string &error) {
    const auto fail = [&error](const char *code) { error = code; return false; };
    if (c.schema != COUNTRY_AI_SCHEMA) return fail("country_ai_schema_unsupported");
    if (c.think_days < 1 || c.strategy_days < 1 || c.research_days < 1 ||
        c.tax_days < 1 || c.colonize_days < 1)
        return fail("country_ai_cadence_invalid");
    if (c.personalities.empty() || c.personalities.size() > COUNTRY_AI_MAX_PERSONALITIES)
        return fail("country_ai_personalities_invalid");
    for (const CountryAiPersonality &p : c.personalities) {
        if (p.weight <= 0) return fail("country_ai_personality_weight_invalid");
        for (uint32_t k = 0; k < COUNTRY_AI_TAX_KIND_COUNT; ++k) {
            if (p.tax_min_bp[k] < -100000 || p.tax_max_bp[k] > 10000 ||
                p.tax_min_bp[k] > p.tax_max_bp[k])
                return fail("country_ai_tax_bounds_invalid");
        }
        for (int32_t v : p.domain_affinity_bp)
            if (v <= 0) return fail("country_ai_domain_affinity_invalid");
    }
    for (const CountryAiAgendaDef &a : c.agendas) {
        if (a.consideration_count > COUNTRY_AI_MAX_CONSIDERATIONS)
            return fail("country_ai_agenda_considerations_invalid");
        for (uint32_t i = 0; i < a.consideration_count; ++i) {
            if (a.considerations[i].input >= COUNTRY_AI_INPUT_COUNT ||
                a.considerations[i].kind >= COUNTRY_AI_CURVE_COUNT)
                return fail("country_ai_curve_invalid");
        }
        if (a.research_share_bp < 0 || a.research_share_bp > 10000)
            return fail("country_ai_research_share_invalid");
    }
    if (c.tax_step_bp <= 0 || c.tax_max_step_bp < c.tax_step_bp)
        return fail("country_ai_tax_step_invalid");
    if (c.research_max_enqueue_per_eval < 0 || c.research_max_enqueue_per_eval > 8)
        return fail("country_ai_research_enqueue_invalid");
    if (c.colonize_population_share_bp < 0 || c.colonize_population_share_bp > 10000)
        return fail("country_ai_colonize_share_invalid");
    return true;
}

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
        row.research_budget = state.research_daily_budgets[slot];
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
            m.commands_rejected, m.colonize_intents};
        for (const uint64_t f : fields) h = fnv_u64(h, f);
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

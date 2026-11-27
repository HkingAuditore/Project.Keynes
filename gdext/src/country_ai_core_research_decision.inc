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
    // Daily budget: a fixed share of discretionary cash spread over a horizon,
    // planned whether or not anything is queued yet (the queue above fills
    // from the same evaluation). Economy procurement turns the share of cash
    // into the epoch's research reservation, so the AI never writes an
    // absolute daily amount.
    const int64_t cash = ctx.obs.cash;
    const int64_t burn = std::max<int64_t>(0, -ctx.mem.cash_delta_ema);
    const int64_t floor = catalog.reserve_floor_cash +
        clamp64(burn, 0, CASH_EMA_LIMIT) * catalog.reserve_target_days / 4;
    const int64_t discretionary = std::max<int64_t>(0, cash - floor);
    int64_t share = agenda.research_share_bp;
    share = share * (5000 + ctx.personality.risk_bp) / 10000;
    int64_t target = clamp64(discretionary, 0, CASH_EMA_LIMIT * 100) / 10000 * share /
        std::max(1, catalog.research_budget_horizon_days);
    const CountryAiEconomyRow *row = ctx.obs.economy;
    if (row == nullptr || row->essentials_q16 < catalog.research_essentials_floor_q16 ||
        row->hungry_share_q16 >= catalog.research_hungry_share_max_q16) {
        target = 0;
    } else {
        const int64_t fiscal =
            clamp64(row->tax_paid, 0, CASH_EMA_LIMIT) / 10000 * catalog.research_tax_share_bp +
            clamp64(row->population, 0, CASH_EMA_LIMIT) * catalog.research_per_capita_budget;
        target = std::min(target, fiscal);
        const int64_t full = catalog.research_load_full_q16;
        const int64_t zero = catalog.research_load_zero_q16;
        const int64_t load = row->carrying_load_q16;
        if (load >= zero) target = 0;
        else if (load > full)
            target = clamp64(target, 0, CASH_EMA_LIMIT) * (zero - load) / (zero - full);
    }
    // The food and load gates only lower the share to its floor: a starter
    // colony sits above the load cut-off for months and would otherwise never
    // research at all.
    const int64_t cash_unit = std::max<int64_t>(1, cash / 10000);
    const int32_t share_bp = static_cast<int32_t>(clamp64(
        (clamp64(target, 0, CASH_EMA_LIMIT * 100) + cash_unit - 1) / cash_unit,
        std::max(0, catalog.research_min_share_bp),
        std::max(catalog.research_min_share_bp, catalog.research_max_share_bp)));
    const int32_t previous = ctx.mem.research_share_bp;
    const int64_t delta = std::abs(static_cast<int64_t>(share_bp) - previous);
    if (previous < 0 || (share_bp != previous &&
            (previous == 0 || share_bp == 0 ||
             delta * 10000 >= static_cast<int64_t>(catalog.research_budget_change_bp) *
                                  std::max<int64_t>(1, previous)))) {
        CountryAiProcurementIntent intent;
        intent.day = ctx.input.day;
        intent.country_handle = ctx.obs.handle;
        intent.research_share_bp = share_bp;
        intent.sequence = (static_cast<uint64_t>(ctx.input.day) << 12) |
                          static_cast<uint64_t>(ctx.obs.slot & 0xfff);
        ctx.out.procurement.push_back(intent);
        ctx.mem.research_share_bp = share_bp;
        CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_RESEARCH,
            COUNTRY_AI_OUTCOME_EMITTED, -1, "set_research_share");
        decision.amount = target;
        decision.value = share_bp;
    }
    const uint8_t auto_purchase = state.research_auto_purchase[static_cast<size_t>(ctx.obs.slot)];
    if (auto_purchase == 0 && share_bp > 0) {
        CountryAiCommand &command = push_command(ctx, 9, COUNTRY_AI_MODULE_RESEARCH);
        command.aux = 1;
        CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_RESEARCH,
            COUNTRY_AI_OUTCOME_EMITTED, -1, "enable_auto_purchase");
        decision.value = 1;
    }
}

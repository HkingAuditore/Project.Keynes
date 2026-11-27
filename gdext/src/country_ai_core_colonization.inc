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
    if (row->ai_colonization_started > ctx.mem.colonize_started_seen)
        ctx.mem.colonize_last_target = -1;
    if (row->ai_colonization_failures > ctx.mem.colonize_failures_seen) {
        ctx.mem.colonize_cooldown_until = ctx.input.day + catalog.colonize_failure_cooldown_days;
        if (ctx.mem.colonize_last_target >= 0) {
            const uint32_t at = ctx.mem.colonize_bad_cursor % COUNTRY_AI_COLONIZE_BAD_TARGETS;
            ctx.mem.colonize_bad_targets[at] = ctx.mem.colonize_last_target;
            ctx.mem.colonize_bad_cursor = at + 1;
            ctx.mem.colonize_last_target = -1;
        }
    }
    ctx.mem.colonize_failures_seen = row->ai_colonization_failures;
    ctx.mem.colonize_started_seen = row->ai_colonization_started;
    const int32_t cap = catalog.colonize_max_in_flight + agenda.expansion_slots;
    const char *skip = nullptr;
    if (cap <= 0) skip = "colonize_disabled";
    else if (ctx.input.day < ctx.mem.colonize_cooldown_until) skip = "colonize_cooldown";
    else if (row->expeditions_active >= cap) skip = "colonize_in_flight_cap";
    else if (ctx.obs.reserve_days < catalog.colonize_min_reserve_days) skip = "colonize_reserve_low";
    else if (row->family_count <= 0) skip = "colonize_no_family";
    else if (row->population < catalog.colonize_min_country_population ||
             row->population < catalog.colonize_min_population_per_cell *
                 std::max<int64_t>(1, ctx.obs.territory))
        skip = "colonize_population_low";
    else if (row->essentials_q16 < catalog.colonize_essentials_floor_q16)
        skip = "colonize_essentials_low";
    else if (row->hungry_share_q16 > catalog.colonize_hungry_share_max_q16)
        skip = "colonize_hungry";
    if (skip != nullptr) {
        push_decision(ctx, COUNTRY_AI_MODULE_COLONIZE, COUNTRY_AI_OUTCOME_SKIPPED, -1, skip);
        return;
    }
    const std::vector<int32_t> &neighbors = *ctx.input.neighbors;
    std::vector<int32_t> dist;
    std::vector<int32_t> cells;
    const int32_t radius = std::max(catalog.colonize_vision_radius, catalog.colonize_target_ring);
    bfs_rings(state, ctx.obs.slot, neighbors, radius, dist, cells);
    const auto bad_target = [&](int32_t cell) {
        return std::find(std::begin(ctx.mem.colonize_bad_targets),
                         std::end(ctx.mem.colonize_bad_targets), cell) !=
               std::end(ctx.mem.colonize_bad_targets);
    };
    const auto cell_people = [&](int32_t cell) -> int64_t {
        if (ctx.input.economy == nullptr || cell < 0 ||
            static_cast<size_t>(cell) >= ctx.input.economy->cell_population.size())
            return 0;
        return std::max<int64_t>(0, ctx.input.economy->cell_population[
            static_cast<size_t>(cell)]);
    };
    struct Target { int32_t cell; int64_t score; };
    std::vector<Target> reinforce;
    std::vector<Target> expand;
    // Reinforce first: own cells below the founding floor never become cities
    // without follow-up relocate expeditions (Economy kind=relocate).
    const int64_t reinforce_below = std::max<int64_t>(3, catalog.colonize_min_population);
    const int32_t terr_begin = state.territory_offsets[static_cast<size_t>(ctx.obs.slot)];
    const int32_t terr_end = state.territory_offsets[static_cast<size_t>(ctx.obs.slot) + 1u];
    // Need a second owned cell to pull settlers from; otherwise relocate quotes
    // have no legal source != target.
    if (terr_end - terr_begin >= 2) {
        for (int32_t i = terr_begin; i < terr_end; ++i) {
            const int32_t cell = state.territory_cells[static_cast<size_t>(i)];
            if (cell < 0 || bad_target(cell)) continue;
            if (static_cast<size_t>(cell) < state.is_water.size() &&
                state.is_water[static_cast<size_t>(cell)] != 0) continue;
            const int64_t people = cell_people(cell);
            if (people >= reinforce_below) continue;
            const int64_t gap = reinforce_below - people;
            int64_t score = gap * COUNTRY_AI_Q16 / reinforce_below;
            if (ctx.input.cell_value_q16 != nullptr &&
                static_cast<size_t>(cell) < ctx.input.cell_value_q16->size()) {
                const int64_t value = (*ctx.input.cell_value_q16)[static_cast<size_t>(cell)];
                if (value > 0)
                    score += value * catalog.colonize_cell_value_weight_bp / 10000;
            }
            int32_t own_adjacent = 0;
            for (int32_t k = 0; k < 6; ++k) {
                const int32_t n = neighbors[static_cast<size_t>(cell) * 6u +
                    static_cast<size_t>(k)];
                if (n < 0) continue;
                if (state.cell_country_slot[static_cast<size_t>(n)] == ctx.obs.slot)
                    ++own_adjacent;
            }
            score += static_cast<int64_t>(own_adjacent) * COUNTRY_AI_Q16 / 6;
            // Prefer emptiest first; tiny noise breaks ties deterministically.
            score = score * 2 + static_cast<int64_t>(country_ai_mix(catalog.seed,
                ctx.obs.handle, static_cast<uint64_t>(ctx.input.day),
                static_cast<uint64_t>(cell) ^ 0x52454e46ull) % 1024u);
            reinforce.push_back({cell, score});
        }
    }
    for (const int32_t cell : cells) {
        const int32_t d = dist[static_cast<size_t>(cell)];
        if (d <= 0 || d > catalog.colonize_target_ring) continue;
        if (state.cell_country_slot[static_cast<size_t>(cell)] >= 0) continue;
        if (static_cast<size_t>(cell) < state.is_water.size() &&
            state.is_water[static_cast<size_t>(cell)] != 0) continue;
        if (bad_target(cell)) continue;
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
            static_cast<size_t>(cell) < ctx.input.cell_value_q16->size()) {
            const int64_t value = (*ctx.input.cell_value_q16)[static_cast<size_t>(cell)];
            if (value < catalog.colonize_min_cell_value_q16) continue;
            score += value * catalog.colonize_cell_value_weight_bp / 10000;
        }
        score = score * 2 / (1 + d);
        score += static_cast<int64_t>(country_ai_mix(catalog.seed, ctx.obs.handle,
            static_cast<uint64_t>(ctx.input.day), static_cast<uint64_t>(cell)) % 2048u);
        expand.push_back({cell, score});
    }
    const bool prefer_reinforce = !reinforce.empty();
    std::vector<Target> &targets = prefer_reinforce ? reinforce : expand;
    if (targets.empty()) {
        push_decision(ctx, COUNTRY_AI_MODULE_COLONIZE, COUNTRY_AI_OUTCOME_SKIPPED, -1,
                      ctx.obs.frontier <= 0 ? "colonize_no_frontier" : "colonize_no_target");
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
    // Own territory is dist 0 in the BFS; keep it visible so relocate quotes
    // can pull from any homeland branch, not only the frontier ring.
    for (const int32_t cell : cells)
        if (dist[static_cast<size_t>(cell)] <= catalog.colonize_vision_radius)
            intent.visible_cells.push_back(cell);
    std::sort(intent.visible_cells.begin(), intent.visible_cells.end());
    ctx.out.colonization.push_back(std::move(intent));
    ++ctx.mem.colonize_intents;
    ctx.mem.colonize_last_target = targets.front().cell;
    CountryAiDecision &decision = push_decision(ctx, COUNTRY_AI_MODULE_COLONIZE,
        COUNTRY_AI_OUTCOME_EMITTED, targets.front().cell,
        prefer_reinforce ? "reinforce_intent" : "colonize_intent");
    decision.score_q16 = static_cast<int32_t>(clamp64(targets.front().score, 0,
        std::numeric_limits<int32_t>::max()));
    for (size_t i = 0; i < 3; ++i) {
        if (i + 1 >= targets.size()) break;
        decision.alt_subject[i] = targets[i + 1].cell;
        decision.alt_score_q16[i] = static_cast<int32_t>(clamp64(targets[i + 1].score, 0,
            std::numeric_limits<int32_t>::max()));
    }
}

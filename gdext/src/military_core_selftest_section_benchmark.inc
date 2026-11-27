// ================================================================= bench
bool MilitaryCore::bench(int32_t cells, int32_t armies, int32_t engagements, int32_t days, double &avg_ms,
                         double &p95_ms, double &max_ms, std::string &report) {
    avg_ms = p95_ms = max_ms = 0.0;
    report.clear();
    if (cells < 64 || armies < 1 || days < 1) {
        report = "bench_bad_config";
        return false;
    }
    armies = std::min(armies, MILITARY_MAX_ARMIES);
    int32_t w = std::max<int32_t>(16, (int32_t)std::lround(std::sqrt((double)cells * 1.5)));
    w &= ~1;
    int32_t h = std::max<int32_t>(4, cells / w);
    const MilitaryTerrainInput t = make_hex_terrain(w, h);
    const int32_t n = t.cell_count;
    constexpr int32_t kCountries = 8;
    MilitaryCore core;
    std::string error;
    if (!core.configure(make_catalog(), 99, error) || !core.set_terrain(t, error)) {
        report = error;
        return false;
    }
    MilitaryWorldDigest d;
    d.country_capacity = kCountries;
    d.cell_owner_slot.assign((size_t)n, -1);
    for (int32_t c = 0; c < n; ++c) d.cell_owner_slot[(size_t)c] = ((c % w) * kCountries) / w;
    for (int32_t s = 0; s < kCountries; ++s) {
        d.country_handle.push_back(handle_for(s));
        d.country_cash.push_back(1000000000000ll);
        d.country_era.push_back(2);
        d.country_annual_revenue.push_back(0);
        d.country_capital_cell.push_back(-1);
        d.country_soldier_living_cost.push_back(10000);
        core.ensure_country_slot(handle_for(s));
    }
    d.cell_population.assign((size_t)n, 1000);
    d.cell_unemployed.assign((size_t)n, 100);
    d.cell_soldiers.assign((size_t)n, 0);
    d.cell_has_merchant.assign((size_t)n, 0);
    for (int32_t c = 0; c < n; c += 64) {
        d.cell_has_merchant[(size_t)c] = 1;
        d.market_cell.push_back(c);
        d.market_good.push_back(0);
        d.market_sellable.push_back(100000000);
        d.market_price.push_back(10000);
    }
    d.unlock_words = 1;
    d.country_unlock_bits.assign(kCountries, 1ull);
    d.day = 0;
    core._last_day = 0;
    core._last_digest = d;
    // Wars between stripe pairs (0,1) (2,3) ...
    for (int32_t p = 0; p < kCountries / 2; ++p) {
        MilitaryWar war;
        war.id = p + 1;
        war.attacker_slot = 2 * p;
        war.defender_slot = 2 * p + 1;
        war.attacker_handle = handle_for(2 * p);
        war.defender_handle = handle_for(2 * p + 1);
        war.start_day = 0;
        war.active = 1;
        core._wars.push_back(war);
    }
    const int32_t stripe = w / kCountries;
    std::vector<uint8_t> used((size_t)n, 0);
    uint64_t r = 0x1234567ull;
    auto next_rand = [&r]() { r = splitmix_final(r + 0x9e3779b97f4a7c15ull); return r; };
    auto pick_cell = [&](int32_t country, int32_t margin) -> int32_t {
        for (int32_t tries = 0; tries < 1000; ++tries) {
            const int32_t col = country * stripe + margin + (int32_t)(next_rand() % (uint64_t)std::max(1, stripe - 2 * margin));
            const int32_t row = 1 + (int32_t)(next_rand() % (uint64_t)std::max(1, h - 2));
            const int32_t c = row * w + col;
            if (c >= 0 && c < n && !used[(size_t)c] && d.cell_owner_slot[(size_t)c] == country) return c;
        }
        return -1;
    };
    auto spawn = [&](int32_t owner, int32_t cell, int64_t heads) -> int32_t {
        const int32_t a = core.create_army(owner, cell);
        if (a < 0) return -1;
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_ARMY, a, owner, 0, 256);
        core._lots.count[(size_t)lot] = heads;
        core.refresh_army_cache(a);
        used[(size_t)cell] = 1;
        return a;
    };
    int32_t attackers = std::min<int32_t>(armies / 2, (engagements + 5) / 6);
    if (engagements <= 0) attackers = 0;
    int32_t made_eng = 0, spawned = 0;
    std::vector<int32_t> att_cells;
    for (int32_t i = 0; i < attackers; ++i) {
        const int32_t pair = i % (kCountries / 2);
        const int32_t att = 2 * pair, def = att + 1;
        const int32_t cell = pick_cell(def, 2);
        if (cell < 0) break;
        // Keep the invader's ring free so its six edges stay distinct.
        bool clash = false;
        for (int32_t k = 0; k < 6; ++k) {
            const int32_t nb = t.neighbors[(size_t)cell * 6 + (size_t)k];
            if (nb < 0 || used[(size_t)nb] || d.cell_owner_slot[(size_t)nb] != def) clash = true;
        }
        if (clash) { --i; if (++spawned > 100000) break; continue; }
        const int32_t a = spawn(att, cell, 1000);
        if (a < 0) break;
        core.set_controller(cell, att);
        for (int32_t k = 0; k < 6; ++k) used[(size_t)t.neighbors[(size_t)cell * 6 + (size_t)k]] = 1;
        att_cells.push_back(cell);
        for (int32_t k = 0; k < 6 && made_eng < engagements; ++k) {
            core.open_engagement(cell, t.neighbors[(size_t)cell * 6 + (size_t)k], a, def);
            ++made_eng;
        }
    }
    attackers = (int32_t)att_cells.size();
    // Defenders on engaged far cells, then movers in their own territory.
    int32_t remaining = armies - attackers;
    int32_t defenders = 0;
    for (size_t i = 0; i < att_cells.size() && defenders < remaining / 2; ++i) {
        const int32_t far = t.neighbors[att_cells[i] * 6 + (size_t)(i % 6)];
        const int32_t a = core.create_army(d.cell_owner_slot[(size_t)far], far);
        if (a < 0) break;
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_ARMY, a, d.cell_owner_slot[(size_t)far], 1, 256);
        core._lots.count[(size_t)lot] = 800;
        core.refresh_army_cache(a);
        ++defenders;
    }
    int32_t movers = 0;
    std::vector<int32_t> mover_slot, mover_target;
    for (int32_t i = defenders + attackers; i < armies; ++i) {
        const int32_t owner = i % kCountries;
        const int32_t cell = pick_cell(owner, 1);
        if (cell < 0) break;
        const int32_t a = spawn(owner, cell, 500);
        if (a < 0) break;
        const int32_t row = cell / w;
        const int32_t trow = row + (row < h / 2 ? h / 3 : -h / 3);
        mover_slot.push_back(a);
        mover_target.push_back(std::max(0, std::min(h - 1, trow)) * w + (cell % w));
        ++movers;
    }
    // Paths: per-country daily budget (32) is spent in setup "days".
    int32_t pathed = 0;
    for (int32_t round = 0; round < 64 && pathed < movers; ++round) {
        for (int32_t &v : core._path_daily_requests) v = 0;
        for (int32_t i = 0; i < movers; ++i) {
            const size_t s = (size_t)mover_slot[(size_t)i];
            if (core._armies.path_len[s] > 0) continue;
            std::vector<int32_t> path;
            if (core.find_path(mover_slot[(size_t)i], mover_target[(size_t)i], d, path) && !path.empty()) {
                core.assign_path(mover_slot[(size_t)i], path);
                ++pathed;
            }
        }
    }
    std::vector<double> samples;
    std::vector<MilitaryIntent> intents;
    std::vector<MilitaryIntentReceipt> receipts;
    int64_t astar = 0, convoy_hops = 0, front = 0, intents_total = 0, threat = 0;
    int32_t max_eng = 0, max_moving = 0, captured = 0, battles = 0;
    constexpr size_t work_count = 29;
    int64_t work_total[work_count] = {}, work_first[work_count] = {};
    double stage_sum[MILITARY_STAGE_COUNT] = {}, stage_max[MILITARY_STAGE_COUNT] = {};
    const auto wall0 = std::chrono::steady_clock::now();
    for (int32_t day = 1; day <= days; ++day) {
        d.day = day;
        intents.clear();
        if (!core.step_day(day, d, receipts, intents, error)) {
            report = "bench_step_failed:" + error;
            return false;
        }
        const MilitaryReport &rep = core.report();
        const int64_t work[] = {
            rep.supply_ring_requests, rep.supply_ring_cache_hits,
            rep.supply_ring_centers_built, rep.supply_ring_cells_visited,
            rep.payroll_lots_visited, rep.payroll_holders_visited, rep.war_cells_visited,
            rep.engagement_index_slots_visited, rep.engagement_members_cleared,
            rep.front_position_lookups, rep.front_position_rows, rep.front_removal_fallback_rows,
            rep.garrison_queries, rep.garrison_lots_visited, rep.garrison_scan_fallbacks,
            rep.event_evictions, rep.event_index_rows_visited,
            rep.market_index_builds, rep.market_index_reuses, rep.market_index_cells,
            rep.procurement_garrison_links_visited, rep.procurement_garrison_heads_visited,
            rep.battle_plan_value_queries, rep.battle_plan_value_builds,
            rep.battle_plan_fort_queries, rep.battle_plan_fort_builds,
            rep.procurement_inflight_rows, rep.procurement_inflight_keys,
            rep.procurement_inflight_sort_fallbacks,
        };
        static_assert(sizeof(work) / sizeof(work[0]) == work_count);
        for (size_t i = 0; i < work_count; ++i) {
            work_total[i] += work[i];
            if (day == 1) work_first[i] = work[i];
        }
        samples.push_back(rep.day_ms);
        astar += rep.astar_expansions;
        convoy_hops += rep.convoy_hops;
        front += rep.front_edges_touched;
        threat += rep.threat_field_cells;
        intents_total += (int64_t)intents.size();
        max_eng = std::max(max_eng, rep.engagements_active);
        max_moving = std::max(max_moving, rep.armies_moving);
        captured += rep.cells_captured;
        const double *sm = military_stage_ms();
        for (int32_t k = 0; k < MILITARY_STAGE_COUNT; ++k) {
            stage_sum[k] += sm[k];
            stage_max[k] = std::max(stage_max[k], sm[k]);
        }
    }
    const double wall = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - wall0).count();
    const uint64_t timed_hash = core.state_hash();
    // Stage profile from the timed days themselves (step_day laps).
    std::string profile = " | stages avg/max(ms):";
    {
        int32_t idx[MILITARY_STAGE_COUNT];
        for (int32_t i = 0; i < MILITARY_STAGE_COUNT; ++i) idx[i] = i;
        std::sort(idx, idx + MILITARY_STAGE_COUNT, [&](int32_t a, int32_t b) { return stage_sum[a] > stage_sum[b]; });
        char sb[96];
        for (int32_t i = 0; i < MILITARY_STAGE_COUNT; ++i) {
            std::snprintf(sb, sizeof(sb), " %s=%.3f/%.3f", military_stage_name(idx[i]), stage_sum[idx[i]] / days,
                          stage_max[idx[i]]);
            profile += sb;
        }
    }    battles = (int32_t)core.battle_log().size();
    std::vector<double> sorted = samples;
    std::sort(sorted.begin(), sorted.end());
    double sum = 0.0;
    for (double v : samples) sum += v;
    avg_ms = sum / (double)samples.size();
    max_ms = sorted.back();
    size_t p95 = (size_t)std::ceil(0.95 * (double)sorted.size());
    p95 = p95 == 0 ? 0 : p95 - 1;
    p95_ms = sorted[std::min(p95, sorted.size() - 1)];
    // The first day includes cold derived-index work. Keep it separate from
    // warmed daily cost without changing the existing acceptance percentile.
    {
        std::vector<double> warm(samples.begin() + 1, samples.end());
        std::sort(warm.begin(), warm.end());
        double warm_sum = 0.0;
        for (double value : warm) warm_sum += value;
        size_t warm_p95 = warm.empty() ? 0 : (size_t)std::ceil(0.95 * (double)warm.size()) - 1;
        char cold[160];
        std::snprintf(cold, sizeof(cold), " | first_day=%.3fms warm_avg=%.3fms warm_p95=%.3fms warm_max=%.3fms",
                      samples.front(), warm.empty() ? 0.0 : warm_sum / warm.size(),
                      warm.empty() ? 0.0 : warm[warm_p95], warm.empty() ? 0.0 : warm.back());
        profile += cold;
    }
    char buf[640];
    std::snprintf(buf, sizeof(buf),
                  "cells=%d (%dx%d) armies=%d (att=%d def=%d movers=%d pathed=%d) engagements=%d days=%d | "
                  "avg=%.3fms p95=%.3fms max=%.3fms wall=%.1fms | max_engaged=%d max_moving=%d astar=%lld "
                  "threat_cells/day=%lld convoy_hops=%lld front_touched=%lld captured=%d intents=%lld "
                  "battle_log=%d reconcile=%lld",
                  n, w, h, attackers + defenders + movers, attackers, defenders, movers, pathed, made_eng, days, avg_ms,
                  p95_ms, max_ms, wall, max_eng, max_moving, (long long)astar, (long long)(threat / days),
                  (long long)convoy_hops, (long long)front, captured, (long long)intents_total, battles,
                  (long long)core.report().reconcile_delta);
    report = buf + profile;
    {
        static const char *names[] = {
            "ring_requests", "ring_hits", "ring_centers", "ring_cells",
            "payroll_lots", "payroll_holders", "war_cells", "engagement_index_slots",
            "engagement_members",
            "front_lookups", "front_position_rows", "front_fallback_rows",
            "garrison_queries", "garrison_lots", "garrison_fallbacks",
            "event_evictions", "event_index_rows",
            "market_builds", "market_reuses", "market_cells", "garrison_link_candidates",
            "garrison_head_candidates",
            "battle_value_queries", "battle_value_builds", "battle_fort_queries", "battle_fort_builds",
            "inflight_rows", "inflight_keys", "inflight_sort_fallbacks",
        };
        report += " | work total/first:";
        static_assert(sizeof(names) / sizeof(names[0]) == work_count);
        for (size_t i = 0; i < work_count; ++i)
            report += " " + std::string(names[i]) + "=" + std::to_string(work_total[i]) +
                      "/" + std::to_string(work_first[i]);
    }
    {
        char hb[96];
        std::snprintf(hb, sizeof(hb), " | hash_timed=%016llx hash_end=%016llx", (unsigned long long)timed_hash,
                      (unsigned long long)core.state_hash());
        report += hb;
    }
    return true;
}

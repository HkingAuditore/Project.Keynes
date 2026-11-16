// Included once by military_core_selftest.cpp after fixture definitions.
std::vector<int32_t> reference_supply_ring(const MilitaryTerrainInput &terrain, int32_t center,
                                          std::vector<uint8_t> &distance) {
    std::vector<int32_t> visited((size_t)terrain.cell_count, -1);
    std::vector<int32_t> cells{center};
    distance.assign(1, 0);
    visited[(size_t)center] = 0;
    for (size_t at = 0; at < cells.size(); ++at) {
        const int32_t cell = cells[at];
        if (distance[at] >= MILITARY_SUPPLY_RADIUS) continue;
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t next = terrain.neighbors[(size_t)cell * 6 + (size_t)direction];
            if (next < 0 || visited[(size_t)next] >= 0) continue;
            visited[(size_t)next] = (int32_t)distance[at] + 1;
            cells.push_back(next);
            distance.push_back((uint8_t)visited[(size_t)next]);
        }
    }
    return cells;
}

bool test_performance_supply(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 20261114), "supply index fixture");
    auto &core = sim.core;
    auto &digest = sim.dg;
    std::fill(digest.cell_owner_slot.begin(), digest.cell_owner_slot.end(), 0);
    const int32_t center = cell_at(8, 10);
    ST_CHECK(!military_supply_connected(core, digest, 0, center) &&
                 core.report().supply_ring_centers_built == 0,
             "cold supply probe does not prepare rings");
    {
        MilitaryCore::MarketDayScope day(core);
        day.ensure(digest);
        ST_CHECK(military_supply_rings_ready(core) && core._ring_cells.empty(),
                 "first logistics request prepares metadata without whole-map BFS");
        // Deliberately non-monotonic center order; neighboring offsets are not row ends.
        for (int32_t cell : {center, 0, t.cell_count - 1, center - 7}) {
            std::vector<uint8_t> expected_distance;
            const auto expected = reference_supply_ring(t, cell, expected_distance);
            int32_t begin = 0, end = 0;
            ST_CHECK(military_supply_ring(core, cell, begin, end), "requested supply row exists");
            ST_CHECK(std::vector<int32_t>(core._ring_cells.begin() + begin, core._ring_cells.begin() + end) == expected &&
                         std::vector<uint8_t>(core._ring_dist.begin() + begin, core._ring_dist.begin() + end) == expected_distance,
                     "supply BFS order and distance equal eager reference");
        }
        const int64_t visits = core.report().supply_ring_cells_visited;
        int32_t begin = 0, end = 0;
        ST_CHECK(military_supply_ring(core, center, begin, end) &&
                     core.report().supply_ring_centers_built == 4 &&
                     core.report().supply_ring_cache_hits == 1 &&
                     core.report().supply_ring_cells_visited == visits,
                 "repeated center performs no BFS work");
        ST_CHECK(end - begin == 37, "interior radius-three row retains all 37 cells");
    }
    // With no current market CSR, the historical probe tests owned/controlled
    // cells. A previously unseen center is available after the first prepare.
    ST_CHECK(military_supply_connected(core, digest, 0, center + 3) &&
                 core.report().supply_ring_centers_built == 5,
             "warm supply probes can build any previously unseen center");
    const auto bytes = core.encode();
    ST_CHECK(core.restore(bytes.data(), bytes.size(), sim.error) &&
                 military_supply_rings_ready(core),
             "warm restore retains terrain-only supply rows");
    MilitaryCore cold;
    ST_CHECK(cold.configure(make_catalog(), 20261114, sim.error) &&
                 cold.set_terrain(t, sim.error) &&
                 cold.restore(bytes.data(), bytes.size(), sim.error) &&
                 !military_supply_rings_ready(cold),
             "cold restore does not make supply available early");
    ST_CHECK(core.set_terrain(t, sim.error) && !military_supply_rings_ready(core),
             "terrain refresh retains existing ring invalidation behavior");
    const auto tiny = make_hex_terrain(2, 2);
    ST_CHECK(core.set_terrain(tiny, sim.error), "supply index different topology");
    military_prepare_supply_rings(core);
    int32_t begin = 0, end = 0;
    std::vector<uint8_t> expected_distance;
    const auto expected = reference_supply_ring(tiny, 3, expected_distance);
    ST_CHECK(military_supply_ring(core, 3, begin, end) &&
                 std::vector<int32_t>(core._ring_cells.begin() + begin, core._ring_cells.begin() + end) == expected,
             "small wrapped topology visits duplicate neighbors once");
    core.reset_state();
    ST_CHECK(!military_supply_rings_ready(core), "reset clears supply index");

    // A market in BFS entry 19 is beyond general procurement's 19-entry cap
    // but inside the full row used by maintenance. Exercise both consumers.
    MilitaryCatalog catalog = make_catalog();
    catalog.state_buildings[0].repair_materials = {{0, 42949672960ll}};
    Sim caps;
    ST_CHECK(caps.init(t, 20261115, catalog), "supply consumer limits fixture");
    std::fill(caps.dg.cell_owner_slot.begin(), caps.dg.cell_owner_slot.end(), 0);
    const auto full_row = reference_supply_ring(t, center, expected_distance);
    const int32_t far_market = full_row[19];
    caps.dg.market_cell = {far_market};
    caps.dg.market_good = {0};
    caps.dg.market_price = {1000};
    caps.dg.market_sellable = {1000000};
    std::fill(caps.dg.cell_has_merchant.begin(), caps.dg.cell_has_merchant.end(), 0);
    caps.dg.cell_has_merchant[(size_t)far_market] = 1;
    caps.dg.day = caps.core._last_day = 1;
    const int32_t lot = caps.core.lot_find_or_create(MILITARY_LOT_GARRISON, center, 0, 0, 256);
    caps.core._lots.count[(size_t)lot] = 100;
    std::vector<MilitaryIntent> intents;
    caps.core.run_procurement(caps.dg, intents);
    bool bought = false;
    for (const auto &intent : intents)
        bought |= intent.kind == MILITARY_INTENT_PROCURE_GOOD && intent.count > 0;
    ST_CHECK(!bought && caps.core.report().unmet_procurement_units > 0,
             "general procurement excludes BFS entries after its first 19");
    caps.core.cell_state(center, true)->barracks_count[0] = 1;
    intents.clear();
    caps.core.run_maintenance(caps.dg, intents);
    bought = false;
    for (const auto &intent : intents)
        bought |= intent.kind == MILITARY_INTENT_PROCURE_GOOD && intent.count > 0 &&
                  intent.cell == far_market;
    ST_CHECK(bought, "maintenance uses the complete radius-three row");
    return true;
}

bool test_performance_engagements(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 20261116), "engagement index fixture");
    auto &core = sim.core;
    const int32_t from = cell_at(8, 10), to = cell_at(9, 10);
    const int32_t attacker = core.create_army(0, from);
    const int32_t defender = core.create_army(1, to);
    const int32_t ally = core.create_army(0, from);
    core.open_engagement(from, to, attacker, 1);
    core.open_engagement(from, to, ally, 1);
    ST_CHECK(core._engagements.size() == 1 &&
                 core._armies.engagement[(size_t)attacker] == 0 &&
                 core._armies.engagement[(size_t)defender] == 0 &&
                 core._armies.engagement[(size_t)ally] == 0,
             "same edge joins existing engagement");
    core.ensure_engagement_members();
    core.open_engagement(from, from + 2, attacker, 2);
    ST_CHECK(core._armies.engagement[(size_t)attacker] == 1,
             "new edge preserves existing attacker reassignment behavior");
    core.index_remove(defender);
    core._armies.cell[(size_t)defender] = to + 10;
    core.index_insert(defender, to + 10);
    core.destroy_army(ally);
    const int32_t reused = core.create_army(2, from + 2);
    ST_CHECK(reused == ally, "destroyed army slot is reused");
    core.set_army_engagement(reused, 1);
    const int64_t visited = core.report().engagement_index_slots_visited;
    core.close_engagement(0);
    ST_CHECK(core._armies.engagement[(size_t)defender] == -1 &&
                 core._armies.engagement[(size_t)attacker] == 1 &&
                 core._armies.engagement[(size_t)reused] == 1 &&
                 core.report().engagement_members_cleared == 1 &&
                 core.report().engagement_index_slots_visited == visited,
             "close touches only remaining members after movement reassignment and slot reuse");
    const auto bytes = core.encode();
    const uint64_t hash = core.state_hash();
    core.close_engagement(1);
    ST_CHECK(core.report().engagement_members_cleared == 3,
             "second close clears exactly its two members");
    ST_CHECK(core.restore(bytes.data(), bytes.size(), sim.error) &&
                 core.state_hash() == hash && core.encode() == bytes &&
                 !core._engagement_members_valid,
             "restore into warm core preserves bytes and invalidates reverse membership");
    core.close_engagement(1);
    ST_CHECK(core._armies.engagement[(size_t)attacker] == -1 &&
                 core._armies.engagement[(size_t)reused] == -1 &&
                 core.report().engagement_members_cleared == 2 &&
                 core.report().engagement_index_slots_visited == (int64_t)core._armies.engagement.size(),
             "first close after restore rebuilds once and clears restored members");
    auto invalid = bytes;
    invalid[0] ^= 1;
    const auto before_failed_restore = core.encode();
    ST_CHECK(!core.restore(invalid.data(), invalid.size(), sim.error) &&
                 core.encode() == before_failed_restore && core._engagement_members_valid,
             "failed restore preserves authoritative state and reverse membership");
    // PKMI preserves inactive payload verbatim. A future engagement index can
    // become valid as the append-only engagement table grows.
    core.invalidate_engagement_members();
    const int32_t inactive = (int32_t)core._armies.engagement.size() - 1;
    core._armies.engagement[(size_t)inactive] = (int32_t)core._engagements.size();
    core.ensure_engagement_members();
    const int32_t future = (int32_t)core._engagements.size();
    MilitaryEngagement added;
    added.active = 1;
    added.cell_a = from;
    added.cell_b = to;
    core._engagements.push_back(added);
    core.close_engagement(future);
    ST_CHECK(core._armies.engagement[(size_t)inactive] == -1,
             "new engagement clears matching previously out-of-range inactive payload");
    core.reset_state();
    ST_CHECK(!core._engagement_members_valid && core._engagement_army_head.empty(),
             "reset discards reverse engagement membership");
    return true;
}


bool test_performance_battle_plan(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 20261121), "battle plan cache fixture");
    auto &core = sim.core;
    const int32_t from = cell_at(8, 10), to = cell_at(9, 10);
    const int32_t attacker = core.create_army(0, from);
    const int32_t defender = core.create_army(1, to);
    const int32_t attacker_lot = core.lot_find_or_create(MILITARY_LOT_ARMY, attacker, 0, 0, 384);
    const int32_t defender_lot = core.lot_find_or_create(MILITARY_LOT_ARMY, defender, 1, 1, 192);
    ST_CHECK(attacker_lot >= 0 && defender_lot >= 0, "battle plan lots exist");
    core._lots.count[(size_t)attacker_lot] = 1000;
    core._lots.count[(size_t)defender_lot] = 900;
    // Raw combat arithmetic intentionally differs from the presentation cache.
    core._lots.condition_q16[(size_t)attacker_lot] = 12345;
    core._lots.condition_q16[(size_t)defender_lot] = 100000;
    core.refresh_army_cache(attacker);
    core.refresh_army_cache(defender);
    sim.dg.day = core._last_day = 3;
    core._last_digest = sim.dg;
    core.open_engagement(from, to, attacker, 1);
    const MilitaryEngagement edge = core._engagements[0];
    core._engagements.assign(4, edge);
    core.invalidate_engagement_members();
    const auto start = core.encode();
    std::vector<MilitaryIntent> intents;
    core.run_engagements(sim.dg, intents);
    ST_CHECK(core.report().battle_plan_value_queries == 12 &&
                 core.report().battle_plan_value_builds == 3 &&
                 core.report().battle_plan_fort_queries == 4 &&
                 core.report().battle_plan_fort_builds == 1,
             "repeated edges reuse each independently requested raw army value");
    const auto expected = core.encode();
    ST_CHECK(core.restore(start.data(), start.size(), sim.error), "battle plan restore original input");
    // A cache retained from the previous invocation would use the old lots.
    core._lots.count[(size_t)attacker_lot] *= 2;
    core._lots.condition_q16[(size_t)defender_lot] = 32768;
    core.refresh_army_cache(attacker);
    core.refresh_army_cache(defender);
    const auto changed = core.encode();
    intents.clear();
    core.run_engagements(sim.dg, intents);
    ST_CHECK(core.report().battle_plan_value_builds == 3 &&
                 core.report().battle_plan_fort_builds == 1 && core.encode() != expected,
             "new invocation recomputes changed lot inputs after restore");
    const auto changed_result = core.encode();
    ST_CHECK(core.restore(changed.data(), changed.size(), sim.error), "battle plan restore changed input");
    core._armies.cached_attack_q16[(size_t)attacker] = 1;
    core._armies.cached_defense_q16[(size_t)defender] = 1;
    intents.clear();
    core.run_engagements(sim.dg, intents);
    // Replay refreshes any casualty-bearing army; compare the actual battle
    // progress and casualty decisions, not presentation-cache storage bytes.
    const auto actual_edges = core._engagements;
    ST_CHECK(core.restore(changed_result.data(), changed_result.size(), sim.error),
             "battle plan restore reference outcome");
    bool same = actual_edges.size() == core._engagements.size();
    for (size_t i = 0; same && i < actual_edges.size(); ++i) {
        const auto &a = actual_edges[i];
        const auto &b = core._engagements[i];
        same = a.progress_q16 == b.progress_q16 &&
               a.casualties_attacker == b.casualties_attacker &&
               a.casualties_defender == b.casualties_defender && a.active == b.active;
    }
    ST_CHECK(same, "combat continues to use raw lot sums rather than presentation caches");
    return true;
}

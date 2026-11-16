// Included by military_core_selftest.cpp. The reference retains the former
// full scan and vector operations to compare exact order and every revision.
struct ReferenceFront {
    std::vector<uint32_t> edges;
    std::vector<uint8_t> present;
    uint64_t revision = 0;
    void update(const MilitaryCore &core, const std::vector<int32_t> &cells) {
        const int32_t count = core.terrain().cell_count;
        if (present.size() < (size_t)count * 6) present.assign((size_t)count * 6, 0);
        auto owner = [&](int32_t cell) {
            const int32_t controller = core.controller_of(cell);
            return controller >= 0 ? controller : core._last_digest.cell_owner_slot[(size_t)cell];
        };
        bool changed = false;
        for (int32_t cell : cells) {
            if (cell < 0 || cell >= count) continue;
            for (int32_t dir = 0; dir < 6; ++dir) {
                const int32_t key = cell * 6 + dir;
                const int32_t next = core.terrain().neighbors[(size_t)key];
                const int32_t a = owner(cell), b = next >= 0 ? owner(next) : -1;
                const bool front = a >= 0 && b >= 0 && a != b && core.at_war(a, b);
                if (front == (present[(size_t)key] != 0)) continue;
                present[(size_t)key] = front ? 1 : 0;
                changed = true;
                if (front) edges.push_back((uint32_t)key);
                else for (size_t i = 0; i < edges.size(); ++i) {
                    if (edges[i] != (uint32_t)key) continue;
                    edges[i] = edges.back();
                    edges.pop_back();
                    break;
                }
            }
        }
        if (changed) ++revision;
    }
    void rebuild() {
        const size_t before = edges.size();
        edges.erase(std::remove_if(edges.begin(), edges.end(), [&](uint32_t key) {
            return (size_t)key >= present.size() || !present[(size_t)key];
        }), edges.end());
        if (edges.size() != before) ++revision;
        std::sort(edges.begin(), edges.end());
    }
    bool matches(const MilitaryCore &core) const {
        return edges == core._front_edges && present == core._front_edge_set &&
               revision == core._front_revision;
    }
};

bool test_performance_front(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 2026111501), "front position fixture");
    auto &core = sim.core;
    MilitaryWar war;
    war.id = 1; war.active = 1; war.attacker_slot = 0; war.defender_slot = 1;
    war.attacker_handle = handle_for(0); war.defender_handle = handle_for(1);
    core._wars.push_back(war);
    core._last_digest = sim.dg;
    std::vector<int32_t> all;
    for (int32_t cell = 0; cell < t.cell_count; ++cell) {
        core._last_digest.cell_owner_slot[(size_t)cell] = cell % 2;
        all.push_back(cell);
    }
    ReferenceFront reference;
    reference.update(core, all);
    core.update_front_cells(all);
    ST_CHECK(reference.matches(core) && !core._front_edges.empty(), "front initial order and revision");
    for (int32_t step = 0; step < 180; ++step) {
        const int32_t cell = (step * 29) % t.cell_count;
        core._cell_controller[(size_t)cell] = (step / 11) % 2;
        const std::vector<int32_t> touched{cell, -1, (cell + 1) % t.cell_count, cell, t.cell_count};
        reference.update(core, touched);
        core.update_front_cells(touched);
        ST_CHECK(reference.matches(core), "front swap-pop order and per-call revision match scan");
        if (step % 7 == 0) {
            reference.rebuild();
            core.front_rebuild(sim.dg);
            ST_CHECK(reference.matches(core), "front daily sort preserves subsequent position lookup");
        }
    }
    ST_CHECK(core.report().front_position_lookups > 0 &&
                 core.report().front_removal_fallback_rows == 0,
             "unique front removals do not scan the edge vector");
    // Front arrays are not saved. Nevertheless keep the historical behavior
    // for duplicate/stale derived rows, including removing only the first hit.
    const uint32_t repeated = core._front_edges.front();
    uint32_t retained_duplicate = repeated;
    for (uint32_t key : core._front_edges) if (key / 6 != repeated / 6) {
        retained_duplicate = key;
        break;
    }
    core._front_edges.push_back(repeated);
    core._front_edges.push_back(retained_duplicate);
    core._front_edges.push_back((uint32_t)t.cell_count * 6 + 1);
    core._front_edge_pos.clear();
    reference.edges = core._front_edges;
    const int32_t cell = (int32_t)repeated / 6;
    const int32_t next = t.neighbors[repeated];
    core._cell_controller[(size_t)cell] = core.controller_of(next) >= 0 ?
        core.controller_of(next) : core._last_digest.cell_owner_slot[(size_t)next];
    reference.update(core, {cell}); core.update_front_cells({cell});
    ST_CHECK(reference.matches(core) && core.report().front_removal_fallback_rows > 0,
             "duplicate front removes first matching row with original swap-pop");
    reference.rebuild(); core.front_rebuild(sim.dg);
    ST_CHECK(reference.matches(core) &&
                 std::count(core._front_edges.begin(), core._front_edges.end(), retained_duplicate) == 2,
             "front compaction drops stale rows without deduplicating active keys");
    const auto bytes = core.encode();
    auto invalid = bytes; invalid[0] ^= 1;
    const auto positions = core._front_edge_pos;
    ST_CHECK(!core.restore(invalid.data(), invalid.size(), sim.error) &&
                 positions == core._front_edge_pos && reference.matches(core),
             "failed restore leaves front position index untouched");
    ST_CHECK(core.restore(bytes.data(), bytes.size(), sim.error) && core.encode() == bytes &&
                 core._front_edges.empty() && core._front_edge_pos.empty(),
             "successful restore preserves bytes and discards front positions");
    core.update_front_cells({0, 1});
    ST_CHECK(core.set_terrain(t, sim.error) && core._front_edge_pos.empty() && core._front_edges.empty(),
             "same-topology terrain refresh clears front positions");
    core.reset_state();
    ST_CHECK(core._front_edge_pos.empty(), "reset clears front positions");
    return true;
}

int64_t reference_garrison_heads(const MilitaryCore &core, int32_t cell, int32_t owner) {
    int64_t heads = 0;
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (core._lots.active[i] && core._lots.location_kind[i] == MILITARY_LOT_GARRISON &&
            core._lots.location[i] == cell && (owner < 0 || core._lots.country_slot[i] == owner))
            heads += core._lots.count[i];
    }
    return heads;
}

bool test_performance_garrison(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 2026111502), "garrison index fixture");
    auto &core = sim.core;
    const int32_t cell = 9;
    const int32_t a = core.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 0, 0, 256);
    const int32_t b = core.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 1, 0, 256);
    const int32_t retired = core.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 0, 1, 256);
    core._lots.count[(size_t)a] = 7; core._lots.count[(size_t)b] = 13;
    core._lots.active[(size_t)retired] = 0;
    core._lots.count[(size_t)retired] = 99;
    core._lots.free_list.push_back(retired);
    const int32_t army = core.create_army(0, cell);
    for (int32_t i = 0; i < 50; ++i) {
        const int32_t row = core.lot_find_or_create(MILITARY_LOT_ARMY, army, 0, 0, (int16_t)(256 + 32 * i));
        core._lots.count[(size_t)row] = 100;
    }
    const int32_t inactive = core.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 0, 1, 4096);
    core._lots.active[(size_t)inactive] = 0;
    core._lots.count[(size_t)inactive] = 99;
    core._lots.free_list.push_back(inactive);
    core._report = MilitaryReport();
    const auto bytes = core.encode();
    for (int32_t owner : {-1, 0, 1, 2})
        ST_CHECK(core.garrison_heads_at(cell, owner) == reference_garrison_heads(core, cell, owner),
                 "indexed garrison keeps owner active kind location filters and sum");
    ST_CHECK(core.report().garrison_scan_fallbacks == 0 && core.report().garrison_lots_visited <= 12 &&
                 core.encode() == bytes,
             "garrison query visits only cell rows without changing continuation bytes");
    ST_CHECK(core.garrison_heads_at(cell + 1, -1) == 0 &&
                 core.report().garrison_lots_visited <= 12, "empty cell visits no unrelated army lots");
    core._lots.count[(size_t)a] = -7;
    ST_CHECK(core.garrison_heads_at(cell, -1) == 6, "garrison sum does not add a positive-count filter");
    core._lots.count[(size_t)a] = 7;
    // Accepted PKMI permits missing membership and a linked row whose actual
    // location differs. Queries must still scan them and must not repair bytes.
    for (int32_t mode = 0; mode < 3; ++mode) {
        ST_CHECK(core.restore(bytes.data(), bytes.size(), sim.error), "garrison restore complete lists");
        if (mode == 0) military_lot_index_unlink(core, a);
        if (mode == 1) core._lots.location[(size_t)a] = cell + 1;
        if (mode == 2) core._lot_index_ok = false;
        const auto legacy = core.encode();
        ST_CHECK(core.restore(legacy.data(), legacy.size(), sim.error), "incomplete garrison index remains accepted");
        for (int32_t target : {cell, cell + 1})
            ST_CHECK(core.garrison_heads_at(target, -1) == reference_garrison_heads(core, target, -1),
                     "accepted incomplete continuation retains full-scan answer");
        ST_CHECK(core.report().garrison_scan_fallbacks == 2 && core.encode() == legacy,
                 "fallback leaves incomplete saved index byte-for-byte unchanged");
        military_lot_index_rebuild(core);
        core._report = MilitaryReport();
        ST_CHECK(core.garrison_heads_at(cell, -1) == reference_garrison_heads(core, cell, -1) &&
                     core.report().garrison_scan_fallbacks == 0,
                 "existing index rebuild restores complete lookup after slot/location changes");
    }
    core.reset_state();
    ST_CHECK(!core._lot_garrison_lookup_complete, "reset discards garrison completeness proof");
    return true;
}

bool test_performance_garrison_candidates(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 2026111503), "garrison candidates fixture");
    auto &core = sim.core;
    for (int32_t cell : {19, 5, 29, 5}) {
        const int32_t row = core.lot_find_or_create(MILITARY_LOT_GARRISON, cell, cell % 3, 0, 256);
        core._lots.count[(size_t)row] = 10;
    }
    const auto complete = core.encode();
    std::vector<int32_t> actual, expected;
    auto dense_candidates = [&]() {
        expected.clear();
        for (size_t cell = 0; cell < core._lot_cell_head.size(); ++cell)
            if (core._lot_cell_head[cell] >= 0) expected.push_back((int32_t)cell);
    };
    for (int32_t mode = 0; mode < 3; ++mode) {
        ST_CHECK(core.restore(complete.data(), complete.size(), sim.error), "garrison candidates restore");
        const int32_t row = core._lot_cell_head[19];
        if (mode == 1) {
            core._lots.active[(size_t)row] = 0;
            core._lots.free_list.push_back(row);
        }
        if (mode == 2) core._lots.location[(size_t)row] = 31;
        const auto continuation = core.encode();
        ST_CHECK(core.restore(continuation.data(), continuation.size(), sim.error),
                 "inactive or misplaced linked garrison continuation remains accepted");
        dense_candidates();
        ST_CHECK(military_garrison_candidate_cells(core, actual) && actual == expected &&
                     actual == std::vector<int32_t>({5, 19, 29}) && core.encode() == continuation,
                 "sparse candidates retain every nonempty head in ascending cell order");
    }
    core._lot_index_ok = false;
    const auto lazy = core.encode();
    ST_CHECK(!military_garrison_candidate_cells(core, actual) && core.encode() == lazy,
             "unready candidate query preserves original lazy-rebuild timing");
    ST_CHECK(core.restore(complete.data(), complete.size(), sim.error), "candidate malformed-shape fixture");
    core._lot_cell_head.pop_back();
    ST_CHECK(!military_garrison_candidate_cells(core, actual), "candidate shape mismatch retains dense pass");
    // A false saved index may still have heads. The original dense pass first
    // rebuilds at the first nonempty old head, so newly discovered earlier cells
    // are intentionally not revisited during that call.
    Sim lazy_sim;
    ST_CHECK(lazy_sim.init(t, 2026111504), "candidate lazy procurement fixture");
    auto &lazy_core = lazy_sim.core;
    std::fill(lazy_sim.dg.cell_owner_slot.begin(), lazy_sim.dg.cell_owner_slot.end(), 0);
    lazy_sim.dg.market_cell = {2, 5}; lazy_sim.dg.market_good = {0, 0};
    lazy_sim.dg.market_sellable = {1000000, 1000000}; lazy_sim.dg.market_price = {1000, 1000};
    for (int32_t cell : {2, 5}) {
        const int32_t row = lazy_core.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 0, 0, 256);
        lazy_core._lots.count[(size_t)row] = 10;
    }
    lazy_core._lot_cell_head[2] = -1;
    lazy_core._lot_index_ok = false;
    const auto legacy = lazy_core.encode();
    ST_CHECK(lazy_core.restore(legacy.data(), legacy.size(), lazy_sim.error), "lazy procurement continuation accepted");
    std::vector<MilitaryIntent> out;
    lazy_core.run_procurement(lazy_sim.dg, out);
    bool later_purchased = false, earlier_purchased = false;
    for (const auto &purchase : lazy_core._purchase_orders) {
        later_purchased |= purchase.dest == 5;
        earlier_purchased |= purchase.dest == 2;
    }
    ST_CHECK(later_purchased && !earlier_purchased && lazy_core._lot_index_ok,
             "lazy procurement still skips cells discovered before the first old nonempty head");
    return true;
}

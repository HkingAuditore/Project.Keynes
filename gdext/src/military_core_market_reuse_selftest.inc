// Included once by military_core_selftest.cpp after the fixture definitions.
// Compare real consumers with the original independent-scope execution. Market
// quotas deliberately run out, so accidentally sharing a pass's remaining stock
// changes the emitted purchases, not just a diagnostic work counter.
bool market_reuse_scratch_empty(const MilitaryCore &core) {
    return core._md_day == -1 && core._md_cell_off.empty() &&
           core._md_cell_rows.empty() && core._md_row_cell.empty() &&
           core._md_row_good.empty() && core._md_row_sellable.empty() &&
           core._md_row_price.empty() && core._md_cell_has_merchant.empty() &&
           core._md_row_left.empty() && core._sup_row_own.empty();
}

bool market_reuse_same_intents(const std::vector<MilitaryIntent> &a,
                               const std::vector<MilitaryIntent> &b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        const MilitaryIntent &x = a[i], &y = b[i];
        if (x.kind != y.kind || x.reserved != y.reserved || x.cell != y.cell ||
            x.good != y.good || x.pad != y.pad || x.country_a != y.country_a ||
            x.country_b != y.country_b || x.count != y.count ||
            x.amount != y.amount || x.source_id != y.source_id) return false;
    }
    return true;
}

bool test_market_reuse_consumers(const MilitaryTerrainInput &t, std::string &report) {
    MilitaryCatalog catalog = make_catalog();
    catalog.state_buildings[0].repair_materials = {{0, 100ll << 32}};
    Sim reference, reused;
    ST_CHECK(reference.init(t, 2026111505, catalog) && reused.init(t, 2026111505, catalog),
             "market reuse consumer fixtures");
    const int32_t home = cell_at(5, 5), occupied = cell_at(24, 12);
    for (Sim *sim : {&reference, &reused}) {
        auto &core = sim->core;
        auto &digest = sim->dg;
        digest.day = core._last_day = 17;
        digest.market_cell = {home, occupied};
        digest.market_good = {0, 0};
        digest.market_sellable = {200, 200}; // Original per-pass quota is 100.
        digest.market_price = {1000, 1000};
        std::fill(digest.cell_has_merchant.begin(), digest.cell_has_merchant.end(), 0);
        digest.cell_has_merchant[(size_t)home] = 1;
        core.cell_state(home, true)->barracks_count[0] = 1;
        const int32_t garrison = core.lot_find_or_create(MILITARY_LOT_GARRISON, home, 0, 0, 256);
        core._lots.count[(size_t)garrison] = 100000;
        const int32_t army = core.create_army(0, occupied);
        ST_CHECK(army >= 0, "market reuse occupied army exists");
        const int32_t marching = core.lot_find_or_create(MILITARY_LOT_ARMY, army, 0, 0, 256);
        core._lots.count[(size_t)marching] = 100000;
        core._armies.cached_headcount[(size_t)army] = 100000;
        core._cell_controller[(size_t)occupied] = 0;
    }
    std::vector<MilitaryIntent> expected, actual;
    ST_CHECK(market_reuse_scratch_empty(reused.core), "market scratch is empty before consumer sequence");
    {
        MilitaryMarketDayReuse reuse(reused.core, reused.dg);
        reference.core.run_maintenance(reference.dg, expected);
        reused.core.run_maintenance(reused.dg, actual);
        int64_t maintenance_qty = 0;
        for (const auto &order : reused.core.purchase_orders())
            if (order.channel == 1 && order.intent.cell == home && order.intent.good == 0)
                maintenance_qty += order.intent.count;
        ST_CHECK(maintenance_qty == 100 && reuse.parked &&
                     !reuse.row_sellable.empty() && reuse.row_sellable[0] == 0,
                 "maintenance really exhausts the home row's complete sale quota");
        ST_CHECK(market_reuse_same_intents(expected, actual) &&
                     reference.core.encode() == reused.core.encode() &&
                     market_reuse_scratch_empty(reused.core),
                 "maintenance keeps complete ordered intents and continuation bytes");

        reference.core.run_procurement(reference.dg, expected);
        reused.core.run_procurement(reused.dg, actual);
        int64_t supply_qty = 0;
        for (const auto &order : reused.core.purchase_orders())
            if (order.channel == 0 && order.intent.cell == home && order.intent.good == 0)
                supply_qty += order.intent.count;
        ST_CHECK(supply_qty == 100,
                 "general supply receives its original quota after maintenance exhausted that row");
        ST_CHECK(market_reuse_same_intents(expected, actual) &&
                     reference.core.encode() == reused.core.encode() &&
                     market_reuse_scratch_empty(reused.core),
                 "general supply keeps complete ordered intents and continuation bytes");

        reference.core.run_requisition(reference.dg, expected);
        reused.core.run_requisition(reused.dg, actual);
        int64_t requisition_qty = 0;
        for (const MilitaryIntent &intent : actual)
            if (intent.kind == MILITARY_INTENT_REQUISITION && intent.cell == occupied)
                requisition_qty += intent.count;
        ST_CHECK(requisition_qty == 10,
                 "disconnected occupying army retains its independent local requisition allowance");
        ST_CHECK(market_reuse_same_intents(expected, actual) &&
                     reference.core.encode() == reused.core.encode() &&
                     reference.core.state_hash() == reused.core.state_hash() &&
                     market_reuse_scratch_empty(reused.core),
                 "all three consumers keep full intents, state hash and PKMI bytes");
        ST_CHECK(reused.core.report().market_index_builds == 1 &&
                     reused.core.report().market_index_reuses == 2 &&
                     reference.core.report().market_index_builds == 3,
                 "consumer equality exercises one build and two actual reuses");
    }
    ST_CHECK(reused.core._market_day_reuse == nullptr && market_reuse_scratch_empty(reused.core),
             "consumer scope releases borrowed input and every market column");
    return true;
}

bool test_market_reuse_boundaries(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 2026111506), "market reuse boundary fixture");
    auto &core = sim.core;
    auto &digest = sim.dg;
    const int32_t home = cell_at(5, 5), distant = cell_at(24, 12);
    digest.day = 19;
    digest.market_cell = {distant}; digest.market_good = {0};
    digest.market_sellable = {200}; digest.market_price = {1000};
    {
        MilitaryMarketDayReuse reuse(core, digest);
        {
            MilitaryCore::MarketDayScope pass(core);
            pass.ensure(digest);
            ST_CHECK(!military_supply_connected(core, digest, 0, home),
                     "active market rows require an own market for supply");
            core._md_row_sellable[0] = 0;
        }
        ST_CHECK(reuse.parked && market_reuse_scratch_empty(core) &&
                     military_supply_connected(core, digest, 0, home),
                 "parked market rows preserve the old outside-pass ownership-only supply probe");
        // The date and shape match, but this is a distinct immutable input.
        MilitaryWorldDigest different = digest;
        different.market_cell = {home}; different.market_sellable = {600};
        different.market_price = {7000};
        const auto before_different = core.report().market_index_builds;
        {
            MilitaryCore::MarketDayScope pass(core);
            pass.ensure(different);
            ST_CHECK(core._md_row_cell == std::vector<int32_t>({home}) &&
                         core._md_row_sellable == std::vector<int64_t>({300}) &&
                         core._md_row_price == std::vector<int64_t>({7000}) &&
                         military_supply_connected(core, different, 0, home),
                     "same-date different digest receives its own market rows and quantities");
        }
        ST_CHECK(core.report().market_index_builds == before_different + 1,
                 "same-date distinct input is rebuilt instead of borrowing parked columns");
        {
            MilitaryCore::MarketDayScope pass(core);
            pass.ensure(digest);
            ST_CHECK(core._md_row_cell == std::vector<int32_t>({distant}) &&
                         core._md_row_sellable == std::vector<int64_t>({100}) &&
                         core._md_row_price == std::vector<int64_t>({1000}),
                     "returning to the original input restores its own fresh allowance");
        }
    }
    ST_CHECK(core._market_day_reuse == nullptr && market_reuse_scratch_empty(core),
             "input-switch scope cleans up all public market scratch");

    // A return while the inner pass still owns live rows exercises destruction
    // in the same order as a failing consumer; no special cleanup call is used.
    auto leave_early = [&]() {
        MilitaryMarketDayReuse reuse(core, digest);
        MilitaryCore::MarketDayScope pass(core);
        pass.ensure(digest);
        return false;
    };
    ST_CHECK(!leave_early() && core._market_day_reuse == nullptr && market_reuse_scratch_empty(core),
             "early return releases live pass rows and the borrowed reuse context");

    for (int32_t action = 0; action < 6; ++action) {
        Sim lifecycle;
        ST_CHECK(lifecycle.init(t, 2026111507), "market reuse lifecycle fixture");
        auto &c = lifecycle.core;
        lifecycle.dg.day = 20;
        lifecycle.dg.market_cell = {home}; lifecycle.dg.market_good = {0};
        lifecycle.dg.market_sellable = {200}; lifecycle.dg.market_price = {1000};
        const auto saved = c.encode();
        {
            MilitaryMarketDayReuse reuse(c, lifecycle.dg);
            { MilitaryCore::MarketDayScope pass(c); pass.ensure(lifecycle.dg); }
            ST_CHECK(reuse.parked && market_reuse_scratch_empty(c), "lifecycle begins with parked rows");
            if (action == 0) {
                MilitaryCore::MarketDayScope pass(c);
                pass.drop();
            } else if (action == 1) {
                c.reset_state();
            } else if (action == 2) {
                ST_CHECK(c.set_terrain(t, lifecycle.error), "same-topology terrain replacement succeeds");
            } else if (action == 3) {
                ST_CHECK(c.restore(saved.data(), saved.size(), lifecycle.error), "market fixture restore succeeds");
            } else if (action == 4) {
                ST_CHECK(!c.restore(saved.data(), 4, lifecycle.error) && c.encode() == saved,
                         "failed restore preserves the original continuation");
            } else {
                military_market_reset(c);
            }
            const bool failed_restore = action == 4;
            ST_CHECK(reuse.allowed == failed_restore && reuse.parked == failed_restore &&
                         market_reuse_scratch_empty(c),
                     "drop/reset/terrain/restore invalidate reuse; failed restore preserves it");
            const int64_t builds = c.report().market_index_builds;
            const int64_t reuses = c.report().market_index_reuses;
            {
                MilitaryCore::MarketDayScope pass(c);
                pass.ensure(lifecycle.dg);
                ST_CHECK(c._md_row_cell == std::vector<int32_t>({home}) &&
                             c._md_row_sellable == std::vector<int64_t>({100}),
                         "next consumer obtains complete input after the lifecycle boundary");
            }
            ST_CHECK(c.report().market_index_builds == builds + (failed_restore ? 0 : 1) &&
                         c.report().market_index_reuses == reuses + (failed_restore ? 1 : 0),
                     "successful mutation cannot reuse old rows; rejected mutation can");
        }
        ST_CHECK(c._market_day_reuse == nullptr && market_reuse_scratch_empty(c),
                 "lifecycle scope never leaves borrowed rows behind");
    }

    Sim stepped;
    ST_CHECK(stepped.init(t, 2026111508) && market_reuse_scratch_empty(stepped.core),
             "real step starts with empty market scratch");
    ST_CHECK(stepped.step() && stepped.core._market_day_reuse == nullptr &&
                 market_reuse_scratch_empty(stepped.core),
             "real complete step returns with no reuse context or market rows");
    return true;
}

bool test_performance_market_reuse(const MilitaryTerrainInput &t, std::string &report) {
    return test_market_reuse_consumers(t, report) && test_market_reuse_boundaries(t, report);
}

bool test_performance_direct_wars(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 2026111509), "direct war entry fixture");
    auto &core = sim.core;
    auto &digest = sim.dg;
    digest.day = core._last_day = 17;
    std::fill(digest.cell_owner_slot.begin(), digest.cell_owner_slot.end(), 0);
    digest.cell_owner_slot[20] = 1;
    digest.country_annual_revenue = {500, 1000, 1500};
    MilitaryWar war;
    war.id = 7; war.active = 1; war.attacker_slot = 0; war.defender_slot = 1;
    war.start_day = digest.day;
    core._wars.push_back(war);
    MilitaryIntent queued;
    queued.kind = MILITARY_INTENT_TRANSFER_CASH;
    queued.country_a = handle_for(0); queued.country_b = handle_for(1);
    queued.amount = 123; queued.source_id = 456;
    core._war_intents.push_back(queued);
    MilitaryIntent prior;
    prior.kind = MILITARY_INTENT_PROCUREMENT_DEMAND;
    std::vector<MilitaryIntent> out{prior};
    core.run_wars(digest, out);
    ST_CHECK(out.size() == 2 && market_reuse_same_intents(out, {prior, queued}) &&
                 core._war_intents.empty(),
             "direct war entry appends queued treaties once and in original order");
    ST_CHECK(core.annual_revenue_q16(1) == 1000 &&
                 core.annex_price_q16(0, core._wars[0]) == 10 * MILITARY_Q16,
             "direct war entry publishes current revenue and ownership to cold queries");
    const auto first = core.evaluate_peace(7, handle_for(0), {MPEACE_LUMP_SUM, 0, 0}, {100});
    ST_CHECK(first.valid && first.price_q16 == 5 * MILITARY_Q16 / 2,
             "direct war treaty quotation uses the supplied annual revenue");

    // A caller is allowed to invoke run_wars directly again without step_day.
    // Ownership and annual income must replace the previous public-query view.
    digest.country_annual_revenue[1] = 2000;
    digest.cell_owner_slot[21] = digest.cell_owner_slot[22] = 1;
    core.run_wars(digest, out);
    const auto second = core.evaluate_peace(7, handle_for(0), {MPEACE_LUMP_SUM, 0, 0}, {100});
    ST_CHECK(out.size() == 2 && second.valid && second.price_q16 == 5 * MILITARY_Q16 / 4 &&
                 core.annex_price_q16(0, core._wars[0]) == 30 * MILITARY_Q16 &&
                 core.annual_revenue_q16(1) == 2000,
             "second direct war call updates real treaty prices without duplicating queued intents");
    return true;
}

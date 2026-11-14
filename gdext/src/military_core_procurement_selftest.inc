// Private self-test using the enclosing TU synthetic Sim bridge.
// --- 11. 3-cell procurement (design 9.3): only markets of the same country in
// the demander's ring, nothing in range is unmet demand, and a delivered
// quantity is booked in the sec 9.7 ledger.
// The synthetic digest carries a market every 37th cell, so a garrison on its
// own ring sources locally; a garrison far from any own market records unmet
// demand instead of scanning the map.
bool test_procurement(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 9091), "procurement sim init");
    // Markets of the synthetic digest sit on every 37th cell of the map. A cell
    // whose 3-ring holds no market sees only unmet demand (no global scan).
    int32_t far_cell = -1;
    int32_t near_cell = -1;
    for (int32_t c = 0; c < t.cell_count; ++c) {
        const int32_t col = c % kW;
        if (col >= 14) continue;   // country 0 owns columns 0..13
        bool has_market = false;
        for (int32_t m = 0; m < t.cell_count; m += 37) {
            if (sim.core.cell_distance(c, m) <= MILITARY_SUPPLY_RADIUS) has_market = true;
        }
        if (c % 37 == 0 && near_cell < 0 && has_market) near_cell = c;
        if (!has_market && far_cell < 0) far_cell = c;
    }
    ST_CHECK(near_cell >= 0, "procurement: a market cell of country 0 exists");
    ST_CHECK(far_cell >= 0, "procurement: a country 0 cell with no market in its ring exists");
    {
        MilitaryCommand c;
        c.cell = near_cell;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "procurement: barracks on a market cell");
        MilitaryCommand target;
        target.count = 0;
        target.value = 50;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "procurement: target 50");
    }
    for (int32_t day = 0; day < 60; ++day) ST_STEP(sim, sim.day + 1);
    ST_CHECK(garrison_at(sim.core, near_cell) > 0, "procurement: garrison recruited on the market cell");
    int64_t held = 0;
    for (const MilitaryStockRow &row : sim.core.stocks()) {
        if (row.holder_kind == MILITARY_LOT_GARRISON && row.holder == near_cell && row.qty > 0) held += row.qty;
    }
    ST_CHECK(held > 0, "procurement: garrison stock was bought from its own 3-cell ring");
    // Physical maintenance (design §2): the barracks the harness placed must be
    // tracked as its own repair object, with a positive daily recipe demand and
    // a satisfaction ratio in range - not a per-country cash verdict.
    ST_CHECK(!sim.core.maintenance_rows().empty(),
             "maintenance: a state building group is tracked as a repair object");
    bool saw_building_row = false;
    for (const MilitaryMaintenanceRow &row : sim.core.maintenance_rows()) {
        if (row.kind != 0) continue;
        saw_building_row = true;
        ST_CHECK(row.ratio_bp >= 0 && row.ratio_bp <= 10000,
                 "maintenance: satisfaction ratio is basis points");
        ST_CHECK(row.cell >= 0 && row.holder_kind == MILITARY_LOT_MAINTENANCE,
                 "maintenance: building inventory is its own composite holder");
    }
    ST_CHECK(saw_building_row, "maintenance: at least one building repair row exists");
    ST_CHECK(sim.max_abs_reconcile == 0, "procurement: ledger reconcile_delta == 0 every day");
    // A far garrison cell (no market in range) must not invent goods: build a
    // barracks there and confirm nothing arrives from outside the ring.
    MilitaryCommand far;
    far.cell = far_cell;
    far.unit_to = 0;
    ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, far), "procurement: barracks with no market in range");
    for (int32_t day = 0; day < 20; ++day) ST_STEP(sim, sim.day + 1);
    int64_t far_held = 0;
    for (const MilitaryStockRow &row : sim.core.stocks()) {
        if (row.holder_kind == MILITARY_LOT_GARRISON && row.holder == far_cell && row.qty > 0) far_held += row.qty;
    }
    ST_CHECK(far_held == 0, "procurement: nothing supplied outside the 3-cell ring (no fallback scan)");
    MilitaryCommand train;
    train.cell = near_cell;
    train.unit_from = 0;
    train.unit_to = 1;
    train.count = 50;
    ST_CHECK(sim.submit(MCMD_TRAIN, 0, train), "equipment procurement training order");
    bool bought_equipment = false;
    for (int32_t day = 0; day < 10; ++day) {
        ST_STEP(sim, sim.day + 1);
        for (const MilitaryIntent &intent : sim.last) {
            if (intent.kind != MILITARY_INTENT_PROCURE_GOOD) continue;
            ST_CHECK(intent.good >= 0, "purchase bridge always names a real market SKU");
            bought_equipment |= intent.good == 1;
        }
    }
    ST_CHECK(bought_equipment, "training equipment purchase reaches the market bridge");
    Sim cold;
    ST_CHECK(cold.init(t, 9092), "empty-market demand fixture init");
    std::fill(cold.dg.market_sellable.begin(), cold.dg.market_sellable.end(), 0);
    MilitaryCommand barracks;
    barracks.cell = near_cell;
    barracks.unit_to = 0;
    ST_CHECK(cold.submit(MCMD_STATE_BUILD, 0, barracks), "empty-market barracks");
    MilitaryCommand target;
    target.count = 0;
    target.value = 50;
    ST_CHECK(cold.submit(MCMD_FORCE_SET_TARGET, 0, target), "empty-market recruitment target");
    bool forecast = false, bought = false;
    for (int32_t day = 0; day < 20; ++day) {
        ST_STEP(cold, cold.day + 1);
        for (const MilitaryIntent &intent : cold.last) {
            if (intent.kind == MILITARY_INTENT_PROCUREMENT_DEMAND && intent.count > 0) {
                forecast = true;
                ST_CHECK(intent.good >= 0 && intent.cell >= 0 && intent.amount == 10,
                    "empty-market forecast names real SKU, source market and normalization");
            }
            bought |= intent.kind == MILITARY_INTENT_PROCURE_GOOD && intent.count > 0;
        }
    }
    ST_CHECK(forecast && !bought && cold.core.stocks().empty(),
        "zero stock publishes military demand without inventing purchases or cargo");
    return true;
}

// --- 12. Physical maintenance (design §2/§3, plan S2-4/S3): the demand carry,
// the min-ratio consumption rule and the buy/settle handover.
//
// The synthetic digest publishes dense goods 0 and 1 on every 37th cell, so the
// recipe below is expressible without touching the harness market.
bool test_maintenance(const MilitaryTerrainInput &t, std::string &report) {
    // ---- (a) fixed-point carry: a rate that is not a whole milli-good/day ----
    // 2^32/3 = one third of a milli-good per day. A truncating implementation
    // consumes 0 every day; a carrying one consumes 1 milli-good every third
    // day, i.e. exactly 100 over 300 days.
    MilitaryCatalog carry_catalog = make_catalog();
    ST_CHECK(!carry_catalog.state_buildings.empty(), "maintenance: synthetic catalog has a barracks");
    carry_catalog.state_buildings[0].repair_materials.clear();
    carry_catalog.state_buildings[0].repair_materials.push_back({0, 1431655765ll});
    int32_t near_cell = -1;
    for (int32_t c = 0; c < t.cell_count && near_cell < 0; ++c) {
        if (c % kW >= 14) continue;                 // country 0 owns columns 0..13
        if (c % 37 == 0) near_cell = c;             // a market cell of its own
    }
    ST_CHECK(near_cell >= 0, "maintenance: a market cell of country 0 exists");
    {
        Sim sim;
        ST_CHECK(sim.init(t, 9401, carry_catalog), "maintenance carry fixture init");
        MilitaryCommand c;
        c.cell = near_cell;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "maintenance carry: barracks accepted");
        // The barracks needs a few days to finish, so count only the days that
        // actually produced demand: with a rate of exactly one third of a
        // milli-good per day, `active` such days must sum to floor(active / 3).
        // A truncating implementation would sum to 0 - that is the whole point of
        // the persisted carry.
        int64_t need_total = 0;
        int64_t row_days = 0;      // days the repair object existed (demand days)
        int64_t emit_days = 0;     // days a whole milli-good was actually due
        for (int32_t day = 0; day < 300; ++day) {
            if (!sim.step()) { ST_CHECK(false, "maintenance carry: day failed"); break; }
            const MilitaryReport &rep = sim.core.report();
            const int64_t need = rep.maintenance_need_goods;
            need_total += need;
            if (rep.maintenance_rows > 0) ++row_days;
            if (need > 0) ++emit_days;
        }
        const int64_t expected = row_days / 3;
        ST_CHECK(row_days > 250,
                 ("maintenance carry: the repair object existed for most of the run ("
                  + std::to_string(row_days) + " days)").c_str());
        ST_CHECK(emit_days == expected,
                 ("maintenance carry: one milli-good falls due every third day (" +
                  std::to_string(emit_days) + " vs " + std::to_string(expected) + ")").c_str());
        ST_CHECK(need_total == expected,
                 ("maintenance carry: one third of a milli-good per day accumulates to "
                  "floor(days/3) (expected " + std::to_string(expected) + ", got " +
                  std::to_string(need_total) + ")").c_str());
    }
    // ---- (b) min-ratio consumption + buy/settle handover --------------------
    MilitaryCatalog trade_catalog = make_catalog();
    trade_catalog.state_buildings[0].repair_materials.clear();
    trade_catalog.state_buildings[0].repair_materials.push_back({0, 42949672960ll});  // 10/day
    trade_catalog.state_buildings[0].repair_materials.push_back({1, 85899345920ll});  // 20/day
    Sim sim;
    ST_CHECK(sim.init(t, 9402, trade_catalog), "maintenance trade fixture init");
    {
        MilitaryCommand c;
        c.cell = near_cell;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "maintenance trade: barracks accepted");
    }
    int64_t need_total = 0, met_total = 0;
    for (int32_t day = 0; day < 60; ++day) {
        if (!sim.step()) { ST_CHECK(false, "maintenance trade: day failed"); break; }
        need_total += sim.core.report().maintenance_need_goods;
        met_total += sim.core.report().maintenance_met_goods;
    }
    ST_CHECK(need_total > 0, "maintenance trade: the recipe produces demand");
    ST_CHECK(met_total > 0, "maintenance trade: bought materials were consumed");
    ST_CHECK(sim.max_abs_reconcile == 0, "maintenance trade: ledger reconcile_delta == 0");
    // A financed country must never let a stocked building starve: the buy pass
    // keeps a 10-day cover, so by the end of the window the building is repaired.
    bool found_building = false;
    for (const MilitaryMaintenanceRow &row : sim.core.maintenance_rows()) {
        if (row.kind != 0) continue;
        found_building = true;
        ST_CHECK(row.ratio_bp >= 5000,
                 ("maintenance trade: a financed building stays repaired (ratio_bp=" +
                  std::to_string(row.ratio_bp) + ")").c_str());
    }
    ST_CHECK(found_building, "maintenance trade: the barracks is a repair object");
    return true;
}

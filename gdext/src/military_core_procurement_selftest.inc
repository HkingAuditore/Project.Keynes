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

bool test_barracks_capacity_scale(const MilitaryTerrainInput &t, std::string &report) {
    const int32_t A = cell_at(5, 5);
    const int64_t cap = (int64_t)MILITARY_MAX_ARMIES * 256;
    // q16 1.1 exactly as the tech chain encodes it. Every expected value below
    // is computed from this constant, never from posts * 11 / 10.
    const int64_t kQ = 72089;
    auto setup = [&](MilitaryCore &core, int32_t barracks_rows, int32_t slot0_q16,
                     int32_t slot1_q16) -> bool {
        std::string error;
        if (!core.configure(make_catalog(), 11, error) || !core.set_terrain(t, error)) {
            return false;
        }
        core.ensure_country_slot(handle_for(0));
        core.ensure_country_slot(handle_for(1));
        MilitaryCellState row = {};
        row.cell = A;
        row.barracks_count[0] = barracks_rows;
        core._cell_states.clear();
        core._cell_states.push_back(row);
        // Write the committed digest directly: posts_for_cell reads _last_digest,
        // which is the previous commit day's view, so the test cannot rely on
        // "change the stat and step one day". country_capacity and stat_count are
        // what has_stat gates on: without them stat_q16 silently returns 1.0.
        core._last_digest.country_capacity = 2;
        core._last_digest.stat_count = MSTAT_COUNT;
        core._last_digest.country_stat_q16.assign(2 * MSTAT_COUNT, MILITARY_Q16);
        core._last_digest.country_stat_q16[MSTAT_BARRACKS_CAPACITY] = slot0_q16;
        core._last_digest.country_stat_q16[MSTAT_COUNT + MSTAT_BARRACKS_CAPACITY] =
            slot1_q16;
        return true;
    };
    MilitaryCore core;
    // (1) factor 1.0 must be bit-identical to the unscaled sum: 48 rows.
    ST_CHECK(setup(core, 48, MILITARY_Q16, MILITARY_Q16), "barracks scale 1.0: configure + terrain");
    const int32_t posts_48 = core.posts_for_cell(A, 0);
    ST_CHECK(posts_48 == 4800, "factor 1.0: 48 rows -> 4800 posts unchanged");
    // Measured, not assumed: the catalog's tier-0 barracks capacity.
    const int64_t per_row = posts_48 / 48;
    // (2) q16 factor on 164,000 posts: one encoding, one number.
    const int64_t posts_164k = 1640 * per_row;
    const int64_t want_164k = posts_164k * kQ / MILITARY_Q16;
    ST_CHECK(setup(core, 1640, (int32_t)kQ, MILITARY_Q16),
             "barracks scale 72089: configure + terrain");
    const int32_t got_164k = core.posts_for_cell(A, 0);
    ST_CHECK((int64_t)got_164k == want_164k,
             "factor 72089: 164000 posts -> 180398 (q16 of 72090 would be 180401, decimal 180400)");
    // (3) the cap still holds after scaling: 480,000 -> 527,995 -> 524,288.
    const int64_t pre_cap = 4800 * per_row * kQ / MILITARY_Q16;
    ST_CHECK(pre_cap > cap, "cap fixture is above the cap before truncation (527995 > 524288)");
    ST_CHECK(setup(core, 4800, (int32_t)kQ, MILITARY_Q16),
             "barracks scale cap: configure + terrain");
    const int32_t got_cap = core.posts_for_cell(A, 0);
    ST_CHECK((int64_t)got_cap == cap, "cap still enforced after scaling (524288)");
    // (4) per-slot factors: same cell, different country -> different posts.
    ST_CHECK(setup(core, 1640, (int32_t)kQ, MILITARY_Q16),
             "barracks scale per-slot: configure + terrain");
    const int32_t got_slot0 = core.posts_for_cell(A, 0);
    const int32_t got_slot1 = core.posts_for_cell(A, 1);
    ST_CHECK((int64_t)got_slot0 == want_164k && (int64_t)got_slot1 == posts_164k,
             "per-country factor: slot0 scaled, slot1 neutral");
    report += "barracks_capacity_scale kQ=" + std::to_string(kQ) +
              " per_row=" + std::to_string(per_row) +
              " posts164000->" + std::to_string(got_164k) + "/want " +
              std::to_string(want_164k) + " precap=" + std::to_string(pre_cap) +
              " capped=" + std::to_string(got_cap) + "/cap " + std::to_string(cap) +
              " per-slot=" + std::to_string(got_slot0) + "," + std::to_string(got_slot1) +
              " all ok\n";
    return true;
}

// --- B2 read point: MSTAT_CONVOY_ESCORT scales `ESCORT_BASE_Q16` before the
// interception roll. The escort value is a local of the convoy loop, so the
// assertion pins the risk boundary it produces, with exact rng rolls:
//   stat 65536 -> escort = mul_div(13107, 65536, 65536) = 13107
//                 risk = 13107 * 32768 / (13107 + 13107) = 16384
//   stat 98304 -> escort = mul_div(13107, 98304, 65536) = 19660  (19660.5 truncated)
//                 risk = 13107 * 32768 / (13107 + 19660) = 13107
// Same shipments, same ids and the same rolls in both worlds, so the only
// variable is the stat. A missing read point leaves the 1.5 world at risk 16384
// and it would then also swallow the 13107 and 16383 rolls.
bool test_convoy_escort_scale(const MilitaryTerrainInput &t, std::string &report) {
    const int32_t A = cell_at(3, 5);
    const int32_t B = cell_at(9, 5);
    const int64_t day = 7;
    // value / MILITARY_MONEY_SCALE = 65536, so escort == escort_q16 (no shift loss).
    const int64_t value = 65536 * MILITARY_MONEY_SCALE;
    const int32_t rolls[4] = {13106, 13107, 16383, 16384};
    int64_t ids[4] = {-1, -1, -1, -1};
    int32_t found = 0;
    for (int64_t id = 1; id <= 4000000 && found < 4; ++id) {
        const int32_t roll = (int32_t)(rng(11, (uint64_t)id, day) & 0xffffu);
        for (int32_t k = 0; k < 4; ++k) {
            if (ids[k] < 0 && roll == rolls[k]) {
                ids[k] = id;
                ++found;
            }
        }
    }
    ST_CHECK(found == 4, "escort fixture: rolls 13106/13107/16383/16384 exist within 4M ids");
    auto run = [&](MilitaryCore &core, int32_t escort_stat_q16) -> bool {
        std::string error;
        if (!core.configure(make_catalog(), 11, error) || !core.set_terrain(t, error)) {
            return false;
        }
        const size_t cells = (size_t)core.terrain().cell_count;
        core._cell_controller.assign(cells, 0);
        core._threat.assign(cells, 13107);      // threat > 0 on every hop
        core._guard.assign(cells, 0);
        core._threat_owner.assign(cells, 0);    // no interceptor army: goods just vanish
        core._shipments.clear();
        for (int32_t k = 0; k < 4; ++k) {
            MilitaryShipment s;
            s.id = (uint64_t)ids[k];
            s.country_slot = 0;
            s.current_cell = A;
            s.origin_cell = A;
            s.dest = B;
            s.eta_day = 60;                     // day 7 < 60: one hop, never delivered
            s.good = 0;
            s.qty = 1;
            s.value = value;
            s.departure_day = 1;
            core._shipments.push_back(s);
        }
        MilitaryWorldDigest digest = make_digest(t);
        digest.day = day;
        digest.stat_count = MSTAT_COUNT;
        digest.country_stat_q16.assign(3 * MSTAT_COUNT, MILITARY_Q16);
        digest.country_stat_q16[MSTAT_CONVOY_ESCORT] = escort_stat_q16;
        std::vector<MilitaryIntent> out;
        core.run_convoys(digest, out);
        // Four hops proves the loop body ran; otherwise "all shipments present"
        // would be misread as "nothing intercepted".
        return core.report().convoys_due == 4 && core.report().convoy_hops == 4;
    };
    const auto survived = [](const MilitaryCore &core, int64_t id) {
        for (const MilitaryShipment &s : core.shipments()) {
            if ((int64_t)s.id == id) return true;
        }
        return false;
    };
    MilitaryCore neutral;
    ST_CHECK(run(neutral, MILITARY_Q16), "escort 1.0: four convoys each took one hop");
    MilitaryCore scaled;
    ST_CHECK(run(scaled, 98304), "escort 1.5: four convoys each took one hop");
    // 1.0 -> risk 16384: 13106 / 13107 / 16383 intercepted, 16384 survives.
    ST_CHECK(!survived(neutral, ids[0]) && !survived(neutral, ids[1]) &&
                 !survived(neutral, ids[2]) && survived(neutral, ids[3]),
             "escort 1.0: risk boundary 16384 (13106/13107/16383 hit, 16384 misses)");
    // 1.5 -> risk 13107: only 13106 intercepted.
    ST_CHECK(!survived(scaled, ids[0]) && survived(scaled, ids[1]) &&
                 survived(scaled, ids[2]) && survived(scaled, ids[3]),
             "escort 1.5: risk boundary 13107 (only 13106 hits; 13107/16383/16384 miss)");
    report += "convoy_escort_scale ids=" + std::to_string(ids[0]) + "/" +
              std::to_string(ids[1]) + "/" + std::to_string(ids[2]) + "/" +
              std::to_string(ids[3]) + " rolls=13106/13107/16383/16384 risk1.0=16384"
              " risk1.5=13107 all ok\n";
    return true;
}

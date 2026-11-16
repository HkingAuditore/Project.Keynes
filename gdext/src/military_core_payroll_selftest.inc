// Included inside military_core_selftest.cpp's test namespace.
// These direct owner-level fixtures isolate payroll/war arithmetic from
// recruitment, procurement and combat; the existing Sim cases cover those paths.

bool test_sparse_payroll(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 60640), "sparse payroll: configure");
    MilitaryCore &core = sim.core;
    ST_CHECK(core.ensure_country_slot(handle_for(3)) == 3,
             "sparse payroll: empty country registered");
    const int32_t army0 = core.create_army(0, 20);
    const int32_t army1 = core.create_army(0, 21);
    const int32_t army2 = core.create_army(1, 22);
    ST_CHECK(army0 >= 0 && army0 < army1 && army1 < army2,
             "sparse payroll: ordered formation slots");
    core._armies.cached_headcount[(size_t)army0] = 7;
    core._armies.cached_headcount[(size_t)army1] = 5;
    core._armies.cached_headcount[(size_t)army2] = 3;
    core._policies[0].wage_mode = 1;
    core._policies[0].wage_absolute = 7;
    core._policies[0].budget_share_bp = 10000;
    core._policies[0].budget_wage_bp = 5000;
    core._policies[0].spend_payroll_30 = 301;
    core._policies[1].wage_mode = 0;
    core._policies[1].spend_payroll_30 = 59;
    core._policies[2].wage_mode = 1;
    core._policies[2].wage_absolute = 100;
    core._policy_handle[2] = 0; // A retired country must not be paid.
    core._policies[3].wage_mode = 1;
    core._policies[3].wage_absolute = -10;
    core._policies[3].spend_payroll_30 = 60;
    core._policies[3].upkeep_demand = 9;
    core._policies[3].upkeep_arrears = 8;
    core._policies[3].upkeep_overspend = 7;
    sim.dg.country_capacity = 4;
    sim.dg.country_cash = {90, 90, 1000, 1000};
    sim.dg.country_soldier_living_cost = {0, 11, 0, 0};
    sim.dg.stat_count = MSTAT_COUNT;
    sim.dg.country_stat_q16.assign(4 * MSTAT_COUNT, MILITARY_Q16);
    sim.dg.country_stat_q16[MSTAT_COUNT + MSTAT_WAGE] = 3 * MILITARY_Q16 / 2;
    core._last_digest = sim.dg;
    // Deliberately scrambled by country, holder kind, holder and unit. Direct
    // lot rows also exercise rejected shapes without asking the index builder
    // to accept an invalid holder. Payroll only reads the columns below.
    auto lot = [&](int32_t country, uint8_t kind, int32_t holder,
                   int16_t unit, int64_t count, uint8_t active = 1) {
        core._lots.active.push_back(active);
        core._lots.location_kind.push_back(kind);
        core._lots.location.push_back(holder);
        core._lots.country_slot.push_back(country);
        core._lots.unit_type.push_back(unit);
        core._lots.equip_quality_q8.push_back(256);
        core._lots.kit_q16.push_back(MILITARY_Q16);
        core._lots.condition_q16.push_back(MILITARY_Q16);
        core._lots.count.push_back(count);
    };
    lot(1, MILITARY_LOT_ARMY, army2, 0, 3);
    lot(0, MILITARY_LOT_ARMY, army1, 0, 5);
    lot(0, MILITARY_LOT_GARRISON, 9, 0, 4);
    lot(0, MILITARY_LOT_ARMY, army0, 0, 6);
    lot(1, MILITARY_LOT_GARRISON, 3, 0, 2);
    lot(0, MILITARY_LOT_GARRISON, 3, 0, 2);
    lot(0, MILITARY_LOT_GARRISON, 3, 1, 3);
    lot(1, MILITARY_LOT_ARMY, army0, 2, 1); // Lot country owns this wage.
    lot(0, MILITARY_LOT_GARRISON, 4, 0, 0);
    lot(0, MILITARY_LOT_GARRISON, 5, 0, -2);
    lot(0, MILITARY_LOT_GARRISON, 6, 0, 100, 0);
    lot(0, MILITARY_LOT_GARRISON, -1, 0, 100);
    lot(0, MILITARY_LOT_GARRISON, t.cell_count, 0, 100);
    lot(0, MILITARY_LOT_ARMY, (int32_t)core._armies.active.size(), 0, 100);
    lot(0, MILITARY_LOT_ARMY, army2 + 1, 0, 100); // Inactive formation.
    lot(0, 9, 7, 0, 100);
    lot(-1, MILITARY_LOT_GARRISON, 7, 0, 100);
    lot(99, MILITARY_LOT_GARRISON, 7, 0, 100);
    lot(2, MILITARY_LOT_GARRISON, 7, 0, 100);
    lot(3, MILITARY_LOT_GARRISON, 7, 0, 100);
    std::vector<MilitaryIntent> out;
    core.run_wages_and_upkeep(sim.dg, out);
    ST_CHECK(core.soldier_daily_wage(1) == 16,
             "sparse payroll: AUTO rounds the per-head wage before multiplying lots");
    ST_CHECK(out.size() == 6, "sparse payroll: exact funded holder count");
    const uint16_t kinds[] = {MILITARY_INTENT_PAY_WAGES, MILITARY_INTENT_PAY_WAGES,
                             MILITARY_INTENT_ARMY_PAY, MILITARY_INTENT_PAY_WAGES,
                             MILITARY_INTENT_ARMY_PAY, MILITARY_INTENT_ARMY_PAY};
    const int32_t cells[] = {3, 9, 20, 3, 20, 22};
    const int64_t amounts[] = {35, 28, 27, 32, 16, 42};
    const int64_t heads[] = {0, 0, 7, 0, 7, 3};
    const uint64_t sources[] = {3, 9, core.army_handle(army0), 3,
                                core.army_handle(army0), core.army_handle(army2)};
    for (size_t i = 0; i < out.size(); ++i) {
        const MilitaryIntent &in = out[i];
        ST_CHECK(in.kind == kinds[i] && in.cell == cells[i] && in.amount == amounts[i] &&
                     in.count == heads[i] && in.source_id == sources[i] &&
                     in.country_a == handle_for(i < 3 ? 0 : 1),
                 "sparse payroll: exact country/garrison/army order and clipped cash");
    }
    ST_CHECK(core._policies[0].wage_demand == 140 &&
                 core._policies[0].wage_arrears == 50 &&
                 core._policies[0].wage_overspend == 45 &&
                 core._policies[0].wage_planned_today == 90 &&
                 core._policies[0].pay_ratio_30_q16 == (90 * MILITARY_Q16) / 140 &&
                 core._policies[0].spend_payroll_30 == 381,
             "sparse payroll: exact demand, envelope, pay ratio and rolling spend");
    ST_CHECK(core._policies[1].wage_demand == 0 && core._policies[1].wage_arrears == 0 &&
                 core._policies[1].wage_overspend == 0 &&
                 core._policies[1].pay_ratio_30_q16 == (90 * MILITARY_Q16) / 96 &&
                 core._policies[1].spend_payroll_30 == 148,
             "sparse payroll: unmetered country retains cash-only settlement");
    ST_CHECK(core._policies[3].wage_planned_today == 0 &&
                 core._policies[3].pay_ratio_30_q16 == MILITARY_Q16 &&
                 core._policies[3].spend_payroll_30 == 58 &&
                 core._policies[3].upkeep_demand == 0 &&
                 core._policies[3].upkeep_arrears == 0 &&
                 core._policies[3].upkeep_overspend == 0,
             "sparse payroll: empty wage country still updates policy statistics");
    ST_CHECK(core._report.payroll_lots_visited == (int64_t)core._lots.active.size() &&
                 core._report.payroll_holders_visited == 7 &&
                 core._report.payroll_garrison == 95 && core._report.payroll_army == 85,
             "sparse payroll: one lot scan and only seven eligible holder groups");
    MilitaryCore small;
    std::string error;
    ST_CHECK(small.configure(make_catalog(), 60641, error) &&
                 small.set_terrain(make_hex_terrain(2, 2), error) &&
                 small.ensure_country_slot(handle_for(0)) == 0,
             "sparse payroll: smaller world on the same calling thread");
    MilitaryWorldDigest empty;
    empty.country_cash = {1000};
    out.clear();
    small.run_wages_and_upkeep(empty, out);
    ST_CHECK(out.empty() && small._report.payroll_holders_visited == 0 &&
                 small._report.payroll_lots_visited == 0 &&
                 small._policies[0].wage_planned_today == 0,
             "sparse payroll: previous world's rows cannot leak into empty input");
    return true;
}

// Independent slow reference for the old per-war contract. It deliberately
// visits cells per participant/war, whereas production now collects once.
MilitaryWar reference_war_totals(const MilitaryCore &core, const MilitaryWorldDigest &d,
                                 MilitaryWar war) {
    if (!war.active) return war;
    if (core.country_handle_for_slot(war.attacker_slot) == 0 ||
        core.country_handle_for_slot(war.defender_slot) == 0) {
        war.active = 0;
        return war;
    }
    int64_t value[2] = {}, lost[2] = {};
    bool occupied[2] = {};
    for (int32_t cell = 0; cell < core._terrain.cell_count; ++cell) {
        const int32_t owner = (size_t)cell < d.cell_owner_slot.size()
                                  ? d.cell_owner_slot[(size_t)cell] : -1;
        const int32_t control = core.controller_of(cell) >= 0 ? core.controller_of(cell) : owner;
        if (owner == war.attacker_slot && control != owner) occupied[0] = true;
        if (owner == war.defender_slot && control != owner) occupied[1] = true;
        if (owner != war.attacker_slot && owner != war.defender_slot) continue;
        const size_t side = owner == war.attacker_slot ? 0 : 1;
        const int64_t cell_value = core.cell_value_q16(cell) +
            ((size_t)cell < d.cell_population.size() ? d.cell_population[(size_t)cell] : 0);
        value[side] += cell_value;
        if (control != owner) lost[side] += cell_value;
    }
    war.fully_occupied_since_a = occupied[0] ? d.day : -1;
    war.fully_occupied_since_b = occupied[1] ? d.day : -1;
    const int64_t occupation = mul_div(lost[1] - lost[0], 60 * MILITARY_Q16,
                                       std::max<int64_t>(value[0] + value[1], 1));
    war.score_annihilation_q16 = (int32_t)clamp64(
        mul_div(war.score_annihilation_q16 + occupation, MILITARY_Q16, 2 * MILITARY_Q16),
        -60 * MILITARY_Q16, 60 * MILITARY_Q16);
    war.score_attrition_q16 = (int32_t)clamp64(war.score_attrition_q16,
                                               -10 * MILITARY_Q16, 10 * MILITARY_Q16);
    return war;
}

bool test_sparse_war_totals(std::string &report) {
    MilitaryCore core;
    std::string error;
    MilitaryTerrainInput terrain = make_hex_terrain(4, 2);
    terrain.settlement_tier = {0, 1, 2, 3, 4, 0, 0, 0};
    ST_CHECK(core.configure(make_catalog(), 60642, error) && core.set_terrain(terrain, error),
             "sparse wars: configure");
    for (int32_t slot = 0; slot < 5; ++slot)
        ST_CHECK(core.ensure_country_slot(handle_for(slot)) == slot, "sparse wars: country slot");
    core._policy_handle[4] = 0;
    MilitaryWorldDigest d;
    d.day = 17;
    d.cell_owner_slot = {0, 0, 1, 1, 2, 2, 99, -1};
    d.cell_population = {1, 2, 3, 4, 5, 6}; // The last two cells have no population row.
    core._cell_controller = {1, -1, 0, -1, -1, 1, 0, 0};
    const int32_t pairs[][2] = {{0, 1}, {1, 2}, {0, 2}, {2, 2},
                               {0, 3}, {-1, 0}, {0, 99}, {0, 4}};
    for (const auto &pair : pairs) {
        MilitaryWar war;
        war.id = (int32_t)core._wars.size();
        war.attacker_slot = pair[0];
        war.defender_slot = pair[1];
        war.score_annihilation_q16 = (war.id - 3) * MILITARY_Q16 + 3;
        war.score_attrition_q16 = (war.id & 1 ? -11 : 11) * MILITARY_Q16;
        war.active = 1;
        core._wars.push_back(war);
    }
    for (int32_t pass = 0; pass < 3; ++pass) {
        if (pass == 1) {
            ++d.day;
            d.cell_owner_slot[2] = 2;
            d.cell_population[0] = 999;
            core._terrain.settlement_tier[3] = 4;
            core._cell_controller[0] = -1;
            core._cell_controller[3] = 2;
        } else if (pass == 2) {
            ++d.day;
            d.cell_owner_slot = {0, 0}; // Missing owners remain neutral.
            d.cell_population.clear();
            core._cell_controller.assign(8, -1);
        }
        std::vector<MilitaryWar> expected;
        for (const MilitaryWar &war : core._wars)
            expected.push_back(reference_war_totals(core, d, war));
        core._report = {};
        std::vector<MilitaryIntent> out;
        core.run_wars(d, out);
        ST_CHECK(core._report.war_cells_visited == terrain.cell_count,
                 "sparse wars: one whole-map scan regardless of active war count");
        for (size_t i = 0; i < expected.size(); ++i) {
            const MilitaryWar &actual = core._wars[i];
            const MilitaryWar &want = expected[i];
            ST_CHECK(actual.active == want.active &&
                         actual.fully_occupied_since_a == want.fully_occupied_since_a &&
                         actual.fully_occupied_since_b == want.fully_occupied_since_b &&
                         actual.score_annihilation_q16 == want.score_annihilation_q16 &&
                         actual.score_attrition_q16 == want.score_attrition_q16,
                     "sparse wars: exact old arithmetic after ownership/population/control changes");
        }
        if (pass == 0) {
            ST_CHECK(core._wars[0].fully_occupied_since_a == 17 &&
                         core._wars[0].fully_occupied_since_b == 17 &&
                         core._wars[4].fully_occupied_since_b == -1,
                     "sparse wars: any lost cell sets today; no territory remains -1");
            ST_CHECK(!core._wars[5].active && !core._wars[6].active && !core._wars[7].active,
                     "sparse wars: negative, out-of-range and retired participant slots close");
        }
    }
    for (MilitaryWar &war : core._wars) war.active = 0;
    core._report = {};
    std::vector<MilitaryIntent> out;
    core.run_wars(d, out);
    ST_CHECK(core._report.war_cells_visited == 0,
             "sparse wars: no active war performs no cell scan");
    return true;
}

bool test_performance_payroll_wars(const MilitaryTerrainInput &t, std::string &report) {
    return test_sparse_payroll(t, report) && test_sparse_war_totals(report);
}

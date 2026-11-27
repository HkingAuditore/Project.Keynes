bool test_war_peace_save(const MilitaryTerrainInput &t, std::string &report, uint64_t &hash_out) {
    Sim sim;
    ST_CHECK(sim.init(t, 777), "war sim init");
    const int32_t C = cell_at(13, 12);   // country 0, west neighbour of the enclave
    ST_CHECK(is_neighbor(t, C, kEnclave), "enclave adjacent to staging cell");
    {
        MilitaryCommand c;
        c.cell = C;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks C");
        MilitaryCommand target;
        target.value = 100;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 100");
    }
    ST_STEP(sim, 21);
    ST_CHECK(sim.core.country_soldiers(0) == 100, "staging garrison recruited");
    {
        MilitaryCommand c;
        c.cell = C;
        c.ints = {0, 100};
        ST_CHECK(sim.submit(MCMD_ARMY_CREATE, 0, c), "army.create at C");
        MilitaryCommand w;
        w.other = handle_for(2);
        ST_CHECK(sim.submit(MCMD_WAR_DECLARE, 0, w), "war.declare 0 -> 2");
    }
    ST_STEP(sim, sim.day + 1);
    ST_CHECK(sim.core.at_war(0, 2) && has_event(sim.core, MILITARY_EVENT_WAR_DECLARED), "war active + WAR_DECLARED event");
    const int32_t army = sim.army_of(0);
    ST_CHECK(army >= 0, "army exists");
    {
        MilitaryCommand c;
        c.army = sim.core.army_handle(army);
        c.cell = kEnclave;
        ST_CHECK(sim.submit(MCMD_ARMY_MOVE, 0, c), "army.move into enemy cell");
    }
    bool engaged = false;
    for (int32_t k = 0; k < 90 && sim.core.controller_of(kEnclave) != 0; ++k) {
        ST_STEP(sim, sim.day + 1);
        for (const MilitaryEngagement &e : sim.core.engagements()) engaged = engaged || e.active;
    }
    ST_CHECK(engaged, "movement into enemy cell opened an engagement");
    ST_CHECK(sim.core.controller_of(kEnclave) == 0, "capture: controller of enclave is the attacker");
    ST_CHECK(has_event(sim.core, MILITARY_EVENT_CELL_CONTROL_CHANGED), "CELL_CONTROL_CHANGED event emitted");
    ST_CHECK(sim.core.report().cells_captured > 0 || sim.core.control_revision() > 0, "control revision bumped");
    {
        MilitaryCommand formation;
        formation.op = MCMD_ARMY_CREATE;
        formation.country = handle_for(2);
        formation.cell = kEnclave;
        formation.value = 912;
        sim.core.apply_command(formation, sim.day);
        const auto rejected = sim.core.take_player_command_rejections();
        ST_CHECK(rejected.size() == 1 && rejected[0].caller_sequence == 912 &&
                     std::string(rejected[0].reason) == "cell_occupied",
                 "player formation: a foreign controller rejects a local order");
    }
    ST_STEP(sim, sim.day + 2);   // let run_wars record the full occupation
    // PKMI round trip mid-war (armies, engagements history, wars, events).
    {
        const std::vector<uint8_t> bytes = sim.core.encode();
        MilitaryCore copy;
        std::string error;
        copy.configure(make_catalog(), 777, error);
        copy.set_terrain(t, error);
        const bool ok = copy.restore(bytes.data(), bytes.size(), error);
        ST_CHECK(ok, std::string("PKMI restore ") + error);
        if (copy.state_hash() != sim.core.state_hash()) report += describe_diff(sim.core, copy);
        ST_CHECK(copy.state_hash() == sim.core.state_hash(), "PKMI restore -> identical state_hash");
        ST_CHECK(copy.encode() == bytes, "PKMI re-encode byte-identical");
    }
    std::vector<int32_t> ints = {MPEACE_CEDE_CELL, kEnclave, 0, MPEACE_ANNEX, 0, 0};
    std::vector<int64_t> longs = {0, 0};
    int32_t war_id = sim.core.war_between(0, 2);
    const MilitaryPeaceEvaluation ev = sim.core.evaluate_peace(war_id, handle_for(0), ints, longs);
    ST_CHECK(ev.valid && ev.willing_q16 >= ev.price_q16, "fully occupied enemy willing to accept cede+annex");
    {
        MilitaryCommand c;
        c.other = (uint64_t)(uint32_t)war_id;
        c.ints = ints;
        c.longs = longs;
        ST_CHECK(sim.submit(MCMD_PEACE_PROPOSE, 0, c), "peace.propose cede+annex");
    }
    ST_STEP(sim, sim.day + 1);
    bool cede = false, annex = false;
    for (const MilitaryIntent &in : sim.last) {
        if (in.kind == MILITARY_INTENT_TRANSFER_TERRITORY && in.cell == kEnclave && in.count == 1 &&
            in.country_b == handle_for(0))
            cede = true;
        if (in.kind == MILITARY_INTENT_ANNEX_COUNTRY && in.country_a == handle_for(2) && in.country_b == handle_for(0))
            annex = true;
    }
    ST_CHECK(cede && annex, "treaty emits TRANSFER_TERRITORY + ANNEX_COUNTRY intents the same day");
    ST_CHECK(!sim.core.at_war(0, 2) && has_event(sim.core, MILITARY_EVENT_WAR_ENDED) &&
                 has_event(sim.core, MILITARY_EVENT_COUNTRY_ANNEXED),
             "war closed, WAR_ENDED + COUNTRY_ANNEXED events");
    // Bridge applies the cession (D+1) the way Country would.
    sim.dg.cell_owner_slot[(size_t)kEnclave] = 0;
    sim.dg.country_handle[2] = 0;
    ST_STEP(sim, sim.day + 10);
    {
        std::string leak = "ledger reconcile_delta == 0 throughout the war run";
        if (sim.max_abs_reconcile != 0 || sim.core.report().reconcile_delta != 0) {
            leak += " (max=" + std::to_string(sim.max_abs_reconcile) +
                    " first_leak_day=" + std::to_string(sim.first_leak_day) +
                    " live=" + std::to_string(sim.core.report().reconcile_delta) +
                    " events=" + sim.first_leak_events + ")";
        }
        ST_CHECK(sim.max_abs_reconcile == 0 && sim.core.report().reconcile_delta == 0,
                 leak.c_str());
    }
    {
        const std::vector<uint8_t> bytes = sim.core.encode();
        MilitaryCore copy;
        std::string error;
        copy.configure(make_catalog(), 777, error);
        copy.set_terrain(t, error);
        ST_CHECK(copy.restore(bytes.data(), bytes.size(), error) && copy.state_hash() == sim.core.state_hash() &&
                     copy.encode() == bytes,
                 "PKMI round trip after peace");
    }
    hash_out = sim.core.state_hash();
    return true;
}
// --- 9. auto-discharge reconciled against a partially applied Economy move
// run_recruitment removes the surplus garrison heads when it emits the
// DISCHARGE intent; the receipt must then only put back the heads Economy did
// NOT move (requested - committed). A receipt that removed them a second time
// (or a core that ignored the shortfall) leaves Military and Economy unequal.

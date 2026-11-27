bool test_recruit_and_move(const MilitaryTerrainInput &t, std::string &report, uint64_t &hash_out) {
    Sim sim;
    ST_CHECK(sim.init(t, 1234), "sim init");
    const int32_t A = cell_at(5, 5);
    const int32_t B = cell_at(8, 5);
    {
        MilitaryCommand c;
        c.cell = A;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks A");
        c.cell = B;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks B");
        MilitaryCommand target;
        target.count = 0;
        target.value = 150;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 150");
    }
    ST_STEP(sim, 41);
    ST_CHECK(sim.core.posts_for_cell(A, 0) == 100 && sim.core.posts_for_cell(B, 0) == 100,
             "barracks completed: 100 posts each");
    ST_CHECK(sim.core.country_soldiers(0) == 150, "recruitment reached target exactly (150)");
    ST_CHECK(garrison_at(sim.core, A) <= 100 && garrison_at(sim.core, B) <= 100, "per-cell garrison <= posts");
    const int64_t enlisted_before = sim.enlist_by_cell[(size_t)A] + sim.enlist_by_cell[(size_t)B];
    ST_STEP(sim, 61);
    ST_CHECK(sim.enlist_by_cell[(size_t)A] + sim.enlist_by_cell[(size_t)B] == enlisted_before,
             "no enlistment after target reached");
    ST_CHECK(sim.core.country_soldiers(1) == 0, "other countries untouched");
    // Cession path: `from < 0` means every garrison lot in the cell. The old
    // exact-match version made this a silent no-op and left the previous
    // owner's roster behind after a territory transfer.
    {
        const int64_t gA_before = garrison_at(sim.core, A);
        sim.core.transfer_garrison_owner(A, -1, 1);
        ST_CHECK(garrison_at(sim.core, A) == gA_before &&
                     sim.core.garrison_heads_at(A, 1) == gA_before &&
                     sim.core.garrison_heads_at(A, 0) == 0,
                 "cession transfer (from=-1) moves every garrison lot at the cell");
        sim.core.transfer_garrison_owner(A, 1, 0);
        ST_CHECK(sim.core.garrison_heads_at(A, 0) == gA_before &&
                     sim.core.garrison_heads_at(A, 1) == 0,
                 "explicit source transfer moves the lots back");
    }
    // Army from A's whole garrison marches to B (3 hexes east).
    const int64_t gA = garrison_at(sim.core, A);
    {
        MilitaryCommand c;
        c.cell = A;
        c.ints = {0, (int32_t)gA};
        ST_CHECK(sim.submit(MCMD_ARMY_CREATE, 0, c), "army.create at A");
    }
    ST_STEP(sim, sim.day + 1);
    const int32_t army = sim.army_of(0);
    ST_CHECK(army >= 0 && sim.core.armies().cached_headcount[(size_t)army] == gA, "army holds A's garrison");
    {
        MilitaryCommand c;
        c.army = sim.core.army_handle(army);
        c.cell = B;
        ST_CHECK(sim.submit(MCMD_ARMY_MOVE, 0, c), "army.move to B");
    }
    std::vector<int32_t> trail = {sim.core.armies().cell[(size_t)army]};
    for (int32_t k = 0; k < 8; ++k) {
        ST_STEP(sim, sim.day + 1);
        trail.push_back(sim.core.armies().cell[(size_t)army]);
    }
    bool contiguous = true;
    int32_t moves = 0;
    for (size_t i = 1; i < trail.size(); ++i) {
        contiguous = contiguous && is_neighbor(t, trail[i - 1], trail[i]);
        if (trail[i] != trail[i - 1]) ++moves;
    }
    ST_CHECK(trail.back() == B, "army arrived at B");
    ST_CHECK(contiguous && moves == sim.core.cell_distance(A, B), "army walked a contiguous shortest path, 1 hex/day");
    // Raise the target: A (emptied) gets quota, B (army present >= posts) gets none.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 400;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 400");
    }
    const int64_t a0 = sim.enlist_by_cell[(size_t)A], b0 = sim.enlist_by_cell[(size_t)B];
    ST_STEP(sim, sim.day + 12);
    ST_CHECK(sim.enlist_by_cell[(size_t)B] == b0, "army presence at B suppresses B's quota");
    ST_CHECK(sim.enlist_by_cell[(size_t)A] > a0, "emptied barracks A recruits again");
    ST_CHECK(sim.max_abs_reconcile == 0, "ledger reconcile_delta == 0 every day (recruit run)");
    // A sovereign with no soldiers can still be forced into a rebellion war:
    // this is the "朝廷讨伐" path used after a cell secedes.
    {
        MilitaryCommand forced;
        forced.other = handle_for(0);
        ST_CHECK(sim.submit(MCMD_WAR_DECLARE_FORCED, 1, forced),
                 "war.declare_forced accepted for a soldier-less country");
        ST_STEP(sim, sim.day + 1);
        ST_CHECK(sim.core.at_war(1, 0),
                 "soldier-less country is at war after a forced declaration");
    }
    hash_out = sim.core.state_hash();
    return true;
}
// --- 5..8. war -> engagement -> capture -> peace (cede + annex) -> PKMI -> ledger

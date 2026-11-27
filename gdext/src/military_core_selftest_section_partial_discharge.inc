bool test_partial_discharge(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 5252), "partial discharge sim init");
    const int32_t C = cell_at(5, 5);
    {
        MilitaryCommand c;
        c.cell = C;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "partial discharge: barracks C");
        MilitaryCommand target;
        target.count = 0;
        target.value = 100;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 100");
        MilitaryCommand auto_discharge;
        auto_discharge.count = 1;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_AUTO_DISCHARGE, 0, auto_discharge),
                 "partial discharge: auto discharge on");
    }
    ST_STEP(sim, 21);
    ST_CHECK(garrison_at(sim.core, C) == 100, "partial discharge: 100 soldiers at C");
    // Lower the target so the next sample day discharges 40 of them, and apply
    // only 25 of the 40 on the Economy side.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 60;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 60");
    }
    int64_t discharged = 0, committed = 0;
    bool saw_discharge = false;
    for (int32_t k = 0; k < 6 && !saw_discharge; ++k) {
        sim.last.clear();
        sim.receipts.clear();
        sim.dg.day = sim.day;
        ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
                 "partial discharge: step_day");
        ++sim.day;
        for (const MilitaryIntent &in : sim.last) {
            if (in.kind != MILITARY_INTENT_DISCHARGE) continue;
            saw_discharge = true;
            discharged += in.count;
            MilitaryIntentReceipt r;
            r.kind = in.kind;
            r.ok = 1;
            r.cell = in.cell;
            r.source_id = in.source_id;
            r.committed_count = in.count * 5 / 8;   // Economy moved 5/8 of the request
            committed += r.committed_count;
            sim.enlist_by_cell[(size_t)C] = std::max<int64_t>(0,
                sim.enlist_by_cell[(size_t)C] - r.committed_count);
            sim.dg.cell_soldiers[(size_t)C] = sim.enlist_by_cell[(size_t)C];
            sim.dg.cell_unemployed[(size_t)C] += r.committed_count;
            sim.receipts.push_back(r);
        }
    }
    ST_CHECK(saw_discharge && discharged == 40, "partial discharge: emitted for the 40 surplus");
    const int64_t after_emit = garrison_at(sim.core, C);
    ST_CHECK(after_emit == 60, "partial discharge: lots already removed when emitted");
    // Next day: the shortfall goes back and nothing is removed twice.
    sim.last.clear();
    sim.dg.day = sim.day;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
             "partial discharge: receipt day");
    ++sim.day;
    ST_CHECK(garrison_at(sim.core, C) == after_emit + (discharged - committed),
             "partial discharge: only the unmoved heads return");
    ST_CHECK(garrison_at(sim.core, C) == 75, "partial discharge: 60 + 15 unmoved = 75");
    ST_CHECK(sim.core.country_soldiers(0) == 75, "partial discharge: country roster equals the cohort");
    // A failed receipt for the whole request puts every head back.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 40;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 40");
    }
    bool failed_receipt = false;
    for (int32_t k = 0; k < 8 && !failed_receipt; ++k) {
        sim.last.clear();
        sim.receipts.clear();
        sim.dg.day = sim.day;
        ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
                 "partial discharge: second step_day");
        ++sim.day;
        for (const MilitaryIntent &in : sim.last) {
            if (in.kind != MILITARY_INTENT_DISCHARGE) continue;
            failed_receipt = true;
            MilitaryIntentReceipt r;
            r.kind = in.kind;
            r.ok = 0;
            r.cell = in.cell;
            r.source_id = in.source_id;
            r.committed_count = 0;
            sim.receipts.push_back(r);
        }
    }
    ST_CHECK(failed_receipt, "partial discharge: second discharge emitted");
    const int64_t before_fail = garrison_at(sim.core, C);
    int64_t failed_request = 0;
    for (const MilitaryIntentReceipt &r : sim.receipts)
        failed_request += (int64_t)((r.source_id >> 48) & 0xFFFFull);
    sim.last.clear();
    sim.dg.day = sim.day;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
             "partial discharge: failed receipt day");
    ++sim.day;
    ST_CHECK(failed_request > 0 && garrison_at(sim.core, C) == before_fail + failed_request,
             "partial discharge: a failed receipt refunds the whole request");
    return true;
}
#include "military_core_payroll_budget_selftest.inc"

// --- 10. AI agenda soak

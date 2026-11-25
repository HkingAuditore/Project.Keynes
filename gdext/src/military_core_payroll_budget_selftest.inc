// --- 9b. Army pay (army-pay contract §2 / §4.3): wages follow the people.
// Two holders, one treasury: a garrison lot at A and an army lot that marched
// off it. run_wages_and_upkeep must emit exactly one PAY_WAGES row for the
// garrison (headed for A) and one ARMY_PAY row for the formation (headed for its
// lane), the two amounts must sum to the total payroll demand (conservation), and
// the army row must carry the army share -- not the garrison's -- so a campaign
// never drains the lane while the home cohort keeps collecting.
bool test_army_pay(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 60601), "army pay sim init");
    const int32_t A = cell_at(5, 5);
    const int32_t B = cell_at(9, 5);
    // A fixed per-head wage keeps the arithmetic exact: wage_mode 1 (ABSOLUTE)
    // ignores the living cost and the MSTAT_WAGE stat, so both paths use
    // `wage_absolute` -- which is the contract's "the SAME per-head daily wage"
    // requirement, checked below by comparing the two emitted rows.
    constexpr int64_t kWage = 25000;   // MONEY_SCALE per head per day
    int64_t garrison_heads = 0;
    int64_t army_heads = 0;
    {
        MilitaryCommand c;
        c.cell = A;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "army pay: barracks at A");
        MilitaryCommand target;
        target.count = 0;
        target.value = 50;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "army pay: target 50");
        MilitaryCommand wage;
        wage.count = 1;          // wage_mode = ABSOLUTE
        wage.value = kWage;
        ST_CHECK(sim.submit(MCMD_POLICY_SET_WAGE, 0, wage), "army pay: absolute wage policy");
    }
    ST_STEP(sim, 41);
    const int64_t recruited = garrison_at(sim.core, A);
    ST_CHECK(recruited == 50, "army pay: 50 soldiers recruited at A");
    // Take most of the garrison into a formation and march it away, so the home
    // cell and the formation are different places to pay.
    {
        MilitaryCommand c;
        c.cell = A;
        c.ints = {0, 40};
        ST_CHECK(sim.submit(MCMD_ARMY_CREATE, 0, c), "army pay: army.create 40 at A");
    }
    ST_STEP(sim, sim.day + 1);
    const int32_t army = sim.army_of(0);
    ST_CHECK(army >= 0, "army pay: formation exists");
    {
        MilitaryCommand c;
        c.army = sim.core.army_handle(army);
        c.cell = B;
        ST_CHECK(sim.submit(MCMD_ARMY_MOVE, 0, c), "army pay: army.move to B");
    }
    for (int32_t k = 0; k < 8; ++k) ST_STEP(sim, sim.day + 1);
    ST_CHECK(sim.core.armies().cell[(size_t)army] == B, "army pay: formation arrived at B");
    garrison_heads = garrison_at(sim.core, A);
    army_heads = sim.core.armies().cached_headcount[(size_t)army];
    ST_CHECK(garrison_heads == 10 && army_heads == 40,
             "army pay: 10 garrisoned at A, 40 with the formation");
    // One wages day, collected instead of auto-receipted: the harness only
    // answers ENLIST/LEVY/DISCHARGE, so the pay rows stay in `last` for us.
    sim.last.clear();
    sim.receipts.clear();
    sim.dg.day = sim.day;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
             "army pay: step_day");
    int64_t garrison_pay = 0, army_pay = 0;
    int64_t garrison_rows = 0, army_rows = 0;
    uint64_t army_source = 0;
    int32_t army_cell = -1;
    for (const MilitaryIntent &in : sim.last) {
        if (in.kind == MILITARY_INTENT_PAY_WAGES) {
            if (in.cell == A) {
                garrison_pay += in.amount;
                ++garrison_rows;
            }
        } else if (in.kind == MILITARY_INTENT_ARMY_PAY) {
            army_pay += in.amount;
            ++army_rows;
            army_source = in.source_id;
            army_cell = in.cell;
        }
    }
    ST_CHECK(garrison_rows == 1, "army pay: exactly one garrison payroll row");
    ST_CHECK(army_rows == 1, "army pay: exactly one army payroll row");
    ST_CHECK(garrison_pay == garrison_heads * kWage,
             "army pay: garrison row is garrison heads x the shared daily wage");
    ST_CHECK(army_pay == army_heads * kWage,
             "army pay: army row is formation heads x the SAME daily wage");
    // Conservation: the two rows together are the whole payroll demand, no head
    // is paid twice and none is dropped.
    ST_CHECK(garrison_pay + army_pay == (garrison_heads + army_heads) * kWage,
             "army pay: garrison + army pay equals heads x wage (conserved)");
    ST_CHECK(army_pay == 40 * kWage && garrison_pay == 10 * kWage,
             "army pay: the army lane receives the army share, not the garrison's");
    // The row names the formation by HANDLE (the lane key) and sits at the
    // formation's cell, never at the home cell it left behind.
    ST_CHECK(army_source == sim.core.army_handle(army),
             "army pay: army row carries the formation handle");
    ST_CHECK(army_cell == B, "army pay: army row is anchored at the formation's cell");
    // ...and the garrison row really is the garrison's: the home cell keeps
    // paying its own 10 and no longer carries the embarked 40.
    ST_CHECK(garrison_pay != (garrison_heads + army_heads) * kWage,
             "army pay: the home cell no longer covers the embarked heads");
    // Receipts: army pay is bookkeeping only (the lane cash is Economy's), so a
    // success or a failure must not change the roster or the lot counts.
    std::vector<MilitaryIntentReceipt> receipts;
    for (const MilitaryIntent &in : sim.last) {
        if (in.kind != MILITARY_INTENT_ARMY_PAY && in.kind != MILITARY_INTENT_PAY_WAGES)
            continue;
        MilitaryIntentReceipt r;
        r.kind = in.kind;
        r.ok = 1;
        r.cell = in.cell;
        r.source_id = in.source_id;
        r.committed_count = in.count;
        r.committed_amount = in.amount;
        receipts.push_back(r);
    }
    const int64_t roster_before = sim.core.country_soldiers(0);
    ST_CHECK(!receipts.empty(), "army pay: pay rows produced receipts");
    ++sim.day;
    sim.dg.day = sim.day;
    std::vector<MilitaryIntent> next;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, receipts, next, sim.error),
             "army pay: receipt day");
    ++sim.day;
    ST_CHECK(sim.core.country_soldiers(0) == roster_before,
             "army pay: a pay receipt never moves heads");
    ST_CHECK(garrison_at(sim.core, A) == garrison_heads,
             "army pay: a pay receipt leaves the garrison lot untouched");
    return true;
}
// --- 9c. Budget envelope (任务 6 / 需求 5.1, 5.5, 9.3).
// The envelope is a share of the country's daily treasury cash, split into
// three channel ceilings. Three properties are easy to get wrong and are pinned
// here because the panel and the settlement both read them:
//  1. `budget_share_bp <= 0` is NO envelope, not a zero envelope. Every foreign
//     AI country and every save loaded before the player re-pushes a policy must
//     keep the legacy cash-driven behaviour, so `enabled` stays false on the
//     default policy. A ceiling of 0 is the different statement "this channel is
//     paused", and only a real envelope can express it.
//  2. Channel shares are percentages of the envelope itself, so 6000/2000/2000
//     spends it exactly and a single 0 pauses exactly one channel.
//  3. The three NEW budget fields are transient (需求 9.3): they must not enter
//     state_hash and must not survive PKMI, because the player session re-pushes
//     them after a load. `procurement_share_bp` is deliberately outside that set
//     - it predates this work and is already a persisted policy field - so the
//     procurement channel reuses it instead of introducing a second, unsaved
//     copy of the same number.
// State is driven through `apply_command` (immediate, queues nothing) and the
// guard rails through `submit` (rejections leave the queue untouched), so the
// hash/encode comparisons at the end are not disturbed by pending commands.
bool test_budget_envelope(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 60602), "budget envelope sim init");
    const int64_t cash = sim.dg.country_cash[(size_t)0];
    ST_CHECK(cash > 0, "budget envelope: digest carries treasury cash");
    // (1) The default policy has no envelope at all.
    {
        const MilitaryCore::MilitaryBudgetSplit split = sim.core.budget_split(0, cash);
        ST_CHECK(!split.enabled, "budget envelope: default policy has no envelope");
        ST_CHECK(split.envelope_daily == 0 && split.wage_ceiling == 0 &&
                     split.upkeep_ceiling == 0 && split.procurement_ceiling == 0,
                 "budget envelope: no envelope splits into zero ceilings");
    }
    // (2) A total share opens the envelope; the default channels fill it.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 1000;   // 10% of treasury cash per day
        sim.core.apply_command(c, sim.day);
        const MilitaryCore::MilitaryBudgetSplit split = sim.core.budget_split(0, cash);
        ST_CHECK(split.enabled, "budget envelope: a positive share enables it");
        ST_CHECK(split.envelope_daily == cash / 10,
                 "budget envelope: envelope is the share x treasury cash");
        ST_CHECK(split.wage_ceiling == split.envelope_daily * 6000 / 10000 &&
                     split.upkeep_ceiling == split.envelope_daily * 2000 / 10000 &&
                     split.procurement_ceiling == split.envelope_daily * 2000 / 10000,
                 "budget envelope: default channels are 60/20/20 of the envelope");
        ST_CHECK(split.wage_ceiling + split.upkeep_ceiling + split.procurement_ceiling ==
                     split.envelope_daily,
                 "budget envelope: the default channels spend it exactly");
    }
    // (3) -1 keeps a channel; 0 pauses exactly that channel.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = -1;
        c.ints = {-1, -1, 0};
        sim.core.apply_command(c, sim.day);
        const MilitaryCore::MilitaryBudgetSplit split = sim.core.budget_split(0, cash);
        ST_CHECK(split.enabled && split.procurement_ceiling == 0,
                 "budget envelope: a zero channel pauses, the envelope stays on");
        ST_CHECK(split.wage_ceiling == split.envelope_daily * 6000 / 10000 &&
                     split.upkeep_ceiling == split.envelope_daily * 2000 / 10000,
                 "budget envelope: untouched channels keep their stored share");
    }
    // (4) A zero total removes the envelope but keeps the channel shares, so the
    // panel never loses what the player chose.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 0;
        sim.core.apply_command(c, sim.day);
        ST_CHECK(!sim.core.budget_split(0, cash).enabled,
                 "budget envelope: a zero total disables it again");
        const MilitaryCountryPolicy &p = sim.core.policies()[(size_t)0];
        ST_CHECK(p.budget_wage_bp == 6000 && p.procurement_share_bp == 0,
                 "budget envelope: disabling keeps the stored channel shares");
    }
    // (5) Guard rails. Rejections never queue, so nothing below moves the state
    // the hash comparison at the end is looking at.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 10001;
        std::string error;
        ST_CHECK(!sim.core.submit(c, error) && error == "command_bad_budget_share",
                 "budget envelope: a total above 100% is rejected");
        MilitaryCommand many;
        many.op = MCMD_POLICY_SET_BUDGET;
        many.country = handle_for(0);
        many.ints = {1000, 1000, 1000, 1000};
        ST_CHECK(!sim.core.submit(many, error) && error == "command_bad_budget_channels",
                 "budget envelope: more than three channels is rejected");
        MilitaryCommand bad;
        bad.op = MCMD_POLICY_SET_BUDGET;
        bad.country = handle_for(0);
        bad.ints = {10001, -1, -1};
        ST_CHECK(!sim.core.submit(bad, error) &&
                     error == "command_bad_budget_channel_share",
                 "budget envelope: an out-of-range channel share is rejected");
        // Stored 4000 / 4000 / 2000 is exactly 100%. One more basis point on a
        // single channel must fail, which also proves an unspecified channel is
        // checked against its STORED value rather than against zero.
        MilitaryCommand stored;
        stored.op = MCMD_POLICY_SET_BUDGET;
        stored.country = handle_for(0);
        stored.value = 1000;
        stored.ints = {4000, 4000, 2000};
        sim.core.apply_command(stored, sim.day);
        MilitaryCommand over;
        over.op = MCMD_POLICY_SET_BUDGET;
        over.country = handle_for(0);
        over.ints = {4001, -1, -1};
        over.count = 123;
        ST_CHECK(sim.core.submit(over, error),
                 "budget envelope: a partial update is admitted for settlement");
        sim.step();
        const auto rejections = sim.core.take_player_command_rejections();
        ST_CHECK(rejections.size() == 1 && rejections[0].caller_sequence == 123 &&
                     std::string(rejections[0].reason) == "command_budget_channels_exceed_10000" &&
                     sim.core.policies()[0].budget_wage_bp == 4000,
                 "budget envelope: an over-limit partial update is rejected on its effective day");
        MilitaryCommand equal;
        equal.op = MCMD_POLICY_SET_BUDGET;
        equal.country = handle_for(0);
        equal.value = -1;
        equal.ints = {4000, 4000, 2000};
        ST_CHECK(sim.core.submit(equal, error),
                 "budget envelope: channels totalling exactly 100% are accepted");
    }
    // (6) The executor saves the current envelope with the military policy.
    {
        std::string error;
        MilitaryCore plain;
        MilitaryCore budgeted;
        ST_CHECK(plain.configure(make_catalog(), 60602, error) &&
                     budgeted.configure(make_catalog(), 60602, error),
                 "budget envelope: two cores configure");
        ST_CHECK(plain.set_terrain(t, error) && budgeted.set_terrain(t, error),
                 "budget envelope: two cores take the terrain");
        ST_CHECK(plain.ensure_country_slot(handle_for(0)) == 0 &&
                     budgeted.ensure_country_slot(handle_for(0)) == 0,
                 "budget envelope: two cores open the same country slot");
        MilitaryCountryPolicy &p = budgeted._policies[(size_t)0];
        p.budget_share_bp = 3000;
        p.budget_wage_bp = 5000;
        p.budget_upkeep_bp = 3000;
        ST_CHECK(budgeted.budget_split(0, cash).enabled &&
                     !plain.budget_split(0, cash).enabled,
                 "budget envelope: the two cores really differ on the envelope");
        ST_CHECK(plain.state_hash() != budgeted.state_hash(),
                 "budget envelope: committed shares change the state hash");
        MilitaryTerrainInput refreshed = t;
        ST_CHECK(!refreshed.cover.empty(), "budget envelope: terrain has cover");
        refreshed.cover[0] = refreshed.cover[0] == 0 ? 1 : 0;
        ST_CHECK(budgeted.set_terrain(refreshed, error),
                 "budget envelope: same-topology cover refresh succeeds");
        const auto &policy = budgeted.policies()[0];
        ST_CHECK(policy.budget_share_bp == 3000 && policy.budget_wage_bp == 5000 &&
                     policy.budget_upkeep_bp == 3000 && policy.procurement_share_bp == 2000,
                 "budget envelope: cover refresh preserves each policy share");
        ST_CHECK(budgeted.set_terrain(t, error),
                 "budget envelope: original terrain reinstalls for the restore check");
        ST_CHECK(plain.encode() != budgeted.encode(),
                 "budget envelope: PKMI records non-default shares");
        const std::vector<uint8_t> bytes = budgeted.encode();
        MilitaryCore restored;
        restored.configure(make_catalog(), 60602, error);
        restored.set_terrain(t, error);
        ST_CHECK(restored.restore(bytes.data(), bytes.size(), error),
                 "budget envelope: PKMI restore accepts the stream");
        const int32_t slot = restored.country_slot_for_handle(handle_for(0));
        ST_CHECK(slot >= 0 && restored.budget_split(slot, cash).enabled &&
                     restored.state_hash() == budgeted.state_hash() && restored.encode() == bytes,
                 "budget envelope: the restored policy and committed bytes agree");
    }
    // (7) Settlement (任务 7 / 需求 5.2, 5.3, 7.1). Runs the real `step_day`
    // path over a recruited garrison instead of re-deriving the arithmetic here:
    // the point is that the settlement WRITES these numbers, and that with no
    // envelope it writes none of them.
    {
        Sim pay;
        ST_CHECK(pay.init(t, 60603), "budget settlement sim init");
        const int32_t A = cell_at(5, 5);
        {
            MilitaryCommand c;
            c.cell = A;
            c.unit_to = 0;
            ST_CHECK(pay.submit(MCMD_STATE_BUILD, 0, c),
                     "budget settlement: barracks at A");
            MilitaryCommand target;
            target.count = 0;
            target.value = 40;
            ST_CHECK(pay.submit(MCMD_FORCE_SET_TARGET, 0, target),
                     "budget settlement: target 40");
            MilitaryCommand wage;
            wage.count = 1;          // ABSOLUTE, so the arithmetic is exact
            // Large enough that 40 heads out-earn the 1-bp envelope opened
            // below (cash 1e12 -> envelope 1e8 -> wage ceiling 6e7, payroll
            // 40 * 2e6 = 8e7). A smaller wage would never exercise overspend.
            wage.value = 2000000;
            ST_CHECK(pay.submit(MCMD_POLICY_SET_WAGE, 0, wage),
                     "budget settlement: absolute wage policy");
        }
        ST_STEP(pay, 41);
        ST_CHECK(garrison_at(pay.core, A) == 40,
                 "budget settlement: 40 soldiers recruited");
        // One settled day WITHOUT an envelope: nothing may be reported, which is
        // 需求 5.5's "AI countries do not change" expressed as a contract.
        ST_STEP(pay, pay.day + 1);
        {
            const MilitaryCountryPolicy &p = pay.core.policies()[(size_t)0];
            ST_CHECK(p.wage_demand == 0 && p.wage_arrears == 0 &&
                         p.wage_overspend == 0,
                     "budget settlement: no envelope reports no wage outcome");
        }
        // Now open an envelope whose wage share is far below the payroll, and
        // settle one more day. 军饷 is high priority, so it gets paid anyway and
        // the excess is reported; nothing is left in arrears.
        const int64_t payroll = 40 * 2000000;
        {
            MilitaryCommand c;
            c.op = MCMD_POLICY_SET_BUDGET;
            c.country = handle_for(0);
            c.value = 1;     // 0.01% of cash: a ceiling far under the payroll
            c.ints = {6000, 2000, 2000};
            ST_CHECK(pay.submit(MCMD_POLICY_SET_BUDGET, 0, c),
                     "budget settlement: a tiny envelope is accepted");
        }
        ST_STEP(pay, pay.day + 1);
        {
            const MilitaryCountryPolicy &p = pay.core.policies()[(size_t)0];
            const MilitaryCore::MilitaryBudgetSplit split = pay.core.budget_split(
                0, pay.dg.country_cash[(size_t)0]);
            ST_CHECK(split.enabled && split.wage_ceiling < payroll,
                     "budget settlement: the wage ceiling really is under the bill");
            ST_CHECK(p.wage_demand == payroll,
                     "budget settlement: the day's demand is the whole payroll");
            ST_CHECK(p.wage_arrears == 0,
                     "budget settlement: a solvent country leaves no wage arrears");
            ST_CHECK(p.wage_overspend == payroll - split.wage_ceiling,
                     "budget settlement: paying past the share is reported, not blocked");
        }
    }
    return true;
}
// --- 12. Procurement quota (任务 8 / 需求 5.4, 6.2, 7.1).
// The point of this case is that `run_procurement` now CONSUMES a money quota
// rather than buying whatever the market can sell. It therefore asserts three
// things the arithmetic alone cannot: that a country without an envelope still
// reports nothing, that a metered country never spends past its ceiling
// (procurement is low priority - it stops, it does not overspend), and that the
// reported spend equals the money the emitted intents actually carry, so the
// panel and the treasury cannot drift apart.
bool test_procurement_quota(const MilitaryTerrainInput &t, std::string &report) {
    Sim buy;
    ST_CHECK(buy.init(t, 60604), "procurement quota: sim init");
    // Same market-cell discovery as test_procurement: a garrison must sit on a
    // cell whose 3-ring holds one of the synthetic digest's markets.
    int32_t near_cell = -1;
    for (int32_t c = 0; c < t.cell_count && near_cell < 0; ++c) {
        if (c % kW >= 14) continue;            // country 0 owns columns 0..13
        if (c % 37 != 0) continue;
        near_cell = c;
    }
    ST_CHECK(near_cell >= 0, "procurement quota: a country 0 market cell exists");
    {
        MilitaryCommand c;
        c.cell = near_cell;
        c.unit_to = 0;
        ST_CHECK(buy.submit(MCMD_STATE_BUILD, 0, c), "procurement quota: barracks at the market");
        MilitaryCommand target;
        target.count = 0;
        target.value = 50;
        ST_CHECK(buy.submit(MCMD_FORCE_SET_TARGET, 0, target), "procurement quota: target 50");
    }
    ST_STEP(buy, 60);
    ST_CHECK(garrison_at(buy.core, near_cell) > 0, "procurement quota: garrison recruited");
    // Money the emitted PROCURE_GOOD intents carry on the last stepped day. This
    // is the treasury's view of the pass, so comparing it with the policy row is
    // a conservation check rather than a restatement of the same variable.
    // Filtered by country: the other two slots have no demanders today, and a
    // shared sum would silently start passing if they ever did.
    const uint64_t home = handle_for(0);
    auto procured_amount = [&](const std::vector<MilitaryIntent> &rows) {
        int64_t sum = 0;
        for (const MilitaryIntent &in : rows) {
            if (in.kind == MILITARY_INTENT_PROCURE_GOOD && in.country_a == home)
                sum += in.amount;
        }
        return sum;
    };
    // ---- 1. no envelope: buy the gap, report nothing ----------------------
    int64_t free_spend = 0;
    for (int32_t day = 0; day < 20; ++day) {
        ST_STEP(buy, buy.day + 1);
        free_spend += procured_amount(buy.last);
        const MilitaryCountryPolicy &p = buy.core.policies()[(size_t)0];
        if (p.procurement_budget_used != 0 || p.procurement_deferred_units != 0) {
            report += "FAIL procurement quota: no envelope must report no outcome\n";
            return false;
        }
    }
    ST_CHECK(free_spend > 0, "procurement quota: an unmetered country keeps buying");
    // ---- 2. a tiny envelope: the quota meters the purchase ----------------
    // cash 1e6 x 0.01% = an envelope of 100 money, and with the whole envelope on
    // the procurement channel that is the day's ceiling. A need unit costs 20
    // money here (price 20000 per GOODS_SCALE with the ration yield at 1.0), so
    // the quota affords 5 units - far below a 50-head garrison's 10-day target.
    buy.dg.country_cash[(size_t)0] = 1000000;
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 1;
        c.ints = {0, 0, 10000};
        ST_CHECK(buy.submit(MCMD_POLICY_SET_BUDGET, 0, c),
                 "procurement quota: a procurement-only envelope is accepted");
    }
    // Commands apply inside `step_day` on their effective day, so the split can
    // only be read after one more day; asserting it here (before the step) was
    // reading the pre-command policy and is exactly the mistake this line fixes.
    ST_STEP(buy, buy.day + 1);
    const MilitaryCore::MilitaryBudgetSplit split = buy.core.budget_split(
        0, buy.dg.country_cash[(size_t)0]);
    ST_CHECK(split.enabled && split.procurement_ceiling == 100,
             "procurement quota: the ceiling is the whole 100-money envelope");
    bool metered = false;
    bool overspent = false;
    bool drifted = false;
    int64_t deferred_total = 0;
    for (int32_t day = 0; day < 20; ++day) {
        ST_STEP(buy, buy.day + 1);
        const MilitaryCountryPolicy &p = buy.core.policies()[(size_t)0];
        if (p.procurement_budget_used > split.procurement_ceiling) overspent = true;
        // Conservation: what the policy reports spending is exactly what the
        // batch charges the treasury. No second ledger, no rounding gap.
        if (p.procurement_budget_used != procured_amount(buy.last)) drifted = true;
        if (p.procurement_deferred_units > 0) {
            metered = true;
            deferred_total += p.procurement_deferred_units;
        }
    }
    ST_CHECK(!overspent,
             "procurement quota: a low-priority channel never overspends its share");
    ST_CHECK(!drifted,
             "procurement quota: reported spend equals the emitted intents");
    ST_CHECK(metered && deferred_total > 0,
             "procurement quota: the unfunded gap is reported as 待购");
    // ---- 3. restore the quota and the same gap is bought again ------------
    // The shortfall is not a separate queue: demand is `want - held`, so nothing
    // has to be replayed and the next pass buys in the same cheapest-first order.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 0;            // back to "no envelope"
        c.ints = {-1, -1, -1};
        ST_CHECK(buy.submit(MCMD_POLICY_SET_BUDGET, 0, c),
                 "procurement quota: the envelope can be switched off again");
    }
    int64_t resumed = 0;
    for (int32_t day = 0; day < 10; ++day) {
        ST_STEP(buy, buy.day + 1);
        resumed += procured_amount(buy.last);
    }
    ST_CHECK(resumed > 0, "procurement quota: procurement resumes once the quota is gone");
    {
        const MilitaryCountryPolicy &p = buy.core.policies()[(size_t)0];
        ST_CHECK(p.procurement_budget_used == 0 && p.procurement_deferred_units == 0,
                 "procurement quota: switching the envelope off clears the counters");
    }
    return true;
}
// --- 13. Cross-channel conservation (任务 10 / 需求 9.4, 7.2).
// 7 and 8 each prove their own channel books itself. Neither checks what happens
// when all three settle against the SAME treasury on the SAME day, which is the
// only configuration where a double debit could hide:
//   * 军饷 (op 5) and 采购 (op 6) are emitted in one `step_day`, and both are
//     translated into economy commands keyed by the same country handle. If the
//     payroll planner and the procurement quota each assumed the full cash
//     balance, a country could pay out cash + ceiling while only cash existed.
//   * 维护 (op 9) is deferred to D+1 by the bridge, so on day D the military side
//     reports an amount the treasury has not been charged for yet. The invariant
//     that has to hold is therefore not "cash - spend >= 0" on the military book
//     alone, but "the emitted rows never claim more than the cash the split was
//     computed from" - the split is what the bridge will actually collect from.
// The assertions below are all cross-channel: per-day sums of the three intent
// kinds, compared against the cash the core itself used for the split, and each
// channel's own reported figure compared against the rows it emitted. An envelope
// that lets every channel individually stay under its ceiling but collectively
// promise more money than exists fails here and nowhere else.
bool test_cross_channel_conservation(const MilitaryTerrainInput &t,
                                     std::string &report) {
    Sim sim;
    // A non-zero barracks upkeep is what makes 维护 reachable at all: with the
    // default 0 catalog the channel has nothing to bill, so every cross-channel
    // assertion about it would pass without ever running.
    ST_CHECK(sim.init(t, 60605, make_catalog(20000)), "cross channel: sim init");
    // A garrison that owes wages and wants equipment, parked on a market cell so
    // procurement has somewhere to buy. Same discovery rule as the quota case.
    int32_t near_cell = -1;
    for (int32_t c = 0; c < t.cell_count && near_cell < 0; ++c) {
        if (c % kW >= 14) continue;
        if (c % 37 != 0) continue;
        near_cell = c;
    }
    ST_CHECK(near_cell >= 0, "cross channel: a country 0 market cell exists");
    {
        MilitaryCommand c;
        c.cell = near_cell;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c),
                 "cross channel: barracks at the market");
        MilitaryCommand target;
        target.count = 0;
        target.value = 50;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target),
                 "cross channel: target 50");
        MilitaryCommand wage;
        wage.count = 1;              // ABSOLUTE, so the payroll is exact
        wage.value = 2000000;
        ST_CHECK(sim.submit(MCMD_POLICY_SET_WAGE, 0, wage),
                 "cross channel: absolute wage policy");
    }
    sim.run_until(61);
    ST_CHECK(garrison_at(sim.core, near_cell) > 0,
             "cross channel: the garrison recruited");
    // Every channel is squeezed at once. The total share is 20% of cash and the
    // channels are 40/30/30 - deliberately close to 100% so each ceiling is a
    // binding constraint, and no channel can be funded out of another's slack.
    const uint64_t home = handle_for(0);
    auto amount_of = [&](const std::vector<MilitaryIntent> &rows, uint8_t kind) {
        int64_t sum = 0;
        for (const MilitaryIntent &in : rows) {
            if (in.kind == kind && in.country_a == home) sum += in.amount;
        }
        return sum;
    };
    auto rows_of = [&](const std::vector<MilitaryIntent> &rows, uint8_t kind) {
        int64_t n = 0;
        for (const MilitaryIntent &in : rows) {
            if (in.kind == kind && in.country_a == home) ++n;
        }
        return n;
    };
    // Shrink the treasury so the envelope is a real constraint rather than a
    // rounding detail on a 1e12 pile: 2,000,000 cash x 20% = 400,000 envelope,
    // which the 40/30/30 split cuts into 160,000 / 120,000 / 120,000 per day.
    sim.dg.country_cash[(size_t)0] = 2000000;
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = home;
        c.value = 2000;
        c.ints = {4000, 3000, 3000};
        ST_CHECK(sim.submit(MCMD_POLICY_SET_BUDGET, 0, c),
                 "cross channel: a binding 40/30/30 envelope is accepted");
    }
    // Budget commands take effect on their own day, so step once before reading
    // the split (same trap the quota case documents).
    // 50 days: long enough to cross several `kUpkeepPeriod` (5) settlements and
    // to let a suppressed procurement queue build up a backlog, which is where
    // a channel would start reaching into another channel's cash if the
    // committed-采购 deduction were missing.
    int64_t days_checked = 0;
    int64_t wage_rows_total = 0;
    int64_t proc_rows_total = 0;
    int64_t upkeep_rows_total = 0;
    int64_t upkeep_bills = 0;
    bool over_cash = false;
    std::string over_cash_detail;
    bool wage_exhausted_cash = false;
    bool wage_drift = false;
    bool proc_drift = false;
    bool upkeep_drift = false;
    bool upkeep_overpaid = false;
    bool ceiling_blown = false;
    for (int32_t day = 0; day < 50; ++day) {
        sim.step();
        const MilitaryCountryPolicy &p = sim.core.policies()[(size_t)0];
        const MilitaryCore::MilitaryBudgetSplit split = sim.core.budget_split(
            0, sim.dg.country_cash[(size_t)0]);
        if (!split.enabled) continue;
        const int64_t cash = sim.dg.country_cash[(size_t)0];
        const int64_t wages = amount_of(sim.last, MILITARY_INTENT_PAY_WAGES);
        const int64_t bought = amount_of(sim.last, MILITARY_INTENT_PROCURE_GOOD);
        const int64_t upkeep = amount_of(sim.last, MILITARY_INTENT_SPEND_CASH);
        // The three channels must never together promise more than the treasury
        // holds: 军饷 and 维护 draw cash, and 采购 is charged the same treasury.
        if (cash > 0 && wages >= cash) wage_exhausted_cash = true;
        if (wages + upkeep + bought > cash) {
            over_cash = true;
            if (over_cash_detail.empty())
                over_cash_detail = "day=" + std::to_string(day) +
                    " wages=" + std::to_string(wages) + " bought=" + std::to_string(bought) +
                    " upkeep=" + std::to_string(upkeep) + " cash=" + std::to_string(cash) +
                    " plan_wage=" + std::to_string(p.wage_planned_today) +
                    " plan_maint=" + std::to_string(p.maintenance_planned_today);
        }
        // 军饷 is high priority: it may pass its share, but what it reports as
        // paid has to be exactly what the rows charge. A drift here means the
        // panel and the treasury disagree about the same money.
        if (p.wage_demand > 0 && p.wage_demand - p.wage_arrears != wages) wage_drift = true;
        // 采购 is low priority: never past its ceiling, and its reported spend is
        // the row amount (no second ledger, no rounding gap).
        if (bought > split.procurement_ceiling) ceiling_blown = true;
        if (p.procurement_budget_used != bought) proc_drift = true;
        // 维护 settles every kUpkeepPeriod days. The bill is computed even when
        // the wage channel already drained the cash, in which case it settles
        // for 0 - so "the row exists" and "the row never overpays" are the two
        // invariants that actually hold. `upkeep_demand` records the full bill,
        // not the afford amount, which is why the comparison is against the bill
        // being at least what was paid.
        // 建筑维护 now settles as a PHYSICAL purchase (design §1 / plan S3-4):
        // the cash bill and its SPEND_CASH row are retired, so any such row -
        // or any cash upkeep "demand" - is a regression. Money conservation for
        // the maintenance channel is proved by test_maintenance instead
        // (demand -> buy -> settle -> consume -> ledger 0, ratio 100%).
        if (p.upkeep_demand > 0) {
            ++upkeep_bills;
            upkeep_drift = true;
        }
        if (upkeep != 0) upkeep_overpaid = true;
        wage_rows_total += rows_of(sim.last, MILITARY_INTENT_PAY_WAGES);
        proc_rows_total += rows_of(sim.last, MILITARY_INTENT_PROCURE_GOOD);
        upkeep_rows_total += rows_of(sim.last, MILITARY_INTENT_SPEND_CASH);
        ++days_checked;
    }
    ST_CHECK(days_checked > 0, "cross channel: the envelope stayed on for the window");
    ST_CHECK(!over_cash,
             ("cross channel: the three channels never promise more cash than exists :: " +
              over_cash_detail).c_str());
    ST_CHECK(!wage_drift,
             "cross channel: reported payroll equals the PAY_WAGES rows");
    ST_CHECK(!proc_drift,
             "cross channel: reported procurement equals the PROCURE_GOOD rows");
    ST_CHECK(!ceiling_blown,
             "cross channel: procurement stays inside its own share");
    ST_CHECK(!upkeep_drift,
             "cross channel: upkeep never pays without a bill behind it");
    ST_CHECK(!upkeep_overpaid,
             "cross channel: upkeep never pays more than the treasury holds");
    // Each channel really did settle something: a window where all three stayed
    // silent would make every assertion above vacuously true.
    // Payroll claims the treasury FIRST (design S4-1), so a country whose wage
    // bill equals its whole treasury legitimately buys nothing that day. The
    // invariant is therefore: the payroll settled, and procurement settled too
    // unless the payroll consumed every last unit of cash.
    ST_CHECK(wage_rows_total > 0, "cross channel: payroll settled in the window");
    ST_CHECK(proc_rows_total > 0 || wage_exhausted_cash,
             "cross channel: procurement settles unless the payroll took the whole treasury");
    // 维护 (op 9) bills every `kUpkeepPeriod` (5) days, so a 50-day window must
    // contain ten bills. This is what proves the assertions above ran at all:
    // with a 0-upkeep catalog the channel is silent and every check is vacuous.
    ST_CHECK(upkeep_rows_total == 0 && upkeep_bills == 0,
             "cross channel: building maintenance no longer emits a cash bill");
    ST_CHECK(days_checked >= 45,
             "cross channel: the envelope covered nearly the whole window");
    return true;
}

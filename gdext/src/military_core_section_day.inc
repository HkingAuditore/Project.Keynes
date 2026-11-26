namespace {

double g_stage_ms[MILITARY_STAGE_COUNT] = {};

double now_ms(const std::chrono::steady_clock::time_point &start) {
    const auto end = std::chrono::steady_clock::now();
    return (double)std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count() / 1000000.0;
}

} // namespace

const double *military_stage_ms() { return g_stage_ms; }

const char *military_stage_name(int32_t stage) {
    static const char *kNames[MILITARY_STAGE_COUNT] = {
        "commands", "force_targets", "supply_fields", "threat_fields", "recruitment", "training", "reinforcement",
        "movement", "area_missions", "engagements", "wars", "procurement", "convoys", "consumption", "requisition",
        "morale_org", "wages", "reparations", "ai", "ledger_report"};
    return (stage >= 0 && stage < MILITARY_STAGE_COUNT) ? kNames[stage] : "?";
}

bool MilitaryCore::step_day(int64_t day, const MilitaryWorldDigest &digest,
                            const std::vector<MilitaryIntentReceipt> &receipts,
                            std::vector<MilitaryIntent> &intents, std::string &error) {
    error.clear();
    if (!_configured) {
        error = "military_not_configured";
        return false;
    }
    const auto start = std::chrono::steady_clock::now();
    _last_day = day;
    _report = MilitaryReport();
    _report.day = day;
    MilitaryWorldDigest view = digest;
    normalize_digest(_terrain, view);

    const size_t cells = (size_t)std::max(0, _terrain.cell_count);
    if (_cell_head.size() < cells) {
        _cell_head.resize(cells, -1);
        _cell_engagement_mask.resize(cells, 0);
        _front_edge_set.assign(cells * 6, 0);
        _front_edge_pos.clear();
        _threat.assign(cells, 0);
        _guard.assign(cells, 0);
        _threat_stamp.assign(cells, 0);
        _dij_dist.resize(cells, 0);
        _dij_parent.resize(cells, -1);
        _dij_stamp.assign(cells, 0);
        _cell_controller.resize(cells, -1);
        rebuild_cell_index();
    }
    if ((size_t)_path_daily_requests.size() < _policies.size()) {
        _path_daily_requests.resize(_policies.size(), 0);
    }
    for (int32_t &n : _path_daily_requests) n = 0;
    if ((size_t)_exploration_daily_path_requests.size() < _policies.size()) {
        _exploration_daily_path_requests.resize(_policies.size(), 0);
    }
    for (int32_t &n : _exploration_daily_path_requests) n = 0;

    const size_t intents_before = intents.size();
    _attrition_intents.clear();
    // Mirror the committed view for cold queries and the AI agenda.
    _last_digest = view;
    // The state building cache is a derived read of the economy ledger, so it
    // is rebuilt before anything downstream (posts, upkeep, training speed,
    // fortification strength, the AI's barracks planner) consults it
    // (requirement 6.1-6.4).
    refresh_state_building_cache(view);
    _country_annual_revenue.assign(view.country_annual_revenue.begin(), view.country_annual_revenue.end());
    _country_era.assign(view.country_era.begin(), view.country_era.end());
    _cell_owner_dirty.assign((size_t)view.cell_owner_slot.size(), 0);
    double *stage = g_stage_ms;
    for (int32_t i = 0; i < MILITARY_STAGE_COUNT; ++i) stage[i] = 0.0;
    auto mark = std::chrono::steady_clock::now();
    auto lap = [&](int32_t idx) {
        const auto t = std::chrono::steady_clock::now();
        stage[idx] += (double)std::chrono::duration_cast<std::chrono::nanoseconds>(t - mark).count() / 1e6;
        mark = t;
    };
    // Reconcile against the committed Economy view before applying today's
    // commands.  In particular, an army.create must board the post-reconcile
    // garrison lots after natural Economy-side deaths have been observed.
    reconcile_receipts(receipts);
    reconcile_soldier_roster(view);
    apply_due_commands(day);    for (MilitaryCellState &st : _cell_states) for (int32_t k = 0; k < 3; ++k) {   // A3: finish state builds
        const int32_t b = st.construction_building[k];
        if (b < 0 || st.construction_done_day[k] > day || (size_t)b >= _catalog.state_buildings.size()) continue;
        // No cache increment: the economy ledger owns the count (requirement
        // 6.1/6.5) and the next `refresh_state_building_cache` reads the
        // finished lot back. This pass only expires the local schedule slot,
        // which is a cache of the economy's completion day - the economy also
        // applies the country construction time factor this local sum cannot
        // see, so booking anything here would double count.
        st.construction_building[k] = -1; st.construction_done_day[k] = -1;
    }
    // Army personnel lane rows queued by today's command application (create /
    // station / disband / merge) join the same D+1 batch as every other intent.
    for (const MilitaryIntent &row : _lane_intents) intents.push_back(row);
    _lane_intents.clear();
    lap(0);
    update_force_targets(view);
    lap(1);
    // Supply fields: daily logistics indexes are built by the logistics pass
    // (design 9.3) inside build_threat_fields' shared prep step; the old
    // nationwide nearest-market field no longer exists.
    lap(2);
    build_threat_fields(view);
    lap(3);
    run_recruitment(view, intents);
    lap(4);
    run_training(view);
    lap(5);
    run_reinforcement(view);
    lap(6);
    // Exploration plans after today's commands land and before movement, using
    // the frozen explored snapshot the host pushed on the day boundary.
    prepare_exploration_day(view);
    run_movement(view);
    lap(7);
    // Soldier losses from harsh-environment attrition drain into the batch.
    for (const MilitaryIntent &row : _attrition_intents) intents.push_back(row);
    _attrition_intents.clear();
    // State building requests become economy construction orders in the bridge.
    // `MCMD_STATE_BUILD` no longer settles anything itself, so a request that
    // the treasury cannot pay for simply never turns into a lot.
    for (const StateBuildRequest &request : _build_requests) {
        if (request.country == 0 || request.cell < 0 || request.building < 0) continue;
        MilitaryIntent intent;
        intent.kind = MILITARY_INTENT_STATE_BUILD;
        intent.cell = request.cell;
        intent.country_a = request.country;
        intent.count = request.building;
        intent.source_id = 0x5354415445ull;   // "STATE"
        intents.push_back(intent);
    }
    _build_requests.clear();
    run_area_missions(view);
    lap(8);
    run_engagements(view, intents);
    lap(9);
    run_wars_prepared(view, intents);
    // Battles can open or close; resume only tasks whose army is no longer
    // engaged. The next day's prepare revalidates every route.
    settle_exploration_day();
    lap(10);
    // Order matters (design S4-1): payroll claims cash first, then the
    // maintenance channel, then general procurement. All three clip against the
    // same frozen treasury snapshot, so emitting payroll first is what makes the
    // D+1 batch fund the soldiers before it funds goods.
    {
        MilitaryMarketDayReuse market_reuse(*this, view);
        run_wages_and_upkeep(view, intents);
        run_maintenance(view, intents);
        run_procurement(view, intents);
        lap(11);
        run_convoys(view, intents);
        lap(12);
        run_consumption(view, intents);
        lap(13);
        run_requisition(view, intents);
    } // Return parked capacities and end the borrowed view before later passes.
    lap(14);
    update_morale_org(view);
    lap(15);
    // Payroll already ran at the top of the day (design S4-1); the lap stays so
    // the stage index/name table keeps its shape for the perf log.
    lap(16);
    run_reparations(view, intents);
    lap(17);
    if (ai_decision_due(day)) run_country_ai(view);
    lap(18);

    if (cells > 0) _control_revision += 0;   // bumped by whoever mutates control
    _report.intents_emitted = (int32_t)(intents.size() - intents_before);
    _report.armies_active = 0;
    _report.armies_moving = 0;
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        ++_report.armies_active;
        if (_armies.mission[(size_t)slot] == (uint8_t)MILITARY_MISSION_MOVE ||
            _armies.path_cursor[(size_t)slot] < _armies.path_len[(size_t)slot]) {
            ++_report.armies_moving;
        }
    }
    _report.engagements_active = 0;
    for (const MilitaryEngagement &e : _engagements) {
        if (e.active) ++_report.engagements_active;
    }
    _report.wars_active = 0;
    for (const MilitaryWar &w : _wars) {
        if (w.active) ++_report.wars_active;
    }
    int64_t soldiers = 0;
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i]) soldiers += _lots.count[i];
    }
    _report.soldiers_total = soldiers;
    reconcile_ledger();   // A3: report.reconcile_delta is the sec 9.7 goods residual
    lap(19);
    _report.day_ms = now_ms(start);
    _report.idle = (_report.armies_moving == 0 && _report.engagements_active == 0 &&
                    _report.wars_active == 0 && _report.intents_emitted == 0)
                       ? 1
                       : 0;
    return true;
}

bool MilitaryCore::ai_decision_due(int64_t day) const {
    const size_t n = _ai_country.size();
    for (size_t i = 0; i < n; ++i) {
        if (!_ai_country[i]) continue;
        const int64_t next = i < _ai_next_decision_day.size() ? _ai_next_decision_day[i] : 0;
        if (day >= next) return true;
    }
    return false;
}

bool MilitaryCore::should_run(int64_t day) const {
    if (!_configured) return false;
    if (std::any_of(_pending.begin(), _pending.end(), [day](const MilitaryCommand &command) {
        return command.effective_day <= day;
    })) return true;
    // Physical maintenance (design S3/S4): a country whose only work is keeping
    // its buildings repaired, or waiting on a paid purchase, must still step -
    // otherwise the maintenance pass never runs and the orders never settle.
    if (!_maint_rows.empty() || !_purchase_orders.empty()) return true;
    if (has_exploration_work(day)) return true;
    const bool upkeep_day = (day % kUpkeepPeriod) == 0;
    const bool recruit_day = (day % kRecruitCheckPeriod) == 0;
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        if (_armies.cached_headcount[(size_t)slot] > 0) return true;
        if (_armies.mission[(size_t)slot] != (uint8_t)MILITARY_MISSION_NONE) return true;
        if (_armies.path_cursor[(size_t)slot] < _armies.path_len[(size_t)slot]) return true;
    }
    for (const MilitaryEngagement &e : _engagements) {
        if (e.active) return true;
    }
    for (const MilitaryWar &w : _wars) {
        if (w.active) return true;
    }
    for (const MilitaryShipment &sh : _shipments) {
        if (sh.qty > 0) return true;
    }
    for (const MilitaryTrainingOrder &o : _training) {
        if (o.count > 0) return true;
    }
    for (const MilitaryReparation &r : _reparations) {
        if (r.remaining > 0) return true;
    }
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i] && _lots.count[i] > 0) return true;
    }
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        if (_policy_handle[slot] == 0) continue;
        const MilitaryCountryPolicy &p = _policies[slot];
        if (p.effective_target > 0 || p.target_value > 0) return true;
        if (recruit_day) return true;
        if (upkeep_day && !_cell_states.empty()) return true;
    }
    if (ai_decision_due(day)) return true;
    return false;
}

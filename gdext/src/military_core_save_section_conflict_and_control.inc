            case kSection_Engagements: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_engagements";
                    return false;
                }
                tmp._engagements.clear();
                tmp._engagements.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryEngagement e;
                    e.cell_a = r.i32();
                    e.cell_b = r.i32();
                    e.attacker_side_cell = r.i32();
                    e.attacker_slot = r.i32();
                    e.defender_slot = r.i32();
                    e.war_id = r.i32();
                    e.progress_q16 = r.i32();
                    e.start_day = r.i64();
                    e.idle_days = r.i32();
                    e.days_since_battle = r.i32();
                    e.casualties_attacker = r.i64();
                    e.casualties_defender = r.i64();
                    e.active = r.u8();
                    if (!r.ok()) break;
                    tmp._engagements.push_back(e);
                }
                break;
            }
            case kSection_Wars: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_wars";
                    return false;
                }
                tmp._wars.clear();
                tmp._wars.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryWar x;
                    x.id = r.i32();
                    x.attacker_slot = r.i32();
                    x.defender_slot = r.i32();
                    x.attacker_handle = r.u64();
                    x.defender_handle = r.u64();
                    x.start_day = r.i64();
                    x.score_battle_q16 = r.i32();
                    x.score_annihilation_q16 = r.i32();
                    x.score_attrition_q16 = r.i32();
                    x.attacker_losses = r.i64();
                    x.defender_losses = r.i64();
                    x.last_rejected_offer_day_a = r.i64();
                    x.last_rejected_offer_day_b = r.i64();
                    x.fully_occupied_since_a = r.i64();
                    x.fully_occupied_since_b = r.i64();
                    x.active = r.u8();
                    if (!r.ok()) break;
                    tmp._wars.push_back(x);
                }
                break;
            }
            case kSection_Truces: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_truces";
                    return false;
                }
                tmp._truces.clear();
                tmp._truces.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryTruce t;
                    t.slot_a = r.i32();
                    t.slot_b = r.i32();
                    t.until_day = r.i64();
                    if (!r.ok()) break;
                    tmp._truces.push_back(t);
                }
                break;
            }
            case kSection_Reparations: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_reparations";
                    return false;
                }
                tmp._reparations.clear();
                tmp._reparations.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryReparation x;
                    x.payer = r.u64();
                    x.receiver = r.u64();
                    x.installment = r.i64();
                    x.remaining = r.i32();
                    x.next_day = r.i64();
                    x.arrears = r.i64();
                    x.war_id = r.i32();
                    if (!r.ok()) break;
                    tmp._reparations.push_back(x);
                }
                break;
            }
            case kSection_BattleLog: {
                const uint32_t n = r.u32();
                if (n > (uint32_t)MILITARY_BATTLE_LOG_CAPACITY) {
                    error = "pkmi_bad_battle_log";
                    return false;
                }
                tmp._battle_log.clear();
                tmp._battle_log.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryBattleLogRow b;
                    b.day = r.i64();
                    b.cell = r.i32();
                    b.war_id = r.i32();
                    b.winner_slot = r.i32();
                    b.loser_slot = r.i32();
                    b.winner_losses = r.i64();
                    b.loser_losses = r.i64();
                    b.score_gain_q16 = r.i32();
                    if (!r.ok()) break;
                    tmp._battle_log.push_back(b);
                }
                break;
            }
            case kSection_Areas: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_areas";
                    return false;
                }
                tmp._areas.clear();
                tmp._areas.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryArea a;
                    a.id = r.i32();
                    a.owner_slot = r.i32();
                    a.last_eval_day = r.i64();
                    a.active = r.u8();
                    const uint32_t m = r.u32();
                    if (m > (uint32_t)MILITARY_MAX_AREA_CELLS) {
                        error = "pkmi_bad_area_cells";
                        return false;
                    }
                    a.cells.resize(m);
                    for (uint32_t k = 0; k < m; ++k) a.cells[k] = r.i32();
                    if (!r.ok()) break;
                    std::sort(a.cells.begin(), a.cells.end());
                    tmp._areas.push_back(std::move(a));
                }
                break;
            }
            case kSection_Policies: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_policies";
                    return false;
                }
                tmp._policies.clear();
                tmp._policy_handle.clear();
                tmp._policies.resize(n);
                tmp._policy_handle.assign(n, 0);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryCountryPolicy &p = tmp._policies[i];
                    tmp._policy_handle[i] = r.u64();
                    p.target_mode = r.u8();
                    p.target_value = r.i64();
                    p.effective_target = r.i64();
                    p.levy_enabled = r.u8();
                    p.auto_retrain = r.u8();
                    p.auto_discharge = r.u8();
                    p.quality_policy = r.u8();
                    p.wage_mode = r.u8();
                    p.wage_absolute = r.i64();
                    p.procurement_share_bp = r.i32();
                    p.pay_ratio_30_q16 = r.i32();
                    p.spend_payroll_30 = r.i64();
                    p.spend_procurement_30 = r.i64();
                    p.spend_upkeep_30 = r.i64();
                    p.per_soldier_cost = r.i64();
                    const uint32_t m = r.u32();
                    if (m > (uint32_t)MILITARY_MAX_UNIT_TYPES) {
                        error = "pkmi_bad_policy_shares";
                        return false;
                    }
                    p.config_share_bp.assign(m, 0);
                    for (uint32_t k = 0; k < m; ++k) p.config_share_bp[k] = r.i32();
                    if (!r.ok()) break;
                }
                break;
            }
            case kSection_BudgetEnvelope: {
                if (r.section_remaining() < sizeof(uint32_t)) {
                    error = "pkmi_bad_budget_envelope";
                    return false;
                }
                const uint32_t n = r.u32();
                if (n != tmp._policies.size() || r.section_remaining() != n * 12ULL) {
                    error = "pkmi_bad_budget_envelope";
                    return false;
                }
                for (auto &policy : tmp._policies) {
                    policy.budget_share_bp = r.i32();
                    policy.budget_wage_bp = r.i32();
                    policy.budget_upkeep_bp = r.i32();
                    if (policy.budget_share_bp < 0 || policy.budget_share_bp > 10000 ||
                        policy.budget_wage_bp < 0 || policy.budget_wage_bp > 10000 ||
                        policy.budget_upkeep_bp < 0 || policy.budget_upkeep_bp > 10000) {
                        error = "pkmi_bad_budget_envelope";
                        return false;
                    }
                }
                break;
            }
            case kSection_CellStates: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_cell_states";
                    return false;
                }
                tmp._cell_states.clear();
                tmp._cell_states.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryCellState st;
                    st.cell = r.i32();
                    // Derived cache: restored verbatim for hash parity, then
                    // rebuilt from the economy ledger on the first step (see the
                    // writer above and `refresh_state_building_cache`).
                    for (int32_t t = 0; t < 8; ++t) st.barracks_count[t] = r.i32();
                    st.fort_tier = r.i32();
                    st.college_tier = r.i32();
                    st.paused = r.u8();
                    st.disrepair = r.u8();
                    st.pending_enlist = r.i64();
                    st.quota = r.i64();
                    st.requisition_until_day = r.i64();
                    for (int32_t k = 0; k < 3; ++k) {
                        st.construction_done_day[k] = r.i64();
                        st.construction_building[k] = r.i32();
                    }
                    if (!r.ok()) break;
                    if (st.cell < 0 || st.cell >= tmp._terrain.cell_count) {
                        error = "pkmi_bad_cell_state_cell";
                        return false;
                    }
                    tmp._cell_states.push_back(st);
                }
                std::sort(tmp._cell_states.begin(), tmp._cell_states.end(),
                          [](const MilitaryCellState &a, const MilitaryCellState &b) { return a.cell < b.cell; });
                break;
            }

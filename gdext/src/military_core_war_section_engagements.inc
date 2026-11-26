void MilitaryCore::open_engagement(int32_t from_cell, int32_t to_cell, int32_t attacker_slot,
                                   int32_t defender_slot) {
    if (from_cell < 0 || to_cell < 0) return;
    if (!army_live(_armies, attacker_slot)) return;
    if ((size_t)to_cell >= (size_t)_cell_head.size()) return;
    const int32_t a = std::min(from_cell, to_cell);
    const int32_t b = std::max(from_cell, to_cell);
    for (size_t i = 0; i < _engagements.size(); ++i) {
        MilitaryEngagement &e = _engagements[i];
        if (!e.active) continue;
        if (e.cell_a != a || e.cell_b != b) continue;
        if (_armies.engagement[(size_t)attacker_slot] < 0) {
            set_army_engagement(attacker_slot, (int32_t)i);
        }
        return;
    }
    MilitaryEngagement e;
    e.cell_a = a;
    e.cell_b = b;
    e.attacker_side_cell = from_cell;
    e.attacker_slot = attacker_slot;
    e.defender_slot = defender_slot;
    e.war_id = war_between(_armies.owner_slot[(size_t)attacker_slot], defender_slot);
    e.progress_q16 = 32768;
    e.start_day = _last_day;
    e.active = 1;
    _engagements.push_back(e);
    const int32_t index = (int32_t)_engagements.size() - 1;
    set_army_engagement(attacker_slot, index);
    for (int32_t other = _cell_head[(size_t)to_cell]; other >= 0;
         other = _armies.next_in_cell[(size_t)other]) {
        if (!_armies.active[(size_t)other]) continue;
        if (_armies.owner_slot[(size_t)other] != defender_slot) continue;
        if (_armies.engagement[(size_t)other] >= 0) continue;
        set_army_engagement(other, index);
    }
    update_front_cells({from_cell, to_cell});
}

void MilitaryCore::close_engagement(int32_t index) {
    if (index < 0 || (size_t)index >= _engagements.size()) return;
    if (!_engagements[(size_t)index].active) return;
    _engagements[(size_t)index].active = 0;
    ensure_engagement_members();
    while (_engagement_army_head[(size_t)index] >= 0) {
        const int32_t army = _engagement_army_head[(size_t)index];
        set_army_engagement(army, -1);
        ++_report.engagement_members_cleared;
    }
    update_front_cells({_engagements[(size_t)index].cell_a, _engagements[(size_t)index].cell_b});
}

// ------------------------------------------------------------ daily replay

void MilitaryCore::run_engagements(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    if (_engagements.empty()) return;
    const size_t army_count = _armies.active.size();
    if (_armies.engagement.size() != army_count) _armies.engagement.resize(army_count, -1);

    struct Plan {
        int32_t index = -1;
        int32_t delta_q16 = 0;
        int64_t losses_attacker = 0;
        int64_t losses_defender = 0;
        int32_t org_attacker = 0;
        int32_t org_defender = 0;
        uint8_t battle = 0;
        int32_t battle_delta_q16 = 0;
        int32_t battle_score_q16 = 0;
        int32_t winner_slot = -1;
        int32_t loser_slot = -1;
        int64_t winner_losses = 0;
        int64_t loser_losses = 0;
        int32_t defender_slot = -1;
        int32_t far_cell = -1;
        uint8_t attacker_no_disengage = 0;
    };

    std::vector<int32_t> order;
    order.reserve(_engagements.size());
    for (size_t i = 0; i < _engagements.size(); ++i) {
        if (_engagements[i].active) order.push_back((int32_t)i);
    }
    if (order.empty()) return;
    std::sort(order.begin(), order.end(), [this](int32_t lhs, int32_t rhs) {
        const MilitaryEngagement &a = _engagements[(size_t)lhs];
        const MilitaryEngagement &b = _engagements[(size_t)rhs];
        if (a.cell_a != b.cell_a) return a.cell_a < b.cell_a;
        return a.cell_b < b.cell_b;
    });

    // ---- Plan: pure reads, thread-safe, no shared mutation.
    // ---- Plan: pure reads, thread-safe, no shared mutation.
    // These three lot-derived values are frozen throughout Plan. Each first
    // query keeps the original walk and arithmetic; Replay never reads this cache.
    struct ArmyPlanValues {
        int64_t attack = 0;
        int64_t defense = 0;
        int32_t fort_ignore = 0;
        uint8_t valid = 0;
    };
    std::vector<ArmyPlanValues> army_values(army_count);
    int64_t value_queries = 0, value_builds = 0;
    int64_t fort_queries = 0, fort_builds = 0;
    auto lot_value = [&](size_t army, bool attack) -> int64_t {
        ++value_queries;
        ArmyPlanValues &values = army_values[army];
        const uint8_t bit = attack ? 1 : 2;
        int64_t &value = attack ? values.attack : values.defense;
        if ((values.valid & bit) == 0) {
            value = sum_lot_value(*this, army, attack);
            values.valid |= bit;
            ++value_builds;
        }
        return value;
    };
    auto fort_ignore_value = [&](size_t army) -> int32_t {
        ++fort_queries;
        ArmyPlanValues &values = army_values[army];
        if ((values.valid & 4) == 0) {
            values.fort_ignore = army_fort_ignore_q16(*this, army);
            values.valid |= 4;
            ++fort_builds;
        }
        return values.fort_ignore;
    };
    std::vector<Plan> plans;
    plans.reserve(order.size());
    for (size_t oi = 0; oi < order.size(); ++oi) {
        const int32_t index = order[oi];
        const MilitaryEngagement &e = _engagements[(size_t)index];
        Plan plan;
        plan.index = index;
        if (!army_live(_armies, e.attacker_slot)) {
            plans.push_back(plan);
            continue;
        }
        const int32_t attacker = _armies.owner_slot[(size_t)e.attacker_slot];
        const int32_t from_cell = _armies.cell[(size_t)e.attacker_slot];
        const int32_t far_cell = (from_cell == e.cell_a) ? e.cell_b : e.cell_a;
        plan.far_cell = far_cell;
        const int32_t defender_country = e.defender_slot;
        plan.defender_slot = defender_country;

        int64_t defender_attack = 0;
        int64_t defender_defence = 0;
        int64_t defender_heads = 0;
        int64_t attacker_heads = _armies.cached_headcount[(size_t)e.attacker_slot];
        for (int32_t other = _cell_head[(size_t)far_cell]; other >= 0;
             other = _armies.next_in_cell[(size_t)other]) {
            if (!_armies.active[(size_t)other]) continue;
            if (defender_country >= 0 && _armies.owner_slot[(size_t)other] != defender_country) {
                continue;
            }
            const int32_t cohesion = cohesion_q16(_armies, (size_t)other);
            const int32_t other_owner = _armies.owner_slot[(size_t)other];
            const bool other_connected = supply_connected(*this, digest, other_owner, far_cell);
            const RuleFactor rules =
                evaluate_rules(*this, digest, other, far_cell, other_owner, true, true,
                               other_connected, e.start_day, digest.day);
            defender_heads += _armies.cached_headcount[(size_t)other];
            // v5: 攻/防科技加成此前从未参与结算（MSTAT_ATTACK/DEFENSE 无读取点）。
            // 每支守军按自己的国家乘一次，避免与 rules.attack_q16 重复相乘。
            defender_attack += mul_q(
                mul_q(mul_q(lot_value((size_t)other, true), cohesion),
                      rules.attack_q16),
                stat_q16(digest, other_owner, MSTAT_ATTACK));
            defender_defence += mul_q(
                mul_q(mul_q(lot_value((size_t)other, false), cohesion),
                      rules.defense_q16),
                stat_q16(digest, other_owner, MSTAT_DEFENSE));
        }
        const int32_t attacker_cohesion = cohesion_q16(_armies, (size_t)e.attacker_slot);
        int64_t attacker_attack = mul_q(lot_value((size_t)e.attacker_slot, true),
                                        attacker_cohesion);
        // v5: 攻/防科技加成（同 defenders 侧，只乘这一次）。
        attacker_attack = mul_q(attacker_attack, stat_q16(digest, attacker, MSTAT_ATTACK));
        // Channel-B rules (sec 17.1): the attacker fights from its own cell, the
        // defender holds the contested one.
        const bool attacker_connected = supply_connected(*this, digest, attacker, from_cell);
        const RuleFactor attacker_rules =
            evaluate_rules(*this, digest, e.attacker_slot, from_cell, attacker, false, false,
                           attacker_connected, e.start_day, digest.day);
        attacker_attack = mul_q(attacker_attack, attacker_rules.attack_q16);
        plan.attacker_no_disengage = attacker_rules.no_auto_disengage;

        // Frontage W = frontage(era) * terrain width * frontage stat (sec 11.4).
        int32_t era = 0;
        if (attacker >= 0 && (size_t)attacker < digest.country_era.size()) {
            era = digest.country_era[(size_t)attacker];
        }
        const int64_t frontage =
            mul_q(kFrontageBaseQ16 + (int64_t)kFrontagePerEraQ16 * era,
                  terrain_width_q16(*this, far_cell));
        const int64_t width = std::max<int64_t>(1, mul_q(frontage, stat_q16(digest, attacker, MSTAT_FRONTAGE)));
        const int64_t n_attacker = std::min<int64_t>(attacker_heads, width);
        const int64_t n_defender = std::min<int64_t>(defender_heads, width);
        if (attacker_heads > 0 && n_attacker < attacker_heads) {
            attacker_attack = mul_div(attacker_attack, n_attacker, attacker_heads);
        }
        if (defender_heads > 0 && n_defender < defender_heads) {
            defender_defence = mul_div(defender_defence, n_defender, defender_heads);
            defender_attack = mul_div(defender_attack, n_defender, defender_heads);
        }

        // T_b = terrain_def * fort^(1-ignore) * river penalty.
        const int32_t fort_ignore = fort_ignore_value((size_t)e.attacker_slot);
        const int32_t fort = fort_q16(*this, far_cell);
        int64_t fort_term = fort;
        if (fort_ignore > 0) {
            fort_term = MILITARY_Q16 + mul_q(fort - MILITARY_Q16, MILITARY_Q16 - fort_ignore);
        }
        int64_t t_defence = mul_q(terrain_def_q16(*this, far_cell), fort_term);
        const MilitaryTerrainInput &terrain = _terrain;
        if ((size_t)far_cell < terrain.has_river.size() &&
            (size_t)e.attacker_side_cell < terrain.has_river.size() &&
            terrain.has_river[(size_t)far_cell] &&
            !terrain.has_river[(size_t)e.attacker_side_cell]) {
            t_defence = mul_q(t_defence, 95 * MILITARY_Q16 / 100);
        }
        if (e.war_id >= 0) {
            if (const MilitaryWar *war = find_war_const(e.war_id)) {
                if (digest.day - war->start_day < kDefenderBonusDays) t_defence += kDefenderBonusQ16;
            }
        }
        const int64_t local = local_defence(*this, digest, far_cell);
        const int64_t s_attacker = attacker_attack;
        const int64_t s_defender = mul_q(defender_defence, t_defence) + local;
        const int64_t p_attacker = attacker_attack / 2;
        const int64_t c_defender = defender_attack / 2;
        if (s_attacker <= 0 && s_defender <= 0) {
            plans.push_back(plan);
            continue;
        }
        const int64_t denominator = std::max<int64_t>(s_attacker + s_defender, 1);
        const uint64_t key = edge_key(e.cell_a, e.cell_b);
        const int64_t noise_q16 = 65536 + (int64_t)rng_q16(_seed, key, digest.day) * 19661 / 65536;
        const int64_t delta = mul_q(mul_div(kBaseDailyDeltaQ16, s_attacker - s_defender, denominator),
                                    noise_q16);
        plan.delta_q16 = (int32_t)clamp64(delta, -kBaseDailyDeltaQ16 * 2, kBaseDailyDeltaQ16 * 2);
        // Casualties: 0.8% of the engaged force scaled by the odds.
        const int64_t casualty_att =
            mul_div(mul_div(mul_div(n_attacker, 8, 1000), c_defender,
                            std::max<int64_t>(c_defender + p_attacker, 1)),
                    stat_q16(digest, attacker, MSTAT_CASUALTY), MILITARY_Q16);
        const int64_t casualty_def =
            mul_div(mul_div(mul_div(n_defender, 8, 1000), s_attacker, denominator),
                    stat_q16(digest, defender_country, MSTAT_CASUALTY), MILITARY_Q16);
        plan.losses_attacker = std::min<int64_t>(casualty_att, std::max<int64_t>(n_attacker, 0));
        plan.losses_defender = std::min<int64_t>(casualty_def, std::max<int64_t>(n_defender, 0));
        plan.org_attacker = -(int32_t)mul_div(kOrgLossBaseQ16, s_defender, denominator);
        plan.org_defender = -(int32_t)mul_div(kOrgLossBaseQ16, s_attacker, denominator);

        // Battle (sec 11.5): 1.5% + 4% * intensity, or ASSAULT every 5 days.
        const int64_t minority = std::min(s_attacker, s_defender);
        const int32_t intensity_q16 = (int32_t)mul_div(minority, MILITARY_Q16, denominator);
        const int32_t chance_q16 =
            kBattleChanceBaseQ16 + (int32_t)mul_div(kBattleChanceIntensityQ16, intensity_q16,
                                                    MILITARY_Q16);
        const uint64_t battle_key = key ^ 0xba771u;
        const bool rolled = (int64_t)rng_q16(_seed, battle_key, digest.day) < chance_q16;
        const bool assault_due =
            _armies.stance[(size_t)e.attacker_slot] == (uint8_t)MILITARY_STANCE_ASSAULT &&
            e.days_since_battle >= kAssaultBattleIntervalDays;
        if (rolled || assault_due) {
            plan.battle = 1;
            const int32_t base_r = (int32_t)mul_div(s_attacker, MILITARY_Q16, denominator);
            const int32_t r_q16 = clamp_q16_i32((int64_t)base_r +
                                                    gauss_q16(_seed, battle_key, digest.day, kBattleSigmaQ16),
                                                0, MILITARY_Q16);
            const int64_t span = kBattleMinDeltaQ16 +
                                 mul_div(kBattleSpanDeltaQ16, std::llabs((int64_t)r_q16 - 32768), 32768);
            const bool attacker_wins = r_q16 >= 32768;
            plan.battle_delta_q16 = (int32_t)(attacker_wins ? span : -span);
            plan.battle_score_q16 = (int32_t)(2 * MILITARY_Q16 +
                                              mul_div(6 * MILITARY_Q16, intensity_q16, MILITARY_Q16));
            const int32_t winner_bp = 150 + (int32_t)(rng_q16(_seed, battle_key ^ 0x11u, digest.day) % 151);
            const int32_t loser_bp = 400 + (int32_t)(rng_q16(_seed, battle_key ^ 0x22u, digest.day) % 401);
            if (attacker_wins) {
                plan.winner_slot = e.attacker_slot;
                plan.loser_slot = defender_country;
                plan.winner_losses = mul_div(n_attacker, winner_bp, 10000);
                plan.loser_losses = mul_div(n_defender, loser_bp, 10000);
                plan.org_attacker -= kOrgLossBattleWinnerQ16;
                plan.org_defender -= kOrgLossBattleLoserQ16;
            } else {
                plan.winner_slot = defender_country;
                plan.loser_slot = e.attacker_slot;
                plan.winner_losses = mul_div(n_defender, winner_bp, 10000);
                plan.loser_losses = mul_div(n_attacker, loser_bp, 10000);
                plan.org_attacker -= kOrgLossBattleLoserQ16;
                plan.org_defender -= kOrgLossBattleWinnerQ16;
            }
            if (assault_due && !rolled) plan.org_attacker -= kOrgLossAssaultQ16;
        }
        plans.push_back(plan);
    }

    _report.battle_plan_value_queries += value_queries;
    _report.battle_plan_value_builds += value_builds;
    _report.battle_plan_fort_queries += fort_queries;
    _report.battle_plan_fort_builds += fort_builds;

    // ---- Replay in ascending edge key. All shared mutation happens here.
    int32_t battle_events = 0;
    std::vector<int32_t> captured;
    for (size_t pi = 0; pi < plans.size(); ++pi) {
        const Plan &plan = plans[pi];
        MilitaryEngagement &e = _engagements[(size_t)plan.index];
        if (!e.active) continue;
        if (!army_live(_armies, e.attacker_slot)) {
            close_engagement(plan.index);
            continue;
        }
        int64_t delta = plan.delta_q16;
        if (plan.battle != 0) {
            delta += plan.battle_delta_q16;
            e.days_since_battle = 0;
        } else {
            e.days_since_battle += 1;
        }
        // Progress stays in q16 (65536 = 1.0).
        e.progress_q16 = clamp_q16_i32((int64_t)e.progress_q16 + delta, 0, MILITARY_Q16);
        e.casualties_attacker += plan.losses_attacker;
        e.casualties_defender += plan.losses_defender;
        apply_casualties(plan.losses_attacker, e.attacker_slot, plan.far_cell, out);
        // Defender casualties land on every defending army of the far cell.
        if (plan.losses_defender > 0) {
            int64_t remaining = plan.losses_defender;
            for (int32_t other = _cell_head[(size_t)plan.far_cell]; other >= 0 && remaining > 0;
                 other = _armies.next_in_cell[(size_t)other]) {
                if (!_armies.active[(size_t)other]) continue;
                if (_armies.engagement[(size_t)other] != plan.index) continue;
                const int64_t heads = _armies.cached_headcount[(size_t)other];
                const int64_t take = std::min(remaining, heads);
                if (take <= 0) continue;
                apply_casualties(take, other, plan.far_cell, out);
                remaining -= take;
            }
        }
        if ((size_t)e.attacker_slot < _armies.organization_q16.size()) {
            _armies.organization_q16[(size_t)e.attacker_slot] = clamp_q16_i32(
                (int64_t)_armies.organization_q16[(size_t)e.attacker_slot] + plan.org_attacker, 0,
                MILITARY_Q16);
        }
        for (int32_t other = _cell_head[(size_t)plan.far_cell]; other >= 0;
             other = _armies.next_in_cell[(size_t)other]) {
            if (_armies.engagement[(size_t)other] != plan.index) continue;
            _armies.organization_q16[(size_t)other] = clamp_q16_i32(
                (int64_t)_armies.organization_q16[(size_t)other] + plan.org_defender, 0, MILITARY_Q16);
        }
        if (plan.battle != 0) {
            record_battle(digest.day, (e.cell_a + e.cell_b) / 2, e.war_id, plan.winner_slot,
                          plan.loser_slot, plan.winner_losses, plan.loser_losses,
                          plan.battle_score_q16);
            with_war_score(e.war_id, plan.winner_slot == e.attacker_slot ? plan.battle_score_q16
                                                                        : -plan.battle_score_q16);
            if (battle_events < kEventCapBattle) {
                MilitaryEvent event;
                event.day = digest.day;
                event.type = MILITARY_EVENT_BATTLE_RESOLVED;
                event.payload_schema = 21;
                event.cell = (e.cell_a + e.cell_b) / 2;
                event.i0 = (uint64_t)(uint32_t)plan.winner_slot;
                event.i1 = (uint64_t)(uint32_t)plan.loser_slot;
                event.i2 = (uint64_t)(uint32_t)e.progress_q16;
                event.i3 = 0;
                event.value = plan.loser_losses;
                push_event(event);
                ++battle_events;
            } else {
                ++_report.event_coalesced;
            }
        }
        if (e.progress_q16 >= MILITARY_Q16) {
            captured.push_back(plan.index);
            continue;
        }
        if (e.progress_q16 <= 0) {
            const bool assaulting =
                _armies.stance[(size_t)e.attacker_slot] == (uint8_t)MILITARY_STANCE_ASSAULT;
            // last_stand keeps a cut-off formation in the fight (sec 17.1).
            if (!assaulting && plan.attacker_no_disengage == 0) close_engagement(plan.index);
        }
    }
    // Capture after the whole replay so retreat routes see final control.
    for (int32_t index : captured) {
        if ((size_t)index >= _engagements.size()) continue;
        if (!_engagements[(size_t)index].active) continue;
        capture_cell(index, digest, out);
    }
}

void MilitaryCore::apply_casualties(int64_t losses, int32_t army_hint, int32_t fallback_cell,
                                    std::vector<MilitaryIntent> &out) {
    if (losses <= 0) return;
    if (army_hint >= 0 && army_live(_armies, army_hint)) {
        const int32_t taken = (int32_t)lot_remove_casualties((uint8_t)MILITARY_LOT_ARMY, army_hint,
                                                            losses);
        if (taken > 0) {
            // Army personnel lane (contract §2.1): the dead live in the
            // formation's Economy lane, not in the home cell's soldier cohort,
            // so the lane is released to the battle cell and the casualty is
            // booked there. Emitting the old cell-targeted casualty alone would
            // kill an unrelated garrison and leave the lane holding ghosts.
            emit_army_personnel_loss(army_hint, _armies.cell[(size_t)army_hint], taken, taken,
                                     out);
        }
        refresh_army_cache(army_hint);
        return;
    }
    // Garrison casualties from battles are not applicable in v1: engagements
    // only exist between armies, which are always addressed by army_hint.
    (void)fallback_cell;
}

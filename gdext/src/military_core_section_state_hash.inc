uint64_t MilitaryCore::state_hash() const {
    uint64_t h = 0x243f6a8885a308d3ull;
    h = mix_scalar<uint64_t>(h, _seed);
    h = mix_scalar<uint64_t>(h, _catalog.hash);
    h = mix_scalar<int64_t>(h, _last_day);
    h = mix_scalar<uint64_t>(h, _next_sequence);
    h = mix_scalar<uint64_t>(h, _next_id);
    h = mix_scalar<uint64_t>(h, _next_event_id);
    h = mix_scalar<uint64_t>(h, _control_revision);
    h = mix_scalar<uint64_t>(h, _front_revision);
    h = mix_scalar<uint64_t>(h, (uint64_t)_path_daily_requests.size());
    for (int32_t n : _path_daily_requests) h = mix_scalar<int32_t>(h, n);
    h = mix_scalar<uint64_t>(h, (uint64_t)_pending.size());
    for (const MilitaryCommand &c : _pending) {
        h = mix_scalar<uint16_t>(h, c.op);
        h = mix_scalar<int64_t>(h, c.effective_day);
        h = mix_scalar<uint64_t>(h, c.sequence);
        h = mix_scalar<uint64_t>(h, c.country);
        h = mix_scalar<uint64_t>(h, c.army);
        h = mix_scalar<uint64_t>(h, c.other);
        h = mix_scalar<int32_t>(h, c.cell);
        h = mix_scalar<int32_t>(h, c.radius);
        h = mix_scalar<int32_t>(h, c.unit_from);
        h = mix_scalar<int32_t>(h, c.unit_to);
        h = mix_scalar<int64_t>(h, c.count);
        h = mix_scalar<int64_t>(h, c.value);
        for (int32_t v : c.cells) h = mix_scalar<int32_t>(h, v);
        for (int32_t v : c.ints) h = mix_scalar<int32_t>(h, v);
        for (int64_t v : c.longs) h = mix_scalar<int64_t>(h, v);
    }
    // Empty tables add nothing, so a world that never used auto-exploration
    // keeps exactly the pre-v4 hash. Non-empty rows are hashed in table order
    // (the same order PKMI writes), including terminal rows.
    if (!_explorations.empty()) {
        h = mix_scalar<uint64_t>(h, (uint64_t)_explorations.size());
        for (const MilitaryExplorationTask &task : _explorations) {
            h = mix_scalar<uint8_t>(h, task.active ? 1 : 0);
            h = mix_scalar<int32_t>(h, task.row_index);
            h = mix_scalar<uint64_t>(h, task.army_handle);
            h = mix_scalar<int32_t>(h, task.owner_slot);
            h = mix_scalar<uint64_t>(h, task.owner_handle);
            h = mix_scalar<int32_t>(h, task.origin_cell);
            h = mix_scalar<int32_t>(h, task.return_cell);
            h = mix_scalar<int32_t>(h, task.anchor_cell);
            h = mix_scalar<int32_t>(h, task.radius);
            h = mix_scalar<int32_t>(h, task.selected_count);
            for (int32_t i = 0; i < task.selected_count; ++i)
                h = mix_scalar<int32_t>(h, task.selected_cells[(size_t)i]);
            for (int32_t w = 0; w < 4; ++w) {
                h = mix_scalar<uint64_t>(h, task.seen_mask[(size_t)w]);
                h = mix_scalar<uint64_t>(h, task.visited_mask[(size_t)w]);
                h = mix_scalar<uint64_t>(h, task.blocked_mask[(size_t)w]);
            }
            h = mix_scalar<uint8_t>(h, task.phase);
            h = mix_scalar<uint8_t>(h, task.pause_reason);
            h = mix_scalar<uint8_t>(h, task.result);
            h = mix_scalar<uint8_t>(h, task.resume_phase);
            h = mix_scalar<int32_t>(h, task.focus_index);
            h = mix_scalar<int32_t>(h, task.current_observation_cell);
            h = mix_scalar<int32_t>(h, task.observer_tries);
            for (int32_t v : task.reached_observer_cells)
                h = mix_scalar<int32_t>(h, v);
            h = mix_scalar<uint32_t>(h, task.tried_observer_mask);
            h = mix_scalar<int64_t>(h, task.started_day);
            h = mix_scalar<int64_t>(h, task.last_progress_day);
            h = mix_scalar<int64_t>(h, task.last_plan_day);
            h = mix_scalar<int64_t>(h, task.complete_day);
            h = mix_scalar<uint8_t>(h, task.return_fallback);
        }
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_lots.active.size());
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        h = mix_scalar<uint8_t>(h, _lots.active[i]);
        if (!_lots.active[i]) continue;
        h = mix_scalar<uint8_t>(h, _lots.location_kind[i]);
        h = mix_scalar<int32_t>(h, _lots.location[i]);
        h = mix_scalar<int32_t>(h, _lots.country_slot[i]);
        h = mix_scalar<int16_t>(h, _lots.unit_type[i]);
        h = mix_scalar<int16_t>(h, _lots.equip_quality_q8[i]);
        h = mix_scalar<int32_t>(h, _lots.kit_q16[i]);
        if (_lots.partial_equipment[i] != 0)
            h = mix_scalar<uint16_t>(h, _lots.partial_equipment[i]);
        h = mix_scalar<int32_t>(h, _lots.condition_q16[i]);
        h = mix_scalar<int64_t>(h, _lots.count[i]);
    }
    const MilitaryArmyStore &a = _armies;
    h = mix_scalar<uint64_t>(h, (uint64_t)a.active.size());
    for (size_t i = 0; i < a.active.size(); ++i) {
        h = mix_scalar<uint8_t>(h, a.active[i]);
        if (!a.active[i]) continue;
        h = mix_scalar<uint32_t>(h, a.generation[i]);
        h = mix_scalar<int32_t>(h, a.owner_slot[i]);
        h = mix_scalar<int32_t>(h, a.cell[i]);
        h = mix_scalar<int32_t>(h, a.next_cell[i]);
        h = mix_scalar<int32_t>(h, a.move_points_q16[i]);
        h = mix_scalar<uint8_t>(h, a.stance[i]);
        h = mix_scalar<uint8_t>(h, a.mission[i]);
        h = mix_scalar<int32_t>(h, a.target_cell[i]);
        h = mix_scalar<int32_t>(h, a.area_id[i]);
        h = mix_scalar<int32_t>(h, a.organization_q16[i]);
        h = mix_scalar<int32_t>(h, a.morale_q16[i]);
        h = mix_scalar<int32_t>(h, a.supply_ratio_q16[i]);
        h = mix_scalar<int32_t>(h, a.ration_ratio_q16[i]);
        h = mix_scalar<int32_t>(h, a.pay_ratio_q16[i]);
        h = mix_scalar<int32_t>(h, a.path_cursor[i]);
        h = mix_scalar<int32_t>(h, a.path_len[i]);
        h = mix_scalar<uint8_t>(h, a.reinforce_enabled[i]);
        h = mix_scalar<int32_t>(h, a.template_len[i]);
        h = mix_scalar<int64_t>(h, a.cached_headcount[i]);
        h = mix_scalar<int64_t>(h, a.cached_attack_q16[i]);
        h = mix_scalar<int64_t>(h, a.cached_defense_q16[i]);
        h = mix_scalar<int32_t>(h, a.cached_speed_q16[i]);
        h = mix_scalar<int32_t>(h, a.engagement[i]);
        h = mix_scalar<int64_t>(h, a.moved_day[i]);
        h = mix_scalar<int32_t>(h, a.prev_cell[i]);
        h = mix_scalar<uint32_t>(h, a.name_seed[i]);
        h = mix_scalar<int64_t>(h, a.funds[i]);
    }
    // Live spans only (arenas are compacted by PKMI encode; dead rows are not state).
    for (size_t i = 0; i < a.active.size(); ++i) {
        if (!a.active[i]) continue;
        for (int32_t k = 0; k < a.path_len[i]; ++k) {
            const size_t at = (size_t)(a.path_offset[i] + k);
            h = mix_scalar<int32_t>(h, at < _path_cells.size() ? _path_cells[at] : -1);
        }
        for (int32_t k = 0; k < a.template_len[i]; ++k) {
            const size_t at = (size_t)(a.template_offset[i] + k);
            h = mix_scalar<int32_t>(h, at < _template_rows.size() ? _template_rows[at] : -1);
        }
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_training.size());
    for (const MilitaryTrainingOrder &o : _training) {
        h = mix_scalar<uint64_t>(h, o.id);
        h = mix_scalar<int32_t>(h, o.country_slot);
        h = mix_scalar<int32_t>(h, o.cell);
        h = mix_scalar<int16_t>(h, o.from_unit);
        h = mix_scalar<int16_t>(h, o.to_unit);
        h = mix_scalar<int64_t>(h, o.count);
        h = mix_scalar<int32_t>(h, o.days_total);
        h = mix_scalar<int32_t>(h, o.days_done);
        h = mix_scalar<uint8_t>(h, o.equipment_ready);
        h = mix_scalar<uint8_t>(h, o.manual);
        h = mix_scalar<int16_t>(h, o.quality_q8);
        for (int8_t quality : o.slot_delivered_quality)
            h = mix_scalar<int8_t>(h, quality);
        h = mix_scalar<int16_t>(h, o.delivered_quality_q8);
        h = mix_scalar<uint64_t>(h, o.equipped_slot_mask);
        if (o.source_partial_equipment != 0)
            h = mix_scalar<uint16_t>(h, o.source_partial_equipment);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_stocks.size());
    for (const MilitaryStockRow &r : _stocks) {
        h = mix_scalar<uint8_t>(h, r.holder_kind);
        h = mix_scalar<int32_t>(h, r.holder);
        h = mix_scalar<int32_t>(h, r.country_slot);
        h = mix_scalar<int32_t>(h, r.good);
        h = mix_scalar<int64_t>(h, r.qty);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_shipments.size());
    for (const MilitaryShipment &s : _shipments) {
        h = mix_scalar<uint64_t>(h, s.id);
        h = mix_scalar<int32_t>(h, s.country_slot);
        h = mix_scalar<uint8_t>(h, s.dest_kind);
        h = mix_scalar<int32_t>(h, s.dest);
        h = mix_scalar<uint64_t>(h, s.dest_handle);
        h = mix_scalar<int32_t>(h, s.origin_cell);
        h = mix_scalar<int32_t>(h, s.current_cell);
        h = mix_scalar<int32_t>(h, s.good);
        h = mix_scalar<int64_t>(h, s.qty);
        h = mix_scalar<int64_t>(h, s.value);
        h = mix_scalar<int64_t>(h, s.departure_day);
        h = mix_scalar<int64_t>(h, s.eta_day);
        h = mix_scalar<int32_t>(h, s.route_cost_q16);
        h = mix_scalar<int32_t>(h, s.progress_q16);
        h = mix_scalar<int32_t>(h, s.blocked_days);
    }
    // Paid-but-unsettled purchases are state: the request identity and the
    // destination decide who receives the goods when the fill receipt lands, so
    // two runs that differ here are not the same world. An empty table adds
    // nothing beyond the sentinels, so a world that never buys keeps the shape
    // of its previous hash.
    h = mix_scalar<int32_t>(h, _next_purchase_id);
    h = mix_scalar<uint64_t>(h, (uint64_t)_purchase_orders.size());
    for (const MilitaryPurchaseOrder &o : _purchase_orders) {
        h = mix_scalar<uint16_t>(h, o.intent.kind);
        h = mix_scalar<int32_t>(h, o.intent.cell);
        h = mix_scalar<int32_t>(h, o.intent.good);
        h = mix_scalar<uint64_t>(h, o.intent.country_a);
        h = mix_scalar<int64_t>(h, o.intent.count);
        h = mix_scalar<int64_t>(h, o.intent.amount);
        h = mix_scalar<uint64_t>(h, o.intent.source_id);
        h = mix_scalar<uint8_t>(h, o.channel);
        h = mix_scalar<int32_t>(h, o.destination_cell);
        h = mix_scalar<uint8_t>(h, o.dest_kind);
        h = mix_scalar<int32_t>(h, o.dest);
        h = mix_scalar<uint64_t>(h, o.dest_handle);
        h = mix_scalar<int32_t>(h, o.stock_good);
        h = mix_scalar<int32_t>(h, o.real_good);
        h = mix_scalar<int32_t>(h, o.category);
        h = mix_scalar<int8_t>(h, o.quality);
        h = mix_scalar<int32_t>(h, o.route_cost_q16);
        h = mix_scalar<int32_t>(h, o.days);
    }
    // Maintenance objects: the carry, the window and the verdict are state, so
    // two runs that differ here are different worlds. A world with no state
    // buildings or soldiers adds only the sentinel.
    h = mix_scalar<uint64_t>(h, (uint64_t)_maint_rows.size());
    for (const MilitaryMaintenanceRow &r : _maint_rows) {
        h = mix_scalar<uint8_t>(h, r.kind);
        h = mix_scalar<int32_t>(h, r.country_slot);
        h = mix_scalar<int32_t>(h, r.cell);
        h = mix_scalar<int32_t>(h, r.object_id);
        h = mix_scalar<uint8_t>(h, r.holder_kind);
        h = mix_scalar<int32_t>(h, r.holder);
        h = mix_scalar<int32_t>(h, r.units);
        for (int32_t m = 0; m < MILITARY_MAX_REPAIR_MATERIALS; ++m)
            h = mix_scalar<int64_t>(h, r.acc_q32[m]);
        h = mix_scalar<int64_t>(h, r.window_need);
        h = mix_scalar<int64_t>(h, r.window_met);
        h = mix_scalar<int32_t>(h, r.window_days);
        h = mix_scalar<int32_t>(h, r.ratio_bp);
        h = mix_scalar<uint8_t>(h, r.disrepair);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_engagements.size());
    for (const MilitaryEngagement &e : _engagements) {
        h = mix_scalar<int32_t>(h, e.cell_a);
        h = mix_scalar<int32_t>(h, e.cell_b);
        h = mix_scalar<int32_t>(h, e.attacker_side_cell);
        h = mix_scalar<int32_t>(h, e.attacker_slot);
        h = mix_scalar<int32_t>(h, e.defender_slot);
        h = mix_scalar<int32_t>(h, e.war_id);
        h = mix_scalar<int32_t>(h, e.progress_q16);
        h = mix_scalar<int64_t>(h, e.start_day);
        h = mix_scalar<int32_t>(h, e.idle_days);
        h = mix_scalar<int32_t>(h, e.days_since_battle);
        h = mix_scalar<int64_t>(h, e.casualties_attacker);
        h = mix_scalar<int64_t>(h, e.casualties_defender);
        h = mix_scalar<uint8_t>(h, e.active);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_wars.size());
    for (const MilitaryWar &w : _wars) {
        h = mix_scalar<int32_t>(h, w.id);
        h = mix_scalar<int32_t>(h, w.attacker_slot);
        h = mix_scalar<int32_t>(h, w.defender_slot);
        h = mix_scalar<uint64_t>(h, w.attacker_handle);
        h = mix_scalar<uint64_t>(h, w.defender_handle);
        h = mix_scalar<int64_t>(h, w.start_day);
        h = mix_scalar<int32_t>(h, w.score_battle_q16);
        h = mix_scalar<int32_t>(h, w.score_annihilation_q16);
        h = mix_scalar<int32_t>(h, w.score_attrition_q16);
        h = mix_scalar<int64_t>(h, w.attacker_losses);
        h = mix_scalar<int64_t>(h, w.defender_losses);
        h = mix_scalar<int64_t>(h, w.last_rejected_offer_day_a);
        h = mix_scalar<int64_t>(h, w.last_rejected_offer_day_b);
        h = mix_scalar<int64_t>(h, w.fully_occupied_since_a);
        h = mix_scalar<int64_t>(h, w.fully_occupied_since_b);
        h = mix_scalar<uint8_t>(h, w.active);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_truces.size());
    for (const MilitaryTruce &t : _truces) {
        h = mix_scalar<int32_t>(h, t.slot_a);
        h = mix_scalar<int32_t>(h, t.slot_b);
        h = mix_scalar<int64_t>(h, t.until_day);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_reparations.size());
    for (const MilitaryReparation &r : _reparations) {
        h = mix_scalar<uint64_t>(h, r.payer);
        h = mix_scalar<uint64_t>(h, r.receiver);
        h = mix_scalar<int64_t>(h, r.installment);
        h = mix_scalar<int32_t>(h, r.remaining);
        h = mix_scalar<int64_t>(h, r.next_day);
        h = mix_scalar<int64_t>(h, r.arrears);
        h = mix_scalar<int32_t>(h, r.war_id);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_battle_log.size());
    for (const MilitaryBattleLogRow &b : _battle_log) {
        h = mix_scalar<int64_t>(h, b.day);
        h = mix_scalar<int32_t>(h, b.cell);
        h = mix_scalar<int32_t>(h, b.war_id);
        h = mix_scalar<int32_t>(h, b.winner_slot);
        h = mix_scalar<int32_t>(h, b.loser_slot);
        h = mix_scalar<int64_t>(h, b.winner_losses);
        h = mix_scalar<int64_t>(h, b.loser_losses);
        h = mix_scalar<int32_t>(h, b.score_gain_q16);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_areas.size());
    for (const MilitaryArea &ar : _areas) {
        h = mix_scalar<int32_t>(h, ar.id);
        h = mix_scalar<int32_t>(h, ar.owner_slot);
        h = mix_scalar<int64_t>(h, ar.last_eval_day);
        h = mix_scalar<uint8_t>(h, ar.active);
        h = mix_scalar<uint64_t>(h, (uint64_t)ar.cells.size());
        for (int32_t c : ar.cells) h = mix_scalar<int32_t>(h, c);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_policies.size());
    for (size_t i = 0; i < _policies.size(); ++i) {
        const MilitaryCountryPolicy &p = _policies[i];
        h = mix_scalar<uint64_t>(h, _policy_handle[i]);
        h = mix_scalar<uint8_t>(h, p.target_mode);
        h = mix_scalar<int64_t>(h, p.target_value);
        h = mix_scalar<int64_t>(h, p.effective_target);
        h = mix_scalar<uint8_t>(h, p.levy_enabled);
        h = mix_scalar<uint8_t>(h, p.auto_retrain);
        h = mix_scalar<uint8_t>(h, p.auto_discharge);
        h = mix_scalar<uint8_t>(h, p.quality_policy);
        h = mix_scalar<uint8_t>(h, p.wage_mode);
        h = mix_scalar<int64_t>(h, p.wage_absolute);
        h = mix_scalar<int32_t>(h, p.procurement_share_bp);
        if (p.budget_share_bp != 0 || p.budget_wage_bp != 6000 || p.budget_upkeep_bp != 2000) {
            h = mix_scalar<int32_t>(h, p.budget_share_bp);
            h = mix_scalar<int32_t>(h, p.budget_wage_bp);
            h = mix_scalar<int32_t>(h, p.budget_upkeep_bp);
        }
        h = mix_scalar<int32_t>(h, p.pay_ratio_30_q16);
        h = mix_scalar<int64_t>(h, p.per_soldier_cost);
        for (int32_t bp : p.config_share_bp) h = mix_scalar<int32_t>(h, bp);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_cell_states.size());
    for (const MilitaryCellState &st : _cell_states) {
        h = mix_scalar<int32_t>(h, st.cell);
        for (int32_t t = 0; t < 8; ++t) h = mix_scalar<int32_t>(h, st.barracks_count[t]);
        h = mix_scalar<int32_t>(h, st.fort_tier);
        h = mix_scalar<int32_t>(h, st.college_tier);
        h = mix_scalar<uint8_t>(h, st.paused);
        h = mix_scalar<uint8_t>(h, st.disrepair);
        h = mix_scalar<int64_t>(h, st.pending_enlist);
        h = mix_scalar<int64_t>(h, st.quota);
        h = mix_scalar<int64_t>(h, st.requisition_until_day);
        for (int32_t k = 0; k < 3; ++k) {
            h = mix_scalar<int64_t>(h, st.construction_done_day[k]);
            h = mix_scalar<int32_t>(h, st.construction_building[k]);
        }
    }
    for (int32_t c : _cell_controller) h = mix_scalar<int32_t>(h, c);
    h = mix_scalar<int64_t>(h, _ledger_received);
    h = mix_scalar<int64_t>(h, _ledger_consumed);
    h = mix_scalar<int64_t>(h, _ledger_intercepted_out);
    h = mix_scalar<int64_t>(h, _ledger_intercepted_in);
    h = mix_scalar<int64_t>(h, _ledger_returned);
    h = mix_scalar<uint64_t>(h, (uint64_t)_events.size());
    for (const MilitaryEvent &e : _events) {
        h = mix_scalar<uint64_t>(h, e.id);
        h = mix_scalar<int64_t>(h, e.day);
        h = mix_scalar<uint16_t>(h, e.type);
        h = mix_scalar<uint16_t>(h, e.payload_schema);
        h = mix_scalar<int32_t>(h, e.cell);
        h = mix_scalar<uint64_t>(h, e.i0);
        h = mix_scalar<uint64_t>(h, e.i1);
        h = mix_scalar<uint64_t>(h, e.i2);
        h = mix_scalar<uint64_t>(h, e.i3);
        h = mix_scalar<int64_t>(h, e.value);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_ai_country.size());
    for (size_t i = 0; i < _ai_country.size(); ++i) {
        h = mix_scalar<uint8_t>(h, _ai_country[i]);
        if (i < _ai_next_decision_day.size()) h = mix_scalar<int64_t>(h, _ai_next_decision_day[i]);
    }
    return h;
}

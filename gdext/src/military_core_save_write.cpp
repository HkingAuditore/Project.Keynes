#include "military_core.h"
#include "military_core_save_internal.h"
#include <algorithm>

namespace pk {

namespace {

// -------------------------------------------------------------- writers

void write_lots(Writer &w, const MilitaryLotStore &s) {
    w.u32((uint32_t)s.active.size());
    for (size_t i = 0; i < s.active.size(); ++i) {
        w.u8(s.active[i]);
        if (!s.active[i]) continue;
        w.u8(s.location_kind[i]);
        w.i32(s.location[i]);
        w.i32(s.country_slot[i]);
        w.i16(s.unit_type[i]);
        w.i16(s.equip_quality_q8[i]);
        w.i32(s.kit_q16[i]);
        w.i32(s.condition_q16[i]);
        w.i64(s.count[i]);
    }
}

void write_armies(Writer &w, const MilitaryArmyStore &s) {
    w.u32((uint32_t)s.active.size());
    for (size_t i = 0; i < s.active.size(); ++i) {
        w.u8(s.active[i]);
        if (!s.active[i]) continue;
        w.u32(s.generation[i]);
        w.i32(s.owner_slot[i]);
        w.i32(s.cell[i]);
        w.i32(s.next_cell[i]);
        w.i32(s.move_points_q16[i]);
        w.u8(s.stance[i]);
        w.u8(s.mission[i]);
        w.i32(s.target_cell[i]);
        w.i32(s.area_id[i]);
        w.i32(s.organization_q16[i]);
        w.i32(s.morale_q16[i]);
        w.i32(s.supply_ratio_q16[i]);
        w.i32(s.ration_ratio_q16[i]);
        w.i32(s.pay_ratio_q16[i]);
        // Path spans are stored relative to the compacted arena; encode() has
        // already remapped path_offset into the compacted numbering.
        w.i32(s.path_offset[i]);
        w.i32(s.path_len[i]);
        w.i32(s.path_cursor[i]);
        w.u8(s.reinforce_enabled[i]);
        w.i32(s.template_offset[i]);
        w.i32(s.template_len[i]);
        w.u64(s.commander_slot[i]);
        w.i64(s.cached_headcount[i]);
        w.i64(s.cached_attack_q16[i]);
        w.i64(s.cached_defense_q16[i]);
        w.i32(s.cached_speed_q16[i]);
        w.i32(s.engagement[i]);
        w.i64(s.moved_day[i]);
        w.i32(s.prev_cell[i]);
        w.u32(s.name_seed[i]);
        w.i64(s.funds[i]);
    }
}

void write_policies(Writer &w, const MilitaryCore &core) {
    w.u32((uint32_t)core._policies.size());
    for (size_t i = 0; i < core._policies.size(); ++i) {
        const MilitaryCountryPolicy &p = core._policies[i];
        w.u64(i < core._policy_handle.size() ? core._policy_handle[i] : 0);
        w.u8(p.target_mode);
        w.i64(p.target_value);
        w.i64(p.effective_target);
        w.u8(p.levy_enabled);
        w.u8(p.auto_retrain);
        w.u8(p.auto_discharge);
        w.u8(p.quality_policy);
        w.u8(p.wage_mode);
        w.i64(p.wage_absolute);
        w.i32(p.procurement_share_bp);
        w.i32(p.pay_ratio_30_q16);
        w.i64(p.spend_payroll_30);
        w.i64(p.spend_procurement_30);
        w.i64(p.spend_upkeep_30);
        w.i64(p.per_soldier_cost);
        w.u32((uint32_t)p.config_share_bp.size());
        for (int32_t bp : p.config_share_bp) w.i32(bp);
    }
}


template<class T> void write_index_vector(Writer &w, const std::vector<T> &values) {
    w.u32((uint32_t)values.size());
    for (T value : values) w.i64((int64_t)value);
}

void write_index_continuation(Writer &w, const MilitaryCore &c) {
    write_index_vector(w, c._lots.location_kind);
    write_index_vector(w, c._lots.location);
    write_index_vector(w, c._lots.country_slot);
    write_index_vector(w, c._lots.unit_type);
    write_index_vector(w, c._lots.equip_quality_q8);
    write_index_vector(w, c._lots.kit_q16);
    write_index_vector(w, c._lots.condition_q16);
    write_index_vector(w, c._lots.count);
    write_index_vector(w, c._lots.free_list);
    w.u8(c._lot_index_ok ? 1 : 0);
    write_index_vector(w, c._lot_next);
    write_index_vector(w, c._lot_link_kind);
    write_index_vector(w, c._lot_link_loc);
    write_index_vector(w, c._lot_army_head);
    write_index_vector(w, c._lot_cell_head);
    write_index_vector(w, c._armies.generation);
    write_index_vector(w, c._armies.free_list);
    write_index_vector(w, c._army_lane_pending);
    bool partial = std::any_of(c._training.begin(), c._training.end(),
        [](const auto &order) { return order.source_partial_equipment != 0; });
    for (size_t row = 0; row < c._lots.active.size() && !partial; ++row)
        partial = c._lots.active[row] && c._lots.partial_equipment[row] != 0;
    if (partial) {
        for (size_t row = 0; row < c._lots.active.size(); ++row)
            w.u16(c._lots.active[row] ? c._lots.partial_equipment[row] : 0);
        for (const auto &order : c._training) w.u16(order.source_partial_equipment);
    }
}

} // namespace

// ============================================================== encode

std::vector<uint8_t> MilitaryCore::encode() const {

    Writer w;
    w.out.reserve(1u << 16);
    // ---- header
    w.u32(PKMI_MAGIC);
    w.u32(PKMI_VERSION);
    w.u64(_catalog.hash);
    w.u64(_seed);
    w.i32(_terrain.cell_count);
    w.i32(_terrain.width);
    w.i32(_terrain.height);
    w.i64(_last_day);

    // ---- counters
    w.begin(kSection_Counters);
    w.u64(_next_sequence);
    w.u64(_next_id);
    w.u64(_next_event_id);
    w.u64(_control_revision);
    w.u64(_front_revision);
    w.u32((uint32_t)_path_daily_requests.size());
    for (int32_t n : _path_daily_requests) w.i32(n);
    w.u32((uint32_t)_pending.size());
    w.end();

    // ---- pending commands
    w.begin(kSection_Pending);
    w.u32((uint32_t)_pending.size());
    for (const MilitaryCommand &c : _pending) {
        w.u16(c.op);
        w.i64(c.effective_day);
        w.u64(c.sequence);
        w.u64(c.country);
        w.u64(c.army);
        w.u64(c.other);
        w.i32(c.cell);
        w.i32(c.radius);
        w.i32(c.unit_from);
        w.i32(c.unit_to);
        w.i64(c.count);
        w.i64(c.value);
        w.u32((uint32_t)c.cells.size());
        for (int32_t v : c.cells) w.i32(v);
        w.u32((uint32_t)c.ints.size());
        for (int32_t v : c.ints) w.i32(v);
        w.u32((uint32_t)c.longs.size());
        for (int64_t v : c.longs) w.i64(v);
    }
    w.end();

    // ---- lots
    w.begin(kSection_Lots);
    write_lots(w, _lots);
    w.end();

    // ---- training orders
    w.begin(kSection_Training);
    w.u32((uint32_t)_training.size());
    for (const MilitaryTrainingOrder &o : _training) {
        w.u64(o.id);
        w.i32(o.country_slot);
        w.i32(o.cell);
        w.i16(o.from_unit);
        w.i16(o.to_unit);
        w.i64(o.count);
        w.i32(o.days_total);
        w.i32(o.days_done);
        w.u8(o.equipment_ready);
        w.u8(o.manual);
        w.i16(o.quality_q8);
        for (int8_t quality : o.slot_delivered_quality) w.i8(quality);
        w.i16(o.delivered_quality_q8);
        w.u64(o.equipped_slot_mask);
    }
    w.end();

    // ---- armies (with a compacted path arena and template arena)
    std::vector<int32_t> path_out;
    std::vector<int32_t> template_out;
    std::vector<int32_t> remap_off(_armies.active.size(), 0);
    std::vector<int32_t> remap_tpl(_armies.active.size(), 0);
    for (size_t i = 0; i < _armies.active.size(); ++i) {
        if (!_armies.active[i]) continue;
        const int32_t off = _armies.path_offset[i];
        const int32_t len = _armies.path_len[i];
        if (off >= 0 && len > 0 && (size_t)(off + len) <= _path_cells.size()) {
            remap_off[i] = (int32_t)path_out.size();
            path_out.insert(path_out.end(), _path_cells.begin() + off, _path_cells.begin() + off + len);
        } else {
            remap_off[i] = 0;
        }
        const int32_t toff = _armies.template_offset[i];
        const int32_t tlen = _armies.template_len[i];
        if (toff >= 0 && tlen > 0 && (size_t)(toff + tlen) <= _template_rows.size()) {
            remap_tpl[i] = (int32_t)template_out.size();
            template_out.insert(template_out.end(), _template_rows.begin() + toff,
                                _template_rows.begin() + toff + tlen);
        } else {
            remap_tpl[i] = 0;
        }
    }
    w.begin(kSection_Armies);
    {
        // Write armies with remapped spans by temporarily shadowing the offsets.
        MilitaryArmyStore shadow = _armies;
        for (size_t i = 0; i < shadow.active.size(); ++i) {
            if (!shadow.active[i]) continue;
            shadow.path_offset[i] = remap_off[i];
            shadow.template_offset[i] = remap_tpl[i];
        }
        write_armies(w, shadow);
    }
    w.end();

    w.begin(kSection_PathArena);
    w.u32((uint32_t)path_out.size());
    for (int32_t v : path_out) w.i32(v);
    w.end();

    w.begin(kSection_Templates);
    w.u32((uint32_t)template_out.size());
    for (int32_t v : template_out) w.i32(v);
    w.end();

    // ---- stocks
    w.begin(kSection_Stocks);
    w.u32((uint32_t)_stocks.size());
    for (const MilitaryStockRow &r : _stocks) {
        w.u8(r.holder_kind);
        w.i32(r.holder);
        w.i32(r.country_slot);
        w.i32(r.good);
        w.i64(r.qty);
    }
    w.end();

    // ---- shipments
    w.begin(kSection_Shipments);
    w.u32((uint32_t)_shipments.size());
    for (const MilitaryShipment &s : _shipments) {
        w.u64(s.id);
        w.i32(s.country_slot);
        w.u8(s.dest_kind);
        w.i32(s.dest);
        w.u64(s.dest_handle);
        w.i32(s.origin_cell);
        w.i32(s.current_cell);
        w.i32(s.good);
        w.i32(s.real_good);
        w.i8(s.quality);
        w.i64(s.qty);
        w.i64(s.value);
        w.i64(s.departure_day);
        w.i64(s.eta_day);
        w.i32(s.route_cost_q16);
        w.i32(s.progress_q16);
        w.i32(s.blocked_days);
    }
    w.end();

    // ---- purchase orders (section 24)
    w.begin(kSection_PurchaseOrders);
    w.u32((uint32_t)std::max(1, _next_purchase_id));
    w.u32((uint32_t)_purchase_orders.size());
    for (const MilitaryPurchaseOrder &o : _purchase_orders) {
        w.u16(o.intent.kind);
        w.i32(o.intent.cell);
        w.i32(o.intent.good);
        w.u64(o.intent.country_a);
        w.i64(o.intent.count);
        w.i64(o.intent.amount);
        w.u64(o.intent.source_id);          // stable request identity
        w.u8(o.channel);
        w.i32(o.destination_cell);
        w.u8(o.dest_kind);
        w.i32(o.dest);
        w.u64(o.dest_handle);
        w.i32(o.stock_good);
        w.i32(o.real_good);
        w.i32(o.category);
        w.i8(o.quality);
        w.i32(o.route_cost_q16);
        w.i32(o.days);
    }
    w.end();

    // ---- maintenance objects (section 25)
    w.begin(kSection_Maintenance);
    w.u32((uint32_t)_maint_rows.size());
    for (const MilitaryMaintenanceRow &r : _maint_rows) {
        w.u8(r.kind);
        w.i32(r.country_slot);
        w.i32(r.cell);
        w.i32(r.object_id);
        w.u8(r.holder_kind);
        w.i32(r.holder);
        w.i32(r.units);
        for (int32_t m = 0; m < MILITARY_MAX_REPAIR_MATERIALS; ++m) w.i64(r.acc_q32[m]);
        w.i64(r.window_need);
        w.i64(r.window_met);
        w.i32(r.window_days);
        w.i32(r.ratio_bp);
        w.u8(r.disrepair);
    }
    w.end();

    // ---- engagements
    w.begin(kSection_Engagements);
    w.u32((uint32_t)_engagements.size());
    for (const MilitaryEngagement &e : _engagements) {
        w.i32(e.cell_a);
        w.i32(e.cell_b);
        w.i32(e.attacker_side_cell);
        w.i32(e.attacker_slot);
        w.i32(e.defender_slot);
        w.i32(e.war_id);
        w.i32(e.progress_q16);
        w.i64(e.start_day);
        w.i32(e.idle_days);
        w.i32(e.days_since_battle);
        w.i64(e.casualties_attacker);
        w.i64(e.casualties_defender);
        w.u8(e.active);
    }
    w.end();

    // ---- wars
    w.begin(kSection_Wars);
    w.u32((uint32_t)_wars.size());
    for (const MilitaryWar &x : _wars) {
        w.i32(x.id);
        w.i32(x.attacker_slot);
        w.i32(x.defender_slot);
        w.u64(x.attacker_handle);
        w.u64(x.defender_handle);
        w.i64(x.start_day);
        w.i32(x.score_battle_q16);
        w.i32(x.score_annihilation_q16);
        w.i32(x.score_attrition_q16);
        w.i64(x.attacker_losses);
        w.i64(x.defender_losses);
        w.i64(x.last_rejected_offer_day_a);
        w.i64(x.last_rejected_offer_day_b);
        w.i64(x.fully_occupied_since_a);
        w.i64(x.fully_occupied_since_b);
        w.u8(x.active);
    }
    w.end();

    // ---- truces
    w.begin(kSection_Truces);
    w.u32((uint32_t)_truces.size());
    for (const MilitaryTruce &t : _truces) {
        w.i32(t.slot_a);
        w.i32(t.slot_b);
        w.i64(t.until_day);
    }
    w.end();

    // ---- reparation schedules
    w.begin(kSection_Reparations);
    w.u32((uint32_t)_reparations.size());
    for (const MilitaryReparation &r : _reparations) {
        w.u64(r.payer);
        w.u64(r.receiver);
        w.i64(r.installment);
        w.i32(r.remaining);
        w.i64(r.next_day);
        w.i64(r.arrears);
        w.i32(r.war_id);
    }
    w.end();

    // ---- battle log (last MILITARY_BATTLE_LOG_CAPACITY rows)
    w.begin(kSection_BattleLog);
    {
        const size_t keep = std::min<size_t>(_battle_log.size(), (size_t)MILITARY_BATTLE_LOG_CAPACITY);
        const size_t first = _battle_log.size() - keep;
        w.u32((uint32_t)keep);
        for (size_t i = first; i < _battle_log.size(); ++i) {
            const MilitaryBattleLogRow &b = _battle_log[i];
            w.i64(b.day);
            w.i32(b.cell);
            w.i32(b.war_id);
            w.i32(b.winner_slot);
            w.i32(b.loser_slot);
            w.i64(b.winner_losses);
            w.i64(b.loser_losses);
            w.i32(b.score_gain_q16);
        }
    }
    w.end();

    // ---- areas
    w.begin(kSection_Areas);
    w.u32((uint32_t)_areas.size());
    for (const MilitaryArea &a : _areas) {
        w.i32(a.id);
        w.i32(a.owner_slot);
        w.i64(a.last_eval_day);
        w.u8(a.active);
        w.u32((uint32_t)a.cells.size());
        for (int32_t c : a.cells) w.i32(c);
    }
    w.end();

    // ---- per-country policy
    w.begin(kSection_Policies);
    write_policies(w, *this);
    w.end();
    if (std::any_of(_policies.begin(), _policies.end(), [](const MilitaryCountryPolicy &p) {
            return p.budget_share_bp != 0 || p.budget_wage_bp != 6000 || p.budget_upkeep_bp != 2000;
        })) {
        w.begin(kSection_BudgetEnvelope);
        w.u32(static_cast<uint32_t>(_policies.size()));
        for (const auto &policy : _policies) {
            w.i32(policy.budget_share_bp);
            w.i32(policy.budget_wage_bp);
            w.i32(policy.budget_upkeep_bp);
        }
        w.end();
    }

    // ---- sparse cell state
    w.begin(kSection_CellStates);
    w.u32((uint32_t)_cell_states.size());
    for (const MilitaryCellState &st : _cell_states) {
        w.i32(st.cell);
        // Derived cache (requirement 6.1): the economy building groups are the
        // count of record, but the tuple is still written so a restored save
        // reproduces the same day-0 cache and the same state hash. The first
        // `step_day` after the restore rebuilds it from the ledger anyway, and
        // any difference is reported by `report().state_cache_repairs`.
        for (int32_t t = 0; t < 8; ++t) w.i32(st.barracks_count[t]);
        w.i32(st.fort_tier);
        w.i32(st.college_tier);
        w.u8(st.paused);
        w.u8(st.disrepair);
        w.i64(st.pending_enlist);
        w.i64(st.quota);
        w.i64(st.requisition_until_day);
        for (int32_t k = 0; k < 3; ++k) {
            w.i64(st.construction_done_day[k]);
            w.i32(st.construction_building[k]);
        }
    }
    w.end();

    // ---- cell controller (sparse: write (cell, slot) pairs)
    w.begin(kSection_Controller);
    {
        uint32_t count = 0;
        for (int32_t v : _cell_controller) {
            if (v >= 0) ++count;
        }
        w.u32((uint32_t)_cell_controller.size());
        w.u32(count);
        for (size_t i = 0; i < _cell_controller.size(); ++i) {
            if (_cell_controller[i] < 0) continue;
            w.i32((int32_t)i);
            w.i32(_cell_controller[i]);
        }
    }
    w.end();

    // ---- ledger
    w.begin(kSection_Ledger);
    w.i64(_ledger_received);
    w.i64(_ledger_consumed);
    w.i64(_ledger_intercepted_out);
    w.i64(_ledger_intercepted_in);
    w.i64(_ledger_returned);
    w.i64(_ledger_stock);
    w.i64(_ledger_transit);
    w.end();

    // ---- events ring
    w.begin(kSection_Events);
    w.u32((uint32_t)_events.size());
    for (const MilitaryEvent &e : _events) {
        w.u64(e.id);
        w.i64(e.day);
        w.u16(e.type);
        w.u16(e.payload_schema);
        w.i32(e.cell);
        w.u64(e.i0);
        w.u64(e.i1);
        w.u64(e.i2);
        w.u64(e.i3);
        w.i64(e.value);
    }
    w.end();

    // ---- AI agenda memory
    w.begin(kSection_Ai);
    w.u32((uint32_t)_ai_country.size());
    for (size_t i = 0; i < _ai_country.size(); ++i) {
        w.u8(_ai_country[i]);
        w.i64(i < _ai_next_decision_day.size() ? _ai_next_decision_day[i] : 0);
    }
    w.end();

    // ---- player auto-exploration rows (section 23) ------------------------
    // Always written, including an empty table. Trail / explored view / fog
    // are host-owned and intentionally absent.
    w.begin(kSection_Exploration);
    w.u32((uint32_t)_explorations.size());
    for (const MilitaryExplorationTask &task : _explorations) {
        w.u8(task.active ? 1 : 0);
        w.i32(task.row_index);
        w.u64(task.army_handle);
        w.i32(task.owner_slot);
        w.u64(task.owner_handle);
        w.i32(task.origin_cell);
        w.i32(task.return_cell);
        w.i32(task.anchor_cell);
        w.i32(task.radius);
        w.u32((uint32_t)task.selected_count);
        for (int32_t i = 0; i < task.selected_count; ++i)
            w.i32(task.selected_cells[(size_t)i]);
        for (int32_t word = 0; word < 4; ++word) {
            w.u64(task.seen_mask[(size_t)word]);
            w.u64(task.visited_mask[(size_t)word]);
            w.u64(task.blocked_mask[(size_t)word]);
        }
        w.u8(task.phase);
        w.u8(task.pause_reason);
        w.u8(task.result);
        w.u8(task.resume_phase);
        w.i32(task.focus_index);
        w.i32(task.current_observation_cell);
        w.i32(task.observer_tries);
        for (int32_t cell : task.reached_observer_cells) w.i32(cell);
        w.u32(task.tried_observer_mask);
        w.i64(task.started_day);
        w.i64(task.last_progress_day);
        w.i64(task.last_plan_day);
        w.i64(task.complete_day);
        w.u8(task.return_fallback);
    }
    w.end();

    w.begin(kSection_IndexContinuation);
    write_index_continuation(w, *this);
    w.end();

    w.u16(kSection_End);
    w.u32(PKMI_MAGIC ^ (uint32_t)w.out.size());
    return w.out;
}


} // namespace pk

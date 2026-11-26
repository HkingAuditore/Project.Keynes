Dictionary DCWorldExt::get_military_report() {
    if (!_military) {
        Dictionary out = military_unavailable();
        out["configured"] = false;
        return out;
    }
    const auto published = military_executor_active() ? _military->read() : nullptr;
    const auto frame = published ? published->view : read_military_core();
    const MilitaryCore *core = frame.get();
    const MilitaryReport &report = core->report();
    Dictionary out;
    out["background_day"] = published ? published->executor_day : _military->_military_last_background_day;
    out["ok"] = true;
    out["configured"] = core->configured();
    out["day"] = report.day;
    out["military_day_ms"] = report.day_ms;
    out["armies_active"] = static_cast<int64_t>(report.armies_active);
    out["armies_moving"] = static_cast<int64_t>(report.armies_moving);
    out["engagements_active"] = static_cast<int64_t>(report.engagements_active);
    out["astar_expansions"] = report.astar_expansions;
    out["area_evals"] = static_cast<int64_t>(report.area_evals);
    out["threat_field_cells"] = static_cast<int64_t>(report.threat_field_cells);
    out["convoys_due"] = static_cast<int64_t>(report.convoys_due);
    out["convoy_hops"] = report.convoy_hops;
    out["front_edges_touched"] = static_cast<int64_t>(report.front_edges_touched);
    out["vision_patch_cells"] = static_cast<int64_t>(report.vision_patch_cells);
    out["event_coalesced"] = static_cast<int64_t>(report.event_coalesced);
    out["reconcile_delta"] = report.reconcile_delta;
    // Physical maintenance (design §5). These were exported only on the DAILY
    // return dict, so every reader of `get_military_report()` - the panel, the
    // long-run probe - saw nothing and could not tell "the channel is idle" from
    // "the numbers are not published".
    out["maintenance_spend"] = report.maintenance_spend;
    out["maintenance_need_goods"] = report.maintenance_need_goods;
    out["maintenance_met_goods"] = report.maintenance_met_goods;
    out["maintenance_backlog"] = report.maintenance_backlog;
    out["maintenance_rows"] = static_cast<int64_t>(report.maintenance_rows);
    out["maintenance_disrepair_rows"] = static_cast<int64_t>(report.maintenance_disrepair_rows);
    out["maintenance_ms"] = report.maintenance_ms;
    out["intents_emitted"] = static_cast<int64_t>(report.intents_emitted);
    out["wars_active"] = static_cast<int64_t>(report.wars_active);
    out["soldiers_total"] = report.soldiers_total;
    out["idle"] = report.idle != 0;
    // State building cache diagnostics (requirement 6.4). They are transient:
    // a nonzero `state_cache_repairs` means "the economy ledger disagreed with
    // the cache on this day", not "the save is broken".
    out["state_cache_repairs"] = static_cast<int64_t>(report.state_cache_repairs);
    out["state_ledger_unmapped"] = static_cast<int64_t>(report.state_ledger_unmapped);
    out["state_role_mismatch"] = static_cast<int64_t>(report.state_role_mismatch);
    out["configured_units"] = static_cast<int64_t>(core->catalog().units.size());
    out["catalog_hash"] = static_cast<int64_t>(core->catalog().hash);
    out["last_step_day"] = published ? published->last_step_day : _military->_military_last_step_day;
    out["sequence_cursor"] = published ? published->sequence : _military->_military_sequence;
    out["pending_intents"] = published ? published->pending_intents : static_cast<int64_t>(_military->_military_pending_intents.size());
    out["ledger_received"] = core->_ledger_received;
    out["ledger_consumed"] = core->_ledger_consumed;
    out["ledger_stock"] = core->ledger_stock_total();
    out["ledger_transit"] = core->ledger_transit_total();
    out["has_terrain"] = core->terrain().cell_count > 0;
    out["cell_count"] = static_cast<int64_t>(core->terrain().cell_count);
    out["state_hash"] = published ? published->state_hash : static_cast<int64_t>(core->state_hash() & 0x7fffffffffffffffll);
    out["render_revision"] = published ? published->revision : _military->_military_render_revision;
    return out;
}

Dictionary DCWorldExt::get_military_daily_result() const {
    if (military_executor_active()) {
        if (const auto published = _military->read()) return published->result.duplicate(false);
    }
    return {};
}

PackedInt64Array DCWorldExt::capture_military_event_progress() const {
    PackedInt64Array out;
    if (!_military) return out;
    const auto published = military_executor_active() ? _military->read() : nullptr;
    out.append(published ? published->event_cursor : _military->event_cursor);
    out.append(published ? published->event_tick : _military->event_tick);
    out.append(published ? published->events_forwarded : _military->events_forwarded);
    return out;
}

bool DCWorldExt::restore_military_event_progress(const PackedInt64Array &progress) {
    if (!_military || military_executor_active() || progress.size() != 3 ||
        progress[0] < 0 || progress[1] < -1 || progress[2] < 0) return false;
    _military->event_cursor = progress[0];
    _military->event_tick = progress[1];
    _military->events_forwarded = progress[2];
    return true;
}

// Physical maintenance view (design §4 / D7). Read-only: it never mutates the
// core, never books a purchase and never touches the ledger. Everything is a
// Packed array of the same length so the panel can render a table from one poll.
Dictionary DCWorldExt::get_military_maintenance_snapshot(int64_t country) const {
    if (!_military) return military_unavailable();
    const auto frame = read_military_core();
    const MilitaryCore *core = frame.get();
    PackedInt32Array out_country, out_cell, out_kind, out_object, out_ratio,
        out_days, out_disrepair, out_reason;
    PackedInt64Array out_units, out_need, out_stock, out_inbound;
    // `country` follows the facade contract: 0 or -1 means "every country", a
    // positive handle filters to that payer. The GDScript facade probes this
    // method's arity and passes -1 for "all", so both spellings must work.
    const int32_t only_slot = country <= 0
        ? -1 : core->country_slot_for_handle(static_cast<uint64_t>(country));
    const std::vector<MilitaryMaintenanceRow> &rows = core->maintenance_rows();
    for (size_t row_index = 0; row_index < rows.size(); ++row_index) {
        const MilitaryMaintenanceRow &row = rows[row_index];
        if (only_slot >= 0 && row.country_slot != only_slot) continue;
        const std::vector<MilitaryRepairMaterial> *recipe = nullptr;
        if (row.kind == 0) {
            if (row.object_id >= 0 && row.object_id < (int32_t)core->catalog().state_buildings.size())
                recipe = &core->catalog().state_buildings[(size_t)row.object_id].repair_materials;
        } else if (row.object_id >= 0 && row.object_id < (int32_t)core->catalog().units.size()) {
            recipe = &core->catalog().units[(size_t)row.object_id].repair_materials;
        }
        int64_t daily = 0, stock = 0, inbound = 0;
        if (recipe != nullptr) {
            for (const MilitaryRepairMaterial &mat : *recipe) {
                if (mat.good < 0 || mat.rate_q32 <= 0) continue;
                const int64_t per_day = row.kind == 0
                                            ? mat.rate_q32 * (int64_t)std::max(0, row.units)
                                            : (mat.rate_q32 * (int64_t)std::max(0, row.units)) / 100;
                daily += per_day >> 32;
                stock += std::max<int64_t>(0, core->stock_get(row.holder_kind, row.holder,
                                                              row.country_slot, mat.good));
                for (const MilitaryShipment &shipment : core->shipments()) {
                    if (shipment.dest_kind != row.holder_kind || shipment.dest != row.holder ||
                        shipment.country_slot != row.country_slot || shipment.good != mat.good)
                        continue;
                    inbound += std::max<int64_t>(0, shipment.qty);
                }
                for (const MilitaryPurchaseOrder &order : core->purchase_orders()) {
                    if (order.channel != 1 || order.dest_kind != row.holder_kind ||
                        order.dest != row.holder || order.stock_good != mat.good)
                        continue;
                    inbound += std::max<int64_t>(0, order.intent.count);
                }
            }
        }
        int32_t reason = 0;
        if (daily > 0 && stock <= 0) reason = inbound > 0 ? 3 : 1;
        // Diagnostic only (design R1): when the buy pass also refused this row,
        // report WHY. 4 = no spendable cash, 5 = no reachable market row,
        // 6 = an order was queued (so the failure is downstream, at settlement).
        if (daily > 0 && stock <= 0) {
            const std::vector<uint8_t> &buy = core->maintenance_buy_state();
            if (row_index < buy.size()) {
                // Folded back into the PUBLISHED 0..3 contract (design D7) so the
                // panel never sees an undocumented code: 1 = no stock/market,
                // 2 = budget, 3 = transport. The finer internal states (1 no cash,
                // 4 no reachable market row, 5 ordered but unsettled) are what the
                // comment above records.
                const uint8_t state = buy[row_index];
                if (state == 1) reason = 2;
                else if (state == 4) reason = 1;
                else if (state == 5) reason = 3;
            }
        }
        out_country.push_back(row.country_slot);
        out_cell.push_back(row.cell);
        out_kind.push_back((int32_t)row.kind);
        out_object.push_back(row.object_id);
        out_units.push_back((int64_t)row.units);
        out_need.push_back(daily);
        out_stock.push_back(stock);
        out_inbound.push_back(inbound);
        out_ratio.push_back(row.ratio_bp);
        out_days.push_back(daily > 0 ? (int32_t)std::min<int64_t>(INT32_MAX,
                                                                 (stock + inbound) * 10 / daily)
                                     : -1);
        out_disrepair.push_back(row.disrepair ? 1 : 0);
        out_reason.push_back(reason);
    }
    Dictionary out;
    out["ok"] = true;
    out["country_slot"] = out_country;
    out["cell"] = out_cell;
    out["kind"] = out_kind;
    out["object_id"] = out_object;
    out["units"] = out_units;
    out["daily_need_goods"] = out_need;
    out["stock_goods"] = out_stock;
    out["inbound_goods"] = out_inbound;
    out["ratio_bp"] = out_ratio;
    out["days_cover_x10"] = out_days;
    out["disrepair"] = out_disrepair;
    out["shortage_reason"] = out_reason;
    return out;
}

Dictionary DCWorldExt::get_military_country_snapshot(int64_t country) const {
    if (!_military) return military_unavailable();
    const auto frame = read_military_core();
    const MilitaryCore *core = frame.get();
    const int32_t slot = core->country_slot_for_handle(static_cast<uint64_t>(country));
    if (slot < 0) return military_fail("military_country_slot_unknown");
    Dictionary out;
    out["ok"] = true;
    out["country"] = static_cast<int64_t>(core->country_handle_for_slot(slot));
    out["country_slot"] = static_cast<int64_t>(slot);

    // ---- force overview ----
    int64_t militia = 0, trained = 0, in_armies = 0, garrisoned = 0;
    const MilitaryLotStore &lots = core->lots();
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        if (lots.country_slot[i] != slot) continue;
        const int32_t unit = lots.unit_type[i];
        const bool is_militia = unit >= 0 &&
            unit < static_cast<int32_t>(core->catalog().units.size()) &&
            core->catalog().units[static_cast<size_t>(unit)].is_default_militia != 0;
        if (is_militia) militia += lots.count[i];
        else trained += lots.count[i];
        if (lots.location_kind[i] == MILITARY_LOT_ARMY) in_armies += lots.count[i];
        else garrisoned += lots.count[i];
    }
    int64_t training = 0;
    for (const MilitaryTrainingOrder &order : core->training()) {
        if (order.country_slot == slot) training += std::max<int64_t>(0, order.count);
    }
    out["soldiers_total"] = core->country_soldiers(slot);
    out["soldiers_militia"] = militia;
    out["soldiers_trained"] = trained;
    out["soldiers_garrisoned"] = garrisoned;
    out["soldiers_in_armies"] = in_armies;
    out["soldiers_training"] = training;

    // ---- policy / target / config ----
    const std::vector<MilitaryCountryPolicy> &policies = core->policies();
    if (static_cast<size_t>(slot) < policies.size()) {
        const MilitaryCountryPolicy &policy = policies[static_cast<size_t>(slot)];
        out["has_policy"] = true;
        out["target_mode"] = static_cast<int64_t>(policy.target_mode);
        out["target_value"] = policy.target_value;
        out["effective_target"] = policy.effective_target;
        out["levy_enabled"] = policy.levy_enabled != 0;
        out["auto_retrain"] = policy.auto_retrain != 0;
        out["auto_discharge"] = policy.auto_discharge != 0;
        out["quality_policy"] = static_cast<int64_t>(policy.quality_policy);
        out["wage_mode"] = static_cast<int64_t>(policy.wage_mode);
        out["wage_absolute"] = policy.wage_absolute;
        out["procurement_share_bp"] = static_cast<int64_t>(policy.procurement_share_bp);
        // ---- budget envelope (任务 6). `budget_enabled == false` is the
        // documented "no envelope" state: the panel keeps the read-only block
        // and the native settlement keeps the legacy cash-driven path, so both
        // sides agree on what an absent policy means.
        out["budget_share_bp"] = static_cast<int64_t>(policy.budget_share_bp);
        out["budget_enabled"] = policy.budget_share_bp > 0;
        out["budget_wage_bp"] = static_cast<int64_t>(policy.budget_wage_bp);
        out["budget_upkeep_bp"] = static_cast<int64_t>(policy.budget_upkeep_bp);
        // The channel ceilings need the envelope base, which is the country's
        // committed treasury cash (需求 5.1). Publish the split so the panel and
        // the settlement cannot drift apart.
        const MilitaryCore::MilitaryBudgetSplit split =
            core->budget_split(slot, core->last_country_cash(slot));
        out["budget_envelope_daily"] = split.envelope_daily;
        out["budget_wage_daily"] = split.enabled ? split.wage_ceiling : -1;
        out["budget_upkeep_daily"] = split.enabled ? split.upkeep_ceiling : -1;
        out["budget_procurement_daily"] = split.enabled ? split.procurement_ceiling : -1;
        out["pay_ratio_30_q16"] = static_cast<int64_t>(policy.pay_ratio_30_q16);
        out["spend_payroll_30"] = policy.spend_payroll_30;
        out["spend_procurement_30"] = policy.spend_procurement_30;
        out["spend_upkeep_30"] = policy.spend_upkeep_30;
        // ---- budget settlement outcome (任务 7 / 需求 5.2, 5.3, 7.1) -------
        // Per-step, non-cumulative: these describe the LAST settled day, so the
        // panel paints today's shortfall/overspend and forgets it tomorrow. All
        // six stay 0 when the country has no envelope.
        out["budget_wage_demand"] = policy.wage_demand;
        out["budget_wage_arrears"] = policy.wage_arrears;
        out["budget_wage_overspend"] = policy.wage_overspend;
        out["budget_upkeep_demand"] = policy.upkeep_demand;
        out["budget_upkeep_arrears"] = policy.upkeep_arrears;
        out["budget_upkeep_overspend"] = policy.upkeep_overspend;
        // ---- procurement quota outcome (任务 8 / 需求 5.4, 6.2, 7.1) ------
        // `procurement_budget_used` is money committed to markets on the last
        // procurement pass, read off the same `cost` the intents carry, so it
        // reconciles with the treasury one-for-one. `procurement_deferred_units`
        // is the need-unit gap the QUOTA refused (not the gap no market could
        // fill), which is what the panel labels 待购. Both stay 0 with no
        // envelope, so a country without budget control looks exactly as before.
        out["budget_procurement_used"] = policy.procurement_budget_used;
        out["budget_procurement_deferred_units"] = policy.procurement_deferred_units;
        out["per_soldier_cost"] = policy.per_soldier_cost;
        // The per-head DAILY WAGE both pay paths use (army-pay contract §2.2):
        // ABSOLUTE takes the policy value, AUTO is living cost x the MSTAT_WAGE
        // stat. `country_soldier_living_cost` is the input the AUTO branch reads,
        // published so a test can recompute the same number instead of guessing.
        out["daily_wage"] = core->soldier_daily_wage(slot);
        out["soldier_living_cost"] = core->soldier_living_cost(slot);
        PackedInt32Array shares;
        shares.resize(static_cast<int64_t>(policy.config_share_bp.size()));
        for (int64_t i = 0; i < shares.size(); ++i)
            shares[i] = policy.config_share_bp[static_cast<size_t>(i)];
        out["config_share_bp"] = shares;
    } else {
        out["has_policy"] = false;
    }

    // ---- barracks (cell states + posts) ----
    Array barracks;
    int64_t posts_total = 0;
    const std::vector<MilitaryCellState> &states = core->cell_states();
    for (const MilitaryCellState &state : states) {
        if (state.cell < 0) continue;
        int32_t building_count = 0;
        for (int32_t tier = 0; tier < 8; ++tier) building_count += state.barracks_count[tier];
        const int32_t posts = core->posts_for_cell(state.cell, slot);
        if (building_count == 0 && posts == 0 && state.quota == 0) continue;
        Dictionary row;
        row["cell"] = static_cast<int64_t>(state.cell);
        row["post_count"] = static_cast<int64_t>(posts);
        row["present"] = core->present_for_cell(state.cell);
        row["open"] = static_cast<int64_t>(std::max<int64_t>(
            0, posts - core->present_for_cell(state.cell) - state.pending_enlist));
        row["quota"] = state.quota;
        row["pending_enlist"] = state.pending_enlist;
        row["paused"] = state.paused != 0;
        row["disrepair"] = state.disrepair != 0;
        row["fort_tier"] = static_cast<int64_t>(state.fort_tier);
        row["college_tier"] = static_cast<int64_t>(state.college_tier);
        barracks.push_back(row);
        posts_total += posts;
    }
    out["barracks"] = barracks;
    out["post_count"] = posts_total;

    // ---- training queue ----
    Array queue;
    for (const MilitaryTrainingOrder &order : core->training()) {
        if (order.country_slot != slot) continue;
        Dictionary row;
        row["id"] = static_cast<int64_t>(order.id);
        row["cell"] = static_cast<int64_t>(order.cell);
        row["from_unit"] = static_cast<int64_t>(order.from_unit);
        row["to_unit"] = static_cast<int64_t>(order.to_unit);
        row["count"] = order.count;
        row["days_total"] = static_cast<int64_t>(order.days_total);
        row["days_done"] = static_cast<int64_t>(order.days_done);
        row["equipment_ready"] = order.equipment_ready != 0;
        row["quality_q8"] = static_cast<int64_t>(order.quality_q8);
        queue.push_back(row);
    }
    out["training"] = queue;

    // ---- wars ----
    Array wars;
    for (const MilitaryWar &war : core->wars()) {
        if (!war.active) continue;
        if (war.attacker_slot != slot && war.defender_slot != slot) continue;
        const bool attacker = war.attacker_slot == slot;
        int32_t score = war.score_battle_q16 + war.score_annihilation_q16 +
            war.score_attrition_q16;
        if (!attacker) score = -score;
        Dictionary row;
        row["war_id"] = static_cast<int64_t>(war.id);
        row["attacker_slot"] = static_cast<int64_t>(war.attacker_slot);
        row["defender_slot"] = static_cast<int64_t>(war.defender_slot);
        row["start_day"] = war.start_day;
        row["score_q16"] = static_cast<int64_t>(score);
        row["attacker_losses"] = war.attacker_losses;
        row["defender_losses"] = war.defender_losses;
        row["fully_occupied"] = (attacker ? war.fully_occupied_since_b
                                         : war.fully_occupied_since_a) >= 0;
        wars.push_back(row);
    }
    out["wars"] = wars;
    out["wars_active"] = static_cast<int64_t>(wars.size());
    return out;
}

Array DCWorldExt::get_military_armies(int64_t country) const {
    Array out;
    if (!_military) return out;
    const auto frame = read_military_core();
    const MilitaryCore *core = frame.get();
    const int32_t slot = core->country_slot_for_handle(static_cast<uint64_t>(country));
    if (slot < 0) {
        // 0 means "every army", which the map UI uses for the overview.
        if (country != 0) return out;
    }
    const MilitaryArmyStore &armies = core->armies();
    for (int32_t i = 0; i < static_cast<int32_t>(armies.active.size()); ++i) {
        if (!armies.active[static_cast<size_t>(i)]) continue;
        if (country != 0 && armies.owner_slot[static_cast<size_t>(i)] != slot) continue;
        Dictionary row;
        row["handle"] = static_cast<int64_t>(core->army_handle(i));
        row["owner_slot"] = static_cast<int64_t>(armies.owner_slot[static_cast<size_t>(i)]);
        row["cell"] = static_cast<int64_t>(armies.cell[static_cast<size_t>(i)]);
        row["headcount"] = armies.cached_headcount[static_cast<size_t>(i)];
        row["attack_q16"] = armies.cached_attack_q16[static_cast<size_t>(i)];
        row["defense_q16"] = armies.cached_defense_q16[static_cast<size_t>(i)];
        row["speed_q16"] = static_cast<int64_t>(armies.cached_speed_q16[static_cast<size_t>(i)]);
        row["morale_q16"] = static_cast<int64_t>(armies.morale_q16[static_cast<size_t>(i)]);
        row["organization_q16"] = static_cast<int64_t>(
            armies.organization_q16[static_cast<size_t>(i)]);
        row["supply_ratio_q16"] = static_cast<int64_t>(
            armies.supply_ratio_q16[static_cast<size_t>(i)]);
        row["ration_ratio_q16"] = static_cast<int64_t>(
            armies.ration_ratio_q16[static_cast<size_t>(i)]);
        row["pay_ratio_q16"] = static_cast<int64_t>(armies.pay_ratio_q16[static_cast<size_t>(i)]);
        row["stance"] = static_cast<int64_t>(armies.stance[static_cast<size_t>(i)]);
        row["mission"] = static_cast<int64_t>(armies.mission[static_cast<size_t>(i)]);
        row["target_cell"] = static_cast<int64_t>(armies.target_cell[static_cast<size_t>(i)]);
        row["engagement"] = static_cast<int64_t>(armies.engagement[static_cast<size_t>(i)]);
        row["moved_day"] = armies.moved_day[static_cast<size_t>(i)];
        row["prev_cell"] = static_cast<int64_t>(armies.prev_cell[static_cast<size_t>(i)]);
        row["reinforce_enabled"] = armies.reinforce_enabled[static_cast<size_t>(i)] != 0;
        row["name_seed"] = static_cast<int64_t>(armies.name_seed[static_cast<size_t>(i)]);
        out.push_back(row);
    }
    return out;
}

Dictionary DCWorldExt::get_military_army(int64_t army) {
    if (!_military) return military_unavailable();
    const auto published = military_executor_active() ? _military->read() : nullptr;
    const auto frame = published ? published->view : read_military_core();
    const MilitaryCore *core = frame.get();
    int32_t slot = -1;
    if (!core->resolve_army(static_cast<uint64_t>(army), slot))
        return military_fail("military_army_unknown");
    const MilitaryArmyStore &armies = core->armies();
    const size_t s = static_cast<size_t>(slot);
    Dictionary out;
    out["ok"] = true;
    out["handle"] = static_cast<int64_t>(core->army_handle(slot));
    out["owner_slot"] = static_cast<int64_t>(armies.owner_slot[s]);
    out["cell"] = static_cast<int64_t>(armies.cell[s]);
    out["next_cell"] = static_cast<int64_t>(armies.next_cell[s]);
    out["headcount"] = armies.cached_headcount[s];
    out["attack_q16"] = armies.cached_attack_q16[s];
    out["defense_q16"] = armies.cached_defense_q16[s];
    out["speed_q16"] = static_cast<int64_t>(armies.cached_speed_q16[s]);
    out["organization_q16"] = static_cast<int64_t>(armies.organization_q16[s]);
    out["morale_q16"] = static_cast<int64_t>(armies.morale_q16[s]);
    out["supply_ratio_q16"] = static_cast<int64_t>(armies.supply_ratio_q16[s]);
    out["ration_ratio_q16"] = static_cast<int64_t>(armies.ration_ratio_q16[s]);
    out["pay_ratio_q16"] = static_cast<int64_t>(armies.pay_ratio_q16[s]);
    out["stance"] = static_cast<int64_t>(armies.stance[s]);
    out["mission"] = static_cast<int64_t>(armies.mission[s]);
    out["target_cell"] = static_cast<int64_t>(armies.target_cell[s]);
    out["area_id"] = static_cast<int64_t>(armies.area_id[s]);
    out["engagement"] = static_cast<int64_t>(armies.engagement[s]);
    out["move_points_q16"] = static_cast<int64_t>(armies.move_points_q16[s]);
    out["reinforce_enabled"] = armies.reinforce_enabled[s] != 0;
    out["funds"] = armies.funds[s];
    // ---- personnel lane (army-personnel contract §2.1) --------------------
    // `headcount` is what Military books; `personnel` is what Economy actually
    // holds in the formation's lane row. They are the same people and must stay
    // equal, so both are reported (an older economy without the lane bindings
    // reports the military book and lane_supported = false).
    // Lane cash: what the formation's people actually hold in Economy. Army pay
    // (contract §3) lands here, so the smoke test asserts on this instead of the
    // Military-side `funds` mirror, which only the pre-lane bookkeeping touched.
    const int64_t lane_population = published
        ? (published->lane_supported ? published->lane_population[s] : -1)
        : economy_army_lane_population(_economy_runtime, core->army_handle(slot));
    const int64_t lane_funds = published
        ? (published->lane_supported ? published->lane_funds[s] : -1)
        : economy_army_lane_funds(_economy_runtime, core->army_handle(slot));
    out["lane_supported"] = published ? published->lane_supported : economy_army_lane_supported(_economy_runtime);
    out["lane_population"] = lane_population;
    out["lane_funds"] = lane_funds;
    out["lane_pay_supported"] = published ? published->lane_pay_supported :
        army_lane_pay_supported(static_cast<const NativeEconomyRuntime *>(_economy_runtime));
    out["personnel"] = lane_population >= 0 ? lane_population : armies.cached_headcount[s];
    out["personnel_pending"] = core->army_lane_pending(slot);
    // Ration still in the formation's store (need units of the ration class).
    out["ration_stock"] = core->stock_units(armies.owner_slot[s], MILITARY_LOT_ARMY,
        slot, MILITARY_SUPPLY_RATION);
    out["moved_day"] = armies.moved_day[s];
    out["prev_cell"] = static_cast<int64_t>(armies.prev_cell[s]);
    out["name_seed"] = static_cast<int64_t>(armies.name_seed[s]);
    // commander: v1 keeps the seat open (design §6.4).
    Dictionary commander;
    commander["open"] = true;
    commander["slot"] = static_cast<int64_t>(armies.commander_slot[s]);
    commander["handle"] = static_cast<int64_t>(0);
    out["commander"] = commander;
    // ---- composition ----
    Array composition;
    const MilitaryLotStore &lots = core->lots();
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        if (lots.location_kind[i] != MILITARY_LOT_ARMY || lots.location[i] != slot) continue;
        Dictionary row;
        row["unit"] = static_cast<int64_t>(lots.unit_type[i]);
        row["count"] = lots.count[i];
        row["quality_q8"] = static_cast<int64_t>(lots.equip_quality_q8[i]);
        row["condition_q16"] = static_cast<int64_t>(lots.condition_q16[i]);
        composition.push_back(row);
    }
    out["composition"] = composition;
    // ---- supply days by class ----
    PackedInt64Array supply_days;
    supply_days.resize(MILITARY_SUPPLY_CLASSES);
    for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES; ++cls) {
        const int64_t units = core->stock_units(armies.owner_slot[s],
            MILITARY_LOT_ARMY, slot, cls);
        supply_days[cls] = armies.cached_headcount[s] > 0
            ? units * 100 / std::max<int64_t>(1, armies.cached_headcount[s]) : 0;
    }
    out["supply_days"] = supply_days;
    // ---- convoys bound for this army ----
    Array convoys;
    for (const MilitaryShipment &shipment : core->shipments()) {
        if (shipment.qty <= 0) continue;
        if (shipment.dest_kind != 1 || shipment.dest != slot) continue;
        Dictionary row;
        row["id"] = static_cast<int64_t>(shipment.id);
        row["good"] = static_cast<int64_t>(shipment.good);
        row["qty"] = shipment.qty;
        row["current_cell"] = static_cast<int64_t>(shipment.current_cell);
        row["eta_day"] = shipment.eta_day;
        row["progress_q16"] = static_cast<int64_t>(shipment.progress_q16);
        convoys.push_back(row);
    }
    out["convoys"] = convoys;
    // ---- path preview ----
    PackedInt32Array path;
    const int32_t path_begin = armies.path_cursor[s];
    for (int32_t k = path_begin; k < armies.path_len[s]; ++k) {
        const int32_t offset = armies.path_offset[s] + k;
        if (offset < 0 || static_cast<size_t>(offset) >= core->_path_cells.size()) break;
        path.push_back(core->_path_cells[static_cast<size_t>(offset)]);
    }
    out["path"] = path;
    // ---- player auto-exploration (counts only; never the 256-cell selection)
    Dictionary exploration;
    const MilitaryExplorationTask *explore_task =
        core->exploration_task_for_army(slot);
    if (explore_task != nullptr) {
        int32_t seen = 0, visited = 0, blocked = 0, resolved = 0;
        for (int32_t i = 0; i < explore_task->selected_count; ++i) {
            const size_t word = static_cast<size_t>(i >> 6);
            const uint64_t bit = 1ull << static_cast<uint32_t>(i & 63);
            const bool is_seen = (explore_task->seen_mask[word] & bit) != 0;
            const bool is_visited = (explore_task->visited_mask[word] & bit) != 0;
            const bool is_blocked = (explore_task->blocked_mask[word] & bit) != 0;
            if (is_seen) ++seen;
            if (is_visited) ++visited;
            if (is_blocked) ++blocked;
            if (is_seen || is_visited || is_blocked) ++resolved;
        }
        exploration["phase"] = static_cast<int64_t>(explore_task->phase);
        exploration["result"] = static_cast<int64_t>(explore_task->result);
        exploration["pause_reason"] = static_cast<int64_t>(explore_task->pause_reason);
        exploration["selected"] = static_cast<int64_t>(explore_task->selected_count);
        exploration["resolved"] = static_cast<int64_t>(resolved);
        exploration["seen"] = static_cast<int64_t>(seen);
        exploration["visited"] = static_cast<int64_t>(visited);
        exploration["blocked"] = static_cast<int64_t>(blocked);
        exploration["origin"] = static_cast<int64_t>(explore_task->origin_cell);
        exploration["return"] = static_cast<int64_t>(explore_task->return_cell);
        exploration["started_day"] = explore_task->started_day;
        exploration["last_progress_day"] = explore_task->last_progress_day;
        exploration["complete_day"] = explore_task->complete_day;
        exploration["return_fallback"] =
            static_cast<int64_t>(explore_task->return_fallback);
    }
    out["exploration"] = exploration;
    return out;
}

Dictionary DCWorldExt::get_military_cell_snapshot(int64_t cell, int64_t observer) const {
    if (!_military) return military_unavailable();
    (void)observer;  // v1: the military roster is not fog-filtered
    const auto frame = read_military_core();
    const MilitaryCore *core = frame.get();
    if (cell < 0 || cell >= core->terrain().cell_count)
        return military_fail("military_cell_out_of_range");
    const int32_t c = static_cast<int32_t>(cell);
    // Owner comes from Country (Military only stores controllers).
    int32_t owner_slot = -1;
    if (_country_runtime != nullptr)
        owner_slot = country_api::country_slot_for_cell(
            *static_cast<NativeCountryRuntime *>(_country_runtime), c);
    const int32_t controller = core->controller_of(c);
    Dictionary out;
    out["ok"] = true;
    out["cell"] = static_cast<int64_t>(c);
    out["owner_slot"] = static_cast<int64_t>(owner_slot);
    out["controller_slot"] = static_cast<int64_t>(
        controller >= 0 ? controller : owner_slot);
    out["post_count"] = static_cast<int64_t>(core->posts_for_cell(c, owner_slot));
    out["present"] = core->present_for_cell(c);
    out["garrison"] = core->present_for_cell(c);
    int64_t quota = 0, pending = 0, fort_tier = -1, college_tier = -1;
    bool paused = false, disrepair = false;
    // Per-tier barracks counts and running state builds, so the tile dossier can
    // show "how many of which tier" and target a demolish at the exact catalog
    // row instead of guessing from `post_count`.
    PackedInt32Array barracks_tiers;
    barracks_tiers.resize(MILITARY_STATE_BARRACKS_TIERS);
    barracks_tiers.fill(0);
    PackedInt32Array construction_buildings;
    construction_buildings.resize(MILITARY_STATE_BUILD_SLOTS);
    construction_buildings.fill(-1);
    PackedInt32Array construction_done_days;
    construction_done_days.resize(MILITARY_STATE_BUILD_SLOTS);
    construction_done_days.fill(-1);
    for (const MilitaryCellState &state : core->cell_states()) {
        if (state.cell != c) continue;
        quota = state.quota;
        pending = state.pending_enlist;
        fort_tier = state.fort_tier;
        college_tier = state.college_tier;
        paused = state.paused != 0;
        disrepair = state.disrepair != 0;
        for (int32_t tier = 0; tier < MILITARY_STATE_BARRACKS_TIERS; ++tier)
            barracks_tiers[tier] = state.barracks_count[tier];
        for (int32_t k = 0; k < MILITARY_STATE_BUILD_SLOTS; ++k) {
            construction_buildings[k] = state.construction_building[k];
            construction_done_days[k] = static_cast<int32_t>(std::clamp<int64_t>(
                state.construction_done_day[k], -1,
                std::numeric_limits<int32_t>::max()));
        }
        break;
    }
    out["quota"] = quota;
    out["pending_enlist"] = pending;
    out["fort_tier"] = fort_tier;
    out["college_tier"] = college_tier;
    out["paused"] = paused;
    out["disrepair"] = disrepair;
    out["barracks_tiers"] = barracks_tiers;
    out["construction_buildings"] = construction_buildings;
    out["construction_done_days"] = construction_done_days;
    // Garrison composition (lots located in this cell).
    Array garrison;
    const MilitaryLotStore &lots = core->lots();
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        if (lots.location_kind[i] != MILITARY_LOT_GARRISON || lots.location[i] != c) continue;
        Dictionary row;
        row["country_slot"] = static_cast<int64_t>(lots.country_slot[i]);
        row["unit"] = static_cast<int64_t>(lots.unit_type[i]);
        row["count"] = lots.count[i];
        row["quality_q8"] = static_cast<int64_t>(lots.equip_quality_q8[i]);
        garrison.push_back(row);
    }
    out["garrison_lots"] = garrison;
    // Visiting armies (design §5.4 "in-station / foreign").
    Array armies_here;
    const MilitaryArmyStore &armies = core->armies();
    for (size_t i = 0; i < armies.active.size(); ++i) {
        if (!armies.active[i] || armies.cell[i] != c) continue;
        Dictionary row;
        row["handle"] = static_cast<int64_t>(core->army_handle(static_cast<int32_t>(i)));
        row["owner_slot"] = static_cast<int64_t>(armies.owner_slot[i]);
        row["headcount"] = armies.cached_headcount[i];
        row["foreign"] = armies.owner_slot[i] != owner_slot;
        armies_here.push_back(row);
    }
    out["armies"] = armies_here;
    // Local training queue.
    Array training;
    for (const MilitaryTrainingOrder &order : core->training()) {
        if (order.cell != c) continue;
        Dictionary row;
        row["id"] = static_cast<int64_t>(order.id);
        row["country_slot"] = static_cast<int64_t>(order.country_slot);
        row["from_unit"] = static_cast<int64_t>(order.from_unit);
        row["to_unit"] = static_cast<int64_t>(order.to_unit);
        row["count"] = order.count;
        row["days_done"] = static_cast<int64_t>(order.days_done);
        row["days_total"] = static_cast<int64_t>(order.days_total);
        training.push_back(row);
    }
    out["training"] = training;
    return out;
}

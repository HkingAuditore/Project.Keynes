Dictionary DCWorldExt::get_military_render_snapshot(int64_t after_revision) {
    if (!_military) {
        Dictionary out = military_unavailable();
        out["available"] = false;
        out["revision"] = after_revision;
        return out;
    }
    const auto published = military_executor_active() ? _military->read() : nullptr;
    const auto frame = published ? published->view : read_military_core();
    int64_t revision = _military_render_selection_revision +
        (published ? published->revision : _military->_military_render_revision);
    const MilitaryCore *core = frame.get();
    Dictionary out;
    out["ok"] = true;
    out["available"] = true;
    out["revision"] = revision;
    const int64_t control_revision = static_cast<int64_t>(core->control_revision());
    const int64_t front_revision = static_cast<int64_t>(core->front_revision());
    out["control_revision"] = control_revision;
    out["front_revision"] = front_revision;
    if (after_revision == revision &&
        control_revision == _military_render_control_revision &&
        front_revision == _military_render_front_revision) {
        // Unchanged: the feed keeps its previous arrays and does no work.
        out["unchanged"] = true;
        return out;
    }
    out["unchanged"] = false;
    if (after_revision > revision) {
        _military_render_selection_revision += after_revision - revision;
        revision = after_revision;
    }
    _military_render_control_revision = control_revision;
    _military_render_front_revision = front_revision;
    // ---- armies ----
    const MilitaryArmyStore &armies = core->armies();
    int32_t army_count = 0;
    for (size_t i = 0; i < armies.active.size(); ++i)
        if (armies.active[i]) ++army_count;
    PackedInt64Array handle, headcount, composition_weight;
    PackedInt32Array owner, cell, prev_cell, moved_day, flags;
    PackedInt32Array composition_offsets, composition_unit;
    PackedInt32Array heading_q16, attack_seq, hit_seq;
    PackedByteArray unit_class;
    handle.resize(army_count);
    headcount.resize(army_count);
    owner.resize(army_count);
    cell.resize(army_count);
    prev_cell.resize(army_count);
    moved_day.resize(army_count);
    flags.resize(army_count);
    unit_class.resize(army_count);
    composition_offsets.resize(static_cast<int64_t>(army_count) + 1);
    composition_offsets[0] = 0;
    composition_unit.resize(static_cast<int64_t>(army_count) * 3);
    composition_weight.resize(static_cast<int64_t>(army_count) * 3);
    heading_q16.resize(army_count);
    attack_seq.resize(army_count);
    hit_seq.resize(army_count);
    std::vector<int32_t> army_lane(armies.active.size(), -1);
    std::vector<int32_t> dominant_lot_unit(army_count, -1);
    std::vector<int64_t> dominant_lot_count(army_count, 0);
    int32_t lane = 0;
    for (int32_t i = 0; i < static_cast<int32_t>(armies.active.size()); ++i) {
        if (!armies.active[static_cast<size_t>(i)]) continue;
        army_lane[static_cast<size_t>(i)] = lane;
        handle[lane] = static_cast<int64_t>(core->army_handle(i));
        owner[lane] = armies.owner_slot[static_cast<size_t>(i)];
        cell[lane] = armies.cell[static_cast<size_t>(i)];
        prev_cell[lane] = armies.prev_cell[static_cast<size_t>(i)];
        moved_day[lane] = static_cast<int32_t>(std::clamp<int64_t>(
            armies.moved_day[static_cast<size_t>(i)], -1,
            std::numeric_limits<int32_t>::max()));
        headcount[lane] = armies.cached_headcount[static_cast<size_t>(i)];
        int32_t bits = 0;
        if (armies.supply_ratio_q16[static_cast<size_t>(i)] < MILITARY_Q / 2) bits |= 1 << 0;
        if (armies.ration_ratio_q16[static_cast<size_t>(i)] < MILITARY_Q / 4) bits |= 1 << 1;
        if (armies.pay_ratio_q16[static_cast<size_t>(i)] < (MILITARY_Q * 6) / 10) bits |= 1 << 2;
        if (armies.morale_q16[static_cast<size_t>(i)] < (MILITARY_Q * 4) / 10) bits |= 1 << 3;
        if (armies.engagement[static_cast<size_t>(i)] >= 0) bits |= 1 << 4;
        if (armies.stance[static_cast<size_t>(i)] == MILITARY_STANCE_RETREAT) bits |= 1 << 5;
        flags[lane] = bits;
        heading_q16[lane] = 0;  // East; runtime quad rotation supplies other headings.
        attack_seq[lane] = 0;
        hit_seq[lane] = 0;
        ++lane;
    }

    // Aggregate army lots once by (army lane, dense unit id), then derive both
    // the existing dominant class and the new top-three visual composition.
    const MilitaryLotStore &lots = core->lots();
    const size_t unit_count = core->catalog().units.size();
    std::vector<int64_t> unit_weight_by_army(
        static_cast<size_t>(army_count) * unit_count, 0);
    for (size_t lot = 0; lot < lots.active.size(); ++lot) {
        if (!lots.active[lot] || lots.count[lot] <= 0) continue;
        if (lots.location_kind[lot] != MILITARY_LOT_ARMY) continue;
        const int32_t army_slot = lots.location[lot];
        if (army_slot < 0 || static_cast<size_t>(army_slot) >= army_lane.size()) continue;
        const int32_t lot_lane = army_lane[static_cast<size_t>(army_slot)];
        if (lot_lane < 0) continue;
        if (lots.count[lot] > dominant_lot_count[static_cast<size_t>(lot_lane)]) {
            dominant_lot_count[static_cast<size_t>(lot_lane)] = lots.count[lot];
            dominant_lot_unit[static_cast<size_t>(lot_lane)] = lots.unit_type[lot];
        }
        const int32_t unit = lots.unit_type[lot];
        if (unit < 0 || static_cast<size_t>(unit) >= unit_count) continue;
        unit_weight_by_army[static_cast<size_t>(lot_lane) * unit_count +
            static_cast<size_t>(unit)] += lots.count[lot];
    }
    int32_t composition_count = 0;
    for (int32_t row = 0; row < army_count; ++row) {
        const size_t weight_base = static_cast<size_t>(row) * unit_count;
        std::array<int32_t, 3> top_units = {-1, -1, -1};
        for (int32_t term = 0; term < 3; ++term) {
            int32_t best_unit = -1;
            int64_t best_weight = 0;
            for (size_t unit = 0; unit < unit_count; ++unit) {
                const int64_t weight = unit_weight_by_army[weight_base + unit];
                if (weight <= 0) continue;
                bool already_selected = false;
                for (int32_t selected = 0; selected < term; ++selected) {
                    if (top_units[static_cast<size_t>(selected)] ==
                        static_cast<int32_t>(unit)) {
                        already_selected = true;
                        break;
                    }
                }
                if (already_selected) continue;
                if (weight > best_weight ||
                    (weight == best_weight &&
                     (best_unit < 0 || static_cast<int32_t>(unit) < best_unit))) {
                    best_unit = static_cast<int32_t>(unit);
                    best_weight = weight;
                }
            }
            if (best_unit < 0) break;
            top_units[static_cast<size_t>(term)] = best_unit;
            composition_unit[composition_count] = best_unit;
            composition_weight[composition_count] = best_weight;
            ++composition_count;
        }
        composition_offsets[row + 1] = composition_count;
        const int32_t dominant_unit = dominant_lot_unit[static_cast<size_t>(row)];
        unit_class[row] = (dominant_unit >= 0 &&
            static_cast<size_t>(dominant_unit) < unit_count)
            ? core->catalog().units[static_cast<size_t>(dominant_unit)].unit_class : 0;
    }
    composition_unit.resize(composition_count);
    composition_weight.resize(composition_count);
    Dictionary army_rows;
    army_rows["handle"] = handle;
    army_rows["owner_slot"] = owner;
    army_rows["cell"] = cell;
    army_rows["prev_cell"] = prev_cell;
    army_rows["moved_day"] = moved_day;
    army_rows["unit_class"] = unit_class;
    army_rows["headcount"] = headcount;
    army_rows["flags"] = flags;
    army_rows["composition_offsets"] = composition_offsets;
    army_rows["composition_unit"] = composition_unit;
    army_rows["composition_weight"] = composition_weight;
    army_rows["heading_q16"] = heading_q16;
    army_rows["attack_seq"] = attack_seq;
    army_rows["hit_seq"] = hit_seq;
    out["armies"] = army_rows;
    out["army_count"] = static_cast<int64_t>(army_count);
    // ---- engagements ----
    const std::vector<MilitaryEngagement> &engagements = core->engagements();
    int32_t engagement_count = 0;
    for (const MilitaryEngagement &e : engagements)
        if (e.active) ++engagement_count;
    PackedInt32Array e_a, e_b, e_progress, e_attacker;
    PackedByteArray e_battle;
    e_a.resize(engagement_count);
    e_b.resize(engagement_count);
    e_progress.resize(engagement_count);
    e_attacker.resize(engagement_count);
    e_battle.resize(engagement_count);
    int32_t e_lane = 0;
    for (const MilitaryEngagement &e : engagements) {
        if (!e.active) continue;
        e_a[e_lane] = e.cell_a;
        e_b[e_lane] = e.cell_b;
        e_progress[e_lane] = e.progress_q16;
        e_attacker[e_lane] = e.attacker_slot;
        e_battle[e_lane] = e.days_since_battle == 0 ? 1 : 0;
        ++e_lane;
    }
    Dictionary engagement_rows;
    engagement_rows["cell_a"] = e_a;
    engagement_rows["cell_b"] = e_b;
    engagement_rows["progress_q16"] = e_progress;
    engagement_rows["attacker_slot"] = e_attacker;
    engagement_rows["battle"] = e_battle;
    out["engagements"] = engagement_rows;
    out["engagement_count"] = static_cast<int64_t>(engagement_count);
    // ---- convoys ----
    const std::vector<MilitaryShipment> &shipments = core->shipments();
    int32_t convoy_count = 0;
    for (const MilitaryShipment &s : shipments)
        if (s.qty > 0) ++convoy_count;
    PackedInt32Array c_current, c_dest, c_country, c_risk;
    c_current.resize(convoy_count);
    c_dest.resize(convoy_count);
    c_country.resize(convoy_count);
    c_risk.resize(convoy_count);
    int32_t c_lane = 0;
    for (const MilitaryShipment &s : shipments) {
        if (s.qty <= 0) continue;
        c_current[c_lane] = s.current_cell;
        c_dest[c_lane] = s.dest_kind == 0 ? s.dest : -1;
        c_country[c_lane] = s.country_slot;
        // Risk proxy: stretch of contested route already covered.
        c_risk[c_lane] = std::clamp<int32_t>(s.route_cost_q16, 0, MILITARY_Q * 4);
        ++c_lane;
    }
    Dictionary convoy_rows;
    convoy_rows["current_cell"] = c_current;
    convoy_rows["dest_cell"] = c_dest;
    convoy_rows["country_slot"] = c_country;
    convoy_rows["risk_q16"] = c_risk;
    out["convoys"] = convoy_rows;
    out["convoy_count"] = static_cast<int64_t>(convoy_count);
    // ---- controllers (sparse) ----
    const std::vector<int32_t> &controllers = core->cell_controller();
    PackedInt32Array controller_cells, controller_slots;
    for (size_t i = 0; i < controllers.size(); ++i) {
        if (controllers[i] < 0) continue;
        controller_cells.push_back(static_cast<int32_t>(i));
        controller_slots.push_back(controllers[i]);
    }
    out["controller_cells"] = controller_cells;
    out["controller_slots"] = controller_slots;
    // ---- front edges (key = cell*6 + dir) ----
    // Progress byte: 255 for a quiet front; when an active engagement sits on
    // the edge, its progress_q16 (attacker perspective) mapped to 0..254.
    const std::vector<uint32_t> &front = core->front_edges();
    const std::vector<int32_t> &neighbors = core->terrain().neighbors;
    PackedInt32Array front_edges;
    PackedByteArray front_progress;
    front_edges.resize(static_cast<int64_t>(front.size()));
    front_progress.resize(static_cast<int64_t>(front.size()));
    for (int64_t i = 0; i < front_edges.size(); ++i) {
        const uint32_t key = front[static_cast<size_t>(i)];
        front_edges[i] = static_cast<int32_t>(key);
        uint8_t progress = 255;
        const int32_t cell_x = static_cast<int32_t>(key / 6u);
        const size_t neighbor_index = static_cast<size_t>(key);
        const int32_t cell_y = neighbor_index < neighbors.size() ? neighbors[neighbor_index] : -1;
        if (cell_y >= 0 && engagement_count > 0) {
            const int32_t lo = std::min(cell_x, cell_y);
            const int32_t hi = std::max(cell_x, cell_y);
            for (const MilitaryEngagement &e : engagements) {
                if (!e.active || e.cell_a != lo || e.cell_b != hi) continue;
                const int64_t q = std::clamp<int64_t>(e.progress_q16, 0, MILITARY_Q);
                progress = static_cast<uint8_t>((q * 254) / MILITARY_Q);
                break;
            }
        }
        front_progress[i] = progress;
    }
    out["front_edges"] = front_edges;
    out["front_progress"] = front_progress;
    // ---- selection (set_military_render_selection) ----
    PackedInt32Array area_cells, path_cells;
    int64_t selected = 0;
    int32_t army_slot = -1;
    if (_military_render_selected_army != 0 &&
        core->resolve_army(static_cast<uint64_t>(_military_render_selected_army), army_slot)) {
        selected = _military_render_selected_army;
        const size_t s = static_cast<size_t>(army_slot);
        const int32_t area_id = armies.area_id[s];
        const std::vector<MilitaryArea> &areas = core->areas();
        if (area_id >= 0 && static_cast<size_t>(area_id) < areas.size() &&
            areas[static_cast<size_t>(area_id)].active) {
            const std::vector<int32_t> &cells_ref = areas[static_cast<size_t>(area_id)].cells;
            area_cells.resize(static_cast<int64_t>(cells_ref.size()));
            for (int64_t k = 0; k < area_cells.size(); ++k)
                area_cells[k] = cells_ref[static_cast<size_t>(k)];
        }
        for (int32_t k = armies.path_cursor[s]; k < armies.path_len[s]; ++k) {
            const int32_t offset = armies.path_offset[s] + k;
            if (offset < 0 || static_cast<size_t>(offset) >= core->_path_cells.size()) break;
            path_cells.push_back(core->_path_cells[static_cast<size_t>(offset)]);
        }
    }
    out["selected_army"] = selected;
    out["selected_area_cells"] = area_cells;
    out["selected_path_cells"] = path_cells;
    return out;
}

Dictionary DCWorldExt::set_military_render_selection(int64_t army) {
    if (!_military) return military_unavailable();
    if (army != 0) {
        int32_t slot = -1;
        if (!read_military_core()->resolve_army(static_cast<uint64_t>(army), slot))
            return military_fail("military_army_unknown");
    }
    Dictionary out;
    out["ok"] = true;
    out["selected_army"] = army;
    out["changed"] = army != _military_render_selected_army;
    if (army != _military_render_selected_army) {
        _military_render_selected_army = army;
        ++_military_render_selection_revision;  // the feed rebuilds on revision change
    }
    const auto published = military_executor_active() ? _military->read() : nullptr;
    out["revision"] = _military_render_selection_revision +
        (published ? published->revision : _military->_military_render_revision);
    return out;
}

Dictionary DCWorldExt::get_military_control_snapshot() const {
    if (!_military) return military_unavailable();
    const auto frame = read_military_core();
    const MilitaryCore *core = frame.get();
    const std::vector<int32_t> &controllers = core->cell_controller();
    PackedInt32Array cells, slots;
    for (size_t i = 0; i < controllers.size(); ++i) {
        if (controllers[i] < 0) continue;
        cells.push_back(static_cast<int32_t>(i));
        slots.push_back(controllers[i]);
    }
    Dictionary out;
    out["ok"] = true;
    out["revision"] = static_cast<int64_t>(core->control_revision());
    out["cells"] = cells;
    out["controller_slots"] = slots;
    out["count"] = cells.size();
    return out;
}

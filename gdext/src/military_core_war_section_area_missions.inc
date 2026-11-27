void MilitaryCore::run_area_missions(const MilitaryWorldDigest &digest) {
    if (_areas.empty()) return;
    int32_t budget = MILITARY_AREA_EVALS_PER_COUNTRY_DAY;
    for (MilitaryArea &area : _areas) {
        if (!area.active) continue;
        const int32_t owner = area.owner_slot;
        if (owner < 0) continue;
        if (budget <= 0) break;
        bool need_eval = digest.day - area.last_eval_day >= 5;
        for (int32_t slot = 0; slot < (int32_t)_armies.active.size() && !need_eval; ++slot) {
            if (!_armies.active[(size_t)slot]) continue;
            if (_armies.owner_slot[(size_t)slot] != owner) continue;
            if (_armies.area_id[(size_t)slot] != area.id) continue;
            if (_armies.mission[(size_t)slot] != (uint8_t)MILITARY_MISSION_AREA_CONTROL) continue;
            if (_armies.target_cell[(size_t)slot] < 0) need_eval = true;
        }
        if (!need_eval) continue;
        area.last_eval_day = digest.day;
        --budget;
        ++_report.area_evals;
        evaluate_area(area, digest);
    }
}

void MilitaryCore::evaluate_area(MilitaryArea &area, const MilitaryWorldDigest &digest) {
    const int32_t owner = area.owner_slot;
    if (owner < 0) return;
    std::vector<int32_t> army_slots;
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        if (_armies.owner_slot[(size_t)slot] != owner) continue;
        if (_armies.area_id[(size_t)slot] != area.id) continue;
        army_slots.push_back(slot);
    }
    if (army_slots.empty()) return;
    std::sort(army_slots.begin(), army_slots.end(), [this](int32_t a, int32_t b) {
        const int64_t sa = _armies.cached_attack_q16[(size_t)a] + _armies.cached_defense_q16[(size_t)a];
        const int64_t sb = _armies.cached_attack_q16[(size_t)b] + _armies.cached_defense_q16[(size_t)b];
        if (sa != sb) return sa > sb;
        return a < b;
    });
    static thread_local std::vector<std::pair<int32_t, int32_t>> reserved;
    reserved.clear();
    for (int32_t slot : army_slots) {
        const size_t s = (size_t)slot;
        // Organisation below 30%: rest on a friendly cell of the area (sec 6.3).
        if (_armies.organization_q16[s] < MILITARY_Q16 * 3 / 10) {
            for (int32_t cell : area.cells) {
                if (cell < 0 || cell >= _terrain.cell_count) continue;
                if (effective_controller(*this, digest, cell) != owner) continue;
                if (_armies.cell[s] == cell) break;
                _armies.target_cell[s] = cell;
                _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
                std::vector<int32_t> path;
                if (find_path(slot, cell, digest, path)) assign_path(slot, path);
                break;
            }
            continue;
        }
        int32_t best_cell = -1;
        int64_t best_score = 0;
        int32_t best_tier = 0;
        for (int32_t cell : area.cells) {
            if (cell < 0 || cell >= _terrain.cell_count) continue;
            const int32_t controller = effective_controller(*this, digest, cell);
            if (controller < 0 || controller == owner) continue;
            if (!at_war(owner, controller)) continue;
            int32_t tier = 0;
            if ((size_t)cell < _terrain.settlement_tier.size()) {
                tier = _terrain.settlement_tier[(size_t)cell];
            }
            const int32_t distance = cell_distance(_armies.cell[s], cell);
            int64_t cell_value = 0;
            if ((size_t)cell < digest.cell_population.size()) {
                cell_value = digest.cell_population[(size_t)cell];
            }
            int64_t score = 0;
            if (tier >= 1) score += cell_value + 100;
            score -= (int64_t)distance * 200;
            for (const std::pair<int32_t, int32_t> &row : reserved) {
                if (row.first == cell) score -= 30 * row.second;
            }
            // Candidate A: an enemy army inside the area.
            for (int32_t other = _cell_head[(size_t)cell]; other >= 0;
                 other = _armies.next_in_cell[(size_t)other]) {
                if (!_armies.active[(size_t)other]) continue;
                if (!at_war(owner, _armies.owner_slot[(size_t)other])) continue;
                score += 150;
                if ((size_t)cell < _threat.size()) score += _threat[(size_t)cell] / 1024;
                break;
            }
            if (best_cell < 0 || score > best_score) {
                best_cell = cell;
                best_score = score;
                best_tier = tier;
            }
        }
        if (best_cell < 0) {
            // Candidate D: hold on the nearest friendly cell.
            for (int32_t cell : area.cells) {
                if (cell < 0 || cell >= _terrain.cell_count) continue;
                if (effective_controller(*this, digest, cell) != owner) continue;
                _armies.target_cell[s] = cell;
                _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
                break;
            }
            continue;
        }
        reserved.push_back({best_cell, 1});
        _armies.target_cell[s] = best_cell;
        _armies.stance[s] = (uint8_t)(best_tier >= 2 ? MILITARY_STANCE_ASSAULT
                                                     : MILITARY_STANCE_ADVANCE);
        std::vector<int32_t> path;
        if (find_path(slot, best_cell, digest, path)) assign_path(slot, path);
    }
}

void MilitaryCore::assign_path(int32_t army_slot, const std::vector<int32_t> &path) {
    if (!army_live(_armies, army_slot)) return;
    const size_t s = (size_t)army_slot;
    _armies.path_offset[s] = (int32_t)_path_cells.size();
    _armies.path_len[s] = (int32_t)path.size();
    _armies.path_cursor[s] = 0;
    _path_cells.insert(_path_cells.end(), path.begin(), path.end());
    _armies.mission[s] = (uint8_t)MILITARY_MISSION_MOVE;
}

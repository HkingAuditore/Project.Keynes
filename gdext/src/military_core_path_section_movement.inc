void MilitaryCore::index_insert(int32_t army_slot, int32_t cell) {
    if (!army_alive(_armies, army_slot)) return;
    if (cell < 0 || (size_t)cell >= _cell_head.size()) return;
    const size_t a = (size_t)army_slot;
    _armies.prev_in_cell[a] = -1;
    _armies.next_in_cell[a] = _cell_head[(size_t)cell];
    if (_cell_head[(size_t)cell] >= 0) _armies.prev_in_cell[(size_t)_cell_head[(size_t)cell]] = army_slot;
    _cell_head[(size_t)cell] = army_slot;
}

void MilitaryCore::index_remove(int32_t army_slot) {
    if (army_slot < 0 || (size_t)army_slot >= _armies.active.size()) return;
    const size_t a = (size_t)army_slot;
    const int32_t prev = _armies.prev_in_cell[a];
    const int32_t next = _armies.next_in_cell[a];
    if (prev >= 0) {
        _armies.next_in_cell[(size_t)prev] = next;
    } else {
        const int32_t cell = _armies.cell[a];
        if (cell >= 0 && (size_t)cell < _cell_head.size()) _cell_head[(size_t)cell] = next;
    }
    if (next >= 0) _armies.prev_in_cell[(size_t)next] = prev;
    _armies.prev_in_cell[a] = -1;
    _armies.next_in_cell[a] = -1;
}

void MilitaryCore::rebuild_cell_index() {
    _cell_head.assign((size_t)std::max(0, _terrain.cell_count), -1);
    for (int32_t i = 0; i < (int32_t)_armies.active.size(); ++i) {
        _armies.prev_in_cell[(size_t)i] = -1;
        _armies.next_in_cell[(size_t)i] = -1;
    }
    for (int32_t i = 0; i < (int32_t)_armies.active.size(); ++i) {
        if (!_armies.active[(size_t)i]) continue;
        const int32_t cell = _armies.cell[(size_t)i];
        if (cell < 0 || (size_t)cell >= _cell_head.size()) continue;
        _armies.next_in_cell[(size_t)i] = _cell_head[(size_t)cell];
        if (_cell_head[(size_t)cell] >= 0) _armies.prev_in_cell[(size_t)_cell_head[(size_t)cell]] = i;
        _cell_head[(size_t)cell] = i;
    }
}

// ============================================================== movement

namespace {

// Contract §2.1: an army standing on water is EMBARKED; landing restores the
// stance it had before embarkation. RETREAT formations are driven by the war
// stage and are left alone.
void sync_sea_stance(MilitaryCore &core, int32_t slot) {
    MilitaryArmyStore &a = core._armies;
    const size_t s = (size_t)slot;
    if (a.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) return;
    const bool at_sea = cell_is_water(core._terrain, a.cell[s]);
    SeaStanceCache &cache = sea_stance_cache();
    cache.ensure(a.active.size());
    const uint32_t generation = a.generation[s];
    if (at_sea) {
        if (a.stance[s] != (uint8_t)MILITARY_STANCE_EMBARKED) {
            cache.stance[s] = (int32_t)a.stance[s];
            cache.generation[s] = generation;
            a.stance[s] = (uint8_t)MILITARY_STANCE_EMBARKED;
        }
        return;
    }
    if (a.stance[s] != (uint8_t)MILITARY_STANCE_EMBARKED) return;
    const bool restored = cache.generation[s] == generation && cache.stance[s] >= 0 &&
                          cache.stance[s] != (int32_t)MILITARY_STANCE_EMBARKED &&
                          cache.stance[s] <= (int32_t)MILITARY_STANCE_RETREAT;
    a.stance[s] = (uint8_t)(restored ? cache.stance[s] : (int32_t)MILITARY_STANCE_HOLD);
    cache.stance[s] = -1;
}

} // namespace

void MilitaryCore::run_movement(const MilitaryWorldDigest &digest) {
    MilitaryArmyStore &a = _armies;
    static thread_local std::vector<uint8_t> touched;
    bool moved_any = false;
    const size_t cells = (size_t)std::max(0, _terrain.cell_count);
    touched.assign(cells, 0);
    int32_t moving = 0;
    // Naval transport: settle the stance of every formation against the cell it
    // occupies before the day's movement, so the embarked exemption below and
    // the sea attrition are never a day behind.
    for (int32_t slot = 0; slot < (int32_t)a.active.size(); ++slot) {
        if (!a.active[(size_t)slot]) continue;
        if (a.owner_slot[(size_t)slot] < 0) continue;
        sync_sea_stance(*this, slot);
    }
    for (int32_t slot = 0; slot < (int32_t)a.active.size(); ++slot) {
        if (!a.active[(size_t)slot]) continue;
        const size_t s = (size_t)slot;
        const int32_t owner = a.owner_slot[s];
        if (owner < 0) continue;
        if (a.path_cursor[s] >= a.path_len[s]) continue;
        // RETREAT formations get their route from the war stage only.
        if (a.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) continue;
        ++moving;
        // ---- daily move budget (design 7.3)
        const int64_t speed_stat = stat_q16(digest, owner, MSTAT_SPEED);
        int64_t mp = a.move_points_q16[s] + mul_div((int64_t)a.cached_speed_q16[s], speed_stat, MILITARY_Q16);
        if (a.supply_ratio_q16[s] < (MILITARY_Q16 / 2)) mp = mul_div(mp, 4, 5);           // supply x0.8
        if (a.organization_q16[s] < (MILITARY_Q16 * 3 / 10)) mp = mul_div(mp, 7, 10);     // org x0.7
        const int64_t mp_cap = (int64_t)MILITARY_Q16 * 8;
        if (mp > mp_cap) mp = mp_cap;
        const bool engaged = a.engagement[s] >= 0;
        const bool exploring = exploration_is_live_for_army(slot);
        while (a.path_cursor[s] < a.path_len[s]) {
            const int32_t idx = a.path_offset[s] + a.path_cursor[s];
            if (idx < 0 || (size_t)idx >= _path_cells.size()) break;
            const int32_t next = _path_cells[(size_t)idx];
            const int32_t cur = a.cell[s];
            if (exploring &&
                !exploration_passable_for(next, owner, digest)) {
                // Exploration never crosses a foreign controller. A route can
                // become stale when control changes between days; stop here and
                // let the next prepare replan instead of opening an engagement.
                a.path_len[s] = 0;
                a.path_cursor[s] = 0;
                a.target_cell[s] = -1;
                a.move_points_q16[s] = 0;
                break;
            }
            const int32_t cost = step_cost_q16(cur, next, owner, digest);
            if (cost < 0) break;                        // lost access: wait
            if (mp < cost) break;                       // out of move points
            // ZOC: an army already in a fight cannot slip past into another
            // cell that is adjacent to a hostile formation (design 7.3).
            if (engaged && has_hostile_adjacent_army(next, owner)) break;
            // Entering an enemy-controlled cell opens an engagement instead of
            // stepping in; the army halts on the border. Water carries no land
            // engagement (design §7.4: a seaborne army never fights on the way),
            // so a sea cell is entered whatever its nominal owner.
            if (!cell_is_water(_terrain, next)) {
                const int32_t owner_next = (size_t)next < digest.cell_owner_slot.size()
                                               ? digest.cell_owner_slot[(size_t)next]
                                               : -1;
                const int32_t ctrl_next = controller_of(next);
                const int32_t effective = ctrl_next >= 0 ? ctrl_next : owner_next;
                if (effective >= 0 && effective != owner) {
                    int32_t defender = has_hostile_adjacent_army(next, owner) ? effective : effective;
                    open_engagement(cur, next, slot, defender);
                    a.path_cursor[s] = a.path_len[s];
                    if (exploration_row_for_army(slot) >= 0) {
                        // Automatic exploration keeps its mission while the
                        // engagement resolves so the next day can resume the
                        // planned phase instead of silently becoming a manual
                        // idle formation.
                        pause_exploration_for_battle(slot);
                    } else {
                        a.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
                    }
                    mp = 0;
                    break;
                }
            }
            // ---- step in
            index_remove(slot);
            a.prev_cell[s] = cur;
            a.cell[s] = next;
            a.moved_day[s] = _last_day;
            index_insert(slot, next);
            // Every actually entered cell feeds the explored-only trail. The
            // final cell remains the ordinary vision source; this is the extra
            // history for multi-cell days.
            record_exploration_trail(slot, owner, next);
            if ((size_t)next < touched.size()) touched[(size_t)next] = 1;
            moved_any = true;
            mp -= cost;
            ++a.path_cursor[s];
        }
        a.move_points_q16[s] = (int32_t)std::min<int64_t>(mp, 0x07FFFFFF);

        // ---- end-of-day losses (design 7.1 / 7.3, contract §2.1)
        const int32_t cell = a.cell[s];
        if (cell < 0 || cell >= _terrain.cell_count) continue;
        int64_t heads = a.cached_headcount[s];
        if (heads <= 0) continue;
        if (cell_is_water(_terrain, cell)) {
            // At sea there is no land environment attrition, but the crossing
            // costs kSeaAttritionBp per day. The dead are booked on the last
            // land cell they left, so Economy never creates a cohort at sea.
            const int64_t bp100 = (int64_t)kSeaAttritionBp * kBp100PerBp;
            int64_t loss = mul_div(heads * bp100, 1, kBp100Scale);
            if (loss <= 0) {
                const int32_t roll = rng_q16(_seed, mix_key(kSeaAttritionKey, (uint64_t)slot), _last_day);
                if ((int64_t)roll * kBp100Scale < heads * bp100) loss = 1;
            }
            if (loss <= 0) continue;
            const int64_t removed = lot_remove_casualties((uint8_t)MILITARY_LOT_ARMY, slot, loss);
            if (removed <= 0) continue;
            int32_t book_cell = cell;
            const int32_t prev = a.prev_cell[s];
            if (prev >= 0 && prev < _terrain.cell_count && !cell_is_water(_terrain, prev)) book_cell = prev;
            emit_army_personnel_loss(slot, book_cell, removed, removed, _attrition_intents);
            refresh_army_cache(slot);
            continue;
        }
        int64_t attr_bp100 = 0;
        const uint8_t lf = _terrain.landform[(size_t)cell];
        const uint8_t veg = _terrain.vegetation[(size_t)cell];
        const uint8_t cv = _terrain.cover[(size_t)cell];
        if ((size_t)lf < _catalog.landform_attrition_bp100.size()) attr_bp100 += _catalog.landform_attrition_bp100[(size_t)lf];
        if ((size_t)veg < _catalog.vegetation_attrition_bp100.size()) attr_bp100 += _catalog.vegetation_attrition_bp100[(size_t)veg];
        if ((size_t)cv < _catalog.cover_attrition_bp100.size()) attr_bp100 += _catalog.cover_attrition_bp100[(size_t)cv];
        if (a.stance[s] == (uint8_t)MILITARY_STANCE_EMBARKED) attr_bp100 = 0;   // at sea: no land attrition
        if (attr_bp100 <= 0) continue;
        const int64_t attr_stat = stat_q16(digest, owner, MSTAT_ATTRITION);
        // bp100 (0.01%) -> fraction; stat divides the loss.
        int64_t loss = mul_div(mul_div(heads * attr_bp100, MILITARY_Q16, attr_stat), 1, kBp100Scale);
        if (loss <= 0) {
            // Sub-one-head attrition is rolled deterministically per (army, day).
            const int32_t roll = rng_q16(_seed, mix_key(0x41545452ull, (uint64_t)slot), _last_day);
            if ((int64_t)roll * kBp100Scale < heads * attr_bp100) loss = 1;
        }
        if (loss <= 0) continue;
        const int64_t removed = lot_remove_casualties((uint8_t)MILITARY_LOT_ARMY, slot, loss);
        if (removed <= 0) continue;
        // Harsh-environment deaths (army-personnel contract §2.1): the formation's
        // people live in an Economy lane row, so the loss is released to the cell
        // the formation died in (opcode 31) and booked there as a casualty in the
        // same D+1 batch. A casualty row alone would target the home cell's
        // soldier cohort, which these men are not part of any more.
        emit_army_personnel_loss(slot, cell, removed, removed, _attrition_intents);
        refresh_army_cache(slot);
    }
    // A formation that ended the day on water is embarked from now on, and one
    // that landed gets its previous stance back in the same frame.
    for (int32_t slot = 0; slot < (int32_t)a.active.size(); ++slot) {
        if (!a.active[(size_t)slot]) continue;
        if (a.owner_slot[(size_t)slot] < 0) continue;
        sync_sea_stance(*this, slot);
    }
    if (moved_any && !touched.empty()) rebuild_cell_index();
    _report.armies_moving = moving;
}

bool MilitaryCore::has_hostile_adjacent_army(int32_t cell, int32_t country_slot) const {
    if (cell < 0 || cell >= _terrain.cell_count) return false;
    const int32_t base = cell * 6;
    for (int32_t d = 0; d < 6; ++d) {
        const int32_t nb = _terrain.neighbors[(size_t)(base + d)];
        if (nb < 0 || (size_t)nb >= _cell_head.size()) continue;
        int32_t a = _cell_head[(size_t)nb];
        while (a >= 0) {
            const int32_t owner = _armies.owner_slot[(size_t)a];
            if (owner >= 0 && owner != country_slot && at_war(country_slot, owner)) return true;
            a = _armies.next_in_cell[(size_t)a];
        }
    }
    return false;
}

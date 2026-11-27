void MilitaryCore::capture_cell(int32_t index, const MilitaryWorldDigest &digest,
                                std::vector<MilitaryIntent> &out) {
    if ((size_t)index >= _engagements.size()) return;
    const MilitaryEngagement e = _engagements[(size_t)index];
    if (!army_live(_armies, e.attacker_slot)) {
        close_engagement(index);
        return;
    }
    const int32_t attacker = _armies.owner_slot[(size_t)e.attacker_slot];
    const int32_t from_cell = _armies.cell[(size_t)e.attacker_slot];
    const int32_t target = (from_cell == e.cell_a) ? e.cell_b : e.cell_a;
    if (target < 0 || target >= _terrain.cell_count) {
        close_engagement(index);
        return;
    }
    const int32_t previous = effective_controller(*this, digest, target);
    // sec 11.2/sec 11.6.1: control change goes as a Country SET_CELL_CONTROL intent.
    MilitaryIntent control;
    control.kind = MILITARY_INTENT_TRANSFER_TERRITORY;
    control.cell = target;
    control.country_a = country_handle_for_slot(previous >= 0 ? previous : attacker);
    control.country_b = country_handle_for_slot(attacker);
    control.count = 0;          // 0 = control change, >0 = cession
    control.amount = 0;
    control.source_id = 0;
    out.push_back(control);
    ++_report.intents_emitted;
    set_controller(target, attacker);
    ++_report.cells_captured;
    if (_event_counter_control < kEventCapControl) {
        MilitaryEvent event;
        event.day = digest.day;
        event.type = MILITARY_EVENT_CELL_CONTROL_CHANGED;
        event.payload_schema = 22;
        event.cell = target;
        event.i0 = (uint64_t)(uint32_t)(attacker >= 0 ? attacker : 0);
        event.i1 = (uint64_t)(uint32_t)(previous >= 0 ? previous : 0);
        event.i2 = (uint64_t)(uint32_t)std::max(0, owner_of_cell(digest, target));
        event.i3 = (uint64_t)((size_t)target < _terrain.settlement_tier.size()
                                  ? _terrain.settlement_tier[(size_t)target]
                                  : 0);
        push_event(event);
        ++_event_counter_control;
    } else {
        ++_report.event_coalesced;
    }
    // Cancel training at the captured cell (sec 11.6.6).
    for (size_t t = 0; t < _training.size();) {
        if (_training[t].cell == target) {
            _training[t] = _training.back();
            _training.pop_back();
            continue;
        }
        ++t;
    }
    // Defender armies retreat or are annihilated (sec 11.6.2/3).
    std::vector<int32_t> defenders;
    for (int32_t other = _cell_head[(size_t)target]; other >= 0;
         other = _armies.next_in_cell[(size_t)other]) {
        if (!_armies.active[(size_t)other]) continue;
        if (_armies.owner_slot[(size_t)other] == attacker) continue;
        defenders.push_back(other);
    }
    for (int32_t other : defenders) {
        retreat_or_annihilate(other, target, attacker, digest, out);
    }
    // The best-organised attacker occupies the cell (sec 11.6.5).
    int32_t best = -1;
    for (int32_t other = _cell_head[(size_t)target]; other >= 0;
         other = _armies.next_in_cell[(size_t)other]) {
        if (!_armies.active[(size_t)other]) continue;
        if (_armies.owner_slot[(size_t)other] != attacker) continue;
        if (best < 0 || _armies.organization_q16[(size_t)other] >
                            _armies.organization_q16[(size_t)best]) {
            best = other;
        }
    }
    if (best < 0 && army_live(_armies, e.attacker_slot)) best = e.attacker_slot;
    if (best >= 0) {
        index_remove(best);
        _armies.prev_cell[(size_t)best] = from_cell;
        _armies.cell[(size_t)best] = target;
        _armies.moved_day[(size_t)best] = digest.day;
        _armies.path_len[(size_t)best] = 0;
        _armies.path_cursor[(size_t)best] = 0;
        if (exploration_is_live_for_army(best)) {
            record_exploration_trail(best, _armies.owner_slot[(size_t)best], target);
            pause_exploration_for_battle(best);
        } else {
            _armies.mission[(size_t)best] = (uint8_t)MILITARY_MISSION_NONE;
        }
        index_insert(best, target);
    }
    // Garrison soldiers of the previous owner fall back with the retreating
    // armies (sec 11.6.4); their cohorts stay Economy-owned at the home cell.
    if (previous >= 0 && previous != attacker) {
        const int64_t garrison = garrison_heads_at(target, previous);
        if (garrison > 0) {
            const int32_t refuge = nearest_friendly_cell(target, previous, digest);
            if (refuge >= 0) {
                const int32_t army = create_army(previous, refuge);
                if (army >= 0) {
                    // Move the trainable garrison heads into the retreat army.
                    military_for_each_lot(*this, (uint8_t)MILITARY_LOT_GARRISON, target, [&](int32_t i) {
                        if (_lots.count[(size_t)i] <= 0) return;
                        if (_lots.country_slot[(size_t)i] != previous) return;
                        const int64_t move = _lots.count[(size_t)i];
                        const int32_t to = lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, army,
                                                              previous, _lots.unit_type[(size_t)i],
                                                              _lots.equip_quality_q8[(size_t)i],
                                                              _lots.kit_q16[(size_t)i],
                                                              _lots.partial_equipment[(size_t)i]);
                        if (to < 0) return;
                        _lots.count[(size_t)to] += move;
                        _lots.count[(size_t)i] = 0;
                    });
                    _armies.organization_q16[(size_t)army] =
                        clamp_q16_i32((int64_t)_armies.organization_q16[(size_t)army] -
                                          kOrgLossCaptureQ16, 0, MILITARY_Q16);
                    refresh_army_cache(army);
                }
            } else {
                // No refuge: the garrison dispersal becomes casualties.
                lot_remove_casualties((uint8_t)MILITARY_LOT_GARRISON, target, garrison);
            }
            transfer_garrison_owner(target, previous, attacker);
        }
    }
    with_war_score(e.war_id, 6 * MILITARY_Q16);
    close_engagement(index);
    update_front_cells({target, from_cell});
    (void)out;
}

void MilitaryCore::retreat_or_annihilate(int32_t army, int32_t from_cell, int32_t victor,
                                         const MilitaryWorldDigest &digest,
                                         std::vector<MilitaryIntent> &out) {
    if (!army_live(_armies, army)) return;
    const int32_t owner = _armies.owner_slot[(size_t)army];
    const int64_t heads = _armies.cached_headcount[(size_t)army];
    int32_t refuge = nearest_friendly_cell(from_cell, owner, digest);
    if (refuge < 0) {
        // Annihilated (sec 11.6.3): 40% dead, 60% routed with zero organisation.
        //
        // Army personnel lane (army-personnel contract §2.1): the formation's
        // people live in an Economy lane row, not in the home cell's soldier
        // cohort, so the lane must be released here or it keeps ghosts forever.
        // One helper emits both rows in batch order: the whole lane returns to the
        // death cell (opcode 31) and the casualty kills the 40% there. Economy
        // clamps each row to what it holds, so no head is counted twice.
        const int64_t dead = mul_div(heads, 4, 10);
        emit_army_personnel_loss(army, from_cell, heads, dead, out);
        if (dead > 0) {
            lot_remove_casualties((uint8_t)MILITARY_LOT_ARMY, army, dead);
            _report.casualties_annihilation += dead;
        }
        // The routed survivors become that cell's garrison — exactly where Economy
        // keeps them after the disembark — so the two books stay equal and a dead
        // army slot never keeps lots nobody can see (soldiers_total counts lots).
        for (size_t i = 0; i < _lots.active.size(); ++i) {
            if (!_lots.active[i] || _lots.count[i] <= 0) continue;
            if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
            if (_lots.location[i] != army) continue;
            const int32_t dest = lot_find_or_create((uint8_t)MILITARY_LOT_GARRISON, from_cell,
                                                    _lots.country_slot[i], _lots.unit_type[i],
                                                    _lots.equip_quality_q8[i], _lots.kit_q16[i],
                                                    _lots.partial_equipment[i]);
            if (dest < 0) continue;
            _lots.count[(size_t)dest] += _lots.count[i];
            _lots.count[i] = 0;
        }
        for (size_t i = 0; i < _lots.active.size(); ++i) {
            if (_lots.active[i] && _lots.count[i] <= 0) {
                _lots.active[i] = 0;
                _lots.free_list.push_back((int32_t)i);
            }
        }
        // The victor seizes the supply stock of the annihilated formation.
        if (victor >= 0) {
            int32_t victor_army = -1;
            for (int32_t other = _cell_head[(size_t)from_cell]; other >= 0;
                 other = _armies.next_in_cell[(size_t)other]) {
                if (!_armies.active[(size_t)other]) continue;
                if (_armies.owner_slot[(size_t)other] != victor) continue;
                victor_army = other;
                break;
            }
            transfer_stock((uint8_t)MILITARY_LOT_ARMY, army, victor_army, victor);
        }
        MilitaryEvent event;
        event.day = digest.day;
        event.type = MILITARY_EVENT_ARMY_DESTROYED;
        event.payload_schema = 21;
        event.cell = from_cell;
        event.i0 = (uint64_t)(uint32_t)(victor >= 0 ? victor : 0);
        event.i1 = (uint64_t)(uint32_t)(owner >= 0 ? owner : 0);
        event.value = heads;
        push_event(event);
        stock_clear_holder((uint8_t)MILITARY_LOT_ARMY, army);
        destroy_army(army);
        return;
    }
    // Retreat: organisation -25% (sec 11.6.2).
    index_remove(army);
    _armies.prev_cell[(size_t)army] = from_cell;
    _armies.cell[(size_t)army] = refuge;
    _armies.moved_day[(size_t)army] = digest.day;
    _armies.stance[(size_t)army] = (uint8_t)MILITARY_STANCE_RETREAT;
    _armies.path_len[(size_t)army] = 0;
    _armies.path_cursor[(size_t)army] = 0;
    if (exploration_is_live_for_army(army)) {
        record_exploration_trail(army, _armies.owner_slot[(size_t)army], refuge);
        pause_exploration_for_battle(army);
    } else {
        _armies.mission[(size_t)army] = (uint8_t)MILITARY_MISSION_NONE;
    }
    _armies.organization_q16[(size_t)army] = clamp_q16_i32(
        (int64_t)_armies.organization_q16[(size_t)army] - kOrgLossCaptureQ16, 0, MILITARY_Q16);
    index_insert(army, refuge);
    ++_report.armies_retreated;
}

int32_t MilitaryCore::nearest_friendly_cell(int32_t from, int32_t owner,
                                            const MilitaryWorldDigest &digest) const {
    if (from < 0 || owner < 0) return -1;
    static thread_local std::vector<int32_t> queue;
    static thread_local std::vector<uint32_t> stamp;
    const int32_t n = _terrain.cell_count;
    if ((int32_t)stamp.size() < n) stamp.assign((size_t)n, 0);
    static thread_local uint32_t generation = 0;
    generation += 1;
    if (generation == 0) {
        std::fill(stamp.begin(), stamp.end(), 0);
        generation = 1;
    }
    queue.clear();
    queue.push_back(from);
    stamp[(size_t)from] = generation;
    size_t head = 0;
    int32_t visited = 0;
    while (head < queue.size() && visited < kBfsExpansionCap) {
        const int32_t cell = queue[head++];
        ++visited;
        if (cell != from && effective_controller(*this, digest, cell) == owner) return cell;
        if ((size_t)cell * 6 + 5 >= _terrain.neighbors.size()) continue;
        for (int32_t dir = 0; dir < 6; ++dir) {
            const int32_t next = _terrain.neighbors[(size_t)(cell * 6 + dir)];
            if (next < 0 || stamp[(size_t)next] == generation) continue;
            if ((size_t)next < _terrain.is_water.size() && _terrain.is_water[(size_t)next]) continue;
            stamp[(size_t)next] = generation;
            queue.push_back(next);
        }
    }
    return -1;
}

int64_t MilitaryCore::garrison_heads_at(int32_t cell, int32_t country_slot) const {
    ++_report.garrison_queries;
    int64_t total = 0;
    auto add = [&](size_t i) {
        ++_report.garrison_lots_visited;
        if (!_lots.active[i]) return;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) return;
        if (_lots.location[i] != cell) return;
        if (country_slot >= 0 && _lots.country_slot[i] != country_slot) return;
        total += _lots.count[i];
    };
    if (_lot_index_ok && _lot_garrison_lookup_complete &&
        _lot_next.size() == _lots.active.size() && cell >= 0 &&
        (size_t)cell < _lot_cell_head.size()) {
        for (int32_t row = _lot_cell_head[(size_t)cell]; row >= 0; row = _lot_next[(size_t)row]) {
            add((size_t)row);
        }
    } else {
        // Do not rebuild here: unlike other lot consumers this query never
        // changed saved continuation lists, including accepted incomplete ones.
        ++_report.garrison_scan_fallbacks;
        for (size_t i = 0; i < _lots.active.size(); ++i) add(i);
    }
    return total;
}

void MilitaryCore::transfer_garrison_owner(int32_t cell, int32_t from, int32_t to) {
    military_for_each_lot(*this, (uint8_t)MILITARY_LOT_GARRISON, cell, [&](int32_t i) {
        // Cession does not know the previous owner, so it calls this with
        // `from = -1`. Treat a negative source as "every garrison lot in the
        // cell"; the previous exact match made the cession path a silent no-op
        // and left the old owner's roster in a cell it no longer owned.
        if (from >= 0 && _lots.country_slot[(size_t)i] != from) return;
        _lots.country_slot[(size_t)i] = to;
    });
}

void MilitaryCore::transfer_stock(uint8_t holder_kind, int32_t from_holder, int32_t to_holder,
                                  int32_t to_country) {
    if (to_holder < 0) {
        stock_clear_holder(holder_kind, from_holder);
        return;
    }
    // Copy into a scratch list first: stock_add may reallocate _stocks.
    static thread_local std::vector<MilitaryStockRow> rows;
    rows.clear();
    for (const MilitaryStockRow &row : _stocks) {
        if (row.holder_kind != holder_kind) continue;
        if (row.holder != from_holder) continue;
        if (row.qty <= 0) continue;
        rows.push_back(row);
    }
    for (const MilitaryStockRow &row : rows) {
        stock_add(holder_kind, to_holder, to_country, row.good, row.qty);
    }
    stock_clear_holder(holder_kind, from_holder);
}

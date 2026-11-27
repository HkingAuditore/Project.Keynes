namespace {
struct WarOccupationTotals {
    bool participant = false;
    bool occupied = false;
    int64_t value = 0;
    int64_t lost = 0;
};

void track_full_occupation(MilitaryWar &war, int64_t day,
                           const WarOccupationTotals &a, const WarOccupationTotals &b) {
    // Preserve the existing rule despite the field name: any lost owned cell
    // sets today's date; no lost cells (including no territory) sets -1.
    war.fully_occupied_since_a = a.occupied ? day : -1;
    war.fully_occupied_since_b = b.occupied ? day : -1;
}

void update_war_score(MilitaryWar &war,
                      const WarOccupationTotals &a, const WarOccupationTotals &b) {
    // Occupation component (sec 12.2): +-60 scaled by value lost / total value.
    const int64_t a_value = a.value;
    const int64_t a_lost = a.lost;
    // The original if/else credited a shared attacker/defender slot only to A.
    const int64_t b_value = war.attacker_slot == war.defender_slot ? 0 : b.value;
    const int64_t b_lost = war.attacker_slot == war.defender_slot ? 0 : b.lost;
    const int64_t total = std::max<int64_t>(a_value + b_value, 1);
    war.score_annihilation_q16 = (int32_t)clamp64(
        mul_div((int64_t)war.score_annihilation_q16 + mul_div(b_lost - a_lost, 60 * MILITARY_Q16, total),
                MILITARY_Q16, 2 * MILITARY_Q16),
        -60 * MILITARY_Q16, 60 * MILITARY_Q16);
    war.score_attrition_q16 = (int32_t)clamp64(war.score_attrition_q16, -10 * MILITARY_Q16,
                                               10 * MILITARY_Q16);
}
} // namespace

// ================================================================ front

namespace {
void index_front_positions(MilitaryCore &core) {
    for (size_t i = 0; i < core._front_edges.size(); ++i) {
        ++core._report.front_position_rows;
        const uint32_t key = core._front_edges[i];
        if ((size_t)key >= core._front_edge_pos.size()) continue;
        int32_t &position = core._front_edge_pos[(size_t)key];
        position = position == -1 ? (int32_t)i : -2;
    }
}

void remove_front_edge(MilitaryCore &core, int32_t key) {
    ++core._report.front_position_lookups;
    const int32_t position = core._front_edge_pos[(size_t)key];
    if (position == -1) return;
    if (position >= 0 && (size_t)position < core._front_edges.size() &&
        core._front_edges[(size_t)position] == (uint32_t)key) {
        const uint32_t moved = core._front_edges.back();
        core._front_edges[(size_t)position] = moved;
        core._front_edges.pop_back();
        if ((size_t)moved < core._front_edge_pos.size() && core._front_edge_pos[(size_t)moved] >= 0)
            core._front_edge_pos[(size_t)moved] = position;
        core._front_edge_pos[(size_t)key] = -1;
        return;
    }
    // Runtime additions are unique and PKMI does not contain front vectors.
    // Still preserve the old first-match swap/pop if derived input has repeats.
    for (size_t i = 0; i < core._front_edges.size(); ++i) {
        ++core._report.front_removal_fallback_rows;
        if (core._front_edges[i] != (uint32_t)key) continue;
        core._front_edges[i] = core._front_edges.back();
        core._front_edges.pop_back();
        break;
    }
    std::fill(core._front_edge_pos.begin(), core._front_edge_pos.end(), -1);
    index_front_positions(core);
}
} // namespace

void MilitaryCore::update_front_cells(const std::vector<int32_t> &touched_cells) {
    if (touched_cells.empty()) return;
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    const size_t edge_total = (size_t)cells * 6;
    if (_front_edge_set.size() < edge_total) _front_edge_set.assign(edge_total, 0);
    if (_front_edge_pos.size() != edge_total) {
        _front_edge_pos.assign(edge_total, -1);
        index_front_positions(*this);
    }
    const int32_t neighbor_total = (int32_t)_terrain.neighbors.size();
    bool changed = false;
    for (int32_t cell : touched_cells) {
        if (cell < 0 || cell >= cells) continue;
        const int32_t controller = effective_controller(*this, _last_digest, cell);
        if ((size_t)cell * 6 + 5 >= (size_t)neighbor_total) continue;
        for (int32_t dir = 0; dir < 6; ++dir) {
            const int32_t key = cell * 6 + dir;
            const int32_t next = _terrain.neighbors[(size_t)key];
            bool front = false;
            if (next >= 0) {
                const int32_t other = effective_controller(*this, _last_digest, next);
                if (controller >= 0 && other >= 0 && controller != other) {
                    front = at_war(controller, other);
                }
            }
            const uint8_t current = _front_edge_set[(size_t)key];
            if (front == (current != 0)) continue;
            _front_edge_set[(size_t)key] = front ? 1 : 0;
            changed = true;
            if (front) {
                int32_t &position = _front_edge_pos[(size_t)key];
                position = position == -1 ? (int32_t)_front_edges.size() : -2;
                _front_edges.push_back((uint32_t)key);
            } else {
                remove_front_edge(*this, key);
            }
            ++_report.front_edges_touched;
        }
    }
    if (changed) _front_revision += 1;
}

// ============================================================ controllers

void MilitaryCore::set_controller(int32_t cell, int32_t controller) {
    if (cell < 0 || cell >= _terrain.cell_count) return;
    if ((size_t)_cell_controller.size() < (size_t)_terrain.cell_count) {
        _cell_controller.assign((size_t)_terrain.cell_count, -1);
    }
    if (_cell_controller[(size_t)cell] == controller) return;
    _cell_controller[(size_t)cell] = controller;
    _control_revision += 1;
    // Supply connectivity is probed against the live controller map (design
    // 9.3), so pushing this cell's dirty flag is enough to refresh it.
    if ((size_t)cell < _cell_owner_dirty.size()) _cell_owner_dirty[(size_t)cell] = 1;
    update_front_cells({cell});
}

void MilitaryCore::clear_controller(int32_t cell) {
    if (cell < 0 || cell >= _terrain.cell_count) return;
    if ((size_t)_cell_controller.size() < (size_t)_terrain.cell_count) {
        _cell_controller.assign((size_t)_terrain.cell_count, -1);
    }
    if (_cell_controller[(size_t)cell] < 0) return;
    _cell_controller[(size_t)cell] = -1;
    _control_revision += 1;
    if ((size_t)cell < _cell_owner_dirty.size()) _cell_owner_dirty[(size_t)cell] = 1;
    update_front_cells({cell});
}

void MilitaryCore::on_cells_ceded_or_annexed(const std::vector<int32_t> &cells, int32_t new_owner) {
    for (int32_t cell : cells) {
        if (cell < 0 || cell >= _terrain.cell_count) continue;
        clear_controller(cell);   // occupation is void after a cession
        transfer_garrison_owner(cell, -1, new_owner >= 0 ? new_owner : 0);
        // Supply connectivity follows the live owner/controller map (design
        // 9.3), so only the ceded cells themselves need a refresh.
        if ((size_t)cell < _cell_owner_dirty.size()) _cell_owner_dirty[(size_t)cell] = 1;
    }
}

// ================================================================ wars day

void MilitaryCore::run_wars(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out) {
    _last_digest = digest;
    if (_country_annual_revenue.size() < digest.country_annual_revenue.size()) {
        _country_annual_revenue.resize(digest.country_annual_revenue.size(), 0);
    }
    for (size_t slot = 0; slot < digest.country_annual_revenue.size(); ++slot) {
        _country_annual_revenue[slot] = digest.country_annual_revenue[slot];
    }
    run_wars_prepared(digest, out);
}

void MilitaryCore::run_wars_prepared(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out) {
    _event_counter_control = 0;
    // Treaty batches queued by commands flush here, before the daily passes.
    if (!_war_intents.empty()) {
        out.insert(out.end(), _war_intents.begin(), _war_intents.end());
        _report.intents_emitted += (int32_t)_war_intents.size();
        _war_intents.clear();
    }
    // Scratch is rebuilt from today's owner, controller, tier and population
    // inputs. It survives neither a day boundary nor a restored world.
    static thread_local std::vector<WarOccupationTotals> totals;
    totals.assign(_policy_handle.size(), {});
    bool has_war = false;
    // Close wars whose participants no longer exist. This also validates both
    // indices before they may address the dense per-country scratch below:
    // country_handle_for_slot returns zero for negative/out-of-range slots.
    for (MilitaryWar &war : _wars) {
        if (!war.active) continue;
        if (country_handle_for_slot(war.attacker_slot) == 0 ||
            country_handle_for_slot(war.defender_slot) == 0) {
            war.active = 0;
            continue;
        }
        totals[(size_t)war.attacker_slot].participant = true;
        totals[(size_t)war.defender_slot].participant = true;
        has_war = true;
    }
    if (has_war) {
        // Every country's additions retain ascending cell order, matching the
        // former per-war scan, including the population's original units.
        for (int32_t cell = 0; cell < _terrain.cell_count; ++cell) {
            ++_report.war_cells_visited;
            const int32_t owner = owner_of_cell(digest, cell);
            if (owner < 0 || (size_t)owner >= totals.size()) continue;
            WarOccupationTotals &sum = totals[(size_t)owner];
            if (!sum.participant) continue;
            int64_t value = cell_value_q16(cell);
            if ((size_t)cell < digest.cell_population.size()) value += digest.cell_population[(size_t)cell];
            sum.value += value;
            if (effective_controller(*this, digest, cell) != owner) {
                sum.occupied = true;
                sum.lost += value;
            }
        }
    }
    for (MilitaryWar &war : _wars) {
        if (!war.active) continue;
        const WarOccupationTotals &a = totals[(size_t)war.attacker_slot];
        const WarOccupationTotals &b = totals[(size_t)war.defender_slot];
        track_full_occupation(war, digest.day, a, b);
        update_war_score(war, a, b);
    }
    front_rebuild(digest);
    // Expire old truce rows so the save stays small.
    _truces.erase(std::remove_if(_truces.begin(), _truces.end(),
                                 [&digest](const MilitaryTruce &t) { return t.until_day <= digest.day; }),
                  _truces.end());
}

void MilitaryCore::front_rebuild(const MilitaryWorldDigest &digest) {
    (void)digest;
    if (_front_edge_pos.size() != _front_edge_set.size())
        _front_edge_pos.assign(_front_edge_set.size(), -1);
    // The incremental set is already authoritative; only drop stale keys.
    size_t write = 0;
    for (size_t i = 0; i < _front_edges.size(); ++i) {
        const uint32_t key = _front_edges[i];
        if ((size_t)key < _front_edge_pos.size()) _front_edge_pos[(size_t)key] = -1;
        if ((size_t)key < _front_edge_set.size() && _front_edge_set[(size_t)key] != 0) {
            _front_edges[write++] = key;
        }
    }
    if (write != _front_edges.size()) {
        _front_edges.resize(write);
        _front_revision += 1;
    }
    std::sort(_front_edges.begin(), _front_edges.end());
    index_front_positions(*this);
}

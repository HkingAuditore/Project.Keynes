void MilitaryCore::build_threat_fields(const MilitaryWorldDigest &digest) {
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    if (static_cast<int32_t>(_threat.size()) < cells) {
        _threat.assign(static_cast<size_t>(cells), 0);
        _guard.assign(static_cast<size_t>(cells), 0);
        _threat_stamp.assign(static_cast<size_t>(cells), 0);
    }
    _stamp += 1;
    if (_stamp == 0) {
        std::fill(_threat_stamp.begin(), _threat_stamp.end(), 0);
        _stamp = 1;
    }
    const uint32_t stamp = _stamp;
    const int32_t neighbor_total = static_cast<int32_t>(_terrain.neighbors.size());
    const int32_t *neighbors = _terrain.neighbors.data();
    const int32_t ring_weight = 39322;   // 0.6
    int32_t touched = 0;
    // threat[c] = sum of hostile strength within distance 1; guard[c] = own
    // presence. _threat_owner keeps the strongest adjacent owner so convoys can
    // decide who intercepts (sec 9.5).
    if (static_cast<int32_t>(_threat_owner.size()) < cells) {
        _threat_owner.assign(static_cast<size_t>(cells), 0);
    }
    const size_t army_count = _armies.active.size();
    for (size_t a = 0; a < army_count; ++a) {
        if (_armies.active[a] == 0) continue;
        const int32_t cell = _armies.cell[a];
        if (cell < 0 || cell >= cells) continue;
        const int64_t strength = _armies.cached_attack_q16[a] + _armies.cached_defense_q16[a];
        if (strength <= 0) continue;
        const int32_t slot = _armies.owner_slot[a];
        if (slot < 0 || slot > 65533) continue;
        for (int32_t plane = 0; plane < INTERCEPT_PLANES; ++plane) {
            int32_t at = cell;
            int32_t weight_q16 = MILITARY_Q16;
            if (plane > 0) {
                if (cell * 6 + 5 >= neighbor_total) continue;
                at = neighbors[cell * 6 + (plane - 1)];
                if (at < 0 || at >= cells) continue;
                weight_q16 = ring_weight;
            }
            if (_threat_stamp[static_cast<size_t>(at)] != stamp) {
                _threat_stamp[static_cast<size_t>(at)] = stamp;
                _threat[static_cast<size_t>(at)] = 0;
                _guard[static_cast<size_t>(at)] = 0;
                _threat_owner[static_cast<size_t>(at)] = 0;
                ++touched;
            }
            const int64_t weighted = mul_q16(strength, weight_q16);
            _threat[static_cast<size_t>(at)] += weighted;
            _guard[static_cast<size_t>(at)] += weighted;
            if (weighted > _threat[static_cast<size_t>(at)] / 2) {
                _threat_owner[static_cast<size_t>(at)] = static_cast<uint16_t>(slot + 1);
            }
        }
    }
    _report.threat_field_cells = touched;
    (void)digest;
}
// Destination cell of a shipment (-1 when the destination vanished).
int32_t shipment_dest_cell(const MilitaryCore &core, const MilitaryShipment &shipment) {
    // A building group's repair inventory is addressed by the composite holder,
    // so its destination cell is decoded from it (design D2).
    if (shipment.dest_kind == MILITARY_LOT_MAINTENANCE) {
        if (shipment.dest < 0) return -1;
        const int32_t cell = shipment.dest / MILITARY_MAINT_HOLDER_STRIDE;
        return cell < core.terrain().cell_count ? cell : -1;
    }
    if (shipment.dest_kind == MILITARY_LOT_ARMY) {
        int32_t slot = -1;
        if (core.resolve_army(shipment.dest_handle, slot)) {
            return core._armies.cell[static_cast<size_t>(slot)];
        }
        if (shipment.dest >= 0 &&
            shipment.dest < static_cast<int32_t>(core._armies.active.size()) &&
            core._armies.active[static_cast<size_t>(shipment.dest)] != 0) {
            return core._armies.cell[static_cast<size_t>(shipment.dest)];
        }
        return -1;
    }
    return shipment.dest;
}
// Neighbour of <from> that reduces the hex distance to <target>; ties keep the
// lowest neighbour id so replays are deterministic.
int32_t convoy_step(const MilitaryTerrainInput &terrain, const MilitaryCore &core, int32_t from,
                    int32_t target) {
    const int32_t neighbor_total = static_cast<int32_t>(terrain.neighbors.size());
    if (from < 0 || from * 6 + 5 >= neighbor_total) return -1;
    int32_t best = -1;
    int32_t best_distance = 0;
    for (int32_t dir = 0; dir < 6; ++dir) {
        const int32_t next = terrain.neighbors[from * 6 + dir];
        if (next < 0) continue;
        const int32_t distance = core.cell_distance(next, target);
        if (best < 0 || distance < best_distance ||
            (distance == best_distance && next < best)) {
            best = next;
            best_distance = distance;
        }
    }
    return best;
}
void MilitaryCore::run_convoys(const MilitaryWorldDigest &digest,
                               std::vector<MilitaryIntent> &out) {
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    if (static_cast<int32_t>(_cell_controller.size()) < cells) {
        _cell_controller.resize(static_cast<size_t>(cells), -1);
    }
    if (static_cast<int32_t>(_threat.size()) < cells) return;   // threat field not built
    Scratch &s = scratch();
    if (static_cast<int32_t>(s.event_stamp.size()) < digest.country_capacity) {
        s.event_stamp.assign(static_cast<size_t>(digest.country_capacity), 0xffffffffu);
    }
    int32_t intercepted_events = 0;
    const auto deliver = [&](const MilitaryShipment &shipment) {
        const int32_t slot = shipment.country_slot;
        if (shipment.dest_kind == MILITARY_LOT_ARMY) {
            int32_t army = -1;
            if (resolve_army(shipment.dest_handle, army)) {
                stock_add(MILITARY_LOT_ARMY, army, slot, shipment.good, shipment.qty);
                return true;
            }
            _ledger_returned += shipment.qty;   // army gone: refund to treasury
            return false;
        }
        // Keep the stock under the same holder kind it was booked against, and
        // fold delivered equipment into the exact training order (stable id).
        stock_add(shipment.dest_kind, shipment.dest, slot, shipment.good, shipment.qty);
        if (shipment.dest_kind == MILITARY_LOT_TRAINING && shipment.quality > 0) {
            const int32_t category = -1 - shipment.good;
            note_training_delivery(_training, _catalog, shipment.dest_handle,
                                   category, (int32_t)shipment.quality);
        }
        return true;
    };
    size_t write = 0;
    for (size_t i = 0; i < _shipments.size(); ++i) {
        MilitaryShipment shipment = _shipments[i];
        const int32_t slot = shipment.country_slot;
        const int32_t dest_cell = shipment_dest_cell(*this, shipment);
        if (dest_cell < 0) {
            _ledger_returned += shipment.qty;
            continue;
        }
        if (digest.day >= shipment.eta_day || shipment.current_cell == dest_cell) {
            deliver(shipment);
            continue;
        }
        ++_report.convoys_due;
        const int32_t next = convoy_step(_terrain, *this, shipment.current_cell, dest_cell);
        const int32_t dest_controller = controller_of_cell(*this, digest, dest_cell);
        bool blocked = next < 0;
        if (!blocked) {
            const int32_t next_controller = controller_of_cell(*this, digest, next);
            if (dest_controller != slot) {
                blocked = true;   // destination lost: wait for reconnection
            } else if (next != dest_cell && next_controller != slot) {
                blocked = true;
            }
        }
        if (blocked) {
            shipment.blocked_days += 1;
            if (shipment.blocked_days >= BLOCKED_RETURN_DAYS) {
                _ledger_returned += shipment.qty;   // returned to the treasury
                continue;
            }
            _shipments[write++] = shipment;
            continue;
        }
        shipment.blocked_days = 0;
        shipment.current_cell = next;
        shipment.progress_q16 += MILITARY_Q16;
        ++_report.convoy_hops;
        // Interception on the traversed cell (sec 9.5).
        const int64_t threat = _threat[static_cast<size_t>(next)];
        if (threat > 0) {
            const int64_t guard = _guard[static_cast<size_t>(next)];
            const int64_t value_units = std::max<int64_t>(1, shipment.value / MILITARY_MONEY_SCALE);
            // B2: convoy escort scales `ESCORT_BASE_Q16` by the country stat
            // (q16, 1.0 base, military_core.h) before the value conversion. The
            // divisor is the same q16 constant, so a 65536 stat leaves the
            // legacy escort value bit-equal (13107 stays 13107).
            const int64_t escort_q16 = mul_div(
                static_cast<int64_t>(ESCORT_BASE_Q16),
                static_cast<int64_t>(stat_q16(digest, slot, MSTAT_CONVOY_ESCORT)),
                (int64_t)MILITARY_Q16);
            const int64_t escort = (escort_q16 * value_units) >> 16;
            const int64_t denominator = threat + guard + escort;
            int64_t risk_q16 = denominator > 0 ? (threat * INTERCEPT_CAP_Q16) / denominator : 0;
            if (risk_q16 > INTERCEPT_CAP_Q16) risk_q16 = INTERCEPT_CAP_Q16;
            const uint64_t roll = rng(_seed, shipment.id, digest.day) & 0xffffu;
            if (static_cast<int64_t>(roll) < risk_q16) {
                const uint16_t owner_plus = _threat_owner[static_cast<size_t>(next)];
                const int32_t interceptor = owner_plus > 0 ? static_cast<int32_t>(owner_plus) - 1
                                                           : -1;
                if (interceptor >= 0) {
                    // Nearest interceptor army takes custody of the goods.
                    int32_t best_army = -1;
                    int32_t best_distance = 0x7fffffff;
                    for (size_t a = 0; a < _armies.active.size(); ++a) {
                        if (_armies.active[a] == 0) continue;
                        if (_armies.owner_slot[a] != interceptor) continue;
                        const int32_t distance = cell_distance(next, _armies.cell[a]);
                        if (distance < best_distance) {
                            best_distance = distance;
                            best_army = static_cast<int32_t>(a);
                        }
                    }
                    if (best_army >= 0) {
                        stock_add(MILITARY_LOT_ARMY, best_army, interceptor, shipment.good,
                                  shipment.qty);
                        _ledger_intercepted_in += shipment.qty;   // A3: only when custody is taken
                    }
                    _ledger_intercepted_out += shipment.qty;
                    bool emit = intercepted_events < EVENT_CAP_CONVOY;
                    if (interceptor < static_cast<int32_t>(s.event_stamp.size())) {
                        if (s.event_stamp[static_cast<size_t>(interceptor)] ==
                            static_cast<uint32_t>(digest.day)) {
                            emit = false;
                        }
                        s.event_stamp[static_cast<size_t>(interceptor)] =
                            static_cast<uint32_t>(digest.day);
                    }
                    if (emit && best_army >= 0) {
                        MilitaryEvent event;
                        event.day = digest.day;
                        event.type = MILITARY_EVENT_CONVOY_INTERCEPTED;
                        event.payload_schema = 24;
                        event.cell = next;
                        event.i0 = static_cast<uint64_t>(interceptor);
                        event.i1 = static_cast<uint64_t>(slot);
                        event.i2 = shipment.id;
                        event.value = shipment.value;
                        push_event(event);
                        ++intercepted_events;
                    } else {
                        ++_report.event_coalesced;
                    }
                }
                continue;   // goods left our custody
            }
        }
        if (shipment.current_cell == dest_cell) {
            deliver(shipment);
            continue;
        }
        _shipments[write++] = shipment;
    }
    _shipments.resize(write);
    (void)out;
}

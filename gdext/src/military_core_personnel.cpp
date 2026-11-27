#include "military_core.h"
#include "military_core_personnel_internal.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <string>
#include <utility>

namespace pk {

using namespace mil;

namespace {
constexpr int32_t kMaxOrdersPerCellPerDay = 4;
} // namespace

// ============================================================== force targets

void MilitaryCore::update_force_targets(const MilitaryWorldDigest &digest) {
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        MilitaryCountryPolicy &p = _policies[slot];
        const int32_t s = (int32_t)slot;
        const int64_t heads = country_soldiers(s);
        const int64_t living = slot < digest.country_soldier_living_cost.size()
                                   ? digest.country_soldier_living_cost[slot]
                                   : 0;
        const int64_t wage = p.wage_mode == 1
                                 ? p.wage_absolute
                                 : mul_div(living, stat_q16(digest, s, MSTAT_WAGE), MILITARY_Q16);
        int64_t upkeep_total = 0;
        for (const MilitaryCellState &st : _cell_states) {
            for (int32_t tier = 0; tier < 8; ++tier) {
                if (st.barracks_count[tier] <= 0) continue;
                for (const MilitaryStateBuilding &b : _catalog.state_buildings) {
                    if (b.role == (uint8_t)MILITARY_STATE_BARRACKS && (int32_t)b.tier == tier) {
                        upkeep_total += (int64_t)st.barracks_count[tier] * b.upkeep_per_day;
                        break;
                    }
                }
            }
        }
        const int64_t upkeep_per_head = heads > 0 ? upkeep_total / heads : 0;
        const int64_t procurement_per_head = p.spend_procurement_30 > 0
                                                 ? (p.spend_procurement_30 / 30) / std::max<int64_t>(heads, 1)
                                                 : 0;
        p.per_soldier_cost = std::max<int64_t>(1, wage + procurement_per_head + upkeep_per_head);

        int64_t target = p.target_mode == 1 ? p.target_value / p.per_soldier_cost : p.target_value;
        if (target < 0) target = 0;
        // +/-2% hysteresis for BUDGET mode; HEADCOUNT mode is a direct setting.
        if (p.target_mode == 1) {
            const int64_t old = p.effective_target;
            if (old <= 0 || target * 100 < old * 98 || target * 100 > old * 102) {
                p.effective_target = target;
            }
        } else {
            p.effective_target = target;
        }
    }
}

// ======================================================== roster reconcile

// Design 5.5: Economy owns natural deaths. Every day the Military roster must
// equal the cell's committed soldier cohort; when Economy has fewer people than
// the lots claim (deaths, or people leaving the soldier lane), the excess is
// trimmed proportionally and booked as non-combat attrition. Economy is never
// written here, so the reconcile is a pure read-and-trim. Soldiers only enter
// through ENLIST/LEVY (design 5.4), so the roster never needs to adopt heads.
void MilitaryCore::reconcile_soldier_roster(const MilitaryWorldDigest &digest) {
    if (digest.cell_soldiers.size() != (size_t)_terrain.cell_count) return;
    static thread_local std::vector<int32_t> rows;
    rows.clear();
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i] == 0) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        rows.push_back((int32_t)i);
    }
    if (rows.empty()) return;
    std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
        if (_lots.location[a] != _lots.location[b]) return _lots.location[a] < _lots.location[b];
        return a < b;
    });
    size_t begin = 0;
    while (begin < rows.size()) {
        const int32_t cell = _lots.location[(size_t)rows[begin]];
        size_t end = begin;
        int64_t total = 0;
        while (end < rows.size() && _lots.location[(size_t)rows[end]] == cell) {
            total += std::max<int64_t>(0, _lots.count[(size_t)rows[end]]);
            ++end;
        }
        // A transiently unavailable digest (worker read view busy) reports zero
        // population for every cell. Treating that as "everyone died" wipes the
        // roster, so a cell only participates when the digest actually carries
        // population for it.
        const bool digest_has_cell =
            (size_t)cell < digest.cell_population.size() &&
            digest.cell_population[(size_t)cell] > 0;
        const int64_t economy_heads = digest_has_cell && (size_t)cell < digest.cell_soldiers.size()
            ? std::max<int64_t>(0, digest.cell_soldiers[(size_t)cell]) : 0;
        // Heads already enlisted but not yet converted are pre-applied to the
        // roster and still missing from the committed cohort: trimming them here
        // re-opens the quota the next sample and converts the same people twice
        // (economy 19 soldiers against 6 in the roster).
        const MilitaryCellState *cell_row = cell_state(cell, false);
        const int64_t in_flight = cell_row != nullptr
            ? std::max<int64_t>(0, cell_row->pending_enlist) : 0;
        const int64_t allowed = economy_heads + in_flight;
        if (total > allowed) {
            const int64_t removed_total = total - allowed;
            int64_t excess = removed_total;
            // Proportional largest-remainder trim in ascending lot order.
            for (size_t k = begin; k < end && excess > 0; ++k) {
                const int32_t lot = rows[k];
                const int64_t share =
                    std::max<int64_t>(0, mul_div(_lots.count[(size_t)lot], removed_total, total));
                const int64_t take = std::min(share, std::min<int64_t>(_lots.count[(size_t)lot], excess));
                if (take <= 0) continue;
                _lots.count[(size_t)lot] -= take;
                excess -= take;
            }
            // Any remainder falls on the last lots, one head each.
            for (size_t k = begin; k < end && excess > 0; ++k) {
                const int32_t lot = rows[k];
                if (_lots.count[(size_t)lot] <= 0) continue;
                _lots.count[(size_t)lot] -= 1;
                --excess;
            }
            for (size_t k = begin; k < end; ++k) {
                const int32_t lot = rows[k];
                if (_lots.count[(size_t)lot] > 0) continue;
                _lots.active[(size_t)lot] = 0;
                _lots.free_list.push_back(lot);
            }
        }
        begin = end;
    }
}

// ================================================== army personnel lane
//
// Army-personnel contract §2.1. Military books the heads the moment the intent
// is emitted (same pre-apply rule as ENLIST/DISCHARGE) and never writes Economy;
// the lane row itself is Economy's, keyed by army handle. The bridge translates
// these rows into opcodes 30/31/32/33 and reads `military_army_population(handle)`
// back the next day to trim lots Economy no longer holds people for.

void MilitaryCore::emit_army_lane_intent(uint16_t kind, int32_t army_slot, int32_t cell,
                                         int64_t count, uint64_t peer_handle) {
    if (count <= 0) return;
    if (!army_alive(_armies, army_slot)) return;
    if (_army_lane_pending.size() < _armies.active.size())
        _army_lane_pending.resize(_armies.active.size(), 0);
    MilitaryIntent in;
    in.kind = kind;
    in.cell = cell;
    in.count = count;
    // `source_id` is the receipt's key and always names the formation whose book
    // is short: the formation being (re)filled here. For a lane -> lane move that
    // is the DESTINATION — its lots already carry the heads, its lane only catches
    // up when the command lands, so its in-flight ceiling stays raised until the
    // receipt. The bridge translates 32/33 from country_a/country_b, never from
    // source_id, so the receipt key is free to be the destination.
    in.source_id = army_handle(army_slot);
    if (peer_handle != 0) {
        // MERGE_LANES / SPLIT_LANES: country_a = source lane, country_b = the
        // formation whose lane grows.
        in.country_a = peer_handle;
        in.country_b = army_handle(army_slot);
    } else {
        in.country_a = country_handle_for_slot(_armies.owner_slot[(size_t)army_slot]);
    }
    _lane_intents.push_back(in);
    // Only an inbound move leaves heads in Economy's future: a DISEMBARK removes
    // them from the lane, so it must not widen the trim ceiling.
    if (kind != MILITARY_INTENT_ARMY_DISEMBARK)
        _army_lane_pending[(size_t)army_slot] += count;
}

int64_t MilitaryCore::army_lane_pending(int32_t army_slot) const {
    if (army_slot < 0 || (size_t)army_slot >= _army_lane_pending.size()) return 0;
    return std::max<int64_t>(0, _army_lane_pending[(size_t)army_slot]);
}

void MilitaryCore::emit_army_personnel_loss(int32_t army_slot, int32_t cell,
                                            int64_t lane_count, int64_t dead_count,
                                            std::vector<MilitaryIntent> &out) {
    if (!army_alive(_armies, army_slot)) return;
    if (cell < 0 || cell >= _terrain.cell_count) return;
    const uint64_t handle = army_handle(army_slot);
    const uint64_t owner_handle =
        country_handle_for_slot(_armies.owner_slot[(size_t)army_slot]);
    if (lane_count > 0) {
        // The dead are in the formation's lane, not in the home cell's soldier
        // cohort: hand the heads back to the cell first (opcode 31), then let the
        // casualty row below kill them there. Economy clamps both to what it
        // actually holds, so the pair cannot invent or destroy a head.
        MilitaryIntent release;
        release.kind = MILITARY_INTENT_ARMY_DISEMBARK;
        release.cell = cell;
        release.country_a = owner_handle;
        release.count = lane_count;
        release.source_id = handle;
        out.push_back(release);
        ++_report.intents_emitted;
    }
    if (dead_count > 0) {
        MilitaryIntent dead;
        dead.kind = MILITARY_INTENT_CASUALTY;
        dead.cell = cell;
        dead.country_a = owner_handle;
        dead.count = dead_count;
        dead.source_id = handle;
        out.push_back(dead);
        ++_report.intents_emitted;
    }
}

void MilitaryCore::trim_army_lots(int32_t army_slot, int64_t allowed) {
    if (army_slot < 0) return;
    if (allowed < 0) allowed = 0;
    static thread_local std::vector<int32_t> rows;
    rows.clear();
    int64_t total = 0;
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i] == 0 || _lots.count[i] <= 0) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (_lots.location[i] != army_slot) continue;
        rows.push_back((int32_t)i);
        total += _lots.count[i];
    }
    if (total <= allowed) return;
    const int64_t removed_total = total - allowed;
    int64_t excess = removed_total;
    // Proportional largest-remainder trim in ascending lot order (same rule as
    // reconcile_soldier_roster, but scoped to one formation).
    for (size_t k = 0; k < rows.size() && excess > 0; ++k) {
        const int32_t lot = rows[k];
        const int64_t share =
            std::max<int64_t>(0, mul_div(_lots.count[(size_t)lot], removed_total, total));
        const int64_t take = std::min(share, std::min<int64_t>(_lots.count[(size_t)lot], excess));
        if (take <= 0) continue;
        _lots.count[(size_t)lot] -= take;
        excess -= take;
    }
    for (size_t k = 0; k < rows.size() && excess > 0; ++k) {
        const int32_t lot = rows[k];
        if (_lots.count[(size_t)lot] <= 0) continue;
        _lots.count[(size_t)lot] -= 1;
        --excess;
    }
    for (size_t k = 0; k < rows.size(); ++k) {
        const int32_t lot = rows[k];
        if (_lots.count[(size_t)lot] > 0) continue;
        _lots.active[(size_t)lot] = 0;
        _lots.free_list.push_back(lot);
    }
}

void MilitaryCore::reconcile_receipts(const std::vector<MilitaryIntentReceipt> &receipts) {
    for (const MilitaryIntentReceipt &r : receipts) {
        if (r.kind == MILITARY_INTENT_PROCURE_GOOD) { settle_purchase(r); continue; }
        // Army personnel lane rows (contract §2.1). A row is bookkeeping only:
        // the heads were booked by Military when the intent was emitted and
        // Economy owns the lane. Whatever the outcome, the formation no longer has
        // a lane move in flight, so a lane reconcile may trim it again from the
        // next day on. `source_id` names the formation whose in-flight ceiling has
        // to be released — the one whose lane grew (the destination for
        // MERGE_LANES / SPLIT_LANES), which is who `emit_army_lane_intent` stamps
        // on the row; a merged-away formation never resolves and needs nothing
        // (destroy_army already cleared its bookkeeping).
        if (r.kind == MILITARY_INTENT_ARMY_EMBARK ||
            r.kind == MILITARY_INTENT_ARMY_DISEMBARK ||
            r.kind == MILITARY_INTENT_ARMY_MERGE_LANES ||
            r.kind == MILITARY_INTENT_ARMY_SPLIT_LANES) {
            int32_t lane_army = -1;
            if (resolve_army(r.source_id, lane_army) &&
                (size_t)lane_army < _army_lane_pending.size())
                _army_lane_pending[(size_t)lane_army] = 0;
            continue;
        }
        // Army pay (army-pay contract §2, opcode 34). The heads and the lane cash
        // are Economy's, and the lot book already holds them, so there is nothing
        // to reconcile a second time: the receipt only tells Military how much of
        // the payroll the treasury could actually fund. A failed row means the
        // lane was not credited at all, which is the pay-ratio statistic's
        // business (already booked from `planned` when the intent was emitted),
        // not a head-count correction.
        if (r.kind == MILITARY_INTENT_ARMY_PAY) continue;

        // DISCHARGE pre-applies to the garrison lots when the intent is emitted
        // (run_recruitment / attrition); the receipt never removes heads a second
        // time. Only the shortfall the old owner could not move is put back, so
        // the Military roster stays equal to the Economy soldier cohort.
        if (r.kind == MILITARY_INTENT_DISCHARGE) {
            const int64_t requested = (int64_t)((r.source_id >> 48) & 0xFFFFull);
            const int32_t slot = (int32_t)((r.source_id >> 32) & 0xFFFFull) - 1;
            const int64_t committed = r.ok
                ? std::clamp<int64_t>(r.committed_count, 0, requested) : 0;
            const int64_t shortfall = requested - committed;
            if (slot >= 0 && shortfall > 0 && r.cell >= 0 && r.cell < _terrain.cell_count) {
                const int16_t militia = (int16_t)(_catalog.militia_unit >= 0 ? _catalog.militia_unit : 0);
                const int32_t lot = lot_find_or_create((uint8_t)MILITARY_LOT_GARRISON, r.cell, slot, militia, 256);
                if (lot >= 0) _lots.count[(size_t)lot] += shortfall;
            }
            continue;
        }
        // ENLIST/LEVY is pre-applied to the Military lot before Economy moves
        // the cohort.  A zero or failed receipt still has to remove the
        // uncommitted heads and release the pending quota; the generic early
        // return below used to leave one such head stranded in the roster.
        if (r.kind == MILITARY_INTENT_ENLIST || r.kind == MILITARY_INTENT_LEVY) {
            if (r.cell < 0 || r.cell >= _terrain.cell_count) continue;
            const int64_t requested = (int64_t)((r.source_id >> 48) & 0xFFFFull);
            const int64_t committed = r.ok
                ? std::clamp<int64_t>(r.committed_count, 0, requested) : 0;
            const int64_t shortfall = requested > 0 ? requested - committed : 0;
            int32_t slot = (int32_t)((r.source_id >> 32) & 0xFFFFull) - 1;
            if (slot < 0 && (size_t)r.cell < _last_digest.cell_owner_slot.size())
                slot = _last_digest.cell_owner_slot[(size_t)r.cell];
            if (slot < 0) slot = 0;
            if (shortfall > 0) {
                const int16_t militia =
                    (int16_t)(_catalog.militia_unit >= 0 ? _catalog.militia_unit : 0);
                const int32_t lot = lot_find_or_create(
                    (uint8_t)MILITARY_LOT_GARRISON, r.cell, slot, militia, 256);
                if (lot >= 0)
                    _lots.count[(size_t)lot] = std::max<int64_t>(
                        0, _lots.count[(size_t)lot] - shortfall);
            }
            if (MilitaryCellState *st = cell_state(r.cell, false)) {
                st->pending_enlist = std::max<int64_t>(0,
                    st->pending_enlist - requested);
            }
            _report.reconcile_delta += committed;
            continue;
        }
        if (!r.ok || r.committed_count == 0) continue;
        switch (r.kind) {
            case MILITARY_INTENT_CASUALTY: {
                if (r.cell < 0 || r.cell >= _terrain.cell_count) break;
                // Casualties are booked on military lots when the intent is
                // emitted, and an army lot and a garrison lot are different
                // places: only the heads Economy could not remove (a shortfall,
                // or a fully failed row) belong back on the home garrison. The
                // emitter never packs the request into `source_id`, so the
                // requested count is the one the bridge translated. A full
                // refund therefore needs the bridge to report the shortfall;
                // with committed heads it adds back exactly what Economy kept.
                //
                // The roster total is what the report counts, so the refund is
                // applied to the garrison lot the receipt names.
                const int64_t committed = r.ok ? std::max<int64_t>(0, r.committed_count) : 0;
                if (committed <= 0) break;
                _report.reconcile_delta -= committed;
                break;
            }
            default:
                break;
        }
    }
}

// ============================================================== recruitment

// ============================================================== training

namespace {

int32_t cell_training_speed_q16(const MilitaryCatalog &c, const MilitaryCellState *st) {
    if (!st || st->college_tier < 0) return MILITARY_Q16;
    int32_t speed = 0;
    if (!barracks_speed_index_matches(c, st->college_tier, &speed)) return MILITARY_Q16;
    if (st->disrepair) speed = MILITARY_Q16 + (speed - MILITARY_Q16) / 2;
    return speed > 0 ? speed : MILITARY_Q16;
}

void transfer_trained_garrison(MilitaryCore &core, const MilitaryTrainingOrder &order,
                              int16_t quality_q8, int32_t kit_q16, uint16_t partial_equipment) {
    int64_t left = order.count;
    for (size_t i = 0; i < core._lots.active.size() && left > 0; ++i) {
        if (!core._lots.active[i]) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (core._lots.location[i] != order.cell || core._lots.country_slot[i] != order.country_slot ||
            core._lots.unit_type[i] != order.from_unit) continue;
        if (order.source_partial_equipment != 0 &&
            core._lots.partial_equipment[i] != order.source_partial_equipment) continue;
        const int64_t take = std::min(left, core._lots.count[i]);
        if (take <= 0) continue;
        core._lots.count[i] -= take;
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_GARRISON, order.cell,
            order.country_slot, order.to_unit, quality_q8, kit_q16, partial_equipment);
        if (lot < 0) {
            core._lots.count[i] += take;
            break;
        }
        core._lots.count[(size_t)lot] += take;
        left -= take;
    }
}

bool training_equipment_ready(const MilitaryCore &core, const MilitaryWorldDigest &digest,
                              const MilitaryTrainingOrder &order, const MilitaryUnitType &unit) {
    const uint64_t slots = equipment_slot_mask(unit);
    if (slots && (slots & order.equipped_slot_mask) == slots) return true;
    // A quality upgrade replaces an existing full kit only when the new kit
    // is complete. An unavailable slot is optional for new training.
    if (order.from_unit == order.to_unit && order.source_partial_equipment == 0)
        return false;
    if (!unlocked(digest, order.country_slot, unit.unlock_bit) ||
        digest.country_equipment_available.empty()) return false;
    for (int32_t slot = 0; slot < unit.slot_count; ++slot) {
        if (order.slot_delivered_quality[slot] == 0 &&
            equipment_slot_available(core.catalog(), digest, order.country_slot, unit, slot)) return false;
    }
    const auto in_transit = [&](const auto &delivery) {
        return delivery.dest_kind == MILITARY_LOT_TRAINING && delivery.dest_handle == order.id;
    };
    return std::none_of(core._purchase_orders.begin(), core._purchase_orders.end(), in_transit) &&
        std::none_of(core._shipments.begin(), core._shipments.end(), in_transit);
}

} // namespace

void MilitaryCore::run_training(const MilitaryWorldDigest &digest) {
    // 1. Advance after the slots the country can obtain have been delivered.
    for (size_t i = 0; i < _training.size(); ++i) {
        MilitaryTrainingOrder &o = _training[i];
        if (o.count <= 0 || o.days_done >= o.days_total) continue;
        if (o.to_unit < 0 || static_cast<size_t>(o.to_unit) >= _catalog.units.size()) continue;
        const MilitaryUnitType &unit = _catalog.units[o.to_unit];
        o.equipment_ready = training_equipment_ready(*this, digest, o, unit);
        if (!o.equipment_ready) continue;
        ++o.days_done;
        if (o.days_done < o.days_total) continue;
        const uint16_t partial_equipment = training_partial_equipment(unit, o);
        const int16_t delivered_q8 = unit.slot_count > 0 ? o.delivered_quality_q8 : o.quality_q8;
        const int32_t kit_q16 = partial_equipment == 0
            ? training_kit_factor_q16(unit, o) : MILITARY_Q16;
        if (o.from_unit >= 0) {
            transfer_trained_garrison(*this, o, delivered_q8, kit_q16, partial_equipment);
        }
        o.count = 0;
    }
    // 2. Compact finished orders.
    {
        size_t w = 0;
        for (size_t r = 0; r < _training.size(); ++r) {
            if (_training[r].count <= 0) continue;
            if (w != r) _training[w] = _training[r];
            ++w;
        }
        _training.resize(w);
    }
    const int32_t units = (int32_t)_catalog.units.size();
    if (units <= 0 || _catalog.militia_unit < 0) return;
    static thread_local std::vector<int64_t> gap;
    static thread_local std::vector<int64_t> existing;
    const bool has_partial_equipment = std::any_of(_lots.partial_equipment.begin(),
        _lots.partial_equipment.end(), [](uint16_t kit) { return kit != 0; });

    // 3. Automatic training / retraining / re-equip (5.6).
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        MilitaryCountryPolicy &p = _policies[slot];
        const int32_t s = (int32_t)slot;
        if (!p.auto_retrain) continue;
        if (p.config_share_bp.size() < (size_t)units) p.config_share_bp.resize((size_t)units, 0);
        int64_t share_sum = 0;
        for (int32_t u = 0; u < units; ++u) {
            int32_t bp = p.config_share_bp[(size_t)u];
            if (bp < 0) bp = 0;
            if (bp > 10000) bp = 10000;
            p.config_share_bp[(size_t)u] = bp;
            if (u == _catalog.militia_unit) continue;
            share_sum += bp;
        }
        const int64_t target = p.effective_target;
        if (share_sum <= 0 || target <= 0) {
            if (has_partial_equipment) run_reequipment(digest, s, false);
            continue;
        }
        gap.assign((size_t)units, 0);
        existing.assign((size_t)units, 0);
        for (size_t i = 0; i < _lots.active.size(); ++i) {
            if (!_lots.active[i]) continue;
            if (_lots.country_slot[i] != s) continue;
            const int32_t u = _lots.unit_type[i];
            if (u >= 0 && u < units) existing[(size_t)u] += _lots.count[i];
        }
        for (const MilitaryTrainingOrder &o : _training) {
            if (o.country_slot != s) continue;
            if (o.to_unit >= 0 && o.to_unit < units) existing[(size_t)o.to_unit] += o.count;
        }
        for (int32_t u = 0; u < units; ++u) {
            if (u == _catalog.militia_unit) continue;
            const int64_t want = mul_div(p.config_share_bp[(size_t)u], target, 10000);
            gap[(size_t)u] = want - existing[(size_t)u];
        }
        const int16_t militia = (int16_t)_catalog.militia_unit;
        for (MilitaryCellState &st : _cell_states) {
            const int32_t cell = st.cell;
            if (cell < 0 || cell >= _terrain.cell_count) continue;
            if ((size_t)cell >= digest.cell_owner_slot.size()) continue;
            if (digest.cell_owner_slot[(size_t)cell] != s) continue;
            const int32_t ctrl = controller_of(cell);
            if (ctrl >= 0 && ctrl != s) continue;
            if (st.paused) continue;
            const int64_t posts = posts_for_cell(cell, s);
            if (posts <= 0) continue;
            int64_t in_training = 0;
            for (const MilitaryTrainingOrder &o : _training) {
                if (o.cell == cell) in_training += o.count;
            }
            int64_t capacity = posts - in_training;
            if (capacity <= 0) continue;
            // v3: heads stay in the militia lot until the order completes, so
            // reserve those already committed to in-flight orders in this cell.
            const int64_t militia_heads = std::max<int64_t>(0,
                garrison_heads_for_unit(_lots, cell, s, militia) - in_training);
            if (militia_heads <= 0) continue;
            const int32_t speed = cell_training_speed_q16(_catalog, &st);
            const int64_t train_stat = stat_q16(digest, s, MSTAT_TRAINING_TIME);
            int32_t orders = 0;
            // Upgrade path A: militia -> configured unit, biggest gap first.
            while (capacity > 0 && orders < kMaxOrdersPerCellPerDay) {
                int32_t best = -1;
                int64_t best_gap = 0;
                for (int32_t u = 0; u < units; ++u) {
                    if (u == _catalog.militia_unit) continue;
                    if (!unlocked(digest, s, _catalog.units[(size_t)u].unlock_bit)) continue;
                    if (gap[(size_t)u] > best_gap) {
                        best_gap = gap[(size_t)u];
                        best = u;
                    }
                }
                if (best < 0) break;
                const MilitaryUnitType &ut = _catalog.units[(size_t)best];
                const int64_t count = std::min({capacity, militia_heads, best_gap});
                if (count <= 0) break;
                const int64_t kind = kind_factor_q16((uint8_t)MILITARY_CLASS_LINE, ut.unit_class, false);
                int64_t days = ceil_div_pos((int64_t)ut.training_days * kind, MILITARY_Q16);
                days = std::max<int64_t>(1, mul_div(days, train_stat, speed));
                MilitaryTrainingOrder o;
                o.id = _next_id++;
                o.country_slot = s;
                o.cell = cell;
                o.from_unit = militia;
                o.to_unit = (int16_t)best;
                o.count = count;
                o.days_total = (int32_t)std::min<int64_t>(days, 100000);
                o.days_done = 0;
                o.equipment_ready = 0;   // A2 fills this from procurement
                o.manual = 0;
                o.quality_q8 = (int16_t)(p.quality_policy == 0 ? 5 * 256 : 1 * 256);
                _training.push_back(o);
                gap[(size_t)best] -= count;
                capacity -= count;
                ++orders;
            }
            // Upgrade path B (retrain): a trained unit whose share is now the
            // largest gap retrains from an over-represented unit of the same
            // category where that is cheaper than training militia.
            for (int32_t u = 0; u < units && orders < kMaxOrdersPerCellPerDay; ++u) {
                if (u == _catalog.militia_unit) continue;
                if (gap[(size_t)u] <= 0) continue;
                if (!unlocked(digest, s, _catalog.units[(size_t)u].unlock_bit)) continue;
                int32_t source = -1;
                int64_t source_heads = 0;
                for (int32_t v = 0; v < units; ++v) {
                    if (v == _catalog.militia_unit || v == u) continue;
                    if (gap[(size_t)v] >= 0) continue;
                    const int64_t heads = garrison_heads_for_unit(_lots, cell, s, (int16_t)v);
                    if (heads > source_heads) {
                        source_heads = heads;
                        source = v;
                    }
                }
                if (source < 0) break;
                source_heads = std::max<int64_t>(0, source_heads - in_training);
                if (source_heads <= 0) break;
                const MilitaryUnitType &ut = _catalog.units[(size_t)u];
                const int64_t count = std::min({capacity, source_heads, gap[(size_t)u]});
                if (count <= 0) break;
                const int64_t kind = kind_factor_q16(_catalog.units[(size_t)source].unit_class,
                                                     ut.unit_class, false);
                int64_t days = ceil_div_pos((int64_t)ut.training_days * kind, MILITARY_Q16);
                days = std::max<int64_t>(1, mul_div(days, train_stat, speed));
                MilitaryTrainingOrder o;
                o.id = _next_id++;
                o.country_slot = s;
                o.cell = cell;
                o.from_unit = (int16_t)source;
                o.to_unit = (int16_t)u;
                o.count = count;
                o.days_total = (int32_t)std::min<int64_t>(days, 100000);
                o.equipment_ready = 0;
                o.manual = 0;
                o.quality_q8 = (int16_t)(p.quality_policy == 0 ? 5 * 256 : 1 * 256);
                _training.push_back(o);
                gap[(size_t)u] -= count;
                gap[(size_t)source] += count;
                capacity -= count;
                ++orders;
                break;
            }
        }
        if (has_partial_equipment || p.quality_policy == 0)
            run_reequipment(digest, s, p.quality_policy == 0);
    }
}

void MilitaryCore::run_reequipment(const MilitaryWorldDigest &digest, int32_t country,
                                   bool upgrade_quality) {
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (!_lots.active[i] || _lots.country_slot[i] != country ||
            _lots.location_kind[i] != MILITARY_LOT_GARRISON || _lots.count[i] <= 0) continue;
        const uint16_t kit = _lots.partial_equipment[i];
        if (kit == 0 && (!upgrade_quality || _lots.equip_quality_q8[i] + 128 >= 5 * 256)) continue;
        const int32_t unit_id = _lots.unit_type[i];
        if (unit_id < 0 || static_cast<size_t>(unit_id) >= _catalog.units.size() ||
            unit_id == _catalog.militia_unit) continue;
        const auto &unit = _catalog.units[unit_id];
        if (unit.slot_count <= 0) continue;
        const int32_t cell = _lots.location[i];
        const MilitaryCellState *state = cell_state(cell, false);
        if (!state || state->paused || cell < 0 || static_cast<size_t>(cell) >= digest.cell_owner_slot.size() ||
            digest.cell_owner_slot[cell] != country || (_last_day + cell) % 7 != 0) continue;
        if (std::any_of(_training.begin(), _training.end(), [&](const auto &pending) {
                return pending.country_slot == country && pending.cell == cell &&
                    pending.from_unit == unit_id && pending.to_unit == unit_id &&
                    pending.source_partial_equipment == kit;
            })) continue;
        MilitaryTrainingOrder order;
        if (kit != 0) {
            bool can_fill = false;
            for (int32_t slot = 0; slot < unit.slot_count; ++slot) {
                const int32_t grade = partial_equipment_grade(kit, slot);
                order.slot_delivered_quality[slot] = static_cast<int8_t>(grade);
                if (grade == 0) {
                    can_fill |= equipment_slot_available(_catalog, digest, country, unit, slot);
                    continue;
                }
                order.equipped_slot_mask |= uint64_t{1} << unit.slot_category[slot];
            }
            if (!can_fill) continue;
            order.source_partial_equipment = kit;
            order.delivered_quality_q8 = _lots.equip_quality_q8[i];
        } else {
            bool complete_kit_available = true;
            for (int32_t slot = 0; slot < unit.slot_count && complete_kit_available; ++slot)
                complete_kit_available = equipment_slot_available(_catalog, digest, country, unit, slot);
            if (!complete_kit_available) continue;
        }
        const int32_t speed = cell_training_speed_q16(_catalog, state);
        const int64_t training = stat_q16(digest, country, MSTAT_TRAINING_TIME);
        const int64_t days = ceil_div_pos(unit.training_days, 4);
        order.id = _next_id++;
        order.country_slot = country;
        order.cell = cell;
        order.from_unit = order.to_unit = static_cast<int16_t>(unit_id);
        order.count = std::min<int64_t>(_lots.count[i], 256);
        order.days_total = static_cast<int32_t>(std::clamp<int64_t>(mul_div(days, training, speed), 1, 100000));
        order.quality_q8 = upgrade_quality ? 5 * 256 : 256;
        _training.push_back(order);
        break;
    }
}

// ============================================================== reinforcement

void MilitaryCore::run_reinforcement(const MilitaryWorldDigest &digest) {
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        if (!_armies.reinforce_enabled[(size_t)slot]) continue;
        const int32_t owner = _armies.owner_slot[(size_t)slot];
        if (owner < 0) continue;
        const int32_t cell = _armies.cell[(size_t)slot];
        if (cell < 0 || cell >= _terrain.cell_count) continue;
        if ((size_t)cell >= digest.cell_owner_slot.size()) continue;
        if (digest.cell_owner_slot[(size_t)cell] != owner) continue;
        const int32_t ctrl = controller_of(cell);
        if (ctrl >= 0 && ctrl != owner) continue;
        const int32_t tpl_off = _armies.template_offset[(size_t)slot];
        const int32_t tpl_len = _armies.template_len[(size_t)slot];
        if (tpl_off < 0 || tpl_len <= 0) continue;
        bool changed = false;
        for (int32_t row = 0; row < tpl_len; row += 2) {
            const size_t ri = (size_t)(tpl_off + row);
            if (ri + 1 >= _template_rows.size()) break;
            const int32_t unit = _template_rows[ri];
            const int64_t want = _template_rows[ri + 1];
            if (unit < 0 || (size_t)unit >= _catalog.units.size()) continue;
            int64_t have = 0;
            for (size_t i = 0; i < _lots.active.size(); ++i) {
                if (!_lots.active[i]) continue;
                if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
                if (_lots.location[i] != slot) continue;
                if (_lots.unit_type[i] != unit) continue;
                have += _lots.count[i];
            }
            int64_t deficit = want - have;
            if (deficit <= 0) continue;
            // Pull trained heads from garrisons in the same cell; never take
            // the last 10%, never touch trainees (6.5).
            for (size_t i = 0; i < _lots.active.size() && deficit > 0; ++i) {
                if (!_lots.active[i]) continue;
                if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
                if (_lots.location[i] != cell) continue;
                if (_lots.country_slot[i] != owner) continue;
                if (_lots.unit_type[i] != unit) continue;
                const int64_t take = std::min(deficit, _lots.count[i] - _lots.count[i] / 10);
                if (take <= 0) continue;
                _lots.count[i] -= take;
                const int32_t dest = lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, slot, owner,
                                                        (int16_t)unit, _lots.equip_quality_q8[i],
                                                        _lots.kit_q16[i], _lots.partial_equipment[i]);
                if (dest < 0) {
                    _lots.count[i] += take;
                    break;
                }
                _lots.count[(size_t)dest] += take;
                deficit -= take;
                changed = true;
            }
        }
        if (changed) refresh_army_cache(slot);
    }
}

// ============================================================== morale / org

void MilitaryCore::update_morale_org(const MilitaryWorldDigest &digest) {
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        const size_t a = (size_t)slot;
        const int32_t owner = _armies.owner_slot[a];
        const int32_t cell = _armies.cell[a];
        // Morale (10): weights 30/25/10/10/15/10 scaled by their ratios.
        int64_t morale = 0;
        morale += 30 * _armies.pay_ratio_q16[a] / MILITARY_Q16;
        morale += 25 * _armies.ration_ratio_q16[a] / MILITARY_Q16;
        morale += 10 * 3 / 4;   // daily consumption satisfaction proxy (0.75)
        morale += 10 * std::min<int64_t>(MILITARY_Q16, _armies.supply_ratio_q16[a] * 2) / MILITARY_Q16;
        int64_t civic_q16 = MILITARY_Q16 * 3 / 10;
        if (owner >= 0 && cell >= 0 && cell < _terrain.cell_count &&
            (size_t)cell < digest.cell_owner_slot.size() &&
            digest.cell_owner_slot[(size_t)cell] == owner) {
            const int32_t ctrl = controller_of(cell);
            civic_q16 = (ctrl >= 0 && ctrl != owner) ? MILITARY_Q16 * 3 / 10 : MILITARY_Q16 * 3 / 4;
        }
        morale += 15 * civic_q16 / MILITARY_Q16;
        morale += 10;
        if (owner >= 0) morale += stat_add(digest, owner, MSTAT_MORALE_ADD) / 655;   // additive, 1/100 steps
        _armies.morale_q16[a] = (int32_t)clamp64(morale * MILITARY_Q16 / 100, 0, MILITARY_Q16);

        // Organisation: +3% * supply * recovery while not engaged (13). The
        // engagement stage subtracts for engaged units.
        if (_armies.engagement[a] < 0) {
            int32_t org = _armies.organization_q16[a];
            if (org < MILITARY_Q16) {
                const int64_t rec = owner >= 0 ? stat_q16(digest, owner, MSTAT_ORG_RECOVERY) : MILITARY_Q16;
                int64_t gain = mul_div(mul_div(3 * MILITARY_Q16 / 100, _armies.supply_ratio_q16[a], MILITARY_Q16),
                                       rec, MILITARY_Q16);
                org = (int32_t)std::min<int64_t>(MILITARY_Q16, org + gain);
                _armies.organization_q16[a] = org;
            }
        }
        if (_armies.cached_headcount[a] <= 0) {
            // Empty formations are removed here (A2 may already have done it).
            destroy_army(slot);
        }
    }
}

} // namespace pk

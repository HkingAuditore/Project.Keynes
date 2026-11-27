// military_core_selftest.cpp - MilitaryCore::self_test and the synthetic
// bench (owner: A3). Pure C++, no Godot types; the bridge exposes both through
// runtime_military_self_test / run_military_bench.
//
// The self test builds a 32x24 odd-r, east-west wrapping hex map (neighbour
// order = HexUtils.CUBE_DIRECTIONS, same convention as military_core_path.cpp),
// a four-entry catalog (militia + 2 units + 1 barracks) and a three-country
// digest, then drives step_day() through a tiny in-process "bridge" that turns
// ENLIST/LEVY/DISCHARGE/CASUALTY intents into next-day receipts.

#include "military_core.h"
#include "military_core_internal.h"
#include "military_core_flight_sums.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace pk {

namespace {

using namespace mil;

// ------------------------------------------------------------ fixtures

MilitaryTerrainInput make_hex_terrain(int32_t w, int32_t h) {
    MilitaryTerrainInput t;
    t.width = w;
    t.height = h;
    t.cell_count = w * h;
    const size_t n = (size_t)t.cell_count;
    t.neighbors.assign(n * 6, -1);
    static const int32_t kDir[6][2] = {{1, 0}, {1, -1}, {0, -1}, {-1, 0}, {-1, 1}, {0, 1}};   // (dq, dr)
    for (int32_t row = 0; row < h; ++row) {
        for (int32_t col = 0; col < w; ++col) {
            const int32_t q = col - (row - (row & 1)) / 2;
            for (int32_t d = 0; d < 6; ++d) {
                const int32_t nq = q + kDir[d][0];
                const int32_t nr = row + kDir[d][1];
                if (nr < 0 || nr >= h) continue;
                int32_t ncol = nq + (nr - (nr & 1)) / 2;
                ncol = ((ncol % w) + w) % w;
                t.neighbors[(size_t)(row * w + col) * 6 + (size_t)d] = nr * w + ncol;
            }
        }
    }
    t.landform.assign(n, 4);   // PLAIN
    t.vegetation.assign(n, 0);
    t.cover.assign(n, 0);
    t.is_water.assign(n, 0);
    t.has_river.assign(n, 0);
    t.settlement_tier.assign(n, 0);
    return t;
}

MilitaryCatalog make_catalog(int64_t barracks_upkeep = 0) {
    MilitaryCatalog c;
    MilitaryUnitType militia;
    militia.id = "a_militia";
    militia.unit_class = MILITARY_CLASS_LINE;
    militia.is_default_militia = 1;
    militia.attack_q16 = MILITARY_Q16;
    militia.defense_q16 = MILITARY_Q16;
    militia.training_days = 10;
    militia.idle_per_100_day[MILITARY_SUPPLY_RATION] = 500;
    MilitaryUnitType inf;
    inf.id = "b_infantry";
    inf.unit_class = MILITARY_CLASS_LINE;
    inf.attack_q16 = MILITARY_Q16 * 3 / 2;
    inf.defense_q16 = MILITARY_Q16 * 3 / 2;
    inf.training_days = 20;
    inf.slot_count = 1;
    inf.slot_category[0] = 0;
    inf.slot_min_quality[0] = 1;
    inf.slot_qty_per_100[0] = 1000 * MILITARY_GOODS_SCALE / 1000;
    inf.slot_power_weight_q16[0] = MILITARY_Q16;
    inf.idle_per_100_day[MILITARY_SUPPLY_RATION] = 500;
    MilitaryUnitType gun;
    gun.id = "c_cannon";
    gun.unit_class = MILITARY_CLASS_ARTILLERY;
    gun.unlock_bit = 0;
    gun.attack_q16 = MILITARY_Q16 * 3;
    gun.defense_q16 = MILITARY_Q16;
    gun.speed_q16 = MILITARY_Q16 / 2;
    gun.training_days = 30;
    c.units = {militia, inf, gun};
    MilitaryEquipCategory arms;
    arms.id = "arms";
    arms.good_ids = {1};
    arms.good_quality = {1};
    c.categories = {arms};
    MilitaryStateBuilding barracks;
    barracks.id = "barracks";
    // The economy type this lot is filed under. The core resolves the digest's
    // state rows back through this column, so a synthetic catalog without it
    // would make every ledger row unmappable.
    barracks.economy_building_id = 0;
    barracks.role = MILITARY_STATE_BARRACKS;
    barracks.tier = 0;
    barracks.capacity = 100;
    barracks.build_days = 5;
    // MONEY_SCALE per building per day. Zero by default: every other case bills
    // nothing for standing buildings, so the upkeep channel stays silent exactly
    // as before this parameter existed.
    barracks.upkeep_per_day = barracks_upkeep;
    c.state_buildings = {barracks};
    c.supply_goods[MILITARY_SUPPLY_RATION] = {0};
    c.supply_yield_q16[MILITARY_SUPPLY_RATION] = {MILITARY_Q16};
    c.economy_good_count = 2;
    c.unlock_count = 1;
    return c;
}

constexpr int32_t kW = 32, kH = 24;
inline int32_t cell_at(int32_t col, int32_t row) { return row * kW + col; }
const int32_t kEnclave = cell_at(14, 12);   // the single cell of country 2

uint64_t handle_for(int32_t slot) { return (7ull << 32) | (uint64_t)(slot + 1); }

MilitaryWorldDigest make_digest(const MilitaryTerrainInput &t) {
    MilitaryWorldDigest d;
    const size_t n = (size_t)t.cell_count;
    d.country_capacity = 3;
    d.cell_owner_slot.assign(n, -1);
    for (int32_t row = 0; row < kH; ++row) {
        for (int32_t col = 0; col < kW; ++col) {
            d.cell_owner_slot[(size_t)cell_at(col, row)] = col < 14 ? 0 : 1;
        }
    }
    d.cell_owner_slot[(size_t)kEnclave] = 2;
    d.country_handle = {handle_for(0), handle_for(1), handle_for(2)};
    d.country_cash = {1000000000000ll, 1000000000000ll, 1000000000000ll};
    d.country_era = {0, 0, 0};
    d.country_annual_revenue = {0, 0, 0};
    d.country_capital_cell = {cell_at(5, 12), cell_at(24, 12), kEnclave};
    d.country_soldier_living_cost = {0, 0, 0};
    d.cell_population.assign(n, 1000);
    d.cell_population[(size_t)kEnclave] = 200;
    d.cell_unemployed.assign(n, 200);
    d.cell_soldiers.assign(n, 0);
    d.cell_has_merchant.assign(n, 0);
    for (int32_t c = 0; c < t.cell_count; c += 37) {
        d.cell_has_merchant[(size_t)c] = 1;
        d.market_cell.push_back(c);
        d.market_good.push_back(0);
        d.market_sellable.push_back(1000000);
        d.market_price.push_back(20000);
        d.market_cell.push_back(c);
        d.market_good.push_back(1);
        d.market_sellable.push_back(500000);
        d.market_price.push_back(80000);
    }
    d.unlock_words = 1;
    d.country_unlock_bits = {0ull, 1ull, 0ull};   // only country 1 has cannons
    d.stat_count = 0;
    return d;
}
// In-process bridge: intents of day D become receipts for day D+1.
// It also stands in for the economy's building ledger. `MilitaryCellState`'s
// barracks/fort/college fields are a derived read of the economy's kind-3
// building groups (requirement 6.1), so a harness that only submitted
// `MCMD_STATE_BUILD` would hold a cache that is forever empty. Every lot the
// harness accepts is therefore recorded here and published on the digest from
// its completion day on - exactly what a re-read of the economy would report.
struct Sim {
    MilitaryCore core;
    MilitaryWorldDigest dg;
    std::vector<MilitaryIntentReceipt> receipts;
    std::vector<MilitaryIntent> last;
    std::vector<int64_t> enlist_by_cell;
    struct LedgerLot {
        int32_t cell = -1;
        int32_t building = -1;
        int64_t ready_day = 0;
        int32_t units = 0;
    };
    std::vector<LedgerLot> lots;
    int64_t day = 0;
    int64_t max_abs_reconcile = 0;
    int64_t first_leak_day = -1;
    std::string first_leak_events;
    std::string error;
    bool init(const MilitaryTerrainInput &t, uint64_t seed) {
        return init(t, seed, make_catalog());
    }
    bool init(const MilitaryTerrainInput &t, uint64_t seed, MilitaryCatalog catalog) {
        if (!core.configure(std::move(catalog), seed, error)) return false;
        if (!core.set_terrain(t, error)) return false;
        dg = make_digest(t);
        for (int32_t s = 0; s < dg.country_capacity; ++s) {
            if (core.ensure_country_slot(dg.country_handle[(size_t)s]) != s) {
                error = "slot_order";
                return false;
            }
        }
        enlist_by_cell.assign((size_t)t.cell_count, 0);
        return true;
    }
    bool submit(uint16_t op, int32_t slot, MilitaryCommand cmd) {
        cmd.op = op;
        cmd.country = handle_for(slot);
        cmd.effective_day = day;
        const int32_t build_cell = cmd.cell;
        const int32_t build_index = cmd.unit_to;
        if (!core.submit(std::move(cmd), error)) return false;
        // A submitted `state.build` is by contract one the economy already
        // accepted (the bridge only forwards after the bill settled), so the
        // harness's ledger has to know about it too.
        if (op == MCMD_STATE_BUILD) record_lot(build_cell, build_index);
        return true;
    }
    // The economy side of a `state.build`: one unit that starts standing on its
    // completion day.
    void record_lot(int32_t cell, int32_t building) {
        if (cell < 0 || building < 0 ||
            (size_t)building >= core.catalog().state_buildings.size())
            return;
        const MilitaryStateBuilding &sb = core.catalog().state_buildings[(size_t)building];
        if (sb.economy_building_id < 0) return;   // no economy profile, no bill
        LedgerLot lot;
        lot.cell = cell;
        lot.building = building;
        lot.ready_day = day + std::max(1, sb.build_days);
        lot.units = 1;
        lots.push_back(lot);
    }
    // Publishes the ledger as the digest's state lanes, the way
    // `capture_military_digest` reads the economy's building groups.
    void publish_state_ledger() {
        dg.state_cell.clear();
        dg.state_type_id.clear();
        dg.state_state_role.clear();
        dg.state_units.clear();
        for (const LedgerLot &lot : lots) {
            if (lot.units <= 0 || lot.ready_day > day) continue;
            const MilitaryStateBuilding &sb = core.catalog().state_buildings[(size_t)lot.building];
            dg.state_cell.push_back(lot.cell);
            dg.state_type_id.push_back(sb.economy_building_id);
            dg.state_state_role.push_back((int32_t)sb.role + 1);
            dg.state_units.push_back(lot.units);
        }
        dg.state_lanes_present = true;
        dg.state_lane_rows = (int32_t)dg.state_cell.size();
    }
    bool step() {
        last.clear();
        dg.day = day;
        publish_state_ledger();
        // Economy owns the soldier cohort count and Military reconciles against
        // it every day, so the synthetic digest has to expose what the "economy"
        // side of this harness would hold: the heads enlisted so far.
        for (size_t c = 0; c < enlist_by_cell.size() && c < dg.cell_soldiers.size(); ++c)
            dg.cell_soldiers[c] = enlist_by_cell[c];
        if (!core.step_day(day, dg, receipts, last, error)) return false;
        receipts.clear();
        for (const MilitaryIntent &in : last) {
            MilitaryIntentReceipt r;
            r.kind = in.kind;
            r.ok = 1;
            r.cell = in.cell;
            r.source_id = in.source_id;
            r.committed_count = in.count;
            r.committed_amount = in.amount;
            switch (in.kind) {
                case MILITARY_INTENT_ENLIST:
                case MILITARY_INTENT_LEVY:
                    if (in.cell >= 0) {
                        enlist_by_cell[(size_t)in.cell] += in.count;
                        dg.cell_unemployed[(size_t)in.cell] =
                            std::max<int64_t>(0, dg.cell_unemployed[(size_t)in.cell] - in.count);
                    }
                    receipts.push_back(r);
                    break;
                case MILITARY_INTENT_DISCHARGE:
                    if (in.cell >= 0) {
                        enlist_by_cell[(size_t)in.cell] = std::max<int64_t>(0,
                            enlist_by_cell[(size_t)in.cell] - in.count);
                        dg.cell_unemployed[(size_t)in.cell] += in.count;
                    }
                    receipts.push_back(r);
                    break;
                case MILITARY_INTENT_CASUALTY:
                    if (in.cell >= 0)
                        enlist_by_cell[(size_t)in.cell] = std::max<int64_t>(0,
                            enlist_by_cell[(size_t)in.cell] - in.count);
                    receipts.push_back(r);
                    break;
                case MILITARY_INTENT_STATE_BUILD: {
                    // The bridge's state.build lane: accept the lot in the
                    // ledger, then echo the bookkeeping command the way
                    // `translate_military_intent` does.
                    const int32_t building = static_cast<int32_t>(in.count);
                    if (building >= 0 &&
                        (size_t)building < core.catalog().state_buildings.size() &&
                        core.catalog().state_buildings[(size_t)building].economy_building_id >= 0 &&
                        in.cell >= 0) {
                        record_lot(in.cell, building);
                        MilitaryCommand echo;
                        echo.op = MCMD_STATE_BUILD;
                        echo.country = in.country_a;
                        echo.cell = in.cell;
                        echo.unit_to = building;
                        echo.effective_day = day;
                        std::string echo_error;
                        core.submit(std::move(echo), echo_error);
                    }
                    break;
                }
                case MILITARY_INTENT_PROCURE_GOOD: {
                    // Physical procurement settles ONLY on a real fill receipt
                    // (design D1/D6). This harness stands in for Economy, so it
                    // fills what was asked and echoes the paid amount; the core
                    // is what turns that into stock, a convoy and a ledger term.
                    // Without this row nothing would ever enter custody, which is
                    // the whole point of removing the optimistic booking.
                    r.ok = in.count > 0 ? 1 : 0;
                    r.committed_count = in.count;
                    r.committed_amount = in.amount;
                    receipts.push_back(r);
                    break;
                }
                default:
                    break;
            }
        }
        const int64_t rd = core.report().reconcile_delta;
        if (rd != 0 && max_abs_reconcile == 0) {
            first_leak_day = day;
            for (const MilitaryEvent &e : core.events_after(0, 100000)) {
                if (e.day == day) first_leak_events += std::to_string(e.type) + " ";
            }
            // Which ledger term moved without its pair? The identity is
            // received = stock + transit + consumed + intercepted_out
            //                    - intercepted_in + returned.
            first_leak_events += "|received=" + std::to_string(core._ledger_received) +
                                 " stock=" + std::to_string(core.ledger_stock_total()) +
                                 " transit=" + std::to_string(core.ledger_transit_total()) +
                                 " consumed=" + std::to_string(core._ledger_consumed) +
                                 " int_out=" + std::to_string(core._ledger_intercepted_out) +
                                 " int_in=" + std::to_string(core._ledger_intercepted_in) +
                                 " returned=" + std::to_string(core._ledger_returned) +
                                 " delta=" + std::to_string(rd);
        }
        if (std::llabs(rd) > max_abs_reconcile) max_abs_reconcile = std::llabs(rd);
        ++day;
        return true;
    }
    bool run_until(int64_t end_day) {
        while (day < end_day) {
            if (!step()) return false;
        }
        return true;
    }
    int32_t army_of(int32_t slot) const {
        const MilitaryArmyStore &a = core.armies();
        for (int32_t i = 0; i < (int32_t)a.active.size(); ++i) {
            if (a.active[(size_t)i] && a.owner_slot[(size_t)i] == slot) return i;
        }
        return -1;
    }
};
int64_t garrison_at(const MilitaryCore &core, int32_t cell) {
    const MilitaryLotStore &l = core.lots();
    int64_t total = 0;
    for (size_t i = 0; i < l.active.size(); ++i) {
        if (l.active[i] && l.location_kind[i] == MILITARY_LOT_GARRISON && l.location[i] == cell) total += l.count[i];
    }
    return total;
}
bool is_neighbor(const MilitaryTerrainInput &t, int32_t a, int32_t b) {
    if (a == b) return true;
    for (int32_t d = 0; d < 6; ++d) {
        if (t.neighbors[(size_t)a * 6 + (size_t)d] == b) return true;
    }
    return false;
}
// Names the first state component that differs after a PKMI round trip.
std::string describe_diff(const MilitaryCore &a, const MilitaryCore &b) {
    std::string out;
    auto note = [&out](bool same, const char *what) {
        if (!same) out += std::string("     diff: ") + what + "\n";
    };
    note(a._last_day == b._last_day && a._next_sequence == b._next_sequence && a._next_id == b._next_id &&
             a._next_event_id == b._next_event_id && a._control_revision == b._control_revision &&
             a._front_revision == b._front_revision,
         "counters");
    note(a._path_daily_requests == b._path_daily_requests, "path_daily_requests");
    note(a._pending.size() == b._pending.size(), "pending");
    note(a._lots.active == b._lots.active && a._lots.count == b._lots.count &&
             a._lots.condition_q16 == b._lots.condition_q16 && a._lots.location == b._lots.location,
         "lots");
    const MilitaryArmyStore &x = a._armies, &y = b._armies;
    for (size_t i = 0; i < x.active.size(); ++i) {
        if (!x.active[i]) continue;
        char buf[160];
        std::snprintf(buf, sizeof(buf), "army %zu head %lld/%lld atk %lld/%lld eng %d/%d spd %d/%d mvday %lld/%lld",
                      i, (long long)x.cached_headcount[i], (long long)y.cached_headcount[i],
                      (long long)x.cached_attack_q16[i], (long long)y.cached_attack_q16[i], x.engagement[i],
                      y.engagement[i], x.cached_speed_q16[i], y.cached_speed_q16[i], (long long)x.moved_day[i],
                      (long long)y.moved_day[i]);
        note(x.cached_headcount[i] == y.cached_headcount[i] && x.cached_attack_q16[i] == y.cached_attack_q16[i] &&
                 x.cached_defense_q16[i] == y.cached_defense_q16[i] && x.engagement[i] == y.engagement[i] &&
                 x.cached_speed_q16[i] == y.cached_speed_q16[i] && x.path_len[i] == y.path_len[i] &&
                 x.moved_day[i] == y.moved_day[i] && x.prev_cell[i] == y.prev_cell[i] &&
                 x.generation[i] == y.generation[i] && x.organization_q16[i] == y.organization_q16[i],
             buf);
    }
    note(a._stocks.size() == b._stocks.size(), "stocks");
    note(a._shipments.size() == b._shipments.size(), "shipments");
    note(a._engagements.size() == b._engagements.size(), "engagements");
    note(a._wars.size() == b._wars.size(), "wars");
    note(a._truces.size() == b._truces.size(), "truces");
    note(a._battle_log.size() == b._battle_log.size(), "battle_log");
    note(a._areas.size() == b._areas.size(), "areas");
    note(a._explorations.size() == b._explorations.size(), "explorations");
    if (a._explorations.size() == b._explorations.size()) {
        for (size_t i = 0; i < a._explorations.size(); ++i) {
            const MilitaryExplorationTask &x = a._explorations[i];
            const MilitaryExplorationTask &y = b._explorations[i];
            char buf[220];
            std::snprintf(buf, sizeof(buf),
                          "exploration %zu active %d/%d phase %u/%u result %u/%u "
                          "selected %d/%d seen %016llx/%016llx",
                          i, x.active ? 1 : 0, y.active ? 1 : 0,
                          (unsigned)x.phase, (unsigned)y.phase,
                          (unsigned)x.result, (unsigned)y.result,
                          x.selected_count, y.selected_count,
                          (unsigned long long)x.seen_mask[0],
                          (unsigned long long)y.seen_mask[0]);
            note(x.active == y.active && x.row_index == y.row_index &&
                     x.army_handle == y.army_handle &&
                     x.owner_slot == y.owner_slot &&
                     x.owner_handle == y.owner_handle &&
                     x.origin_cell == y.origin_cell &&
                     x.return_cell == y.return_cell &&
                     x.anchor_cell == y.anchor_cell &&
                     x.radius == y.radius &&
                     x.selected_count == y.selected_count &&
                     x.selected_cells == y.selected_cells &&
                     x.seen_mask == y.seen_mask &&
                     x.visited_mask == y.visited_mask &&
                     x.blocked_mask == y.blocked_mask &&
                     x.phase == y.phase &&
                     x.pause_reason == y.pause_reason &&
                     x.result == y.result &&
                     x.resume_phase == y.resume_phase &&
                     x.focus_index == y.focus_index &&
                     x.current_observation_cell == y.current_observation_cell &&
                     x.observer_tries == y.observer_tries &&
                     x.reached_observer_cells == y.reached_observer_cells &&
                     x.tried_observer_mask == y.tried_observer_mask &&
                     x.started_day == y.started_day &&
                     x.last_progress_day == y.last_progress_day &&
                     x.last_plan_day == y.last_plan_day &&
                     x.complete_day == y.complete_day &&
                     x.return_fallback == y.return_fallback,
                 buf);
        }
    }
    note(a._policies.size() == b._policies.size(), "policies");
    note(a._cell_states.size() == b._cell_states.size(), "cell_states");
    note(a._cell_controller == b._cell_controller, "controller");
    note(a._events.size() == b._events.size(), "events");
    note(a._ai_country == b._ai_country && a._ai_next_decision_day == b._ai_next_decision_day, "ai");
    note(a._ledger_received == b._ledger_received && a._ledger_consumed == b._ledger_consumed, "ledger");
    note(a._seed == b._seed && a._catalog.hash == b._catalog.hash, "seed/catalog");
    return out;
}
bool has_event(const MilitaryCore &core, uint16_t type) {
    for (const MilitaryEvent &e : core.events_after(0, 100000)) {
        if (e.type == type) return true;
    }
    return false;
}
#define ST_CHECK(cond, msg)                                    \
    do {                                                       \
        if (!(cond)) {                                         \
            report += std::string("FAIL ") + (msg) + "\n";     \
            return false;                                      \
        }                                                      \
        report += std::string("ok   ") + (msg) + "\n";         \
    } while (0)
#define ST_STEP(sim, end)                                                          \
    do {                                                                           \
        if (!(sim).run_until(end)) {                                               \
            report += "FAIL step_day: " + (sim).error + "\n";                      \
            return false;                                                          \
        }                                                                          \
    } while (0)
// --- 1. peaceful empty world
bool test_idle(const MilitaryTerrainInput &t, std::string &report) {
    MilitaryCore core;
    std::string error;
    ST_CHECK(core.configure(make_catalog(), 11, error) && core.set_terrain(t, error), "configure + terrain");
    bool any = false;
    for (int64_t d = 0; d < 60; ++d) any = any || core.should_run(d);
    ST_CHECK(!any, "peaceful empty world: should_run false for 60 days");
    // Registered countries with no target, no AI, no armies: off-cadence days idle.
    MilitaryCore core2;
    core2.configure(make_catalog(), 11, error);
    core2.set_terrain(t, error);
    for (int32_t s = 0; s < 3; ++s) core2.ensure_country_slot(handle_for(s));
    ST_CHECK(!core2.should_run(1) && !core2.should_run(7), "peaceful registered world idle off the 5-day cadence");
    return true;
}
// --- B1 read point: MSTAT_BARRACKS_CAPACITY scales the summed posts.
// Fixtures are deliberately separate and each pins one explicit q16 constant.
//   1,640 rows = 164,000 posts: far from the cap, and for kQ = 72089 the three
//   plausible implementations print three different numbers
//   (q16 180,398 / q16 of 72090 180,401 / decimal 11/10 180,400), so this
//   fixture fails whichever way the factor is mis-encoded.
//   4,800 rows = 480,000 posts: the only size that reaches the cap after a 1.1
//   factor; 527,995 truncates back to 524,288. Removing the cap (527,995) and
//   scaling after the cap (also 527,995) each fail this assertion.
#include "military_core_selftest_section_force_capacity.inc"

#include "military_core_selftest_section_recruitment_and_movement.inc"
#include "military_core_selftest_section_war_peace_save.inc"
#include "military_core_selftest_section_partial_discharge.inc"
bool test_ai(const MilitaryTerrainInput &t, std::string &report, uint64_t &hash_out, std::string &stats) {
    Sim sim;
    ST_CHECK(sim.init(t, 4242), "ai sim init");
    sim.dg.country_soldier_living_cost = {50000, 50000, 50000};
    // Revenue so the peace budget buys ~400 / ~250 / ~40 soldiers.
    const int64_t per_soldier = 65000;   // 1.3 x living cost
    sim.dg.country_annual_revenue = {400 * per_soldier * 365 * 10000 / 800, 250 * per_soldier * 365 * 10000 / 800,
                                     40 * per_soldier * 365 * 10000 / 800};
    for (int32_t s = 0; s < 3; ++s) sim.core.set_ai_country(s, true);
    ST_STEP(sim, 1500);
    const MilitaryCore &c = sim.core;
    bool modes = true, configs = true;
    for (int32_t s = 0; s < 3; ++s) {
        modes = modes && c.policies()[(size_t)s].target_mode == 1 && c.policies()[(size_t)s].effective_target > 0;
        int32_t share = 0;
        for (int32_t bp : c.policies()[(size_t)s].config_share_bp) share += bp;
        configs = configs && share == 10000;
    }
    ST_CHECK(modes, "AI set BUDGET force targets for every country");
    ST_CHECK(configs, "AI configured unit shares summing to 100%");
    ST_CHECK(c.policies()[1].config_share_bp[2] == 1000 && c.policies()[0].config_share_bp[2] == 0,
             "artillery 10% only where unlocked");
    int32_t barracks = 0;
    for (const MilitaryCellState &st : c.cell_states()) barracks += st.barracks_count[0];
    ST_CHECK(barracks > 0 && c.country_soldiers(0) > 0, "AI built barracks and recruited");
    // The upkeep bill is per country, so its `disrepair` verdict has to stay
    // inside that country. Two things are checked, because the old writer broke
    // both at once by walking every cell state inside the per-country loop:
    //  - a flagged cell must actually hold a state building. `upkeep` is only
    //    ever charged for standing barracks / fortification / college, so a flag
    //    on an empty cell is a bill with no building behind it.
    //  - the flag may only appear on cells the billing country owns.
    {
        bool scope_ok = true;
        for (const MilitaryCellState &st : c.cell_states()) {
            if (st.disrepair == 0) continue;
            bool has_building = st.fort_tier >= 0 || st.college_tier >= 0;
            for (int32_t tier = 0; tier < MILITARY_STATE_BARRACKS_TIERS && !has_building; ++tier)
                has_building = st.barracks_count[tier] > 0;
            if (!has_building) { scope_ok = false; break; }
            if (st.cell < 0 || (size_t)st.cell >= sim.dg.cell_owner_slot.size()) { scope_ok = false; break; }
            if (sim.dg.cell_owner_slot[(size_t)st.cell] < 0) { scope_ok = false; break; }
        }
        ST_CHECK(scope_ok, "disrepair only marks cells that hold a state building");
    }
    // The cache is a derived read, so a rebuild that disagrees with the ledger
    // would already have been counted here.
    ST_CHECK(c.report().state_cache_repairs == 0 && c.report().state_ledger_unmapped == 0 &&
                 c.report().state_role_mismatch == 0,
             "state building cache tracks the ledger with no divergence");
    int32_t wars = 0, ended = 0;
    for (const MilitaryWar &w : c.wars()) {
        ++wars;
        if (!w.active) ++ended;
    }
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "ai: day=%lld soldiers=[%lld,%lld,%lld] targets=[%lld,%lld,%lld] barracks=%d wars=%d ended=%d "
                  "armies=%d events=%zu reconcile_max=%lld\n",
                  (long long)sim.day, (long long)c.country_soldiers(0), (long long)c.country_soldiers(1),
                  (long long)c.country_soldiers(2), (long long)c.policies()[0].effective_target,
                  (long long)c.policies()[1].effective_target, (long long)c.policies()[2].effective_target, barracks,
                  wars, ended, c.report().armies_active, c.events_after(0, 100000).size(),
                  (long long)sim.max_abs_reconcile);
    stats = buf;
    if (sim.first_leak_day >= 0)
        stats += "first_leak_day=" + std::to_string(sim.first_leak_day) + " events=" + sim.first_leak_events + "\n";
    ST_CHECK(sim.max_abs_reconcile == 0, "ledger reconcile_delta == 0 in AI soak | " + stats);
    hash_out = c.state_hash();
    return true;
}
#include "military_core_procurement_selftest.inc"
// --- 12. Water crossing (army-personnel contract 2 §2.1 / design §7.4).
// The synthetic map only wraps east-west, so a full-width water band cuts it in
// two and every land route between the shores has to cross the band. The band's
// landform decides WHICH water it is (lake / shallow / far / deep) and that is
// the only gate: the number of water cells in a row is irrelevant.
MilitaryTerrainInput make_hex_terrain_with_water_band(int32_t first_row, int32_t band,
                                                      uint8_t water_landform = 2) {
    MilitaryTerrainInput t = make_hex_terrain(kW, kH);
    for (int32_t c = 0; c < t.cell_count; ++c) {
        const int32_t row = c / kW;
        if (row < first_row || row >= first_row + band) continue;
        t.is_water[(size_t)c] = 1;
        t.has_river[(size_t)c] = 0;
        // Landform ids mirror scripts/geography/landform_type.gd: 0 deep ocean,
        // 1 ocean, 2 coast (shallow), 3 lake.
        t.landform[(size_t)c] = water_landform;
    }
    return t;
}
// Unlock bits: 0 = cannon (existing fixture), 1..4 = lake/shallow/far/deep
// water tiers (army-personnel contract 2 §2.2 catalog slots).
constexpr int32_t kLakeBit = 1;
constexpr int32_t kShallowBit = 2;
constexpr int32_t kFarBit = 3;
constexpr int32_t kDeepBit = 4;
constexpr uint64_t kLakeUnlock = 1ull << kLakeBit;
constexpr uint64_t kShallowUnlock = 1ull << kShallowBit;
constexpr uint64_t kFarUnlock = 1ull << kFarBit;
constexpr uint64_t kDeepUnlock = 1ull << kDeepBit;
constexpr uint8_t kLandformDeepOcean = 0;
constexpr uint8_t kLandformOcean = 1;
constexpr uint8_t kLandformCoast = 2;
constexpr uint8_t kLandformLake = 3;
MilitaryCatalog make_naval_catalog() {
    MilitaryCatalog c = make_catalog();
    c.unlock_count = 5;
    c.water_lake_bit = kLakeBit;
    c.water_shallow_bit = kShallowBit;
    c.water_far_bit = kFarBit;
    c.water_deep_bit = kDeepBit;
    return c;
}
// Digest over a water-band map: water is unowned (crossing it must not open an
// engagement) and country 0 carries exactly `unlock_bits`.
MilitaryWorldDigest make_naval_digest(const MilitaryTerrainInput &t, uint64_t unlock_bits) {
    MilitaryWorldDigest d = make_digest(t);
    for (int32_t c = 0; c < t.cell_count; ++c) {
        if (t.is_water[(size_t)c]) d.cell_owner_slot[(size_t)c] = -1;
    }
    d.country_unlock_bits.assign((size_t)d.country_capacity, 0ull);
    d.country_unlock_bits[0] = unlock_bits;
    return d;
}
#include "military_core_navigation_selftest.inc"
#include "military_core_performance_selftest.inc"
#include "military_core_flight_selftest.inc"
#include "military_core_front_selftest.inc"
#include "military_core_market_reuse_selftest.inc"
#include "military_core_payroll_selftest.inc"
} // namespace
bool MilitaryCore::self_test(std::string &report) {
    report.clear();
    const MilitaryTerrainInput t = make_hex_terrain(kW, kH);
    // Neighbour symmetry of the synthetic map (same convention as path TU).
    bool symmetric = true;
    for (int32_t c = 0; c < t.cell_count && symmetric; ++c) {
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t nb = t.neighbors[(size_t)c * 6 + (size_t)d];
            if (nb >= 0 && t.neighbors[(size_t)nb * 6 + (size_t)((d + 3) % 6)] != c) symmetric = false;
        }
    }
    ST_CHECK(symmetric, "32x24 wrap hex map: neighbour table symmetric");
    {
        Sim sim;
        ST_CHECK(sim.init(t, 2526), "index continuation init");
        auto &c = sim.core;
        const int32_t cell = cell_at(5, 5);
        const int32_t old = c.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 0, 0, 256);
        c._lots.count[(size_t)old] = 0;
        c._lots.active[(size_t)old] = 0;
        c._lots.free_list.push_back(old);
        const int32_t reused = c.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 0, 0, 256);
        c._lots.count[(size_t)reused] = 3;
        ST_CHECK(reused == old && c._lots.active[(size_t)old] == 0,
            "inactive linked slot reuse keeps original mutation semantics");
        const auto bytes = c.encode();
        MilitaryCore copy;
        std::string error;
        ST_CHECK(copy.configure(make_catalog(), 2526, error) && copy.set_terrain(t, error) &&
            copy.restore(bytes.data(), bytes.size(), error), "index continuation restore");
        ST_CHECK(copy._lot_army_head == c._lot_army_head && copy._lot_cell_head == c._lot_cell_head &&
            copy._lot_next == c._lot_next && copy._lot_link_kind == c._lot_link_kind &&
            copy._lot_link_loc == c._lot_link_loc && copy._lots.active == c._lots.active &&
            copy._lots.location_kind == c._lots.location_kind && copy._lots.location == c._lots.location &&
            copy._lots.count == c._lots.count && copy._lots.country_slot == c._lots.country_slot &&
            copy._lots.unit_type == c._lots.unit_type && copy._lots.equip_quality_q8 == c._lots.equip_quality_q8 &&
            copy._lots.condition_q16 == c._lots.condition_q16 && copy._lots.free_list == c._lots.free_list &&
            copy._armies.generation == c._armies.generation && copy._army_lane_pending == c._army_lane_pending &&
            copy._armies.free_list == c._armies.free_list,
            "index heads next inactive payload and free-slot order match field by field");
        ST_CHECK(copy.present_for_cell(cell) == c.present_for_cell(cell) && copy.encode() == bytes,
            "index continuation query and bytes stable");
        c._lot_next[(size_t)old] = old;
        auto cycle = c.encode();
        ST_CHECK(!copy.restore(cycle.data(), cycle.size(), error) && copy.encode() == bytes,
            "cyclic index rejected without modifying live state");
        c._lot_next[(size_t)old] = -1;
        auto legacy = bytes;
        legacy[4] = 1;
        ST_CHECK(!copy.restore(legacy.data(), legacy.size(), error) &&
            error == (std::string("pkmi_version_mismatch_expected_") + std::to_string(PKMI_VERSION)), "PKMI v1 explicitly refused");
    }
    if (!test_performance_supply(t, report)) return false;
    if (!test_performance_engagements(t, report)) return false;
    if (!test_performance_battle_plan(t, report)) return false;
    if (!test_performance_flight_sums(report)) return false;
    if (!test_performance_front(t, report)) return false;
    if (!test_performance_garrison(t, report)) return false;
    if (!test_performance_garrison_candidates(t, report)) return false;
    if (!test_performance_market_reuse(t, report)) return false;
    if (!test_performance_direct_wars(t, report)) return false;
    if (!test_performance_payroll_wars(t, report)) return false;
    if (!test_idle(t, report)) return false;
    if (!test_barracks_capacity_scale(t, report)) return false;
    if (!test_convoy_escort_scale(t, report)) return false;
    uint64_t h1 = 0, h2 = 0, w1 = 0, w2 = 0, a1 = 0, a2 = 0;
    std::string stats, stats2;
    if (!test_recruit_and_move(t, report, h1)) return false;
    if (!test_war_peace_save(t, report, w1)) return false;
    if (!test_partial_discharge(t, report)) return false;
    if (!test_procurement(t, report)) return false;
    if (!test_maintenance(t, report)) return false;
    if (!test_army_pay(t, report)) return false;
    if (!test_budget_envelope(t, report)) return false;
    if (!test_procurement_quota(t, report)) return false;
    if (!test_cross_channel_conservation(t, report)) return false;
    if (!test_naval_transport(t, report)) return false;
    if (!test_exploration(t, report)) return false;
    if (!test_ai(t, report, a1, stats)) return false;
    report += stats;
    std::string ignored;
    if (!test_recruit_and_move(t, ignored, h2) || !test_war_peace_save(t, ignored, w2) ||
        !test_ai(t, ignored, a2, stats2)) {
        report += "FAIL determinism rerun\n" + ignored.substr(ignored.find("FAIL") == std::string::npos ? ignored.size() : ignored.find("FAIL"));
        return false;
    }
    ST_CHECK(h1 == h2 && w1 == w2 && a1 == a2, "determinism: two runs give identical state_hash");
    {
        char hb[160];
        std::snprintf(hb, sizeof(hb), "hashes: recruit=%016llx war=%016llx ai=%016llx\n", (unsigned long long)h1,
                      (unsigned long long)w1, (unsigned long long)a1);
        report += hb;
    }
    return true;
}
#include "military_core_selftest_section_benchmark.inc"
} // namespace pk

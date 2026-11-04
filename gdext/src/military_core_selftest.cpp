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
//
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
                case MILITARY_INTENT_CASUALTY:
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

// --- 2..4. recruitment quota, army move path, foreign presence suppression
bool test_recruit_and_move(const MilitaryTerrainInput &t, std::string &report, uint64_t &hash_out) {
    Sim sim;
    ST_CHECK(sim.init(t, 1234), "sim init");
    const int32_t A = cell_at(5, 5);
    const int32_t B = cell_at(8, 5);
    {
        MilitaryCommand c;
        c.cell = A;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks A");
        c.cell = B;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks B");
        MilitaryCommand target;
        target.count = 0;
        target.value = 150;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 150");
    }
    ST_STEP(sim, 41);
    ST_CHECK(sim.core.posts_for_cell(A, 0) == 100 && sim.core.posts_for_cell(B, 0) == 100,
             "barracks completed: 100 posts each");
    ST_CHECK(sim.core.country_soldiers(0) == 150, "recruitment reached target exactly (150)");
    ST_CHECK(garrison_at(sim.core, A) <= 100 && garrison_at(sim.core, B) <= 100, "per-cell garrison <= posts");
    const int64_t enlisted_before = sim.enlist_by_cell[(size_t)A] + sim.enlist_by_cell[(size_t)B];
    ST_STEP(sim, 61);
    ST_CHECK(sim.enlist_by_cell[(size_t)A] + sim.enlist_by_cell[(size_t)B] == enlisted_before,
             "no enlistment after target reached");
    ST_CHECK(sim.core.country_soldiers(1) == 0, "other countries untouched");

    // Army from A's whole garrison marches to B (3 hexes east).
    const int64_t gA = garrison_at(sim.core, A);
    {
        MilitaryCommand c;
        c.cell = A;
        c.ints = {0, (int32_t)gA};
        ST_CHECK(sim.submit(MCMD_ARMY_CREATE, 0, c), "army.create at A");
    }
    ST_STEP(sim, sim.day + 1);
    const int32_t army = sim.army_of(0);
    ST_CHECK(army >= 0 && sim.core.armies().cached_headcount[(size_t)army] == gA, "army holds A's garrison");
    {
        MilitaryCommand c;
        c.army = sim.core.army_handle(army);
        c.cell = B;
        ST_CHECK(sim.submit(MCMD_ARMY_MOVE, 0, c), "army.move to B");
    }
    std::vector<int32_t> trail = {sim.core.armies().cell[(size_t)army]};
    for (int32_t k = 0; k < 8; ++k) {
        ST_STEP(sim, sim.day + 1);
        trail.push_back(sim.core.armies().cell[(size_t)army]);
    }
    bool contiguous = true;
    int32_t moves = 0;
    for (size_t i = 1; i < trail.size(); ++i) {
        contiguous = contiguous && is_neighbor(t, trail[i - 1], trail[i]);
        if (trail[i] != trail[i - 1]) ++moves;
    }
    ST_CHECK(trail.back() == B, "army arrived at B");
    ST_CHECK(contiguous && moves == sim.core.cell_distance(A, B), "army walked a contiguous shortest path, 1 hex/day");

    // Raise the target: A (emptied) gets quota, B (army present >= posts) gets none.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 400;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 400");
    }
    const int64_t a0 = sim.enlist_by_cell[(size_t)A], b0 = sim.enlist_by_cell[(size_t)B];
    ST_STEP(sim, sim.day + 12);
    ST_CHECK(sim.enlist_by_cell[(size_t)B] == b0, "army presence at B suppresses B's quota");
    ST_CHECK(sim.enlist_by_cell[(size_t)A] > a0, "emptied barracks A recruits again");
    ST_CHECK(sim.max_abs_reconcile == 0, "ledger reconcile_delta == 0 every day (recruit run)");
    hash_out = sim.core.state_hash();
    return true;
}

// --- 5..8. war -> engagement -> capture -> peace (cede + annex) -> PKMI -> ledger
bool test_war_peace_save(const MilitaryTerrainInput &t, std::string &report, uint64_t &hash_out) {
    Sim sim;
    ST_CHECK(sim.init(t, 777), "war sim init");
    const int32_t C = cell_at(13, 12);   // country 0, west neighbour of the enclave
    ST_CHECK(is_neighbor(t, C, kEnclave), "enclave adjacent to staging cell");
    {
        MilitaryCommand c;
        c.cell = C;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks C");
        MilitaryCommand target;
        target.value = 100;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 100");
    }
    ST_STEP(sim, 21);
    ST_CHECK(sim.core.country_soldiers(0) == 100, "staging garrison recruited");
    {
        MilitaryCommand c;
        c.cell = C;
        c.ints = {0, 100};
        ST_CHECK(sim.submit(MCMD_ARMY_CREATE, 0, c), "army.create at C");
        MilitaryCommand w;
        w.other = handle_for(2);
        ST_CHECK(sim.submit(MCMD_WAR_DECLARE, 0, w), "war.declare 0 -> 2");
    }
    ST_STEP(sim, sim.day + 1);
    ST_CHECK(sim.core.at_war(0, 2) && has_event(sim.core, MILITARY_EVENT_WAR_DECLARED), "war active + WAR_DECLARED event");
    const int32_t army = sim.army_of(0);
    ST_CHECK(army >= 0, "army exists");
    {
        MilitaryCommand c;
        c.army = sim.core.army_handle(army);
        c.cell = kEnclave;
        ST_CHECK(sim.submit(MCMD_ARMY_MOVE, 0, c), "army.move into enemy cell");
    }
    bool engaged = false;
    for (int32_t k = 0; k < 90 && sim.core.controller_of(kEnclave) != 0; ++k) {
        ST_STEP(sim, sim.day + 1);
        for (const MilitaryEngagement &e : sim.core.engagements()) engaged = engaged || e.active;
    }
    ST_CHECK(engaged, "movement into enemy cell opened an engagement");
    ST_CHECK(sim.core.controller_of(kEnclave) == 0, "capture: controller of enclave is the attacker");
    ST_CHECK(has_event(sim.core, MILITARY_EVENT_CELL_CONTROL_CHANGED), "CELL_CONTROL_CHANGED event emitted");
    ST_CHECK(sim.core.report().cells_captured > 0 || sim.core.control_revision() > 0, "control revision bumped");
    ST_STEP(sim, sim.day + 2);   // let run_wars record the full occupation

    // PKMI round trip mid-war (armies, engagements history, wars, events).
    {
        const std::vector<uint8_t> bytes = sim.core.encode();
        MilitaryCore copy;
        std::string error;
        copy.configure(make_catalog(), 777, error);
        copy.set_terrain(t, error);
        const bool ok = copy.restore(bytes.data(), bytes.size(), error);
        ST_CHECK(ok, std::string("PKMI restore ") + error);
        if (copy.state_hash() != sim.core.state_hash()) report += describe_diff(sim.core, copy);
        ST_CHECK(copy.state_hash() == sim.core.state_hash(), "PKMI restore -> identical state_hash");
        ST_CHECK(copy.encode() == bytes, "PKMI re-encode byte-identical");
    }

    std::vector<int32_t> ints = {MPEACE_CEDE_CELL, kEnclave, 0, MPEACE_ANNEX, 0, 0};
    std::vector<int64_t> longs = {0, 0};
    int32_t war_id = sim.core.war_between(0, 2);
    const MilitaryPeaceEvaluation ev = sim.core.evaluate_peace(war_id, handle_for(0), ints, longs);
    ST_CHECK(ev.valid && ev.willing_q16 >= ev.price_q16, "fully occupied enemy willing to accept cede+annex");
    {
        MilitaryCommand c;
        c.other = (uint64_t)(uint32_t)war_id;
        c.ints = ints;
        c.longs = longs;
        ST_CHECK(sim.submit(MCMD_PEACE_PROPOSE, 0, c), "peace.propose cede+annex");
    }
    ST_STEP(sim, sim.day + 1);
    bool cede = false, annex = false;
    for (const MilitaryIntent &in : sim.last) {
        if (in.kind == MILITARY_INTENT_TRANSFER_TERRITORY && in.cell == kEnclave && in.count == 1 &&
            in.country_b == handle_for(0))
            cede = true;
        if (in.kind == MILITARY_INTENT_ANNEX_COUNTRY && in.country_a == handle_for(2) && in.country_b == handle_for(0))
            annex = true;
    }
    ST_CHECK(cede && annex, "treaty emits TRANSFER_TERRITORY + ANNEX_COUNTRY intents the same day");
    ST_CHECK(!sim.core.at_war(0, 2) && has_event(sim.core, MILITARY_EVENT_WAR_ENDED) &&
                 has_event(sim.core, MILITARY_EVENT_COUNTRY_ANNEXED),
             "war closed, WAR_ENDED + COUNTRY_ANNEXED events");
    // Bridge applies the cession (D+1) the way Country would.
    sim.dg.cell_owner_slot[(size_t)kEnclave] = 0;
    sim.dg.country_handle[2] = 0;
    ST_STEP(sim, sim.day + 10);
    ST_CHECK(sim.max_abs_reconcile == 0 && sim.core.report().reconcile_delta == 0,
             "ledger reconcile_delta == 0 throughout the war run");
    {
        const std::vector<uint8_t> bytes = sim.core.encode();
        MilitaryCore copy;
        std::string error;
        copy.configure(make_catalog(), 777, error);
        copy.set_terrain(t, error);
        ST_CHECK(copy.restore(bytes.data(), bytes.size(), error) && copy.state_hash() == sim.core.state_hash() &&
                     copy.encode() == bytes,
                 "PKMI round trip after peace");
    }
    hash_out = sim.core.state_hash();
    return true;
}

// --- 9. auto-discharge reconciled against a partially applied Economy move
//
// run_recruitment removes the surplus garrison heads when it emits the
// DISCHARGE intent; the receipt must then only put back the heads Economy did
// NOT move (requested - committed). A receipt that removed them a second time
// (or a core that ignored the shortfall) leaves Military and Economy unequal.
bool test_partial_discharge(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 5252), "partial discharge sim init");
    const int32_t C = cell_at(5, 5);
    {
        MilitaryCommand c;
        c.cell = C;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "partial discharge: barracks C");
        MilitaryCommand target;
        target.count = 0;
        target.value = 100;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 100");
        MilitaryCommand auto_discharge;
        auto_discharge.count = 1;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_AUTO_DISCHARGE, 0, auto_discharge),
                 "partial discharge: auto discharge on");
    }
    ST_STEP(sim, 21);
    ST_CHECK(garrison_at(sim.core, C) == 100, "partial discharge: 100 soldiers at C");
    // Lower the target so the next sample day discharges 40 of them, and apply
    // only 25 of the 40 on the Economy side.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 60;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 60");
    }
    int64_t discharged = 0, committed = 0;
    bool saw_discharge = false;
    for (int32_t k = 0; k < 6 && !saw_discharge; ++k) {
        sim.last.clear();
        sim.receipts.clear();
        sim.dg.day = sim.day;
        ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
                 "partial discharge: step_day");
        ++sim.day;
        for (const MilitaryIntent &in : sim.last) {
            if (in.kind != MILITARY_INTENT_DISCHARGE) continue;
            saw_discharge = true;
            discharged += in.count;
            MilitaryIntentReceipt r;
            r.kind = in.kind;
            r.ok = 1;
            r.cell = in.cell;
            r.source_id = in.source_id;
            r.committed_count = in.count * 5 / 8;   // Economy moved 5/8 of the request
            committed += r.committed_count;
            sim.receipts.push_back(r);
        }
    }
    ST_CHECK(saw_discharge && discharged == 40, "partial discharge: emitted for the 40 surplus");
    const int64_t after_emit = garrison_at(sim.core, C);
    ST_CHECK(after_emit == 60, "partial discharge: lots already removed when emitted");
    // Next day: the shortfall goes back and nothing is removed twice.
    sim.last.clear();
    sim.dg.day = sim.day;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
             "partial discharge: receipt day");
    ++sim.day;
    ST_CHECK(garrison_at(sim.core, C) == after_emit + (discharged - committed),
             "partial discharge: only the unmoved heads return");
    ST_CHECK(garrison_at(sim.core, C) == 75, "partial discharge: 60 + 15 unmoved = 75");
    ST_CHECK(sim.core.country_soldiers(0) == 75, "partial discharge: country roster equals the cohort");
    // A failed receipt for the whole request puts every head back.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 40;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 40");
    }
    bool failed_receipt = false;
    for (int32_t k = 0; k < 8 && !failed_receipt; ++k) {
        sim.last.clear();
        sim.receipts.clear();
        sim.dg.day = sim.day;
        ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
                 "partial discharge: second step_day");
        ++sim.day;
        for (const MilitaryIntent &in : sim.last) {
            if (in.kind != MILITARY_INTENT_DISCHARGE) continue;
            failed_receipt = true;
            MilitaryIntentReceipt r;
            r.kind = in.kind;
            r.ok = 0;
            r.cell = in.cell;
            r.source_id = in.source_id;
            r.committed_count = 0;
            sim.receipts.push_back(r);
        }
    }
    ST_CHECK(failed_receipt, "partial discharge: second discharge emitted");
    const int64_t before_fail = garrison_at(sim.core, C);
    int64_t failed_request = 0;
    for (const MilitaryIntentReceipt &r : sim.receipts)
        failed_request += (int64_t)((r.source_id >> 48) & 0xFFFFull);
    sim.last.clear();
    sim.dg.day = sim.day;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
             "partial discharge: failed receipt day");
    ++sim.day;
    ST_CHECK(failed_request > 0 && garrison_at(sim.core, C) == before_fail + failed_request,
             "partial discharge: a failed receipt refunds the whole request");
    return true;
}

// --- 9b. Army pay (army-pay contract §2 / §4.3): wages follow the people.
//
// Two holders, one treasury: a garrison lot at A and an army lot that marched
// off it. run_wages_and_upkeep must emit exactly one PAY_WAGES row for the
// garrison (headed for A) and one ARMY_PAY row for the formation (headed for its
// lane), the two amounts must sum to the total payroll demand (conservation), and
// the army row must carry the army share -- not the garrison's -- so a campaign
// never drains the lane while the home cohort keeps collecting.
bool test_army_pay(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 60601), "army pay sim init");
    const int32_t A = cell_at(5, 5);
    const int32_t B = cell_at(9, 5);
    // A fixed per-head wage keeps the arithmetic exact: wage_mode 1 (ABSOLUTE)
    // ignores the living cost and the MSTAT_WAGE stat, so both paths use
    // `wage_absolute` -- which is the contract's "the SAME per-head daily wage"
    // requirement, checked below by comparing the two emitted rows.
    constexpr int64_t kWage = 25000;   // MONEY_SCALE per head per day
    int64_t garrison_heads = 0;
    int64_t army_heads = 0;
    {
        MilitaryCommand c;
        c.cell = A;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "army pay: barracks at A");
        MilitaryCommand target;
        target.count = 0;
        target.value = 50;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "army pay: target 50");
        MilitaryCommand wage;
        wage.count = 1;          // wage_mode = ABSOLUTE
        wage.value = kWage;
        ST_CHECK(sim.submit(MCMD_POLICY_SET_WAGE, 0, wage), "army pay: absolute wage policy");
    }
    ST_STEP(sim, 41);
    const int64_t recruited = garrison_at(sim.core, A);
    ST_CHECK(recruited == 50, "army pay: 50 soldiers recruited at A");
    // Take most of the garrison into a formation and march it away, so the home
    // cell and the formation are different places to pay.
    {
        MilitaryCommand c;
        c.cell = A;
        c.ints = {0, 40};
        ST_CHECK(sim.submit(MCMD_ARMY_CREATE, 0, c), "army pay: army.create 40 at A");
    }
    ST_STEP(sim, sim.day + 1);
    const int32_t army = sim.army_of(0);
    ST_CHECK(army >= 0, "army pay: formation exists");
    {
        MilitaryCommand c;
        c.army = sim.core.army_handle(army);
        c.cell = B;
        ST_CHECK(sim.submit(MCMD_ARMY_MOVE, 0, c), "army pay: army.move to B");
    }
    for (int32_t k = 0; k < 8; ++k) ST_STEP(sim, sim.day + 1);
    ST_CHECK(sim.core.armies().cell[(size_t)army] == B, "army pay: formation arrived at B");
    garrison_heads = garrison_at(sim.core, A);
    army_heads = sim.core.armies().cached_headcount[(size_t)army];
    ST_CHECK(garrison_heads == 10 && army_heads == 40,
             "army pay: 10 garrisoned at A, 40 with the formation");

    // One wages day, collected instead of auto-receipted: the harness only
    // answers ENLIST/LEVY/DISCHARGE, so the pay rows stay in `last` for us.
    sim.last.clear();
    sim.receipts.clear();
    sim.dg.day = sim.day;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
             "army pay: step_day");
    int64_t garrison_pay = 0, army_pay = 0;
    int64_t garrison_rows = 0, army_rows = 0;
    uint64_t army_source = 0;
    int32_t army_cell = -1;
    for (const MilitaryIntent &in : sim.last) {
        if (in.kind == MILITARY_INTENT_PAY_WAGES) {
            if (in.cell == A) {
                garrison_pay += in.amount;
                ++garrison_rows;
            }
        } else if (in.kind == MILITARY_INTENT_ARMY_PAY) {
            army_pay += in.amount;
            ++army_rows;
            army_source = in.source_id;
            army_cell = in.cell;
        }
    }
    ST_CHECK(garrison_rows == 1, "army pay: exactly one garrison payroll row");
    ST_CHECK(army_rows == 1, "army pay: exactly one army payroll row");
    ST_CHECK(garrison_pay == garrison_heads * kWage,
             "army pay: garrison row is garrison heads x the shared daily wage");
    ST_CHECK(army_pay == army_heads * kWage,
             "army pay: army row is formation heads x the SAME daily wage");
    // Conservation: the two rows together are the whole payroll demand, no head
    // is paid twice and none is dropped.
    ST_CHECK(garrison_pay + army_pay == (garrison_heads + army_heads) * kWage,
             "army pay: garrison + army pay equals heads x wage (conserved)");
    ST_CHECK(army_pay == 40 * kWage && garrison_pay == 10 * kWage,
             "army pay: the army lane receives the army share, not the garrison's");
    // The row names the formation by HANDLE (the lane key) and sits at the
    // formation's cell, never at the home cell it left behind.
    ST_CHECK(army_source == sim.core.army_handle(army),
             "army pay: army row carries the formation handle");
    ST_CHECK(army_cell == B, "army pay: army row is anchored at the formation's cell");
    // ...and the garrison row really is the garrison's: the home cell keeps
    // paying its own 10 and no longer carries the embarked 40.
    ST_CHECK(garrison_pay != (garrison_heads + army_heads) * kWage,
             "army pay: the home cell no longer covers the embarked heads");
    // Receipts: army pay is bookkeeping only (the lane cash is Economy's), so a
    // success or a failure must not change the roster or the lot counts.
    std::vector<MilitaryIntentReceipt> receipts;
    for (const MilitaryIntent &in : sim.last) {
        if (in.kind != MILITARY_INTENT_ARMY_PAY && in.kind != MILITARY_INTENT_PAY_WAGES)
            continue;
        MilitaryIntentReceipt r;
        r.kind = in.kind;
        r.ok = 1;
        r.cell = in.cell;
        r.source_id = in.source_id;
        r.committed_count = in.count;
        r.committed_amount = in.amount;
        receipts.push_back(r);
    }
    const int64_t roster_before = sim.core.country_soldiers(0);
    ST_CHECK(!receipts.empty(), "army pay: pay rows produced receipts");
    ++sim.day;
    sim.dg.day = sim.day;
    std::vector<MilitaryIntent> next;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, receipts, next, sim.error),
             "army pay: receipt day");
    ++sim.day;
    ST_CHECK(sim.core.country_soldiers(0) == roster_before,
             "army pay: a pay receipt never moves heads");
    ST_CHECK(garrison_at(sim.core, A) == garrison_heads,
             "army pay: a pay receipt leaves the garrison lot untouched");
    return true;
}

// --- 10. AI agenda soak
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

// --- 11. 3-cell procurement (design 9.3): only markets of the same country in
// the demander's ring, nothing in range is unmet demand, and a delivered
// quantity is booked in the sec 9.7 ledger.
//
// The synthetic digest carries a market every 37th cell, so a garrison on its
// own ring sources locally; a garrison far from any own market records unmet
// demand instead of scanning the map.
bool test_procurement(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 9091), "procurement sim init");
    // Markets of the synthetic digest sit on every 37th cell of the map. A cell
    // whose 3-ring holds no market sees only unmet demand (no global scan).
    int32_t far_cell = -1;
    int32_t near_cell = -1;
    for (int32_t c = 0; c < t.cell_count; ++c) {
        const int32_t col = c % kW;
        if (col >= 14) continue;   // country 0 owns columns 0..13
        bool has_market = false;
        for (int32_t m = 0; m < t.cell_count; m += 37) {
            if (sim.core.cell_distance(c, m) <= MILITARY_SUPPLY_RADIUS) has_market = true;
        }
        if (c % 37 == 0 && near_cell < 0 && has_market) near_cell = c;
        if (!has_market && far_cell < 0) far_cell = c;
    }
    ST_CHECK(near_cell >= 0, "procurement: a market cell of country 0 exists");
    ST_CHECK(far_cell >= 0, "procurement: a country 0 cell with no market in its ring exists");
    {
        MilitaryCommand c;
        c.cell = near_cell;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "procurement: barracks on a market cell");
        MilitaryCommand target;
        target.count = 0;
        target.value = 50;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "procurement: target 50");
    }
    for (int32_t day = 0; day < 60; ++day) ST_STEP(sim, sim.day + 1);
    ST_CHECK(garrison_at(sim.core, near_cell) > 0, "procurement: garrison recruited on the market cell");
    int64_t held = 0;
    for (const MilitaryStockRow &row : sim.core.stocks()) {
        if (row.holder_kind == MILITARY_LOT_GARRISON && row.holder == near_cell && row.qty > 0) held += row.qty;
    }
    ST_CHECK(held > 0, "procurement: garrison stock was bought from its own 3-cell ring");
    ST_CHECK(sim.max_abs_reconcile == 0, "procurement: ledger reconcile_delta == 0 every day");
    // A far garrison cell (no market in range) must not invent goods: build a
    // barracks there and confirm nothing arrives from outside the ring.
    MilitaryCommand far;
    far.cell = far_cell;
    far.unit_to = 0;
    ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, far), "procurement: barracks with no market in range");
    for (int32_t day = 0; day < 20; ++day) ST_STEP(sim, sim.day + 1);
    int64_t far_held = 0;
    for (const MilitaryStockRow &row : sim.core.stocks()) {
        if (row.holder_kind == MILITARY_LOT_GARRISON && row.holder == far_cell && row.qty > 0) far_held += row.qty;
    }
    ST_CHECK(far_held == 0, "procurement: nothing supplied outside the 3-cell ring (no fallback scan)");
    return true;
}

// --- 12. Naval transport (army-personnel contract 2 §2.1 / design §7.4).
//
// The synthetic map only wraps east-west, so a full-width water band cuts it in
// two and every land route between the shores has to cross exactly `band`
// consecutive water cells. Those are the shapes the transport gate has to
// classify: <= 3 water cells with the coastal technology, any width with the
// ocean technology, nothing without either.
MilitaryTerrainInput make_hex_terrain_with_water_band(int32_t first_row, int32_t band) {
    MilitaryTerrainInput t = make_hex_terrain(kW, kH);
    for (int32_t c = 0; c < t.cell_count; ++c) {
        const int32_t row = c / kW;
        if (row < first_row || row >= first_row + band) continue;
        // Water cells keep the PLAIN terrain entry: whether they can be entered
        // is the transport gate's decision, not the landform table's.
        t.is_water[(size_t)c] = 1;
        t.has_river[(size_t)c] = 0;
    }
    return t;
}

// Unlock bits: 0 = cannon (existing fixture), 1 = coastal transport,
// 2 = ocean transport (army-personnel contract 2 §2.2 catalog slots).
constexpr int32_t kCoastalTransportBit = 1;
constexpr int32_t kOceanTransportBit = 2;
constexpr uint64_t kCoastalUnlock = 1ull << kCoastalTransportBit;
constexpr uint64_t kOceanUnlock = 1ull << kOceanTransportBit;

MilitaryCatalog make_naval_catalog() {
    MilitaryCatalog c = make_catalog();
    c.unlock_count = 3;
    c.coastal_transport_bit = kCoastalTransportBit;
    c.ocean_transport_bit = kOceanTransportBit;
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

// --- 9c. Budget envelope (任务 6 / 需求 5.1, 5.5, 9.3).
//
// The envelope is a share of the country's daily treasury cash, split into
// three channel ceilings. Three properties are easy to get wrong and are pinned
// here because the panel and the settlement both read them:
//
//  1. `budget_share_bp <= 0` is NO envelope, not a zero envelope. Every foreign
//     AI country and every save loaded before the player re-pushes a policy must
//     keep the legacy cash-driven behaviour, so `enabled` stays false on the
//     default policy. A ceiling of 0 is the different statement "this channel is
//     paused", and only a real envelope can express it.
//  2. Channel shares are percentages of the envelope itself, so 6000/2000/2000
//     spends it exactly and a single 0 pauses exactly one channel.
//  3. The three NEW budget fields are transient (需求 9.3): they must not enter
//     state_hash and must not survive PKMI, because the player session re-pushes
//     them after a load. `procurement_share_bp` is deliberately outside that set
//     - it predates this work and is already a persisted policy field - so the
//     procurement channel reuses it instead of introducing a second, unsaved
//     copy of the same number.
//
// State is driven through `apply_command` (immediate, queues nothing) and the
// guard rails through `submit` (rejections leave the queue untouched), so the
// hash/encode comparisons at the end are not disturbed by pending commands.
bool test_budget_envelope(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 60602), "budget envelope sim init");
    const int64_t cash = sim.dg.country_cash[(size_t)0];
    ST_CHECK(cash > 0, "budget envelope: digest carries treasury cash");

    // (1) The default policy has no envelope at all.
    {
        const MilitaryCore::MilitaryBudgetSplit split = sim.core.budget_split(0, cash);
        ST_CHECK(!split.enabled, "budget envelope: default policy has no envelope");
        ST_CHECK(split.envelope_daily == 0 && split.wage_ceiling == 0 &&
                     split.upkeep_ceiling == 0 && split.procurement_ceiling == 0,
                 "budget envelope: no envelope splits into zero ceilings");
    }

    // (2) A total share opens the envelope; the default channels fill it.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 1000;   // 10% of treasury cash per day
        sim.core.apply_command(c, sim.day);
        const MilitaryCore::MilitaryBudgetSplit split = sim.core.budget_split(0, cash);
        ST_CHECK(split.enabled, "budget envelope: a positive share enables it");
        ST_CHECK(split.envelope_daily == cash / 10,
                 "budget envelope: envelope is the share x treasury cash");
        ST_CHECK(split.wage_ceiling == split.envelope_daily * 6000 / 10000 &&
                     split.upkeep_ceiling == split.envelope_daily * 2000 / 10000 &&
                     split.procurement_ceiling == split.envelope_daily * 2000 / 10000,
                 "budget envelope: default channels are 60/20/20 of the envelope");
        ST_CHECK(split.wage_ceiling + split.upkeep_ceiling + split.procurement_ceiling ==
                     split.envelope_daily,
                 "budget envelope: the default channels spend it exactly");
    }

    // (3) -1 keeps a channel; 0 pauses exactly that channel.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = -1;
        c.ints = {-1, -1, 0};
        sim.core.apply_command(c, sim.day);
        const MilitaryCore::MilitaryBudgetSplit split = sim.core.budget_split(0, cash);
        ST_CHECK(split.enabled && split.procurement_ceiling == 0,
                 "budget envelope: a zero channel pauses, the envelope stays on");
        ST_CHECK(split.wage_ceiling == split.envelope_daily * 6000 / 10000 &&
                     split.upkeep_ceiling == split.envelope_daily * 2000 / 10000,
                 "budget envelope: untouched channels keep their stored share");
    }

    // (4) A zero total removes the envelope but keeps the channel shares, so the
    // panel never loses what the player chose.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 0;
        sim.core.apply_command(c, sim.day);
        ST_CHECK(!sim.core.budget_split(0, cash).enabled,
                 "budget envelope: a zero total disables it again");
        const MilitaryCountryPolicy &p = sim.core.policies()[(size_t)0];
        ST_CHECK(p.budget_wage_bp == 6000 && p.procurement_share_bp == 0,
                 "budget envelope: disabling keeps the stored channel shares");
    }

    // (5) Guard rails. Rejections never queue, so nothing below moves the state
    // the hash comparison at the end is looking at.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 10001;
        std::string error;
        ST_CHECK(!sim.core.submit(c, error) && error == "command_bad_budget_share",
                 "budget envelope: a total above 100% is rejected");

        MilitaryCommand many;
        many.op = MCMD_POLICY_SET_BUDGET;
        many.country = handle_for(0);
        many.ints = {1000, 1000, 1000, 1000};
        ST_CHECK(!sim.core.submit(many, error) && error == "command_bad_budget_channels",
                 "budget envelope: more than three channels is rejected");

        MilitaryCommand bad;
        bad.op = MCMD_POLICY_SET_BUDGET;
        bad.country = handle_for(0);
        bad.ints = {10001, -1, -1};
        ST_CHECK(!sim.core.submit(bad, error) &&
                     error == "command_bad_budget_channel_share",
                 "budget envelope: an out-of-range channel share is rejected");

        // Stored 4000 / 4000 / 2000 is exactly 100%. One more basis point on a
        // single channel must fail, which also proves an unspecified channel is
        // checked against its STORED value rather than against zero.
        MilitaryCommand stored;
        stored.op = MCMD_POLICY_SET_BUDGET;
        stored.country = handle_for(0);
        stored.value = 1000;
        stored.ints = {4000, 4000, 2000};
        sim.core.apply_command(stored, sim.day);
        MilitaryCommand over;
        over.op = MCMD_POLICY_SET_BUDGET;
        over.country = handle_for(0);
        over.ints = {4001, -1, -1};
        ST_CHECK(!sim.core.submit(over, error) &&
                     error == "command_budget_channels_exceed_10000",
                 "budget envelope: a partial update is checked against stored channels");
        MilitaryCommand equal;
        equal.op = MCMD_POLICY_SET_BUDGET;
        equal.country = handle_for(0);
        equal.value = -1;
        equal.ints = {4000, 4000, 2000};
        ST_CHECK(sim.core.submit(equal, error),
                 "budget envelope: channels totalling exactly 100% are accepted");
    }

    // (6) Transient (需求 9.3). Two identical cores that differ ONLY in the three
    // NEW budget fields have to agree on both the hash and the encoded bytes.
    // `procurement_share_bp` is deliberately NOT in that set: it predates this
    // work and is already a persisted policy field, so the procurement channel
    // reuses it instead of introducing a second, unsaved copy.
    {
        std::string error;
        MilitaryCore plain;
        MilitaryCore budgeted;
        ST_CHECK(plain.configure(make_catalog(), 60602, error) &&
                     budgeted.configure(make_catalog(), 60602, error),
                 "budget envelope: two cores configure");
        ST_CHECK(plain.set_terrain(t, error) && budgeted.set_terrain(t, error),
                 "budget envelope: two cores take the terrain");
        ST_CHECK(plain.ensure_country_slot(handle_for(0)) == 0 &&
                     budgeted.ensure_country_slot(handle_for(0)) == 0,
                 "budget envelope: two cores open the same country slot");
        MilitaryCountryPolicy &p = budgeted._policies[(size_t)0];
        p.budget_share_bp = 3000;
        p.budget_wage_bp = 5000;
        p.budget_upkeep_bp = 3000;
        ST_CHECK(budgeted.budget_split(0, cash).enabled &&
                     !plain.budget_split(0, cash).enabled,
                 "budget envelope: the two cores really differ on the envelope");
        ST_CHECK(plain.state_hash() == budgeted.state_hash(),
                 "budget envelope: the three budget fields stay out of state_hash");
        ST_CHECK(plain.encode() == budgeted.encode(),
                 "budget envelope: the three budget fields stay out of PKMI");
        // A restored core therefore comes back with no envelope: the player
        // session re-pushes the policy, which is the documented contract.
        const std::vector<uint8_t> bytes = budgeted.encode();
        MilitaryCore restored;
        restored.configure(make_catalog(), 60602, error);
        restored.set_terrain(t, error);
        ST_CHECK(restored.restore(bytes.data(), bytes.size(), error),
                 "budget envelope: PKMI restore accepts the stream");
        const int32_t slot = restored.country_slot_for_handle(handle_for(0));
        ST_CHECK(slot >= 0 && !restored.budget_split(slot, cash).enabled,
                 "budget envelope: a restored core starts with no envelope");
    }

    // (7) Settlement (任务 7 / 需求 5.2, 5.3, 7.1). Runs the real `step_day`
    // path over a recruited garrison instead of re-deriving the arithmetic here:
    // the point is that the settlement WRITES these numbers, and that with no
    // envelope it writes none of them.
    {
        Sim pay;
        ST_CHECK(pay.init(t, 60603), "budget settlement sim init");
        const int32_t A = cell_at(5, 5);
        {
            MilitaryCommand c;
            c.cell = A;
            c.unit_to = 0;
            ST_CHECK(pay.submit(MCMD_STATE_BUILD, 0, c),
                     "budget settlement: barracks at A");
            MilitaryCommand target;
            target.count = 0;
            target.value = 40;
            ST_CHECK(pay.submit(MCMD_FORCE_SET_TARGET, 0, target),
                     "budget settlement: target 40");
            MilitaryCommand wage;
            wage.count = 1;          // ABSOLUTE, so the arithmetic is exact
            // Large enough that 40 heads out-earn the 1-bp envelope opened
            // below (cash 1e12 -> envelope 1e8 -> wage ceiling 6e7, payroll
            // 40 * 2e6 = 8e7). A smaller wage would never exercise overspend.
            wage.value = 2000000;
            ST_CHECK(pay.submit(MCMD_POLICY_SET_WAGE, 0, wage),
                     "budget settlement: absolute wage policy");
        }
        ST_STEP(pay, 41);
        ST_CHECK(garrison_at(pay.core, A) == 40,
                 "budget settlement: 40 soldiers recruited");

        // One settled day WITHOUT an envelope: nothing may be reported, which is
        // 需求 5.5's "AI countries do not change" expressed as a contract.
        ST_STEP(pay, pay.day + 1);
        {
            const MilitaryCountryPolicy &p = pay.core.policies()[(size_t)0];
            ST_CHECK(p.wage_demand == 0 && p.wage_arrears == 0 &&
                         p.wage_overspend == 0,
                     "budget settlement: no envelope reports no wage outcome");
        }

        // Now open an envelope whose wage share is far below the payroll, and
        // settle one more day. 军饷 is high priority, so it gets paid anyway and
        // the excess is reported; nothing is left in arrears.
        const int64_t payroll = 40 * 2000000;
        {
            MilitaryCommand c;
            c.op = MCMD_POLICY_SET_BUDGET;
            c.country = handle_for(0);
            c.value = 1;     // 0.01% of cash: a ceiling far under the payroll
            c.ints = {6000, 2000, 2000};
            ST_CHECK(pay.submit(MCMD_POLICY_SET_BUDGET, 0, c),
                     "budget settlement: a tiny envelope is accepted");
        }
        ST_STEP(pay, pay.day + 1);
        {
            const MilitaryCountryPolicy &p = pay.core.policies()[(size_t)0];
            const MilitaryCore::MilitaryBudgetSplit split = pay.core.budget_split(
                0, pay.dg.country_cash[(size_t)0]);
            ST_CHECK(split.enabled && split.wage_ceiling < payroll,
                     "budget settlement: the wage ceiling really is under the bill");
            ST_CHECK(p.wage_demand == payroll,
                     "budget settlement: the day's demand is the whole payroll");
            ST_CHECK(p.wage_arrears == 0,
                     "budget settlement: a solvent country leaves no wage arrears");
            ST_CHECK(p.wage_overspend == payroll - split.wage_ceiling,
                     "budget settlement: paying past the share is reported, not blocked");
        }
    }

    return true;
}

// --- 12. Procurement quota (任务 8 / 需求 5.4, 6.2, 7.1).
//
// The point of this case is that `run_procurement` now CONSUMES a money quota
// rather than buying whatever the market can sell. It therefore asserts three
// things the arithmetic alone cannot: that a country without an envelope still
// reports nothing, that a metered country never spends past its ceiling
// (procurement is low priority - it stops, it does not overspend), and that the
// reported spend equals the money the emitted intents actually carry, so the
// panel and the treasury cannot drift apart.
bool test_procurement_quota(const MilitaryTerrainInput &t, std::string &report) {
    Sim buy;
    ST_CHECK(buy.init(t, 60604), "procurement quota: sim init");

    // Same market-cell discovery as test_procurement: a garrison must sit on a
    // cell whose 3-ring holds one of the synthetic digest's markets.
    int32_t near_cell = -1;
    for (int32_t c = 0; c < t.cell_count && near_cell < 0; ++c) {
        if (c % kW >= 14) continue;            // country 0 owns columns 0..13
        if (c % 37 != 0) continue;
        near_cell = c;
    }
    ST_CHECK(near_cell >= 0, "procurement quota: a country 0 market cell exists");
    {
        MilitaryCommand c;
        c.cell = near_cell;
        c.unit_to = 0;
        ST_CHECK(buy.submit(MCMD_STATE_BUILD, 0, c), "procurement quota: barracks at the market");
        MilitaryCommand target;
        target.count = 0;
        target.value = 50;
        ST_CHECK(buy.submit(MCMD_FORCE_SET_TARGET, 0, target), "procurement quota: target 50");
    }
    ST_STEP(buy, 60);
    ST_CHECK(garrison_at(buy.core, near_cell) > 0, "procurement quota: garrison recruited");

    // Money the emitted PROCURE_GOOD intents carry on the last stepped day. This
    // is the treasury's view of the pass, so comparing it with the policy row is
    // a conservation check rather than a restatement of the same variable.
    // Filtered by country: the other two slots have no demanders today, and a
    // shared sum would silently start passing if they ever did.
    const uint64_t home = handle_for(0);
    auto procured_amount = [&](const std::vector<MilitaryIntent> &rows) {
        int64_t sum = 0;
        for (const MilitaryIntent &in : rows) {
            if (in.kind == MILITARY_INTENT_PROCURE_GOOD && in.country_a == home)
                sum += in.amount;
        }
        return sum;
    };

    // ---- 1. no envelope: buy the gap, report nothing ----------------------
    int64_t free_spend = 0;
    for (int32_t day = 0; day < 20; ++day) {
        ST_STEP(buy, buy.day + 1);
        free_spend += procured_amount(buy.last);
        const MilitaryCountryPolicy &p = buy.core.policies()[(size_t)0];
        if (p.procurement_budget_used != 0 || p.procurement_deferred_units != 0) {
            report += "FAIL procurement quota: no envelope must report no outcome\n";
            return false;
        }
    }
    ST_CHECK(free_spend > 0, "procurement quota: an unmetered country keeps buying");

    // ---- 2. a tiny envelope: the quota meters the purchase ----------------
    // cash 1e6 x 0.01% = an envelope of 100 money, and with the whole envelope on
    // the procurement channel that is the day's ceiling. A need unit costs 20
    // money here (price 20000 per GOODS_SCALE with the ration yield at 1.0), so
    // the quota affords 5 units - far below a 50-head garrison's 10-day target.
    buy.dg.country_cash[(size_t)0] = 1000000;
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 1;
        c.ints = {0, 0, 10000};
        ST_CHECK(buy.submit(MCMD_POLICY_SET_BUDGET, 0, c),
                 "procurement quota: a procurement-only envelope is accepted");
    }
    // Commands apply inside `step_day` on their effective day, so the split can
    // only be read after one more day; asserting it here (before the step) was
    // reading the pre-command policy and is exactly the mistake this line fixes.
    ST_STEP(buy, buy.day + 1);
    const MilitaryCore::MilitaryBudgetSplit split = buy.core.budget_split(
        0, buy.dg.country_cash[(size_t)0]);
    ST_CHECK(split.enabled && split.procurement_ceiling == 100,
             "procurement quota: the ceiling is the whole 100-money envelope");

    bool metered = false;
    bool overspent = false;
    bool drifted = false;
    int64_t deferred_total = 0;
    for (int32_t day = 0; day < 20; ++day) {
        ST_STEP(buy, buy.day + 1);
        const MilitaryCountryPolicy &p = buy.core.policies()[(size_t)0];
        if (p.procurement_budget_used > split.procurement_ceiling) overspent = true;
        // Conservation: what the policy reports spending is exactly what the
        // batch charges the treasury. No second ledger, no rounding gap.
        if (p.procurement_budget_used != procured_amount(buy.last)) drifted = true;
        if (p.procurement_deferred_units > 0) {
            metered = true;
            deferred_total += p.procurement_deferred_units;
        }
    }
    ST_CHECK(!overspent,
             "procurement quota: a low-priority channel never overspends its share");
    ST_CHECK(!drifted,
             "procurement quota: reported spend equals the emitted intents");
    ST_CHECK(metered && deferred_total > 0,
             "procurement quota: the unfunded gap is reported as 待购");

    // ---- 3. restore the quota and the same gap is bought again ------------
    // The shortfall is not a separate queue: demand is `want - held`, so nothing
    // has to be replayed and the next pass buys in the same cheapest-first order.
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = handle_for(0);
        c.value = 0;            // back to "no envelope"
        c.ints = {-1, -1, -1};
        ST_CHECK(buy.submit(MCMD_POLICY_SET_BUDGET, 0, c),
                 "procurement quota: the envelope can be switched off again");
    }
    int64_t resumed = 0;
    for (int32_t day = 0; day < 10; ++day) {
        ST_STEP(buy, buy.day + 1);
        resumed += procured_amount(buy.last);
    }
    ST_CHECK(resumed > 0, "procurement quota: procurement resumes once the quota is gone");
    {
        const MilitaryCountryPolicy &p = buy.core.policies()[(size_t)0];
        ST_CHECK(p.procurement_budget_used == 0 && p.procurement_deferred_units == 0,
                 "procurement quota: switching the envelope off clears the counters");
    }
    return true;
}

// --- 13. Cross-channel conservation (任务 10 / 需求 9.4, 7.2).
//
// 7 and 8 each prove their own channel books itself. Neither checks what happens
// when all three settle against the SAME treasury on the SAME day, which is the
// only configuration where a double debit could hide:
//
//   * 军饷 (op 5) and 采购 (op 6) are emitted in one `step_day`, and both are
//     translated into economy commands keyed by the same country handle. If the
//     payroll planner and the procurement quota each assumed the full cash
//     balance, a country could pay out cash + ceiling while only cash existed.
//   * 维护 (op 9) is deferred to D+1 by the bridge, so on day D the military side
//     reports an amount the treasury has not been charged for yet. The invariant
//     that has to hold is therefore not "cash - spend >= 0" on the military book
//     alone, but "the emitted rows never claim more than the cash the split was
//     computed from" - the split is what the bridge will actually collect from.
//
// The assertions below are all cross-channel: per-day sums of the three intent
// kinds, compared against the cash the core itself used for the split, and each
// channel's own reported figure compared against the rows it emitted. An envelope
// that lets every channel individually stay under its ceiling but collectively
// promise more money than exists fails here and nowhere else.
bool test_cross_channel_conservation(const MilitaryTerrainInput &t,
                                     std::string &report) {
    Sim sim;
    // A non-zero barracks upkeep is what makes 维护 reachable at all: with the
    // default 0 catalog the channel has nothing to bill, so every cross-channel
    // assertion about it would pass without ever running.
    ST_CHECK(sim.init(t, 60605, make_catalog(20000)), "cross channel: sim init");

    // A garrison that owes wages and wants equipment, parked on a market cell so
    // procurement has somewhere to buy. Same discovery rule as the quota case.
    int32_t near_cell = -1;
    for (int32_t c = 0; c < t.cell_count && near_cell < 0; ++c) {
        if (c % kW >= 14) continue;
        if (c % 37 != 0) continue;
        near_cell = c;
    }
    ST_CHECK(near_cell >= 0, "cross channel: a country 0 market cell exists");
    {
        MilitaryCommand c;
        c.cell = near_cell;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c),
                 "cross channel: barracks at the market");
        MilitaryCommand target;
        target.count = 0;
        target.value = 50;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target),
                 "cross channel: target 50");
        MilitaryCommand wage;
        wage.count = 1;              // ABSOLUTE, so the payroll is exact
        wage.value = 2000000;
        ST_CHECK(sim.submit(MCMD_POLICY_SET_WAGE, 0, wage),
                 "cross channel: absolute wage policy");
    }
    sim.run_until(61);
    ST_CHECK(garrison_at(sim.core, near_cell) > 0,
             "cross channel: the garrison recruited");

    // Every channel is squeezed at once. The total share is 20% of cash and the
    // channels are 40/30/30 - deliberately close to 100% so each ceiling is a
    // binding constraint, and no channel can be funded out of another's slack.
    const uint64_t home = handle_for(0);
    auto amount_of = [&](const std::vector<MilitaryIntent> &rows, uint8_t kind) {
        int64_t sum = 0;
        for (const MilitaryIntent &in : rows) {
            if (in.kind == kind && in.country_a == home) sum += in.amount;
        }
        return sum;
    };
    auto rows_of = [&](const std::vector<MilitaryIntent> &rows, uint8_t kind) {
        int64_t n = 0;
        for (const MilitaryIntent &in : rows) {
            if (in.kind == kind && in.country_a == home) ++n;
        }
        return n;
    };

    // Shrink the treasury so the envelope is a real constraint rather than a
    // rounding detail on a 1e12 pile: 2,000,000 cash x 20% = 400,000 envelope,
    // which the 40/30/30 split cuts into 160,000 / 120,000 / 120,000 per day.
    sim.dg.country_cash[(size_t)0] = 2000000;
    {
        MilitaryCommand c;
        c.op = MCMD_POLICY_SET_BUDGET;
        c.country = home;
        c.value = 2000;
        c.ints = {4000, 3000, 3000};
        ST_CHECK(sim.submit(MCMD_POLICY_SET_BUDGET, 0, c),
                 "cross channel: a binding 40/30/30 envelope is accepted");
    }
    // Budget commands take effect on their own day, so step once before reading
    // the split (same trap the quota case documents).
    // 50 days: long enough to cross several `kUpkeepPeriod` (5) settlements and
    // to let a suppressed procurement queue build up a backlog, which is where
    // a channel would start reaching into another channel's cash if the
    // committed-采购 deduction were missing.
    int64_t days_checked = 0;
    int64_t wage_rows_total = 0;
    int64_t proc_rows_total = 0;
    int64_t upkeep_rows_total = 0;
    int64_t upkeep_bills = 0;
    bool over_cash = false;
    bool wage_drift = false;
    bool proc_drift = false;
    bool upkeep_drift = false;
    bool upkeep_overpaid = false;
    bool ceiling_blown = false;
    for (int32_t day = 0; day < 50; ++day) {
        sim.step();
        const MilitaryCountryPolicy &p = sim.core.policies()[(size_t)0];
        const MilitaryCore::MilitaryBudgetSplit split = sim.core.budget_split(
            0, sim.dg.country_cash[(size_t)0]);
        if (!split.enabled) continue;
        const int64_t cash = sim.dg.country_cash[(size_t)0];
        const int64_t wages = amount_of(sim.last, MILITARY_INTENT_PAY_WAGES);
        const int64_t bought = amount_of(sim.last, MILITARY_INTENT_PROCURE_GOOD);
        const int64_t upkeep = amount_of(sim.last, MILITARY_INTENT_SPEND_CASH);
        // The three channels must never together promise more than the treasury
        // holds: 军饷 and 维护 draw cash, and 采购 is charged the same treasury.
        if (wages + upkeep + bought > cash) over_cash = true;
        // 军饷 is high priority: it may pass its share, but what it reports as
        // paid has to be exactly what the rows charge. A drift here means the
        // panel and the treasury disagree about the same money.
        if (p.wage_demand > 0 && p.wage_demand - p.wage_arrears != wages) wage_drift = true;
        // 采购 is low priority: never past its ceiling, and its reported spend is
        // the row amount (no second ledger, no rounding gap).
        if (bought > split.procurement_ceiling) ceiling_blown = true;
        if (p.procurement_budget_used != bought) proc_drift = true;
        // 维护 settles every kUpkeepPeriod days. The bill is computed even when
        // the wage channel already drained the cash, in which case it settles
        // for 0 - so "the row exists" and "the row never overpays" are the two
        // invariants that actually hold. `upkeep_demand` records the full bill,
        // not the afford amount, which is why the comparison is against the bill
        // being at least what was paid.
        if (p.upkeep_demand > 0) {
            ++upkeep_bills;
            if (upkeep > cash) upkeep_overpaid = true;
            if (p.upkeep_demand < upkeep) upkeep_drift = true;
        } else if (upkeep != 0) {
            // A row with no bill behind it is money leaving for nothing.
            upkeep_drift = true;
        }
        wage_rows_total += rows_of(sim.last, MILITARY_INTENT_PAY_WAGES);
        proc_rows_total += rows_of(sim.last, MILITARY_INTENT_PROCURE_GOOD);
        upkeep_rows_total += rows_of(sim.last, MILITARY_INTENT_SPEND_CASH);
        ++days_checked;
    }
    ST_CHECK(days_checked > 0, "cross channel: the envelope stayed on for the window");
    ST_CHECK(!over_cash,
             "cross channel: the three channels never promise more cash than exists");
    ST_CHECK(!wage_drift,
             "cross channel: reported payroll equals the PAY_WAGES rows");
    ST_CHECK(!proc_drift,
             "cross channel: reported procurement equals the PROCURE_GOOD rows");
    ST_CHECK(!ceiling_blown,
             "cross channel: procurement stays inside its own share");
    ST_CHECK(!upkeep_drift,
             "cross channel: upkeep never pays without a bill behind it");
    ST_CHECK(!upkeep_overpaid,
             "cross channel: upkeep never pays more than the treasury holds");
    // Each channel really did settle something: a window where all three stayed
    // silent would make every assertion above vacuously true.
    ST_CHECK(wage_rows_total > 0 && proc_rows_total > 0,
             "cross channel: payroll and procurement both settled in the window");
    // 维护 (op 9) bills every `kUpkeepPeriod` (5) days, so a 50-day window must
    // contain ten bills. This is what proves the assertions above ran at all:
    // with a 0-upkeep catalog the channel is silent and every check is vacuous.
    ST_CHECK(upkeep_bills >= 9,
             "cross channel: upkeep billed on the 5-day cadence for the window");
    ST_CHECK(days_checked >= 45,
             "cross channel: the envelope covered nearly the whole window");
    return true;
}


bool test_naval_transport(const MilitaryTerrainInput &, std::string &report) {
    constexpr int32_t kBandRow = 10;                 // water rows 10..(10+band-1)
    constexpr int32_t kNorthShore = kBandRow - 1;    // land row just above the band
    const int32_t shore_north = cell_at(5, kNorthShore);
    const int32_t shore_3 = cell_at(5, kBandRow + 3);   // land past a 3-water strait
    const int32_t shore_4 = cell_at(5, kBandRow + 4);   // land past a 4-water strait
    std::string error;

    // ---- 1. no transport technology: water is refused exactly as before
    {
        const MilitaryTerrainInput t3 = make_hex_terrain_with_water_band(kBandRow, 3);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4242, error) && core.set_terrain(t3, error),
                 "naval: configure + 3-water strait terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: country slot");
        const int32_t army = core.create_army(0, shore_north);
        ST_CHECK(army >= 0, "naval: army created on the north shore");
        const MilitaryWorldDigest locked = make_naval_digest(t3, 0ull);
        std::vector<int32_t> path;
        ST_CHECK(!core.find_path(army, shore_3, locked, path),
                 "naval: no transport technology -> find_path refuses the strait");
        ST_CHECK(core.find_path(army, cell_at(9, kNorthShore), locked, path),
                 "naval: no transport technology -> land routes are unaffected");
        std::vector<int32_t> cells;
        int32_t days = 0;
        core._last_digest = locked;
        ST_CHECK(!core.preview_path(core.army_handle(army), shore_3, cells, days),
                 "naval: no transport technology -> preview_path reports unreachable");
    }

    // ---- 2. coastal transport: runs of <= 3 consecutive water cells
    {
        const MilitaryTerrainInput t3 = make_hex_terrain_with_water_band(kBandRow, 3);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4243, error) && core.set_terrain(t3, error),
                 "naval: coastal configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: coastal country slot");
        const int32_t army = core.create_army(0, shore_north);
        const MilitaryWorldDigest coastal = make_naval_digest(t3, kCoastalUnlock);
        std::vector<int32_t> path;
        ST_CHECK(core.find_path(army, shore_3, coastal, path),
                 "naval: coastal transport allows a 3-water strait");
        ST_CHECK((int32_t)path.size() == 4, "naval: the 3-water crossing is 3 sea steps + 1 landing");
        // Same topology, one row wider: the fourth consecutive water cell is
        // past the coastal limit.
        const MilitaryTerrainInput t4 = make_hex_terrain_with_water_band(kBandRow, 4);
        ST_CHECK(core.set_terrain(t4, error), "naval: 4-water strait terrain");
        const MilitaryWorldDigest coastal4 = make_naval_digest(t4, kCoastalUnlock);
        path.clear();
        ST_CHECK(!core.find_path(army, shore_4, coastal4, path),
                 "naval: coastal transport refuses 4 consecutive water cells");
    }

    // ---- 3. ocean transport: the run limit is gone
    {
        const MilitaryTerrainInput t4 = make_hex_terrain_with_water_band(kBandRow, 4);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4245, error) && core.set_terrain(t4, error),
                 "naval: ocean configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: ocean country slot");
        const int32_t army = core.create_army(0, shore_north);
        const MilitaryWorldDigest ocean = make_naval_digest(t4, kOceanUnlock);
        std::vector<int32_t> path;
        ST_CHECK(core.find_path(army, shore_4, ocean, path),
                 "naval: ocean transport allows the 4-water strait");
        ST_CHECK((int32_t)path.size() == 5, "naval: the 4-water crossing is 4 sea steps + 1 landing");
        // The ocean bit must also keep working for a narrow (coastal-sized) run.
        ST_CHECK(core.find_path(army, cell_at(3, kBandRow + 4), ocean, path),
                 "naval: ocean transport keeps ordinary crossings working");
    }

    // ---- 4. preview_path days include the sea cost (contract §2.2)
    {
        const MilitaryTerrainInput t3 = make_hex_terrain_with_water_band(kBandRow, 3);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4246, error) && core.set_terrain(t3, error),
                 "naval: preview configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: preview country slot");
        const int32_t army = core.create_army(0, shore_north);
        core._last_digest = make_naval_digest(t3, kCoastalUnlock);
        std::vector<int32_t> sea_cells;
        int32_t sea_days = 0;
        ST_CHECK(core.preview_path(core.army_handle(army), shore_3, sea_cells, sea_days),
                 "naval: preview_path reaches the far shore with coastal transport");
        ST_CHECK((int32_t)sea_cells.size() == 4 && sea_days == 6,
                 std::string("naval: 3 sea cells + 1 landing preview as 3*1.5+1 = 6 days | got cells=") +
                     std::to_string((int)sea_cells.size()) + " days=" + std::to_string(sea_days));
        std::vector<int32_t> land_cells;
        int32_t land_days = 0;
        ST_CHECK(core.preview_path(core.army_handle(army), cell_at(8, kNorthShore), land_cells, land_days),
                 "naval: preview_path plans a same-shore land route");
        ST_CHECK(land_days == (int32_t)land_cells.size() && land_days > 0,
                 "naval: land steps still preview as one day each");
        ST_CHECK(sea_days > land_days, "naval: a sea move costs more days than the land equivalent");
    }

    // ---- 5. crossing: forced EMBARKED, stance restored on landing, sea
    //         attrition at kSeaAttritionBp (0.2%/day) instead of land loss
    {
        const MilitaryTerrainInput t3 = make_hex_terrain_with_water_band(kBandRow, 3);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4247, error) && core.set_terrain(t3, error),
                 "naval: movement configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: movement country slot");
        MilitaryWorldDigest d = make_naval_digest(t3, kCoastalUnlock);
        core._last_digest = d;
        const int32_t army = core.create_army(0, shore_north);
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_ARMY, army, 0, 0, 256);
        core._lots.count[(size_t)lot] = 5000;
        core.refresh_army_cache(army);
        core._armies.stance[(size_t)army] = (uint8_t)MILITARY_STANCE_ADVANCE;
        std::vector<int32_t> path;
        ST_CHECK(core.find_path(army, shore_3, d, path), "naval: movement plans the crossing");
        core.assign_path(army, path);
        const int64_t heads_before = core._armies.cached_headcount[(size_t)army];
        int32_t sea_days = 0;
        int64_t expected_losses = 0;
        for (int32_t day = 0;
             day < 40 && core._armies.path_cursor[(size_t)army] < core._armies.path_len[(size_t)army];
             ++day) {
            const int64_t heads_day_before = core._armies.cached_headcount[(size_t)army];
            core._last_day = day;
            core.run_movement(d);
            const int32_t cell = core._armies.cell[(size_t)army];
            if (cell < 0 || (size_t)cell >= t3.is_water.size() || !t3.is_water[(size_t)cell]) continue;
            ++sea_days;
            ST_CHECK(core._armies.stance[(size_t)army] == (uint8_t)MILITARY_STANCE_EMBARKED,
                     "naval: an army standing on water is EMBARKED");
            // 20bp of the formation per day at sea = 2000 bp100 units of 1e-6.
            expected_losses += mul_div(heads_day_before * (int64_t)20 * 100, 1, 1000000);
        }
        ST_CHECK(sea_days >= 2, "naval: the crossing spent at least two days at sea");
        ST_CHECK(core._armies.cell[(size_t)army] == shore_3, "naval: the army landed on the far shore");
        ST_CHECK(core._armies.stance[(size_t)army] == (uint8_t)MILITARY_STANCE_ADVANCE,
                 "naval: landing restores the pre-embarkation stance");
        // 0.2%/day while the formation is on water, and the PLAIN land cell it
        // started from has no environment attrition, so the whole difference is
        // the sea loss.
        const int64_t heads_after = core._armies.cached_headcount[(size_t)army];
        ST_CHECK(expected_losses > 0 && heads_before - heads_after == expected_losses,
                 "naval: sea attrition is 0.2% of the formation per day at sea");
    }
    return true;
}
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
    if (!test_idle(t, report)) return false;
    uint64_t h1 = 0, h2 = 0, w1 = 0, w2 = 0, a1 = 0, a2 = 0;
    std::string stats, stats2;
    if (!test_recruit_and_move(t, report, h1)) return false;
    if (!test_war_peace_save(t, report, w1)) return false;
    if (!test_partial_discharge(t, report)) return false;
    if (!test_procurement(t, report)) return false;
    if (!test_army_pay(t, report)) return false;
    if (!test_budget_envelope(t, report)) return false;
    if (!test_procurement_quota(t, report)) return false;
    if (!test_cross_channel_conservation(t, report)) return false;
    if (!test_naval_transport(t, report)) return false;
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

// ================================================================= bench

bool MilitaryCore::bench(int32_t cells, int32_t armies, int32_t engagements, int32_t days, double &avg_ms,
                         double &p95_ms, double &max_ms, std::string &report) {
    avg_ms = p95_ms = max_ms = 0.0;
    report.clear();
    if (cells < 64 || armies < 1 || days < 1) {
        report = "bench_bad_config";
        return false;
    }
    armies = std::min(armies, MILITARY_MAX_ARMIES);
    int32_t w = std::max<int32_t>(16, (int32_t)std::lround(std::sqrt((double)cells * 1.5)));
    w &= ~1;
    int32_t h = std::max<int32_t>(4, cells / w);
    const MilitaryTerrainInput t = make_hex_terrain(w, h);
    const int32_t n = t.cell_count;
    constexpr int32_t kCountries = 8;
    MilitaryCore core;
    std::string error;
    if (!core.configure(make_catalog(), 99, error) || !core.set_terrain(t, error)) {
        report = error;
        return false;
    }
    MilitaryWorldDigest d;
    d.country_capacity = kCountries;
    d.cell_owner_slot.assign((size_t)n, -1);
    for (int32_t c = 0; c < n; ++c) d.cell_owner_slot[(size_t)c] = ((c % w) * kCountries) / w;
    for (int32_t s = 0; s < kCountries; ++s) {
        d.country_handle.push_back(handle_for(s));
        d.country_cash.push_back(1000000000000ll);
        d.country_era.push_back(2);
        d.country_annual_revenue.push_back(0);
        d.country_capital_cell.push_back(-1);
        d.country_soldier_living_cost.push_back(10000);
        core.ensure_country_slot(handle_for(s));
    }
    d.cell_population.assign((size_t)n, 1000);
    d.cell_unemployed.assign((size_t)n, 100);
    d.cell_soldiers.assign((size_t)n, 0);
    d.cell_has_merchant.assign((size_t)n, 0);
    for (int32_t c = 0; c < n; c += 64) {
        d.cell_has_merchant[(size_t)c] = 1;
        d.market_cell.push_back(c);
        d.market_good.push_back(0);
        d.market_sellable.push_back(100000000);
        d.market_price.push_back(10000);
    }
    d.unlock_words = 1;
    d.country_unlock_bits.assign(kCountries, 1ull);
    d.day = 0;
    core._last_day = 0;
    core._last_digest = d;
    // Wars between stripe pairs (0,1) (2,3) ...
    for (int32_t p = 0; p < kCountries / 2; ++p) {
        MilitaryWar war;
        war.id = p + 1;
        war.attacker_slot = 2 * p;
        war.defender_slot = 2 * p + 1;
        war.attacker_handle = handle_for(2 * p);
        war.defender_handle = handle_for(2 * p + 1);
        war.start_day = 0;
        war.active = 1;
        core._wars.push_back(war);
    }
    const int32_t stripe = w / kCountries;
    std::vector<uint8_t> used((size_t)n, 0);
    uint64_t r = 0x1234567ull;
    auto next_rand = [&r]() { r = splitmix_final(r + 0x9e3779b97f4a7c15ull); return r; };
    auto pick_cell = [&](int32_t country, int32_t margin) -> int32_t {
        for (int32_t tries = 0; tries < 1000; ++tries) {
            const int32_t col = country * stripe + margin + (int32_t)(next_rand() % (uint64_t)std::max(1, stripe - 2 * margin));
            const int32_t row = 1 + (int32_t)(next_rand() % (uint64_t)std::max(1, h - 2));
            const int32_t c = row * w + col;
            if (c >= 0 && c < n && !used[(size_t)c] && d.cell_owner_slot[(size_t)c] == country) return c;
        }
        return -1;
    };
    auto spawn = [&](int32_t owner, int32_t cell, int64_t heads) -> int32_t {
        const int32_t a = core.create_army(owner, cell);
        if (a < 0) return -1;
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_ARMY, a, owner, 0, 256);
        core._lots.count[(size_t)lot] = heads;
        core.refresh_army_cache(a);
        used[(size_t)cell] = 1;
        return a;
    };
    int32_t attackers = std::min<int32_t>(armies / 2, (engagements + 5) / 6);
    if (engagements <= 0) attackers = 0;
    int32_t made_eng = 0, spawned = 0;
    std::vector<int32_t> att_cells;
    for (int32_t i = 0; i < attackers; ++i) {
        const int32_t pair = i % (kCountries / 2);
        const int32_t att = 2 * pair, def = att + 1;
        const int32_t cell = pick_cell(def, 2);
        if (cell < 0) break;
        // Keep the invader's ring free so its six edges stay distinct.
        bool clash = false;
        for (int32_t k = 0; k < 6; ++k) {
            const int32_t nb = t.neighbors[(size_t)cell * 6 + (size_t)k];
            if (nb < 0 || used[(size_t)nb] || d.cell_owner_slot[(size_t)nb] != def) clash = true;
        }
        if (clash) { --i; if (++spawned > 100000) break; continue; }
        const int32_t a = spawn(att, cell, 1000);
        if (a < 0) break;
        core.set_controller(cell, att);
        for (int32_t k = 0; k < 6; ++k) used[(size_t)t.neighbors[(size_t)cell * 6 + (size_t)k]] = 1;
        att_cells.push_back(cell);
        for (int32_t k = 0; k < 6 && made_eng < engagements; ++k) {
            core.open_engagement(cell, t.neighbors[(size_t)cell * 6 + (size_t)k], a, def);
            ++made_eng;
        }
    }
    attackers = (int32_t)att_cells.size();
    // Defenders on engaged far cells, then movers in their own territory.
    int32_t remaining = armies - attackers;
    int32_t defenders = 0;
    for (size_t i = 0; i < att_cells.size() && defenders < remaining / 2; ++i) {
        const int32_t far = t.neighbors[att_cells[i] * 6 + (size_t)(i % 6)];
        const int32_t a = core.create_army(d.cell_owner_slot[(size_t)far], far);
        if (a < 0) break;
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_ARMY, a, d.cell_owner_slot[(size_t)far], 1, 256);
        core._lots.count[(size_t)lot] = 800;
        core.refresh_army_cache(a);
        ++defenders;
    }
    int32_t movers = 0;
    std::vector<int32_t> mover_slot, mover_target;
    for (int32_t i = defenders + attackers; i < armies; ++i) {
        const int32_t owner = i % kCountries;
        const int32_t cell = pick_cell(owner, 1);
        if (cell < 0) break;
        const int32_t a = spawn(owner, cell, 500);
        if (a < 0) break;
        const int32_t row = cell / w;
        const int32_t trow = row + (row < h / 2 ? h / 3 : -h / 3);
        mover_slot.push_back(a);
        mover_target.push_back(std::max(0, std::min(h - 1, trow)) * w + (cell % w));
        ++movers;
    }
    // Paths: per-country daily budget (32) is spent in setup "days".
    int32_t pathed = 0;
    for (int32_t round = 0; round < 64 && pathed < movers; ++round) {
        for (int32_t &v : core._path_daily_requests) v = 0;
        for (int32_t i = 0; i < movers; ++i) {
            const size_t s = (size_t)mover_slot[(size_t)i];
            if (core._armies.path_len[s] > 0) continue;
            std::vector<int32_t> path;
            if (core.find_path(mover_slot[(size_t)i], mover_target[(size_t)i], d, path) && !path.empty()) {
                core.assign_path(mover_slot[(size_t)i], path);
                ++pathed;
            }
        }
    }
    std::vector<double> samples;
    std::vector<MilitaryIntent> intents;
    std::vector<MilitaryIntentReceipt> receipts;
    int64_t astar = 0, convoy_hops = 0, front = 0, intents_total = 0, threat = 0;
    int32_t max_eng = 0, max_moving = 0, captured = 0, battles = 0;
    double stage_sum[MILITARY_STAGE_COUNT] = {}, stage_max[MILITARY_STAGE_COUNT] = {};
    const auto wall0 = std::chrono::steady_clock::now();
    for (int32_t day = 1; day <= days; ++day) {
        d.day = day;
        intents.clear();
        if (!core.step_day(day, d, receipts, intents, error)) {
            report = "bench_step_failed:" + error;
            return false;
        }
        const MilitaryReport &rep = core.report();
        samples.push_back(rep.day_ms);
        astar += rep.astar_expansions;
        convoy_hops += rep.convoy_hops;
        front += rep.front_edges_touched;
        threat += rep.threat_field_cells;
        intents_total += (int64_t)intents.size();
        max_eng = std::max(max_eng, rep.engagements_active);
        max_moving = std::max(max_moving, rep.armies_moving);
        captured += rep.cells_captured;
        const double *sm = military_stage_ms();
        for (int32_t k = 0; k < MILITARY_STAGE_COUNT; ++k) {
            stage_sum[k] += sm[k];
            stage_max[k] = std::max(stage_max[k], sm[k]);
        }
    }
    const double wall = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - wall0).count();
    const uint64_t timed_hash = core.state_hash();
    // Stage profile from the timed days themselves (step_day laps).
    std::string profile = " | stages avg/max(ms):";
    {
        int32_t idx[MILITARY_STAGE_COUNT];
        for (int32_t i = 0; i < MILITARY_STAGE_COUNT; ++i) idx[i] = i;
        std::sort(idx, idx + MILITARY_STAGE_COUNT, [&](int32_t a, int32_t b) { return stage_sum[a] > stage_sum[b]; });
        char sb[96];
        for (int32_t i = 0; i < 10; ++i) {
            std::snprintf(sb, sizeof(sb), " %s=%.3f/%.3f", military_stage_name(idx[i]), stage_sum[idx[i]] / days,
                          stage_max[idx[i]]);
            profile += sb;
        }
    }    battles = (int32_t)core.battle_log().size();
    std::vector<double> sorted = samples;
    std::sort(sorted.begin(), sorted.end());
    double sum = 0.0;
    for (double v : samples) sum += v;
    avg_ms = sum / (double)samples.size();
    max_ms = sorted.back();
    size_t p95 = (size_t)std::ceil(0.95 * (double)sorted.size());
    p95 = p95 == 0 ? 0 : p95 - 1;
    p95_ms = sorted[std::min(p95, sorted.size() - 1)];
    char buf[640];
    std::snprintf(buf, sizeof(buf),
                  "cells=%d (%dx%d) armies=%d (att=%d def=%d movers=%d pathed=%d) engagements=%d days=%d | "
                  "avg=%.3fms p95=%.3fms max=%.3fms wall=%.1fms | max_engaged=%d max_moving=%d astar=%lld "
                  "threat_cells/day=%lld convoy_hops=%lld front_touched=%lld captured=%d intents=%lld "
                  "battle_log=%d reconcile=%lld",
                  n, w, h, attackers + defenders + movers, attackers, defenders, movers, pathed, made_eng, days, avg_ms,
                  p95_ms, max_ms, wall, max_eng, max_moving, (long long)astar, (long long)(threat / days),
                  (long long)convoy_hops, (long long)front, captured, (long long)intents_total, battles,
                  (long long)core.report().reconcile_delta);
    report = buf + profile;
    {
        char hb[96];
        std::snprintf(hb, sizeof(hb), " | hash_timed=%016llx hash_end=%016llx", (unsigned long long)timed_hash,
                      (unsigned long long)core.state_hash());
        report += hb;
    }
    return true;
}

} // namespace pk

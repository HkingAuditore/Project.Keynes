// military_core_ai.cpp - country military AI agenda (design sec 20, owner: A3).
//
// The AI is a player-equivalent command producer: every decision becomes a
// MilitaryCommand pushed through MilitaryCore::submit() with effective day
// D+1, tagged with MILITARY_PRODUCER_ID in the high 32 bits of `sequence`
// (MilitaryCommand has no producer field; the tag also orders AI commands after
// same-day player commands, deterministically). The AI never mutates Military
// state directly except its own schedule (_ai_next_decision_day).
//
// Schedule: each AI slot has a MAIN decision on days where (day + slot) % 30 == 0
// (staggered by slot). A main decision runs the whole agenda:
//   1. BUDGET force target = 8% (peace) / 20% (alert: an adjacent country is
//      >= 2x stronger) / 40% (war) of annual revenue, per day.
//   2. Unit configuration: best 3 unlocked non-artillery units by
//      (attack + defense) / equipment value, weighted 50/30/20, plus 10%
//      artillery when one is unlocked.
//   3. state.build barracks in the most populous owned+controlled cells while
//      posts (+ posts under construction / pending) < min(target, population cap).
//   4. War: create armies from garrisons, give idle armies area_control
//      missions centred on frontier cells facing the enemy (radius 4 = 61 cells).
//   5. Peace: annex (sole occupier of everything) / cede (occupied enemy cells)
//      / white peace when losing or the war is long, priced with evaluate_peace
//      and only proposed when price <= willing (the core applies the same rule
//      to incoming offers, so "accept when willing >= price" is automatic).
//   6. Declare war (3-year cooldown since our last declaration) on the weakest
//      adjacent country not in truce when our strength >= 1.5x theirs.
//   7. Peace-time cleanup: idle armies on own cells are stationed back.
// A FOLLOW-UP decision (next day) is scheduled only after army.create so the
// new formations receive their area_control mission without waiting 30 days.
//
// All arithmetic is integer; iteration orders are slot / cell / war-id order.

#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace pk {

namespace {

using namespace mil;

constexpr int64_t kAiPeriodDays = 30;
constexpr int64_t kWarCooldownDays = 3 * 365;
constexpr int32_t kBudgetPeaceBp = 800;
constexpr int32_t kBudgetAlertBp = 2000;
constexpr int32_t kBudgetWarBp = 4000;
constexpr int32_t kPopCapPeaceBp = 300;      // soldiers <= 3% of population (sec 24)
constexpr int32_t kPopCapWarBp = 1000;       // <= 10% at war
constexpr int32_t kMaxBuildsPerDecision = 2;
constexpr int32_t kMaxArmiesCreatedPerDecision = 4;
constexpr int32_t kMaxArmiesPerWar = 8;
constexpr int64_t kMinGarrisonForArmy = 20;
constexpr int32_t kAreaRadius = 4;           // 61 cells <= MILITARY_MAX_AREA_CELLS
constexpr size_t kMaxFrontier = 512;
constexpr int64_t kPeaceCedeMinDays = 180;
constexpr int64_t kPeaceWhiteLongDays = 2 * 365;
constexpr int64_t kPeaceWhiteLosingDays = 90;
constexpr int32_t kMaxCedeTerms = 16;
constexpr int32_t kArtilleryShareBp = 1000;

struct AiScratch {
    int32_t cap = 0;
    std::vector<int32_t> eff;          // effective controller per cell
    std::vector<int32_t> ctrl_off;     // CSR by effective controller (cap + 1)
    std::vector<int32_t> ctrl_cells;
    std::vector<int32_t> fill;
    std::vector<int64_t> owned_pop;
    std::vector<int64_t> owned_cells;
    std::vector<int64_t> strength;
    std::vector<uint8_t> adjacent;     // owner-based, cap * cap
    std::vector<int64_t> category_price;
    std::vector<int32_t> frontier;
    std::vector<std::pair<int64_t, int32_t>> ranked;
    std::vector<int32_t> armies;
};

AiScratch &ai_scratch() {
    static thread_local AiScratch s;
    return s;
}

int64_t next_main_day(int64_t after_day, int32_t slot) {
    int64_t d = after_day + 1;
    if (d < 0) d = 0;
    const int64_t r = (d + slot) % kAiPeriodDays;
    if (r != 0) d += kAiPeriodDays - r;
    return d;
}

bool ai_submit(MilitaryCore &core, uint64_t handle, MilitaryCommand cmd) {
    cmd.country = handle;
    cmd.effective_day = core._last_day + 1;
    const uint32_t local = (uint32_t)(core._next_sequence++ & 0xFFFFFFFFull);
    cmd.sequence = ((uint64_t)MILITARY_PRODUCER_ID << 32) | (uint64_t)local;
    std::string error;
    return core.submit(std::move(cmd), error);
}

int32_t owner_at(const MilitaryWorldDigest &d, int32_t cell) {
    return (cell >= 0 && (size_t)cell < d.cell_owner_slot.size()) ? d.cell_owner_slot[(size_t)cell] : -1;
}

// One O(cells + lots) pass shared by every AI slot due today.
void build_scratch(const MilitaryCore &core, const MilitaryWorldDigest &digest, AiScratch &s) {
    const int32_t cells = core._terrain.cell_count;
    int32_t cap = std::max<int32_t>(digest.country_capacity, (int32_t)core._policies.size());
    if (cap < 0) cap = 0;
    s.cap = cap;
    s.eff.assign((size_t)std::max(0, cells), -1);
    s.ctrl_off.assign((size_t)cap + 1, 0);
    s.owned_pop.assign((size_t)cap, 0);
    s.owned_cells.assign((size_t)cap, 0);
    s.strength.assign((size_t)cap, 0);
    s.adjacent.assign((size_t)cap * (size_t)cap, 0);
    for (int32_t c = 0; c < cells; ++c) {
        const int32_t owner = owner_at(digest, c);
        const int32_t ctrl = core.controller_of(c);
        const int32_t e = ctrl >= 0 ? ctrl : owner;
        s.eff[(size_t)c] = e;
        if (e >= 0 && e < cap) ++s.ctrl_off[(size_t)e + 1];
        if (owner >= 0 && owner < cap) {
            ++s.owned_cells[(size_t)owner];
            if ((size_t)c < digest.cell_population.size()) s.owned_pop[(size_t)owner] += digest.cell_population[(size_t)c];
            const int32_t base = c * 6;
            for (int32_t dir = 0; dir < 6; ++dir) {
                const int32_t nb = core._terrain.neighbors[(size_t)(base + dir)];
                if (nb < 0) continue;
                const int32_t other = owner_at(digest, nb);
                if (other < 0 || other == owner || other >= cap) continue;
                s.adjacent[(size_t)owner * (size_t)cap + (size_t)other] = 1;
            }
        }
    }
    for (int32_t i = 0; i < cap; ++i) s.ctrl_off[(size_t)i + 1] += s.ctrl_off[(size_t)i];
    s.ctrl_cells.assign((size_t)s.ctrl_off[(size_t)cap], -1);
    s.fill.assign(s.ctrl_off.begin(), s.ctrl_off.end() - 1);
    for (int32_t c = 0; c < cells; ++c) {
        const int32_t e = s.eff[(size_t)c];
        if (e < 0 || e >= cap) continue;
        s.ctrl_cells[(size_t)s.fill[(size_t)e]++] = c;   // ascending cell order
    }
    // Strength = sum heads * (attack + defense) / 2 (militia scaled by era).
    const MilitaryLotStore &lots = core._lots;
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        const int32_t slot = lots.country_slot[i];
        const int32_t unit = lots.unit_type[i];
        if (slot < 0 || slot >= cap) continue;
        if (unit < 0 || (size_t)unit >= core._catalog.units.size()) continue;
        const MilitaryUnitType &u = core._catalog.units[(size_t)unit];
        int64_t ad = (int64_t)u.attack_q16 + (int64_t)u.defense_q16;
        if (unit == core._catalog.militia_unit) ad = mul_div(ad, era_factor_militia_q16(core.militia_era(slot)), MILITARY_Q16);
        s.strength[(size_t)slot] += mul_div(lots.count[i], ad, 2 * (int64_t)MILITARY_Q16);
    }
    // Cheapest market price per equipment category (MONEY_SCALE per 1.0 good).
    const size_t ncat = core._catalog.categories.size();
    s.category_price.assign(ncat, -1);
    for (size_t row = 0; row < digest.market_cell.size(); ++row) {
        const int32_t good = row < digest.market_good.size() ? digest.market_good[row] : -1;
        const int64_t price = row < digest.market_price.size() ? digest.market_price[row] : 0;
        if (good < 0 || price <= 0) continue;
        for (size_t k = 0; k < ncat; ++k) {
            const std::vector<int32_t> &ids = core._catalog.categories[k].good_ids;
            if (std::find(ids.begin(), ids.end(), good) == ids.end()) continue;
            if (s.category_price[k] < 0 || price < s.category_price[k]) s.category_price[k] = price;
        }
    }
    for (int64_t &p : s.category_price) {
        if (p <= 0) p = MILITARY_MONEY_SCALE;
    }
}

// Equipment value of 100 heads in MONEY_SCALE (floor 1 money so equipment-free
// units still rank by raw power).
int64_t equipment_value(const MilitaryCore &core, const AiScratch &s, const MilitaryUnitType &u) {
    int64_t value = MILITARY_MONEY_SCALE;
    for (int32_t k = 0; k < u.slot_count && k < MILITARY_MAX_EQUIP_SLOTS; ++k) {
        const int32_t cat = u.slot_category[(size_t)k];
        if (cat < 0 || (size_t)cat >= s.category_price.size()) continue;
        const int64_t qty = u.slot_qty_per_100[(size_t)k];
        if (qty <= 0) continue;
        int64_t v = mul_div(qty, s.category_price[(size_t)cat], MILITARY_GOODS_SCALE);
        v = mul_div(v, quality_mult_q16(u.slot_min_quality[(size_t)k]), MILITARY_Q16);
        value += v;
    }
    (void)core;
    return value;
}

void decide_budget(MilitaryCore &core, const MilitaryWorldDigest &digest, const AiScratch &s,
                   int32_t slot, uint64_t handle, bool at_war_any) {
    const int64_t own = s.strength[(size_t)slot];
    bool alert = false;
    for (int32_t b = 0; b < s.cap && !alert; ++b) {
        if (!s.adjacent[(size_t)slot * (size_t)s.cap + (size_t)b]) continue;
        if (s.strength[(size_t)b] > 0 && s.strength[(size_t)b] >= 2 * std::max<int64_t>(own, 1)) alert = true;
    }
    const int32_t bp = at_war_any ? kBudgetWarBp : (alert ? kBudgetAlertBp : kBudgetPeaceBp);
    const int64_t revenue = (size_t)slot < digest.country_annual_revenue.size()
                                ? digest.country_annual_revenue[(size_t)slot]
                                : 0;
    if (revenue <= 0) return;
    const int64_t daily = mul_div(revenue, bp, 10000 * 365);
    if (daily <= 0) return;
    const MilitaryCountryPolicy &p = core._policies[(size_t)slot];
    if (!p.auto_discharge) {   // AI sheds surplus soldiers when the budget falls after a war
        MilitaryCommand ad;
        ad.op = MCMD_FORCE_SET_AUTO_DISCHARGE;
        ad.count = 1;
        ai_submit(core, handle, std::move(ad));
    }
    const int64_t diff = p.target_value > daily ? p.target_value - daily : daily - p.target_value;
    if (p.target_mode == 1 && diff * 50 <= daily) return;   // within 2%
    MilitaryCommand cmd;
    cmd.op = MCMD_FORCE_SET_TARGET;
    cmd.count = 1;
    cmd.value = daily;
    ai_submit(core, handle, std::move(cmd));
}

void decide_config(MilitaryCore &core, const MilitaryWorldDigest &digest, AiScratch &s, int32_t slot,
                   uint64_t handle) {
    const MilitaryCatalog &c = core._catalog;
    const int32_t units = (int32_t)c.units.size();
    s.ranked.clear();
    int32_t best_art = -1;
    int64_t best_art_score = -1;
    for (int32_t u = 0; u < units; ++u) {
        if (u == c.militia_unit) continue;
        const MilitaryUnitType &t = c.units[(size_t)u];
        if (!unlocked(digest, slot, t.unlock_bit)) continue;
        const int64_t power = (int64_t)t.attack_q16 + (int64_t)t.defense_q16;
        const int64_t score = mul_div(power, (int64_t)1 << 24, std::max<int64_t>(1, equipment_value(core, s, t)));
        if (t.unit_class == (uint8_t)MILITARY_CLASS_ARTILLERY) {
            if (score > best_art_score) {
                best_art_score = score;
                best_art = u;
            }
            continue;
        }
        s.ranked.push_back({score, u});
    }
    std::sort(s.ranked.begin(), s.ranked.end(), [](const std::pair<int64_t, int32_t> &a,
                                                   const std::pair<int64_t, int32_t> &b) {
        if (a.first != b.first) return a.first > b.first;
        return a.second < b.second;
    });
    if (s.ranked.size() > 3) s.ranked.resize(3);
    if (s.ranked.empty() && best_art < 0) return;
    std::vector<int32_t> want((size_t)units, 0);
    const int32_t art = best_art >= 0 ? kArtilleryShareBp : 0;
    const int32_t rest = s.ranked.empty() ? 0 : 10000 - art;
    static const int32_t kW[3][3] = {{100, 0, 0}, {60, 40, 0}, {50, 30, 20}};
    if (!s.ranked.empty()) {
        const size_t k = s.ranked.size() - 1;
        int32_t assigned = 0;
        for (size_t i = 0; i < s.ranked.size(); ++i) {
            const int32_t bp = rest * kW[k][i] / 100;
            want[(size_t)s.ranked[i].second] = bp;
            assigned += bp;
        }
        want[(size_t)s.ranked[0].second] += rest - assigned;
    }
    if (best_art >= 0) want[(size_t)best_art] += s.ranked.empty() ? kArtilleryShareBp : art;
    const MilitaryCountryPolicy &p = core._policies[(size_t)slot];
    bool same = true;
    for (int32_t u = 0; u < units; ++u) {
        const int32_t cur = (size_t)u < p.config_share_bp.size() ? p.config_share_bp[(size_t)u] : 0;
        if (cur != want[(size_t)u]) {
            same = false;
            break;
        }
    }
    if (same) return;
    MilitaryCommand cmd;
    cmd.op = MCMD_CONFIG_SET;
    for (int32_t u = 0; u < units; ++u) {
        if (want[(size_t)u] <= 0) continue;
        cmd.ints.push_back(u);
        cmd.ints.push_back(want[(size_t)u]);
    }
    ai_submit(core, handle, std::move(cmd));
}

void decide_barracks(MilitaryCore &core, const MilitaryWorldDigest &digest, const AiScratch &s, int32_t slot,
                     uint64_t handle, bool at_war_any) {
    const MilitaryCatalog &c = core._catalog;
    int32_t building = -1;
    for (size_t b = 0; b < c.state_buildings.size(); ++b) {
        const MilitaryStateBuilding &sb = c.state_buildings[b];
        if (sb.role != (uint8_t)MILITARY_STATE_BARRACKS || sb.capacity <= 0) continue;
        if (!unlocked(digest, slot, sb.unlock_bit)) continue;
        if (building < 0 || sb.capacity > c.state_buildings[(size_t)building].capacity) building = (int32_t)b;
    }
    if (building < 0) return;
    const int64_t capacity = c.state_buildings[(size_t)building].capacity;
    const int64_t day = core._last_day;
    int64_t posts = 0;
    for (const MilitaryCellState &st : core._cell_states) {
        if (owner_at(digest, st.cell) != slot) continue;
        posts += core.posts_for_cell(st.cell, slot);
        for (int32_t k = 0; k < 3; ++k) {
            const int32_t bi = st.construction_building[k];
            if (bi < 0 || (size_t)bi >= c.state_buildings.size()) continue;
            if (st.construction_done_day[k] < day) continue;
            const MilitaryStateBuilding &sb = c.state_buildings[(size_t)bi];
            if (sb.role == (uint8_t)MILITARY_STATE_BARRACKS) posts += sb.capacity;
        }
    }
    for (const MilitaryCommand &pc : core._pending) {
        if (pc.op != MCMD_STATE_BUILD || pc.country != handle) continue;
        if (pc.unit_to >= 0 && (size_t)pc.unit_to < c.state_buildings.size() &&
            c.state_buildings[(size_t)pc.unit_to].role == (uint8_t)MILITARY_STATE_BARRACKS) {
            posts += c.state_buildings[(size_t)pc.unit_to].capacity;
        }
    }
    const int64_t target = core._policies[(size_t)slot].effective_target;
    const int64_t pop_cap = mul_div(s.owned_pop[(size_t)slot], at_war_any ? kPopCapWarBp : kPopCapPeaceBp, 10000);
    const int64_t want = std::min(target, pop_cap);
    if (posts >= want) return;
    int64_t builds = ceil_div_pos(want - posts, capacity);
    if (builds > kMaxBuildsPerDecision) builds = kMaxBuildsPerDecision;
    // Top-`builds` most populous owned + controlled cells without a running or
    // pending construction (ties -> lower cell id).
    std::pair<int64_t, int32_t> top[kMaxBuildsPerDecision];
    int32_t ntop = 0;
    const int32_t lo = s.ctrl_off[(size_t)slot], hi = s.ctrl_off[(size_t)slot + 1];
    for (int32_t i = lo; i < hi; ++i) {
        const int32_t cell = s.ctrl_cells[(size_t)i];
        if (owner_at(digest, cell) != slot) continue;
        if (core._terrain.is_water[(size_t)cell]) continue;
        const int64_t pop = (size_t)cell < digest.cell_population.size() ? digest.cell_population[(size_t)cell] : 0;
        if (pop <= 0) continue;
        if (ntop == (int32_t)builds && pop <= top[ntop - 1].first) continue;
        bool busy = false;
        if (const MilitaryCellState *st = const_cast<MilitaryCore &>(core).cell_state(cell, false)) {
            for (int32_t k = 0; k < 3; ++k) {
                if (st->construction_building[k] >= 0 && st->construction_done_day[k] >= day) busy = true;
            }
        }
        for (const MilitaryCommand &pc : core._pending) {
            if (pc.op == MCMD_STATE_BUILD && pc.cell == cell) busy = true;
        }
        if (busy) continue;
        int32_t pos = ntop < (int32_t)builds ? ntop++ : ntop - 1;
        top[pos] = {pop, cell};
        while (pos > 0 && top[pos].first > top[pos - 1].first) {
            std::swap(top[pos], top[pos - 1]);
            --pos;
        }
    }
    for (int32_t i = 0; i < ntop; ++i) {
        // Request, do not submit: `state.build` is no longer a settlement, so a
        // direct submit here would found a barracks without the economy ever
        // charging for its materials. The bridge runs each request through
        // `queue_treasury_sponsored_build` and echoes accepted lots back as
        // MCMD_STATE_BUILD, which keeps the same-origin `posts` accounting
        // above honest: an unaffordable request simply never completes.
        MilitaryCore::StateBuildRequest request;
        request.country = handle;
        request.cell = top[i].second;
        request.building = building;
        core._build_requests.push_back(request);
    }
}

bool army_is_idle_for(const MilitaryCore &core, const AiScratch &s, int32_t army, int32_t enemy) {
    const MilitaryArmyStore &a = core._armies;
    const size_t i = (size_t)army;
    if (a.engagement[i] >= 0) return false;
    if (a.stance[i] == (uint8_t)MILITARY_STANCE_RETREAT) return false;
    if (a.path_cursor[i] < a.path_len[i]) return false;
    const int32_t area = a.area_id[i];
    if (area < 0 || (size_t)area >= core._areas.size()) return true;
    const MilitaryArea &ar = core._areas[(size_t)area];
    if (!ar.active || ar.owner_slot != a.owner_slot[i]) return true;
    for (int32_t cell : ar.cells) {
        if (cell >= 0 && (size_t)cell < s.eff.size() && s.eff[(size_t)cell] == enemy) return false;
    }
    return true;   // area no longer touches the enemy: re-task
}

// Returns true when army.create commands were issued (follow-up needed).
bool decide_war_armies(MilitaryCore &core, AiScratch &s, int32_t slot, uint64_t handle, int32_t enemy,
                       bool allow_create) {
    const MilitaryTerrainInput &t = core._terrain;
    // Frontier: cells we control that touch a cell the enemy controls.
    s.frontier.clear();
    const int32_t lo = s.ctrl_off[(size_t)slot], hi = s.ctrl_off[(size_t)slot + 1];
    for (int32_t i = lo; i < hi && s.frontier.size() < kMaxFrontier; ++i) {
        const int32_t cell = s.ctrl_cells[(size_t)i];
        const int32_t base = cell * 6;
        for (int32_t dir = 0; dir < 6; ++dir) {
            const int32_t nb = t.neighbors[(size_t)(base + dir)];
            if (nb >= 0 && s.eff[(size_t)nb] == enemy) {
                s.frontier.push_back(cell);
                break;
            }
        }
    }
    if (s.frontier.empty()) return false;
    s.armies.clear();
    int32_t total = 0;
    for (int32_t a = 0; a < (int32_t)core._armies.active.size(); ++a) {
        if (!core._armies.active[(size_t)a] || core._armies.owner_slot[(size_t)a] != slot) continue;
        ++total;
        if (army_is_idle_for(core, s, a, enemy)) s.armies.push_back(a);
    }
    bool created = false;
    if (allow_create && s.armies.empty() && total < kMaxArmiesPerWar) {
        // Garrison cells by heads (desc, then cell asc); lots are scanned once.
        std::vector<std::pair<int64_t, int32_t>> cells;
        const MilitaryLotStore &lots = core._lots;
        for (size_t i = 0; i < lots.active.size(); ++i) {
            if (!lots.active[i] || lots.count[i] <= 0) continue;
            if (lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON || lots.country_slot[i] != slot) continue;
            const int32_t cell = lots.location[i];
            bool found = false;
            for (auto &row : cells) {
                if (row.second == cell) {
                    row.first += lots.count[i];
                    found = true;
                    break;
                }
            }
            if (!found) cells.push_back({lots.count[i], cell});
        }
        std::sort(cells.begin(), cells.end(), [](const std::pair<int64_t, int32_t> &a,
                                                 const std::pair<int64_t, int32_t> &b) {
            if (a.first != b.first) return a.first > b.first;
            return a.second < b.second;
        });
        int32_t made = 0;
        for (const auto &row : cells) {
            if (made >= kMaxArmiesCreatedPerDecision || total + made >= kMaxArmiesPerWar) break;
            if (row.first < kMinGarrisonForArmy) break;
            if (military_cell_garrison_slot(core, row.second) != slot) continue;
            // Board 75% of each unit type; the rest keeps the barracks manned.
            MilitaryCommand cmd;
            cmd.op = MCMD_ARMY_CREATE;
            cmd.cell = row.second;
            const int32_t units = (int32_t)core._catalog.units.size();
            for (int32_t u = 0; u < units; ++u) {
                int64_t heads = 0;
                for (size_t i = 0; i < lots.active.size(); ++i) {
                    if (!lots.active[i] || lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
                    if (lots.location[i] != row.second || lots.country_slot[i] != slot || lots.unit_type[i] != u) continue;
                    heads += lots.count[i];
                }
                const int64_t take = heads * 3 / 4;
                if (take <= 0) continue;
                cmd.ints.push_back(u);
                cmd.ints.push_back((int32_t)std::min<int64_t>(take, 0x3FFFFFFF));
            }
            if (cmd.ints.empty()) continue;
            if (ai_submit(core, handle, std::move(cmd))) {
                ++made;
                created = true;
            }
        }
    }
    // Area control for idle armies: nearest frontier cell, spread so two
    // armies do not share a centre (penalty for centres within 3 cells).
    std::vector<int32_t> centres;
    for (int32_t army : s.armies) {
        const int32_t at = core._armies.cell[(size_t)army];
        int32_t best = -1;
        int64_t best_score = 0;
        for (int32_t f : s.frontier) {
            int64_t score = core.cell_distance(at, f);
            for (int32_t c : centres) {
                if (core.cell_distance(c, f) <= 3) score += 8;
            }
            if (best < 0 || score < best_score) {
                best = f;
                best_score = score;
            }
        }
        if (best < 0) continue;
        centres.push_back(best);
        MilitaryCommand cmd;
        cmd.op = MCMD_ARMY_AREA_CONTROL;
        cmd.army = core.army_handle(army);
        cmd.cell = best;
        cmd.radius = kAreaRadius;
        ai_submit(core, handle, std::move(cmd));
    }
    return created;
}

void decide_peace(MilitaryCore &core, const MilitaryWorldDigest &digest, const AiScratch &s, int32_t slot,
                  uint64_t handle, const MilitaryWar &war) {
    const int32_t enemy = war.attacker_slot == slot ? war.defender_slot : war.attacker_slot;
    const int64_t day = core._last_day;
    const int64_t age = day - war.start_day;
    const int64_t last_rejected = war.attacker_slot == slot ? war.last_rejected_offer_day_a
                                                            : war.last_rejected_offer_day_b;
    if (day - last_rejected < kAiPeriodDays) return;
    // Enemy-owned cells we control (ascending cell order from the CSR).
    std::vector<int32_t> occupied;
    const int32_t lo = s.ctrl_off[(size_t)slot], hi = s.ctrl_off[(size_t)slot + 1];
    for (int32_t i = lo; i < hi; ++i) {
        const int32_t cell = s.ctrl_cells[(size_t)i];
        if (owner_at(digest, cell) == enemy) occupied.push_back(cell);
    }
    const int64_t enemy_cells = enemy >= 0 && enemy < s.cap ? s.owned_cells[(size_t)enemy] : 0;
    MilitaryCommand cmd;
    cmd.op = MCMD_PEACE_PROPOSE;
    cmd.other = (uint64_t)(uint32_t)war.id;
    auto fits = [&](const std::vector<int32_t> &ints, const std::vector<int64_t> &longs) {
        const MilitaryPeaceEvaluation ev = core.evaluate_peace(war.id, handle, ints, longs);
        return ev.valid && ev.price_q16 <= ev.willing_q16;
    };
    if (enemy_cells > 0 && (int64_t)occupied.size() == enemy_cells) {
        std::vector<int32_t> ints = {MPEACE_ANNEX, 0, 0};
        std::vector<int64_t> longs = {0};
        if (fits(ints, longs)) {
            cmd.ints = std::move(ints);
            cmd.longs = std::move(longs);
            ai_submit(core, handle, std::move(cmd));
            return;
        }
    }
    if (!occupied.empty() && age >= kPeaceCedeMinDays) {
        std::stable_sort(occupied.begin(), occupied.end(), [&core](int32_t a, int32_t b) {
            return core.cell_value_q16(a) > core.cell_value_q16(b);
        });
        std::vector<int32_t> ints;
        std::vector<int64_t> longs;
        int32_t terms = 0;
        for (int32_t cell : occupied) {
            if (terms >= kMaxCedeTerms) break;
            ints.push_back(MPEACE_CEDE_CELL);
            ints.push_back(cell);
            ints.push_back(0);
            longs.push_back(0);
            if (!fits(ints, longs)) {
                ints.resize(ints.size() - 3);
                longs.pop_back();
                break;
            }
            ++terms;
        }
        if (terms > 0) {
            cmd.ints = std::move(ints);
            cmd.longs = std::move(longs);
            ai_submit(core, handle, std::move(cmd));
            return;
        }
    }
    const int64_t score = core.war_score(war.id, slot);
    const bool losing = score <= -25 * (int64_t)MILITARY_Q16 && age >= kPeaceWhiteLosingDays;
    const bool long_war = age >= kPeaceWhiteLongDays && score <= 0;
    const bool stale = age >= 3 * 365;
    if (losing || long_war || stale) {
        std::vector<int32_t> ints = {MPEACE_WHITE, 0, 0};
        std::vector<int64_t> longs = {0};
        if (fits(ints, longs)) {
            cmd.ints = std::move(ints);
            cmd.longs = std::move(longs);
            ai_submit(core, handle, std::move(cmd));
        }
    }
}

bool decide_declare(MilitaryCore &core, const MilitaryWorldDigest &digest, const AiScratch &s, int32_t slot,
                    uint64_t handle) {
    const int64_t day = core._last_day;
    int64_t last_declared = -kWarCooldownDays - 1;
    for (const MilitaryWar &w : core._wars) {
        if (w.attacker_slot == slot && w.start_day > last_declared) last_declared = w.start_day;
    }
    if (day - last_declared < kWarCooldownDays) return false;
    const int64_t own = s.strength[(size_t)slot];
    if (own <= 0 || core.country_soldiers(slot) <= 0) return false;
    int32_t target = -1;
    for (int32_t b = 0; b < s.cap; ++b) {
        if (b == slot || !s.adjacent[(size_t)slot * (size_t)s.cap + (size_t)b]) continue;
        const uint64_t hb = (size_t)b < digest.country_handle.size() ? digest.country_handle[(size_t)b] : 0;
        if (hb == 0 || core.country_slot_for_handle(hb) != b) continue;
        if (core.at_war(slot, b) || core.truce_active(slot, b, day)) continue;
        const int64_t theirs = s.strength[(size_t)b];
        if (own * 2 < theirs * 3) continue;   // ratio >= 1.5
        if (target < 0 || theirs < s.strength[(size_t)target]) target = b;
    }
    if (target < 0) return false;
    MilitaryCommand cmd;
    cmd.op = MCMD_WAR_DECLARE;
    cmd.other = digest.country_handle[(size_t)target];
    return ai_submit(core, handle, std::move(cmd));
}

void decide_peacetime_armies(MilitaryCore &core, const AiScratch &s, int32_t slot, uint64_t handle,
                             const MilitaryWorldDigest &digest) {
    for (int32_t a = 0; a < (int32_t)core._armies.active.size(); ++a) {
        const size_t i = (size_t)a;
        if (!core._armies.active[i] || core._armies.owner_slot[i] != slot) continue;
        if (core._armies.engagement[i] >= 0 || core._armies.path_cursor[i] < core._armies.path_len[i]) continue;
        const int32_t cell = core._armies.cell[i];
        MilitaryCommand cmd;
        cmd.army = core.army_handle(a);
        if (cell >= 0 && owner_at(digest, cell) == slot && s.eff[(size_t)cell] == slot) {
            cmd.op = MCMD_ARMY_STATION;
        } else {
            int32_t home = (size_t)slot < digest.country_capital_cell.size() ? digest.country_capital_cell[(size_t)slot] : -1;
            if (home < 0 || owner_at(digest, home) != slot) {
                const int32_t lo = s.ctrl_off[(size_t)slot], hi = s.ctrl_off[(size_t)slot + 1];
                int32_t best = -1;
                for (int32_t k = lo; k < hi; ++k) {
                    const int32_t c = s.ctrl_cells[(size_t)k];
                    if (owner_at(digest, c) != slot) continue;
                    if (best < 0 || core.cell_distance(cell, c) < core.cell_distance(cell, best)) best = c;
                }
                home = best;
            }
            if (home < 0) continue;
            cmd.op = MCMD_ARMY_MOVE;
            cmd.cell = home;
        }
        ai_submit(core, handle, std::move(cmd));
    }
}

} // namespace

void MilitaryCore::set_ai_country(int32_t slot, bool ai) {
    if (slot < 0 || slot >= 4096) return;
    const size_t want = (size_t)slot + 1;
    if (_ai_country.size() < want) _ai_country.resize(want, 0);
    if (_ai_next_decision_day.size() < want) _ai_next_decision_day.resize(want, 0);
    const bool was = _ai_country[(size_t)slot] != 0;
    _ai_country[(size_t)slot] = ai ? 1 : 0;
    if (ai && (!was || _ai_next_decision_day[(size_t)slot] <= _last_day)) {
        _ai_next_decision_day[(size_t)slot] = next_main_day(_last_day, slot);
    }
}

void MilitaryCore::run_country_ai(const MilitaryWorldDigest &digest) {
    const int64_t day = _last_day;
    bool any_due = false;
    for (size_t i = 0; i < _ai_country.size(); ++i) {
        if (_ai_country[i] && i < _ai_next_decision_day.size() && day >= _ai_next_decision_day[i]) any_due = true;
    }
    if (!any_due || _terrain.cell_count <= 0) return;
    AiScratch &s = ai_scratch();
    build_scratch(*this, digest, s);
    for (int32_t slot = 0; slot < (int32_t)_ai_country.size(); ++slot) {
        if (!_ai_country[(size_t)slot]) continue;
        if ((size_t)slot >= _ai_next_decision_day.size() || day < _ai_next_decision_day[(size_t)slot]) continue;
        const int64_t next_main = next_main_day(day, slot);
        _ai_next_decision_day[(size_t)slot] = next_main;
        if ((size_t)slot >= _policies.size() || slot >= s.cap) continue;
        const uint64_t handle = _policy_handle[(size_t)slot];
        if (handle == 0) continue;
        const bool main = ((day + slot) % kAiPeriodDays) == 0;
        bool at_war_any = false;
        for (const MilitaryWar &w : _wars) {
            if (w.active && (w.attacker_slot == slot || w.defender_slot == slot)) at_war_any = true;
        }
        if (main) {
            decide_budget(*this, digest, s, slot, handle, at_war_any);
            decide_config(*this, digest, s, slot, handle);
            decide_barracks(*this, digest, s, slot, handle, at_war_any);
        }
        bool follow_up = false;
        // Index loop: proposals may not mutate _wars (commands apply tomorrow).
        for (size_t wi = 0; wi < _wars.size(); ++wi) {
            const MilitaryWar war = _wars[wi];
            if (!war.active || (war.attacker_slot != slot && war.defender_slot != slot)) continue;
            const int32_t enemy = war.attacker_slot == slot ? war.defender_slot : war.attacker_slot;
            if (decide_war_armies(*this, s, slot, handle, enemy, true)) follow_up = true;
            if (main) decide_peace(*this, digest, s, slot, handle, war);
        }
        if (main && !at_war_any) {
            if (decide_declare(*this, digest, s, slot, handle)) follow_up = true;   // mobilise tomorrow
            decide_peacetime_armies(*this, s, slot, handle, digest);
        }
        if (follow_up) _ai_next_decision_day[(size_t)slot] = std::min<int64_t>(next_main, day + 1);
    }
}

} // namespace pk

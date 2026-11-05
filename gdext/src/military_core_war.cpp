// NativeMilitaryRuntime - war, engagements, capture, peace, annex, front (sec 11-12).
//
// War state machine (sec 11.1):
//   PEACE --declare--> WAR(D+1); WAR --treaty--> PEACE + TRUCE(365d)
//   WAR --treaty cedes the victim's last cell--> that side is annexed (sec 12.5)
//
// All battle arithmetic is integer q16 and every random draw is
// SplitMix64(seed, key, day) keyed by the normalised edge, so the plan-then-
// replay order is the only thing that decides determinism (sec 21.5).

#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace pk {

namespace {

using namespace mil;

constexpr int64_t kTruceDays = 365;
constexpr int64_t kDefenderBonusDays = 30;
constexpr int32_t kDefenderBonusQ16 = 6554;         // +10% defence
constexpr int32_t kFrontageBaseQ16 = 100000;
constexpr int32_t kFrontagePerEraQ16 = 13107;       // +0.2 per era
constexpr int32_t kBaseDailyDeltaQ16 = 3932;        // 6%
constexpr int32_t kBattleChanceBaseQ16 = 983;       // 1.5%
constexpr int32_t kBattleChanceIntensityQ16 = 2621; // 4% * intensity
constexpr int32_t kBattleSigmaQ16 = 11796;          // sigma 0.18
constexpr int32_t kBattleMinDeltaQ16 = 7864;        // 12%
constexpr int32_t kBattleSpanDeltaQ16 = 26214;      // +40% * |r-0.5|
constexpr int64_t kAssaultBattleIntervalDays = 5;
constexpr int32_t kOrgLossBaseQ16 = 2621;           // 4% * enemy share
constexpr int32_t kOrgLossBattleLoserQ16 = 19661;   // 30%
constexpr int32_t kOrgLossBattleWinnerQ16 = 6554;   // 10%
constexpr int32_t kOrgLossAssaultQ16 = 6554;        // 10%
constexpr int32_t kOrgLossCaptureQ16 = 16384;       // 25%
constexpr int32_t kEngagementIdleCloseDays = 3;
constexpr int32_t kEventCapControl = 128;
constexpr int32_t kEventCapBattle = 64;
constexpr int32_t kLocalDefenceBp = 200;            // 2% of population
constexpr int32_t kReparationPeriodDays = 30;
constexpr int64_t kReparationArrearsMultiple = 3;
constexpr int64_t kWarScoreCapQ16 = 100 * MILITARY_Q16;
constexpr int64_t kBfsExpansionCap = 512;

int64_t mul_q(int64_t a, int64_t b) { return mul_div(a, b, MILITARY_Q16); }

int32_t clamp_q16_i32(int64_t v, int32_t lo, int32_t hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return static_cast<int32_t>(v);
}

bool army_live(const MilitaryArmyStore &s, int32_t slot) { return army_alive(s, slot); }

// Fortification coefficient of a cell (sec 11.7).
int32_t fort_q16(const MilitaryCore &core, int32_t cell) {
    const MilitaryTerrainInput &t = core.terrain();
    int32_t tier_bonus = 0;
    if ((size_t)cell < t.settlement_tier.size()) {
        switch (t.settlement_tier[(size_t)cell]) {
            case 1: tier_bonus = 0; break;
            case 2: tier_bonus = 19661; break;     // +0.3
            case 3: tier_bonus = 45875; break;     // +0.7
            case 4: tier_bonus = 78643; break;     // +1.2
            default: tier_bonus = 0; break;
        }
    }
    int32_t fort = MILITARY_Q16 + tier_bonus;
    for (const MilitaryCellState &row : core.cell_states()) {
        if (row.cell != cell) continue;
        if (row.fort_tier < 0) break;
        int32_t best = 0;
        const int32_t tier = row.fort_tier;
        for (const MilitaryStateBuilding &b : core.catalog().state_buildings) {
            if (b.role != (uint8_t)MILITARY_STATE_FORTIFICATION) continue;
            if (b.tier > tier) continue;
            if (b.fort_bonus_q16 > best) best = b.fort_bonus_q16;
        }
        if (row.disrepair != 0) best /= 2;
        fort += best;
        break;
    }
    return fort;
}

int32_t terrain_def_q16(const MilitaryCore &core, int32_t cell) {
    const MilitaryTerrainInput &t = core.terrain();
    const MilitaryCatalog &c = core.catalog();
    int32_t def = MILITARY_Q16;
    if ((size_t)cell < t.landform.size()) {
        const size_t lf = t.landform[(size_t)cell];
        if (lf < c.landform_def_q8.size() && c.landform_def_q8[lf] > 0) {
            def = (int32_t)c.landform_def_q8[lf] * 256;
        }
    }
    if ((size_t)cell < t.vegetation.size()) {
        const size_t v = t.vegetation[(size_t)cell];
        if (v < c.vegetation_def_q8.size() && c.vegetation_def_q8[v] > 0) {
            def = (int32_t)mul_div(def, (int64_t)c.vegetation_def_q8[v] * 256, MILITARY_Q16);
        }
    }
    return def;
}

int32_t terrain_width_q16(const MilitaryCore &core, int32_t cell) {
    const MilitaryTerrainInput &t = core.terrain();
    const MilitaryCatalog &c = core.catalog();
    int32_t width = MILITARY_Q16;
    if ((size_t)cell < t.landform.size()) {
        const size_t lf = t.landform[(size_t)cell];
        if (lf < c.landform_width_q8.size() && c.landform_width_q8[lf] > 0) {
            width = (int32_t)c.landform_width_q8[lf] * 256;
        }
    }
    return width;
}

int32_t effective_controller(const MilitaryCore &core, const MilitaryWorldDigest &digest,
                             int32_t cell) {
    const int32_t controller = core.controller_of(cell);
    if (controller >= 0) return controller;
    if ((size_t)cell < digest.cell_owner_slot.size()) return digest.cell_owner_slot[(size_t)cell];
    return -1;
}

int32_t owner_of_cell(const MilitaryWorldDigest &digest, int32_t cell) {
    if ((size_t)cell < digest.cell_owner_slot.size()) return digest.cell_owner_slot[(size_t)cell];
    return -1;
}

// F_supply x F_pay x F_morale x F_org, clamped to [0.05, 4] (sec 13).
int32_t cohesion_q16(const MilitaryArmyStore &armies, size_t slot) {
    const int64_t supply = 19661 + mul_q(45875, armies.supply_ratio_q16[slot]);
    const int64_t pay = 26214 + mul_q(39322, armies.pay_ratio_q16[slot]);
    const int64_t morale = 39322 + mul_q(52429, armies.morale_q16[slot]);
    const int64_t org = 32768 + mul_q(32768, armies.organization_q16[slot]);
    int64_t total = mul_q(mul_q(supply, pay), mul_q(morale, org));
    total = clamp64(total, 3283, 4 * (int64_t)MILITARY_Q16);
    return (int32_t)total;
}

int64_t sum_lot_value(const MilitaryCore &core, size_t army_slot, bool attack) {
    // Lot index walk: only the formation's own rows, never the whole table.
    const MilitaryCatalog &catalog = core.catalog();
    int64_t sum = 0;
    military_for_each_lot(core, (uint8_t)MILITARY_LOT_ARMY, (int32_t)army_slot, [&](int32_t i) {
        const size_t s = (size_t)i;
        if (core._lots.count[s] <= 0) return;
        if (core._lots.unit_type[s] < 0 || (size_t)core._lots.unit_type[s] >= catalog.units.size()) return;
        const MilitaryUnitType &type = catalog.units[(size_t)core._lots.unit_type[s]];
        const int64_t condition = std::max(core._lots.condition_q16[s], 32768);
        const int64_t factor = 32768 + mul_q(32768, condition);
        // v3: fold the *actually delivered* equipment quality into live combat,
        // exactly as refresh_army_cache does for the UI / AI numbers.
        const int64_t eq = equip_factor_q16(type, core._lots.equip_quality_q8[s]);
        const int64_t per = attack ? type.attack_q16 : type.defense_q16;
        sum += mul_q(mul_q(mul_q(core._lots.count[s], per), factor), eq);
    });
    return sum;
}

int32_t army_fort_ignore_q16(const MilitaryCore &core, size_t army_slot) {
    const MilitaryCatalog &catalog = core.catalog();
    int64_t weighted = 0;
    int64_t heads = 0;
    military_for_each_lot(core, (uint8_t)MILITARY_LOT_ARMY, (int32_t)army_slot, [&](int32_t i) {
        const size_t s = (size_t)i;
        const int64_t count = core._lots.count[s];
        if (count <= 0) return;
        heads += count;
        if (core._lots.unit_type[s] < 0 || (size_t)core._lots.unit_type[s] >= catalog.units.size()) return;
        const MilitaryUnitType &type = catalog.units[(size_t)core._lots.unit_type[s]];
        if (type.fortification_ignore_q16 > 0) {
            weighted += mul_q(count, type.fortification_ignore_q16);
        }
    });
    if (heads <= 0) return 0;
    return (int32_t)std::min<int64_t>(mul_div(weighted, MILITARY_Q16, heads), MILITARY_Q16);
}

int64_t local_defence(const MilitaryCore &core, const MilitaryWorldDigest &digest, int32_t cell) {
    int64_t population = 0;
    if ((size_t)cell < digest.cell_population.size()) population = digest.cell_population[(size_t)cell];
    if (population <= 0) return 0;
    const int32_t controller = effective_controller(core, digest, cell);
    int32_t era = 0;
    if (controller >= 0 && (size_t)controller < digest.country_era.size()) {
        era = digest.country_era[(size_t)controller];
    }
    int32_t best_defence_q16 = MILITARY_Q16;
    for (const MilitaryUnitType &type : core.catalog().units) {
        if (type.unit_class != (uint8_t)MILITARY_CLASS_LINE) continue;
        if (type.era_index > era) continue;
        if (type.defense_q16 > best_defence_q16) best_defence_q16 = type.defense_q16;
    }
    const int64_t base = mul_div(population, kLocalDefenceBp, 10000);
    return mul_q(mul_q(base, best_defence_q16), fort_q16(core, cell));
}

// Deterministic gaussian sample (Box-Muller on two keyed uniforms).
int32_t gauss_q16(uint64_t seed, uint64_t key, int64_t day, int32_t sigma_q16) {
    const uint64_t r1 = rng(seed, key, day) >> 11;
    const uint64_t r2 = rng(seed, mix_key(key, 0x9e37u), day) >> 11;
    double u1 = (double)r1 / (double)(1ull << 53);
    const double u2 = (double)r2 / (double)(1ull << 53);
    if (u1 < 1e-12) u1 = 1e-12;
    const double radius = std::sqrt(-2.0 * std::log(u1));
    const double value = radius * std::cos(6.283185307179586 * u2);
    const double scaled = value * (double)sigma_q16;
    const double limit = 8.0 * (double)sigma_q16;
    if (scaled > limit) return (int32_t)limit;
    if (scaled < -limit) return (int32_t)-limit;
    return (int32_t)(scaled >= 0.0 ? scaled + 0.5 : scaled - 0.5);
}

// Channel-B unit rules (sec 17.1). Each rule is a closed integer kernel driven by
// country.military.rule.* parameters; there is no script evaluation.
struct RuleFactor {
    int32_t attack_q16 = MILITARY_Q16;
    int32_t defense_q16 = MILITARY_Q16;
    uint8_t no_auto_disengage = 0;
};

// Supply connectivity (sec 17.1 last_stand): cell reaches a stocked market of the
// same country within the supply radius (design 9.3; the nationwide
// nearest-market field is retired).
bool supply_connected(const MilitaryCore &core, const MilitaryWorldDigest &digest, int32_t slot,
                      int32_t cell) {
    return military_supply_connected(core, digest, slot, cell);
}
int32_t rule_param_q16(const MilitaryWorldDigest &digest, int32_t slot, MilitaryStatId id) {
    // Rule stats are additive with a 0 base (sec 16.1); a zero means "not taken".
    if (!has_stat(digest, slot, id)) return 0;
    const size_t idx = (size_t)slot * (size_t)digest.stat_count + (size_t)id;
    if (idx >= digest.country_stat_q16.size()) return 0;
    return digest.country_stat_q16[idx];
}

bool has_hostile_army_near(const MilitaryCore &core, const MilitaryWorldDigest &digest,
                           int32_t cell, int32_t slot) {
    const MilitaryTerrainInput &terrain = core.terrain();
    if ((size_t)cell * 6 + 5 >= terrain.neighbors.size()) return false;
    for (int32_t dir = 0; dir < 6; ++dir) {
        const int32_t next = terrain.neighbors[(size_t)(cell * 6 + dir)];
        if (next < 0) continue;
        for (int32_t other = core._cell_head[(size_t)next]; other >= 0;
             other = core._armies.next_in_cell[(size_t)other]) {
            if (!core._armies.active[(size_t)other]) continue;
            const int32_t owner = core._armies.owner_slot[(size_t)other];
            if (owner < 0 || owner == slot) continue;
            if (core.at_war(slot, owner)) return true;
        }
    }
    return false;
}

// Encirclement: how many of the 6 neighbours are ours (control or army).
int32_t friendly_neighbours(const MilitaryCore &core, const MilitaryWorldDigest &digest,
                            int32_t cell, int32_t slot) {
    const MilitaryTerrainInput &terrain = core.terrain();
    if ((size_t)cell * 6 + 5 >= terrain.neighbors.size()) return 0;
    int32_t count = 0;
    for (int32_t dir = 0; dir < 6; ++dir) {
        const int32_t next = terrain.neighbors[(size_t)(cell * 6 + dir)];
        if (next < 0) continue;
        if (effective_controller(core, digest, next) == slot) {
            ++count;
            continue;
        }
        for (int32_t other = core._cell_head[(size_t)next]; other >= 0;
             other = core._armies.next_in_cell[(size_t)other]) {
            if (!core._armies.active[(size_t)other]) continue;
            if (core._armies.owner_slot[(size_t)other] != slot) continue;
            ++count;
            break;
        }
    }
    return count;
}

// Mutual support: other friendly armies within distance 2 (capped at 3).
int32_t support_armies_near(const MilitaryCore &core, int32_t cell, int32_t slot,
                            int32_t self_army) {
    int32_t count = 0;
    for (int32_t other = 0; other < (int32_t)core._armies.active.size() && count < 3; ++other) {
        if (other == self_army) continue;
        if (!core._armies.active[(size_t)other]) continue;
        if (core._armies.owner_slot[(size_t)other] != slot) continue;
        if (core.cell_distance(core._armies.cell[(size_t)other], cell) > 2) continue;
        ++count;
    }
    return count;
}

// Evaluates the closed rule set for one army.
RuleFactor evaluate_rules(const MilitaryCore &core, const MilitaryWorldDigest &digest, int32_t army,
                          int32_t cell, int32_t slot, bool defending, bool cell_attacked,
                          bool connected, int64_t engagement_start_day, int64_t day) {
    RuleFactor factor;
    if (slot < 0) return factor;
    const int64_t attack_owner_cell =
        core._armies.cell[(size_t)army] < (int32_t)core.cell_controller().size()
            ? (int32_t)core.cell_controller()[(size_t)core._armies.cell[(size_t)army]]
            : -1;
    (void)attack_owner_cell;
    // mutual_support: 3% per supporting army (max 3), defence.
    const int32_t support = rule_param_q16(digest, slot, MSTAT_RULE_MUTUAL_SUPPORT);
    if (support > 0) {
        const int32_t count = support_armies_near(core, cell, slot, army);
        factor.defense_q16 += (int32_t)mul_div(support, count, 1);
    }
    // last_stand: cut off from supply, attack and defence, no auto-disengage.
    const int32_t last_stand = rule_param_q16(digest, slot, MSTAT_RULE_LAST_STAND);
    if (last_stand > 0 && !connected) {
        factor.attack_q16 += last_stand;
        factor.defense_q16 += last_stand;
        factor.no_auto_disengage = 1;
    }
    // blitz: fast unit inside the first 5 days of an engagement, attack.
    const int32_t blitz = rule_param_q16(digest, slot, MSTAT_RULE_BLITZ);
    if (blitz > 0 && defending == false && engagement_start_day >= 0 &&
        day - engagement_start_day < 5 && core._armies.cached_speed_q16[(size_t)army] >= 2 * MILITARY_Q16) {
        factor.attack_q16 += blitz;
    }
    // hold_the_line: HOLD stance while being attacked, defence.
    const int32_t hold = rule_param_q16(digest, slot, MSTAT_RULE_HOLD_THE_LINE);
    if (hold > 0 && defending && cell_attacked &&
        core._armies.stance[(size_t)army] == (uint8_t)MILITARY_STANCE_HOLD) {
        factor.defense_q16 += hold;
    }
    // encirclement: the attacked enemy cell has >= 4 friendly neighbours, attack.
    const int32_t encircle = rule_param_q16(digest, slot, MSTAT_RULE_ENCIRCLEMENT);
    if (encircle > 0 && !defending) {
        const int32_t target = core._armies.cell[(size_t)army];
        if (friendly_neighbours(core, digest, target, slot) >= 4) {
            factor.attack_q16 += encircle;
        }
    }
    // home_ground: fighting on own territory, attack and defence.
    const int32_t home = rule_param_q16(digest, slot, MSTAT_RULE_HOME_GROUND);
    if (home > 0 && (size_t)cell < digest.cell_owner_slot.size() &&
        digest.cell_owner_slot[(size_t)cell] == slot) {
        factor.attack_q16 += home;
        factor.defense_q16 += home;
    }
    return factor;
}

uint64_t edge_key(int32_t a, int32_t b) {
    const int32_t lo = std::min(a, b);
    const int32_t hi = std::max(a, b);
    return (uint64_t)(uint32_t)lo << 32 | (uint32_t)hi;
}

} // namespace

// ================================================================ war rows

bool MilitaryCore::truce_active(int32_t slot_a, int32_t slot_b, int64_t day) const {
    if (slot_a < 0 || slot_b < 0) return false;
    for (const MilitaryTruce &t : _truces) {
        if (t.until_day <= day) continue;
        if ((t.slot_a == slot_a && t.slot_b == slot_b) ||
            (t.slot_a == slot_b && t.slot_b == slot_a)) {
            return true;
        }
    }
    return false;
}

MilitaryWar *MilitaryCore::find_war(int32_t war_id) {
    for (MilitaryWar &w : _wars) {
        if (w.id == war_id) return &w;
    }
    return nullptr;
}

const MilitaryWar *MilitaryCore::find_war_const(int32_t war_id) const {
    for (const MilitaryWar &w : _wars) {
        if (w.id == war_id) return &w;
    }
    return nullptr;
}

int32_t MilitaryCore::next_war_id() {
    int32_t next = 1;
    for (const MilitaryWar &w : _wars) next = std::max(next, w.id + 1);
    return next;
}

// ============================================================ war commands

void MilitaryCore::apply_war_command(const MilitaryCommand &cmd, int64_t day) {
    switch (cmd.op) {
        case MCMD_WAR_DECLARE: {
            const int32_t attacker = country_slot_for_handle(cmd.country);
            const int32_t defender = country_slot_for_handle(cmd.other);
            if (attacker < 0 || defender < 0 || attacker == defender) return;
            if (at_war(attacker, defender)) return;
            if (truce_active(attacker, defender, day)) return;
            if (country_soldiers(attacker) <= 0) return;
            MilitaryWar war;
            war.id = next_war_id();
            war.attacker_slot = attacker;
            war.defender_slot = defender;
            war.attacker_handle = cmd.country;
            war.defender_handle = cmd.other;
            war.start_day = day;
            war.active = 1;
            _wars.push_back(war);
            MilitaryEvent event;
            event.day = day;
            event.type = MILITARY_EVENT_WAR_DECLARED;
            event.payload_schema = 20;
            event.cell = -1;
            event.i0 = (uint64_t)(uint32_t)attacker;
            event.i1 = (uint64_t)(uint32_t)defender;
            event.i2 = (uint64_t)(uint32_t)war.id;
            push_event(event);
            return;
        }
        case MCMD_PEACE_PROPOSE:
        case MCMD_PEACE_RESPOND: {
            MilitaryWar *war = find_war((int32_t)cmd.other);
            if (war == nullptr || !war->active) return;
            const int32_t proposer = country_slot_for_handle(cmd.country);
            if (proposer < 0) return;
            if (proposer != war->attacker_slot && proposer != war->defender_slot) return;
            const int64_t last_rejected = proposer == war->attacker_slot
                                              ? war->last_rejected_offer_day_a
                                              : war->last_rejected_offer_day_b;
            if (day - last_rejected < 30) return;
            MilitaryPeaceEvaluation evaluation;
            if (cmd.op == MCMD_PEACE_PROPOSE) {
                const std::vector<int32_t> ints = cmd.ints;
                const std::vector<int64_t> longs = cmd.longs;
                evaluation = evaluate_peace(war->id, cmd.country, ints, longs);
                if (!evaluation.valid) return;
                if (evaluation.price_q16 > evaluation.willing_q16) {
                    if (proposer == war->attacker_slot) {
                        war->last_rejected_offer_day_a = day;
                    } else {
                        war->last_rejected_offer_day_b = day;
                    }
                    return;
                }
                execute_treaty(*war, ints, longs, proposer, day, _war_intents);
                return;
            }
            // Respond: the peer's standing offer is accepted/rejected.
            const std::vector<int32_t> ints = cmd.ints;
            const std::vector<int64_t> longs = cmd.longs;
            if (cmd.count <= 0) {
                if (proposer == war->attacker_slot) {
                    war->last_rejected_offer_day_a = day;
                } else {
                    war->last_rejected_offer_day_b = day;
                }
                return;
            }
            execute_treaty(*war, ints, longs, proposer, day, _war_intents);
            return;
        }
        default:
            return;
    }
}

// ============================================================ engagements

void MilitaryCore::open_engagement(int32_t from_cell, int32_t to_cell, int32_t attacker_slot,
                                   int32_t defender_slot) {
    if (from_cell < 0 || to_cell < 0) return;
    if (!army_live(_armies, attacker_slot)) return;
    if ((size_t)to_cell >= (size_t)_cell_head.size()) return;
    const int32_t a = std::min(from_cell, to_cell);
    const int32_t b = std::max(from_cell, to_cell);
    for (size_t i = 0; i < _engagements.size(); ++i) {
        MilitaryEngagement &e = _engagements[i];
        if (!e.active) continue;
        if (e.cell_a != a || e.cell_b != b) continue;
        if (_armies.engagement[(size_t)attacker_slot] < 0) {
            _armies.engagement[(size_t)attacker_slot] = (int32_t)i;
        }
        return;
    }
    MilitaryEngagement e;
    e.cell_a = a;
    e.cell_b = b;
    e.attacker_side_cell = from_cell;
    e.attacker_slot = attacker_slot;
    e.defender_slot = defender_slot;
    e.war_id = war_between(_armies.owner_slot[(size_t)attacker_slot], defender_slot);
    e.progress_q16 = 32768;
    e.start_day = _last_day;
    e.active = 1;
    _engagements.push_back(e);
    const int32_t index = (int32_t)_engagements.size() - 1;
    _armies.engagement[(size_t)attacker_slot] = index;
    for (int32_t other = _cell_head[(size_t)to_cell]; other >= 0;
         other = _armies.next_in_cell[(size_t)other]) {
        if (!_armies.active[(size_t)other]) continue;
        if (_armies.owner_slot[(size_t)other] != defender_slot) continue;
        if (_armies.engagement[(size_t)other] >= 0) continue;
        _armies.engagement[(size_t)other] = index;
    }
    update_front_cells({from_cell, to_cell});
}

void MilitaryCore::close_engagement(int32_t index) {
    if (index < 0 || (size_t)index >= _engagements.size()) return;
    if (!_engagements[(size_t)index].active) return;
    _engagements[(size_t)index].active = 0;
    for (size_t a = 0; a < _armies.engagement.size(); ++a) {
        if (_armies.engagement[a] == index) _armies.engagement[a] = -1;
    }
    update_front_cells({_engagements[(size_t)index].cell_a, _engagements[(size_t)index].cell_b});
}

// ------------------------------------------------------------ daily replay

void MilitaryCore::run_engagements(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    if (_engagements.empty()) return;
    const size_t army_count = _armies.active.size();
    if (_armies.engagement.size() != army_count) _armies.engagement.resize(army_count, -1);

    struct Plan {
        int32_t index = -1;
        int32_t delta_q16 = 0;
        int64_t losses_attacker = 0;
        int64_t losses_defender = 0;
        int32_t org_attacker = 0;
        int32_t org_defender = 0;
        uint8_t battle = 0;
        int32_t battle_delta_q16 = 0;
        int32_t battle_score_q16 = 0;
        int32_t winner_slot = -1;
        int32_t loser_slot = -1;
        int64_t winner_losses = 0;
        int64_t loser_losses = 0;
        int32_t defender_slot = -1;
        int32_t far_cell = -1;
        uint8_t attacker_no_disengage = 0;
    };

    std::vector<int32_t> order;
    order.reserve(_engagements.size());
    for (size_t i = 0; i < _engagements.size(); ++i) {
        if (_engagements[i].active) order.push_back((int32_t)i);
    }
    if (order.empty()) return;
    std::sort(order.begin(), order.end(), [this](int32_t lhs, int32_t rhs) {
        const MilitaryEngagement &a = _engagements[(size_t)lhs];
        const MilitaryEngagement &b = _engagements[(size_t)rhs];
        if (a.cell_a != b.cell_a) return a.cell_a < b.cell_a;
        return a.cell_b < b.cell_b;
    });

    // ---- Plan: pure reads, thread-safe, no shared mutation.
    // ---- Plan: pure reads, thread-safe, no shared mutation.
    std::vector<Plan> plans;
    plans.reserve(order.size());
    for (size_t oi = 0; oi < order.size(); ++oi) {
        const int32_t index = order[oi];
        const MilitaryEngagement &e = _engagements[(size_t)index];
        Plan plan;
        plan.index = index;
        if (!army_live(_armies, e.attacker_slot)) {
            plans.push_back(plan);
            continue;
        }
        const int32_t attacker = _armies.owner_slot[(size_t)e.attacker_slot];
        const int32_t from_cell = _armies.cell[(size_t)e.attacker_slot];
        const int32_t far_cell = (from_cell == e.cell_a) ? e.cell_b : e.cell_a;
        plan.far_cell = far_cell;
        const int32_t defender_country = e.defender_slot;
        plan.defender_slot = defender_country;

        int64_t defender_attack = 0;
        int64_t defender_defence = 0;
        int64_t defender_heads = 0;
        int64_t attacker_heads = _armies.cached_headcount[(size_t)e.attacker_slot];
        for (int32_t other = _cell_head[(size_t)far_cell]; other >= 0;
             other = _armies.next_in_cell[(size_t)other]) {
            if (!_armies.active[(size_t)other]) continue;
            if (defender_country >= 0 && _armies.owner_slot[(size_t)other] != defender_country) {
                continue;
            }
            const int32_t cohesion = cohesion_q16(_armies, (size_t)other);
            const int32_t other_owner = _armies.owner_slot[(size_t)other];
            const bool other_connected = supply_connected(*this, digest, other_owner, far_cell);
            const RuleFactor rules =
                evaluate_rules(*this, digest, other, far_cell, other_owner, true, true,
                               other_connected, e.start_day, digest.day);
            defender_heads += _armies.cached_headcount[(size_t)other];
            defender_attack += mul_q(mul_q(sum_lot_value(*this, (size_t)other, true), cohesion),
                                     rules.attack_q16);
            defender_defence += mul_q(mul_q(sum_lot_value(*this, (size_t)other, false), cohesion),
                                      rules.defense_q16);
        }
        const int32_t attacker_cohesion = cohesion_q16(_armies, (size_t)e.attacker_slot);
        int64_t attacker_attack = mul_q(sum_lot_value(*this, (size_t)e.attacker_slot, true),
                                        attacker_cohesion);
        // Channel-B rules (sec 17.1): the attacker fights from its own cell, the
        // defender holds the contested one.
        const bool attacker_connected = supply_connected(*this, digest, attacker, from_cell);
        const RuleFactor attacker_rules =
            evaluate_rules(*this, digest, e.attacker_slot, from_cell, attacker, false, false,
                           attacker_connected, e.start_day, digest.day);
        attacker_attack = mul_q(attacker_attack, attacker_rules.attack_q16);
        plan.attacker_no_disengage = attacker_rules.no_auto_disengage;

        // Frontage W = frontage(era) * terrain width * frontage stat (sec 11.4).
        int32_t era = 0;
        if (attacker >= 0 && (size_t)attacker < digest.country_era.size()) {
            era = digest.country_era[(size_t)attacker];
        }
        const int64_t frontage =
            mul_q(kFrontageBaseQ16 + (int64_t)kFrontagePerEraQ16 * era,
                  terrain_width_q16(*this, far_cell));
        const int64_t width = std::max<int64_t>(1, mul_q(frontage, stat_q16(digest, attacker, MSTAT_FRONTAGE)));
        const int64_t n_attacker = std::min<int64_t>(attacker_heads, width);
        const int64_t n_defender = std::min<int64_t>(defender_heads, width);
        if (attacker_heads > 0 && n_attacker < attacker_heads) {
            attacker_attack = mul_div(attacker_attack, n_attacker, attacker_heads);
        }
        if (defender_heads > 0 && n_defender < defender_heads) {
            defender_defence = mul_div(defender_defence, n_defender, defender_heads);
            defender_attack = mul_div(defender_attack, n_defender, defender_heads);
        }

        // T_b = terrain_def * fort^(1-ignore) * river penalty.
        const int32_t fort_ignore = army_fort_ignore_q16(*this, (size_t)e.attacker_slot);
        const int32_t fort = fort_q16(*this, far_cell);
        int64_t fort_term = fort;
        if (fort_ignore > 0) {
            fort_term = MILITARY_Q16 + mul_q(fort - MILITARY_Q16, MILITARY_Q16 - fort_ignore);
        }
        int64_t t_defence = mul_q(terrain_def_q16(*this, far_cell), fort_term);
        const MilitaryTerrainInput &terrain = _terrain;
        if ((size_t)far_cell < terrain.has_river.size() &&
            (size_t)e.attacker_side_cell < terrain.has_river.size() &&
            terrain.has_river[(size_t)far_cell] &&
            !terrain.has_river[(size_t)e.attacker_side_cell]) {
            t_defence = mul_q(t_defence, 95 * MILITARY_Q16 / 100);
        }
        if (e.war_id >= 0) {
            if (const MilitaryWar *war = find_war_const(e.war_id)) {
                if (digest.day - war->start_day < kDefenderBonusDays) t_defence += kDefenderBonusQ16;
            }
        }
        const int64_t local = local_defence(*this, digest, far_cell);
        const int64_t s_attacker = attacker_attack;
        const int64_t s_defender = mul_q(defender_defence, t_defence) + local;
        const int64_t p_attacker = attacker_attack / 2;
        const int64_t c_defender = defender_attack / 2;
        if (s_attacker <= 0 && s_defender <= 0) {
            plans.push_back(plan);
            continue;
        }
        const int64_t denominator = std::max<int64_t>(s_attacker + s_defender, 1);
        const uint64_t key = edge_key(e.cell_a, e.cell_b);
        const int64_t noise_q16 = 65536 + (int64_t)rng_q16(_seed, key, digest.day) * 19661 / 65536;
        const int64_t delta = mul_q(mul_div(kBaseDailyDeltaQ16, s_attacker - s_defender, denominator),
                                    noise_q16);
        plan.delta_q16 = (int32_t)clamp64(delta, -kBaseDailyDeltaQ16 * 2, kBaseDailyDeltaQ16 * 2);
        // Casualties: 0.8% of the engaged force scaled by the odds.
        const int64_t casualty_att =
            mul_div(mul_div(mul_div(n_attacker, 8, 1000), c_defender,
                            std::max<int64_t>(c_defender + p_attacker, 1)),
                    stat_q16(digest, attacker, MSTAT_CASUALTY), MILITARY_Q16);
        const int64_t casualty_def =
            mul_div(mul_div(mul_div(n_defender, 8, 1000), s_attacker, denominator),
                    stat_q16(digest, defender_country, MSTAT_CASUALTY), MILITARY_Q16);
        plan.losses_attacker = std::min<int64_t>(casualty_att, std::max<int64_t>(n_attacker, 0));
        plan.losses_defender = std::min<int64_t>(casualty_def, std::max<int64_t>(n_defender, 0));
        plan.org_attacker = -(int32_t)mul_div(kOrgLossBaseQ16, s_defender, denominator);
        plan.org_defender = -(int32_t)mul_div(kOrgLossBaseQ16, s_attacker, denominator);

        // Battle (sec 11.5): 1.5% + 4% * intensity, or ASSAULT every 5 days.
        const int64_t minority = std::min(s_attacker, s_defender);
        const int32_t intensity_q16 = (int32_t)mul_div(minority, MILITARY_Q16, denominator);
        const int32_t chance_q16 =
            kBattleChanceBaseQ16 + (int32_t)mul_div(kBattleChanceIntensityQ16, intensity_q16,
                                                    MILITARY_Q16);
        const uint64_t battle_key = key ^ 0xba771u;
        const bool rolled = (int64_t)rng_q16(_seed, battle_key, digest.day) < chance_q16;
        const bool assault_due =
            _armies.stance[(size_t)e.attacker_slot] == (uint8_t)MILITARY_STANCE_ASSAULT &&
            e.days_since_battle >= kAssaultBattleIntervalDays;
        if (rolled || assault_due) {
            plan.battle = 1;
            const int32_t base_r = (int32_t)mul_div(s_attacker, MILITARY_Q16, denominator);
            const int32_t r_q16 = clamp_q16_i32((int64_t)base_r +
                                                    gauss_q16(_seed, battle_key, digest.day, kBattleSigmaQ16),
                                                0, MILITARY_Q16);
            const int64_t span = kBattleMinDeltaQ16 +
                                 mul_div(kBattleSpanDeltaQ16, std::llabs((int64_t)r_q16 - 32768), 32768);
            const bool attacker_wins = r_q16 >= 32768;
            plan.battle_delta_q16 = (int32_t)(attacker_wins ? span : -span);
            plan.battle_score_q16 = (int32_t)(2 * MILITARY_Q16 +
                                              mul_div(6 * MILITARY_Q16, intensity_q16, MILITARY_Q16));
            const int32_t winner_bp = 150 + (int32_t)(rng_q16(_seed, battle_key ^ 0x11u, digest.day) % 151);
            const int32_t loser_bp = 400 + (int32_t)(rng_q16(_seed, battle_key ^ 0x22u, digest.day) % 401);
            if (attacker_wins) {
                plan.winner_slot = e.attacker_slot;
                plan.loser_slot = defender_country;
                plan.winner_losses = mul_div(n_attacker, winner_bp, 10000);
                plan.loser_losses = mul_div(n_defender, loser_bp, 10000);
                plan.org_attacker -= kOrgLossBattleWinnerQ16;
                plan.org_defender -= kOrgLossBattleLoserQ16;
            } else {
                plan.winner_slot = defender_country;
                plan.loser_slot = e.attacker_slot;
                plan.winner_losses = mul_div(n_defender, winner_bp, 10000);
                plan.loser_losses = mul_div(n_attacker, loser_bp, 10000);
                plan.org_attacker -= kOrgLossBattleLoserQ16;
                plan.org_defender -= kOrgLossBattleWinnerQ16;
            }
            if (assault_due && !rolled) plan.org_attacker -= kOrgLossAssaultQ16;
        }
        plans.push_back(plan);
    }

    // ---- Replay in ascending edge key. All shared mutation happens here.
    int32_t battle_events = 0;
    std::vector<int32_t> captured;
    for (size_t pi = 0; pi < plans.size(); ++pi) {
        const Plan &plan = plans[pi];
        MilitaryEngagement &e = _engagements[(size_t)plan.index];
        if (!e.active) continue;
        if (!army_live(_armies, e.attacker_slot)) {
            close_engagement(plan.index);
            continue;
        }
        int64_t delta = plan.delta_q16;
        if (plan.battle != 0) {
            delta += plan.battle_delta_q16;
            e.days_since_battle = 0;
        } else {
            e.days_since_battle += 1;
        }
        // Progress stays in q16 (65536 = 1.0).
        e.progress_q16 = clamp_q16_i32((int64_t)e.progress_q16 + delta, 0, MILITARY_Q16);
        e.casualties_attacker += plan.losses_attacker;
        e.casualties_defender += plan.losses_defender;
        apply_casualties(plan.losses_attacker, e.attacker_slot, plan.far_cell, out);
        // Defender casualties land on every defending army of the far cell.
        if (plan.losses_defender > 0) {
            int64_t remaining = plan.losses_defender;
            for (int32_t other = _cell_head[(size_t)plan.far_cell]; other >= 0 && remaining > 0;
                 other = _armies.next_in_cell[(size_t)other]) {
                if (!_armies.active[(size_t)other]) continue;
                if (_armies.engagement[(size_t)other] != plan.index) continue;
                const int64_t heads = _armies.cached_headcount[(size_t)other];
                const int64_t take = std::min(remaining, heads);
                if (take <= 0) continue;
                apply_casualties(take, other, plan.far_cell, out);
                remaining -= take;
            }
        }
        if ((size_t)e.attacker_slot < _armies.organization_q16.size()) {
            _armies.organization_q16[(size_t)e.attacker_slot] = clamp_q16_i32(
                (int64_t)_armies.organization_q16[(size_t)e.attacker_slot] + plan.org_attacker, 0,
                MILITARY_Q16);
        }
        for (int32_t other = _cell_head[(size_t)plan.far_cell]; other >= 0;
             other = _armies.next_in_cell[(size_t)other]) {
            if (_armies.engagement[(size_t)other] != plan.index) continue;
            _armies.organization_q16[(size_t)other] = clamp_q16_i32(
                (int64_t)_armies.organization_q16[(size_t)other] + plan.org_defender, 0, MILITARY_Q16);
        }
        if (plan.battle != 0) {
            record_battle(digest.day, (e.cell_a + e.cell_b) / 2, e.war_id, plan.winner_slot,
                          plan.loser_slot, plan.winner_losses, plan.loser_losses,
                          plan.battle_score_q16);
            with_war_score(e.war_id, plan.winner_slot == e.attacker_slot ? plan.battle_score_q16
                                                                        : -plan.battle_score_q16);
            if (battle_events < kEventCapBattle) {
                MilitaryEvent event;
                event.day = digest.day;
                event.type = MILITARY_EVENT_BATTLE_RESOLVED;
                event.payload_schema = 21;
                event.cell = (e.cell_a + e.cell_b) / 2;
                event.i0 = (uint64_t)(uint32_t)plan.winner_slot;
                event.i1 = (uint64_t)(uint32_t)plan.loser_slot;
                event.i2 = (uint64_t)(uint32_t)e.progress_q16;
                event.i3 = 0;
                event.value = plan.loser_losses;
                push_event(event);
                ++battle_events;
            } else {
                ++_report.event_coalesced;
            }
        }
        if (e.progress_q16 >= MILITARY_Q16) {
            captured.push_back(plan.index);
            continue;
        }
        if (e.progress_q16 <= 0) {
            const bool assaulting =
                _armies.stance[(size_t)e.attacker_slot] == (uint8_t)MILITARY_STANCE_ASSAULT;
            // last_stand keeps a cut-off formation in the fight (sec 17.1).
            if (!assaulting && plan.attacker_no_disengage == 0) close_engagement(plan.index);
        }
    }
    // Capture after the whole replay so retreat routes see final control.
    for (int32_t index : captured) {
        if ((size_t)index >= _engagements.size()) continue;
        if (!_engagements[(size_t)index].active) continue;
        capture_cell(index, digest, out);
    }
}

void MilitaryCore::apply_casualties(int64_t losses, int32_t army_hint, int32_t fallback_cell,
                                    std::vector<MilitaryIntent> &out) {
    if (losses <= 0) return;
    if (army_hint >= 0 && army_live(_armies, army_hint)) {
        const int32_t taken = (int32_t)lot_remove_casualties((uint8_t)MILITARY_LOT_ARMY, army_hint,
                                                            losses);
        if (taken > 0) {
            // Army personnel lane (contract §2.1): the dead live in the
            // formation's Economy lane, not in the home cell's soldier cohort,
            // so the lane is released to the battle cell and the casualty is
            // booked there. Emitting the old cell-targeted casualty alone would
            // kill an unrelated garrison and leave the lane holding ghosts.
            emit_army_personnel_loss(army_hint, _armies.cell[(size_t)army_hint], taken, taken,
                                     out);
        }
        refresh_army_cache(army_hint);
        return;
    }
    // Garrison casualties from battles are not applicable in v1: engagements
    // only exist between armies, which are always addressed by army_hint.
    (void)fallback_cell;
}

// ================================================================ capture

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
        _armies.mission[(size_t)best] = (uint8_t)MILITARY_MISSION_NONE;
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
                                                              _lots.equip_quality_q8[(size_t)i]);
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
                                                    _lots.equip_quality_q8[i]);
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
    _armies.mission[(size_t)army] = (uint8_t)MILITARY_MISSION_NONE;
    _armies.path_len[(size_t)army] = 0;
    _armies.path_cursor[(size_t)army] = 0;
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
    int64_t total = 0;
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (!_lots.active[i]) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (_lots.location[i] != cell) continue;
        if (country_slot >= 0 && _lots.country_slot[i] != country_slot) continue;
        total += _lots.count[i];
    }
    return total;
}

void MilitaryCore::transfer_garrison_owner(int32_t cell, int32_t from, int32_t to) {
    military_for_each_lot(*this, (uint8_t)MILITARY_LOT_GARRISON, cell, [&](int32_t i) {
        if (_lots.country_slot[(size_t)i] != from) return;
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

// ============================================================== war score

void MilitaryCore::with_war_score(int32_t war_id, int32_t delta_q16) {
    MilitaryWar *war = find_war(war_id);
    if (war == nullptr) return;
    int64_t total = (int64_t)war->score_battle_q16 + delta_q16;
    war->score_battle_q16 = (int32_t)clamp64(total, -40 * MILITARY_Q16, 40 * MILITARY_Q16);
}

void MilitaryCore::record_battle(int64_t day, int32_t cell, int32_t war_id, int32_t winner,
                                 int32_t loser, int64_t winner_losses, int64_t loser_losses,
                                 int32_t score_gain_q16) {
    MilitaryBattleLogRow row;
    row.day = day;
    row.cell = cell;
    row.war_id = war_id;
    row.winner_slot = winner;
    row.loser_slot = loser;
    row.winner_losses = winner_losses;
    row.loser_losses = loser_losses;
    row.score_gain_q16 = score_gain_q16;
    _battle_log.push_back(row);
    if ((int32_t)_battle_log.size() > MILITARY_BATTLE_LOG_CAPACITY) {
        _battle_log.erase(_battle_log.begin());
    }
    if (MilitaryWar *war = find_war(war_id)) {
        if (winner == war->attacker_slot) {
            war->attacker_losses += winner_losses;
            war->defender_losses += loser_losses;
        } else {
            war->defender_losses += winner_losses;
            war->attacker_losses += loser_losses;
        }
    }
}

int64_t MilitaryCore::war_score(int32_t war_id, int32_t slot) const {
    const MilitaryWar *war = find_war_const(war_id);
    if (war == nullptr || slot < 0) return 0;
    const int32_t sign = slot == war->attacker_slot ? 1 : -1;
    int64_t score = war->score_battle_q16 + war->score_annihilation_q16 + war->score_attrition_q16;
    const int64_t our_losses = sign > 0 ? war->attacker_losses : war->defender_losses;
    const int64_t their_losses = sign > 0 ? war->defender_losses : war->attacker_losses;
    if (our_losses + their_losses > 0) {
        score += mul_div((their_losses - our_losses) * 10 * MILITARY_Q16, 1,
                         our_losses + their_losses);
    }
    score = clamp64(score, -kWarScoreCapQ16, kWarScoreCapQ16);
    return sign > 0 ? score : -score;
}

int64_t MilitaryCore::cell_value_q16(int32_t cell) const {
    if (cell < 0 || cell >= _terrain.cell_count) return 0;
    int64_t value = 0;
    if ((size_t)cell < _terrain.settlement_tier.size()) {
        switch (_terrain.settlement_tier[(size_t)cell]) {
            case 1: value += 20; break;
            case 2: value += 80; break;
            case 3: value += 200; break;
            case 4: value += 400; break;
            default: break;
        }
    }
    if (value <= 0) value = 10;
    return value * MILITARY_Q16;
}

int64_t MilitaryCore::annual_revenue_q16(int32_t slot) const {
    if (slot < 0 || (size_t)slot >= _country_annual_revenue.size()) return 0;
    return _country_annual_revenue[(size_t)slot];
}

int64_t MilitaryCore::country_power(int32_t slot) const {
    int64_t power = 0;
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (!_lots.active[i]) continue;
        if (slot >= 0 && _lots.country_slot[i] != slot) continue;
        power += _lots.count[i];
    }
    return power;
}

int64_t MilitaryCore::annex_price_q16(int32_t receiver, const MilitaryWar &war) const {
    int64_t total = 0;
    const int32_t victim =
        receiver == war.attacker_slot ? war.defender_slot : war.attacker_slot;
    const int32_t cells = _terrain.cell_count;
    for (int32_t cell = 0; cell < cells; ++cell) {
        if (owner_of_cell(_last_digest, cell) != victim) continue;
        total += std::max<int64_t>(2 * MILITARY_Q16, cell_value_q16(cell));
    }
    return total;
}

void MilitaryCore::track_full_occupation(MilitaryWar &war, const MilitaryWorldDigest &digest) {
    const auto assess = [&](int32_t slot) -> int64_t {
        if (slot < 0) return -1;
        bool owns = false;
        bool occupied = false;
        for (int32_t cell = 0; cell < _terrain.cell_count; ++cell) {
            if (owner_of_cell(digest, cell) != slot) continue;
            owns = true;
            if (effective_controller(*this, digest, cell) != slot) {
                occupied = true;
                break;
            }
        }
        if (!owns) return -1;
        return occupied ? digest.day : -1;
    };
    war.fully_occupied_since_a = assess(war.attacker_slot);
    war.fully_occupied_since_b = assess(war.defender_slot);
}

void MilitaryCore::update_war_score(MilitaryWar &war, const MilitaryWorldDigest &digest) {
    // Occupation component (sec 12.2): +-60 scaled by value lost / total value.
    int64_t a_value = 0;
    int64_t b_value = 0;
    int64_t a_lost = 0;
    int64_t b_lost = 0;
    for (int32_t cell = 0; cell < _terrain.cell_count; ++cell) {
        const int32_t owner = owner_of_cell(digest, cell);
        if (owner != war.attacker_slot && owner != war.defender_slot) continue;
        int64_t value = cell_value_q16(cell);
        if ((size_t)cell < digest.cell_population.size()) value += digest.cell_population[(size_t)cell];
        const bool lost = effective_controller(*this, digest, cell) != owner;
        if (owner == war.attacker_slot) {
            a_value += value;
            if (lost) a_lost += value;
        } else {
            b_value += value;
            if (lost) b_lost += value;
        }
    }
    const int64_t total = std::max<int64_t>(a_value + b_value, 1);
    war.score_annihilation_q16 = (int32_t)clamp64(
        mul_div((int64_t)war.score_annihilation_q16 + mul_div(b_lost - a_lost, 60 * MILITARY_Q16, total),
                MILITARY_Q16, 2 * MILITARY_Q16),
        -60 * MILITARY_Q16, 60 * MILITARY_Q16);
    war.score_attrition_q16 = (int32_t)clamp64(war.score_attrition_q16, -10 * MILITARY_Q16,
                                               10 * MILITARY_Q16);
}

// ================================================================ front

void MilitaryCore::update_front_cells(const std::vector<int32_t> &touched_cells) {
    if (touched_cells.empty()) return;
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    const size_t edge_total = (size_t)cells * 6;
    if (_front_edge_set.size() < edge_total) _front_edge_set.assign(edge_total, 0);
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
                _front_edges.push_back((uint32_t)key);
            } else {
                for (size_t i = 0; i < _front_edges.size(); ++i) {
                    if ((int32_t)_front_edges[i] == key) {
                        _front_edges[i] = _front_edges.back();
                        _front_edges.pop_back();
                        break;
                    }
                }
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
    _event_counter_control = 0;
    _last_digest = digest;
    if (_country_annual_revenue.size() < digest.country_annual_revenue.size()) {
        _country_annual_revenue.resize(digest.country_annual_revenue.size(), 0);
    }
    for (size_t slot = 0; slot < digest.country_annual_revenue.size(); ++slot) {
        _country_annual_revenue[slot] = digest.country_annual_revenue[slot];
    }
    // Treaty batches queued by commands flush here, before the daily passes.
    if (!_war_intents.empty()) {
        out.insert(out.end(), _war_intents.begin(), _war_intents.end());
        _report.intents_emitted += (int32_t)_war_intents.size();
        _war_intents.clear();
    }
    // Close wars whose participants no longer exist.
    for (MilitaryWar &war : _wars) {
        if (!war.active) continue;
        if (country_handle_for_slot(war.attacker_slot) == 0 ||
            country_handle_for_slot(war.defender_slot) == 0) {
            war.active = 0;
        }
    }
    for (MilitaryWar &war : _wars) {
        if (!war.active) continue;
        track_full_occupation(war, digest);
        update_war_score(war, digest);
    }
    front_rebuild(digest);
    // Expire old truce rows so the save stays small.
    _truces.erase(std::remove_if(_truces.begin(), _truces.end(),
                                 [&digest](const MilitaryTruce &t) { return t.until_day <= digest.day; }),
                  _truces.end());
}

void MilitaryCore::front_rebuild(const MilitaryWorldDigest &digest) {
    (void)digest;
    // The incremental set is already authoritative; only drop stale keys.
    size_t write = 0;
    for (size_t i = 0; i < _front_edges.size(); ++i) {
        const uint32_t key = _front_edges[i];
        if ((size_t)key < _front_edge_set.size() && _front_edge_set[(size_t)key] != 0) {
            _front_edges[write++] = key;
        }
    }
    if (write != _front_edges.size()) {
        _front_edges.resize(write);
        _front_revision += 1;
    }
    std::sort(_front_edges.begin(), _front_edges.end());
}

// ============================================================ area tasks

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

// ============================================================ reparations

void MilitaryCore::run_reparations(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    if (_reparations.empty()) return;
    for (MilitaryReparation &row : _reparations) {
        if (row.remaining <= 0) continue;
        if (digest.day < row.next_day) continue;
        const int32_t payer_slot = country_slot_for_handle(row.payer);
        const int32_t receiver_slot = country_slot_for_handle(row.receiver);
        if (payer_slot < 0 || receiver_slot < 0) {
            row.remaining = 0;
            continue;
        }
        const int64_t available = (size_t)payer_slot < digest.country_cash.size()
                                      ? digest.country_cash[(size_t)payer_slot]
                                      : 0;
        const int64_t amount = std::min(row.installment, std::max<int64_t>(available, 0));
        MilitaryIntent intent;
        intent.kind = MILITARY_INTENT_TRANSFER_CASH;
        intent.cell = -1;
        intent.country_a = row.payer;
        intent.country_b = row.receiver;
        intent.count = 0;
        intent.amount = amount;
        intent.source_id = (uint64_t)(uint32_t)row.war_id;
        out.push_back(intent);
        ++_report.intents_emitted;
        row.remaining -= 1;
        row.next_day = digest.day + kReparationPeriodDays;
        if (amount < row.installment) {
            row.arrears += row.installment - amount;
            if (row.arrears > kReparationArrearsMultiple * row.installment) {
                // Treaty broken: the war resumes (sec 12.3).
                if (MilitaryWar *war = find_war(row.war_id)) {
                    if (!war->active) {
                        war->active = 1;
                        war->start_day = digest.day;
                        war->fully_occupied_since_a = -1;
                        war->fully_occupied_since_b = -1;
                    }
                }
                row.remaining = 0;
            }
        }
    }
    _reparations.erase(
        std::remove_if(_reparations.begin(), _reparations.end(),
                       [](const MilitaryReparation &r) { return r.remaining <= 0; }),
        _reparations.end());
}

// ================================================================ treaties

MilitaryPeaceEvaluation MilitaryCore::evaluate_peace(int32_t war_id, uint64_t proposer,
                                                     const std::vector<int32_t> &ints,
                                                     const std::vector<int64_t> &longs) const {
    MilitaryPeaceEvaluation evaluation;
    const MilitaryWar *war = find_war_const(war_id);
    if (war == nullptr || !war->active) {
        evaluation.reason = "war_not_found";
        return evaluation;
    }
    const int32_t proposer_slot = country_slot_for_handle(proposer);
    if (proposer_slot < 0) {
        evaluation.reason = "country_not_found";
        return evaluation;
    }
    const bool proposer_is_attacker = proposer_slot == war->attacker_slot;
    if (!proposer_is_attacker && proposer_slot != war->defender_slot) {
        evaluation.reason = "not_a_belligerent";
        return evaluation;
    }
    const int32_t receiver = proposer_is_attacker ? war->defender_slot : war->attacker_slot;
    const int64_t gap = war_score(war_id, proposer_slot) - war_score(war_id, receiver);
    int64_t price_q16 = 0;
    const size_t terms = ints.size() / 3;
    const int64_t revenue = annual_revenue_q16(receiver);
    for (size_t t = 0; t < terms; ++t) {
        const int32_t kind = ints[t * 3 + 0];
        const int32_t a = ints[t * 3 + 1];
        const int64_t amount = t < longs.size() ? longs[t] : 0;
        switch (kind) {
            case MPEACE_WHITE:
                break;
            case MPEACE_CEDE_CELL:
                price_q16 += std::max<int64_t>(2 * MILITARY_Q16, cell_value_q16(a));
                break;
            case MPEACE_ANNEX:
                price_q16 += annex_price_q16(receiver, *war);
                break;
            case MPEACE_LUMP_SUM:
                price_q16 += revenue > 0 ? mul_div(25 * MILITARY_Q16, amount, revenue) : 0;
                break;
            case MPEACE_INSTALLMENTS: {
                const int64_t n = std::max<int64_t>(1, a);
                const int64_t per = revenue > 0 ? mul_div(25 * MILITARY_Q16, amount, revenue) : 0;
                price_q16 += mul_q(mul_div(per, n, 1), 78643);   // x0.75 deferred discount
                break;
            }
            case MPEACE_GOODS:
                price_q16 += revenue > 0 ? mul_div(25 * MILITARY_Q16, amount, revenue) : 0;
                break;
            case MPEACE_RETURN_OCCUPATION:
                price_q16 -= cell_value_q16(a);
                break;
            default:
                break;
        }
    }
    if (price_q16 < 0) price_q16 = 0;
    // Willingness of the receiver (sec 12.3).
    int64_t willing = std::max<int64_t>(0, gap / 2);
    const int64_t war_days = std::max<int64_t>(0, _last_day - war->start_day);
    const int64_t fatigue_q16 = clamp64(mul_div(32768, war_days - kTruceDays, 730), 0, 32768);
    willing = mul_div(willing * MILITARY_Q16, MILITARY_Q16 + fatigue_q16 / 2, MILITARY_Q16);
    const int64_t proposer_power = country_power(proposer_slot);
    const int64_t receiver_power = country_power(receiver);
    if (receiver_power > 0 && receiver_power * 2 < proposer_power) willing += 10 * MILITARY_Q16;
    const int64_t occupied_since =
        receiver == war->attacker_slot ? war->fully_occupied_since_a : war->fully_occupied_since_b;
    if (occupied_since >= 0) {
        willing += 60 * MILITARY_Q16;
        willing += ((_last_day - occupied_since) / 30) * 10 * MILITARY_Q16;
    }
    evaluation.valid = true;
    evaluation.price_q16 = (int32_t)clamp64(price_q16, 0, 100 * MILITARY_Q16);
    evaluation.willing_q16 = (int32_t)clamp64(willing, 0, 400 * MILITARY_Q16);
    evaluation.gap_q16 = (int32_t)clamp64(gap, -200 * MILITARY_Q16, 200 * MILITARY_Q16);
    if (evaluation.willing_q16 >= 100 * MILITARY_Q16) {
        evaluation.acceptance_band = 2;
    } else if (evaluation.willing_q16 >= 40 * MILITARY_Q16) {
        evaluation.acceptance_band = 1;
    } else {
        evaluation.acceptance_band = 0;
    }
    evaluation.reason = "ok";
    return evaluation;
}

void MilitaryCore::execute_treaty(MilitaryWar &war, const std::vector<int32_t> &ints,
                                  const std::vector<int64_t> &longs, int32_t proposer_slot,
                                  int64_t day, std::vector<MilitaryIntent> &out) {
    // sec 12.4: one atomic batch for every term.
    const bool proposer_is_attacker = proposer_slot == war.attacker_slot;
    // The proposer demands the terms (gains); the other side accepts and pays.
    const int32_t receiver = proposer_slot;
    const int32_t payer = proposer_is_attacker ? war.defender_slot : war.attacker_slot;
    const uint64_t receiver_handle = country_handle_for_slot(receiver);
    const uint64_t payer_handle = country_handle_for_slot(payer);
    std::vector<int32_t> ceded;
    const size_t terms = ints.size() / 3;
    bool annex = false;
    int64_t payout = 0;
    for (size_t t = 0; t < terms; ++t) {
        const int32_t kind = ints[t * 3 + 0];
        const int32_t a = ints[t * 3 + 1];
        const int64_t amount = t < longs.size() ? longs[t] : 0;
        switch (kind) {
            case MPEACE_CEDE_CELL:
                if (a >= 0) ceded.push_back(a);
                break;
            case MPEACE_ANNEX:
                annex = true;
                break;
            case MPEACE_LUMP_SUM:
                payout += amount;
                break;
            case MPEACE_INSTALLMENTS: {
                MilitaryReparation row;
                row.payer = payer_handle;
                row.receiver = receiver_handle;
                row.installment = amount;
                row.remaining = std::max<int32_t>(1, a);
                row.next_day = day + kReparationPeriodDays;
                row.war_id = war.id;
                _reparations.push_back(row);
                break;
            }
            case MPEACE_GOODS: {
                MilitaryIntent goods;
                goods.kind = MILITARY_INTENT_TRANSFER_GOODS;
                goods.good = a;
                goods.country_a = payer_handle;
                goods.country_b = receiver_handle;
                goods.count = amount;
                out.push_back(goods);
                break;
            }
            case MPEACE_RETURN_OCCUPATION:
                if (a >= 0) clear_controller(a);
                break;
            default:
                break;
        }
    }
    for (int32_t cell : ceded) {
        MilitaryIntent intent;
        intent.kind = MILITARY_INTENT_TRANSFER_TERRITORY;
        intent.cell = cell;
        intent.country_a = payer_handle;
        intent.country_b = receiver_handle;
        intent.count = 1;   // cession
        out.push_back(intent);
    }
    if (payout > 0) {
        MilitaryIntent cash;
        cash.kind = MILITARY_INTENT_TRANSFER_CASH;
        cash.country_a = payer_handle;
        cash.country_b = receiver_handle;
        cash.amount = payout;
        out.push_back(cash);
    }
    if (annex) {
        MilitaryIntent intent;
        intent.kind = MILITARY_INTENT_ANNEX_COUNTRY;
        intent.country_a = payer_handle;
        intent.country_b = receiver_handle;
        out.push_back(intent);
    }
    // Return the occupation of every cell that was not ceded (sec 12.4.4).
    for (int32_t cell = 0; cell < _terrain.cell_count; ++cell) {
        if (controller_of(cell) != receiver) continue;
        if (owner_of_cell(_last_digest, cell) == receiver) continue;
        clear_controller(cell);
    }
    on_cells_ceded_or_annexed(ceded, receiver);
    // Peace: truce 365 days, every engagement of this war closes (sec 11.1).
    MilitaryTruce truce;
    truce.slot_a = war.attacker_slot;
    truce.slot_b = war.defender_slot;
    truce.until_day = day + kTruceDays;
    _truces.push_back(truce);
    const int32_t war_id = war.id;
    for (MilitaryWar &row : _wars) {
        if (row.id == war_id) row.active = 0;
    }
    for (size_t i = 0; i < _engagements.size(); ++i) {
        if (_engagements[i].war_id == war_id) close_engagement((int32_t)i);
    }
    MilitaryEvent event;
    event.day = day;
    event.type = MILITARY_EVENT_WAR_ENDED;
    event.payload_schema = 20;
    event.cell = -1;
    event.i0 = (uint64_t)(uint32_t)(annex ? 2 : 1);
    event.i1 = (uint64_t)(uint32_t)ceded.size();
    event.i2 = (uint64_t)(uint32_t)war_id;
    event.value = payout;
    push_event(event);
    if (annex) {
        const int32_t victim = payer;
        MilitaryEvent annexed;
        annexed.day = day;
        annexed.type = MILITARY_EVENT_COUNTRY_ANNEXED;
        annexed.payload_schema = 23;
        annexed.i0 = payer_handle;
        annexed.i1 = receiver_handle;
        annexed.i2 = (uint64_t)(uint32_t)ceded.size();
        push_event(annexed);
        // Every other war of the victim ends; its reparations are void (sec 12.5).
        for (MilitaryWar &row : _wars) {
            if (!row.active) continue;
            if (row.attacker_slot != victim && row.defender_slot != victim) continue;
            row.active = 0;
            for (size_t i = 0; i < _engagements.size(); ++i) {
                if (_engagements[i].war_id == row.id) close_engagement((int32_t)i);
            }
        }
        _reparations.erase(std::remove_if(_reparations.begin(), _reparations.end(),
                                          [payer_handle](const MilitaryReparation &r) {
                                              return r.payer == payer_handle;
                                          }),
                           _reparations.end());
    }
    _report.intents_emitted += (int32_t)out.size();
}

} // namespace pk

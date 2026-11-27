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
#include "simulation_math.h"
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
        const int64_t eq = lot_equip_factor_q16(type, core._lots.equip_quality_q8[s],
                                                core._lots.kit_q16[s], core._lots.partial_equipment[s]);
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
    // v5: 民兵训练与筑城科技此前对城防毫无影响（两个 stat 从未被读取）。
    // 现在按控制国的 MSTAT_MILITIA / MSTAT_FORTIFICATION 各乘一次；
    // 没有相关科技时 stat_q16 返回 1.0，行为与改造前一致。
    const int32_t militia_q16 =
        (controller >= 0) ? stat_q16(digest, controller, MSTAT_MILITIA) : MILITARY_Q16;
    const int32_t fort_stat_q16 =
        (controller >= 0) ? stat_q16(digest, controller, MSTAT_FORTIFICATION) : MILITARY_Q16;
    return mul_q(mul_q(mul_q(mul_q(base, best_defence_q16), fort_q16(core, cell)),
                       militia_q16),
                 fort_stat_q16);
}

// Deterministic gaussian sample (Box-Muller on two keyed uniforms).
int32_t gauss_q16(uint64_t seed, uint64_t key, int64_t day, int32_t sigma_q16) {
    const uint64_t r1 = rng(seed, key, day) >> 11;
    const uint64_t r2 = rng(seed, mix_key(key, 0x9e37u), day) >> 11;
    double u1 = (double)r1 / (double)(1ull << 53);
    const double u2 = (double)r2 / (double)(1ull << 53);
    if (u1 < 1e-12) u1 = 1e-12;
    const double radius = std::sqrt(-2.0 * simulation_math::log(u1));
    const double value = radius * simulation_math::cos(6.283185307179586 * u2);
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
        case MCMD_WAR_DECLARE_FORCED:
        case MCMD_WAR_DECLARE: {
            const int32_t attacker = country_slot_for_handle(cmd.country);
            const int32_t defender = country_slot_for_handle(cmd.other);
            if (attacker < 0 || defender < 0 || attacker == defender) return;
            if (at_war(attacker, defender)) return;
            if (truce_active(attacker, defender, day)) return;
            if (cmd.op == MCMD_WAR_DECLARE && country_soldiers(attacker) <= 0)
                return;
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

#include "military_core_war_section_engagements.inc"

// ================================================================ capture

#include "military_core_war_section_occupation.inc"

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

#include "military_core_war_section_fronts.inc"

// ============================================================ area tasks

#include "military_core_war_section_area_missions.inc"

// ============================================================ reparations

#include "military_core_war_section_peace_and_reparations.inc"

} // namespace pk

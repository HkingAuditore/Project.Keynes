#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "pk_log.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace pk {
using namespace godot;

namespace {

constexpr int64_t kMobQ16 = 65536;
// 0.50: below this a profession starts accumulating organization.
constexpr int64_t kMobThetaLowQ16 = 32768;
// Stage gates on organization, then on combined power.
constexpr int64_t kMobStageGate[5] = {0, 19661, 29491, 40632, 51118};
constexpr int64_t kMobTierGate[5] = {0, 16384, 29491, 40632, 52429};
constexpr int64_t kMobBaseHazardQ16 = 6554;      // 10% per epoch at full severity
constexpr int64_t kMobEscalateChanceQ16 = 22938; // 35% per check
constexpr int64_t kMobMaxHazardQ16 = 3277;       // 5% cap
constexpr int64_t kMobTauUpDays = 60;
constexpr int64_t kMobTauDownDays = 35;
constexpr int64_t kMobEmaTauDays = 12;
constexpr int64_t kMobStageDelayDays[5] = {0, 14, 12, 10, 0};
constexpr int64_t kMobStallDelayDays = 10;
constexpr int64_t kMobChainCooldownDays = 240;
constexpr int64_t kMobDormantMobQ16 = 656; // 1%
constexpr int64_t kMobPlayerFlag = 1;
constexpr int64_t kMobCapitalFlag = 2;

uint64_t mob_mix64(uint64_t x) {
    x += 0x9e3779b97f4a7c15ull;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
    return x ^ (x >> 31);
}

uint64_t mob_hash64(int64_t day, int32_t cell, int32_t profession,
                    int32_t stage, uint64_t salt) {
    uint64_t h = 0x243f6a8885a308d3ull;
    h = mob_mix64(h ^ static_cast<uint64_t>(day));
    h = mob_mix64(h ^ (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32 |
                       static_cast<uint32_t>(profession)));
    h = mob_mix64(h ^ static_cast<uint64_t>(static_cast<uint32_t>(stage)));
    h = mob_mix64(h ^ salt);
    return h;
}

int32_t profession_floor_for_id(const std::string &id) {
    // Q16 floors: the peacetime organizing capacity of a profession. These are
    // deliberately content constants, not simulation state; a later profile
    // knob can replace them without changing the row layout.
    if (id == "soldier") return 13107; // 0.20
    if (id == "merchant") return 7864;  // 0.12
    if (id == "artisan" || id == "apprentice" || id == "journeyman" ||
        id == "dyer" || id == "guild_master")
        return 5243; // 0.08
    if (id == "miner" || id == "industrial_worker" ||
        id == "construction_worker" || id == "metallurgist" ||
        id == "machinist" || id == "technician" || id == "electrician" ||
        id == "transport_worker" || id == "petroleum_worker" ||
        id == "chemist")
        return 6554; // 0.10
    if (id == "scholar" || id == "scribe" || id == "lorekeeper" ||
        id == "natural_philosopher" || id == "scientist" ||
        id == "researcher" || id == "engineer" ||
        id == "research_scientist" || id == "data_scientist" ||
        id == "ai_researcher" || id == "agronomist")
        return 3932; // 0.06
    if (id == "serf" || id == "unemployed" || id == "enslaved_laborer" ||
        id == "indentured_laborer" || id == "corvee_worker")
        return 1311; // 0.02
    if (id == "farmer" || id == "subsistence_farmer" ||
        id == "tenant_farmer" || id == "sharecropper" ||
        id == "household_farmer" || id == "pastoralist" || id == "fisher" ||
        id == "hunter" || id == "forager" || id == "agricultural_worker" ||
        id == "aquaculturist" || id == "forestry_worker")
        return 1966; // 0.03
    return 3277;     // 0.05 default
}

int32_t profession_political_weight_for_id(const std::string &id) {
    if (id == "soldier") return 85197;                   // 1.30
    if (id == "merchant" || id == "industrialist" ||
        id == "landlord")
        return 78643;                                    // 1.20
    if (id == "serf" || id == "enslaved_laborer" ||
        id == "indentured_laborer" || id == "corvee_worker")
        return 45875;                                    // 0.70
    return 65536;
}

inline int64_t mob_clamp_q16(int64_t value) {
    return std::clamp<int64_t>(value, 0, kMobQ16 - 1);
}

} // namespace

void NativeEconomyRuntime::ensure_mobilization_profession_config() {
    const std::vector<std::string> &ids = profession_ids();
    if (_profession_mobilization_config_ready.size() == ids.size()) return;
    _profession_mobilization_floor_q16.resize(ids.size());
    _profession_political_weight_q16.resize(ids.size());
    for (size_t i = 0; i < ids.size(); ++i) {
        _profession_mobilization_floor_q16[i] =
            static_cast<uint16_t>(profession_floor_for_id(ids[i]));
        _profession_political_weight_q16[i] =
            static_cast<uint16_t>(profession_political_weight_for_id(ids[i]));
    }
    _profession_mobilization_config_ready.assign(ids.size(), 1);
}

int32_t NativeEconomyRuntime::set_military_cell_garrison(
        const std::vector<int32_t> &cells, const std::vector<int32_t> &heads) {
    const size_t count = std::min(cells.size(), heads.size());
    if (count == 0) return 0;
    const int32_t cell_count = _cell_count.get();
    if (cell_count <= 0) return 0;
    if (_cell_garrison_heads.size() != static_cast<size_t>(cell_count)) {
        _cell_garrison_heads.assign(static_cast<size_t>(cell_count), 0);
        _cell_garrison_present.assign(static_cast<size_t>(cell_count), 0);
    }
    int32_t written = 0;
    for (size_t i = 0; i < count; ++i) {
        const int32_t cell = cells[i];
        if (cell < 0 || cell >= cell_count) continue;
        _cell_garrison_heads[static_cast<size_t>(cell)] = std::max(0, heads[i]);
        _cell_garrison_present[static_cast<size_t>(cell)] = 1;
        ++written;
    }
    return written;
}

void NativeEconomyRuntime::reset_stratum_mobilization() {
    _stratum_mobilization.clear(_cell_count.get());
    _profession_mobilization_floor_q16.clear();
    _profession_political_weight_q16.clear();
    _profession_mobilization_config_ready.clear();
    _cell_garrison_heads.clear();
    _cell_garrison_present.clear();
}

void NativeEconomyRuntime::advance_cell_mobilization(
        int32_t cell, int32_t country, int64_t cell_population,
        int64_t cell_satisfaction, const std::vector<int32_t> &touched,
        const std::vector<int64_t> &profession_population,
        const std::vector<int64_t> &profession_satisfaction) {
    const int32_t cell_count = _cell_count.get();
    if (cell < 0 || cell >= cell_count || country < 0 || cell_population <= 0)
        return;
    ensure_mobilization_profession_config();
    if (_stratum_mobilization.cell_offsets.size() !=
        static_cast<size_t>(cell_count) + 1u) {
        _stratum_mobilization.clear(cell_count);
    }
    const int32_t dt = cell_elapsed_days(cell);
    if (dt <= 0) return;
    const int64_t day = _current_day.get();
    const bool is_player_country = country == _epoch_player_country_slot;
    const bool is_capital =
        country < static_cast<int32_t>(_epoch_country_capital_cells.size()) &&
        _epoch_country_capital_cells[static_cast<size_t>(country)] == cell;
    const int64_t ema_alpha = std::min<int64_t>(
        kMobQ16, static_cast<int64_t>(dt) * kMobQ16 / kMobEmaTauDays);

    for (const int32_t profession : touched) {
        if (profession < 0 ||
            profession >= static_cast<int32_t>(profession_population.size()) ||
            profession >= static_cast<int32_t>(profession_satisfaction.size()))
            continue;
        const int64_t people = profession_population[static_cast<size_t>(profession)];
        if (people <= 0 || people > cell_population) continue;
        const int64_t satisfaction = std::clamp<int64_t>(
            profession_satisfaction[static_cast<size_t>(profession)] / people,
            0, kMobQ16 - 1);
        const int64_t share = people * kMobQ16 / cell_population;
        const int64_t other_people = cell_population - people;
        const int64_t other_satisfaction = other_people > 0
            ? std::clamp<int64_t>((cell_satisfaction -
                   profession_satisfaction[static_cast<size_t>(profession)]) /
                       other_people, 0, kMobQ16 - 1)
            : satisfaction;

        int32_t row_index = _stratum_mobilization.find(cell, profession);
        if (row_index < 0) {
            // A peaceful profession does not get a row at all. This is the
            // performance contract: only aggrieved cells grow the table.
            if (satisfaction >= kMobThetaLowQ16) continue;
            row_index = _stratum_mobilization.ensure(cell, profession, cell_count);
            if (row_index < 0) continue;
            StratumMobilizationRow &created =
                _stratum_mobilization.rows[static_cast<size_t>(row_index)];
            created.owner_slot = country;
            created.satisfaction_ema_q16 = static_cast<uint16_t>(satisfaction);
            created.mobilization_q16 = 0;
        }
        StratumMobilizationRow &row =
            _stratum_mobilization.rows[static_cast<size_t>(row_index)];
        if (row.owner_slot != country) {
            // Territory changed hands: the local organization is not portable.
            row.owner_slot = country;
            row.mobilization_q16 = 0;
            row.stage = 0;
            row.next_check_day = 0;
            row.cooldown_until_day = static_cast<int32_t>(day + 90);
            row.trauma_q16 = 0;
            row.satisfaction_ema_q16 = static_cast<uint16_t>(satisfaction);
        }
        int64_t ema = row.satisfaction_ema_q16;
        ema += (satisfaction - ema) * ema_alpha / kMobQ16;
        ema = mob_clamp_q16(ema);
        row.satisfaction_ema_q16 = static_cast<uint16_t>(ema);
        row.share_q16 = static_cast<uint16_t>(std::clamp<int64_t>(share, 0, kMobQ16 - 1));
        row.local_sat_q16 = static_cast<uint16_t>(
            std::clamp<int64_t>(other_satisfaction, 0, kMobQ16 - 1));

        int64_t grievance = 0;
        if (ema < kMobThetaLowQ16)
            grievance = (kMobThetaLowQ16 - ema) * kMobQ16 / kMobThetaLowQ16;
        const int64_t floor = profession >= static_cast<int32_t>(
                _profession_mobilization_floor_q16.size())
            ? 3277
            : _profession_mobilization_floor_q16[static_cast<size_t>(profession)];
        const int64_t influence = std::min<int64_t>(kMobQ16, share * 4);
        int64_t capacity = floor +
            (kMobQ16 - floor) * grievance / kMobQ16 *
                (39322 + 26214 * influence / kMobQ16) / kMobQ16;
        capacity += row.trauma_q16 / 2;
        capacity = mob_clamp_q16(capacity);

        int64_t mobilization = row.mobilization_q16;
        const int64_t tau = capacity >= mobilization ? kMobTauUpDays : kMobTauDownDays;
        mobilization += (capacity - mobilization) * dt / tau;
        mobilization = mob_clamp_q16(mobilization);
        row.mobilization_q16 = static_cast<uint16_t>(mobilization);

        // Combined impact: organization plus how much of the cell is aggrieved.
        int64_t power = mobilization *
            (36045 + 29491 * influence / kMobQ16) / kMobQ16;
        power += 13107 * (kMobQ16 - row.local_sat_q16) / kMobQ16;
        power = std::clamp<int64_t>(power, 0, kMobQ16 - 1);

        const int32_t previous_stage = row.stage;
        int32_t stage = row.stage;
        if (stage == 0) {
            if (mobilization >= kMobStageGate[1] &&
                day >= row.cooldown_until_day) {
                const int64_t severity =
                    (mobilization - kMobStageGate[1]) * kMobQ16 /
                    (kMobQ16 - kMobStageGate[1]);
                int64_t hazard = kMobBaseHazardQ16 * severity / kMobQ16;
                const int64_t weight = profession < static_cast<int32_t>(
                        _profession_political_weight_q16.size())
                    ? _profession_political_weight_q16[static_cast<size_t>(profession)]
                    : kMobQ16;
                hazard = hazard * std::min<int64_t>(kMobQ16 * 2, share * 4) /
                    kMobQ16;
                hazard = hazard * weight / kMobQ16;
                hazard = hazard *
                    (39322 + 26214 * (kMobQ16 - row.local_sat_q16) / kMobQ16) /
                    kMobQ16;
                hazard = std::min<int64_t>(kMobMaxHazardQ16, hazard * dt);
                if (hazard > 0 &&
                    static_cast<int64_t>(mob_hash64(day, cell, profession, 0,
                        0x5354524154554dULL) % kMobQ16) < hazard) {
                    stage = 1;
                    row.last_event_day = static_cast<int32_t>(day);
                    row.next_check_day =
                        static_cast<int32_t>(day + kMobStageDelayDays[1]);
                }
            }
        } else if (day >= row.next_check_day) {
            bool escalated = false;
            if (stage < 4 && mobilization >= kMobStageGate[stage + 1] &&
                power >= kMobTierGate[stage + 1] &&
                static_cast<int64_t>(mob_hash64(day, cell, profession, stage,
                    0x455343414c415445ULL) % kMobQ16) < kMobEscalateChanceQ16) {
                ++stage;
                escalated = true;
            }
            row.next_check_day = static_cast<int32_t>(
                day + (escalated ? kMobStageDelayDays[stage] : kMobStallDelayDays));
            if (escalated) row.last_event_day = static_cast<int32_t>(day);
        }
        // The capital is a political anchor: it can be blockaded and protested,
        // but it never becomes an independence event.
        if (is_capital && stage > 3) stage = 3;
        // AI countries resolve their own stage transition immediately: no popup,
        // just a deterministic repression/ignore decision. Applying the result
        // also emits the fact, so the block below skips its own fact for AI.
        bool ai_resolved = false;
        if (!is_player_country && stage != previous_stage) {
            row.stage = static_cast<uint8_t>(stage);
            row.mobilization_q16 = static_cast<uint16_t>(mobilization);
            const bool has_garrison =
                cell >= 0 && static_cast<size_t>(cell) < _cell_garrison_heads.size() &&
                _cell_garrison_heads[static_cast<size_t>(cell)] > 0;
            const int32_t ai_action = has_garrison ? 2 : 3;
            const bool ai_success = has_garrison &&
                (mob_hash64(day, cell, profession, stage,
                            0x41495245534f4c56ULL) % 2) == 0;
            apply_mobilization_result(cell, profession, ai_action, ai_success);
            stage = row.stage;
            mobilization = row.mobilization_q16;
            ai_resolved = true;
        }
        const uint8_t pending_independence = row.flags & 8;
        row.stage = static_cast<uint8_t>(stage);
        row.mobilization_q16 = static_cast<uint16_t>(mobilization);
        row.flags = static_cast<uint8_t>(
            (is_player_country ? kMobPlayerFlag : 0) |
            (is_capital ? kMobCapitalFlag : 0) |
            pending_independence);
        if (stage != previous_stage && !ai_resolved) {
            CommittedGameplayFact fact;
            fact.kind = GAMEPLAY_FACT_STRATUM_MOBILIZATION;
            fact.cell = cell;
            fact.entity_id = static_cast<int32_t>(std::clamp<int64_t>(
                people, 0, std::numeric_limits<int32_t>::max()));
            fact.value = static_cast<int64_t>(row.mobilization_q16);
            fact.payload = {stage, previous_stage, profession, country};
            fact.flags = static_cast<int32_t>(
                (is_player_country ? kMobPlayerFlag : 0) |
                (is_capital ? kMobCapitalFlag : 0) |
                pending_independence);
            _staging_gameplay_facts.push_back(fact);
        }
        // Dormant row cleanup: no chain and no measurable organization.
        if (stage == 0 && row.mobilization_q16 <= kMobDormantMobQ16 &&
            row.satisfaction_ema_q16 >= kMobThetaLowQ16) {
            _stratum_mobilization.erase_at(row_index, cell_count);
        }
    }
}

Dictionary NativeEconomyRuntime::cell_mobilization_snapshot(int32_t cell) const {
    Dictionary out;
    out["ok"] = false;
    if (cell < 0 || cell >= _cell_count.get() ||
        _stratum_mobilization.cell_offsets.size() !=
            static_cast<size_t>(_cell_count.get()) + 1u) {
        out["reason"] = "cell_out_of_range_or_unavailable";
        return out;
    }
    Array rows;
    const int32_t begin = _stratum_mobilization.cell_offsets[static_cast<size_t>(cell)];
    const int32_t end = _stratum_mobilization.cell_offsets[static_cast<size_t>(cell) + 1u];
    for (int32_t i = begin; i < end; ++i) {
        const StratumMobilizationRow &row =
            _stratum_mobilization.rows[static_cast<size_t>(i)];
        Dictionary item;
        item["profession"] = static_cast<int32_t>(row.profession);
        item["mobilization_q16"] = static_cast<int32_t>(row.mobilization_q16);
        item["satisfaction_ema_q16"] = static_cast<int32_t>(row.satisfaction_ema_q16);
        item["share_q16"] = static_cast<int32_t>(row.share_q16);
        item["local_sat_q16"] = static_cast<int32_t>(row.local_sat_q16);
        item["stage"] = static_cast<int32_t>(row.stage);
        item["flags"] = static_cast<int32_t>(row.flags);
        item["cooldown_until_day"] = row.cooldown_until_day;
        item["next_check_day"] = row.next_check_day;
        item["trauma_q16"] = static_cast<int32_t>(row.trauma_q16);
        rows.push_back(item);
    }
    out["ok"] = true;
    out["cell_index"] = cell;
    out["rows"] = rows;
    out["row_count"] = rows.size();
    return out;
}

Dictionary NativeEconomyRuntime::country_mobilization_summary(
        int32_t country_slot) const {
    Dictionary out;
    out["ok"] = false;
    if (country_slot < 0 || country_slot >= _epoch_country_count) {
        out["reason"] = "country_slot_invalid";
        return out;
    }
    int32_t stage_counts[5] = {0, 0, 0, 0, 0};
    Array top_cells;
    int32_t total = 0;
    for (const StratumMobilizationRow &row : _stratum_mobilization.rows) {
        if (row.owner_slot != country_slot) continue;
        ++total;
        const int32_t stage = std::clamp<int32_t>(row.stage, 0, 4);
        ++stage_counts[stage];
        if (row.stage > 0 && top_cells.size() < 8) {
            Dictionary item;
            item["cell"] = row.cell;
            item["profession"] = static_cast<int32_t>(row.profession);
            item["stage"] = stage;
            item["mobilization_q16"] = static_cast<int32_t>(row.mobilization_q16);
            top_cells.push_back(item);
        }
    }
    out["ok"] = true;
    out["country_slot"] = country_slot;
    out["row_count"] = total;
    PackedInt32Array counts;
    for (int32_t i = 0; i < 5; ++i) counts.push_back(stage_counts[i]);
    out["stage_counts"] = counts;
    out["top_cells"] = top_cells;
    return out;
}

Dictionary NativeEconomyRuntime::mobilization_odds(
        int32_t cell, int32_t profession, int32_t action,
        int64_t spend_bp) const {
    Dictionary out;
    out["ok"] = false;
    const int32_t row_index =
        _stratum_mobilization.find(cell, profession);
    if (row_index < 0 ||
        row_index >= static_cast<int32_t>(_stratum_mobilization.rows.size())) {
        out["reason"] = "mobilization_row_missing";
        return out;
    }
    const StratumMobilizationRow &row =
        _stratum_mobilization.rows[static_cast<size_t>(row_index)];
    const int32_t stage = std::clamp<int32_t>(row.stage, 0, 4);
    int64_t cell_population = 0;
    if (cell >= 0 && static_cast<size_t>(cell) < _committed_cells.size())
        cell_population = std::max<int64_t>(
            0, _committed_cells[static_cast<size_t>(cell)].population);
    if (cell_population <= 0) {
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            cell_population += std::max<int64_t>(
                0, population_store().population[static_cast<size_t>(slot)]);
        });
    }
    const int64_t share = row.share_q16;
    const int64_t rebel_pop = cell_population * share / kMobQ16;
    const int64_t need = std::max<int64_t>(1, rebel_pop * 5 / 100);
    int64_t garrison = 0;
    if (cell >= 0 &&
        static_cast<size_t>(cell) < _cell_garrison_heads.size())
        garrison = std::max<int64_t>(0, _cell_garrison_heads[
            static_cast<size_t>(cell)]);
    const int64_t ration = cell >= 0 &&
            static_cast<size_t>(cell) < _military_ration_sat_q16.size()
        ? _military_ration_sat_q16[static_cast<size_t>(cell)] : kMobQ16;
    int64_t g_strength = std::min<int64_t>(
        kMobQ16, garrison * kMobQ16 / need);
    g_strength = g_strength *
        (32768 + 32768 * std::clamp<int64_t>(ration, 0, kMobQ16) / kMobQ16) /
        kMobQ16;
    const bool soldier_revolt =
        profession >= 0 && profession < static_cast<int32_t>(
            profession_ids().size()) &&
        profession_ids()[static_cast<size_t>(profession)] == "soldier";
    if (soldier_revolt) {
        // The garrison is the rebels: it neither suppresses nor stays neutral.
        g_strength = 0;
    }

    const int64_t family_backing = mobilization_family_backing_q16(cell);

    // Cost is expressed as a share of the treasury so it scales with the
    // economy; the service converts cost_bp to cash with the same coefficient.
    static constexpr int64_t kCostBp[5] = {0, 50, 125, 250, 500};
    const int64_t cost_bp = kCostBp[stage];
    int64_t base = 0;
    switch (action) {
        case 0: base = 36045; break;   // concede
        case 1: base = 29491; break;   // bribe
        case 2: base = 22938; break;   // repress
        case 4: base = 32768; break;   // amnesty
        default: base = -1; break;     // ignore/abandon have no roll
    }
    if (base < 0) {
        out["ok"] = true;
        out["no_roll"] = true;
        out["p_success_q16"] = 0;
        out["cost_bp"] = cost_bp;
        out["stage"] = stage;
        out["terms"] = Dictionary();
        return out;
    }
    const int64_t local_term =
        (static_cast<int64_t>(row.local_sat_q16) - 32768) * 70 / 100;
    const int64_t garrison_term = g_strength * 25 / 100;
    const int64_t family_term = family_backing * 25 / 100;
    const int64_t spend_ratio = cost_bp > 0
        ? std::min<int64_t>(kMobQ16, spend_bp * kMobQ16 / cost_bp)
        : 0;
    int64_t cost_term = spend_ratio * 15 / 100;
    cost_term = std::min<int64_t>(16384, cost_term);
    const int64_t org_term = static_cast<int64_t>(row.mobilization_q16) * 35 / 100;
    const int64_t share_term = std::min<int64_t>(kMobQ16, share * 4) * 15 / 100;
    int64_t probability = base + local_term + garrison_term + family_term +
        cost_term - org_term - share_term;
    if (soldier_revolt) {
        // A garrison revolt is the one case where local troops make it worse.
        probability -= 16384;
    }
    probability = std::clamp<int64_t>(probability, 3277, 62259);

    Dictionary terms;
    terms["base_q16"] = base;
    terms["local_sat_q16"] = local_term;
    terms["garrison_q16"] = garrison_term;
    terms["family_q16"] = family_term;
    terms["cost_q16"] = cost_term;
    terms["org_q16"] = -org_term;
    terms["share_q16"] = -share_term;
    out["ok"] = true;
    out["no_roll"] = false;
    out["p_success_q16"] = probability;
    out["cost_bp"] = cost_bp;
    out["stage"] = stage;
    out["mobilization_q16"] = static_cast<int32_t>(row.mobilization_q16);
    out["family_backing_q16"] = static_cast<int32_t>(family_backing);
    out["garrison_strength_q16"] = static_cast<int32_t>(g_strength);
    out["soldier_revolt"] = soldier_revolt;
    out["terms"] = terms;
    return out;
}

bool NativeEconomyRuntime::apply_mobilization_result(
        int32_t cell, int32_t profession, int32_t action, bool success) {
    const int32_t row_index = _stratum_mobilization.find(cell, profession);
    if (row_index < 0) return false;
    StratumMobilizationRow &row =
        _stratum_mobilization.rows[static_cast<size_t>(row_index)];
    const int64_t day = _current_day.get();
    const int32_t previous_stage = row.stage;
    int64_t mobilization = row.mobilization_q16;
    int64_t trauma = row.trauma_q16;
    int32_t stage = std::clamp<int32_t>(row.stage, 0, 4);
    const bool ignored = action == 3;
    if (ignored) success = false;
    if (success) {
        switch (action) {
            case 0: // concede
                mobilization -= stage >= 3 ? 29491 : (stage == 2 ? 22938 : 16384);
                stage = std::max(0, stage - 1);
                row.cooldown_until_day = static_cast<int32_t>(day + 180);
                break;
            case 1: // bribe
                mobilization -= stage >= 2 ? 19661 : 9830;
                stage = std::max(0, stage - 1);
                row.cooldown_until_day = static_cast<int32_t>(day + 120);
                break;
            case 2: // repress
                mobilization -= stage >= 4 ? 45875 : (stage == 3 ? 22938 :
                                    (stage == 2 ? 16384 : 13107));
                trauma += stage >= 3 ? 6554 : 3277;
                stage = std::max(0, stage - 1);
                row.cooldown_until_day = static_cast<int32_t>(day + 180);
                break;
            case 4: // amnesty
                mobilization = 0;
                stage = 0;
                row.cooldown_until_day = static_cast<int32_t>(day + 240);
                break;
            case 5: // abandon the cell
                mobilization = 0;
                stage = 0;
                row.cooldown_until_day = static_cast<int32_t>(day + 240);
                row.flags |= 8; // independence pending, the service creates it
                break;
            default:
                return false;
        }
    } else {
        mobilization += stage >= 3 ? 13107 : (stage == 2 ? 6554 : 3277);
        if (action == 2) trauma += 6554;
        if (stage < 4) ++stage;
        row.next_check_day = static_cast<int32_t>(day + 7);
        if (stage >= 4 && (action == 2 || action == 5)) {
            const bool capital =
                row.owner_slot >= 0 &&
                row.owner_slot < static_cast<int32_t>(
                    _epoch_country_capital_cells.size()) &&
                _epoch_country_capital_cells[
                    static_cast<size_t>(row.owner_slot)] == cell;
            if (!capital) row.flags |= 8;
        }
    }
    row.mobilization_q16 = static_cast<uint16_t>(mob_clamp_q16(mobilization));
    row.stage = static_cast<uint8_t>(std::clamp(stage, 0, 4));
    row.trauma_q16 = static_cast<uint16_t>(std::clamp<int64_t>(trauma, 0, kMobQ16 - 1));
    row.last_event_day = static_cast<int32_t>(day);
    if (stage != previous_stage || (row.flags & 8) != 0) {
        CommittedGameplayFact fact;
        fact.kind = GAMEPLAY_FACT_STRATUM_MOBILIZATION;
        fact.cell = cell;
        fact.entity_id = 0;
        fact.value = static_cast<int64_t>(row.mobilization_q16);
        fact.payload = {row.stage, previous_stage, profession, row.owner_slot};
        fact.flags = static_cast<int32_t>(row.flags);
        _staging_gameplay_facts.push_back(fact);
    }
    return true;
}

} // namespace pk

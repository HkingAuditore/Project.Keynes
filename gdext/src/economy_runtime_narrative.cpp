#include "economy_runtime.h"

#include "runtime_narrative_context.h"

namespace pk {

void NativeEconomyRuntime::sample_narrative_cell(NarrativeCellView &out, bool detailed) const {
    const int32_t cell = out.cell;
    if (!_bootstrapped || cell < 0 || cell >= _cell_count.get()) return;
    out.detailed = detailed;
    out.settlement = settlement_name_for_cell(cell);
    if (out.settlement.empty()) out.settlement = "地块 " + std::to_string(cell + 1);

    const auto &population = population_store();
    const auto &professions = profession_ids();
    int64_t largest = 0, weighted = 0, saturation = 0;
    int32_t lowest = 65536;
    std::vector<std::string> profession_order;
    population.for_each_in_cell(cell, [&](int32_t slot) {
        const int64_t people = std::max<int64_t>(0, population.population[slot]);
        const uint64_t handle = population.handle_for_slot(slot);
        if (!handle || people <= 0) return;
        out.population = saturating_add(out.population, people, saturation);
        weighted = saturating_add(weighted, saturating_mul(
            population.composite_satisfaction[slot], people, saturation), saturation);
        const int32_t profession = _signatures[population.signature_id[slot]].profession_id;
        const std::string id = profession >= 0 && size_t(profession) < professions.size()
            ? professions[profession] : std::string();
        if (people > largest) {
            largest = people;
            out.primary_cohort = handle;
            out.primary_profession = id;
        }
        if (!detailed) return;
        lowest = std::min<int32_t>(lowest, population.needs_satisfaction[slot]);
        const int64_t unemployed = std::max<int64_t>(0, people -
            population.owner_employed[slot] - population.employee_employed[slot]);
        out.unemployment += unemployed;
        const int64_t in_kind = population.epoch_in_kind_income[slot];
        const int64_t income = saturating_add(population.epoch_income[slot], in_kind, saturation);
        const int64_t expense = saturating_add(population.epoch_expense[slot], in_kind, saturation);
        if (unemployed < people && expense > 0 &&
            mul_div_sat(income, Q16_ONE, expense, saturation) < Q16_ONE / 2)
            out.subsistence_shortfall += people;
        if (!id.empty()) {
            const auto entry = out.profession_population.try_emplace(id, 0);
            if (entry.second) profession_order.push_back(id);
            entry.first->second += people;
        }
    });
    out.satisfaction = double(out.population > 0 ?
        std::clamp<int64_t>(weighted / out.population, 0, Q16_ONE - 1) : Q16_ONE - 1) / Q16_ONE;
    out.neediest_satisfaction = double(lowest) / Q16_ONE;
    int64_t dominant = 0;
    for (const auto &id : profession_order) {
        const int64_t people = out.profession_population.at(id);
        if (people > dominant) {
            dominant = people;
            out.dominant_profession = id;
        }
    }

    if (!detailed || _family_cell_offsets.size() != size_t(_cell_count.get()) + 1) return;
    const auto &families = families_store();
    const int32_t begin = _family_cell_offsets[cell], end = _family_cell_offsets[cell + 1];
    int32_t family = -1;
    for (int32_t pos = begin; pos < end; ++pos) {
        const int32_t candidate = _family_cell_indices[pos];
        const uint64_t handle = families.handle_for_index(candidate);
        const int64_t people = family_population(handle);
        if (family < 0 || people > out.family_population ||
            (people == out.family_population && families.stable_id[candidate] < families.stable_id[family])) {
            family = candidate;
            out.family = handle;
            out.family_population = people;
        }
    }
    if (family < 0) return;
    out.family_count = std::min(8, end - begin);
    out.family_buildings = family_owned_buildings(out.family);
    out.notables = _person_family_offsets.size() == families.active.size() + 1 ?
        _person_family_offsets[family + 1] - _person_family_offsets[family] : 0;
    const auto &influences = family_influences();
    for (size_t branch = 0; branch < influences.active.size(); ++branch) {
        if (influences.active[branch] && influences.family_handle[branch] == out.family &&
            influences.cell[branch] == cell) {
            out.prestige = influences.prestige_level[branch];
            break;
        }
    }
    const int32_t surname = families.surname_id[family];
    const int32_t culture = families.culture_group_id[family];
    const auto value = [](const auto &column, int32_t index, const char *fallback) {
        return index >= 0 && size_t(index) < column.size() ?
            godot::String::utf8(column[index].c_str()) : godot::String::utf8(fallback);
    };
    auto stem = value(_family_surname_text, surname, "").strip_edges();
    if (stem.is_empty()) stem = "家族";
    const auto origin = godot::String::utf8(settlement_name_for_cell(families.origin_cell[family]).c_str()).strip_edges();
    const auto format = value(_family_culture_group_naming_formats, culture, "CITY_SURNAME_SUFFIX");
    const auto suffix = value(_family_culture_group_suffixes, culture, "氏");
    if (origin.is_empty()) {
        if (format == "CITY_SURNAME_SUFFIX" && !suffix.is_empty() && !stem.ends_with(suffix))
            stem += suffix;
    } else if (format == "CITY_SEPARATOR_SURNAME") {
        stem = origin + value(_family_culture_group_separators, culture, "-") + stem;
    } else {
        stem = origin + stem;
        if (format != "CITY_SURNAME") stem += suffix;
    }
    out.family_name = stem.utf8().get_data();
    for (const auto &roll : family_trait_rolls()) {
        if (roll.family_handle != out.family || roll.trait_id < 0 ||
            size_t(roll.trait_id) >= _family_trait_ids.size()) continue;
        out.family_traits.insert(_family_trait_ids[roll.trait_id]);
        out.family_trait_names.push_back(_family_trait_display_names[roll.trait_id]);
    }
}

bool NativeEconomyRuntime::narrative_unrest_rows(
        int32_t cell, std::vector<NarrativeUnrestRow> &out) const {
    out.clear();
    if (cell < 0 || cell >= _cell_count.get() ||
        _stratum_mobilization.cell_offsets.size() != size_t(_cell_count.get()) + 1)
        return false;
    for (int32_t index = _stratum_mobilization.cell_offsets[cell];
            index < _stratum_mobilization.cell_offsets[cell + 1]; ++index) {
        const auto &row = _stratum_mobilization.rows[index];
        out.push_back({cell, row.profession, row.stage, row.flags, row.cooldown_until_day});
    }
    return true;
}

namespace economy_api {
void sample_narrative_cell(const NativeEconomyRuntime &economy, NarrativeCellView &out, bool detailed) {
    economy.sample_narrative_cell(out, detailed);
}
bool narrative_unrest_rows(const NativeEconomyRuntime &economy, int32_t cell,
        std::vector<NarrativeUnrestRow> &out) {
    return economy.narrative_unrest_rows(cell, out);
}
NarrativeUnrestOdds narrative_unrest_odds(const NativeEconomyRuntime &economy,
        int32_t cell, int32_t profession, int32_t action) {
    return economy.calculate_mobilization_odds(cell, profession, action, 0, nullptr);
}
bool settle_narrative_unrest(NativeEconomyRuntime &economy, int32_t cell,
        int32_t profession, int32_t action, bool success) {
    return economy.apply_mobilization_result(cell, profession, action, success);
}
const std::vector<std::string> &narrative_professions(const NativeEconomyRuntime &economy) {
    return economy.profession_ids();
}
} // namespace economy_api
} // namespace pk

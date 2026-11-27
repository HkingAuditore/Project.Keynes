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
            out.primary_cash = population.funds[slot];
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

    if (_building_cell_offsets.size() == size_t(_cell_count.get()) + 1) {
        const int32_t first = _building_cell_offsets[cell], last = _building_cell_offsets[cell + 1];
        for (int32_t index = first; index < last; ++index) {
            const auto group = building_at(index);
            if (group.cell != cell || group.count <= 0) continue;
            out.building_counts[_building_type_ids[group.type_id]] += group.count;
            out.buildings += group.count;
        }
    }
    const auto &market = market_store();
    const int32_t local_market = market.cell_to_market[cell];
    out.market_id = local_market;
    out.has_local_merchant = local_market >= 0 &&
        size_t(local_market) < _merchant_primary_slot.size() &&
        _merchant_primary_slot[local_market] >= 0;
    if (local_market >= 0 && local_market < market.market_count.get()) {
        for (size_t good = 0; good < _good_ids.size(); ++good) {
            const auto lane = market.index(local_market, good);
            const auto &id = _good_ids[good];
            out.market_stocks.emplace(id, market.stock[lane]);
            if (_good_default_price[good] <= 0) continue;
            const double ratio = double(market.price[lane]) / _good_default_price[good];
            out.market_prices.emplace(id, ratio);
            if (ratio > out.max_price_ratio) {
                out.max_price_ratio = ratio;
                out.expensive_good = id;
            }
        }
    }
    for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
        const size_t lane = resource * _cell_count.get() + cell;
        if (_worker_resource_seeded && lane < _worker_resource_reserve.size())
            out.resources.emplace(_resource_ids[resource], _worker_resource_reserve[lane]);
        else if (lane < resource_stock_lanes().size())
            out.resources.emplace(_resource_ids[resource], double(resource_stock_lanes()[lane]) / GOODS_SCALE);
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
            out.prestige_q16 = influences.score_q16[branch];
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

std::vector<NarrativeEconomyNotice> NativeEconomyRuntime::narrative_economy_notices(
        int64_t day, uint64_t country) const {
    using Notice = NarrativeEconomyNotice;
    std::vector<Notice> notices;
    for (const auto &row : _committed_construction_receipts)
        if (row.settled_day == day && row.country_handle == country)
            notices.push_back({Notice::CONSTRUCTION, row.cell});
    for (const auto &row : _canal_receipts)
        if (row.settled_day == day && row.country_handle == country)
            notices.push_back({Notice::INFRASTRUCTURE, -1});
    for (const auto &row : _colonization_receipts)
        if (row.settled_day == day && row.country_handle == country)
            notices.push_back({Notice::COLONIZATION, row.target_cell});
    if (_commit_day == day)
        for (int32_t cell : _population_changed_cells)
            notices.push_back({Notice::POPULATION, cell});
    return notices;
}

namespace economy_api {
void sample_narrative_cell(const NativeEconomyRuntime &economy, NarrativeCellView &out, bool detailed) {
    economy.sample_narrative_cell(out, detailed);
}
std::vector<NarrativeEconomyNotice> narrative_economy_notices(
        const NativeEconomyRuntime &economy, int64_t day, uint64_t country) {
    return economy.narrative_economy_notices(day, country);
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
int32_t clear_cell_independence(NativeEconomyRuntime &economy, int32_t cell) {
    return economy.clear_cell_mobilization_independence(cell);
}
const std::vector<std::string> &narrative_professions(const NativeEconomyRuntime &economy) {
    return economy.profession_ids();
}
} // namespace economy_api
} // namespace pk

namespace pk {

int32_t NativeEconomyRuntime::resolve_family_trait_command(int32_t operation, uint64_t handle,
        const std::string &key, int32_t strength, int64_t day, std::string &error) const {
    const auto trait = std::lower_bound(_family_trait_ids.begin(), _family_trait_ids.end(), key);
    int32_t family = -1;
    if (operation < 1 || operation > 3 || trait == _family_trait_ids.end() || *trait != key ||
            !families_store().valid_handle(handle, family) || day < 0) {
        error = "family_trait_command_entry_invalid";
        return -1;
    }
    const int32_t id = static_cast<int32_t>(trait - _family_trait_ids.begin());
    const int32_t minimum = _family_trait_strength_min_q16[id];
    if (operation != 2 && (strength < minimum || strength > _family_trait_strength_max_q16[id] ||
            (strength - minimum) % _family_trait_strength_step_q16[id] != 0)) {
        error = "family_trait_command_strength_invalid";
        return -1;
    }
    return id;
}

bool NativeEconomyRuntime::submit_effect_family_trait(uint64_t family, const std::string &trait,
        bool grant, int32_t strength, int64_t day, int64_t sequence) {
    if (!_configured) return false;
    if (grant) {
        const auto found = std::lower_bound(_family_trait_ids.begin(), _family_trait_ids.end(), trait);
        if (found == _family_trait_ids.end() || *found != trait) return false;
        const size_t index = found - _family_trait_ids.begin();
        const int32_t minimum = _family_trait_strength_min_q16[index];
        const int32_t maximum = _family_trait_strength_max_q16[index];
        const int32_t step = _family_trait_strength_step_q16[index];
        const int32_t offset = std::clamp(strength, minimum, maximum) - minimum;
        strength = minimum + std::min((offset + step / 2) / step, (maximum - minimum) / step) * step;
    }
    const int32_t operation = grant ? 1 : 2;
    std::string error;
    const int32_t id = resolve_family_trait_command(operation, family, trait, strength, day, error);
    if (id < 0) return false;
    _family_trait_commands.push_back({operation, family, id, strength, day, 100,
        sequence, ++_next_submit_order});
    return true;
}

bool economy_api::submit_effect_family_trait(NativeEconomyRuntime &economy, uint64_t family,
        const std::string &trait, bool grant, int32_t strength, int64_t day, int64_t sequence) {
    return economy.submit_effect_family_trait(family, trait, grant, strength, day, sequence);
}

} // namespace pk

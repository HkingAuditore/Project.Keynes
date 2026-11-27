#include "runtime_narrative_catalog.h"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace pk {
using namespace godot;

namespace {

std::vector<std::string> keys(const Variant &raw) {
    std::vector<std::string> result;
    if (raw.get_type() == Variant::PACKED_STRING_ARRAY) {
        const PackedStringArray list = raw;
        for (int32_t i = 0; i < list.size(); ++i) result.push_back(narrative_key(list[i]));
    } else if (raw.get_type() == Variant::ARRAY) {
        const Array list = raw;
        for (int32_t i = 0; i < list.size(); ++i) result.push_back(narrative_key(list[i]));
    }
    return result;
}

std::vector<int32_t> integers(const Variant &raw) {
    std::vector<int32_t> result;
    if (raw.get_type() == Variant::PACKED_INT32_ARRAY) {
        const PackedInt32Array list = raw;
        for (int32_t i = 0; i < list.size(); ++i) result.push_back(list[i]);
    } else if (raw.get_type() == Variant::ARRAY) {
        const Array list = raw;
        for (int32_t i = 0; i < list.size(); ++i) result.push_back(static_cast<int32_t>(list[i]));
    }
    return result;
}

template <typename Map>
int64_t count_for(const Map &map, const std::string &key) {
    const auto entry = map.find(key);
    return entry == map.end() ? 0 : entry->second;
}

enum Condition : int32_t {
    ALWAYS_TRUE, TEMP_GTE, TEMP_LTE, MOISTURE_GTE, MOISTURE_LTE,
    PRECIP_GTE, PRECIP_LTE, SNOW_GTE, ELEVATION_GTE, ELEVATION_LTE,
    HAS_RIVER, IS_COASTAL, OCEAN_CURRENT_SPEED_GTE, OCEAN_UPWELLING_GTE,
    TERRAIN_IN, LANDFORM_IN, VEGETATION_IN, POPULATION_GTE, POPULATION_LTE,
    SATISFACTION_GTE, SATISFACTION_LTE, HAS_BUILDING_TYPE, BUILDING_COUNT_GTE,
    MARKET_GOOD_SHORTAGE, MARKET_GOOD_STOCK_GTE, MARKET_GOOD_STOCK_LTE,
    MARKET_GOOD_PRICE_RATIO_GTE, HAS_NATURAL_RESOURCE, HAS_TECHNOLOGY,
    LACKS_TECHNOLOGY, TREASURY_CASH_GTE, TREASURY_CASH_LTE, ERA_GTE, ERA_LTE,
    HAS_STORY_FLAG, LACKS_STORY_FLAG, SUBSISTENCE_SHORTFALL_GTE, UNEMPLOYMENT_GTE,
    PROFESSION_SHARE_GTE, COHORT_SATISFACTION_LTE, HAS_NOTABLE_FAMILY,
    FAMILY_PRESTIGE_GTE, FAMILY_POP_SHARE_GTE, FAMILY_OWNS_BUILDINGS_GTE,
    HAS_FAMILY_TRAIT, AT_WAR, SOLDIERS_TOTAL_GTE, WAR_GOING_BADLY
};

bool read_leaf(const NarrativeConditionProgram::Leaf &leaf,
        const NarrativeCountryView &country, const NarrativeCellView &cell,
        const NarrativeFlagReader &flag) {
    const auto member = [&](int32_t value) {
        return std::find(leaf.values.begin(), leaf.values.end(), value) != leaf.values.end();
    };
    const auto ratio = [&](int64_t count) { return double(count) / double(cell.denominator()); };
    switch (leaf.op) {
        case ALWAYS_TRUE: return true;
        case TEMP_GTE: return cell.temperature >= leaf.threshold;
        case TEMP_LTE: return cell.temperature <= leaf.threshold;
        case MOISTURE_GTE: return cell.moisture >= leaf.threshold;
        case MOISTURE_LTE: return cell.moisture <= leaf.threshold;
        case PRECIP_GTE: return cell.precipitation >= leaf.threshold;
        case PRECIP_LTE: return cell.precipitation <= leaf.threshold;
        case SNOW_GTE: return cell.snow >= leaf.threshold;
        case ELEVATION_GTE: return cell.elevation >= leaf.threshold;
        case ELEVATION_LTE: return cell.elevation <= leaf.threshold;
        case HAS_RIVER: return cell.river == leaf.boolean;
        case IS_COASTAL: return cell.coastal == leaf.boolean;
        case OCEAN_CURRENT_SPEED_GTE: return cell.current >= leaf.threshold;
        case OCEAN_UPWELLING_GTE: return cell.upwelling >= leaf.threshold;
        case TERRAIN_IN: return member(cell.terrain);
        case LANDFORM_IN: return member(cell.landform);
        case VEGETATION_IN: return member(cell.vegetation);
        case POPULATION_GTE: return cell.population >= leaf.integer;
        case POPULATION_LTE: return cell.population <= leaf.integer;
        case SATISFACTION_GTE: return cell.satisfaction >= leaf.threshold;
        case SATISFACTION_LTE: return cell.satisfaction <= leaf.threshold;
        case HAS_BUILDING_TYPE: return count_for(cell.building_counts, leaf.key) > 0;
        case MARKET_GOOD_SHORTAGE: return cell.price_ratio(leaf.key) >= 1.30;
        case HAS_NATURAL_RESOURCE: {
            const auto resource = cell.resources.find(leaf.key);
            return resource != cell.resources.end() &&
                resource->second >= std::max<int64_t>(1, leaf.integer);
        }
        case BUILDING_COUNT_GTE:
            return (leaf.key.empty() ? cell.buildings : count_for(cell.building_counts, leaf.key))
                >= leaf.integer;
        case MARKET_GOOD_STOCK_GTE: return cell.stock(leaf.key) >= leaf.integer;
        case MARKET_GOOD_STOCK_LTE: return cell.stock(leaf.key) <= leaf.integer;
        case MARKET_GOOD_PRICE_RATIO_GTE: return cell.price_ratio(leaf.key) >= leaf.threshold;
        case HAS_TECHNOLOGY: return country.technologies.count(leaf.key) != 0;
        case LACKS_TECHNOLOGY: return country.technologies.count(leaf.key) == 0;
        case TREASURY_CASH_GTE: return country.treasury_cash >= leaf.integer;
        case TREASURY_CASH_LTE: return country.treasury_cash <= leaf.integer;
        case ERA_GTE: return country.era >= leaf.integer;
        case ERA_LTE: return country.era <= leaf.integer;
        case HAS_STORY_FLAG: return flag(leaf.key);
        case LACKS_STORY_FLAG: return !flag(leaf.key);
        case SUBSISTENCE_SHORTFALL_GTE: return ratio(cell.subsistence_shortfall) >= leaf.threshold;
        case UNEMPLOYMENT_GTE: return ratio(cell.unemployment) >= leaf.threshold;
        case PROFESSION_SHARE_GTE: return ratio(count_for(cell.profession_population, leaf.key)) >= leaf.threshold;
        case COHORT_SATISFACTION_LTE: return cell.neediest_satisfaction <= leaf.threshold;
        case HAS_NOTABLE_FAMILY:
            return (cell.family != 0 && (cell.notables >= 1 || cell.prestige >= 1)) == leaf.boolean;
        case FAMILY_PRESTIGE_GTE: return cell.family != 0 && cell.prestige >= leaf.integer;
        case FAMILY_POP_SHARE_GTE:
            return cell.family != 0 && std::min(1.0, ratio(cell.family_population)) >= leaf.threshold;
        case FAMILY_OWNS_BUILDINGS_GTE: return cell.family != 0 && cell.family_buildings >= leaf.integer;
        case HAS_FAMILY_TRAIT:
            return cell.family != 0 && !leaf.key.empty() &&
                (cell.family_traits.count(leaf.key) != 0) == leaf.boolean;
        case AT_WAR: return country.at_war == leaf.boolean;
        case SOLDIERS_TOTAL_GTE: return country.military_available && country.soldiers >= leaf.integer;
        case WAR_GOING_BADLY: return (country.at_war && country.war_score <= -32768) == leaf.boolean;
        default: return false;
    }
}

} // namespace

std::string narrative_key(const Variant &value) {
    return String(value).utf8().get_data();
}

uint64_t narrative_hash(uint64_t seed, int64_t day, uint64_t country, int64_t cell, int64_t salt) {
    static constexpr uint64_t mask = 0x7fffffffffffffffULL;
    const auto mix = [](uint64_t value) {
        uint64_t z = (value + 0x6a09e667f3bcc908ULL) & mask;
        z = ((z ^ (z >> 30)) * 0x517cc1b727220a95ULL) & mask;
        z = ((z ^ (z >> 27)) * 0x2545f4914f6cdd1dULL) & mask;
        return z ^ (z >> 31);
    };
    uint64_t h = mix(0x1f83d9abfb41bd6bULL ^ (seed & mask));
    h = mix(h ^ ((day * 0x3c6ef372fe94f82bULL) & mask));
    h = mix(h ^ ((country * 0x5be0cd19137e2179ULL) & mask));
    h = mix(h ^ ((cell * 0x517cc1b727220a95ULL) & mask));
    return mix(h ^ ((salt * 0x2545f4914f6cdd1dULL) & mask));
}

int32_t narrative_roll(uint64_t seed, int64_t day, uint64_t country, int64_t cell, int64_t salt) {
    return static_cast<int32_t>((narrative_hash(seed, day, country, cell, salt) >> 16) & 65535);
}

bool NarrativeConditionProgram::matches(const NarrativeCountryView &country,
        const NarrativeCellView &cell, const NarrativeFlagReader &flag_present) const {
    return code.empty() || evaluate_trigger_conditions<4>(code.size(),
        [&](size_t index) { return code[index].instruction; },
        [&](size_t index, bool &value) {
            value = read_leaf(code[index], country, cell, flag_present);
            return true;
        });
}

NarrativeConditionProgram RuntimeNarrativeCatalog::compile_conditions(const Array &conditions) const {
    NarrativeConditionProgram result;
    for (int32_t i = 0; i < conditions.size(); ++i) {
        const Dictionary raw = conditions[i];
        NarrativeConditionProgram::Leaf leaf;
        leaf.op = raw.get("op", 0);
        leaf.key = narrative_key(raw.get("target_key", ""));
        leaf.integer = raw.get("int_value", 0);
        leaf.boolean = raw.get("bool_value", true);
        leaf.threshold = raw.get("float_value", 0.0);
        if (leaf.op == SATISFACTION_GTE || leaf.op == SATISFACTION_LTE ||
            leaf.op == COHORT_SATISFACTION_LTE) {
            if (std::abs(leaf.threshold) < 0.00001 && leaf.integer > 0)
                leaf.threshold = static_cast<double>(leaf.integer);
            if (leaf.threshold > 100.0) leaf.threshold /= 65536.0;
            else if (leaf.threshold > 1.0001) leaf.threshold /= 100.0;
        }
        const PackedStringArray *names = leaf.op == TERRAIN_IN ? &terrain_names :
            leaf.op == LANDFORM_IN ? &landform_names :
            leaf.op == VEGETATION_IN ? &vegetation_names : nullptr;
        if (names != nullptr) {
            leaf.values = integers(raw.get("int_list", Array()));
            auto accepted_names = keys(raw.get("string_list", Array()));
            if (leaf.values.empty() && accepted_names.empty() && !leaf.key.empty())
                accepted_names.push_back(leaf.key);
            for (int32_t index = 0; index < names->size(); ++index) {
                const String name = (*names)[index].to_lower();
                for (const auto &allowed : accepted_names) {
                    if (name == String(allowed.c_str()).to_lower()) leaf.values.push_back(index);
                }
            }
        }
        result.code.push_back(std::move(leaf));
        if (bool(raw.get("negated", false))) {
            NarrativeConditionProgram::Leaf negate;
            negate.instruction = RuntimeTriggerConditionOp::BOOL_NOT;
            result.code.push_back(std::move(negate));
        }
        if (i != 0) {
            NarrativeConditionProgram::Leaf unite;
            unite.instruction = RuntimeTriggerConditionOp::BOOL_AND;
            result.code.push_back(std::move(unite));
        }
    }
    return result;
}

NarrativeEffect compile_narrative_effect(const Dictionary &effect) {
    NarrativeEffect result;
    result.kind = effect.get("kind", 0);
    result.key = narrative_key(String(effect.get("target_key", "")).strip_edges());
    result.tag = narrative_key(effect.get("tag_key", ""));
    result.value = effect.get("int_value", 0);
    result.ratio = std::clamp<int64_t>(effect.get("ratio_bp", 0), -5000, 5000);
    if (result.kind == NarrativeEffect::ADD_POPULATION)
        result.value = std::clamp<int64_t>(result.value, -5000, 5000);
    result.duration = std::clamp<int64_t>(effect.get("duration_days", 90), 1, 1825);
    result.magnitude = std::clamp<int64_t>(effect.get("magnitude_q16", 65536), 655, 131072);
    if (result.kind == NarrativeEffect::WEIGHT_BIAS)
        result.value = std::clamp<int64_t>(result.value, -500, 1000);
    result.cell_scope = effect.get("scope_to_cell", true);
    result.radius = effect.get("radius_cells", 0);
    result.falloff = int32_t(effect.get("falloff", 0)) > 0;
    result.ai_prompt = effect.get("ai_followup_prompt", "");
    result.label = effect.get("description", effect.get("custom_label", ""));
    return result;
}

NarrativeDefinition RuntimeNarrativeCatalog::compile_event(const Dictionary &raw) const {
    NarrativeDefinition result;
    const String id = raw.get("event_id", "");
    result.id = narrative_key(id);
    result.salt = id.hash();
    result.channel = raw.get("trigger_channel", 2);
    result.fact = raw.get("fact_event_type", 0);
    result.scope = raw.get("scope", 0);
    result.base_weight = raw.get("base_weight", 100);
    result.chance = raw.get("trigger_chance_q16", 65536);
    result.cooldown = raw.get("cooldown_days", 0);
    result.min_era = raw.get("min_era_index", 0);
    result.max_era = raw.get("max_era_index", 10);
    result.one_shot = raw.get("one_shot", false);
    result.category = std::clamp<int32_t>(raw.get("event_category", 7), 0, 7);
    result.notification = result.id == "evt.chain.ancient_foundry_legacy" ||
        bool(raw.get("event_notification", false));
    result.tags = keys(raw.get("tags", Array()));
    result.required_tech = keys(raw.get("required_technologies", Array()));
    result.blocked_tech = keys(raw.get("blocked_technologies", Array()));
    result.prerequisites = keys(raw.get("required_events_completed", Array()));
    result.required_flags = keys(raw.get("required_story_flags", Array()));
    result.blocked_flags = keys(raw.get("blocked_story_flags", Array()));
    result.conditions = compile_conditions(raw.get("conditions", Array()));
    const Array weights = raw.get("weight_rules", Array());
    for (int32_t i = 0; i < weights.size(); ++i) {
        const Dictionary source = weights[i];
        Array condition;
        if (source.has("condition")) condition.push_back(source["condition"]);
        result.weights.push_back({compile_conditions(condition),
            int32_t(source.get("add_weight", 0)), int32_t(source.get("multiplier_q16", 65536))});
    }
    const Array effects = raw.get("on_trigger_effects", Array());
    for (int32_t i = 0; i < effects.size(); ++i)
        result.on_trigger.push_back(compile_narrative_effect(effects[i]));
    const Array options = raw.get("options", Array());
    for (int32_t i = 0; i < options.size(); ++i) {
        const Dictionary option = options[i];
        result.options.push_back({int64_t(option.get("require_treasury_cash", 0)),
            int64_t(option.get("require_good_qty", 0)),
            narrative_key(option.get("require_good_id", "")),
            narrative_key(option.get("require_technology", "")),
            option.get("require_good_name", ""), option.get("probabilities", PackedInt32Array())});
    }
    result.presentation = raw.duplicate(true);
    return result;
}

bool RuntimeNarrativeCatalog::configure(const Dictionary &packet) {
    terrain_names = packet.get("terrain_names", PackedStringArray());
    landform_names = packet.get("landform_names", PackedStringArray());
    vegetation_names = packet.get("vegetation_names", PackedStringArray());
    era_names = packet.get("era_names", PackedStringArray());
    era_milestones = integers(packet.get("era_milestones", Array()));
    month_lengths = integers(packet.get("month_lengths", Array()));
    technology_ids = keys(packet.get("technology_ids", Array()));
    good_ids = keys(packet.get("good_ids", Array()));
    signal_ids = keys(packet.get("signal_ids", Array()));
    profession_names = Dictionary(packet.get("profession_names", Dictionary())).duplicate();
    unrest_profession_names = Dictionary(packet.get("unrest_profession_names", Dictionary())).duplicate();
    ai_fact_hints = Dictionary(packet.get("ai_fact_hints", Dictionary())).duplicate();
    good_names = Dictionary(packet.get("good_names", Dictionary())).duplicate();
    technology_names = Dictionary(packet.get("technology_names", Dictionary())).duplicate();
    const Array definitions = packet.get("events", Array());
    for (int32_t index = 0; index < definitions.size(); ++index)
        events.push_back(compile_event(definitions[index]));
    const Array authored_probes = packet.get("probes", Array());
    for (int32_t index = 0; index < authored_probes.size(); ++index) {
        const Dictionary probe = authored_probes[index];
        probes.push_back({narrative_key(probe.get("state_id", "")),
            probe.get("display_name", ""), probe.get("prompt_hint", ""),
            int32_t(probe.get("dwell_days", 0)), int32_t(probe.get("cooldown_days", 0)),
            int32_t(probe.get("min_era_index", 0)), int32_t(probe.get("max_era_index", 10)),
            compile_conditions(probe.get("conditions", Array()))});
    }
    const Array templates = packet.get("unrest", Array());
    const Array actions = packet.get("unrest_actions", Array());
    if (events.empty() || templates.size() != 12 || actions.size() != 4 || month_lengths.empty())
        return false;
    for (size_t i = 0; i < 4; ++i) {
        unrest_actions[i] = integers(actions[static_cast<int32_t>(i)]);
        for (size_t kind = 0; kind < unrest.size(); ++kind)
            unrest[kind][i] = compile_event(templates[static_cast<int32_t>(kind * 4 + i)]);
    }
    return true;
}

const NarrativeDefinition *RuntimeNarrativeCatalog::find(const std::string &id) const {
    const auto result = std::find_if(events.begin(), events.end(),
        [&](const auto &event) { return event.id == id; });
    return result == events.end() ? nullptr : &*result;
}

} // namespace pk

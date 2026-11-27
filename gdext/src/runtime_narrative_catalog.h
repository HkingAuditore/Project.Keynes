#pragma once

#include "runtime_narrative_context.h"
#include "runtime_trigger_conditions.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <array>
#include <functional>
#include <string>
#include <vector>

namespace pk {

using NarrativeFlagReader = std::function<bool(const std::string &)>;

struct NarrativeConditionProgram {
    struct Leaf {
        RuntimeTriggerConditionOp instruction = RuntimeTriggerConditionOp::PUSH_TRUE;
        int32_t op = 0;
        int64_t integer = 0;
        double threshold = 0;
        bool boolean = true;
        std::string key;
        std::vector<int32_t> values;
    };
    std::vector<Leaf> code;
    bool matches(const NarrativeCountryView &country, const NarrativeCellView &cell,
                 const NarrativeFlagReader &flag_present) const;
};

struct NarrativeEffect {
    enum Kind {
        CITY_MODIFIER = 1, COUNTRY_MODIFIER, TREASURY_CASH_TO_COHORT,
        COHORT_CASH_TO_TREASURY, COUNTRY_GOOD_TO_MARKET, MARKET_GOOD_TO_COUNTRY,
        MARKET_ADD_STOCK, MARKET_REMOVE_STOCK, DISCOVER_RESEARCH_SIGNAL, SET_FLAG,
        CLEAR_FLAG, WEIGHT_BIAS, SCHEDULE, GRANT_TRAIT, REMOVE_TRAIT, ADD_POPULATION
    };
    int32_t kind = 0;
    std::string key, tag;
    godot::String label, ai_prompt;
    int64_t value = 0, ratio = 0, duration = -1, magnitude = 65536;
    int32_t radius = 0;
    bool cell_scope = true, falloff = false;
};

struct NarrativeOptionRule {
    int64_t cash = 0, quantity = 0;
    std::string good, technology;
    godot::String good_name;
    godot::PackedInt32Array probabilities;
};

struct NarrativeDefinition {
    std::string id;
    uint32_t salt = 0;
    int32_t channel = 2, fact = 0, scope = 0;
    int32_t base_weight = 100, chance = 65536, cooldown = 0;
    int32_t min_era = 0, max_era = 10;
    uint8_t category = 7;
    bool one_shot = false, notification = false;
    std::vector<std::string> tags, required_tech, blocked_tech, prerequisites;
    std::vector<std::string> required_flags, blocked_flags;
    NarrativeConditionProgram conditions;
    struct Weight {
        NarrativeConditionProgram conditions;
        int32_t add = 0, factor = 65536;
    };
    std::vector<Weight> weights;
    std::vector<NarrativeEffect> on_trigger;
    std::vector<NarrativeOptionRule> options;
    godot::Dictionary presentation;
};

struct NarrativeProbe {
    std::string id;
    godot::String description, prompt;
    int32_t dwell = 0, cooldown = 0, min_era = 0, max_era = 10;
    NarrativeConditionProgram conditions;
};

class RuntimeNarrativeCatalog {
public:
    // Player-approved interval between sampling and settlement.
    static constexpr int64_t AI_REPLY_DELAY_DAYS = 90;

    bool configure(const godot::Dictionary &packet);
    NarrativeDefinition compile_event(const godot::Dictionary &definition) const;
    const NarrativeDefinition *find(const std::string &id) const;
    godot::PackedStringArray terrain_names, landform_names, vegetation_names, era_names;
    std::vector<int32_t> era_milestones;
    std::vector<std::string> technology_ids, good_ids, signal_ids;
    godot::Dictionary profession_names, unrest_profession_names, ai_fact_hints;
    godot::Dictionary good_names, technology_names;
    std::vector<NarrativeDefinition> events;
    std::vector<NarrativeProbe> probes;
    std::array<std::array<NarrativeDefinition, 4>, 3> unrest;
    std::array<std::vector<int32_t>, 4> unrest_actions;
    std::vector<int32_t> month_lengths;
private:
    NarrativeConditionProgram compile_conditions(const godot::Array &conditions) const;
};

NarrativeEffect compile_narrative_effect(const godot::Dictionary &effect);
std::string narrative_key(const godot::Variant &value);
uint64_t narrative_hash(uint64_t seed, int64_t day, uint64_t country, int64_t cell, int64_t salt);
int32_t narrative_roll(uint64_t seed, int64_t day, uint64_t country, int64_t cell, int64_t salt);

} // namespace pk

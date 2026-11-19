#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace pk {

struct NarrativeCountryView {
    uint64_t handle = 0;
    int32_t slot = -1;
    int32_t capital = -1;
    int32_t era = 0;
    int64_t treasury_cash = 0;
    int64_t soldiers = 0, soldiers_in_armies = 0;
    int32_t war_count = 0;
    bool military_available = false;
    bool at_war = false;
    int64_t war_score = 0;
    int64_t war_losses = 0;
    std::string name;
    std::vector<int32_t> territory;
    std::unordered_set<std::string> technologies;
    std::unordered_map<std::string, int64_t> treasury_goods;
};

struct NarrativeCellView {
    int32_t cell = -1;
    int32_t terrain = 2, landform = 4, vegetation = 0, cover = 0;
    int64_t population = 0;
    double temperature = 18.0, moisture = 0.5, elevation = 0.5;
    double snow = 0.0, precipitation = 0.0, current = 0.0, upwelling = 0.0;
    bool river = false, coastal = false;
    double satisfaction = 0.65, neediest_satisfaction = 1.0;
    bool detailed = false;
    int64_t unemployment = 0, subsistence_shortfall = 0;
    uint64_t primary_cohort = 0;
    std::string primary_profession, dominant_profession;
    std::unordered_map<std::string, int64_t> profession_population;
    std::string settlement;
    uint64_t family = 0;
    int32_t prestige = 0, notables = 0, family_count = 0;
    int64_t family_population = 0, family_buildings = 0;
    std::string family_name;
    std::vector<std::string> family_trait_names;
    std::unordered_set<std::string> family_traits;
    std::vector<int32_t> nearby[2];

    // The old sample did not read the live stock, building, resource or
    // cohort-cash columns. Preserve those results until the effects migration.
    double price_ratio(const std::string &) const { return 1.0; }
    int64_t denominator() const { return population > 0 ? population : 1; }
};

struct NarrativeUnrestRow {
    int32_t cell = -1, profession = -1, stage = 0, flags = 0, cooldown = 0;
};
struct NarrativeUnrestOdds {
    int32_t probability = 32768;
    int32_t cost_bp = 0;
};

} // namespace pk

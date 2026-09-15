#include "runtime_economy_live_tables.h"

#include <algorithm>
#include <cstdint>

namespace pk {

void EconomyFamilyStore::clear() {
    active.clear(); generation.clear(); stable_id.clear(); surname_id.clear();
    surname_disambiguator.clear(); founded_day.clear(); home_cell.clear();
    origin_cell.clear(); origin_ethnicity.clear(); culture_group_id.clear();
    split_sequence.clear(); decline_reviews.clear(); flags.clear();
    free_indices.clear(); active_count = 0;
}

int32_t EconomyFamilyStore::allocate() {
    int32_t index = -1;
    if (!free_indices.empty()) {
        const auto reusable = std::min_element(free_indices.begin(), free_indices.end());
        index = *reusable;
        free_indices.erase(reusable);
    } else {
        index = static_cast<int32_t>(active.size());
        active.push_back(0); generation.push_back(1); stable_id.push_back(0);
        surname_id.push_back(-1); surname_disambiguator.push_back(0);
        founded_day.push_back(-1); home_cell.push_back(-1); origin_cell.push_back(-1);
        origin_ethnicity.push_back(-1); culture_group_id.push_back(-1);
        split_sequence.push_back(0); decline_reviews.push_back(0);
        flags.push_back(0);
    }
    active[index] = 1;
    stable_id[index] = 0; surname_id[index] = -1;
    surname_disambiguator[index] = 0; founded_day[index] = -1;
    home_cell[index] = -1; origin_cell[index] = -1;
    origin_ethnicity[index] = -1; culture_group_id[index] = -1;
    split_sequence[index] = 0;
    decline_reviews[index] = 0; flags[index] = 0;
    ++active_count;
    return index;
}

void EconomyFamilyStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return;
    active[index] = 0;
    generation[index] = generation[index] == UINT32_MAX ? 1 : generation[index] + 1;
    free_indices.push_back(index);
    --active_count;
}

uint64_t EconomyFamilyStore::handle_for_index(int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return 0;
    return (static_cast<uint64_t>(generation[index]) << 32) |
        static_cast<uint32_t>(index);
}

bool EconomyFamilyStore::valid_handle(uint64_t handle,
                                      int32_t &index_out) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= active.size() || active[index] == 0 || generation[index] != gen)
        return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

} // namespace pk

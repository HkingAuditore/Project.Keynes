#pragma once

// Public peer surface; each free function forwards to one runtime member.
#include <cstdint>
#include <string>
#include "derived_cell_layer.h"

namespace pk {
class ModifierRuntime;
struct ModifierApi {
    enum Domain : int32_t { CLIMATE = 0, COUNTRY = 1, ECONOMY = 2, GAMEPLAY = 3, DOMAIN_COUNT = 4 };
};

namespace modifier_api {
// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
double effective_value(const ModifierRuntime &modifier, int32_t domain, int32_t stat_id, uint64_t entity_handle, uint64_t group_handle, double base_value);
double effective_value(const ModifierRuntime &modifier, int32_t domain, const char *stat_key, uint64_t entity_handle, uint64_t group_handle, double base_value);
int32_t stat_id_for_key(const ModifierRuntime &modifier, const std::string &key);
const DerivedCellFront *derived_cell_front(const ModifierRuntime &modifier);
} // namespace modifier_api
} // namespace pk

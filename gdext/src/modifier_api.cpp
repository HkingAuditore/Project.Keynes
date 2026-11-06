// One-line forwards; no policy or state belongs in this adapter.
#include "modifier_api.h"
#include "modifier_runtime.h"

namespace pk {
namespace modifier_api {
// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
double effective_value(const ModifierRuntime &modifier, int32_t domain, int32_t stat_id, uint64_t entity_handle, uint64_t group_handle, double base_value) { return modifier.effective_value(domain, stat_id, entity_handle, group_handle, base_value); }
double effective_value(const ModifierRuntime &modifier, int32_t domain, const char *stat_key, uint64_t entity_handle, uint64_t group_handle, double base_value) { return modifier.effective_value(domain, stat_key, entity_handle, group_handle, base_value); }
int32_t stat_id_for_key(const ModifierRuntime &modifier, const std::string &key) { return modifier.stat_id_for_key(key); }
const DerivedCellFront *derived_cell_front(const ModifierRuntime &modifier) { return modifier.derived_cell_front(); }
} // namespace modifier_api
} // namespace pk

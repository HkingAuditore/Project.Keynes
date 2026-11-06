// One-line forwards; no policy or state belongs in this adapter.
#include "country_api.h"
#include "country_runtime.h"

namespace pk {
namespace country_api {
// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
bool copy_economy_snapshot(const NativeCountryRuntime &country, CountryEconomySnapshot &out) { return country.copy_economy_snapshot(out); }
int64_t cash_for_slot(const NativeCountryRuntime &country, int32_t country_slot) { return country.cash_for_slot(country_slot); }
bool has_technology(const NativeCountryRuntime &country, int32_t country_slot, int32_t technology_id) { return country.has_technology(country_slot, technology_id); }
int32_t country_slot_for_cell(const NativeCountryRuntime &country, int32_t cell) { return country.country_slot_for_cell(cell); }
bool valid_handle(const NativeCountryRuntime &country, int64_t handle) { return country.valid_handle(handle); }
int64_t last_committed_day(const NativeCountryRuntime &country) { return country.last_committed_day(); }
bool sync_store_writes_forbidden(const NativeCountryRuntime &country) { return country.sync_store_writes_forbidden(); }
} // namespace country_api
} // namespace pk

#pragma once

// Public peer surface; each free function forwards to one runtime member.
#include "country_read_view.h"

namespace pk {
class NativeCountryRuntime;
struct CountryApi {};
using CountryEconomySnapshot = CountryReadView::Snapshot;

namespace country_api {
// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
bool copy_economy_snapshot(const NativeCountryRuntime &country, CountryEconomySnapshot &out);
int64_t cash_for_slot(const NativeCountryRuntime &country, int32_t country_slot);
bool has_technology(const NativeCountryRuntime &country, int32_t country_slot, int32_t technology_id);
int32_t country_slot_for_cell(const NativeCountryRuntime &country, int32_t cell);
bool valid_handle(const NativeCountryRuntime &country, int64_t handle);
int64_t last_committed_day(const NativeCountryRuntime &country);
bool sync_store_writes_forbidden(const NativeCountryRuntime &country);
} // namespace country_api
} // namespace pk

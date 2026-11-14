// One-line forwards; no policy or state belongs in this adapter.
#include "country_api.h"
#include "country_runtime.h"

namespace pk {
namespace country_api {
// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
bool copy_economy_snapshot(const NativeCountryRuntime &country, CountryEconomySnapshot &out) { return country.copy_economy_snapshot(out); }
int64_t cash_for_slot(const NativeCountryRuntime &country, int32_t country_slot) { return country.cash_for_slot(country_slot); }
bool has_technology(const NativeCountryRuntime &country, int32_t country_slot, int32_t technology_id) { return country.has_technology(country_slot, technology_id); }
uint32_t political_regime_capabilities(const NativeCountryRuntime &country, int32_t country_slot) { return country.political_regime_capabilities_for_slot(country_slot); }
int32_t political_regime_id(const NativeCountryRuntime &country, int32_t country_slot) { return country.political_regime_id_for_slot(country_slot); }
int32_t country_slot_for_cell(const NativeCountryRuntime &country, int32_t cell) { return country.country_slot_for_cell(cell); }
bool valid_handle(const NativeCountryRuntime &country, int64_t handle) { return country.valid_handle(handle); }
int64_t last_committed_day(const NativeCountryRuntime &country) { return country.last_committed_day(); }
bool sync_store_writes_forbidden(const NativeCountryRuntime &country) { return country.sync_store_writes_forbidden(); }

// ---- Economy (economy_runtime.cpp, economy_runtime_annual.cpp, economy_runtime_building_employment.cpp, economy_runtime_building_investment.cpp, economy_runtime_building_production.cpp, economy_runtime_colonization_kit.cpp, economy_runtime_diagnostics.cpp, economy_runtime_fiscal.cpp, economy_runtime_internal_external_types.inc, economy_runtime_market.cpp, economy_runtime_military_view.cpp, economy_runtime_persistence_read.cpp, economy_runtime_persistence_write.cpp, economy_runtime_procurement.cpp, economy_runtime_queries_market_building.cpp, economy_runtime_trade.cpp, runtime_economy_army_personnel.cpp)
CountryReadView read_view(const NativeCountryRuntime &country) { return country.read_view(); }
CountryFiscalReturnPort fiscal_return_port(NativeCountryRuntime &country) { return country.fiscal_return_port(); }
CountryProcurementPort procurement_port(NativeCountryRuntime &country) { return country.procurement_port(); }
bool economy_available(const NativeCountryRuntime &country) { return country.economy_available(); }
int64_t country_handle_for_cell(const NativeCountryRuntime &country, int32_t cell) { return country.country_handle_for_cell(cell); }

// ---- Effect (effect_runtime.cpp)
bool submit_effect_commands_pod(NativeCountryRuntime &country, const CountryEffectCommand *commands, size_t count, std::vector<int64_t> &request_ids, std::string &error) { return country.submit_effect_commands_pod(commands, count, request_ids, error); }
void drain_effect_host_command_receipts(NativeCountryRuntime &country) { country.drain_effect_host_command_receipts(); }
bool effect_command_result_pod(const NativeCountryRuntime &country, int64_t request_id, bool &complete, bool &ok, std::string &reason) { return country.effect_command_result_pod(request_id, complete, ok, reason); }
godot::Dictionary country_snapshot(const NativeCountryRuntime &country, int64_t handle) { return country.country_snapshot(handle); }
godot::Dictionary treasury_snapshot(const NativeCountryRuntime &country, int64_t handle) { return country.treasury_snapshot(handle); }
godot::Dictionary research_snapshot(const NativeCountryRuntime &country, int64_t handle) { return country.research_snapshot(handle); }
godot::Dictionary research_signal_snapshot(const NativeCountryRuntime &country, int64_t handle) { return country.research_signal_snapshot(handle); }
void set_era_reward_reference_pod(NativeCountryRuntime &country, int64_t plan_id, int64_t offer_generation, int32_t milestone_technology, int32_t status) { country.set_era_reward_reference_pod(plan_id, offer_generation, milestone_technology, status); }
CountryApi::EraRewardReference era_reward_reference_pod(const NativeCountryRuntime &country) { return country.era_reward_reference_pod(); }
int64_t world_seed(const NativeCountryRuntime &country) { return country.world_seed(); }

// ---- Ideology (ideology_runtime.cpp)
bool has_research_signal(const NativeCountryRuntime &country, int32_t country_slot, int32_t signal_id) { return country.has_research_signal(country_slot, signal_id); }

// ---- Modifier (modifier_runtime.cpp): reuses valid_handle from the Military group.
} // namespace country_api
} // namespace pk

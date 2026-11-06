// One-line forwards; no policy or state belongs in this adapter.
#include "modifier_api.h"
#include "modifier_runtime.h"

#include <utility>

namespace pk {
namespace modifier_api {
// ---- Country checkpoint staging (country_runtime.cpp)
void ModifierRuntimeDeleter::operator()(ModifierRuntime *runtime) const { delete runtime; }
ModifierRuntimeCopy copy_runtime(const ModifierRuntime &source) {
    return ModifierRuntimeCopy(new ModifierRuntime(source));
}
void replace_runtime(ModifierRuntime &live, ModifierRuntime &&staged) { live = std::move(staged); }
void attach_country_runtime(ModifierRuntime &modifier, void *runtime) { modifier.attach_country_runtime(static_cast<NativeCountryRuntime *>(runtime)); }
void attach_economy_runtime(ModifierRuntime &modifier, void *runtime) { modifier.attach_economy_runtime(static_cast<NativeEconomyRuntime *>(runtime)); }

// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
double effective_value(const ModifierRuntime &modifier, int32_t domain, int32_t stat_id, uint64_t entity_handle, uint64_t group_handle, double base_value) { return modifier.effective_value(domain, stat_id, entity_handle, group_handle, base_value); }
double effective_value(const ModifierRuntime &modifier, int32_t domain, const char *stat_key, uint64_t entity_handle, uint64_t group_handle, double base_value) { return modifier.effective_value(domain, stat_key, entity_handle, group_handle, base_value); }
int32_t stat_id_for_key(const ModifierRuntime &modifier, const std::string &key) { return modifier.stat_id_for_key(key); }
const DerivedCellFront *derived_cell_front(const ModifierRuntime &modifier) { return modifier.derived_cell_front(); }

// ---- Economy/Effect/Ideology shared (economy_runtime_building_commit.cpp, effect_runtime.cpp, ideology_runtime.cpp)
bool configured(const ModifierRuntime &modifier) { return modifier.configured(); }
bool should_run(const ModifierRuntime &modifier, int64_t day_index) { return modifier.should_run(day_index); }
uint64_t domain_snapshot_version(const ModifierRuntime &modifier, int32_t domain) { return modifier.domain_snapshot_version(domain); }
double stat_clamp_max(const ModifierRuntime &modifier, const char *key, double fallback) { return modifier.stat_clamp_max(key, fallback); }

// ---- Economy (economy_runtime_building_commit.cpp, economy_runtime_colonization_kit.cpp, economy_runtime_configuration.cpp, economy_runtime_family_buff.cpp, economy_runtime_persistence.cpp, economy_runtime.cpp, economy_runtime_state_hash.cpp, economy_runtime_lineage_branch_effects.cpp, economy_runtime_country_epoch_capture.cpp)
void effective_values(const ModifierRuntime &modifier, int32_t domain, const int32_t *stat_ids, uint64_t entity_handle, const int32_t *base_values, int32_t *out_values, size_t count) { modifier.effective_values(domain, stat_ids, entity_handle, base_values, out_values, count); }
void collect_scope_ids(const ModifierRuntime &modifier, int32_t domain, int32_t scope, const int32_t *stat_ids, size_t stat_count, std::vector<uint64_t> &out_scope_ids) { modifier.collect_scope_ids(domain, scope, stat_ids, stat_count, out_scope_ids); }
void collect_scope_stat_entries(const ModifierRuntime &modifier, int32_t domain, int32_t scope, const int32_t *stat_ids, size_t stat_count, std::vector<uint64_t> &out_scope_ids, std::vector<int32_t> &out_stat_ids) { modifier.collect_scope_stat_entries(domain, scope, stat_ids, stat_count, out_scope_ids, out_stat_ids); }
uint64_t stat_bucket_version(const ModifierRuntime &modifier, int32_t domain, const int32_t *stat_ids, size_t stat_count) { return modifier.stat_bucket_version(domain, stat_ids, stat_count); }
bool has_technology_effect(const ModifierRuntime &modifier, uint64_t country_handle, const std::string &definition_key, int32_t technology_id) { return modifier.has_technology_effect(country_handle, definition_key, technology_id); }
bool apply_technology_effect(ModifierRuntime &modifier, uint64_t country_handle, const std::string &definition_key, int32_t technology_id, int64_t day_index, std::string &error) { return modifier.apply_technology_effect(country_handle, definition_key, technology_id, day_index, error); }
double country_economy_output_factor(const ModifierRuntime &modifier, uint64_t country_handle) { return modifier.country_economy_output_factor(country_handle); }
double country_sector_output_factor(const ModifierRuntime &modifier, uint64_t country_handle, int32_t economic_sector) { return modifier.country_sector_output_factor(country_handle, economic_sector); }
double country_research_institution_output_factor(const ModifierRuntime &modifier, uint64_t country_handle) { return modifier.country_research_institution_output_factor(country_handle); }
double country_trade_capacity_factor(const ModifierRuntime &modifier, uint64_t country_handle) { return modifier.country_trade_capacity_factor(country_handle); }
double country_trade_speed_factor(const ModifierRuntime &modifier, uint64_t country_handle) { return modifier.country_trade_speed_factor(country_handle); }
double country_construction_cost_factor(const ModifierRuntime &modifier, uint64_t country_handle) { return modifier.country_construction_cost_factor(country_handle); }
double country_construction_time_factor(const ModifierRuntime &modifier, uint64_t country_handle) { return modifier.country_construction_time_factor(country_handle); }
double economy_building_output_factor(const ModifierRuntime &modifier, uint64_t building_handle, uint64_t settlement_cell, int32_t economic_sector) { return modifier.economy_building_output_factor(building_handle, settlement_cell, economic_sector); }
uint64_t building_output_stat_version(const ModifierRuntime &modifier) { return modifier.building_output_stat_version(); }
uint64_t ensure_building_identity(ModifierRuntime &modifier, int32_t cell, int32_t type_id, int32_t owner_signature_id) { return modifier.ensure_building_identity(cell, type_id, owner_signature_id); }
bool retire_building_identity(ModifierRuntime &modifier, int32_t cell, int32_t type_id, int32_t owner_signature_id, int64_t day_index) { return modifier.retire_building_identity(cell, type_id, owner_signature_id, day_index); }
bool queue_family_group_effect(ModifierRuntime &modifier, const std::string &definition_key, int32_t settlement_cell, uint64_t branch_stable_id, int32_t magnitude_q16, int64_t day_index, std::string &error) { return modifier.queue_family_group_effect(definition_key, settlement_cell, branch_stable_id, magnitude_q16, day_index, error); }
bool queue_family_group_effect_remove(ModifierRuntime &modifier, const std::string &definition_key, int32_t settlement_cell, uint64_t branch_stable_id, int64_t day_index, std::string &error) { return modifier.queue_family_group_effect_remove(definition_key, settlement_cell, branch_stable_id, day_index, error); }
int32_t family_group_effect_magnitude(const ModifierRuntime &modifier, const std::string &definition_key, int32_t settlement_cell, uint64_t branch_stable_id) { return modifier.family_group_effect_magnitude(definition_key, settlement_cell, branch_stable_id); }
void register_person_target(ModifierRuntime &modifier, uint64_t handle) { modifier.register_person_target(handle); }
void unregister_person_target(ModifierRuntime &modifier, uint64_t handle) { modifier.unregister_person_target(handle); }
bool serialize_domain(const ModifierRuntime &modifier, int32_t domain, std::vector<uint8_t> &out, std::string &error) { return modifier.serialize_domain(domain, out, error); }
bool restore_domain(ModifierRuntime &modifier, int32_t domain, const std::vector<uint8_t> &bytes, std::string &error, bool allow_tax_catalog_extension) { return modifier.restore_domain(domain, bytes, error, allow_tax_catalog_extension); }
void clear_domain(ModifierRuntime &modifier, int32_t domain) { modifier.clear_domain(domain); }

// ---- Effect (effect_runtime.cpp)
bool submit_commands_pod(ModifierRuntime &modifier, const ModifierApi::NativeCommand *commands, size_t count, std::vector<int64_t> &request_ids, std::string &error) { return modifier.submit_commands_pod(commands, count, request_ids, error); }
bool command_result_pod(const ModifierRuntime &modifier, int64_t request_id, bool &complete, bool &ok, std::string &reason) { return modifier.command_result_pod(request_id, complete, ok, reason); }
int32_t remove_rows_for_source(ModifierRuntime &modifier, uint64_t source_type, uint64_t source_id, int64_t day) { return modifier.remove_rows_for_source(source_type, source_id, day); }

// ---- Ideology (ideology_runtime.cpp)
uint64_t catalog_hash(const ModifierRuntime &modifier) { return modifier.catalog_hash(); }
bool install_derived_cell_layer(ModifierRuntime &modifier, DerivedCellFront front, uint64_t expected_generation, bool &skipped, std::string &error) { return modifier.install_derived_cell_layer(front, expected_generation, skipped, error); }
bool resolve_definition_terms(const ModifierRuntime &modifier, const std::string &definition_key, std::vector<ModifierApi::ResolvedTerm> &out) { return modifier.resolve_definition_terms(definition_key, out); }
} // namespace modifier_api
} // namespace pk

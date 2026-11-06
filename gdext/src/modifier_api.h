#pragma once

// Public peer surface; each free function forwards to one runtime member.
#include <cstdint>
#include <string>
#include <vector>
#include "derived_cell_layer.h"

namespace pk {
class ModifierRuntime;
struct ModifierApi {
    enum Domain : int32_t { CLIMATE = 0, COUNTRY = 1, ECONOMY = 2, GAMEPLAY = 3, DOMAIN_COUNT = 4 };
    enum Scope : int32_t { GLOBAL = 0, GROUP = 1, ENTITY = 2 };
    enum Operation : int32_t { ADD = 0, SUBTRACT = 1, MULTIPLY = 2, DIVIDE = 3 };
    enum CommandOpcode : int32_t {
        COMMAND_APPLY = 1, COMMAND_REMOVE = 2, COMMAND_REFRESH = 3,
        COMMAND_SET_STACKS = 4, COMMAND_SET_MAGNITUDE = 5,
    };
    static constexpr int32_t Q16_ONE = 65536;
    // Mirrors EFFECT_MAX_MAGNITUDE_Q16 in effect_magnitude.h; modifier_runtime.h
    // static_asserts the two stay equal, and this header stays a leaf.
    static constexpr int32_t MAX_MAGNITUDE_Q16 = 4 * 65536;

    // Native batch ingress used by EffectRuntime. `definition_key` is resolved
    // before entering the Modifier daily commit, so no Godot Variant or
    // Dictionary construction occurs per Effect command.
    struct NativeCommand {
        int32_t opcode = 0;
        int32_t producer = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        const char *definition_key = nullptr;
        int32_t domain = CLIMATE;
        int32_t scope = ENTITY;
        uint64_t entity_handle = 0;
        uint64_t group_handle = 0;
        uint64_t source_type = 0;
        uint64_t source_id = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        int32_t magnitude_q16 = Q16_ONE;
        uint64_t modifier_handle = 0;
    };

    struct ResolvedTerm {
        int32_t stat_id = -1;
        int32_t operation = ADD;
        double value = 0.0;
    };
};

namespace modifier_api {
// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
double effective_value(const ModifierRuntime &modifier, int32_t domain, int32_t stat_id, uint64_t entity_handle, uint64_t group_handle, double base_value);
double effective_value(const ModifierRuntime &modifier, int32_t domain, const char *stat_key, uint64_t entity_handle, uint64_t group_handle, double base_value);
int32_t stat_id_for_key(const ModifierRuntime &modifier, const std::string &key);
const DerivedCellFront *derived_cell_front(const ModifierRuntime &modifier);

// ---- Economy/Effect/Ideology shared (economy_runtime_building_commit.cpp, effect_runtime.cpp, ideology_runtime.cpp)
bool configured(const ModifierRuntime &modifier);

// ---- Economy (economy_runtime_building_commit.cpp, economy_runtime_colonization_kit.cpp, economy_runtime_configuration.cpp, economy_runtime_family_buff.cpp, economy_runtime_persistence.cpp, economy_runtime.cpp, economy_runtime_state_hash.cpp, economy_runtime_lineage_branch_effects.cpp, economy_runtime_country_epoch_capture.cpp)
void effective_values(const ModifierRuntime &modifier, int32_t domain, const int32_t *stat_ids, uint64_t entity_handle, const int32_t *base_values, int32_t *out_values, size_t count);
void collect_scope_ids(const ModifierRuntime &modifier, int32_t domain, int32_t scope, const int32_t *stat_ids, size_t stat_count, std::vector<uint64_t> &out_scope_ids);
void collect_scope_stat_entries(const ModifierRuntime &modifier, int32_t domain, int32_t scope, const int32_t *stat_ids, size_t stat_count, std::vector<uint64_t> &out_scope_ids, std::vector<int32_t> &out_stat_ids);
uint64_t stat_bucket_version(const ModifierRuntime &modifier, int32_t domain, const int32_t *stat_ids, size_t stat_count);
double country_economy_output_factor(const ModifierRuntime &modifier, uint64_t country_handle);
double country_sector_output_factor(const ModifierRuntime &modifier, uint64_t country_handle, int32_t economic_sector);
double country_research_institution_output_factor(const ModifierRuntime &modifier, uint64_t country_handle);
double country_trade_capacity_factor(const ModifierRuntime &modifier, uint64_t country_handle);
double country_trade_speed_factor(const ModifierRuntime &modifier, uint64_t country_handle);
double country_construction_cost_factor(const ModifierRuntime &modifier, uint64_t country_handle);
double country_construction_time_factor(const ModifierRuntime &modifier, uint64_t country_handle);
double economy_building_output_factor(const ModifierRuntime &modifier, uint64_t building_handle, uint64_t settlement_cell, int32_t economic_sector);
uint64_t building_output_stat_version(const ModifierRuntime &modifier);
uint64_t ensure_building_identity(ModifierRuntime &modifier, int32_t cell, int32_t type_id, int32_t owner_signature_id);
bool retire_building_identity(ModifierRuntime &modifier, int32_t cell, int32_t type_id, int32_t owner_signature_id, int64_t day_index);
bool queue_family_group_effect(ModifierRuntime &modifier, const std::string &definition_key, int32_t settlement_cell, uint64_t branch_stable_id, int32_t magnitude_q16, int64_t day_index, std::string &error);
bool queue_family_group_effect_remove(ModifierRuntime &modifier, const std::string &definition_key, int32_t settlement_cell, uint64_t branch_stable_id, int64_t day_index, std::string &error);
int32_t family_group_effect_magnitude(const ModifierRuntime &modifier, const std::string &definition_key, int32_t settlement_cell, uint64_t branch_stable_id);
void register_person_target(ModifierRuntime &modifier, uint64_t handle);
void unregister_person_target(ModifierRuntime &modifier, uint64_t handle);
bool serialize_domain(const ModifierRuntime &modifier, int32_t domain, std::vector<uint8_t> &out, std::string &error);
bool restore_domain(ModifierRuntime &modifier, int32_t domain, const std::vector<uint8_t> &bytes, std::string &error, bool allow_tax_catalog_extension = false);
void clear_domain(ModifierRuntime &modifier, int32_t domain);

// ---- Effect (effect_runtime.cpp)
bool submit_commands_pod(ModifierRuntime &modifier, const ModifierApi::NativeCommand *commands, size_t count, std::vector<int64_t> &request_ids, std::string &error);
bool command_result_pod(const ModifierRuntime &modifier, int64_t request_id, bool &complete, bool &ok, std::string &reason);
int32_t remove_rows_for_source(ModifierRuntime &modifier, uint64_t source_type, uint64_t source_id, int64_t day);

// ---- Ideology (ideology_runtime.cpp)
uint64_t catalog_hash(const ModifierRuntime &modifier);
bool install_derived_cell_layer(ModifierRuntime &modifier, DerivedCellFront front, uint64_t expected_generation, bool &skipped, std::string &error);
bool resolve_definition_terms(const ModifierRuntime &modifier, const std::string &definition_key, std::vector<ModifierApi::ResolvedTerm> &out);
} // namespace modifier_api
} // namespace pk

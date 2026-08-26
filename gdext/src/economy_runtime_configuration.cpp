#include "economy_runtime.h"
#include "country_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include "modifier_runtime.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <limits>
#include <numeric>
#include <unordered_map>
#include <unordered_set>

#include <godot_cpp/variant/utility_functions.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

Dictionary NativeEconomyRuntime::configure(const Dictionary &catalog, const Dictionary &profile,
                                           int32_t cell_count, int64_t seed) {
    reset("reconfigure");
    Dictionary out;
    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    if (cell_count <= 0 || cell_count > 100000) {
        out["ok"] = false;
        out["reason"] = "cell_count_out_of_range";
        return out;
    }
    std::string error;
    if (!configure_profile(profile, error) || !compile_catalog(catalog, error)) {
        reset(String(error.c_str()));
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    const auto resolve_tax_stats = [&](const char *kind,
                                       const std::vector<std::string> &item_ids,
                                       std::vector<int32_t> &out_ids) {
        out_ids.clear();
        out_ids.reserve(item_ids.size());
        for (const std::string &item : item_ids) {
            const std::string key = std::string("country.tax.") + kind + "." +
                item + ".rate_pct";
            const int32_t id = _modifier_runtime != nullptr
                ? _modifier_runtime->stat_id_for_key(key) : -1;
            if (id < 0) {
                error = "modifier_tax_stat_missing:" + key;
                return false;
            }
            out_ids.push_back(id);
        }
        return true;
    };
    if (_modifier_runtime == nullptr) {
        _income_tax_stat_ids.assign(_profession_ids.size(), -1);
        _consumption_tax_stat_ids.assign(_good_ids.size(), -1);
        _business_tax_stat_ids.assign(_building_type_ids.size(), -1);
        _import_tax_stat_ids.assign(_good_ids.size(), -1);
        _export_tax_stat_ids.assign(_good_ids.size(), -1);
    } else if (
        !resolve_tax_stats("income", _profession_ids, _income_tax_stat_ids) ||
        !resolve_tax_stats("consumption", _good_ids, _consumption_tax_stat_ids) ||
        !resolve_tax_stats("business", _building_type_ids, _business_tax_stat_ids) ||
        !resolve_tax_stats("import", _good_ids, _import_tax_stat_ids) ||
        !resolve_tax_stats("export", _good_ids, _export_tax_stat_ids)) {
        reset(String(error.c_str()));
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    _city_birth_stat_id = _modifier_runtime != nullptr
        ? _modifier_runtime->stat_id_for_key("economy.city.birth_factor") : -1;
    _city_consumption_stat_id = _modifier_runtime != nullptr
        ? _modifier_runtime->stat_id_for_key("economy.city.consumption_factor") : -1;
    _city_need_consumption_stat_ids.clear();
    _city_need_consumption_stat_ids.reserve(_need_ids.size());
    for (const std::string &need_id : _need_ids) {
        const std::string key = "economy.city.need." + need_id +
            ".consumption_factor";
        _city_need_consumption_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(key) : -1);
    }
    _city_good_consumption_stat_ids.clear();
    _city_good_consumption_stat_ids.reserve(_good_ids.size());
    _city_good_output_stat_ids.clear();
    _city_good_output_stat_ids.reserve(_good_ids.size());
    for (const std::string &good_id : _good_ids) {
        const std::string key = "economy.city.good." + good_id +
            ".consumption_factor";
        _city_good_consumption_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(key) : -1);
        _city_good_output_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(
                "economy.city.good." + good_id + ".output_factor") : -1);
    }
    _city_building_output_stat_ids.clear();
    _city_building_output_stat_ids.reserve(_building_type_ids.size());
    for (const std::string &building_id : _building_type_ids) {
        _city_building_output_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(
                "economy.city.building." + building_id + ".output_factor") : -1);
    }
    if (_modifier_runtime != nullptr && (_city_birth_stat_id < 0 ||
            _city_consumption_stat_id < 0 || std::any_of(
                _city_need_consumption_stat_ids.begin(),
                _city_need_consumption_stat_ids.end(),
                [](int32_t id) { return id < 0; }) || std::any_of(
                _city_good_consumption_stat_ids.begin(),
                _city_good_consumption_stat_ids.end(),
                [](int32_t id) { return id < 0; }) || std::any_of(
                _city_good_output_stat_ids.begin(),
                _city_good_output_stat_ids.end(),
                [](int32_t id) { return id < 0; }) || std::any_of(
                _city_building_output_stat_ids.begin(),
                _city_building_output_stat_ids.end(),
                [](int32_t id) { return id < 0; }))) {
        reset("modifier_city_stat_missing");
        out["ok"] = false;
        out["reason"] = "modifier_city_stat_missing";
        return out;
    }
    _country_family_output_stat_ids.clear();
    _country_family_output_stat_ids.reserve(_building_upgrade_family_ids.size());
    for (const std::string &family_id : _building_upgrade_family_ids) {
        const std::string key = "country.output.family." + family_id + "_factor";
        _country_family_output_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(key) : -1);
    }
    _country_good_output_stat_ids.clear();
    _country_good_input_stat_ids.clear();
    _country_good_consumption_stat_ids.clear();
    _country_good_output_stat_ids.reserve(_good_ids.size());
    _country_good_input_stat_ids.reserve(_good_ids.size());
    _country_good_consumption_stat_ids.reserve(_good_ids.size());
    for (const std::string &good_id : _good_ids) {
        const std::string key = "country.output.good." + good_id + "_factor";
        _country_good_output_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(key) : -1);
        _country_good_input_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(
                "country.input.good." + good_id + "_factor") : -1);
        _country_good_consumption_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(
                "country.consumption.good." + good_id + "_factor") : -1);
    }
    _country_resource_use_stat_ids.clear();
    _country_resource_generation_stat_ids.clear();
    for (const std::string &resource_id : _resource_ids) {
        _country_resource_use_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(
                "country.resource." + resource_id + ".use_factor") : -1);
        _country_resource_generation_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(
                "country.resource." + resource_id +
                ".managed_generation_factor") : -1);
    }
    const auto resolve_geography_stats = [&](const std::string &kind,
            const std::vector<std::string> &geography_ids,
            std::vector<int32_t> &target) {
        target.clear();
        target.reserve(geography_ids.size() * _modifier_sector_ids.size());
        for (const std::string &geography_id : geography_ids)
            for (const std::string &sector_id : _modifier_sector_ids)
                target.push_back(_modifier_runtime != nullptr
                    ? _modifier_runtime->stat_id_for_key("country.output." + kind +
                        "." + geography_id + "." + sector_id + "_factor") : -1);
    };
    resolve_geography_stats("terrain", _modifier_terrain_ids,
                            _country_terrain_sector_output_stat_ids);
    resolve_geography_stats("landform", _modifier_landform_ids,
                            _country_landform_sector_output_stat_ids);
    _country_production_input_stat_id = _modifier_runtime != nullptr
        ? _modifier_runtime->stat_id_for_key("country.production.input_factor") : -1;
    _country_household_consumption_stat_id = _modifier_runtime != nullptr
        ? _modifier_runtime->stat_id_for_key(
            "country.household.consumption_factor") : -1;
    _country_resource_use_stat_id = _modifier_runtime != nullptr
        ? _modifier_runtime->stat_id_for_key("country.resource.use_factor") : -1;
    _country_building_output_stat_ids.clear();
    _country_building_output_stat_ids.reserve(_building_type_ids.size());
    for (const std::string &building_id : _building_type_ids) {
        const std::string key =
            "country.output.building." + building_id + "_factor";
        _country_building_output_stat_ids.push_back(_modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(key) : -1);
    }
    static const char *CLIMATE_LOSS_STATS[4] = {
        "country.climate.drought_loss_factor",
        "country.climate.flood_loss_factor",
        "country.climate.cold_stress_factor",
        "country.climate.heat_stress_factor",
    };
    for (size_t i = 0; i < _country_climate_loss_stat_ids.size(); ++i)
        _country_climate_loss_stat_ids[i] = _modifier_runtime != nullptr
            ? _modifier_runtime->stat_id_for_key(CLIMATE_LOSS_STATS[i]) : -1;
    if (_modifier_runtime != nullptr && (std::any_of(
            _country_family_output_stat_ids.begin(),
            _country_family_output_stat_ids.end(),
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_good_output_stat_ids.begin(),
            _country_good_output_stat_ids.end(),
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_good_input_stat_ids.begin(),
            _country_good_input_stat_ids.end(),
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_good_consumption_stat_ids.begin(),
            _country_good_consumption_stat_ids.end(),
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_resource_use_stat_ids.begin(),
            _country_resource_use_stat_ids.end(),
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_resource_generation_stat_ids.begin(),
            _country_resource_generation_stat_ids.end(),
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_terrain_sector_output_stat_ids.begin(),
            _country_terrain_sector_output_stat_ids.end(),
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_landform_sector_output_stat_ids.begin(),
            _country_landform_sector_output_stat_ids.end(),
            [](int32_t id) { return id < 0; }) ||
            _country_production_input_stat_id < 0 ||
            _country_household_consumption_stat_id < 0 ||
            _country_resource_use_stat_id < 0 || std::any_of(
            _country_building_output_stat_ids.begin(),
            _country_building_output_stat_ids.end(),
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_climate_loss_stat_ids.begin(),
            _country_climate_loss_stat_ids.end(),
            [](int32_t id) { return id < 0; }))) {
        reset("modifier_technology_route_stat_missing");
        out["ok"] = false;
        out["reason"] = "modifier_technology_route_stat_missing";
        return out;
    }
    _epoch_city_factor_valid = false;
    _epoch_city_factor_stat_version = 0;
    _epoch_city_output_factor_valid = false;
    _epoch_city_output_factor_stat_version = 0;
    _city_factor_dirty_cells.clear();
    _cell_count = cell_count;
    _seed = seed;
    _trace_cell_mask.assign(cell_count, 0);
    _pending_trace_cell_mask.clear();
    _trace_filter_pending = false;
    _inspector_trace_cell = -1;
    _pending_inspector_trace_cell = -1;
    _inspector_trace_pending = false;
    _investment_diagnostic_cell = -1;
    _investment_diagnostic_day = -1;
    _investment_diagnostics.clear();
    _population.clear(cell_count);
    _families.clear();
    _family_expeditions.clear();
    _family_expedition_route_cells.clear();
    _family_expedition_route_costs.clear();
    _family_expedition_payloads.clear();
    _family_expedition_person_handles.clear();
    _family_expedition_cargo.clear();
    _family_expedition_kit_buildings.clear();
    _family_expedition_missing_good_ids.clear();
    _family_expedition_missing_good_quantities.clear();
    _family_expedition_target_index.clear();
    _family_expedition_due_heap.clear();
    _colonization_receipts.clear();
    _next_colonization_receipt_id = 1;
    _next_family_expedition_stable_id = 1;
    _colonization_quote_cache.clear();
    _colonization_quote_index.clear();
    _colonization_quote_route_cells.clear();
    _colonization_quote_route_costs.clear();
    _canal_quotes.clear();
    _canal_quote_index.clear();
    _canal_projects.clear();
    _canal_project_index.clear();
    _canal_receipts.clear();
    _next_canal_quote_token = 1;
    _next_canal_project_id = 1;
    _next_canal_receipt_id = 1;
    _colonization_distance.clear();
    _colonization_distance_stamp.clear();
    _colonization_parent.clear();
    _colonization_parent_stamp.clear();
    _colonization_route_heap.clear();
    _colonization_search_stamp = 0;
    _family_influences.clear();
    _persons.clear();
    _family_memberships.clear();
    _family_ownerships.clear();
    _family_traits.clear();
    _family_behavior_factor_offsets.clear();
    _family_behavior_factor_rows.clear();
    _family_behavior_cache_dirty = true;
    _family_behavior_cache_dirty_reasons =
        FAMILY_BEHAVIOR_DIRTY_INITIAL;
    _family_behavior_cache_last_reasons = 0;
    _family_behavior_cache_rebuilds = 0;
    _family_behavior_cache_skips = 0;
    _family_behavior_metric_contexts_built = 0;
    _family_behavior_condition_edges_evaluated = 0;
    _family_behavior_cache_ms = 0.0;
    _family_behavior_class_rows = 0;
    _family_purchase_factor_q16.clear();
    _family_investment_factor_q16.clear();
    _family_birth_factor_q16.clear();
    _family_absorb_bonus_q16.clear();
    _family_colonization_population_reward.clear();
    _pending_family_split_gifts.clear();
    _family_policy_stamped_cells.clear();
    _epoch_cell_rain_event_threshold_q16.clear();
    _epoch_cell_cold_capacity_factor_q16.clear();
    _epoch_cell_sector_output_factor_q16.clear();
    _family_trait_commands.clear();
    _family_effect_bindings.clear();
    _family_effect_binding_by_instance.clear();
    _family_effect_instances_by_branch.clear();
    _family_effect_instances_by_cell.clear();
    _family_industry_stats.clear();
    _family_owned_output_rows.clear();
    _family_modifier_bindings.clear();
    _family_trigger_bindings.clear();
    _person_needs.clear();
    _person_needs_normalized = false;
    _family_member_offsets.clear();
    _family_member_edge_indices.clear();
    _family_owned_offsets.clear();
    _family_owned_edge_indices.clear();
    _family_cohort_offsets.clear();
    _family_cohort_edge_indices.clear();
    _family_building_offsets.clear();
    _family_building_edge_indices.clear();
    _family_cell_offsets.assign(static_cast<size_t>(cell_count) + 1, 0);
    _family_cell_indices.clear();
    _family_indices_dirty = true;
    _person_family_offsets.clear(); _person_family_indices.clear();
    _person_cohort_offsets.clear(); _person_cohort_indices.clear();
    _person_cohort_migrations.clear();
    _person_family_migrations.clear();
    _person_stable_ids.clear();
    _family_stable_ids.clear();
    _family_surname_members.clear();
    _family_surname_culture_group_ids.clear();
    _family_culture_group_ids.clear();
    _family_culture_group_display_names.clear();
    _family_culture_group_naming_formats.clear();
    _family_culture_group_separators.clear();
    _family_culture_group_suffixes.clear();
    _person_cell_offsets.assign(static_cast<size_t>(cell_count) + 1, 0);
    _person_cell_indices.clear(); _person_building_offsets.clear();
    _person_building_indices.clear(); _person_need_offsets.clear();
    _person_indices_dirty = true; _person_opening_cash_claim.clear();
    _person_previous_building_handle.clear();
    _person_previous_job_kind.clear();
    _person_previous_employee_role_index.clear();
    _person_epoch_needs.clear();
    _settlements.clear(cell_count);
    _market.clear();
    _market_signals.clear(cell_count);
    _buildings.clear();
    _pending_building_topology_rebuild = false;
    _building_handle_index_clean = false;
    _building_groups_rebuild_scratch.clear();
    _building_existing_indices_scratch.clear();
    _building_new_indices_scratch.clear();
    _building_investment_score_rebuild_scratch.clear();
    _building_investment_payback_rebuild_scratch.clear();
    _building_investment_rejection_rebuild_scratch.clear();
    _building_free_role_spans_by_type.assign(_building_types.size(), {});
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _cell_last_settlement_day.clear();
    _birth_residual_q32.assign(
        static_cast<size_t>(cell_count) * _ethnicity_ids.size(), 0);
    _cell_settlement_generation.clear();
    _cell_price_stock_gen.clear();
    _cell_owner_cash_gen.clear();
    _cell_population_gen.clear();
    _cell_building_structure_gen.clear();
    _cell_technology_gen.clear();
    _cell_resource_gen.clear();
    _cell_trade_gen.clear();
    _cell_effect_shortage_q16.clear();
    _cell_essentials_shortage_q16.clear();
    _cell_resource_abundance_q16.clear();
    _cell_previous_precipitation_q16.clear();
    _cell_rain_event_q16.clear();
    _epoch_market_ids.clear();
    _economy_live_cells.clear();
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    _epoch_plan_cells.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _pending_construction.clear();
    _investment_pending_by_cell_type.clear();
    _investment_existing_by_cell_type.clear();
    _investment_merchant_cash_by_cell.clear();
    _investment_outstanding_credit_by_cell.clear();
    _investment_output_signals_scratch.clear();
    int32_t max_building_outputs = 0;
    for (const BuildingType &type : _building_types)
        max_building_outputs = std::max(
            max_building_outputs, type.output_count);
    _investment_output_signals_scratch.reserve(max_building_outputs);
    _investment_employment_cells.clear();
    _investment_review_cell_indices.clear();
    _investment_active_goods_scratch.clear();
    _startup_demand_values.clear();
    _startup_demand_stamps.clear();
    _startup_demand_generation = 0;
    _startup_demand_touched_keys.clear();
    _startup_remote_lanes.clear();
    _startup_remote_groups.clear();
    _startup_inbound_lanes.clear();
    _startup_remote_accumulator_scratch.clear();
    _building_context_day = -1;
    // A game may be saved before the first daily environment capture. Keep the
    // persistent lanes valid from configuration onward so the PKSV/PKEC path is
    // safe and deterministic at day zero; start_epoch still requires a same-day
    // capture before these defaults can affect simulation.
    _environment_temperature_q16.assign(cell_count, Q16_ONE / 2);
    _environment_temperature_30d_q16.assign(cell_count, Q16_ONE / 2);
    _environment_moisture_q16.assign(cell_count, Q16_ONE / 2);
    _environment_plant_available_water_q16.assign(cell_count, Q16_ONE / 2);
    _environment_precipitation_q16.assign(cell_count, 0);
    _environment_snow_q16.assign(cell_count, 0);
    _environment_weather_q16.assign(cell_count, 0);
    _cell_living_cost_per_capita.assign(cell_count, 0);
    _epoch_cell_development_q16.assign(cell_count, 0);
    _cell_social_pressure_level.assign(cell_count, 0);
    _cell_support_ema_q16.assign(cell_count, Q16_ONE);
    _cell_carrying_k_geo.assign(cell_count, _carrying_k_habitat_ref);
    _cell_carrying_k_eff.assign(cell_count, _carrying_k_habitat_ref);
    _cell_carrying_surplus_q16.assign(cell_count, Q16_ONE);
    _cell_carrying_sat_q16.assign(cell_count, Q16_ONE);
    _cell_carrying_family_surplus_q16.assign(
        static_cast<size_t>(cell_count) * CARRYING_FAMILY_COUNT, Q16_ONE);
    _cell_carrying_family_bindable.assign(
        static_cast<size_t>(cell_count) * CARRYING_FAMILY_COUNT, 0);
    uint64_t bootstrap_environment_hash = 1469598103934665603ULL;
    auto mix_bootstrap_environment = [&](uint32_t value) {
        for (int32_t byte = 0; byte < 4; ++byte) {
            bootstrap_environment_hash ^= static_cast<uint8_t>(
                (value >> (byte * 8)) & 0xffU);
            bootstrap_environment_hash *= 1099511628211ULL;
        }
    };
    for (int32_t cell = 0; cell < cell_count; ++cell) {
        mix_bootstrap_environment(Q16_ONE / 2);
        mix_bootstrap_environment(Q16_ONE / 2);
        mix_bootstrap_environment(Q16_ONE / 2);
        mix_bootstrap_environment(Q16_ONE / 2);
        mix_bootstrap_environment(0);
        mix_bootstrap_environment(0);
        mix_bootstrap_environment(0);
    }
    _environment_day = -1;
    _environment_hash = static_cast<int64_t>(
        (bootstrap_environment_hash & 0x7fffffffffffffffULL) | 1ULL);
    _committed_cells.assign(cell_count, {});
    const size_t cache_cells = static_cast<size_t>(cell_count);
    _demand_basis_cache_day.assign(
        cache_cells, std::numeric_limits<int64_t>::min());
    _demand_basis_variant_scores.resize(cache_cells * _variants.size());
    _demand_basis_variant_prices.resize(cache_cells * _variants.size());
    _demand_basis_need_score_sums.resize(cache_cells * _needs.size());
    _demand_basis_need_composites.resize(cache_cells * _needs.size());
    _demand_basis_need_environment.resize(cache_cells * _needs.size());
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63) / 64);
    if (_country_runtime == nullptr || !_country_runtime->economy_available()) {
        reset("country_runtime_required");
        out["ok"] = false;
        out["reason"] = "country_runtime_required";
        return out;
    }
    _configured = true;
    _stage = Stage::IDLE;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["catalog_hash"] = _catalog_hash;
    out["cell_count"] = _cell_count;
    out["good_count"] = static_cast<int32_t>(_good_ids.size());
    out["signature_count"] = static_cast<int32_t>(_signatures.size());
    out["building_type_count"] = static_cast<int32_t>(_building_types.size());
    out["family_catalog_hash"] = _family_catalog_hash;
    out["money_scale"] = MONEY_SCALE;
    out["goods_scale"] = GOODS_SCALE;
    out["ratio_scale"] = Q16_ONE;
    out["rate_scale"] = Q32_ONE;
    return out;
}


Dictionary NativeEconomyRuntime::bootstrap(const Dictionary &population_packet,
                                           const Dictionary &market_packet) {
    Dictionary out;
    out["path"] = "ECONOMY_GRAPH";
    if (!_configured || _epoch_active) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured" : "epoch_in_flight";
        return out;
    }
    _bootstrapped = false;
    _population.clear(_cell_count);
    _birth_residual_q32.assign(
        static_cast<size_t>(_cell_count) * _ethnicity_ids.size(), 0);
    _settlements.clear(_cell_count);
    _market.clear();
    _market_signals.clear(_cell_count);
    _labor_signals.clear(_cell_count);
    _trade_plan.clear_transient();
    _trade_active_keys.clear();
    _trade_active_key_present.clear();
    _trade_active_key_idle_cycles.clear();
    _trade_signal_clock_keys.clear();
    _trade_signal_first_seen_day.clear();
    _trade_signal_first_dispatch_day.clear();
    _trade_signal_last_attempt_day.clear();
    _trade_signal_last_rejection_reason.clear();
    _trade_signal_deadline_reported.clear();
    _trade_response_deadline_misses_cumulative = 0;
    _trade_orders.clear();
    _trade_flows.clear();
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _buildings.clear();
    _pending_building_topology_rebuild = false;
    _building_handle_index_clean = false;
    _building_groups_rebuild_scratch.clear();
    _building_existing_indices_scratch.clear();
    _building_new_indices_scratch.clear();
    _building_investment_score_rebuild_scratch.clear();
    _building_investment_payback_rebuild_scratch.clear();
    _building_investment_rejection_rebuild_scratch.clear();
    _building_free_role_spans_by_type.assign(_building_types.size(), {});
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _building_role_contract_wage.clear();
    _building_role_base_living_cost.clear();
    _building_role_living_cost.clear();
    _building_role_local_average_wage.clear();
    _building_role_base_wage_due.clear();
    _building_role_base_wage_paid.clear();
    _building_role_bonus_due.clear();
    _building_role_bonus_paid.clear();
    _pending_construction.clear();
    _investment_pending_by_cell_type.clear();
    _investment_existing_by_cell_type.clear();
    _investment_merchant_cash_by_cell.clear();
    _investment_outstanding_credit_by_cell.clear();
    _investment_employment_cells.clear();
    _investment_review_cell_indices.clear();
    _investment_active_goods_scratch.clear();
    _startup_demand_touched_keys.clear();
    _startup_remote_lanes.clear();
    _startup_remote_groups.clear();
    _startup_inbound_lanes.clear();
    _startup_remote_accumulator_scratch.clear();
    std::string country_error;
    if (!capture_country_epoch(country_error)) {
        out["ok"] = false;
        out["reason"] = country_error.c_str();
        return out;
    }

    const std::vector<int32_t> cells = packed_i32(population_packet, "cell_indices");
    const std::vector<int32_t> signatures = packed_i32(population_packet, "signature_ids");
    const std::vector<int64_t> populations = packed_i64(population_packet, "population");
    const std::vector<int64_t> funds = packed_i64(population_packet, "funds");
    std::vector<int32_t> forced_named_cells = packed_i32(
        population_packet, "forced_named_cells");
    if (cells.size() != signatures.size() || cells.size() != populations.size() ||
        cells.size() != funds.size()) {
        out["ok"] = false;
        out["reason"] = "population_packet_size_mismatch";
        return out;
    }
    std::vector<size_t> bootstrap_order(cells.size());
    std::iota(bootstrap_order.begin(), bootstrap_order.end(), size_t{0});
    std::stable_sort(bootstrap_order.begin(), bootstrap_order.end(), [&](size_t a, size_t b) {
        if (cells[a] != cells[b]) return cells[a] < cells[b];
        if (signatures[a] != signatures[b]) return signatures[a] < signatures[b];
        return a < b;
    });
    for (size_t i : bootstrap_order) {
        if (cells[i] < 0 || cells[i] >= _cell_count || signatures[i] < 0 ||
            signatures[i] >= static_cast<int32_t>(_signatures.size()) || populations[i] < 0 ||
            funds[i] < 0) {
            out["ok"] = false;
            out["reason"] = "population_packet_entry_invalid";
            _population.clear(_cell_count);
            return out;
        }
        if (populations[i] == 0) continue;
        const int32_t slot = _population.allocate_slot(cells[i], static_cast<uint32_t>(signatures[i]));
        if (slot < 0) {
            out["ok"] = false;
            out["reason"] = "population_page_allocation_failed";
            _population.clear(_cell_count);
            return out;
        }
        _population.population[slot] = saturating_add(_population.population[slot], populations[i], _saturation_count);
        _population.funds[slot] = saturating_add(_population.funds[slot], funds[i], _saturation_count);
    }
    std::sort(forced_named_cells.begin(), forced_named_cells.end());
    forced_named_cells.erase(std::unique(
        forced_named_cells.begin(), forced_named_cells.end()),
        forced_named_cells.end());
    for (int32_t cell : forced_named_cells) {
        bool has_population = false;
        for (size_t i = 0; i < cells.size(); ++i) {
            if (cells[i] == cell && populations[i] > 0) {
                has_population = true;
                break;
            }
        }
        if (cell < 0 || cell >= _cell_count || !has_population) {
            out["ok"] = false;
            out["reason"] = "forced_named_cell_invalid";
            _population.clear(_cell_count);
            return out;
        }
    }

    int64_t merchant_repairs = 0;
    std::string merchant_error;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (!ensure_merchant_invariant(cell, merchant_repairs, merchant_error)) {
            out["ok"] = false;
            out["reason"] = String(merchant_error.c_str());
            _population.clear(_cell_count);
            return out;
        }
    }
    if (!rebuild_merchant_ranges(merchant_error)) {
        out["ok"] = false;
        out["reason"] = String(merchant_error.c_str());
        return out;
    }

    int32_t market_count = dict_num<int32_t>(market_packet, "market_count", _cell_count);
    if (market_count != _cell_count) {
        out["ok"] = false;
        out["reason"] = "market_v2_requires_one_market_per_cell";
        return out;
    }
    _market.market_count = market_count;
    _market.good_count = static_cast<int32_t>(_good_ids.size());
    const int64_t matrix_size = static_cast<int64_t>(market_count) * _market.good_count;
    if (matrix_size <= 0 || matrix_size > 25000000LL) {
        out["ok"] = false;
        out["reason"] = "market_matrix_capacity_exceeded";
        return out;
    }
    _market.stock.resize(static_cast<size_t>(matrix_size));
    _market.price.resize(static_cast<size_t>(matrix_size));
    _market.demand_ema.assign(static_cast<size_t>(matrix_size), 0);
    _market.last_shortage_q16.assign(static_cast<size_t>(matrix_size), 0);
    _trade_active_key_present.assign(static_cast<size_t>(matrix_size), 0);
    const size_t investment_good_words =
        (static_cast<size_t>(_market.good_count) + 63U) / 64U;
    _investment_active_good_words.assign(investment_good_words, 0);
    _investment_active_goods_scratch.clear();
    _startup_demand_values.assign(static_cast<size_t>(matrix_size), 0);
    _startup_demand_stamps.assign(static_cast<size_t>(matrix_size), 0);
    _startup_demand_generation = 0;
    _startup_demand_touched_keys.clear();
    _market.cell_to_market.resize(_cell_count);
    for (int32_t c = 0; c < _cell_count; ++c) _market.cell_to_market[c] = c % market_count;
    for (int32_t m = 0; m < market_count; ++m) {
        for (int32_t g = 0; g < _market.good_count; ++g) {
            const int64_t idx = _market.index(m, g);
            audit_touch_market_lane(static_cast<size_t>(idx));
            _market.stock[idx] = 0;
            _market.price[idx] = _good_default_price[g];
        }
    }

    std::vector<int32_t> cell_to_market = packed_i32(market_packet, "cell_to_market");
    if (!cell_to_market.empty()) {
        if (cell_to_market.size() != static_cast<size_t>(_cell_count)) {
            out["ok"] = false;
            out["reason"] = "cell_to_market_size_mismatch";
            return out;
        }
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            if (cell_to_market[cell] != cell) {
                out["ok"] = false;
                out["reason"] = "market_v2_requires_identity_cell_mapping";
                return out;
            }
        }
        _market.cell_to_market.swap(cell_to_market);
    }
    std::vector<int64_t> stock = packed_i64(market_packet, "stock");
    std::vector<int32_t> price = packed_i32(market_packet, "price");
    if (market_packet.has("market_cash")) {
        out["ok"] = false;
        out["reason"] = "market_cash_removed_in_schema_v2";
        return out;
    }
    if (!stock.empty()) {
        if (stock.size() != static_cast<size_t>(matrix_size) ||
            std::any_of(stock.begin(), stock.end(), [](int64_t v) { return v < 0; })) {
            out["ok"] = false;
            out["reason"] = "market_stock_invalid";
            return out;
        }
        _market.stock.swap(stock);
    }
    if (!price.empty()) {
        if (price.size() != static_cast<size_t>(matrix_size)) {
            out["ok"] = false;
            out["reason"] = "market_price_size_mismatch";
            return out;
        }
        for (int32_t m = 0; m < market_count; ++m) {
            for (int32_t g = 0; g < _market.good_count; ++g) {
                const int64_t idx = _market.index(m, g);
                if (price[idx] < PRICE_NUMERIC_GUARD_MIN ||
                    price[idx] > PRICE_NUMERIC_GUARD_MAX) {
                    out["ok"] = false;
                    out["reason"] = "market_price_out_of_range";
                    return out;
                }
            }
        }
        _market.price.swap(price);
    }
    std::string market_range_error;
    if (!rebuild_market_cell_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }

    const std::vector<int32_t> building_cells = packed_i32(market_packet, "building_cells");
    const std::vector<int32_t> building_types = packed_i32(market_packet, "building_type_ids");
    const std::vector<int32_t> building_owners = packed_i32(market_packet, "building_owner_signature_ids");
    const std::vector<int64_t> building_counts = packed_i64(market_packet, "building_counts");
    std::vector<int32_t> founder_cells = packed_i32(
        market_packet, "founder_family_cells");
    std::vector<int32_t> founder_types = packed_i32(
        market_packet, "founder_family_building_type_ids");
    std::vector<int32_t> founder_owners = packed_i32(
        market_packet, "founder_family_owner_signature_ids");
    if (building_cells.size() != building_types.size() ||
        building_cells.size() != building_owners.size() ||
        building_cells.size() != building_counts.size()) {
        out["ok"] = false;
        out["reason"] = "building_bootstrap_column_size_mismatch";
        return out;
    }
    if (founder_cells.size() != founder_types.size() ||
        founder_cells.size() != founder_owners.size()) {
        out["ok"] = false;
        out["reason"] = "founder_family_bootstrap_column_size_mismatch";
        return out;
    }
    // Native authority also recognizes the formal opening from its persisted
    // invariants. This keeps a long-lived editor that still emits the v2
    // GDScript packet from silently losing founders: forced capital + actual
    // gathering ground is sufficient to derive the same sparse declaration.
    if (founder_cells.empty() && !forced_named_cells.empty()) {
        const auto type_it = std::lower_bound(_building_type_ids.begin(),
            _building_type_ids.end(), std::string("gathering_ground"));
        if (type_it != _building_type_ids.end() &&
            *type_it == "gathering_ground") {
            const int32_t founder_type = static_cast<int32_t>(
                type_it - _building_type_ids.begin());
            for (int32_t cell : forced_named_cells) {
                for (size_t i = 0; i < building_cells.size(); ++i) {
                    if (building_cells[i] != cell ||
                        building_types[i] != founder_type) continue;
                    founder_cells.push_back(cell);
                    founder_types.push_back(founder_type);
                    founder_owners.push_back(building_owners[i]);
                    break;
                }
            }
        }
    }
    if (!founder_cells.empty() &&
        (_family_runtime_mode != 2 || _person_runtime_mode != 2)) {
        out["ok"] = false;
        out["reason"] = _family_runtime_mode != 2
            ? "founder_family_runtime_inactive"
            : "founder_person_runtime_inactive";
        return out;
    }
    for (size_t i = 0; i < building_cells.size(); ++i) {
        if (building_cells[i] < 0 || building_cells[i] >= _cell_count ||
            building_types[i] < 0 || building_types[i] >= static_cast<int32_t>(_building_types.size()) ||
            building_owners[i] < 0 || building_owners[i] >= static_cast<int32_t>(_signatures.size()) ||
            building_counts[i] <= 0 ||
            _signatures[building_owners[i]].profession_id !=
                _building_types[building_types[i]].owner_profession_id) {
            out["ok"] = false;
            out["reason"] = "building_bootstrap_entry_invalid";
            return out;
        }
        const int32_t existing = find_building_group(building_cells[i], building_types[i],
                                                     building_owners[i]);
        if (existing >= 0) {
            _buildings[existing].count = saturating_add(_buildings[existing].count,
                                                        building_counts[i], _saturation_count);
            _building_handle_index_clean = false;
        } else {
            BuildingGroup group;
            group.cell = building_cells[i];
            group.type_id = building_types[i];
            group.owner_signature_id = building_owners[i];
            group.count = building_counts[i];
            _buildings.push_back(group);
        }
    }
    rebuild_building_role_storage();

    int32_t founder_family_count = 0;
    int32_t founder_person_count = 0;
    if (!founder_cells.empty()) {
        refresh_building_modifier_factors();
        std::vector<size_t> founder_order(founder_cells.size());
        std::iota(founder_order.begin(), founder_order.end(), size_t{0});
        std::stable_sort(founder_order.begin(), founder_order.end(),
            [&](size_t a, size_t b) {
                return std::tie(founder_cells[a], founder_types[a],
                                founder_owners[a], a) <
                    std::tie(founder_cells[b], founder_types[b],
                             founder_owners[b], b);
            });
        std::vector<int32_t> founder_family_indices;
        founder_family_indices.reserve(founder_order.size());
        int32_t previous_cell = -1;
        for (size_t packet_index : founder_order) {
            const int32_t cell = founder_cells[packet_index];
            const int32_t type_id = founder_types[packet_index];
            const int32_t owner_signature = founder_owners[packet_index];
            if (cell < 0 || cell >= _cell_count || cell == previous_cell ||
                type_id < 0 ||
                type_id >= static_cast<int32_t>(_building_types.size()) ||
                owner_signature < 0 ||
                owner_signature >= static_cast<int32_t>(_signatures.size()) ||
                _signatures[owner_signature].profession_id !=
                    _building_types[type_id].owner_profession_id) {
                out["ok"] = false;
                out["reason"] = "founder_family_bootstrap_entry_invalid";
                return out;
            }
            previous_cell = cell;
            const int32_t group_index = find_building_group(
                cell, type_id, owner_signature);
            const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
            const int64_t owner_slots =
                _building_types[type_id].owner_slots_per_building;
            if (group_index < 0 || owner_slot < 0 || owner_slots <= 0 ||
                _buildings[group_index].count <= 0 ||
                _buildings[group_index].modifier_handle == 0 ||
                _population.population[owner_slot] < owner_slots) {
                out["ok"] = false;
                out["reason"] = "founder_family_bootstrap_target_invalid";
                return out;
            }
            _buildings[group_index].filled_owner = std::max(
                _buildings[group_index].filled_owner, owner_slots);
            _population.owner_employed[owner_slot] = std::max(
                _population.owner_employed[owner_slot], owner_slots);
            const int64_t founders = family_household_people_for_slot(
                owner_slot, owner_slots);
            const int32_t family_index = create_family_for_building(
                cell, group_index, founders, owner_slots, true);
            if (family_index < 0) {
                out["ok"] = false;
                out["reason"] = "founder_family_bootstrap_failed";
                return out;
            }
            founder_family_indices.push_back(family_index);
            ++founder_family_count;
        }
        rebuild_family_indices();
        rebuild_person_indices();
        for (int32_t family_index : founder_family_indices) {
            const int64_t before = _persons.active_count;
            promote_person_for_family(family_index);
            if (_persons.active_count != before + 1) {
                out["ok"] = false;
                out["reason"] = "founder_person_bootstrap_failed";
                return out;
            }
            ++founder_person_count;
        }
        rebuild_person_indices();
        bind_notable_person_jobs();
        update_person_equity_shares();
    }

    // Opening food lots are pre-staffed from their owner-profession cohorts so
    // gathering/hunting produce on the first epoch. Construction-material techs
    // are not part of the survival-core grant, and these lots must not wait for
    // a later hire after an unavailable clamp.
    for (BuildingGroup &group : _buildings) {
        if (group.count <= 0 || group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_type_ids.size()) ||
            group.type_id >= static_cast<int32_t>(_building_types.size())) {
            continue;
        }
        const std::string &type_id = _building_type_ids[group.type_id];
        if (type_id != "gathering_ground" &&
            type_id != "stone_age_hunting_camp") {
            continue;
        }
        const int64_t owner_slots = saturating_mul(
            group.count,
            _building_types[group.type_id].owner_slots_per_building,
            _saturation_count);
        const int32_t owner_slot = find_cohort_slot(
            group.cell, group.owner_signature_id);
        if (owner_slot < 0 || owner_slots <= 0) continue;
        const int64_t fill = std::min(
            owner_slots,
            std::max<int64_t>(0, _population.population[owner_slot]));
        group.filled_owner = std::max(group.filled_owner, fill);
        _population.owner_employed[owner_slot] = std::max(
            _population.owner_employed[owner_slot], fill);
    }

    if (_configured_target_cohorts_per_slice == 0) {
        _target_cohorts_per_slice = _population.active_count <= 500000 ? 4000
            : (_population.active_count <= 2000000 ? 12000 : 30000);
    }
    if (_auto_slice_by_scale) {
        _cells_per_slice = std::clamp(_market.market_count, 1, 128);
    }
    if (_auto_building_slice_by_scale)
        _building_cells_per_slice = AUTO_BUILDING_CELLS_PER_SLICE;
    _epoch_days = choose_epoch_days(_population.active_count);
    _commit_lag_budget_days = std::max(0, locked_market_cycle_days() - 1);
    _last_committed_day = -1;
    _cell_last_settlement_day.resize(_cell_count);
    _cell_settlement_generation.assign(_cell_count, 0);
    _cell_price_stock_gen.assign(_cell_count, 0);
    _cell_owner_cash_gen.assign(_cell_count, 0);
    _cell_population_gen.assign(_cell_count, 0);
    _cell_building_structure_gen.assign(_cell_count, 0);
    _cell_technology_gen.assign(_cell_count, 0);
    _cell_resource_gen.assign(_cell_count, 0);
    _cell_trade_gen.assign(_cell_count, 0);
    _cell_effect_shortage_q16.assign(_cell_count, 0);
    _cell_essentials_shortage_q16.assign(_cell_count, 0);
    _cell_resource_abundance_q16.assign(_cell_count, 0);
    _fiscal_previous_country_handles.assign(
        static_cast<size_t>(_cell_count), 0);
    _fiscal_previous_requests.assign(
        static_cast<size_t>(_cell_count) * ACTIVE_TAX_KIND_COUNT, 0);
    const int32_t n = locked_market_cycle_days();
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _cell_last_settlement_day[cell] =
            static_cast<int64_t>(((cell % n) + n) % n) - n;
    }
    _settlement_watermark = -n;
    _settlement_newest_day = -1;
    _settlement_max_age_days = n - 1;
    _sample_day = -1;
    _current_day = -1;
    _commit_day = -1;
    _epoch_id = 0;
    _bootstrapped = true;
    _fatal = false;
    _fatal_reason.clear();
    rebuild_committed_summaries();
    initialize_settlements_from_population();
    for (int32_t cell : forced_named_cells) {
        _settlements.name_forced[cell] = 1;
        assign_settlement_name(cell);
    }
    if (founder_family_count > 0)
        rebuild_family_influences();
    _closing_totals = audit_totals();
    _opening_totals = _closing_totals;
    rebuild_incremental_audit_shadow();
    _closing_audit_force_full = true;
    if (_worker_enabled && _population.active_count >= _worker_market_threshold &&
        godot::WorkerThreadPool::get_singleton() != nullptr) {
        const int warm_tasks = _worker_tasks_hint > 0 ? _worker_tasks_hint : 16;
        auto warm_worker = [](int32_t begin, int32_t end) {
            volatile uint32_t local = 0;
            for (int32_t i = begin; i < end; ++i) local ^= static_cast<uint32_t>(i);
            (void)local;
        };
        parallel_for_range("pk_economy_warmup", 1024, warm_tasks, 1, warm_worker);
    }
    out["ok"] = true;
    out["cohort_count"] = _population.active_count;
    out["market_count"] = _market.market_count;
    out["good_count"] = _market.good_count;
    write_cadence_report(out);
    out["markets_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["building_output_efficiency_q16"] = _building_output_efficiency_q16;
    out["founder_family_count"] = founder_family_count;
    out["founder_person_count"] = founder_person_count;
    out["economy_high_speed_batching_enabled"] =
        _high_speed_batching_enabled;
    out["market_target_cohorts_per_slice"] = _target_cohorts_per_slice;
    out["estimated_market_slices_per_epoch"] =
        _estimated_market_slices_per_epoch;
    out["estimated_building_slices_per_epoch"] =
        _estimated_building_slices_per_epoch;
    out["estimated_total_slices_per_epoch"] =
        _estimated_total_slices_per_epoch;
    out["workload_deadline_feasible"] = _workload_deadline_feasible;
    out["workload_cycle_clamped"] = _workload_cycle_clamped;
    out["approximation_model"] = "rolling_cell_settlement_v19_class_good_elasticity";
    out["economy_accuracy_preset"] = _accuracy_preset == 0 ? "EXACT" :
        (_accuracy_preset == 1 ? "BALANCED" :
        (_accuracy_preset == 2 ? "FAST" : "CUSTOM"));
    out["economy_approximation_runtime_mode"] =
        _approximation_runtime_mode == 0 ? "OFF" :
        (_approximation_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    // Retained for report compatibility. Household workers are safe on large
    // ACTIVE worlds now that result and staging-touch sinks are thread-local.
    out["approximation_large_world_scalar_guard"] = false;
    out["approximation_authoritative"] =
        _approximation_runtime_mode == 2 && _accuracy_preset != 0 &&
        _approximation_cooldown_epochs_left == 0;
    out["accuracy_max_regret_q16"] = _accuracy_max_regret_q16;
    out["accuracy_household_tail_share_q16"] =
        _accuracy_household_tail_share_q16;
    out["accuracy_candidate_top_k"] = _accuracy_candidate_top_k;
    out["accuracy_choice_temperature_q16"] =
        _accuracy_choice_temperature_q16;
    out["accuracy_exact_probe_rate_q16"] = _accuracy_exact_probe_rate_q16;
    out["accuracy_fallback_cooldown_epochs"] =
        _accuracy_fallback_cooldown_epochs;
    out["merchant_count"] = static_cast<int64_t>(_merchant_slots.size());
    out["merchant_repairs"] = merchant_repairs;
    out["building_group_count"] = static_cast<int64_t>(_buildings.size());
    out["family_runtime_mode"] = _family_runtime_mode == 0 ? "OFF" :
        (_family_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["family_count"] = _families.active_count;
    out["family_membership_edge_count"] = static_cast<int64_t>(
        _family_memberships.size());
    out["family_ownership_edge_count"] = static_cast<int64_t>(
        _family_ownerships.size());
    out["family_trait_roll_count"] = static_cast<int64_t>(
        _family_traits.size());
    out["family_branch_count"] = static_cast<int64_t>(std::count(
        _family_influences.active.begin(), _family_influences.active.end(),
        uint8_t{1}));
    out["family_modifier_binding_count"] = static_cast<int64_t>(
        _family_modifier_bindings.size());
    out["family_effect_binding_count"] = static_cast<int64_t>(
        _family_effect_bindings.size());
    out["family_owned_output_row_count"] = static_cast<int64_t>(
        _family_owned_output_rows.size());
    out["family_industry_stat_count"] = static_cast<int64_t>(
        _family_industry_stats.size());
    out["family_trigger_binding_count"] = static_cast<int64_t>(
        _family_trigger_bindings.size());
    out["family_membership_edges_processed"] =
        _family_membership_edges_processed;
    out["family_ownership_edges_processed"] =
        _family_ownership_edges_processed;
    out["families_formed"] = _families_formed;
    out["families_dissolved"] = _families_dissolved;
    out["family_owner_jobs_filled"] = _family_owner_jobs_filled;
    out["family_owner_jobs_vacant"] = _family_owner_jobs_vacant;
    out["notable_person_runtime_mode"] = _person_runtime_mode == 0 ? "OFF" :
        (_person_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["notable_person_count"] = _persons.active_count;
    out["person_need_edge_count"] = static_cast<int64_t>(_person_needs.size());
    out["persons_promoted"] = _persons_promoted;
    out["persons_died"] = _persons_died;
    out["persons_migrated"] = _persons_migrated;
    out["person_jobs_bound"] = _person_jobs_bound;
    out["person_need_edges_processed"] = _person_need_edges_processed;
    out["memory_bytes"] = memory_bytes();
    return out;
}


Dictionary NativeEconomyRuntime::submit_commands(const Dictionary &batch) {
    Dictionary out;
    if (!_bootstrapped || _fatal || _save.active || _restore.active) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped"
                                         : (_fatal ? "economy_fatal" : "save_restore_active");
        return out;
    }
    const std::vector<int32_t> opcodes = packed_i32(batch, "opcodes");
    const std::vector<int64_t> days = packed_i64(batch, "effective_days");
    const std::vector<int64_t> sequences = packed_i64(batch, "sequences");
    const std::vector<int64_t> handles = packed_i64(batch, "target_handles");
    const std::vector<int32_t> i32_0 = packed_i32(batch, "i32_0");
    const std::vector<int32_t> i32_1 = packed_i32(batch, "i32_1");
    const std::vector<int64_t> i64_0 = packed_i64(batch, "i64_0");
    const std::vector<int64_t> i64_1 = packed_i64(batch, "i64_1");
    const size_t n = opcodes.size();
    if (days.size() != n || sequences.size() != n || handles.size() != n ||
        i32_0.size() != n || i32_1.size() != n || i64_0.size() != n || i64_1.size() != n) {
        out["ok"] = false;
        out["reason"] = "command_batch_size_mismatch";
        return out;
    }
    if (_pending_commands.size() + n > 1000000ULL) {
        out["ok"] = false;
        out["reason"] = "command_queue_capacity_exceeded";
        return out;
    }
    // Preflight the whole batch before mutating the queue.
    for (size_t i = 0; i < n; ++i) {
        const bool family_reward = is_family_ledger_command(opcodes[i]);
        const bool split_policy = opcodes[i] == COMMAND_FAMILY_SET_SPLIT_POLICY;
        const bool allowed_opcode =
            (opcodes[i] >= COMMAND_TRANSFER_TO_COHORT &&
             opcodes[i] <= COMMAND_TREASURY_SPONSORED_BUILD) ||
            family_reward || split_policy;
        if (!allowed_opcode || days[i] < 0 || sequences[i] < 0 ||
            (i64_0[i] < 0 && opcodes[i] != COMMAND_ADD_POPULATION &&
             opcodes[i] != COMMAND_FAMILY_PURCHASE_DISCOUNT &&
             opcodes[i] != COMMAND_FAMILY_ABSORB_ANONYMOUS)) {
            out["ok"] = false;
            out["reason"] = "command_entry_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        const bool treasury_build =
            opcodes[i] == COMMAND_TREASURY_SPONSORED_BUILD;
        if (!family_reward && !treasury_build && !split_policy &&
            opcodes[i] != COMMAND_ADD_STOCK &&
            opcodes[i] != COMMAND_REMOVE_STOCK &&
            opcodes[i] != COMMAND_COUNTRY_GOOD_TO_MARKET &&
            opcodes[i] != COMMAND_MARKET_GOOD_TO_COUNTRY) {
            int32_t slot = -1;
            if (!_population.valid_handle(static_cast<uint64_t>(handles[i]), slot)) {
                out["ok"] = false;
                out["reason"] = "stale_or_invalid_cohort_handle";
                out["index"] = static_cast<int64_t>(i);
                return out;
            }
        }
        if ((opcodes[i] == COMMAND_ADD_STOCK || opcodes[i] == COMMAND_REMOVE_STOCK ||
             opcodes[i] == COMMAND_COUNTRY_GOOD_TO_MARKET ||
             opcodes[i] == COMMAND_MARKET_GOOD_TO_COUNTRY) &&
            (i32_0[i] < 0 || i32_0[i] >= _market.market_count || i32_1[i] < 0 ||
             i32_1[i] >= _market.good_count)) {
            out["ok"] = false;
            out["reason"] = "command_market_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_ADD_STOCK || opcodes[i] == COMMAND_COUNTRY_GOOD_TO_MARKET) &&
            _merchant_primary_slot[i32_0[i]] < 0) {
            out["ok"] = false;
            out["reason"] = "cannot_add_stock_without_local_merchant";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_MOVE_POPULATION &&
             (i32_0[i] < 0 || i32_0[i] >= _cell_count)) ||
            (opcodes[i] == COMMAND_CHANGE_SIGNATURE &&
             (i32_0[i] < 0 || i32_0[i] >= static_cast<int32_t>(_signatures.size())))) {
            out["ok"] = false;
            out["reason"] = "command_structural_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_BUILD || opcodes[i] == COMMAND_DEMOLISH ||
             treasury_build) &&
            (i32_0[i] < 0 || i32_0[i] >= _cell_count || i32_1[i] < 0 ||
             i32_1[i] >= static_cast<int32_t>(_building_types.size()) || i64_0[i] <= 0)) {
            out["ok"] = false;
            out["reason"] = "command_building_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (treasury_build &&
            (i64_0[i] != 1 ||
             i64_1[i] != OWNERSHIP_TREASURY_SPONSORED_PRIVATE ||
             _country_runtime == nullptr ||
             !_country_runtime->valid_handle(handles[i]))) {
            out["ok"] = false;
            out["reason"] = i64_1[i] != OWNERSHIP_TREASURY_SPONSORED_PRIVATE
                ? "unsupported_ownership_policy"
                : "command_treasury_build_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (family_reward) {
            Command probe;
            probe.opcode = opcodes[i];
            probe.target_handle = static_cast<uint64_t>(handles[i]);
            probe.i32_0 = i32_0[i];
            probe.i32_1 = i32_1[i];
            probe.i64_0 = i64_0[i];
            probe.i64_1 = i64_1[i];
            if (!family_ledger_command_preflight(probe)) {
                out["ok"] = false;
                out["reason"] = "command_family_reward_target_invalid";
                out["index"] = static_cast<int64_t>(i);
                return out;
            }
        }
        if (split_policy) {
            Command probe;
            probe.opcode = opcodes[i];
            probe.target_handle = static_cast<uint64_t>(handles[i]);
            probe.i32_0 = i32_0[i];
            probe.i32_1 = i32_1[i];
            probe.i64_0 = i64_0[i];
            probe.i64_1 = i64_1[i];
            if (!family_split_policy_command_preflight(probe)) {
                out["ok"] = false;
                out["reason"] = "command_family_split_policy_invalid";
                out["index"] = static_cast<int64_t>(i);
                return out;
            }
        }
    }
    for (size_t i = 0; i < n; ++i) {
        _pending_commands.push_back({opcodes[i], days[i], sequences[i],
                                     static_cast<uint64_t>(handles[i]), i32_0[i], i32_1[i],
                                     i64_0[i], i64_1[i], _next_submit_order++});
    }
    out["ok"] = true;
    out["accepted"] = static_cast<int64_t>(n);
    out["queued"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool NativeEconomyRuntime::family_ledger_command_preflight(const Command &cmd) const {
    if (!is_family_ledger_command(cmd.opcode)) return false;
    int32_t branch = -1;
    if (!_family_influences.valid_handle(cmd.target_handle, branch)) return false;
    if (cmd.opcode == COMMAND_FAMILY_FREE_BUILDING)
        return cmd.i32_0 >= 0 && cmd.i32_0 <= 1 && cmd.i64_0 > 0 &&
            family_free_building_type_id(cmd) >= 0;
    if (cmd.opcode == COMMAND_FAMILY_POPULATION_REWARD)
        return ((cmd.i32_0 >= 0 && cmd.i32_0 <= 1) || cmd.i32_0 == -1) &&
            cmd.i64_0 > 0;
    if (cmd.opcode == COMMAND_FAMILY_ABSORB_ANONYMOUS) {
        if (cmd.i32_0 == 0) return cmd.i64_0 > 0;
        if (cmd.i32_0 == 1) return cmd.i64_0 >= 0;
        return false;
    }
    if (cmd.opcode == COMMAND_FAMILY_PURCHASE_DISCOUNT)
        return cmd.i64_0 >= 0 && cmd.i64_0 <= 4 * Q16_ONE;
    return false;
}

bool NativeEconomyRuntime::family_split_policy_command_preflight(
        const Command &cmd) const {
    if (cmd.opcode != COMMAND_FAMILY_SET_SPLIT_POLICY) return false;
    const int32_t mode = cmd.i32_0 & static_cast<int32_t>(FAMILY_FLAG_SPLIT_MODE_MASK);
    const int32_t gifts = cmd.i32_0 & static_cast<int32_t>(
        FAMILY_FLAG_SPLIT_GIFT_BUILDING | FAMILY_FLAG_SPLIT_GIFT_POPULATION);
    if ((cmd.i32_0 & ~static_cast<int32_t>(FAMILY_FLAG_SPLIT_POLICY_MASK)) != 0)
        return false;
    if (mode != 0 &&
        mode != static_cast<int32_t>(FAMILY_FLAG_SPLIT_RETAIN_ONLY) &&
        mode != static_cast<int32_t>(FAMILY_FLAG_SPLIT_BONUS_WEIGHT) &&
        mode != static_cast<int32_t>(FAMILY_FLAG_SPLIT_REPLACE))
        return false;
    (void)gifts;
    if (cmd.i64_0 < 0 || cmd.i64_0 > 255) return false;
    int32_t family = -1;
    int32_t branch = -1;
    if (_families.valid_handle(cmd.target_handle, family)) return true;
    return _family_influences.valid_handle(cmd.target_handle, branch) &&
        _families.valid_handle(_family_influences.family_handle[branch], family);
}

bool NativeEconomyRuntime::validate_command_pod(const Command &cmd,
                                                std::string &error) const {
    const bool family_reward = is_family_ledger_command(cmd.opcode);
    const bool split_policy = cmd.opcode == COMMAND_FAMILY_SET_SPLIT_POLICY;
    const bool opcode_ok =
        (cmd.opcode >= COMMAND_TRANSFER_TO_COHORT &&
         cmd.opcode <= COMMAND_SETTLE_FAMILY_EXPEDITION) ||
        family_reward || split_policy;
    if (!opcode_ok ||
        cmd.effective_day < 0 || cmd.sequence < 0 ||
        (cmd.i64_0 < 0 && cmd.opcode != COMMAND_ADD_POPULATION &&
         cmd.opcode != COMMAND_FAMILY_PURCHASE_DISCOUNT &&
         cmd.opcode != COMMAND_FAMILY_ABSORB_ANONYMOUS)) {
        error = "command_entry_invalid";
        return false;
    }
    const bool expedition_settle =
        cmd.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION;
    const bool expedition_player =
        cmd.opcode == COMMAND_START_FAMILY_EXPEDITION ||
        cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION;
    if (!family_reward && !split_policy && !expedition_settle &&
        !expedition_player &&
        cmd.opcode != COMMAND_ADD_STOCK &&
        cmd.opcode != COMMAND_REMOVE_STOCK &&
        cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
        cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY) {
        int32_t slot = -1;
        if (!_population.valid_handle(cmd.target_handle, slot)) {
            error = "stale_or_invalid_cohort_handle";
            return false;
        }
    }
    if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_REMOVE_STOCK ||
         cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
         cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY) &&
        (cmd.i32_0 < 0 || cmd.i32_0 >= _market.market_count ||
         cmd.i32_1 < 0 || cmd.i32_1 >= _market.good_count)) {
        error = "command_market_target_invalid";
        return false;
    }
    if ((cmd.opcode == COMMAND_ADD_STOCK ||
         cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET) &&
        (cmd.i32_0 < 0 || cmd.i32_0 >= static_cast<int32_t>(
            _merchant_primary_slot.size()) ||
         _merchant_primary_slot[cmd.i32_0] < 0)) {
        error = "cannot_add_stock_without_local_merchant";
        return false;
    }
    if ((cmd.opcode == COMMAND_MOVE_POPULATION &&
         (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count)) ||
        (cmd.opcode == COMMAND_CHANGE_SIGNATURE &&
         (cmd.i32_0 < 0 || cmd.i32_0 >= static_cast<int32_t>(
             _signatures.size())))) {
        error = "command_structural_target_invalid";
        return false;
    }
    if ((cmd.opcode == COMMAND_BUILD || cmd.opcode == COMMAND_DEMOLISH) &&
        (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count || cmd.i32_1 < 0 ||
         cmd.i32_1 >= static_cast<int32_t>(_building_types.size()) ||
         cmd.i64_0 <= 0)) {
        error = "command_building_target_invalid";
        return false;
    }
    if (family_reward && !family_ledger_command_preflight(cmd)) {
        error = "command_family_reward_target_invalid";
        return false;
    }
    if (split_policy && !family_split_policy_command_preflight(cmd)) {
        error = "command_family_split_policy_invalid";
        return false;
    }
    if (expedition_settle) {
        int32_t expedition = -1;
        if (!_family_expeditions.valid_handle(cmd.target_handle, expedition) ||
            cmd.i32_0 != _family_expeditions.target_cell[expedition] ||
            cmd.i64_1 != static_cast<int64_t>(
                _family_expeditions.country_handle[expedition])) {
            error = "colonization_settlement_target_invalid";
            return false;
        }
    }
    if (expedition_player) {
        if (cmd.opcode == COMMAND_START_FAMILY_EXPEDITION) {
            int32_t family = -1;
            if (!_families.valid_handle(cmd.target_handle, family) ||
                cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count ||
                cmd.i32_1 < 0 || cmd.i32_1 >= _cell_count ||
                cmd.i64_0 < 1) {
                error = "colonization_command_invalid";
                return false;
            }
        } else {
            int32_t expedition = -1;
            if (!_family_expeditions.valid_handle(cmd.target_handle, expedition)) {
                error = "colonization_expedition_invalid";
                return false;
            }
        }
    }
    return true;
}

int32_t NativeEconomyRuntime::preflight_effect_commands_pod(
        const EffectCommand *commands, size_t count, std::string &error) const {
    error.clear();
    if (!_bootstrapped || _save.active || _restore.active) {
        error = !_bootstrapped ? "economy_not_bootstrapped" :
            "save_restore_active";
        return EFFECT_PREFLIGHT_RETRY;
    }
    if (_fatal) {
        error = "economy_fatal";
        return EFFECT_PREFLIGHT_REJECT;
    }
    if ((commands == nullptr && count != 0) || count > 1000000ULL) {
        error = "effect_economy_command_batch_invalid";
        return EFFECT_PREFLIGHT_REJECT;
    }
    for (size_t i = 0; i < count; ++i) {
        const EffectCommand &source = commands[i];
        if (source.idempotency_key == 0 || source.sequence < 0) {
            error = "effect_economy_command_identity_invalid";
            return EFFECT_PREFLIGHT_REJECT;
        }
        // An already accepted idempotency key is safe to replay regardless of
        // whether its generation-safe target has since retired.
        if (_effect_idempotency_requests.find(source.idempotency_key) !=
                _effect_idempotency_requests.end())
            continue;
        Command command;
        command.opcode = source.opcode;
        command.effective_day = source.effective_day;
        command.sequence = source.sequence;
        command.target_handle = source.target_handle;
        command.i32_0 = source.i32_0;
        command.i32_1 = source.i32_1;
        command.i64_0 = source.i64_0;
        command.i64_1 = source.i64_1;
        command.effect_idempotency_key = source.idempotency_key;
        if (!validate_command_pod(command, error)) {
            error = "effect_economy_preflight_" + error;
            return EFFECT_PREFLIGHT_REJECT;
        }
    }
    return EFFECT_PREFLIGHT_ACCEPT;
}

bool NativeEconomyRuntime::submit_effect_commands_pod(
        const EffectCommand *commands, size_t count,
        std::vector<int64_t> &request_ids, std::string &error) {
    request_ids.clear();
    if (!_bootstrapped || _fatal || _save.active || _restore.active) {
        error = !_bootstrapped ? "economy_not_bootstrapped" :
            (_fatal ? "economy_fatal" : "save_restore_active");
        return false;
    }
    if ((commands == nullptr && count != 0) || count > 1000000ULL) {
        error = "effect_economy_command_batch_invalid";
        return false;
    }
    std::vector<Command> staged;
    staged.reserve(count);
    request_ids.reserve(count);
    std::unordered_map<uint64_t, int64_t> staged_idempotency;
    for (size_t i = 0; i < count; ++i) {
        const EffectCommand &source = commands[i];
        if (source.idempotency_key == 0 || source.sequence < 0) {
            error = "effect_economy_command_identity_invalid";
            return false;
        }
        const auto existing = _effect_idempotency_requests.find(
            source.idempotency_key);
        if (existing != _effect_idempotency_requests.end()) {
            request_ids.push_back(existing->second);
            continue;
        }
        const auto duplicate = staged_idempotency.find(source.idempotency_key);
        if (duplicate != staged_idempotency.end()) {
            request_ids.push_back(duplicate->second);
            continue;
        }
        Command command;
        command.opcode = source.opcode;
        command.effective_day = source.effective_day;
        command.sequence = source.sequence;
        command.target_handle = source.target_handle;
        command.i32_0 = source.i32_0;
        command.i32_1 = source.i32_1;
        command.i64_0 = source.i64_0;
        command.i64_1 = source.i64_1;
        command.effect_request_id = _next_effect_request_id +
            static_cast<int64_t>(staged.size());
        command.effect_idempotency_key = source.idempotency_key;
        if (!validate_command_pod(command, error)) {
            error = "effect_economy_preflight_" + error;
            return false;
        }
        staged_idempotency.emplace(source.idempotency_key,
            command.effect_request_id);
        request_ids.push_back(command.effect_request_id);
        staged.push_back(command);
    }
    if (_pending_commands.size() + staged.size() > 1000000ULL ||
        _effect_command_results.size() + staged.size() > 1000000ULL ||
        _next_effect_request_id > std::numeric_limits<int64_t>::max() -
            static_cast<int64_t>(staged.size())) {
        error = "effect_economy_queue_capacity_exceeded";
        return false;
    }
    const bool immediate_family_settlement = !_epoch_active &&
        staged.size() == 1 &&
        staged.front().opcode == COMMAND_SETTLE_FAMILY_EXPEDITION &&
        staged.front().effective_day <= _current_day;
    for (Command &command : staged) {
        command.submit_order = _next_submit_order++;
        _effect_idempotency_requests.emplace(command.effect_idempotency_key,
            command.effect_request_id);
        EffectCommandResult &result = _effect_command_results[
            command.effect_request_id];
        if (immediate_family_settlement) {
            std::string commit_error;
            const bool applied = apply_settle_family_expedition(
                command, commit_error);
            result.complete = 1;
            result.ok = applied ? 1 : 0;
            result.reason = applied ? std::string{} :
                (commit_error.empty()
                    ? "effect_economy_commit_failed" : commit_error);
        } else if (command.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION) {
            queue_family_settlement_command(command);
        } else {
            _pending_commands.push_back(command);
        }
    }
    _next_effect_request_id += static_cast<int64_t>(staged.size());
    return true;
}

bool NativeEconomyRuntime::effect_command_result_pod(int64_t request_id,
        bool &complete, bool &ok, std::string &reason) const {
    complete = false;
    ok = false;
    reason.clear();
    const auto found = _effect_command_results.find(request_id);
    if (found == _effect_command_results.end()) {
        reason = "effect_economy_request_unknown";
        return false;
    }
    complete = found->second.complete != 0;
    ok = found->second.ok != 0;
    reason = found->second.reason;
    return true;
}

bool NativeEconomyRuntime::has_pending_effect_commands() const {
    for (const auto &entry : _effect_command_results)
        if (entry.second.complete == 0) return true;
    return false;
}


} // namespace pk

#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include "modifier_api.h"
#include "economy_host_port.h"
#include "parallel_dispatcher.h"
#include "runtime_economy_pod.h"

#include <algorithm>
#include <limits>
#include <numeric>
#include <unordered_map>
#include <unordered_set>

#include <godot_cpp/variant/utility_functions.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

void NativeEconomyRuntime::rebuild_building_upgrade_requirements() {
    _building_upgrade_required_tiers.assign(_building_upgrade_family_ids.size(), 0);
    for (size_t type = 0; type < _building_upgrade_family_indices.size(); ++type) {
        const int32_t family = _building_upgrade_family_indices[type];
        const int32_t tier = type < _building_upgrade_tiers.size()
            ? _building_upgrade_tiers[type] : -1;
        if (family < 0 ||
            static_cast<size_t>(family) >= _building_upgrade_required_tiers.size() ||
            tier < 0 || tier >= 32) continue;
        _building_upgrade_required_tiers[static_cast<size_t>(family)] |=
            uint32_t{1} << static_cast<uint32_t>(tier);
    }
    ++_building_upgrade_catalog_builds;
    _building_upgrade_catalog_rows += _building_upgrade_family_indices.size();
}

Dictionary NativeEconomyRuntime::configure(const Dictionary &catalog, const Dictionary &profile,
                                           int32_t cell_count, int64_t seed) {
    reset("reconfigure");
    _worker_natural_resources.clear();
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
    rebuild_building_upgrade_requirements();
    const auto resolve_tax_stats = [&](const char *kind,
                                       const std::vector<std::string> &item_ids,
                                       std::vector<int32_t> &out_ids) {
        out_ids.clear();
        out_ids.reserve(item_ids.size());
        for (const std::string &item : item_ids) {
            const std::string key = std::string("country.tax.") + kind + "." +
                item + ".rate_bp";
            const int32_t id = _modifier_runtime != nullptr
                ? modifier_api::stat_id_for_key(*_modifier_runtime, key) : -1;
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
        ? modifier_api::stat_id_for_key(*_modifier_runtime, "economy.city.birth_factor") : -1;
    _city_consumption_stat_id = _modifier_runtime != nullptr
        ? modifier_api::stat_id_for_key(*_modifier_runtime, "economy.city.consumption_factor") : -1;
    _city_need_consumption_stat_ids.clear();
    _city_need_consumption_stat_ids.reserve(_need_ids.size());
    for (const std::string &need_id : _need_ids) {
        const std::string key = "economy.city.need." + need_id +
            ".consumption_factor";
        _city_need_consumption_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime, key) : -1);
    }
    _city_good_consumption_stat_ids.clear();
    _city_good_consumption_stat_ids.reserve(_good_ids.size());
    _city_good_output_stat_ids.clear();
    _city_good_output_stat_ids.reserve(_good_ids.size());
    for (const std::string &good_id : _good_ids) {
        const std::string key = "economy.city.good." + good_id +
            ".consumption_factor";
        _city_good_consumption_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime, key) : -1);
        _city_good_output_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "economy.city.good." + good_id + ".output_factor") : -1);
    }
    _city_building_output_stat_ids.clear();
    _city_building_output_stat_ids.reserve(_building_type_ids.size());
    for (const std::string &building_id : _building_type_ids) {
        _city_building_output_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
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
            ? modifier_api::stat_id_for_key(*_modifier_runtime, key) : -1);
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
            ? modifier_api::stat_id_for_key(*_modifier_runtime, key) : -1);
        _country_good_input_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "country.input.good." + good_id + "_factor") : -1);
        _country_good_consumption_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "country.consumption.good." + good_id + "_factor") : -1);
    }
    // Per-good trade factors: same generated-key family as the three vectors
    // above, resolved once here so the epoch capture only walks dense ids.
    // A good without the stat resolves to -1, which is LEGAL -- only the goods
    // that actually declare `country.trade.good.<good>.{capacity,speed}_factor`
    // get a non-neutral value. Do not add these to the `any_of(id < 0)`
    // failure gate below: that gate means "the catalog is missing something
    // every good must have", and these ten keys are declared for seven goods
    // out of the whole good list.
    _country_good_trade_capacity_stat_ids.clear();
    _country_good_trade_speed_stat_ids.clear();
    _country_good_trade_capacity_stat_ids.reserve(_good_ids.size());
    _country_good_trade_speed_stat_ids.reserve(_good_ids.size());
    for (const std::string &good_id : _good_ids) {
        _country_good_trade_capacity_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "country.trade.good." + good_id + ".capacity_factor") : -1);
        _country_good_trade_speed_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "country.trade.good." + good_id + ".speed_factor") : -1);
    }
    _country_resource_use_stat_ids.clear();
    _country_resource_generation_stat_ids.clear();
    for (const std::string &resource_id : _resource_ids) {
        _country_resource_use_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "country.resource." + resource_id + ".use_factor") : -1);
        _country_resource_generation_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "country.resource." + resource_id +
                ".managed_generation_factor") : -1);
    }
    // X16: per-profession tax tolerance and satisfaction bias. Resolved in
    // `_profession_ids` order so the arrays can be indexed by `profession_id`
    // directly. -1 means "this profession has no such stat", which the reader treats
    // as the default (1.0 / 0 bp) instead of calling into Modifier.
    _profession_tax_tolerance_stat_ids.clear();
    _profession_satisfaction_bp_stat_ids.clear();
    _profession_tax_tolerance_stat_ids.reserve(_profession_ids.size());
    _profession_satisfaction_bp_stat_ids.reserve(_profession_ids.size());
    for (const std::string &profession_id : _profession_ids) {
        _profession_tax_tolerance_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "economy.profession." + profession_id +
                ".tax_tolerance_factor") : -1);
        _profession_satisfaction_bp_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime,
                "economy.profession." + profession_id +
                ".satisfaction_bp") : -1);
    }
    _political_class_satisfaction_bp_stat_ids.clear();
    _political_class_satisfaction_bp_stat_ids.reserve(_political_class_ids.size());
    for (const std::string &class_id : _political_class_ids) {
        _political_class_satisfaction_bp_stat_ids.push_back(
            _modifier_runtime != nullptr
                ? modifier_api::stat_id_for_key(*_modifier_runtime,
                    "economy.class." + class_id + ".satisfaction_bp")
                : -1);
    }
    const auto resolve_geography_stats = [&](const std::string &kind,
            const std::vector<std::string> &geography_ids,
            std::vector<int32_t> &target) {
        target.clear();
        target.reserve(geography_ids.size() * _modifier_sector_ids.size());
        for (const std::string &geography_id : geography_ids)
            for (const std::string &sector_id : _modifier_sector_ids)
                target.push_back(_modifier_runtime != nullptr
                    ? modifier_api::stat_id_for_key(*_modifier_runtime, "country.output." + kind +
                        "." + geography_id + "." + sector_id + "_factor") : -1);
    };
    resolve_geography_stats("terrain", _modifier_terrain_ids,
                            _country_terrain_sector_output_stat_ids);
    resolve_geography_stats("landform", _modifier_landform_ids,
                            _country_landform_sector_output_stat_ids);
    _country_production_input_stat_id = _modifier_runtime != nullptr
        ? modifier_api::stat_id_for_key(*_modifier_runtime, "country.production.input_factor") : -1;
    _country_household_consumption_stat_id = _modifier_runtime != nullptr
        ? modifier_api::stat_id_for_key(*_modifier_runtime,
            "country.household.consumption_factor") : -1;
    _family_scoped_output_stat_id = _modifier_runtime != nullptr
        ? modifier_api::stat_id_for_key(*_modifier_runtime, "economy.city.output_factor") : -1;
    _country_resource_use_stat_id = _modifier_runtime != nullptr
        ? modifier_api::stat_id_for_key(*_modifier_runtime, "country.resource.use_factor") : -1;
    _country_population_death_stat_id = _modifier_runtime != nullptr
        ? modifier_api::stat_id_for_key(*_modifier_runtime, "country.population.death_factor") : -1;
    _country_building_output_stat_ids.clear();
    _country_building_output_stat_ids.reserve(_building_type_ids.size());
    for (const std::string &building_id : _building_type_ids) {
        const std::string key =
            "country.output.building." + building_id + "_factor";
        _country_building_output_stat_ids.push_back(_modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime, key) : -1);
    }
    static const char *CLIMATE_LOSS_STATS[4] = {
        "country.climate.drought_loss_factor",
        "country.climate.flood_loss_factor",
        "country.climate.cold_stress_factor",
        "country.climate.heat_stress_factor",
    };
    for (size_t i = 0; i < _country_climate_loss_stat_ids.size(); ++i)
        _country_climate_loss_stat_ids[i] = _modifier_runtime != nullptr
            ? modifier_api::stat_id_for_key(*_modifier_runtime, CLIMATE_LOSS_STATS[i]) : -1;
    static const char *CLIMATE_HAZARDS[4] = {
        "drought", "flood", "cold_stress", "heat_stress",
    };
    _country_climate_profile_loss_stat_ids.clear();
    _country_climate_profile_loss_stat_ids.reserve(
        _production_climate_profile_ids.size() * 4U);
    for (const std::string &profile_id : _production_climate_profile_ids) {
        for (const char *hazard : CLIMATE_HAZARDS) {
            const std::string key = "country.climate.profile." + profile_id +
                "." + hazard + "_loss_factor";
            _country_climate_profile_loss_stat_ids.push_back(
                _modifier_runtime != nullptr
                    ? modifier_api::stat_id_for_key(*_modifier_runtime, key) : -1);
        }
    }
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
            [](int32_t id) { return id < 0; }) || std::any_of(
            _country_climate_profile_loss_stat_ids.begin(),
            _country_climate_profile_loss_stat_ids.end(),
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
    _employment_diagnostic_cell = -1;
    _employment_diagnostic_day = -1;
    _employment_diagnostics.clear();
    _family_clamp_traces.clear();
    population_store().clear(cell_count);
    families_store().clear();
    family_expeditions_store().clear();
    family_expedition_route_cells().clear();
    family_expedition_route_costs().clear();
    family_expedition_payloads().clear();
    family_expedition_person_handles().clear();
    family_expedition_cargo().clear();
    family_expedition_kit_buildings().clear();
    family_expedition_missing_good_ids().clear();
    family_expedition_missing_good_quantities().clear();
    _family_expedition_target_index.clear();
    _family_expedition_due_heap.clear();
    _colonization_receipts.clear();
    {
        std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
        _worker_command_inbox->commands.clear();
    }
    clear_procurement_runtime_state(true);
    _next_colonization_receipt_id = 1;
    reset_country_ai_pending();
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
    family_influences().clear();
    persons_store().clear();
    family_memberships().clear();
    _family_csr_edge_count = SIZE_MAX;
    _family_demography_rows.clear();
    _family_owner_seat_rows.clear();
    family_ownerships().clear();
    family_trait_rolls().clear();
    _family_behavior_factor_offsets.clear();
    _family_behavior_factor_rows.clear();
    _family_behavior_cache_dirty = true;
    _family_behavior_cache_dirty_reasons =
        FAMILY_BEHAVIOR_DIRTY_INITIAL;
    _family_behavior_cache_last_reasons = 0;
    _family_behavior_cache_rebuilds = 0;
    _family_behavior_cache_skips = 0;
    _track_b_family_cache_last_day = std::numeric_limits<int64_t>::min();
    _family_behavior_metric_contexts_built = 0;
    _family_behavior_condition_edges_evaluated = 0;
    _family_behavior_cache_ms = 0.0;
    _family_behavior_class_rows = 0;
    _family_purchase_factor_q16.clear();
    _family_investment_factor_q16.clear();
    _family_birth_factor_q16.clear();
    _family_absorb_bonus_q16.clear();
    _family_colonization_population_reward.clear();
    _family_colonization_population_reward_pending.clear();
    _pending_family_split_gifts.clear();
    _family_policy_stamped_cells.clear();
    _epoch_cell_rain_event_threshold_q16.clear();
    _epoch_cell_cold_capacity_factor_q16.clear();
    _epoch_cell_sector_output_factor_q16.clear();
    _family_trait_commands.clear();
    clear_family_founding_state();
    _family_effect_bindings.clear();
    _family_effect_binding_by_instance.clear();
    _family_effect_instances_by_branch.clear();
    _family_effect_instances_by_cell.clear();
    _family_industry_stats.clear();
    _family_owned_output_rows.clear();
    _family_modifier_bindings.clear();
    _family_trigger_bindings.clear();
    person_needs().clear();
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
    market_store().clear();
    _market_signals.clear(cell_count);
    mark_market_signal_full_rebuild("configure");
    mark_labor_signal_full_rebuild("configure");
    mark_input_reserve_full_rebuild("configure");
    clear_building_groups();
    _building_factor_cache.clear();
    _pending_building_topology_rebuild = false;
    _building_handle_index_clean = false;
    _building_group_order_scratch.clear();
    _building_group_is_new_scratch.clear();
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
    _cell_temperature_annual_q16.clear();
    _cell_temperature_anomaly_q16.clear();
    _cell_hazard_today_mask.clear();
    _cell_dry_streak_days.clear();
    _cell_days_since_hazard.clear();
    _cell_previous_hazard_mask.clear();
    _cell_weather_type.clear();
    _cell_cover.clear();
    _epoch_market_ids.clear();
    _economy_live_cells.clear();
    {
        std::lock_guard<std::mutex> lock(_economy_live_cells_published_mutex);
        _economy_live_cells_published.reset();
    }
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    _epoch_plan_cells.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    clear_pending_construction();
    _investment_pending_by_cell_type.clear();
    _investment_existing_by_cell_type.clear();
    _investment_prepared_epoch = -1;
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
    _cell_temperature_annual_q16.assign(cell_count, Q16_ONE / 2);
    _cell_temperature_anomaly_q16.assign(cell_count, 0);
    _cell_hazard_today_mask.assign(cell_count, 0);
    _cell_dry_streak_days.assign(cell_count, 0);
    _cell_days_since_hazard.assign(cell_count, 0);
    _cell_previous_hazard_mask.assign(cell_count, 0);
    _cell_weather_type.assign(cell_count, 0);
    _cell_cover.assign(cell_count, 0);
    _cell_living_cost_per_capita.assign(cell_count, 0);
    _epoch_cell_development_q16.assign(cell_count, 0);
    _cell_social_pressure_level.assign(cell_count, 0);
    _visual_living_level.assign(cell_count, BUILDING_VISUAL_UNKNOWN);
    _visual_rich_bucket.assign(cell_count, BUILDING_VISUAL_UNKNOWN);
    _visual_poor_bucket.assign(cell_count, BUILDING_VISUAL_UNKNOWN);
        _cell_support_ema_q16.assign(cell_count, Q16_ONE);
        _cell_carrying_k_geo.assign(cell_count, 0);
        _cell_carrying_k_eff.assign(cell_count, 0);
    _cell_carrying_surplus_q16.assign(cell_count, Q16_ONE);
    _cell_carrying_sat_q16.assign(cell_count, Q16_ONE);
    // Military v1: default ration satisfaction is 1.0 so a world without
    // soldiers keeps the pre-military result bit-for-bit.
    _military_ration_sat_q16.assign(cell_count, static_cast<int32_t>(Q16_ONE));
    _military_ration_sat_present.assign(cell_count, 0);
    _cell_garrison_heads.assign(cell_count, 0);
    _cell_garrison_present.assign(cell_count, 0);
    _stratum_mobilization.clear(cell_count);
    _cell_carrying_family_surplus_q16.assign(
        static_cast<size_t>(cell_count) * CARRYING_FAMILY_COUNT, Q16_ONE);
        _cell_carrying_family_bindable.assign(
            static_cast<size_t>(cell_count) * CARRYING_FAMILY_COUNT, 0);
        _cell_food_output_eq_period.assign(cell_count, 0);
        _cell_food_input_eq_period.assign(cell_count, 0);
        _cell_food_import_eq_period.assign(cell_count, 0);
        _cell_food_export_eq_period.assign(cell_count, 0);
        _cell_food_access_eq_period.assign(cell_count, 0);
        _cell_food_output_eq_previous.assign(cell_count, 0);
        _cell_food_input_eq_previous.assign(cell_count, 0);
        _cell_food_import_eq_previous.assign(cell_count, 0);
        _cell_food_export_eq_previous.assign(cell_count, 0);
        _cell_food_access_eq_previous.assign(cell_count, 0);
        _cell_food_flow_valid.assign(cell_count, 0);
        _food_flow_previous_period_days = 0;
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
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63) / 64);
    if (_country_runtime == nullptr || !country_reads().economy_available()) {
        reset("country_runtime_required");
        out["ok"] = false;
        out["reason"] = "country_runtime_required";
        return out;
    }
    // X10: copy the immutable technology->domain table exactly once. Economy
    // must not keep reading live Country catalog state across the authority
    // boundary, and the four domain masks are static for the whole session.
    std::vector<int32_t> technology_domains;
    if (!country_reads().copy_technology_domains(technology_domains) ||
        technology_domains.size() != _technology_ids.size()) {
        reset("country_technology_domains_invalid");
        out["ok"] = false;
        out["reason"] = "country_technology_domains_invalid";
        return out;
    }
    // The metric contract has four domain columns. Keep the first four distinct
    // authored domains if a future catalog adds more; diagnostics expose the
    // exact count so the expansion can be reviewed without changing metric ids.
    _technology_domain_ids.clear();
    for (const int32_t domain : technology_domains) {
        if (domain < 0) {
            reset("country_technology_domain_out_of_range");
            out["ok"] = false;
            out["reason"] = "country_technology_domain_out_of_range";
            return out;
        }
        if (std::find(_technology_domain_ids.begin(),
                      _technology_domain_ids.end(), domain) ==
            _technology_domain_ids.end()) {
            _technology_domain_ids.push_back(domain);
        }
    }
    std::sort(_technology_domain_ids.begin(), _technology_domain_ids.end());
    if (_technology_domain_ids.size() > 4)
        _technology_domain_ids.resize(4);
    // One 64-bit mask per technology word per retained domain. Indexing is
    // [domain_slot * technology_word_count + word], so a catalog wider than one
    // word works without a second representation.
    _technology_domain_masks.assign(
        _technology_domain_ids.size() *
            static_cast<size_t>(std::max(0, _technology_words)), 0);
    for (size_t technology = 0;
         technology < technology_domains.size(); ++technology) {
        const int32_t domain = technology_domains[technology];
        const auto domain_it = std::find(_technology_domain_ids.begin(),
                                         _technology_domain_ids.end(), domain);
        if (domain_it == _technology_domain_ids.end()) continue;
        const size_t domain_slot = static_cast<size_t>(
            std::distance(_technology_domain_ids.begin(), domain_it));
        const size_t mask_index =
            domain_slot *
                static_cast<size_t>(_technology_words) +
            technology / 64U;
        _technology_domain_masks[mask_index] |=
            uint64_t{1} << (technology % 64U);
    }
    _configured = true;
    _stage = Stage::IDLE;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["catalog_hash"] = _catalog_hash.get();
    out["cell_count"] = _cell_count.get();
    out["good_count"] = static_cast<int32_t>(_good_ids.size());
    out["signature_count"] = static_cast<int32_t>(_signatures.size());
    out["building_type_count"] = static_cast<int32_t>(_building_types.size());
    out["family_catalog_hash"] = _family_catalog_hash.get();
    out["money_scale"] = MONEY_SCALE;
    out["goods_scale"] = GOODS_SCALE;
    out["ratio_scale"] = Q16_ONE;
    out["rate_scale"] = Q32_ONE;
    return out;
}


} // namespace pk

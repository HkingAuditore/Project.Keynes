#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <numeric>
#include <unordered_set>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

bool NativeEconomyRuntime::compile_catalog(const Dictionary &catalog, std::string &error) {
    _profession_ids = packed_strings(catalog, "profession_ids");
    _ethnicity_ids = packed_strings(catalog, "ethnicity_ids");
    _good_ids = packed_strings(catalog, "good_ids");
    _family_corn_good_id = -1;
    for (size_t i = 0; i < _good_ids.size(); ++i) {
        if (_good_ids[i] == "corn_grain") {
            _family_corn_good_id = static_cast<int32_t>(i);
            break;
        }
    }
    _plan_ids = packed_strings(catalog, "plan_ids");
    _technology_ids = packed_strings(catalog, "technology_ids");
    const std::vector<int32_t> technology_prerequisite_offsets = packed_i32(
        catalog, "technology_prerequisite_offsets");
    const std::vector<int32_t> technology_prerequisites = packed_i32(
        catalog, "technology_prerequisites");
    _water_tech_river = -1;
    _water_tech_shallow = -1;
    _water_tech_far = -1;
    _water_tech_deep = -1;
    if (_profession_ids.empty() || _ethnicity_ids.empty() || _good_ids.empty() || _plan_ids.empty()) {
        error = "catalog_id_table_empty";
        return false;
    }
    if (_good_ids.size() > 256) {
        error = "good_count_exceeds_256";
        return false;
    }
    auto unique_sorted = [&](const std::vector<std::string> &ids, const char *name) {
        if (!std::is_sorted(ids.begin(), ids.end()) ||
            std::adjacent_find(ids.begin(), ids.end()) != ids.end()) {
            error = std::string(name) + "_ids_not_sorted_unique";
            return false;
        }
        return true;
    };
    if (!unique_sorted(_profession_ids, "profession") ||
        !unique_sorted(_ethnicity_ids, "ethnicity") ||
        !unique_sorted(_good_ids, "good") || !unique_sorted(_plan_ids, "plan"))
        return false;
    {
        std::unordered_set<std::string> technology_ids;
        technology_ids.reserve(_technology_ids.size());
        for (const std::string &id : _technology_ids) {
            if (id.empty() || !technology_ids.insert(id).second) {
                error = "technology_ids_not_unique";
                return false;
            }
        }
    }
    if (_technology_ids.size() > 4096) {
        error = "technology_count_exceeds_4096";
        return false;
    }
    if (technology_prerequisite_offsets.size() != _technology_ids.size() + 1 ||
        technology_prerequisite_offsets.empty() ||
        technology_prerequisite_offsets.front() != 0 ||
        !std::is_sorted(technology_prerequisite_offsets.begin(),
                        technology_prerequisite_offsets.end()) ||
        technology_prerequisite_offsets.back() !=
            static_cast<int32_t>(technology_prerequisites.size())) {
        error = "technology_prerequisite_catalog_invalid";
        return false;
    }
    const size_t technology_ancestor_words = (_technology_ids.size() + 63) / 64;
    std::vector<uint64_t> technology_ancestor_bits(
        _technology_ids.size() * technology_ancestor_words, 0);
    for (size_t technology = 0; technology < _technology_ids.size(); ++technology) {
        uint64_t *row = technology_ancestor_bits.data() +
            technology * technology_ancestor_words;
        row[technology / 64] |= uint64_t{1} << (technology % 64);
        for (int32_t edge = technology_prerequisite_offsets[technology];
             edge < technology_prerequisite_offsets[technology + 1]; ++edge) {
            const int32_t prerequisite = technology_prerequisites[static_cast<size_t>(edge)];
            if (prerequisite < 0 || prerequisite >= static_cast<int32_t>(technology)) {
                error = "technology_prerequisite_order_invalid";
                return false;
            }
            const uint64_t *prerequisite_row = technology_ancestor_bits.data() +
                static_cast<size_t>(prerequisite) * technology_ancestor_words;
            for (size_t word = 0; word < technology_ancestor_words; ++word)
                row[word] |= prerequisite_row[word];
        }
    }
    auto resolve_tech = [&](const char *id) -> int32_t {
        const auto it = std::find(_technology_ids.begin(), _technology_ids.end(), id);
        return it == _technology_ids.end()
            ? -1 : static_cast<int32_t>(it - _technology_ids.begin());
    };
    _water_tech_river = resolve_tech("tech.river_transport");
    _water_tech_shallow = resolve_tech("tech.military.coastal_transport");
    _water_tech_far = resolve_tech("tech.celestial_navigation");
    _water_tech_deep = resolve_tech("tech.oceanic_ship_design");
    auto compile_technology_tags = [&](const std::vector<int32_t> &tag_offsets,
                                       const std::vector<std::string> &tags,
                                       size_t item_count,
                                       std::vector<int32_t> &offsets,
                                       std::vector<int32_t> &requirements,
                                       const char *reason) {
        if (tag_offsets.size() != item_count + 1 || tag_offsets.empty() ||
            tag_offsets.front() != 0 ||
            !std::is_sorted(tag_offsets.begin(), tag_offsets.end()) ||
            tag_offsets.back() != static_cast<int32_t>(tags.size())) {
            error = reason;
            return false;
        }
        offsets.clear(); requirements.clear(); offsets.push_back(0);
        for (size_t item = 0; item < item_count; ++item) {
            for (int32_t k = tag_offsets[item]; k < tag_offsets[item + 1]; ++k) {
                const std::string &tag = tags[k];
                if (tag.rfind("tech.", 0) != 0) continue;
                const auto it = std::find(_technology_ids.begin(), _technology_ids.end(), tag);
                if (it == _technology_ids.end() || *it != tag) {
                    error = std::string(reason) + ":" + tag;
                    return false;
                }
                requirements.push_back(static_cast<int32_t>(it - _technology_ids.begin()));
            }
            std::sort(requirements.begin() + offsets.back(), requirements.end());
            requirements.erase(std::unique(requirements.begin() + offsets.back(),
                                            requirements.end()), requirements.end());
            offsets.push_back(static_cast<int32_t>(requirements.size()));
        }
        return true;
    };

    const std::vector<int32_t> profession_tag_offsets =
        packed_i32(catalog, "profession_technology_tag_offsets");
    const std::vector<std::string> profession_tags =
        packed_strings(catalog, "profession_technology_tags");
    if (!compile_technology_tags(profession_tag_offsets, profession_tags,
            _profession_ids.size(), _profession_technology_offsets,
            _profession_required_technologies, "profession_technology_catalog_invalid")) return false;
    _profession_entry_savings_days = packed_i32(catalog, "profession_entry_savings_days");
    if (_profession_entry_savings_days.size() != _profession_ids.size())
        _profession_entry_savings_days.assign(_profession_ids.size(), 0);
    for (int32_t &days : _profession_entry_savings_days)
        days = std::clamp<int32_t>(days, 0, 36500);
    // Startup buffer for private investment. Legacy catalogs without the
    // column keep the historical one-month buffer.
    _profession_startup_capital_days = packed_i32(
        catalog, "profession_startup_capital_days");
    if (_profession_startup_capital_days.size() != _profession_ids.size())
        _profession_startup_capital_days.assign(_profession_ids.size(), 30);
    for (int32_t &days : _profession_startup_capital_days)
        days = std::clamp<int32_t>(days, 0, 36500);
    // Military v1 (design §5.1). Both columns are optional so every legacy
    // catalog keeps compiling with "no state service, no ration needs".
    const std::vector<int32_t> state_service_only = packed_i32(
        catalog, "profession_state_service_only");
    _profession_state_service_only.assign(_profession_ids.size(), uint8_t{0});
    if (!state_service_only.empty()) {
        if (state_service_only.size() != _profession_ids.size()) {
            error = "profession_state_service_only_size_mismatch";
            return false;
        }
        for (size_t p = 0; p < state_service_only.size(); ++p)
            _profession_state_service_only[p] = state_service_only[p] != 0 ? 1 : 0;
    }
    // Military v1 state-supplied needs are indices into the global need list, so
    // the need ids must be parsed before this block validates them and sizes the
    // mask by their count. Parsed here (and assigned to `_need_ids` below) instead
    // of after this block: doing it later left `_need_ids` empty on a fresh
    // configure and rejected every supplied index as out of range.
    const std::vector<std::string> catalog_need_ids = packed_strings(catalog, "need_ids");
    _state_supplied_need_columns = 0;
    _profession_state_supplied_need_mask.clear();
    const std::vector<int32_t> state_supplied_offsets = packed_i32(
        catalog, "profession_state_supplied_need_offsets");
    const std::vector<int32_t> state_supplied_needs = packed_i32(
        catalog, "profession_state_supplied_need_ids");
    if (!state_supplied_offsets.empty() || !state_supplied_needs.empty()) {
        if (state_supplied_offsets.size() != _profession_ids.size() + 1 ||
            state_supplied_offsets.front() != 0 ||
            !std::is_sorted(state_supplied_offsets.begin(),
                            state_supplied_offsets.end()) ||
            state_supplied_offsets.back() !=
                static_cast<int32_t>(state_supplied_needs.size())) {
            error = "profession_state_supplied_need_columns_invalid";
            return false;
        }
        for (size_t p = 0; p < _profession_ids.size(); ++p) {
            if (state_supplied_offsets[p] != state_supplied_offsets[p + 1] &&
                _profession_state_service_only[p] == 0) {
                error = "profession_state_supplied_need_without_state_service:" +
                    _profession_ids[p];
                return false;
            }
        }
        _profession_state_supplied_need_mask.assign(
            _profession_ids.size() * catalog_need_ids.size(), uint8_t{0});
        for (size_t p = 0; p < _profession_ids.size(); ++p) {
            for (int32_t k = state_supplied_offsets[p];
                 k < state_supplied_offsets[p + 1]; ++k) {
                const int32_t need = state_supplied_needs[static_cast<size_t>(k)];
                if (need < 0 || need >= static_cast<int32_t>(catalog_need_ids.size())) {
                    error = "profession_state_supplied_need_out_of_range:" +
                        _profession_ids[p];
                    return false;
                }
                _profession_state_supplied_need_mask[
                    p * catalog_need_ids.size() + static_cast<size_t>(need)] = 1;
                ++_state_supplied_need_columns;
            }
        }
    }

    _profession_need_weight_q16.clear();  // Ideology material-support baskets
    if (catalog.has("profession_need_weight_q16")) {
        const std::vector<int32_t> weights = packed_i32(catalog, "profession_need_weight_q16");
        if (weights.size() != _profession_ids.size() * catalog_need_ids.size()) {
            error = "profession_need_weight_columns_invalid"; return false;
        }
        _profession_need_weight_q16 = weights;
    }
    _good_default_price = packed_i32(catalog, "good_default_price");
    _good_default_stock = packed_i64(catalog, "good_initial_stock");
    if (catalog.has("good_min_price")) {
        error = "obsolete_good_min_price_price_v5";
        return false;
    }
    if (catalog.has("good_max_price")) {
        error = "obsolete_good_max_price_price_v6";
        return false;
    }
    _good_reference_max_price = packed_i32(catalog, "good_reference_max_price");
    _good_price_adjust_q16 = packed_i32(catalog, "good_price_adjust_q16");
    _good_demand_price_elasticity_q16 = packed_i32(catalog, "good_demand_price_elasticity_q16");
    _good_household_wealth_elasticity_q16 = packed_i32(
        catalog, "good_household_wealth_elasticity_q16");
    _good_household_savings_threshold_months_q16 = packed_i32(
        catalog, "good_household_savings_threshold_months_q16");
    _good_demand_ema_alpha_q16 = packed_i32(catalog, "good_demand_ema_alpha_q16");
    const std::vector<int32_t> good_inventory_target_ratios_q16 = packed_i32(
        catalog, "good_inventory_target_ratios_q16");
    _good_target_inventory_days_q16 = packed_i32(
        catalog, "good_target_inventory_days_q16");
    _good_inventory_weight_q16 = packed_i32(catalog, "good_inventory_weight_q16");
    _good_shortage_weight_q16 = packed_i32(catalog, "good_shortage_weight_q16");
    _good_excess_demand_weight_q16 = packed_i32(catalog, "good_excess_demand_weight_q16");
    _good_cost_anchor_weight_q16 = packed_i32(catalog, "good_cost_anchor_weight_q16");
    _good_inactive_reversion_weight_q16 = packed_i32(catalog, "good_inactive_reversion_weight_q16");
    _good_business_demand_ema_alpha_q16 = packed_i32(catalog, "good_business_demand_ema_alpha_q16");
    _good_supply_ema_alpha_q16 = packed_i32(catalog, "good_supply_ema_alpha_q16");
    _good_cost_ema_alpha_q16 = packed_i32(catalog, "good_cost_ema_alpha_q16");
    _good_max_price_rise_q16 = packed_i32(catalog, "good_max_price_rise_q16");
    _good_max_price_fall_q16 = packed_i32(catalog, "good_max_price_fall_q16");
    _good_merchant_buy_factor_q16 = packed_i32(catalog, "good_merchant_buy_factor_q16");
	const std::vector<int32_t> good_trade_enabled = packed_i32(catalog, "good_trade_enabled");
	_good_transport_load_per_unit_q16 = packed_i32(
		catalog, "good_transport_load_per_unit_q16");
	_good_category_ids = packed_strings(catalog, "good_category_ids");
    _good_is_essential.assign(_good_category_ids.size(), 0);
    for (size_t good = 0; good < _good_category_ids.size(); ++good) {
        const std::string &category = _good_category_ids[good];
        if (category == "staple_food" || category == "protein" ||
            category == "produce" || category == "clothing" ||
            category == "housing" || category == "household_goods" ||
            category == "hygiene" || category == "home_energy")
            _good_is_essential[good] = 1;
    }
	_good_storage_modes = packed_i32(catalog, "good_storage_modes");
	_good_monetary_issue_values = packed_i64(catalog, "good_monetary_issue_values");
	_good_technology_tag_offsets = packed_i32(catalog, "good_technology_tag_offsets");
	_good_technology_tags = packed_strings(catalog, "good_technology_tags");
    const size_t goods = _good_ids.size();
    if (!good_inventory_target_ratios_q16.empty()) {
        if (good_inventory_target_ratios_q16.size() != goods) {
            error = "good_inventory_target_ratio_size_mismatch";
            return false;
        }
        _good_target_inventory_days_q16.resize(goods);
        for (size_t i = 0; i < goods; ++i) {
            if (good_inventory_target_ratios_q16[i] < 0 ||
                good_inventory_target_ratios_q16[i] > Q16_ONE * 4) {
                error = "good_inventory_target_ratio_out_of_range";
                return false;
            }
            _good_target_inventory_days_q16[i] = static_cast<int32_t>(mul_div_sat(
                _merchant_market_making_days_q16.get(),
                good_inventory_target_ratios_q16[i], Q16_ONE,
                _saturation_count));
        }
    }
    if (_good_excess_demand_weight_q16.empty())
        _good_excess_demand_weight_q16.assign(goods, Q16_ONE / 8);
    if (_good_cost_anchor_weight_q16.empty())
        _good_cost_anchor_weight_q16.assign(goods, Q16_ONE / 4);
    if (_good_inactive_reversion_weight_q16.empty())
        _good_inactive_reversion_weight_q16.assign(goods, 512);
    if (_good_business_demand_ema_alpha_q16.empty())
        _good_business_demand_ema_alpha_q16.assign(goods, Q16_ONE / 8);
    if (_good_supply_ema_alpha_q16.empty())
        _good_supply_ema_alpha_q16.assign(goods, Q16_ONE / 8);
    if (_good_cost_ema_alpha_q16.empty())
        _good_cost_ema_alpha_q16.assign(goods, Q16_ONE / 16);
    // Legacy synthetic catalogs predate class/good wealth choice. Neutral
    // values preserve their exact behavior without weakening formal content.
    if (_good_household_wealth_elasticity_q16.empty())
        _good_household_wealth_elasticity_q16.assign(goods, 0);
    if (_good_household_savings_threshold_months_q16.empty())
        _good_household_savings_threshold_months_q16.assign(goods, 0);
    if (_good_default_price.size() != goods || _good_default_stock.size() != goods ||
        _good_reference_max_price.size() != goods ||
        _good_price_adjust_q16.size() != goods ||
        _good_demand_price_elasticity_q16.size() != goods ||
        _good_household_wealth_elasticity_q16.size() != goods ||
        _good_household_savings_threshold_months_q16.size() != goods ||
        _good_demand_ema_alpha_q16.size() != goods ||
        _good_target_inventory_days_q16.size() != goods ||
        _good_inventory_weight_q16.size() != goods ||
        _good_shortage_weight_q16.size() != goods ||
        _good_excess_demand_weight_q16.size() != goods ||
        _good_cost_anchor_weight_q16.size() != goods ||
        _good_inactive_reversion_weight_q16.size() != goods ||
        _good_business_demand_ema_alpha_q16.size() != goods ||
        _good_supply_ema_alpha_q16.size() != goods ||
        _good_cost_ema_alpha_q16.size() != goods ||
        _good_max_price_rise_q16.size() != goods ||
        _good_max_price_fall_q16.size() != goods ||
		_good_category_ids.size() != goods || _good_storage_modes.size() != goods ||
		_good_monetary_issue_values.size() != goods ||
		_good_technology_tag_offsets.size() != goods + 1 ||
		_good_technology_tag_offsets.empty() || _good_technology_tag_offsets.front() != 0 ||
		!std::is_sorted(_good_technology_tag_offsets.begin(), _good_technology_tag_offsets.end()) ||
		_good_technology_tag_offsets.back() != static_cast<int32_t>(_good_technology_tags.size()) ||
        (!_good_merchant_buy_factor_q16.empty() &&
         _good_merchant_buy_factor_q16.size() != goods)) {
        error = "good_parameter_size_mismatch";
        return false;
    }
    if (_good_merchant_buy_factor_q16.empty()) {
        _good_merchant_buy_factor_q16.assign(goods, 62259); // 0.95 Q16.
    }
    _good_trade_enabled.assign(goods, 1);
    if (!good_trade_enabled.empty()) {
        if (good_trade_enabled.size() != goods) {
            error = "good_trade_enabled_size_mismatch";
            return false;
        }
        for (size_t i = 0; i < goods; ++i)
            _good_trade_enabled[i] = good_trade_enabled[i] != 0 ? 1 : 0;
    }
    if (_good_transport_load_per_unit_q16.empty())
        _good_transport_load_per_unit_q16.assign(goods, Q16_ONE);
    if (_good_transport_load_per_unit_q16.size() != goods) {
        error = "good_transport_load_size_mismatch";
        return false;
    }
    if (!compile_technology_tags(_good_technology_tag_offsets, _good_technology_tags,
            goods, _good_technology_offsets, _good_required_technologies,
            "good_technology_catalog_invalid")) return false;
    for (size_t i = 0; i < goods; ++i) {
        if (_good_default_price[i] < PRICE_NUMERIC_GUARD_MIN ||
            _good_reference_max_price[i] < _good_default_price[i] || _good_default_stock[i] < 0 ||
            _good_demand_price_elasticity_q16[i] <= 0 ||
            _good_household_wealth_elasticity_q16[i] < -Q16_ONE ||
            _good_household_wealth_elasticity_q16[i] > Q16_ONE * 2 ||
            _good_household_savings_threshold_months_q16[i] < 0 ||
            _good_household_savings_threshold_months_q16[i] > Q16_ONE * 120 ||
            _good_excess_demand_weight_q16[i] < 0 ||
            _good_cost_anchor_weight_q16[i] < 0 ||
            _good_inactive_reversion_weight_q16[i] < 0 ||
            _good_business_demand_ema_alpha_q16[i] < 0 ||
            _good_business_demand_ema_alpha_q16[i] > Q16_ONE ||
            _good_supply_ema_alpha_q16[i] < 0 ||
            _good_supply_ema_alpha_q16[i] > Q16_ONE ||
            _good_cost_ema_alpha_q16[i] < 0 ||
            _good_cost_ema_alpha_q16[i] > Q16_ONE ||
            _good_merchant_buy_factor_q16[i] < 0 ||
			_good_merchant_buy_factor_q16[i] > Q16_ONE ||
			_good_category_ids[i].empty() || _good_storage_modes[i] < 0 ||
			_good_storage_modes[i] > 1 || _good_monetary_issue_values[i] < 0 ||
			(_good_storage_modes[i] == 1 && _good_ids[i] != "electricity") ||
			(_good_monetary_issue_values[i] > 0 && _good_ids[i] != "gold" &&
			 _good_ids[i] != "silver") || _good_transport_load_per_unit_q16[i] <= 0) {
            error = "good_parameter_out_of_range";
            return false;
        }
    }
	_cycle_flow_good_ids.clear();
	for (size_t i = 0; i < goods; ++i) {
		if (_good_storage_modes[i] == 1) {
			_cycle_flow_good_ids.push_back(static_cast<int32_t>(i));
			_good_trade_enabled[i] = 0;
		}
	}

#include "economy_runtime_catalog_needs_and_signatures.inc"
    _state_owner_signature = -1;
    for (size_t p = 0; p < _profession_state_service_only.size() &&
         _state_owner_signature < 0; ++p) {
        if (_profession_state_service_only[p] == 0) continue;
        for (size_t eth = 0; eth < _ethnicity_ids.size(); ++eth) {
            const int32_t signature = signature_for_profession_ethnicity(
                static_cast<int32_t>(p), static_cast<int32_t>(eth));
            if (signature >= 0) {
                _state_owner_signature = signature;
                break;
            }
        }
    }
    if (!compile_building_catalog(catalog, error)) return false;
    if (!compile_technology_tags(_building_technology_tag_offsets,
            _building_technology_tags, _building_type_ids.size(),
            _building_technology_offsets, _building_required_technologies,
            "building_technology_catalog_invalid")) return false;
    if (!compile_technology_tags(_building_required_technology_tag_offsets,
            _building_required_technology_tags, _building_type_ids.size(),
            _building_all_technology_offsets, _building_all_required_technologies,
            "building_required_technology_catalog_invalid")) return false;
    _building_technology_practice_masks.assign(_building_type_ids.size(), 0);
    auto type_has_technology = [&](size_t type, const char *wanted) {
        const auto wanted_it = std::find(_technology_ids.begin(), _technology_ids.end(), wanted);
        if (wanted_it == _technology_ids.end()) return false;
        const size_t wanted_id = static_cast<size_t>(wanted_it - _technology_ids.begin());
        auto requirement_has_ancestor = [&](int32_t requirement) {
            return requirement >= 0 &&
                requirement < static_cast<int32_t>(_technology_ids.size()) &&
                (technology_ancestor_bits[static_cast<size_t>(requirement) *
                    technology_ancestor_words + wanted_id / 64] &
                    (uint64_t{1} << (wanted_id % 64))) != 0;
        };
        for (int32_t edge = _building_technology_offsets[type];
             edge < _building_technology_offsets[type + 1]; ++edge)
            if (requirement_has_ancestor(
                    _building_required_technologies[static_cast<size_t>(edge)]))
                return true;
        for (int32_t edge = _building_all_technology_offsets[type];
             edge < _building_all_technology_offsets[type + 1]; ++edge)
            if (requirement_has_ancestor(
                    _building_all_required_technologies[static_cast<size_t>(edge)]))
                return true;
        return false;
    };
    auto type_outputs = [&](size_t type, const char *wanted) {
        if (type >= _building_types.size()) return false;
        const BuildingType &building = _building_types[type];
        for (int32_t i = building.output_begin;
             i < building.output_begin + building.output_count; ++i) {
            const int32_t good = _building_outputs[static_cast<size_t>(i)].good_id;
            if (good >= 0 && good < static_cast<int32_t>(_good_ids.size()) &&
                _good_ids[static_cast<size_t>(good)] == wanted)
                return true;
        }
        return false;
    };
    auto practice_bit = [](int32_t rule) { return uint32_t{1} << rule; };
    for (size_t type = 0; type < _building_type_ids.size(); ++type) {
        const std::string &id = _building_type_ids[type];
        const BuildingType &building = _building_types[type];
        uint32_t mask = 0;
        if (id.find("landed_estate") != std::string::npos ||
            type_outputs(type, "corn_grain"))
            mask |= practice_bit(PRACTICE_MAIZE_SELECTION);
        if (building.production_climate_profile_id >= 0 &&
            building.production_climate_profile_id <
                static_cast<int32_t>(_production_climate_profile_ids.size()) &&
            _production_climate_profile_ids[static_cast<size_t>(
                building.production_climate_profile_id)] == "dryland_crop") {
            mask |= practice_bit(PRACTICE_DRYLAND_DAYS) |
                    practice_bit(PRACTICE_DRYLAND_DROUGHTS);
        }
        if (type_has_technology(type, "tech.irrigation") ||
            type_has_technology(type, "tech.canal_engineering") ||
            type_has_technology(type, "tech.hydraulic_engineering") ||
            type_has_technology(type, "tech.rice_paddy_cultivation"))
            mask |= practice_bit(PRACTICE_HYDRAULIC_ENGINEERING);
        if (type_outputs(type, "tools") ||
            id.find("tool_workshop") != std::string::npos)
            mask |= practice_bit(PRACTICE_METALWORKING);
        if (type_outputs(type, "printed_materials"))
            mask |= practice_bit(PRACTICE_PRINTING);
        if (id.rfind("steam_", 0) == 0 ||
            type_has_technology(type, "tech.steam_power"))
            mask |= practice_bit(PRACTICE_STEAM_POWER);
        if (id.find("electric") != std::string::npos ||
            type_has_technology(type, "tech.electrification") ||
            type_has_technology(type, "tech.electric_grid"))
            mask |= practice_bit(PRACTICE_ELECTRIFICATION);
        if (building.kind == 1 && building.employee_count > 0)
            mask |= practice_bit(PRACTICE_INDUSTRIAL_ORGANIZATION);
        if (type_has_technology(type, "tech.robotic_manufacturing") ||
            type_has_technology(type, "tech.autonomous_systems") ||
            type_has_technology(type, "tech.automated_agriculture") ||
            type_has_technology(type, "tech.autonomous_mining") ||
            type_has_technology(type, "tech.digital_control") ||
            type_has_technology(type, "tech.automated_logistics") ||
            id.find("robot") != std::string::npos)
            mask |= practice_bit(PRACTICE_AUTOMATION);
        if (id == "computing_research_center" ||
            id == "industrial_research_laboratory" ||
            type_has_technology(type, "tech.climate_modeling"))
            mask |= practice_bit(PRACTICE_CLIMATE_MODELING);
        if (type_outputs(type, "corn_grain") || type_outputs(type, "wheat_grain") ||
            type_outputs(type, "rice_grain") || type_outputs(type, "potatoes") ||
            type_outputs(type, "seed_cotton"))
            mask |= practice_bit(PRACTICE_SEED_SAVING);
        if (building.production_climate_profile_id >= 0 &&
            building.production_climate_profile_id <
                static_cast<int32_t>(_production_climate_profile_ids.size())) {
            const std::string &climate = _production_climate_profile_ids[
                static_cast<size_t>(building.production_climate_profile_id)];
            if (climate == "dryland_crop")
                mask |= practice_bit(PRACTICE_RAINFED_ADAPTATION);
            if (climate == "paddy_crop")
                mask |= practice_bit(PRACTICE_PADDY_CONTROL);
        }
        if (id == "wild_tuber_patch" || id.find("terrace") != std::string::npos ||
            type_has_technology(type, "tech.terrace_farming"))
            mask |= practice_bit(PRACTICE_TERRACE_MAINTENANCE);
        const bool mine_working = id.find("mine") != std::string::npos ||
            id.find("adit") != std::string::npos ||
            id.find("placer_gold") != std::string::npos ||
            id.find("silver_working") != std::string::npos;
        if (mine_working)
            mask |= practice_bit(PRACTICE_MINE_SUPPORT);
        if (mine_working && (type_has_technology(type, "tech.deep_mining") ||
            type_has_technology(type, "tech.shaft_sinking") ||
            type_has_technology(type, "tech.mine_drainage") ||
            id.rfind("steam_", 0) == 0))
            mask |= practice_bit(PRACTICE_MINE_DRAINAGE);
        if (id.find("kiln") != std::string::npos ||
            id.find("smelter") != std::string::npos || id == "charcoal_pit" ||
            id == "bricks_plant")
            mask |= practice_bit(PRACTICE_KILN_TEMPERATURE);
        if (type_outputs(type, "printed_materials"))
            mask |= practice_bit(PRACTICE_PRINT_CALIBRATION);
        if (id.rfind("steam_", 0) == 0 || id == "atmospheric_engine_workshop")
            mask |= practice_bit(PRACTICE_STEAM_SEALING);
        if (type_outputs(type, "electric_motor") ||
            type_has_technology(type, "tech.electric_motors"))
            mask |= practice_bit(PRACTICE_MOTOR_WINDING);
        if (type_has_technology(type, "tech.assembly_line") ||
            type_has_technology(type, "tech.mass_production"))
            mask |= practice_bit(PRACTICE_ASSEMBLY_LINE);
        if (type_has_technology(type, "tech.digital_control") ||
            type_has_technology(type, "tech.autonomous_systems") ||
            type_has_technology(type, "tech.robotic_manufacturing"))
            mask |= practice_bit(PRACTICE_DIGITAL_CONTROL);
        if (id.find("shipyard") != std::string::npos ||
            type_has_technology(type, "tech.oceanic_navigation") ||
            type_has_technology(type, "tech.oceanic_ship_design") ||
            type_has_technology(type, "tech.coastal_shipyards") ||
            type_has_technology(type, "tech.automated_logistics") ||
            type_has_technology(type, "tech.autonomous_logistics"))
            mask |= practice_bit(PRACTICE_MARITIME_OPERATIONS);
        if (id.find("irrigation") != std::string::npos ||
            id.find("waterworks") != std::string::npos ||
            type_has_technology(type, "tech.canal_engineering") ||
            type_has_technology(type, "tech.hydraulic_engineering") ||
            type_has_technology(type, "tech.hydrological_remote_sensing") ||
            type_has_technology(type, "tech.precision_irrigation") ||
            type_has_technology(type, "tech.adaptive_irrigation"))
            mask |= practice_bit(PRACTICE_WATERSHED_MANAGEMENT);
        if (id.find("timber") != std::string::npos ||
            id.find("lumber") != std::string::npos ||
            type_outputs(type, "paper") || type_outputs(type, "lumber") ||
            type_has_technology(type, "tech.forest_management") ||
            type_has_technology(type, "tech.steam_sawmilling"))
            mask |= practice_bit(PRACTICE_FOREST_MANAGEMENT);
        if (id.find("chemical") != std::string::npos ||
            id.find("fertilizer") != std::string::npos ||
            id.find("petrochemical") != std::string::npos ||
            type_has_technology(type, "tech.industrial_chemistry") ||
            type_has_technology(type, "tech.electrochemistry") ||
            type_has_technology(type, "tech.petrochemical_cracking"))
            mask |= practice_bit(PRACTICE_CHEMICAL_PROCESS_CONTROL);
        if (id.find("power_plant") != std::string::npos ||
            type_has_technology(type, "tech.electric_generation") ||
            type_has_technology(type, "tech.electric_grid") ||
            type_has_technology(type, "tech.nuclear_energy") ||
            type_has_technology(type, "tech.smart_grid"))
            mask |= practice_bit(PRACTICE_ENERGY_CONTROL);
        if (type_outputs(type, "raw_hide"))
            mask |= practice_bit(PRACTICE_HIDE_WORKING);
        _building_technology_practice_masks[type] = mask;
    }
    for (int32_t rule = 0; rule < PRACTICE_RULE_COUNT; ++rule) {
        bool has_publisher = false;
        for (const uint32_t mask : _building_technology_practice_masks) {
            if ((mask & (uint32_t{1} << rule)) != 0) {
                has_publisher = true;
                break;
            }
        }
        if (!has_publisher) {
            error = "technology_practice_publisher_missing:" +
                std::to_string(rule);
            return false;
        }
    }
    const std::vector<std::string> research_signals = packed_strings(
        catalog, "research_signal_ids");
    auto signal_id = [&](const char *wanted) {
        const auto found = std::find(research_signals.begin(),
                                     research_signals.end(), wanted);
        return found != research_signals.end() && *found == wanted
            ? static_cast<int32_t>(found - research_signals.begin()) : -1;
    };
    _bio_maize_signal_id = signal_id("bio.maize");
    _research_signal_prefix_words = static_cast<int32_t>(
        (research_signals.size() + 63u) / 64u);
    _research_signal_prefix_masks.assign(
        static_cast<size_t>(_research_signal_prefix_words) * 3u, 0);
    static constexpr std::array<const char *, 3> kSignalPrefixes{
        "landform.", "weather.", "bio."};
    for (size_t signal = 0; signal < research_signals.size(); ++signal) {
        for (size_t prefix = 0; prefix < kSignalPrefixes.size(); ++prefix) {
            if (research_signals[signal].rfind(kSignalPrefixes[prefix], 0) != 0)
                continue;
            _research_signal_prefix_masks[
                prefix * static_cast<size_t>(_research_signal_prefix_words) +
                signal / 64u] |= uint64_t{1} << (signal % 64u);
        }
    }
    _good_occupancy_bit_offsets.assign(_good_ids.size() + 1, 0);
    _good_occupancy_bits.clear();
    {
        const std::vector<std::string> intro_goods = packed_strings(
            catalog, "research_bio_introduce_good_ids");
        const std::vector<int32_t> intro_bits = packed_i32(
            catalog, "research_bio_introduce_occupancy_bits");
        const size_t pair_count = std::min(intro_goods.size(), intro_bits.size());
        std::vector<std::vector<int32_t>> bits_by_good(_good_ids.size());
        for (size_t i = 0; i < pair_count; ++i) {
            const auto found = std::find(_good_ids.begin(), _good_ids.end(),
                                         intro_goods[i]);
            if (found == _good_ids.end() || *found != intro_goods[i]) continue;
            const int32_t bit = intro_bits[i];
            if (bit < 0 || bit >= 32) continue;
            bits_by_good[size_t(found - _good_ids.begin())].push_back(bit);
        }
        _good_occupancy_bit_offsets[0] = 0;
        for (size_t g = 0; g < _good_ids.size(); ++g) {
            auto &row = bits_by_good[g];
            std::sort(row.begin(), row.end());
            row.erase(std::unique(row.begin(), row.end()), row.end());
            _good_occupancy_bits.insert(_good_occupancy_bits.end(),
                                        row.begin(), row.end());
            _good_occupancy_bit_offsets[g + 1] =
                static_cast<int32_t>(_good_occupancy_bits.size());
        }
    }
    const std::array<const char *, 28> breakthrough_ids{
        "breakthrough.maize_selection", "breakthrough.dryland_adaptation",
        "breakthrough.hydraulic_engineering", "breakthrough.metalworking",
        "breakthrough.printing", "breakthrough.steam_power",
        "breakthrough.electrification", "breakthrough.industrial_organization",
        "breakthrough.automation", "breakthrough.climate_modeling",
        "breakthrough.seed_saving", "breakthrough.rainfed_adaptation",
        "breakthrough.paddy_control", "breakthrough.terrace_maintenance",
        "breakthrough.mine_support", "breakthrough.mine_drainage",
        "breakthrough.kiln_temperature", "breakthrough.print_calibration",
        "breakthrough.steam_sealing", "breakthrough.motor_winding",
        "breakthrough.assembly_line", "breakthrough.digital_control",
        "breakthrough.maritime_operations", "breakthrough.watershed_management",
        "breakthrough.forest_management", "breakthrough.chemical_process_control",
        "breakthrough.energy_control", "breakthrough.hide_working"};
    for (size_t i = 0; i < breakthrough_ids.size(); ++i)
        _breakthrough_signal_ids[i] = signal_id(breakthrough_ids[i]);
    for (size_t i = 22; i < breakthrough_ids.size(); ++i) {
        if (_breakthrough_signal_ids[i] < 0) {
            error = "technology_practice_signal_missing:" +
                std::string(breakthrough_ids[i]);
            return false;
        }
    }
    const std::array<const char *, 8> metal_signal_ids{
        "resource.copper_ore", "resource.iron_ore", "resource.tin_ore",
        "resource.gold_ore", "resource.silver_ore", "resource.lead_ore",
        "resource.zinc_ore", "resource.manganese_ore"};
    for (size_t i = 0; i < metal_signal_ids.size(); ++i)
        _metal_resource_signal_ids[i] = signal_id(metal_signal_ids[i]);
    _living_cost_base_plan_id = -1;
    for (size_t p = 0; p < _plan_ids.size(); ++p) {
        if (_plan_ids[p] == _living_cost_base_plan_stable_id) {
            _living_cost_base_plan_id = static_cast<int32_t>(p);
            break;
        }
    }
    if (_living_cost_base_plan_id < 0) {
        error = "living_cost_base_plan_missing:" + _living_cost_base_plan_stable_id;
        return false;
    }
    _survival_required_need_indices.assign(_need_ids.size(), -1);
    const Plan &survival_plan = _plans[_living_cost_base_plan_id];
    for (int32_t n = 0; n < survival_plan.need_count; ++n) {
        const int32_t need_index = survival_plan.need_begin + n;
        const int32_t stable_need = _needs[need_index].stable_id;
        if (_survival_required_need_indices[stable_need] >= 0) {
            error = "survival_required_need_duplicate:" + _need_ids[stable_need];
            return false;
        }
        _survival_required_need_indices[stable_need] = need_index;
    }
    for (int32_t stable_need : _survival_food_need_stable_ids) {
        if (_survival_required_need_indices[stable_need] < 0) {
            error = "survival_required_food_missing:" + _need_ids[stable_need];
            return false;
        }
    }
    if (_survival_required_need_indices[_survival_clothing_need_stable_id] < 0) {
        error = "survival_required_clothing_missing:" +
            _need_ids[_survival_clothing_need_stable_id];
        return false;
    }
    _catalog_hash = dict_num<int64_t>(catalog, "catalog_hash", 0);
    _catalog_compat_hash_v8 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v8", 0);
    _catalog_compat_hash_v10 = dict_num<int64_t>(catalog, "catalog_compat_hash_v10", 0);
    _catalog_compat_hash_v13 = dict_num<int64_t>(catalog, "catalog_compat_hash_v13", 0);
    _catalog_compat_hash_v39 = dict_num<int64_t>(catalog, "catalog_compat_hash_v39", 0);
    _catalog_compat_hash_v6 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v6", 0);
    _catalog_compat_hash_v7 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v7", 0);
    _building_catalog_hash = dict_num<int64_t>(catalog, "building_catalog_hash", 1);
    _building_catalog_compat_hash_v6 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v6", 0);
    _building_catalog_compat_hash_v7 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v7", 0);
    _building_catalog_compat_hash_v13 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v13", 0);
    if (_catalog_hash.get() == 0) {
        error = "catalog_hash_required";
        return false;
    }
    if (!compile_carrying_catalog(catalog, error)) return false;
    if (!compile_settlement_catalog(catalog, error)) return false;
    if (!compile_family_catalog(catalog, error)) return false;
    if (!compile_person_catalog(catalog, error)) return false;
    return compile_development_catalog(catalog, error);
}

} // namespace pk

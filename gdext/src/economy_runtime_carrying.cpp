#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <array>
#include <cstring>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

namespace {

constexpr const char *kCarryingFamilyIds[NativeEconomyRuntime::CARRYING_FAMILY_COUNT] = {
    "staple", "protein", "produce", "clothing", "housing", "household", "hygiene",
    "healthcare", "energy", "transport", "communication", "education", "recreation",
    "durables", "work_tools", "luxury", "status", "construction", "mill_tools",
    "metals", "bullion"};

constexpr int32_t kDefaultFamilyWeight[NativeEconomyRuntime::CARRYING_FAMILY_COUNT] = {
    10, 7, 5, 4, 4, 2, 4, 3, 3, 2, 1, 1, 1, 2, 3, 1, 1, 3, 2, 2, 1};

constexpr int32_t kDefaultLandform[NativeEconomyRuntime::CARRYING_LANDFORM_COUNT] = {
    3277, 6554, 26214, 36045, 65536, 58982, 45875, 22938, 6554, 72090,
    16384, 6554, 19661, 39322, 52429, 29491};

constexpr int32_t kDefaultVegetation[NativeEconomyRuntime::CARRYING_VEGETATION_COUNT] = {
    32768, 6554, 16384, 13107, 29491, 36045, 29491, 65536, 58982, 65536,
    45875, 42598, 58982, 49152, 52429, 45875, 19661, 6554, 52429, 45875,
    49152, 52429, 39322, 32768, 45875, 52429, 36045, 29491};

int32_t lut_or_one(const std::vector<int32_t> &lut, int32_t index) {
    constexpr int32_t one = static_cast<int32_t>(NativeEconomyRuntime::Q16_ONE);
    if (index < 0 || static_cast<size_t>(index) >= lut.size()) return one;
    return std::clamp(lut[static_cast<size_t>(index)], 0, one * 2);
}

} // namespace

void NativeEconomyRuntime::accumulate_trade_food_flow(
        int32_t cell, int32_t good, int64_t import_qty,
        int64_t export_qty, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count || good < 0 ||
        good >= static_cast<int32_t>(_good_food_equivalent_q16.size())) return;
    const int64_t coefficient = _good_food_equivalent_q16[
        static_cast<size_t>(good)];
    if (coefficient <= 0) return;
    ++_food_trade_events;
    const size_t lane = static_cast<size_t>(cell);
    if (lane >= _cell_food_import_eq_period.size()) return;
    _cell_food_import_eq_period[lane] = saturating_add(
        _cell_food_import_eq_period[lane],
        mul_div_sat(std::max<int64_t>(0, import_qty), coefficient, Q16_ONE, sat), sat);
    _cell_food_export_eq_period[lane] = saturating_add(
        _cell_food_export_eq_period[lane],
        mul_div_sat(std::max<int64_t>(0, export_qty), coefficient, Q16_ONE, sat), sat);
}

void NativeEconomyRuntime::commit_food_flow_snapshot() {
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count));
    if (_cell_food_output_eq_period.size() != cells ||
        _cell_food_input_eq_period.size() != cells ||
        _cell_food_import_eq_period.size() != cells ||
        _cell_food_export_eq_period.size() != cells ||
        _cell_food_access_eq_period.size() != cells) return;
    _cell_food_output_eq_previous.swap(_cell_food_output_eq_period);
    _cell_food_input_eq_previous.swap(_cell_food_input_eq_period);
    _cell_food_import_eq_previous.swap(_cell_food_import_eq_period);
    _cell_food_export_eq_previous.swap(_cell_food_export_eq_period);
    _cell_food_access_eq_previous.swap(_cell_food_access_eq_period);
    if (_cell_food_flow_valid.size() != cells)
        _cell_food_flow_valid.resize(cells, 0);
    std::fill(_cell_food_flow_valid.begin(), _cell_food_flow_valid.end(), 1);
    _food_flow_previous_period_days = std::max(1, _epoch_days);
    const int64_t denominator = saturating_mul(
        _food_flow_previous_period_days,
        std::max<int64_t>(1, _carrying_survival_food_per_person),
        _saturation_count);
    for (size_t cell = 0; cell < cells; ++cell) {
        int64_t k_geo = 0;
        _cell_carrying_k_eff[cell] = food_flow_capacity_for_cell(
            static_cast<int32_t>(cell), k_geo, _saturation_count);
        _cell_carrying_k_geo[cell] = k_geo;
    }
}

int64_t NativeEconomyRuntime::food_flow_capacity_for_cell(
        int32_t cell, int64_t &k_geo, int64_t &sat) const {
    k_geo = 0;
    if (cell < 0 || cell >= _cell_count ||
        static_cast<size_t>(cell) >= _cell_food_flow_valid.size() ||
        _cell_food_flow_valid[static_cast<size_t>(cell)] == 0) return 0;
    const int64_t flow_days = std::max<int32_t>(1, _food_flow_previous_period_days);
    const int64_t per_person_food = std::max<int64_t>(
        1, _carrying_survival_food_per_person);
    const int64_t denominator = saturating_mul(flow_days, per_person_food, sat);
    if (denominator <= 0) return 0;
    const size_t lane = static_cast<size_t>(cell);
    if (lane >= _cell_food_output_eq_previous.size() ||
        lane >= _cell_food_input_eq_previous.size() ||
        lane >= _cell_food_import_eq_previous.size() ||
        lane >= _cell_food_export_eq_previous.size()) return 0;
    const int64_t local = std::max<int64_t>(0,
        _cell_food_output_eq_previous[lane] -
        _cell_food_input_eq_previous[lane]);
    const int64_t effective = std::max<int64_t>(0, local +
        _cell_food_import_eq_previous[lane] -
        _cell_food_export_eq_previous[lane]);
    // A warehouse reserve is useful only for a bounded horizon. Convert
    // household-available stock into equivalent flow for the current period,
    // excluding production/construction reserves from the stock contribution.
    int64_t stock_food_eq = 0;
    if (cell < _market.market_count) {
        const int32_t market = cell;
        for (int32_t good = 0; good < _market.good_count; ++good) {
            if (good < 0 || good >= static_cast<int32_t>(
                    _good_food_equivalent_q16.size())) continue;
            const int32_t coefficient = _good_food_equivalent_q16[
                static_cast<size_t>(good)];
            if (coefficient <= 0) continue;
            const int64_t idx = _market.index(market, good);
            if (idx < 0 || idx >= static_cast<int64_t>(_market.stock.size())) continue;
            int64_t reserve = 0;
            const int32_t signal = market_signal_index(market, good);
            if (signal >= 0) {
                if (signal < static_cast<int32_t>(_production_input_reserve.size()))
                    reserve = std::max(reserve, _production_input_reserve[
                        static_cast<size_t>(signal)]);
                if (signal < static_cast<int32_t>(_construction_material_reserve.size()))
                    reserve = std::max(reserve, _construction_material_reserve[
                        static_cast<size_t>(signal)]);
            }
            const int64_t available = std::max<int64_t>(0,
                _market.stock[static_cast<size_t>(idx)] - reserve);
            stock_food_eq = saturating_add(stock_food_eq,
                mul_div_sat(available, coefficient, Q16_ONE, sat), sat);
        }
    }
    const int64_t stock_period_eq = mul_div_sat(
        stock_food_eq, flow_days,
        std::max<int32_t>(1, _carrying_stock_buffer_days), sat);
    const int64_t effective_with_stock = saturating_add(
        effective, stock_period_eq, sat);
    k_geo = local / denominator;
    return effective_with_stock / denominator;
}

bool NativeEconomyRuntime::compile_carrying_catalog(const Dictionary &catalog,
                                                    std::string &error) {
    _carrying_family_ids = packed_strings(catalog, "carrying_family_ids");
    _carrying_family_need_stable = packed_i32(catalog, "carrying_family_need_stable_ids");
    _carrying_family_good_offsets = packed_i32(catalog, "carrying_family_good_offsets");
    _carrying_family_goods = packed_i32(catalog, "carrying_family_good_ids");
    _carrying_support_resource_ids = packed_i32(catalog, "carrying_support_resource_ids");
    _carrying_food_yield_offsets = packed_i32(catalog, "carrying_food_yield_offsets");
    const std::vector<int32_t> yield_buildings =
        packed_i32(catalog, "carrying_food_yield_building_type_ids");
    const std::vector<int32_t> yield_resources =
        packed_i32(catalog, "carrying_food_yield_resource_ids");
    const std::vector<int32_t> yield_secondary =
        packed_i32(catalog, "carrying_food_yield_secondary_resource_ids");
    const std::vector<int64_t> yield_food =
        packed_i64(catalog, "carrying_food_yield_food_output");
    const std::vector<int64_t> yield_qty =
        packed_i64(catalog, "carrying_food_yield_resource_qty");
    const std::vector<int64_t> yield_secondary_qty =
        packed_i64(catalog, "carrying_food_yield_secondary_qty");
    const std::vector<int32_t> yield_modes =
        packed_i32(catalog, "carrying_food_yield_modes");
    if (_carrying_family_ids.size() != CARRYING_FAMILY_COUNT ||
        _carrying_family_need_stable.size() != CARRYING_FAMILY_COUNT ||
        _carrying_family_good_offsets.size() != CARRYING_FAMILY_COUNT + 1 ||
        _carrying_family_good_offsets.empty() ||
        _carrying_family_good_offsets.front() != 0 ||
        !std::is_sorted(_carrying_family_good_offsets.begin(),
                        _carrying_family_good_offsets.end()) ||
        _carrying_family_good_offsets.back() !=
            static_cast<int32_t>(_carrying_family_goods.size()) ||
        _carrying_support_resource_ids.size() != CARRYING_SUPPORT_RESOURCE_COUNT ||
        _carrying_food_yield_offsets.size() != CARRYING_SUPPORT_RESOURCE_COUNT + 1 ||
        _carrying_food_yield_offsets.empty() ||
        _carrying_food_yield_offsets.front() != 0 ||
        !std::is_sorted(_carrying_food_yield_offsets.begin(),
                        _carrying_food_yield_offsets.end()) ||
        _carrying_food_yield_offsets.back() !=
            static_cast<int32_t>(yield_buildings.size()) ||
        yield_resources.size() != yield_buildings.size() ||
        yield_secondary.size() != yield_buildings.size() ||
        yield_food.size() != yield_buildings.size() ||
        yield_qty.size() != yield_buildings.size() ||
        yield_secondary_qty.size() != yield_buildings.size() ||
        yield_modes.size() != yield_buildings.size()) {
        error = "carrying_catalog_shape_invalid";
        return false;
    }
    for (int32_t family = 0; family < CARRYING_FAMILY_COUNT; ++family) {
        if (_carrying_family_ids[static_cast<size_t>(family)] !=
            kCarryingFamilyIds[family]) {
            error = "carrying_family_id_mismatch:" +
                _carrying_family_ids[static_cast<size_t>(family)];
            return false;
        }
        const int32_t need = _carrying_family_need_stable[static_cast<size_t>(family)];
        if (family < CARRYING_NEED_FAMILY_COUNT) {
            if (need < 0 || need >= static_cast<int32_t>(_need_ids.size())) {
                error = "carrying_family_need_invalid";
                return false;
            }
        } else if (need != -1) {
            error = "carrying_producer_family_need_invalid";
            return false;
        }
        for (int32_t edge = _carrying_family_good_offsets[family];
             edge < _carrying_family_good_offsets[family + 1]; ++edge) {
            const int32_t good = _carrying_family_goods[static_cast<size_t>(edge)];
            if (good < 0 || good >= static_cast<int32_t>(_good_ids.size())) {
                error = "carrying_family_good_invalid";
                return false;
            }
        }
    }
    _need_carrying_family.assign(_need_ids.size(), -1);
    for (int32_t family = 0; family < CARRYING_NEED_FAMILY_COUNT; ++family) {
        const int32_t need = _carrying_family_need_stable[static_cast<size_t>(family)];
        if (_need_carrying_family[static_cast<size_t>(need)] >= 0) {
            error = "carrying_need_family_duplicate";
            return false;
        }
        _need_carrying_family[static_cast<size_t>(need)] = family;
    }
    _carrying_food_yields.resize(yield_buildings.size());
    for (size_t i = 0; i < yield_buildings.size(); ++i) {
        if (yield_buildings[i] < 0 ||
            yield_buildings[i] >= static_cast<int32_t>(_building_types.size()) ||
            yield_resources[i] < 0 ||
            yield_resources[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            yield_food[i] <= 0 || yield_qty[i] <= 0 ||
            (yield_secondary[i] < -1) ||
            (yield_secondary[i] >= static_cast<int32_t>(_resource_ids.size())) ||
            (yield_modes[i] != 0 && yield_modes[i] != 1)) {
            error = "carrying_food_yield_row_invalid";
            return false;
        }
        _carrying_food_yields[i] = {
            yield_buildings[i], yield_resources[i], yield_secondary[i],
            yield_modes[i], yield_food[i], yield_qty[i],
            std::max<int64_t>(0, yield_secondary_qty[i])};
    }
    for (int32_t support = 0; support < CARRYING_SUPPORT_RESOURCE_COUNT; ++support) {
        const int32_t resource = _carrying_support_resource_ids[static_cast<size_t>(support)];
        if (resource != -1 &&
            (resource < 0 || resource >= static_cast<int32_t>(_resource_ids.size()))) {
            error = "carrying_support_resource_invalid";
            return false;
        }
    }
    const std::vector<std::string> profession_class_ids =
        packed_strings(catalog, "profession_class_ids");
    std::vector<std::string> class_ids;
    if (profession_class_ids.size() == _profession_ids.size()) {
        class_ids = profession_class_ids;
        for (std::string &id : class_ids) {
            if (id.empty()) id = "general";
        }
    } else {
        class_ids.assign(_profession_ids.size(), "general");
    }
    // Political classes deliberately have their own intern table. Carrying
    // weights are a population-capacity concern and must never become the
    // identity or weighting contract consumed by IdeologyRuntime.
    _political_class_ids = class_ids;
    std::sort(_political_class_ids.begin(), _political_class_ids.end());
    _political_class_ids.erase(
        std::unique(_political_class_ids.begin(), _political_class_ids.end()),
        _political_class_ids.end());
    if (_political_class_ids.empty()) _political_class_ids.push_back("general");
    _profession_political_class_index.assign(_profession_ids.size(), 0);
    for (size_t profession = 0; profession < class_ids.size(); ++profession) {
        const auto found = std::lower_bound(_political_class_ids.begin(),
            _political_class_ids.end(), class_ids[profession]);
        _profession_political_class_index[profession] =
            found == _political_class_ids.end() ||
                    *found != class_ids[profession]
                ? 0 : static_cast<int32_t>(
                    found - _political_class_ids.begin());
    }
    _political_class_hash = 1469598103934665603ULL;
    for (const std::string &id : _political_class_ids) {
        for (const unsigned char value : id) {
            _political_class_hash ^= value;
            _political_class_hash *= 1099511628211ULL;
        }
        _political_class_hash ^= 0xffU;
        _political_class_hash *= 1099511628211ULL;
    }
    _carrying_class_ids = class_ids;
    std::sort(_carrying_class_ids.begin(), _carrying_class_ids.end());
    _carrying_class_ids.erase(
        std::unique(_carrying_class_ids.begin(), _carrying_class_ids.end()),
        _carrying_class_ids.end());
    if (_carrying_class_ids.empty())
        _carrying_class_ids.push_back("general");
    _profession_class_index.assign(_profession_ids.size(), 0);
    for (size_t profession = 0; profession < class_ids.size(); ++profession) {
        const auto found = std::lower_bound(
            _carrying_class_ids.begin(), _carrying_class_ids.end(),
            class_ids[profession]);
        _profession_class_index[profession] =
            found == _carrying_class_ids.end() || *found != class_ids[profession]
                ? 0 : static_cast<int32_t>(found - _carrying_class_ids.begin());
    }
    _carrying_class_weight_q16.assign(_carrying_class_ids.size(), Q16_ONE);
    for (size_t i = 0; i < _carrying_profile_class_ids.size() &&
         i < _carrying_profile_class_weight_q16.size(); ++i) {
        const auto found = std::lower_bound(
            _carrying_class_ids.begin(), _carrying_class_ids.end(),
            _carrying_profile_class_ids[i]);
        if (found == _carrying_class_ids.end() ||
            *found != _carrying_profile_class_ids[i]) continue;
        _carrying_class_weight_q16[static_cast<size_t>(
            found - _carrying_class_ids.begin())] = std::clamp(
            _carrying_profile_class_weight_q16[i], 1,
            static_cast<int32_t>(Q16_ONE * 4));
    }
    if (_carrying_family_weight.size() != CARRYING_FAMILY_COUNT) {
        _carrying_family_weight.assign(
            kDefaultFamilyWeight, kDefaultFamilyWeight + CARRYING_FAMILY_COUNT);
    }
    // Food-equivalent coefficients convert one goods subunit into the fraction
    // of an authored survival need it covers, so the food-flow numerator is
    // already measured in need units. The per-person denominator must therefore
    // be the authored ration itself: the sum of base_qty_per_person across the
    // survival food needs of the base living-cost plan. Counting needs instead
    // of quantities silently assumed one full need unit per need per day, which
    // overstated the ration by ~239x and pinned every settlement at maximum
    // carrying load.
    _carrying_survival_food_per_person = 0;
    if (_living_cost_base_plan_id >= 0 &&
        _living_cost_base_plan_id < static_cast<int32_t>(_plans.size())) {
        int64_t food_need_count = 0;
        int64_t ration_per_person = 0;
        int64_t sat = 0;
        const Plan &plan = _plans[static_cast<size_t>(_living_cost_base_plan_id)];
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const Need &need = _needs[static_cast<size_t>(plan.need_begin + n)];
            if (need.stable_id >= 0 &&
                static_cast<size_t>(need.stable_id) < _survival_food_need_mask.size() &&
                _survival_food_need_mask[static_cast<size_t>(need.stable_id)] != 0) {
                ++food_need_count;
                ration_per_person = saturating_add(ration_per_person,
                    std::max<int64_t>(0, need.base_qty_per_person), sat);
            }
        }
        if (ration_per_person > 0) {
            _carrying_survival_food_per_person = ration_per_person;
        } else if (food_need_count > 0) {
            // Defensive fallback for a plan that authors no positive ration:
            // keep one need unit per food need so capacity stays finite.
            _carrying_survival_food_per_person = saturating_mul(
                food_need_count, GOODS_SCALE, sat);
        }
    }
    return true;
}

void NativeEconomyRuntime::refresh_epoch_carrying_yields() {
    const size_t countries = static_cast<size_t>(std::max(0, _epoch_country_count));
    _epoch_country_support_yield.assign(
        countries * CARRYING_SUPPORT_RESOURCE_COUNT, {});
    if (_carrying_food_yield_offsets.size() != CARRYING_SUPPORT_RESOURCE_COUNT + 1)
        return;
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t support = 0; support < CARRYING_SUPPORT_RESOURCE_COUNT; ++support) {
            NativeEconomyRuntime::CarryingSupportYield best;
            int64_t best_score = -1;
            int64_t sat = 0;
            const int32_t begin = _carrying_food_yield_offsets[static_cast<size_t>(support)];
            const int32_t end = _carrying_food_yield_offsets[static_cast<size_t>(support) + 1];
            for (int32_t row = begin; row < end; ++row) {
                const NativeEconomyRuntime::CarryingSupportYield &yield =
                    _carrying_food_yields[static_cast<size_t>(row)];
                const size_t cache = static_cast<size_t>(country) *
                    _building_types.size() +
                    static_cast<size_t>(yield.building_type_id);
                if (cache >= _epoch_country_building_available.size() ||
                    _epoch_country_building_available[cache] == 0) continue;
                const int64_t score = mul_div_sat(
                    yield.food_output_per_day, Q16_ONE,
                    std::max<int64_t>(1, yield.resource_qty), sat);
                if (score > best_score) {
                    best_score = score;
                    best = yield;
                }
            }
            _epoch_country_support_yield[
                static_cast<size_t>(country) * CARRYING_SUPPORT_RESOURCE_COUNT +
                static_cast<size_t>(support)] = best;
        }
    }
}

int64_t NativeEconomyRuntime::carrying_mix_q16(int64_t value_q16, int32_t elasticity_q16,
                                               int64_t &sat) const {
    const int32_t elasticity = std::clamp(
        elasticity_q16, 0, static_cast<int32_t>(Q16_ONE));
    const int64_t value = std::clamp<int64_t>(value_q16, 0, Q16_ONE * 4);
    return saturating_add(Q16_ONE, mul_div_sat(
        elasticity, value - Q16_ONE, Q16_ONE, sat), sat);
}

int64_t NativeEconomyRuntime::carrying_climate_habitability_q16(
        int32_t cell, int64_t &sat) const {
    const int32_t temp = cell >= 0 &&
            static_cast<size_t>(cell) < _environment_temperature_30d_q16.size()
        ? _environment_temperature_30d_q16[static_cast<size_t>(cell)] : Q16_ONE / 2;
    const int32_t paw = cell >= 0 &&
            static_cast<size_t>(cell) < _environment_plant_available_water_q16.size()
        ? _environment_plant_available_water_q16[static_cast<size_t>(cell)]
        : Q16_ONE / 2;
    auto band_fit = [&](int32_t value, int32_t lo, int32_t hi) -> int64_t {
        const int32_t opt_lo = std::min(lo, hi);
        const int32_t opt_hi = std::max(lo, hi);
        const int32_t x = std::clamp(value, 0, static_cast<int32_t>(Q16_ONE));
        if (x >= opt_lo && x <= opt_hi) return Q16_ONE;
        if (x < opt_lo) {
            if (opt_lo <= 0) return 0;
            return mul_div_sat(x, Q16_ONE, opt_lo, sat);
        }
        if (opt_hi >= static_cast<int32_t>(Q16_ONE)) return 0;
        return mul_div_sat(Q16_ONE - x, Q16_ONE, Q16_ONE - opt_hi, sat);
    };
    const int64_t temp_fit = band_fit(
        temp, _carrying_temp_opt_lo_q16, _carrying_temp_opt_hi_q16);
    const int64_t paw_fit = band_fit(
        paw, _carrying_paw_opt_lo_q16, _carrying_paw_opt_hi_q16);
    return std::max<int64_t>(Q16_ONE / 8, std::min(temp_fit, paw_fit));
}

int64_t NativeEconomyRuntime::carrying_resource_stock(int32_t resource_id,
                                                      int32_t cell) const {
    if (cell < 0 || cell >= _cell_count || resource_id < 0 ||
        resource_id >= static_cast<int32_t>(_resource_ids.size())) return 0;
    const size_t idx = static_cast<size_t>(resource_id) *
        static_cast<size_t>(_cell_count) + static_cast<size_t>(cell);
    if (idx >= _resource_snapshot.size()) return 0;
    return std::max<int64_t>(0, _resource_snapshot[idx]);
}

int64_t NativeEconomyRuntime::cell_k_geo_persons(int32_t cell, int64_t &sat) const {
    const int64_t habitat_ref = std::max<int64_t>(0, _carrying_k_habitat_ref);
    const int64_t floor_k = std::max<int64_t>(0, _carrying_k_floor);
    if (cell < 0 || cell >= _cell_count ||
        _building_landform.size() != static_cast<size_t>(_cell_count)) {
        return std::max(floor_k, habitat_ref);
    }
    const bool is_water = _building_is_water[static_cast<size_t>(cell)] != 0;
    const bool has_river = _building_has_river[static_cast<size_t>(cell)] != 0;
    int64_t habitability = carrying_climate_habitability_q16(cell, sat);
    habitability = mul_div_sat(habitability, lut_or_one(
        _carrying_landform_habitability_q16,
        _building_landform[static_cast<size_t>(cell)]), Q16_ONE, sat);
    habitability = mul_div_sat(habitability, lut_or_one(
        _carrying_vegetation_habitability_q16,
        _building_vegetation[static_cast<size_t>(cell)]), Q16_ONE, sat);
    if (has_river && !is_water) {
        habitability = mul_div_sat(habitability,
            std::max(1, _carrying_river_bonus_q16), Q16_ONE, sat);
    }
    if (is_water) {
        habitability = mul_div_sat(habitability,
            std::max(1, _carrying_water_habitability_q16), Q16_ONE, sat);
    } else {
        const int32_t elevation = static_cast<size_t>(cell) <
                _building_elevation_q16.size()
            ? _building_elevation_q16[static_cast<size_t>(cell)] : 0;
        if (elevation > (Q16_ONE * 82) / 100) {
            habitability = mul_div_sat(habitability, Q16_ONE / 4, Q16_ONE, sat);
        } else if (elevation > (Q16_ONE * 62) / 100) {
            habitability = mul_div_sat(habitability, Q16_ONE / 2, Q16_ONE, sat);
        }
    }
    const int64_t k_habitat = mul_div_sat(habitat_ref, habitability, Q16_ONE, sat);
    int64_t k_resource = 0;
    const int32_t country = static_cast<size_t>(cell) < _epoch_cell_country.size()
        ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
    if (country >= 0 && country < _epoch_country_count &&
        _epoch_country_support_yield.size() ==
            static_cast<size_t>(std::max(0, _epoch_country_count)) *
                CARRYING_SUPPORT_RESOURCE_COUNT) {
        for (int32_t support = 0; support < CARRYING_SUPPORT_RESOURCE_COUNT; ++support) {
            const bool dryland = support <= 4;
            const bool marine = support == 6;
            const bool freshwater = support == 5;
            if (is_water && dryland) continue;
            if (!is_water && marine) continue;
            if (!is_water && freshwater && !has_river) continue;
            const NativeEconomyRuntime::CarryingSupportYield &yield =
                _epoch_country_support_yield[
                    static_cast<size_t>(country) * CARRYING_SUPPORT_RESOURCE_COUNT +
                    static_cast<size_t>(support)];
            if (yield.building_type_id < 0 || yield.resource_qty <= 0 ||
                yield.food_output_per_day <= 0) continue;
            int64_t harvestable = carrying_resource_stock(yield.resource_id, cell);
            if (yield.mode == 0) {
                int64_t dummy = 0;
                const int64_t capacity =
                    yield.resource_id >= 0 &&
                    yield.resource_id < static_cast<int32_t>(_resource_ecology_capacity.size())
                        ? _resource_ecology_capacity[static_cast<size_t>(yield.resource_id)] : 0;
                const int64_t reserve_floor = mul_div_sat(
                    harvestable, _resource_min_reserve_q16, Q16_ONE, dummy);
                const int64_t harvestable_stock = std::max<int64_t>(
                    0, harvestable - reserve_floor);
                const int64_t biomass = std::min<int64_t>(
                    capacity > 0 ? capacity / 8 : harvestable_stock, harvestable_stock);
                const int32_t growth = yield.resource_id >= 0 &&
                    yield.resource_id < static_cast<int32_t>(
                        _resource_ecology_growth_q16.size())
                    ? _resource_ecology_growth_q16[static_cast<size_t>(yield.resource_id)]
                    : 0;
                harvestable = mul_div_sat(mul_div_sat(biomass, std::max(0, growth),
                    Q16_ONE, dummy), std::max(0, _resource_safe_harvest_q16),
                    Q16_ONE, dummy);
            }
            if (yield.secondary_resource_id >= 0 && yield.secondary_qty > 0) {
                const int64_t secondary = carrying_resource_stock(
                    yield.secondary_resource_id, cell);
                const int64_t primary_equiv = mul_div_sat(
                    harvestable, Q16_ONE, yield.resource_qty, sat);
                const int64_t secondary_equiv = mul_div_sat(
                    secondary, Q16_ONE, yield.secondary_qty, sat);
                harvestable = mul_div_sat(
                    std::min(primary_equiv, secondary_equiv), yield.resource_qty,
                    Q16_ONE, sat);
            }
            int64_t food = mul_div_sat(harvestable, yield.food_output_per_day,
                yield.resource_qty, sat);
            if (yield.building_type_id >= 0 &&
                yield.building_type_id < static_cast<int32_t>(_building_types.size())) {
                const BuildingType &type =
                    _building_types[static_cast<size_t>(yield.building_type_id)];
                int64_t climate = production_climate_capacity_q16(
                    type, cell, nullptr, nullptr, sat);
                food = mul_div_sat(food, climate, Q16_ONE, sat);
                food = mul_div_sat(food, std::max(1, _building_output_efficiency_q16),
                    Q16_ONE, sat);
                food = mul_div_sat(food,
                    std::max(1, _food_building_output_efficiency_q16),
                    Q16_ONE, sat);
                if (static_cast<size_t>(country) <
                    _epoch_country_output_factor_q16.size()) {
                    food = mul_div_sat(food,
                        _epoch_country_output_factor_q16[static_cast<size_t>(country)],
                        Q16_ONE, sat);
                }
                const size_t sector_index = static_cast<size_t>(country) * 5U +
                    static_cast<size_t>(std::clamp(type.economic_sector, 0, 4));
                if (sector_index < _epoch_country_sector_output_factor_q16.size()) {
                    food = mul_div_sat(food,
                        _epoch_country_sector_output_factor_q16[sector_index],
                        Q16_ONE, sat);
                }
                const size_t building_index = static_cast<size_t>(country) *
                    _building_types.size() +
                    static_cast<size_t>(yield.building_type_id);
                if (building_index < _epoch_country_building_output_factor_q16.size()) {
                    food = mul_div_sat(food,
                        _epoch_country_building_output_factor_q16[building_index],
                        Q16_ONE, sat);
                }
            }
            k_resource = saturating_add(k_resource, mul_div_sat(
                food, 1, std::max<int64_t>(1, _carrying_survival_food_per_person),
                sat), sat);
        }
    }
    return std::max(floor_k, saturating_add(k_habitat, k_resource, sat));
}

int64_t NativeEconomyRuntime::cell_family_surplus_q16(
        int32_t market, int32_t cell, int32_t family, int64_t food_filled,
        int64_t food_desired, const int64_t *good_demand,
        const int64_t *good_sales, int64_t &sat) const {
    if (family < 0 || family >= CARRYING_FAMILY_COUNT ||
        market < 0 || market >= _market.market_count) return Q16_ONE;
    if (_carrying_family_good_offsets.size() != CARRYING_FAMILY_COUNT + 1)
        return Q16_ONE;
    const int32_t availability_cell = cell >= 0 ? cell : market;
    const int32_t begin = _carrying_family_good_offsets[static_cast<size_t>(family)];
    const int32_t end = _carrying_family_good_offsets[static_cast<size_t>(family) + 1];
    int64_t cover_num = 0;
    int64_t cover_den = 0;
    bool bindable = false;
    for (int32_t edge = begin; edge < end; ++edge) {
        const int32_t good = _carrying_family_goods[static_cast<size_t>(edge)];
        if (!good_available(availability_cell, good, true)) continue;
        bindable = true;
        const int64_t idx = _market.index(market, good);
        if (idx < 0 || idx >= static_cast<int64_t>(_market.demand_ema.size())) continue;
        const int64_t demand_ema = std::max<int64_t>(0, _market.demand_ema[
            static_cast<size_t>(idx)]);
        if (demand_ema <= 0) continue;
        int64_t shortage = 0;
        if (good_demand != nullptr && good_sales != nullptr &&
            good >= 0 && good < _market.good_count) {
            shortage = good_demand[good] <= 0 ? 0 : std::clamp<int64_t>(
                Q16_ONE - mul_div_sat(good_sales[good], Q16_ONE,
                                      good_demand[good], sat),
                0, Q16_ONE);
        } else if (idx < static_cast<int64_t>(_market.last_shortage_q16.size())) {
            shortage = std::clamp<int64_t>(_market.last_shortage_q16[
                static_cast<size_t>(idx)], 0, Q16_ONE);
        }
        int64_t cover = Q16_ONE - shortage;
        if (idx < static_cast<int64_t>(_market.stock.size()) &&
            good < static_cast<int32_t>(_good_target_inventory_days_q16.size())) {
            const int64_t target = std::max<int64_t>(GOODS_SCALE, mul_div_sat(
                demand_ema, std::max(1, _good_target_inventory_days_q16[
                    static_cast<size_t>(good)]), Q16_ONE, sat));
            const int64_t stock_cover = mul_div_sat(
                std::max<int64_t>(0, _market.stock[static_cast<size_t>(idx)]),
                Q16_ONE, target, sat);
            cover = (cover + std::clamp<int64_t>(stock_cover, 0, Q16_ONE * 4)) / 2;
        }
        cover_num = saturating_add(cover_num, saturating_mul(cover, demand_ema, sat), sat);
        cover_den = saturating_add(cover_den, demand_ema, sat);
    }
    if (!bindable) return -1;
    int64_t family_surplus = cover_den > 0
        ? mul_div_sat(cover_num, 1, cover_den, sat) : Q16_ONE;
    if (family < 3 && food_desired > 0) {
        const int64_t fill_cover = std::clamp<int64_t>(
            mul_div_sat(std::max<int64_t>(0, food_filled), Q16_ONE,
                        food_desired, sat), 0, Q16_ONE);
        family_surplus = (family_surplus + fill_cover) / 2;
    }
    return std::clamp<int64_t>(family_surplus, _carrying_surplus_floor_q16,
                               _carrying_surplus_cap_q16);
}

void NativeEconomyRuntime::append_carrying_capacity_fields(
        Dictionary &out, int32_t cell_idx) const {
    if (cell_idx < 0 || cell_idx >= _cell_count) return;
    const size_t cell = static_cast<size_t>(cell_idx);
    const int64_t flow_days = std::max<int32_t>(1, _food_flow_previous_period_days);
    const bool valid = cell < _cell_food_flow_valid.size() &&
        _cell_food_flow_valid[cell] != 0;
    const int64_t local_net = valid && cell < _cell_food_output_eq_previous.size()
        ? std::max<int64_t>(0, _cell_food_output_eq_previous[cell] -
            _cell_food_input_eq_previous[cell]) : 0;
    const int64_t effective_supply = valid && cell < _cell_food_import_eq_previous.size()
        ? std::max<int64_t>(0, local_net + _cell_food_import_eq_previous[cell] -
            _cell_food_export_eq_previous[cell]) : 0;
    int64_t sat = 0;
    int64_t stock_food_eq = 0;
    if (cell_idx < _market.market_count) {
        for (int32_t good = 0; good < _market.good_count; ++good) {
            if (good < 0 || good >= static_cast<int32_t>(
                    _good_food_equivalent_q16.size())) continue;
            const int32_t coefficient = _good_food_equivalent_q16[
                static_cast<size_t>(good)];
            if (coefficient <= 0) continue;
            const int64_t idx = _market.index(cell_idx, good);
            if (idx < 0 || idx >= static_cast<int64_t>(_market.stock.size())) continue;
            int64_t reserve = 0;
            const int32_t signal = market_signal_index(cell_idx, good);
            if (signal >= 0) {
                if (signal < static_cast<int32_t>(_production_input_reserve.size()))
                    reserve = std::max(reserve, _production_input_reserve[
                        static_cast<size_t>(signal)]);
                if (signal < static_cast<int32_t>(_construction_material_reserve.size()))
                    reserve = std::max(reserve, _construction_material_reserve[
                        static_cast<size_t>(signal)]);
            }
            const int64_t available = std::max<int64_t>(0,
                _market.stock[static_cast<size_t>(idx)] - reserve);
            stock_food_eq = saturating_add(stock_food_eq,
                mul_div_sat(available, coefficient, Q16_ONE, sat), sat);
        }
    }
    const int64_t stock_daily = stock_food_eq /
        std::max<int32_t>(1, _carrying_stock_buffer_days);
    const int64_t local_daily = local_net / flow_days;
    const int64_t effective_daily = effective_supply / flow_days;
    int64_t population = 0;
    _population.for_each_in_cell(cell_idx, [&](int32_t slot) {
        population = saturating_add(population,
            std::max<int64_t>(0, _population.population[slot]),
            sat);
    });
    int64_t access_q16 = Q16_ONE;
    if (valid && cell < _cell_food_access_eq_previous.size() && population > 0) {
        const int64_t denominator = saturating_mul(
            saturating_mul(population, flow_days,
                sat),
            std::max<int64_t>(1, _carrying_survival_food_per_person),
            sat);
        access_q16 = denominator > 0 ? std::clamp<int64_t>(mul_div_sat(
            _cell_food_access_eq_previous[cell], Q16_ONE, denominator,
            sat), 0, Q16_ONE) : 0;
    }
    out["carrying_schema_version"] = 2;
    out["carrying_survival_food_per_person"] =
        std::max<int64_t>(1, _carrying_survival_food_per_person);
    out["local_food_output_eq_per_day"] = local_daily;
    out["effective_food_supply_eq_per_day"] = effective_daily;
    out["food_stock_eq"] = stock_food_eq;
    out["food_stock_capacity_persons"] = stock_daily /
        std::max<int64_t>(1, _carrying_survival_food_per_person);
    out["local_food_capacity_persons"] = cell < _cell_carrying_k_geo.size()
        ? _cell_carrying_k_geo[cell] : 0;
    out["effective_food_capacity_persons"] = cell < _cell_carrying_k_eff.size()
        ? _cell_carrying_k_eff[cell] : 0;
    out["food_access_q16"] = access_q16;
    out["population_load_q16"] = cell < _cell_carrying_k_eff.size() &&
            _cell_carrying_k_eff[cell] > 0
        ? std::clamp<int64_t>(mul_div_sat(population, Q16_ONE,
            _cell_carrying_k_eff[cell], sat),
            0, Q16_ONE * 4) : (valid && population > 0 ? Q16_ONE * 4 : 0);
    out["carrying_k_geo"] = cell < _cell_carrying_k_geo.size()
        ? _cell_carrying_k_geo[cell] : 0;
    out["carrying_k_eff"] = cell < _cell_carrying_k_eff.size()
        ? _cell_carrying_k_eff[cell] : 0;
}

} // namespace pk
